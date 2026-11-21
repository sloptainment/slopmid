## Sheet: left-click adds a note or drags it, its right end resizes it,
## right-click deletes. Note names: click to audition. Velocity lane: drag.
## Select tool (corner buttons): drag a box to select (in the Vol/Exp lane: curve points; Shift adds), drag a selected note to move them all, Delete removes them; Ctrl+A selects all (or deselects, if anything is selected), Ctrl+D duplicates the selection after its last note, Ctrl+Q quantizes the selection's starts and ends to the snap.
## Ctrl+C copies the selection, Ctrl+V pastes it as a group at the playhead set on the ruler, rounded to the snap. In the Vol/Exp/Pan lane they copy and paste curve points, replacing the points the pasted span covers.
## Bend tool (corner buttons): every note shows its pitch bend as a line between points, the first at its start and the last at its end (pinned in time). Drag a point (up/down is semitones from the note, continuous), click the line or a note to add one at the snap, right-drag a middle point to delete it, Ctrl+click puts a point on the note's own pitch. Selection as in Select, built in: click, Shift+click, drag a box, Delete, Ctrl+A. Notes themselves are untouched.
## Wheel scrolls pitch, Shift+wheel scrolls time, middle-drag pans, Ctrl+middle-drag zooms. Space plays/pauses.

import std/[algorithm, locks, math, os, sequtils, strformat, strutils]
import imgui
import wrap/[alsa, filebrowser, gui, slopgs]
import roll, gm, smf, smm

const
  KeyW = 56f32 # note-name column
  RulerH = 18f32
  SbW = 12f32 # scrollbar thickness
  HdrW = 108f32 # lane numbers and mute/solo in the song window
  EdgeW = 6f32 # grab zone at a note's right end for resizing
  Snaps = [ # name, ticks, triplet (grid lines go to 1/3 of a beat)
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
  Names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
  ClickHz = 1000.0
  ClickDownHz = 1500.0 # the first beat of a bar
  ClickLen = 1000 # samples
  ClickAmp = 8000.0 # of 32767
  # a block and a half, as in slopgs's alsa-synth.c
  LatencyUs = 3 * 1_000_000 * BlockFrames div Rate div 2

# --- shared with the audio thread, under `lock` ---
var
  lock: Lock
  song = Song(bpm: 120, clips: newSeq[Clip](1))
  live: seq[(int, int, int)] # key previews, played at the next block's top
  pcm: Pcm
  synth, previewSynth: Synth # separate engines: the song keeps all 16 channels
  audio: Thread[void]

proc audioLoop() {.thread.} =
  var buf, pbuf: Block
  var clicks: seq[tuple[offset: int, downbeat: bool]]
  var hz = ClickHz
  var click = ClickLen # samples of the current click played; ClickLen = silent
  while true:
    {.cast(gcsafe).}:
      withLock(lock):
        for (status, d1, d2) in live:
          slopgs.midi(previewSynth, 0, status, d1, d2)
        live.setLen(0)
        for m in song.advance(BlockFrames, Rate):
          slopgs.midi(synth, m.offset, m.status, m.d1, m.d2)
        slopgs.render(synth, buf)
        slopgs.render(previewSynth, pbuf)
        clicks = song.clicks
      for f in 0 ..< BlockFrames:
        for (at, down) in clicks:
          if at == f:
            click = 0
            hz = if down: ClickDownHz else: ClickHz
        var c = 0
        if click < ClickLen: # a sine that fades out, so it ends without a pop
          c = int(sin(2 * PI * hz * click.float / Rate) * (1 - click / ClickLen) * ClickAmp)
          inc click
        for i in [2 * f, 2 * f + 1]:
          buf[i] = clamp(buf[i].int + pbuf[i].int + c, int16.low.int, int16.high.int).int16
      pcm.write(buf)

# --- UI state, UI thread only ---
type Drag = enum
  Idle
  Move
  Resize
  Box ## a selection box

type Tool = enum
  Draw
  Select
  Bend ## the piano roll only

type PDrag = enum ## dragging a placement in the song window
  PIdle
  PMove
  PTrimL
  PTrimR
  PBox ## a selection box

type ScrollGrab = enum
  GrabBody
  GrabLo
  GrabHi

var
  snapIdx = 7 # 1/16
  lastLen = Ppq
  lastVel = 100 # velocity of the last clicked or dragged note
  beatW = 64f32 # zoom: pixels per beat
  keyH = 14f32 # zoom: pixels per pitch row
  scrollX = 0f32
  scrollY = float32(127 - 84) * keyH # C6 at the top
  velMode = 0 # velocity lane's combo: Vel, Vol, Exp, Pan; a curve's index in `Track.cc` is velMode - 1
  volDrag = -1 # index of the curve point being dragged
  bendNote = -1 # the note whose bend point is being dragged, and which point of its `bend`
  bendPt: int
  bendBox: bool # a selection box of bend points is being dragged, from `boxA`
  ptBoxA: ImVec2 # where the lane's selection box started, relative to the scrolled lane
  velFrac = 0.25f32 # share of the sheet+velocity height taken by the velocity lane
  sbGrab: ScrollGrab
  sbOff: float32
  drag = Idle
  tool = Draw
  boxA: ImVec2 # where the selection box started, relative to the scrolled sheet
  dragNote, grabTicks: int
  velLine: seq[int] # notes whose velocity line was clicked, kept for the drag
  previewKey = -1
  focusTrack = -1 # in clip song.clip; -1 = none
  noTrack: Track # stands in for the focused track while there is none
  songBeatW = 16f32 # the song window's zoom and scroll, like the roll's
  laneH = 28f32
  songScrollX = 0f32
  songScrollY = 0f32
  pdrag = PIdle
  pIdx, pGrab: int
  pSel = -1 # the clicked placement, drawn with a white border
  songTool = Draw
  pBoxA: ImVec2 # where the selection box started, relative to the scrolled lanes
  pOrig: seq[Placement] # the placements when the drag began; a blocked drop goes back to them
  pBlocked: bool # the drag now would overlap placements in a lane
  noteClip: seq[Note] # Ctrl+C in the piano roll
  ccClip: seq[tuple[t, v: int, sel: bool]] # Ctrl+C in a Vol/Exp/Pan lane
  placeClip: seq[Placement] # Ctrl+C in the song window

type Cmd = enum
  None, Undo, Redo, SelectAll, Duplicate, Copy, Paste, Quantize, Delete, SemiUp, SemiDown, OctUp, OctDown

var
  menuCmd: Cmd # picked in the Edit menu this frame
  editor: string # the piano roll or song window, whichever had focus last: where the Edit menu acts

proc fired(win: string, c: Cmd, key: ImGuiKey, ctrl = true): bool =
  ## `c` was picked in the Edit menu with `win` the last editor focused, or its shortcut was pressed in `win`.
  let io = igGetIO()
  (menuCmd == c and editor == win) or
    (igIsWindowFocused() and (io.keyCtrl or not ctrl) and igIsKeyPressed(key, false) and not io.wantTextInput)

proc clipPos(): var float =
  ## The piano roll's playhead, whichever mode is playing.
  if song.songMode:
    result = song.idlePos
  else:
    result = song.pos

proc songPos(): var float =
  if song.songMode:
    result = song.pos
  else:
    result = song.idlePos

proc cur(): var Track =
  if focusTrack >= 0:
    result = song.clips[song.clip].tracks[focusTrack]
  else:
    result = noTrack

proc rgb(r, g, b: int, a = 255): uint32 =
  uint32(r) or uint32(g) shl 8 or uint32(b) shl 16 or uint32(a) shl 24

proc v2(x, y: float32): ImVec2 =
  ImVec2(x: x, y: y)

proc noteName(p: int): string =
  if cur().rhythm and p - DrumLow in 0 .. DrumNames.high:
    return DrumNames[p - DrumLow]
  Names[p mod 12] & $(p div 12 - 1)

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
      song.playing = false # `pos` means something else now
      swap(song.pos, song.idlePos)
    igSameLine()

proc scrollbar(
    id: cstring,
    vertical: bool,
    at: ImVec2,
    len: float32, # track length = visible pixels
    scroll, zoom: var float32, # zoom: pixels per unit
    content, maxZoom: float32, # content length in units
) =
  ## Drag the thumb to scroll, its ends to zoom (the far end stays put).
  let k = len / content # track pixels per unit
  let size =
    if vertical:
      v2(SbW, len)
    else:
      v2(len, SbW)
  igSetCursorScreenPos(at)
  discard igInvisibleButton(id, size)
  let io = igGetIO()
  let mouse = (if vertical: io.mousePos.y - at.y else: io.mousePos.x - at.x)
  var lo = scroll / zoom * k
  var hi = (scroll + len) / zoom * k
  if igIsItemActivated():
    sbGrab =
      if abs(mouse - lo) < EdgeW:
        GrabLo
      elif abs(mouse - hi) < EdgeW:
        GrabHi
      else:
        GrabBody
    sbOff =
      if mouse in lo .. hi:
        mouse - lo
      else:
        (hi - lo) / 2
  if igIsItemActive():
    case sbGrab
    of GrabBody:
      scroll = (mouse - sbOff) / k * zoom
    of GrabLo:
      lo = clamp(mouse, 0, hi - SbW)
      zoom = len / ((hi - lo) / k)
      scroll = lo / k * zoom
    of GrabHi:
      hi = max(mouse, lo + SbW) # past the track end zooms out beyond fit
      zoom = len / ((hi - lo) / k)
      scroll = lo / k * zoom
    zoom = clamp(zoom, k / 4, maxZoom)
    scroll = clamp(scroll, 0, max(0, content * zoom - len))
    lo = scroll / zoom * k
    hi = (scroll + len) / zoom * k
  let a =
    if vertical:
      v2(at.x, at.y + lo)
    else:
      v2(at.x + lo, at.y)
  let b =
    if vertical:
      v2(at.x + SbW, at.y + min(hi, len))
    else:
      v2(at.x + min(hi, len), at.y + SbW)
  let dl = igGetWindowDrawList()
  dl.addRectFilled(at, v2(at.x + size.x, at.y + size.y), rgb(24, 24, 26))
  dl.addRectFilled(
    a,
    b,
    if igIsItemActive():
      rgb(150, 150, 160)
    else:
      rgb(100, 100, 110),
    3,
  )
  # the resize hitboxes, brighter under the mouse or while grabbed
  for (e, g) in [(lo, GrabLo), (hi, GrabHi)]:
    let hot =
      if igIsItemActive():
        sbGrab == g
      else:
        igIsItemHovered() and abs(mouse - e) < EdgeW
    let (e0, e1) = (max(0, e - EdgeW), min(len, e + EdgeW))
    dl.addRectFilled(
      if vertical:
        v2(at.x, at.y + e0)
      else:
        v2(at.x + e0, at.y),
      if vertical:
        v2(at.x + SbW, at.y + e1)
      else:
        v2(at.x + e1, at.y + SbW),
      if hot:
        rgb(255, 255, 255)
      else:
        rgb(110, 160, 255),
      3,
    )

iterator playLines(): float =
  ## Clip time of each playhead line in the current clip: one per playing placement in song mode.
  if song.songMode:
    for p in song.placements:
      let c = p.clipTime(song.clips[p.clip].loopEnd, song.pos)
      if p.clip == song.clip and c >= 0:
        yield c
  else:
    yield song.pos

proc toolButtons(tool: var Tool, origin: ImVec2, bend = false) =
  ## The Draw and Select buttons in a window's top-left corner, and Bend if `bend`.
  let dl = igGetWindowDrawList()
  let ts = if bend: @[Draw, Select, Bend] else: @[Draw, Select]
  let w = KeyW / ts.len.float32
  for i, t in ts:
    let a = v2(origin.x + i.float32 * w, origin.y)
    igSetCursorScreenPos(a)
    if igInvisibleButton(cstring($t), v2(w, RulerH)):
      tool = t
    if igIsItemHovered():
      igSetTooltip("%s", cstring($t))
    let c = v2(a.x + w / 2, a.y + RulerH / 2)
    let col = if tool == t: rgb(255, 255, 255) else: rgb(130, 130, 140)
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

proc pianoRoll() =
  let io = igGetIO()
  if igIsWindowFocused():
    editor = "Piano roll"
  let dl = igGetWindowDrawList()
  let origin = igGetCursorScreenPosNonUDT()
  let avail = igGetContentRegionAvailNonUDT()
  let
    gridX = origin.x + KeyW
    gridW = avail.x - KeyW - SbW
    right = gridX + gridW
    bothH = avail.y - RulerH - SbW # sheet on top, velocity below
    velH = bothH * velFrac
    valH = velH - 8 # value 127 sits 8px below the border, clear of the split grip
    paneH = bothH - velH # sheet height
    sheetTop = origin.y + RulerH
    velTop = sheetTop + paneH
    bottom = velTop + velH
    grid = Snaps[snapIdx][1]
    mouse = v2(io.mousePos.x, io.mousePos.y) # imgui's ImVec2 is not cimgui's

  scrollY = clamp(scrollY, 0, max(0, 128 * keyH - paneH))
  scrollX = max(scrollX, 0)
  proc tickX(t: float): float32 =
    gridX + float32(t / Ppq.float) * beatW - scrollX

  # clamp before int(): imgui parks an absent mouse at -FLT_MAX
  proc xTick(x: float32): int =
    int(max(0, (x - gridX + scrollX) / beatW * Ppq.float32))

  proc pitchY(p: int): float32 =
    sheetTop + float32(127 - p) * keyH - scrollY

  proc yPitch(y: float32): int =
    127 - int(clamp((y - sheetTop + scrollY) / keyH, 0, 127))

  # --- input ---
  # drag the border between sheet and velocity lane; first submitted item wins
  # hover where items overlap, so this goes before the lanes' buttons
  igSetCursorScreenPos(v2(origin.x, velTop - 8))
  discard igInvisibleButton("split", v2(avail.x - SbW, 8)) # above the border only
  let splitHot = igIsItemHovered() or igIsItemActive()
  if splitHot:
    igSetMouseCursor(ImGuiMouseCursor.ResizeNS)
  if igIsItemActive():
    velFrac = clamp((bottom - io.mousePos.y) / bothH, 0.1, 0.9)

  toolButtons(tool, origin, bend = true)
  let notesOk = tool != Bend # in Bend the notes are only looked at
  if tool == Bend:
    for n in cur().notes.mitems:
      if n.bend.len < 2: # the two end points, flat
        n.bend = @[(0, 0.0, false), (0, 0.0, false)]

  if velMode == 0 and fired("Piano roll", SelectAll, ImGuiKey.A):
    if notesOk:
      let all = not cur().notes.anyIt(it.sel) # anything selected: deselect instead
      for n in cur().notes.mitems:
        n.sel = all
    else:
      let all = not cur().notes.anyIt(it.bend.anyIt(it.sel))
      for n in cur().notes.mitems:
        for k in 0 .. n.bend.high:
          n.bend[k].sel = all and n.bendVisible(k)
  if notesOk and fired("Piano roll", Duplicate, ImGuiKey.D):
    let sel = cur().notes.filterIt(it.sel)
    if sel.len > 0:
      let first = sel.mapIt(it.start).min
      var at = sel.mapIt(it.start + it.len).max # right after the last note ends
      let bar = (at + BarTicks - 1) div BarTicks * BarTicks
      if grid < Ppq div 4 and bar - at <= grid: # fine snap: don't leave a sliver before the bar
        at = bar
      for n in cur().notes.mitems:
        n.sel = false
      for n in sel:
        var m = n
        m.start += at - first
        cur().notes.add m
  if notesOk and velMode == 0 and fired("Piano roll", Copy, ImGuiKey.C):
    let sel = cur().notes.filterIt(it.sel)
    if sel.len > 0:
      noteClip = sel
  if notesOk and velMode == 0 and fired("Piano roll", Paste, ImGuiKey.V) and focusTrack >= 0 and noteClip.len > 0:
    let d = snap(clipPos().int, grid) - noteClip.mapIt(it.start).min # the group's first note lands on the playhead
    for n in cur().notes.mitems:
      n.sel = false
    for n in noteClip:
      var m = n
      m.start += d
      cur().notes.add m
  if notesOk and fired("Piano roll", Quantize, ImGuiKey.Q):
    for n in cur().notes.mitems:
      if n.sel:
        let s = snap(n.start, grid)
        n.len = max(grid, snap(n.start + n.len, grid) - s) # at least one snap long
        n.start = s
  var semis = 0 # semitones to transpose by
  if notesOk and editor == "Piano roll" and menuCmd in SemiUp .. OctDown:
    semis = [1, -1, 12, -12][menuCmd.ord - SemiUp.ord]
  elif notesOk and igIsWindowFocused() and (io.keyCtrl or io.keyShift) and not io.wantTextInput:
    let up = igIsKeyPressed(ImGuiKey.UpArrow, true)
    if up or igIsKeyPressed(ImGuiKey.DownArrow, true):
      semis = (if io.keyCtrl: 12 else: 1) * (if up: 1 else: -1)
  if semis != 0:
    let anySel = cur().notes.anyIt(it.sel)
    var d = semis
    for n in cur().notes: # the whole group stops at the edge, keeping its shape
      if n.sel or not anySel:
        d = clamp(d, -n.pitch, 127 - n.pitch)
    for n in cur().notes.mitems:
      if n.sel or not anySel:
        n.pitch += d

  # click or drag on the ruler moves the playhead
  igSetCursorScreenPos(v2(gridX, origin.y))
  discard igInvisibleButton("ruler", v2(gridW, RulerH))
  if igIsItemActive():
    clipPos() = xTick(mouse.x).float

  igSetCursorScreenPos(v2(origin.x, sheetTop))
  discard igInvisibleButton("keys", v2(KeyW, paneH))
  let keysHeld = igIsItemActive()
  let keysHovered = igIsItemHovered()
  igSetCursorScreenPos(v2(gridX, sheetTop))
  discard igInvisibleButton(
    "sheet",
    v2(gridW, paneH),
    ImGuiButtonFlags.MouseButtonLeft or ImGuiButtonFlags.MouseButtonRight or
      ImGuiButtonFlags.MouseButtonMiddle,
  )
  let sheetHovered = igIsItemHovered()
  let sheetPan = igIsItemActive() and igIsMouseDown(ImGuiMouseButton.Middle)
  igSetCursorScreenPos(v2(gridX, velTop))
  discard igInvisibleButton("vel", v2(gridW, velH))
  let velHeld = igIsItemActive()
  let velHovered = igIsItemHovered()
  let velDown = igIsItemActivated()
  let velUp = igIsItemDeactivated()

  igSetCursorScreenPos(v2(origin.x + 2, velTop + 10))
  igSetNextItemWidth(KeyW - 4)
  if igBeginCombo("##velMode", ["Vel", "Vol", "Exp", "Pan"][velMode]):
    for i, name in ["Vel", "Vol", "Exp", "Pan"]:
      if igSelectable(cstring(name), i == velMode):
        velMode = i
    igEndCombo()
  if velMode > 0:
    igSetCursorScreenPos(v2(origin.x + 2, velTop + 14 + igGetFrameHeight()))
    igSetNextItemWidth(KeyW - 4)
    if igBeginCombo("##volRes", ["1/16", "1/32", "1/64", "1/96"][cur().ccRes]):
      for i, name in ["1/16", "1/32", "1/64", "1/96"]:
        if igSelectable(cstring(name), i == cur().ccRes):
          cur().ccRes = i
      igEndCombo()

  if keysHovered or sheetHovered or igIsItemHovered():
    if io.keyShift:
      scrollX -= io.mouseWheel * beatW
    else:
      scrollY -= io.mouseWheel * keyH * 3
    scrollX -= io.mouseWheelH * beatW

  let beats = float32(song.clips[song.clip].loopEnd + 4 * BarTicks) / Ppq.float32
    # room to add past the end
  if sheetPan:
    if io.keyCtrl: # zoom about the mouse: right/up zooms in
      let u = (mouse.x - gridX + scrollX) / beatW
      let v = (mouse.y - sheetTop + scrollY) / keyH
      beatW = clamp(beatW * exp(io.mouseDelta.x * 0.01), gridW / beats / 4, 1024)
      keyH = clamp(keyH * exp(-io.mouseDelta.y * 0.01), paneH / 128 / 4, 160)
      scrollX = u * beatW - (mouse.x - gridX)
      scrollY = v * keyH - (mouse.y - sheetTop)
    else:
      scrollX -= io.mouseDelta.x
      scrollY -= io.mouseDelta.y
  # clamp after the input above, or the frame draws past the edge
  scrollY = clamp(scrollY, 0, max(0, 128 * keyH - paneH))
  scrollX = max(scrollX, 0)
  scrollbar("scrollX", false, v2(gridX, bottom), gridW, scrollX, beatW, beats, 1024)
  scrollbar("scrollY", true, v2(right, sheetTop), paneH, scrollY, keyH, 128, 160)

  let t = xTick(mouse.x)
  let p = yPitch(mouse.y)
  var hit = -1
  for i in countdown(cur().notes.high, 0):
    let n = cur().notes[i]
    if n.pitch == p and t >= n.start and t < n.start + n.len:
      hit = i
      break
  let onEdge =
    hit >= 0 and
    tickX(float(cur().notes[hit].start + cur().notes[hit].len)) - mouse.x < EdgeW
  if notesOk and sheetHovered and (onEdge or drag == Resize):
    igSetMouseCursor(ImGuiMouseCursor.ResizeEW)

  # --- bend points: a point is (note, index into its `bend`) ---
  proc bendXY(n: Note, k: int): ImVec2 =
    v2(tickX(float(n.start + n.bendTick(k))), pitchY(n.pitch) + keyH / 2 - float32(n.bend[k].v) * keyH)
  proc bendVal(n: Note): float = # the mouse's height as semitones from `n`
    clamp(float((pitchY(n.pitch) + keyH / 2 - mouse.y) / keyH), -BendRange.float, BendRange.float)
  proc bendHit(): tuple[note, pt: int] = # the point under the mouse
    result = (-1, -1)
    for i in countdown(cur().notes.high, 0):
      let n = cur().notes[i]
      for k in n.bendIdx:
        let q = bendXY(n, k)
        if abs(q.x - mouse.x) <= 6 and abs(q.y - mouse.y) <= 6:
          return (i, k)
  proc bendLine(): int = # the note whose bend line, else body, is under the mouse
    for i in countdown(cur().notes.high, 0):
      let n = cur().notes[i]
      let ks = n.bendIdx
      for j in 1 .. ks.high:
        let (a, b) = (bendXY(n, ks[j - 1]), bendXY(n, ks[j]))
        let (dx, dy) = (b.x - a.x, b.y - a.y)
        let l2 = dx * dx + dy * dy
        let u = if l2 == 0: 0f32 else: clamp(((mouse.x - a.x) * dx + (mouse.y - a.y) * dy) / l2, 0, 1)
        let (ex, ey) = (mouse.x - a.x - u * dx, mouse.y - a.y - u * dy)
        if ex * ex + ey * ey <= 36:
          return i
    hit
  proc addBend(i: int, v: float) = # a point at the snapped tick, or that tick's own point, set to `v`
    template n(): untyped = cur().notes[i]
    if n.len >= 2:
      let t = clamp(snap(xTick(mouse.x), grid) - n.start, 1, n.len - 1)
      var k = 1
      while k < n.bend.high and n.bend[k].t < t:
        inc k
      if k < n.bend.high and n.bend[k].t == t:
        n.bend[k].v = v
      else:
        n.bend.insert((t, v, false), k)
      bendNote = i
      bendPt = k
  if not notesOk:
    if sheetHovered and igIsMouseClicked(ImGuiMouseButton.Left):
      let (hi, hk) = bendHit()
      let ln = bendLine()
      bendNote = -1
      if hi >= 0:
        bendNote = hi
        bendPt = hk
        if io.keyCtrl: # on the note's own pitch; a selected point takes its whole selection along
          let group = cur().notes[hi].bend[hk].sel
          cur().notes[hi].bend[hk].v = 0
          if group:
            for n in cur().notes.mitems:
              for k in n.bendIdx:
                if n.bend[k].sel:
                  n.bend[k].v = 0
          bendNote = -1
        elif not cur().notes[hi].bend[hk].sel: # a selected point keeps the group
          if not io.keyShift:
            for n in cur().notes.mitems:
              for q in n.bend.mitems:
                q.sel = false
          cur().notes[hi].bend[hk].sel = true
      elif ln >= 0:
        addBend(ln, if io.keyCtrl: 0.0 else: bendVal(cur().notes[ln]))
        if io.keyCtrl:
          bendNote = -1
      else:
        bendBox = true
        boxA = v2(mouse.x - gridX + scrollX, mouse.y - sheetTop + scrollY)
    if not igIsMouseDown(ImGuiMouseButton.Left):
      if bendBox: # the points in the box get selected
        let (bx0, bx1) = (min(boxA.x + gridX - scrollX, mouse.x), max(boxA.x + gridX - scrollX, mouse.x))
        let (by0, by1) = (min(boxA.y + sheetTop - scrollY, mouse.y), max(boxA.y + sheetTop - scrollY, mouse.y))
        for n in cur().notes.mitems:
          for k in n.bendIdx:
            let q = bendXY(n, k)
            if q.x >= bx0 and q.x <= bx1 and q.y >= by0 and q.y <= by1:
              n.bend[k].sel = true
            elif not io.keyShift:
              n.bend[k].sel = false
      bendBox = false
      bendNote = -1
    if bendNote >= 0:
      # the dragged point, or its whole selection, moves by the same ticks and semitones
      let bn = cur().notes[bendNote]
      let inGroup = proc(i, k: int): bool =
        let n = cur().notes[i]
        (i == bendNote and k == bendPt) or (n.bendVisible(k) and n.bend[k].sel)
      var dt = 0 # the end points only move up and down
      if bendPt > 0 and bendPt < bn.bend.high:
        dt = snap(xTick(mouse.x), grid) - bn.start - bn.bend[bendPt].t
      var dv = bendVal(bn) - bn.bend[bendPt].v
      for i, n in cur().notes:
        for k in n.bendIdx:
          if inGroup(i, k):
            dv = clamp(dv, -BendRange.float - n.bend[k].v, BendRange.float - n.bend[k].v)
            if k > 0 and k < n.bend.high: # the group stops at its neighbours and the note's ends
              let t = n.bend[k].t
              if k > 1 and not inGroup(i, k - 1): dt = max(dt, n.bend[k - 1].t + 1 - t)
              if k == n.bend.high - 1: dt = min(dt, n.len - 1 - t)
              elif not inGroup(i, k + 1): dt = min(dt, min(n.bend[k + 1].t, n.len) - 1 - t)
              if k == 1: dt = max(dt, 1 - t)
      for i, n in cur().notes.mpairs:
        for k in n.bendIdx:
          if inGroup(i, k):
            n.bend[k].v += dv
            if k > 0 and k < n.bend.high:
              n.bend[k].t += dt
    elif sheetHovered and igIsMouseDown(ImGuiMouseButton.Right): # dragging deletes; not the ends
      let (hi, hk) = bendHit()
      if hi >= 0 and hk > 0 and hk < cur().notes[hi].bend.high:
        cur().notes[hi].bend.delete hk

  if notesOk and sheetHovered and igIsMouseClicked(ImGuiMouseButton.Left):
    if hit < 0 and tool == Draw:
      for n in cur().notes.mitems:
        n.sel = false
      cur().notes.add Note(
        start: max(0, snapDown(t, grid)), len: lastLen, pitch: p, vel: lastVel
      )
      hit = cur().notes.high
    if hit >= 0:
      dragNote = hit
      drag = if onEdge: Resize else: Move
      grabTicks = t - cur().notes[hit].start
      lastLen = cur().notes[hit].len
      lastVel = cur().notes[hit].vel
      if tool == Select and not cur().notes[hit].sel: # a selected note keeps the group
        if not io.keyShift:
          for n in cur().notes.mitems:
            n.sel = false
        cur().notes[hit].sel = true
    else:
      drag = Box
      boxA = v2(mouse.x - gridX + scrollX, mouse.y - sheetTop + scrollY)
  # the box in screen space; touched notes get selected on release
  let (bx0, bx1) = (min(boxA.x + gridX - scrollX, mouse.x), max(boxA.x + gridX - scrollX, mouse.x))
  let (by0, by1) = (min(boxA.y + sheetTop - scrollY, mouse.y), max(boxA.y + sheetTop - scrollY, mouse.y))
  if not igIsMouseDown(ImGuiMouseButton.Left):
    if drag == Box:
      for n in cur().notes.mitems:
        let touched =
          tickX(n.start.float) <= bx1 and tickX(float(n.start + n.len)) >= bx0 and
          pitchY(n.pitch) <= by1 and pitchY(n.pitch) + keyH >= by0
        if touched:
          n.sel = true
        elif not io.keyShift:
          n.sel = false
    drag = Idle
  case drag
  of Move:
    # the dragged note, or its whole selection, moves by the same ticks and pitches
    let n = cur().notes[dragNote]
    var ds = snap(t - grabTicks, grid) - n.start
    var dp = p - n.pitch
    for i, m in cur().notes:
      if (if n.sel: m.sel else: i == dragNote):
        ds = max(ds, -m.start)
        dp = clamp(dp, -m.pitch, 127 - m.pitch)
    for i, m in cur().notes.mpairs:
      if (if n.sel: m.sel else: i == dragNote):
        m.start += ds
        m.pitch += dp
  of Box:
    discard
  of Resize:
    # the dragged note, or its whole selection, changes length by the same ticks
    let n = cur().notes[dragNote]
    var d = snap(t, grid) - n.start - n.len
    for i, m in cur().notes:
      if (if n.sel: m.sel else: i == dragNote):
        d = max(d, grid - m.len)
    for i, m in cur().notes.mpairs:
      if (if n.sel: m.sel else: i == dragNote):
        m.len += d
    lastLen = cur().notes[dragNote].len
  of Idle:
    if velMode == 0 and fired("Piano roll", Delete, ImGuiKey.Delete, ctrl = false):
      if notesOk:
        cur().notes.keepItIf(not it.sel)
      else: # the selected middle points
        for n in cur().notes.mitems:
          for k in countdown(n.bend.high - 1, 1):
            if n.bendVisible(k) and n.bend[k].sel:
              n.bend.delete k
    elif tool == Draw and sheetHovered and igIsMouseDown(ImGuiMouseButton.Right) and hit >= 0:
      cur().notes.delete hit

  # clicking a key or placing/moving a note plays it; dragging across pitches glides
  var key = -1
  var vel = 0
  if keysHeld:
    key = yPitch(mouse.y)
    vel = clamp(int((mouse.x - origin.x) / KeyW * 127), 1, 127)
  elif drag == Move:
    key = cur().notes[dragNote].pitch
    vel = cur().notes[dragNote].vel
  if key != previewKey:
    let ch = if cur().rhythm: Drums else: PreviewCh
    if previewKey >= 0: # note off
      live.add (0x80 or ch, previewKey, 0)
    if key >= 0: # the track's sound, then note on
      live.add (0xB0 or ch, 0, cur().bank)
      live.add (0xC0 or ch, cur().program, 0)
      live.add (0x90 or ch, key, vel)
    previewKey = key

  # dragging in the velocity lane sets the selected notes (all, if none) whose bar is under the mouse
  let onLine = proc(n: Note): bool = # the faint line across the note's length
    mouse.x >= tickX(n.start.float) and mouse.x <= tickX(float(n.start + n.len)) and
      abs(bottom - float32(n.vel) / 127 * valH - mouse.y) <= 4
  template pts(): untyped = cur().cc[velMode - 1] # the curve shown, in a curve mode
  let volHit = proc(): int = # the curve point under the mouse
    result = -1
    for i, p in pts:
      if abs(tickX(p.t.float) - mouse.x) <= 6 and abs(bottom - float32(p.v) / 127 * valH - mouse.y) <= 6:
        return i
  let volVal = proc(): int = clamp(int((bottom - mouse.y) / valH * 127), 0, 127)
  let loopT = song.clips[song.clip].loopEnd
  let addPt = proc(v: int) = # a point at the snapped tick, or that tick's own point, set to `v`
    let t = min(snap(xTick(mouse.x), grid), loopT)
    volDrag = pts.len
    for i, p in pts:
      if p.t >= t:
        volDrag = i
        break
    if volDrag < pts.len and pts[volDrag].t == t:
      pts[volDrag].v = v
    else:
      pts.insert((t, v, false), volDrag)
  let onCurve = proc(): bool = # the drawn curve under the mouse
    let t = xTick(mouse.x)
    t >= pts[0].t and t <= loopT and
      abs(bottom - float32(cur().ccAt(velMode - 1, t)) / 127 * valH - mouse.y) <= 6
  if velMode > 0:
    if fired("Piano roll", SelectAll, ImGuiKey.A):
      let all = not pts.anyIt(it.sel) # anything selected: deselect instead
      for p in pts.mitems:
        p.sel = all
    if fired("Piano roll", Delete, ImGuiKey.Delete, ctrl = false):
      pts.keepItIf(not it.sel)
    if fired("Piano roll", Copy, ImGuiKey.C) and pts.anyIt(it.sel):
      ccClip = pts.filterIt(it.sel)
    if fired("Piano roll", Paste, ImGuiKey.V) and ccClip.len > 0:
      let d = snap(clipPos().int, grid) - ccClip[0].t # the first point lands on the playhead
      let moved = ccClip.mapIt((t: it.t + d, v: it.v, sel: true)).filterIt(it.t <= loopT)
      if moved.len > 0: # replaces the points the pasted span covers
        pts.keepItIf(it.t < moved[0].t or it.t > moved[^1].t)
        for p in pts.mitems:
          p.sel = false
        pts = (pts & moved).sortedByIt(it.t)
  if velMode > 0:
    if pts.len == 0: # the default, as a point at the start
      pts.add (0, CcDefault[velMode - 1], false)
    if velDown:
      volDrag = volHit()
      if velMode == 3 and io.keyCtrl and (volDrag >= 0 or onCurve()): # Pan: Ctrl+click centres a point, or adds one at centre
        if volDrag >= 0:
          pts[volDrag].v = CcDefault[2]
        else:
          addPt(CcDefault[2])
        volDrag = -2 # no drag, no box
      elif tool == Select:
        if volDrag >= 0 and not pts[volDrag].sel: # a selected point keeps the group
          if not io.keyShift:
            for p in pts.mitems:
              p.sel = false
          pts[volDrag].sel = true
        elif volDrag < 0: # empty space: a box
          ptBoxA = v2(mouse.x - gridX + scrollX, mouse.y)
      elif volDrag < 0: # a click on empty space adds a point, at the snap
        addPt(volVal())
    let (bx0, bx1) = (min(ptBoxA.x + gridX - scrollX, mouse.x), max(ptBoxA.x + gridX - scrollX, mouse.x))
    let (by0, by1) = (min(ptBoxA.y, mouse.y), max(ptBoxA.y, mouse.y))
    if tool == Select and volDrag == -1 and velUp: # a box ends: the points in it get selected
      for i, p in pts:
        let (x, y) = (tickX(p.t.float), bottom - float32(p.v) / 127 * valH)
        if x >= bx0 and x <= bx1 and y >= by0 and y <= by1:
          pts[i].sel = true
        elif not io.keyShift:
          pts[i].sel = false
    if velHeld and volDrag in 0 ..< pts.len:
      # the dragged point, or in Select its whole selection, moves by the same ticks and values
      let inGroup = proc(i: int): bool = i == volDrag or (tool == Select and pts[i].sel)
      var dt = clamp(snap(xTick(mouse.x), grid), 0, loopT) - pts[volDrag].t
      var dv = volVal() - pts[volDrag].v
      for i, p in pts: # the group stops at its neighbours and the edges, keeping its shape
        if inGroup(i):
          if i > 0 and not inGroup(i - 1): dt = max(dt, pts[i - 1].t + 1 - p.t)
          if i < pts.high and not inGroup(i + 1): dt = min(dt, pts[i + 1].t - 1 - p.t)
          dt = clamp(dt, -p.t, max(0, loopT - p.t))
          dv = clamp(dv, -p.v, 127 - p.v)
      for i in 0 .. pts.high:
        if inGroup(i):
          pts[i].t += dt
          pts[i].v += dv
    if velHovered and igIsMouseDown(ImGuiMouseButton.Right): # dragging deletes; the last point stays
      let h = volHit()
      if h >= 0 and pts.len > 1:
        pts.delete h
  if velMode == 0 and velDown:
    velLine.setLen 0
    for i, n in cur().notes:
      if onLine(n):
        velLine.add i
  if velMode == 0 and velHeld:
    let v = clamp(int((bottom - mouse.y) / valH * 127), 1, 127)
    let anySel = cur().notes.anyIt(it.sel)
    for i, n in cur().notes.mpairs:
      if (n.sel or not anySel) and (abs(tickX(n.start.float) - mouse.x) <= 4 or i in velLine):
        n.vel = v
        lastVel = v

  # tooltip: the value being dragged, else one line per note the drag would set
  if velHeld or velHovered:
    var lines: seq[string]
    let line = proc(v: int): string =
      if velMode != 3:
        fmt"{v} - {int(round(v / 127 * 100))}%"
      elif v == 64: # pan: 0 = full left, 64 = centre, 127 = full right
        fmt"{v} - Center"
      elif v < 64:
        fmt"{v} - {int(round((64 - v) / 64 * 100))}% L"
      else:
        fmt"{v} - {int(round((v - 64) / 63 * 100))}% R"
    if velMode > 0:
      let h = if velHeld: volDrag else: volHit()
      if h in 0 ..< pts.len:
        lines.add line(pts[h].v)
    elif velHeld:
      lines.add line(clamp(int((bottom - mouse.y) / valH * 127), 1, 127))
    else:
      let anySel = cur().notes.anyIt(it.sel)
      for n in cur().notes:
        if (n.sel or not anySel) and (abs(tickX(n.start.float) - mouse.x) <= 4 or onLine(n)):
          lines.add noteName(n.pitch) & ": " & line(n.vel)
    if lines.len > 0:
      igSetTooltip("%s", cstring(lines.join("\n")))

  # --- drawing ---
  # note names
  dl.pushClipRect(v2(origin.x, sheetTop), v2(gridX, velTop), true)
  for q in 0 .. 127:
    let y = pitchY(q)
    let black = Names[q mod 12].len == 2
    let col =
      if q == previewKey:
        rgb(120, 170, 255)
      elif black:
        rgb(30, 30, 34)
      else:
        rgb(220, 220, 220)
    dl.addRectFilled(v2(origin.x, y), v2(gridX - 1, y + keyH - 1), col)
    dl.addText(
      v2(origin.x + 4, y),
      if black:
        rgb(200, 200, 200)
      else:
        rgb(20, 20, 20),
      cstring(noteName(q)),
    )
  dl.popClipRect()

  # pitch rows, then grid lines through ruler, sheet and velocity lane
  dl.pushClipRect(v2(gridX, sheetTop), v2(right, velTop), true)
  for q in 0 .. 127:
    let y = pitchY(q)
    dl.addRectFilled(
      v2(gridX, y),
      v2(right, y + keyH),
      if Names[q mod 12].len == 2:
        rgb(40, 44, 50)
      else:
        rgb(52, 56, 62),
    )
  dl.popClipRect()
  dl.pushClipRect(v2(gridX, origin.y), v2(right, bottom), true)
  dl.addRectFilled(v2(gridX, origin.y), v2(right, sheetTop), rgb(30, 30, 30))
  dl.addRectFilled(v2(gridX, velTop), v2(right, bottom), rgb(34, 36, 40))
  let step = if Snaps[snapIdx][2]: Ppq div 3 else: Ppq div 4
  var gt = xTick(gridX).snapDown(step)
  while gt <= xTick(right):
    let x = tickX(gt.float)
    let col =
      if gt mod BarTicks == 0:
        rgb(20, 20, 20)
      elif gt mod Ppq == 0:
        rgb(32, 34, 38)
      else:
        rgb(44, 48, 54)
    dl.addLine(v2(x, sheetTop), v2(x, bottom), col)
    if gt mod BarTicks == 0:
      dl.addText(
        v2(x + 3, origin.y + 1), rgb(200, 200, 200), cstring($(gt div BarTicks + 1))
      )
    gt += step
  dl.addLine(
    v2(gridX, velTop),
    v2(right, velTop),
    (if splitHot: rgb(110, 160, 255) else: rgb(90, 90, 90)),
    (if splitHot: 3 else: 2),
  )
  let le = tickX(song.clips[song.clip].loopEnd.float)
  dl.addLine(v2(le, origin.y), v2(le, sheetTop), rgb(200, 120, 60), 3)

  # notes, then their velocities
  dl.pushClipRect(v2(gridX, sheetTop), v2(right, velTop), true)
  for n in cur().notes:
    let (x0, x1, y) =
      (tickX(n.start.float), tickX(float(n.start + n.len)), pitchY(n.pitch))
    let shade = 90 + n.vel
    dl.addRectFilled(
      v2(x0, y + 1),
      v2(x1, y + keyH - 1),
      if n.sel: rgb(shade, shade, shade div 3) else: rgb(shade div 2, shade, shade div 2),
      2,
    )
    dl.addRect(v2(x0, y + 1), v2(x1, y + keyH - 1), if n.sel: rgb(255, 255, 255) else: rgb(10, 30, 10), 2)
    let name = noteName(n.pitch) # faded, only where the whole name fits inside the note
    if keyH >= igGetTextLineHeight() and x1 - x0 >= igCalcTextSizeNonUDT(cstring(name)).x + 6:
      dl.addText(v2(x0 + 3, y + (keyH - igGetTextLineHeight()) / 2), rgb(0, 0, 0, 120), cstring(name))
  let notes = cur().notes
  for i, a in notes: # same-pitch notes sounding together: red on the shared ticks only
    for b in notes[i + 1 ..< notes.len]: # ponytail: O(n^2) pairs, sort by pitch if big clips lag
      let (s, e) = (max(a.start, b.start), min(a.start + a.len, b.start + b.len))
      if a.pitch == b.pitch and s < e:
        let y = pitchY(a.pitch)
        dl.addRectFilled(v2(tickX(s.float), y + 1), v2(tickX(e.float), y + keyH - 1), rgb(255, 30, 30), 2)
  if tool == Bend:
    # a point or segment is black where another note's bend wins the track's wheel there
    # ponytail: O(notes^2) per frame; fine for a clip's worth of notes
    let loses = proc(i, tick: int): bool =
      let w = cur().bendWinner(tick)
      w >= 0 and w != i
    for i, n in cur().notes:
      let ks = n.bendIdx
      for j in 1 .. ks.high:
        let mid = n.start + (n.bendTick(ks[j - 1]) + n.bendTick(ks[j])) div 2
        dl.addLine(bendXY(n, ks[j - 1]), bendXY(n, ks[j]), if loses(i, mid): rgb(0, 0, 0) else: rgb(255, 255, 255), 2)
      for k in ks:
        let c = if loses(i, n.start + min(n.bendTick(k), n.len - 1)): rgb(0, 0, 0) else: rgb(255, 255, 255)
        if n.bend[k].sel:
          dl.addCircleFilled(bendXY(n, k), 5, rgb(255, 150, 30))
        dl.addCircle(bendXY(n, k), 5, c, 0, 2)
  if drag == Box or bendBox:
    dl.addRectFilled(v2(bx0, by0), v2(bx1, by1), rgb(66, 150, 250, 50))
    dl.addRect(v2(bx0, by0), v2(bx1, by1), rgb(66, 150, 250))
  dl.popClipRect()
  if velMode > 0:
    dl.pushClipRect(v2(gridX, velTop), v2(right, bottom), true)
    let col = rgb(110, 210, 110)
    if velMode == 3: # the centre
      let cy = bottom - float32(CcDefault[2]) / 127 * valH
      dl.addLine(v2(gridX, cy), v2(right, cy), rgb(255, 255, 255, 200), 3)
    let pt = proc(p: tuple[t, v: int, sel: bool]): ImVec2 = v2(tickX(p.t.float), bottom - float32(p.v) / 127 * valH)
    for i, p in pts:
      if i > 0:
        dl.addLine(pt(pts[i - 1]), pt(p), col, 2)
    for p in pts:
      dl.addCircleFilled(pt(p), 4, if p.sel: rgb(255, 255, 85) else: col)
    if tool == Select and velHeld and volDrag == -1:
      let (bx0, bx1) = (min(ptBoxA.x + gridX - scrollX, mouse.x), max(ptBoxA.x + gridX - scrollX, mouse.x))
      let (by0, by1) = (min(ptBoxA.y, mouse.y), max(ptBoxA.y, mouse.y))
      dl.addRectFilled(v2(bx0, by0), v2(bx1, by1), rgb(66, 150, 250, 50))
      dl.addRect(v2(bx0, by0), v2(bx1, by1), rgb(66, 150, 250))
    let last = pt(pts[^1]) # held to the loop point
    dl.addLine(last, v2(le, last.y), col, 2)
    dl.popClipRect()
  for n in (if velMode == 0: cur().notes else: @[]):
    let x0 = tickX(n.start.float)
    let vy = bottom - float32(n.vel) / 127 * valH
    let c = if n.sel: rgb(255, 255, 85) else: rgb(110, 210, 110)
    dl.addLine(v2(x0, vy), v2(tickX(float(n.start + n.len)), vy), (if n.sel: rgb(255, 255, 85, 90) else: rgb(110, 210, 110, 90)), 2)
    dl.addLine(v2(x0, bottom), v2(x0, vy), c, 2)
    dl.addCircleFilled(v2(x0, vy), 4, c)

  for c in playLines():
    dl.addLine(v2(tickX(c), origin.y), v2(tickX(c), bottom), rgb(255, 255, 255, 180))
  if song.songMode: # the clip's own position, where Ctrl+V pastes
    dl.addLine(v2(tickX(song.idlePos), origin.y), v2(tickX(song.idlePos), bottom), rgb(255, 255, 255, 80))
  dl.popClipRect()

var
  togglePianoRoll = true
  toggleClips = true
  toggleSong = true
  firstFrame = true

proc focus(clip, track: int) =
  ## Moving focus stops playback and deselects; leaving a clip forgets its mutes and solos.
  for n in cur().notes.mitems:
    n.sel = false
  for c in cur().cc.mitems:
    for p in c.mitems:
      p.sel = false
  for n in cur().notes.mitems:
    for p in n.bend.mitems:
      p.sel = false
  if clip != song.clip:
    pSel = -1
    for t in song.clips[song.clip].tracks.mitems:
      t.mute = false
      t.solo = false
  song.clip = clip
  focusTrack = track
  if not song.songMode: # the song plays on through clip changes
    song.playing = false
    song.pos = 0

proc clipLabel(i: int): string =
  if song.clips[i].name == "": &"Clip {i + 1}" else: song.clips[i].name

proc clips() =
  igText("Clip:")
  igSameLine()
  igSetNextItemWidth(100)
  if igBeginCombo("##clip", cstring(clipLabel(song.clip))):
    for i in song.clips.low .. song.clips.high:
      if igSelectable(cstring(&"{clipLabel(i)}##{i}"), i == song.clip):
        focus(i, -1)
    igEndCombo()
  igSameLine()
  if igButton("Add"):
    song.clips.add Clip()
    focus(song.clips.high, -1)
  igSameLine()
  if igButton("Remove") and song.clips.len > 1:
    let gone = song.clip
    focus(gone, -1)
    song.clips.delete gone
    song.placements.keepItIf(it.clip != gone)
    placeClip.setLen 0 # its clip numbers are stale
    pSel = -1
    for p in song.placements.mitems:
      if p.clip > gone:
        dec p.clip
    song.clip = min(gone, song.clips.high)
  igSameLine()
  if igButton("Duplicate"):
    focus(song.clip, -1) # deselects, so the copy has no selection
    song.clips.add song.clips[song.clip]
    for t in song.clips[^1].tracks.mitems:
      t.mute = false
      t.solo = false
    focus(song.clips.high, -1)
  igSameLine()
  igText("Clip name: ")
  igSameLine()
  igSetNextItemWidth(-1)
  var buf: array[64, char]
  copyMem(addr buf[0], cstring(song.clips[song.clip].name), min(song.clips[song.clip].name.len, 63))
  if igInputText("##name", cast[cstring](addr buf[0]), buf.len.uint):
    song.clips[song.clip].name = $cast[cstring](addr buf[0])
  igSeparator()
  if igBeginTable("tracks", 4, ImGuiTableFlags.SizingStretchProp):
    igTableSetupColumn("", ImGuiTableColumnFlags.WidthFixed) # "X"
    igTableSetupColumn("", ImGuiTableColumnFlags.WidthFixed) # "M/S"
    igTableSetupColumn("", ImGuiTableColumnFlags.WidthFixed) # name
    igTableSetupColumn("", ImGuiTableColumnFlags.WidthStretch, 1)
    let dl = igGetWindowDrawList()
    let span = song.clips[song.clip].loopEnd.float32
    for i in 0 ..< song.clips[song.clip].tracks.len:
      igTableNextRow()
      igPushID(int32(i))
      template t(): untyped =
        song.clips[song.clip].tracks[i]

      discard igTableNextColumn()
      if igButton("X"):
        let f = focusTrack - ord(focusTrack > i) # tracks after the gone one shift down
        focus(song.clip, if focusTrack == i: -1 else: f)
        song.clips[song.clip].tracks.delete i
        igPopID()
        break
      discard igTableNextColumn()
      discard igCheckbox("M", addr t.mute)
      discard igCheckbox("S", addr t.solo)
      discard igTableNextColumn()
      igSetNextItemWidth(-1)
      if igBeginCombo(
        "##prog",
        cstring(
          if t.rhythm:
            &"Rhythm {t.program:03}"
          else:
            &"{t.bank:03}:{t.program:03} {GmNames[t.program]}"
        ),
      ):
        for q, name in GmNames:
          if igSelectable(cstring(&"{t.bank:03}:{q:03} {name}"), not t.rhythm and q == t.program):
            t.program = q
            t.rhythm = false
        if igSelectable("Rhythm", t.rhythm):
          t.rhythm = true
          t.bank = 0
        igEndCombo()
      igSetNextItemWidth(70)
      var bank = t.bank.int32
      igBeginDisabled(t.rhythm)
      if igInputInt("Bk#", addr bank):
        t.bank = clamp(bank, 0, 127).int
      igEndDisabled()
      igSameLine()
      igSetNextItemWidth(70)
      var prog = t.program.int32
      if igInputInt("P#", addr prog):
        t.program = clamp(prog, 0, 127).int
      discard igTableNextColumn()
      # the preview: notes as tiny rectangles; clicking it focuses the track
      let at = igGetCursorScreenPosNonUDT()
      let size = v2(max(igGetContentRegionAvailNonUDT().x, 1), 56)
      if igInvisibleButton("preview", size):
        focus(song.clip, i)
      let (x0, y0) = (at.x, at.y)
      dl.addRectFilled(
        v2(x0, y0),
        v2(x0 + size.x, y0 + size.y),
        if i == focusTrack:
          rgb(60, 60, 90)
        else:
          rgb(0, 0, 0),
      )
      if t.notes.len > 0:
        var (lo, hi) = (127, 0)
        for n in t.notes:
          lo = min(lo, n.pitch)
          hi = max(hi, n.pitch)
        let rowH = size.y / float32(hi - lo + 1)
        for n in t.notes:
          let y = y0 + float32(hi - n.pitch) * rowH
          dl.addRectFilled(
            v2(x0 + n.start.float32 / span * size.x, y),
            v2(x0 + float32(n.start + n.len) / span * size.x, y + max(rowH, 1)),
            rgb(110, 210, 110),
          )
      for c in playLines():
        let x = x0 + c / span * size.x
        dl.addLine(v2(x, y0), v2(x, y0 + size.y), rgb(255, 255, 255, 180))
      igPopID()
    igEndTable()
  if igButton("ADD"):
    song.clips[song.clip].tracks.add Track()

proc fits(i: int, p: Placement): bool =
  ## `p` could replace placement `i` (-1: be added): in bounds and clear of its lane's others.
  result = p.len > 0 and p.start >= 0 and p.lane in 0 ..< Lanes
  for j, q in song.placements:
    if j != i and q.lane == p.lane and q.start < p.start + p.len and p.start < q.start + q.len:
      result = false

proc songPlaylist() =
  ## Lanes of placed clips. Draw tool: click empty space to place the clip chosen in Clips (drag before releasing to position it),
  ## right-click removes. Select tool: drag a box to select; Delete removes the selection, Ctrl+A selects all, or deselects if anything is selected.
  ## Either tool: drag to move (a selection moves together), drag an edge to trim (the left one starts the clip part-way in,
  ## the right one past its end repeats it, and moves the whole selection's right edges). A drop that would overlap
  ## in a lane draws red and goes back. Panning and zooming as in the piano roll.
  let io = igGetIO()
  if igIsWindowFocused():
    editor = "Song"
  let dl = igGetWindowDrawList()
  let origin = igGetCursorScreenPosNonUDT()
  let avail = igGetContentRegionAvailNonUDT()
  let
    gridX = origin.x + HdrW
    gridW = avail.x - HdrW - SbW
    right = gridX + gridW
    paneH = avail.y - RulerH - SbW
    laneTop = origin.y + RulerH
    bottom = laneTop + paneH
    grid = Snaps[snapIdx][1]
    mouse = v2(io.mousePos.x, io.mousePos.y)

  songScrollY = clamp(songScrollY, 0, max(0, Lanes.float32 * laneH - paneH))
  songScrollX = max(songScrollX, 0)
  proc tickX(t: float): float32 =
    gridX + float32(t / Ppq.float) * songBeatW - songScrollX

  proc xTick(x: float32): int =
    int(max(0, (x - gridX + songScrollX) / songBeatW * Ppq.float32))

  proc laneY(l: int): float32 =
    laneTop + l.float32 * laneH - songScrollY

  proc yLane(y: float32): int =
    int(clamp((y - laneTop + songScrollY) / laneH, 0, Lanes - 1))

  # --- input ---
  igSetCursorScreenPos(v2(gridX, origin.y))
  discard igInvisibleButton("ruler", v2(gridW, RulerH))
  if igIsItemActive():
    songPos() = xTick(mouse.x).float
  igSetCursorScreenPos(v2(gridX, laneTop))
  discard igInvisibleButton(
    "grid",
    v2(gridW, paneH),
    ImGuiButtonFlags.MouseButtonLeft or ImGuiButtonFlags.MouseButtonRight or
      ImGuiButtonFlags.MouseButtonMiddle,
  )
  let hovered = igIsItemHovered()
  let pan = igIsItemActive() and igIsMouseDown(ImGuiMouseButton.Middle)
  if hovered:
    if io.keyShift:
      songScrollX -= io.mouseWheel * songBeatW
    else:
      songScrollY -= io.mouseWheel * laneH * 3
    songScrollX -= io.mouseWheelH * songBeatW
  let beats = float32(song.songEnd + 16 * BarTicks) / Ppq.float32 # room to add past the end
  if pan:
    if io.keyCtrl: # zoom about the mouse: right/up zooms in
      let u = (mouse.x - gridX + songScrollX) / songBeatW
      let v = (mouse.y - laneTop + songScrollY) / laneH
      songBeatW = clamp(songBeatW * exp(io.mouseDelta.x * 0.01), gridW / beats / 4, 1024)
      laneH = clamp(laneH * exp(-io.mouseDelta.y * 0.01), paneH / Lanes.float32 / 4, 320)
      songScrollX = u * songBeatW - (mouse.x - gridX)
      songScrollY = v * laneH - (mouse.y - laneTop)
    else:
      songScrollX -= io.mouseDelta.x
      songScrollY -= io.mouseDelta.y
  songScrollY = clamp(songScrollY, 0, max(0, Lanes.float32 * laneH - paneH))
  songScrollX = max(songScrollX, 0)
  scrollbar("scrollX", false, v2(gridX, bottom), gridW, songScrollX, songBeatW, beats, 1024)
  scrollbar("scrollY", true, v2(right, laneTop), paneH, songScrollY, laneH, Lanes.float32, 320)

  toolButtons(songTool, origin)
  if fired("Song", SelectAll, ImGuiKey.A):
    let all = not song.placements.anyIt(it.sel) # anything selected: deselect instead
    for p in song.placements.mitems:
      p.sel = all
  if fired("Song", Copy, ImGuiKey.C):
    let sel = song.placements.filterIt(it.sel)
    if sel.len > 0:
      placeClip = sel
  if fired("Song", Paste, ImGuiKey.V) and placeClip.len > 0:
    let d = snap(songPos().int, grid) - placeClip.mapIt(it.start).min # the group's first clip lands on the playhead
    let moved = placeClip.mapIt(Placement(clip: it.clip, lane: it.lane, start: it.start + d, len: it.len, offset: it.offset, sel: true))
    if moved.allIt(fits(-1, it)): # all or nothing: an overlap anywhere cancels the paste
      for p in song.placements.mitems:
        p.sel = false
      song.placements.add moved
  if fired("Song", Quantize, ImGuiKey.Q):
    for i in 0 ..< song.placements.len:
      var p = song.placements[i]
      if p.sel:
        let s = snap(p.start, grid)
        p.len = max(grid, snap(p.start + p.len, grid) - s) # at least one snap long; skipped if it would overlap
        p.start = s
        if fits(i, p):
          song.placements[i] = p

  let t = xTick(mouse.x)
  let lane = yLane(mouse.y)
  var hit = -1
  for i in countdown(song.placements.high, 0):
    let p = song.placements[i]
    if p.lane == lane and t >= p.start and t < p.start + p.len:
      hit = i
      break
  let onR = hit >= 0 and
    tickX(float(song.placements[hit].start + song.placements[hit].len)) - mouse.x < EdgeW
  let onL = hit >= 0 and not onR and
    mouse.x - tickX(song.placements[hit].start.float) < EdgeW
  if hovered and (onL or onR or pdrag in {PTrimL, PTrimR}):
    igSetMouseCursor(ImGuiMouseCursor.ResizeEW)

  if hovered and igIsMouseClicked(ImGuiMouseButton.Left):
    if hit < 0 and songTool == Draw:
      for q in song.placements.mitems:
        q.sel = false
      var p = Placement(
        clip: song.clip, lane: lane, start: snapDown(t, grid),
        len: song.clips[song.clip].loopEnd,
      )
      for q in song.placements: # no longer than the gap before the next one
        if q.lane == lane and q.start >= p.start:
          p.len = min(p.len, q.start - p.start)
      if fits(-1, p):
        song.placements.add p
        pIdx = song.placements.high # keep dragging it, as a new note in the roll
        pSel = pIdx
        pGrab = t - p.start
        pdrag = PMove
    elif hit >= 0:
      if song.placements[hit].clip != song.clip:
        focus(song.placements[hit].clip, -1)
      pIdx = hit
      pSel = hit
      pGrab = t - song.placements[hit].start
      pdrag = if onR: PTrimR elif onL: PTrimL else: PMove
      if songTool == Select and not song.placements[hit].sel: # a selected one keeps the group
        if not io.keyShift:
          for q in song.placements.mitems:
            q.sel = false
        song.placements[hit].sel = true
    else:
      pdrag = PBox
      pBoxA = v2(mouse.x - gridX + songScrollX, mouse.y - laneTop + songScrollY)
    if pdrag in {PMove, PTrimL, PTrimR}:
      pOrig = song.placements
  # the box in screen space; touched placements get selected on release
  let (bx0, bx1) = (min(pBoxA.x + gridX - songScrollX, mouse.x), max(pBoxA.x + gridX - songScrollX, mouse.x))
  let (by0, by1) = (min(pBoxA.y + laneTop - songScrollY, mouse.y), max(pBoxA.y + laneTop - songScrollY, mouse.y))
  proc moving(i: int): bool =
    ## Dragged with the mouse: the grabbed placement, or its whole selection. A left trim is the grabbed one only.
    pdrag in {PMove, PTrimL, PTrimR} and
      (if pdrag != PTrimL and song.placements[pIdx].sel: song.placements[i].sel else: i == pIdx)

  if not igIsMouseDown(ImGuiMouseButton.Left):
    if pdrag == PBox:
      for p in song.placements.mitems:
        let touched =
          tickX(p.start.float) <= bx1 and tickX(float(p.start + p.len)) >= bx0 and
          laneY(p.lane) <= by1 and laneY(p.lane) + laneH >= by0
        if touched:
          p.sel = true
        elif not io.keyShift:
          p.sel = false
    elif pdrag != PIdle and pBlocked: # overlapping: it goes back where it was
      song.placements = pOrig
    pdrag = PIdle
    pBlocked = false
  case pdrag
  of PMove, PTrimL, PTrimR:
    # from where the drag began, so nothing sticks to an overlap passed on the way
    let a = pOrig[pIdx]
    var ds, dn = 0 # ticks and lanes moved by
    case pdrag
    of PMove: # the group stops at the edges, keeping its shape
      ds = snap(t - pGrab, grid) - a.start
      dn = lane - a.lane
      for i, q in pOrig:
        if moving(i):
          ds = max(ds, -q.start)
          dn = clamp(dn, -q.lane, Lanes - 1 - q.lane)
    of PTrimR: # all change length by the same ticks
      ds = snap(t, grid) - a.start - a.len
      for i, q in pOrig:
        if moving(i):
          ds = max(ds, grid - q.len)
    of PTrimL: # the clip stays put under the cursor: its start moves with the edge
      ds = max(-a.start, min(snap(t, grid) - a.start, a.len - grid))
    else:
      discard
    for i, q in pOrig:
      if moving(i):
        var p = q
        case pdrag
        of PMove:
          p.start += ds
          p.lane += dn
        of PTrimR:
          p.len += ds
        else:
          p.start += ds
          p.len -= ds
          p.offset = floorMod(p.offset + ds, song.clips[p.clip].loopEnd)
        song.placements[i] = p
    pBlocked = false
    for i, p in song.placements:
      if not fits(i, p):
        pBlocked = true
  of PBox:
    discard
  of PIdle:
    if fired("Song", Delete, ImGuiKey.Delete, ctrl = false):
      song.placements.keepItIf(not it.sel)
      pSel = -1
    elif songTool == Draw and hovered and igIsMouseClicked(ImGuiMouseButton.Right) and hit >= 0:
      song.placements.delete hit
      if pSel == hit:
        pSel = -1
      elif pSel > hit:
        dec pSel

  # --- drawing ---
  dl.pushClipRect(v2(origin.x, laneTop), v2(gridX, bottom), true)
  for l in 0 ..< Lanes:
    dl.addRectFilled(v2(origin.x, laneY(l)), v2(gridX - 1, laneY(l) + laneH - 1), rgb(44, 46, 52))
  dl.popClipRect()
  dl.pushClipRect(v2(gridX, origin.y), v2(right, bottom), true)
  for l in 0 ..< Lanes:
    dl.addRectFilled(
      v2(gridX, laneY(l)),
      v2(right, laneY(l) + laneH),
      if l mod 2 == 0: rgb(52, 56, 62) else: rgb(46, 50, 56),
    )
  dl.addRectFilled(v2(gridX, origin.y), v2(right, laneTop), rgb(30, 30, 30)) # over the rows scrolled up
  let step = if Snaps[snapIdx][2]: Ppq div 3 else: Ppq
  var gt = xTick(gridX).snapDown(step)
  while gt <= xTick(right):
    let x = tickX(gt.float)
    dl.addLine(
      v2(x, laneTop),
      v2(x, bottom),
      if gt mod BarTicks == 0: rgb(20, 20, 20) elif gt mod Ppq == 0: rgb(38, 40, 44) else: rgb(46, 48, 52),
    )
    if gt mod BarTicks == 0:
      dl.addText(v2(x + 3, origin.y + 1), rgb(200, 200, 200), cstring($(gt div BarTicks + 1)))
    gt += step
  dl.popClipRect()

  dl.pushClipRect(v2(gridX, laneTop), v2(right, bottom), true)
  for i, p in song.placements:
    let (x0, x1, y) = (tickX(p.start.float), tickX(float(p.start + p.len)), laneY(p.lane))
    dl.addRectFilled(
      v2(x0, y + 1), v2(x1, y + laneH - 2),
      if pBlocked and moving(i): rgb(200, 50, 50)
      else: rgb(70 + p.clip * 67 mod 100, 100 + p.clip * 131 mod 90, 150 + p.clip * 43 mod 80),
      2,
    )
    dl.addRect(
      v2(x0, y + 1), v2(x1, y + laneH - 2),
      if i == pSel or p.sel: rgb(255, 255, 255) else: rgb(10, 10, 10), 2,
    )
    let loop = song.clips[p.clip].loopEnd
    dl.pushClipRect(v2(x0, y), v2(x1, y + laneH), true)
    var (lo, hi) = (127, 0) # pitch range of the clip, spread over the box height
    for t in song.clips[p.clip].tracks:
      for n in t.notes:
        lo = min(lo, n.pitch)
        hi = max(hi, n.pitch)
    let hh = igGetTextLineHeight() + 2 # title header
    dl.addRectFilled(v2(x0, y + 1), v2(x1, y + 1 + hh), rgb(0, 0, 0, 70), 2)
    let (top, body) = (y + 1 + hh + 1, laneH - 3 - hh - 2) # the rest of the box
    let nh = max(1f32, body / float32(hi - lo + 1)) # ponytail: no cap, a one-pitch clip fills the body
    var base = p.start - p.offset # where the clip starts, repeating every `loop`
    while body >= 2 and base < p.start + p.len:
      for t in song.clips[p.clip].tracks:
        for n in t.notes:
          let ny = top + (body - nh) * float32(hi - n.pitch) / max(1, hi - lo).float32
          dl.addRectFilled(
            v2(tickX(float(base + n.start)), ny),
            v2(max(tickX(float(base + n.start + n.len)), tickX(float(base + n.start)) + 1), ny + nh),
            rgb(255, 255, 255, 200),
          )
      base += loop
    dl.addText(v2(x0 + 4, y + 2), rgb(255, 255, 255), cstring(clipLabel(p.clip)))
    dl.popClipRect()
    var m = p.start + loop - p.offset # where the clip starts over
    while m < p.start + p.len:
      dl.addLine(v2(tickX(m.float), y + 1), v2(tickX(m.float), y + laneH - 2), rgb(255, 255, 255), 2)
      m += loop
  if pdrag == PBox:
    dl.addRectFilled(v2(bx0, by0), v2(bx1, by1), rgb(66, 150, 250, 50))
    dl.addRect(v2(bx0, by0), v2(bx1, by1), rgb(66, 150, 250))
  dl.popClipRect()
  dl.pushClipRect(v2(gridX, origin.y), v2(right, bottom), true)
  dl.addLine(v2(tickX(songPos()), origin.y), v2(tickX(songPos()), bottom), rgb(255, 255, 255, if song.songMode: 180 else: 80))
  dl.popClipRect()

  # lane numbers and mute/solo, after the backgrounds
  if laneH >= 22: # smaller rows would overlap
    igPushClipRect(v2(origin.x, laneTop), v2(gridX, bottom), true)
    for l in 0 ..< Lanes:
      let y = laneY(l)
      if y + laneH < laneTop or y > bottom:
        continue
      igSetCursorScreenPos(v2(origin.x + 4, y + (laneH - igGetFrameHeight()) / 2))
      igPushID(int32(l))
      igText("%s", cstring($(l + 1)))
      igSameLine()
      discard igCheckbox("M", addr song.laneMute[l])
      igSameLine()
      discard igCheckbox("S", addr song.laneSolo[l])
      igPopID()
    igPopClipRect()

type Snap = object ## what undo restores; selection and mute/solo cleared, so they don't count as edits
  clips: seq[Clip]
  placements: seq[Placement]

var
  undoStack, redoStack: seq[Snap]
  last: Snap # the state at the last commit

proc `==`(a, b: Snap): bool =
  a.clips == b.clips and a.placements == b.placements

proc capture(): Snap =
  # ponytail: copies the whole song every idle frame; diff or dirty flag if big songs lag
  result = Snap(clips: song.clips, placements: song.placements)
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

proc restore(s: Snap) =
  let old = song.clips[song.clip].tracks
  song.clips = s.clips
  song.placements = s.placements
  song.clip = min(song.clip, song.clips.high)
  for i in 0 ..< min(old.len, song.clips[song.clip].tracks.len): # mute/solo aren't undone
    song.clips[song.clip].tracks[i].mute = old[i].mute
    song.clips[song.clip].tracks[i].solo = old[i].solo
  if focusTrack >= song.clips[song.clip].tracks.len:
    focusTrack = -1
  pSel = -1

proc history() =
  ## Once no mouse button or text field is busy: an edit since the last commit becomes an undo step; then handle undo/redo.
  let io = igGetIO()
  if igIsMouseDown(ImGuiMouseButton.Left) or igIsMouseDown(ImGuiMouseButton.Right) or io.wantTextInput:
    return
  let now = capture()
  if now != last:
    undoStack.add last
    redoStack.setLen 0
    last = now
  let z = io.keyCtrl and igIsKeyPressed(ImGuiKey.Z, false)
  let redo = menuCmd == Redo or (io.keyCtrl and igIsKeyPressed(ImGuiKey.Y, false)) or (z and io.keyShift)
  let undo = menuCmd == Undo or (z and not io.keyShift)
  if redo and redoStack.len > 0:
    undoStack.add last
    last = redoStack.pop
    restore last
  elif undo and undoStack.len > 0:
    redoStack.add last
    last = undoStack.pop
    restore last

type After = enum ## what to do once unsaved changes are dealt with
  Nothing
  NewSong
  OpenSong
  ExitApp

var
  smmPath: string # "" = never saved
  saved: Snap # the state at the last save, load or new
  savedBpm: float
  after: After
  openPrompt, openErr: bool # popups are opened at the top level, not from inside a menu
  fileErr: string

proc dirty(): bool =
  capture() != saved or song.bpm != savedBpm

proc apply(s: Song) =
  ## `s` becomes the song, with a fresh undo history.
  song.clips = s.clips
  song.placements = s.placements
  song.bpm = s.bpm
  song.clip = 0
  song.playing = false
  song.pos = 0
  song.idlePos = 0
  placeClip.setLen 0
  pSel = -1
  focusTrack = -1 # the old index may not exist in `s`; focus() reads cur()
  focus(0, -1)
  undoStack.setLen 0
  redoStack.setLen 0
  last = capture()
  saved = last
  savedBpm = s.bpm

proc fail(e: ref CatchableError) =
  fileErr = e.msg
  openErr = true

proc load(path: string) =
  try:
    apply fromSmm(readFile(path))
    smmPath = path
  except CatchableError as e:
    fail e

proc write(path: string): bool =
  try:
    writeFile(path, toSmm(song))
    smmPath = path
    saved = capture()
    savedBpm = song.bpm
    result = true
  except CatchableError as e:
    fail e

proc proceed() =
  let a = after
  after = Nothing
  case a
  of NewSong:
    apply Song(bpm: 120, clips: @[Clip()])
    smmPath = ""
  of OpenSong:
    fbOpen(0)
  of ExitApp:
    gui.requestClose()
  of Nothing:
    discard

proc ask(a: After) =
  ## Do `a`, after asking about unsaved changes.
  after = a
  if dirty():
    openPrompt = true
  else:
    proceed()

proc fileDialogs() =
  ## Top level, every frame: the popups and the file browsers.
  if openPrompt:
    igOpenPopup("Save changes?")
    openPrompt = false
  if openErr:
    igOpenPopup("File error")
    openErr = false
  if igBeginPopupModal("Save changes?", nil, ImGuiWindowFlags.AlwaysAutoResize):
    igText("The song has unsaved changes.")
    if igButton("Save"):
      igCloseCurrentPopup()
      if smmPath == "":
        fbOpen(1) # `after` happens once the name is picked
      elif write(smmPath):
        proceed()
    igSameLine()
    if igButton("Don't save"):
      igCloseCurrentPopup()
      proceed()
    igSameLine()
    if igButton("Cancel"):
      igCloseCurrentPopup()
      after = Nothing
    igEndPopup()
  if igBeginPopupModal("File error", nil, ImGuiWindowFlags.AlwaysAutoResize):
    igText("%s", cstring(fileErr))
    if igButton("OK"):
      igCloseCurrentPopup()
    igEndPopup()
  let opened = fbPick(0)
  if opened != nil:
    load $opened
  let named = fbPick(1)
  if named != nil:
    var path = $named
    if not path.endsWith ".smm":
      path &= ".smm"
    if write(path):
      proceed()
  let exported = fbPick(2)
  if exported != nil:
    var path = $exported
    if not path.endsWith ".mid":
      path &= ".mid"
    try:
      writeFile(path, song.toMidi)
    except CatchableError as e:
      fail e

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
        ask ExitApp
      igEndMenu()
    if igBeginMenu("Edit"): # acts on the piano roll or song window, whichever you used last
      for (c, name, keys) in [
        (Undo, "Undo", "Ctrl+Z"),
        (Redo, "Redo", "Ctrl+Shift+Z"),
        (SelectAll, "Select all / none", "Ctrl+A"),
        (Duplicate, "Duplicate", "Ctrl+D"),
        (Copy, "Copy", "Ctrl+C"),
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
      if igCheckbox("Piano roll", addr togglePianoRoll):
        discard
      if igCheckbox("Clips", addr toggleClips):
        discard
      if igCheckbox("Song", addr toggleSong):
        discard
      igEndMenu()
    igEndMainMenuBar()
  if hNew:
    ask NewSong
  if hOpen:
    ask OpenSong
  if hSave:
    if smmPath == "":
      after = Nothing
      fbOpen(1)
    else:
      discard write(smmPath)
  if hSaveAs:
    after = Nothing
    fbOpen(1)
  if hExport:
    fbOpen(2)
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
  if togglePianoRoll:
    if igBegin("Piano roll"):
      igBeginDisabled(focusTrack < 0)
      pianoRoll()
      igEndDisabled()
    igEnd()
  if toggleClips:
    if igBegin("Clips"):
      clips()
    igEnd()
  if toggleSong:
    # the lane widgets overhang the pane at the edges; scrolling is ours
    if igBegin("Song", nil, ImGuiWindowFlags.NoScrollbar or ImGuiWindowFlags.NoScrollWithMouse):
      songPlaylist()
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
  synth = slopgs.open(dlsPath)
  previewSynth = slopgs.open(dlsPath)
  pcm = alsa.open(Rate, LatencyUs)
  initLock(lock)
  last = capture()
  saved = last
  savedBpm = song.bpm
  createThread(audio, audioLoop)
  gui.open("slopmid", 1280, 800)
  while gui.running():
    gui.beginFrame()
    withLock lock:
      ui()
    gui.endFrame()

main()
