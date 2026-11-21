## The window and Dear ImGui's plumbing: nimgl's vendored GLFW, imgui via
## cimgui (nimgl/imgui), its OpenGL3 renderer. Callers draw between
## `beginFrame` and `endFrame` with the plain `imgui` API.
import std/os
import imgui, imgui/impl_opengl
import nimgl/[glfw, opengl]

# imgui/impl_glfw.nim links the system's libglfw; build its backend against
# nimgl's vendored GLFW instead. impl_opengl's passC supplies the imgui
# include dirs and IMGUI_IMPL_API="extern \"C\"".
const deps = currentSourcePath.parentDir / ".." / ".." / "deps"
{.passC: "-I" & deps / "nimgl/src/nimgl/private/glfw/include".}
{.
  compile(
    deps / "imgui/src/imgui/private/cimgui/imgui/backends/imgui_impl_glfw.cpp",
    "-include " & currentSourcePath.parentDir / "glfw_compat.h",
  )
.}
proc ImGui_ImplGlfw_InitForOpenGL(
  window: GLFWWindow, installCallbacks: bool
): bool {.importc, cdecl.}

proc ImGui_ImplGlfw_NewFrame() {.importc, cdecl.}

type Flags = ImGuiWindowFlags | ImGuiButtonFlags | ImGuiConfigFlags
proc `or`*[T: Flags](a, b: T): T =
  cast[T](a.int32 or b.int32)

var window: GLFWWindow

proc open*(title: string, w, h: int) =
  doAssert glfwInit()
  glfwWindowHint(GLFWContextVersionMajor, 3)
  glfwWindowHint(GLFWContextVersionMinor, 3)
  glfwWindowHint(GLFWOpenglForwardCompat, GLFWTrue)
  glfwWindowHint(GLFWOpenglProfile, GLFWOpenglCoreProfile)
  window = glfwCreateWindow(w.int32, h.int32, title)
  doAssert window != nil
  window.makeContextCurrent()
  glfwSwapInterval(1)
  doAssert glInit()
  discard igCreateContext()
  # everything here is transient, the layout included
  igGetIO().iniFilename = nil
  igGetIO().configFlags = igGetIO().configFlags or ImGuiConfigFlags.DockingEnable
  igStyleColorsDark()
  doAssert ImGui_ImplGlfw_InitForOpenGL(window, true)
  doAssert igOpenGL3Init("#version 330")

proc running*(): bool =
  not window.windowShouldClose

proc setTitle*(title: string) =
  window.setWindowTitle(cstring(title))

proc requestClose*() =
  window.setWindowShouldClose(true)

proc beginFrame*() =
  glfwPollEvents()
  igOpenGL3NewFrame()
  ImGui_ImplGlfw_NewFrame()
  igNewFrame()

proc endFrame*() =
  igRender()
  var w, h: int32
  window.getFramebufferSize(w.addr, h.addr)
  glViewport(0, 0, w, h)
  glClearColor(0.1, 0.1, 0.1, 1)
  glClear(GL_COLOR_BUFFER_BIT)
  discard igOpenGL3RenderDrawData(igGetDrawData())
  window.swapBuffers()
