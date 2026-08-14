-- layers/crop.lua — cut a rectangular region out of the partial composite;
-- the working size becomes the crop size for everything above (export
-- resolution = size at the top, so crop is how you resize the output by
-- cutting, unlike downscale which resamples). w/h = 0 means "full source".

local M = {}

function M.render(l, size, below)
  local p = l.params
  local src = below
  if not src then
    src = tw.tex.new(size[1], size[2], { r = 0, g = 0, b = 0, a = 0 })
  end
  local sw, sh = tw.tex.size(src)
  local x = math.max(0, math.min(sw - 1, math.floor(p.x or 0)))
  local y = math.max(0, math.min(sh - 1, math.floor(p.y or 0)))
  local w = (p.w or 0) > 0 and math.min(sw - x, math.floor(p.w)) or (sw - x)
  local h = (p.h or 0) > 0 and math.min(sh - y, math.floor(p.h)) or (sh - y)
  w = math.max(1, w)
  h = math.max(1, h)
  return tw.tex.crop(src, x, y, w, h), { w, h }
end

function M.panel(l, ui)
  local p = l.params
  ui.slider("X", p.x, 0, 1024, function(v) p.x = math.floor(v) end)
  ui.slider("Y", p.y, 0, 1024, function(v) p.y = math.floor(v) end)
  ui.slider("Width", p.w, 0, 1024, function(v) p.w = math.floor(v) end)
  ui.slider("Height", p.h, 0, 1024, function(v) p.h = math.floor(v) end)
  ui.text_colored("Width/Height 0 = full source", 0.45, 0.47, 0.52, 1)
  ui.text_colored("Everything above works at the crop size.",
                  0.45, 0.47, 0.52, 1)
end

return M
