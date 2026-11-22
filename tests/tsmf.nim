import std/[unittest, math, strutils]
import ../src/player
import ../src/model
import ../src/smf

test "smf":
  # one bar, a note on beat 1 (a beat long), one on a drum track at beat 2, 120 BPM = 500000 us/beat
  var s = Song(
    bpm: 120,
    songMode: true,
    clips: @[Clip(tracks: @[Track(program: 5), Track(rhythm: true)])],
  )
  s.clips[0].tracks[0].notes = @[Note(start: 0, len: Ppq, pitch: 60, vel: 100)]
  s.clips[0].tracks[1].notes = @[Note(start: Ppq, len: 24, pitch: 36, vel: 90)]
  s.placements = @[Placement(clip: 0, start: 0, len: BarTicks)]
  let m = s.toMidi
  check m[0 ..< 14] == "MThd\0\0\0\6\0\1\0\3\0\x60"
    # type 1, tempo + channels 0 and 9, 96 ppq
  check "\0\xFF\x51\x03\x07\xA1\x20" in m # 500000 = 0x07A120
  # channel 0: bank, program 5, three curve defaults, bend range (3), wheel, on at 0; off 96 ticks later; end at tick 384
  check "\x90\x3C\x64\x60\x3C\0" in m
  check "\xC0\5" in m and "\xC9\0" in m
  check "\x60\xB9\0\0" in m and "\x99\x24\x5A" in m
    # the drum track starts 96 ticks in
  check "\xB0\x07\x64\0\x0B\x7F\0\x0A\x40" in m
  check m.len > 14 and m[^3 .. ^1] == "\xFF\x2F\0"
  # a muted track gets no MIDI track; a program change on a reused channel in the same bank sends no bank select again
  var u = Song(
    bpm: 120,
    songMode: true,
    clips: @[
      Clip(
        tracks: @[Track(program: 5), Track(program: 7), Track(program: 9, mute: true)]
      )
    ],
  )
  u.clips[0].tracks[0].notes = @[Note(start: 0, len: Ppq, pitch: 60, vel: 100)]
  u.clips[0].tracks[1].notes = @[Note(start: 2 * Ppq, len: Ppq, pitch: 62, vel: 100)]
  u.clips[0].tracks[2].notes = @[Note(start: 0, len: Ppq, pitch: 64, vel: 100)]
  u.placements = s.placements
  let um = u.toMidi
  check um[10 ..< 12] == "\0\2" and um.count("MTrk") == 2 and
    um.count("\xB0\0\0") == 1 and "\xC0\7" in um
  # clip mode plays one loop
  s.songMode = false
  check s.toMidi.len == m.len
  # two rhythm tracks at once: channel 16 (Part 15) is made a rhythm part after a GS reset, in the tempo track
  var d = Song(
    bpm: 120,
    songMode: true,
    clips: @[Clip(tracks: @[Track(rhythm: true), Track(rhythm: true, program: 16)])],
  )
  for t in 0 .. 1:
    d.clips[0].tracks[t].notes = @[Note(start: 0, len: 24, pitch: 36 + t, vel: 90)]
  d.placements = @[Placement(clip: 0, start: 0, len: BarTicks)]
  let dm = d.toMidi
  check "\0\xF0\x0A" & GsReset in dm and
    "\0\xF0\x0A\x41\x10\x42\x12\x40\x1F\x15\x01\x0B\xF7" in dm
  check "\x99\x24\x5A" in dm and "\x9F\x25\x5A" in dm
