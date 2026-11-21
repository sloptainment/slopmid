## The window and Dear ImGui's plumbing: SDL2 and its renderer (software or
## GPU, SDL's choice), imgui via cimgui (nimgl/imgui). Callers draw between
## `beginFrame` and `endFrame` with the plain `imgui` API.
import std/strutils
import imgui

# imgui's SDL2 and SDL_Renderer backends are built here; the imgui package has no
# binding for them. imgui.nim's passC supplies the cimgui include dir, config.nims SDL's.
const here = currentSourcePath.replace("\\", "/").rsplit('/', 1)[0] # `/` even for a Windows target on a Linux host
const be = here & "/../../deps/imgui/src/imgui/private/cimgui/imgui/backends"
{.passC: "-I" & be & """ -DIMGUI_IMPL_API="extern \"C\" " """.}
{.compile: be & "/imgui_impl_sdl2.cpp".}
{.compile: be & "/imgui_impl_sdlrenderer2.cpp".}

proc SDL_Init(flags: uint32): cint {.importc, cdecl.}
proc SDL_CreateWindow(
  title: cstring, x, y, w, h: cint, flags: uint32
): pointer {.importc, cdecl.}

proc SDL_CreateRenderer(
  window: pointer, index: cint, flags: uint32
): pointer {.importc, cdecl.}

proc SDL_SetWindowTitle(window: pointer, title: cstring) {.importc, cdecl.}
proc SDL_PollEvent(event: pointer): cint {.importc, cdecl.}
proc SDL_SetRenderDrawColor(r: pointer, red, g, b, a: uint8): cint {.importc, cdecl.}
proc SDL_RenderClear(r: pointer): cint {.importc, cdecl.}
proc SDL_RenderPresent(r: pointer) {.importc, cdecl.}
proc ImGui_ImplSDL2_InitForSDLRenderer(
  window, renderer: pointer
): bool {.importc, cdecl.}

proc ImGui_ImplSDL2_ProcessEvent(event: pointer): bool {.importc, cdecl, discardable.}
proc ImGui_ImplSDL2_NewFrame() {.importc, cdecl.}
proc ImGui_ImplSDLRenderer2_Init(renderer: pointer): bool {.importc, cdecl.}
proc ImGui_ImplSDLRenderer2_NewFrame() {.importc, cdecl.}
proc ImGui_ImplSDLRenderer2_RenderDrawData(
  data, renderer: pointer
) {.importc, cdecl.}

const
  SdlInitVideo = 0x20'u32
  SdlWindowResizable = 0x20'u32
  SdlWindowposCentered = 0x2FFF0000
  SdlRendererPresentVsync = 4'u32 # SDL picks the GPU or software renderer
  SdlQuit = 0x100'u32

type Flags = ImGuiWindowFlags | ImGuiButtonFlags | ImGuiConfigFlags
proc `or`*[T: Flags](a, b: T): T =
  cast[T](a.int32 or b.int32)

var
  window, renderer: pointer
  closing: bool

proc open*(title: string, w, h: int) =
  doAssert SDL_Init(SdlInitVideo) == 0
  window = SDL_CreateWindow(
    title, SdlWindowposCentered, SdlWindowposCentered, w.cint, h.cint, SdlWindowResizable
  )
  doAssert window != nil
  renderer = SDL_CreateRenderer(window, -1, SdlRendererPresentVsync)
  doAssert renderer != nil
  discard igCreateContext()
  # everything here is transient, the layout included
  igGetIO().iniFilename = nil
  igGetIO().configFlags = igGetIO().configFlags or ImGuiConfigFlags.DockingEnable
  igStyleColorsDark()
  doAssert ImGui_ImplSDL2_InitForSDLRenderer(window, renderer)
  doAssert ImGui_ImplSDLRenderer2_Init(renderer)

proc running*(): bool =
  not closing

proc setTitle*(title: string) =
  SDL_SetWindowTitle(window, cstring(title))

proc requestClose*() =
  closing = true

proc beginFrame*() =
  var event: array[7, uint64] # SDL_Event is a 56-byte union, its type the first uint32
  while SDL_PollEvent(event.addr) != 0:
    ImGui_ImplSDL2_ProcessEvent(event.addr)
    if cast[ptr uint32](event.addr)[] == SdlQuit:
      closing = true
  ImGui_ImplSDLRenderer2_NewFrame()
  ImGui_ImplSDL2_NewFrame()
  igNewFrame()

proc endFrame*() =
  igRender()
  discard SDL_SetRenderDrawColor(renderer, 26, 26, 26, 255)
  discard SDL_RenderClear(renderer)
  ImGui_ImplSDLRenderer2_RenderDrawData(igGetDrawData(), renderer)
  SDL_RenderPresent(renderer)
