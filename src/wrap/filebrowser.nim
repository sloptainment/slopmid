## imgui-filebrowser, a header-only C++ widget, behind two calls (see filebrowser.h).
import std/os

const deps = currentSourcePath.parentDir / ".." / ".." / "deps"
{.passC: "-I" & deps / "imgui-filebrowser" & " -I" & currentSourcePath.parentDir & " -I" & deps / "imgui/src/imgui/private/cimgui/imgui".}

proc fbOpen*(save: bool) {.importc, header: "filebrowser.h".}
proc fbPick*(save: bool): cstring {.importc, header: "filebrowser.h".}
  ## Draws the browser; the picked path once, else nil.
