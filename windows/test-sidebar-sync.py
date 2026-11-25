"""Unit tests for sidebar_ldb.py and sidebar-sync.py (synthetic data only, stdlib). Nothing real is read or written.

  py -3 -I windows/test-sidebar-sync.py
"""
import contextlib
import importlib.util
import io
import json
import os
import shutil
import struct
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import sidebar_ldb as L  # noqa: E402

_spec = importlib.util.spec_from_file_location('sidebar_sync', os.path.join(HERE, 'sidebar-sync.py'))
SS = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(SS)

FAILS = []
PASSES = [0]


def check(name, ok, detail=''):
    if ok:
        PASSES[0] += 1
        print('  PASS  ' + name)
    else:
        FAILS.append(name)
        print('  FAIL  %s  %s' % (name, detail))


def raises(fn, exc=Exception):
    try:
        fn()
    except exc:
        return True
    return False


# ---- a tiny leveldb builder ----------------------------------------------------------------------------------------------------

def frame(data_records):
    """Log-file bytes for the given logical records (32 KB block framing)."""
    out, pos = bytearray(), 0
    for data in data_records:
        first = True
        while True:
            left = L.BLOCK - pos % L.BLOCK
            if left < 7:
                out += b'\x00' * left
                pos += left
                continue
            n = min(len(data), left - 7)
            last = n == len(data)
            typ = (1 if last else 2) if first else (4 if last else 3)
            frag = data[:n]
            out += struct.pack('<IHB', L.mask_crc(L.crc32c(bytes([typ]) + frag)), n, typ) + frag
            pos += 7 + n
            data = data[n:]
            first = False
            if last:
                break
    return bytes(out)


def batch(seq, puts, dels=()):
    b = struct.pack('<QI', seq, len(puts) + len(dels))
    for k, v in puts:
        b += b'\x01' + L.uvarint(len(k)) + k + L.uvarint(len(v)) + v
    for k in dels:
        b += b'\x00' + L.uvarint(len(k)) + k
    return b


def version_edit(log_number=None, prev=None, next_file=None, last_seq=None, new=(), deleted=()):
    b = L.uvarint(1) + L.uvarint(len(b'leveldb.BytewiseComparator')) + b'leveldb.BytewiseComparator'
    if log_number is not None:
        b += L.uvarint(2) + L.uvarint(log_number)
    if next_file is not None:
        b += L.uvarint(3) + L.uvarint(next_file)
    if last_seq is not None:
        b += L.uvarint(4) + L.uvarint(last_seq)
    if prev is not None:
        b += L.uvarint(9) + L.uvarint(prev)
    for lvl, n in deleted:
        b += L.uvarint(6) + L.uvarint(lvl) + L.uvarint(n)
    for lvl, n in new:
        b += L.uvarint(7) + L.uvarint(lvl) + L.uvarint(n) + L.uvarint(100) + L.uvarint(1) + b'a' + L.uvarint(1) + b'z'
    return b


def block(entries):
    out, restarts = bytearray(), []
    for k, v in entries:
        restarts.append(len(out))
        out += L.uvarint(0) + L.uvarint(len(k)) + L.uvarint(len(v)) + k + v
    for r in restarts or [0]:
        out += struct.pack('<I', r)
    out += struct.pack('<I', len(restarts) or 1)
    return bytes(out)


def table_bytes(entries):
    """entries [(user_key, seq, value)] -> a one-data-block .ldb."""
    ents = sorted(entries, key=lambda e: (e[0], -e[1]))
    ik = [(k + struct.pack('<Q', (seq << 8) | 1), v) for k, seq, v in ents]
    data = block(ik)
    out = bytearray(data + b'\x00' + b'\x00\x00\x00\x00')
    meta = block([])
    moff = len(out)
    out += meta + b'\x00\x00\x00\x00\x00'
    idx = block([(ik[-1][0], L.uvarint(0) + L.uvarint(len(data)))])
    ioff = len(out)
    out += idx + b'\x00\x00\x00\x00\x00'
    foot = L.uvarint(moff) + L.uvarint(len(meta)) + L.uvarint(ioff) + L.uvarint(len(idx))
    out += foot + b'\x00' * (40 - len(foot)) + L.TABLE_MAGIC
    return bytes(out)


def make_db(d, tables=(), logs=None, log_number=3, prev=0, last_seq=0, manifest=1, extra_files=()):
    """tables [(number, [(key, seq, value)])] (listed live in the manifest); logs {number: [batch bytes]}; extra_files: tables on disk NOT in the manifest."""
    os.makedirs(d, exist_ok=True)
    live = []
    for n, ents in tables:
        open(os.path.join(d, '%06d.ldb' % n), 'wb').write(table_bytes(ents))
        live.append((0, n))
    for n, ents in extra_files:
        open(os.path.join(d, '%06d.ldb' % n), 'wb').write(table_bytes(ents))
    for n, recs in (logs or {3: []}).items():
        open(os.path.join(d, '%06d.log' % n), 'wb').write(frame(recs))
    open(os.path.join(d, 'MANIFEST-%06d' % manifest), 'wb').write(frame([version_edit(log_number, prev, 10, last_seq, new=live)]))
    open(os.path.join(d, 'CURRENT'), 'wb').write(b'MANIFEST-%06d\n' % manifest)
    open(os.path.join(d, 'LOCK'), 'wb').close()


# ---- reader / writer --------------------------------------------------------------------------------------------------------------

def test_ldb(tmp):
    d = os.path.join(tmp, 'db1')
    make_db(d, tables=[(5, [(b'a', 1, b'A1'), (b'b', 2, b'B2')])], logs={7: [batch(10, [(b'a', b'A10')]), batch(11, [(b'c', b'C11')], dels=[b'b'])]},
            log_number=7, last_seq=9, extra_files=[(6, [(b'zz', 99, b'ghost')])])
    snap = L.read_snapshot(d)
    got = {k: v for k, (s, v) in snap.entries.items()}
    check('manifest parse: log number, last sequence, live tables', snap.manifest.log_number == 7 and snap.manifest.last_sequence == 9 and snap.manifest.files == {5: 0}, str(vars(snap.manifest)))
    check('reader: newest value wins, deletion applied', got == {b'a': b'A10', b'c': b'C11'}, str(got))
    check('reader: a leftover table not in the manifest is ignored', b'zz' not in got)
    check('reader: max sequence over tables and logs', snap.max_seq == 12, str(snap.max_seq))

    d = os.path.join(tmp, 'db2')            # an obsolete log (number below the manifest's) is ignored
    make_db(d, tables=[(5, [(b'a', 1, b'A1')])], logs={4: [batch(20, [(b'old', b'x')])], 8: [batch(30, [(b'new', b'y')])]}, log_number=8, last_seq=1)
    got = L.read_db(d)
    check('reader: obsolete log ignored, current log read', b'old' not in got and got.get(b'new') == b'y')

    d = os.path.join(tmp, 'db3')            # the prev-log-number log is replayed too
    make_db(d, logs={4: [batch(1, [(b'p', b'prev')])], 8: [batch(2, [(b'c', b'cur')])]}, log_number=8, prev=4)
    got = L.read_db(d)
    check('reader: prev-log-number log is replayed', got == {b'p': b'prev', b'c': b'cur'}, str(got))
    check('writer refuses with two recovery logs', raises(lambda: L.append_batch(d, [(b'k', b'v')]), L.LdbError))

    d = os.path.join(tmp, 'db4')            # sequence above the manifest's, and above the highest live entry
    make_db(d, logs={3: [batch(5, [(b'a', b'1')])]}, log_number=3, last_seq=40)
    seq = L.append_batch(d, [(b'b', b'2'), (b'c', b'3')])
    check('writer: sequence is above the manifest last sequence', seq == 41, str(seq))
    check('writer: both keys read back', L.read_db(d) == {b'a': b'1', b'b': b'2', b'c': b'3'})
    seq = L.append_batch(d, [(b'a', b'new')])
    check('writer: the next batch continues above the previous one', seq == 43 and L.read_db(d)[b'a'] == b'new', str(seq))

    d = os.path.join(tmp, 'db5')            # 32 KB block round trip: a value that spans three blocks, appended after a partial block
    make_db(d, logs={3: [batch(1, [(b'a', b'x' * 100)])]}, log_number=3, last_seq=1)
    big = os.urandom(70000)
    L.append_batch(d, [(b'big', big)])
    check('writer: a 70 KB value spanning log blocks round-trips', L.read_db(d)[b'big'] == big)
    L.append_batch(d, [(b'after', b'ok')])
    check('writer: a batch after a fragmented one still reads', L.read_db(d)[b'after'] == b'ok')

    d = os.path.join(tmp, 'db6')            # refusals
    make_db(d, logs={3: [batch(1, [(b'a', b'1')])]}, log_number=3)
    lp = os.path.join(d, '000003.log')
    open(lp, 'ab').write(b'\x01\x02\x03')    # torn tail
    check('writer refuses a torn tail and writes nothing', raises(lambda: L.append_batch(d, [(b'k', b'v')]), L.LdbError) and open(lp, 'rb').read().endswith(b'\x01\x02\x03'))
    d = os.path.join(tmp, 'db7')            # Chromium's reuse_logs: the one replayed log may be NEWER than the manifest's log number (even 0)
    make_db(d, logs={5: [batch(1, [(b'a', b'1')])]}, log_number=0, last_seq=1)
    L.append_batch(d, [(b'k', b'v')])
    check('writer accepts the single recovery log when it is newer than the manifest log number (reuse_logs)', L.read_db(d) == {b'a': b'1', b'k': b'v'})
    d = os.path.join(tmp, 'db7b')           # an obsolete older log beside the one recovery log is not a second recovery log
    make_db(d, logs={2: [batch(1, [(b'old', b'x')])], 5: [batch(2, [(b'a', b'1')])]}, log_number=5, last_seq=2)
    L.append_batch(d, [(b'k', b'v')])
    check('writer: an obsolete older log is neither read nor appended to', L.read_db(d) == {b'a': b'1', b'k': b'v'} and open(os.path.join(d, '000002.log'), 'rb').read() == frame([batch(1, [(b'old', b'x')])]))
    d = os.path.join(tmp, 'db8')
    make_db(d, logs={3: []}, log_number=9)                                # no recovery log at all
    check('writer refuses with no recovery log', raises(lambda: L.append_batch(d, [(b'k', b'v')]), L.LdbError))
    d = os.path.join(tmp, 'db9')
    make_db(d, logs={3: [batch(1, [(b'a', b'1')])]}, log_number=3)
    raw = bytearray(open(os.path.join(d, '000003.log'), 'rb').read())
    raw[10] ^= 0xFF
    open(os.path.join(d, '000003.log'), 'wb').write(bytes(raw))
    check('a CRC error is a torn tail: reader says not clean, writer refuses', not L.read_snapshot(d).clean and raises(lambda: L.append_batch(d, [(b'k', b'v')]), L.LdbError))
    check('missing live table is an error', raises(lambda: L.read_snapshot(_missing_table(tmp)), L.LdbError))

    # V8 one-byte string replace
    old = b'\xc8K\xff\x15\xfe' + b'\x00' * 12 + b'\xff\x10"' + L.uvarint(3) + b'abc'
    new = L.idb_replace(old, '{"x":' + '1' * 200 + '}')
    check('V8 replace: prefix and envelope kept, new length varint', new.startswith(old[:-4]) and L.idb_json(new) == '{"x":' + '1' * 200 + '}', repr(new[:30]))
    check('V8 replace: non-ASCII is refused', raises(lambda: L.idb_replace(old, '{"x":"א"}'), L.LdbError))
    check('V8 replace: a value that is not a one-byte V8 string is refused', raises(lambda: L.idb_replace(b'\xc8K\xff\x15\xfe\x00', '{}'), L.LdbError))
    check('local storage codec: Latin-1 and UTF-16LE', L.ls_decode(L.ls_encode('abc')) == 'abc' and L.ls_encode('abc')[0] == 1 and L.ls_encode('א')[0] == 0 and L.ls_decode(L.ls_encode('א')) == 'א')


def _missing_table(tmp):
    d = os.path.join(tmp, 'dbm')
    make_db(d, tables=[(5, [(b'a', 1, b'A')])], logs={3: []}, log_number=3)
    os.unlink(os.path.join(d, '000005.ldb'))
    return d


# ---- a world of seats ---------------------------------------------------------------------------------------------------------------

ORG = 'org1'


class World:
    def __init__(self, tmp):
        self.seats = os.path.join(tmp, 'seats')
        self.app = os.path.join(tmp, 'app')
        os.makedirs(self.seats)
        os.makedirs(self.app)
        self.n = 0

    def seat(self, name, acct, pins, ls_extra=None, idb_key=True, manifest=(1, 1)):
        d = os.path.join(self.seats, name)
        os.makedirs(d, exist_ok=True)
        open(os.path.join(d, 'owner-uuid.txt'), 'w').write(acct + '\n')
        self.set_pins(name, pins, manifest)
        return d

    def set_pins(self, name, pins, manifest=(1, 1), idb_key=True):
        d = os.path.join(self.seats, name)
        ls = os.path.join(d, 'Local Storage', 'leveldb')
        idb = os.path.join(d, 'IndexedDB', 'https_claude.ai_0.indexeddb.leveldb')
        for x in (ls, idb):
            shutil.rmtree(x, ignore_errors=True)
        lsval = SS.jdump({'value': pins, 'tabId': 't1', 'timestamp': 1})
        make_db(ls, logs={3: [batch(5, [(L.ls_key(SS.LS_PIN_NAME), L.ls_encode(lsval)), (L.ls_key('other'), L.ls_encode('{"keep":1}'))])]}, log_number=3, last_seq=5, manifest=manifest[0])
        idbval = SS.jdump({'state': {'starredIds': pins}, 'version': 0, 'updatedAt': 1})
        v = b'\xc8K\xff\x15\xfe' + b'\x00' * 12 + b'\xff\x10"' + L.uvarint(len(idbval)) + idbval.encode()
        puts = [(IDB_KEY, v)] if idb_key else []
        make_db(idb, logs={3: [batch(5, puts + [(b'\x00\x05\x01\x01\x01\x04abcd', b'x')])]}, log_number=3, last_seq=5, manifest=manifest[1])

    def rec(self, acct, sid, cli, archived=False, last=1, title=None, org=ORG):
        d = os.path.join(self.app, 'claude-code-sessions', acct, org)
        os.makedirs(d, exist_ok=True)
        json.dump({'sessionId': sid, 'cliSessionId': cli, 'isArchived': archived, 'lastActivityAt': last, 'title': title or ('t-' + sid)}, open(os.path.join(d, sid + '.json'), 'w'))

    def drop_rec(self, acct, sid, org=ORG):
        os.unlink(os.path.join(self.app, 'claude-code-sessions', acct, org, sid + '.json'))

    def baseline(self, name, pins, manifest=(1, 1), valid=True, gen='g0'):
        b = {'valid': True, 'gen': gen, 'pins': pins, 'manifest': {'ls': manifest[0], 'idb': manifest[1]}} if valid else {'valid': False}
        json.dump(b, open(os.path.join(self.seats, name, SS.BASELINE), 'w'))
        return b

    def checkpoint(self, name, baseline, created=None, installed=None, no_installed=False):
        inst = {'created': {'ls': 111, 'idb': 222}} if installed is None else installed
        c = {'baseline': baseline, 'created': created or {'ls': 111, 'idb': 222}}
        if not no_installed:
            c['installed'] = inst
        json.dump(c, open(os.path.join(self.seats, name, SS.DEPARTURE), 'w'))

    def state(self, pins):
        json.dump({'version': 1, 'gen': 'g0', 'pins': pins}, open(os.path.join(self.seats, SS.STATE), 'w'))

    def stage(self, leaving, target, gen='g1'):
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            rc = SS.main(['--stage', '--seats', self.seats, '--app', self.app, '--leaving', leaving, '--target', target, '--gen', gen])
        g = os.path.join(self.seats, SS.WORK, gen)
        return Gen(g, rc, out.getvalue())

    def install(self, gen, target):
        """What the rotator does after a good stage: the staged pair (if any) replaces the seat's dirs, the baseline and state are published,
        consumed checkpoints removed."""
        g = gen.dir
        d = os.path.join(self.seats, target)
        if os.path.isdir(os.path.join(g, 'Local Storage')):
            for rel in ('Local Storage', 'IndexedDB'):
                shutil.rmtree(os.path.join(d, rel))
                shutil.copytree(os.path.join(g, rel), os.path.join(d, rel))
            shutil.copy(os.path.join(g, 'baseline.json'), os.path.join(d, SS.BASELINE))
        else:
            shutil.copy(os.path.join(g, 'baseline-stash.json'), os.path.join(d, SS.BASELINE))
        if os.path.exists(os.path.join(g, 'state.json')):
            shutil.copy(os.path.join(g, 'state.json'), os.path.join(self.seats, SS.STATE))
        if os.path.exists(os.path.join(g, 'consumed.txt')):
            for line in open(os.path.join(g, 'consumed.txt')).read().splitlines():
                s, h = line.split('\t')
                p = os.path.join(self.seats, s, SS.DEPARTURE)
                if os.path.exists(p) and SS.sha256_file(p) == h:
                    os.unlink(p)


IDB_KEY = b'\x00\x05\x01\x01\x01\x23' + 'store:pin-state:dframe-starred-code'.encode('utf-16-be')


class Gen:
    def __init__(self, d, rc, out):
        self.dir, self.rc, self.out = d, rc, out

    def f(self, name):
        p = os.path.join(self.dir, name)
        return json.load(open(p)) if os.path.exists(p) and name.endswith('.json') else (open(p).read() if os.path.exists(p) else None)

    @property
    def staged(self):
        return os.path.isdir(os.path.join(self.dir, 'Local Storage'))

    def pins(self):
        p = SS.read_pins(os.path.join(self.dir, *SS.LS_DIR), os.path.join(self.dir, *SS.IDB_DIR))
        return p.pins if p.ok else None

    @property
    def result(self):
        return self.f('result.json')


def seat_pins(w, name):
    p = SS.read_pins(*SS.seat_dirs(os.path.join(w.seats, name)))
    return p.pins if p.ok else None


def two(tmp_root):
    """C (acct ac) and D (acct ad), one session cli1 on both, state known."""
    w = World(tmp_root)
    w.seat('C', 'ac', [])
    w.seat('D', 'ad', [])
    w.rec('ac', 'local_c1', 'cli1')
    w.rec('ad', 'local_d1', 'cli1')
    return w


def test_logic(tmp):
    n = [0]

    def fresh():
        n[0] += 1
        return os.path.join(tmp, 'w%d' % n[0])

    # departure pin reaches the target, in both stores
    w = two(fresh())
    w.state({'cli1': False})
    b = w.baseline('C', [])
    w.set_pins('C', ['local_c1'])
    w.checkpoint('C', b)
    g = w.stage('C', 'D')
    check('departure pin reaches the target (staged, both stores agree)', g.rc == 0 and g.staged and g.pins() == ['local_d1'] and g.result['status'] == 'synced' and g.result['n'] == 1 and 'Sidebar: synced 1 pins.' in g.out, g.out + str(g.result))
    check('stage: state publishes the pin, baseline carries the gen and the new list', g.f('state.json')['pins'] == {'cli1': True} and g.f('baseline.json')['pins'] == ['local_d1'] and g.f('baseline.json')['gen'] == 'g1')
    check('stage: the stash is untouched (byte for byte)', seat_pins(w, 'D') == [])
    check('stage: consumed lists the checkpoint with its hash', g.f('consumed.txt').split('\t')[0] == 'C')
    # repeat idempotent
    w.install(g, 'D')
    w.set_pins('C', ['local_c1'])
    g2 = w.stage('C', 'D', 'g2')
    check('a second identical stage stages no databases', g2.rc == 0 and not g2.staged and g2.result['status'] == 'nothing' and 'nothing to sync' in g2.out, g2.out)
    check('the checkpoint was consumed by the install, a repeat reads none', not os.path.exists(os.path.join(w.seats, 'C', SS.DEPARTURE)))

    # unpin reaches the target; the last remaining pin can be unpinned
    w = two(fresh())
    w.set_pins('D', ['local_d1', 'local_foreign'])
    w.state({'cli1': True})
    b = w.baseline('C', ['local_c1'])
    w.set_pins('C', [])
    w.checkpoint('C', b)
    g = w.stage('C', 'D')
    check('departure unpin (the last remaining pin) reaches the target; an unmapped foreign pin is kept in both stores', g.staged and g.pins() == ['local_foreign'] and g.f('state.json')['pins'] == {'cli1': False}, str(g.pins()) + g.out)

    # invalid / missing / recreated baseline contribute nothing; no resurrection from an old stash
    cases = [('invalid baseline', dict(valid=False), {}), ('missing installed record', {}, dict(no_installed=True)),
             ('created differs (S78: same manifest number)', {}, dict(created={'ls': 111, 'idb': 999})),
             ('manifest lower than at activation', dict(manifest=(5, 5)), {})]
    for name, bk, ck in cases:
        w = two(fresh())
        w.state({'cli1': False})
        b = w.baseline('C', [], **bk)
        w.set_pins('C', ['local_c1'])       # the old stash still holds a pin
        w.checkpoint('C', b, **ck)
        g = w.stage('C', 'D')
        check('%s: the seat contributes nothing, reported, no pin invented' % name, g.result['status'] == 'nothing' and g.f('state.json')['pins'] == {'cli1': False}
              and 'edits made on C were not synced' in g.f('report.txt'), g.f('report.txt'))
        check('%s: the checkpoint is still consumed' % name, g.f('consumed.txt').startswith('C\t'))
    w = two(fresh())
    w.state({'cli1': False})
    w.set_pins('C', ['local_c1'])           # no checkpoint at all: nothing observed
    g = w.stage('C', 'D')
    check('no checkpoint: nothing observed, nothing staged', g.result['status'] == 'nothing' and g.f('consumed.txt') == '')

    # a vanished record and a replacement copy are no removal
    w = two(fresh())
    w.set_pins('D', ['local_d1'])
    w.state({'cli1': True})
    b = w.baseline('C', ['local_c1'])
    w.set_pins('C', [])
    w.drop_rec('ac', 'local_c1')            # the pinned copy vanished
    w.rec('ac', 'local_c2', 'cli1')         # a replacement copy, not in the baseline
    w.checkpoint('C', b)
    g = w.stage('C', 'D')
    check('vanished record + unpinned replacement copy: no removal', g.result['status'] == 'nothing' and g.f('state.json')['pins'] == {'cli1': True}, g.out)

    # S77: a cli with one copy unpinned and another pinned stays pinned; pin intent per cli across copies in two org folders
    w = two(fresh())
    w.rec('ac', 'local_c2', 'cli1', org='org2')
    w.set_pins('D', [])
    w.state({'cli1': True})
    b = w.baseline('C', ['local_c1'])
    w.set_pins('C', ['local_c2'])           # copy 1 unpinned, copy 2 (other org folder) pinned
    w.checkpoint('C', b)
    g = w.stage('C', 'D')
    check('S77: one copy unpinned and another pinned stays pinned, per cli across two org folders', g.f('state.json')['pins'] == {'cli1': True} and g.pins() == ['local_d1'], g.out)

    # per cli on the TARGET: two copies, one already pinned keeps; unpin removes every copy; the preferred copy is the unarchived newest
    w = two(fresh())
    w.rec('ad', 'local_d2', 'cli1', archived=True, last=99)
    w.rec('ad', 'local_d3', 'cli1', last=5)
    w.rec('ad', 'local_d4', 'cli1', last=7)
    w.state({'cli1': True})
    g = w.stage('C', 'D')
    check('target pin goes to the preferred copy (unarchived, then newest)', g.pins() == ['local_d4'], str(g.pins()))
    w.set_pins('D', ['local_d3'])
    g = w.stage('C', 'D', 'g2')
    check('a copy already pinned on the target is kept (no second pin)', g.result['status'] == 'nothing')
    w.state({'cli1': False})
    w.set_pins('D', ['local_d2', 'local_d3', 'local_foreign'])
    g = w.stage('C', 'D', 'g3')
    check('desired unpinned removes every copy, keeps the unmapped entry', g.pins() == ['local_foreign'], str(g.pins()))

    # no copy on the target is counted, not added
    w = two(fresh())
    w.rec('ac', 'local_c9', 'cli9')
    w.state({'cli1': False, 'cli9': True})
    g = w.stage('C', 'D')
    check('a pinned session the target has no record for is counted, nothing added', g.result['status'] == 'nothing' and 'no copy on D' in g.f('report.txt') and ': 1' in g.f('report.txt').split('no copy on D')[1].splitlines()[0])

    # an id in no record, or a record without cliSessionId, is never added or removed
    w = two(fresh())
    w.set_pins('D', ['local_orphan'])
    w.rec('ad', 'local_nocli', 'x')
    p = os.path.join(w.app, 'claude-code-sessions', 'ad', ORG, 'local_nocli.json')
    j = json.load(open(p))
    del j['cliSessionId']
    json.dump(j, open(p, 'w'))
    w.state({'cli1': True})
    g = w.stage('C', 'D')
    check('unmapped entries kept; the record without a cliSessionId is ignored', g.pins() == ['local_orphan', 'local_d1'], str(g.pins()))

    # bootstrap: disagreeing seats -> pinned; unreadable seat contributes nothing, its pin is unknown, recorded at its activation
    w = World(fresh())
    w.seat('C', 'ac', ['local_c1'])
    w.seat('D', 'ad', [])
    w.seat('E', 'ae', ['local_e2'], idb_key=False)
    w.set_pins('E', ['local_e2'], idb_key=False)          # E's IndexedDB has no pin state: unreadable
    for acct, sid, cli in (('ac', 'local_c1', 'cli1'), ('ad', 'local_d1', 'cli1'), ('ae', 'local_e1', 'cli1'), ('ae', 'local_e2', 'cli2'), ('ad', 'local_d2', 'cli2')):
        w.rec(acct, sid, cli)
    g = w.stage('C', 'D')
    check('bootstrap: pinned on C, unpinned on D -> becomes pinned on D; the unreadable seat is reported and contributes nothing',
          g.pins() == ['local_d1'] and g.f('state.json')['pins'] == {'cli1': True} and 'E is unreadable' in g.f('report.txt'), g.out + g.f('report.txt'))
    w.install(g, 'D')
    w.set_pins('E', ['local_e2'])                           # E becomes readable (it is entered)
    g = w.stage('D', 'E', 'g2')
    check('bootstrap: the unreadable seat\'s pin is unknown, so E keeps its own value and records it as observed intent (S65)',
          g.f('state.json')['pins'] == {'cli1': True, 'cli2': True} and g.pins() == ['local_e2', 'local_e1'] and g.result['n'] == 1, str(g.f('state.json')) + str(g.pins()))

    # unknown clis on the target keep the target's own value and are recorded
    w = two(fresh())
    w.set_pins('D', ['local_d1'])
    w.state({})
    g = w.stage('C', 'D')
    check('unknown cli: the target keeps its pin and it is recorded as observed intent', g.result['status'] == 'nothing' and g.f('state.json')['pins'] == {'cli1': True})

    # unreadable state file -> no staging, reported, nothing consumed
    w = two(fresh())
    open(os.path.join(w.seats, SS.STATE), 'w').write('{broken')
    g = w.stage('C', 'D')
    check('unreadable state file: no staging, nothing published or consumed, reported', g.rc == 0 and not g.staged and g.f('state.json') is None and g.f('consumed.txt') is None and g.result['status'] == 'skipped' and 'Sidebar: skipped (' in g.out and 'report.txt' in g.out, g.out)

    # S72: a pending departure from A survives a timed-out A->B stage and is applied at B->A
    w = World(fresh())
    w.seat('A', 'aa', [])
    w.seat('B', 'ab', [])
    w.rec('aa', 'local_a1', 'cli1')
    w.rec('ab', 'local_b1', 'cli1')
    w.state({'cli1': False})
    ba = w.baseline('A', [])
    w.set_pins('A', ['local_a1'])
    w.checkpoint('A', ba)                                   # A->B: checkpoint written, then the stage "timed out": nothing published, nothing consumed
    bb = w.baseline('B', [])
    w.checkpoint('B', bb)                                   # B->A: B's own checkpoint (B changed nothing)
    g = w.stage('B', 'A')
    check('S72: the pending departure from A is applied at the B->A stage and consumed', g.f('state.json')['pins'] == {'cli1': True} and {x.split('\t')[0] for x in g.f('consumed.txt').splitlines()} == {'A', 'B'}, g.f('consumed.txt'))

    # the leaving seat is applied last: A pins, B (leaving) unpins -> unpinned
    w = World(fresh())
    w.seat('A', 'aa', [])
    w.seat('B', 'ab', [])
    w.seat('C', 'ac', [])
    for acct, sid in (('aa', 'local_a1'), ('ab', 'local_b1'), ('ac', 'local_c1')):
        w.rec(acct, sid, 'cli1')
    w.state({'cli1': False})
    w.checkpoint('A', w.baseline('A', []))
    w.set_pins('A', ['local_a1'])
    w.checkpoint('B', w.baseline('B', ['local_b1']))
    g = w.stage('B', 'C')
    check('the leaving seat is applied last', g.f('state.json')['pins'] == {'cli1': False}, str(g.f('state.json')))

    # an unchanged pin is no evidence: a stale seat cannot undo another seat's unpin
    w = World(fresh())
    w.seat('A', 'aa', ['local_a1'])
    w.seat('B', 'ab', [])
    w.seat('C', 'ac', [])
    for acct, sid in (('aa', 'local_a1'), ('ab', 'local_b1'), ('ac', 'local_c1')):
        w.rec(acct, sid, 'cli1')
    w.state({'cli1': False})                                # someone unpinned it earlier
    w.checkpoint('A', w.baseline('A', ['local_a1']))        # A still pins it, unchanged since its baseline
    g = w.stage('B', 'C')
    check('an unchanged pinned copy does not resurrect a pin another seat removed', g.f('state.json')['pins'] == {'cli1': False}, str(g.f('state.json')))

    # refusals: the writer cannot stage (two recovery logs) -> skipped, state still published, baseline-stash valid, no staged dirs
    w = two(fresh())
    w.state({'cli1': True})
    ld = os.path.join(w.seats, 'D', 'Local Storage', 'leveldb')
    open(os.path.join(ld, '000004.log'), 'wb').write(frame([batch(9, [(b'q', b'q')])]))
    g = w.stage('C', 'D')
    check('writer refusal: skipped with the reason, no staged dirs, stash baseline valid, state still published',
          g.result['status'] == 'skipped' and not g.staged and 'staging refused' in g.result['reason'] and g.f('baseline-stash.json')['valid'] and g.f('state.json') is not None and 'Sidebar: skipped (staging refused' in g.out, g.out)

    # config: written to the gen only when the list differs, with the shared config's other keys untouched
    w = two(fresh())
    w.state({'cli1': True})
    cfg = {'preferences': {'epitaxyPrefs': {'starred-local-code-sessions': ['local_x'], 'other': {'k': 1}}}, 'top': True}
    cp = os.path.join(w.app, 'claude_desktop_config.json')
    open(cp, 'wb').write(json.dumps(cfg, indent=2, ensure_ascii=False).encode('utf-8'))
    g = w.stage('C', 'D')
    c = g.f('config.json')
    newcfg = json.loads(__import__('base64').b64decode(c['b64']))
    check('config.json: pair staged, hash of the config read, only the pin list changed',
          c['pair'] == 'staged' and c['sha256'] == SS.sha256_file(cp) and newcfg['preferences']['epitaxyPrefs']['starred-local-code-sessions'] == ['local_d1']
          and newcfg['preferences']['epitaxyPrefs']['other'] == {'k': 1} and newcfg['top'] is True)
    check('the live config is untouched by the stage', json.load(open(cp)) == cfg)
    w.install(g, 'D')
    cfg['preferences']['epitaxyPrefs']['starred-local-code-sessions'] = ['local_d1']
    open(cp, 'wb').write(json.dumps(cfg, indent=2, ensure_ascii=False).encode('utf-8'))
    g = w.stage('C', 'D', 'g2')
    check('config already holding the pins: no config.json', g.f('config.json') is None)
    cfg['preferences']['epitaxyPrefs']['starred-local-code-sessions'] = []
    open(cp, 'wb').write(json.dumps(cfg, indent=2, ensure_ascii=False).encode('utf-8'))
    g = w.stage('C', 'D', 'g3')
    check('no pin change but a stale config: a config-only repair, pair stash', g.f('config.json')['pair'] == 'stash' and not g.staged)
    open(cp, 'wb').write(b'{"preferences": {"epitaxyPrefs": {"starred-local-code-sessions": []}}}')
    g = w.stage('C', 'D', 'g4')
    check('a config that does not round-trip byte for byte is never rewritten', g.f('config.json') is None and 'config not changed' in g.f('report.txt'))

    # --forget
    w = two(fresh())
    w.baseline('C', ['x'])
    w.checkpoint('C', w.baseline('C', ['x']))
    with contextlib.redirect_stdout(io.StringIO()):
        rc = SS.main(['--forget', 'C', '--seats', w.seats, '--app', w.app])
    check('--forget invalidates the baseline and drops the pending departure', rc == 0 and json.load(open(os.path.join(w.seats, 'C', SS.BASELINE))) == {'valid': False} and not os.path.exists(os.path.join(w.seats, 'C', SS.DEPARTURE)))

    # dry run writes nothing and reports
    w = two(fresh())
    w.state({'cli1': True})
    before = sorted(os.listdir(w.seats)) + ['.sync-history.lock']
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        rc = SS.main(['--dry-run', '--target', 'D', '--leaving', 'C', '--leaving-stash', '--seats', w.seats, '--app', w.app])
    check('dry run: lists the pin with its title, writes nothing', rc == 0 and 'pin t-local_d1' in out.getvalue() and sorted(set(os.listdir(w.seats)) | {'.sync-history.lock'}) == sorted(before) and not os.path.exists(os.path.join(w.seats, SS.WORK)), out.getvalue())

    # verify
    w = two(fresh())
    w.state({'cli1': True})
    g = w.stage('C', 'D', 'g7')
    w.install(g, 'D')
    live = os.path.join(w.app, 'Local Storage')
    shutil.copytree(os.path.join(w.seats, 'D', 'Local Storage'), live)
    shutil.copytree(os.path.join(w.seats, 'D', 'IndexedDB'), os.path.join(w.app, 'IndexedDB'))
    json.dump({'lastKnownAccountUuid': 'ad'}, open(os.path.join(w.app, 'config.json'), 'w'))
    json.dump({'preferences': {'epitaxyPrefs': {'starred-local-code-sessions': ['local_d1']}}}, open(os.path.join(w.app, 'claude_desktop_config.json'), 'w'))
    ns = SS.argparse.Namespace(seats=w.seats, app=w.app, gen='g7', target='D', wait=5, settle=0)
    SS.run_verify(ns, pids=lambda: [1], sleep=lambda s: None)
    v = open(os.path.join(w.seats, SS.WORK, 'g7', 'verify.txt')).read()
    check('verify: all three stores agree with the baseline', 'differences=0' in v and v.count('OK') == 3 and 'seat D' in v and 'gen g7' in v, v)
    json.dump({'preferences': {'epitaxyPrefs': {'starred-local-code-sessions': []}}}, open(os.path.join(w.app, 'claude_desktop_config.json'), 'w'))
    SS.run_verify(ns, pids=lambda: [1], sleep=lambda s: None)
    v = open(os.path.join(w.seats, SS.WORK, 'g7', 'verify.txt')).read()
    check('verify: a differing store is named and counted', 'differences=1' in v and 'config: DIFFERS' in v and 'app revert or an edit within 0 s' in v, v)
    json.dump({'lastKnownAccountUuid': 'ac'}, open(os.path.join(w.app, 'config.json'), 'w'))
    SS.run_verify(ns, pids=lambda: [1], sleep=lambda s: None)
    check('verify: another login is live -> superseded, nothing compared', 'superseded' in open(os.path.join(w.seats, SS.WORK, 'g7', 'verify.txt')).read())
    ns.gen = 'other'
    json.dump({'lastKnownAccountUuid': 'ad'}, open(os.path.join(w.app, 'config.json'), 'w'))
    os.makedirs(os.path.join(w.seats, SS.WORK, 'other'))
    SS.run_verify(ns, pids=lambda: [1], sleep=lambda s: None)
    check('verify: the baseline carries a different gen -> superseded', 'superseded' in open(os.path.join(w.seats, SS.WORK, 'other', 'verify.txt')).read())


def main():
    tmp = tempfile.mkdtemp(prefix='sidebar-sync-test-')
    try:
        test_ldb(tmp)
        test_logic(tmp)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    if FAILS:
        print('%d FAILED: %s' % (len(FAILS), ', '.join(FAILS)))
        return 1
    print('test-sidebar-sync: %d checks passed' % PASSES[0])
    return 0


if __name__ == '__main__':
    sys.exit(main())
