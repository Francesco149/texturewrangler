-- layers/fill.lua — solid fill or linear/radial/conic gradient. The
-- video's "color infusion" trick: a fill layer with blend=overlay at low
-- opacity gives the cohesive mood. cx/cy/rx/ry are canvas fractions so
-- fills scale with the working size.

local M = {}

local TYPES = { "solid", "linear", "radial", "conic" }

function M.render(l, size)
  local p = l.params
  local c0 = p.c0 or { r = 255, g = 255, b = 255, a = 255 }
  local c1 = p.c1 or { r = 0, g = 0, b = 0, a = 0 }
  return tw.tex.fill(size[1], size[2], p.type or "solid", c0, c1,
                     p.angle or 0,
                     (p.cx or 0.5) * size[1], (p.cy or 0.5) * size[2],
                     (p.rx or 0.5) * size[1], (p.ry or 0.5) * size[2])
end

function M.panel(l, ui)
  local p = l.params
  ui.combo("Type", TYPES, p.type, function(v) p.type = v end)
  ui.color("Color A", p.c0, function(v) p.c0 = v end)
  if p.type ~= "solid" then
    ui.color("Color B", p.c1, function(v) p.c1 = v end)
  end
  if p.type == "linear" then
    ui.slider("Angle", p.angle, 0, 360, function(v) p.angle = v end)
  end
  if p.type == "radial" or p.type == "linear" then
    ui.slider("Center X", p.cx, -0.5, 1.5, function(v) p.cx = v end)
    ui.slider("Center Y", p.cy, -0.5, 1.5, function(v) p.cy = v end)
  end
  if p.type == "radial" then
    ui.slider("Radius X", p.rx, 0.05, 2, function(v) p.rx = v end)
    ui.slider("Radius Y", p.ry, 0.05, 2, function(v) p.ry = v end)
  end
end

return M
