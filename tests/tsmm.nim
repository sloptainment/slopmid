import std/[unittest, sequtils, strutils]
import ../src/model
import ../src/smm

test "smm":
  var s = Song(
    bpm: 97.5,
    clips: @[
      Clip(name: "Intro one", tracks: @[Track(bank: 1, program: 5, ccRes: 2, lockedchannel: 5)]),
      Clip(tracks: @[Track(rhythm: true)]),
    ],
    placements: @[Placement(clip: 1, lane: 3, start: 96, len: 384, offset: 48)],
  )
  s.clips[0].tracks[0].notes.add Note(
    start: 0,
    len: 96,
    pitch: 60,
    vel: 100,
    bend: @[(0, 0.0, false), (48, -1.25, false), (96, 0.0, false)],
  )
  s.clips[0].tracks[0].cc[2].add (0, 10, false)
  s.clips[0].tracks[0].cc[2].add (384, 127, false)
  s.clips[1].tracks[0].notes.add Note(start: 48, len: 24, pitch: 36, vel: 110)
  let r = fromSmm(s.toSmm)
  check r == s
  for bad in [
    "note 0 96 60 100", "clip\ntrack 0 0 3 0\nnote 0 96 200 100",
    "clip\nplace 1 0 0 96 0", "clip\nfoo", "", "clip\nbpm x",
    "clip\ntrack 0 0 3 0 16", "clip\ntrack 0 0 3 0 -2",
  ]:
    var failed = false
    try:
      discard fromSmm(bad)
    except ValueError:
      failed = true
    check failed
  # a track line without a lock is unlocked
  check fromSmm("clip\ntrack 0 0 3 0").clips[0].tracks[0].lockedchannel == -1
