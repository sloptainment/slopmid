import std/[locks, os, strformat]
import imgui
import wrap/gui
import model, common, audio, history, files, pianoroll, clipswin, songwin

proc transport() =
  let io = igGetIO()
  if igButton(if song.playing: "Pause" else: "Play", v2(60, 0)) or
      (igIsKeyPressed(ImGuiKey.Space, false) and not io.wantTextInput):
    song.playing = (song.songMode or song.clips[song.clip].tracks.len > 0) and not song.playing
  igSameLine()
  if igButton("Stop", v2(60, 0)) and (song.songMode or song.clips[song.clip].tracks.len > 0):
    song.playing = false
    song.pos = 0
  igSameLine()
  igPushStyleColor(
    ImGuiCol.Button, if song.metronome: rgb(66, 150, 250) else: rgb(60, 60, 64)
  )
  if igButton("Metronome"):
    song.metronome = not song.metronome
  igPopStyleColor()
  igSameLine()
  igSetNextItemWidth(110)
  var bpm = song.bpm.float32
  if igInputFloat("BPM", bpm.addr, 1, 10, "%.1f"):
    song.bpm = clamp(bpm, 20, 999)
  igSameLine()
  igSetNextItemWidth(70)
  if igBeginCombo("Snap", cstring(Snaps[snapIdx][0])):
    for i, (name, _, _) in Snaps:
      if igSelectable(cstring(name), i == snapIdx):
        snapIdx = i
    igEndCombo()
  igSameLine(0, 24)
  let t = song.pos.int
  igText(
    "%s", cstring(&"{t div BarTicks + 1}:{t mod BarTicks div Ppq + 1}:{t mod Ppq:02}")
  )
  igSameLine()
  for (name, mode) in [("Song", true), ("Clip", false)]:
    if igRadioButton(cstring(name), song.songMode == mode) and song.songMode != mode:
      song.songMode = mode
      song.playing = false
    igSameLine()

var
  showPianoRoll = true
  showClips = true
  showSong = true
  firstFrame = true

proc ui() =
  let io = igGetIO()
  # File shortcuts work with the menu closed, but not under a popup or in a text field
  let free = not io.wantTextInput and not igIsPopupOpen("", cast[ImGuiPopupFlags](ord(ImGuiPopupFlags.AnyPopupId) or ord(ImGuiPopupFlags.AnyPopupLevel)))
  proc hot(k: ImGuiKey, shift = false): bool =
    free and io.keyCtrl and io.keyShift == shift and igIsKeyPressed(k, false)
  var (hNew, hOpen, hSave, hSaveAs, hExport) =
    (hot(ImGuiKey.N), hot(ImGuiKey.O), hot(ImGuiKey.S), hot(ImGuiKey.S, true), hot(ImGuiKey.E))
  if igBeginMainMenuBar():
    if igBeginMenu("File"):
      hNew = igMenuItem("New", "Ctrl+N") or hNew
      hOpen = igMenuItem("Open...", "Ctrl+O") or hOpen
      hSave = igMenuItem("Save", "Ctrl+S") or hSave
      hSaveAs = igMenuItem("Save as...", "Ctrl+Shift+S") or hSaveAs
      hExport = igMenuItem("Export...", "Ctrl+E") or hExport
      igSeparator()
      if igMenuItem("Exit"):
        confirm ExitApp
      igEndMenu()
    if igBeginMenu("Edit"): # acts on the piano roll or song window, whichever you used last
      for (c, name, keys) in [
        (Undo, "Undo", "Ctrl+Z"),
        (Redo, "Redo", "Ctrl+Shift+Z"),
        (SelectAll, "Select all / none", "Ctrl+A"),
        (Duplicate, "Duplicate", "Ctrl+D"),
        (Copy, "Copy", "Ctrl+C"),
        (Cut, "Cut", "Ctrl+X"),
        (Paste, "Paste", "Ctrl+V"),
        (Quantize, "Quantize", "Ctrl+Q"),
        (Delete, "Delete", "Delete"),
        (SemiUp, "Transpose up", "Shift+Up"),
        (SemiDown, "Transpose down", "Shift+Down"),
        (OctUp, "Octave up", "Ctrl+Up"),
        (OctDown, "Octave down", "Ctrl+Down"),
      ]:
        if igMenuItem(name, keys):
          menuCmd = c
      igEndMenu()
    if igBeginMenu("Window"):
      if igCheckbox("Piano roll", addr showPianoRoll):
        discard
      if igCheckbox("Clips", addr showClips):
        discard
      if igCheckbox("Song", addr showSong):
        discard
      igEndMenu()
    igEndMainMenuBar()
  fileCommands(hNew, hOpen, hSave, hSaveAs, hExport)
  # a bar under the menu: the work area shrinks, so no window can cover it
  if igBeginViewportSideBar(
    "transport",
    nil,
    ImGuiDir.Up,
    igGetFrameHeight() + 2 * igGetStyle().windowPadding.y,
    ImGuiWindowFlags.NoScrollbar or ImGuiWindowFlags.NoSavedSettings,
  ):
    transport()
  igEnd()
  # after the bars, so the dockspace fills what they leave
  let space = igDockSpaceOverViewport()
  if firstFrame: # default layout
    var left, right, lowerLeft: ImGuiID
    discard igDockBuilderSplitNode(space, ImGuiDir.Left, 0.5, addr left, addr right)
    igDockBuilderDockWindow("Clips", left)
    igDockBuilderDockWindow("Piano roll", right)
    discard igDockBuilderSplitNode(left, ImGuiDir.Down, 0.5, addr lowerLeft, nil)
    igDockBuilderDockWindow("Song", lowerLeft)
    firstFrame = false
  if showPianoRoll:
    if igBegin("Piano roll"):
      igBeginDisabled(focusTrack < 0)
      pianoRollWindow()
      igEndDisabled()
    igEnd()
  if showClips:
    if igBegin("Clips"):
      clipsWindow()
    igEnd()
  if showSong:
    # the lane widgets overhang the pane at the edges; scrolling is ours
    if igBegin("Song", nil, ImGuiWindowFlags.NoScrollbar or ImGuiWindowFlags.NoScrollWithMouse):
      songWindow()
    igEnd()
  fileDialogs()
  history()
  menuCmd = None

proc main() =
  let dlsPath =
    if paramCount() >= 1:
      paramStr(1)
    else:
      getAppDir() / "deps/slopgs/dist/gm.dls"
  audio.start(dlsPath)
  gui.open("slopmid", 1280, 800)
  while gui.running():
    gui.beginFrame()
    withLock lock:
      ui()
    gui.endFrame()

main()
