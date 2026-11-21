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
          if k > 1 and not inGroup(i, k - 1): dt = max(dt, n.bend[k - 1].t + 1 - t)
          if k == n.bend.high - 1: dt = min(dt, n.len - 1 - t)
          elif not inGroup(i, k + 1): dt = min(dt, min(n.bend[k + 1].t, n.len) - 1 - t)
          if k == 1: dt = max(dt, 1 - t)
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

proc moveCurvePts*(pts: var seq[CurvePt], grabbed: int, group: bool, dt, dv, loopT: int) =
  ## Moves point `grabbed`, and with `group` the selected points too, by `dt` ticks and `dv` values.
  ## The group stops at its neighbours and at 0 .. `loopT` ticks and 0 .. 127, keeping its shape.
  var (dt, dv) = (dt, dv)
  template inGroup(i: int): bool = i == grabbed or (group and pts[i].sel)
  for i, p in pts:
    if inGroup(i):
      if i > 0 and not inGroup(i - 1): dt = max(dt, pts[i - 1].t + 1 - p.t)
      if i < pts.high and not inGroup(i + 1): dt = min(dt, pts[i + 1].t - 1 - p.t)
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
    if j != i and q.lane == p.lane and q.start < p.start + p.len and p.start < q.start + q.len:
      result = false

proc moves*(ps: seq[Placement], grabbed: int, mode: PDrag, i: int): bool =
  ## Placement `i` is dragged with the mouse: the grabbed one, or its whole selection. A left trim is the grabbed one only.
  mode in {PMove, PTrimL, PTrimR} and
    (if mode != PTrimL and ps[grabbed].sel: ps[i].sel else: i == grabbed)

proc pastePlacements*(s: var Song, clip: seq[Placement], at: int) =
  ## `clip` as the new selection, its first placement starting at `at`. All or nothing: an overlap anywhere cancels it.
  let d = at - clip.mapIt(it.start).min
  let moved = clip.mapIt(Placement(clip: it.clip, lane: it.lane, start: it.start + d, len: it.len, offset: it.offset, sel: true))
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
  var p = Placement(clip: s.clip, lane: lane, start: snapDown(tick, grid), len: s.clips[s.clip].loopEnd)
  for q in s.placements:
    if q.lane == lane and q.start >= p.start:
      p.len = min(p.len, q.start - p.start)
  if s.placements.fits(-1, p):
    s.placements.add p
    result = s.placements.high

proc dragPlacements*(s: var Song, orig: seq[Placement], grabbed: int, mode: PDrag, tick, lane, grab, grid: int): bool =
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

when isMainModule:
  proc nt(start, len, pitch: int, sel = false): Note =
    Note(start: start, len: len, pitch: pitch, sel: sel)
  proc pl(clip, lane, start, len: int, sel = false): Placement =
    Placement(clip: clip, lane: lane, start: start, len: len, sel: sel)
  proc starts(ns: seq[Note]): seq[int] = ns.mapIt(it.start)

  # duplicate: after the last selected note, the copies selected; a fine snap goes on to the bar when a sliver is left
  var ns = @[nt(0, 96, 60, true), nt(96, 96, 62, true), nt(200, 10, 64)]
  ns.duplicate(Ppq div 4)
  doAssert ns.starts == @[0, 96, 200, 192, 288] and ns.mapIt(it.sel) == @[false, false, false, true, true]
  ns = @[nt(0, BarTicks - 4, 60, true)]
  ns.duplicate(Ppq div 24)
  doAssert ns.starts == @[0, BarTicks]
  ns = @[nt(0, BarTicks - 4, 60, true)]
  ns.duplicate(Ppq)
  doAssert ns.starts == @[0, BarTicks - 4]

  # pasteNotes: the first lands on `at`, the paste replaces the selection
  ns = @[nt(5, 10, 60, true)]
  ns.pasteNotes(@[nt(100, 10, 61, true), nt(120, 10, 62, true)], 300)
  doAssert ns.starts == @[5, 300, 320] and ns.mapIt(it.sel) == @[false, true, true]

  # quantize: only the selection; never shorter than a snap
  ns = @[nt(10, 3, 60, true), nt(50, 40, 60), nt(97, 90, 60, true)]
  ns.quantize(24)
  doAssert ns.starts == @[0, 50, 96] and ns.mapIt(it.len) == @[24, 40, 96]

  # transpose: the group stops at the edge keeping its shape; no selection = everything
  ns = @[nt(0, 1, 126, true), nt(0, 1, 120, true), nt(0, 1, 10)]
  ns.transpose(12)
  doAssert ns.mapIt(it.pitch) == @[127, 121, 10]
  ns = @[nt(0, 1, 2), nt(0, 1, 5)]
  ns.transpose(-12)
  doAssert ns.mapIt(it.pitch) == @[0, 3]

  # moveNotes: a selected note takes the selection along, an unselected one goes alone; edges clamp
  ns = @[nt(10, 5, 60, true), nt(20, 5, 1, true), nt(30, 5, 60)]
  ns.moveNotes(0, -50, -5)
  doAssert ns.starts == @[0, 10, 30] and ns.mapIt(it.pitch) == @[59, 0, 60]
  ns.moveNotes(2, 7, 1)
  doAssert ns.starts == @[0, 10, 37] and ns.mapIt(it.pitch) == @[59, 0, 61]

  # resizeNotes: same change for the group, none under one snap
  ns = @[nt(0, 48, 60, true), nt(0, 30, 60, true), nt(0, 48, 60)]
  ns.resizeNotes(0, -40, 24)
  doAssert ns.mapIt(it.len) == @[42, 24, 48] # the 30-long one limits the group to -6

  # addBendPt: sorted in between the ends, clamped inside the note, an existing tick is reused
  var bn = nt(100, 96, 60)
  bn.bend = @[(0, 0.0, false), (0, 0.0, false)]
  doAssert bn.addBendPt(148, 2.0) == 1 and bn.bend[1].t == 48
  doAssert bn.addBendPt(100, 1.0) == 1 and bn.bend[1].t == 1 # clamped off the start
  doAssert bn.addBendPt(148, 3.0) == 2 and bn.bend.len == 4
  doAssert bn.addBendPt(148, 4.0) == 2 and bn.bend.len == 4 and bn.bend[2].v == 4.0
  var short = nt(0, 1, 60)
  doAssert short.addBendPt(0, 1.0) == -1

  # zeroBendPts: the point, or its whole selection
  ns = @[nt(0, 96, 60)]
  ns[0].bend = @[(0, 1.0, false), (24, 2.0, true), (48, 3.0, true), (0, 4.0, false)]
  ns.zeroBendPts(0, 3)
  doAssert ns[0].bend.mapIt(it.v) == @[1.0, 2.0, 3.0, 0.0]
  ns.zeroBendPts(0, 1)
  doAssert ns[0].bend.mapIt(it.v) == @[1.0, 0.0, 0.0, 0.0]

  # moveBendPts: the group keeps its shape and stops at the note's end / the first at 1 tick / BendRange; ends move up and down only
  ns = @[nt(0, 96, 60)]
  ns[0].bend = @[(0, 0.0, false), (24, 1.0, true), (48, 2.0, true), (0, 0.0, false)]
  ns.moveBendPts(0, 1, 100, 100.0)
  doAssert ns[0].bend.mapIt(it.t)[1 .. 2] == @[71, 95] and ns[0].bend[1].v == BendRange.float - 1
  ns.moveBendPts(0, 1, -100, 0.0)
  doAssert ns[0].bend.mapIt(it.t)[1 .. 2] == @[1, 25]
  ns = @[nt(0, 96, 60)]
  ns[0].bend = @[(0, 0.0, false), (24, 1.0, false), (0, 0.0, false)]
  ns.moveBendPts(0, 0, 50, 3.0) # an end: only up and down
  doAssert ns[0].bend.mapIt(it.v) == @[3.0, 1.0, 0.0] and ns[0].bend[1].t == 24

  # deleteBendPts: selected middle points only
  ns = @[nt(0, 96, 60)]
  ns[0].bend = @[(0, 0.0, true), (24, 1.0, true), (48, 2.0, false), (0, 0.0, true)]
  ns.deleteBendPts
  doAssert ns[0].bend.len == 3 and ns[0].bend[1].t == 48

  # addCurvePt: sorted in, capped at loopT, an existing tick is reused
  var cp: seq[CurvePt] = @[(0, 10, false), (100, 20, false)]
  doAssert cp.addCurvePt(50, 5, 400) == 1 and cp.mapIt(it.t) == @[0, 50, 100]
  doAssert cp.addCurvePt(100, 7, 400) == 2 and cp.len == 3 and cp[2].v == 7
  doAssert cp.addCurvePt(900, 9, 400) == 3 and cp[3].t == 400

  # pasteCurve: replaces exactly the covered span (ends included), the paste is the selection, points past the loop are dropped
  cp = @[(0, 1, true), (10, 2, false), (20, 3, false), (30, 4, false), (40, 5, false)]
  cp.pasteCurve(@[(5, 70, true), (15, 80, true)], 20, 100)
  doAssert cp.mapIt(it.t) == @[0, 10, 20, 30, 40] and cp.mapIt(it.v) == @[1, 2, 70, 80, 5] and cp.mapIt(it.sel) == @[false, false, true, true, false]
  cp.pasteCurve(@[(0, 1, true), (50, 2, true)], 0, 30) # the second lands past the loop
  doAssert cp.mapIt(it.v) == @[1, 2, 70, 80, 5] and cp[0].sel and cp.mapIt(it.t) == @[0, 10, 20, 30, 40]

  # moveCurvePts: the group stops at its neighbours / 0 / loopT, keeping its shape
  cp = @[(0, 5, false), (10, 100, true), (20, 120, true), (30, 50, false)]
  cp.moveCurvePts(1, true, 100, 100, 200) # stops 1 tick short of the neighbour at 30, and at 127
  doAssert cp.mapIt(it.t) == @[0, 19, 29, 30] and cp.mapIt(it.v) == @[5, 107, 127, 50]
  cp = @[(0, 5, false), (10, 100, true), (20, 120, true), (30, 50, false)]
  cp.moveCurvePts(1, true, -100, 100, 200)
  doAssert cp.mapIt(it.t) == @[0, 1, 11, 30] and cp.mapIt(it.v) == @[5, 107, 127, 50]
  cp = @[(0, 5, false), (10, 100, true), (20, 120, false)]
  cp.moveCurvePts(1, false, 50, -50, 200) # alone: the selection is ignored
  doAssert cp.mapIt(it.t) == @[0, 19, 20] and cp[1].v == 50

  # fits: in bounds and clear of its lane
  let ps = @[pl(0, 1, 0, 100), pl(0, 2, 0, 100)]
  doAssert ps.fits(-1, pl(0, 1, 100, 50)) and not ps.fits(-1, pl(0, 1, 99, 50))
  doAssert ps.fits(0, pl(0, 1, 50, 100)) and ps.fits(-1, pl(0, 3, 0, 100))
  doAssert not ps.fits(-1, pl(0, 3, -1, 5)) and not ps.fits(-1, pl(0, Lanes, 0, 5)) and not ps.fits(-1, pl(0, 3, 0, 0))

  # moves: the group for a move/right trim, the grabbed one only for a left trim
  let gp = @[pl(0, 0, 0, 10, true), pl(0, 1, 0, 10, true), pl(0, 2, 0, 10)]
  doAssert gp.moves(0, PMove, 1) and not gp.moves(0, PMove, 2) and not gp.moves(0, PTrimL, 1) and gp.moves(2, PMove, 2)
  doAssert not gp.moves(0, PIdle, 0)

  # pastePlacements: all or nothing
  var sg = Song(clips: @[Clip(), Clip()], placements: @[pl(0, 0, 0, 100, true), pl(1, 1, 500, 100)])
  sg.pastePlacements(@[pl(0, 0, 10, 50, true), pl(0, 2, 20, 50, true)], 200)
  doAssert sg.placements.len == 4 and sg.placements[2].start == 200 and sg.placements[3].start == 210 and not sg.placements[0].sel
  sg.pastePlacements(@[pl(0, 0, 0, 50, true), pl(0, 1, 0, 50, true)], 480) # the second hits (1, 500)
  doAssert sg.placements.len == 4 and sg.placements[2].sel

  # quantizePlacements: rounds, at least a snap long, skips one that would overlap
  sg = Song(clips: @[Clip()], placements: @[pl(0, 0, 10, 3, true), pl(0, 1, 20, 100, true), pl(0, 1, 130, 20)])
  sg.quantizePlacements(24)
  doAssert sg.placements[0].start == 0 and sg.placements[0].len == 24
  doAssert sg.placements[1].start == 24 and sg.placements[1].len == 96 # 20..120 -> 24..120
  sg = Song(clips: @[Clip()], placements: @[pl(0, 0, 0, 100), pl(0, 0, 110, 30, true)])
  sg.quantizePlacements(48) # 110..140 -> 96..144, overlaps the first
  doAssert sg.placements[1].start == 110 and sg.placements[1].len == 30

  # addPlacement: gap-clamped, -1 when it can't fit, deselects regardless
  sg = Song(clips: @[Clip(tracks: @[Track(notes: @[Note(start: 0, len: 8)])])], placements: @[pl(0, 0, 300, 50, true), pl(0, 1, 0, 700)])
  doAssert sg.addPlacement(0, 100, 24) == 2 and sg.placements[2].start == 96 and sg.placements[2].len == 204 and not sg.placements[0].sel
  doAssert sg.addPlacement(0, 310, 24) == -1 and sg.placements.len == 3 # inside one
  doAssert sg.addPlacement(2, 10, 24) == 3 and sg.placements[3].len == BarTicks

  # dragPlacements: a move keeps the shape and stops at the edges, reports an overlap; trims
  sg = Song(clips: @[Clip(tracks: @[Track(notes: @[Note(start: 0, len: 8)])])],
            placements: @[pl(0, 0, 50, 100, true), pl(0, 1, 120, 100, true), pl(0, 2, 0, 100)])
  let o = sg.placements
  doAssert not sg.dragPlacements(o, 0, PMove, 0, 5, 0, 24) # to tick 0: the group stops where the first reaches 0
  doAssert sg.placements.mapIt((it.start, it.lane)) == @[(0, 5), (70, 6), (0, 2)] # the unselected one stays
  sg.placements = o
  doAssert not sg.dragPlacements(o, 0, PMove, 50, 31, 0, 24) # to lane 31: the group stops where the second reaches it
  doAssert sg.placements.mapIt(it.lane) == @[30, 31, 2]
  sg.placements = o
  doAssert sg.dragPlacements(o, 0, PMove, 50, 2, 0, 24) # lane 0 -> 2: collides with the unselected one
  doAssert sg.placements[0].lane == 2 and sg.placements[1].lane == 3
  sg.placements = o
  doAssert not sg.dragPlacements(o, 0, PTrimR, 250, 0, 0, 24) # right edge 150 -> 240: all grow by 90
  doAssert sg.placements.mapIt(it.len)[0 .. 1] == @[190, 190] and sg.placements[0].lane == 0
  doAssert not sg.dragPlacements(o, 0, PTrimR, 0, 0, 0, 24) # shrinks only to one snap
  doAssert sg.placements.mapIt(it.len)[0 .. 1] == @[24, 24]
  sg.placements = o
  doAssert not sg.dragPlacements(o, 1, PTrimL, 168, 0, 0, 24) # left trim: the grabbed one only, the clip starts part-way in
  doAssert sg.placements[1].start == 168 and sg.placements[1].len == 52 and sg.placements[1].offset == 48 and sg.placements[0] == o[0]

  # removeClip: its placements go, later clips renumber, the playing clip stays in range
  sg = Song(clips: @[Clip(), Clip(), Clip()], clip: 2, placements: @[pl(0, 0, 0, 10), pl(1, 0, 20, 10), pl(2, 0, 40, 10)])
  sg.removeClip(1)
  doAssert sg.clips.len == 2 and sg.placements.mapIt(it.clip) == @[0, 1] and sg.clip == 1
  sg.removeClip(1)
  doAssert sg.clips.len == 1 and sg.placements.mapIt(it.clip) == @[0] and sg.clip == 0

  # duplicateClip: a copy at the end, name included, unmuted
  sg = Song(clips: @[Clip(name: "a", tracks: @[Track(mute: true, solo: true)])])
  sg.duplicateClip(0)
  doAssert sg.clips.len == 2 and sg.clips[1].name == "a" and not sg.clips[1].tracks[0].mute and not sg.clips[1].tracks[0].solo
  doAssert sg.clips[0].tracks[0].mute
  echo "edit: ok"
