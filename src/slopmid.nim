## Sheet: left-click adds a note or drags it, its right end resizes it,
## right-click deletes. Note names: click to audition. Velocity lane: drag.
## Wheel scrolls pitch, Shift+wheel scrolls time. Space plays/pauses.

import std/[locks, os, strformat]
import imgui
import wrap/[alsa, gui, slopgs]
import roll

const
  KeyW = 56f32 # note-name column
  RulerH = 18f32
  KeyH = 14f32 # one pitch row
  BeatW = 64f32
  EdgeW = 6f32 # grab zone at a note's right end for resizing
  NewVel = 100
  Snaps = [
    ("Bar", BarTicks),
    ("1/2", Ppq * 2),
    ("1/4", Ppq),
    ("1/8", Ppq div 2),
    ("1/16", Ppq div 4),
    ("1/32", Ppq div 8),
    ("None", 1),
  ]
  Names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
  # a block and a half, as in slopgs's alsa-synth.c
  LatencyUs = 3 * 1_000_000 * BlockFrames div Rate div 2

# --- shared with the audio thread, under `lock` ---
var
  lock: Lock
  song = Song(bpm: 120)
  live: seq[(int, int, int)] # key previews, played at the next block's top
  pcm: Pcm
  audio: Thread[void]

proc audioLoop() {.thread.} =
  var buf: Block
  while true:
    {.cast(gcsafe).}:
      withLock(lock):
        for (status, d1, d2) in live:
          slopgs.midi(0, status, d1, d2)
        live.setLen(0)
        for e in song.advance(BlockFrames, Rate):
          slopgs.midi(e.offset, (if e.on: 0x90 else: 0x80), e.pitch, e.vel)
        slopgs.render(buf)
      pcm.write(buf)

# --- UI state, UI thread only ---
type Drag = enum
  Idle
  Move
  Resize

var
  snapIdx = 4 # 1/16
  lastLen = Ppq
  scrollX = 0f32
  scrollY = float32(127 - 84) * KeyH # C6 at the top
  drag = Idle
  dragNote, grabTicks: int
  previewKey = -1

proc rgb(r, g, b: int, a = 255): uint32 =
  uint32(r) or uint32(g) shl 8 or uint32(b) shl 16 or uint32(a) shl 24

proc v2(x, y: float32): ImVec2 =
  ImVec2(x: x, y: y)

proc noteName(p: int): string =
  Names[p mod 12] & $(p div 12 - 1)

proc transport() =
  let io = igGetIO()
  if igButton(if song.playing: "Pause" else: "Play", v2(60, 0)) or
      (igIsKeyPressed(ImGuiKey.Space, false) and not io.wantTextInput):
    song.playing = not song.playing
  igSameLine()
  if igButton("Stop", v2(60, 0)):
    song.playing = false
    song.pos = 0
  igSameLine()
  igSetNextItemWidth(110)
  var bpm = song.bpm.float32
  if igInputFloat("BPM", bpm.addr, 1, 10, "%.1f"):
    song.bpm = clamp(bpm, 20, 999)
  igSameLine()
  igSetNextItemWidth(70)
  if igBeginCombo("Snap", cstring(Snaps[snapIdx][0])):
    for i, (name, _) in Snaps:
      if igSelectable(cstring(name), i == snapIdx):
        snapIdx = i
    igEndCombo()
  igSameLine(0, 24)
  let t = song.pos.int
  igText(
    "%s", cstring(&"{t div BarTicks + 1}:{t mod BarTicks div Ppq + 1}:{t mod Ppq:02}")
  )

proc pianoRoll() =
  let io = igGetIO()
  let dl = igGetWindowDrawList()
  let origin = igGetCursorScreenPosNonUDT()
  let avail = igGetContentRegionAvailNonUDT()
  let
    gridX = origin.x + KeyW
    right = origin.x + avail.x
    gridW = avail.x - KeyW
    paneH = (avail.y - RulerH) / 2 # sheet on top, velocity below, in half
    sheetTop = origin.y + RulerH
    velTop = sheetTop + paneH
    bottom = velTop + paneH
    grid = Snaps[snapIdx][1]
    mouse = v2(io.mousePos.x, io.mousePos.y) # imgui's ImVec2 is not cimgui's

  scrollY = clamp(scrollY, 0, max(0, 128 * KeyH - paneH))
  scrollX = max(scrollX, 0)
  proc tickX(t: float): float32 =
    gridX + float32(t / Ppq.float) * BeatW - scrollX

  # clamp before int(): imgui parks an absent mouse at -FLT_MAX
  proc xTick(x: float32): int =
    int(max(0, (x - gridX + scrollX) / BeatW * Ppq.float32))

  proc pitchY(p: int): float32 =
    sheetTop + float32(127 - p) * KeyH - scrollY

  proc yPitch(y: float32): int =
    127 - int(clamp((y - sheetTop + scrollY) / KeyH, 0, 127))

  # --- input ---
  igSetCursorScreenPos(v2(origin.x, sheetTop))
  discard igInvisibleButton("keys", v2(KeyW, paneH))
  let keysHeld = igIsItemActive()
  let keysHovered = igIsItemHovered()
  igSetCursorScreenPos(v2(gridX, sheetTop))
  discard igInvisibleButton(
    "sheet",
    v2(gridW, paneH),
    ImGuiButtonFlags.MouseButtonLeft or ImGuiButtonFlags.MouseButtonRight,
  )
  let sheetHovered = igIsItemHovered()
  igSetCursorScreenPos(v2(gridX, velTop))
  discard igInvisibleButton("vel", v2(gridW, paneH))
  let velHeld = igIsItemActive()

  if keysHovered or sheetHovered or igIsItemHovered():
    if io.keyShift:
      scrollX -= io.mouseWheel * BeatW
    else:
      scrollY -= io.mouseWheel * KeyH * 3
    scrollX -= io.mouseWheelH * BeatW

  # clicking a key plays it; dragging across keys glides
  let key =
    if keysHeld:
      yPitch(mouse.y)
    else:
      -1
  if key != previewKey:
    if previewKey >= 0:
      live.add (0x80, previewKey, 0)
    if key >= 0:
      live.add (0x90, key, NewVel)
    previewKey = key

  let t = xTick(mouse.x)
  let p = yPitch(mouse.y)
  var hit = -1
  for i in countdown(song.notes.high, 0):
    let n = song.notes[i]
    if n.pitch == p and t >= n.start and t < n.start + n.len:
      hit = i
      break
  let onEdge =
    hit >= 0 and
    tickX(float(song.notes[hit].start + song.notes[hit].len)) - mouse.x < EdgeW
  if sheetHovered and (onEdge or drag == Resize):
    igSetMouseCursor(ImGuiMouseCursor.ResizeEW)

  if sheetHovered and igIsMouseClicked(ImGuiMouseButton.Left):
    if hit < 0:
      song.notes.add Note(
        start: max(0, snapDown(t, grid)), len: lastLen, pitch: p, vel: NewVel
      )
      hit = song.notes.high
    dragNote = hit
    drag = if onEdge: Resize else: Move
    grabTicks = t - song.notes[hit].start
    lastLen = song.notes[hit].len
  if not igIsMouseDown(ImGuiMouseButton.Left):
    drag = Idle
  case drag
  of Move:
    song.notes[dragNote].start = max(0, snap(t - grabTicks, grid))
    song.notes[dragNote].pitch = p
  of Resize:
    let n = song.notes[dragNote]
    song.notes[dragNote].len = max(grid, snap(t, grid) - n.start)
    lastLen = song.notes[dragNote].len
  of Idle:
    if sheetHovered and igIsMouseDown(ImGuiMouseButton.Right) and hit >= 0:
      song.notes.delete hit

  # dragging in the velocity lane sets the notes whose bar is under the mouse
  if velHeld:
    let v = clamp(int((bottom - mouse.y) / paneH * 127), 1, 127)
    for n in song.notes.mitems:
      if abs(tickX(n.start.float) - mouse.x) <= 4:
        n.vel = v

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
    dl.addRectFilled(v2(origin.x, y), v2(gridX - 1, y + KeyH - 1), col)
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
      v2(right, y + KeyH),
      if Names[q mod 12].len == 2:
        rgb(40, 44, 50)
      else:
        rgb(52, 56, 62),
    )
  dl.popClipRect()
  dl.pushClipRect(v2(gridX, origin.y), v2(right, bottom), true)
  dl.addRectFilled(v2(gridX, origin.y), v2(right, sheetTop), rgb(30, 30, 30))
  dl.addRectFilled(v2(gridX, velTop), v2(right, bottom), rgb(34, 36, 40))
  let step = Ppq div 4
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
  dl.addLine(v2(gridX, velTop), v2(right, velTop), rgb(90, 90, 90), 2)
  let le = tickX(song.loopEnd.float)
  dl.addLine(v2(le, origin.y), v2(le, sheetTop), rgb(200, 120, 60), 3)

  # notes, then their velocities
  dl.pushClipRect(v2(gridX, sheetTop), v2(right, velTop), true)
  for n in song.notes:
    let (x0, x1, y) =
      (tickX(n.start.float), tickX(float(n.start + n.len)), pitchY(n.pitch))
    let shade = 90 + n.vel
    dl.addRectFilled(
      v2(x0, y + 1), v2(x1, y + KeyH - 1), rgb(shade div 2, shade, shade div 2), 2
    )
    dl.addRect(v2(x0, y + 1), v2(x1, y + KeyH - 1), rgb(10, 30, 10), 2)
  dl.popClipRect()
  for n in song.notes:
    let x0 = tickX(n.start.float)
    let vy = bottom - float32(n.vel) / 127 * paneH
    dl.addLine(v2(x0, bottom), v2(x0, vy), rgb(110, 210, 110), 2)
    dl.addCircleFilled(v2(x0, vy), 4, rgb(110, 210, 110))

  let px = tickX(song.pos)
  dl.addLine(v2(px, origin.y), v2(px, bottom), rgb(255, 255, 255, 180))
  dl.popClipRect()

var togglePianoRoll = true

proc ui() =
  let vp = igGetMainViewport()
  igSetNextWindowPos(v2(vp.workPos.x, vp.workPos.y))
  igSetNextWindowSize(v2(vp.workSize.x, vp.workSize.y))
  if igBegin(
    "slopmid",
    nil,
    ImGuiWindowFlags.NoDecoration or ImGuiWindowFlags.NoMove or
      ImGuiWindowFlags.NoSavedSettings or ImGuiWindowFlags.NoScrollWithMouse,
  ):
    if igBeginMainMenuBar():
      if igBeginMenu("Window"):
        if igCheckbox("Piano roll", addr togglePianoRoll):
          discard
        igEndMenu()
      igEndMainMenuBar()
    transport()
    if togglePianoRoll:
      if igBegin("Piano roll"):
        pianoRoll()
      igEnd()
  igEnd()

proc main() =
  slopgs.init(
    if paramCount() >= 1:
      paramStr(1)
    else:
      getAppDir() / "deps/slopgs/dist/gm.dls"
  )
  slopgs.midi(0, 0xC0, 0, 0) # program 0, Acoustic Grand Piano
  pcm = alsa.open(Rate, LatencyUs)
  initLock(lock)
  createThread(audio, audioLoop)
  gui.open("slopmid", 1280, 800)
  while gui.running():
    gui.beginFrame()
    withLock lock:
      ui()
    gui.endFrame()

main()
