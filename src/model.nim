## The song document and the pure rules over it: notes, tracks, clips, placements, snapping,
## curves and pitch bends. No I/O, no playback state (see `player`).
import std/math

const
  Ppq* = 96 ## ticks per beat
  BarTicks* = 4 * Ppq ## 4/4 only
  Drums* = 9 ## MIDI channel 10, where rhythm tracks go
  PreviewCh* = 15 ## key previews; their own synth, so the song may use it too
  Lanes* = 32 ## rows in the song window
  CcNum* = [7, 11, 10] ## the curves: volume, expression, pan
  CcDefault* = [100, 127, 64] ## a track's value with no points; the GM defaults
  BendRange* = 24 ## semitones either way, sent to each channel as RPN 0
  BendMid* = 8192 ## pitch bend wheel centre
  CcSteps* = [Ppq div 4, Ppq div 8, Ppq div 16, Ppq div 24]
    ## ticks between messages: 1/16, 1/32, 1/64, 1/96

type
  CurvePt* = tuple[t, v: int, sel: bool]
    ## a curve point: tick, value, selected in the editor
  BendPt* = tuple[t: int, v: float, sel: bool] ## a bend point: see `Note.bend`

  Note* = object
    start*, len*: int ## ticks
    pitch*, vel*: int
    sel*: bool ## selected in the piano roll
    bend*: seq[BendPt]
      ## pitch bend: points ramped between, `v` in semitones from the note, `sel` is the editor's selection. Empty = flat; else the first point is the note's start and the last its end (their `t` unused), the rest sorted by `t` ticks into the note, those at or past the end ignored

  Track* = object
    notes*: seq[Note]
    bank*, program*: int
    cc*: array[3, seq[CurvePt]]
      ## per curve (`CcNum`): points by tick, ramped between; held outside the first and last; `sel` is the editor's selection
    ccRes*: int = 3 ## index into `CcSteps`; default 1/96
    rhythm*: bool ## plays on the drum channel
    mute*, solo*: bool ## transient, cleared when the clip changes
    lockedchannel*: int = -1 ## The MIDI channel to fix this track to

  Clip* = object ## a named set of tracks; loops at `loopEnd`
    name*: string ## "" shows as "Clip N"
    tracks*: seq[Track]

  Placement* = object ## a clip placed in the song window
    clip*, lane*: int
    start*, len*, offset*: int
      ## ticks; `offset`: where in the clip it starts; past its loop end it repeats
    sel*: bool ## selected in the song window

  Song* = object
    clips*: seq[Clip]
    clip*: int ## the one that plays in clip mode
    placements*: seq[Placement]
    songMode*: bool ## plays the placements
    laneMute*, laneSolo*: array[Lanes, bool]
    bpm*: float
    playing*: bool
    metronome*: bool
    clipPos*: float ## the clip's playhead, ticks of clip time
    songPos*: float ## the song's playhead, ticks of song time

proc snap*(t, grid: int): int =
  ## `t` to the nearest multiple of `grid`.
  (t + grid div 2).floorDiv(grid) * grid

proc snapDown*(t, grid: int): int =
  t.floorDiv(grid) * grid

proc loopEnd*(c: Clip): int =
  ## Playback loops at the end of the last bar holding a note.
  result = BarTicks
  for t in c.tracks:
    for n in t.notes:
      result = max(result, (n.start + n.len + BarTicks - 1) div BarTicks * BarTicks)

proc ccAt*(t: Track, c, tick: int): int =
  ## Curve `c` at `tick`.
  let pts = t.cc[c]
  if pts.len == 0:
    return CcDefault[c]
  for i, p in pts:
    if tick <= p.t:
      if i == 0:
        return p.v
      let q = pts[i - 1]
      return q.v + int(round((p.v - q.v) * (tick - q.t) / (p.t - q.t)))
  pts[^1].v

proc bendVisible*(n: Note, k: int): bool =
  ## Point `k` of `n.bend` is in play: an end, or inside the note.
  n.bend.len >= 2 and (k == 0 or k == n.bend.high or n.bend[k].t in 1 ..< n.len)

proc bendIdx*(n: Note): seq[int] =
  ## The points of `n.bend` in play.
  for k in 0 .. n.bend.high:
    if n.bendVisible(k):
      result.add k

proc bendTick*(n: Note, k: int): int =
  ## Point `k`, in ticks into the note.
  if k == 0:
    0
  elif k == n.bend.high:
    n.len
  else:
    n.bend[k].t

proc bendPts*(n: Note): seq[tuple[t: int, v: float]] =
  ## The points in play as (ticks into the note, semitones); a flat line without any.
  for k in n.bendIdx:
    result.add (n.bendTick(k), n.bend[k].v)
  if result.len == 0:
    result = @[(0, 0.0), (n.len, 0.0)]

proc bendOff*(n: Note, tick: int): float =
  ## `n`'s bend in semitones at `tick`.
  let pts = n.bendPts
  let t = tick - n.start
  for i in 1 .. pts.high:
    if t <= pts[i].t:
      return
        pts[i - 1].v +
        (pts[i].v - pts[i - 1].v) * ((t - pts[i - 1].t) / (pts[i].t - pts[i - 1].t))
  pts[^1].v

proc bendRaw(off: float): int =
  clamp(BendMid + int(round(off / BendRange * BendMid.float)), 0, 2 * BendMid - 1)

proc bendWinner*(t: Track, tick: int): int =
  ## One channel, one wheel: the note sounding at `tick` with a bend, the latest start winning; -1 if none.
  result = -1
  for i, n in t.notes:
    if n.start <= tick and tick < n.start + n.len and n.bendOff(tick).bendRaw != BendMid and
        (result < 0 or n.start >= t.notes[result].start):
      result = i

proc bendAt*(t: Track, tick: int): int =
  ## The wheel at `tick`, 0 .. 16383.
  let w = t.bendWinner(tick)
  if w < 0:
    BendMid
  else:
    t.notes[w].bendOff(tick).bendRaw

proc pos*(s: var Song): var float =
  ## The playhead of the mode that plays.
  if s.songMode:
    result = s.songPos
  else:
    result = s.clipPos

proc clipTime*(p: Placement, loop: int, pos: float): float =
  ## Where song time `pos` falls in the clip placed at `p` (`loop`: its loopEnd); -1 outside the placement.
  if pos < p.start.float or pos >= p.start.float + p.len.float:
    -1.0
  else:
    (p.offset.float + pos - p.start.float) mod loop.float

proc songEnd*(s: Song): int =
  for p in s.placements:
    result = max(result, p.start + p.len)
