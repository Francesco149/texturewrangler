-- tools/make_demo_project.lua — build a demo project for UI smoke shots.
-- Run via the console: require("tools.make_demo_project") (tools dir must
-- be on package.path) or copy the body into the REPL.

local function make_demo(dir)
  doc.path = dir
  doc.name = "demo-granite"
  doc.canvas = { 64, 64 }
  doc.layers = {}
  doc.exports = {}
  doc.assets = {}
  doc.loaded = true
  undo.clear()

  -- 1: noise base (the "photo source")
  local n = doc.new_layer("noise", "Stone")
  n.params.type = "fbm"
  n.params.scale = 10
  n.params.octaves = 4
  n.params.seed = 42
  doc.add_layer(n)

  -- 2: grade — contrast before blur (the video's order)
  local g = doc.new_layer("grade", "Contrast")
  g.params.contrast = 0.35
  doc.add_layer(g)

  -- 3: blur — softens detail before posterization
  local b = doc.new_layer("noise", "Blur-pass") -- placeholder; real blur layer below
  doc.remove_layer(b.id)

  -- 3: seamless — make it tile
  local s = doc.new_layer("seamless", "Tile")
  doc.add_layer(s)

  -- 4: palette — the retro quantize (16 colors, fs dither)
  local p = doc.new_layer("palette", "Quantize 16")
  p.params.colors = 16
  p.params.dither = "fs"
  doc.add_layer(p)

  -- 5: color infusion (the video's overlay trick) — fill + overlay blend
  local f = doc.new_layer("fill", "Mood")
  f.params.type = "solid"
  f.params.c0 = { r = 90, g = 120, b = 170, a = 255 } -- icy blue
  f.blend = "overlay"
  f.opacity = 0.45
  doc.add_layer(f)

  -- 6: export capture at this point (partial composite)
  local e = doc.new_layer("export", "Pre-paint")
  e.params.export_name = "pre-paint"
  doc.add_layer(e)

  -- 7: paint layer with a few strokes
  local pt = doc.new_layer("paint", "Details")
  pt.params.size = 5
  pt.params.hardness = 0.6
  doc.add_layer(pt)
  doc.paint_begin(pt.id)
  doc.paint_append(12, 14)
  doc.paint_append(16, 18)
  doc.paint_append(20, 17)
  doc.paint_append(24, 20)
  doc.paint_end()
  doc.paint_begin(pt.id)
  doc.paint_append(40, 44)
  doc.paint_append(44, 40)
  doc.paint_append(48, 44)
  doc.paint_end()

  doc.save()
  tw.log("demo project written to " .. dir)
end

return make_demo
