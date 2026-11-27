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

    d = os.path.join(tmp, 'dbc')            # create_db: synthetic fixtures built with the module's own writer
    L.create_db(d, [(b'a', b'1'), (b'b', b'2')])
    L.append_batch(d, [(b'c', b'3')])
    check('create_db: a new synthetic database reads back, takes an appended batch, and a non-empty directory is refused',
          L.read_db(d) == {b'a': b'1', b'b': b'2', b'c': b'3'} and raises(lambda: L.create_db(d, [(b'x', b'y')]), L.LdbError))
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

    def baseline(self, name, pins, manifest=(1, 1), gen='b1', created=(111, 222), write=True):
        """A seat's baseline: what was installed (gen, pins, manifest) and the creation times of the live databases right after that install."""
        b = {'gen': gen, 'pins': pins, 'manifest': {'ls': manifest[0], 'idb': manifest[1]}}
        if created:
            b['created'] = {'ls': created[0], 'idb': created[1]}
        if write:
            json.dump(b, open(os.path.join(self.seats, name, SS.BASELINE), 'w'))
        return b

    def marker(self, name, baseline, dep='d1', at=1, created=(111, 222)):
        """A seat's ONE departure marker (what the rotator writes after a good re-capture): the baseline verbatim, the creation times seen at departure."""
        m = {'dep': dep, 'at': at, 'baseline': baseline, 'created': {'ls': created[0], 'idb': created[1]}}
        json.dump(m, open(os.path.join(self.seats, name, SS.DEPARTURE), 'w'))
        return m

    def state(self, pins, seats=None):
        json.dump({'version': 2, 'gen': 'g0', 'pins': pins, 'seats': seats or {}}, open(os.path.join(self.seats, SS.STATE), 'w'))

    def committed(self):
        """The state file Python committed (None when there is none)."""
        p = os.path.join(self.seats, SS.STATE)
        return json.load(open(p)) if os.path.exists(p) else None

    def stage(self, leaving, target, gen='g1'):
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            rc = SS.main(['--stage', '--seats', self.seats, '--app', self.app, '--leaving', leaving, '--target', target, '--gen', gen])
        g = os.path.join(self.seats, SS.WORK, gen)
        return Gen(g, rc, out.getvalue())

    def install(self, gen, target):
        """What the rotator does after a good stage: the staged pair (if any) replaces the seat's dirs and the baseline is written ONCE, with the creation
        times of the new live databases (the state was already committed by the stage)."""
        g = gen.dir
        d = os.path.join(self.seats, target)
        if os.path.isdir(os.path.join(g, 'Local Storage')):
            for rel in ('Local Storage', 'IndexedDB'):
                shutil.rmtree(os.path.join(d, rel))
                shutil.copytree(os.path.join(g, rel), os.path.join(d, rel))
            b = json.load(open(os.path.join(g, 'baseline.json')))
        else:
            b = json.load(open(os.path.join(g, 'baseline-stash.json')))
        b['created'] = {'ls': 111, 'idb': 222}
        json.dump(b, open(os.path.join(d, SS.BASELINE), 'w'))
        json.dump({'gen': os.path.basename(g), 'target': target, 'pair': 'staged' if os.path.isdir(os.path.join(g, 'Local Storage')) else 'stash',
                   'pins': b['pins'], 'created': b['created']}, open(os.path.join(g, SS.INSTALL), 'w'))


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


def test_v8_versions():
    js = '{"state":{"starredIds":["local_x"]},"version":0,"updatedAt":1786903504263}'
    hdr_a = bytes.fromhex('05ff15fe' + '00' * 12 + 'ff0f22')                      # seat A's real header: version 0x0f
    val_a = hdr_a + L.uvarint(len(js)) + js.encode()
    check('V8 version 0x0f (seat A) is read', L.idb_json(val_a) == js)
    new_a = L.idb_replace(val_a, js.replace('local_x', 'local_yy'))
    check('V8 version 0x0f replace keeps the original header bytes, only the string changes', new_a.startswith(hdr_a) and L.idb_json(new_a).count('local_yy') == 1 and new_a[:len(hdr_a)] == hdr_a)
    val_b = bytes.fromhex('c84bff15fe' + '00' * 12 + 'ff1022') + L.uvarint(len(js)) + js.encode()
    check('V8 version 0x10 (seats B-F) is still read and replaced', L.idb_json(val_b) == js and L.idb_replace(val_b, '{}').startswith(bytes.fromhex('c84bff15fe' + '00' * 12 + 'ff1022')))
    val_x = bytes.fromhex('05ff15fe' + '00' * 12 + 'ff1122') + L.uvarint(len(js)) + js.encode()
    try:
        L.idb_json(val_x)
        why = ''
    except L.LdbError as e:
        why = str(e)
    check('any other V8 version is refused and named in the reason (idb_json and idb_replace)', '0x11' in why and raises(lambda: L.idb_replace(val_x, '{}'), L.LdbError), why)


def test_logic(tmp):
    n = [0]

    def fresh():
        n[0] += 1
        return os.path.join(tmp, 'w%d' % n[0])

    def clean(st):
        return {k: v for k, v in st.items() if k != 'gen'}

    # ---- a departure pin reaches the target, in both stores; the state is COMMITTED by the stage itself
    w = two(fresh())
    w.state({'cli1': False})
    b = w.baseline('C', [])
    w.set_pins('C', ['local_c1'])
    w.marker('C', b)
    g = w.stage('C', 'D')
    st = w.committed()
    check('departure pin reaches the target (staged, both stores agree)', g.rc == 0 and g.staged and g.pins() == ['local_d1'] and g.result['status'] == 'synced' and g.result['n'] == 1 and 'Sidebar: synced 1 pins.' in g.out, g.out + str(g.result))
    check('the state is committed by the stage: the pin, and the departure merged (dep, base, observed)', st['version'] == 2 and st['pins'] == {'cli1': True} and st['seats']['C'] == {'dep': 'd1', 'base': 'b1', 'observed': ['local_c1']}, str(st))
    check('stage: baseline carries the gen and the new list (the rotator adds created); no valid flag; the stash is untouched', g.f('baseline.json')['pins'] == ['local_d1'] and g.f('baseline.json')['gen'] == 'g1'
          and 'valid' not in g.f('baseline.json') and seat_pins(w, 'D') == [])
    check('stage: there is no consumed.txt and no candidate state file in the gen dir', g.f('consumed.txt') is None and g.f('state.json') is None)
    w.install(g, 'D')
    w.set_pins('C', ['local_c1'])
    g2 = w.stage('C', 'D', 'g2')
    check('a second stage over the same marker stages no databases and leaves the committed state unchanged (apart from its gen)', g2.rc == 0 and not g2.staged and g2.result['status'] == 'nothing' and clean(w.committed()) == clean(st), g2.out)

    # ---- spec test 1, REPLAY: a marker read twice (or again after a later stage) is never applied twice
    w = World(fresh())
    w.seat('B', 'ab', [])
    w.seat('C', 'ac', [])
    w.seat('D', 'ad', [])
    for ac, nm in (('ab', 'b'), ('ac', 'c'), ('ad', 'd')):
        w.rec(ac, 'local_%s1' % nm, 'cliX')
    w.state({'cliX': False})
    bc = w.baseline('C', [])
    w.set_pins('C', ['local_c1'])                                            # C pins X
    w.marker('C', bc, dep='dC', at=10)
    w.stage('C', 'D', 'rp1')
    check('replay setup: X is pinned after the first merge', w.committed()['pins'] == {'cliX': True})
    bb = w.baseline('B', ['local_b1'])
    w.set_pins('B', [])                                                      # B unpins X later
    w.marker('B', bb, dep='dB', at=20)
    w.stage('B', 'D', 'rp2')
    check('replay setup: the later unpin on B wins', w.committed()['pins'] == {'cliX': False})
    w.stage('B', 'D', 'rp3')                                                 # C's marker is still on disk, unchanged
    check('REPLAY: C\'s old marker is never applied again: X stays unpinned, and the target gets no pin added back', w.committed()['pins'] == {'cliX': False} and seat_pins(w, 'D') == [], str(w.committed()))

    # ---- spec test 2, WRONG ACTIVATION: a valid pending marker, then an invalid departure: nothing is merged, the seat is reported
    w = two(fresh())
    w.state({'cli1': False})
    w.set_pins('C', ['local_c1'])
    w.marker('C', w.baseline('C', [], created=(111, 222)), dep='dBad', created=(999, 999))      # the databases were recreated between install and departure
    g = w.stage('C', 'D')
    check('an invalid departure (the databases were recreated): nothing merged, no pin invented, the seat is reported not synced',
          w.committed()['pins'] == {'cli1': False} and g.result['not_synced'] == ['C'] and 'recreated' in g.f('report.txt') and w.committed()['seats']['C'] == {'dep': 'dBad'}, g.f('report.txt'))
    for name, bk, mk in (('no baseline at all, seat known to the state', None, {}), ('baseline without created', dict(created=None), {}), ('manifest lower than at install', dict(manifest=(5, 5)), {})):
        w = two(fresh())
        w.state({'cli1': False}, seats={'C': {'dep': 'old'}})
        w.set_pins('C', ['local_c1'])
        base = None if bk is None else w.baseline('C', [], write=False, **bk)
        w.marker('C', base, dep='dX', **mk)
        g = w.stage('C', 'D')
        check('%s: the seat contributes nothing and is reported' % name, w.committed()['pins'] == {'cli1': False} and g.result['not_synced'] == ['C'], g.f('report.txt'))
    w = two(fresh())
    w.state({'cli1': False})
    w.set_pins('C', ['local_c1'])
    w.marker('C', None, dep='dFirst')
    g = w.stage('C', 'D')
    check('the FIRST departure of a seat the state has never seen, with no baseline yet: nothing to compare, not a warning', g.result['not_synced'] == [] and 'first departure of C' in g.f('report.txt') and w.committed()['pins'] == {'cli1': False}, g.f('report.txt'))
    w = two(fresh())
    w.state({'cli1': False})
    open(os.path.join(w.seats, 'C', SS.DEPARTURE), 'w').write('{"dep"')
    g = w.stage('C', 'D')
    m_ = w.committed()['seats']['C']['dep']
    check('an unreadable marker is dismissed once (keyed by its content) and reported; it is not reported again', g.result['not_synced'] == ['C'] and m_.startswith('unreadable:') and w.stage('C', 'D', 'g2').result['not_synced'] == [])

    # ---- spec test 3: a pending marker, the stash re-installed, a second departure: the edits of BOTH activations merge once
    w = World(fresh())
    w.seat('A', 'aa', [])
    w.seat('B', 'ab', [])
    for nm, ac in (('a', 'aa'), ('b', 'ab')):
        w.rec(ac, 'local_%s1' % nm, 'cli1')
        w.rec(ac, 'local_%s2' % nm, 'cli2')
    w.state({'cli1': False, 'cli2': False})
    w.set_pins('A', ['local_a1', 'local_a2'])                                # cli1 pinned in activation 1, cli2 in activation 2
    lineage = w.baseline('A', [], gen='b1', created=(333, 444), write=False)  # the stash re-install kept the old gen/pins/manifest, refreshed `created`
    w.marker('A', lineage, dep='d2', created=(333, 444))
    g = w.stage('A', 'B')
    check('pending marker + stash re-install + second departure: both activations\' edits merged, once', w.committed()['pins'] == {'cli1': True, 'cli2': True} and g.result['not_synced'] == [], str(w.committed()))

    # ---- spec test 4: a refused switch after the commit, more edits on the departed seat: only the NEW edits apply
    w = two(fresh())
    w.state({'cli1': False, 'cli2': False})
    w.rec('ac', 'local_c2', 'cli2')
    w.rec('ad', 'local_d2', 'cli2')
    bc = w.baseline('C', [])
    w.set_pins('C', ['local_c1'])
    w.marker('C', bc, dep='d1', at=1)
    w.stage('C', 'D', 'rf1')                                                 # committed; then the switch is REFUSED and C stays live
    check('refused-switch setup: cli1 merged as pinned', w.committed()['pins'] == {'cli1': True, 'cli2': False})
    w.set_pins('C', ['local_c2'])                                            # more edits on C: cli1 unpinned, cli2 pinned
    w.marker('C', bc, dep='d2', at=2)                                        # C departs again; its baseline file is still the same install
    w.stage('C', 'D', 'rf2')
    check('only the new edits apply: the unpin of cli1 (seen against the last merged observation, not the install baseline) and the pin of cli2', w.committed()['pins'] == {'cli1': False, 'cli2': True}, str(w.committed()))

    # ---- spec test 6: a stage killed after the commit: the next stage does not replay
    w = two(fresh())
    w.state({'cli1': False})
    w.set_pins('C', ['local_c1'])
    w.marker('C', w.baseline('C', []), dep='dK')
    real_sd = SS.stage_databases

    def killed(*a, **k):
        raise KeyboardInterrupt('killed at the deadline')
    SS.stage_databases = killed
    try:
        try:
            w.stage('C', 'D', 'k1')
        except KeyboardInterrupt:
            pass
    finally:
        SS.stage_databases = real_sd
    st1 = w.committed()
    check('killed after the commit: the departure is already merged; no result.json exists for that gen (the rotator installs the stash pair)', st1['pins'] == {'cli1': True} and st1['seats']['C']['dep'] == 'dK'
          and not os.path.exists(os.path.join(w.seats, SS.WORK, 'k1', 'result.json')) and os.path.exists(os.path.join(w.seats, SS.WORK, 'k1', 'baseline-stash.json')))
    w.set_pins('C', [])                                                      # the departed seat edits again... and then the next stage runs for another seat
    g = w.stage('C', 'D', 'k2')
    check('the next stage does not replay the merged marker', clean(w.committed()) == clean(st1) and g.result['status'] in ('nothing', 'synced'), str(w.committed()))

    # ---- spec test 7: two pending markers apply in `at` order, not seat-name order
    w = World(fresh())
    for nm in 'ABC':
        w.seat(nm, 'a' + nm.lower(), [])
        w.rec('a' + nm.lower(), 'local_%s1' % nm.lower(), 'cli1')
    w.state({'cli1': False})
    ba = w.baseline('A', ['local_a1'])
    w.set_pins('A', [])                                                      # A unpins (the NEWER departure, at=20)
    w.marker('A', ba, dep='dA', at=20)
    bb = w.baseline('B', [])
    w.set_pins('B', ['local_b1'])                                            # B pins (the OLDER departure, at=10)
    w.marker('B', bb, dep='dB', at=10)
    g = w.stage('A', 'C')
    check('pending markers apply oldest `at` first: the newer unpin on A wins over the older pin on B (name order would give the opposite)', w.committed()['pins'] == {'cli1': False}, str(w.committed()))

    # ---- a failed commit is a Skip: no staged copy is built
    w = two(fresh())
    w.state({'cli1': False})
    w.set_pins('C', ['local_c1'])
    w.marker('C', w.baseline('C', []), dep='dF')
    real_replace = os.replace

    def failing_replace(src, dst, *a, **k):
        if os.path.basename(str(dst)) == SS.STATE:
            raise OSError('disk full')
        return real_replace(src, dst, *a, **k)
    os.replace = failing_replace
    try:
        g = w.stage('C', 'D', 'fc1')
    finally:
        os.replace = real_replace
    check('the state could not be committed: the stage is skipped with that reason, nothing is staged, the old state stays, the stash pair\'s files are there', g.result['status'] == 'skipped' and 'could not be written' in g.result['reason']
          and not g.staged and w.committed()['seats'] == {} and g.f('baseline-stash.json') is not None and g.f('stash-result.json') is not None, str(g.result))

    # ---- unpin reaches the target; the last remaining pin can be unpinned
    w = two(fresh())
    w.set_pins('D', ['local_d1', 'local_foreign'])
    w.state({'cli1': True})
    b = w.baseline('C', ['local_c1'])
    w.set_pins('C', [])
    w.marker('C', b)
    g = w.stage('C', 'D')
    check('departure unpin (the last remaining pin) reaches the target; an unmapped foreign pin is kept in both stores', g.staged and g.pins() == ['local_foreign'] and w.committed()['pins'] == {'cli1': False}, str(g.pins()) + g.out)

    # ---- no marker at all: nothing observed
    w = two(fresh())
    w.state({'cli1': False})
    w.set_pins('C', ['local_c1'])
    g = w.stage('C', 'D')
    check('no marker: nothing observed, nothing staged', g.result['status'] == 'nothing' and w.committed()['pins'] == {'cli1': False})

    # ---- a vanished record and a replacement copy are no removal
    w = two(fresh())
    w.set_pins('D', ['local_d1'])
    w.state({'cli1': True})
    b = w.baseline('C', ['local_c1'])
    w.set_pins('C', [])
    w.drop_rec('ac', 'local_c1')            # the pinned copy vanished
    w.rec('ac', 'local_c2', 'cli1')         # a replacement copy, not in the baseline
    w.marker('C', b)
    g = w.stage('C', 'D')
    check('vanished record + unpinned replacement copy: no removal', g.result['status'] == 'nothing' and w.committed()['pins'] == {'cli1': True}, g.out)

    # ---- S77: a cli with one copy unpinned and another pinned stays pinned
    w = two(fresh())
    w.rec('ac', 'local_c2', 'cli1', org='org2')
    w.set_pins('D', [])
    w.state({'cli1': True})
    b = w.baseline('C', ['local_c1'])
    w.set_pins('C', ['local_c2'])           # copy 1 unpinned, copy 2 (other org folder) pinned
    w.marker('C', b)
    g = w.stage('C', 'D')
    check('S77: one copy unpinned and another pinned stays pinned, per cli across two org folders', w.committed()['pins'] == {'cli1': True} and g.pins() == ['local_d1'], g.out)

    # ---- per cli on the TARGET
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

    # ---- no copy on the target is counted and named, not added
    w = two(fresh())
    w.rec('ac', 'local_c9', 'cli9', title='Only on C')
    w.state({'cli1': False, 'cli9': True})
    g = w.stage('C', 'D')
    check('a pinned session the target has no record for is counted and named, nothing added', g.result['status'] == 'nothing' and 'no copy: Only on C (cli9)' in g.f('report.txt') and ': 1' in g.f('report.txt').split('no copy on D')[1].splitlines()[0], g.f('report.txt'))

    # ---- an id in no record, or a record without cliSessionId, is never added or removed
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

    # ---- no state yet: the target's own pins are adopted as it is entered (there is no first-switch scan of the other seats)
    w = two(fresh())
    w.set_pins('D', ['local_d1'])
    g = w.stage('C', 'D')
    check('no state file yet: nothing is read from the other seats; the target keeps its pin and it is recorded as observed intent', g.result['status'] == 'nothing' and w.committed()['pins'] == {'cli1': True} and w.committed()['seats'] == {}, str(w.committed()))
    w = two(fresh())
    w.set_pins('D', ['local_d1'])
    w.state({})
    g = w.stage('C', 'D')
    check('unknown cli: the target keeps its pin and it is recorded as observed intent', g.result['status'] == 'nothing' and w.committed()['pins'] == {'cli1': True})

    # ---- F1a: the stash pair's baseline + config outcome are produced first and kept when the stage is Skipped
    w = two(fresh())
    w.set_pins('D', ['local_d1'])
    open(os.path.join(w.seats, SS.STATE), 'w').write('{broken')
    cfgp = os.path.join(w.app, 'claude_desktop_config.json')
    open(cfgp, 'wb').write(json.dumps({'preferences': {'epitaxyPrefs': {'starred-local-code-sessions': ['stale']}}}, indent=2, ensure_ascii=False).encode('utf-8'))
    g = w.stage('C', 'D', 'gs1')
    sr = g.f('stash-result.json')
    check('a Skipped stage (unreadable state) still leaves the stash pair\'s baseline (the target\'s own pins), its config outcome and stash-result.json', g.result['status'] == 'skipped' and g.f('baseline-stash.json')['pins'] == ['local_d1']
          and 'valid' not in g.f('baseline-stash.json') and sr['target'] == 'D' and sr['gen'] == 'gs1' and sr['config'] == 'prepared' and g.f('config-stash.json')['pair'] == 'stash'
          and g.result['config'] == 'prepared' and g.result['config_pair'] == 'stash', str(g.result) + str(sr))
    check('unreadable state file: no staging, reported on the Sidebar line, the file itself untouched', g.rc == 0 and not g.staged and 'Sidebar: skipped (' in g.out and open(os.path.join(w.seats, SS.STATE)).read() == '{broken', g.out)
    w = two(fresh())
    json.dump({'version': 1, 'gen': 'x', 'pins': {}}, open(os.path.join(w.seats, SS.STATE), 'w'))
    check('a state of another version is not read: skipped, not migrated', w.stage('C', 'D').result['status'] == 'skipped')

    # ---- F1c: a departure that could not be read is on the line the dashboard shows
    w = two(fresh())
    w.state({'cli1': False}, seats={'C': {'dep': 'old'}})
    w.set_pins('C', ['local_c1'])
    w.marker('C', w.baseline('C', [], created=None), dep='dN')
    g = w.stage('C', 'D', 'gn1')
    check('a departure that was not synced is on the Sidebar line, not only in report.txt', g.result['not_synced'] == ['C'] and 'Sidebar: nothing to sync; edits on C not synced - see ' in g.out and g.out.strip().endswith('report.txt'), g.out)
    check('summary line forms', SS.summary_line({'status': 'synced', 'n': 2, 'not_synced': ['C', 'E']}, 'R') == 'Sidebar: synced 2 pins; edits on C, E not synced - see R'
          and SS.summary_line({'status': 'synced', 'n': 1}, 'R') == 'Sidebar: synced 1 pins.')

    # ---- F1b: the target's stash is read ONCE per stage (staging reuses it)
    w = two(fresh())
    w.state({'cli1': True})
    reads = []
    real_rp = SS.read_pins

    def counting_rp(ls, idb):
        reads.append(ls)
        return real_rp(ls, idb)
    SS.read_pins = counting_rp
    try:
        g = w.stage('C', 'D', 'gr1')
    finally:
        SS.read_pins = real_rp
    stash_reads = [r for r in reads if SS.WORK not in r and os.sep + 'D' + os.sep in r]
    check('the target stash is read once in a staging stage (the staged copy is verified separately)', g.staged and len(stash_reads) == 1, str(reads))

    # ---- refusals: the writer cannot stage (two recovery logs) -> skipped, the state still committed, baseline-stash there, no staged dirs
    w = two(fresh())
    w.state({'cli1': True})
    ld = os.path.join(w.seats, 'D', 'Local Storage', 'leveldb')
    open(os.path.join(ld, '000004.log'), 'wb').write(frame([batch(9, [(b'q', b'q')])]))
    g = w.stage('C', 'D')
    check('writer refusal: skipped with the reason, no staged dirs, the stash baseline is there, the state was committed before', g.result['status'] == 'skipped' and not g.staged and 'staging refused' in g.result['reason']
          and g.f('baseline-stash.json') is not None and w.committed()['pins'] == {'cli1': True} and 'Sidebar: skipped (staging refused' in g.out, g.out)

    # ---- config: written to the gen only when the list differs, with the shared config's other keys untouched
    w = two(fresh())
    w.state({'cli1': True})
    cfg = {'preferences': {'epitaxyPrefs': {'starred-local-code-sessions': ['local_x'], 'other': {'k': 1}}}, 'top': True}
    cp = os.path.join(w.app, 'claude_desktop_config.json')
    open(cp, 'wb').write(json.dumps(cfg, indent=2, ensure_ascii=False).encode('utf-8'))
    g = w.stage('C', 'D')
    c = g.f('config.json')
    newcfg = json.loads(__import__('base64').b64decode(c['b64']))
    check('result.json carries the config outcome for the installed pair: prepared', g.result['config'] == 'prepared' and g.result['config_pair'] == 'staged', str(g.result))
    check('config.json: pair staged, hash of the config read, only the pin list changed',
          c['pair'] == 'staged' and c['sha256'] == SS.sha256_file(cp) and newcfg['preferences']['epitaxyPrefs']['starred-local-code-sessions'] == ['local_d1']
          and newcfg['preferences']['epitaxyPrefs']['other'] == {'k': 1} and newcfg['top'] is True)
    check('the live config is untouched by the stage', json.load(open(cp)) == cfg)
    w.install(g, 'D')
    cfg['preferences']['epitaxyPrefs']['starred-local-code-sessions'] = ['local_d1']
    open(cp, 'wb').write(json.dumps(cfg, indent=2, ensure_ascii=False).encode('utf-8'))
    g = w.stage('C', 'D', 'g2')
    check('config already holding the pins: no config.json, and the outcome says match explicitly', g.f('config.json') is None and g.result['config'] == 'match', str(g.result))
    cfg['preferences']['epitaxyPrefs']['starred-local-code-sessions'] = []
    open(cp, 'wb').write(json.dumps(cfg, indent=2, ensure_ascii=False).encode('utf-8'))
    g = w.stage('C', 'D', 'g3')
    check('no pin change but a stale config: a config-only repair, prepared for the stash pair in config-stash.json', g.f('config-stash.json')['pair'] == 'stash' and g.f('config.json') is None and not g.staged and g.result['config'] == 'prepared' and g.result['config_pair'] == 'stash', str(g.result))
    open(cp, 'wb').write(b'{"preferences": {"epitaxyPrefs": {"starred-local-code-sessions": []}}}')
    g = w.stage('C', 'D', 'g4')
    check('a config that does not round-trip byte for byte is never rewritten, and the outcome is an explicit refusal (not an omission)', g.f('config.json') is None and 'config not changed' in g.f('report.txt') and g.result['config'].startswith('refused: config not changed'), str(g.result))
    os.unlink(cp)
    g = w.stage('C', 'D', 'g5')
    check('an unreadable (missing) config is a refusal too', g.result['config'].startswith('refused:'), str(g.result))

    # ---- --forget removes the baseline and the marker, under the seat lock
    w = two(fresh())
    w.marker('C', w.baseline('C', ['x']))
    with contextlib.redirect_stdout(io.StringIO()):
        rc = SS.main(['--forget', 'C', '--seats', w.seats, '--app', w.app])
    check('--forget drops the baseline and the departure marker', rc == 0 and not os.path.exists(os.path.join(w.seats, 'C', SS.BASELINE)) and not os.path.exists(os.path.join(w.seats, 'C', SS.DEPARTURE)))
    w = two(fresh())
    w.baseline('C', ['x'])
    lk = os.open(os.path.join(w.seats, '.seat-write.lock'), os.O_CREAT | os.O_EXCL | os.O_WRONLY)
    out = io.StringIO()
    try:
        with contextlib.redirect_stdout(out):
            rc = SS.main(['--forget', 'C', '--seats', w.seats, '--app', w.app])
        check('--forget refuses while a switch holds the seat lock and changes nothing', rc == 1 and 'refused' in out.getvalue() and os.path.exists(os.path.join(w.seats, 'C', SS.BASELINE)), out.getvalue())
    finally:
        os.close(lk)
        os.unlink(os.path.join(w.seats, '.seat-write.lock'))
    with contextlib.redirect_stdout(io.StringIO()):
        rc = SS.main(['--forget', 'C', '--seats', w.seats, '--app', w.app])
    check('--forget works when the lock is free and releases it', rc == 0 and not os.path.exists(os.path.join(w.seats, '.seat-write.lock')))

    # ---- result.json names target, generation and pair; a generation is used once
    w = two(fresh())
    w.state({'cli1': True})
    g = w.stage('C', 'D', 'gen-a')
    check('result.json names the target, the generation and the pair that exists', g.result['target'] == 'D' and g.result['gen'] == 'gen-a' and g.result['pair'] == 'staged' and g.staged, str(g.result))
    again = w.stage('C', 'D', 'gen-a')
    check('a generation that already has a result is refused (exit 1), its files are not touched', again.rc == 1 and g.f('result.json')['gen'] == 'gen-a')
    w.install(g, 'D')
    g2 = w.stage('C', 'D', 'gen-b')
    check('a stage with nothing to stage says pair stash', g2.result['pair'] == 'stash' and g2.result['gen'] == 'gen-b' and not g2.staged)

    # ---- dry run writes nothing and reports
    w = two(fresh())
    w.state({'cli1': True})
    before = sorted(os.listdir(w.seats)) + ['.sync-history.lock']
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        rc = SS.main(['--dry-run', '--target', 'D', '--leaving', 'C', '--leaving-stash', '--seats', w.seats, '--app', w.app])
    check('dry run: lists the pin with its title, writes nothing', rc == 0 and 'pin t-local_d1' in out.getvalue() and sorted(set(os.listdir(w.seats)) | {'.sync-history.lock'}) == sorted(before) and not os.path.exists(os.path.join(w.seats, SS.WORK)), out.getvalue())

    # ---- verify
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
    json.dump({'lastKnownAccountUuid': 'ad'}, open(os.path.join(w.app, 'config.json'), 'w'))
    b_ = json.load(open(os.path.join(w.seats, 'D', SS.BASELINE)))
    b_['created'] = {'ls': 5, 'idb': 6}
    json.dump(b_, open(os.path.join(w.seats, 'D', SS.BASELINE), 'w'))
    SS.run_verify(ns, pids=lambda: [1], sleep=lambda s: None)
    check('verify: a later install rewrote the baseline (other created) -> superseded', 'superseded' in open(os.path.join(w.seats, SS.WORK, 'g7', 'verify.txt')).read())
    # a stash-lineage switch: the baseline keeps an OLDER gen and pins; verification uses this install's own record and is not superseded
    b_.update({'gen': 'old-lineage', 'pins': ['stale'], 'created': {'ls': 111, 'idb': 222}})
    json.dump(b_, open(os.path.join(w.seats, 'D', SS.BASELINE), 'w'))
    json.dump({'preferences': {'epitaxyPrefs': {'starred-local-code-sessions': ['local_d1']}}}, open(os.path.join(w.app, 'claude_desktop_config.json'), 'w'))
    SS.run_verify(ns, pids=lambda: [1], sleep=lambda s: None)
    v = open(os.path.join(w.seats, SS.WORK, 'g7', 'verify.txt')).read()
    check('verify: a stash-lineage switch (baseline gen and pins older than this install) is verified against the install record, not superseded', 'superseded' not in v and 'differences=0' in v, v)
    ns.gen = 'other'
    os.makedirs(os.path.join(w.seats, SS.WORK, 'other'))
    SS.run_verify(ns, pids=lambda: [1], sleep=lambda s: None)
    check('verify: no install record for the generation -> could not check', 'could not check' in open(os.path.join(w.seats, SS.WORK, 'other', 'verify.txt')).read())


def idle_priority():
    """Owner rule 10e: the test and every child it starts run at IDLE priority."""
    if os.name == 'nt':
        import ctypes
        ctypes.windll.kernel32.SetPriorityClass(ctypes.windll.kernel32.GetCurrentProcess(), 0x00000040)


def main():
    idle_priority()
    tmp = tempfile.mkdtemp(prefix='sidebar-sync-test-')
    try:
        test_ldb(tmp)
        test_v8_versions()
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
