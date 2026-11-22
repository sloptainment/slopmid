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
    chIsLocked: bool
      ## whether the event is coming from
      ## a track that's locked

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
        evs.add Ev(offset: at.round.int, src: si, track: ti, pitch: n.pitch,
        chIsLocked: t.lockedchannel != -1 )

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
                chIsLocked: t.lockedchannel != -1
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
              chIsLocked: t.lockedchannel != -1
            )
          if en >= lo and en < hi:
            evs.add Ev(
              offset: round(base + (en - lo) * fpt).int,
              src: si,
              track: ti,
              pitch: n.pitch,
              chIsLocked: t.lockedchannel != -1
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
  for e in evs.sortedByIt((it.offset, it.on, not it.chIsLocked)):
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
      let tr = tracks(e.src)[e.track]
      if tr.lockedchannel != -1 and not tr.rhythm:
        ch = tr.lockedchannel
      else:
        for x in pl.sounding:
          if x.src == e.src and x.track == e.track:
            ch = x.ch
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
