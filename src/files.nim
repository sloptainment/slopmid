## Files: New, Open, Save, Save as, Export and Export WAV, and the prompts about unsaved changes.
import std/strutils
import imgui
import wrap/[filebrowser, gui]
import model, smf, audio, smm, common, history

type Pending* = enum ## what to do once unsaved changes are dealt with
  Nothing
  NewSong
  OpenSong
  ExitApp

const
  OpenDlg = 0
  SaveDlg = 1
  ExportDlg = 2
  WavDlg = 3

var
  smmPath: string # "" = never saved
  saved = capture() # the state at the last save, load or new
  savedBpm = song.bpm
  pending: Pending
  openPrompt, openErr, wavPrompt: bool # popups are opened at the top level, not from inside a menu
  fileErr: string

proc markSaved() =
  saved = capture()
  savedBpm = song.bpm

proc dirty(): bool =
  capture() != saved or song.bpm != savedBpm

proc apply(s: Song) =
  ## `s` becomes the song, with a fresh undo history.
  song.clips = s.clips
  song.placements = s.placements
  song.bpm = s.bpm
  song.clip = 0
  song.playing = false
  song.clipPos = 0
  song.songPos = 0
  placeClip.setLen 0
  clicked = -1
  focusTrack = -1 # the old index may not exist in `s`; focus() reads focused()
  focus(0, -1)
  resetHistory()
  markSaved()

proc showError(e: ref CatchableError) =
  fileErr = e.msg
  openErr = true

proc load(path: string) =
  try:
    apply fromSmm(readFile(path))
    smmPath = path
  except CatchableError as e:
    showError e

proc save(path: string): bool =
  try:
    writeFile(path, toSmm(song))
    smmPath = path
    markSaved()
    result = true
  except CatchableError as e:
    showError e

proc runPending() =
  let a = pending
  pending = Nothing
  case a
  of NewSong:
    apply Song(bpm: 120, clips: @[Clip()])
    smmPath = ""
  of OpenSong:
    fbOpen(OpenDlg)
  of ExitApp:
    gui.requestClose()
  of Nothing:
    discard

proc confirm*(a: Pending) =
  ## Do `a`, after asking about unsaved changes.
  pending = a
  if dirty():
    openPrompt = true
  else:
    runPending()

proc fileDialogs*() =
  ## Top level, every frame: the popups and the file browsers.
  if openPrompt:
    igOpenPopup("Save changes?")
    openPrompt = false
  if openErr:
    igOpenPopup("File error")
    openErr = false
  if wavPrompt:
    igOpenPopup("Exporting WAV")
    wavPrompt = false
  if igBeginPopupModal("Exporting WAV", nil, ImGuiWindowFlags.AlwaysAutoResize):
    igProgressBar(wavProgress(), v2(300, 0))
    if not wavBusy():
      igCloseCurrentPopup()
      fileErr = wavFinish()
      openErr = fileErr != ""
    igEndPopup()
  if igBeginPopupModal("Save changes?", nil, ImGuiWindowFlags.AlwaysAutoResize):
    igText("The song has unsaved changes.")
    if igButton("Save"):
      igCloseCurrentPopup()
      if smmPath == "":
        fbOpen(SaveDlg) # `pending` happens once the name is picked
      elif save(smmPath):
        runPending()
    igSameLine()
    if igButton("Don't save"):
      igCloseCurrentPopup()
      runPending()
    igSameLine()
    if igButton("Cancel"):
      igCloseCurrentPopup()
      pending = Nothing
    igEndPopup()
  if igBeginPopupModal("File error", nil, ImGuiWindowFlags.AlwaysAutoResize):
    igText("%s", cstring(fileErr))
    if igButton("OK"):
      igCloseCurrentPopup()
    igEndPopup()
  let opened = fbPick(OpenDlg)
  if opened != nil:
    load $opened
  let named = fbPick(SaveDlg)
  if named != nil:
    var path = $named
    if not path.endsWith ".smm":
      path &= ".smm"
    if save(path):
      runPending()
  let exported = fbPick(ExportDlg)
  if exported != nil:
    var path = $exported
    if not path.endsWith ".mid":
      path &= ".mid"
    try:
      writeFile(path, song.toMidi)
    except CatchableError as e:
      showError e
  let wav = fbPick(WavDlg)
  if wav != nil:
    var path = $wav
    if not path.endsWith ".wav":
      path &= ".wav"
    exportWav(song, path)
    wavPrompt = true

proc fileCommands*(hNew, hOpen, hSave, hSaveAs, hExport, hWav: bool) =
  ## What the File menu or its shortcuts picked this frame.
  if hNew:
    confirm NewSong
  if hOpen:
    confirm OpenSong
  if hSave:
    if smmPath == "":
      pending = Nothing
      fbOpen(SaveDlg)
    else:
      discard save(smmPath)
  if hSaveAs:
    pending = Nothing
    fbOpen(SaveDlg)
  if hExport:
    fbOpen(ExportDlg)
  if hWav:
    fbOpen(WavDlg)
