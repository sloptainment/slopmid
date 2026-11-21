## The song and its playback: notes on one channel, turned into note on/offs
## for each block the synth renders. Pure logic, no I/O.
import std/[algorithm, math, sequtils]

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
  CcSteps* = [Ppq div 4, Ppq div 8, Ppq div 16, Ppq div 24] ## ticks between messages: 1/16, 1/32, 1/64, 1/96

type
  Note* = object
    start*, len*: int ## ticks
    pitch*, vel*: int
    sel*: bool ## selected in the piano roll
    bend*: seq[tuple[t: int, v: float, sel: bool]] ## pitch bend: points ramped between, `v` in semitones from the note, `sel` is the editor's selection. Empty = flat; else the first point is the note's start and the last its end (their `t` unused), the rest sorted by `t` ticks into the note, those at or past the end ignored

  Track* = object
    notes*: seq[Note]
    bank*, program*: int
    cc*: array[3, seq[tuple[t, v: int, sel: bool]]] ## per curve (`CcNum`): points by tick, ramped between; held outside the first and last; `sel` is the editor's selection
    ccRes*: int = 3 ## index into `CcSteps`; default 1/96
    rhythm*: bool ## plays on the drum channel
    mute*, solo*: bool ## transient, cleared when the clip changes

  Clip* = object ## a named set of tracks; loops at `loopEnd`
    name*: string ## "" shows as "Clip N"
    tracks*: seq[Track]

  Placement* = object ## a clip placed in the song window
    clip*, lane*: int
    start*, len*, offset*: int ## ticks; `offset`: where in the clip it starts; past its loop end it repeats
    sel*: bool ## selected in the song window

  Src = object ## a placement playing in this block
    p: Placement
    audible: bool ## its lane is

  Ev = object
    offset, src, track: int ## offset: frames into the block
    on: bool
    pitch, vel: int
    cc: bool ## a curve message, not a note
    which: int ## the curve of a `cc`
    vals: array[4, int] ## the track's curves now (3: pitch bend): sent to the channel before a note; a `cc` sends `vals[which]`

  Msg* = tuple[offset, status, d1, d2: int] ## a MIDI message, `offset` frames into the block

  Song* = object
    clips*: seq[Clip]
    clip*: int ## the one that plays in clip mode
    placements*: seq[Placement]
    songMode*: bool ## plays the placements; `pos` is then song time, not clip time
    laneMute*, laneSolo*: array[Lanes, bool]
    bpm*: float
    playing*: bool
    metronome*: bool
    clicks*: seq[tuple[offset: int, downbeat: bool]] ## beats in the last `advance`d block, `offset` frames in
    pos*: float ## playhead, ticks
    idlePos*: float ## the other mode's playhead: song time in clip mode, clip time in song mode; swaps with `pos` on a mode change
    sounding: seq[tuple[src, track, pitch, ch: int]] ## src: index into the block's sources
    sent: array[16, int] ## bank * 128 + program + 1 last sent per channel, 0 = none
    sentCc: array[3, array[16, int]] ## value + 1 last sent per curve and channel, 0 = none
    sentBend: array[16, int] ## bend last sent per channel, minus `BendMid`: 0 = centre or none
    bendSet: array[16, bool] ## the channel has had its bend range set

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
  if k == 0: 0 elif k == n.bend.high: n.len else: n.bend[k].t

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
      return pts[i - 1].v + (pts[i].v - pts[i - 1].v) * ((t - pts[i - 1].t) / (pts[i].t - pts[i - 1].t))
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
  if w < 0: BendMid else: t.notes[w].bendOff(tick).bendRaw

proc hasBend(t: Track): bool =
  t.notes.anyIt(it.bend.anyIt(it.v != 0))

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
  template clipOf(si: int): untyped =
    s.clips[srcs[si].p.clip]
  template tracks(si: int): untyped =
    clipOf(si).tracks

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
      let c = if ok: srcs[si].p.clipTime(clipOf(si).loopEnd, a) else: -1.0
      if c < 0 or not tracks(si)[ti].notes.anyIt(it.covers(p, c)):
        evs.add Ev(src: si, track: ti, pitch: p)
    # clip-time stretches of this block: (source, from, to, frame of `from`)
    var segs: seq[tuple[si: int, lo, hi, base: float]]
    for si, x in srcs:
      let loop = clipOf(si).loopEnd
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
        for c in 0 .. 3:
          if (if c < 3: t.cc[c].len > 0 else: t.hasBend):
            let step = CcSteps[t.ccRes]
            for k in ceil(lo / step.float).int ..< ceil(hi / step.float).int:
              var vals: array[4, int]
              vals[c] = if c < 3: t.ccAt(c, k * step) else: t.bendAt(k * step)
              evs.add Ev(
                offset: round(base + (float(k * step) - lo) * fpt).int,
                src: si, track: ti, cc: true, which: c, vals: vals,
              )
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
              vals: [t.ccAt(0, n.start), t.ccAt(1, n.start), t.ccAt(2, n.start), t.bendAt(n.start)],
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
      let lend = clipOf(0).loopEnd.float
      s.pos = if b >= lend: b - lend else: b
  else:
    for (si, ti, p, _) in s.sounding:
      evs.add Ev(src: si, track: ti, pitch: p)
  template sendBend(ch, at, v: int) =
    if s.sentBend[ch] != v - BendMid:
      if not s.bendSet[ch]: # RPN 0, data entry MSB: the range in semitones
        s.bendSet[ch] = true
        for (cc, val) in [(101, 0), (100, 0), (6, BendRange)]:
          result.add (at, 0xB0 or ch, cc, val)
      s.sentBend[ch] = v - BendMid
      result.add (at, 0xE0 or ch, v and 127, v shr 7)

  # offs before ons at the same frame; offs only for what sounds
  for e in evs.sortedByIt((it.offset, it.on)):
    let at = min(e.offset, frames - 1)
    if e.cc: # only a channel that sounds the track takes it
      for x in s.sounding:
        if x.src == e.src and x.track == e.track:
          if e.which == 3:
            sendBend(x.ch, at, e.vals[3])
          elif s.sentCc[e.which][x.ch] != e.vals[e.which] + 1:
            s.sentCc[e.which][x.ch] = e.vals[e.which] + 1
            result.add (at, 0xB0 or x.ch, CcNum[e.which], e.vals[e.which])
          break
      continue
    let i = s.soundIdx(e.src, e.track, e.pitch)
    if i >= 0: # an off, or a retrigger
      let och = s.sounding[i].ch
      result.add (at, 0x80 or och, e.pitch, 0)
      s.sounding.delete i
      if s.sounding.allIt(it.ch != och): # nothing left on the channel to keep bent
        sendBend(och, at, BendMid)
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
      for c in 0 .. 2:
        if s.sentCc[c][ch] != e.vals[c] + 1:
          s.sentCc[c][ch] = e.vals[c] + 1
          result.add (at, 0xB0 or ch, CcNum[c], e.vals[c])
      sendBend(ch, at, e.vals[3])
      result.add (at, 0x90 or ch, e.pitch, e.vel)
      s.sounding.add (e.src, e.track, e.pitch, ch)

when isMainModule:
  proc nt(s: var Song, t = 0): var seq[Note] =
    s.clips[0].tracks[t].notes

  proc keys(ms: seq[Msg]): seq[Msg] =
    ms.filterIt(it.status shr 4 in [8, 9])

  # 120 BPM at 22050 Hz: 114.84 frames/tick, a 1024-frame block is ~8.9 ticks
  var s = Song(bpm: 120, playing: true, clips: @[Clip(tracks: @[Track()])])
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
  var c = Song(bpm: 120, playing: true, clips: @[Clip(tracks: @[Track()])])
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
  doAssert Clip(tracks: @[Track(notes: @[Note(start: 380, len: 8)])]).loopEnd == 2 * BarTicks

  # dispatch: tracks 0 and 1 sound together on channels 0 and 1, each after
  # its program change; track 2 (a later note) reuses channel 0
  var d = Song(bpm: 120, playing: true, clips: @[Clip(tracks: @[Track(), Track(program: 5), Track(program: 7)])])
  d.nt(0) = @[Note(start: 0, len: Ppq, pitch: 60, vel: 100)]
  d.nt(1) = @[Note(start: 0, len: Ppq, pitch: 62, vel: 100)]
  d.nt(2) = @[Note(start: 2 * Ppq, len: Ppq, pitch: 64, vel: 100)]
  var all: seq[Msg]
  for blk in 0 ..< 50:
    all.add d.advance(1024, 22050)
  doAssert all[0 ..< 12] ==
    @[
      (0, 0xB0, 0, 0).Msg, (0, 0xC0, 0, 0), (0, 0xB0, 7, CcDefault[0]), (0, 0xB0, 11, CcDefault[1]), (0, 0xB0, 10, CcDefault[2]), (0, 0x90, 60, 100),
      (0, 0xB1, 0, 0), (0, 0xC1, 5, 0), (0, 0xB1, 7, CcDefault[0]), (0, 0xB1, 11, CcDefault[1]), (0, 0xB1, 10, CcDefault[2]), (0, 0x91, 62, 100),
    ], $all
  # tick 192 = frame 22050 = block 21, offset 546: channel 0 is free again, program 7
  doAssert (0xC0, 7) in all.mapIt((it.status, it.d1)) and
    all.anyIt(it.status == 0x90 and it.d1 == 64), $all
  # mute silences, solo isolates
  d.playing = true
  d.pos = 0
  d.clips[0].tracks[0].mute = true
  doAssert d.advance(1024, 22050).keys.filterIt(it.status == 0x90).mapIt(it.d1) == @[62]
  d.clips[0].tracks[0].mute = false
  d.clips[0].tracks[1].solo = true
  d.pos = 0
  doAssert d.advance(1024, 22050).keys.filterIt(it.status == 0x90).mapIt(it.d1) == @[62]
  # rhythm tracks take channel 10
  var r = Song(bpm: 120, playing: true, clips: @[Clip(tracks: @[Track(rhythm: true, program: 8)])])
  r.nt = @[Note(start: 0, len: Ppq, pitch: 36, vel: 100)]
  doAssert r.advance(1024, 22050)[^1] == (0, 0x99, 36, 100).Msg
  # 15 simultaneous melodic tracks fill every channel but the drums, including 15
  var m = Song(bpm: 120, playing: true, clips: @[Clip(tracks: newSeq[Track](16))])
  for t in 0 ..< 16:
    m.clips[0].tracks[t].notes = @[Note(start: 0, len: Ppq, pitch: 60 + t, vel: 100)]
  let chs = m.advance(1024, 22050).keys.filterIt(it.status shr 4 == 9).mapIt(it.status and 15)
  doAssert chs.len == 15 and 15 in chs and Drums notin chs, $chs
  # song mode: the clip placed twice back to back, the second truncated to a
  # beat; the song then stops. Tick 384 = frame 44100 = block 43, offset 68
  var g = Song(bpm: 120, playing: true, songMode: true, clips: @[Clip(tracks: @[Track()])])
  g.clips[0].tracks[0].notes = @[Note(start: 0, len: BarTicks, pitch: 60, vel: 100)]
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
  g.clips[0].tracks[0].notes = @[Note(start: 0, len: Ppq, pitch: 60, vel: 100)]
  g.placements = @[Placement(clip: 0, start: 0, len: 2 * BarTicks, offset: 2 * Ppq)]
  g.playing = true
  let looped = g.play.filterIt(it[1].status shr 4 == 9).mapIt((it[0], it[1].offset))
  doAssert looped == @[(21, 546), (64, 614)], $looped
  # volume: ramps 0 -> 127 over the first beat, held after; one CC 7 per 1/16 (24 ticks)
  let ramp = Track(ccRes: 0, cc: [@[(0, 0, false), (96, 127, false)], @[], @[]])
  doAssert (ramp.ccAt(0, 0), ramp.ccAt(0, 48), ramp.ccAt(0, 96), ramp.ccAt(0, 500)) == (0, 64, 127, 127)
  var v = Song(bpm: 120, playing: true, clips: @[Clip(tracks: @[ramp])])
  v.nt = @[Note(start: 0, len: BarTicks, pitch: 60, vel: 100)]
  var vols: seq[int]
  for blk in 0 ..< 40: # before the loop seam at block 43
    vols.add v.advance(1024, 22050).filterIt(it.status == 0xB0 and it.d1 == 7).mapIt(it.d2)
  doAssert vols == @[0, 32, 64, 95, 127], $vols # steps at ticks 0, 24, 48, 72, 96; none after
  # expression is its own curve on CC 11, independent of volume
  v = Song(bpm: 120, playing: true, clips: @[Clip(tracks: @[Track(ccRes: 0, cc: [@[], @[(0, 127, false), (96, 0, false)], @[]])])])
  v.nt = @[Note(start: 0, len: BarTicks, pitch: 60, vel: 100)]
  var exps: seq[int]
  for blk in 0 ..< 40:
    exps.add v.advance(1024, 22050).filterIt(it.status == 0xB0 and it.d1 == 11).mapIt(it.d2)
  doAssert exps == @[127, 95, 63, 32, 0], $exps
  # pan is the third curve, on CC 10, centred (64) by default
  v = Song(bpm: 120, playing: true, clips: @[Clip(tracks: @[Track(ccRes: 0, cc: [@[], @[], @[(0, 0, false), (96, 127, false)]])])])
  v.nt = @[Note(start: 0, len: BarTicks, pitch: 60, vel: 100)]
  var pans: seq[int]
  for blk in 0 ..< 40:
    pans.add v.advance(1024, 22050).filterIt(it.status == 0xB0 and it.d1 == 10).mapIt(it.d2)
  doAssert pans == @[0, 32, 64, 95, 127], $pans
  doAssert Track().ccAt(2, 0) == 64
  # bend: 0 -> +12 semitones over the first beat, one message per 1/16 (24 ticks) after the range is set to 24
  var bt = Song(bpm: 120, playing: true, clips: @[Clip(tracks: @[Track(ccRes: 0)])])
  bt.nt = @[Note(start: 0, len: Ppq, pitch: 60, vel: 100, bend: @[(0, 0.0, false), (0, 12.0, false)])]
  var bends: seq[Msg]
  for blk in 0 ..< 40:
    bends.add bt.advance(1024, 22050)
  doAssert bends.filterIt(it.status == 0xB0 and it.d1 in [100, 101, 6]).mapIt(it.d2) == @[0, 0, BendRange], $bends
  # +3, +6, +9 semitones of 24 = 9216, 10240, 11264; the wheel recentres by the note's end at tick 96
  doAssert bends.filterIt(it.status == 0xE0).mapIt(it.d2 * 128 + it.d1) == @[9216, 10240, 11264, 8192], $bends
  # one wheel per track: the latest start with a bend wins, a flat note never does
  let bw = Track(notes: @[
    Note(start: 0, len: Ppq, bend: @[(0, 0.0, false), (0, 12.0, false)]),
    Note(start: 48, len: Ppq),
    Note(start: 48, len: Ppq, bend: @[(0, 6.0, false), (0, 6.0, false)]),
  ])
  doAssert (bw.bendWinner(20), bw.bendWinner(60), bw.bendWinner(120), bw.bendWinner(200)) == (0, 2, 2, -1)
  doAssert (bw.bendAt(60), bw.bendAt(200)) == (8192 + 2048, 8192)
  # a middle point past the note's end is ignored; the ramp passes through the others
  let bm = Note(len: 48, bend: @[(0, 0.0, false), (24, 4.0, false), (60, 9.0, false), (0, 0.0, false)])
  doAssert (bm.bendOff(12), bm.bendOff(24), bm.bendOff(36)) == (2.0, 4.0, 2.0)
  echo "roll: ok"
