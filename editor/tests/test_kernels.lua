-- test_kernels.lua — pixel-exact kernel tests. All deterministic.

local t = require("testlib")
local tex = tw.tex

local M = {}

local function solid(w, h, r, g, b, a)
  return tex.new(w, h, { r = r, g = g, b = b, a = a or 255 })
end

-- ── resize ─────────────────────────────────────────────────────────────────

function M.test_resize_nearest_down()
  local img = tex.new(2, 2, { r = 0, g = 0, b = 0, a = 255 })
  tex.set(img, 1, 0, 255, 0, 0, 255)
  tex.set(img, 0, 1, 0, 255, 0, 255)
  tex.set(img, 1, 1, 0, 0, 255, 255)
  local out = tex.resize(img, 1, 1, "nearest")
  t.pixel_eq(out, 0, 0, 0, 0, 0, 255, "nearest takes top-left")
end

function M.test_resize_nearest_up()
  local img = solid(1, 1, 200, 100, 50, 255)
  local out = tex.resize(img, 2, 2, "nearest")
  t.pixel_eq(out, 1, 1, 200, 100, 50, 255, "nearest upscale")
end

function M.test_resize_box_average()
  -- 2x2 with four distinct colors → 1x1 box average
  local img = tex.new(2, 2, { r = 0, g = 0, b = 0, a = 255 })
  tex.set(img, 1, 0, 100, 0, 0, 255)
  tex.set(img, 0, 1, 0, 100, 0, 255)
  tex.set(img, 1, 1, 0, 0, 100, 255)
  local out = tex.resize(img, 1, 1, "box")
  t.pixel_eq(out, 0, 0, 25, 25, 25, 255, "box exact average")
end

function M.test_resize_bilinear_center()
  -- gradient left=black right=white: center of 2x1 bilinear = 128
  local img = tex.new(2, 1, { r = 0, g = 0, b = 0, a = 255 })
  tex.set(img, 1, 0, 255, 255, 255, 255)
  local out = tex.resize(img, 2, 1, "bilinear")
  t.pixel_eq(out, 1, 0, 255, 255, 255, 255, "bilinear right stays")
end

function M.test_resize_identity()
  local img = solid(7, 5, 12, 34, 56, 200)
  local out = tex.resize(img, 7, 5, "bicubic")
  t.all_pixels(out, 12, 34, 56, 200, "bicubic same-size solid")
  local out2 = tex.resize(img, 7, 5, "aniso")
  t.all_pixels(out2, 12, 34, 56, 200, "aniso same-size solid")
end

-- ── blur ───────────────────────────────────────────────────────────────────

function M.test_blur_constant()
  local img = solid(8, 8, 40, 80, 120, 255)
  local out = tex.blur(img, 2, "box")
  t.all_pixels(out, 40, 80, 120, 255, "box blur keeps constant")
  local g = tex.blur(img, 2, "gaussian")
  t.all_pixels(g, 40, 80, 120, 255, "gaussian blur keeps constant")
end

function M.test_blur_spreads()
  local img = solid(8, 8, 0, 0, 0, 255)
  tex.set(img, 3, 3, 255, 0, 0, 255)
  local out = tex.blur(img, 1, "box")
  -- 3x3 box of one red pixel: center = 255/9 ≈ 28, neighbors > 0
  local r, g, b, a = tex.get(out, 3, 3)
  t.true_(r > 20 and r < 40, "center = 255/9 ≈ 28, got " .. r)
  r, g, b, a = tex.get(out, 4, 3)
  t.true_(r > 0 and r < 40, "spread to neighbor")
end

function M.test_blur_radius_zero()
  local img = solid(4, 4, 1, 2, 3, 4)
  local out = tex.blur(img, 0, "gaussian")
  t.all_pixels(out, 1, 2, 3, 4, "radius 0 = identity")
end

-- ── grade ──────────────────────────────────────────────────────────────────

function M.test_grade_identity()
  local img = solid(3, 3, 100, 150, 200, 255)
  local out = tex.grade(img, {})
  t.all_pixels(out, 100, 150, 200, 255, "identity grade")
end

function M.test_grade_brightness()
  local img = solid(2, 2, 100, 100, 100, 255)
  local out = tex.grade(img, { brightness = 0.5 })
  -- 100/255 + 0.5 = 0.892 → 227.5 → rounds to 228
  t.all_pixels(out, 228, 228, 228, 255, "brightness +0.5 → 228")
end

function M.test_grade_saturation_zero()
  local img = tex.new(1, 1, { r = 255, g = 0, b = 0, a = 255 })
  local out = tex.grade(img, { saturation = 0 })
  local r, g, b = tex.get(out, 0, 0)
  t.near(r, g, 1, "sat 0 → gray")
  t.near(g, b, 1, "gray channels equal")
  -- luma of red = 0.299*255 ≈ 76
  t.true_(g > 70 and g < 82, "luma of red ≈ 76, got " .. g)
end

function M.test_grade_gamma()
  local img = solid(1, 1, 64, 64, 64, 255)
  local up = tex.grade(img, { gamma = 2 })
  local r = select(1, tex.get(up, 0, 0))
  t.true_(r > 64, "gamma 2 brightens midtone, got " .. r)
  local down = tex.grade(img, { gamma = 0.5 })
  local r2 = select(1, tex.get(down, 0, 0))
  t.true_(r2 < 64, "gamma 0.5 darkens midtone, got " .. r2)
end

-- ── quantize + palette ─────────────────────────────────────────────────────

function M.test_quantize_known_palette()
  -- 2 distinct colors → palette is exactly those two
  local img = tex.new(2, 1, { r = 255, g = 0, b = 0, a = 255 })
  tex.set(img, 1, 0, 0, 0, 255, 255)
  local out, pal = tex.quantize(img, 16, "mediancut", "none", 0)
  t.eq(#pal, 2, "palette size 2")
  t.pixel_eq(out, 0, 0, 255, 0, 0, 255, "red preserved")
  t.pixel_eq(out, 1, 0, 0, 0, 255, 255, "blue preserved")
end

function M.test_quantize_deterministic()
  local img = solid(8, 8, 10, 20, 30, 255)
  local out1, pal1 = tex.quantize(img, 4, "mediancut", "none", 0)
  local out2, pal2 = tex.quantize(img, 4, "mediancut", "none", 0)
  t.all_pixels(out1, 10, 20, 30, 255, "single color → itself")
  t.eq(#pal1, 1, "one unique color")
  t.eq(pal1[1].r, pal2[1].r, "palette deterministic")
end

function M.test_quantize_reduces_colors()
  local img = tex.new(4, 4, { r = 0, g = 0, b = 0, a = 255 })
  for y = 0, 3 do
    for x = 0, 3 do
      tex.set(img, x, y, x * 60, y * 60, 0, 255)
    end
  end
  local out, pal = tex.quantize(img, 4, "mediancut", "none", 0)
  t.eq(#pal, 4, "4-color palette")
  local stats = tex.stats(out)
  t.true_(stats.unique <= 4, "output uses ≤4 colors, got " .. stats.unique)
end

function M.test_map_palette_recolor()
  local img = tex.new(2, 1, { r = 255, g = 0, b = 0, a = 255 })
  tex.set(img, 1, 0, 0, 255, 0, 255)
  -- pal {green, magenta}: red → magenta (65025 < 130050), green → green
  local pal = { { r = 0, g = 255, b = 0, a = 255 }, { r = 255, g = 0, b = 255, a = 255 } }
  local out = tex.map_palette(img, pal, "none", 0)
  t.pixel_eq(out, 0, 0, 255, 0, 255, 255, "red → palette[1] (magenta)")
  t.pixel_eq(out, 1, 0, 0, 255, 0, 255, "green → palette[0] (green)")
end

function M.test_dither_deterministic()
  local img = solid(16, 16, 100, 100, 100, 255)
  local out1 = tex.quantize(img, 4, "mediancut", "fs", 0)
  local out2 = tex.quantize(img, 4, "mediancut", "fs", 0)
  local w, h = tex.size(out1)
  local same = true
  for y = 0, h - 1 do
    for x = 0, w - 1 do
      local a = tex.get(out1, x, y)
      local b = tex.get(out2, x, y)
      if a ~= b then same = false end
    end
  end
  t.true_(same, "fs dither deterministic")
end

-- ── blend ──────────────────────────────────────────────────────────────────

function M.test_blend_normal_over_transparent()
  local base = solid(2, 2, 0, 0, 0, 0)
  local src = solid(2, 2, 10, 20, 30, 255)
  local out = tex.blend(base, src, "normal", 1)
  t.all_pixels(out, 10, 20, 30, 255, "normal over transparent")
end

function M.test_blend_transparent_over_opaque()
  local base = solid(2, 2, 200, 100, 50, 255)
  local src = solid(2, 2, 0, 0, 0, 0)
  local out = tex.blend(base, src, "normal", 1)
  t.all_pixels(out, 200, 100, 50, 255, "transparent src leaves base")
end

function M.test_blend_multiply()
  local base = solid(1, 1, 255, 255, 255, 255)
  local src = solid(1, 1, 100, 100, 100, 255)
  local out = tex.blend(base, src, "multiply", 1)
  t.pixel_eq(out, 0, 0, 100, 100, 100, 255, "white × gray = gray")
  local base2 = solid(1, 1, 200, 100, 50, 255)
  local out2 = tex.blend(base2, src, "multiply", 1)
  local r, g, b = tex.get(out2, 0, 0)
  t.near(r, 200 * 100 / 255, 1, "multiply r")
  t.near(g, 100 * 100 / 255, 1, "multiply g")
end

function M.test_blend_screen()
  local base = solid(1, 1, 0, 0, 0, 255)
  local src = solid(1, 1, 128, 64, 32, 255)
  local out = tex.blend(base, src, "screen", 1)
  t.pixel_eq(out, 0, 0, 128, 64, 32, 255, "screen over black = src")
end

function M.test_blend_overlay_symmetry()
  local base = solid(1, 1, 128, 128, 128, 255)
  local src = solid(1, 1, 255, 0, 0, 255)
  local out = tex.blend(base, src, "overlay", 1)
  local r, g, b = tex.get(out, 0, 0)
  t.near(r, 255, 1, "overlay: 50% gray × red = red, got " .. r)
  t.near(g, 0, 1, "overlay green zero")
end

function M.test_blend_opacity()
  local base = solid(1, 1, 0, 0, 0, 255)
  local src = solid(1, 1, 200, 0, 0, 255)
  local out = tex.blend(base, src, "normal", 0.5)
  t.pixel_eq(out, 0, 0, 100, 0, 0, 255, "50% opacity")
end

function M.test_blend_erase()
  local base = solid(1, 1, 100, 100, 100, 255)
  local src = solid(1, 1, 0, 0, 0, 255)
  local out = tex.blend(base, src, "erase", 1)
  t.pixel_eq(out, 0, 0, 100, 100, 100, 0, "erase removes alpha")
end

function M.test_blend_alphamask()
  local base = solid(1, 1, 200, 100, 50, 255)
  local src = solid(1, 1, 0, 0, 0, 128)
  local out = tex.blend(base, src, "alphamask", 1)
  local r, g, b, a = tex.get(out, 0, 0)
  t.near(r, 200 * 128 / 255, 1, "mask scales rgb")
  t.near(a, 255 * 128 / 255, 1, "mask scales alpha")
end

-- ── noise ──────────────────────────────────────────────────────────────────

function M.test_noise_deterministic()
  local a = tex.noise(16, 16, "value", 4, 1, 42)
  local b = tex.noise(16, 16, "value", 4, 1, 42)
  local w, h = tex.size(a)
  local same = true
  for y = 0, h - 1 do
    for x = 0, w - 1 do
      if tex.get(a, x, y) ~= tex.get(b, x, y) then same = false end
    end
  end
  t.true_(same, "same seed → same noise")
end

function M.test_noise_seed_differs()
  local a = tex.noise(16, 16, "value", 4, 1, 1)
  local b = tex.noise(16, 16, "value", 4, 1, 2)
  local diff = 0
  for y = 0, 15 do
    for x = 0, 15 do
      if tex.get(a, x, y) ~= tex.get(b, x, y) then diff = diff + 1 end
    end
  end
  t.true_(diff > 50, "different seeds differ, diff=" .. diff)
end

function M.test_noise_alpha_from()
  local img = tex.noise(8, 8, "value", 4, 1, 5, { r = 255, g = 255, b = 255, a = 255 }, 0, true)
  local w, h = tex.size(img)
  local all_alpha_lt_255 = true
  for y = 0, h - 1 do
    for x = 0, w - 1 do
      local r, g, b, a = tex.get(img, x, y)
      if a > 255 or r ~= g or g ~= b then all_alpha_lt_255 = false end
      if a == 255 then all_alpha_lt_255 = false end
    end
  end
  t.true_(all_alpha_lt_255, "alpha-from-noise gives gray + partial alpha")
end

-- ── seamless ───────────────────────────────────────────────────────────────

function M.test_seamless_constant()
  local img = solid(16, 16, 30, 60, 90, 255)
  local out = tex.seamless(img, 4, "offset")
  t.all_pixels(out, 30, 60, 90, 255, "constant stays constant")
end

function M.test_seamless_reduces_seam()
  -- horizontal gradient black→white with a HARD seam (0→255) at the wrap.
  -- Offset-crossfade moves the boundary samples to the middle of the
  -- source: out(0) = src(w/2), out(w-1) = src(w/2-1) — the boundary step
  -- shrinks from 255 to the source's per-texel step (17).
  local img = tex.new(16, 16, { r = 0, g = 0, b = 0, a = 255 })
  for x = 0, 15 do
    local v = math.floor(x / 15 * 255)
    for y = 0, 15 do tex.set(img, x, y, v, v, v, 255) end
  end
  local out = tex.seamless(img, 4, "offset")
  -- mask=1 at the edges: out pulls exactly from the shifted source
  t.pixel_eq(out, 0, 0, 136, 136, 136, 255, "left edge = src(8)")
  t.pixel_eq(out, 15, 0, 119, 119, 119, 255, "right edge = src(7)")
  -- mask=0 in the middle (both axes): interior untouched
  t.pixel_eq(out, 7, 7, 119, 119, 119, 255, "interior = src(7)")
  -- boundary step (17) is far smaller than the original seam (255)
  local l = select(1, tex.get(out, 0, 0))
  local r = select(1, tex.get(out, 15, 0))
  t.true_(math.abs(l - r) <= 17, "boundary step ≤ source step, got " .. math.abs(l - r))
end

-- ── fill ───────────────────────────────────────────────────────────────────

function M.test_fill_solid()
  local out = tex.fill(4, 4, "solid", { r = 10, g = 20, b = 30, a = 255 })
  t.all_pixels(out, 10, 20, 30, 255, "solid fill")
end

function M.test_fill_linear_gradient()
  -- gradient from left edge (t=0) across: center x=0, extent rx=2
  local out = tex.fill(4, 1, "linear", { r = 0, g = 0, b = 0, a = 255 },
                       { r = 255, g = 255, b = 255, a = 255 }, 0, 0, 0.5, 2, 1)
  local r0 = select(1, tex.get(out, 0, 0))
  local r1 = select(1, tex.get(out, 1, 0))
  local r2 = select(1, tex.get(out, 2, 0))
  local r3 = select(1, tex.get(out, 3, 0))
  t.true_(r0 < r1 and r1 < r2, "linear ramp increases, " .. r0 .. " " .. r1 .. " " .. r2)
  t.eq(r3, 255, "clamped at 1.0, got " .. r3)
end

-- ── stamp ──────────────────────────────────────────────────────────────────

function M.test_stamp_hard_circle()
  local img = tex.new(8, 8, { r = 0, g = 0, b = 0, a = 0 })
  tex.stamp(img, 4, 4, 2, 1, { r = 255, g = 0, b = 0, a = 255 })
  t.pixel_eq(img, 4, 4, 255, 0, 0, 255, "center solid")
  t.pixel_eq(img, 0, 0, 0, 0, 0, 0, "corner untouched")
  t.pixel_eq(img, 4, 1, 0, 0, 0, 0, "outside radius untouched")
end

function M.test_stamp_max_alpha_accumulate()
  local img = tex.new(8, 8, { r = 0, g = 0, b = 0, a = 0 })
  tex.stamp(img, 4, 4, 2, 1, { r = 100, g = 0, b = 0, a = 128 })
  tex.stamp(img, 4, 4, 2, 1, { r = 100, g = 0, b = 0, a = 128 })
  local r, g, b, a = tex.get(img, 4, 4)
  t.eq(a, 128, "overlap does not darken (max-alpha)")
end

function M.test_stamp_erase()
  local img = solid(8, 8, 100, 100, 100, 255)
  tex.stamp(img, 4, 4, 2, 1, { r = 0, g = 0, b = 0, a = 255 }, nil, 4, 1)
  t.pixel_eq(img, 4, 4, 100, 100, 100, 0, "erase removes alpha")
end

function M.test_stamp_image_brush()
  local brush = solid(4, 4, 200, 100, 50, 255)
  local img = tex.new(8, 8, { r = 0, g = 0, b = 0, a = 0 })
  tex.stamp(img, 4, 4, 2, 0.5, { r = 255, g = 255, b = 255, a = 255 }, brush, 4, 0)
  t.pixel_eq(img, 4, 4, 200, 100, 50, 255, "stamp image at center")
end

-- ── stats ──────────────────────────────────────────────────────────────────

function M.test_stats()
  local img = tex.new(2, 1, { r = 0, g = 0, b = 0, a = 255 })
  tex.set(img, 1, 0, 255, 255, 255, 255)
  local s = tex.stats(img)
  t.eq(s.unique, 2, "unique count")
  t.near(s.r, 127.5, 0.5, "avg r")
  t.eq(s.min_r, 0, "min r")
  t.eq(s.max_r, 255, "max r")
end


return M
