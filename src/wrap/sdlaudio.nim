## Blocking playback of interleaved stereo int16 through SDL2's audio queue.
## SDL's flags come from config.nims.

type
  Pcm* = object
    dev: uint32 # SDL_AudioDeviceID
    maxQueued: uint32 # bytes `write` lets wait in SDL's queue

  AudioSpec = object # SDL_AudioSpec, field for field
    freq: cint
    format: uint16
    channels, silence: uint8
    samples, padding: uint16
    size: uint32
    callback, userdata: pointer

proc SDL_InitSubSystem(flags: uint32): cint {.importc, cdecl.}
proc SDL_GetError(): cstring {.importc, cdecl.}
proc SDL_OpenAudioDevice(
  name: cstring, capture: cint, desired, obtained: ptr AudioSpec, allowedChanges: cint
): uint32 {.importc, cdecl.}

proc SDL_PauseAudioDevice(dev: uint32, pause: cint) {.importc, cdecl.}
proc SDL_QueueAudio(dev: uint32, data: pointer, len: uint32): cint {.importc, cdecl.}
proc SDL_GetQueuedAudioSize(dev: uint32): uint32 {.importc, cdecl.}
proc SDL_Delay(ms: uint32) {.importc, cdecl.}

const
  InitAudio = 0x10'u32
  FormatS16Sys = 0x8010'u16 # AUDIO_S16SYS

proc check(what: string, err: cint) =
  if err < 0:
    raise newException(IOError, what & ": " & $SDL_GetError())

proc open*(rate, latencyUs: int): Pcm =
  check "SDL_InitSubSystem", SDL_InitSubSystem(InitAudio)
  var want, have: AudioSpec
  want.freq = rate.cint
  want.format = FormatS16Sys
  want.channels = 2
  want.samples = 1024
  # allowedChanges 0: SDL converts to the device's own format and rate
  result.dev = SDL_OpenAudioDevice(nil, 0, want.addr, have.addr, 0)
  check "SDL_OpenAudioDevice", (if result.dev == 0: -1.cint else: 0.cint)
  result.maxQueued = uint32(rate * 4 * latencyUs div 1_000_000) # 4 bytes a frame
  SDL_PauseAudioDevice(result.dev, 0)

proc write*(pcm: Pcm, frames: openArray[int16]) =
  ## Blocks until little enough is queued: this is the audio clock.
  # ponytail: polls every ms; a callback and a ring buffer would wake exactly
  while SDL_GetQueuedAudioSize(pcm.dev) > pcm.maxQueued:
    SDL_Delay(1)
  check "SDL_QueueAudio",
    SDL_QueueAudio(pcm.dev, frames[0].unsafeAddr, uint32(frames.len * 2))
