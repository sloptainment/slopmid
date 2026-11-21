## The slopgs engine (deps/slopgs/src/engine), compiled in as C. It takes
## raw MIDI and renders interleaved stereo int16 at `Rate`, `BlockFrames` at a
## time. Not thread-safe: the caller serializes every call.
import std/os

const engine = currentSourcePath.parentDir / ".." / ".." / "deps/slopgs/src/engine"
{.passC: "-I" & engine.}
{.compile(engine / "dls.c", "-x c -std=c11").}
{.compile(engine / "render.c", "-x c -std=c11").}
{.compile(engine / "rt.c", "-x c -std=c11").}
{.compile(engine / "smf.c", "-x c -std=c11").}
{.compile(engine / "synth.c", "-x c -std=c11").}
{.compile(engine / "tables.c", "-x c -std=c11").}
{.compile(engine / "voice.c", "-x c -std=c11").}

const
  Rate* = 22050 ## voice.h RENDER_RATE (RESAMPLE_FACTOR 1)
  BlockFrames* = 1024 ## voice.h SERVICE_BLOCK_FRAMES, the driver's Mix call

type Block* = array[BlockFrames * 2, int16]

proc tables_build() {.importc, cdecl.}
proc dls_load(data: pointer, len: uint32): cint {.importc, cdecl.}
proc synth_construct() {.importc, cdecl.}
proc synth_midi(status, d1, d2: uint32) {.importc, cdecl.}
proc voice_set_event_offset(frames: uint32) {.importc, cdecl.}
proc render_frames(output: ptr int16, frames: uint32) {.importc, cdecl.}

# rt.h: the host supplies the allocator. Never freed, like alsa-synth.c's.
var allocated: uint32
proc rt_alloc(n: uint32): pointer {.exportc, cdecl.} =
  allocated += n
  allocShared0(max(n, 8))

proc rt_mem_size(): uint32 {.exportc, cdecl.} =
  allocated

# gm.dls is parsed in place, so it lives as long as the engine does.
var dls: string

proc init*(dlsPath: string) =
  dls = readFile(dlsPath)
  tables_build()
  if dls_load(dls[0].addr, dls.len.uint32) != 0:
    raise newException(IOError, dlsPath & " is not a usable gm.dls")
  synth_construct()

proc midi*(offset, status, d1, d2: int) =
  ## A short message, acting `offset` frames into the next `render`.
  voice_set_event_offset(offset.uint32)
  synth_midi(status.uint32, d1.uint32, d2.uint32)
  voice_set_event_offset(0)

proc render*(buf: var Block) =
  render_frames(buf[0].addr, BlockFrames)
