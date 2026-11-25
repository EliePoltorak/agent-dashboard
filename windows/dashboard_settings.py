#!/usr/bin/env python3
"""dashboard_settings.py - the Agent Dashboard's Settings panel, server side.

Routes (all on the dashboard's own loopback server; usage-history.py only delegates to serve()):
  GET  /settings.js               the drawer's script (settings.js next to this file)
  GET  /api/settings/seats        every provider's seats, removed seats, what each provider can do
  GET  /api/settings/automation   scheduled tasks, rotate proxy, keepalive, auto-resume
  GET  /api/settings/update       autoUpdate, installed commit, last check, what differs
  GET  /api/settings/job?id=      a background job: state and the last lines of its output
  POST /api/settings/action       {"action": ..., ...}; needs the X-Quota-App header like every other POST

Rules: every action calls an existing rotator / system entry point as an argv list (no shell string, no page text in a command); a label is
^[A-Za-z0-9_-]{1,32}$ and only ever lands in a path or an argv element; a removed seat is MOVED to <store>\\.removed\\<label>-<UTC stamp>, never
deleted; token and credential values are never returned, logged or put in an error text. Every outside effect (starting a process, listing
processes, the Windows Credential Manager, the clock) is a constructor argument, so test-dashboard-settings.py drives it all with fakes.
"""
import base64
import ctypes
import glob
import json
import math
import os
import re
import shutil
import subprocess
import tempfile
import threading
import time
import urllib.request
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
LABEL_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]{0,31}")      # no leading - (it would read as an option to the rotators) or _ (the rotators ignore such a folder)
EMAIL_OK = re.compile(r"[^\s@<>\"',;()]{1,64}@[^\s@<>\"',;()]{1,190}\.[A-Za-z]{2,}")
EMAIL_ANY = re.compile(r"[^\s@()<>\"',;]+@[^\s@()<>\"',;]+\.[A-Za-z]{2,}")
TOKEN_OK = re.compile(r"[A-Za-z0-9._~+/=-]{20,1000}")
STAMP_RE = re.compile(r"(?P<label>[A-Za-z0-9][A-Za-z0-9_-]{0,31})-(?P<ts>\d{8}T\d{6}Z)")
ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")
CHILD_FLAGS = 0x08000000 | 0x40 if os.name == "nt" else 0       # no console window, Idle CPU priority (as usage-history.py's children)
NEW_CONSOLE = 0x10 if os.name == "nt" else 0                      # CREATE_NEW_CONSOLE: the visible window a login needs
PROXY_HEALTH = "http://127.0.0.1:18484/__proxy/health"
CLAUDE_APP_PATH = re.compile(r"\\AnthropicClaude\\|\\WindowsApps\\Claude_", re.I)        # the desktop app's two install flavours (README: MSIX vs Squirrel)
TASKS = {                                                          # id -> (Windows task name, what the page calls it)
    "autorotate": ("Claude usage auto-rotate", "Rotate Claude seats automatically (every 5 min)"),
    "historysync": ("Claude app-history sync", "Copy CLI sessions into the Claude app's history (every 30 min)"),
    "keepalive": ("Claude app-seat keepalive", "Keep the Claude app seats' logins fresh (every 6 h)"),
    "codexkeepalive": ("Codex seat keepalive", "Keep the Codex logins fresh (every 4 min)"),
    "proxy": ("Claude rotate proxy", "Local rotate proxy (retries a limit-hit request on the next seat)"),
}
KIMI_DIRS = ("credentials", "auth", "tokens")                      # shortcut: Kimi's token folder name could not be verified (not signed in here); first that exists wins


class Bad(Exception):
    """A refused request: its text is shown to the owner as is."""

    def __init__(self, text, code=400):
        Exception.__init__(self, text)
        self.text, self.code = text, code


def scrub(text, keep_emails=False):
    """Output safe to show: no colour codes, tokens or (unless keep_emails) addresses."""
    t = ANSI.sub("", text or "")
    t = re.sub(r"sk-ant-[A-Za-z0-9_\-]+", "[redacted]", t)
    t = re.sub(r"(?i)bearer\s+\S+", "Bearer [redacted]", t)
    t = re.sub(r"[A-Za-z0-9_\-.+/=]{40,}", "[redacted]", t)
    return t if keep_emails else EMAIL_ANY.sub("[email]", t)


def stamp(now):
    return time.strftime("%Y%m%dT%H%M%SZ", time.gmtime(now))


def jwt_email(tok):
    """The email claim of a JWT (never anything else), or ''."""
    try:
        p = tok.split(".")[1]
        c = json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4)))
        e = c.get("email")
        return e if isinstance(e, str) else ""
    except (AttributeError, IndexError, ValueError):
        return ""


def read_json(path):
    try:
        with open(path, encoding="utf-8-sig") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def read_text(path):
    try:
        with open(path, encoding="utf-8-sig") as fh:
            return fh.read().strip()
    except OSError:
        return ""


def write_atomic(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = "%s.tmp-%d" % (path, os.getpid())
    with open(tmp, "wb") as fh:
        fh.write(data if isinstance(data, bytes) else data.encode("utf-8"))
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp, path)


def real_popen(argv, **kw):
    return subprocess.Popen(argv, **kw)


class WinCred:
    """The Windows Credential Manager, generic credentials only: read(target) -> {"blob", "user", "persist"} or None; write(target, blob, user, persist); delete(target)."""

    def __init__(self):
        from ctypes import wintypes
        self.w = wintypes

        class CRED(ctypes.Structure):
            _fields_ = [("Flags", wintypes.DWORD), ("Type", wintypes.DWORD), ("TargetName", wintypes.LPWSTR), ("Comment", wintypes.LPWSTR),
                        ("LastWritten", wintypes.FILETIME), ("BlobSize", wintypes.DWORD), ("Blob", ctypes.POINTER(ctypes.c_ubyte)),
                        ("Persist", wintypes.DWORD), ("AttrCount", wintypes.DWORD), ("Attrs", ctypes.c_void_p),
                        ("Alias", wintypes.LPWSTR), ("UserName", wintypes.LPWSTR)]
        self.CRED = CRED
        a = ctypes.windll.advapi32
        a.CredReadW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, ctypes.POINTER(ctypes.POINTER(CRED))]
        a.CredWriteW.argtypes = [ctypes.POINTER(CRED), wintypes.DWORD]
        a.CredDeleteW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD]
        a.CredFree.argtypes = [ctypes.c_void_p]
        self.a = a

    def read(self, target):
        p = ctypes.POINTER(self.CRED)()
        if not self.a.CredReadW(target, 1, 0, ctypes.byref(p)):
            return None
        try:
            c = p.contents
            return {"blob": ctypes.string_at(c.Blob, c.BlobSize) if c.BlobSize else b"", "user": c.UserName or "", "persist": int(c.Persist)}
        finally:
            self.a.CredFree(p)

    def write(self, target, blob, user="", persist=2):
        buf = (ctypes.c_ubyte * max(len(blob), 1)).from_buffer_copy(blob or b"\0")
        c = self.CRED(Flags=0, Type=1, TargetName=target, BlobSize=len(blob), Blob=ctypes.cast(buf, ctypes.POINTER(ctypes.c_ubyte)),
                      Persist=persist or 2, UserName=user or None)
        if not self.a.CredWriteW(ctypes.byref(c), 0):
            raise OSError("CredWrite failed (%d)" % ctypes.GetLastError())

    def delete(self, target):
        self.a.CredDeleteW(target, 1, 0)


def real_procs():
    """[(image name lower-case, executable path)] of every process, from one fixed CIM query."""
    ps = ("Get-CimInstance Win32_Process | ForEach-Object { $_.Name + '|' + $_.ExecutablePath }")
    try:
        out = subprocess.run(["pwsh", "-NoProfile", "-NonInteractive", "-Command", ps], capture_output=True, timeout=45, creationflags=CHILD_FLAGS).stdout
    except (OSError, subprocess.SubprocessError):
        raise Bad("Could not list the running programs, so nothing was changed.", 500)
    rows = []
    for ln in out.decode("utf-8", "replace").splitlines():
        n, _, p = ln.partition("|")
        if n.strip():
            rows.append((n.strip().lower(), p.strip()))
    return rows


class Settings:
    def __init__(self, home=None, here=None, popen=real_popen, procs=real_procs, cred=None, now=time.time, store=None, which=shutil.which):
        self.home = home or os.path.expanduser("~")
        self.root = os.path.join(self.home, ".claude-cli-accounts")             # Claude CLI seats
        self.app_seats = os.path.join(self.home, ".claude-app-seats")           # Claude desktop-app seats
        self.codex = os.path.join(self.home, ".codex")
        self.homes = os.path.join(self.codex, "homes")                          # Codex seats
        self.cred_root = os.path.join(self.home, ".agent-dashboard-seats")      # the generic credential-seat store (Gemini, Grok, Kimi)
        self.here = here or HERE
        self.local_cfg = os.path.join(self.here, "rotator.local.json")
        self.popen, self.procs, self.now, self.store, self.which = popen, procs, now, store, which
        self._cred = cred
        self.busy = threading.Lock()
        self.jobs = {}
        self.jlock = threading.Lock()
        self.providers = self.cred_specs()

    # ------------------------------------------------------------ credential seat providers
    def cred_specs(self):
        h = self.home
        kimi_home = os.environ.get("KIMI_CODE_HOME") or os.path.join(h, ".kimi-code")
        kimi_dir = next((os.path.join(kimi_home, d) for d in KIMI_DIRS if os.path.isdir(os.path.join(kimi_home, d))), os.path.join(kimi_home, KIMI_DIRS[0]))
        return {
            "gemini": {"name": "Gemini", "app": "Antigravity", "procs": ["antigravity.exe"], "creds": ["gemini:antigravity"], "email": self.gemini_email,
                       "files": [os.path.join(h, ".gemini", "oauth_creds.json"), os.path.join(h, ".gemini", "google_accounts.json")], "dirs": [],
                       "how": "Sign in to Antigravity (or the Gemini CLI) with the account, close Antigravity, then save it here."},
            "grok": {"name": "xAI (Grok)", "app": "the Grok CLI", "procs": ["grok.exe"], "creds": [], "email": self.grok_email,
                     "files": [os.path.join(h, ".grok", "auth.json")], "dirs": [],
                     "how": "Sign in with `grok` using the account, close Grok, then save it here."},
            "kimi": {"name": "Kimi", "app": "Kimi", "procs": ["kimi.exe", "kimi-code.exe"], "creds": [], "email": lambda: "", "files": [], "dirs": [kimi_dir],
                     "installed": lambda: self.kimi_exe() is not None, "signin": True,
                     "how": "Sign in to Kimi with the account, close Kimi, then save it here. (Not tested on a real Kimi login yet.)"},
        }

    def kimi_exe(self):
        """Kimi Code's executable: `kimi` on PATH, else its own bin folder (the installer does not always touch PATH); None when it is not installed."""
        kimi_home = os.environ.get("KIMI_CODE_HOME") or os.path.join(self.home, ".kimi-code")
        return self.which("kimi") or next((f for f in (os.path.join(kimi_home, "bin", "kimi.exe"), os.path.join(kimi_home, "bin", "kimi")) if os.path.isfile(f)), None)

    @property
    def cred(self):
        if self._cred is None:
            self._cred = WinCred()
        return self._cred

    def cread(self, target):
        return self.cred.read(target) if (os.name == "nt" or self._cred) else None

    def gemini_email(self):
        r = self.cread("gemini:antigravity")
        if r:
            try:
                e = json.loads(r["blob"].decode("utf-8")).get("id_token_email")
                if isinstance(e, str) and e:
                    return e
            except (ValueError, AttributeError):
                pass
        o = read_json(os.path.join(self.home, ".gemini", "oauth_creds.json")) or {}
        return jwt_email(o.get("id_token") or "") or ((read_json(os.path.join(self.home, ".gemini", "google_accounts.json")) or {}).get("active") or "")

    def grok_email(self):
        d = read_json(os.path.join(self.home, ".grok", "auth.json"))
        for v in (d.values() if isinstance(d, dict) else ()):
            if isinstance(v, dict) and isinstance(v.get("email"), str):
                return v["email"]
        return ""

    # ------------------------------------------------------------ paths and small readers
    def blob(self):
        b = getattr(self.store, "blob", None)
        return b if isinstance(b, dict) else {}

    def bprov(self, pid):
        return next((p for p in self.blob().get("providers", []) if p.get("id") == pid), {})

    def bacct(self, pid, label):
        return next((a for a in self.bprov(pid).get("accounts", []) if a.get("label") == label), {})

    def claude_labels(self):
        cli = {os.path.basename(d) for d in glob.glob(os.path.join(self.root, "*")) if os.path.isfile(os.path.join(d, "token.txt"))}
        app = {os.path.basename(d) for d in glob.glob(os.path.join(self.app_seats, "*")) if os.path.isfile(os.path.join(d, "config.json"))}
        ok = lambda s: {l for l in s if LABEL_RE.fullmatch(l)}
        return sorted(ok(cli | app)), ok(cli), ok(app)

    def codex_labels(self):
        return sorted(os.path.basename(d) for d in glob.glob(os.path.join(self.homes, "*")) if os.path.isfile(os.path.join(d, "auth.json")) and LABEL_RE.fullmatch(os.path.basename(d)))

    def active_of(self, pid):
        """{role: label} of the seats in use: from the dashboard's own reading when it has one, else the rotators' pointer files."""
        a = dict(self.bprov(pid).get("inUse") or {})
        if pid == "claude":
            a.setdefault("cli", read_text(os.path.join(self.root, ".active")))
            a.setdefault("app", read_text(os.path.join(self.app_seats, ".active")))
        elif pid == "codex":
            a.setdefault("app", read_text(os.path.join(self.codex, ".active-account")))
        return {k: v for k, v in a.items() if v}

    def local_cfg_data(self):
        d = read_json(self.local_cfg)
        return d if isinstance(d, dict) else {}

    def weight_of(self, pid, label, acct):
        w = ((self.local_cfg_data().get("seatWeights") or {}).get(pid) or {}).get(label)
        if isinstance(w, (int, float)) and not isinstance(w, bool):
            return w
        return acct.get("w") if isinstance(acct.get("w"), (int, float)) else 1

    def removed(self, stores):
        out = {}
        for d in stores:
            for p in glob.glob(os.path.join(d, ".removed", "*")):
                m = STAMP_RE.fullmatch(os.path.basename(p))
                if m and os.path.isdir(p):
                    e = out.setdefault(m.group(0), {"id": m.group(0), "label": m.group("label"), "ts": m.group("ts")})
        return sorted(out.values(), key=lambda e: e["ts"], reverse=True)

    # ------------------------------------------------------------ headroom
    def headroom(self, windows, now=None):
        """1 - the most used window, None when there is no reading or any window is capped (a capped seat is never offered)."""
        now = now or self.now()
        used = []
        for w in windows or ():
            u = w.get("used")
            if not isinstance(u, (int, float)):
                continue
            if isinstance(w.get("reset"), (int, float)) and w["reset"] <= now:
                u = 0.0                                        # the window renewed since that reading
            if u >= 1.0:
                return None
            used.append(u)
        return None if not used else round(1.0 - max(used), 4)

    def capped(self, windows, now=None):
        """Some window is used up and has not renewed: headroom() says None for that as well as for no reading, and the page tells the two apart."""
        now = now or self.now()
        return any(isinstance(w.get("used"), (int, float)) and w["used"] >= 1.0 and not (isinstance(w.get("reset"), (int, float)) and w["reset"] <= now) for w in windows or ())

    def pick_best(self, pid, role=None):
        """(label, headroom) of the usable seat with the most headroom that is not already in use for `role`, from the dashboard's own numbers."""
        best = None
        for s in self.state_for(pid)["seats"]:
            if (s["active"].get(role) if role else any(s["active"].values())) or (role in (s.get("roles") or {}) and not s["roles"][role]):
                continue
            h = s.get("headroom")
            if h is not None and (best is None or h > best[1]):
                best = (s["label"], h)
        return best

    # ------------------------------------------------------------ the generic credential-seat store
    def cdir(self, pid, *parts):
        return os.path.join(self.cred_root, pid, *parts)

    def cred_seats(self, pid):
        out = {}
        for p in sorted(glob.glob(os.path.join(self.cdir(pid), "*"))):
            m = read_json(os.path.join(p, "meta.json"))
            if os.path.isdir(p) and isinstance(m, dict) and LABEL_RE.fullmatch(os.path.basename(p)):
                out[os.path.basename(p)] = m
        return out

    def cred_live(self, pid):
        """The provider's live login as {"files": {i: bytes}, "dirs": {i: path}, "creds": {target: {...}}}; a store that is not there is left out."""
        sp, live = self.providers[pid], {"files": {}, "dirs": {}, "creds": {}}
        for i, f in enumerate(sp["files"]):
            if os.path.isfile(f):
                with open(f, "rb") as fh:
                    live["files"][i] = fh.read()
        for i, d in enumerate(sp["dirs"]):
            if os.path.isdir(d) and bool(os.listdir(d)):
                live["dirs"][i] = d
        for t in sp["creds"]:
            r = self.cread(t)
            if r:
                live["creds"][t] = r
        return live

    def cred_dump(self, base, live):
        """Write `live` under `base` (files/ and cred/), the one on-disk shape of a seat and of a backup."""
        os.makedirs(os.path.join(base, "files"))
        os.makedirs(os.path.join(base, "cred"))
        for i, b in live["files"].items():
            with open(os.path.join(base, "files", "f%d" % i), "wb") as fh:
                fh.write(b)
        for i, d in live["dirs"].items():
            shutil.copytree(d, os.path.join(base, "files", "d%d" % i))
        for n, (t, r) in enumerate(sorted(live["creds"].items())):
            write_atomic(os.path.join(base, "cred", "c%d.json" % n), json.dumps({"target": t, "user": r["user"], "persist": r["persist"], "blob": base64.b64encode(r["blob"]).decode()}))

    def cred_write_seat(self, pid, label, live, email, extra=None, backup=True):
        """Write `live` as seat `label` (a temp folder first, then swapped in; with `backup` the folder it replaces goes to .swap-backups)."""
        base, tmp = self.cdir(pid, label), self.cdir(pid, ".tmp-%s-%d" % (label, os.getpid()))
        if os.path.isdir(tmp):
            shutil.rmtree(tmp)
        self.cred_dump(tmp, live)
        write_atomic(os.path.join(tmp, "meta.json"), json.dumps(dict(extra or {}, email=email, captured=int(self.now()))))
        if os.path.isdir(base):
            if backup:
                os.makedirs(self.cdir(pid, ".swap-backups"), exist_ok=True)
                shutil.move(base, self.cdir(pid, ".swap-backups", "%s-replaced-%s" % (label, stamp(self.now()))))
            else:
                shutil.rmtree(base)      # a seat's own older snapshot, superseded by the fresher live copy (itself backed up just before)
        os.replace(tmp, base)

    def cred_read_dir(self, pid, base):
        """A saved seat or a backup as the same shape cred_live gives (dirs are paths inside it)."""
        sp = self.providers[pid]
        live = {"files": {}, "dirs": {}, "creds": {}}
        for i in range(len(sp["files"])):
            p = os.path.join(base, "files", "f%d" % i)
            if os.path.isfile(p):
                with open(p, "rb") as fh:
                    live["files"][i] = fh.read()
        for i in range(len(sp["dirs"])):
            p = os.path.join(base, "files", "d%d" % i)
            if os.path.isdir(p):
                live["dirs"][i] = p
        for p in sorted(glob.glob(os.path.join(base, "cred", "c*.json"))):
            j = read_json(p) or {}
            if j.get("target") in sp["creds"]:
                live["creds"][j["target"]] = {"blob": base64.b64decode(j.get("blob", "")), "user": j.get("user", ""), "persist": j.get("persist", 2)}
        return live

    def cred_apply(self, pid, live, onto_dirs=True):
        """Put `live` in the provider's real places. Files and credentials are replaced in one step each; a folder is replaced by a copy."""
        sp = self.providers[pid]
        for i, b in live["files"].items():
            write_atomic(sp["files"][i], b)
        for i, src in live["dirs"].items():
            dst = sp["dirs"][i]
            if os.path.isdir(dst):
                shutil.rmtree(dst)               # the live folder was copied to .swap-backups just before
            shutil.copytree(src, dst)
        for t, r in live["creds"].items():
            self.cred.write(t, r["blob"], r["user"], r["persist"])

    def cred_same(self, pid, a, b):
        return (a["files"] == b["files"] and sorted(a["dirs"]) == sorted(b["dirs"])
                and {t: r["blob"] for t, r in a["creds"].items()} == {t: r["blob"] for t, r in b["creds"].items()})

    def check_closed(self, pid):
        sp = self.providers[pid]
        if any(n in sp["procs"] for n, _ in self.procs()):
            raise Bad("%s is running. Close it completely (also from the system tray), then try again: it keeps the login in memory and would write it back over the switch." % sp["app"], 409)

    def match_seat(self, pid, email):
        e = (email or "").lower()
        return next((l for l, m in self.cred_seats(pid).items() if e and (m.get("email") or "").lower() == e), None)

    def cred_capture(self, pid, label, replace=False):
        sp = self.providers[pid]
        live = self.cred_live(pid)
        if not (live["files"] or live["dirs"] or live["creds"]):
            raise Bad("No %s login was found on this PC. Sign in to %s first, then save it." % (sp["name"], sp["app"]))
        email = sp["email"]()
        seats, other = self.cred_seats(pid), self.match_seat(pid, email)
        if other and other != label:
            raise Bad("This login is already saved as seat %s. A second copy of the same login can end up signing the first one out." % other)
        old = seats.get(label)
        if old and not replace and email and (old.get("email") or "").lower() != email.lower():
            raise Bad("Seat %s holds a different account. Tick 'Replace an existing seat' to overwrite it (the old one is kept in a backup)." % label)
        extra = {k: v for k, v in (old or {}).items() if k == "display"}
        self.cred_write_seat(pid, label, live, email, extra)
        self.note_readings(pid)
        return {"outcome": "ok", "text": "Saved the current %s login as seat %s." % (sp["name"], label)}

    def cred_switch(self, pid, label):
        sp = self.providers[pid]
        seats = self.cred_seats(pid)
        if label not in seats:
            raise Bad("There is no saved %s seat %s." % (sp["name"], label))
        self.check_closed(pid)
        target = self.cred_read_dir(pid, self.cdir(pid, label))
        cur_email = sp["email"]()
        if cur_email and (seats[label].get("email") or "").lower() == cur_email.lower():
            return {"outcome": "ok", "text": "Seat %s is already the login in use." % label}
        cur = self.cred_live(pid)
        leaving = self.match_seat(pid, cur_email)
        self.note_readings(pid)
        bdir = self.cdir(pid, ".swap-backups", "before-%s-%s" % (label, stamp(self.now())))
        has_cur = bool(cur["files"] or cur["dirs"] or cur["creds"])
        if has_cur:
            self.cred_dump(bdir, cur)
        if has_cur and leaving and leaving != label:
            self.cred_write_seat(pid, leaving, cur, cur_email, {k: v for k, v in seats[leaving].items() if k == "display"}, backup=False)     # keeps the leaving seat's tokens fresh
        try:
            self.cred_apply(pid, target)
            if not self.cred_same(pid, self.cred_live(pid), target):
                raise OSError("read-back differs")
        except (OSError, Bad) as e:
            try:
                self.cred_apply(pid, self.cred_read_dir(pid, bdir))
            except OSError:
                pass
            raise Bad("The switch failed (%s) and the previous login was put back from %s." % (type(e).__name__, os.path.basename(bdir)), 500)
        note = "" if leaving else " The login you left was not saved as a seat, so it is only in the backup %s." % os.path.basename(bdir)
        return {"outcome": "ok", "text": "Switched %s to seat %s.%s" % (sp["name"], label, note)}

    def readings(self, pid):
        return read_json(os.path.join(self.cdir(pid), ".readings.json")) or {}

    def note_readings(self, pid):
        """Remember the dashboard's current reading for the seat in use (the dashboard reads only the live login): the 'most headroom' pick uses it for seats not in use."""
        try:
            lab = self.match_seat(pid, self.providers[pid]["email"]())
            wins = [{"used": w.get("used"), "reset": w.get("reset")} for a in self.bprov(pid).get("accounts", [])[:1] for w in a.get("windows", []) if isinstance(w.get("used"), (int, float))]
            if lab and wins:
                write_atomic(os.path.join(self.cdir(pid), ".readings.json"), json.dumps(dict(self.readings(pid), **{lab: {"t": int(self.now()), "windows": wins}})))
        except (OSError, ValueError, KeyError):
            pass

    def cred_state(self, pid):
        sp = self.providers[pid]
        seats = self.cred_seats(pid)
        live_email = sp["email"]() if self.cred_has_login(pid) else ""
        active = self.match_seat(pid, live_email)
        out = []
        for l, m in seats.items():
            wins = (self.bprov(pid).get("accounts") or [{}])[0].get("windows") if l == active else (self.readings(pid).get(l) or {}).get("windows")
            ba = (self.bprov(pid).get("accounts") or [{}])[0] if l == active else {}
            out.append({"label": l, "email": m.get("display") or m.get("email") or "", "plan": ba.get("plan") or "",
                        "weight": self.weight_of(pid, l, {}), "active": {"login": l == active}, "headroom": self.headroom(wins), "capped": self.capped(wins),
                        "health": {"ok": ba.get("ok", True) if l == active else None, "note": ba.get("note", "") if l == active else ""}})
        return {"id": pid, "name": sp["name"], "kind": "cred", "app": sp["app"], "how": sp["how"], "seats": out,
                "current": {"email": live_email, "saved": bool(active), "present": self.cred_has_login(pid)}, "signin": bool(sp.get("signin")),
                "removed": self.removed([self.cdir(pid)]), "can": ["capture", "switch", "best", "email", "weight", "remove"]}

    def cred_has_login(self, pid):
        sp = self.providers[pid]
        return any(os.path.isfile(f) for f in sp["files"]) or any(os.path.isdir(d) and bool(os.listdir(d)) for d in sp["dirs"]) or \
            any(self.cread(t) for t in sp["creds"])

    # ------------------------------------------------------------ seat listing
    def state_for(self, pid):
        if pid == "claude":
            return self.claude_state()
        if pid == "codex":
            return self.codex_state()
        return self.cred_state(pid)

    def claude_state(self):
        labels, cli, app = self.claude_labels()
        act, seats = self.active_of("claude"), []
        for l in labels:
            a = self.bacct("claude", l)
            em = read_text(os.path.join(self.root, l, "email.txt")) or read_text(os.path.join(self.app_seats, l, "email.txt")) or a.get("email") or ""
            seats.append({"label": l, "email": em, "plan": "", "weight": self.weight_of("claude", l, a),
                          "roles": {"cli": l in cli, "app": l in app}, "active": {"cli": act.get("cli") == l, "app": act.get("app") == l},
                          "headroom": self.headroom(a.get("windows")), "capped": self.capped(a.get("windows")), "health": {"ok": a.get("ok", True), "note": a.get("note", "")}})
        can = ["cli.add", "app.capture", "email", "weight", "remove", "best"]
        for n, f in (("cli.switch", "claude-cli-account.ps1"), ("app.switch", "claude-app-rotator.ps1")):
            if os.path.isfile(os.path.join(self.here, f)):
                can.append(n)
        return {"id": "claude", "name": "Claude", "kind": "claude", "seats": seats, "removed": self.removed([self.root, self.app_seats]), "can": can,
                "how": "CLI seats use a long-lived token; app seats are the desktop app's own login. Both are listed under one label."}

    def codex_state(self):
        act, seats = self.active_of("codex"), []
        for l in self.codex_labels():
            a = self.bacct("codex", l)
            seats.append({"label": l, "email": a.get("email") or jwt_email(((read_json(os.path.join(self.homes, l, "auth.json")) or {}).get("tokens") or {}).get("id_token") or ""),
                          "plan": a.get("plan") or "", "weight": self.weight_of("codex", l, a), "active": {"app": act.get("app") == l},
                          "headroom": self.headroom(a.get("windows")), "capped": self.capped(a.get("windows")), "health": {"ok": a.get("ok", True), "note": a.get("note", "")}})
        can = ["add", "weight", "remove", "best"] + (["switch"] if os.path.isfile(os.path.join(self.here, "codex-app-rotator.ps1")) else [])
        return {"id": "codex", "name": "Codex", "kind": "codex", "seats": seats, "removed": self.removed([self.homes]), "can": can,
                "how": "The Codex CLI and app share one login, so a switch closes and reopens the Codex app."}

    def state(self):
        provs = []
        for pid in ("claude", "codex"):
            provs.append(self.state_for(pid))
        for pid, sp in self.providers.items():
            if self.cred_has_login(pid) or self.cred_seats(pid) or ("installed" in sp and sp["installed"]()):     # an installed program that is signed out still gets its tab (to sign in from)
                provs.append(self.cred_state(pid))
        provs.append({"id": "muse", "name": "Muse (Meta)", "kind": "unsupported", "seats": [], "removed": [], "can": [],
                      "how": "Seats can't be switched for Muse: this PC doesn't keep its login anywhere the dashboard can find (no login file, no Windows Credential Manager entry). To sign in or change account, press the button below.",
                      "signin": self.which("muse") is not None})
        return {"providers": provs}

    # ------------------------------------------------------------ automation
    def quick(self, argv, timeout=30):
        """One short system command (schtasks, ...) -> (exit code, scrubbed text). A fixed argv; killed if it hangs."""
        try:
            p = self.popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, creationflags=CHILD_FLAGS)
            out, _ = p.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            p.kill()
            return 124, "timed out"
        except (OSError, subprocess.SubprocessError) as e:
            return 127, "could not run: %s" % type(e).__name__
        return p.returncode, scrub((out or b"").decode("utf-8", "replace"))

    def task_state(self, name):
        rc, out = self.quick(["schtasks", "/Query", "/TN", name, "/FO", "CSV", "/NH"], 20)
        if rc != 0:
            return "missing"
        m = re.findall(r'"([^"]*)"', out.splitlines()[0] if out.strip() else "")
        return (m[-1] if m else "unknown").lower()

    def proxy_health(self):
        try:
            with urllib.request.urlopen(PROXY_HEALTH, timeout=2) as r:
                j = json.loads(r.read(4096))
            return {"up": True, "ok": bool(j.get("ok"))}
        except (OSError, ValueError, AttributeError):
            return {"up": False, "ok": False}

    def tail(self, path, n=6):
        try:
            with open(path, "rb") as fh:
                fh.seek(0, 2)
                fh.seek(max(0, fh.tell() - 4000))
                lines = fh.read().decode("utf-8", "replace").splitlines()
        except OSError:
            return []
        return [scrub(x)[:240] for x in lines[-n:] if x.strip()]

    def automation(self):
        tasks = [{"id": k, "name": v[1], "state": self.task_state(v[0])} for k, v in TASKS.items()]
        return {"tasks": tasks, "autoResume": not os.path.exists(os.path.join(self.root, ".auto-resume-off")), "proxy": self.proxy_health(), "update": self.update_info(),
                "keepaliveLog": self.tail(os.path.join(self.app_seats, ".keepalive-log.txt")),
                "codexKeepaliveLog": self.tail(os.path.join(self.codex, "rotator-state", "keepalive.log"))}

    def update_info(self):
        """The dashboard's update state for the Updates section (the store knows the drift file and the installer); None when the store has none (a bare Settings)."""
        f = getattr(self.store, "update_info", None)
        try:
            info = f() if callable(f) else None
        except Exception:    # shortcut: the section then says "not available" instead of the whole Automation view failing
            return None
        return info if isinstance(info, dict) else None

    # ------------------------------------------------------------ jobs and locks
    def enter(self):
        """The action lock (and the store's own, when it has one) -> release function. 409 when something else is running."""
        if not self.busy.acquire(blocking=False):
            raise Bad("Another settings action is still running. Wait for it to finish.", 409)
        lk = getattr(self.store, "refreshing", None)
        if lk is not None and hasattr(lk, "acquire") and not lk.acquire(blocking=False):
            self.busy.release()
            raise Bad("A refresh or switch is running. Try again in a minute.", 409)
        running = getattr(self.store, "refresh_running", None)
        if lk is not None and callable(running) and running():     # a provider refresh holds only its own lock, not `refreshing`
            lk.release()
            self.busy.release()
            raise Bad("A refresh or switch is running. Try again in a minute.", 409)

        def release():
            if lk is not None and hasattr(lk, "release"):
                lk.release()
            self.busy.release()
        return release

    def rebuild(self):
        try:
            with self.store.lock:
                self.store.rebuild(self.now())
        except Exception:    # shortcut: the page re-reads on its own 5-minute tick; a store without rebuild() is fine
            pass

    def job(self, title, argv, release, env=None, cleanup=None):
        """Run argv in the background (never killed: a rotator killed mid-switch can leave a login moved aside), with the lock held until it ends."""
        j = {"id": uuid.uuid4().hex[:12], "title": title, "state": "running", "started": int(self.now()), "text": "Running...", "tail": []}
        with self.jlock:
            self.jobs[j["id"]] = j
            for k in list(self.jobs)[:-20]:
                self.jobs.pop(k, None)

        def run():
            rc, out = None, ""
            try:
                p = self.popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, creationflags=CHILD_FLAGS, env=env)
                o, _ = p.communicate()
                rc, out = p.returncode, (o or b"").decode("utf-8", "replace")
            except (OSError, subprocess.SubprocessError) as e:
                out = "could not run: %s" % type(e).__name__
            finally:
                try:
                    if cleanup:
                        cleanup()
                finally:
                    lines = [x.rstrip()[:300] for x in scrub(out).splitlines() if x.strip()]
                    last = next((x for x in reversed(lines) if not x[:1].isspace()), lines[-1] if lines else "").strip()
                    j["tail"] = lines[-40:]
                    j["text"] = ("Done" if rc == 0 else "Failed (exit %s)" % rc) + (": " + last[:200] if last else ".")
                    j["state"] = "ok" if rc == 0 else "error"
                    j["ended"] = int(self.now())
                    self.rebuild()
                    release()
        threading.Thread(target=run, daemon=True).start()
        return {"outcome": "running", "text": "%s started." % title, "job": j["id"]}

    def get_job(self, jid):
        with self.jlock:
            j = self.jobs.get(jid)
        if not j:
            raise Bad("Unknown job.", 404)
        return dict(j)

    def ps(self, name, *a):
        return ["pwsh", "-NoProfile", "-File", os.path.join(self.here, name)] + list(a)

    def need(self, name):
        if not os.path.isfile(os.path.join(self.here, name)):
            raise Bad("%s is not next to the dashboard, so this can't run." % name, 404)

    # ------------------------------------------------------------ actions
    def label(self, b, key="label"):
        v = b.get(key)
        if not isinstance(v, str) or not LABEL_RE.fullmatch(v):
            raise Bad("A seat name is 1 to 32 letters, digits, - or _.")
        return v

    def act(self, b):
        a = b.get("action")
        fn = getattr(self, "do_" + re.sub(r"[^a-z]", "_", a), None) if isinstance(a, str) and re.fullmatch(r"[a-z.]{3,40}", a) else None
        if fn is None:
            raise Bad("Unknown action.", 404)
        return fn(b)

    def sync(self, fn):
        """A quick action: lock, run, unlock."""
        release = self.enter()
        try:
            return fn()
        finally:
            release()

    def job_of(self, title, argv, env=None, cleanup=None):
        release = self.enter()
        try:
            return self.job(title, argv, release, env, cleanup)
        except BaseException:
            release()
            raise

    def console(self, argv, env=None):
        try:
            self.popen(argv, env=env, creationflags=NEW_CONSOLE)
        except (OSError, subprocess.SubprocessError) as e:
            raise Bad("Could not open the window: %s." % type(e).__name__, 500)

    # --- Claude
    def do_claude_cli_add(self, b):
        l = self.label(b)
        env = {k: v for k, v in os.environ.items() if k != "CLAUDE_CODE_OAUTH_TOKEN"}
        self.console(["cmd.exe", "/k", "claude setup-token"], env)
        return {"outcome": "ok", "text": "A window opened. Sign in to the account there, copy the token it prints, and paste it below. Seat name: %s." % l}

    def do_claude_cli_import(self, b):
        l, tok = self.label(b), b.get("token")
        if not isinstance(tok, str) or not TOKEN_OK.fullmatch(tok.strip()):
            raise Bad("That doesn't look like a token from `claude setup-token`. Paste only the token.")
        self.need("claude-cli-account.ps1")
        d = tempfile.mkdtemp(prefix="seat-import-")
        f = os.path.join(d, "token.txt")
        try:
            with open(f, "w", encoding="utf-8", newline="") as fh:
                fh.write(tok.strip())
            argv = self.ps("claude-cli-account.ps1", "--import", l, f) + (["--replace"] if b.get("replace") is True else [])
            return self.job_of("Save Claude token for seat %s" % l, argv, cleanup=lambda: shutil.rmtree(d, ignore_errors=True))
        except BaseException:
            shutil.rmtree(d, ignore_errors=True)
            raise

    def do_claude_cli_switch(self, b):
        l = self.label(b)
        if l not in self.claude_labels()[1]:
            raise Bad("Seat %s has no CLI token." % l)
        self.need("claude-cli-account.ps1")
        return self.job_of("Switch Claude CLI to %s" % l, self.ps("claude-cli-account.ps1", "--switch", l, "--no-usage"))

    def do_claude_cli_best(self, b):
        self.need("claude-cli-account.ps1")
        return self.job_of("Switch Claude CLI to the seat with most headroom", self.ps("claude-cli-account.ps1", "--switch", "best", "--no-usage"))

    def claude_app_running(self):
        return any(n == "claude.exe" and CLAUDE_APP_PATH.search(p) for n, p in self.procs())

    def do_claude_app_capture(self, b):
        l = self.label(b)
        self.need("claude-app-rotator.ps1")
        if self.claude_app_running():
            raise Bad("The Claude app is running. Sign in to the account in the app, then quit the app completely (also from the system tray) and try again.", 409)
        return self.job_of("Save the Claude app login as seat %s" % l, self.ps("claude-app-rotator.ps1", "--capture", l))

    def do_claude_app_switch(self, b):
        l = self.label(b)
        if l not in self.claude_labels()[2]:
            raise Bad("Seat %s has no saved app login." % l)
        self.need("claude-app-rotator.ps1")
        return self.job_of("Switch the Claude app to %s" % l, self.ps("claude-app-rotator.ps1", "--switch", l, "--relaunch"))

    def do_claude_app_best(self, b):
        best = self.pick_best("claude", "app")
        if not best:
            raise Bad("No other app seat has a usable reading right now.")
        return self.do_claude_app_switch({"label": best[0]})

    # --- Codex
    def do_codex_add(self, b):
        l = self.label(b)
        d = os.path.join(self.homes, l)
        if os.path.exists(d):
            raise Bad("Codex seat %s already exists. Pick a new name (logging in over an existing seat overwrites its login)." % l)
        os.makedirs(d)
        self.console(["cmd.exe", "/k", "codex login"], dict(os.environ, CODEX_HOME=d))
        return {"outcome": "ok", "text": "A window opened. Sign in to the new account there, then press 'Check login' here. Use an account that is not already a seat."}

    def do_codex_check(self, b):
        l = self.label(b)
        auth = os.path.join(self.homes, l, "auth.json")
        if not os.path.isfile(auth):
            raise Bad("No login was saved for %s yet. Finish the sign-in in the window first." % l, 409)
        em = jwt_email(((read_json(auth) or {}).get("tokens") or {}).get("id_token") or "")
        other = next((o for o in self.codex_labels() if o != l and em and jwt_email(((read_json(os.path.join(self.homes, o, "auth.json")) or {}).get("tokens") or {}).get("id_token") or "").lower() == em.lower()), None)
        if other:
            self.move_out([(self.homes, l)])
            raise Bad("That account is already seat %s. The new copy was moved to Removed seats (a second login can sign the first out); use seat %s." % (other, other))
        return {"outcome": "ok", "text": "Codex seat %s is ready." % l}

    def do_codex_switch(self, b):
        l = self.label(b)
        if l not in self.codex_labels():
            raise Bad("Codex seat %s has no saved login." % l)
        self.need("codex-app-rotator.ps1")
        return self.job_of("Switch Codex to %s" % l, self.ps("codex-app-rotator.ps1", "--switch", l))

    def do_codex_best(self, b):
        best = self.pick_best("codex", "app")
        if not best:
            raise Bad("No other Codex seat has a usable reading right now.")
        return self.do_codex_switch({"label": best[0]})

    # --- the generic credential seats
    def cpid(self, b):
        pid = b.get("provider")
        if pid not in self.providers:
            raise Bad("Unknown provider.", 404)
        return pid

    def do_cred_capture(self, b):
        pid, l = self.cpid(b), self.label(b)
        return self.sync(lambda: self.cred_capture(pid, l, b.get("replace") is True))

    def do_cred_signin(self, b):
        pid = self.cpid(b)
        if not self.providers[pid].get("signin"):
            raise Bad("There is no sign-in window to open for %s." % self.providers[pid]["name"], 404)
        exe = self.kimi_exe() if pid == "kimi" else None
        if not exe:
            raise Bad("%s is not installed on this PC." % self.providers[pid]["name"], 404)
        self.console(["cmd.exe", "/k", exe])
        return {"outcome": "ok", "text": "A window opened running %s. Sign in there, then come back and press Check again." % self.providers[pid]["app"]}

    def do_muse_login(self, b):
        exe = self.which("muse")
        if not exe:
            raise Bad("Muse is not installed on this PC.", 404)
        self.console(["cmd.exe", "/k", exe, "login"])
        return {"outcome": "ok", "text": "A window opened running muse login. Sign in there, then press Refresh on the Muse tab."}

    def do_cred_switch(self, b):
        pid, l = self.cpid(b), self.label(b)
        return self.sync(lambda: self.cred_switch(pid, l))

    def do_cred_best(self, b):
        pid = self.cpid(b)
        best = self.pick_best(pid)
        if not best:
            raise Bad("No other %s seat has a usable reading right now. (A seat only has a number once it has been in use while this page was open.)" % self.providers[pid]["name"])
        return self.sync(lambda: self.cred_switch(pid, best[0]))

    # --- shared by providers
    def do_best(self, b):
        pid = b.get("provider")
        return {"claude": self.do_claude_cli_best, "codex": self.do_codex_best}.get(pid, self.do_cred_best)(b)

    def do_set_email(self, b):
        pid, l, em = b.get("provider"), self.label(b), b.get("email")
        if not isinstance(em, str) or not (em == "" or (len(em) <= 254 and EMAIL_OK.fullmatch(em))):
            raise Bad("That is not an email address.")
        ok = {"outcome": "ok", "text": "Saved the address for seat %s." % l}

        def claude():
            lab, cli, _ = self.claude_labels()
            if l not in lab:
                raise Bad("There is no Claude seat %s." % l)
            f = os.path.join(self.root if l in cli else self.app_seats, l, "email.txt")
            if em:
                write_atomic(f, em + "\n")
            elif os.path.exists(f):
                os.remove(f)
            return ok

        def cred():
            m = self.cred_seats(pid).get(l)
            if m is None:
                raise Bad("There is no %s seat %s." % (self.providers[pid]["name"], l))
            m = dict(m, display=em) if em else {k: v for k, v in m.items() if k != "display"}
            write_atomic(os.path.join(self.cdir(pid, l), "meta.json"), json.dumps(m))
            return ok
        if pid == "claude":
            return self.sync(claude)
        if pid in self.providers:
            return self.sync(cred)
        raise Bad("Codex shows the address its own login gives.")

    def do_set_weight(self, b):
        pid, l, w = b.get("provider"), self.label(b), b.get("weight")
        if pid not in ("claude", "codex") and pid not in self.providers:
            raise Bad("Unknown provider.", 404)
        if w is not None and (isinstance(w, bool) or not isinstance(w, (int, float)) or not math.isfinite(w) or not 0 <= w <= 100):
            raise Bad("A weight is a number from 0 to 100 (how many regular seats this one counts as).")

        def go():
            cfg = self.local_cfg_data()
            if not isinstance(cfg.get("seatWeights"), dict):
                cfg["seatWeights"] = {}
            p = cfg["seatWeights"].setdefault(pid, {})
            if w is None:
                p.pop(l, None)
            else:
                p[l] = w
            write_atomic(self.local_cfg, json.dumps(cfg, indent=2) + "\n")
            return {"outcome": "ok", "text": "Seat %s now counts as %s regular seat(s). The dashboard picks it up on its next update." % (l, "1" if w is None else "%g" % w)}
        return self.sync(go)

    def move_out(self, pairs):
        """[(store folder, label)] -> moved to <store>\\.removed\\<label>-<stamp>; undone if one move fails. Never deletes."""
        done, ts = [], stamp(self.now())
        try:
            for store, l in pairs:
                src = os.path.join(store, l)
                if os.path.isdir(src):
                    dst = os.path.join(store, ".removed", "%s-%s" % (l, ts))
                    os.makedirs(os.path.dirname(dst), exist_ok=True)
                    shutil.move(src, dst)
                    done.append((src, dst))
        except OSError as e:
            for src, dst in reversed(done):
                shutil.move(dst, src)
            raise Bad("Could not move it (%s); is something still using that seat? Nothing was changed." % type(e).__name__, 500)
        return "%s-%s" % (pairs[0][1], ts)

    def do_remove(self, b):
        pid, l = b.get("provider"), self.label(b)
        if pid == "claude":
            lab, cli, app = self.claude_labels()
            act = self.active_of("claude")
            if l not in lab:
                raise Bad("There is no Claude seat %s." % l)
            if l in act.values():
                raise Bad("Seat %s is the one in use. Switch to another seat first." % l)
            pairs = [(self.app_seats, l), (self.root, l)]       # the app seat first: it is the one most likely to be locked
        elif pid == "codex":
            if l not in self.codex_labels():
                raise Bad("There is no Codex seat %s." % l)
            if l in self.active_of("codex").values():
                raise Bad("Seat %s is the one in use. Switch to another seat first." % l)
            pairs = [(self.homes, l)]
        elif pid in self.providers:
            if l not in self.cred_seats(pid):
                raise Bad("There is no %s seat %s." % (self.providers[pid]["name"], l))
            pairs = [(self.cdir(pid), l)]
        else:
            raise Bad("Unknown provider.", 404)
        return self.sync(lambda: {"outcome": "ok", "text": "Moved seat %s to Removed seats (nothing was deleted). You can restore it there." % l, "id": self.move_out(pairs)})

    def stores_of(self, pid):
        return {"claude": [self.root, self.app_seats], "codex": [self.homes]}.get(pid) or ([self.cdir(pid)] if pid in self.providers else None)

    def do_restore(self, b):
        pid, rid = b.get("provider"), b.get("id")
        stores = self.stores_of(pid)
        m = STAMP_RE.fullmatch(rid) if isinstance(rid, str) else None
        if stores is None or not m:
            raise Bad("Unknown removed seat.", 404)
        l = m.group("label")
        have = [s for s in stores if os.path.isdir(os.path.join(s, ".removed", rid))]
        if not have:
            raise Bad("That removed seat is gone.", 404)
        if any(os.path.exists(os.path.join(s, l)) for s in have):
            raise Bad("There is already a seat %s. Remove or rename it first, then restore." % l, 409)

        def go():
            done = []
            try:
                for s in have:
                    shutil.move(os.path.join(s, ".removed", rid), os.path.join(s, l))
                    done.append(s)
            except OSError as e:
                for s in reversed(done):
                    shutil.move(os.path.join(s, l), os.path.join(s, ".removed", rid))
                raise Bad("Could not restore it (%s). Nothing was changed." % type(e).__name__, 500)
            return {"outcome": "ok", "text": "Restored seat %s." % l}
        return self.sync(go)

    # --- automation
    def do_sync_history(self, b):
        grok = os.path.join(self.home, ".grok", "bin", "sync-app-history.ps1")        # the copy the scheduled task runs; the repo file is its source
        script = grok if os.path.isfile(grok) else os.path.join(self.here, "sync-app-history.ps1")
        if not os.path.isfile(script):
            raise Bad("sync-app-history.ps1 was not found.", 404)
        return self.job_of("Sync Claude app history", ["pwsh", "-NoProfile", "-File", script])

    def do_keepalive_status(self, b):
        self.need("claude-app-seat-keepalive.ps1")
        return self.job_of("Claude app-seat keepalive status", self.ps("claude-app-seat-keepalive.ps1", "-Status"))

    def do_task_set(self, b):
        t, en = TASKS.get(b.get("task")), b.get("enabled")
        if t is None or not isinstance(en, bool):
            raise Bad("Unknown task.", 404)
        rc, out = self.sync(lambda: self.quick(["schtasks", "/Change", "/TN", t[0], "/ENABLE" if en else "/DISABLE"]))
        return {"outcome": "ok" if rc == 0 else "error", "text": ("%s is now %s." % (t[1], "on" if en else "off")) if rc == 0 else "Windows refused (exit %s): %s" % (rc, out.strip()[:160])}

    def do_update_auto(self, b):
        en = b.get("enabled")
        if not isinstance(en, bool):
            raise Bad("Say on or off.")

        def go():
            cfg = self.local_cfg_data()
            cfg["autoUpdate"] = en                                     # every other key stays as it is
            write_atomic(self.local_cfg, json.dumps(cfg, indent=2) + "\n")
            return {"outcome": "ok", "text": "Automatic updates are %s." % ("on" if en else "off. The dashboard will offer Update now instead")}
        return self.sync(go)

    def do_update_check(self, b):
        check = getattr(self.store, "drift_check", None)
        if not callable(check):
            raise Bad("The update check is not available here.", 404)
        before = (self.update_info() or {}).get("checked")

        def go():
            check(self.now(), force=True)
            self.rebuild()
            i = self.update_info() or {}
            if not i.get("checked") or i.get("checked") == before:
                return {"outcome": "error", "text": "The check did not finish (GitHub could not be reached, or the check is missing). Try again in a minute."}
            n = len(i.get("differing") or [])
            return {"outcome": "ok", "text": ("%d file%s differ from GitHub. Press Update now to install %s." % (n, "" if n == 1 else "s", "it" if n == 1 else "them")) if n else "Up to date with GitHub."}
        return self.sync(go)

    def do_proxy_restart(self, b):
        def go():
            self.quick(["schtasks", "/End", "/TN", TASKS["proxy"][0]])
            return self.quick(["schtasks", "/Run", "/TN", TASKS["proxy"][0]])
        rc, out = self.sync(go)
        return {"outcome": "ok" if rc == 0 else "error", "text": "Restarted the rotate proxy." if rc == 0 else "Could not start it (exit %s): %s" % (rc, out.strip()[:160])}

    def do_auto_resume(self, b):
        en = b.get("enabled")
        if not isinstance(en, bool):
            raise Bad("Say on or off.")
        f = os.path.join(self.root, ".auto-resume-off")

        def go():
            if en and os.path.exists(f):
                os.remove(f)
            elif not en:
                write_atomic(f, "off by the dashboard's Settings page\n")
            return {"outcome": "ok", "text": "Auto-resume is %s." % ("on" if en else "off")}
        return self.sync(go)

    # ------------------------------------------------------------ dispatch (what the HTTP layer calls)
    def handle(self, method, path, query, body):
        """-> (HTTP code, JSON-able). Raises nothing: a refusal is {"outcome": "error", "text": ...}."""
        try:
            if method == "GET" and path == "/api/settings/seats":
                for pid in self.providers:
                    if self.cred_seats(pid):
                        self.note_readings(pid)
                return 200, self.state()
            if method == "GET" and path == "/api/settings/automation":
                return 200, self.automation()
            if method == "GET" and path == "/api/settings/update":
                return 200, {"update": self.update_info()}
            if method == "GET" and path == "/api/settings/job":
                return 200, self.get_job(query.get("id", ""))
            if method == "POST" and path == "/api/settings/action":
                if not isinstance(body, dict):
                    raise Bad("Bad request.")
                res = self.act(body)
                return (202 if res.get("outcome") == "running" else 200), res
            return 404, {"outcome": "error", "text": "Not found."}
        except Bad as e:
            return e.code, {"outcome": "error", "text": e.text}
        except Exception as e:   # shortcut: one broad catch so a bug is a message on the page, not a dropped connection
            return 500, {"outcome": "error", "text": "That did not work: %s." % type(e).__name__}


_default = {}


def owns(path):
    return path == "/settings.js" or path.startswith("/api/settings/")


def serve(h, method, store=None):
    """Answer one request on the dashboard's handler `h` (its Host check already passed). Needs h.send(code, body, ctype) and h.js(code, obj)."""
    path, _, qs = h.path.partition("?")
    if method == "GET" and path == "/settings.js":
        try:
            with open(os.path.join(HERE, "settings.js"), "rb") as fh:
                return h.send(200, fh.read(), "text/javascript; charset=utf-8")
        except OSError:
            return h.send(404, "not found")
    body = None
    if method == "POST":
        try:
            n = int(h.headers.get("Content-Length") or 0)
            raw = h.rfile.read(n) if 0 < n <= 8192 else b""
        except (ValueError, OSError):
            raw = b""
        if h.headers.get("X-Quota-App") != "1":
            return h.send(403, "forbidden")
        try:
            body = json.loads(raw) if raw else None
        except ValueError:
            body = None
    s = _default.get("s")
    if s is None or (store is not None and s.store is not store):
        s = _default["s"] = Settings(store=store)
    q = dict(kv.split("=", 1) for kv in qs.split("&") if "=" in kv)
    code, obj = s.handle(method, path, q, body)
    return h.js(code, obj)
