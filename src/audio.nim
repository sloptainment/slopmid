## The audio thread: renders the song and the key previews and mixes in the metronome.
## `lock` guards `song` (in `common`) and the queue of previews; the UI runs under it.
import std/[atomics, locks, math]
import wrap/[alsa, slopgs]
import model, player, common

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
  dlsFile: string
  wavThread: Thread[(Song, string)]
  wavRunning: Atomic[bool]
  wavDone, wavTotal: Atomic[int] # frames rendered of all to render; total 0 until known
  wavErr: string # set before `wavRunning` goes false

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
  dlsFile = dlsPath
  synth = slopgs.open(dlsPath)
  previewSynth = slopgs.open(dlsPath)
  pcm = alsa.open(Rate, LatencyUs)
  initLock(lock)
  createThread(audioThread, audioLoop)

proc preview*(status, d1, d2: int) =
  ## Queues a MIDI message for the preview synth, played at the next block's top. Call under `lock`.
  previews.add (status, d1, d2)

proc renderWav(song: Song): string =
  ## The song as a 16-bit stereo WAV at `Rate`, rendered by slopgs faster than it plays: song mode's
  ## arrangement or one pass of the clip, no metronome, then 2 s for the releases to die away.
  var s = song
  s.metronome = false
  s.pos = 0
  let frames = round(
    (if s.songMode: s.songEnd else: s.clips[s.clip].loopEnd).float * Rate / (s.bpm / 60 * Ppq)
  ).int
  let synth = slopgs.open(dlsFile) # a fresh one, so nothing of the live song carries over
  defer: slopgs.close(synth)
  wavTotal.store frames + 2 * Rate
  var pl: Player
  var blk: Block
  var data: seq[int16]
  var done = 0 # frames rendered; the last playing block is cut to end at `frames` exactly
  while done < frames + 2 * Rate:
    s.playing = done < frames
    let msgs = pl.advance(s, if s.playing: min(BlockFrames, frames - done) else: BlockFrames, Rate)
    for r in pl.rhythm:
      slopgs.sysex(synth, rhythmSysex(r.part, r.on))
    for m in msgs:
      slopgs.midi(synth, m.offset, m.status, m.d1, m.d2)
    slopgs.render(synth, blk)
    data.add blk
    done += BlockFrames
    wavDone.store done
  proc le(n, bytes: int): string =
    for i in 0 ..< bytes:
      result.add char((n shr (8 * i)) and 255)
  let size = data.len * 2
  result = "RIFF" & le(36 + size, 4) & "WAVEfmt " & le(16, 4) & le(1, 2) & le(2, 2) & le(Rate, 4) &
    le(Rate * 4, 4) & le(4, 2) & le(16, 2) & "data" & le(size, 4)
  result.setLen 44 + size
  copyMem(result[44].addr, data[0].addr, size) # little-endian host

proc wavWorker(job: (Song, string)) {.thread.} =
  {.cast(gcsafe).}:
    wavErr = ""
    try:
      writeFile(job[1], renderWav(job[0]))
    except CatchableError as e:
      wavErr = e.msg
    wavRunning.store false

proc exportWav*(song: Song, path: string) =
  ## Renders `song` (a copy) to the WAV at `path` on a thread of its own; watch `wavProgress`, `wavBusy`.
  wavDone.store 0
  wavTotal.store 0
  wavRunning.store true
  createThread(wavThread, wavWorker, (song, path))

proc wavBusy*(): bool =
  wavRunning.load

proc wavProgress*(): float32 =
  let t = wavTotal.load
  if t == 0: 0 else: min(1, wavDone.load / t)

proc wavFinish*(): string =
  ## Once not `wavBusy`: joins the thread; the error, "" if it wrote the file.
  joinThread(wavThread)
  wavErr
