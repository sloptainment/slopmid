## The Clips window: the clip list, its name, and its tracks with their sounds, mute/solo and previews.

import std/strformat
import imgui
import model, edit, gm, common

proc clipsWindow*() =
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
    song.removeClip(gone)
    placeClip.setLen 0 # its clip numbers are stale
    clicked = -1
  igSameLine()
  if igButton("Duplicate"):
    focus(song.clip, -1) # deselects, so the copy has no selection
    song.duplicateClip(song.clip)
    focus(song.clips.high, -1)
  igSameLine()
  igText("Clip name: ")
  igSameLine()
  igSetNextItemWidth(-1)
  var buf: array[64, char]
  copyMem(
    addr buf[0],
    cstring(song.clips[song.clip].name),
    min(song.clips[song.clip].name.len, 63),
  )
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
    # the timeline, above the previews: click or drag sets the clip's playhead
    igTableNextRow()
    for _ in 0 .. 3:
      discard igTableNextColumn()
    let tl = igGetCursorScreenPosNonUDT()
    let tw = max(igGetContentRegionAvailNonUDT().x, 1)
    discard igInvisibleButton("timeline", v2(tw, RulerH))
    if igIsItemActive():
      song.clipPos = clamp((igGetIO().mousePos.x - tl.x) / tw * span, 0, span - 1)
    for b in 0 ..< int(span) div BarTicks:
      let x = tl.x + b.float32 * BarTicks.float32 / span * tw
      dl.addLine(v2(x, tl.y), v2(x, tl.y + RulerH), rgb(200, 200, 200))
      dl.addText(v2(x + 3, tl.y + 1), rgb(200, 200, 200), cstring($(b + 1)))
    for c in playLines():
      let x = tl.x + c / span * tw
      dl.addLine(v2(x, tl.y), v2(x, tl.y + RulerH), rgb(255, 255, 255, 180))
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
          if igSelectable(
            cstring(&"{t.bank:03}:{q:03} {name}"), not t.rhythm and q == t.program
          ):
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
      igBeginDisabled(t.rhythm)
      let side = igGetFrameHeight()
      if igButton("##lock", v2(side, side)):
        t.lockedchannel = if t.lockedchannel == -1: 0 else: -1
      # the padlock: a solid body and a closed shackle when locked, an outline and an open one when not
      let (b0, b1) = (igGetItemRectMinNonUDT(), igGetItemRectMaxNonUDT())
      let (s, ink) = (b1.x - b0.x, rgb(255, 255, 255, if t.rhythm: 90 else: 255))
      let (xl, xr, yTop, yBody) =
        (b0.x + 0.35 * s, b1.x - 0.35 * s, b0.y + 0.25 * s, b0.y + 0.5 * s)
      let (body0, body1) =
        (v2(b0.x + 0.25 * s, yBody), v2(b1.x - 0.25 * s, b1.y - 0.2 * s))
      dl.addLine(v2(xl, yBody), v2(xl, yTop), ink, 2)
      dl.addLine(v2(xl, yTop), v2(xr, yTop), ink, 2)
      if t.lockedchannel != -1:
        dl.addLine(v2(xr, yTop), v2(xr, yBody), ink, 2)
        dl.addRectFilled(body0, body1, ink)
      else:
        dl.addLine(v2(xr, yTop), v2(xr, b0.y + 0.36 * s), ink, 2)
        dl.addRect(body0, body1, ink, 0, 2)
      if t.lockedchannel != -1:
        igSameLine()
        igSetNextItemWidth(70)
        var locked = t.lockedchannel.int32
        if igInputInt("##channel", addr locked):
          t.lockedchannel = clamp(locked, 0, 15).int
            # the toggle unlocks; the field never does
      igEndDisabled()
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
