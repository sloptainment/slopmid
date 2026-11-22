import std/[unittest, sequtils]
import ../src/model

test "model":
  check snap(47, 24) == 48 and snap(-13, 24) == -24 and snapDown(47, 24) == 24
  check Clip(tracks: @[Track(notes: @[Note(start: 380, len: 8)])]).loopEnd ==
    2 * BarTicks
  # `pos` is the playhead of the mode that plays, and assigns through
  var s = Song(clipPos: 1, songPos: 5)
  check s.pos == 1
  s.songMode = true
  check s.pos == 5
  s.pos = 7
  check s.songPos == 7 and s.clipPos == 1
  # volume: ramps 0 -> 127 over the first beat, held after
  let ramp = Track(ccRes: 0, cc: [@[(0, 0, false), (96, 127, false)], @[], @[]])
  check (ramp.ccAt(0, 0), ramp.ccAt(0, 48), ramp.ccAt(0, 96), ramp.ccAt(0, 500)) ==
    (0, 64, 127, 127)
  # pan is centred (64) by default
  check Track().ccAt(2, 0) == 64
  # one wheel per track: the latest start with a bend wins, a flat note never does
  let bw = Track(
    notes: @[
      Note(start: 0, len: Ppq, bend: @[(0, 0.0, false), (0, 12.0, false)]),
      Note(start: 48, len: Ppq),
      Note(start: 48, len: Ppq, bend: @[(0, 6.0, false), (0, 6.0, false)]),
    ]
  )
  check (
    bw.bendWinner(20), bw.bendWinner(60), bw.bendWinner(120), bw.bendWinner(200)
  ) == (0, 2, 2, -1)
  check (bw.bendAt(60), bw.bendAt(200)) == (8192 + 2048, 8192)
  # a middle point past the note's end is ignored; the ramp passes through the others
  let bm = Note(
    len: 48,
    bend: @[(0, 0.0, false), (24, 4.0, false), (60, 9.0, false), (0, 0.0, false)],
  )
  check (bm.bendOff(12), bm.bendOff(24), bm.bendOff(36)) == (2.0, 4.0, 2.0)
