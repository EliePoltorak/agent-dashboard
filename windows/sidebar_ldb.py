"""LevelDB reader and a guarded one-batch writer for the Claude desktop app's sidebar pin stores. Stdlib only.

Used by sidebar-sync.py (issue #10). Ported from the proof-of-concept (ldb_read.py, idb_put.py) and made manifest-aware:
the reader follows CURRENT -> MANIFEST (VersionEdits: log number, prev log number, last sequence, new/deleted files), reads the
live tables plus the logs leveldb itself would replay, and verifies every log CRC. The writer appends ONE batch to the single
recovery log of a STAGING copy and refuses (LdbError, nothing written) in every case it cannot prove safe.

Never open a live database with this module's writer: the caller works on a copy only.
"""
import os
import re
import struct

BLOCK = 32768
TABLE_MAGIC = bytes.fromhex('57fb808b247547db')


class LdbError(Exception):
    """The database is not in a shape this module can read or safely write."""


# ---- primitives ----------------------------------------------------------------------------------------------------------

def varint(b, i):
    r = s = 0
    while True:
        if i >= len(b):
            raise LdbError('truncated varint')
        c = b[i]
        i += 1
        r |= (c & 0x7F) << s
        s += 7
        if not c & 0x80:
            return r, i
        if s > 70:
            raise LdbError('varint too long')


def uvarint(n):
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        out.append(b | (0x80 if n else 0))
        if not n:
            return bytes(out)


def lp_slice(b, i):
    n, i = varint(b, i)
    if i + n > len(b):
        raise LdbError('truncated slice')
    return b[i:i + n], i + n


def snappy_decompress(b):
    n, i = varint(b, 0)
    out = bytearray()
    while i < len(b):
        tag = b[i]
        i += 1
        t = tag & 3
        if t == 0:
            ln = tag >> 2
            if ln >= 60:
                nb = ln - 59
                ln = int.from_bytes(b[i:i + nb], 'little')
                i += nb
            ln += 1
            if i + ln > len(b):
                raise LdbError('bad snappy literal')
            out += b[i:i + ln]
            i += ln
            continue
        if t == 1:
            ln = ((tag >> 2) & 7) + 4
            off = ((tag >> 5) << 8) | b[i]
            i += 1
        elif t == 2:
            ln = (tag >> 2) + 1
            off = int.from_bytes(b[i:i + 2], 'little')
            i += 2
        else:
            ln = (tag >> 2) + 1
            off = int.from_bytes(b[i:i + 4], 'little')
            i += 4
        if off == 0 or off > len(out):
            raise LdbError('bad snappy offset')
        for _ in range(ln):  # byte-wise: copies may overlap
            out.append(out[-off])
    if len(out) != n:
        raise LdbError('snappy length mismatch')
    return bytes(out)


_T = []
for _i in range(256):
    _c = _i
    for _ in range(8):
        _c = (_c >> 1) ^ 0x82F63B78 if _c & 1 else _c >> 1
    _T.append(_c)


def crc32c(b):
    c = 0xFFFFFFFF
    for x in b:
        c = _T[(c ^ x) & 0xFF] ^ (c >> 8)
    return c ^ 0xFFFFFFFF


def mask_crc(c):
    return ((((c >> 15) | (c << 17)) & 0xFFFFFFFF) + 0xA282EAD8) & 0xFFFFFFFF


# ---- tables --------------------------------------------------------------------------------------------------------------

def _read_block(f, off, size):
    f.seek(off)
    raw = f.read(size + 5)
    if len(raw) != size + 5:
        raise LdbError('short block')
    data, ctype = raw[:size], raw[size]
    if ctype == 1:
        data = snappy_decompress(data)
    elif ctype != 0:
        raise LdbError('unknown compression %d' % ctype)
    return data


def _block_entries(data):
    if len(data) < 4:
        raise LdbError('short block')
    nrest = struct.unpack('<I', data[-4:])[0]
    end = len(data) - 4 - 4 * nrest
    if end < 0:
        raise LdbError('bad restart array')
    i, key = 0, b''
    while i < end:
        shared, i = varint(data, i)
        unshared, i = varint(data, i)
        vlen, i = varint(data, i)
        if shared > len(key) or i + unshared + vlen > end:
            raise LdbError('bad block entry')
        key = key[:shared] + data[i:i + unshared]
        i += unshared
        yield key, data[i:i + vlen]
        i += vlen


def read_table(path):
    """Yield (user_key, seq, type, value) for every entry of one .ldb/.sst table."""
    try:
        with open(path, 'rb') as f:
            f.seek(-48, 2)
            foot = f.read(48)
            if foot[-8:] != TABLE_MAGIC:
                raise LdbError('bad table magic: %s' % os.path.basename(path))
            _, j = varint(foot, 0)
            _, j = varint(foot, j)
            ioff, j = varint(foot, j)
            isz, j = varint(foot, j)
            for _, h in _block_entries(_read_block(f, ioff, isz)):
                doff, k = varint(h, 0)
                dsz, k = varint(h, k)
                for ikey, val in _block_entries(_read_block(f, doff, dsz)):
                    if len(ikey) < 8:
                        raise LdbError('short internal key')
                    tagnum = struct.unpack('<Q', ikey[-8:])[0]
                    yield ikey[:-8], tagnum >> 8, tagnum & 0xFF, val
    except (OSError, struct.error, IndexError) as e:
        raise LdbError('%s: %s' % (os.path.basename(path), e))


# ---- logs ----------------------------------------------------------------------------------------------------------------

def log_records(path):
    """-> (records, clean). Every complete, CRC-valid logical record in a leveldb log file; `clean` is False when anything follows the
    last good record (a torn or corrupt tail, an unfinished fragment). A zero-filled tail (block padding) is clean."""
    with open(path, 'rb') as f:
        data = f.read()
    recs, pos, frag, clean = [], 0, None, True
    while pos < len(data):
        left = BLOCK - pos % BLOCK
        if left < 7:                                     # block trailer padding
            if any(data[pos:pos + left]):
                clean = False
                break
            pos += left
            continue
        if pos + 7 > len(data):
            clean = not any(data[pos:])
            break
        crc, ln, typ = struct.unpack('<IHB', data[pos:pos + 7])
        if typ == 0 and ln == 0 and crc == 0:            # zero fill
            clean = not any(data[pos:])
            break
        if typ not in (1, 2, 3, 4) or ln > left - 7 or pos + 7 + ln > len(data):
            clean = False
            break
        payload = data[pos + 7:pos + 7 + ln]
        if mask_crc(crc32c(bytes([typ]) + payload)) != crc:
            clean = False
            break
        pos += 7 + ln
        if typ == 1:
            if frag is not None:
                clean = False
                break
            recs.append(payload)
        elif typ == 2:
            if frag is not None:
                clean = False
                break
            frag = payload
        elif typ == 3:
            if frag is None:
                clean = False
                break
            frag += payload
        else:
            if frag is None:
                clean = False
                break
            recs.append(frag + payload)
            frag = None
    if frag is not None:
        clean = False
    return recs, clean


def decode_batch(rec):
    """-> (seq, [(type, key, value|None)])."""
    if len(rec) < 12:
        raise LdbError('short batch')
    seq, cnt = struct.unpack('<QI', rec[:12])
    i, ops = 12, []
    for _ in range(cnt):
        if i >= len(rec):
            raise LdbError('truncated batch')
        t = rec[i]
        i += 1
        k, i = lp_slice(rec, i)
        v = None
        if t == 1:
            v, i = lp_slice(rec, i)
        elif t != 0:
            raise LdbError('bad batch op %d' % t)
        ops.append((t, k, v))
    if i != len(rec):
        raise LdbError('trailing bytes in batch')
    return seq, ops


# ---- manifest ------------------------------------------------------------------------------------------------------------

class Manifest:
    def __init__(self):
        self.number = 0
        self.comparator = ''
        self.log_number = 0
        self.prev_log_number = 0
        self.next_file = 0
        self.last_sequence = 0
        self.files = {}        # table number -> level


def read_manifest(d):
    try:
        cur = open(os.path.join(d, 'CURRENT'), 'rb').read().decode('ascii').strip()
    except (OSError, UnicodeDecodeError) as e:
        raise LdbError('CURRENT unreadable: %s' % e)
    m = re.fullmatch(r'MANIFEST-(\d+)', cur)
    if not m:
        raise LdbError('CURRENT names no manifest: %r' % cur)
    mf = Manifest()
    mf.number = int(m.group(1))
    try:
        recs, clean = log_records(os.path.join(d, cur))
    except OSError as e:
        raise LdbError('manifest unreadable: %s' % e)
    if not recs:
        raise LdbError('manifest is empty')
    for rec in recs:                                      # a torn manifest tail is ignored, as leveldb does
        i = 0
        while i < len(rec):
            tag, i = varint(rec, i)
            if tag == 1:
                s, i = lp_slice(rec, i)
                mf.comparator = s.decode('latin-1')
            elif tag == 2:
                mf.log_number, i = varint(rec, i)
            elif tag == 3:
                mf.next_file, i = varint(rec, i)
            elif tag == 4:
                mf.last_sequence, i = varint(rec, i)
            elif tag == 5:
                _, i = varint(rec, i)
                _, i = lp_slice(rec, i)
            elif tag == 6:
                _, i = varint(rec, i)
                n, i = varint(rec, i)
                mf.files.pop(n, None)
            elif tag == 7:
                lvl, i = varint(rec, i)
                n, i = varint(rec, i)
                _, i = varint(rec, i)
                _, i = lp_slice(rec, i)
                _, i = lp_slice(rec, i)
                mf.files[n] = lvl
            elif tag == 9:
                mf.prev_log_number, i = varint(rec, i)
            else:
                raise LdbError('unknown manifest tag %d' % tag)
    return mf


def _file_no(name, ext):
    m = re.fullmatch(r'(\d+)\.' + ext, name)
    return int(m.group(1)) if m else None


def recovery_logs(d, mf):
    """The .log files leveldb replays when it opens this database: number >= the manifest's log number, or == its prev log number."""
    out = []
    for name in os.listdir(d):
        n = _file_no(name, 'log')
        if n is not None and (n >= mf.log_number or n == mf.prev_log_number):
            out.append((n, os.path.join(d, name)))
    return sorted(out)


def table_path(d, n):
    for ext in ('ldb', 'sst'):
        p = os.path.join(d, '%06d.%s' % (n, ext))
        if os.path.exists(p):
            return p
    raise LdbError('live table %06d is missing' % n)


class Snapshot:
    """What leveldb would see on open: .entries {user_key: (seq, value)} (deletions removed), .max_seq, .manifest, .logs [(n, path)], .clean."""

    def __init__(self):
        self.entries = {}
        self.max_seq = 0
        self.manifest = None
        self.logs = []
        self.clean = True


def read_snapshot(d):
    mf = read_manifest(d)
    snap = Snapshot()
    snap.manifest = mf
    best = {}

    def take(k, seq, t, v):
        if seq > snap.max_seq:
            snap.max_seq = seq
        if k not in best or seq > best[k][0]:
            best[k] = (seq, t, v)

    for n in sorted(mf.files):
        for k, seq, t, v in read_table(table_path(d, n)):
            take(k, seq, t, v)
    snap.logs = recovery_logs(d, mf)
    for n, p in snap.logs:
        try:
            recs, clean = log_records(p)
        except OSError as e:
            raise LdbError('log %06d unreadable: %s' % (n, e))
        if not clean:
            snap.clean = False
        for rec in recs:
            seq, ops = decode_batch(rec)
            for j, (t, k, v) in enumerate(ops):
                take(k, seq + j, t, v)
    snap.entries = {k: (s, v) for k, (s, t, v) in best.items() if t == 1}
    return snap


def read_db(d):
    """-> {user_key: value}: the live contents of a leveldb directory."""
    return {k: v for k, (s, v) in read_snapshot(d).entries.items()}


# ---- guarded writer (staging copies only) ----------------------------------------------------------------------------------

def append_batch(d, puts):
    """Append ONE write batch of `puts` [(key, value)] to the only recovery log of leveldb directory `d` (a staging copy) and return its
    sequence number. Refuses (LdbError, nothing written) unless exactly one recovery log exists (the only log leveldb replays) and it has
    no torn tail. Sequence = max(manifest last sequence, highest live entry) + 1; one write, fsync, then CRCs and the keys are re-read."""
    if not puts:
        raise LdbError('nothing to write')
    snap = read_snapshot(d)
    mf = snap.manifest
    if len(snap.logs) != 1:
        raise LdbError('expected exactly one recovery log, found %d' % len(snap.logs))
    n, path = snap.logs[0]
    # Chromium opens its databases with reuse_logs, so the single log leveldb replays can be NEWER than the manifest's log number (a database that
    # has not rotated its log since it was created has log number 0 and one log). What matters is that it is the only log leveldb replays.
    if mf.prev_log_number not in (0, n):
        raise LdbError('the manifest names a previous log that is not the recovery log')
    if not snap.clean:
        raise LdbError('the recovery log has a torn tail')
    seq = max(mf.last_sequence, snap.max_seq) + 1
    batch = struct.pack('<QI', seq, len(puts))
    for k, v in puts:
        batch += b'\x01' + uvarint(len(k)) + k + uvarint(len(v)) + v
    size = os.path.getsize(path)
    pos, data, first, out = size, batch, True, bytearray()
    while True:
        left = BLOCK - pos % BLOCK
        if left < 7:
            out += b'\x00' * left
            pos += left
            continue
        cnt = min(len(data), left - 7)
        last = cnt == len(data)
        typ = (1 if last else 2) if first else (4 if last else 3)
        frag = data[:cnt]
        out += struct.pack('<IHB', mask_crc(crc32c(bytes([typ]) + frag)), cnt, typ) + frag
        pos += 7 + cnt
        data = data[cnt:]
        first = False
        if last:
            break
    with open(path, 'ab') as f:
        f.write(out)
        f.flush()
        os.fsync(f.fileno())
    after = read_snapshot(d)                              # CRCs re-verified by the read; every key read back
    if not after.clean or after.max_seq < seq + len(puts) - 1:
        raise LdbError('the log does not re-read cleanly after the write')
    for k, v in puts:
        if after.entries.get(k, (0, None))[1] != v:
            raise LdbError('a written key does not read back')
    return seq


# ---- value codecs ------------------------------------------------------------------------------------------------------------

LS_ORIGIN = b'_https://claude.ai\x00\x01'


def ls_key(name):
    return LS_ORIGIN + name.encode('latin-1')


def ls_decode(b):
    if not b:
        return ''
    if b[0] == 1:
        return b[1:].decode('latin-1')
    if b[0] == 0:
        return b[1:].decode('utf-16-le')
    raise LdbError('unknown local storage value prefix %d' % b[0])


def ls_encode(s):
    try:
        return b'\x01' + s.encode('latin-1')
    except UnicodeEncodeError:
        return b'\x00' + s.encode('utf-16-le')


_IDB_NAME = 'store:pin-state:dframe-starred-code'


def idb_pin_key(db):
    """The IndexedDB object-store data key of the pin state in `db` ({key: value}), or None unless exactly one key matches."""
    n16 = _IDB_NAME.encode('utf-16-be')
    tail = b'\x01' + bytes([len(_IDB_NAME)]) + n16
    hits = [k for k in db if len(k) == 4 + len(tail) and k[0] == 0 and k[3] == 1 and k[4:] == tail]
    return hits[0] if len(hits) == 1 else None


V8_VERSIONS = (0x0f, 0x10)       # the wire-format versions seen on real seats (seat A writes 0x0f, B-F 0x10); any other is refused by name


def _v8_tail(value):
    """-> (i, version, j): the V8 one-byte string that is the whole tail of `value` starts after `\\xff <version> "` at i, its text at j. LdbError (naming
    an unsupported version) otherwise."""
    i = value.find(b'\xff')
    while i != -1:
        if i + 2 < len(value) and value[i + 2] == 0x22:
            try:
                ln, j = varint(value, i + 3)
            except LdbError:
                ln = j = None
            if j is not None and j + ln == len(value):
                if value[i + 1] not in V8_VERSIONS:
                    raise LdbError('IndexedDB value uses V8 wire version 0x%02x, which is not supported (0x%s are)' % (value[i + 1], ', 0x'.join('%02x' % v for v in V8_VERSIONS)))
                return i, value[i + 1], j
        i = value.find(b'\xff', i + 1)
    raise LdbError('IndexedDB value is not a one-byte V8 string')


def idb_json(value):
    """The JSON text inside a V8-serialized one-byte string IndexedDB value (after the version varint and the envelope). LdbError if it is not one."""
    i, ver, j = _v8_tail(value)
    return value[j:].decode('latin-1')


def idb_replace(old, new_json):
    """`old` with its V8 one-byte string replaced by new_json (ASCII only); key, version prefix, envelope and the string's own header (including its
    wire version byte) kept. LdbError otherwise."""
    try:
        b = new_json.encode('ascii')
    except UnicodeEncodeError:
        raise LdbError('non-ASCII text in an IndexedDB value: not staged')
    i, ver, j = _v8_tail(old)
    return old[:i + 3] + uvarint(len(b)) + b
