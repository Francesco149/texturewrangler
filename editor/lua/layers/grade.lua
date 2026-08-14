-- layers/grade.lua — the "one control to rule them all" grading layer:
-- temperature/tint, brightness, contrast, gamma, saturation, vibrance,
-- hue, colorize — one layer, one panel. Applied to the partial composite
-- below; opacity/blend fade or mix the transformation.

local M = {}

function M.render(l, size, below)
  local p = l.params
  local src = below
  if not src then
    src = tw.tex.new(size[1], size[2], { r = 0, g = 0, b = 0, a = 0 })
  end
  return tw.tex.grade(src, {
    brightness = p.brightness or 0,
    contrast = p.contrast or 0,
    gamma = p.gamma or 1,
    saturation = p.saturation or 1,
    vibrance = p.vibrance or 0,
    hue = p.hue or 0,
    temperature = p.temperature or 0,
    tint = p.tint or 0,
    colorize = p.colorize or { r = 255, g = 255, b = 255, a = 255 },
    colorize_strength = p.colorize_strength or 0,
  })
end

function M.panel(l, ui)
  local p = l.params
  ui.slider("Temperature", p.temperature, -1, 1, function(v) p.temperature = v end)
  ui.slider("Tint", p.tint, -1, 1, function(v) p.tint = v end)
  ui.separator()
  ui.slider("Brightness", p.brightness, -1, 1, function(v) p.brightness = v end)
  ui.slider("Contrast", p.contrast, -1, 1, function(v) p.contrast = v end)
  ui.slider("Gamma", p.gamma, 0.1, 4, function(v) p.gamma = v end)
  ui.separator()
  ui.slider("Saturation", p.saturation, 0, 2, function(v) p.saturation = v end)
  ui.slider("Vibrance", p.vibrance, -1, 1, function(v) p.vibrance = v end)
  ui.slider("Hue", p.hue, -180, 180, function(v) p.hue = v end)
  ui.separator()
  ui.color("Colorize", p.colorize, function(v) p.colorize = v end)
  ui.slider("Colorize amount", p.colorize_strength, 0, 1,
            function(v) p.colorize_strength = v end)
end

return M
