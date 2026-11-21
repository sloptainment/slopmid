import sys, struct
d = open(sys.argv[1], 'rb').read()
fmt, ntrk, div = struct.unpack('>HHH', d[8:14])
pos = 14
notes, other = [], []  # (ch, pitch, vel, start, end) / (kind, ch, tick, ...)
tempo = None; end = 0
def vlq(b, p):
    v = 0
    while True:
        c = b[p]; p += 1; v = v << 7 | c & 127
        if not c & 128: return v, p
for t in range(ntrk):
    assert d[pos:pos+4] == b'MTrk'
    n = struct.unpack('>I', d[pos+4:pos+8])[0]; b = d[pos+8:pos+8+n]; pos += 8 + n
    p = 0; tick = 0; st = 0; on = {}
    while p < len(b):
        dt, p = vlq(b, p); tick += dt
        if b[p] == 0xFF:
            ty = b[p+1]; ln, p = vlq(b, p+2); data = b[p:p+ln]; p += ln
            if ty == 0x51: tempo = int.from_bytes(data, 'big')
            if ty == 0x2F: end = max(end, tick)
            st = 0; continue
        if b[p] & 128: st = b[p]; p += 1
        k, ch = st >> 4, st & 15
        a = b[p]; p += 1
        c = 0
        if k not in (0xC, 0xD): c = b[p]; p += 1
        if k == 9 and c: on[(ch, a)] = (tick, c)
        elif k == 8 or k == 9:
            s, v = on.pop((ch, a)); notes.append((ch, a, v, s, tick))
        elif k == 0xB: other.append(('cc', ch, tick, a, c))
        elif k == 0xE: other.append(('bend', ch, tick, a | c << 7))
        elif k == 0xC: other.append(('prog', ch, tick, a))
bpm = 6e7 / tempo
print(f"format {fmt}, {ntrk} tracks, {div} ppq, {bpm:g} bpm, ends at tick {end}, {len(notes)} notes")
chs = sorted({n[0] for n in notes})
print("channels:", chs)
for o in other: print(o)
lo = min(n[1] for n in notes) - 2; hi = max(n[1] for n in notes) + 2
X, Y, L, T = 1200.0 / end, 10, 60, 40
W, H = 1200 + L + 20, (hi - lo + 1) * Y + T + 40
cols = ['#e6194b','#3cb44b','#4363d8','#f58231','#911eb4','#42d4f4','#f032e6','#bfef45','#fabed4','#469990','#dcbeff','#9a6324','#808000','#800000','#000075','#a9a9a9']
o = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W:.0f}" height="{H}" font-family="monospace" font-size="10">',
     f'<rect width="100%" height="100%" fill="#1b1b1f"/>']
for pch in range(lo, hi + 1):
    y = T + (hi - pch) * Y
    if pch % 12 in (1, 3, 6, 8, 10): o.append(f'<rect x="{L}" y="{y}" width="1200" height="{Y}" fill="#25252b"/>')
    if pch % 12 == 0:
        o.append(f'<text x="{L-4}" y="{y+Y-1}" fill="#888" text-anchor="end">C{pch//12-1}</text>')
        o.append(f'<line x1="{L}" x2="{L+1200}" y1="{y+Y}" y2="{y+Y}" stroke="#3a3a42"/>')
beat = div; bar = 4 * div
for t in range(0, end + 1, beat):
    x = L + t * X
    o.append(f'<line x1="{x:.1f}" x2="{x:.1f}" y1="{T}" y2="{T+(hi-lo+1)*Y}" stroke="{"#666" if t % bar == 0 else "#33333a"}"/>')
    if t % bar == 0 and t < end: o.append(f'<text x="{x+2:.1f}" y="{T-6}" fill="#aaa">bar {t//bar+1}</text>')
for ch, p, v, s, e in notes:
    y = T + (hi - p) * Y
    o.append(f'<rect x="{L+s*X:.1f}" y="{y+1}" width="{max((e-s)*X,1.5):.1f}" height="{Y-2}" rx="2" fill="{cols[ch]}" opacity="{0.4+0.6*v/127:.2f}"><title>ch{ch+1} pitch {p} vel {v} tick {s}-{e}</title></rect>')
for i, ch in enumerate(chs):
    o.append(f'<rect x="{L+i*90}" y="8" width="10" height="10" fill="{cols[ch]}"/><text x="{L+i*90+14}" y="17" fill="#ccc">ch {ch+1}{" drums" if ch==9 else ""}</text>')
o.append(f'<text x="{L}" y="{H-10}" fill="#888">{bpm:g} bpm, {len(notes)} notes</text></svg>')
open(sys.argv[2], 'w').write('\n'.join(o))
