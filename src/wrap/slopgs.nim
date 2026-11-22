## The slopgs engine (deps/slopgs/src/engine), compiled in as C. It takes
## raw MIDI and renders interleaved stereo int16 at `Rate`, `BlockFrames` at a
## time. Each `Synth` is an independent instance, so each has all 16 channels;
## not thread-safe per instance: the caller serializes every call on one.
import std/strutils

const here = currentSourcePath.replace("\\", "/").rsplit('/', 1)[0]
  # `/` even for a Windows target on a Linux host
const engine = here & "/../../deps/slopgs/src/engine"
{.passC: "-I" & engine.}
{.compile(engine & "/dls.c", "-x c -std=c11").}
{.compile(engine & "/msgs.c", "-x c -std=c11").}
{.compile(engine & "/render.c", "-x c -std=c11").}
{.compile(engine & "/rt.c", "-x c -std=c11").}
{.compile(engine & "/smf.c", "-x c -std=c11").}
{.compile(engine & "/synth.c", "-x c -std=c11").}
{.compile(engine & "/tables.c", "-x c -std=c11").}
{.compile(engine & "/voice.c", "-x c -std=c11").}

const
  Rate* = 22050 ## voice.h RENDER_RATE (RESAMPLE_FACTOR 1)
  BlockFrames* = 1024 ## voice.h SERVICE_BLOCK_FRAMES, the driver's Mix call

type
  Block* = array[BlockFrames * 2, int16]
  Synth* = distinct pointer ## a `Msgs *`

proc msgs_size(maxSmfLen: uint32): uint32 {.importc, cdecl.}
proc msgs_create(mem: pointer, len: uint32): Synth {.importc, cdecl.}
proc msgs_init(e: Synth, dls: pointer, len: uint32): int32 {.importc, cdecl.}
proc synth_midi(e: Synth, status, d1, d2: uint32) {.importc, cdecl.}
proc voice_set_event_offset(e: Synth, frames: uint32) {.importc, cdecl.}
proc synth_sysex(e: Synth, buf: ptr uint8, len: uint32) {.importc, cdecl.}
proc render_frames(e: Synth, output: ptr int16, frames: uint32) {.importc, cdecl.}

# gm.dls is embedded in the binary: `-d:dlsPath=<file>` picks another. It is parsed in place,
# so it lives as long as the engines do; all share it.
const dlsPath {.strdefine.} = here & "/../../deps/slopgs/dist/gm.dls"
const dlsData = staticRead(dlsPath)
let dls = dlsData # a `let` so the engine has an address to parse in place

proc open*(): Synth =
  ## A new engine on the embedded gm.dls, GS-reset (it ignores bank select, CC0/CC32,
  ## until that has run). Free it with `close`; the song's and preview's never are.
  let n = msgs_size(0)
  result = msgs_create(allocShared0(n), n)
  if msgs_init(result, dls[0].unsafeAddr, dls.len.uint32) != 0:
    raise newException(IOError, "the embedded " & dlsPath & " is not a usable gm.dls")
  var msg = [0x41'u8, 0x10, 0x42, 0x12, 0x40, 0x00, 0x7F, 0x00, 0x41, 0xF7]
  synth_sysex(result, msg[0].addr, msg.len.uint32) # after the F0

proc close*(s: Synth) =
  ## Frees `s`: the engine keeps everything in the one block `open` allocated, nothing elsewhere.
  deallocShared(s.pointer)

proc midi*(s: Synth, offset, status, d1, d2: int) =
  ## A short message, acting `offset` frames into the next `render`.
  voice_set_event_offset(s, offset.uint32)
  synth_midi(s, status.uint32, d1.uint32, d2.uint32)
  voice_set_event_offset(s, 0)

proc sysex*(s: Synth, msg: string) =
  ## A SysEx, `msg` the bytes after F0 up to and including F7.
  synth_sysex(s, cast[ptr uint8](msg[0].unsafeAddr), msg.len.uint32)

proc render*(s: Synth, buf: var Block) =
  render_frames(s, buf[0].addr, BlockFrames)
