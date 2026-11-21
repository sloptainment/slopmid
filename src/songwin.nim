## The Song window: lanes of placed clips.

import std/sequtils
import imgui
import wrap/gui
import model, edit, view, common

type SongState = object ## the song window's UI state, UI thread only
  view: View # row = lane
  tool: Tool
  drag: PDrag
  grabbed, grabOff: int # the placement dragged and where in it (ticks) it was grabbed
  box: Box # the lanes' selection box
  before: seq[Placement] # the placements when the drag began; a blocked drop goes back to them
  blocked: bool # the drag now would overlap placements in a lane

var st = SongState(view: View(beatW: 16, rowH: 28, rows: Lanes, maxRowH: 320))

proc songWindow*() =
  ## Lanes of placed clips. Draw tool: click empty space to place the clip chosen in Clips (drag before releasing to position it),
  ## right-click removes. Select tool: drag a box to select; Delete removes the selection, Ctrl+A selects all, or deselects if anything is selected.
  ## Either tool: drag to move (a selection moves together), drag an edge to trim (the left one starts the clip part-way in,
  ## the right one past its end repeats it, and moves the whole selection's right edges). A drop that would overlap
  ## in a lane draws red and goes back. Panning and zooming as in the piano roll.
  let io = igGetIO()
  if igIsWindowFocused():
    editor = SongEd
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

  st.view.place(gridX, origin.y, gridW, paneH)
  proc tickX(t: float): float32 =
    st.view.tickX(t)

  proc xTick(x: float32): int =
    st.view.xTick(x)

  proc laneY(l: int): float32 =
    st.view.rowY(l)

  proc yLane(y: float32): int =
    st.view.yRow(y)

  # --- input ---
  let rulerTick = st.view.ruler(mouse)
  if rulerTick >= 0:
    song.songPos = rulerTick.float
  igSetCursorScreenPos(v2(gridX, laneTop))
  discard igInvisibleButton(
    "grid",
    v2(gridW, paneH),
    ImGuiButtonFlags.MouseButtonLeft or ImGuiButtonFlags.MouseButtonRight or
      ImGuiButtonFlags.MouseButtonMiddle,
  )
  let hovered = igIsItemHovered()
  let pan = igIsItemActive() and igIsMouseDown(ImGuiMouseButton.Middle)
  let beats = float32(song.songEnd + 16 * BarTicks) / Ppq.float32 # room to add past the end
  st.view.navigate(hovered, pan, mouse, beats)
  st.view.scrollbars(beats, bottom)

  toolButtons(st.tool, origin)
  if fired(SongEd, SelectAll, ImGuiKey.A):
    song.placements.toggleAll
  if fired(SongEd, Copy, ImGuiKey.C):
    let sel = song.placements.filterIt(it.sel)
    if sel.len > 0:
      placeClip = sel
  if fired(SongEd, Paste, ImGuiKey.V) and placeClip.len > 0:
    song.pastePlacements(placeClip, snap(song.songPos.int, grid)) # the group's first clip lands on the playhead
  if fired(SongEd, Quantize, ImGuiKey.Q):
    song.quantizePlacements(grid)

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
  if hovered and (onL or onR or st.drag in {PTrimL, PTrimR}):
    igSetMouseCursor(ImGuiMouseCursor.ResizeEW)

  if hovered and igIsMouseClicked(ImGuiMouseButton.Left):
    if hit < 0 and st.tool == Draw:
      let added = song.addPlacement(lane, t, grid)
      if added >= 0:
        st.grabbed = added # keep dragging it, as a new note in the roll
        clicked = st.grabbed
        st.grabOff = t - song.placements[added].start
        st.drag = PMove
    elif hit >= 0:
      if song.placements[hit].clip != song.clip:
        focus(song.placements[hit].clip, -1)
      st.grabbed = hit
      clicked = hit
      st.grabOff = t - song.placements[hit].start
      st.drag = if onR: PTrimR elif onL: PTrimL else: PMove
      if st.tool == Select:
        song.placements.clickSelect(hit, io.keyShift)
    else:
      st.drag = PBox
      st.box.start(st.view, mouse)
    if st.drag in {PMove, PTrimL, PTrimR}:
      st.before = song.placements
  proc moving(i: int): bool =
    song.placements.moves(st.grabbed, st.drag, i)

  if not igIsMouseDown(ImGuiMouseButton.Left):
    if st.drag == PBox: # touched placements get selected
      let (bx0, by0, bx1, by1) = st.box.rect(st.view, mouse)
      song.placements.boxSelect(io.keyShift, proc(p: Placement): bool =
        tickX(p.start.float) <= bx1 and tickX(float(p.start + p.len)) >= bx0 and
          laneY(p.lane) <= by1 and laneY(p.lane) + st.view.rowH >= by0
      )
    elif st.drag != PIdle and st.blocked: # overlapping: it goes back where it was
      song.placements = st.before
    st.drag = PIdle
    st.blocked = false
  case st.drag
  of PMove, PTrimL, PTrimR:
    # from where the drag began, so nothing sticks to an overlap passed on the way
    st.blocked = song.dragPlacements(st.before, st.grabbed, st.drag, t, lane, st.grabOff, grid)
  of PBox:
    discard
  of PIdle:
    if fired(SongEd, Delete, ImGuiKey.Delete, ctrl = false):
      song.placements.keepItIf(not it.sel)
      clicked = -1
    elif st.tool == Draw and hovered and igIsMouseClicked(ImGuiMouseButton.Right) and hit >= 0:
      song.placements.delete hit
      if clicked == hit:
        clicked = -1
      elif clicked > hit:
        dec clicked

  # --- drawing ---
  dl.pushClipRect(v2(origin.x, laneTop), v2(gridX, bottom), true)
  for l in 0 ..< Lanes:
    dl.addRectFilled(v2(origin.x, laneY(l)), v2(gridX - 1, laneY(l) + st.view.rowH - 1), rgb(44, 46, 52))
  dl.popClipRect()
  dl.pushClipRect(v2(gridX, origin.y), v2(right, bottom), true)
  for l in 0 ..< Lanes:
    dl.addRectFilled(
      v2(gridX, laneY(l)),
      v2(right, laneY(l) + st.view.rowH),
      if l mod 2 == 0: rgb(52, 56, 62) else: rgb(46, 50, 56),
    )
  dl.addRectFilled(v2(gridX, origin.y), v2(right, laneTop), rgb(30, 30, 30)) # over the rows scrolled up
  st.view.drawGrid(dl, if Snaps[snapIdx][2]: Ppq div 3 else: Ppq, bottom)
  dl.popClipRect()

  dl.pushClipRect(v2(gridX, laneTop), v2(right, bottom), true)
  for i, p in song.placements:
    let (x0, x1, y) = (tickX(p.start.float), tickX(float(p.start + p.len)), laneY(p.lane))
    dl.addRectFilled(
      v2(x0, y + 1), v2(x1, y + st.view.rowH - 2),
      if st.blocked and moving(i): rgb(200, 50, 50)
      else: rgb(70 + p.clip * 67 mod 100, 100 + p.clip * 131 mod 90, 150 + p.clip * 43 mod 80),
      2,
    )
    dl.addRect(
      v2(x0, y + 1), v2(x1, y + st.view.rowH - 2),
      if i == clicked or p.sel: rgb(255, 255, 255) else: rgb(10, 10, 10), 2,
    )
    let loop = song.clips[p.clip].loopEnd
    dl.pushClipRect(v2(x0, y), v2(x1, y + st.view.rowH), true)
    var (lo, hi) = (127, 0) # pitch range of the clip, spread over the box height
    for t in song.clips[p.clip].tracks:
      for n in t.notes:
        lo = min(lo, n.pitch)
        hi = max(hi, n.pitch)
    let hh = igGetTextLineHeight() + 2 # title header
    dl.addRectFilled(v2(x0, y + 1), v2(x1, y + 1 + hh), rgb(0, 0, 0, 70), 2)
    let (top, body) = (y + 1 + hh + 1, st.view.rowH - 3 - hh - 2) # the rest of the box
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
      dl.addLine(v2(tickX(m.float), y + 1), v2(tickX(m.float), y + st.view.rowH - 2), rgb(255, 255, 255), 2)
      m += loop
  if st.drag == PBox:
    st.box.draw(st.view, dl, mouse)
  dl.popClipRect()
  dl.pushClipRect(v2(gridX, origin.y), v2(right, bottom), true)
  dl.addLine(v2(tickX(song.songPos), origin.y), v2(tickX(song.songPos), bottom), rgb(255, 255, 255, if song.songMode: 180 else: 80))
  dl.popClipRect()

  # lane numbers and mute/solo, after the backgrounds
  if st.view.rowH >= 22: # smaller rows would overlap
    igPushClipRect(v2(origin.x, laneTop), v2(gridX, bottom), true)
    for l in 0 ..< Lanes:
      let y = laneY(l)
      if y + st.view.rowH < laneTop or y > bottom:
        continue
      igSetCursorScreenPos(v2(origin.x + 4, y + (st.view.rowH - igGetFrameHeight()) / 2))
      igPushID(int32(l))
      igText("%s", cstring($(l + 1)))
      igSameLine()
      discard igCheckbox("M", addr song.laneMute[l])
      igSameLine()
      discard igCheckbox("S", addr song.laneSolo[l])
      igPopID()
    igPopClipRect()
