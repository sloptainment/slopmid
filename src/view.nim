## One editor's zoom, scroll and screen mapping, shared by the piano roll and the song window: ticks across, rows down.
## Wheel, pan and zoom input, the two scrollbars, the ruler and the grid lines.
import std/math
import imgui
import model, common

type
  View* = object
    beatW*, rowH*: float32 # zoom: pixels per beat, pixels per row
    scrollX*, scrollY*: float32
    rows*: int
    maxRowH*: float32
    x*, rulerY*, top*, w*, h*: float32
      # this frame's grid: left, ruler top, rows' top, width, rows' height

  Box* = object
    ## a drag-a-rectangle selection: the anchor is in content coordinates, so it follows the scroll
    a: ImVec2
    scrollsY: bool
      # false: the anchor's y is a screen y (the curve lane, which does not scroll rows)

  ScrollGrab = enum
    GrabBody
    GrabLo
    GrabHi

var
  sbGrab: ScrollGrab
  sbOff: float32

proc clampScroll(v: var View) =
  v.scrollY = clamp(v.scrollY, 0, max(0, v.rows.float32 * v.rowH - v.h))
  v.scrollX = max(v.scrollX, 0)

proc place*(v: var View, x, rulerY, w, h: float32) =
  ## Sets this frame's grid rect (`h`: the rows' height, below the ruler) and keeps the scroll inside it.
  v.x = x
  v.rulerY = rulerY
  v.top = rulerY + RulerH
  v.w = w
  v.h = h
  v.clampScroll()

proc tickX*(v: View, t: float): float32 =
  v.x + float32(t / Ppq.float) * v.beatW - v.scrollX

# clamp before int(): imgui parks an absent mouse at -FLT_MAX
proc xTick*(v: View, x: float32): int =
  int(max(0, (x - v.x + v.scrollX) / v.beatW * Ppq.float32))

proc rowY*(v: View, r: int): float32 =
  v.top + r.float32 * v.rowH - v.scrollY

proc yRow*(v: View, y: float32): int =
  int(clamp((y - v.top + v.scrollY) / v.rowH, 0, (v.rows - 1).float32))

proc navigate*(v: var View, hovered, pan: bool, mouse: ImVec2, beats: float32) =
  ## Wheel scrolls rows, Shift+wheel and the horizontal wheel scroll time (when `hovered`); `pan` (middle button held) drags the
  ## view, with Ctrl zooms about the mouse. `beats` is the scrollable length. Call after `place`.
  let io = igGetIO()
  if hovered:
    if io.keyShift:
      v.scrollX -= io.mouseWheel * v.beatW
    else:
      v.scrollY -= io.mouseWheel * v.rowH * 3
    v.scrollX -= io.mouseWheelH * v.beatW
  if pan:
    if io.keyCtrl: # zoom about the mouse: right/up zooms in
      let u = (mouse.x - v.x + v.scrollX) / v.beatW
      let t = (mouse.y - v.top + v.scrollY) / v.rowH
      v.beatW = clamp(v.beatW * exp(io.mouseDelta.x * 0.01), v.w / beats / 4, 1024)
      v.rowH = clamp(
        v.rowH * exp(-io.mouseDelta.y * 0.01), v.h / v.rows.float32 / 4, v.maxRowH
      )
      v.scrollX = u * v.beatW - (mouse.x - v.x)
      v.scrollY = t * v.rowH - (mouse.y - v.top)
    else:
      v.scrollX -= io.mouseDelta.x
      v.scrollY -= io.mouseDelta.y
  # clamp after the input above, or the frame draws past the edge
  v.clampScroll()

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

proc scrollbars*(v: var View, beats, bottom: float32) =
  ## The time scrollbar under the grid at `bottom`, the row one on its right. Call after `navigate`.
  scrollbar("scrollX", false, v2(v.x, bottom), v.w, v.scrollX, v.beatW, beats, 1024)
  scrollbar(
    "scrollY",
    true,
    v2(v.x + v.w, v.top),
    v.h,
    v.scrollY,
    v.rowH,
    v.rows.float32,
    v.maxRowH,
  )

proc ruler*(v: View, mouse: ImVec2): int =
  ## The ruler's button; the tick under the mouse while it is held, else -1.
  igSetCursorScreenPos(v2(v.x, v.rulerY))
  discard igInvisibleButton("ruler", v2(v.w, RulerH))
  if igIsItemActive():
    result = v.xTick(mouse.x)
  else:
    result = -1

proc drawGrid*(v: View, dl: ptr ImDrawList, minor: int, bottom: float32) =
  ## Vertical lines every `minor` ticks from the rows' top down to `bottom`, bars darkest, with bar numbers on the ruler.
  var gt = v.xTick(v.x).snapDown(minor)
  while gt <= v.xTick(v.x + v.w):
    let x = v.tickX(gt.float)
    let col =
      if gt mod BarTicks == 0:
        rgb(20, 20, 20)
      elif gt mod Ppq == 0:
        rgb(32, 34, 38)
      else:
        rgb(44, 48, 54)
    dl.addLine(v2(x, v.top), v2(x, bottom), col)
    if gt mod BarTicks == 0:
      dl.addText(
        v2(x + 3, v.rulerY + 1), rgb(200, 200, 200), cstring($(gt div BarTicks + 1))
      )
    gt += minor

proc start*(b: var Box, v: View, mouse: ImVec2, scrollsY = true) =
  ## Anchors the box at the mouse.
  b.scrollsY = scrollsY
  b.a = v2(
    mouse.x - v.x + v.scrollX,
    if scrollsY:
      mouse.y - v.top + v.scrollY
    else:
      mouse.y,
  )

proc rect*(b: Box, v: View, mouse: ImVec2): tuple[x0, y0, x1, y1: float32] =
  ## The box in screen space, from its anchor to the mouse.
  let (ax, ay) = (
    b.a.x + v.x - v.scrollX,
    if b.scrollsY:
      b.a.y + v.top - v.scrollY
    else:
      b.a.y,
  )
  (min(ax, mouse.x), min(ay, mouse.y), max(ax, mouse.x), max(ay, mouse.y))

proc draw*(b: Box, v: View, dl: ptr ImDrawList, mouse: ImVec2) =
  let (x0, y0, x1, y1) = b.rect(v, mouse)
  dl.addRectFilled(v2(x0, y0), v2(x1, y1), rgb(66, 150, 250, 50))
  dl.addRect(v2(x0, y0), v2(x1, y1), rgb(66, 150, 250))

when isMainModule:
  var v = View(beatW: 64, rowH: 14, scrollX: 128, scrollY: 100, rows: 128, maxRowH: 160)
  v.place(50, 10, 400, 300)
  doAssert v.top == 28 and v.tickX(0) == 50 - 128
  doAssert v.xTick(v.tickX(960.0)) == 960 and v.xTick(-1e9) == 0
    # an absent mouse parks at -FLT_MAX
  doAssert v.rowY(3) == 28 + 3 * 14 - 100
  doAssert v.yRow(v.rowY(7) + 1) == 7 and v.yRow(-1e9) == 0 and v.yRow(1e9) == 127
  v.scrollY = 1e6
  v.place(50, 10, 400, 300) # scroll stays inside the content
  doAssert v.scrollY == 128 * 14 - 300
  var b: Box
  v.scrollX = 128
  v.scrollY = 100
  b.start(v, v2(100, 60)) # content (178, 132) at scroll (128, 100)
  doAssert b.rect(v, v2(60, 40)) == (60f32, 40f32, 100f32, 60f32)
  v.scrollX = 0
  v.scrollY = 0
  doAssert b.rect(v, v2(500, 500)) == (50f32 + 178, 28f32 + 132, 500f32, 500f32)
    # follows the scroll
  b.start(v, v2(100, 60), scrollsY = false)
  v.scrollY = 50
  doAssert b.rect(v, v2(200, 100)) == (100f32, 60f32, 200f32, 100f32)
    # y stays on the screen
  echo "view ok"
