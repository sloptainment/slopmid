## The .smm project file: one record per line, keyword first.
##   bpm 120                 clip <name>             track <bank> <program> <ccRes> <rhythm 0|1>
##   note <start> <len> <pitch> <vel>                bend <t v> <t v> ...  (of the last note)
##   cc <curve> <t v> <t v> ...  (of the last track) place <clip> <lane> <start> <len> <offset>
import std/[sequtils, strformat, strutils]
import roll

type Smm* = tuple[bpm: float, clips: seq[seq[Track]], names: seq[string], placements: seq[Placement]]

proc toSmm*(s: Smm): string =
  result = &"bpm {s.bpm}\n"
  for i, clip in s.clips:
    result.add "clip" & (if s.names[i] == "": "" else: " " & s.names[i]) & "\n"
    for t in clip:
      result.add &"track {t.bank} {t.program} {t.ccRes} {t.rhythm.int}\n"
      for n in t.notes:
        result.add &"note {n.start} {n.len} {n.pitch} {n.vel}\n"
        if n.bend.len > 0:
          result.add "bend"
          for p in n.bend:
            result.add &" {p.t} {p.v}"
          result.add "\n"
      for c, pts in t.cc:
        if pts.len > 0:
          result.add &"cc {c}"
          for p in pts:
            result.add &" {p.t} {p.v}"
          result.add "\n"
  for p in s.placements:
    result.add &"place {p.clip} {p.lane} {p.start} {p.len} {p.offset}\n"

proc fromSmm*(text: string): Smm =
  ## Raises ValueError on a malformed file.
  result.bpm = 120
  var line: string
  template bad() =
    raise newException(ValueError, "bad line: " & line)
  template trk(): untyped = result.clips[^1][^1]
  for l in text.splitLines:
    line = l.strip
    let w = line.splitWhitespace
    if w.len == 0:
      continue
    case w[0]
    of "bpm":
      if w.len != 2: bad()
      result.bpm = clamp(parseFloat(w[1]), 20, 999)
    of "clip":
      result.clips.add @[]
      result.names.add (if line.len > 5: line[5 .. ^1] else: "")
    of "track":
      let a = w[1 .. ^1].map(parseInt)
      if a.len != 4 or result.clips.len == 0 or a[2] notin 0 .. 3: bad()
      result.clips[^1].add Track(bank: a[0], program: a[1], ccRes: a[2], rhythm: a[3] != 0)
    of "note":
      let a = w[1 .. ^1].map(parseInt)
      if a.len != 4 or result.clips.len == 0 or result.clips[^1].len == 0 or
          a[0] < 0 or a[1] <= 0 or a[2] notin 0 .. 127 or a[3] notin 0 .. 127: bad()
      trk.notes.add Note(start: a[0], len: a[1], pitch: a[2], vel: a[3])
    of "bend":
      if w.len < 5 or w.len mod 2 == 0 or result.clips.len == 0 or result.clips[^1].len == 0 or
          trk.notes.len == 0: bad()
      for i in countup(1, w.high, 2):
        trk.notes[^1].bend.add (parseInt(w[i]), parseFloat(w[i + 1]), false)
    of "cc":
      if w.len < 4 or w.len mod 2 != 0 or result.clips.len == 0 or result.clips[^1].len == 0: bad()
      let c = parseInt(w[1])
      if c notin 0 .. 2: bad()
      for i in countup(2, w.high, 2):
        trk.cc[c].add (parseInt(w[i]), parseInt(w[i + 1]), false)
    of "place":
      let a = w[1 .. ^1].map(parseInt)
      if a.len != 5 or a[1] notin 0 ..< Lanes or a[3] <= 0: bad()
      result.placements.add Placement(clip: a[0], lane: a[1], start: a[2], len: a[3], offset: a[4])
    else:
      bad()
  if result.clips.len == 0:
    raise newException(ValueError, "no clips")
  for p in result.placements:
    if p.clip notin 0 .. result.clips.high:
      raise newException(ValueError, &"placement of missing clip {p.clip}")

when isMainModule:
  var s: Smm = (bpm: 97.5, clips: @[@[Track(bank: 1, program: 5, ccRes: 2)], @[Track(rhythm: true)]],
                names: @["Intro one", ""], placements: @[Placement(clip: 1, lane: 3, start: 96, len: 384, offset: 48)])
  s.clips[0][0].notes.add Note(start: 0, len: 96, pitch: 60, vel: 100,
                               bend: @[(0, 0.0, false), (48, -1.25, false), (96, 0.0, false)])
  s.clips[0][0].cc[2].add (0, 10, false)
  s.clips[0][0].cc[2].add (384, 127, false)
  s.clips[1][0].notes.add Note(start: 48, len: 24, pitch: 36, vel: 110)
  let r = fromSmm(s.toSmm)
  assert r == s, s.toSmm
  for bad in ["note 0 96 60 100", "clip\ntrack 0 0 3 0\nnote 0 96 200 100", "clip\nplace 1 0 0 96 0", "clip\nfoo", "", "clip\nbpm x"]:
    var failed = false
    try: discard fromSmm(bad)
    except ValueError: failed = true
    assert failed, bad
  echo "smm ok"
