"""sidebar-sync.py: carry the Claude desktop app's sidebar PINS across app seats at seat-switch time (agent-dashboard issue #10, PR 1).

Called by claude-app-rotator.ps1 (which holds the seat lock with the app closed and owns every durable step):

  --stage   --leaving <seat> --target <seat> --gen <gen>   read the seats, work out the pins the target should have, and build the
                                                          staging copy under <seats>\\.sidebar-sync-work\\<gen>\\ (READ-ONLY elsewhere)
  --verify  --gen <gen> --target <seat>                   after the app starts: compare the three pin stores with the baseline; report only
  --dry-run --target <seat>                               print what a switch to <seat> would change; writes nothing, works with the app open
  --forget  <seat>                                        invalidate a seat's baseline and drop its pending departure (README reset steps)

The pin list lives in THREE places the app reads: IndexedDB `store:pin-state:dframe-starred-code` (`starredIds`), Local Storage
`LSS-persisted.starred-local-code-sessions` and claude_desktop_config.json `preferences.epitaxyPrefs.starred-local-code-sessions`. Session
ids differ per seat, so pins are mapped through `cliSessionId`. The design is in the plan (wiki handoffs, sidebar-sync-issue10-plan).

Python's own writes: the state file (via the rotator, which publishes <gen>\\state.json) and <gen>\\ only. Every profile, baseline and config
write is the rotator's. Stdlib only. Run as `py -3 -I sidebar-sync.py ...`.
"""
import argparse
import base64
import fnmatch
import glob
import hashlib
import json
import os
import shutil
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))   # -I drops the script directory from sys.path
import sidebar_ldb as L  # noqa: E402

STATE = '.sidebar-sync-state.json'
WORK = '.sidebar-sync-work'
SYNC_LOCK = '.sidebar-sync.lock'
HIST_LOCK = '.sync-history.lock'
BASELINE, INSTALLED, DEPARTURE = 'sidebar-baseline.json', 'sidebar-installed.json', 'sidebar-departure.json'
LS_DIR = ('Local Storage', 'leveldb')
IDB_DIR = ('IndexedDB', 'https_claude.ai_0.indexeddb.leveldb')
LS_PIN_NAME = 'LSS-persisted.starred-local-code-sessions'
CFG_PIN = 'starred-local-code-sessions'
STATE_VERSION = 1


class Skip(Exception):
    """Not an error: staging is skipped for this reason (reported, the switch goes on)."""


def now_ms():
    return int(time.time() * 1000)


def sha256_file(p):
    return hashlib.sha256(open(p, 'rb').read()).hexdigest()


def jread(p):
    with open(p, 'rb') as f:
        return json.loads(f.read().decode('utf-8-sig'))


def jdump(o):
    return json.dumps(o, separators=(',', ':'), ensure_ascii=False)


def write_text(p, s):
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, 'w', encoding='utf-8', newline='\n') as f:
        f.write(s)


# ---- seats, records -----------------------------------------------------------------------------------------------------------

def list_seats(seats_root):
    """{seat: account uuid}: non-dot directories with owner-uuid.txt."""
    out = {}
    try:
        names = sorted(os.listdir(seats_root))
    except OSError:
        return out
    for n in names:
        d = os.path.join(seats_root, n)
        f = os.path.join(d, 'owner-uuid.txt')
        if not n.startswith('.') and os.path.isdir(d) and os.path.isfile(f):
            u = open(f, encoding='utf-8-sig').read().strip()
            if u:
                out[n] = u
    return out


class Rec:
    __slots__ = ('sid', 'cli', 'archived', 'last', 'title')

    def __init__(self, sid, cli, archived, last, title):
        self.sid, self.cli, self.archived, self.last, self.title = sid, cli, archived, last, title


class View:
    """One seat's records: sid -> Rec, cli -> copies (preferred first: unarchived, then newest lastActivityAt)."""

    def __init__(self, recs):
        self.recs = recs
        self.by_cli = {}
        for r in recs.values():
            self.by_cli.setdefault(r.cli, []).append(r)
        for v in self.by_cli.values():
            v.sort(key=lambda r: (r.archived, -r.last, r.sid))

    def sids(self, cli):
        return {r.sid for r in self.by_cli.get(cli, [])}


def read_view(app_dir, acct):
    """Every org folder of the account: <app>\\claude-code-sessions\\<acct>\\<org>\\local_*.json. Unreadable records are skipped."""
    recs = {}
    for p in glob.glob(os.path.join(app_dir, 'claude-code-sessions', acct, '*', 'local_*.json')):
        try:
            j = jread(p)
            cli = j.get('cliSessionId')
            sid = j.get('sessionId') or os.path.splitext(os.path.basename(p))[0]
            if not isinstance(cli, str) or not cli or not isinstance(sid, str):
                continue
            last = j.get('lastActivityAt')
            recs[sid] = Rec(sid, cli, bool(j.get('isArchived')), last if isinstance(last, (int, float)) else 0, str(j.get('title') or sid))
        except (OSError, ValueError, AttributeError):
            continue
    return View(recs)


# ---- the pin stores -----------------------------------------------------------------------------------------------------------

class Pins:
    def __init__(self, ok, why='', pins=None, manifest=None):
        self.ok, self.why, self.pins, self.manifest = ok, why, pins or [], manifest or {}


def _str_list(x):
    return isinstance(x, list) and all(isinstance(s, str) for s in x)


def read_ls_pins(ls_dir):
    snap = L.read_snapshot(ls_dir)
    e = snap.entries.get(L.ls_key(LS_PIN_NAME))
    if not e:
        raise L.LdbError('Local Storage has no pin list')
    j = json.loads(L.ls_decode(e[1]))
    if not isinstance(j, dict) or not _str_list(j.get('value')):
        raise L.LdbError('Local Storage pin list has an unknown shape')
    return j, snap


def read_idb_pins(idb_dir):
    snap = L.read_snapshot(idb_dir)
    db = {k: v for k, (s, v) in snap.entries.items()}
    k = L.idb_pin_key(db)
    if k is None:
        raise L.LdbError('IndexedDB has no (single) pin state')
    txt = L.idb_json(db[k])
    if txt is None:
        raise L.LdbError('IndexedDB pin state is not a one-byte V8 string')
    j = json.loads(txt)
    ids = j.get('state', {}).get('starredIds') if isinstance(j, dict) and isinstance(j.get('state'), dict) else None
    if not _str_list(ids):
        raise L.LdbError('IndexedDB pin state has an unknown shape')
    return j, k, db[k], snap


def read_pins(ls_dir, idb_dir):
    """The seat's pin list from its two databases; ok only when both are readable and agree (as sets)."""
    try:
        ls, lsnap = read_ls_pins(ls_dir)
        idb, _, _, isnap = read_idb_pins(idb_dir)
    except (L.LdbError, OSError, ValueError) as e:
        return Pins(False, 'pin stores unreadable (%s)' % e)
    if set(ls['value']) != set(idb['state']['starredIds']):
        return Pins(False, 'Local Storage and IndexedDB disagree about the pins')
    return Pins(True, '', list(ls['value']), {'ls': lsnap.manifest.number, 'idb': isnap.manifest.number})


def seat_dirs(seat_dir):
    return os.path.join(seat_dir, *LS_DIR), os.path.join(seat_dir, *IDB_DIR)


# ---- state, checkpoints -------------------------------------------------------------------------------------------------------

def load_state(path):
    """None when absent (bootstrap); the dict when readable; Skip when present but unreadable (no staging)."""
    if not os.path.exists(path):
        return None
    try:
        j = jread(path)
        if not isinstance(j, dict) or j.get('version') != STATE_VERSION or not isinstance(j.get('pins'), dict) \
                or not all(isinstance(v, bool) for v in j['pins'].values()):
            raise ValueError('unknown shape')
        return j
    except (OSError, ValueError) as e:
        raise Skip('the sidebar state file is unreadable (%s)' % e)


def departure_changes(view, base_pins, cur_pins, state_pins):
    """{cli: bool} a departure observed, per cli ONCE across all its copies (S77). Only mapped copies count, so a vanished record is never a
    removal and a replacement copy (not in the baseline) is never one. Pinned now where it was not in the baseline: pin. A copy pinned in the
    baseline and now unpinned, with no copy pinned: unpin. A cli unchanged since the baseline is no evidence (it must not undo another seat's
    change); it is recorded only when the state has no entry for it yet."""
    out = {}
    for cli in view.by_cli:
        sids = view.sids(cli)
        now, was = bool(sids & cur_pins), bool(sids & base_pins)
        if now and (not was or cli not in state_pins):
            out[cli] = True
        elif was and not now:
            out[cli] = False
    return out


def check_departure(chk, pins):
    """None when the checkpoint can be read against, else why the seat contributes nothing."""
    base = chk.get('baseline') if isinstance(chk, dict) else None
    if not isinstance(base, dict) or base.get('valid') is not True or not _str_list(base.get('pins')) or not isinstance(base.get('manifest'), dict):
        return 'no valid baseline (a baseline is valid only after a successful install)'
    inst = chk.get('installed')
    created = chk.get('created')
    if not isinstance(inst, dict) or not isinstance(inst.get('created'), dict) or not isinstance(created, dict):
        return 'no record of what was installed'
    if created != inst['created']:
        return 'its sidebar databases were recreated since the last switch in'
    for k in ('ls', 'idb'):
        if not isinstance(base['manifest'].get(k), int) or pins.manifest[k] < base['manifest'][k]:
            return 'its sidebar databases were recreated since the last switch in'
    return None


# ---- the plan ---------------------------------------------------------------------------------------------------------------

class Plan:
    def __init__(self):
        self.state = None            # the proposed global state (dict), or None
        self.consumed = []           # [(seat, sha256)]
        self.new_list = None         # the target's new pin list, or None when the target is unreadable
        self.old_list = None
        self.adds, self.removes = [], []     # (sid, title)
        self.no_copy = 0
        self.unknown = 0
        self.not_synced = []         # lines
        self.skips = []              # reasons staging did not happen
        self.lines = []              # report lines
        self.target_pins = None      # Pins of the target's stash


def compute(seats, views, state, checkpoints, stash_pins, leaving, target, gen):
    """The whole decision, from already-read inputs.
    seats {seat: acct}; views {seat: View}; state dict|None; checkpoints {seat: (obj|None, sha256)}; stash_pins {seat: Pins};
    -> Plan."""
    plan = Plan()
    tview = views[target]
    state_pins = dict(state['pins']) if state else {}
    pins = dict(state_pins)
    order = [s for s in sorted(checkpoints) if s != leaving] + ([leaving] if leaving in checkpoints else [])
    for s in order:
        chk, sha = checkpoints[s]
        plan.consumed.append((s, sha))
        if state is None:
            continue                                       # bootstrap reads the stashes directly, below
        sp = stash_pins.get(s)
        if sp is None or not sp.ok:
            plan.not_synced.append('edits made on %s were not synced: %s; redo them' % (s, sp.why if sp else 'its stash is missing'))
            continue
        why = check_departure(chk, sp)
        if why:
            plan.not_synced.append('edits made on %s were not synced: %s; redo them' % (s, why))
            continue
        ch = departure_changes(views[s], set(chk['baseline']['pins']), set(sp.pins), state_pins)
        pins.update(ch)
        state_pins.update(ch)
    if state is None:                                      # bootstrap: each cli's pin state from every readable stash; pinned wins
        for s in sorted(seats):
            sp = stash_pins.get(s)
            if sp is None or not sp.ok:
                plan.not_synced.append('%s is unreadable (%s): its pins are unknown until it is switched to' % (s, sp.why if sp else 'no stash'))
                continue
            cur = set(sp.pins)
            for cli in views[s].by_cli:          # only pins are recorded: an unpinned cli stays unknown, so a seat that could not be read keeps its pin
                if views[s].sids(cli) & cur:
                    pins[cli] = True
    tp = stash_pins.get(target)
    plan.target_pins = tp
    if tp is None or not tp.ok:
        plan.skips.append('the target seat %s: %s' % (target, tp.why if tp else 'no stash'))
        plan.state = {'version': STATE_VERSION, 'gen': gen, 'pins': pins}
        return plan
    cur = list(tp.pins)
    new = list(cur)
    curset = set(cur)
    for cli, copies in sorted(tview.by_cli.items()):
        if cli in pins:
            want = pins[cli]
            sids = {r.sid for r in copies}
            if want and not (sids & curset):
                new.append(copies[0].sid)
                plan.adds.append((copies[0].sid, copies[0].title))
            elif not want:
                for r in copies:
                    if r.sid in curset:
                        new = [x for x in new if x != r.sid]
                        plan.removes.append((r.sid, r.title))
        else:
            if {r.sid for r in copies} & curset:                     # unknown: the target keeps its own value; a pin is recorded as observed intent (S65)
                pins[cli] = True
                plan.unknown += 1
    plan.no_copy = sum(1 for cli, want in pins.items() if want and cli not in tview.by_cli)
    plan.old_list, plan.new_list = cur, new
    plan.state = {'version': STATE_VERSION, 'gen': gen, 'pins': pins}
    return plan


# ---- locks -------------------------------------------------------------------------------------------------------------------

class Lock:
    """Context manager: a file created with O_CREAT|O_EXCL (O_TEMPORARY where it exists: deleted when the handle closes, even on a kill)."""

    def __init__(self, path, wait=20):
        self.path, self.wait, self.fd = path, wait, None

    def __enter__(self):
        end = time.time() + self.wait
        while True:
            try:
                self.fd = os.open(self.path, os.O_CREAT | os.O_EXCL | os.O_WRONLY | getattr(os, 'O_TEMPORARY', 0))
                return self
            except FileExistsError:
                if time.time() >= end:
                    raise Skip('another sidebar sync is running')
                time.sleep(0.5)
            except OSError as e:
                raise Skip('cannot take the sidebar sync lock (%s)' % e)

    def __exit__(self, *a):
        os.close(self.fd)
        if not hasattr(os, 'O_TEMPORARY'):
            try:
                os.unlink(self.path)
            except OSError:
                pass


class HistLock:
    """.sync-history.lock opened like sync-app-history.ps1 does ([IO.File]::Open ... FileShare.None) so no history sync writes records while
    they are read. Windows only; elsewhere a no-op."""

    def __init__(self, path, wait=20):
        self.path, self.wait, self.h = path, wait, None

    def __enter__(self):
        if os.name != 'nt':
            return self
        import ctypes
        k = ctypes.windll.kernel32
        k.CreateFileW.restype = ctypes.c_void_p
        end = time.time() + self.wait
        while True:
            h = k.CreateFileW(self.path, 0xC0000000, 0, None, 4, 0, None)      # GENERIC_READ|WRITE, no sharing, OPEN_ALWAYS
            if h not in (None, ctypes.c_void_p(-1).value):
                self.h = h
                return self
            if time.time() >= end:
                raise Skip('a history sync is running (its records are not read while it writes)')
            time.sleep(1)

    def __exit__(self, *a):
        if self.h:
            import ctypes
            ctypes.windll.kernel32.CloseHandle(ctypes.c_void_p(self.h))


# ---- inputs from disk ---------------------------------------------------------------------------------------------------------

def gather(seats_root, app_dir, seats, target, bootstrap, extra=None):
    """views, stash pins and checkpoints. Pins and records are read only for the seats the decision needs: the target and every seat with a
    pending departure, or every seat when there is no state yet (bootstrap). `extra` = {seat: (ls_dir, idb_dir)} replaces a seat's stash
    dirs (dry run's live snapshot)."""
    views, stash, chks = {}, {}, {}
    for s in seats:
        d = os.path.join(seats_root, s)
        cp = os.path.join(d, DEPARTURE)
        if os.path.exists(cp):
            try:
                chks[s] = (jread(cp), sha256_file(cp))
            except (OSError, ValueError):
                chks[s] = (None, sha256_file(cp))
    for s, acct in seats.items():
        if bootstrap or s == target or s in chks or s in (extra or {}):
            views[s] = read_view(app_dir, acct)
            stash[s] = read_pins(*((extra or {}).get(s) or seat_dirs(os.path.join(seats_root, s))))
    return views, stash, chks


def new_config_bytes(app_dir, pins):
    """-> None when the config's list already holds these pins, else (sha256 of the config read, new file bytes). Skip when the file's
    shape cannot be verified (it must round-trip byte for byte through json with indent 2)."""
    p = os.path.join(app_dir, 'claude_desktop_config.json')
    try:
        raw = open(p, 'rb').read()
        cfg = json.loads(raw.decode('utf-8'))
        if json.dumps(cfg, indent=2, ensure_ascii=False).encode('utf-8') != raw:
            raise ValueError('formatting not reproducible')
        prefs = cfg['preferences']['epitaxyPrefs']
        cur = prefs[CFG_PIN]
        if not _str_list(cur):
            raise ValueError('pin list has an unknown shape')
    except (OSError, ValueError, KeyError, TypeError) as e:
        raise Skip('config not changed (%s)' % e)
    if set(cur) == set(pins):
        return None
    prefs[CFG_PIN] = list(pins)
    return hashlib.sha256(raw).hexdigest(), json.dumps(cfg, indent=2, ensure_ascii=False).encode('utf-8')


def _title_lines(prefix, items):
    return ['  %s %s (%s)' % (prefix, t, s) for s, t in items]


def report_text(plan, target, leaving, dry=False):
    out = ['sidebar pins: %s -> %s%s' % (leaving or '?', target, ' (dry run)' if dry else '')]
    if plan.new_list is not None:
        out.append('pin changes for %s: %d add, %d remove' % (target, len(plan.adds), len(plan.removes)))
        out += _title_lines('pin', plan.adds) + _title_lines('unpin', plan.removes)
        out.append('no copy on %s (pinned at the seat\'s next activation): %d' % (target, plan.no_copy))
        out.append('pinned on %s, unknown elsewhere (kept, recorded): %d' % (target, plan.unknown))
    for s in plan.skips:
        out.append('skipped: ' + s)
    for s in plan.not_synced:
        out.append('not synced: ' + s)
    out += plan.lines
    return '\n'.join(out) + '\n'


# ---- stage -------------------------------------------------------------------------------------------------------------------

def stage_databases(seats_root, target, gdir, new_list, old_list):
    """Copy the target's two sidebar dirs into the gen dir and write the new pin list into the COPIES. Returns the manifest numbers; on any
    failure removes what it made and raises Skip."""
    src = os.path.join(seats_root, target)
    made = []
    try:
        for rel in (LS_DIR[0], IDB_DIR[0]):
            dst = os.path.join(gdir, rel)
            shutil.copytree(os.path.join(src, rel), dst)
            made.append(dst)
        ls_dir, idb_dir = (os.path.join(gdir, *LS_DIR), os.path.join(gdir, *IDB_DIR))
        ts = now_ms()
        lj, _ = read_ls_pins(ls_dir)
        lj['value'] = list(new_list)
        lj['timestamp'] = ts
        _, ik, iv, _ = read_idb_pins(idb_dir)
        ij = json.loads(L.idb_json(iv))
        ij['state']['starredIds'] = list(new_list)
        ij['updatedAt'] = ts
        new_iv = L.idb_replace(iv, jdump(ij))
        L.append_batch(ls_dir, [(L.ls_key(LS_PIN_NAME), L.ls_encode(jdump(lj)))])
        L.append_batch(idb_dir, [(ik, new_iv)])
        back = read_pins(ls_dir, idb_dir)
        if not back.ok or back.pins != list(new_list):
            raise L.LdbError('the staged stores do not read back as written (%s)' % (back.why or 'differs'))
        return back.manifest
    except (L.LdbError, OSError, ValueError, KeyError, TypeError) as e:
        for d in made:
            shutil.rmtree(d, ignore_errors=True)
        raise Skip('staging refused (%s)' % e)


def baseline_obj(gen, pins, manifest):
    return {'valid': True, 'gen': gen, 'pins': list(pins), 'manifest': manifest}


def run_stage(a):
    seats_root, app_dir, gen = a.seats, a.app, a.gen
    gdir = os.path.join(seats_root, WORK, gen)
    os.makedirs(gdir, exist_ok=True)
    res = {'status': 'skipped', 'n': 0, 'reason': ''}
    plan = None
    try:
        seats = list_seats(seats_root)
        if a.target not in seats:
            raise Skip('%s is not a seat with an owner-uuid.txt' % a.target)
        with Lock(os.path.join(seats_root, SYNC_LOCK)), HistLock(os.path.join(seats_root, HIST_LOCK)):
            state = load_state(os.path.join(seats_root, STATE))
            views, stash, chks = gather(seats_root, app_dir, seats, a.target, state is None)
            plan = compute(seats, views, state, chks, stash, a.leaving, a.target, gen)
            write_text(os.path.join(gdir, 'state.json'), jdump(plan.state))
            write_text(os.path.join(gdir, 'consumed.txt'), ''.join('%s\t%s\n' % c for c in plan.consumed))
            tp = plan.target_pins
            if tp and tp.ok:
                write_text(os.path.join(gdir, 'baseline-stash.json'), jdump(baseline_obj(gen, tp.pins, tp.manifest)))
            else:
                write_text(os.path.join(gdir, 'baseline-stash.json'), jdump({'valid': False}))
            n = len(plan.adds) + len(plan.removes)
            if plan.new_list is not None:
                changed = set(plan.new_list) != set(plan.old_list)
                final_pair, final_list, final_base = 'stash', plan.old_list, None
                if changed:
                    try:
                        man = stage_databases(seats_root, a.target, gdir, plan.new_list, plan.old_list)
                        write_text(os.path.join(gdir, 'baseline.json'), jdump(baseline_obj(gen, plan.new_list, man)))
                        final_pair, final_list = 'staged', plan.new_list
                    except Skip as e:
                        plan.skips.append(str(e))
                        n = 0
                try:
                    cfg = new_config_bytes(app_dir, final_list)
                    if cfg:
                        write_text(os.path.join(gdir, 'config.json'), jdump({'sha256': cfg[0], 'pair': final_pair, 'b64': base64.b64encode(cfg[1]).decode('ascii')}))
                except Skip as e:
                    plan.lines.append(str(e))
            if plan.skips:
                res = {'status': 'skipped', 'n': 0, 'reason': plan.skips[0]}
            else:
                res = {'status': 'synced' if n else 'nothing', 'n': n, 'reason': ''}
    except Skip as e:
        res = {'status': 'skipped', 'n': 0, 'reason': str(e)}
        for f in ('state.json', 'consumed.txt', 'baseline.json', 'baseline-stash.json', 'config.json'):
            try:
                os.unlink(os.path.join(gdir, f))
            except OSError:
                pass
        for rel in (LS_DIR[0], IDB_DIR[0]):
            shutil.rmtree(os.path.join(gdir, rel), ignore_errors=True)
        if plan is None:
            plan = Plan()
        plan.skips.append(str(e))
    text = report_text(plan, a.target, a.leaving) if plan else ''
    write_text(os.path.join(gdir, 'report.txt'), text)
    write_text(os.path.join(gdir, 'result.json'), jdump(res))
    print(summary_line(res, os.path.join(gdir, 'report.txt')))
    return 0


def summary_line(res, report):
    if res['status'] == 'synced':
        return 'Sidebar: synced %d pins.' % res['n']
    if res['status'] == 'nothing':
        return 'Sidebar: nothing to sync.'
    return 'Sidebar: skipped (%s) - see %s' % (res['reason'], report)


# ---- dry run -------------------------------------------------------------------------------------------------------------------

def snapshot_live(app_dir, dest):
    """Copy the live app's two leveldb dirs (the app may be open: LOCK and other busy files are skipped)."""
    out = []
    for rel in (LS_DIR, IDB_DIR):
        src = os.path.join(app_dir, *rel)
        dst = os.path.join(dest, *rel)
        shutil.copytree(src, dst, ignore=shutil.ignore_patterns('LOCK'), ignore_dangling_symlinks=True)
        out.append(dst)
    return out[0], out[1]


def live_account(app_dir):
    try:
        return jread(os.path.join(app_dir, 'config.json')).get('lastKnownAccountUuid') or ''
    except (OSError, ValueError, AttributeError):
        return ''


def live_created(app_dir):
    """The live leveldb dirs' creation times (Windows file time as an int), what the rotator records in a departure checkpoint."""
    def ft(p):
        st = os.stat(p)
        return int(getattr(st, 'st_birthtime_ns', st.st_ctime_ns) // 100 + 116444736000000000)
    return {k: ft(os.path.join(app_dir, *rel)) for k, rel in (('ls', LS_DIR), ('idb', IDB_DIR))}


def run_dry(a):
    seats = list_seats(a.seats)
    if a.target not in seats:
        print('dry run: %s is not a seat with an owner-uuid.txt' % a.target)
        return 1
    uuid = live_account(a.app)
    leaving = a.leaving or next((s for s, u in seats.items() if u == uuid), '')
    tmp = tempfile.mkdtemp(prefix='sidebar-dry-')
    try:
        if leaving == a.target:
            print('dry run: %s is the seat the app is on: a switch to it stages nothing' % a.target)
            return 0
        extra = {}
        if leaving and not a.leaving_stash:
            try:
                extra[leaving] = snapshot_live(a.app, tmp)
            except (OSError, shutil.Error) as e:
                print('dry run: the live databases could not be copied (%s): the departure is not read' % e)
        with HistLock(os.path.join(a.seats, HIST_LOCK), wait=5):
            state = load_state(os.path.join(a.seats, STATE))
            views, stash, chks = gather(a.seats, a.app, seats, a.target, state is None, extra=extra)
            if leaving in extra:        # the checkpoint the rotator would write now: its pending baseline if any, else the seat's own
                sd = os.path.join(a.seats, leaving)
                try:
                    pend = chks.get(leaving, (None, ''))[0]
                    base = pend['baseline'] if isinstance(pend, dict) and 'baseline' in pend else jread(os.path.join(sd, BASELINE))
                    chks[leaving] = ({'baseline': base, 'installed': jread(os.path.join(sd, INSTALLED)), 'created': live_created(a.app)}, 'dry')
                except (OSError, ValueError, KeyError):
                    chks[leaving] = (None, 'dry')
            plan = compute(seats, views, state, chks, stash, leaving, a.target, 'dry')
            sys.stdout.write(report_text(plan, a.target, leaving, dry=True))
            if state is None:
                print('(no sidebar state yet: the first switch reads every seat\'s pins)')
        return 0
    except Skip as e:
        print('dry run skipped: %s' % e)
        return 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


# ---- verify ---------------------------------------------------------------------------------------------------------------------

def app_pids():
    """PIDs of the desktop app by install path (the same two patterns the rotator's Get-AppProcs matches); Windows only."""
    if os.name != 'nt':
        return []
    import ctypes
    from ctypes import wintypes
    k, ps = ctypes.windll.kernel32, ctypes.windll.psapi
    arr = (wintypes.DWORD * 8192)()
    need = wintypes.DWORD()
    if not ps.EnumProcesses(arr, ctypes.sizeof(arr), ctypes.byref(need)):
        return []
    out = []
    for pid in arr[:need.value // 4]:
        h = k.OpenProcess(0x1000, False, pid)
        if not h:
            continue
        try:
            buf = ctypes.create_unicode_buffer(1024)
            n = wintypes.DWORD(1024)
            if k.QueryFullProcessImageNameW(h, 0, buf, ctypes.byref(n)):
                p = buf.value.lower()
                if fnmatch.fnmatch(p, '*\\windowsapps\\claude_*\\app\\claude.exe') or fnmatch.fnmatch(p, '*\\anthropicclaude\\*\\claude.exe'):
                    out.append(pid)
        finally:
            k.CloseHandle(h)
    return out


def _owner_and_gen(a, seats):
    try:
        b = jread(os.path.join(a.seats, a.target, BASELINE))
        g = b.get('gen') if isinstance(b, dict) else None
    except (OSError, ValueError):
        g = None
    return live_account(a.app) == seats.get(a.target) and g == a.gen


def run_verify(a, pids=app_pids, sleep=time.sleep):
    gdir = os.path.join(a.seats, WORK, a.gen)
    out = os.path.join(gdir, 'verify.txt')
    seats = list_seats(a.seats)
    head = ['seat %s' % a.target, 'gen %s' % a.gen]

    def done(body, diffs=None):
        write_text(out, '\n'.join(head + ['differences=%s' % ('-' if diffs is None else diffs)] + body) + '\n')
        try:
            with open(os.path.join(gdir, 'report.txt'), 'a', encoding='utf-8', newline='\n') as f:
                f.write('last check: %s\n' % (body[0] if diffs is None else '%d differences (%s)' % (diffs, '; '.join(body))))
        except OSError:
            pass
        return 0

    end = time.time() + a.wait
    while not pids():
        if time.time() >= end:
            return done(['the app did not start within %d s' % a.wait])
        sleep(5)
    sleep(a.settle)
    if not _owner_and_gen(a, seats):
        return done(['superseded: the app is no longer on this seat\'s login from this switch'])
    tmp = tempfile.mkdtemp(prefix='sidebar-verify-')
    try:
        ls, idb = snapshot_live(a.app, tmp)
        if not _owner_and_gen(a, seats):
            return done(['superseded: the app is no longer on this seat\'s login from this switch'])
        base = set(jread(os.path.join(a.seats, a.target, BASELINE))['pins'])
        lines, diffs = [], 0
        for name, fn in (('Local Storage', lambda: read_ls_pins(ls)[0]['value']), ('IndexedDB', lambda: read_idb_pins(idb)[0]['state']['starredIds']),
                         ('config', lambda: jread(os.path.join(a.app, 'claude_desktop_config.json'))['preferences']['epitaxyPrefs'][CFG_PIN])):
            try:
                got = set(fn())
                ok = got == base
            except (L.LdbError, OSError, ValueError, KeyError, TypeError):
                ok, got = False, None
            if not ok:
                diffs += 1
            lines.append('%s: %s' % (name, 'OK' if ok else 'DIFFERS (app revert or an edit within %d s)' % a.settle))
        return done(lines, diffs)
    except (OSError, ValueError, KeyError, L.LdbError, shutil.Error) as e:
        return done(['could not check (%s)' % e])
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


# ---- forget ---------------------------------------------------------------------------------------------------------------------

def run_forget(a):
    seats = list_seats(a.seats)
    if a.forget not in seats:
        print('forget: %s is not a seat' % a.forget)
        return 1
    d = os.path.join(a.seats, a.forget)
    write_text(os.path.join(d, BASELINE), jdump({'valid': False}))
    try:
        os.unlink(os.path.join(d, DEPARTURE))
    except FileNotFoundError:
        pass
    print('forgot the sidebar baseline of seat %s (its next departure contributes nothing; its pins sync again after the next switch in)' % a.forget)
    return 0


# ---- journey helpers (test-sidebar-sync-journey.ps1; read-only) --------------------------------------------------------------------

def run_journey(a):
    """--journey pick --leaving C --target D: JSON {pick, nocopy}: a session with a copy on both seats, unpinned on both (pick), and one pinned on
    the leaving seat with no copy on the target (nocopy). --journey stores --target SEAT --cli CLI: JSON, per pin store of the LIVE app (read from a
    snapshot copy), whether that session is pinned there."""
    seats = list_seats(a.seats)
    tmp = tempfile.mkdtemp(prefix='sidebar-journey-')
    try:
        if a.journey == 'pick':
            def seat_view(s, live):
                v = read_view(a.app, seats[s])
                ls, idb = snapshot_live(a.app, tmp) if live else seat_dirs(os.path.join(a.seats, s))
                return v, read_pins(ls, idb)
            lv, lp = seat_view(a.leaving, True)
            tv, tp = seat_view(a.target, False)
            out = {'pick': None, 'nocopy': None}
            if lp.ok and tp.ok:
                lset, tset = set(lp.pins), set(tp.pins)
                for cli, copies in sorted(lv.by_cli.items(), key=lambda kv: -max(r.last for r in kv[1])):
                    pinned_l = bool(lv.sids(cli) & lset)
                    if cli in tv.by_cli and not pinned_l and not (tv.sids(cli) & tset) and out['pick'] is None:
                        out['pick'] = {'cli': cli, 'title': copies[0].title}
                    if cli not in tv.by_cli and pinned_l and out['nocopy'] is None:
                        out['nocopy'] = {'cli': cli, 'title': copies[0].title}
            print(json.dumps(out))
            return 0
        seat = next((s for s, u in seats.items() if u == live_account(a.app)), '')
        v = read_view(a.app, seats[seat]) if seat else View({})
        ls, idb = snapshot_live(a.app, tmp)
        sids = v.sids(a.cli)
        res = {'seat': seat}
        for name, fn in (('Local Storage', lambda: read_ls_pins(ls)[0]['value']), ('IndexedDB', lambda: read_idb_pins(idb)[0]['state']['starredIds']),
                         ('config', lambda: jread(os.path.join(a.app, 'claude_desktop_config.json'))['preferences']['epitaxyPrefs'][CFG_PIN])):
            try:
                res[name] = bool(sids & set(fn()))
            except (L.LdbError, OSError, ValueError, KeyError, TypeError):
                res[name] = None
        print(json.dumps(res))
        return 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


# ---- main -------------------------------------------------------------------------------------------------------------------------

def main(argv=None):
    p = argparse.ArgumentParser(prog='sidebar-sync.py')
    g = p.add_mutually_exclusive_group(required=True)
    g.add_argument('--stage', action='store_true')
    g.add_argument('--verify', action='store_true')
    g.add_argument('--dry-run', action='store_true')
    g.add_argument('--forget', metavar='SEAT')
    g.add_argument('--journey', choices=('pick', 'stores'), help='read-only helpers for test-sidebar-sync-journey.ps1')
    p.add_argument('--leaving', default='')
    p.add_argument('--target', default='')
    p.add_argument('--gen', default='')
    p.add_argument('--root', help='sandbox root: seats in <root>\\seats, the app folder in <root>\\app')
    p.add_argument('--seats', help='seat root (default ~\\.claude-app-seats)')
    p.add_argument('--app', help='app data folder (default %%APPDATA%%\\Claude)')
    p.add_argument('--settle', type=int, default=75, help='verify: seconds after the app starts')
    p.add_argument('--wait', type=int, default=1800, help='verify: seconds to wait for the app to start')
    p.add_argument('--cli', default='')
    p.add_argument('--leaving-stash', action='store_true', help='dry run: read the leaving seat from its stash, not a live snapshot')
    a = p.parse_args(argv)
    for st in (sys.stdout, sys.stderr):
        try:
            st.reconfigure(encoding='utf-8', errors='replace')
        except (AttributeError, ValueError):
            pass
    if a.root:
        a.seats, a.app = a.seats or os.path.join(a.root, 'seats'), a.app or os.path.join(a.root, 'app')
    a.seats = a.seats or os.path.join(os.path.expanduser('~'), '.claude-app-seats')
    a.app = a.app or os.path.join(os.environ.get('APPDATA', ''), 'Claude')
    if (a.stage or a.verify) and not (a.gen and a.target):
        p.error('--stage/--verify need --gen and --target')
    if a.stage and not a.leaving:
        p.error('--stage needs --leaving')
    if a.dry_run and not a.target:
        p.error('--dry-run needs --target')
    try:
        if a.stage:
            return run_stage(a)
        if a.verify:
            return run_verify(a)
        if a.dry_run:
            return run_dry(a)
        if a.journey:
            return run_journey(a)
        return run_forget(a)
    except Exception as e:  # shortcut: the rotator treats any nonzero exit as "ran without a result"; the cause goes to stderr
        sys.stderr.write('sidebar-sync: %s: %s\n' % (type(e).__name__, e))
        return 1


if __name__ == '__main__':
    sys.exit(main())
