-- layers/noise.lua — procedural noise: value / Perlin / fbm. Seeded and
-- deterministic (identical params → identical pixels), lattice wraps so
-- the noise tiles.

local M = {}

local TYPES = { "value", "perlin", "fbm" }

function M.render(l, size)
  local p = l.params
  return tw.tex.noise(size[1], size[2], p.type or "value", p.scale or 8,
                      p.octaves or 1, p.seed or 1, p.tint or { r = 255, g = 255, b = 255, a = 255 },
                      p.colorize or 0, p.alpha_from or false)
end

function M.panel(l, ui)
  local p = l.params
  ui.combo("Type", TYPES, p.type, function(v) p.type = v end)
  ui.slider("Scale", p.scale, 1, 256, function(v) p.scale = v end)
  ui.slider("Octaves", p.octaves, 1, 6, function(v) p.octaves = math.floor(v) end)
  ui.slider("Seed", p.seed, 1, 9999, function(v) p.seed = math.floor(v) end)
  -- ui.combo's `current` is 1-based and on_change receives 1-based: the
  -- stored param is 0/1, so translate both ways (was off-by-one — selecting
  -- "Tinted" stored 2, which the kernel treats as monochrome).
  ui.combo("Color", { "Monochrome", "Tinted" }, p.colorize + 1, function(v)
    p.colorize = v - 1
  end)
  if p.colorize == 1 then
    ui.color("Tint", p.tint, function(v) p.tint = v end)
  end
  ui.check("Alpha from noise", p.alpha_from, function(v) p.alpha_from = v end)
end

return M
