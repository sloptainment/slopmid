## The song and its playback: notes on one channel, turned into note on/offs
## for each block the synth renders. Pure logic, no I/O.
import std/[algorithm, math, sequtils]

const
  Ppq* = 96 ## ticks per beat
  BarTicks* = 4 * Ppq ## 4/4 only
  Drums* = 9 ## MIDI channel 10, where rhythm tracks go
  PreviewCh* = 15 ## key previews; their own synth, so the song may use it too

type
  Note* = object
    start*, len*: int ## ticks
    pitch*, vel*: int
    sel*: bool ## selected in the piano roll

  Track* = object
    notes*: seq[Note]
    bank*, program*: int
    rhythm*: bool ## plays on the drum channel
    mute*, solo*: bool ## transient, cleared when the clip changes

  Ev = object
    offset, track: int ## offset: frames into the block
    on: bool
    pitch, vel: int

  Msg* = tuple[offset, status, d1, d2: int] ## a MIDI message, `offset` frames into the block

  Song* = object
    clips*: seq[seq[Track]] ## clip -> tracks
    clip*: int ## the one that plays
    bpm*: float
    playing*: bool
    metronome*: bool
    clicks*: seq[tuple[offset: int, downbeat: bool]] ## beats in the last `advance`d block, `offset` frames in
    pos*: float ## playhead, ticks
    sounding: seq[tuple[track, pitch, ch: int]]
    sent: array[16, int] ## bank * 128 + program + 1 last sent per channel, 0 = none

proc snap*(t, grid: int): int =
  ## `t` to the nearest multiple of `grid`.
  (t + grid div 2).floorDiv(grid) * grid

proc snapDown*(t, grid: int): int =
  t.floorDiv(grid) * grid

proc loopEnd*(ts: seq[Track]): int =
  ## Playback loops at the end of the last bar holding a note.
  result = BarTicks
  for t in ts:
    for n in t.notes:
      result = max(result, (n.start + n.len + BarTicks - 1) div BarTicks * BarTicks)

proc audible(ts: seq[Track], i: int): bool =
  not ts[i].mute and (ts[i].solo or not ts.anyIt(it.solo))

proc soundIdx(s: Song, track, pitch: int): int =
  for i, x in s.sounding:
    if x.track == track and x.pitch == pitch:
      return i
  -1

proc covers(n: Note, pitch: int, t: float): bool =
  n.pitch == pitch and n.start.float <= t and t < float(n.start + n.len)

proc advance*(s: var Song, frames, rate: int): seq[Msg] =
  ## The MIDI due in the next `frames`; moves the playhead past it. Each note
  ## takes its track's channel if the track already sounds, else the lowest
  ## free one (rhythm tracks: `Drums`), after a bank/program change if that
  ## channel last had another. The channel frees at the note's off.
  template ts(): untyped =
    s.clips[s.clip]

  var evs: seq[Ev]
  s.clicks.setLen 0
  if s.playing:
    let fpt = rate.float / (s.bpm / 60 * Ppq) # frames per tick
    let lend = ts.loopEnd.float
    let a = if s.pos >= lend: 0.0 else: s.pos
    var b = a + frames.float / fpt
    # an edit or a mute took the note out from under a sounding key
    for (ti, p, _) in s.sounding:
      if ti >= ts.len or not ts.audible(ti) or not ts[ti].notes.anyIt(it.covers(p, a)):
        evs.add Ev(track: ti, pitch: p)
    var segs = @[(a, min(b, lend), 0.0)]
    if b >= lend:
      let seam = (lend - a) * fpt
      for ti, t in ts:
        for n in t.notes:
          evs.add Ev(offset: seam.round.int, track: ti, pitch: n.pitch)
      b -= lend
      segs.add (0.0, b, seam)
    for (lo, hi, base) in segs:
      if s.metronome:
        for beat in ceil(lo / Ppq).int ..< ceil(hi / Ppq).int:
          s.clicks.add (round(base + ((beat * Ppq).float - lo) * fpt).int, beat mod 4 == 0)
      for ti, t in ts:
        if not ts.audible(ti):
          continue
        for n in t.notes:
          let (st, en) = (n.start.float, float(n.start + n.len))
          if st >= lo and st < hi:
            evs.add Ev(
              offset: round(base + (st - lo) * fpt).int,
              track: ti,
              on: true,
              pitch: n.pitch,
              vel: n.vel,
            )
          if en >= lo and en < hi:
            evs.add Ev(
              offset: round(base + (en - lo) * fpt).int, track: ti, pitch: n.pitch
            )
    s.pos = b
  else:
    for (ti, p, _) in s.sounding:
      evs.add Ev(track: ti, pitch: p)
  # offs before ons at the same frame; offs only for what sounds
  for e in evs.sortedByIt((it.offset, it.on)):
    let at = min(e.offset, frames - 1)
    let i = s.soundIdx(e.track, e.pitch)
    if i >= 0: # an off, or a retrigger
      result.add (at, 0x80 or s.sounding[i].ch, e.pitch, 0)
      s.sounding.delete i
    if e.on:
      var ch = -1
      for x in s.sounding:
        if x.track == e.track:
          ch = x.ch
      if ch < 0:
        if ts[e.track].rhythm:
          ch = Drums
        else:
          for c in 0 .. 15:
            if c != Drums and s.sounding.allIt(it.ch != c):
              ch = c
              break
      if ch < 0: # all channels busy: the note is dropped
        continue
      let want = ts[e.track].bank * 128 + ts[e.track].program + 1
      if s.sent[ch] != want:
        s.sent[ch] = want
        result.add (at, 0xB0 or ch, 0, ts[e.track].bank)
        result.add (at, 0xC0 or ch, ts[e.track].program, 0)
      result.add (at, 0x90 or ch, e.pitch, e.vel)
      s.sounding.add (e.track, e.pitch, ch)

when isMainModule:
  proc nt(s: var Song, t = 0): var seq[Note] =
    s.clips[0][t].notes

  proc keys(ms: seq[Msg]): seq[Msg] =
    ms.filterIt(it.status shr 4 in [8, 9])

  # 120 BPM at 22050 Hz: 114.84 frames/tick, a 1024-frame block is ~8.9 ticks
  var s = Song(bpm: 120, playing: true, clips: @[@[Track()]])
  s.nt = @[Note(start: 0, len: Ppq, pitch: 60, vel: 100)]
  doAssert s.clips[0].loopEnd == BarTicks
  var log: seq[(int, Msg)]
  for blk in 0 ..< 50: # ~1.2 bars
    for m in s.advance(1024, 22050).keys:
      log.add (blk, m)
  doAssert log.len == 3, $log
  doAssert log[0] == (0, (0, 0x90, 60, 100))
  # off at tick 96 = frame 11025 = block 10, offset 785
  doAssert log[1] == (10, (785, 0x80, 60, 0)), $log[1]
  # bar 2 starts at frame 44100 = block 43, offset 68
  doAssert log[2] == (43, (68, 0x90, 60, 100)), $log[2]
  # deleting a sounding note releases it at the next block's top
  s.nt.setLen 0
  doAssert s.advance(1024, 22050) == @[(0, 0x80, 60, 0).Msg]
  # stop releases, and only once
  s.nt = @[Note(start: 0, len: BarTicks, pitch: 64, vel: 90)]
  s.pos = 0
  doAssert s.advance(1024, 22050).keys.len == 1
  s.playing = false
  doAssert s.advance(1024, 22050) == @[(0, 0x80, 64, 0).Msg]
  doAssert s.advance(1024, 22050).len == 0
  # a note ending on the loop seam is released there, then restarts
  s.playing = true
  s.pos = 0
  doAssert s.advance(1024, 22050).keys.len == 1
  s.pos = BarTicks - 4
  doAssert s.advance(1024, 22050) == @[(459, 0x80, 64, 0).Msg, (459, 0x90, 64, 90)]
  # metronome: a click per beat, 11025 frames apart at 120 BPM; none when off
  var c = Song(bpm: 120, playing: true, clips: @[@[Track()]])
  discard c.advance(1024, 22050)
  doAssert c.clicks.len == 0
  c.metronome = true
  c.pos = 0
  discard c.advance(1024, 22050)
  doAssert c.clicks == @[(0, true)], $c.clicks
  c.pos = 10 * 1024 / 11025 * Ppq # block 10: beat 1 at frame 11025 = offset 785
  discard c.advance(1024, 22050)
  doAssert c.clicks == @[(785, false)], $c.clicks
  # the loop seam (bar end, tick 384 = frame 44100) is a beat too
  c.pos = BarTicks - 4
  discard c.advance(1024, 22050)
  doAssert c.clicks == @[(459, true)], $c.clicks
  doAssert snap(47, 24) == 48 and snap(-13, 24) == -24 and snapDown(47, 24) == 24
  doAssert @[Track(notes: @[Note(start: 380, len: 8)])].loopEnd == 2 * BarTicks

  # dispatch: tracks 0 and 1 sound together on channels 0 and 1, each after
  # its program change; track 2 (a later note) reuses channel 0
  var d = Song(bpm: 120, playing: true, clips: @[@[Track(), Track(program: 5), Track(program: 7)]])
  d.nt(0) = @[Note(start: 0, len: Ppq, pitch: 60, vel: 100)]
  d.nt(1) = @[Note(start: 0, len: Ppq, pitch: 62, vel: 100)]
  d.nt(2) = @[Note(start: 2 * Ppq, len: Ppq, pitch: 64, vel: 100)]
  var all: seq[Msg]
  for blk in 0 ..< 50:
    all.add d.advance(1024, 22050)
  doAssert all[0 ..< 6] ==
    @[
      (0, 0xB0, 0, 0).Msg, (0, 0xC0, 0, 0), (0, 0x90, 60, 100),
      (0, 0xB1, 0, 0), (0, 0xC1, 5, 0), (0, 0x91, 62, 100),
    ], $all
  # tick 192 = frame 22050 = block 21, offset 546: channel 0 is free again, program 7
  doAssert (0xC0, 7) in all.mapIt((it.status, it.d1)) and
    all.anyIt(it.status == 0x90 and it.d1 == 64), $all
  # mute silences, solo isolates
  d.playing = true
  d.pos = 0
  d.clips[0][0].mute = true
  doAssert d.advance(1024, 22050).keys.filterIt(it.status == 0x90).mapIt(it.d1) == @[62]
  d.clips[0][0].mute = false
  d.clips[0][1].solo = true
  d.pos = 0
  doAssert d.advance(1024, 22050).keys.filterIt(it.status == 0x90).mapIt(it.d1) == @[62]
  # rhythm tracks take channel 10
  var r = Song(bpm: 120, playing: true, clips: @[@[Track(rhythm: true, program: 8)]])
  r.nt = @[Note(start: 0, len: Ppq, pitch: 36, vel: 100)]
  doAssert r.advance(1024, 22050)[^1] == (0, 0x99, 36, 100).Msg
  # 15 simultaneous melodic tracks fill every channel but the drums, including 15
  var m = Song(bpm: 120, playing: true, clips: @[newSeq[Track](16)])
  for t in 0 ..< 16:
    m.clips[0][t].notes = @[Note(start: 0, len: Ppq, pitch: 60 + t, vel: 100)]
  let chs = m.advance(1024, 22050).keys.filterIt(it.status shr 4 == 9).mapIt(it.status and 15)
  doAssert chs.len == 15 and 15 in chs and Drums notin chs, $chs
  echo "roll: ok"
