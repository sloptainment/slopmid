## What the windows share: the song, which track is focused, the snap, the Edit menu's command,
## the placement clicked and copied in the song window, and small drawing helpers.
import std/strformat
import imgui
import model, gm

const
  KeyW* = 56f32 # note-name column
  HdrW* = 108f32 # lane numbers and mute/solo in the song window
  RulerH* = 18f32
  SbW* = 12f32 # scrollbar thickness
  EdgeW* = 6f32
    # grab zone at an edge: a scrollbar thumb's end (zooms), a note's right end (resizes)
  Snaps* = [ # name, ticks, triplet (grid lines go to 1/3 of a beat)
    ("Bar", BarTicks, false),
    ("1/2", Ppq * 2, false),
    ("1/3", Ppq div 3, true),
    ("1/4", Ppq, false),
    ("1/6", Ppq div 6, true),
    ("1/8", Ppq div 2, false),
    ("1/12", Ppq div 12, true),
    ("1/16", Ppq div 4, false),
    ("1/24", Ppq div 24, true),
    ("1/32", Ppq div 8, false),
    ("1/48", Ppq div 48, true),
    ("1/64", Ppq div 16, false),
    ("None", 1, false),
  ]
  Names* = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

type
  Tool* = enum
    Draw
    Select
    Bend ## the piano roll only

  Cmd* = enum
    None
    Undo
    Redo
    SelectAll
    Duplicate
    Copy
    Cut
    Paste
    Quantize
    Delete
    SemiUp
    SemiDown
    OctUp
    OctDown

  Editor* = enum
    ## the piano roll or song window, whichever had focus last: where the Edit menu acts
    NoEditor
    RollEd
    SongEd

# --- shared with the audio thread, under `audio.lock` ---
var song* = Song(bpm: 120, clips: newSeq[Clip](1))

var
  snapIdx* = 7 # 1/16
  focusTrack* = -1 # in clip song.clip; -1 = none
  noTrack: Track # stands in for the focused track while there is none
  menuCmd*: Cmd # picked in the Edit menu this frame
  editor*: Editor
  clicked* = -1 # the clicked placement, drawn with a white border
  placeClip*: seq[Placement] # Ctrl+C in the song window

proc rgb*(r, g, b: int, a = 255): uint32 =
  uint32(r) or uint32(g) shl 8 or uint32(b) shl 16 or uint32(a) shl 24

proc v2*(x, y: float32): ImVec2 =
  ImVec2(x: x, y: y)

proc fired*(win: Editor, c: Cmd, key: ImGuiKey, ctrl = true): bool =
  ## `c` was picked in the Edit menu with `win` the last editor focused, or its shortcut was pressed in `win`.
  let io = igGetIO()
  (menuCmd == c and editor == win) or (
    igIsWindowFocused() and (io.keyCtrl or not ctrl) and igIsKeyPressed(key, false) and
    not io.wantTextInput
  )

proc focused*(): var Track =
  if focusTrack >= 0:
    result = song.clips[song.clip].tracks[focusTrack]
  else:
    result = noTrack

proc noteName*(p: int): string =
  if focused().rhythm and p - DrumLow in 0 .. DrumNames.high:
    return DrumNames[p - DrumLow]
  Names[p mod 12] & $(p div 12 - 1)

proc clipLabel*(i: int): string =
  if song.clips[i].name == "":
    &"Clip {i + 1}"
  else:
    song.clips[i].name

iterator playLines*(): float =
  ## Clip time of each playhead line in the current clip: one per playing placement in song mode.
  if song.songMode:
    for p in song.placements:
      let c = p.clipTime(song.clips[p.clip].loopEnd, song.songPos)
      if p.clip == song.clip and c >= 0:
        yield c
  else:
    yield song.clipPos

proc toolButtons*(tool: var Tool, origin: ImVec2, bend = false) =
  ## The Draw and Select buttons in a window's top-left corner, and Bend if `bend`.
  let dl = igGetWindowDrawList()
  let ts =
    if bend:
      @[Draw, Select, Bend]
    else:
      @[Draw, Select]
  let w = KeyW / ts.len.float32
  for i, t in ts:
    let a = v2(origin.x + i.float32 * w, origin.y)
    igSetCursorScreenPos(a)
    if igInvisibleButton(cstring($t), v2(w, RulerH)):
      tool = t
    if igIsItemHovered():
      igSetTooltip("%s", cstring($t))
    let c = v2(a.x + w / 2, a.y + RulerH / 2)
    let col =
      if tool == t:
        rgb(255, 255, 255)
      else:
        rgb(130, 130, 140)
    if tool == t:
      dl.addRectFilled(a, v2(a.x + w, a.y + RulerH), rgb(66, 150, 250), 2)
    case t
    of Draw: # a pencil, tip down-left
      dl.addLine(v2(c.x - 3, c.y + 3), v2(c.x + 5, c.y - 5), col, 3)
      dl.addLine(v2(c.x - 6, c.y + 6), v2(c.x - 3, c.y + 3), col, 1)
    of Select: # a dashed rectangle
      for d in countup(-6, 4, 4):
        dl.addLine(v2(c.x + d.float32, c.y - 5), v2(c.x + d.float32 + 2, c.y - 5), col)
        dl.addLine(v2(c.x + d.float32, c.y + 5), v2(c.x + d.float32 + 2, c.y + 5), col)
      for d in countup(-5, 3, 4):
        dl.addLine(v2(c.x - 6, c.y + d.float32), v2(c.x - 6, c.y + d.float32 + 2), col)
        dl.addLine(v2(c.x + 6, c.y + d.float32), v2(c.x + 6, c.y + d.float32 + 2), col)
    of Bend: # a swoop
      dl.addLine(v2(c.x - 6, c.y + 2), v2(c.x - 2, c.y - 5), col, 2)
      dl.addLine(v2(c.x - 2, c.y - 5), v2(c.x + 2, c.y + 5), col, 2)
      dl.addLine(v2(c.x + 2, c.y + 5), v2(c.x + 6, c.y - 2), col, 2)

proc focus*(clip, track: int) =
  ## Moving focus stops playback and deselects; leaving a clip forgets its mutes and solos.
  for n in focused().notes.mitems:
    n.sel = false
  for c in focused().cc.mitems:
    for p in c.mitems:
      p.sel = false
  for n in focused().notes.mitems:
    for p in n.bend.mitems:
      p.sel = false
  if clip != song.clip:
    clicked = -1
    for t in song.clips[song.clip].tracks.mitems:
      t.mute = false
      t.solo = false
  song.clip = clip
  focusTrack = track
  if not song.songMode: # the song plays on through clip changes
    song.playing = false
    song.clipPos = 0
