-- layers/seamless.lua — make the partial composite tile. offset = shift by
-- half and crossfade border strips (the classic make-seamless); bleed =
-- 1px shift, feathered (softens a raw seam).

local M = {}

local MODES = { "offset", "bleed" }

function M.render(l, size, below)
  local p = l.params
  local src = below
  if not src then
    src = tw.tex.new(size[1], size[2], { r = 0, g = 0, b = 0, a = 0 })
  end
  return tw.tex.seamless(src, p.blend or 8, p.mode or "offset")
end

function M.panel(l, ui)
  local p = l.params
  ui.combo("Mode", MODES, p.mode, function(v) p.mode = v end)
  ui.slider("Blend width", p.blend, 1, 64, function(v) p.blend = math.floor(v) end)
end

return M
