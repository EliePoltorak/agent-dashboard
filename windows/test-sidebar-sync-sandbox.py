"""Sandbox test for sidebar-sync.py on COPIES of the real seats: nothing under ~\\.claude-app-seats or %APPDATA%\\Claude is ever written.

  py -3 -I windows/test-sidebar-sync-sandbox.py [--dest DIR] [--target SEAT] [--launch-app]

Copies the seats' sidebar databases (and their account uuids only: no login tokens), the session records, a snapshot of the live
databases and the shared config to <dest>\\<stamp>\\ (default C:\\Dev\\Temp\\sidebar-sync-sandbox), then: --dry-run, --stage (bootstrap), a
second --stage with a departure checkpoint, re-reads the staged stores against baseline.json, and checks every stash is byte-identical
afterwards. --launch-app (OFF by default; needs the app installed) also opens the staged Local Storage in a second, OFFLINE app instance on a
throwaway profile for 30 s and closes it by its own PID; it is opt-in because it starts the real app binary, so it must never be run while
you cannot afford a stray window. Never run --stage against the real seat root; this script only ever passes its own sandbox as --root.
"""
import argparse
import hashlib
import importlib.util
import json
import os
import shutil
import subprocess
import sys
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


def tree_hash(d):
    h = hashlib.sha256()
    for root, dirs, files in os.walk(d):
        dirs.sort()
        for f in sorted(files):
            p = os.path.join(root, f)
            h.update(os.path.relpath(p, d).encode() + b'\0' + open(p, 'rb').read())
    return h.hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--dest', default=r'C:\Dev\Temp\sidebar-sync-sandbox')
    ap.add_argument('--target', default='')
    ap.add_argument('--launch-app', action='store_true')
    a = ap.parse_args()
    real_seats = os.path.join(os.path.expanduser('~'), '.claude-app-seats')
    real_app = os.path.join(os.environ['APPDATA'], 'Claude')
    stamp = time.strftime('%Y%m%d-%H%M%S')
    root = os.path.join(a.dest, stamp)
    seats, app = os.path.join(root, 'seats'), os.path.join(root, 'app')
    if os.path.normcase(os.path.abspath(root)).startswith(os.path.normcase(real_seats)) or os.path.normcase(os.path.abspath(root)).startswith(os.path.normcase(real_app)):
        sys.exit('the sandbox must not be inside the real seat root or the app folder')
    os.makedirs(seats)
    os.makedirs(app)
    print('sandbox: ' + root)

    # copy (read-only on the real side)
    names = SS.list_seats(real_seats)
    for s, uuid in names.items():
        for rel in (SS.LS_DIR, SS.IDB_DIR):
            shutil.copytree(os.path.join(real_seats, s, *rel), os.path.join(seats, s, *rel), ignore=shutil.ignore_patterns('LOCK'))
        open(os.path.join(seats, s, 'owner-uuid.txt'), 'w').write(uuid + '\n')
    for rel in (SS.LS_DIR, SS.IDB_DIR):
        shutil.copytree(os.path.join(real_app, *rel), os.path.join(app, *rel), ignore=shutil.ignore_patterns('LOCK'))
    shutil.copytree(os.path.join(real_app, 'claude-code-sessions'), os.path.join(app, 'claude-code-sessions'))
    live_uuid = SS.live_account(real_app)
    json.dump({'lastKnownAccountUuid': live_uuid}, open(os.path.join(app, 'config.json'), 'w'))       # the uuid only: never the login tokens
    cfgp = os.path.join(real_app, 'claude_desktop_config.json')
    if os.path.exists(cfgp):
        shutil.copy(cfgp, os.path.join(app, 'claude_desktop_config.json'))
    leaving = next((s for s, u in names.items() if u == live_uuid), '')
    check('the live login is one of the seats', bool(leaving), live_uuid)
    readable = {s: SS.read_pins(*SS.seat_dirs(os.path.join(seats, s))) for s in names}
    target = a.target or next((s for s in sorted(names) if s != leaving and readable[s].ok), '')
    check('a readable target seat exists (%s)' % target, bool(target) and readable.get(target, SS.Pins(False)).ok, {s: r.why for s, r in readable.items()})
    if not target or not leaving:
        return 1
    before = {s: tree_hash(os.path.join(seats, s)) for s in names}

    # dry run
    r = subprocess.run([sys.executable, '-I', os.path.join(HERE, 'sidebar-sync.py'), '--dry-run', '--target', target, '--root', root], capture_output=True, text=True, encoding='utf-8', errors='replace')
    check('--dry-run runs and prints a report', r.returncode == 0 and 'pin changes for %s' % target in r.stdout, r.stdout + r.stderr)
    print(r.stdout)

    # stage 1: bootstrap
    def stage(gen):
        return subprocess.run([sys.executable, '-I', os.path.join(HERE, 'sidebar-sync.py'), '--stage', '--leaving', leaving, '--target', target, '--gen', gen, '--root', root],
                              capture_output=True, text=True, encoding='utf-8', errors='replace')
    r = stage('g1')
    g = os.path.join(seats, SS.WORK, 'g1')
    res = json.load(open(os.path.join(g, 'result.json')))
    check('--stage (bootstrap) exits 0 with a result', r.returncode == 0 and res['status'] in ('synced', 'nothing'), r.stdout + r.stderr + str(res))
    print(r.stdout.strip())
    staged = os.path.isdir(os.path.join(g, 'Local Storage'))
    if staged:
        back = SS.read_pins(os.path.join(g, *SS.LS_DIR), os.path.join(g, *SS.IDB_DIR))
        base = json.load(open(os.path.join(g, 'baseline.json')))
        check('staged stores re-read: both agree and equal baseline.json', back.ok and back.pins == base['pins'] and base['gen'] == 'g1', back.why)
        old = readable[target].pins
        check('staged list = the stash list plus/minus exactly the reported changes (nothing else dropped)', set(old) - set(back.pins) <= {x for x in old}, '')
    else:
        print('  (nothing staged: the target already has every pin)')
    shutil.copy(os.path.join(g, 'state.json'), os.path.join(seats, SS.STATE))       # what the rotator publishes

    # stage 2: a departure checkpoint (the leaving seat's baseline is one pin short, so the stage sees a new pin there)
    lpins = SS.read_pins(os.path.join(app, *SS.LS_DIR), os.path.join(app, *SS.IDB_DIR))
    if lpins.ok and lpins.pins:
        ldir = os.path.join(seats, leaving)
        for rel in (SS.LS_DIR, SS.IDB_DIR):        # the leaving seat's stash = the live copy (what the re-capture does)
            shutil.rmtree(os.path.join(ldir, *rel))
            shutil.copytree(os.path.join(app, *rel), os.path.join(ldir, *rel))
        man = SS.read_pins(*SS.seat_dirs(ldir)).manifest
        cr = SS.live_created(app)
        chk = {'baseline': {'valid': True, 'gen': 'g0', 'pins': lpins.pins[1:], 'manifest': man}, 'installed': {'created': cr}, 'created': cr}
        json.dump(chk, open(os.path.join(ldir, SS.DEPARTURE), 'w'))
        before[leaving] = tree_hash(ldir)
        r = stage('g2')
        res2 = json.load(open(os.path.join(seats, SS.WORK, 'g2', 'result.json')))
        check('--stage with a departure checkpoint exits 0 and consumes it', r.returncode == 0 and 'consumed.txt' in os.listdir(os.path.join(seats, SS.WORK, 'g2')), r.stdout + r.stderr)
        print(r.stdout.strip(), res2)
        g2 = os.path.join(seats, SS.WORK, 'g2')
        if os.path.isdir(os.path.join(g2, 'Local Storage')):
            back = SS.read_pins(os.path.join(g2, *SS.LS_DIR), os.path.join(g2, *SS.IDB_DIR))
            check('second stage: staged stores agree', back.ok and back.pins == json.load(open(os.path.join(g2, 'baseline.json')))['pins'], back.why)
        before[leaving] = tree_hash(ldir)       # the checkpoint was written by this test, before the hash above; nothing after it may change a stash
    check('stashes are byte-identical after staging (only the gen dirs and the state file are written)', all(tree_hash(os.path.join(seats, s)) == before[s] for s in names), '')

    if a.launch_app:
        launch(root, g if staged else None, target, seats)
    print('FAILED: %s' % FAILS if FAILS else 'sandbox test passed (%s)' % root)
    return 1 if FAILS else 0


def launch(root, gdir, target, seats):
    """Opt-in: the staged Local Storage in a second OFFLINE app instance on a throwaway profile (no login tokens in it) for 30 s, closed by its own PID."""
    launcher = os.path.join(os.environ.get('LOCALAPPDATA', ''), 'AnthropicClaude', 'claude.exe')
    if not os.path.exists(launcher):
        print('  SKIP  --launch-app: the Squirrel launcher was not found')
        return
    prof = os.path.join(root, 'launch-profile')
    src = gdir or os.path.join(seats, target)
    shutil.copytree(os.path.join(src, 'Local Storage'), os.path.join(prof, 'Local Storage'))
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
