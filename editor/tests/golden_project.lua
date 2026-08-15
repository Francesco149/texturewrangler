-- golden_project.lua — builds the golden regression project: a deterministic
-- stack exercising image layers, all major blend modes, opacity, a downscale
-- (the size-change cache path), an include-below group, a grade transform, a
-- palette quantizer and a paint stroke. The final composite is the golden:
-- tests/golden/composite.png must match pixel-exact or the build fails.
--
-- Assets are generated with the same pixel kernels used by the app, so the
-- whole project is reproducible from nothing. Re-blessing (make test-bless)
-- regenerates project.json, assets and composite.png — run it ONLY for an
-- intentional visual change, then commit all of tests/golden/.

local golden = {}

local tex = tw.tex

-- ── asset generators (deterministic) ────────────────────────────────────────

-- horizontal gradient, opaque, with a transparent notch at the top-left
local function make_grad(w, h)
  local img = tex.new(w, h, { r = 0, g = 0, b = 0, a = 255 })
  for y = 0, h - 1 do
    for x = 0, w - 1 do
      local v = math.floor(x / (w - 1) * 255)
      local a = (x < w / 4 and y < h / 4) and 128 or 255
      tex.set(img, x, y, v, math.floor(v * 0.8), math.floor(v * 0.5), a)
    end
  end
  return img
end

-- 2x2 checker, one cell transparent
local function make_check(w, h)
  local img = tex.new(w, h, { r = 0, g = 0, b = 0, a = 0 })
  for y = 0, h - 1 do
    for x = 0, w - 1 do
      local on = ((math.floor(x / 4) + math.floor(y / 4)) % 2) == 0
      local a = on and 255 or 0
      tex.set(img, x, y, 240, 200, 60, a)
    end
  end
  return img
end

-- diagonal stripes with alpha
local function make_stripes(w, h)
  local img = tex.new(w, h, { r = 0, g = 0, b = 0, a = 0 })
  for y = 0, h - 1 do
    for x = 0, w - 1 do
      local on = ((x + y) / 2) % 2 < 1
      local a = on and 200 or 40
      tex.set(img, x, y, 60, 180, 240, a)
    end
  end
  return img
end

-- ── project construction ────────────────────────────────────────────────────

-- populate the doc + write assets + project.json into dir
function golden.build(dir)
  doc.path = dir
  doc.name = "golden"
  doc.canvas = { 32, 32 }
  doc.layers = {}
  doc.exports = {}
  doc.assets = {}
  doc.loaded = true
  undo.clear()

  tw.file.mkdirs(dir .. "/assets")

  local function save_asset(name, img)
    local path = dir .. "/assets/" .. name
    tw.file.save_image(img, path)
    local w, h = tex.size(img)
    doc.assets[name:gsub("%.[%w]+$", "")] = { file = name, w = w, h = h }
    doc._asset_cache[name:gsub("%.[%w]+$", "")] = img
    return name:gsub("%.[%w]+$", "")
  end

  local function image_layer(name, aid, blend, opacity)
    local l = doc.new_layer("image", name)
    l.params.asset = aid
    l.params.filter = "bilinear"
    if blend then l.blend = blend end
    if opacity then l.opacity = opacity end
    doc.add_layer(l)
    return l
  end

  local function fill_layer(name, c, blend, opacity)
    local l = doc.new_layer("fill", name)
    l.params.type = "solid"
    l.params.c0 = c
    if blend then l.blend = blend end
    if opacity then l.opacity = opacity end
    doc.add_layer(l)
    return l
  end

  -- 1: gradient base (normal)
  image_layer("Base grad", save_asset("grad.png", make_grad(32, 32)))

  -- 2: downscale — the size-change cache path (regression: cache hits used
  -- to leave the working size unadvanced and broke blends above)
  local d = doc.new_layer("downscale", "Half")
  d.params.size = { 16, 16 }
  d.params.filter = "bilinear"
  doc.add_layer(d)

  -- 3: checker, multiply (transparent cells exercise alpha blending)
  image_layer("Check", save_asset("check.png", make_check(16, 16)),
              "multiply", 0.8)

  -- 4: translucent blue, screen
  fill_layer("Blue", { r = 40, g = 80, b = 255, a = 160 }, "screen", 0.6)

  -- 5: include-below group: stripes image + red overlay child
  local g = doc.new_layer("group", "Box")
  g.params.include_below = true
  doc.add_layer(g)
  local s = doc.new_layer("image", "Stripes")
  s.params.asset = save_asset("stripes.png", make_stripes(16, 16))
  s.params.filter = "bilinear"
  doc.add_layer(s, g.id)
  local r = doc.new_layer("fill", "Red")
  r.params.type = "solid"
  r.params.c0 = { r = 255, g = 60, b = 60, a = 140 }
  r.blend = "overlay"
  r.opacity = 0.6
  doc.add_layer(r, g.id)

  -- 6: yellow, difference
  fill_layer("Yellow", { r = 255, g = 220, b = 80, a = 200 }, "difference", 0.8)

  -- 7: grade transform
  local gr = doc.new_layer("grade", "Bright")
  gr.params.brightness = 0.08
  doc.add_layer(gr)

  -- 8: palette quantize (deterministic median-cut)
  local p = doc.new_layer("palette", "Quant")
  p.params.colors = 16
  p.params.dither = "none"
  doc.add_layer(p)

  -- 9: paint stroke on top (not quantized)
  local pt = doc.new_layer("paint", "Ink")
  pt.params.size = 2
  pt.params.hardness = 0.7
  doc.add_layer(pt)
  doc.paint_begin(pt.id)
  doc.paint_append(4, 4)
  doc.paint_append(5, 5)
  doc.paint_append(6, 5)
  doc.paint_append(7, 6)
  doc.paint_end()

  doc.save()
end

-- render the final composite (post-downscale: 16x16)
function golden.render()
  local img = render.composite(nil, doc.canvas, doc._cache)
  -- render again through the cache: both must be identical to the golden
  local img2 = render.composite(nil, doc.canvas, doc._cache)
  assert(img == img2, "golden: cached composite differs from fresh render")
  return img
end

-- pixel-exact compare of two images; returns count of differing pixels
function golden.diff(a, b)
  local w, h = tex.size(a)
  local bw, bh = tex.size(b)
  if w ~= bw or h ~= bh then return -1 end
  local n = 0
  for y = 0, h - 1 do
    for x = 0, w - 1 do
      local r1, g1, b1, a1 = tex.get(a, x, y)
      local r2, g2, b2, a2 = tex.get(b, x, y)
      if r1 ~= r2 or g1 ~= g2 or b1 ~= b2 or a1 ~= a2 then
        n = n + 1
        if n <= 4 then
          tw.log(string.format("golden diff @(%d,%d): (%d,%d,%d,%d) vs (%d,%d,%d,%d)",
                               x, y, r1, g1, b1, a1, r2, g2, b2, a2))
        end
      end
    end
  end
  return n
end

return golden
