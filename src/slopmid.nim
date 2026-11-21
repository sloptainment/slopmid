## Sheet: left-click adds a note or drags it, its right end resizes it,
## right-click deletes. Note names: click to audition. Velocity lane: drag.
## Select tool (corner buttons): drag a box to select, drag a selected note to move them all, Delete removes them; Ctrl+A selects all.
## Wheel scrolls pitch, Shift+wheel scrolls time, middle-drag pans, Ctrl+middle-drag zooms. Space plays/pauses.

import std/[locks, math, os, sequtils, strformat]
import imgui
import wrap/[alsa, gui, slopgs]
import roll, gm

const
  KeyW = 56f32 # note-name column
  RulerH = 18f32
  SbW = 12f32 # scrollbar thickness
  HdrW = 108f32 # lane numbers and mute/solo in the song window
  EdgeW = 6f32 # grab zone at a note's right end for resizing
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
  ClickHz = 1000.0
  ClickDownHz = 1500.0 # the first beat of a bar
  ClickLen = 1000 # samples
  ClickAmp = 8000.0 # of 32767
  # a block and a half, as in slopgs's alsa-synth.c
  LatencyUs = 3 * 1_000_000 * BlockFrames div Rate div 2

# --- shared with the audio thread, under `lock` ---
var
  lock: Lock
  song = Song(bpm: 120, clips: newSeq[seq[Track]](1))
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

type PDrag = enum ## dragging a placement in the song window
  PIdle
  PMove
  PTrimL
  PTrimR

type ScrollGrab = enum
  GrabBody
  GrabLo
  GrabHi

var
  snapIdx = 4 # 1/16
  lastLen = Ppq
  lastVel = 100 # velocity of the last clicked or dragged note
  beatW = 64f32 # zoom: pixels per beat
  keyH = 14f32 # zoom: pixels per pitch row
  scrollX = 0f32
  scrollY = float32(127 - 84) * keyH # C6 at the top
  velFrac = 0.25f32 # share of the sheet+velocity height taken by the velocity lane
  sbGrab: ScrollGrab
  sbOff: float32
  drag = Idle
  tool = Draw
  boxA: ImVec2 # where the selection box started, relative to the scrolled sheet
  dragNote, grabTicks: int
  previewKey = -1
  focusTrack = -1 # in clip song.clip; -1 = none
  noTrack: Track # stands in for the focused track while there is none
  clipNames = @[""] # parallel to song.clips; "" shows as "Clip N"
  songBeatW = 16f32 # the song window's zoom and scroll, like the roll's
  laneH = 28f32
  songScrollX = 0f32
  songScrollY = 0f32
  pdrag = PIdle
  pIdx, pGrab: int
  pSel = -1 # the clicked placement, drawn with a white border

proc cur(): var Track =
  if focusTrack >= 0:
    result = song.clips[song.clip][focusTrack]
  else:
    result = noTrack

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
    song.playing = (song.songMode or focusTrack >= 0) and not song.playing
  igSameLine()
  if igButton("Stop", v2(60, 0)) and (song.songMode or focusTrack >= 0):
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
    for i, (name, _) in Snaps:
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
      song.pos = 0
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
      hi = clamp(mouse, lo + SbW, len)
      zoom = len / ((hi - lo) / k)
      scroll = lo / k * zoom
    zoom = clamp(zoom, k, maxZoom)
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
      v2(at.x + SbW, at.y + hi)
    else:
      v2(at.x + hi, at.y + SbW)
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

proc pianoRoll() =
  let io = igGetIO()
  let dl = igGetWindowDrawList()
  let origin = igGetCursorScreenPosNonUDT()
  let avail = igGetContentRegionAvailNonUDT()
  let
    gridX = origin.x + KeyW
    gridW = avail.x - KeyW - SbW
    right = gridX + gridW
    bothH = avail.y - RulerH - SbW # sheet on top, velocity below
    velH = bothH * velFrac
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
  discard igInvisibleButton("split", v2(avail.x - SbW, 16))
  let splitHot = igIsItemHovered() or igIsItemActive()
  if splitHot:
    igSetMouseCursor(ImGuiMouseCursor.ResizeNS)
  if igIsItemActive():
    velFrac = clamp((bottom - io.mousePos.y) / bothH, 0.1, 0.9)

  # tool buttons in the corner above the note names
  for (i, t) in [(0, Draw), (1, Select)]:
    let a = v2(origin.x + i.float32 * KeyW / 2, origin.y)
    igSetCursorScreenPos(a)
    if igInvisibleButton(cstring($t), v2(KeyW / 2, RulerH)):
      tool = t
    if igIsItemHovered():
      igSetTooltip("%s", cstring($t))
    let c = v2(a.x + KeyW / 4, a.y + RulerH / 2)
    let col = if tool == t: rgb(255, 255, 255) else: rgb(130, 130, 140)
    if tool == t:
      dl.addRectFilled(a, v2(a.x + KeyW / 2, a.y + RulerH), rgb(66, 150, 250), 2)
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

  if igIsWindowFocused() and io.keyCtrl and igIsKeyPressed(ImGuiKey.A, false) and not io.wantTextInput:
    for n in cur().notes.mitems:
      n.sel = true
  if igIsWindowFocused() and io.keyCtrl and igIsKeyPressed(ImGuiKey.D, false) and not io.wantTextInput:
    for n in cur().notes.mitems:
      n.sel = false
  if igIsWindowFocused() and (io.keyCtrl or io.keyShift) and not io.wantTextInput:
    let up = igIsKeyPressed(ImGuiKey.UpArrow, true)
    if up or igIsKeyPressed(ImGuiKey.DownArrow, true):
      let anySel = cur().notes.anyIt(it.sel)
      var d = (if io.keyCtrl: 12 else: 1) * (if up: 1 else: -1)
      for n in cur().notes: # the whole group stops at the edge, keeping its shape
        if n.sel or not anySel:
          d = clamp(d, -n.pitch, 127 - n.pitch)
      for n in cur().notes.mitems:
        if n.sel or not anySel:
          n.pitch += d

  # click or drag on the ruler moves the playhead
  igSetCursorScreenPos(v2(gridX, origin.y))
  discard igInvisibleButton("ruler", v2(gridW, RulerH))
  if igIsItemActive() and not song.songMode:
    song.pos = xTick(mouse.x).float

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
      beatW = clamp(beatW * exp(io.mouseDelta.x * 0.01), gridW / beats, 256)
      keyH = clamp(keyH * exp(-io.mouseDelta.y * 0.01), paneH / 128, 40)
      scrollX = u * beatW - (mouse.x - gridX)
      scrollY = v * keyH - (mouse.y - sheetTop)
    else:
      scrollX -= io.mouseDelta.x
      scrollY -= io.mouseDelta.y
  # clamp after the input above, or the frame draws past the edge
  scrollY = clamp(scrollY, 0, max(0, 128 * keyH - paneH))
  scrollX = max(scrollX, 0)
  scrollbar("scrollX", false, v2(gridX, bottom), gridW, scrollX, beatW, beats, 256)
  scrollbar("scrollY", true, v2(right, sheetTop), paneH, scrollY, keyH, 128, 40)

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
  if sheetHovered and (onEdge or drag == Resize):
    igSetMouseCursor(ImGuiMouseCursor.ResizeEW)

  if sheetHovered and igIsMouseClicked(ImGuiMouseButton.Left):
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
    if igIsWindowFocused() and igIsKeyPressed(ImGuiKey.Delete, false) and not io.wantTextInput:
      cur().notes.keepItIf(not it.sel)
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

  # dragging in the velocity lane sets the notes whose bar is under the mouse
  if velHeld:
    let v = clamp(int((bottom - mouse.y) / velH * 127), 1, 127)
    for n in cur().notes.mitems:
      if abs(tickX(n.start.float) - mouse.x) <= 4:
        n.vel = v
        lastVel = v

  # tooltip: the value being dragged, else the velocity of the bar under the mouse
  if velHeld or velHovered:
    var shown = if velHeld: clamp(int((bottom - mouse.y) / velH * 127), 1, 127) else: 0
    if not velHeld:
      for n in cur().notes:
        if abs(tickX(n.start.float) - mouse.x) <= 4:
          shown = n.vel
          break
    if shown > 0:
      igSetTooltip("%s", cstring(fmt"{shown} - {int(round(shown / 127 * 100))}%"))

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
  if drag == Box:
    dl.addRectFilled(v2(bx0, by0), v2(bx1, by1), rgb(66, 150, 250, 50))
    dl.addRect(v2(bx0, by0), v2(bx1, by1), rgb(66, 150, 250))
  dl.popClipRect()
  for n in cur().notes:
    let x0 = tickX(n.start.float)
    let vy = bottom - float32(n.vel) / 127 * velH
    dl.addLine(v2(x0, bottom), v2(x0, vy), rgb(110, 210, 110), 2)
    dl.addCircleFilled(v2(x0, vy), 4, rgb(110, 210, 110))

  if song.songMode: # a line for each placement of this clip that is playing
    for p in song.placements:
      let c = p.clipTime(song.clips[p.clip].loopEnd, song.pos)
      if p.clip == song.clip and c >= 0:
        dl.addLine(v2(tickX(c), origin.y), v2(tickX(c), bottom), rgb(255, 255, 255, 180))
  else:
    let px = tickX(song.pos)
    dl.addLine(v2(px, origin.y), v2(px, bottom), rgb(255, 255, 255, 180))
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
  if clip != song.clip:
    pSel = -1
    for t in song.clips[song.clip].mitems:
      t.mute = false
      t.solo = false
  song.clip = clip
  focusTrack = track
  if not song.songMode: # the song plays on through clip changes
    song.playing = false
    song.pos = 0

proc clipLabel(i: int): string =
  if clipNames[i] == "": &"Clip {i + 1}" else: clipNames[i]

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
    song.clips.add newSeq[Track]()
    clipNames.add ""
    focus(song.clips.high, -1)
  igSameLine()
  if igButton("Remove") and song.clips.len > 1:
    let gone = song.clip
    focus(gone, -1)
    song.clips.delete gone
    clipNames.delete gone
    song.placements.keepItIf(it.clip != gone)
    pSel = -1
    for p in song.placements.mitems:
      if p.clip > gone:
        dec p.clip
    song.clip = min(gone, song.clips.high)
  igSameLine()
  igText("Clip name: ")
  igSameLine()
  igSetNextItemWidth(-1)
  var buf: array[64, char]
  copyMem(addr buf[0], cstring(clipNames[song.clip]), min(clipNames[song.clip].len, 63))
  if igInputText("##name", cast[cstring](addr buf[0]), buf.len.uint):
    clipNames[song.clip] = $cast[cstring](addr buf[0])
  igSeparator()
  if igBeginTable("tracks", 4, ImGuiTableFlags.SizingStretchProp):
    igTableSetupColumn("", ImGuiTableColumnFlags.WidthFixed) # "X"
    igTableSetupColumn("", ImGuiTableColumnFlags.WidthFixed) # "M/S"
    igTableSetupColumn("", ImGuiTableColumnFlags.WidthFixed) # name
    igTableSetupColumn("", ImGuiTableColumnFlags.WidthStretch, 1)
    let dl = igGetWindowDrawList()
    let span = song.clips[song.clip].loopEnd.float32
    for i in 0 ..< song.clips[song.clip].len:
      igTableNextRow()
      igPushID(int32(i))
      template t(): untyped =
        song.clips[song.clip][i]

      discard igTableNextColumn()
      if igButton("X"):
        let f = focusTrack - ord(focusTrack > i) # tracks after the gone one shift down
        focus(song.clip, if focusTrack == i: -1 else: f)
        song.clips[song.clip].delete i
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
      igPopID()
    igEndTable()
  if igButton("ADD"):
    song.clips[song.clip].add Track()

proc fits(i: int, p: Placement): bool =
  ## `p` could replace placement `i` (-1: be added): in bounds and clear of its lane's others.
  result = p.len > 0 and p.start >= 0 and p.lane in 0 ..< Lanes
  for j, q in song.placements:
    if j != i and q.lane == p.lane and q.start < p.start + p.len and p.start < q.start + q.len:
      result = false

proc songPlaylist() =
  ## Lanes of placed clips. Click empty space to place the clip chosen in Clips, drag to move,
  ## drag an edge to trim (the left one starts the clip part-way in, the right one past its end
  ## repeats it), right-click removes. Panning and zooming as in the piano roll.
  let io = igGetIO()
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
  if igIsItemActive() and song.songMode:
    song.pos = xTick(mouse.x).float
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
      songBeatW = clamp(songBeatW * exp(io.mouseDelta.x * 0.01), gridW / beats, 256)
      laneH = clamp(laneH * exp(-io.mouseDelta.y * 0.01), paneH / Lanes.float32, 80)
      songScrollX = u * songBeatW - (mouse.x - gridX)
      songScrollY = v * laneH - (mouse.y - laneTop)
    else:
      songScrollX -= io.mouseDelta.x
      songScrollY -= io.mouseDelta.y
  songScrollY = clamp(songScrollY, 0, max(0, Lanes.float32 * laneH - paneH))
  songScrollX = max(songScrollX, 0)
  scrollbar("scrollX", false, v2(gridX, bottom), gridW, songScrollX, songBeatW, beats, 256)
  scrollbar("scrollY", true, v2(right, laneTop), paneH, songScrollY, laneH, Lanes.float32, 80)

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
    if hit < 0:
      var p = Placement(
        clip: song.clip, lane: lane, start: snapDown(t, grid),
        len: song.clips[song.clip].loopEnd,
      )
      for q in song.placements: # no longer than the gap before the next one
        if q.lane == lane and q.start >= p.start:
          p.len = min(p.len, q.start - p.start)
      if fits(-1, p):
        song.placements.add p
    else:
      if song.placements[hit].clip != song.clip:
        focus(song.placements[hit].clip, -1)
      pIdx = hit
      pSel = hit
      pGrab = t - song.placements[hit].start
      pdrag = if onR: PTrimR elif onL: PTrimL else: PMove
  if not igIsMouseDown(ImGuiMouseButton.Left):
    pdrag = PIdle
  if pdrag != PIdle:
    var p = song.placements[pIdx]
    case pdrag
    of PMove:
      p.start = max(0, snap(t - pGrab, grid))
      p.lane = lane
    of PTrimR:
      p.len = max(grid, snap(t, grid) - p.start)
    of PTrimL: # the clip stays put under the cursor: its start moves with the edge
      let d = max(-p.start, min(snap(t, grid) - p.start, p.len - grid))
      p.start += d
      p.len -= d
      p.offset = floorMod(p.offset + d, song.clips[p.clip].loopEnd)
    of PIdle:
      discard
    if fits(pIdx, p):
      song.placements[pIdx] = p
  elif hovered and igIsMouseClicked(ImGuiMouseButton.Right) and hit >= 0:
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
  var gt = xTick(gridX).snapDown(Ppq)
  while gt <= xTick(right):
    let x = tickX(gt.float)
    dl.addLine(
      v2(x, laneTop), v2(x, bottom), if gt mod BarTicks == 0: rgb(20, 20, 20) else: rgb(38, 40, 44)
    )
    if gt mod BarTicks == 0:
      dl.addText(v2(x + 3, origin.y + 1), rgb(200, 200, 200), cstring($(gt div BarTicks + 1)))
    gt += Ppq
  dl.popClipRect()

  dl.pushClipRect(v2(gridX, laneTop), v2(right, bottom), true)
  for i, p in song.placements:
    let (x0, x1, y) = (tickX(p.start.float), tickX(float(p.start + p.len)), laneY(p.lane))
    dl.addRectFilled(
      v2(x0, y + 1), v2(x1, y + laneH - 2),
      rgb(70 + p.clip * 67 mod 100, 100 + p.clip * 131 mod 90, 150 + p.clip * 43 mod 80), 2,
    )
    dl.addRect(
      v2(x0, y + 1), v2(x1, y + laneH - 2),
      if i == pSel: rgb(255, 255, 255) else: rgb(10, 10, 10), 2,
    )
    let loop = song.clips[p.clip].loopEnd
    dl.pushClipRect(v2(x0, y), v2(x1, y + laneH), true)
    var (lo, hi) = (127, 0) # pitch range of the clip, spread over the box height
    for t in song.clips[p.clip]:
      for n in t.notes:
        lo = min(lo, n.pitch)
        hi = max(hi, n.pitch)
    let hh = igGetTextLineHeight() + 2 # title header
    dl.addRectFilled(v2(x0, y + 1), v2(x1, y + 1 + hh), rgb(0, 0, 0, 70), 2)
    let (top, body) = (y + 1 + hh + 1, laneH - 3 - hh - 2) # the rest of the box
    let nh = max(1f32, body / float32(hi - lo + 1)) # ponytail: no cap, a one-pitch clip fills the body
    var base = p.start - p.offset # where the clip starts, repeating every `loop`
    while body >= 2 and base < p.start + p.len:
      for t in song.clips[p.clip]:
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
  dl.popClipRect()
  if song.songMode:
    dl.pushClipRect(v2(gridX, origin.y), v2(right, bottom), true)
    dl.addLine(v2(tickX(song.pos), origin.y), v2(tickX(song.pos), bottom), rgb(255, 255, 255, 180))
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

proc ui() =
  if igBeginMainMenuBar():
    if igBeginMenu("Window"):
      if igCheckbox("Piano roll", addr togglePianoRoll):
        discard
      if igCheckbox("Clips", addr toggleClips):
        discard
      if igCheckbox("Song", addr toggleSong):
        discard
      igEndMenu()
    igEndMainMenuBar()
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
  createThread(audio, audioLoop)
  gui.open("slopmid", 1280, 800)
  while gui.running():
    gui.beginFrame()
    withLock lock:
      ui()
    gui.endFrame()

main()
