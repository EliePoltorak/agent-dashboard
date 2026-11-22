#!/usr/bin/env python3
"""Tests for dashboard_settings.py: py -3 test-dashboard-settings.py

Everything runs on temp folders with a fake command runner, a fake process list and a fake Credential Manager. Nothing here touches the real
seat stores, the real credentials, the live install or the real scheduled tasks. (TestRealCredApi, off unless RUN_REAL_CRED=1, writes and deletes
ONE throwaway Credential Manager entry of its own, to check the ctypes layer.)
"""
import base64
import http.client
import importlib.util
import json
import os
import shutil
import socket
import sys
import tempfile
import threading
import time
import types
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import dashboard_settings as ds   # noqa: E402

SECRET = "sk-ant-oat01-SECRETSECRETSECRETSECRETSECRET"


def jwt(email):
    enc = lambda o: base64.urlsafe_b64encode(json.dumps(o).encode()).decode().rstrip("=")
    return "%s.%s.sig" % (enc({"alg": "none"}), enc({"email": email}))


def put(path, data=b""):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as fh:
        fh.write(data if isinstance(data, bytes) else data.encode())


class FakeProc:
    def __init__(self, rc, out, gate=None):
        self.returncode, self.out, self.gate = rc, out, gate

    def communicate(self, timeout=None):
        if self.gate:
            self.gate.wait(5)
        return self.out, None

    def kill(self):
        pass


class FakePopen:
    """Records every launch; `reply(argv)` -> (rc, bytes); `seen(argv)` runs at launch time (to look at temp files that exist only then)."""

    def __init__(self):
        self.calls, self.reply, self.seen, self.gate = [], lambda argv: (0, b"Done."), None, None

    def __call__(self, argv, **kw):
        self.calls.append((list(argv), kw))
        if self.seen:
            self.seen(list(argv))
        rc, out = self.reply(list(argv))
        return FakeProc(rc, out, self.gate)

    def argvs(self):
        return [c[0] for c in self.calls]


class FakeCred:
    def __init__(self):
        self.d, self.fail_writes_after = {}, None
        self.writes = 0

    def read(self, t):
        v = self.d.get(t)
        return dict(v) if v else None

    def write(self, t, blob, user="", persist=2):
        self.writes += 1
        if self.fail_writes_after is not None and self.writes > self.fail_writes_after:
            raise OSError("fake cred write failure")
        self.d[t] = {"blob": blob, "user": user, "persist": persist}


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="dash-settings-test-")
        self.home = os.path.join(self.tmp, "home")
        self.here = os.path.join(self.tmp, "rot")
        for f in ("claude-cli-account.ps1", "claude-app-rotator.ps1", "codex-app-rotator.ps1", "claude-app-seat-keepalive.ps1", "sync-app-history.ps1"):
            put(os.path.join(self.here, f))
        self.root = os.path.join(self.home, ".claude-cli-accounts")
        self.apps = os.path.join(self.home, ".claude-app-seats")
        self.homes = os.path.join(self.home, ".codex", "homes")
        self.pop, self.cred = FakePopen(), FakeCred()
        self.running = []
        self.clock = [1_800_000_000]
        self.store = types.SimpleNamespace(blob={"providers": []})
        self.s = ds.Settings(home=self.home, here=self.here, popen=self.pop, procs=lambda: list(self.running), cred=self.cred,
                             now=lambda: self.clock[0], store=self.store, which=lambda n: None)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def claude_seat(self, label, email=None, cli=True, app=False):
        if cli:
            put(os.path.join(self.root, label, "token.txt"), SECRET + label)
        if email:
            put(os.path.join(self.root, label, "email.txt"), email + "\n")
        if app:
            put(os.path.join(self.apps, label, "config.json"), "{}")
            put(os.path.join(self.apps, label, "owner-uuid.txt"), "u-" + label)

    def codex_seat(self, label, email):
        put(os.path.join(self.homes, label, "auth.json"), json.dumps({"tokens": {"id_token": jwt(email), "refresh_token": SECRET}}))

    def do(self, **b):
        return self.s.handle("POST", "/api/settings/action", {}, b)

    def wait(self, res):
        code, r = res
        self.assertEqual(code, 202, r)
        end = time.time() + 5
        while time.time() < end:
            j = self.s.get_job(r["job"])
            if j["state"] != "running":
                time.sleep(0.05)       # the lock is released right after the state flips
                return j
            time.sleep(0.01)
        self.fail("job did not finish")

    def provider(self, pid):
        return next(p for p in self.s.state()["providers"] if p["id"] == pid)


class TestListing(Base):
    def test_claude_and_codex_seats(self):
        self.claude_seat("A", "a@x.example", app=True)
        self.claude_seat("B", None, cli=False, app=True)
        put(os.path.join(self.root, ".active"), "A")
        put(os.path.join(self.root, "usage-app", "x.txt"), "x")                         # not a seat: no token
        put(os.path.join(self.root, ".removed", "C-20260101T000000Z", "token.txt"), "t")
        put(os.path.join(self.here, "rotator.local.json"), json.dumps({"seatWeights": {"claude": {"A": 3}}, "keep": 1}))
        self.codex_seat("A", "cx@x.example")
        put(os.path.join(self.home, ".codex", ".active-account"), "A")
        self.store.blob = {"providers": [{"id": "codex", "accounts": [{"label": "A", "email": "cx@x.example", "plan": "team", "ok": True, "note": "",
                                                                      "windows": [{"id": "w", "used": 0.25, "reset": 1_900_000_000}]}]}]}
        c, cx = self.provider("claude"), self.provider("codex")
        self.assertEqual([s["label"] for s in c["seats"]], ["A", "B"])
        a, b = c["seats"]
        self.assertEqual((a["email"], a["weight"], a["roles"], a["active"]["cli"]), ("a@x.example", 3, {"cli": True, "app": True}, True))
        self.assertEqual((b["weight"], b["roles"]), (1, {"cli": False, "app": True}))
        self.assertEqual([r["id"] for r in c["removed"]], ["C-20260101T000000Z"])
        self.assertEqual([(s["label"], s["email"], s["plan"], s["headroom"], s["active"]["app"]) for s in cx["seats"]], [("A", "cx@x.example", "team", 0.75, True)])
        self.assertEqual(self.provider("muse")["kind"], "unsupported")

    def test_no_secret_in_state(self):
        self.claude_seat("A", "a@x.example")
        self.codex_seat("A", "cx@x.example")
        self.assertNotIn("SECRET", json.dumps(self.s.state()))


class TestClaudeActions(Base):
    def test_switch_best_import_argvs(self):
        self.claude_seat("A", "a@x.example")
        r = self.wait(self.do(action="claude.cli.switch", label="A"))
        self.assertEqual(r["state"], "ok")
        cli = os.path.join(self.here, "claude-cli-account.ps1")
        self.assertEqual(self.pop.argvs()[-1], ["pwsh", "-NoProfile", "-File", cli, "--switch", "A", "--no-usage"])
        self.wait(self.do(action="claude.cli.best"))
        self.assertEqual(self.pop.argvs()[-1], ["pwsh", "-NoProfile", "-File", cli, "--switch", "best", "--no-usage"])
        self.assertEqual(self.pop.calls[-1][1]["creationflags"], ds.CHILD_FLAGS)           # no window, idle priority
        self.assertEqual(self.do(action="claude.cli.switch", label="Z")[0], 400)           # a seat without a token

    def test_app_switch_and_capture(self):
        self.claude_seat("A", "a@x.example", app=True)
        app = os.path.join(self.here, "claude-app-rotator.ps1")
        self.wait(self.do(action="claude.app.switch", label="A"))
        self.assertEqual(self.pop.argvs()[-1], ["pwsh", "-NoProfile", "-File", app, "--switch", "A", "--relaunch"])
        self.running = [("claude.exe", r"C:\Users\u\AppData\Local\AnthropicClaude\app-6.1\claude.exe")]
        n = len(self.pop.calls)
        code, r = self.do(action="claude.app.capture", label="N")
        self.assertEqual(code, 409)
        self.assertIn("running", r["text"])
        self.assertEqual(len(self.pop.calls), n, "nothing is launched while the app runs")
        self.running = [("claude.exe", r"C:\Users\u\.local\bin\claude.exe")]            # the CLI shares the image name: not the app
        self.wait(self.do(action="claude.app.capture", label="N"))
        self.assertEqual(self.pop.argvs()[-1], ["pwsh", "-NoProfile", "-File", app, "--capture", "N"])

    def test_import_token_never_leaks_and_temp_file_goes(self):
        seen = {}

        def look(argv):
            if "--import" in argv:
                seen["file"] = argv[-1]
                seen["body"] = open(argv[-1]).read()
                seen["dir"] = os.path.dirname(argv[-1])
        self.pop.seen = look
        self.pop.reply = lambda argv: (0, ("Stored setup-token for 'N' (fingerprint abc) %s\n" % SECRET).encode())
        j = self.wait(self.do(action="claude.cli.import", label="N", token=SECRET))
        self.assertEqual(seen["body"], SECRET)
        self.assertEqual(self.pop.argvs()[-1][3:6], [os.path.join(self.here, "claude-cli-account.ps1"), "--import", "N"])
        self.assertFalse(os.path.exists(seen["dir"]), "temp token file removed")
        self.assertNotIn(SECRET, json.dumps(j))
        self.assertNotIn("--replace", self.pop.argvs()[-1])
        self.wait(self.do(action="claude.cli.import", label="N", token=SECRET, replace=True))
        self.assertEqual(self.pop.argvs()[-1][-1], "--replace")
        for bad in ("", "short", "has space " * 5, "x" * 2000, 5, None):
            self.assertEqual(self.do(action="claude.cli.import", label="N", token=bad)[0], 400)

    def test_failed_job_shows_scrubbed_tail(self):
        self.pop.reply = lambda argv: (1, ("line one for a@b.example\nbearer abcdef\nREFUSED: no way\n").encode())
        j = self.wait(self.do(action="claude.cli.best"))
        self.assertEqual(j["state"], "error")
        self.assertIn("exit 1", j["text"])
        self.assertIn("REFUSED", j["text"])
        self.assertNotIn("a@b.example", json.dumps(j))
        self.assertNotIn("abcdef", json.dumps(j))

    def test_cli_add_opens_console_without_page_text_in_the_command(self):
        os.environ["CLAUDE_CODE_OAUTH_TOKEN"] = "x"
        try:
            code, r = self.do(action="claude.cli.add", label="N")
        finally:
            del os.environ["CLAUDE_CODE_OAUTH_TOKEN"]
        self.assertEqual(code, 200)
        argv, kw = self.pop.calls[-1]
        self.assertEqual(argv, ["cmd.exe", "/k", "claude setup-token"])
        self.assertEqual(kw["creationflags"], ds.NEW_CONSOLE)
        self.assertNotIn("CLAUDE_CODE_OAUTH_TOKEN", kw["env"])

    def test_labels_are_validated_before_anything_runs(self):
        for bad in ("", "-x", "_x", "a b", "../x", "a" * 33, "a;b", "é", None, 5, ["A"]):
            for act in ("claude.cli.switch", "claude.cli.add", "claude.app.capture", "remove", "set.weight", "set.email"):
                self.assertEqual(self.do(action=act, label=bad, provider="claude", weight=1, email="")[0], 400, (act, bad))
        self.assertEqual(self.pop.calls, [])

    def test_unknown_actions(self):
        for a in ("handle", "__class__", "do_remove", "", None, "x" * 80, "state", "cred.nope"):
            self.assertEqual(self.do(action=a)[0], 404, a)
        self.assertEqual(self.s.handle("POST", "/api/settings/action", {}, ["x"])[0], 400)


class TestRemoveRestore(Base):
    def test_claude_remove_moves_both_stores_and_restore_brings_them_back(self):
        self.claude_seat("A", "a@x.example", app=True)
        self.claude_seat("B", "b@x.example", app=True)
        put(os.path.join(self.root, ".active"), "A")
        self.assertEqual(self.do(action="remove", provider="claude", label="A")[0], 400)       # in use
        code, r = self.do(action="remove", provider="claude", label="B")
        self.assertEqual(code, 200, r)
        rid = r["id"]
        self.assertEqual(rid, "B-" + ds.stamp(self.clock[0]))
        self.assertFalse(os.path.exists(os.path.join(self.root, "B")))
        self.assertEqual(open(os.path.join(self.root, ".removed", rid, "token.txt")).read(), SECRET + "B")     # moved, not deleted
        self.assertTrue(os.path.isfile(os.path.join(self.apps, ".removed", rid, "config.json")))
        self.assertEqual([x["id"] for x in self.provider("claude")["removed"]], [rid])
        self.claude_seat("B", "other@x.example")                                               # the label was reused meanwhile
        self.assertEqual(self.do(action="restore", provider="claude", id=rid)[0], 409)
        self.assertTrue(os.path.isdir(os.path.join(self.root, ".removed", rid)))
        shutil.move(os.path.join(self.root, "B"), os.path.join(self.tmp, "aside"))
        self.assertEqual(self.do(action="restore", provider="claude", id=rid)[0], 200)
        self.assertEqual(open(os.path.join(self.root, "B", "token.txt")).read(), SECRET + "B")
        self.assertTrue(os.path.isfile(os.path.join(self.apps, "B", "config.json")))
        self.assertEqual(self.provider("claude")["removed"], [])

    def test_a_failed_move_changes_nothing(self):
        self.claude_seat("B", "b@x.example", app=True)
        real, calls = ds.shutil.move, []

        def flaky(a, b):
            calls.append(a)
            if len(calls) == 2:
                raise OSError("locked")
            return real(a, b)
        ds.shutil.move = flaky
        try:
            code, r = self.do(action="remove", provider="claude", label="B")
        finally:
            ds.shutil.move = real
        self.assertEqual(code, 500)
        self.assertTrue(os.path.isfile(os.path.join(self.root, "B", "token.txt")) and os.path.isfile(os.path.join(self.apps, "B", "config.json")))

    def test_restore_rejects_bad_ids(self):
        for rid in ("../x", "B", "B-1", None, "B-20260101T000000Z"):
            self.assertIn(self.do(action="restore", provider="claude", id=rid)[0], (404,))

    def test_codex_add_check_remove_restore(self):
        self.codex_seat("A", "one@x.example")
        put(os.path.join(self.home, ".codex", ".active-account"), "A")
        self.assertEqual(self.do(action="codex.add", label="A")[0], 400)                        # existing home: never logged over
        code, r = self.do(action="codex.add", label="N")
        self.assertEqual(code, 200)
        argv, kw = self.pop.calls[-1]
        self.assertEqual((argv, kw["env"]["CODEX_HOME"]), (["cmd.exe", "/k", "codex login"], os.path.join(self.homes, "N")))
        self.assertEqual(self.do(action="codex.check", label="N")[0], 409)                      # not signed in yet
        put(os.path.join(self.homes, "N", "auth.json"), json.dumps({"tokens": {"id_token": jwt("ONE@x.example")}}))
        code, r = self.do(action="codex.check", label="N")                                      # the same account as A
        self.assertEqual(code, 400)
        self.assertIn("seat A", r["text"])
        self.assertFalse(os.path.exists(os.path.join(self.homes, "N")))
        self.assertEqual(len(self.provider("codex")["removed"]), 1)
        self.codex_seat("N", "two@x.example")
        self.assertEqual(self.do(action="codex.check", label="N")[0], 200)
        self.assertEqual(self.do(action="remove", provider="codex", label="A")[0], 400)         # in use
        code, r = self.do(action="remove", provider="codex", label="N")
        self.assertEqual(code, 200)
        self.assertTrue(os.path.isfile(os.path.join(self.homes, ".removed", r["id"], "auth.json")))
        self.assertEqual(self.do(action="restore", provider="codex", id=r["id"])[0], 200)
        self.assertTrue(os.path.isfile(os.path.join(self.homes, "N", "auth.json")))

    def test_codex_switch_argv(self):
        self.codex_seat("B", "b@x.example")
        self.wait(self.do(action="codex.switch", label="B"))
        self.assertEqual(self.pop.argvs()[-1], ["pwsh", "-NoProfile", "-File", os.path.join(self.here, "codex-app-rotator.ps1"), "--switch", "B"])


class TestWeightEmail(Base):
    def test_weight_keeps_other_settings(self):
        cfg = os.path.join(self.here, "rotator.local.json")
        put(cfg, json.dumps({"hostId": "h", "seatWeights": {"codex": {"B": 5}}}))
        self.assertEqual(self.do(action="set.weight", provider="claude", label="A", weight=2.5)[0], 200)
        d = json.load(open(cfg))
        self.assertEqual(d, {"hostId": "h", "seatWeights": {"codex": {"B": 5}, "claude": {"A": 2.5}}})
        self.do(action="set.weight", provider="claude", label="A", weight=None)
        self.assertEqual(json.load(open(cfg))["seatWeights"], {"codex": {"B": 5}, "claude": {}})
        for bad in (-1, 101, "3", True, float("inf"), [1]):
            self.assertEqual(self.do(action="set.weight", provider="claude", label="A", weight=bad)[0], 400, bad)
        self.assertEqual(self.do(action="set.weight", provider="nope", label="A", weight=1)[0], 404)

    def test_weight_when_no_file_yet(self):
        self.assertEqual(self.do(action="set.weight", provider="codex", label="C", weight=5)[0], 200)
        self.assertEqual(json.load(open(os.path.join(self.here, "rotator.local.json"))), {"seatWeights": {"codex": {"C": 5}}})

    def test_claude_email(self):
        self.claude_seat("A", "old@x.example")
        self.assertEqual(self.do(action="set.email", provider="claude", label="A", email="new@x.example")[0], 200)
        self.assertEqual(open(os.path.join(self.root, "A", "email.txt")).read().strip(), "new@x.example")
        for bad in ("nope", "a@b", "a b@c.de", 5, "x" * 300 + "@y.example"):
            self.assertEqual(self.do(action="set.email", provider="claude", label="A", email=bad)[0], 400, bad)
        self.assertEqual(self.do(action="set.email", provider="claude", label="Q", email="a@b.example")[0], 400)
        self.assertEqual(self.do(action="set.email", provider="claude", label="A", email="")[0], 200)
        self.assertFalse(os.path.exists(os.path.join(self.root, "A", "email.txt")))


class TestAutomation(Base):
    def test_status_and_toggles(self):
        def reply(argv):
            if argv[:2] == ["schtasks", "/Query"]:
                st = {"Claude usage auto-rotate": "Ready", "Claude app-history sync": "Disabled", "Claude rotate proxy": "Running"}.get(argv[3])
                return (0, ('"\\%s","N/A","%s"\r\n' % (argv[3], st)).encode()) if st else (1, b"ERROR: not found")
            return 0, b""
        self.pop.reply = reply
        self.s.proxy_health = lambda: {"up": True, "ok": True}
        a = self.s.automation()
        self.assertEqual({t["id"]: t["state"] for t in a["tasks"]}, {"autorotate": "ready", "historysync": "disabled", "keepalive": "missing", "codexkeepalive": "missing", "proxy": "running"})
        self.assertTrue(a["autoResume"])
        self.assertEqual(self.do(action="task.set", task="autorotate", enabled=False)[0], 200)
        self.assertEqual(self.pop.argvs()[-1], ["schtasks", "/Change", "/TN", "Claude usage auto-rotate", "/DISABLE"])
        self.do(action="task.set", task="historysync", enabled=True)
        self.assertEqual(self.pop.argvs()[-1], ["schtasks", "/Change", "/TN", "Claude app-history sync", "/ENABLE"])
        self.assertEqual(self.do(action="task.set", task="Claude usage dashboard", enabled=False)[0], 404)       # only the listed tasks
        self.assertEqual(self.do(action="task.set", task="proxy", enabled="no")[0], 404)
        self.do(action="proxy.restart")
        self.assertEqual(self.pop.argvs()[-2:], [["schtasks", "/End", "/TN", "Claude rotate proxy"], ["schtasks", "/Run", "/TN", "Claude rotate proxy"]])

    def test_a_refused_change_says_so(self):
        self.pop.reply = lambda argv: (1, b"ERROR: Access is denied.")
        code, r = self.do(action="task.set", task="autorotate", enabled=True)
        self.assertEqual((r["outcome"], "Access is denied" in r["text"]), ("error", True))

    def test_auto_resume_marker(self):
        marker = os.path.join(self.root, ".auto-resume-off")
        self.assertEqual(self.do(action="auto.resume", enabled=False)[0], 200)
        self.assertTrue(os.path.isfile(marker))
        self.assertFalse(self.s.automation.__self__.automation.__func__ is None)
        self.do(action="auto.resume", enabled=True)
        self.assertFalse(os.path.exists(marker))
        self.assertEqual(self.do(action="auto.resume", enabled="x")[0], 400)

    def test_sync_history_and_keepalive_status_argvs(self):
        self.wait(self.do(action="sync.history"))
        self.assertEqual(self.pop.argvs()[-1], ["pwsh", "-NoProfile", "-File", os.path.join(self.here, "sync-app-history.ps1")])
        put(os.path.join(self.home, ".grok", "bin", "sync-app-history.ps1"))
        self.wait(self.do(action="sync.history"))
        self.assertEqual(self.pop.argvs()[-1][-1], os.path.join(self.home, ".grok", "bin", "sync-app-history.ps1"))      # the copy the task runs wins
        self.wait(self.do(action="keepalive.status"))
        self.assertEqual(self.pop.argvs()[-1], ["pwsh", "-NoProfile", "-File", os.path.join(self.here, "claude-app-seat-keepalive.ps1"), "-Status"])

    def test_one_action_at_a_time(self):
        self.pop.gate = threading.Event()
        code, r = self.do(action="claude.cli.best")
        self.assertEqual(code, 202)
        self.assertEqual(self.do(action="proxy.restart")[0], 409)
        self.assertEqual(self.do(action="remove", provider="claude", label="A")[0], 400)           # refused on its own merits before the lock is even tried
        self.pop.gate.set()
        end = time.time() + 5
        while self.s.get_job(r["job"])["state"] == "running" and time.time() < end:
            time.sleep(0.01)
        time.sleep(0.1)
        self.assertEqual(self.do(action="auto.resume", enabled=True)[0], 200)

    def test_store_lock_is_respected(self):
        self.store.refreshing = threading.Lock()
        self.store.refreshing.acquire()
        self.assertEqual(self.do(action="claude.cli.best")[0], 409)
        self.store.refreshing.release()
        self.wait(self.do(action="claude.cli.best"))
        self.assertTrue(self.store.refreshing.acquire(blocking=False), "released after the job")


class TestHeadroom(Base):
    def test_capped_is_told_apart_from_no_reading(self):
        now = self.clock[0]
        self.assertTrue(self.s.capped([{"used": 0.2, "reset": now + 99}, {"used": 1.0, "reset": now + 99}]))
        self.assertFalse(self.s.capped([{"used": 1.0, "reset": now - 1}]))              # renewed since
        self.assertFalse(self.s.capped([]) or self.s.capped(None) or self.s.capped([{"used": None}]))
        self.store.blob = {"providers": [{"id": "claude", "accounts": [{"label": "A", "windows": [{"used": 1.0, "reset": now + 99}]}]}]}
        self.claude_seat("A")
        a = self.provider("claude")["seats"][0]
        self.assertEqual((a["headroom"], a["capped"]), (None, True))

    def test_headroom_rules(self):
        h = self.s.headroom
        self.assertEqual(h([{"used": 0.3}, {"used": 0.6}]), 0.4)
        self.assertIsNone(h([{"used": 0.3}, {"used": 1.0}]))                      # capped: never offered
        self.assertEqual(h([{"used": 1.0, "reset": 1_700_000_000}]), 1.0)          # renewed since the reading
        self.assertIsNone(h([]))
        self.assertIsNone(h([{"label": "no number"}]))

    def test_pick_best_skips_the_seat_in_use_and_capped_ones(self):
        for l in "ABCD":
            self.codex_seat(l, l.lower() + "@x.example")
        put(os.path.join(self.home, ".codex", ".active-account"), "A")
        acc = lambda l, u: {"label": l, "windows": [{"used": u}]}
        self.store.blob = {"providers": [{"id": "codex", "accounts": [acc("A", 0.0), acc("B", 0.9), acc("C", 0.4), acc("D", 1.0)]}]}
        self.assertEqual(self.s.pick_best("codex", "app"), ("C", 0.6))
        self.wait(self.do(action="codex.best"))
        self.assertEqual(self.pop.argvs()[-1][-2:], ["--switch", "C"])
        self.store.blob = {"providers": [{"id": "codex", "accounts": [acc("A", 0.0), acc("D", 1.0)]}]}
        self.assertEqual(self.do(action="codex.best")[0], 400)

    def test_claude_app_best(self):
        self.claude_seat("A", app=True)
        self.claude_seat("B", app=True)
        self.claude_seat("C", app=False)
        put(os.path.join(self.apps, ".active"), "A")
        acc = lambda l, u: {"label": l, "windows": [{"used": u}]}
        self.store.blob = {"providers": [{"id": "claude", "inUse": {"cli": "A", "app": "A"}, "accounts": [acc("A", 0.0), acc("B", 0.5), acc("C", 0.1)]}]}
        self.wait(self.do(action="claude.app.best"))
        self.assertEqual(self.pop.argvs()[-1][-3:], ["--switch", "B", "--relaunch"])         # C has no app login


class CredBase(Base):
    def setUp(self):
        Base.setUp(self)
        self.gdir = os.path.join(self.home, ".gemini")

    def gemini_login(self, email, tag):
        put(os.path.join(self.gdir, "oauth_creds.json"), json.dumps({"access_token": "tok-" + tag, "id_token": jwt(email)}))
        put(os.path.join(self.gdir, "google_accounts.json"), json.dumps({"active": email, "old": []}))
        self.cred.d["gemini:antigravity"] = {"blob": json.dumps({"token": {"access_token": "app-" + tag}, "id_token_email": email}).encode(), "user": "u", "persist": 2}

    def live(self):
        return (open(os.path.join(self.gdir, "oauth_creds.json"), "rb").read(), self.cred.d["gemini:antigravity"]["blob"])


class TestCredSeats(CredBase):
    def test_capture_switch_round_trip_gemini(self):
        self.gemini_login("one@x.example", "1")
        one = self.live()
        self.assertEqual(self.do(action="cred.capture", provider="gemini", label="one")[0], 200)
        self.gemini_login("two@x.example", "2")
        two = self.live()
        self.assertEqual(self.do(action="cred.capture", provider="gemini", label="two")[0], 200)
        st = {x["label"]: x for x in self.provider("gemini")["seats"]}
        self.assertEqual((st["two"]["active"]["login"], st["one"]["active"]["login"], st["two"]["email"]), (True, False, "two@x.example"))
        # the live login moves on (a token refresh), then we switch away: the refreshed copy must be kept in seat two
        put(os.path.join(self.gdir, "oauth_creds.json"), json.dumps({"access_token": "tok-2-refreshed", "id_token": jwt("two@x.example")}))
        refreshed = open(os.path.join(self.gdir, "oauth_creds.json"), "rb").read()
        code, r = self.do(action="cred.switch", provider="gemini", label="one")
        self.assertEqual(code, 200, r)
        self.assertEqual(self.live(), one, "live login is now exactly seat one's")
        self.assertEqual(open(os.path.join(self.gdir, "google_accounts.json")).read(), json.dumps({"active": "one@x.example", "old": []}))
        self.assertEqual(open(os.path.join(self.s.cdir("gemini", "two"), "files", "f0"), "rb").read(), refreshed)
        bk = os.listdir(self.s.cdir("gemini", ".swap-backups"))
        self.assertTrue(any(n.startswith("before-one-") for n in bk), bk)
        self.assertEqual(open(os.path.join(self.s.cdir("gemini", ".swap-backups"), [n for n in bk if n.startswith("before-one-")][0], "files", "f0"), "rb").read(), refreshed)
        self.assertEqual(self.do(action="cred.switch", provider="gemini", label="one")[1]["text"], "Seat one is already the login in use.")
        self.assertEqual(self.do(action="cred.switch", provider="gemini", label="two")[0], 200)
        self.assertEqual(self.live()[0], refreshed)
        self.assertNotEqual(two[0], refreshed)

    def test_refused_while_the_app_runs_and_changes_nothing(self):
        self.gemini_login("one@x.example", "1")
        self.do(action="cred.capture", provider="gemini", label="one")
        self.gemini_login("two@x.example", "2")
        self.do(action="cred.capture", provider="gemini", label="two")
        before = self.live()
        self.running = [("antigravity.exe", r"C:\x\Antigravity.exe")]
        code, r = self.do(action="cred.switch", provider="gemini", label="one")
        self.assertEqual(code, 409)
        self.assertIn("Antigravity", r["text"])
        self.assertEqual(self.live(), before)

    def test_capture_guards(self):
        self.assertEqual(self.do(action="cred.capture", provider="gemini", label="x")[0], 400)           # nothing signed in
        self.gemini_login("one@x.example", "1")
        self.do(action="cred.capture", provider="gemini", label="one")
        code, r = self.do(action="cred.capture", provider="gemini", label="again")                      # the same login under a second name
        self.assertEqual(code, 400)
        self.assertIn("seat one", r["text"])
        self.gemini_login("two@x.example", "2")
        self.assertEqual(self.do(action="cred.capture", provider="gemini", label="one")[0], 400)         # a different account over an existing seat
        self.assertEqual(self.do(action="cred.capture", provider="gemini", label="one", replace=True)[0], 200)
        self.assertTrue(any("one-replaced" in n for n in os.listdir(self.s.cdir("gemini", ".swap-backups"))))
        self.assertEqual(self.do(action="cred.capture", provider="nope", label="one")[0], 404)

    def test_a_failed_write_puts_the_old_login_back(self):
        self.gemini_login("one@x.example", "1")
        self.do(action="cred.capture", provider="gemini", label="one")
        self.gemini_login("two@x.example", "2")
        self.do(action="cred.capture", provider="gemini", label="two")
        before = self.live()
        self.cred.fail_writes_after = self.cred.writes            # the next credential write fails (files were already replaced)
        code, r = self.do(action="cred.switch", provider="gemini", label="one")
        self.assertEqual(code, 500)
        self.assertIn("put back", r["text"])
        self.cred.fail_writes_after = None
        self.assertEqual(self.live()[0], before[0])

    def test_remove_restore_email_weight_for_cred_seats(self):
        self.gemini_login("one@x.example", "1")
        self.do(action="cred.capture", provider="gemini", label="one")
        self.gemini_login("two@x.example", "2")
        self.do(action="cred.capture", provider="gemini", label="two")
        self.do(action="set.email", provider="gemini", label="one", email="shown@x.example")
        self.assertEqual({x["label"]: x["email"] for x in self.provider("gemini")["seats"]}["one"], "shown@x.example")
        self.assertEqual(self.match("gemini", "one@x.example"), "one", "the shown address does not change which login a seat is")
        self.do(action="set.weight", provider="gemini", label="one", weight=2)
        self.assertEqual({x["label"]: x["weight"] for x in self.provider("gemini")["seats"]}["one"], 2)
        code, r = self.do(action="remove", provider="gemini", label="one")
        self.assertEqual(code, 200)
        self.assertTrue(os.path.isfile(os.path.join(self.s.cdir("gemini"), ".removed", r["id"], "meta.json")))
        self.assertEqual(self.do(action="restore", provider="gemini", id=r["id"])[0], 200)
        self.assertEqual(sorted(self.s.cred_seats("gemini")), ["one", "two"])

    def match(self, pid, email):
        return self.s.match_seat(pid, email)

    def test_most_headroom_uses_remembered_readings(self):
        self.gemini_login("one@x.example", "1")
        self.do(action="cred.capture", provider="gemini", label="one")
        self.gemini_login("two@x.example", "2")
        self.do(action="cred.capture", provider="gemini", label="two")
        self.gemini_login("one@x.example", "1")                                             # one is in use: the dashboard sees one
        self.store.blob = {"providers": [{"id": "gemini", "accounts": [{"label": "antigravity", "ok": True, "windows": [{"used": 0.8, "reset": 1_900_000_000}]}]}]}
        self.s.handle("GET", "/api/settings/seats", {}, None)                               # opening the panel remembers it
        self.assertEqual(self.do(action="cred.best", provider="gemini")[0], 400)           # two has no number yet: never picked blindly
        self.gemini_login("two@x.example", "2")                                             # now two is in use and the dashboard sees two
        self.store.blob = {"providers": [{"id": "gemini", "accounts": [{"label": "antigravity", "ok": True, "windows": [{"used": 0.1, "reset": 1_900_000_000}]}]}]}
        self.s.handle("GET", "/api/settings/seats", {}, None)
        self.gemini_login("one@x.example", "1")
        self.store.blob = {"providers": [{"id": "gemini", "accounts": [{"label": "antigravity", "ok": True, "windows": [{"used": 0.8, "reset": 1_900_000_000}]}]}]}
        self.assertEqual(self.s.pick_best("gemini"), ("two", 0.9))
        self.assertEqual(self.do(action="cred.best", provider="gemini")[0], 200)
        self.assertEqual(self.live()[0], json.dumps({"access_token": "tok-2", "id_token": jwt("two@x.example")}).encode())

    def test_grok_file_seat(self):
        gp = os.path.join(self.home, ".grok", "auth.json")
        put(gp, json.dumps({"https://auth.x.ai::id": {"key": "k1", "email": "g1@x.example"}}))
        self.do(action="cred.capture", provider="grok", label="g1")
        put(gp, json.dumps({"https://auth.x.ai::id": {"key": "k2", "email": "g2@x.example"}}))
        self.do(action="cred.capture", provider="grok", label="g2")
        self.running = [("grok.exe", r"C:\x\grok.exe")]
        self.assertEqual(self.do(action="cred.switch", provider="grok", label="g1")[0], 409)
        self.running = []
        self.assertEqual(self.do(action="cred.switch", provider="grok", label="g1")[0], 200)
        self.assertEqual(json.load(open(gp))["https://auth.x.ai::id"]["key"], "k1")
        self.assertNotIn("k1", json.dumps(self.s.state()))

    def test_kimi_folder_seat(self):
        old = os.environ.get("KIMI_CODE_HOME")
        kh = os.path.join(self.tmp, "kimi")
        os.environ["KIMI_CODE_HOME"] = kh
        try:
            s = ds.Settings(home=self.home, here=self.here, popen=self.pop, procs=lambda: [], cred=self.cred, now=lambda: self.clock[0], store=self.store, which=lambda n: None)
            self.assertEqual(s.handle("POST", "/api/settings/action", {}, {"action": "cred.capture", "provider": "kimi", "label": "k"})[0], 400)   # not signed in
            put(os.path.join(kh, "credentials", "a.json"), '{"t": 1}')
            put(os.path.join(kh, "credentials", "sub", "b.json"), '{"t": 2}')
            self.assertEqual(s.handle("POST", "/api/settings/action", {}, {"action": "cred.capture", "provider": "kimi", "label": "k"})[0], 200)
            put(os.path.join(kh, "credentials", "a.json"), '{"t": 99}')
            put(os.path.join(kh, "credentials", "extra.json"), "x")
            # no email is readable for Kimi, so the seat cannot be matched to the live login: a second capture under another name is allowed, and a switch applies the seat
            self.assertEqual(s.handle("POST", "/api/settings/action", {}, {"action": "cred.switch", "provider": "kimi", "label": "k"})[0], 200)
            self.assertEqual(open(os.path.join(kh, "credentials", "a.json")).read(), '{"t": 1}')
            self.assertTrue(os.path.isfile(os.path.join(kh, "credentials", "sub", "b.json")))
            self.assertFalse(os.path.exists(os.path.join(kh, "credentials", "extra.json")))
            bk = os.listdir(s.cdir("kimi", ".swap-backups"))
            self.assertTrue(os.path.isfile(os.path.join(s.cdir("kimi", ".swap-backups"), bk[0], "files", "d0", "extra.json")), "the replaced folder is kept")
        finally:
            if old is None:
                os.environ.pop("KIMI_CODE_HOME", None)
            else:
                os.environ["KIMI_CODE_HOME"] = old


class TestKimiTab(Base):
    def setUp(self):
        Base.setUp(self)
        self.old = os.environ.get("KIMI_CODE_HOME")
        self.kh = os.path.join(self.tmp, "kimi")
        os.environ["KIMI_CODE_HOME"] = self.kh
        self.s = ds.Settings(home=self.home, here=self.here, popen=self.pop, procs=lambda: [], cred=self.cred, now=lambda: self.clock[0], store=self.store, which=lambda n: None)   # reads the folder at start

    def tearDown(self):
        if self.old is None:
            os.environ.pop("KIMI_CODE_HOME", None)
        else:
            os.environ["KIMI_CODE_HOME"] = self.old
        Base.tearDown(self)

    def ids(self):
        return [p["id"] for p in self.s.state()["providers"]]

    def test_not_installed_means_no_tab_and_no_sign_in(self):
        self.assertNotIn("kimi", self.ids())
        code, r = self.do(action="cred.signin", provider="kimi")
        self.assertEqual((code, r["outcome"]), (404, "error"))
        self.assertEqual(self.pop.calls, [])

    def test_installed_but_signed_out_has_a_tab_that_can_open_kimi_to_log_in(self):
        exe = os.path.join(self.kh, "bin", "kimi.exe")
        put(exe)
        p = self.provider("kimi")
        self.assertEqual((p["signin"], p["current"]["present"], p["seats"]), (True, False, []))
        self.assertEqual(self.do(action="cred.capture", provider="kimi", label="k")[0], 400)           # nothing to save yet
        code, r = self.do(action="cred.signin", provider="kimi")
        self.assertEqual((code, r["outcome"]), (200, "ok"))
        argv, kw = self.pop.calls[-1]
        self.assertEqual(argv, ["cmd.exe", "/k", exe])                                                 # a console running kimi, nothing from the page in the command
        self.assertEqual(kw["creationflags"], ds.NEW_CONSOLE)

    def test_kimi_on_the_path_counts_as_installed(self):
        s = ds.Settings(home=self.home, here=self.here, popen=self.pop, procs=lambda: [], cred=self.cred, now=lambda: 0, store=self.store, which=lambda n: "C:/x/kimi.exe" if n == "kimi" else None)
        self.assertIn("kimi", [p["id"] for p in s.state()["providers"]])

    def test_once_a_login_exists_it_can_be_saved_as_a_seat(self):
        put(os.path.join(self.kh, "bin", "kimi.exe"))
        put(os.path.join(self.kh, "credentials", "a.json"), '{"t": 1}')
        self.assertTrue(self.provider("kimi")["current"]["present"])
        self.assertEqual(self.do(action="cred.capture", provider="kimi", label="k")[0], 200)
        self.assertEqual([x["label"] for x in self.provider("kimi")["seats"]], ["k"])

    def test_signin_is_only_for_providers_that_have_one(self):
        self.assertEqual(self.do(action="cred.signin", provider="grok")[0], 404)
        self.assertEqual(self.do(action="cred.signin", provider="nope")[0], 404)


class FakeUpdateStore:
    """The slice of the dashboard's Store that the Updates section talks to."""
    def __init__(self, checked=100):
        self.blob, self.checked, self.differing, self.forced, self.rebuilds = {"providers": []}, checked, [], [], 0
        self.lock = threading.RLock()

    def update_info(self):
        return {"auto": True, "state": "idle", "text": "", "checkout": False, "installed": "abc1234", "differing": list(self.differing), "checked": self.checked, "done": None}

    def drift_check(self, now, force=False):
        self.forced.append(force)
        self.checked = int(now)

    def rebuild(self, now):
        self.rebuilds += 1


class TestUpdates(Base):
    def setUp(self):
        Base.setUp(self)
        self.us = FakeUpdateStore()
        self.s = ds.Settings(home=self.home, here=self.here, popen=self.pop, procs=lambda: [], cred=self.cred, now=lambda: self.clock[0], store=self.us, which=lambda n: None)

    def test_auto_update_writes_one_key_and_keeps_the_others(self):
        put(self.s.local_cfg, json.dumps({"seatWeights": {"codex": {"B": 5}}, "hostId": "x"}))
        self.assertEqual(self.do(action="update.auto", enabled=False)[0], 200)
        cfg = json.load(open(self.s.local_cfg))
        self.assertEqual(cfg, {"seatWeights": {"codex": {"B": 5}}, "hostId": "x", "autoUpdate": False})
        self.do(action="update.auto", enabled=True)
        self.assertIs(json.load(open(self.s.local_cfg))["autoUpdate"], True)
        self.assertEqual(self.do(action="update.auto", enabled="yes")[0], 400)           # only a real on/off
        self.assertEqual(self.do(action="update.auto")[0], 400)

    def test_auto_update_with_no_config_file_yet(self):
        self.assertFalse(os.path.exists(self.s.local_cfg))
        self.do(action="update.auto", enabled=False)
        self.assertEqual(json.load(open(self.s.local_cfg)), {"autoUpdate": False})

    def test_check_now_runs_the_drift_check_forced_and_says_the_result(self):
        self.clock[0] = 1_800_000_500
        code, r = self.do(action="update.check")
        self.assertEqual((code, r["outcome"], r["text"]), (200, "ok", "Up to date with GitHub."))
        self.assertEqual(self.us.forced, [True])
        self.assertEqual(self.us.rebuilds, 1)                                              # the page's banner is refreshed at once
        self.us.differing = ["a.py", "b.py"]
        self.clock[0] += 5
        self.assertIn("2 files differ from GitHub", self.do(action="update.check")[1]["text"])

    def test_a_check_that_did_not_finish_is_an_error(self):
        self.us.drift_check = lambda now, force=False: None                                   # offline: nothing is recorded
        code, r = self.do(action="update.check")
        self.assertEqual((code, r["outcome"]), (200, "error"))
        self.assertIn("did not finish", r["text"])

    def test_no_store_means_not_available_not_a_crash(self):
        s = ds.Settings(home=self.home, here=self.here, popen=self.pop, procs=lambda: [], cred=self.cred, now=lambda: 0, store=None, which=lambda n: None)
        self.assertEqual(s.handle("POST", "/api/settings/action", {}, {"action": "update.check"})[0], 404)
        self.assertEqual(s.handle("GET", "/api/settings/update", {}, None), (200, {"update": None}))

    def test_the_section_data_is_served(self):
        code, j = self.s.handle("GET", "/api/settings/update", {}, None)
        self.assertEqual((code, j["update"]["installed"], j["update"]["auto"]), (200, "abc1234", True))
        self.pop.reply = lambda argv: (1, b"")
        self.assertEqual(self.s.automation()["update"]["checked"], 100)


class TestHelpers(unittest.TestCase):
    def test_scrub(self):
        t = ds.scrub("tok %s bearer abc.def me@x.example \x1b[31mred\x1b[0m %s" % (SECRET, "A" * 50))
        for bad in (SECRET, "abc.def", "me@x.example", "\x1b", "A" * 50):
            self.assertNotIn(bad, t)

    def test_jwt_email(self):
        self.assertEqual(ds.jwt_email(jwt("a@b.example")), "a@b.example")
        self.assertEqual(ds.jwt_email("garbage"), "")
        self.assertEqual(ds.jwt_email(None), "")


class TestHttp(Base):
    """Through the dashboard's real request handler (usage-history.make_handler) on a spare port."""

    def setUp(self):
        Base.setUp(self)
        os.environ["QUOTA_STATE_DIR"] = os.path.join(self.tmp, "state")
        spec = importlib.util.spec_from_file_location("usage_history_under_test", os.path.join(HERE, "usage-history.py"))
        self.uh = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = self.uh
        spec.loader.exec_module(self.uh)
        with socket.socket() as sk:
            sk.bind(("127.0.0.1", 0))
            self.port = sk.getsockname()[1]
        from http.server import ThreadingHTTPServer
        ds._default["s"] = self.s
        self.srv = ThreadingHTTPServer(("127.0.0.1", self.port), self.uh.make_handler(self.store, self.port))
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()

    def tearDown(self):
        self.srv.shutdown()
        self.srv.server_close()
        ds._default.clear()
        os.environ.pop("QUOTA_STATE_DIR", None)
        Base.tearDown(self)

    def req(self, method, path, body=None, headers=None, host=None):
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        h = {"Host": host or "127.0.0.1:%d" % self.port}
        h.update(headers or {})
        c.request(method, path, json.dumps(body).encode() if body is not None else None, h)
        r = c.getresponse()
        return r.status, r.read(), r.getheader("Content-Type")

    def test_routes_and_guards(self):
        self.claude_seat("A", "a@x.example")
        code, body, ct = self.req("GET", "/settings.js")
        self.assertEqual((code, ct.split(";")[0]), (200, "text/javascript"))
        code, body, _ = self.req("GET", "/api/settings/seats")
        self.assertEqual(code, 200)
        self.assertEqual([s["label"] for p in json.loads(body)["providers"] if p["id"] == "claude" for s in p["seats"]], ["A"])
        self.assertEqual(self.req("GET", "/api/settings/seats", host="evil.example")[0], 403)                 # the existing Host guard still applies
        self.assertEqual(self.req("POST", "/api/settings/action", {"action": "proxy.restart"})[0], 403)        # no X-Quota-App: refused
        self.assertEqual(self.pop.calls, [])
        code, body, _ = self.req("POST", "/api/settings/action", {"action": "set.weight", "provider": "claude", "label": "A", "weight": 4}, {"X-Quota-App": "1"})
        self.assertEqual(code, 200, body)
        self.assertEqual(json.load(open(os.path.join(self.here, "rotator.local.json")))["seatWeights"]["claude"]["A"], 4)
        self.assertEqual(self.req("POST", "/api/settings/action", None, {"X-Quota-App": "1"})[0], 400)         # no body
        code, body, _ = self.req("GET", "/api/settings/job?id=nope")
        self.assertEqual(code, 404)
        self.assertEqual(self.req("GET", "/api/data")[0], 200)                                                 # the page's own routes still work

    def test_job_over_http_and_no_token_in_any_response(self):
        self.claude_seat("A", "a@x.example")
        self.pop.reply = lambda argv: (0, b"Stored. " + SECRET.encode())
        code, body, _ = self.req("POST", "/api/settings/action", {"action": "claude.cli.import", "label": "N", "token": SECRET}, {"X-Quota-App": "1"})
        self.assertEqual(code, 202, body)
        jid = json.loads(body)["job"]
        end = time.time() + 5
        while time.time() < end:
            code, body2, _ = self.req("GET", "/api/settings/job?id=" + jid)
            if json.loads(body2)["state"] != "running":
                break
            time.sleep(0.02)
        self.assertEqual(json.loads(body2)["state"], "ok")
        for b in (body, body2, self.req("GET", "/api/settings/seats")[1]):
            self.assertNotIn(SECRET.encode(), b)


@unittest.skipUnless(os.environ.get("RUN_REAL_CRED") == "1" and os.name == "nt", "set RUN_REAL_CRED=1 on Windows to check the ctypes layer against the real Credential Manager")
class TestRealCredApi(unittest.TestCase):
    def test_round_trip_on_a_throwaway_entry(self):
        c, t = ds.WinCred(), "agent-dashboard-selftest-%d" % os.getpid()
        try:
            self.assertIsNone(c.read(t))
            c.write(t, b'{"a": "\xc3\xa9"}', "someone", 2)
            r = c.read(t)
            self.assertEqual((r["blob"], r["user"], r["persist"]), (b'{"a": "\xc3\xa9"}', "someone", 2))
            c.write(t, b"second", "someone", 2)
            self.assertEqual(c.read(t)["blob"], b"second")
        finally:
            c.delete(t)
        self.assertIsNone(c.read(t))


if __name__ == "__main__":
    unittest.main(verbosity=1)
