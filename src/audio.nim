## The audio thread: renders the song and the key previews and mixes in the metronome.
## `lock` guards `song` (in `common`) and the queue of previews; the UI runs under it.
import std/[locks, math]
import wrap/[alsa, slopgs]
import player, common

const
  ClickHz = 1000.0
  ClickDownHz = 1500.0 # the first beat of a bar
  ClickLen = 1000 # samples
  ClickAmp = 8000.0 # of 32767
  # a block and a half, as in slopgs's alsa-synth.c
  LatencyUs = 3 * 1_000_000 * BlockFrames div Rate div 2

var
  lock*: Lock
  playback: Player
  previews: seq[(int, int, int)] # key previews, played at the next block's top
  pcm: Pcm
  synth, previewSynth: Synth # separate engines: the song keeps all 16 channels
  audioThread: Thread[void]

proc audioLoop() {.thread.} =
  var buf, pbuf: Block
  var clicks: seq[tuple[offset: int, downbeat: bool]]
  var hz = ClickHz
  var click = ClickLen # samples of the current click played; ClickLen = silent
  while true:
    {.cast(gcsafe).}:
      withLock(lock):
        for (status, d1, d2) in previews:
          slopgs.midi(previewSynth, 0, status, d1, d2)
        previews.setLen(0)
        let msgs = playback.advance(song, BlockFrames, Rate)
        for r in playback.rhythm:
          slopgs.sysex(synth, rhythmSysex(r.part, r.on))
        for m in msgs:
          slopgs.midi(synth, m.offset, m.status, m.d1, m.d2)
        slopgs.render(synth, buf)
        slopgs.render(previewSynth, pbuf)
        clicks = playback.clicks
      for f in 0 ..< BlockFrames:
        for (at, down) in clicks:
          if at == f:
            click = 0
            hz = if down: ClickDownHz else: ClickHz
        var c = 0
        if click < ClickLen: # a sine that fades out, so it ends without a pop
          c = int(sin(2 * PI * hz * click.float / Rate) * (1 - click / ClickLen) * ClickAmp)
          inc click
        for i in [2 * f, 2 * f + 1]:
          buf[i] = clamp(buf[i].int + pbuf[i].int + c, int16.low.int, int16.high.int).int16
      pcm.write(buf)

proc start*(dlsPath: string) =
  synth = slopgs.open(dlsPath)
  previewSynth = slopgs.open(dlsPath)
  pcm = alsa.open(Rate, LatencyUs)
  initLock(lock)
  createThread(audioThread, audioLoop)

proc preview*(status, d1, d2: int) =
  ## Queues a MIDI message for the preview synth, played at the next block's top. Call under `lock`.
  previews.add (status, d1, d2)
