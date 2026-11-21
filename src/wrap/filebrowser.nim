## imgui-filebrowser, a header-only C++ widget, behind two calls; `i`: 0 open, 1 save, 2 export (see filebrowser.h).
import std/os

const deps = currentSourcePath.parentDir / ".." / ".." / "deps"
{.passC: "-I" & deps / "imgui-filebrowser" & " -I" & currentSourcePath.parentDir & " -I" & deps / "imgui/src/imgui/private/cimgui/imgui".}

proc fbOpen*(i: int) {.importc, header: "filebrowser.h".}
proc fbPick*(i: int): cstring {.importc, header: "filebrowser.h".}
  ## Draws the browser; the picked path once, else nil.
