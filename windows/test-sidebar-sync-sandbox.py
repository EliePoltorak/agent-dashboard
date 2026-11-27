"""Sandbox test for sidebar-sync.py on SYNTHETIC seats: no real profile data is read, copied or kept.

  py -3 -I windows/test-sidebar-sync-sandbox.py [--dest DIR] [--keep] [--launch-app]

Builds four seats in a fresh directory <dest>\\<stamp>-<random> made with tempfile.mkdtemp (default C:\\Dev\\Temp\\sidebar-sync-sandbox) with sidebar_ldb's own writer: only the pin keys, the session-record
fields and the config structure the engine needs, with made-up ids and titles (seat A's IndexedDB uses V8 wire version 0x0f, the others 0x10, as on the
real machine). Then: --dry-run, --stage with a departure marker of the live seat, a second --stage over the same marker (no replay), the staged stores re-read against
baseline.json, and every stash checked byte-identical afterwards. The sandbox is deleted when the test passes (--keep keeps it); only that directory is ever removed.

--launch-app (OFF by default; needs the app installed) also opens the staged Local Storage in a second, OFFLINE app instance on a throwaway profile for 30 s
and closes it by its own PID; it is opt-in because it starts the real app binary. Never run --stage against the real seat root; this script only ever
passes its own sandbox as --root.
"""
import argparse
import hashlib
import importlib.util
import json
import os
import random
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import sidebar_ldb as L  # noqa: E402

_spec = importlib.util.spec_from_file_location('sidebar_sync', os.path.join(HERE, 'sidebar-sync.py'))
SS = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(SS)

FAILS = []


def check(name, ok, detail=''):
    print('  %s  %s%s' % ('PASS' if ok else 'FAIL', name, '' if ok else '  ' + str(detail)))
    if not ok:
        FAILS.append(name)


def idle_priority():
    """Owner rule 10e: this entry point and every child it starts (children inherit) run at IDLE priority."""
    if os.name == 'nt':
        import ctypes
        ctypes.windll.kernel32.SetPriorityClass(ctypes.windll.kernel32.GetCurrentProcess(), 0x00000040)


def tree_hash(d):
    h = hashlib.sha256()
    for root, dirs, files in os.walk(d):
        dirs.sort()
        for f in sorted(files):
            p = os.path.join(root, f)
            h.update(os.path.relpath(p, d).encode() + b'\0' + open(p, 'rb').read())
    return h.hexdigest()


def uid(rnd):
    return '%08x-%04x-%04x-%04x-%012x' % (rnd.getrandbits(32), rnd.getrandbits(16), rnd.getrandbits(16), rnd.getrandbits(16), rnd.getrandbits(48))


def write_pin_dbs(ls_dir, idb_dir, pins, wire_version):
    """A Local Storage and an IndexedDB leveldb holding the pin list the way the app does (made-up ids)."""
    ls_val = SS.jdump({'value': pins, 'tabId': 'tab-synthetic', 'timestamp': 1700000000000})
    L.create_db(ls_dir, [(L.ls_key(SS.LS_PIN_NAME), L.ls_encode(ls_val)), (L.ls_key('LSS-persisted.other'), L.ls_encode('{"keep":1}'))])
    idb_val = SS.jdump({'state': {'starredIds': pins}, 'version': 0, 'updatedAt': 1700000000000})
    key = b'\x00\x05\x01\x01\x01\x23' + 'store:pin-state:dframe-starred-code'.encode('utf-16-be')
    val = bytes.fromhex('05ff15fe' + '00' * 12 + 'ff%02x22' % wire_version) + L.uvarint(len(idb_val)) + idb_val.encode()
    L.create_db(idb_dir, [(key, val), (b'\x00\x05\x01\x01\x01\x04abcd', b'x')])


def build(root):
    """-> (seats {name: account}, live seat name, per-seat pin lists)."""
    rnd = random.Random(20261126)
    seats, app = os.path.join(root, 'seats'), os.path.join(root, 'app')
    names = ['A', 'B', 'C', 'D']
    accts = {n: uid(rnd) for n in names}
    org = uid(rnd)
    clis = ['cli-' + uid(rnd) for _ in range(14)]
    wire = {'A': 0x0f, 'B': 0x10, 'C': 0x10, 'D': 0x10}
    pins, recs_by_seat = {}, {}
    for i, n in enumerate(names):
        recs = []
        for k, cli in enumerate(clis):
            if (k + i) % 3 == 0 and k > 3:                       # each seat lacks some sessions the others have
                continue
            sid = 'local_' + uid(rnd)
            recs.append((sid, cli, k))
            d = os.path.join(app, 'claude-code-sessions', accts[n], org)
            os.makedirs(d, exist_ok=True)
            json.dump({'sessionId': sid, 'cliSessionId': cli, 'isArchived': False, 'lastActivityAt': 1700000000000 + k, 'title': 'Synthetic session %d (%s)' % (k, n)}, open(os.path.join(d, sid + '.json'), 'w'))
        recs_by_seat[n] = recs
        pins[n] = [sid for sid, cli, k in recs if k in (0, 1) or (n == 'C' and k in (4, 5))][:4] + ['local_' + uid(rnd)]       # + one foreign pin
        sd = os.path.join(seats, n)
        os.makedirs(sd, exist_ok=True)
        open(os.path.join(sd, 'owner-uuid.txt'), 'w').write(accts[n] + '\n')
        write_pin_dbs(os.path.join(sd, *SS.LS_DIR), os.path.join(sd, *SS.IDB_DIR), pins[n], wire[n])
    live = 'B'
    write_pin_dbs(os.path.join(app, *SS.LS_DIR), os.path.join(app, *SS.IDB_DIR), pins[live], 0x10)
    json.dump({'lastKnownAccountUuid': accts[live]}, open(os.path.join(app, 'config.json'), 'w'))
    cfg = {'preferences': {'epitaxyPrefs': {'starred-local-code-sessions': pins[live], 'unrelated': {'k': 1}}}}
    open(os.path.join(app, 'claude_desktop_config.json'), 'wb').write(json.dumps(cfg, indent=2, ensure_ascii=False).encode('utf-8'))
    return accts, live, pins, recs_by_seat


def main():
    idle_priority()
    ap = argparse.ArgumentParser()
    ap.add_argument('--dest', default=r'C:\Dev\Temp\sidebar-sync-sandbox')
    ap.add_argument('--keep', action='store_true')
    ap.add_argument('--launch-app', action='store_true')
    a = ap.parse_args()
    os.makedirs(a.dest, exist_ok=True)
    root = tempfile.mkdtemp(prefix=time.strftime('%Y%m%d-%H%M%S-'), dir=a.dest)          # a fresh, empty directory that nothing else uses
    seats, app = os.path.join(root, 'seats'), os.path.join(root, 'app')
    print('sandbox (synthetic): ' + root)
    accts, leaving, pins, recs = build(root)
    names = sorted(accts)
    readable = {s: SS.read_pins(*SS.seat_dirs(os.path.join(seats, s))) for s in names}
    check('every synthetic seat is readable, including seat A at V8 wire version 0x0f', all(r.ok for r in readable.values()), {s: r.why for s, r in readable.items()})
    target = 'D'
    tool = os.path.join(HERE, 'sidebar-sync.py')
    ldir = os.path.join(seats, leaving)

    # the live seat's departure: its baseline is what was installed; then the user pinned one more session (cli k=2), which the target has a copy of too
    extra_sid = next(sid for sid, cli, k in recs[leaving] if k == 2)
    base_pins = list(pins[leaving])
    live_pins = base_pins + [extra_sid]
    for dst in (app, ldir):
        for rel in (SS.LS_DIR, SS.IDB_DIR):
            shutil.rmtree(os.path.join(dst, *rel))
        write_pin_dbs(os.path.join(dst, *SS.LS_DIR), os.path.join(dst, *SS.IDB_DIR), live_pins, 0x10)
    cr = SS.live_created(app)
    man = SS.read_pins(*SS.seat_dirs(ldir)).manifest
    baseline = {'gen': 'b-sandbox', 'pins': base_pins, 'manifest': man, 'created': cr}
    json.dump(baseline, open(os.path.join(ldir, SS.BASELINE), 'w'))
    json.dump({'dep': 'dep-1', 'at': 1700000000000, 'baseline': baseline, 'created': cr}, open(os.path.join(ldir, SS.DEPARTURE), 'w'))
    before = {s: tree_hash(os.path.join(seats, s)) for s in names}

    r = subprocess.run([sys.executable, '-I', tool, '--dry-run', '--target', target, '--root', root, '--leaving-stash'], capture_output=True, text=True, encoding='utf-8', errors='replace')
    check('--dry-run runs, reads the pending departure and reports the pin it would add on the target', r.returncode == 0 and 'pin changes for %s: 1 add' % target in r.stdout, r.stdout + r.stderr)
    print(r.stdout)
    check('--dry-run writes no state file', not os.path.exists(os.path.join(seats, SS.STATE)))

    def stage(gen):
        return subprocess.run([sys.executable, '-I', tool, '--stage', '--leaving', leaving, '--target', target, '--gen', gen, '--root', root], capture_output=True, text=True, encoding='utf-8', errors='replace')

    r = stage('g1')
    g = os.path.join(seats, SS.WORK, 'g1')
    res = json.load(open(os.path.join(g, 'result.json')))
    st1 = json.load(open(os.path.join(seats, SS.STATE)))
    check('--stage exits 0, merges the departure, stages the pin on the target', r.returncode == 0 and res['status'] == 'synced' and res['n'] == 1 and res['pair'] == 'staged' and res['not_synced'] == [], r.stdout + r.stderr + str(res))
    check('the state was committed by the stage: version 2, the departure recorded (dep, base, observed)', st1['version'] == 2 and st1['seats'][leaving]['dep'] == 'dep-1' and st1['seats'][leaving]['base'] == 'b-sandbox'
          and sorted(st1['seats'][leaving]['observed']) == sorted(live_pins), str(st1['seats']))
    print(r.stdout.strip())
    back = SS.read_pins(os.path.join(g, *SS.LS_DIR), os.path.join(g, *SS.IDB_DIR))
    base = json.load(open(os.path.join(g, 'baseline.json')))
    check('staged stores re-read: both agree and equal baseline.json', back.ok and back.pins == base['pins'] and base['gen'] == 'g1', back.why)
    check('every pin the target had is still there (nothing dropped) and exactly one was added', set(readable[target].pins) < set(back.pins) and len(back.pins) == len(readable[target].pins) + 1, str(back.pins))

    r = stage('g2')                                                       # the same marker again: it was merged once, never again
    g2 = os.path.join(seats, SS.WORK, 'g2')
    res2 = json.load(open(os.path.join(g2, 'result.json')))
    st2 = json.load(open(os.path.join(seats, SS.STATE)))
    check('a second --stage over the same marker does not replay it: the state is unchanged apart from its gen', r.returncode == 0 and res2['not_synced'] == []
          and {k: v for k, v in st2.items() if k != 'gen'} == {k: v for k, v in st1.items() if k != 'gen'}, r.stdout + r.stderr + str(res2))
    check('stashes are byte-identical after staging (only the gen dirs and the state file are written)', all(tree_hash(os.path.join(seats, s)) == before[s] for s in names), '')

    if a.launch_app:
        launch(root, g, target)
    ok = not FAILS
    print('FAILED: %s' % FAILS if FAILS else 'sandbox test passed')
    if ok and not a.keep:
        shutil.rmtree(root, ignore_errors=True)
    return 0 if ok else 1


def launch(root, gdir, target):
    """Opt-in: the staged (synthetic) Local Storage in a second OFFLINE app instance on a throwaway profile for 30 s, closed by its own PID."""
    launcher = os.path.join(os.environ.get('LOCALAPPDATA', ''), 'AnthropicClaude', 'claude.exe')
    if not os.path.exists(launcher):
        print('  SKIP  --launch-app: the Squirrel launcher was not found')
        return
    prof = os.path.join(root, 'launch-profile')
    shutil.copytree(os.path.join(gdir, 'Local Storage'), os.path.join(prof, 'Local Storage'))
    p = subprocess.Popen([launcher, '--user-data-dir=' + prof, '--proxy-server=http://127.0.0.1:9'], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, close_fds=True)
    try:
        time.sleep(30)
    finally:
        subprocess.run(['taskkill', '/PID', str(p.pid), '/T', '/F'], capture_output=True)      # only the PID this script started (and its own children)
    time.sleep(3)
    try:
        ls = SS.read_ls_pins(os.path.join(prof, *SS.LS_DIR))[0]
        check('the app reopened the staged Local Storage: readable, pin list intact', isinstance(ls['value'], list))
    except (L.LdbError, OSError, ValueError) as e:
        check('the app reopened the staged Local Storage: readable, pin list intact', False, e)


if __name__ == '__main__':
    sys.exit(main())
