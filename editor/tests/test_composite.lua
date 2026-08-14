-- test_composite.lua — the layer stack as a system: composite correctness,
-- non-destructive modifier semantics, palette recolor, downscale size
-- flow, groups (include-below), alpha-mask scope, paint strokes.

local t = require("testlib")
local tex = tw.tex

local M = {}

local function fresh()
  doc.deserialize({ name = "c", canvas = { 16, 16 }, layers = {},
                    exports = {}, assets = {} })
  undo.clear()
end

local function add_fill(color, blend, opacity)
  local l = doc.new_layer("fill", "Fill")
  l.params.type = "solid"
  l.params.c0 = color
  l.blend = blend or "normal"
  l.opacity = opacity or 1
  doc.add_layer(l)
  return l
end

function M.test_empty_composite_nil()
  fresh()
  t.eq(render.composite(nil, { 16, 16 }, doc._cache), nil, "empty stack → nil")
end

function M.test_single_fill()
  fresh()
  add_fill({ r = 200, g = 100, b = 50, a = 255 })
  local img = render.composite(nil, { 16, 16 }, doc._cache)
  t.true_(img ~= nil, "composite exists")
  t.all_pixels(img, 200, 100, 50, 255, "solid fill composite")
end

function M.test_grade_modifier_non_destructive()
  fresh()
  add_fill({ r = 100, g = 100, b = 100, a = 255 })
  local plain = render.composite(nil, { 16, 16 }, doc._cache)
  local g = doc.new_layer("grade")
  g.params.brightness = 0.5
  doc.add_layer(g)
  local graded = render.composite(nil, { 16, 16 }, doc._cache)
  local gr = select(1, tex.get(graded, 0, 0))
  local pr = select(1, tex.get(plain, 0, 0))
  t.true_(gr > pr, "grade brightens, " .. pr .. " → " .. gr)
  -- remove the modifier → back to original
  doc.remove_layer(g.id)
  local restored = render.composite(nil, { 16, 16 }, doc._cache)
  t.all_pixels(restored, 100, 100, 100, 255, "remove grade → original")
end

function M.test_downscale_changes_size()
  fresh()
  add_fill({ r = 50, g = 100, b = 150, a = 255 })
  local d = doc.new_layer("downscale")
  d.params.size = { 8, 8 }
  d.params.filter = "box"
  doc.add_layer(d)
  local img = render.composite(nil, { 16, 16 }, doc._cache)
  local w, h = tex.size(img)
  t.eq(w, 8, "width 8")
  t.eq(h, 8, "height 8")
  t.all_pixels(img, 50, 100, 150, 255, "solid stays solid")
end

function M.test_downscale_removal_reverts_size()
  fresh()
  add_fill({ r = 1, g = 2, b = 3, a = 255 })
  local d = doc.new_layer("downscale")
  d.params.size = { 4, 4 }
  doc.add_layer(d)
  local small = render.composite(nil, { 16, 16 }, doc._cache)
  local w = select(1, tex.size(small))
  t.eq(w, 4, "downscaled")
  doc.remove_layer(d.id)
  local big = render.composite(nil, { 16, 16 }, doc._cache)
  local w2 = select(1, tex.size(big))
  t.eq(w2, 16, "reverted to canvas")
end

function M.test_palette_layer_flow()
  fresh()
  add_fill({ r = 200, g = 30, b = 30, a = 255 })
  local p = doc.new_layer("palette")
  p.params.colors = 2
  doc.add_layer(p)
  local img = render.composite(nil, { 16, 16 }, doc._cache)
  t.true_(p.params.palette ~= nil, "palette extracted")
  local r = select(1, tex.get(img, 0, 0))
  t.true_(r > 180, "red stays red-ish")
  -- recolor: edit the palette entry, pixels follow
  local before = tex.get(img, 0, 0)
  p.params.palette[1] = { r = 0, g = 200, b = 0, a = 255 }
  doc.bump(p)
  local img2 = render.composite(nil, { 16, 16 }, doc._cache)
  local g2 = select(2, tex.get(img2, 0, 0))
  t.true_(g2 > 180, "recolor → green, g=" .. g2)
end

function M.test_group_self_only()
  fresh()
  add_fill({ r = 255, g = 0, b = 0, a = 255 }) -- red below
  local g = doc.new_layer("group")
  g.params.include_below = false
  doc.add_layer(g)
  local c = doc.new_layer("fill", "opaque green")
  c.params.type = "solid"
  c.params.c0 = { r = 0, g = 255, b = 0, a = 255 }
  doc.add_layer(c, g.id)
  local img = render.composite(nil, { 16, 16 }, doc._cache)
  local r, gg = tex.get(img, 0, 0)
  t.true_(gg > 200 and r < 50, "opaque green covers red, r=" .. r .. " g=" .. gg)
  -- the group's own output (layer-only) is green with NO red
  local only = render.layer_only(g.id, { 16, 16 })
  local r2, g2 = tex.get(only, 0, 0)
  t.true_(g2 > 200 and r2 < 50, "self-only group output is pure green")
end

function M.test_group_include_below()
  fresh()
  add_fill({ r = 255, g = 0, b = 0, a = 255 }) -- red below
  local g = doc.new_layer("group")
  g.params.include_below = true
  doc.add_layer(g)
  local c = doc.new_layer("fill", "translucent green")
  c.params.type = "solid"
  c.params.c0 = { r = 0, g = 255, b = 0, a = 128 }
  doc.add_layer(c, g.id)
  -- layer-only output: children composite FROM the red below → red+green
  local only = render.layer_only(g.id, { 16, 16 })
  local r, g2 = tex.get(only, 0, 0)
  t.true_(r > 100 and g2 > 100, "include-below group output mixes red+green, r=" .. r)
  -- and it REPLACES the composite (no double-blend)
  local img = render.composite(nil, { 16, 16 }, doc._cache)
  local r3, g3 = tex.get(img, 0, 0)
  t.true_(r3 > 100 and g3 > 100, "composite shows the baked group, r=" .. r3)
end

function M.test_group_semitransparent_over_stack()
  fresh()
  add_fill({ r = 255, g = 0, b = 0, a = 255 }) -- red below
  local g = doc.new_layer("group")
  g.params.include_below = false
  doc.add_layer(g)
  local c = doc.new_layer("fill", "semi green")
  c.params.type = "solid"
  c.params.c0 = { r = 0, g = 255, b = 0, a = 128 }
  doc.add_layer(c, g.id)
  -- self-only group blends over the stack like any layer → red shows through
  local img = render.composite(nil, { 16, 16 }, doc._cache)
  local r, g2 = tex.get(img, 0, 0)
  t.true_(r > 100 and g2 > 100, "translucent self-only group lets red through")
end

function M.test_alpha_mask_scope_below()
  fresh()
  local base = doc.new_layer("fill", "base")
  base.params.type = "solid"
  base.params.c0 = { r = 200, g = 100, b = 50, a = 255 }
  doc.add_layer(base)
  -- mask layer: half-alpha fill, alphamask, scope below
  local mask = doc.new_layer("fill", "mask")
  mask.params.type = "solid"
  mask.params.c0 = { r = 0, g = 0, b = 0, a = 128 }
  mask.blend = "alphamask"
  mask.params.scope = "below"
  doc.add_layer(mask)
  local img = render.composite(nil, { 16, 16 }, doc._cache)
  local r, g, b, a = tex.get(img, 0, 0)
  t.near(a, 128, 1, "mask halves alpha, a=" .. a)
  t.near(r, 200 * 128 / 255, 1, "mask scales color")
end

function M.test_paint_stroke()
  fresh()
  local p = doc.new_layer("paint")
  p.params.size = 4
  doc.add_layer(p)
  doc.paint_begin(p.id)
  doc.paint_append(4, 4)
  doc.paint_append(4, 5)
  doc.paint_end()
  local img = render.composite(nil, { 16, 16 }, doc._cache)
  t.true_(img ~= nil, "composite with stroke")
  local r, g, b, a = tex.get(img, 4, 4)
  t.true_(a > 200, "stroke covers center, a=" .. a)
  local r2, g2, b2, a2 = tex.get(img, 15, 15)
  t.eq(a2, 0, "far corner untouched")
  t.true_(doc._in_flight == nil, "no in-flight stroke after end")
end

function M.test_export_layer_marker()
  fresh()
  add_fill({ r = 10, g = 20, b = 30, a = 255 })
  local e = doc.new_layer("export")
  e.params.export_name = "mid"
  doc.add_layer(e)
  local img = render.composite(nil, { 16, 16 }, doc._cache)
  t.all_pixels(img, 10, 20, 30, 255, "export layer is transparent to composite")
end

function M.test_noise_layer_in_stack()
  fresh()
  local n = doc.new_layer("noise")
  n.params.seed = 7
  doc.add_layer(n)
  local img = render.composite(nil, { 16, 16 }, doc._cache)
  local w, h = tex.size(img)
  t.eq(w, 16, "noise fills canvas")
  local r = select(1, tex.get(img, 3, 3))
  t.true_(r >= 0 and r <= 255, "noise in range")
end

function M.test_seamless_layer()
  fresh()
  local grad = tex.new(16, 16, { r = 0, g = 0, b = 0, a = 255 })
  for x = 0, 15 do
    local v = math.floor(x / 15 * 255)
    for y = 0, 15 do tex.set(grad, x, y, v, v, v, 255) end
  end
  local l = doc.new_layer("image")
  doc._asset_cache["t"] = grad
  doc.assets["t"] = { file = "t.png", w = 16, h = 16 }
  l.params.asset = "t"
  doc.add_layer(l)
  local s = doc.new_layer("seamless")
  doc.add_layer(s)
  local img = render.composite(nil, { 16, 16 }, doc._cache)
  local lv = select(1, tex.get(img, 0, 0))
  local rv = select(1, tex.get(img, 15, 0))
  t.true_(math.abs(lv - rv) <= 2, "seamless edge continuity, " .. lv .. " vs " .. rv)
end

return M
