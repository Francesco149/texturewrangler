-- panel_export.lua — export locations (default project export/ folder +
-- named extra paths, each optionally auto-exporting on change) and the
-- Export button (final composite + every export layer).

local panel = {}
local ig = tw.ig

function panel.frame()
  ig.set_cursor_pos(0, 30)

  if ig.button("Export all (Ctrl+E)") then export.all() end
  ig.same_line()
  if ig.button("+ Location") then
    doc.mutate(function()
      doc.exports[#doc.exports + 1] = { name = "export-" .. (#doc.exports + 1),
                                        path = "", auto = false, format = "png" }
    end, "Add export location")
  end
  ig.separator()

  ig.text_colored("Default: " .. (doc.path and (doc.path .. "/export/") or "(unsaved)")
                  .. doc.name .. ".png", 0.45, 0.47, 0.52, 1)
  ig.separator()

  for i, e in ipairs(doc.exports) do
    ig.push_id("exp" .. i)
    local name_changed, name_v = ig.input_text("##name", e.name, 64)
    if name_changed then
      doc.coalesce_mutate(function() e.name = name_v end)
    end
    local path_changed, path_v = ig.input_text("##path", e.path, 512)
    if path_changed then
      doc.coalesce_mutate(function() e.path = path_v end)
    end
    local auto_changed, auto_v = ig.checkbox("auto", e.auto)
    if auto_changed then
      doc.coalesce_mutate(function() e.auto = auto_v end)
    end
    ig.same_line()
    if ig.small_button("X") then
      doc.mutate(function() table.remove(doc.exports, i) end, "Remove location")
    end
    ig.pop_id()
  end

  -- export layers in the stack
  local exports = {}
  for _, l in ipairs(doc.all_layers()) do
    if l.type == "export" then exports[#exports + 1] = l end
  end
  if #exports > 0 then
    ig.separator()
    ig.text("Export layers:")
    for _, l in ipairs(exports) do
      local idx = doc.stack_index(l.id)
      if ig.small_button("Export: " .. (l.params.export_name or l.name)) then
        export.layer_capture(l)
      end
    end
  end

end

return panel
