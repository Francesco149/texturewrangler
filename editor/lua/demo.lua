-- demo.lua — build a representative project (the video's workflow: noise
-- source → contrast → seamless → palette → color infusion → paint) for
-- headless UI smoke shots and manual exploration.
--   texturewrangler --demo <dir>   → create + open

local demo = {}

function demo.build(dir)
  doc.path = dir
  doc.name = "demo-granite"
  doc.canvas = { 64, 64 }
  doc.layers = {}
  doc.exports = {}
  doc.assets = {}
  doc.loaded = true
  undo.clear()

  -- 1: noise base ("photo source" stand-in)
  local n = doc.new_layer("noise", "Stone")
  n.params.type = "fbm"
  n.params.scale = 10
  n.params.octaves = 4
  n.params.seed = 42
  doc.add_layer(n)

  -- 2: grade — contrast before blur (the video's order)
  local g = doc.new_layer("grade", "Contrast")
  g.params.contrast = 0.35
  g.params.saturation = 0.9
  doc.add_layer(g)

  -- 3: seamless — makes the fbm noise tile exactly
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

  -- 7: paint layer with a couple of strokes
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

  -- 8: a group with a gradient vignette inside (include_below)
  local grp = doc.new_layer("group", "Vignette")
  doc.add_layer(grp)
  local vg = doc.new_layer("fill", "Vignette fill")
  vg.params.type = "radial"
  vg.params.c0 = { r = 0, g = 0, b = 0, a = 0 }
  vg.params.c1 = { r = 0, g = 0, b = 0, a = 200 }
  vg.params.rx = 0.75
  vg.params.ry = 0.75
  doc.add_layer(vg, grp.id)

  doc.save()
  tw.log("demo project built: " .. dir)
  return true
end

return demo
