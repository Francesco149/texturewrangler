-- layers/downscale.lua — resample the partial composite to a target size;
-- the working size becomes the target for everything above. Remove the
-- layer → working size reverts → back to the full-res original.
--
-- The video's filter order: nearest (noisy) < bilinear < bicubic (smooth,
-- loses detail) < anisotropic (the retro-friendly pick) < box (exact
-- area average).

local M = {}

local FILTERS = { "nearest", "bilinear", "bicubic", "box", "aniso" }

M.filters = FILTERS

function M.render(l, size, below)
  local p = l.params
  local tw_ = p.size or { 64, 64 }
  local src = below
  if not src then
    src = tw.tex.new(size[1], size[2], { r = 0, g = 0, b = 0, a = 0 })
  end
  local out = tw.tex.resize(src, tw_[1], tw_[2], p.filter or "aniso")
  return out, { tw_[1], tw_[2] }
end

function M.panel(l, ui)
  local p = l.params
  ui.slider("Width", p.size[1], 1, 1024, function(v) p.size[1] = math.floor(v) end)
  ui.slider("Height", p.size[2], 1, 1024, function(v) p.size[2] = math.floor(v) end)
  local quick = { { 16, "16" }, { 32, "32" }, { 64, "64" }, { 128, "128" }, { 256, "256" } }
  for _, q in ipairs(quick) do
    if ui.small_button(q[2] .. "²") then
      ui.mutate(function()
        p.size = { q[1], q[1] }
      end, "Downscale size")
    end
    ui.same_line()
  end
  ui.new_line()
  ui.combo("Filter", FILTERS, p.filter, function(v) p.filter = v end)
end

return M
