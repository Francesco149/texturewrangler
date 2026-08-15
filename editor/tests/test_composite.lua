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

-- regression: the cache entry for a size-changing layer (downscale/crop)
-- stored the POST-layer size while the hit check compared the PRE-layer
-- size, so the layer missed the cache every frame — the composite and
-- every thumbnail re-rendered (and re-registered GPU textures) each frame.
function M.test_downscale_cache_hits()
  fresh()
  add_fill({ r = 100, g = 100, b = 100, a = 255 })
  local d = doc.new_layer("downscale")
  d.params.size = { 8, 8 }
  doc.add_layer(d)
  local img1 = render.composite(nil, { 16, 16 }, doc._cache)
  local img2 = render.composite(nil, { 16, 16 }, doc._cache)
  local img3 = render.composite(nil, { 16, 16 }, doc._cache)
  t.true_(img1 == img2, "composite is a cache hit (same userdata)")
  t.true_(img2 == img3, "stable across calls")
  -- thumbs too (the panel re-renders one per row per frame)
  local t1 = render.thumb(2)
  local t2 = render.thumb(2)
  t.true_(t1 == t2, "thumbnail cache hits for a downscaled project")
  -- a version bump still re-renders
  doc.bump(d)
  local img4 = render.composite(nil, { 16, 16 }, doc._cache)
  t.true_(img4 ~= img3, "bump invalidates the cache")
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
  -- composite AT the group: children composite FROM the red below
  local at = render.composite(doc.stack_index(g.id), { 16, 16 }, doc._cache)
  local r, g2 = tex.get(at, 0, 0)
  t.true_(r > 100 and g2 > 100, "include-below mixes red+green, r=" .. r)
  -- and it REPLACES the composite (no double-blend): full composite = same
  local img = render.composite(nil, { 16, 16 }, doc._cache)
  local r3, g3 = tex.get(img, 0, 0)
  t.true_(math.abs(r3 - r) < 2 and math.abs(g3 - g2) < 2,
          "full composite = baked group, r=" .. r3)
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

-- regression: with a downscale below, the preview shows the WORKING size
-- (not doc.canvas), but clicks were normalized against doc.canvas — the
-- dab landed shrunk near the texture origin. The preview now rescales
-- clicks into canvas space and paint_begin stores the working size, so a
-- click at working (4,4) on a 32→8 downscaled project paints at (4,4)
-- with a full-size brush.
function M.test_paint_stroke_scales_to_working_size()
  fresh() -- canvas 16x16 here; use a downscale 16 → 8
  add_fill({ r = 100, g = 100, b = 100, a = 255 })
  local d = doc.new_layer("downscale")
  d.params.size = { 8, 8 }
  d.params.filter = "box"
  doc.add_layer(d)
  local p = doc.new_layer("paint")
  p.params.size = 4
  doc.add_layer(p)
  -- the preview mapping: click working (4,4) → canvas coords
  local w, h = 8, 8 -- displayed composite size
  local to_canvas = function(v, dim)
    return v * doc.canvas[dim] / (dim == 1 and w or h)
  end
  doc.paint_begin(p.id, w, h)
  doc.paint_append(to_canvas(4, 1), to_canvas(4, 2))
  doc.paint_end()
  -- paint output at the working size
  local img = render.layer(p, { 8, 8 }, nil, nil)
  local a = select(4, tex.get(img, 4, 4))
  t.true_(a > 200, "dab at click position, a=" .. a)
  local a0 = select(4, tex.get(img, 0, 0))
  t.eq(a0, 0, "origin untouched")
  -- brush radius: size 4 → radius 2 → ~5px dab, not sub-pixel
  local r = select(4, tex.get(img, 5, 4))
  t.true_(r > 100, "brush has real radius, a=" .. r)
  local comp = render.composite(nil, { 16, 16 }, doc._cache)
  t.eq(select(1, tex.size(comp)), 8, "composite stays downscaled")
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
  -- edges pull from the middle (mask=1); boundary step = source step
  t.pixel_eq(img, 0, 0, 136, 136, 136, 255, "left edge = src(8)")
  t.pixel_eq(img, 15, 0, 119, 119, 119, 255, "right edge = src(7)")
  local lv = select(1, tex.get(img, 0, 0))
  local rv = select(1, tex.get(img, 15, 0))
  t.true_(math.abs(lv - rv) <= 17, "boundary step reduced, " .. lv .. " vs " .. rv)
end

-- ── crop layer ──────────────────────────────────────────────────────────────

function M.test_crop_layer_region()
  fresh()
  add_fill({ r = 255, g = 0, b = 0, a = 255 })
  local c = doc.new_layer("crop")
  c.params.w = 8
  c.params.h = 8
  doc.add_layer(c)
  local img = render.composite(nil, { 16, 16 }, doc._cache)
  local w, h = tex.size(img)
  t.eq(w, 8, "crop width 8")
  t.eq(h, 8, "crop height 8")
  t.all_pixels(img, 255, 0, 0, 255, "cropped region keeps color")
end

function M.test_crop_layer_offset()
  fresh()
  local g = tex.new(16, 16, { r = 0, g = 0, b = 0, a = 255 })
  for x = 0, 15 do
    local v = math.floor(x / 15 * 255)
    for y = 0, 15 do tex.set(g, x, y, v, v, v, 255) end
  end
  local l = doc.new_layer("image")
  doc._asset_cache["g"] = g
  doc.assets["g"] = { file = "g.png", w = 16, h = 16 }
  l.params.asset = "g"
  doc.add_layer(l)
  local c = doc.new_layer("crop")
  c.params.x = 8
  c.params.w = 8
  c.params.h = 16
  doc.add_layer(c)
  local img = render.composite(nil, { 16, 16 }, doc._cache)
  local w, h = tex.size(img)
  t.eq(w, 8, "offset crop width")
  t.eq(h, 16, "offset crop height")
  -- the crop starts at source x=8 → v = floor(8/15*255) = 136
  local r = select(1, tex.get(img, 0, 0))
  t.near(r, 136, 2, "right half of gradient cropped, r=" .. r)
end

function M.test_crop_default_noop()
  fresh()
  add_fill({ r = 10, g = 20, b = 30, a = 255 })
  local c = doc.new_layer("crop") -- w/h = 0 means full source
  doc.add_layer(c)
  local img = render.composite(nil, { 16, 16 }, doc._cache)
  local w, h = tex.size(img)
  t.eq(w, 16, "default crop keeps width")
  t.eq(h, 16, "default crop keeps height")
  t.all_pixels(img, 10, 20, 30, 255, "full crop is a no-op")
end

function M.test_crop_first_layer_below_nil()
  fresh()
  local c = doc.new_layer("crop")
  c.params.w = 4
  c.params.h = 4
  doc.add_layer(c)
  local img = render.composite(nil, { 16, 16 }, doc._cache)
  t.true_(img ~= nil, "crop first layer renders")
  local w, h = tex.size(img)
  t.eq(w, 4, "crop of transparent at 4x4")
  t.eq(h, 4, "crop of transparent at 4x4")
  t.all_pixels(img, 0, 0, 0, 0, "transparent stays transparent")
end

-- ── edge cases: effects with nothing below them ─────────────────────────────

function M.test_grade_first_layer_below_nil()
  fresh()
  local g = doc.new_layer("grade")
  doc.add_layer(g) -- index 1 → render(below = nil)
  local img = render.composite(nil, { 16, 16 }, doc._cache)
  t.true_(img ~= nil, "grade first layer renders")
  t.all_pixels(img, 0, 0, 0, 0, "default grade over nil → transparent")
end

function M.test_palette_first_layer_below_nil()
  fresh()
  local p = doc.new_layer("palette")
  p.params.colors = 2
  doc.add_layer(p)
  local img = render.composite(nil, { 16, 16 }, doc._cache)
  t.true_(img ~= nil, "palette first layer renders")
  t.all_pixels(img, 0, 0, 0, 0, "quantize of transparent stays transparent")
  t.true_(p.params.palette ~= nil, "palette still extracted")
end

function M.test_seamless_first_layer_below_nil()
  fresh()
  local s = doc.new_layer("seamless")
  doc.add_layer(s)
  local img = render.composite(nil, { 16, 16 }, doc._cache)
  t.true_(img ~= nil, "seamless first layer renders")
  t.all_pixels(img, 0, 0, 0, 0, "seamless of transparent stays transparent")
end

function M.test_downscale_first_layer()
  fresh()
  local d = doc.new_layer("downscale")
  d.params.size = { 8, 8 }
  doc.add_layer(d)
  local img = render.composite(nil, { 16, 16 }, doc._cache)
  local w, h = tex.size(img)
  t.eq(w, 8, "downscale first: width 8")
  t.eq(h, 8, "downscale first: height 8")
  t.all_pixels(img, 0, 0, 0, 0, "transparent at the new size")
end

function M.test_alpha_mask_below_at_index_one()
  fresh()
  local mask = doc.new_layer("fill", "mask")
  mask.params.type = "solid"
  mask.params.c0 = { r = 0, g = 0, b = 0, a = 128 }
  mask.blend = "alphamask"
  mask.params.scope = "below"
  doc.add_layer(mask) -- index 1: scope=below has nothing below → composite scope
  local img = render.composite(nil, { 16, 16 }, doc._cache)
  t.true_(img ~= nil, "mask at index 1 renders")
  local _, _, _, a = tex.get(img, 0, 0)
  t.eq(a, 128, "mask output passes through unchanged, a=" .. a)
end

function M.test_paint_first_layer()
  fresh()
  local p = doc.new_layer("paint")
  p.params.size = 4
  doc.add_layer(p)
  doc.paint_begin(p.id)
  doc.paint_append(4, 4)
  doc.paint_end()
  local img = render.composite(nil, { 16, 16 }, doc._cache)
  t.true_(img ~= nil, "paint first layer renders")
  local a = select(4, tex.get(img, 4, 4))
  t.true_(a > 200, "stroke over transparent, a=" .. a)
  local a2 = select(4, tex.get(img, 15, 15))
  t.eq(a2, 0, "corner untouched")
end

function M.test_export_layer_only()
  fresh()
  local e = doc.new_layer("export")
  e.params.export_name = "only"
  doc.add_layer(e)
  local img = render.composite(nil, { 16, 16 }, doc._cache)
  t.eq(img, nil, "export marker only → composite nil")
end

function M.test_group_only_self_only()
  fresh()
  local g = doc.new_layer("group")
  g.params.include_below = false
  doc.add_layer(g)
  local c = doc.new_layer("fill", "green")
  c.params.type = "solid"
  c.params.c0 = { r = 0, g = 255, b = 0, a = 255 }
  doc.add_layer(c, g.id)
  local img = render.composite(nil, { 16, 16 }, doc._cache)
  t.true_(img ~= nil, "self-only group alone renders")
  t.all_pixels(img, 0, 255, 0, 255, "group child fill shows")
end

function M.test_group_only_include_below()
  fresh()
  local g = doc.new_layer("group")
  g.params.include_below = true
  doc.add_layer(g)
  local c = doc.new_layer("fill", "green")
  c.params.type = "solid"
  c.params.c0 = { r = 0, g = 255, b = 0, a = 255 }
  doc.add_layer(c, g.id)
  local img = render.composite(nil, { 16, 16 }, doc._cache)
  t.true_(img ~= nil, "include-below group alone renders")
  t.all_pixels(img, 0, 255, 0, 255, "include-below with nil below → child only")
end

function M.test_empty_group_only()
  fresh()
  local g = doc.new_layer("group")
  doc.add_layer(g)
  local img = render.composite(nil, { 16, 16 }, doc._cache)
  t.eq(img, nil, "empty group only → composite nil")
end

-- ── edge cases: layer visibility ────────────────────────────────────────────

function M.test_hidden_top_layer()
  fresh()
  add_fill({ r = 255, g = 0, b = 0, a = 255 })
  local g = add_fill({ r = 0, g = 255, b = 0, a = 255 })
  local both = render.composite(nil, { 16, 16 }, doc._cache)
  t.all_pixels(both, 0, 255, 0, 255, "top green covers red")
  g.visible = false
  doc.bump(g)
  local hid = render.composite(nil, { 16, 16 }, doc._cache)
  t.all_pixels(hid, 255, 0, 0, 255, "hidden top → red shows")
  g.visible = true
  doc.bump(g)
  local back = render.composite(nil, { 16, 16 }, doc._cache)
  t.all_pixels(back, 0, 255, 0, 255, "unhide → green again")
end

function M.test_hidden_downscale_keeps_size()
  fresh()
  add_fill({ r = 50, g = 100, b = 150, a = 255 })
  local d = doc.new_layer("downscale")
  d.params.size = { 4, 4 }
  doc.add_layer(d)
  d.visible = false
  doc.bump(d)
  local img = render.composite(nil, { 16, 16 }, doc._cache)
  local w, h = tex.size(img)
  t.eq(w, 16, "hidden downscale keeps width 16")
  t.eq(h, 16, "hidden downscale keeps height 16")
  t.all_pixels(img, 50, 100, 150, 255, "fill unchanged")
  d.visible = true
  doc.bump(d)
  local small = render.composite(nil, { 16, 16 }, doc._cache)
  local w2 = select(1, tex.size(small))
  t.eq(w2, 4, "unhide → downscaled to 4")
end

function M.test_hidden_group()
  fresh()
  add_fill({ r = 255, g = 0, b = 0, a = 255 })
  local g = doc.new_layer("group")
  g.params.include_below = false
  doc.add_layer(g)
  local c = doc.new_layer("fill", "green")
  c.params.type = "solid"
  c.params.c0 = { r = 0, g = 255, b = 0, a = 255 }
  doc.add_layer(c, g.id)
  g.visible = false
  doc.bump(g)
  local img = render.composite(nil, { 16, 16 }, doc._cache)
  t.all_pixels(img, 255, 0, 0, 255, "hidden group contributes nothing")
end

function M.test_hidden_group_child()
  fresh()
  add_fill({ r = 255, g = 0, b = 0, a = 255 })
  local g = doc.new_layer("group")
  g.params.include_below = false
  doc.add_layer(g)
  local c = doc.new_layer("fill", "green")
  c.params.type = "solid"
  c.params.c0 = { r = 0, g = 255, b = 0, a = 255 }
  doc.add_layer(c, g.id)
  c.visible = false
  doc.bump(c)
  local img = render.composite(nil, { 16, 16 }, doc._cache)
  t.all_pixels(img, 255, 0, 0, 255, "hidden group child contributes nothing")
end

function M.test_all_hidden_stack_nil()
  fresh()
  local a = add_fill({ r = 1, g = 2, b = 3, a = 255 })
  a.visible = false
  doc.bump(a)
  local img = render.composite(nil, { 16, 16 }, doc._cache)
  t.eq(img, nil, "all hidden → composite nil")
end

-- ── noise panel: Monochrome/Tinted combo index round-trip ───────────────────
-- ui.combo is 1-based; the stored param is 0/1. The panel must translate
-- both ways or the combo gets stuck (selecting "Tinted" stored 2, which the
-- kernel treated as monochrome, and Monochrome could never be re-selected).

function M.test_noise_color_combo_roundtrip()
  fresh()
  local n = doc.new_layer("noise")
  doc.add_layer(n)
  local seen = nil
  local fake = setmetatable({}, {
    __index = function(_, k) return function() end end, -- no-op controls
  })
  fake.combo = function(label, items, current, on_change)
    if label == "Color" then seen = { current = current, on_change = on_change } end
  end
  local noise_mod = require("layers.noise")
  -- default Monochrome (colorize=0) must show as 1-based index 1
  noise_mod.panel(n, fake)
  t.eq(seen.current, 1, "monochrome shown at index 1")
  -- user selects "Tinted" (1-based 2) → param becomes 1
  seen.on_change(2)
  t.eq(n.params.colorize, 1, "tinted stores 1")
  -- reopen: Tinted shows at index 2
  seen = nil
  noise_mod.panel(n, fake)
  t.eq(seen.current, 2, "tinted shown at index 2")
  -- user selects "Monochrome" (1-based 1) → param back to 0
  seen.on_change(1)
  t.eq(n.params.colorize, 0, "monochrome stores 0")
  -- serialized round-trip stays 0/1
  t.eq(doc.serialize().layers[1].params.colorize, 0, "serialized colorize is 0")
end

-- ── edge cases: undo / tiny canvas ──────────────────────────────────────────

function M.test_undo_to_empty_stack()
  fresh()
  -- undo snapshots are pushed by doc.mutate (add_fill bypasses it)
  doc.mutate(function()
    local a = doc.new_layer("fill", "red")
    a.params.type = "solid"
    a.params.c0 = { r = 255, g = 0, b = 0, a = 255 }
    doc.add_layer(a)
  end, "Add red")
  doc.mutate(function()
    local b = doc.new_layer("fill", "green")
    b.params.type = "solid"
    b.params.c0 = { r = 0, g = 255, b = 0, a = 255 }
    doc.add_layer(b)
  end, "Add green")
  t.true_(undo.can_undo(), "undo available")
  t.true_(undo.do_undo(), "undo removes top")
  t.true_(undo.do_undo(), "undo removes first")
  local img = render.composite(nil, { 16, 16 }, doc._cache)
  t.eq(img, nil, "undo to empty → composite nil")
  t.true_(undo.do_redo(), "redo restores first fill")
  local img2 = render.composite(nil, { 16, 16 }, doc._cache)
  t.all_pixels(img2, 255, 0, 0, 255, "redo → red fill back")
end

function M.test_canvas_1x1_all_layer_types()
  fresh()
  doc.canvas = { 1, 1 }
  for _, ty in ipairs({ "fill", "noise", "grade", "palette", "seamless",
                        "downscale", "paint", "export", "group" }) do
    local l = doc.new_layer(ty)
    if ty == "fill" then
      l.params.type = "solid"
      l.params.c0 = { r = 255, g = 0, b = 0, a = 255 }
    elseif ty == "downscale" then
      l.params.size = { 1, 1 }
    end
    doc.add_layer(l)
  end
  -- image layer with a real 1×1 asset as the top layer
  doc._asset_cache["one"] = tex.new(1, 1, { r = 9, g = 9, b = 9, a = 255 })
  doc.assets["one"] = { file = "one.png", w = 1, h = 1 }
  local im = doc.new_layer("image")
  im.params.asset = "one"
  doc.add_layer(im)
  local img = render.composite(nil, { 1, 1 }, doc._cache)
  t.true_(img ~= nil, "1×1 stack composites")
  local w, h = tex.size(img)
  t.eq(w, 1, "width 1")
  t.eq(h, 1, "height 1")
end

return M
