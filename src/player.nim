## Playback: the song's notes on one channel each, turned into note on/offs
## for each block the synth renders. Pure logic, no I/O.
import std/[algorithm, math, sequtils]
import model

const
  RhythmCh* = [Drums, 15, 14, 13, 12, 11, 10]
    ## channels rhythm tracks take, in order: the drums, then 16 down to 11
  GsReset* = "\x41\x10\x42\x12\x40\x00\x7F\x00\x41\xF7" ## the SysEx after F0

type
  Src = object ## a placement playing in this block
    p: Placement
    audible: bool ## its lane is

  Ev = object
    offset, src, track: int ## offset: frames into the block
    on: bool
    pitch, vel: int
    cc: bool ## a curve message, not a note
    which: int ## the curve of a `cc`
    vals: array[4, int]
      ## the track's curves now (3: pitch bend): sent to the channel before a note; a `cc` sends `vals[which]`

  Msg* = tuple[offset, status, d1, d2: int]
    ## a MIDI message, `offset` frames into the block

  Player* = object ## what `advance` remembers between blocks
    clicks*: seq[tuple[offset: int, downbeat: bool]]
      ## beats in the last `advance`d block, `offset` frames in
    sounding: seq[tuple[src, track, pitch, ch: int]]
      ## src: index into the block's sources
    sent: array[16, int] ## bank * 128 + program + 1 last sent per channel, 0 = none
    sentCc: array[3, array[16, int]]
      ## value + 1 last sent per curve and channel, 0 = none
    sentBend: array[16, int]
      ## bend last sent per channel, minus `BendMid`: 0 = centre or none
    bendSet: array[16, bool] ## the channel has had its bend range set
    rhythm*: seq[tuple[part: int, on: bool]]
      ## USE FOR RHYTHM PART changes for the last `advance`d block, to send before its messages
    extra: int
      ## rhythm channels beyond `Drums` the synth has set: `RhythmCh[0 .. extra]`
    started: bool ## the last block was playing

proc hasBend(t: Track): bool =
  t.notes.anyIt(it.bend.anyIt(it.v != 0))

proc audible(ts: seq[Track], i: int): bool =
  not ts[i].mute and (ts[i].solo or not ts.anyIt(it.solo))

proc laneAudible(s: Song, l: int): bool =
  not s.laneMute[l] and (s.laneSolo[l] or not s.laneSolo.anyIt(it))

proc rhythmSysex*(part: int, on: bool): string =
  ## USE FOR RHYTHM PART (`40 1n 15`) for Part `part`, the SysEx after F0. It stops every note and
  ## resets every channel's controllers; bank and program stay.
  let body = [0x40, 0x10 + part, 0x15, on.int]
  result = "\x41\x10\x42\x12"
  for b in body:
    result.add char(b)
  result.add char((128 - body.sum mod 128) mod 128)
  result.add "\xF7"

proc rhythmCount(c: Clip): int =
  for i, t in c.tracks:
    if t.rhythm and t.notes.len > 0 and c.tracks.audible(i):
      inc result

proc rhythmPeak(s: Song): int =
  ## The most rhythm tracks that can sound at once: an upper bound, as a track only holds a channel
  ## while a note sounds. Song mode: the largest sum over overlapping audible placements.
  if not s.songMode:
    return s.clips[s.clip].rhythmCount
  var edges: seq[tuple[tick, d: int]]
    ## a placement's end sorts before a start at the same tick
  for p in s.placements:
    if s.laneAudible(p.lane):
      let n = s.clips[p.clip].rhythmCount
      edges.add (p.start, n)
      edges.add (p.start + p.len, -n)
  edges.sort
  var cur = 0
  for e in edges:
    cur += e.d
    result = max(result, cur)

proc occupancy*(pl: Player): tuple[rhy, rhyMax, mel, melMax: int] =
  ## Channels with a note sounding, of the channels the synth has set as rhythm parts and the rest.
  var busy: set[0 .. 15]
  for x in pl.sounding:
    busy.incl x.ch
  result.rhyMax = pl.extra + 1
  result.melMax = 16 - result.rhyMax
  for c in busy:
    if c in RhythmCh[0 .. pl.extra]:
      inc result.rhy
    else:
      inc result.mel

proc soundIdx(pl: Player, src, track, pitch: int): int =
  for i, x in pl.sounding:
    if x.src == src and x.track == track and x.pitch == pitch:
      return i
  -1

proc covers(n: Note, pitch: int, t: float): bool =
  n.pitch == pitch and n.start.float <= t and t < float(n.start + n.len)

proc advance*(pl: var Player, s: var Song, frames, rate: int): seq[Msg] =
  ## The MIDI due in the next `frames`; moves the playhead past it. Clip mode
  ## loops the clip; song mode plays every placement, repeating a clip that is
  ## longer than its loop, and stops at the last one's end. Each note
  ## takes its track's channel if the track already sounds, else the lowest
  ## free one (rhythm tracks: the first free of `RhythmCh`, the last if all are busy), after a
  ## bank/program change if that channel last had another. The channel frees at the note's off.
  ## When playback starts, the channels `RhythmCh` gives to the most rhythm tracks sounding at once
  ## are made rhythm parts (`pl.rhythm`); they never change while it plays, as each cuts every note.
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
  pl.clicks.setLen 0
  pl.rhythm.setLen 0
  if s.playing:
    if not pl.started:
      pl.started = true
      let extra = clamp(s.rhythmPeak - 1, 0, RhythmCh.high)
      for i in 1 .. RhythmCh.high:
        if (i <= extra) != (i <= pl.extra):
          pl.rhythm.add (RhythmCh[i], i <= extra) # channels 11-16 are Parts 10-15
      if pl.rhythm.len > 0:
        reset pl.sentCc # the synth reset every channel's controllers
      pl.extra = extra
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
    for (si, ti, p, _) in pl.sounding:
      let ok =
        si < srcs.len and srcs[si].audible and ti < tracks(si).len and
        tracks(si).audible(ti)
      let c =
        if ok:
          srcs[si].p.clipTime(clipOf(si).loopEnd, a)
        else:
          -1.0
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
          pl.clicks.add (
            round(base + ((beat * Ppq).float - lo) * fpt).int, beat mod 4 == 0
          )
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
              vals[c] =
                if c < 3:
                  t.ccAt(c, k * step)
                else:
                  t.bendAt(k * step)
              evs.add Ev(
                offset: round(base + (float(k * step) - lo) * fpt).int,
                src: si,
                track: ti,
                cc: true,
                which: c,
                vals: vals,
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
              vals: [
                t.ccAt(0, n.start),
                t.ccAt(1, n.start),
                t.ccAt(2, n.start),
                t.bendAt(n.start),
              ],
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
      s.pos =
        if b >= lend:
          b - lend
        else:
          b
  else:
    pl.started = false
    for (si, ti, p, _) in pl.sounding:
      evs.add Ev(src: si, track: ti, pitch: p)
  template sendBend(ch, at, v: int) =
    if pl.sentBend[ch] != v - BendMid:
      if not pl.bendSet[ch]: # RPN 0, data entry MSB: the range in semitones
        pl.bendSet[ch] = true
        for (cc, val) in [(101, 0), (100, 0), (6, BendRange)]:
          result.add (at, 0xB0 or ch, cc, val)
      pl.sentBend[ch] = v - BendMid
      result.add (at, 0xE0 or ch, v and 127, v shr 7)

  # offs before ons at the same frame; offs only for what sounds
  for e in evs.sortedByIt((it.offset, it.on)):
    let at = min(e.offset, frames - 1)
    if e.cc: # only a channel that sounds the track takes it
      for x in pl.sounding:
        if x.src == e.src and x.track == e.track:
          if e.which == 3:
            sendBend(x.ch, at, e.vals[3])
          elif pl.sentCc[e.which][x.ch] != e.vals[e.which] + 1:
            pl.sentCc[e.which][x.ch] = e.vals[e.which] + 1
            result.add (at, 0xB0 or x.ch, CcNum[e.which], e.vals[e.which])
          break
      continue
    let i = pl.soundIdx(e.src, e.track, e.pitch)
    if i >= 0: # an off, or a retrigger
      let och = pl.sounding[i].ch
      result.add (at, 0x80 or och, e.pitch, 0)
      pl.sounding.delete i
      if pl.sounding.allIt(it.ch != och): # nothing left on the channel to keep bent
        sendBend(och, at, BendMid)
    if e.on:
      var ch = -1
      for x in pl.sounding:
        if x.src == e.src and x.track == e.track:
          ch = x.ch
      let tr = tracks(e.src)[e.track]
      if ch < 0:
        if tr.rhythm:
          ch = RhythmCh[pl.extra] # all busy: share the last
          for c in RhythmCh[0 .. pl.extra]:
            if pl.sounding.allIt(it.ch != c):
              ch = c
              break
        else:
          for c in 0 .. 15:
            if c notin RhythmCh[0 .. pl.extra] and pl.sounding.allIt(it.ch != c):
              ch = c
              break
      if ch < 0: # all channels busy: the note is dropped
        continue
      let want = tr.bank * 128 + tr.program + 1
      if pl.sent[ch] != want:
        pl.sent[ch] = want
        result.add (at, 0xB0 or ch, 0, tr.bank)
        result.add (at, 0xC0 or ch, tr.program, 0)
      for c in 0 .. 2:
        if pl.sentCc[c][ch] != e.vals[c] + 1:
          pl.sentCc[c][ch] = e.vals[c] + 1
          result.add (at, 0xB0 or ch, CcNum[c], e.vals[c])
      sendBend(ch, at, e.vals[3])
      result.add (at, 0x90 or ch, e.pitch, e.vel)
      pl.sounding.add (e.src, e.track, e.pitch, ch)

when isMainModule:
  proc nt(s: var Song, t = 0): var seq[Note] =
    s.clips[0].tracks[t].notes

  proc keys(ms: seq[Msg]): seq[Msg] =
    ms.filterIt(it.status shr 4 in [8, 9])

  # 120 BPM at 22050 Hz: 114.84 frames/tick, a 1024-frame block is ~8.9 ticks
  var s = Song(bpm: 120, playing: true, clips: @[Clip(tracks: @[Track()])])
  var ps: Player
  s.nt = @[Note(start: 0, len: Ppq, pitch: 60, vel: 100)]
  doAssert s.clips[0].loopEnd == BarTicks
  var log: seq[(int, Msg)]
  for blk in 0 ..< 50: # ~1.2 bars
    for m in ps.advance(s, 1024, 22050).keys:
      log.add (blk, m)
  doAssert log.len == 3, $log
  doAssert log[0] == (0, (0, 0x90, 60, 100))
  # off at tick 96 = frame 11025 = block 10, offset 785
  doAssert log[1] == (10, (785, 0x80, 60, 0)), $log[1]
  # bar 2 starts at frame 44100 = block 43, offset 68
  doAssert log[2] == (43, (68, 0x90, 60, 100)), $log[2]
  # deleting a sounding note releases it at the next block's top
  s.nt.setLen 0
  doAssert ps.advance(s, 1024, 22050) == @[(0, 0x80, 60, 0).Msg]
  # stop releases, and only once
  s.nt = @[Note(start: 0, len: BarTicks, pitch: 64, vel: 90)]
  s.clipPos = 0
  doAssert ps.advance(s, 1024, 22050).keys.len == 1
  s.playing = false
  doAssert ps.advance(s, 1024, 22050) == @[(0, 0x80, 64, 0).Msg]
  doAssert ps.advance(s, 1024, 22050).len == 0
  # a note ending on the loop seam is released there, then restarts
  s.playing = true
  s.clipPos = 0
  doAssert ps.advance(s, 1024, 22050).keys.len == 1
  s.clipPos = BarTicks - 4
  doAssert ps.advance(s, 1024, 22050) == @[(459, 0x80, 64, 0).Msg, (459, 0x90, 64, 90)]
  # metronome: a click per beat, 11025 frames apart at 120 BPM; none when off
  var c = Song(bpm: 120, playing: true, clips: @[Clip(tracks: @[Track()])])
  var pc: Player
  discard pc.advance(c, 1024, 22050)
  doAssert pc.clicks.len == 0
  c.metronome = true
  c.clipPos = 0
  discard pc.advance(c, 1024, 22050)
  doAssert pc.clicks == @[(0, true)], $pc.clicks
  c.clipPos = 10 * 1024 / 11025 * Ppq # block 10: beat 1 at frame 11025 = offset 785
  discard pc.advance(c, 1024, 22050)
  doAssert pc.clicks == @[(785, false)], $pc.clicks
  # the loop seam (bar end, tick 384 = frame 44100) is a beat too
  c.clipPos = BarTicks - 4
  discard pc.advance(c, 1024, 22050)
  doAssert pc.clicks == @[(459, true)], $pc.clicks

  # dispatch: tracks 0 and 1 sound together on channels 0 and 1, each after
  # its program change; track 2 (a later note) reuses channel 0
  var d = Song(
    bpm: 120,
    playing: true,
    clips: @[Clip(tracks: @[Track(), Track(program: 5), Track(program: 7)])],
  )
  var pd: Player
  d.nt(0) = @[Note(start: 0, len: Ppq, pitch: 60, vel: 100)]
  d.nt(1) = @[Note(start: 0, len: Ppq, pitch: 62, vel: 100)]
  d.nt(2) = @[Note(start: 2 * Ppq, len: Ppq, pitch: 64, vel: 100)]
  var all: seq[Msg]
  for blk in 0 ..< 50:
    all.add pd.advance(d, 1024, 22050)
  doAssert all[0 ..< 12] ==
    @[
      (0, 0xB0, 0, 0).Msg,
      (0, 0xC0, 0, 0),
      (0, 0xB0, 7, CcDefault[0]),
      (0, 0xB0, 11, CcDefault[1]),
      (0, 0xB0, 10, CcDefault[2]),
      (0, 0x90, 60, 100),
      (0, 0xB1, 0, 0),
      (0, 0xC1, 5, 0),
      (0, 0xB1, 7, CcDefault[0]),
      (0, 0xB1, 11, CcDefault[1]),
      (0, 0xB1, 10, CcDefault[2]),
      (0, 0x91, 62, 100),
    ], $all
  # tick 192 = frame 22050 = block 21, offset 546: channel 0 is free again, program 7
  doAssert (0xC0, 7) in all.mapIt((it.status, it.d1)) and
    all.anyIt(it.status == 0x90 and it.d1 == 64), $all
  # mute silences, solo isolates
  d.playing = true
  d.clipPos = 0
  d.clips[0].tracks[0].mute = true
  doAssert pd.advance(d, 1024, 22050).keys.filterIt(it.status == 0x90).mapIt(it.d1) ==
    @[62]
  d.clips[0].tracks[0].mute = false
  d.clips[0].tracks[1].solo = true
  d.clipPos = 0
  doAssert pd.advance(d, 1024, 22050).keys.filterIt(it.status == 0x90).mapIt(it.d1) ==
    @[62]
  # rhythm tracks take channel 10
  var r = Song(
    bpm: 120, playing: true, clips: @[Clip(tracks: @[Track(rhythm: true, program: 8)])]
  )
  var pr: Player
  r.nt = @[Note(start: 0, len: Ppq, pitch: 36, vel: 100)]
  doAssert pr.advance(r, 1024, 22050)[^1] == (0, 0x99, 36, 100).Msg
  # two rhythm tracks at once: the second takes channel 16, made a rhythm part (Part 15) at the start
  var rr = Song(
    bpm: 120,
    playing: true,
    clips: @[Clip(tracks: @[Track(rhythm: true), Track(rhythm: true, program: 16)])],
  )
  var prr: Player
  for t in 0 .. 1:
    rr.clips[0].tracks[t].notes = @[Note(start: 0, len: Ppq, pitch: 36 + t, vel: 100)]
  let rm = prr.advance(rr, 1024, 22050)
  doAssert prr.rhythm == @[(15, true)] and (0, 0x99, 36, 100).Msg in rm and
    (0, 0x9F, 37, 100).Msg in rm, $rm
  doAssert rhythmSysex(15, true) == "\x41\x10\x42\x12\x40\x1F\x15\x01\x0B\xF7"
  # nothing flips while it plays: a third rhythm track added now shares the last channel
  rr.clips[0].tracks.add Track(
    rhythm: true, notes: @[Note(start: 12, len: Ppq, pitch: 38, vel: 100)]
  )
  let rm3 = prr.advance(rr, 1024, 22050)
  doAssert prr.rhythm.len == 0 and (rr.clips[0].tracks.len == 3) and
    0x9F in rm3.mapIt(it.status), $rm3
  # melodic tracks keep off both rhythm channels
  rr.clips[0].tracks.add Track(notes: @[Note(start: 24, len: Ppq, pitch: 60, vel: 100)])
  doAssert 0x90 in prr.advance(rr, 1024, 22050).mapIt(it.status)
  # pause and play again with one rhythm track fewer: channel 16 is melodic again
  rr.playing = false
  discard prr.advance(rr, 1024, 22050)
  rr.clips[0].tracks.setLen 1
  rr.playing = true
  rr.clipPos = 0
  discard prr.advance(rr, 1024, 22050)
  doAssert prr.rhythm == @[(15, false)]
  # two rhythm tracks leave 14 channels for melodic ones: 16 tracks fill 16 different channels
  var mx = Song(bpm: 120, playing: true, clips: @[Clip(tracks: newSeq[Track](16))])
  var pmx: Player
  for t in 0 ..< 16:
    mx.clips[0].tracks[t].rhythm = t < 2
    mx.clips[0].tracks[t].notes = @[Note(start: 0, len: Ppq, pitch: 60 + t, vel: 100)]
  let cx =
    pmx.advance(mx, 1024, 22050).filterIt(it.status shr 4 == 9).mapIt(it.status and 15)
  doAssert cx.deduplicate.len == 16, $cx
  # 15 simultaneous melodic tracks fill every channel but the drums, including 15
  var m = Song(bpm: 120, playing: true, clips: @[Clip(tracks: newSeq[Track](16))])
  var pm: Player
  for t in 0 ..< 16:
    m.clips[0].tracks[t].notes = @[Note(start: 0, len: Ppq, pitch: 60 + t, vel: 100)]
  let chs = pm.advance(m, 1024, 22050).keys.filterIt(it.status shr 4 == 9).mapIt(
      it.status and 15
    )
  doAssert chs.len == 15 and 15 in chs and Drums notin chs, $chs
  # song mode: the clip placed twice back to back, the second truncated to a
  # beat; the song then stops. Tick 384 = frame 44100 = block 43, offset 68
  var g =
    Song(bpm: 120, playing: true, songMode: true, clips: @[Clip(tracks: @[Track()])])
  var pg: Player
  g.clips[0].tracks[0].notes = @[Note(start: 0, len: BarTicks, pitch: 60, vel: 100)]
  g.placements = @[
    Placement(clip: 0, start: 0, len: BarTicks),
    Placement(clip: 0, lane: 1, start: BarTicks, len: Ppq),
  ]
  proc play(pl: var Player, s: var Song): seq[(int, Msg)] =
    for blk in 0 ..< 100:
      if s.playing:
        for m in pl.advance(s, 1024, 22050).keys:
          result.add (blk, m)

  # tick 480 = frame 55125 = block 53, offset 853
  let first = pg.play(g)
  doAssert first ==
    @[
      (0, (0, 0x90, 60, 100).Msg),
      (43, (68, 0x80, 60, 0).Msg),
      (43, (68, 0x90, 60, 100).Msg),
      (53, (853, 0x80, 60, 0).Msg),
    ], $first
  doAssert not g.playing and g.songPos == 0
  # a muted lane is silent
  g.playing = true
  g.laneMute[1] = true
  doAssert pg.play(g).filterIt(it[1].status == 0x90).len == 1 # lane 0's only
  # starting 2 beats in and running 2 bars: the clip repeats at tick 192 and 576
  g.laneMute[1] = false
  g.clips[0].tracks[0].notes = @[Note(start: 0, len: Ppq, pitch: 60, vel: 100)]
  g.placements = @[Placement(clip: 0, start: 0, len: 2 * BarTicks, offset: 2 * Ppq)]
  g.playing = true
  let looped = pg.play(g).filterIt(it[1].status shr 4 == 9).mapIt((it[0], it[1].offset))
  doAssert looped == @[(21, 546), (64, 614)], $looped
  # volume: ramps 0 -> 127 over the first beat, held after; one CC 7 per 1/16 (24 ticks)
  let ramp = Track(ccRes: 0, cc: [@[(0, 0, false), (96, 127, false)], @[], @[]])
  var v = Song(bpm: 120, playing: true, clips: @[Clip(tracks: @[ramp])])
  var pv: Player
  v.nt = @[Note(start: 0, len: BarTicks, pitch: 60, vel: 100)]
  var vols: seq[int]
  for blk in 0 ..< 40: # before the loop seam at block 43
    vols.add pv.advance(v, 1024, 22050).filterIt(it.status == 0xB0 and it.d1 == 7).mapIt(
      it.d2
    )
  doAssert vols == @[0, 32, 64, 95, 127], $vols
    # steps at ticks 0, 24, 48, 72, 96; none after
  # expression is its own curve on CC 11, independent of volume
  v = Song(
    bpm: 120,
    playing: true,
    clips: @[
      Clip(
        tracks: @[Track(ccRes: 0, cc: [@[], @[(0, 127, false), (96, 0, false)], @[]])]
      )
    ],
  )
  pv = Player()
  v.nt = @[Note(start: 0, len: BarTicks, pitch: 60, vel: 100)]
  var exps: seq[int]
  for blk in 0 ..< 40:
    exps.add pv
      .advance(v, 1024, 22050)
      .filterIt(it.status == 0xB0 and it.d1 == 11)
      .mapIt(it.d2)
  doAssert exps == @[127, 95, 63, 32, 0], $exps
  # pan is the third curve, on CC 10
  v = Song(
    bpm: 120,
    playing: true,
    clips: @[
      Clip(
        tracks: @[Track(ccRes: 0, cc: [@[], @[], @[(0, 0, false), (96, 127, false)]])]
      )
    ],
  )
  pv = Player()
  v.nt = @[Note(start: 0, len: BarTicks, pitch: 60, vel: 100)]
  var pans: seq[int]
  for blk in 0 ..< 40:
    pans.add pv
      .advance(v, 1024, 22050)
      .filterIt(it.status == 0xB0 and it.d1 == 10)
      .mapIt(it.d2)
  doAssert pans == @[0, 32, 64, 95, 127], $pans
  # bend: 0 -> +12 semitones over the first beat, one message per 1/16 (24 ticks) after the range is set to 24
  var bt = Song(bpm: 120, playing: true, clips: @[Clip(tracks: @[Track(ccRes: 0)])])
  var pb: Player
  bt.nt = @[
    Note(
      start: 0,
      len: Ppq,
      pitch: 60,
      vel: 100,
      bend: @[(0, 0.0, false), (0, 12.0, false)],
    )
  ]
  var bends: seq[Msg]
  for blk in 0 ..< 40:
    bends.add pb.advance(bt, 1024, 22050)
  doAssert bends.filterIt(it.status == 0xB0 and it.d1 in [100, 101, 6]).mapIt(it.d2) ==
    @[0, 0, BendRange], $bends
  # +3, +6, +9 semitones of 24 = 9216, 10240, 11264; the wheel recentres by the note's end at tick 96
  doAssert bends.filterIt(it.status == 0xE0).mapIt(it.d2 * 128 + it.d1) ==
    @[9216, 10240, 11264, 8192], $bends
  echo "player: ok"
