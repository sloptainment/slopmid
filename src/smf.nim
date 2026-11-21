## Standard MIDI File export (type 1): what `advance` would send to the synth, as played in the current mode.
import std/[math, strutils]
import roll

const SampleRate = 48000 ## only sets the resolution `advance` is run at: far finer than a tick

proc vlq(n: int): string =
  var v = n
  result = $char(v and 127)
  v = v shr 7
  while v > 0:
    result = $char(128 or (v and 127)) & result
    v = v shr 7

proc chunk(tag, body: string): string =
  result = tag
  for sh in [24, 16, 8, 0]:
    result.add char((body.len shr sh) and 255)
  result.add body

proc toMidi*(song: Song): string =
  ## The song window's arrangement in song mode, one pass of the clip in clip mode. Track 0 is the
  ## tempo; each channel with notes gets a track of its own.
  ## Settings the synth would not change (repeats, overwritten at once) and notes' running status are
  ## squeezed out; the result sounds the same.
  var s = Song(clips: song.clips, clip: song.clip, placements: song.placements, songMode: song.songMode,
               laneMute: song.laneMute, laneSolo: song.laneSolo, bpm: song.bpm, playing: true)
  let endTick = if s.songMode: s.songEnd else: s.clips[s.clip].loopEnd
  let fpt = SampleRate.float / (s.bpm / 60 * Ppq)
  let frames = max(1, round(endTick.float * fpt).int)
  # ponytail: one block for the whole song; its events are at integer ticks, so rounding back is exact
  var msgs = s.advance(frames, SampleRate)
  s.playing = false
  var tail = s.advance(1, SampleRate) # releases what still sounds, at the end
  for m in tail.mitems:
    m.offset = frames
  msgs.add tail
  type Ev = tuple[tick, st, d1, d2: int]
  var evs: array[16, seq[Ev]]
  for m in msgs:
    var (st, d2) = (m.status, m.d2)
    if st shr 4 == 8: # a note-off as a note-on of velocity 0, so running status carries through note runs
      st += 0x10
      d2 = 0
    evs[st and 15].add (min(round(m.offset.float / fpt).int, endTick), st, m.d1, d2)
  proc key(e: Ev): int =
    ## What a setting sets: its controller, 128 for the wheel; -1 for anything else.
    if e.st shr 4 == 0xE: 128 elif e.st shr 4 == 0xB and e.d1 notin [6, 100, 101]: e.d1 else: -1
  var tracks: array[16, string]
  var used: array[16, bool] ## has a note: a channel with only settings is left out
  var last, status: array[16, int]
  for ch in 0 .. 15:
    # a setting overwritten at the same tick with no note starting between is never heard;
    # bank select (0) is left, it only counts at the program change after it
    var keep = newSeq[bool](evs[ch].len)
    var seen: set[0 .. 128]
    var at = -1
    for i in countdown(evs[ch].high, 0):
      let e = evs[ch][i]
      if e.tick != at:
        seen = {}
        at = e.tick
      let k = e.key
      keep[i] = k <= 0 or k notin seen
      if k > 0:
        seen.incl k
      if e.st shr 4 == 9 and e.d2 > 0:
        seen = {}
    var now: array[129, int] # the value last sent per setting
    for x in now.mitems:
      x = -1
    for i, e in evs[ch]:
      let k = e.key
      let v = if k == 128: e.d1 or (e.d2 shl 7) else: e.d2
      if not keep[i] or (k >= 0 and now[k] == v): # unchanged since it was last sent
        continue
      if k >= 0:
        now[k] = v
      if e.st shr 4 == 9 and e.d2 > 0:
        used[ch] = true
      tracks[ch].add vlq(e.tick - last[ch])
      last[ch] = e.tick
      if e.st != status[ch]: # running status: a message repeating the last one's status omits it
        tracks[ch].add char(e.st)
        status[ch] = e.st
      tracks[ch].add char(e.d1)
      if e.st shr 4 notin [0xC, 0xD]:
        tracks[ch].add char(e.d2)
  let us = round(60_000_000 / s.bpm).int
  let tempo = "\0\xFF\x51\x03" & char(us shr 16) & char((us shr 8) and 255) & char(us and 255) &
    "\0\xFF\x58\x04\4\2\x18\8" # 4/4
  var body = chunk("MTrk", tempo & "\0\xFF\x2F\0")
  var n = 1
  for ch in 0 .. 15:
    if used[ch]:
      inc n
      body.add chunk("MTrk", tracks[ch] & vlq(endTick - last[ch]) & "\xFF\x2F\0")
  result = chunk("MThd", "\0\1" & char(n shr 8) & char(n and 255) & char(Ppq shr 8) & char(Ppq and 255)) & body

when isMainModule:
  # one bar, a note on beat 1 (a beat long), one on a drum track at beat 2, 120 BPM = 500000 us/beat
  var s = Song(bpm: 120, songMode: true, clips: @[@[Track(program: 5), Track(rhythm: true)]])
  s.clips[0][0].notes = @[Note(start: 0, len: Ppq, pitch: 60, vel: 100)]
  s.clips[0][1].notes = @[Note(start: Ppq, len: 24, pitch: 36, vel: 90)]
  s.placements = @[Placement(clip: 0, start: 0, len: BarTicks)]
  let m = s.toMidi
  doAssert m[0 ..< 14] == "MThd\0\0\0\6\0\1\0\3\0\x60", m[0 ..< 14] # type 1, tempo + channels 0 and 9, 96 ppq
  doAssert "\0\xFF\x51\x03\x07\xA1\x20" in m # 500000 = 0x07A120
  # channel 0: bank, program 5, three curve defaults, bend range (3), wheel, on at 0; off 96 ticks later; end at tick 384
  doAssert "\x90\x3C\x64\x60\x3C\0" in m, "off after one beat: a velocity-0 on, running status"
  doAssert "\xC0\5" in m and "\xC9\0" in m
  doAssert "\x60\xB9\0\0" in m and "\x99\x24\x5A" in m # the drum track starts 96 ticks in
  doAssert "\xB0\x07\x64\0\x0B\x7F\0\x0A\x40" in m, "CC 7, 11, 10 share one status byte"
  doAssert m.len > 14 and m[^3 .. ^1] == "\xFF\x2F\0"
  # a muted track gets no MIDI track; a program change on a reused channel in the same bank sends no bank select again
  var u = Song(bpm: 120, songMode: true, clips: @[@[Track(program: 5), Track(program: 7), Track(program: 9, mute: true)]])
  u.clips[0][0].notes = @[Note(start: 0, len: Ppq, pitch: 60, vel: 100)]
  u.clips[0][1].notes = @[Note(start: 2 * Ppq, len: Ppq, pitch: 62, vel: 100)]
  u.clips[0][2].notes = @[Note(start: 0, len: Ppq, pitch: 64, vel: 100)]
  u.placements = s.placements
  let um = u.toMidi
  doAssert um[10 ..< 12] == "\0\2" and um.count("MTrk") == 2 and um.count("\xB0\0\0") == 1 and "\xC0\7" in um
  # clip mode plays one loop
  s.songMode = false
  doAssert s.toMidi.len == m.len
  echo "smf: ok"
