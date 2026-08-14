-- layers/image.lua — imported image layer. The asset image is resampled to
-- the working size with a per-layer filter (1:1 at its own size).

local M = {}

local FILTERS = { "nearest", "bilinear", "bicubic", "box", "aniso" }

M.filters = FILTERS

function M.render(l, size)
  local aid = l.params.asset
  if not aid then return nil end
  local img = doc.asset_image(aid)
  if not img then return nil end
  local w, h = tw.tex.size(img)
  if w == size[1] and h == size[2] then return img end
  return tw.tex.resize(img, size[1], size[2], l.params.filter or "bilinear")
end

function M.panel(l, ui)
  local p = l.params
  local asset = p.asset and doc.assets[p.asset]
  if asset then
    ui.label("Source", asset.file .. string.format(" (%d×%d)", asset.w, asset.h))
  else
    ui.label("Source", "(none)")
  end
  ui.combo("Resample", FILTERS, p.filter, function(v) p.filter = v end)
end

return M
