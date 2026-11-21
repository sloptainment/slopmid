## The song and its playback: notes on one channel, turned into note on/offs
## for each block the synth renders. Pure logic, no I/O.
import std/[algorithm, math, sequtils]

const
  Ppq* = 96 ## ticks per beat
  BarTicks* = 4 * Ppq ## 4/4 only
  Drums* = 9 ## MIDI channel 10, where rhythm tracks go
  PreviewCh* = 15 ## key previews; their own synth, so the song may use it too
  Lanes* = 32 ## rows in the song window

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

  Placement* = object ## a clip placed in the song window
    clip*, lane*: int
    start*, len*, offset*: int ## ticks; `offset`: where in the clip it starts; past its loop end it repeats

  Src = object ## a placement playing in this block
    p: Placement
    audible: bool ## its lane is

  Ev = object
    offset, src, track: int ## offset: frames into the block
    on: bool
    pitch, vel: int

  Msg* = tuple[offset, status, d1, d2: int] ## a MIDI message, `offset` frames into the block

  Song* = object
    clips*: seq[seq[Track]] ## clip -> tracks
    clip*: int ## the one that plays in clip mode
    placements*: seq[Placement]
    songMode*: bool ## plays the placements; `pos` is then song time, not clip time
    laneMute*, laneSolo*: array[Lanes, bool]
    bpm*: float
    playing*: bool
    metronome*: bool
    clicks*: seq[tuple[offset: int, downbeat: bool]] ## beats in the last `advance`d block, `offset` frames in
    pos*: float ## playhead, ticks
    sounding: seq[tuple[src, track, pitch, ch: int]] ## src: index into the block's sources
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

proc clipTime*(p: Placement, loop: int, pos: float): float =
  ## Where song time `pos` falls in the clip placed at `p` (`loop`: its loopEnd); -1 outside the placement.
  if pos < p.start.float or pos >= p.start.float + p.len.float:
    -1.0
  else:
    (p.offset.float + pos - p.start.float) mod loop.float

proc songEnd*(s: Song): int =
  for p in s.placements:
    result = max(result, p.start + p.len)

proc laneAudible(s: Song, l: int): bool =
  not s.laneMute[l] and (s.laneSolo[l] or not s.laneSolo.anyIt(it))

proc soundIdx(s: Song, src, track, pitch: int): int =
  for i, x in s.sounding:
    if x.src == src and x.track == track and x.pitch == pitch:
      return i
  -1

proc covers(n: Note, pitch: int, t: float): bool =
  n.pitch == pitch and n.start.float <= t and t < float(n.start + n.len)

proc advance*(s: var Song, frames, rate: int): seq[Msg] =
  ## The MIDI due in the next `frames`; moves the playhead past it. Clip mode
  ## loops the clip; song mode plays every placement, repeating a clip that is
  ## longer than its loop, and stops at the last one's end. Each note
  ## takes its track's channel if the track already sounds, else the lowest
  ## free one (rhythm tracks: `Drums`), after a bank/program change if that
  ## channel last had another. The channel frees at the note's off.
  var evs: seq[Ev]
  var srcs: seq[Src] # clip mode: one, endless
  template tracks(si: int): untyped =
    s.clips[srcs[si].p.clip]

  template releaseAll(si: int, at: float) =
    for ti, t in tracks(si):
      for n in t.notes:
        evs.add Ev(offset: at.round.int, src: si, track: ti, pitch: n.pitch)

  if s.playing and s.songMode and s.pos >= s.songEnd.float:
    s.playing = false
    s.pos = 0
  s.clicks.setLen 0
  if s.playing:
    let fpt = rate.float / (s.bpm / 60 * Ppq) # frames per tick
    var a = s.pos
    if s.songMode:
      for p in s.placements:
        srcs.add Src(p: p, audible: s.laneAudible(p.lane))
    else:
      srcs.add Src(p: Placement(clip: s.clip, len: int.high div 2), audible: true)
      if a >= s.clips[s.clip].loopEnd.float:
        a = 0
    let b = a + frames.float / fpt
    # an edit, a mute or a truncation took the note out from under a sounding key
    for (si, ti, p, _) in s.sounding:
      let ok = si < srcs.len and srcs[si].audible and ti < tracks(si).len and tracks(si).audible(ti)
      let c = if ok: srcs[si].p.clipTime(tracks(si).loopEnd, a) else: -1.0
      if c < 0 or not tracks(si)[ti].notes.anyIt(it.covers(p, c)):
        evs.add Ev(src: si, track: ti, pitch: p)
    # clip-time stretches of this block: (source, from, to, frame of `from`)
    var segs: seq[tuple[si: int, lo, hi, base: float]]
    for si, x in srcs:
      let loop = tracks(si).loopEnd
      let pe = x.p.start.float + x.p.len.float
      if pe >= a and pe < b: # truncated here
        releaseAll(si, (pe - a) * fpt)
      var cur = max(a, x.p.start.float)
      let hi = min(b, pe)
      var c = x.p.clipTime(loop, cur)
      while cur < hi:
        let room = loop.float - c
        if room <= hi - cur: # reaches the loop end: the seam
          segs.add (si, c, loop.float, (cur - a) * fpt)
          cur += room
          c = 0
          releaseAll(si, (cur - a) * fpt)
        else:
          segs.add (si, c, c + hi - cur, (cur - a) * fpt)
          cur = hi
    let clickSegs =
      if s.songMode:
        @[(a, b, 0.0)]
      else:
        segs.mapIt((it.lo, it.hi, it.base))
    if s.metronome:
      for (lo, hi, base) in clickSegs:
        for beat in ceil(lo / Ppq).int ..< ceil(hi / Ppq).int:
          s.clicks.add (round(base + ((beat * Ppq).float - lo) * fpt).int, beat mod 4 == 0)
    for (si, lo, hi, base) in segs:
      if not srcs[si].audible:
        continue
      for ti, t in tracks(si):
        if not tracks(si).audible(ti):
          continue
        for n in t.notes:
          let (st, en) = (n.start.float, float(n.start + n.len))
          if st >= lo and st < hi:
            evs.add Ev(
              offset: round(base + (st - lo) * fpt).int,
              src: si,
              track: ti,
              on: true,
              pitch: n.pitch,
              vel: n.vel,
            )
          if en >= lo and en < hi:
            evs.add Ev(
              offset: round(base + (en - lo) * fpt).int,
              src: si,
              track: ti,
              pitch: n.pitch,
            )
    if s.songMode:
      s.pos = b
      if b >= s.songEnd.float:
        s.playing = false
        s.pos = 0
    else:
      let lend = tracks(0).loopEnd.float
      s.pos = if b >= lend: b - lend else: b
  else:
    for (si, ti, p, _) in s.sounding:
      evs.add Ev(src: si, track: ti, pitch: p)
  # offs before ons at the same frame; offs only for what sounds
  for e in evs.sortedByIt((it.offset, it.on)):
    let at = min(e.offset, frames - 1)
    let i = s.soundIdx(e.src, e.track, e.pitch)
    if i >= 0: # an off, or a retrigger
      result.add (at, 0x80 or s.sounding[i].ch, e.pitch, 0)
      s.sounding.delete i
    if e.on:
      var ch = -1
      for x in s.sounding:
        if x.src == e.src and x.track == e.track:
          ch = x.ch
      let tr = tracks(e.src)[e.track]
      if ch < 0:
        if tr.rhythm:
          ch = Drums
        else:
          for c in 0 .. 15:
            if c != Drums and s.sounding.allIt(it.ch != c):
              ch = c
              break
      if ch < 0: # all channels busy: the note is dropped
        continue
      let want = tr.bank * 128 + tr.program + 1
      if s.sent[ch] != want:
        s.sent[ch] = want
        result.add (at, 0xB0 or ch, 0, tr.bank)
        result.add (at, 0xC0 or ch, tr.program, 0)
      result.add (at, 0x90 or ch, e.pitch, e.vel)
      s.sounding.add (e.src, e.track, e.pitch, ch)

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
  # song mode: the clip placed twice back to back, the second truncated to a
  # beat; the song then stops. Tick 384 = frame 44100 = block 43, offset 68
  var g = Song(bpm: 120, playing: true, songMode: true, clips: @[@[Track()]])
  g.clips[0][0].notes = @[Note(start: 0, len: BarTicks, pitch: 60, vel: 100)]
  g.placements =
    @[Placement(clip: 0, start: 0, len: BarTicks), Placement(clip: 0, lane: 1, start: BarTicks, len: Ppq)]
  proc play(s: var Song): seq[(int, Msg)] =
    for blk in 0 ..< 100:
      if s.playing:
        for m in s.advance(1024, 22050).keys:
          result.add (blk, m)
  # tick 480 = frame 55125 = block 53, offset 853
  let first = g.play
  doAssert first ==
    @[(0, (0, 0x90, 60, 100).Msg), (43, (68, 0x80, 60, 0).Msg), (43, (68, 0x90, 60, 100).Msg),
      (53, (853, 0x80, 60, 0).Msg)], $first
  doAssert not g.playing and g.pos == 0
  # a muted lane is silent
  g.playing = true
  g.laneMute[1] = true
  doAssert g.play.filterIt(it[1].status == 0x90).len == 1 # lane 0's only
  # starting 2 beats in and running 2 bars: the clip repeats at tick 192 and 576
  g.laneMute[1] = false
  g.clips[0][0].notes = @[Note(start: 0, len: Ppq, pitch: 60, vel: 100)]
  g.placements = @[Placement(clip: 0, start: 0, len: 2 * BarTicks, offset: 2 * Ppq)]
  g.playing = true
  let looped = g.play.filterIt(it[1].status shr 4 == 9).mapIt((it[0], it[1].offset))
  doAssert looped == @[(21, 546), (64, 614)], $looped
  echo "roll: ok"
