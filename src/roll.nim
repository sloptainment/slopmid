## The song and its playback: notes on one channel, turned into note on/offs
## for each block the synth renders. Pure logic, no I/O.
import std/[algorithm, math, sequtils]

const
  Ppq* = 96            ## ticks per beat
  BarTicks* = 4 * Ppq  ## 4/4 only

type
  Note* = object
    start*, len*: int  ## ticks
    pitch*, vel*: int
  Ev* = object
    offset*: int       ## frames into the block
    on*: bool
    pitch*, vel*: int
  Song* = object
    notes*: seq[Note]
    bpm*: float
    playing*: bool
    pos*: float        ## playhead, ticks
    sounding: array[128, bool]

proc snap*(t, grid: int): int =
  ## `t` to the nearest multiple of `grid`.
  (t + grid div 2).floorDiv(grid) * grid

proc snapDown*(t, grid: int): int = t.floorDiv(grid) * grid

proc loopEnd*(s: Song): int =
  ## Playback loops at the end of the last bar holding a note.
  result = BarTicks
  for n in s.notes:
    result = max(result, (n.start + n.len + BarTicks - 1) div BarTicks * BarTicks)

proc covers(n: Note, pitch: int, t: float): bool =
  n.pitch == pitch and n.start.float <= t and t < float(n.start + n.len)

proc advance*(s: var Song, frames, rate: int): seq[Ev] =
  ## The note on/offs due in the next `frames`; moves the playhead past them.
  var evs: seq[Ev]
  if s.playing:
    let fpt = rate.float / (s.bpm / 60 * Ppq)  # frames per tick
    let lend = s.loopEnd.float
    let a = if s.pos >= lend: 0.0 else: s.pos
    var b = a + frames.float / fpt
    # an edit took the note out from under a sounding key
    for p in 0..127:
      if s.sounding[p] and not s.notes.anyIt(it.covers(p, a)):
        evs.add Ev(pitch: p)
    var segs = @[(a, min(b, lend), 0.0)]
    if b >= lend:
      let seam = (lend - a) * fpt
      for n in s.notes: evs.add Ev(offset: seam.round.int, pitch: n.pitch)
      b -= lend
      segs.add (0.0, b, seam)
    for (lo, hi, base) in segs:
      for n in s.notes:
        let (st, en) = (n.start.float, float(n.start + n.len))
        if st >= lo and st < hi:
          evs.add Ev(offset: round(base + (st - lo) * fpt).int, on: true, pitch: n.pitch, vel: n.vel)
        if en >= lo and en < hi:
          evs.add Ev(offset: round(base + (en - lo) * fpt).int, pitch: n.pitch)
    s.pos = b
  else:
    for p in 0..127: evs.add Ev(pitch: p)
  # offs before ons at the same frame; offs only for what sounds
  for e in evs.sortedByIt((it.offset, it.on)):
    if e.on or s.sounding[e.pitch]:
      s.sounding[e.pitch] = e.on
      result.add Ev(offset: min(e.offset, frames - 1), on: e.on, pitch: e.pitch, vel: e.vel)

when isMainModule:
  # 120 BPM at 22050 Hz: 114.84 frames/tick, a 1024-frame block is ~8.9 ticks
  var s = Song(bpm: 120, playing: true, notes: @[Note(start: 0, len: Ppq, pitch: 60, vel: 100)])
  doAssert s.loopEnd == BarTicks
  var log: seq[(int, Ev)]
  for blk in 0 ..< 50:  # ~1.2 bars
    for e in s.advance(1024, 22050): log.add (blk, e)
  doAssert log.len == 3, $log
  doAssert log[0] == (0, Ev(offset: 0, on: true, pitch: 60, vel: 100))
  # off at tick 96 = frame 11025 = block 10, offset 785
  doAssert log[1] == (10, Ev(offset: 785, pitch: 60)), $log[1]
  # bar 2 starts at frame 44100 = block 43, offset 68
  doAssert log[2] == (43, Ev(offset: 68, on: true, pitch: 60, vel: 100)), $log[2]
  # deleting a sounding note releases it at the next block's top
  s.notes.setLen 0
  doAssert s.advance(1024, 22050) == @[Ev(pitch: 60)]
  # stop releases, and only once
  s.notes = @[Note(start: 0, len: BarTicks, pitch: 64, vel: 90)]
  s.pos = 0
  doAssert s.advance(1024, 22050).len == 1
  s.playing = false
  doAssert s.advance(1024, 22050) == @[Ev(pitch: 64)]
  doAssert s.advance(1024, 22050).len == 0
  # a note ending on the loop seam is released there, then restarts
  s.playing = true
  s.pos = 0
  doAssert s.advance(1024, 22050).len == 1
  s.pos = BarTicks - 4
  doAssert s.advance(1024, 22050) == @[Ev(offset: 459, pitch: 64), Ev(offset: 459, on: true, pitch: 64, vel: 90)]
  doAssert snap(47, 24) == 48 and snap(-13, 24) == -24 and snapDown(47, 24) == 24
  doAssert Song(notes: @[Note(start: 380, len: 8)]).loopEnd == 2 * BarTicks
  echo "roll: ok"
