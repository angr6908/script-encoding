import struct
import sys


def top_boxes(f):
    pos = 0
    out = {}
    while True:
        f.seek(pos)
        h = f.read(8)
        if len(h) < 8:
            break
        size, typ = struct.unpack(">I4s", h)
        if size == 1:
            size = struct.unpack(">Q", f.read(8))[0]
        out.setdefault(typ.decode("latin-1"), (pos, size))
        pos += size
    return out


def dcd_fields(buf, esds_at):
    q = esds_at + 8
    while buf[q] != 0x04:
        q += 1
    q += 1
    while buf[q] & 0x80:
        q += 1
    return q + 3


def read_fields(buf, o):
    return (int.from_bytes(buf[o:o + 3], "big"), *struct.unpack(">II", buf[o + 3:o + 11]))


def source_values(path):
    with open(path, "rb") as f:
        mo, ms = top_boxes(f)["moov"]
        f.seek(mo)
        m = f.read(ms)
    return read_fields(m, dcd_fields(m, m.find(b"esds")))


def main():
    if len(sys.argv) < 3:
        print("usage: ffmpeg-fix-aac-vbr-header.py <merged.mp4> <audio1.m4a> [audio2.m4a ...]", file=sys.stderr)
        sys.exit(2)
    merged = sys.argv[1]
    targets = [source_values(p) for p in sys.argv[2:]]
    with open(merged, "r+b") as f:
        mo, ms = top_boxes(f)["moov"]
        f.seek(mo)
        m = f.read(ms)
        plan = []
        i = 0
        for k, target in enumerate(targets, 1):
            i = m.find(b"esds", i + 1)
            if i < 0:
                sys.exit(f"audio {k}: no esds found, nothing changed")
            o = dcd_fields(m, i)
            cur = read_fields(m, o)
            b = m.find(b"btrt", i, i + 256)
            bcur = struct.unpack(">III", m[b + 4:b + 16]) if b > 0 else None
            if cur == target and bcur in (None, target):
                print(f"audio {k}: already {target}")
                continue
            if cur[0] != 0:
                sys.exit(f"audio {k}: unexpected header {cur}, nothing changed")
            plan.append((k, o, b if bcur is not None else None, cur, target))
        for k, o, b, cur, (buf, mx, av) in plan:
            f.seek(mo + o)
            f.write(buf.to_bytes(3, "big") + struct.pack(">II", mx, av))
            if b is not None:
                f.seek(mo + b + 4)
                f.write(struct.pack(">III", buf, mx, av))
            print(f"audio {k}: {cur} -> {(buf, mx, av)}")


main()
