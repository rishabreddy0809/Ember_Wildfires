"""Shrinks the globe's data files for the web.

    python3 tools/pack.py data/fires.bin data/fires.pack lat,lon,frp,sensor
    python3 tools/pack.py data/land.bin  data/land.pack  lat,lon

Input (.bin): a little-endian uint32 count n, then one array per column, each n long:
lat and lon are int16 (degrees x 100), frp is uint16 (MW x 10), sensor is uint8
(0 = MODIS, 1 = VIIRS).

Output (.pack): the same rows, sorted by place so neighbours sit together, then gzipped.
lat and lon are stored as differences from the previous row (mod 2^16), and every 16-bit
column is split into its low bytes then its high bytes. Both tricks make the bytes far more
repetitive, so gzip squeezes the fire file to about 30% of its size. js/lib.js undoes it.
The order of rows changes; nothing on the page depends on it.
"""
import array, gzip, struct, sys

TYPES = {"lat": "h", "lon": "h", "frp": "H", "sensor": "B"}

src, dst, names = sys.argv[1], sys.argv[2], sys.argv[3].split(",")
raw = open(src, "rb").read()
n = struct.unpack_from("<I", raw, 0)[0]
cols, at = {}, 4
for name in names:
    a = array.array(TYPES[name])
    a.frombytes(raw[at:at + a.itemsize * n])
    cols[name] = list(a)
    at += a.itemsize * n
assert at == len(raw), "file size doesn't match the columns given"

rows = sorted(zip(*(cols[k] for k in names)))           # by latitude, then longitude
out = bytearray(struct.pack("<I", n))
for k, name in enumerate(names):
    values = [r[k] for r in rows]
    if name in ("lat", "lon"):
        prev, deltas = 0, []
        for v in values:
            deltas.append((v - prev) & 0xFFFF)
            prev = v
        values = deltas
    if TYPES[name] == "B":
        out += bytes(values)
    else:
        values = [v & 0xFFFF for v in values]
        out += bytes(v & 0xFF for v in values) + bytes(v >> 8 for v in values)
open(dst, "wb").write(gzip.compress(bytes(out), 9, mtime=0))
print(f"{src}: {len(raw):,} bytes -> {dst}: {len(open(dst, 'rb').read()):,} bytes ({n:,} rows)")
