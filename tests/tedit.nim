import std/[unittest, algorithm, math, sequtils]
import ../src/model
import ../src/edit

test "edit":
  proc nt(start, len, pitch: int, sel = false): Note =
    Note(start: start, len: len, pitch: pitch, sel: sel)

  proc pl(clip, lane, start, len: int, sel = false): Placement =
    Placement(clip: clip, lane: lane, start: start, len: len, sel: sel)

  proc starts(ns: seq[Note]): seq[int] =
    ns.mapIt(it.start)

  # duplicate: after the last selected note, the copies selected; a fine snap goes on to the bar when a sliver is left
  var ns = @[nt(0, 96, 60, true), nt(96, 96, 62, true), nt(200, 10, 64)]
  ns.duplicate(Ppq div 4)
  check ns.starts == @[0, 96, 200, 192, 288] and
    ns.mapIt(it.sel) == @[false, false, false, true, true]
  ns = @[nt(0, BarTicks - 4, 60, true)]
  ns.duplicate(Ppq div 24)
  check ns.starts == @[0, BarTicks]
  ns = @[nt(0, BarTicks - 4, 60, true)]
  ns.duplicate(Ppq)
  check ns.starts == @[0, BarTicks - 4]

  # pasteNotes: the first lands on `at`, the paste replaces the selection
  ns = @[nt(5, 10, 60, true)]
  ns.pasteNotes(@[nt(100, 10, 61, true), nt(120, 10, 62, true)], 300)
  check ns.starts == @[5, 300, 320] and ns.mapIt(it.sel) == @[false, true, true]

  # quantize: only the selection; never shorter than a snap
  ns = @[nt(10, 3, 60, true), nt(50, 40, 60), nt(97, 90, 60, true)]
  ns.quantize(24)
  check ns.starts == @[0, 50, 96] and ns.mapIt(it.len) == @[24, 40, 96]

  # transpose: the group stops at the edge keeping its shape; no selection = everything
  ns = @[nt(0, 1, 126, true), nt(0, 1, 120, true), nt(0, 1, 10)]
  ns.transpose(12)
  check ns.mapIt(it.pitch) == @[127, 121, 10]
  ns = @[nt(0, 1, 2), nt(0, 1, 5)]
  ns.transpose(-12)
  check ns.mapIt(it.pitch) == @[0, 3]

  # moveNotes: a selected note takes the selection along, an unselected one goes alone; edges clamp
  ns = @[nt(10, 5, 60, true), nt(20, 5, 1, true), nt(30, 5, 60)]
  ns.moveNotes(0, -50, -5)
  check ns.starts == @[0, 10, 30] and ns.mapIt(it.pitch) == @[59, 0, 60]
  ns.moveNotes(2, 7, 1)
  check ns.starts == @[0, 10, 37] and ns.mapIt(it.pitch) == @[59, 0, 61]

  # resizeNotes: same change for the group, none under one snap
  ns = @[nt(0, 48, 60, true), nt(0, 30, 60, true), nt(0, 48, 60)]
  ns.resizeNotes(0, -40, 24)
  check ns.mapIt(it.len) == @[42, 24, 48] # the 30-long one limits the group to -6

  # addBendPt: sorted in between the ends, clamped inside the note, an existing tick is reused
  var bn = nt(100, 96, 60)
  bn.bend = @[(0, 0.0, false), (0, 0.0, false)]
  check bn.addBendPt(148, 2.0) == 1 and bn.bend[1].t == 48
  check bn.addBendPt(100, 1.0) == 1 and bn.bend[1].t == 1 # clamped off the start
  check bn.addBendPt(148, 3.0) == 2 and bn.bend.len == 4
  check bn.addBendPt(148, 4.0) == 2 and bn.bend.len == 4 and bn.bend[2].v == 4.0
  var short = nt(0, 1, 60)
  check short.addBendPt(0, 1.0) == -1

  # zeroBendPts: the point, or its whole selection
  ns = @[nt(0, 96, 60)]
  ns[0].bend = @[(0, 1.0, false), (24, 2.0, true), (48, 3.0, true), (0, 4.0, false)]
  ns.zeroBendPts(0, 3)
  check ns[0].bend.mapIt(it.v) == @[1.0, 2.0, 3.0, 0.0]
  ns.zeroBendPts(0, 1)
  check ns[0].bend.mapIt(it.v) == @[1.0, 0.0, 0.0, 0.0]

  # moveBendPts: the group keeps its shape and stops at the note's end / the first at 1 tick / BendRange; ends move up and down only
  ns = @[nt(0, 96, 60)]
  ns[0].bend = @[(0, 0.0, false), (24, 1.0, true), (48, 2.0, true), (0, 0.0, false)]
  ns.moveBendPts(0, 1, 100, 100.0)
  check ns[0].bend.mapIt(it.t)[1 .. 2] == @[71, 95] and
    ns[0].bend[1].v == BendRange.float - 1
  ns.moveBendPts(0, 1, -100, 0.0)
  check ns[0].bend.mapIt(it.t)[1 .. 2] == @[1, 25]
  ns = @[nt(0, 96, 60)]
  ns[0].bend = @[(0, 0.0, false), (24, 1.0, false), (0, 0.0, false)]
  ns.moveBendPts(0, 0, 50, 3.0) # an end: only up and down
  check ns[0].bend.mapIt(it.v) == @[3.0, 1.0, 0.0] and ns[0].bend[1].t == 24

  # deleteBendPts: selected middle points only
  ns = @[nt(0, 96, 60)]
  ns[0].bend = @[(0, 0.0, true), (24, 1.0, true), (48, 2.0, false), (0, 0.0, true)]
  ns.deleteBendPts
  check ns[0].bend.len == 3 and ns[0].bend[1].t == 48

  # addCurvePt: sorted in, capped at loopT, an existing tick is reused
  var cp: seq[CurvePt] = @[(0, 10, false), (100, 20, false)]
  check cp.addCurvePt(50, 5, 400) == 1 and cp.mapIt(it.t) == @[0, 50, 100]
  check cp.addCurvePt(100, 7, 400) == 2 and cp.len == 3 and cp[2].v == 7
  check cp.addCurvePt(900, 9, 400) == 3 and cp[3].t == 400

  # pasteCurve: replaces exactly the covered span (ends included), the paste is the selection, points past the loop are dropped
  cp = @[(0, 1, true), (10, 2, false), (20, 3, false), (30, 4, false), (40, 5, false)]
  cp.pasteCurve(@[(5, 70, true), (15, 80, true)], 20, 100)
  check cp.mapIt(it.t) == @[0, 10, 20, 30, 40] and
    cp.mapIt(it.v) == @[1, 2, 70, 80, 5] and
    cp.mapIt(it.sel) == @[false, false, true, true, false]
  cp.pasteCurve(@[(0, 1, true), (50, 2, true)], 0, 30) # the second lands past the loop
  check cp.mapIt(it.v) == @[1, 2, 70, 80, 5] and cp[0].sel and
    cp.mapIt(it.t) == @[0, 10, 20, 30, 40]

  # moveCurvePts: the group stops at its neighbours / 0 / loopT, keeping its shape
  cp = @[(0, 5, false), (10, 100, true), (20, 120, true), (30, 50, false)]
  cp.moveCurvePts(1, true, 100, 100, 200)
    # stops 1 tick short of the neighbour at 30, and at 127
  check cp.mapIt(it.t) == @[0, 19, 29, 30] and cp.mapIt(it.v) == @[5, 107, 127, 50]
  cp = @[(0, 5, false), (10, 100, true), (20, 120, true), (30, 50, false)]
  cp.moveCurvePts(1, true, -100, 100, 200)
  check cp.mapIt(it.t) == @[0, 1, 11, 30] and cp.mapIt(it.v) == @[5, 107, 127, 50]
  cp = @[(0, 5, false), (10, 100, true), (20, 120, false)]
  cp.moveCurvePts(1, false, 50, -50, 200) # alone: the selection is ignored
  check cp.mapIt(it.t) == @[0, 19, 20] and cp[1].v == 50

  # fits: in bounds and clear of its lane
  let ps = @[pl(0, 1, 0, 100), pl(0, 2, 0, 100)]
  check ps.fits(-1, pl(0, 1, 100, 50)) and not ps.fits(-1, pl(0, 1, 99, 50))
  check ps.fits(0, pl(0, 1, 50, 100)) and ps.fits(-1, pl(0, 3, 0, 100))
  check not ps.fits(-1, pl(0, 3, -1, 5)) and not ps.fits(-1, pl(0, Lanes, 0, 5)) and
    not ps.fits(-1, pl(0, 3, 0, 0))

  # moves: the group for a move/right trim, the grabbed one only for a left trim
  let gp = @[pl(0, 0, 0, 10, true), pl(0, 1, 0, 10, true), pl(0, 2, 0, 10)]
  check gp.moves(0, PMove, 1) and not gp.moves(0, PMove, 2) and
    not gp.moves(0, PTrimL, 1) and gp.moves(2, PMove, 2)
  check not gp.moves(0, PIdle, 0)

  # pastePlacements: all or nothing
  var sg = Song(
    clips: @[Clip(), Clip()], placements: @[pl(0, 0, 0, 100, true), pl(1, 1, 500, 100)]
  )
  sg.pastePlacements(@[pl(0, 0, 10, 50, true), pl(0, 2, 20, 50, true)], 200)
  check sg.placements.len == 4 and sg.placements[2].start == 200 and
    sg.placements[3].start == 210 and not sg.placements[0].sel
  sg.pastePlacements(@[pl(0, 0, 0, 50, true), pl(0, 1, 0, 50, true)], 480)
    # the second hits (1, 500)
  check sg.placements.len == 4 and sg.placements[2].sel

  # quantizePlacements: rounds, at least a snap long, skips one that would overlap
  sg = Song(
    clips: @[Clip()],
    placements: @[pl(0, 0, 10, 3, true), pl(0, 1, 20, 100, true), pl(0, 1, 130, 20)],
  )
  sg.quantizePlacements(24)
  check sg.placements[0].start == 0 and sg.placements[0].len == 24
  check sg.placements[1].start == 24 and sg.placements[1].len == 96
    # 20..120 -> 24..120
  sg = Song(clips: @[Clip()], placements: @[pl(0, 0, 0, 100), pl(0, 0, 110, 30, true)])
  sg.quantizePlacements(48) # 110..140 -> 96..144, overlaps the first
  check sg.placements[1].start == 110 and sg.placements[1].len == 30

  # addPlacement: gap-clamped, -1 when it can't fit, deselects regardless
  sg = Song(
    clips: @[Clip(tracks: @[Track(notes: @[Note(start: 0, len: 8)])])],
    placements: @[pl(0, 0, 300, 50, true), pl(0, 1, 0, 700)],
  )
  check sg.addPlacement(0, 100, 24) == 2 and sg.placements[2].start == 96 and
    sg.placements[2].len == 204 and not sg.placements[0].sel
  check sg.addPlacement(0, 310, 24) == -1 and sg.placements.len == 3 # inside one
  check sg.addPlacement(2, 10, 24) == 3 and sg.placements[3].len == BarTicks

  # dragPlacements: a move keeps the shape and stops at the edges, reports an overlap; trims
  sg = Song(
    clips: @[Clip(tracks: @[Track(notes: @[Note(start: 0, len: 8)])])],
    placements: @[pl(0, 0, 50, 100, true), pl(0, 1, 120, 100, true), pl(0, 2, 0, 100)],
  )
  let o = sg.placements
  check not sg.dragPlacements(o, 0, PMove, 0, 5, 0, 24)
    # to tick 0: the group stops where the first reaches 0
  check sg.placements.mapIt((it.start, it.lane)) ==
    @[(0, 5), (70, 6), (0, 2)] # the unselected one stays
  sg.placements = o
  check not sg.dragPlacements(o, 0, PMove, 50, 31, 0, 24)
    # to lane 31: the group stops where the second reaches it
  check sg.placements.mapIt(it.lane) == @[30, 31, 2]
  sg.placements = o
  check sg.dragPlacements(o, 0, PMove, 50, 2, 0, 24)
    # lane 0 -> 2: collides with the unselected one
  check sg.placements[0].lane == 2 and sg.placements[1].lane == 3
  sg.placements = o
  check not sg.dragPlacements(o, 0, PTrimR, 250, 0, 0, 24)
    # right edge 150 -> 240: all grow by 90
  check sg.placements.mapIt(it.len)[0 .. 1] == @[190, 190] and
    sg.placements[0].lane == 0
  check not sg.dragPlacements(o, 0, PTrimR, 0, 0, 0, 24) # shrinks only to one snap
  check sg.placements.mapIt(it.len)[0 .. 1] == @[24, 24]
  sg.placements = o
  check not sg.dragPlacements(o, 1, PTrimL, 168, 0, 0, 24)
    # left trim: the grabbed one only, the clip starts part-way in
  check sg.placements[1].start == 168 and sg.placements[1].len == 52 and
    sg.placements[1].offset == 48 and sg.placements[0] == o[0]

  # removeClip: its placements go, later clips renumber, the playing clip stays in range
  sg = Song(
    clips: @[Clip(), Clip(), Clip()],
    clip: 2,
    placements: @[pl(0, 0, 0, 10), pl(1, 0, 20, 10), pl(2, 0, 40, 10)],
  )
  sg.removeClip(1)
  check sg.clips.len == 2 and sg.placements.mapIt(it.clip) == @[0, 1] and sg.clip == 1
  sg.removeClip(1)
  check sg.clips.len == 1 and sg.placements.mapIt(it.clip) == @[0] and sg.clip == 0

  # duplicateClip: a copy at the end, name included, unmuted
  sg = Song(clips: @[Clip(name: "a", tracks: @[Track(mute: true, solo: true)])])
  sg.duplicateClip(0)
  check sg.clips.len == 2 and sg.clips[1].name == "a" and
    not sg.clips[1].tracks[0].mute and not sg.clips[1].tracks[0].solo
  check sg.clips[0].tracks[0].mute

  # toggleAll: all, or none if any is selected
  var sn = @[nt(0, 1, 60), nt(0, 1, 61, true)]
  sn.toggleAll
  check sn.allIt(not it.sel)
  sn.toggleAll
  check sn.allIt(it.sel)
  # clickSelect: a selected item keeps the group; else Shift adds, a plain click replaces
  sn = @[nt(0, 1, 60, true), nt(0, 1, 61, true), nt(0, 1, 62)]
  sn.clickSelect(0, false)
  check sn.mapIt(it.sel) == @[true, true, false]
  sn.clickSelect(2, true)
  check sn.mapIt(it.sel) == @[true, true, true]
  sn.clickSelect(1, false)
  check sn.mapIt(it.sel) == @[true, true, true]
  sn = @[nt(0, 1, 60, true), nt(0, 1, 61), nt(0, 1, 62)]
  sn.clickSelect(2, false)
  check sn.mapIt(it.sel) == @[false, false, true]
  # boxSelect: touched ones selected; the rest deselected unless Shift
  sn = @[nt(0, 1, 60, true), nt(0, 1, 61), nt(0, 1, 62)]
  sn.boxSelect(
    true,
    proc(n: Note): bool =
      n.pitch == 61,
  )
  check sn.mapIt(it.sel) == @[true, true, false]
  sn.boxSelect(
    false,
    proc(n: Note): bool =
      n.pitch == 62,
  )
  check sn.mapIt(it.sel) == @[false, false, true]
  var cpts: seq[CurvePt] = @[(0, 1, true), (10, 2, false)] # curve points too
  cpts.boxSelect(
    false,
    proc(p: CurvePt): bool =
      p.t == 10,
  )
  check cpts.mapIt(it.sel) == @[false, true]
