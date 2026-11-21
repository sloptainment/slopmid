## Sheet: left-click adds a note or drags it, its right end resizes it,
## right-click deletes. Note names: click to audition. Velocity lane: drag.
## Select tool (corner buttons): drag a box to select (in the Vol/Exp lane: curve points; Shift adds), drag a selected note to move them all, Delete removes them; Ctrl+A selects all (or deselects, if anything is selected), Ctrl+D duplicates the selection after its last note, Ctrl+Q quantizes the selection's starts and ends to the snap.
## Ctrl+C copies the selection, Ctrl+V pastes it as a group at the playhead set on the ruler, rounded to the snap. In the Vol/Exp/Pan lane they copy and paste curve points, replacing the points the pasted span covers.
## Bend tool (corner buttons): every note shows its pitch bend as a line between points, the first at its start and the last at its end (pinned in time). Drag a point (up/down is semitones from the note, continuous), click the line or a note to add one at the snap, right-drag a middle point to delete it, Ctrl+click puts a point on the note's own pitch. Selection as in Select, built in: click, Shift+click, drag a box, Delete, Ctrl+A. Notes themselves are untouched.
## Wheel scrolls pitch, Shift+wheel scrolls time, middle-drag pans, Ctrl+middle-drag zooms. Space plays/pauses.

import std/[math, sequtils, strformat, strutils]
import imgui
import wrap/gui
import model, edit, view, common, audio

type
  Drag = enum
    Idle
    Move
    Resize
    Box ## a selection box

  LaneMode = enum ## the velocity lane's combo; a curve mode's index in `Track.cc` is `ord - 1`
    Vel
    Vol
    Exp
    Pan

  RollState = object ## the piano roll's UI state, UI thread only
    view: View # row = 127 - pitch; C6 at the top
    tool: Tool
    laneMode: LaneMode
    lastLen: int
    lastVel: int # velocity of the last clicked or dragged note
    velFrac: float32 # share of the sheet+velocity height taken by the velocity lane
    drag: Drag
    box: Box # the sheet's selection box
    ptBox: Box # the lane's selection box
    grabbed, grabOff: int # the note dragged and where in it (ticks) it was grabbed
    velLine: seq[int] # notes whose velocity line was clicked, kept for the drag
    ptDrag: int # index of the curve point being dragged
    bendNote: int # the note whose bend point is being dragged, and which point of its `bend`
    bendPt: int
    bendBox: bool # a selection box of bend points is being dragged, from `box`
    previewKey: int
    noteClip: seq[Note] # Ctrl+C in the piano roll
    ccClip: seq[CurvePt] # Ctrl+C in a Vol/Exp/Pan lane

var st = RollState(
  view: View(beatW: 64, rowH: 14, scrollY: float32(127 - 84) * 14, rows: 128, maxRowH: 160),
  lastLen: Ppq,
  lastVel: 100,
  velFrac: 0.25f32,
  ptDrag: -1,
  bendNote: -1,
  previewKey: -1,
)

template curveIdx(): int =
  ord(st.laneMode) - 1 # only in a curve mode


proc pianoRollWindow*() =
  let io = igGetIO()
  if igIsWindowFocused():
    editor = RollEd
  let dl = igGetWindowDrawList()
  let origin = igGetCursorScreenPosNonUDT()
  let avail = igGetContentRegionAvailNonUDT()
  let
    gridX = origin.x + KeyW
    gridW = avail.x - KeyW - SbW
    right = gridX + gridW
    bothH = avail.y - RulerH - SbW # sheet on top, velocity below
    velH = bothH * st.velFrac
    valH = velH - 8 # value 127 sits 8px below the border, clear of the split grip
    paneH = bothH - velH # sheet height
    sheetTop = origin.y + RulerH
    velTop = sheetTop + paneH
    bottom = velTop + velH
    grid = Snaps[snapIdx][1]
    mouse = v2(io.mousePos.x, io.mousePos.y) # imgui's ImVec2 is not cimgui's

  st.view.place(gridX, origin.y, gridW, paneH)
  proc tickX(t: float): float32 =
    st.view.tickX(t)

  proc xTick(x: float32): int =
    st.view.xTick(x)

  proc pitchY(p: int): float32 =
    st.view.rowY(127 - p)

  proc yPitch(y: float32): int =
    127 - st.view.yRow(y)

  # --- input ---
  # drag the border between sheet and velocity lane; first submitted item wins
  # hover where items overlap, so this goes before the lanes' buttons
  igSetCursorScreenPos(v2(origin.x, velTop - 8))
  discard igInvisibleButton("split", v2(avail.x - SbW, 8)) # above the border only
  let splitHot = igIsItemHovered() or igIsItemActive()
  if splitHot:
    igSetMouseCursor(ImGuiMouseCursor.ResizeNS)
  if igIsItemActive():
    st.velFrac = clamp((bottom - io.mousePos.y) / bothH, 0.1, 0.9)

  toolButtons(st.tool, origin, bend = true)
  let notesOk = st.tool != Bend # in Bend the notes are only looked at
  if st.tool == Bend:
    for n in focused().notes.mitems:
      if n.bend.len < 2: # the two end points, flat
        n.bend = @[(0, 0.0, false), (0, 0.0, false)]

  if st.laneMode == Vel and fired(RollEd, SelectAll, ImGuiKey.A):
    if notesOk:
      focused().notes.toggleAll
    else:
      let all = not focused().notes.anyIt(it.bend.anyIt(it.sel))
      for n in focused().notes.mitems:
        for k in 0 .. n.bend.high:
          n.bend[k].sel = all and n.bendVisible(k)
  if notesOk and fired(RollEd, Duplicate, ImGuiKey.D):
    focused().notes.duplicate(grid)
  if notesOk and st.laneMode == Vel and fired(RollEd, Copy, ImGuiKey.C):
    let sel = focused().notes.filterIt(it.sel)
    if sel.len > 0:
      st.noteClip = sel
  if notesOk and st.laneMode == Vel and fired(RollEd, Paste, ImGuiKey.V) and focusTrack >= 0 and st.noteClip.len > 0:
    focused().notes.pasteNotes(st.noteClip, snap(song.clipPos.int, grid)) # the group's first note lands on the playhead
  if notesOk and fired(RollEd, Quantize, ImGuiKey.Q):
    focused().notes.quantize(grid)
  var semis = 0 # semitones to transpose by
  if notesOk and editor == RollEd and menuCmd in SemiUp .. OctDown:
    semis = [1, -1, 12, -12][menuCmd.ord - SemiUp.ord]
  elif notesOk and igIsWindowFocused() and (io.keyCtrl or io.keyShift) and not io.wantTextInput:
    let up = igIsKeyPressed(ImGuiKey.UpArrow, true)
    if up or igIsKeyPressed(ImGuiKey.DownArrow, true):
      semis = (if io.keyCtrl: 12 else: 1) * (if up: 1 else: -1)
  if semis != 0:
    focused().notes.transpose(semis)

  # click or drag on the ruler moves the playhead
  let rulerTick = st.view.ruler(mouse)
  if rulerTick >= 0:
    song.clipPos = rulerTick.float

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
  if igBeginCombo("##velMode", cstring($st.laneMode)):
    for m in LaneMode:
      if igSelectable(cstring($m), m == st.laneMode):
        st.laneMode = m
    igEndCombo()
  if st.laneMode != Vel:
    igSetCursorScreenPos(v2(origin.x + 2, velTop + 14 + igGetFrameHeight()))
    igSetNextItemWidth(KeyW - 4)
    if igBeginCombo("##volRes", ["1/16", "1/32", "1/64", "1/96"][focused().ccRes]):
      for i, name in ["1/16", "1/32", "1/64", "1/96"]:
        if igSelectable(cstring(name), i == focused().ccRes):
          focused().ccRes = i
      igEndCombo()

  let beats = float32(song.clips[song.clip].loopEnd + 4 * BarTicks) / Ppq.float32
    # room to add past the end
  st.view.navigate(keysHovered or sheetHovered or igIsItemHovered(), sheetPan, mouse, beats)
  st.view.scrollbars(beats, bottom)

  let t = xTick(mouse.x)
  let p = yPitch(mouse.y)
  var hit = -1
  for i in countdown(focused().notes.high, 0):
    let n = focused().notes[i]
    if n.pitch == p and t >= n.start and t < n.start + n.len:
      hit = i
      break
  let onEdge =
    hit >= 0 and
    tickX(float(focused().notes[hit].start + focused().notes[hit].len)) - mouse.x < EdgeW
  if notesOk and sheetHovered and (onEdge or st.drag == Resize):
    igSetMouseCursor(ImGuiMouseCursor.ResizeEW)

  # --- bend points: a point is (note, index into its `bend`) ---
  proc bendXY(n: Note, k: int): ImVec2 =
    v2(tickX(float(n.start + n.bendTick(k))), pitchY(n.pitch) + st.view.rowH / 2 - float32(n.bend[k].v) * st.view.rowH)
  proc bendVal(n: Note): float = # the mouse's height as semitones from `n`
    clamp(float((pitchY(n.pitch) + st.view.rowH / 2 - mouse.y) / st.view.rowH), -BendRange.float, BendRange.float)
  proc bendHit(): tuple[note, pt: int] = # the point under the mouse
    result = (-1, -1)
    for i in countdown(focused().notes.high, 0):
      let n = focused().notes[i]
      for k in n.bendIdx:
        let q = bendXY(n, k)
        if abs(q.x - mouse.x) <= 6 and abs(q.y - mouse.y) <= 6:
          return (i, k)
  proc bendLine(): int = # the note whose bend line, else body, is under the mouse
    for i in countdown(focused().notes.high, 0):
      let n = focused().notes[i]
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
    let k = focused().notes[i].addBendPt(snap(xTick(mouse.x), grid), v)
    if k >= 0:
      st.bendNote = i
      st.bendPt = k
  if not notesOk:
    if sheetHovered and igIsMouseClicked(ImGuiMouseButton.Left):
      let (hi, hk) = bendHit()
      let ln = bendLine()
      st.bendNote = -1
      if hi >= 0:
        st.bendNote = hi
        st.bendPt = hk
        if io.keyCtrl: # on the note's own pitch; a selected point takes its whole selection along
          focused().notes.zeroBendPts(hi, hk)
          st.bendNote = -1
        elif not focused().notes[hi].bend[hk].sel: # a selected point keeps the group
          if not io.keyShift:
            for n in focused().notes.mitems:
              for q in n.bend.mitems:
                q.sel = false
          focused().notes[hi].bend[hk].sel = true
      elif ln >= 0:
        addBend(ln, if io.keyCtrl: 0.0 else: bendVal(focused().notes[ln]))
        if io.keyCtrl:
          st.bendNote = -1
      else:
        st.bendBox = true
        st.box.start(st.view, mouse)
    if not igIsMouseDown(ImGuiMouseButton.Left):
      if st.bendBox: # the points in the box get selected
        let (bx0, by0, bx1, by1) = st.box.rect(st.view, mouse)
        for n in focused().notes.mitems:
          for k in n.bendIdx:
            let q = bendXY(n, k)
            if q.x >= bx0 and q.x <= bx1 and q.y >= by0 and q.y <= by1:
              n.bend[k].sel = true
            elif not io.keyShift:
              n.bend[k].sel = false
      st.bendBox = false
      st.bendNote = -1
    if st.bendNote >= 0:
      # the dragged point, or its whole selection, moves by the same ticks and semitones
      let bn = focused().notes[st.bendNote]
      focused().notes.moveBendPts(
        st.bendNote, st.bendPt, snap(xTick(mouse.x), grid) - bn.start - bn.bend[st.bendPt].t, bendVal(bn) - bn.bend[st.bendPt].v
      )
    elif sheetHovered and igIsMouseDown(ImGuiMouseButton.Right): # dragging deletes; not the ends
      let (hi, hk) = bendHit()
      if hi >= 0 and hk > 0 and hk < focused().notes[hi].bend.high:
        focused().notes[hi].bend.delete hk

  if notesOk and sheetHovered and igIsMouseClicked(ImGuiMouseButton.Left):
    if hit < 0 and st.tool == Draw:
      for n in focused().notes.mitems:
        n.sel = false
      focused().notes.add Note(
        start: max(0, snapDown(t, grid)), len: st.lastLen, pitch: p, vel: st.lastVel
      )
      hit = focused().notes.high
    if hit >= 0:
      st.grabbed = hit
      st.drag = if onEdge: Resize else: Move
      st.grabOff = t - focused().notes[hit].start
      st.lastLen = focused().notes[hit].len
      st.lastVel = focused().notes[hit].vel
      if st.tool == Select:
        focused().notes.clickSelect(hit, io.keyShift)
    else:
      st.drag = Box
      st.box.start(st.view, mouse)
  # the box in screen space; touched notes get selected on release
  if not igIsMouseDown(ImGuiMouseButton.Left):
    if st.drag == Box:
      let (bx0, by0, bx1, by1) = st.box.rect(st.view, mouse)
      focused().notes.boxSelect(io.keyShift, proc(n: Note): bool =
        tickX(n.start.float) <= bx1 and tickX(float(n.start + n.len)) >= bx0 and
          pitchY(n.pitch) <= by1 and pitchY(n.pitch) + st.view.rowH >= by0
      )
    st.drag = Idle
  case st.drag
  of Move:
    # the dragged note, or its whole selection, moves by the same ticks and pitches
    let n = focused().notes[st.grabbed]
    focused().notes.moveNotes(st.grabbed, snap(t - st.grabOff, grid) - n.start, p - n.pitch)
  of Box:
    discard
  of Resize:
    # the dragged note, or its whole selection, changes length by the same ticks
    let n = focused().notes[st.grabbed]
    focused().notes.resizeNotes(st.grabbed, snap(t, grid) - n.start - n.len, grid)
    st.lastLen = focused().notes[st.grabbed].len
  of Idle:
    if st.laneMode == Vel and fired(RollEd, Delete, ImGuiKey.Delete, ctrl = false):
      if notesOk:
        focused().notes.keepItIf(not it.sel)
      else: # the selected middle points
        focused().notes.deleteBendPts
    elif st.tool == Draw and sheetHovered and igIsMouseDown(ImGuiMouseButton.Right) and hit >= 0:
      focused().notes.delete hit

  # clicking a key or placing/moving a note plays it; dragging across pitches glides
  var key = -1
  var vel = 0
  if keysHeld:
    key = yPitch(mouse.y)
    vel = clamp(int((mouse.x - origin.x) / KeyW * 127), 1, 127)
  elif st.drag == Move:
    key = focused().notes[st.grabbed].pitch
    vel = focused().notes[st.grabbed].vel
  if key != st.previewKey:
    let ch = if focused().rhythm: Drums else: PreviewCh
    if st.previewKey >= 0: # note off
      preview(0x80 or ch, st.previewKey, 0)
    if key >= 0: # the track's sound, then note on
      preview(0xB0 or ch, 0, focused().bank)
      preview(0xC0 or ch, focused().program, 0)
      preview(0x90 or ch, key, vel)
    st.previewKey = key

  # dragging in the velocity lane sets the selected notes (all, if none) whose bar is under the mouse
  let onLine = proc(n: Note): bool = # the faint line across the note's length
    mouse.x >= tickX(n.start.float) and mouse.x <= tickX(float(n.start + n.len)) and
      abs(bottom - float32(n.vel) / 127 * valH - mouse.y) <= 4
  template pts(): untyped = focused().cc[curveIdx()] # the curve shown, in a curve mode
  let volHit = proc(): int = # the curve point under the mouse
    result = -1
    for i, p in pts:
      if abs(tickX(p.t.float) - mouse.x) <= 6 and abs(bottom - float32(p.v) / 127 * valH - mouse.y) <= 6:
        return i
  let volVal = proc(): int = clamp(int((bottom - mouse.y) / valH * 127), 0, 127)
  let loopT = song.clips[song.clip].loopEnd
  let addPt = proc(v: int) = # a point at the snapped tick, or that tick's own point, set to `v`
    st.ptDrag = pts.addCurvePt(snap(xTick(mouse.x), grid), v, loopT)
  let onCurve = proc(): bool = # the drawn curve under the mouse
    let t = xTick(mouse.x)
    t >= pts[0].t and t <= loopT and
      abs(bottom - float32(focused().ccAt(curveIdx(), t)) / 127 * valH - mouse.y) <= 6
  if st.laneMode != Vel:
    if fired(RollEd, SelectAll, ImGuiKey.A):
      pts.toggleAll
    if fired(RollEd, Delete, ImGuiKey.Delete, ctrl = false):
      pts.keepItIf(not it.sel)
    if fired(RollEd, Copy, ImGuiKey.C) and pts.anyIt(it.sel):
      st.ccClip = pts.filterIt(it.sel)
    if fired(RollEd, Paste, ImGuiKey.V) and st.ccClip.len > 0:
      pts.pasteCurve(st.ccClip, snap(song.clipPos.int, grid), loopT) # the first point lands on the playhead
  if st.laneMode != Vel:
    if pts.len == 0: # the default, as a point at the start
      pts.add (0, CcDefault[curveIdx()], false)
    if velDown:
      st.ptDrag = volHit()
      if st.laneMode == Pan and io.keyCtrl and (st.ptDrag >= 0 or onCurve()): # Pan: Ctrl+click centres a point, or adds one at centre
        if st.ptDrag >= 0:
          pts[st.ptDrag].v = CcDefault[2]
        else:
          addPt(CcDefault[2])
        st.ptDrag = -2 # no drag, no box
      elif st.tool == Select:
        if st.ptDrag >= 0:
          pts.clickSelect(st.ptDrag, io.keyShift)
        else: # empty space: a box
          st.ptBox.start(st.view, mouse, scrollsY = false)
      elif st.ptDrag < 0: # a click on empty space adds a point, at the snap
        addPt(volVal())
    if st.tool == Select and st.ptDrag == -1 and velUp: # a box ends: the points in it get selected
      let (bx0, by0, bx1, by1) = st.ptBox.rect(st.view, mouse)
      pts.boxSelect(io.keyShift, proc(p: CurvePt): bool =
        let (x, y) = (tickX(p.t.float), bottom - float32(p.v) / 127 * valH)
        x >= bx0 and x <= bx1 and y >= by0 and y <= by1
      )
    if velHeld and st.ptDrag in 0 ..< pts.len:
      # the dragged point, or in Select its whole selection, moves by the same ticks and values
      pts.moveCurvePts(
        st.ptDrag, st.tool == Select, clamp(snap(xTick(mouse.x), grid), 0, loopT) - pts[st.ptDrag].t, volVal() - pts[st.ptDrag].v, loopT
      )
    if velHovered and igIsMouseDown(ImGuiMouseButton.Right): # dragging deletes; the last point stays
      let h = volHit()
      if h >= 0 and pts.len > 1:
        pts.delete h
  if st.laneMode == Vel and velDown:
    st.velLine.setLen 0
    for i, n in focused().notes:
      if onLine(n):
        st.velLine.add i
  if st.laneMode == Vel and velHeld:
    let v = clamp(int((bottom - mouse.y) / valH * 127), 1, 127)
    let anySel = focused().notes.anyIt(it.sel)
    for i, n in focused().notes.mpairs:
      if (n.sel or not anySel) and (abs(tickX(n.start.float) - mouse.x) <= 4 or i in st.velLine):
        n.vel = v
        st.lastVel = v

  # tooltip: the value being dragged, else one line per note the drag would set
  if velHeld or velHovered:
    var lines: seq[string]
    let line = proc(v: int): string =
      if st.laneMode != Pan:
        fmt"{v} - {int(round(v / 127 * 100))}%"
      elif v == 64: # pan: 0 = full left, 64 = centre, 127 = full right
        fmt"{v} - Center"
      elif v < 64:
        fmt"{v} - {int(round((64 - v) / 64 * 100))}% L"
      else:
        fmt"{v} - {int(round((v - 64) / 63 * 100))}% R"
    if st.laneMode != Vel:
      let h = if velHeld: st.ptDrag else: volHit()
      if h in 0 ..< pts.len:
        lines.add line(pts[h].v)
    elif velHeld:
      lines.add line(clamp(int((bottom - mouse.y) / valH * 127), 1, 127))
    else:
      let anySel = focused().notes.anyIt(it.sel)
      for n in focused().notes:
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
      if q == st.previewKey:
        rgb(120, 170, 255)
      elif black:
        rgb(30, 30, 34)
      else:
        rgb(220, 220, 220)
    dl.addRectFilled(v2(origin.x, y), v2(gridX - 1, y + st.view.rowH - 1), col)
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
      v2(right, y + st.view.rowH),
      if Names[q mod 12].len == 2:
        rgb(40, 44, 50)
      else:
        rgb(52, 56, 62),
    )
  dl.popClipRect()
  dl.pushClipRect(v2(gridX, origin.y), v2(right, bottom), true)
  dl.addRectFilled(v2(gridX, origin.y), v2(right, sheetTop), rgb(30, 30, 30))
  dl.addRectFilled(v2(gridX, velTop), v2(right, bottom), rgb(34, 36, 40))
  st.view.drawGrid(dl, if Snaps[snapIdx][2]: Ppq div 3 else: Ppq div 4, bottom)
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
  for n in focused().notes:
    let (x0, x1, y) =
      (tickX(n.start.float), tickX(float(n.start + n.len)), pitchY(n.pitch))
    let shade = 90 + n.vel
    dl.addRectFilled(
      v2(x0, y + 1),
      v2(x1, y + st.view.rowH - 1),
      if n.sel: rgb(shade, shade, shade div 3) else: rgb(shade div 2, shade, shade div 2),
      2,
    )
    dl.addRect(v2(x0, y + 1), v2(x1, y + st.view.rowH - 1), if n.sel: rgb(255, 255, 255) else: rgb(10, 30, 10), 2)
    let name = noteName(n.pitch) # faded, only where the whole name fits inside the note
    if st.view.rowH >= igGetTextLineHeight() and x1 - x0 >= igCalcTextSizeNonUDT(cstring(name)).x + 6:
      dl.addText(v2(x0 + 3, y + (st.view.rowH - igGetTextLineHeight()) / 2), rgb(0, 0, 0, 120), cstring(name))
  let notes = focused().notes
  for i, a in notes: # same-pitch notes sounding together: red on the shared ticks only
    for b in notes[i + 1 ..< notes.len]: # ponytail: O(n^2) pairs, sort by pitch if big clips lag
      let (s, e) = (max(a.start, b.start), min(a.start + a.len, b.start + b.len))
      if a.pitch == b.pitch and s < e:
        let y = pitchY(a.pitch)
        dl.addRectFilled(v2(tickX(s.float), y + 1), v2(tickX(e.float), y + st.view.rowH - 1), rgb(255, 30, 30), 2)
  if st.tool == Bend:
    # a point or segment is black where another note's bend wins the track's wheel there
    # ponytail: O(notes^2) per frame; fine for a clip's worth of notes
    let loses = proc(i, tick: int): bool =
      let w = focused().bendWinner(tick)
      w >= 0 and w != i
    for i, n in focused().notes:
      let ks = n.bendIdx
      for j in 1 .. ks.high:
        let mid = n.start + (n.bendTick(ks[j - 1]) + n.bendTick(ks[j])) div 2
        dl.addLine(bendXY(n, ks[j - 1]), bendXY(n, ks[j]), if loses(i, mid): rgb(0, 0, 0) else: rgb(255, 255, 255), 2)
      for k in ks:
        let c = if loses(i, n.start + min(n.bendTick(k), n.len - 1)): rgb(0, 0, 0) else: rgb(255, 255, 255)
        if n.bend[k].sel:
          dl.addCircleFilled(bendXY(n, k), 5, rgb(255, 150, 30))
        dl.addCircle(bendXY(n, k), 5, c, 0, 2)
  if st.drag == Box or st.bendBox:
    st.box.draw(st.view, dl, mouse)
  dl.popClipRect()
  if st.laneMode != Vel:
    dl.pushClipRect(v2(gridX, velTop), v2(right, bottom), true)
    let col = rgb(110, 210, 110)
    if st.laneMode == Pan: # the centre
      let cy = bottom - float32(CcDefault[2]) / 127 * valH
      dl.addLine(v2(gridX, cy), v2(right, cy), rgb(255, 255, 255, 200), 3)
    let pt = proc(p: tuple[t, v: int, sel: bool]): ImVec2 = v2(tickX(p.t.float), bottom - float32(p.v) / 127 * valH)
    for i, p in pts:
      if i > 0:
        dl.addLine(pt(pts[i - 1]), pt(p), col, 2)
    for p in pts:
      dl.addCircleFilled(pt(p), 4, if p.sel: rgb(255, 255, 85) else: col)
    if st.tool == Select and velHeld and st.ptDrag == -1:
      st.ptBox.draw(st.view, dl, mouse)
    let last = pt(pts[^1]) # held to the loop point
    dl.addLine(last, v2(le, last.y), col, 2)
    dl.popClipRect()
  for n in (if st.laneMode == Vel: focused().notes else: @[]):
    let x0 = tickX(n.start.float)
    let vy = bottom - float32(n.vel) / 127 * valH
    let c = if n.sel: rgb(255, 255, 85) else: rgb(110, 210, 110)
    dl.addLine(v2(x0, vy), v2(tickX(float(n.start + n.len)), vy), (if n.sel: rgb(255, 255, 85, 90) else: rgb(110, 210, 110, 90)), 2)
    dl.addLine(v2(x0, bottom), v2(x0, vy), c, 2)
    dl.addCircleFilled(v2(x0, vy), 4, c)

  for c in playLines():
    dl.addLine(v2(tickX(c), origin.y), v2(tickX(c), bottom), rgb(255, 255, 255, 180))
  if song.songMode: # the clip's own position, where Ctrl+V pastes
    dl.addLine(v2(tickX(song.clipPos), origin.y), v2(tickX(song.clipPos), bottom), rgb(255, 255, 255, 80))
  dl.popClipRect()
