## Blocking ALSA playback of interleaved stereo int16 (system libasound).
{.passL: "-lasound".}

type Pcm* = distinct pointer

proc snd_pcm_open(
  pcm: ptr Pcm, name: cstring, stream, mode: cint
): cint {.importc, cdecl.}

proc snd_pcm_set_params(
  pcm: Pcm,
  format, access: cint,
  channels, rate: cuint,
  softResample: cint,
  latencyUs: cuint,
): cint {.importc, cdecl.}

proc snd_pcm_writei(pcm: Pcm, buf: pointer, frames: culong): clong {.importc, cdecl.}
proc snd_pcm_recover(pcm: Pcm, err, silent: cint): cint {.importc, cdecl.}
proc snd_strerror(err: cint): cstring {.importc, cdecl.}

const
  StreamPlayback = 0 # SND_PCM_STREAM_PLAYBACK
  FormatS16LE = 2 # SND_PCM_FORMAT_S16_LE
  AccessRwInterleaved = 3 # SND_PCM_ACCESS_RW_INTERLEAVED

proc check(what: string, err: cint) =
  if err < 0:
    raise newException(IOError, what & ": " & $snd_strerror(err))

proc open*(rate, latencyUs: int, device = "default"): Pcm =
  check "snd_pcm_open", snd_pcm_open(result.addr, device, StreamPlayback, 0)
  # soft_resample: the engine's rate is not the device's
  check "snd_pcm_set_params",
    snd_pcm_set_params(
      result, FormatS16LE, AccessRwInterleaved, 2, rate.cuint, 1, latencyUs.cuint
    )

proc write*(pcm: Pcm, frames: openArray[int16]) =
  ## Blocks until the device has room: this is the audio clock.
  let n = snd_pcm_writei(pcm, frames[0].addr, culong(frames.len div 2))
  if n < 0:
    check "snd_pcm_writei", snd_pcm_recover(pcm, n.cint, 1)
