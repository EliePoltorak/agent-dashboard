"""sidebar-sync.py: carry the Claude desktop app's sidebar PINS across app seats at seat-switch time (agent-dashboard issue #10, PR 1).

Called by claude-app-rotator.ps1 (which holds the seat lock with the app closed and owns every durable step):

  --stage   --leaving <seat> --target <seat> --gen <gen>   read the seats, work out the pins the target should have, and build the
                                                          staging copy under <seats>\\.sidebar-sync-work\\<gen>\\ (READ-ONLY elsewhere)
  --verify  --gen <gen> --target <seat>                   after the app starts: compare the three pin stores with the baseline; report only
  --dry-run --target <seat>                               print what a switch to <seat> would change; writes nothing, works with the app open
  --forget  <seat>                                        drop a seat's baseline and its departure marker (README reset steps)

The pin list lives in THREE places the app reads: IndexedDB `store:pin-state:dframe-starred-code` (`starredIds`), Local Storage
`LSS-persisted.starred-local-code-sessions` and claude_desktop_config.json `preferences.epitaxyPrefs.starred-local-code-sessions`. Session
ids differ per seat, so pins are mapped through `cliSessionId`. The design is in the plan (wiki handoffs, sidebar-sync-issue10-plan).

Python's own writes: the global state file (ONE atomic replace, committed after the decision and BEFORE any staged copy is built) and <gen>\\ only.
Every profile, baseline, marker and config write is the rotator's. Stdlib only. Run as `py -3 -I sidebar-sync.py ...`.

Departure evidence: each seat has ONE marker `sidebar-departure.json` = {dep, at, baseline, created}, replaced at every departure (never appended). The
state file records, per seat, the last departure merged or dismissed {dep, base, observed}; a marker is merged once (its `dep` is then in the state), against
`observed` when its baseline is the lineage already merged, else against the baseline's own pins.
"""
import argparse
import base64
import copy
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
BASELINE, DEPARTURE = 'sidebar-baseline.json', 'sidebar-departure.json'
LS_DIR = ('Local Storage', 'leveldb')
IDB_DIR = ('IndexedDB', 'https_claude.ai_0.indexeddb.leveldb')
LS_PIN_NAME = 'LSS-persisted.starred-local-code-sessions'
CFG_PIN = 'starred-local-code-sessions'
STATE_VERSION = 2


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
        self.ls_json = self.idb_obj = self.idb_key = self.idb_raw = None      # what a fresh read saw, so staging need not read the same databases again


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
        idb, ik, iraw, isnap = read_idb_pins(idb_dir)
    except (L.LdbError, OSError, ValueError) as e:
        return Pins(False, 'pin stores unreadable (%s)' % e)
    if set(ls['value']) != set(idb['state']['starredIds']):
        return Pins(False, 'Local Storage and IndexedDB disagree about the pins')
    p = Pins(True, '', list(ls['value']), {'ls': lsnap.manifest.number, 'idb': isnap.manifest.number})
    p.ls_json, p.idb_obj, p.idb_key, p.idb_raw = ls, idb, ik, iraw
    return p


def seat_dirs(seat_dir):
    return os.path.join(seat_dir, *LS_DIR), os.path.join(seat_dir, *IDB_DIR)


# ---- state, markers ---------------------------------------------------------------------------------------------------------

def empty_state():
    return {'version': STATE_VERSION, 'gen': '', 'pins': {}, 'seats': {}}


def load_state(path):
    """The empty state when the file is absent; the dict when readable; Skip when present but unreadable or of another version (no staging)."""
    if not os.path.exists(path):
        return empty_state()
    try:
        j = jread(path)
        if not isinstance(j, dict) or j.get('version') != STATE_VERSION or not isinstance(j.get('pins'), dict) or not isinstance(j.get('seats'), dict) \
                or not all(isinstance(v, bool) for v in j['pins'].values()) or not all(isinstance(v, dict) for v in j['seats'].values()):
            raise ValueError('unknown shape')
        return j
    except (OSError, ValueError) as e:
        raise Skip('the sidebar state file is unreadable (%s)' % e)


def write_state(path, state):
    """The commit: the whole state in one atomic replace (temp sibling, then os.replace). Skip when it cannot be written (nothing is staged then)."""
    tmp = path + '.tmp'
    try:
        write_text(tmp, jdump(state))
        os.replace(tmp, path)
    except OSError as e:
        raise Skip('the sidebar state could not be written (%s)' % e)


def load_marker(path):
    """A seat's departure marker as a dict with a `dep`; an unreadable or ill-shaped one becomes {dep: 'unreadable:<sha>', bad: True}."""
    try:
        j = jread(path)
        if isinstance(j, dict) and isinstance(j.get('dep'), str) and j['dep']:
            return j
    except (OSError, ValueError):
        pass
    try:
        sha = sha256_file(path)
    except OSError:
        sha = '?'
    return {'dep': 'unreadable:' + sha, 'bad': True}


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


def check_marker(m, pins):
    """None when the marker can be read against the seat's stash, else why the departure cannot be merged. The baseline is only as good as its `created`: it
    must equal the creation times of the live databases at the departure (so it belongs to THIS activation's install)."""
    if m.get('bad'):
        return 'its departure record is unreadable'
    base = m.get('baseline')
    if not isinstance(base, dict) or not _str_list(base.get('pins')) or not isinstance(base.get('manifest'), dict) or not isinstance(base.get('gen'), str):
        return 'it has no baseline'
    inst, created = base.get('created'), m.get('created')
    if not isinstance(inst, dict) or not isinstance(inst.get('ls'), int) or not isinstance(inst.get('idb'), int) or not isinstance(created, dict):
        return 'no record of what was installed'
    if created != inst:
        return 'its sidebar databases were recreated since the last switch in'
    for k in ('ls', 'idb'):
        if not isinstance(base['manifest'].get(k), int) or pins.manifest[k] < base['manifest'][k]:
            return 'its sidebar databases were recreated since the last switch in'
    return None


# ---- the plan ---------------------------------------------------------------------------------------------------------------

class Plan:
    def __init__(self):
        self.state = None            # the new global state (dict): committed by run_stage right after the decision
        self.new_list = None         # the target's new pin list, or None when the target is unreadable
        self.old_list = None
        self.adds, self.removes = [], []     # (sid, title)
        self.no_copy = 0
        self.no_copy_items = []      # [(cli, title)] pinned elsewhere, no record on the target
        self.unknown = 0
        self.not_synced = []         # lines
        self.not_synced_seats = []   # seats whose departure was not read
        self.skips = []              # reasons staging did not happen
        self.lines = []              # report lines
        self.target_pins = None      # Pins of the target's stash


def compute(seats, views, state, markers, stash_pins, target, gen):
    """The whole decision, from already-read inputs.
    seats {seat: acct}; views {seat: View}; state dict (empty_state() when there is none); markers {seat: marker dict}; stash_pins {seat: Pins}; -> Plan.
    Every marker whose `dep` differs from the state's record of that seat is merged (or dismissed) ONCE, oldest `at` first, and recorded in plan.state.seats."""
    plan = Plan()
    tview = views[target]
    pins = dict(state['pins'])
    merged = {k: dict(v) for k, v in state['seats'].items()}
    pending = sorted(((m.get('at') if isinstance(m.get('at'), (int, float)) else 0, s, m) for s, m in markers.items() if merged.get(s, {}).get('dep') != m['dep']),
                     key=lambda t: (t[0], t[1]))
    for at, s, m in pending:
        sp = stash_pins.get(s)
        why = (sp.why if sp else 'its stash was not read') if (sp is None or not sp.ok) else check_marker(m, sp)
        if why:
            merged[s] = {'dep': m['dep']}                   # dismissed: it can never become valid, so it is not looked at again
            if why == 'it has no baseline' and s not in state['seats']:
                plan.lines.append('first departure of %s: it has no baseline yet (it was never entered through this sync), so there is nothing to compare' % s)
            else:
                plan.not_synced_seats.append(s)
                plan.not_synced.append('edits made on %s were not synced: %s; redo them' % (s, why))
            continue
        base = m['baseline']
        prev = merged.get(s, {})
        base_pins = set(prev['observed']) if prev.get('base') == base['gen'] and isinstance(prev.get('observed'), list) else set(base['pins'])
        ch = departure_changes(views[s], base_pins, set(sp.pins), pins)
        pins.update(ch)
        merged[s] = {'dep': m['dep'], 'base': base['gen'], 'observed': list(sp.pins)}
    tp = stash_pins.get(target)
    plan.target_pins = tp
    if tp is None or not tp.ok:
        plan.skips.append('the target seat %s: %s' % (target, tp.why if tp else 'no stash'))
        plan.state = {'version': STATE_VERSION, 'gen': gen, 'pins': pins, 'seats': merged}
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
    titles = {cli: copies[0].title for v in views.values() for cli, copies in v.by_cli.items()}
    plan.no_copy_items = sorted((cli, titles.get(cli, cli)) for cli, want in pins.items() if want and cli not in tview.by_cli)
    plan.no_copy = len(plan.no_copy_items)
    plan.old_list, plan.new_list = cur, new
    plan.state = {'version': STATE_VERSION, 'gen': gen, 'pins': pins, 'seats': merged}
    return plan


# ---- locks -------------------------------------------------------------------------------------------------------------------

class Lock:
    """Context manager: a file created with O_CREAT|O_EXCL (O_TEMPORARY where it exists: deleted when the handle closes, even on a kill)."""

    def __init__(self, path, wait=20, why='another sidebar sync is running'):
        self.path, self.wait, self.fd, self.why = path, wait, None, why

    def __enter__(self):
        end = time.time() + self.wait
        while True:
            try:
                self.fd = os.open(self.path, os.O_CREAT | os.O_EXCL | os.O_WRONLY | getattr(os, 'O_TEMPORARY', 0))
                return self
            except FileExistsError:
                if time.time() >= end:
                    raise Skip(self.why)
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

def load_markers(seats_root, seats):
    out = {}
    for s in seats:
        cp = os.path.join(seats_root, s, DEPARTURE)
        if os.path.exists(cp):
            out[s] = load_marker(cp)
    return out


def gather(seats_root, app_dir, seats, target, state, markers, leaving='', known=None, extra=None):
    """views and stash pins, read only for the seats the decision needs: the target, every seat with a marker not yet merged, and (records only, for the report's
    titles) the leaving seat. `extra` = {seat: (ls_dir, idb_dir)} replaces a seat's stash dirs (dry run's live snapshot). `known` = {seat: Pins} already read by
    this stage (the target's, read first): not read again."""
    merged = state['seats']
    pending = {s for s, m in markers.items() if merged.get(s, {}).get('dep') != m['dep']}
    views, stash = {}, {}
    for s, acct in seats.items():
        need = s == target or s in pending or s in (extra or {})
        if need or s == leaving:
            views[s] = read_view(app_dir, acct)
        if need:
            stash[s] = (known or {}).get(s) or read_pins(*((extra or {}).get(s) or seat_dirs(os.path.join(seats_root, s))))
    return views, stash


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
        out.append('no copy on %s (pinned once this seat has a copy): %d' % (target, plan.no_copy))
        out += ['  no copy: %s (%s)' % (t, c) for c, t in plan.no_copy_items]
        out.append('pinned on %s, unknown elsewhere (kept, recorded): %d' % (target, plan.unknown))
    for s in plan.skips:
        out.append('skipped: ' + s)
    for s in plan.not_synced:
        out.append('not synced: ' + s)
    out += plan.lines
    return '\n'.join(out) + '\n'


# ---- stage -------------------------------------------------------------------------------------------------------------------

def stage_databases(seats_root, target, gdir, new_list, old_list, tp=None):
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
        if tp is not None and tp.ls_json is not None and tp.idb_raw is not None:      # the stash was read once, by this stage, and the copy is byte-identical
            lj, ik, iv = copy.deepcopy(tp.ls_json), tp.idb_key, tp.idb_raw
        else:
            lj, _ = read_ls_pins(ls_dir)
            _, ik, iv, _ = read_idb_pins(idb_dir)
        lj['value'] = list(new_list)
        lj['timestamp'] = ts
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
    """What was installed: the rotator adds `created` (the creation times of the live databases right after the install) and writes it once."""
    return {'gen': gen, 'pins': list(pins), 'manifest': manifest}


def prepare_config(app_dir, pins, gdir, name, pair):
    """The shared config's outcome for a pin list: 'match', 'prepared' (<gen>\\<name> written, naming `pair`) or 'refused: <why>'. Any older file of that name goes."""
    path = os.path.join(gdir, name)
    try:
        os.unlink(path)
    except OSError:
        pass
    try:
        cfg = new_config_bytes(app_dir, pins)
    except Skip as e:
        return 'refused: %s' % e
    if cfg is None:
        return 'match'
    write_text(path, jdump({'sha256': cfg[0], 'pair': pair, 'b64': base64.b64encode(cfg[1]).decode('ascii')}))
    return 'prepared'


def run_stage(a):
    seats_root, app_dir, gen = a.seats, a.app, a.gen
    gdir = os.path.join(seats_root, WORK, gen)
    os.makedirs(gdir, exist_ok=True)
    if os.path.exists(os.path.join(gdir, 'result.json')):          # a generation is used by one stage only (the rotator allocates it unique)
        sys.stderr.write('sidebar-sync: generation %s already has a result\n' % gen)
        return 1
    res = {'status': 'skipped', 'n': 0, 'reason': ''}
    plan = None
    stash_cfg = ('refused: the target seat was not read', 'stash')
    config_outcome, config_pair = stash_cfg           # the shared config's outcome for the pair that is to be installed
    try:
        seats = list_seats(seats_root)
        if a.target not in seats:
            raise Skip('%s is not a seat with an owner-uuid.txt' % a.target)
        # FIRST, before anything that can Skip, wait or run long: the stash pair's baseline and its config outcome. They need only the target's own pin
        # list (read once here and reused below), no records and no locks, so a stash-pair install gets its baseline whatever happens later, even when
        # this stage is Skipped or killed (the rotator reads stash-result.json for exactly that case).
        tp = read_pins(*seat_dirs(os.path.join(seats_root, a.target)))
        bs = os.path.join(gdir, 'baseline-stash.json')
        if tp.ok:
            write_text(bs, jdump(baseline_obj(gen, tp.pins, tp.manifest)))
        else:
            try:
                os.unlink(bs)
            except OSError:
                pass
        stash_cfg = (prepare_config(app_dir, tp.pins, gdir, 'config-stash.json', 'stash') if tp.ok else 'refused: the target seat was not read', 'stash')
        config_outcome, config_pair = stash_cfg
        write_text(os.path.join(gdir, 'stash-result.json'), jdump({'target': a.target, 'gen': gen, 'config': stash_cfg[0], 'config_pair': 'stash'}))
        with Lock(os.path.join(seats_root, SYNC_LOCK)), HistLock(os.path.join(seats_root, HIST_LOCK)):
            spath = os.path.join(seats_root, STATE)
            state = load_state(spath)
            markers = load_markers(seats_root, seats)
            views, stash = gather(seats_root, app_dir, seats, a.target, state, markers, leaving=a.leaving, known={a.target: tp})
            plan = compute(seats, views, state, markers, stash, a.target, gen)
            write_state(spath, plan.state)          # THE COMMIT: the merged departures and what was read from the target; nothing here depends on the install
            n = len(plan.adds) + len(plan.removes)
            if plan.new_list is not None:
                changed = set(plan.new_list) != set(plan.old_list)
                if changed:
                    try:
                        man = stage_databases(seats_root, a.target, gdir, plan.new_list, plan.old_list, tp)
                        write_text(os.path.join(gdir, 'baseline.json'), jdump(baseline_obj(gen, plan.new_list, man)))
                        config_outcome, config_pair = prepare_config(app_dir, plan.new_list, gdir, 'config.json', 'staged'), 'staged'
                    except Skip as e:
                        plan.skips.append(str(e))
                        n = 0
                if config_outcome.startswith('refused'):
                    plan.lines.append(config_outcome)
            if plan.skips:
                res = {'status': 'skipped', 'n': 0, 'reason': plan.skips[0]}
            else:
                res = {'status': 'synced' if n else 'nothing', 'n': n, 'reason': ''}
    except Skip as e:
        res = {'status': 'skipped', 'n': 0, 'reason': str(e)}
        for f in ('baseline.json', 'config.json'):          # the stash pair's baseline and config stay (they were made first)
            try:
                os.unlink(os.path.join(gdir, f))
            except OSError:
                pass
        for rel in (LS_DIR[0], IDB_DIR[0]):
            shutil.rmtree(os.path.join(gdir, rel), ignore_errors=True)
        config_outcome, config_pair = stash_cfg
        if plan is None:
            plan = Plan()
        plan.skips.append(str(e))
    text = report_text(plan, a.target, a.leaving) if plan else ''
    write_text(os.path.join(gdir, 'report.txt'), text)
    # the rotator installs a staged pair only when this names ITS target, ITS generation and the pair that exists
    res.update({'config': config_outcome, 'config_pair': config_pair, 'not_synced': sorted(set(plan.not_synced_seats)) if plan else []})
    res.update({'target': a.target, 'gen': gen, 'pair': 'staged' if (os.path.isdir(os.path.join(gdir, LS_DIR[0])) and os.path.isdir(os.path.join(gdir, IDB_DIR[0]))
                                                                      and os.path.exists(os.path.join(gdir, 'baseline.json'))) else 'stash'})
    write_text(os.path.join(gdir, 'result.json'), jdump(res))
    print(summary_line(res, os.path.join(gdir, 'report.txt')))
    return 0


def summary_line(res, report):
    ns = res.get('not_synced') or []
    tail = '; edits on %s not synced - see %s' % (', '.join(ns), report) if ns else ''
    if res['status'] == 'synced':
        return 'Sidebar: synced %d pins%s' % (res['n'], tail if tail else '.')
    if res['status'] == 'nothing':
        return 'Sidebar: nothing to sync%s' % (tail if tail else '.')
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
            markers = load_markers(a.seats, seats)
            if leaving in extra:        # the marker the rotator would write at this departure: the seat's baseline as it is now, the live creation times
                try:
                    base = jread(os.path.join(a.seats, leaving, BASELINE))
                except (OSError, ValueError):
                    base = None
                markers[leaving] = {'dep': 'dry-run', 'at': now_ms(), 'baseline': base, 'created': live_created(a.app)}
            views, stash = gather(a.seats, a.app, seats, a.target, state, markers, leaving=leaving, extra=extra)
            plan = compute(seats, views, state, markers, stash, a.target, 'dry')
            sys.stdout.write(report_text(plan, a.target, leaving, dry=True))
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


INSTALL = 'install.json'


def read_install(a):
    '''<gen>/install.json, written by the rotator after the install: {gen, target, pair, pins, created}. It is the identity and the expected pins of THIS
    install, separate from the baseline (whose gen and pins can belong to an older lineage that a stash-pair install continued). None if absent or not ours.'''
    try:
        j = jread(os.path.join(a.seats, WORK, a.gen, INSTALL))
    except (OSError, ValueError):
        return None
    return j if isinstance(j, dict) and j.get('gen') == a.gen and j.get('target') == a.target and isinstance(j.get('pins'), list) else None


def _still_installed(a, seats, inst):
    '''The app is on the target's login AND the baseline on disk is still the one written for this install (a later install rewrites it).'''
    try:
        b = jread(os.path.join(a.seats, a.target, BASELINE))
        same = isinstance(b, dict) and b.get('created') == inst.get('created')
    except (OSError, ValueError):
        same = False
    return same and live_account(a.app) == seats.get(a.target)


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
    inst = read_install(a)
    if not inst:
        return done(['could not check (no install record for this switch)'])
    sleep(a.settle)
    if not _still_installed(a, seats, inst):
        return done(['superseded: the app is no longer on this seat\'s login from this switch'])
    tmp = tempfile.mkdtemp(prefix='sidebar-verify-')
    try:
        ls, idb = snapshot_live(a.app, tmp)
        if not _still_installed(a, seats, inst):
            return done(['superseded: the app is no longer on this seat\'s login from this switch'])
        base = set(inst['pins'])
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
    try:
        with Lock(os.path.join(a.seats, '.seat-write.lock'), wait=0, why='a seat switch, capture or keep-alive holds the seat lock'):
            for f in (BASELINE, DEPARTURE):
                try:
                    os.unlink(os.path.join(d, f))
                except FileNotFoundError:
                    pass
    except Skip as e:
        print('forget refused: %s; try again when it has finished' % e)
        return 1
    print('forgot the sidebar baseline and departure marker of seat %s (its next departure has nothing to compare and contributes nothing; its pins sync again after the next switch in)' % a.forget)
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
