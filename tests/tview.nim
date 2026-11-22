import std/[unittest, math]
import imgui
import ../src/common
import ../src/view

test "view":
  var v = View(beatW: 64, rowH: 14, scrollX: 128, scrollY: 100, rows: 128, maxRowH: 160)
  v.place(50, 10, 400, 300)
  check v.top == 28 and v.tickX(0) == 50 - 128
  check v.xTick(v.tickX(960.0)) == 960 and v.xTick(-1e9) == 0
    # an absent mouse parks at -FLT_MAX
  check v.rowY(3) == 28f32 + 3 * 14 - 100
  check v.yRow(v.rowY(7) + 1) == 7 and v.yRow(-1e9) == 0 and v.yRow(1e9) == 127
  v.scrollY = 1e6
  v.place(50, 10, 400, 300) # scroll stays inside the content
  check v.scrollY == 128f32 * 14 - 300
  var b: Box
  v.scrollX = 128
  v.scrollY = 100
  b.start(v, v2(100, 60)) # content (178, 132) at scroll (128, 100)
  check b.rect(v, v2(60, 40)) == (60f32, 40f32, 100f32, 60f32)
  v.scrollX = 0
  v.scrollY = 0
  check b.rect(v, v2(500, 500)) == (50f32 + 178, 28f32 + 132, 500f32, 500f32)
    # follows the scroll
  b.start(v, v2(100, 60), scrollsY = false)
  v.scrollY = 50
  check b.rect(v, v2(200, 100)) == (100f32, 60f32, 200f32, 100f32)
    # y stays on the screen
