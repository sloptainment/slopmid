import std/[unittest, algorithm, math, sequtils]
import ../src/model
import ../src/player

test "player":
  proc nt(s: var Song, t = 0): var seq[Note] =
    s.clips[0].tracks[t].notes

  proc keys(ms: seq[Msg]): seq[Msg] =
    ms.filterIt(it.status shr 4 in [8, 9])

  # 120 BPM at 22050 Hz: 114.84 frames/tick, a 1024-frame block is ~8.9 ticks
  var s = Song(bpm: 120, playing: true, clips: @[Clip(tracks: @[Track()])])
  var ps: Player
  s.nt = @[Note(start: 0, len: Ppq, pitch: 60, vel: 100)]
  check s.clips[0].loopEnd == BarTicks
  var log: seq[(int, Msg)]
  for blk in 0 ..< 50: # ~1.2 bars
    for m in ps.advance(s, 1024, 22050).keys:
      log.add (blk, m)
  check log.len == 3
  check log[0] == (0, (0, 0x90, 60, 100))
  # off at tick 96 = frame 11025 = block 10, offset 785
  check log[1] == (10, (785, 0x80, 60, 0))
  # bar 2 starts at frame 44100 = block 43, offset 68
  check log[2] == (43, (68, 0x90, 60, 100))
  # deleting a sounding note releases it at the next block's top
  s.nt.setLen 0
  check ps.advance(s, 1024, 22050) == @[(0, 0x80, 60, 0).Msg]
  # stop releases, and only once
  s.nt = @[Note(start: 0, len: BarTicks, pitch: 64, vel: 90)]
  s.clipPos = 0
  check ps.advance(s, 1024, 22050).keys.len == 1
  s.playing = false
  check ps.advance(s, 1024, 22050) == @[(0, 0x80, 64, 0).Msg]
  check ps.advance(s, 1024, 22050).len == 0
  # a note ending on the loop seam is released there, then restarts
  s.playing = true
  s.clipPos = 0
  check ps.advance(s, 1024, 22050).keys.len == 1
  s.clipPos = BarTicks - 4
  check ps.advance(s, 1024, 22050) == @[(459, 0x80, 64, 0).Msg, (459, 0x90, 64, 90)]
  # metronome: a click per beat, 11025 frames apart at 120 BPM; none when off
  var c = Song(bpm: 120, playing: true, clips: @[Clip(tracks: @[Track()])])
  var pc: Player
  discard pc.advance(c, 1024, 22050)
  check pc.clicks.len == 0
  c.metronome = true
  c.clipPos = 0
  discard pc.advance(c, 1024, 22050)
  check pc.clicks == @[(0, true)]
  c.clipPos = 10 * 1024 / 11025 * Ppq # block 10: beat 1 at frame 11025 = offset 785
  discard pc.advance(c, 1024, 22050)
  check pc.clicks == @[(785, false)]
  # the loop seam (bar end, tick 384 = frame 44100) is a beat too
  c.clipPos = BarTicks - 4
  discard pc.advance(c, 1024, 22050)
  check pc.clicks == @[(459, true)]
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
  check all[0 ..< 12] ==
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
    ]
  # tick 192 = frame 22050 = block 21, offset 546: channel 0 is free again, program 7
  check (0xC0, 7) in all.mapIt((it.status, it.d1)) and
    all.anyIt(it.status == 0x90 and it.d1 == 64)
  # mute silences, solo isolates
  d.playing = true
  d.clipPos = 0
  d.clips[0].tracks[0].mute = true
  check pd.advance(d, 1024, 22050).keys.filterIt(it.status == 0x90).mapIt(it.d1) ==
    @[62]
  d.clips[0].tracks[0].mute = false
  d.clips[0].tracks[1].solo = true
  d.clipPos = 0
  check pd.advance(d, 1024, 22050).keys.filterIt(it.status == 0x90).mapIt(it.d1) ==
    @[62]
  # rhythm tracks take channel 10
  var r = Song(
    bpm: 120, playing: true, clips: @[Clip(tracks: @[Track(rhythm: true, program: 8)])]
  )
  var pr: Player
  r.nt = @[Note(start: 0, len: Ppq, pitch: 36, vel: 100)]
  check pr.advance(r, 1024, 22050)[^1] == (0, 0x99, 36, 100).Msg
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
  check prr.rhythm == @[(15, true)] and (0, 0x99, 36, 100).Msg in rm and
    (0, 0x9F, 37, 100).Msg in rm
  check rhythmSysex(15, true) == "\x41\x10\x42\x12\x40\x1F\x15\x01\x0B\xF7"
  # nothing flips while it plays: a third rhythm track added now shares the last channel
  rr.clips[0].tracks.add Track(
    rhythm: true, notes: @[Note(start: 12, len: Ppq, pitch: 38, vel: 100)]
  )
  let rm3 = prr.advance(rr, 1024, 22050)
  check prr.rhythm.len == 0 and (rr.clips[0].tracks.len == 3) and
    0x9F in rm3.mapIt(it.status)
  # melodic tracks keep off both rhythm channels
  rr.clips[0].tracks.add Track(notes: @[Note(start: 24, len: Ppq, pitch: 60, vel: 100)])
  check 0x90 in prr.advance(rr, 1024, 22050).mapIt(it.status)
  # pause and play again with one rhythm track fewer: channel 16 is melodic again
  rr.playing = false
  discard prr.advance(rr, 1024, 22050)
  rr.clips[0].tracks.setLen 1
  rr.playing = true
  rr.clipPos = 0
  discard prr.advance(rr, 1024, 22050)
  check prr.rhythm == @[(15, false)]
  # two rhythm tracks leave 14 channels for melodic ones: 16 tracks fill 16 different channels
  var mx = Song(bpm: 120, playing: true, clips: @[Clip(tracks: newSeq[Track](16))])
  var pmx: Player
  for t in 0 ..< 16:
    mx.clips[0].tracks[t].rhythm = t < 2
    mx.clips[0].tracks[t].notes = @[Note(start: 0, len: Ppq, pitch: 60 + t, vel: 100)]
  let cx =
    pmx.advance(mx, 1024, 22050).filterIt(it.status shr 4 == 9).mapIt(it.status and 15)
  check cx.deduplicate.len == 16
  # 15 simultaneous melodic tracks fill every channel but the drums, including 15
  var m = Song(bpm: 120, playing: true, clips: @[Clip(tracks: newSeq[Track](16))])
  var pm: Player
  for t in 0 ..< 16:
    m.clips[0].tracks[t].notes = @[Note(start: 0, len: Ppq, pitch: 60 + t, vel: 100)]
  let chs = pm.advance(m, 1024, 22050).keys.filterIt(it.status shr 4 == 9).mapIt(
      it.status and 15
    )
  check chs.len == 15 and 15 in chs and Drums notin chs
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
  check first ==
    @[
      (0, (0, 0x90, 60, 100).Msg),
      (43, (68, 0x80, 60, 0).Msg),
      (43, (68, 0x90, 60, 100).Msg),
      (53, (853, 0x80, 60, 0).Msg),
    ]
  check not g.playing and g.songPos == 0
  # a muted lane is silent
  g.playing = true
  g.laneMute[1] = true
  check pg.play(g).filterIt(it[1].status == 0x90).len == 1 # lane 0's only
  # starting 2 beats in and running 2 bars: the clip repeats at tick 192 and 576
  g.laneMute[1] = false
  g.clips[0].tracks[0].notes = @[Note(start: 0, len: Ppq, pitch: 60, vel: 100)]
  g.placements = @[Placement(clip: 0, start: 0, len: 2 * BarTicks, offset: 2 * Ppq)]
  g.playing = true
  let looped = pg.play(g).filterIt(it[1].status shr 4 == 9).mapIt((it[0], it[1].offset))
  check looped == @[(21, 546), (64, 614)]
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
  check vols == @[0, 32, 64, 95, 127]
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
  check exps == @[127, 95, 63, 32, 0]
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
  check pans == @[0, 32, 64, 95, 127]
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
  check bends.filterIt(it.status == 0xB0 and it.d1 in [100, 101, 6]).mapIt(it.d2) ==
    @[0, 0, BendRange]
  # +3, +6, +9 semitones of 24 = 9216, 10240, 11264; the wheel recentres by the note's end at tick 96
  check bends.filterIt(it.status == 0xE0).mapIt(it.d2 * 128 + it.d1) ==
    @[9216, 10240, 11264, 8192]
  # lock: a locked track takes channel 0 from either row; the unlocked one takes the next free
  for locks in [[0, -1], [-1, 0]]:
    var k = Song(
      bpm: 120,
      playing: true,
      clips: @[
        Clip(tracks: @[Track(lockedchannel: locks[0]), Track(lockedchannel: locks[1])])
      ],
    )
    var pk: Player
    k.nt(0) = @[Note(start: 0, len: Ppq, pitch: 60, vel: 100)]
    k.nt(1) = @[Note(start: 0, len: Ppq, pitch: 62, vel: 100)]
    check pk.advance(k, 1024, 22050).filterIt(it.status shr 4 == 9).mapIt(
      (it.d1, it.status and 15)
    ).sorted == (if locks[0] == 0: @[(60, 0), (62, 1)] else: @[(60, 1), (62, 0)])
  # a locked track shares a channel with an unlocked one that already sounds on it
  var kc = Song(
    bpm: 120,
    playing: true,
    clips: @[Clip(tracks: @[Track(), Track(lockedchannel: 0)])],
  )
  var pkc: Player
  kc.nt(0) = @[Note(start: 0, len: 2 * Ppq, pitch: 60, vel: 100)]
  kc.nt(1) = @[Note(start: Ppq, len: Ppq, pitch: 62, vel: 100)]
  var kcOn: seq[Msg]
  for blk in 0 ..< 12: # past tick 96 = block 10
    kcOn.add pkc.advance(kc, 1024, 22050).filterIt(it.status shr 4 == 9)
  check kcOn.mapIt((it.d1, it.status and 15)) == @[(60, 0), (62, 0)]
  # a drum track ignores its lock: its simultaneous hits stay on one drum channel
  var kr = Song(
    bpm: 120,
    playing: true,
    clips: @[Clip(tracks: @[Track(rhythm: true, lockedchannel: 3), Track(rhythm: true)])],
  )
  var pkr: Player
  for t in 0 .. 1:
    kr.nt(t) =
      @[
        Note(start: 0, len: Ppq, pitch: 36, vel: 100),
        Note(start: 0, len: Ppq, pitch: 38, vel: 100),
      ]
  check pkr.advance(kr, 1024, 22050).filterIt(it.status shr 4 == 9).mapIt(
    it.status and 15
  ) == @[9, 9, 15, 15]
  # deleting a track whose note sounds releases it
  var kd = Song(
    bpm: 120,
    playing: true,
    clips: @[Clip(tracks: @[Track(lockedchannel: 2), Track()])],
  )
  var pkd: Player
  kd.nt(0) = @[Note(start: 0, len: BarTicks, pitch: 60, vel: 100)]
  kd.nt(1) = @[Note(start: 0, len: BarTicks, pitch: 64, vel: 100)]
  discard pkd.advance(kd, 1024, 22050)
  kd.clips[0].tracks.delete 1
  check pkd.advance(kd, 1024, 22050) == @[(0, 0x80, 64, 0).Msg]
