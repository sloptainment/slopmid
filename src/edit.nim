## The editing rules, apart from the UI: what a duplicate, a paste, a quantize or a drag does to the notes,
## curve points, bend points, placements and clips. The UI reads the input, works out the wanted change and calls these.
## Groups (a selection moved together) stop at an edge keeping their shape.
import std/[algorithm, math, sequtils]
import model

type PDrag* = enum ## dragging a placement in the song window
  PIdle
  PMove
  PTrimL
  PTrimR
  PBox ## a selection box

# --- notes ---

proc duplicate*(notes: var seq[Note], grid: int) =
  ## Copies the selection right after its last note, which becomes the selection. A fine `grid` that
  ## would leave a sliver before the next bar line goes on to the bar line.
  let sel = notes.filterIt(it.sel)
  if sel.len > 0:
    let first = sel.mapIt(it.start).min
    var at = sel.mapIt(it.start + it.len).max # right after the last note ends
    let bar = (at + BarTicks - 1) div BarTicks * BarTicks
    if grid < Ppq div 4 and bar - at <= grid:
      at = bar
    for n in notes.mitems:
      n.sel = false
    for n in sel:
      var m = n
      m.start += at - first
      notes.add m

proc pasteNotes*(notes: var seq[Note], clip: seq[Note], at: int) =
  ## `clip` as the new selection, its first note starting at `at`.
  let d = at - clip.mapIt(it.start).min
  for n in notes.mitems:
    n.sel = false
  for n in clip:
    var m = n
    m.start += d
    notes.add m

proc quantize*(notes: var seq[Note], grid: int) =
  ## The selection's starts and ends to the nearest `grid`, at least one `grid` long.
  for n in notes.mitems:
    if n.sel:
      let s = snap(n.start, grid)
      n.len = max(grid, snap(n.start + n.len, grid) - s)
      n.start = s

proc transpose*(notes: var seq[Note], semis: int) =
  ## The selection (all, if none) up by `semis`; the whole group stops at the edge, keeping its shape.
  let anySel = notes.anyIt(it.sel)
  var d = semis
  for n in notes:
    if n.sel or not anySel:
      d = clamp(d, -n.pitch, 127 - n.pitch)
  for n in notes.mitems:
    if n.sel or not anySel:
      n.pitch += d

proc moveNotes*(notes: var seq[Note], grabbed, ds, dp: int) =
  ## Moves the grabbed note, or its whole selection if it is selected, by `ds` ticks and `dp` pitches, stopping at the edges.
  let sel = notes[grabbed].sel
  var (ds, dp) = (ds, dp)
  for i, m in notes:
    if (if sel: m.sel else: i == grabbed):
      ds = max(ds, -m.start)
      dp = clamp(dp, -m.pitch, 127 - m.pitch)
  for i, m in notes.mpairs:
    if (if sel: m.sel else: i == grabbed):
      m.start += ds
      m.pitch += dp

proc resizeNotes*(notes: var seq[Note], grabbed, d, grid: int) =
  ## Changes the length of the grabbed note, or its whole selection if it is selected, by `d` ticks; none gets shorter than `grid`.
  let sel = notes[grabbed].sel
  var d = d
  for i, m in notes:
    if (if sel: m.sel else: i == grabbed):
      d = max(d, grid - m.len)
  for i, m in notes.mpairs:
    if (if sel: m.sel else: i == grabbed):
      m.len += d

# --- bend points: a point is (note, index into its `bend`) ---

proc addBendPt*(n: var Note, tick: int, v: float): int =
  ## A point at `tick` (clear of the note's ends), or that tick's own point, set to `v`; its index, -1 if the note is too short.
  result = -1
  if n.len >= 2:
    let t = clamp(tick - n.start, 1, n.len - 1)
    var k = 1
    while k < n.bend.high and n.bend[k].t < t:
      inc k
    if k < n.bend.high and n.bend[k].t == t:
      n.bend[k].v = v
    else:
      n.bend.insert((t, v, false), k)
    result = k

proc zeroBendPts*(notes: var seq[Note], i, k: int) =
  ## Point `k` of note `i` onto the note's own pitch; a selected point takes its whole selection along.
  let group = notes[i].bend[k].sel
  notes[i].bend[k].v = 0
  if group:
    for n in notes.mitems:
      for j in n.bendIdx:
        if n.bend[j].sel:
          n.bend[j].v = 0

proc moveBendPts*(notes: var seq[Note], gi, gk, dt: int, dv: float) =
  ## Moves point `gk` of note `gi`, and the selected points if it is one of them, by `dt` ticks and `dv` semitones.
  ## `dt` is ignored for an end point: the ends only move up and down. The group stops at the note's ends, at its neighbours and at `BendRange`.
  var (dt, dv) = (dt, dv)
  if gk == 0 or gk == notes[gi].bend.high:
    dt = 0
  template inGroup(i, k: int): bool =
    (i == gi and k == gk) or (notes[i].bendVisible(k) and notes[i].bend[k].sel)

  for i, n in notes:
    for k in n.bendIdx:
      if inGroup(i, k):
        dv = clamp(dv, -BendRange.float - n.bend[k].v, BendRange.float - n.bend[k].v)
        if k > 0 and k < n.bend.high:
          let t = n.bend[k].t
          if k > 1 and not inGroup(i, k - 1):
            dt = max(dt, n.bend[k - 1].t + 1 - t)
          if k == n.bend.high - 1:
            dt = min(dt, n.len - 1 - t)
          elif not inGroup(i, k + 1):
            dt = min(dt, min(n.bend[k + 1].t, n.len) - 1 - t)
          if k == 1:
            dt = max(dt, 1 - t)
  for i, n in notes.mpairs:
    for k in n.bendIdx:
      if inGroup(i, k):
        n.bend[k].v += dv
        if k > 0 and k < n.bend.high:
          n.bend[k].t += dt

proc deleteBendPts*(notes: var seq[Note]) =
  ## The selected middle points.
  for n in notes.mitems:
    for k in countdown(n.bend.high - 1, 1):
      if n.bendVisible(k) and n.bend[k].sel:
        n.bend.delete k

# --- curve points ---

proc addCurvePt*(pts: var seq[CurvePt], tick, v, loopT: int): int =
  ## A point at `tick` (no later than `loopT`), or that tick's own point, set to `v`; its index.
  let t = min(tick, loopT)
  result = pts.len
  for i, p in pts:
    if p.t >= t:
      result = i
      break
  if result < pts.len and pts[result].t == t:
    pts[result].v = v
  else:
    pts.insert((t, v, false), result)

proc pasteCurve*(pts: var seq[CurvePt], clip: seq[CurvePt], at, loopT: int) =
  ## `clip` as the new selection, its first point at `at`, points past `loopT` dropped. Replaces the points its span covers.
  let d = at - clip[0].t
  let moved = clip.mapIt((t: it.t + d, v: it.v, sel: true)).filterIt(it.t <= loopT)
  if moved.len > 0:
    pts.keepItIf(it.t < moved[0].t or it.t > moved[^1].t)
    for p in pts.mitems:
      p.sel = false
    pts = (pts & moved).sortedByIt(it.t)

proc moveCurvePts*(
    pts: var seq[CurvePt], grabbed: int, group: bool, dt, dv, loopT: int
) =
  ## Moves point `grabbed`, and with `group` the selected points too, by `dt` ticks and `dv` values.
  ## The group stops at its neighbours and at 0 .. `loopT` ticks and 0 .. 127, keeping its shape.
  var (dt, dv) = (dt, dv)
  template inGroup(i: int): bool =
    i == grabbed or (group and pts[i].sel)

  for i, p in pts:
    if inGroup(i):
      if i > 0 and not inGroup(i - 1):
        dt = max(dt, pts[i - 1].t + 1 - p.t)
      if i < pts.high and not inGroup(i + 1):
        dt = min(dt, pts[i + 1].t - 1 - p.t)
      dt = clamp(dt, -p.t, max(0, loopT - p.t))
      dv = clamp(dv, -p.v, 127 - p.v)
  for i in 0 .. pts.high:
    if inGroup(i):
      pts[i].t += dt
      pts[i].v += dv

# --- placements ---

proc fits*(ps: seq[Placement], i: int, p: Placement): bool =
  ## `p` could replace placement `i` (-1: be added): in bounds and clear of its lane's others.
  result = p.len > 0 and p.start >= 0 and p.lane in 0 ..< Lanes
  for j, q in ps:
    if j != i and q.lane == p.lane and q.start < p.start + p.len and
        p.start < q.start + q.len:
      result = false

proc moves*(ps: seq[Placement], grabbed: int, mode: PDrag, i: int): bool =
  ## Placement `i` is dragged with the mouse: the grabbed one, or its whole selection. A left trim is the grabbed one only.
  mode in {PMove, PTrimL, PTrimR} and
    (if mode != PTrimL and ps[grabbed].sel: ps[i].sel
    else: i == grabbed)

proc pastePlacements*(s: var Song, clip: seq[Placement], at: int) =
  ## `clip` as the new selection, its first placement starting at `at`. All or nothing: an overlap anywhere cancels it.
  let d = at - clip.mapIt(it.start).min
  let moved = clip.mapIt(
    Placement(
      clip: it.clip,
      lane: it.lane,
      start: it.start + d,
      len: it.len,
      offset: it.offset,
      sel: true,
    )
  )
  if moved.allIt(s.placements.fits(-1, it)):
    for p in s.placements.mitems:
      p.sel = false
    s.placements.add moved

proc quantizePlacements*(s: var Song, grid: int) =
  ## The selection's starts and ends to the nearest `grid`, at least one `grid` long; one that would overlap is skipped.
  for i in 0 ..< s.placements.len:
    var p = s.placements[i]
    if p.sel:
      let t = snap(p.start, grid)
      p.len = max(grid, snap(p.start + p.len, grid) - t)
      p.start = t
      if s.placements.fits(i, p):
        s.placements[i] = p

proc addPlacement*(s: var Song, lane, tick, grid: int): int =
  ## The playing clip in `lane` at `tick` rounded down to `grid`, as long as its loop but no longer than the gap before the next one.
  ## Its index, -1 if it does not fit. Deselects everything either way.
  result = -1
  for q in s.placements.mitems:
    q.sel = false
  var p = Placement(
    clip: s.clip, lane: lane, start: snapDown(tick, grid), len: s.clips[s.clip].loopEnd
  )
  for q in s.placements:
    if q.lane == lane and q.start >= p.start:
      p.len = min(p.len, q.start - p.start)
  if s.placements.fits(-1, p):
    s.placements.add p
    result = s.placements.high

proc dragPlacements*(
    s: var Song,
    orig: seq[Placement],
    grabbed: int,
    mode: PDrag,
    tick, lane, grab, grid: int,
): bool =
  ## Drags from `orig`, the placements when the drag began, so nothing sticks to an overlap passed on the way.
  ## The mouse is at `tick` in `lane`, `grab` ticks into the grabbed placement `grabbed`. A move stops at the edges;
  ## a right trim changes all lengths by the same ticks; a left trim moves its edge and starts the clip part-way in.
  ## True if the result overlaps in some lane (the caller puts `orig` back on release).
  let a = orig[grabbed]
  var ds, dn = 0 # ticks and lanes moved by
  case mode
  of PMove:
    ds = snap(tick - grab, grid) - a.start
    dn = lane - a.lane
    for i, q in orig:
      if orig.moves(grabbed, mode, i):
        ds = max(ds, -q.start)
        dn = clamp(dn, -q.lane, Lanes - 1 - q.lane)
  of PTrimR:
    ds = snap(tick, grid) - a.start - a.len
    for i, q in orig:
      if orig.moves(grabbed, mode, i):
        ds = max(ds, grid - q.len)
  of PTrimL:
    ds = max(-a.start, min(snap(tick, grid) - a.start, a.len - grid))
  else:
    discard
  for i, q in orig:
    if orig.moves(grabbed, mode, i):
      var p = q
      case mode
      of PMove:
        p.start += ds
        p.lane += dn
      of PTrimR:
        p.len += ds
      else:
        p.start += ds
        p.len -= ds
        p.offset = floorMod(p.offset + ds, s.clips[p.clip].loopEnd)
      s.placements[i] = p
  for i, p in s.placements:
    if not s.placements.fits(i, p):
      result = true

# --- clips ---

proc removeClip*(s: var Song, gone: int) =
  ## Drops clip `gone` and its placements, renumbers the later clips' placements, and selects a clip still there.
  s.clips.delete gone
  s.placements.keepItIf(it.clip != gone)
  for p in s.placements.mitems:
    if p.clip > gone:
      dec p.clip
  s.clip = min(gone, s.clips.high)

proc duplicateClip*(s: var Song, i: int) =
  ## Appends a copy of clip `i`, its tracks unmuted and unsoloed.
  s.clips.add s.clips[i]
  for t in s.clips[^1].tracks.mitems:
    t.mute = false
    t.solo = false

# --- selection: for any seq of items with a `sel` field (notes, curve points, placements) ---

proc toggleAll*[T](xs: var seq[T]) =
  ## Ctrl+A: selects all, or none if any is selected.
  let all = not xs.anyIt(it.sel)
  for x in xs.mitems:
    x.sel = all

proc clickSelect*[T](xs: var seq[T], i: int, shift: bool) =
  ## A click on item `i`: a selected one keeps the group; else it is selected, with Shift added to the selection, without replacing it.
  if not xs[i].sel:
    if not shift:
      for x in xs.mitems:
        x.sel = false
    xs[i].sel = true

proc boxSelect*[T](xs: var seq[T], shift: bool, inBox: proc(x: T): bool) =
  ## A box ends: the items it touches get selected; the rest are deselected unless Shift is held.
  for x in xs.mitems:
    if inBox(x):
      x.sel = true
    elif not shift:
      x.sel = false
