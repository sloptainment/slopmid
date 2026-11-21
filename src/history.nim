## Undo and redo: each idle frame, an edit since the last commit becomes an undo step.
import imgui
import model, common

type Snapshot = object ## what undo restores; selection and mute/solo cleared, so they don't count as edits
  clips: seq[Clip]
  placements: seq[Placement]

var
  undoStack, redoStack: seq[Snapshot]

proc `==`*(a, b: Snapshot): bool =
  a.clips == b.clips and a.placements == b.placements

proc capture*(): Snapshot =
  # ponytail: copies the whole song every idle frame; diff or dirty flag if big songs lag
  result = Snapshot(clips: song.clips, placements: song.placements)
  for c in result.clips.mitems:
    for t in c.tracks.mitems:
      t.mute = false
      t.solo = false
      for n in t.notes.mitems:
        n.sel = false
        for p in n.bend.mitems:
          p.sel = false
      for cc in t.cc.mitems:
        for p in cc.mitems:
          p.sel = false
  for p in result.placements.mitems:
    p.sel = false

var committed = capture() # the state at the last commit

proc restore(s: Snapshot) =
  let old = song.clips[song.clip].tracks
  song.clips = s.clips
  song.placements = s.placements
  song.clip = min(song.clip, song.clips.high)
  for i in 0 ..< min(old.len, song.clips[song.clip].tracks.len): # mute/solo aren't undone
    song.clips[song.clip].tracks[i].mute = old[i].mute
    song.clips[song.clip].tracks[i].solo = old[i].solo
  if focusTrack >= song.clips[song.clip].tracks.len:
    focusTrack = -1
  clicked = -1
  placeClip.setLen 0 # its clip numbers may be stale

proc resetHistory*() =
  ## A fresh history, starting from the song as it is.
  undoStack.setLen 0
  redoStack.setLen 0
  committed = capture()

proc history*() =
  ## Once no mouse button or text field is busy: an edit since the last commit becomes an undo step; then handle undo/redo.
  let io = igGetIO()
  if igIsMouseDown(ImGuiMouseButton.Left) or igIsMouseDown(ImGuiMouseButton.Right) or io.wantTextInput:
    return
  let now = capture()
  if now != committed:
    undoStack.add committed
    redoStack.setLen 0
    committed = now
  let z = io.keyCtrl and igIsKeyPressed(ImGuiKey.Z, false)
  let redo = menuCmd == Redo or (io.keyCtrl and igIsKeyPressed(ImGuiKey.Y, false)) or (z and io.keyShift)
  let undo = menuCmd == Undo or (z and not io.keyShift)
  if redo and redoStack.len > 0:
    undoStack.add committed
    committed = redoStack.pop
    restore committed
  elif undo and undoStack.len > 0:
    redoStack.add committed
    committed = undoStack.pop
    restore committed
