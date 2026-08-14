-- panel_palette.lua — the palette of the current partial composite:
-- swatches of the nearest palette layer at/below the selection (or the
-- selected layer itself if it's a palette layer). Click a swatch to
-- recolor every pixel of that index; hex field for exact values.

local panel = {}
local ig = tw.ig
local ui = require("ui")
local colors = require("colors")

local function find_palette_layer()
  local sel = panels.selected()
  if not sel then return nil end
  local idx = doc.stack_index(sel)
  if not idx then return nil end
  -- prefer the selected layer if it's a palette layer
  if doc.layers[idx].type == "palette" then return doc.layers[idx] end
  for i = idx, 1, -1 do
    if doc.layers[i].type == "palette" then return doc.layers[i] end
  end
  return nil
end

function panel.frame()
  ig.set_cursor_pos(0, 30)

  local pl = find_palette_layer()
  local pal = pl and pl.params.palette
  if not pal or #pal == 0 then
    ig.text_colored("No palette — add a Palette layer and set its colors.",
                    0.45, 0.47, 0.52, 1)
    return
  end

  ig.text(string.format("%s — %d colors", pl.name, #pal))
  ig.separator()

  local u = ui.new({
    mutate = function(fn) doc.mutate(fn) end,
    coalesce = function(fn) doc.coalesce_mutate(fn) end,
  })

  local avail_w = ig.get_content_region_avail()
  local swatch = 30
  local cols = math.max(1, math.floor(avail_w / (swatch + 6)))
  local sel_idx = math.max(1, math.min(#pal, panel.edit_idx or 1))
  panel.edit_idx = sel_idx
  for i, c in ipairs(pal) do
    if (i - 1) % cols ~= 0 then ig.same_line(0, 6) end
    if u.color_swatch("sw" .. i, c, swatch, swatch) then
      panel.edit_idx = i
      sel_idx = i
    end
    if ig.is_item_hovered() then
      ig.set_tooltip(string.format("#%s  (%d)", colors.hex(c), i))
    end
    -- ring the selected swatch (clicking a swatch selects it for editing)
    if i == sel_idx then
      local x0, y0 = ig.get_item_rect_min()
      local x1, y1 = ig.get_item_rect_max()
      local dl = ig.get_window_draw_list()
      ig.dl_add_rect(dl, x0 - 2, y0 - 2, x1 + 2, y1 + 2, 0.92, 0.62, 0.35, 1, 0, 2)
    end
  end
  ig.new_line()
  ig.separator()

  -- per-swatch edit: click a swatch above to pick which one this edits
  local c = pal[sel_idx]
  ig.text_colored(string.format("Editing swatch %d", sel_idx), 0.45, 0.47, 0.52, 1)
  u.color("Color", c, function(v)
    u.coalesce(function()
      pal[sel_idx] = v
      doc.bump(pl)
    end)
  end)
  ig.text(string.format("Count: %d colors", #pal))
  if ig.button("Regenerate") then
    u.mutate(function() pl.params.palette = nil end, "Regenerate palette")
  end
  ig.same_line()
  if ig.button("Export .pal") then
    -- write a simple text palette next to the project
    local lines = {}
    for _, x in ipairs(pal) do
      lines[#lines + 1] = string.format("%d %d %d", x.r, x.g, x.b)
    end
    local path = doc.path .. "/" .. doc.name .. ".pal"
    if tw.file.write_text(path, table.concat(lines, "\n")) then
      tw.log("palette written: " .. path)
    end
  end

end

return panel
