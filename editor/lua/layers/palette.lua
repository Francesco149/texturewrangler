-- layers/palette.lua — the core retro primitive: color-index to N colors
-- with optional dithering. First render extracts a palette (median-cut)
-- and stores it in params.palette (derived data); afterwards it re-maps
-- through the stored palette, so editing a palette entry recolor every
-- pixel of that index. "Regenerate" clears the stored palette.
--
-- Order-of-operations discipline from the research: palette layers go LAST
-- in the chain; the tool can't enforce it, but the panel nudges via hints.

local M = {}

local METHODS = { "mediancut" }
local DITHERS = { "none", "bayer4", "fs", "sierra", "atkinson" }

function M.render(l, size, below)
  local p = l.params
  local src = below
  if not src then
    src = tw.tex.new(size[1], size[2], { r = 0, g = 0, b = 0, a = 0 })
  end
  if p.palette and #p.palette > 0 then
    return tw.tex.map_palette(src, p.palette, p.dither or "none",
                              p.alpha_mode or 0)
  end
  local out, pal = tw.tex.quantize(src, p.colors or 16, p.method or "mediancut",
                                   p.dither or "none", p.alpha_mode or 0)
  if out and pal then
    p.palette = pal -- derived: stored so edits + recolor persist
  end
  return out
end

function M.panel(l, ui)
  local p = l.params
  ui.combo("Method", METHODS, p.method, function(v) p.method = v end)
  local quick = { { 4, "4" }, { 8, "8" }, { 16, "16" }, { 32, "32" }, { 64, "64" } }
  ui.slider("Colors", p.colors, 2, 256, function(v)
    p.colors = math.floor(v)
    p.palette = nil -- regenerate on color-count change
  end)
  ui.same_line()
  for _, q in ipairs(quick) do
    if ui.small_button(q[2]) then
      ui.mutate(function()
        p.colors = q[1]
        p.palette = nil
      end, "Palette colors")
    end
    ui.same_line()
  end
  ui.new_line()
  ui.combo("Dither", DITHERS, p.dither, function(v) p.dither = v end)
  ui.combo("Alpha", { "Keep alpha", "Quantize RGBA" }, p.alpha_mode or 0,
           function(v) p.alpha_mode = v end)
  if ui.button("Regenerate palette") then
    ui.mutate(function() p.palette = nil end, "Regenerate palette")
  end
  if p.palette and #p.palette > 0 then
    ui.text(string.format("Palette: %d color(s)", #p.palette))
  end
  ui.text_colored("Hint: keep palette layers at the end of the stack",
                  0.6, 0.6, 0.6, 1)
end

return M
