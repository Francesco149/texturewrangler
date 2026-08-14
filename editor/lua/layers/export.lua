-- layers/export.lua — named capture point: the composite at this position,
-- optionally at a fixed size. Exporting "by name" writes this capture.
-- The final composite export needs no export layer (implicit top).

local M = {}

function M.render()
  return nil -- marker: no visual output
end

function M.panel(l, ui)
  local p = l.params
  ui.input("Name", p.export_name or l.name, function(v) p.export_name = v end)
  ui.check("Fixed size", p.size ~= nil, function(v)
    if v then
      p.size = { doc.canvas[1], doc.canvas[2] }
    else
      p.size = nil
    end
  end)
  if p.size then
    ui.slider("Width", p.size[1], 1, 1024, function(v) p.size[1] = math.floor(v) end)
    ui.slider("Height", p.size[2], 1, 1024, function(v) p.size[2] = math.floor(v) end)
  end
  ui.combo("Format", { "png", "tga", "bmp" }, p.format, function(v)
    p.format = ({ "png", "tga", "bmp" })[v]
  end)
end

return M
