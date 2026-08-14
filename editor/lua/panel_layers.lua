-- panel_layers.lua — the layer stack: thumbnails, visibility, select,
-- drag reorder (within the same parent), add menu, row context menu
-- (rename / duplicate / group / delete / move into group).

local panel = {}
local ig = tw.ig

local ROW_H = 34

local function new_layer_of(type)
  if type == "image" then
    -- the file dialog routes through tw.on_drop → import.file, which
    -- creates + selects the layer itself
    import.open_dialog()
    return nil
  end
  local l = doc.new_layer(type)
  doc.mutate(function() doc.add_layer(l) end, "Add " .. l.name)
  return l
end

local function add_menu()
  if ig.button("+ Add") then ig.open_popup("##add_layer") end
  if ig.begin_popup("##add_layer") then
    local types = { "image", "paint", "noise", "grade", "palette",
                    "downscale", "seamless", "fill", "group", "export" }
    for _, t in ipairs(types) do
      if ig.menu_item(doc.type_names[t]) then
        local l = new_layer_of(t)
        if l then panels.set_selected(l.id) end
      end
    end
    ig.end_popup()
  end
end

-- duplicate a layer (deep copy, fresh ids, shared asset)
local function duplicate(l)
  local copy = doc.new_layer(l.type, l.name .. " copy")
  copy.visible = l.visible
  copy.opacity = l.opacity
  copy.blend = l.blend
  copy.params = (function() -- deep copy params
    local function dc(t)
      if type(t) ~= "table" then return t end
      local r = {}
      for k, v in pairs(t) do r[k] = dc(v) end
      return r
    end
    return dc(l.params)
  end)()
  return copy
end

local function group_of(l, at_top)
  local g = doc.new_layer("group", "Group")
  doc.mutate(function()
    local parent = doc.find_parent(l.id)
    local list = parent and parent.children or doc.layers
    local idx = nil
    for i, x in ipairs(list) do if x.id == l.id then idx = i break end end
    table.remove(list, idx)
    g.children = { l }
    doc._parent[l.id] = g.id
    table.insert(list, idx, g)
    doc._parent[g.id] = parent or nil
  end, "Group layers")
  return g
end

local function move_into_group(l, gid)
  doc.mutate(function()
    local parent = doc.find_parent(l.id)
    local list = parent and parent.children or doc.layers
    for i, x in ipairs(list) do if x.id == l.id then table.remove(list, i); break end end
    local g = doc.get_layer(gid)
    g.children[#g.children + 1] = l
    doc._parent[l.id] = gid
  end, "Move into group")
end

-- render one row; returns nil (or a drag result)
local function row(l, depth, in_flight)
  local x0, y0 = ig.get_cursor_screen_pos()
  local avail_w = ig.get_content_region_avail()
  local selected = panels.selected() == l.id

  -- The body is pcall'd so push_id ALWAYS balances even when it throws:
  -- an unbalanced ID stack corrupts imgui's state and asserts next frame.
  ig.push_id(l.id)
  local ok, err = pcall(function()
  local w = avail_w
  local row_h = ROW_H

  -- drag handle (≡) at the row's left edge — explicit reorder affordance.
  -- A real item (invisible button) so it doesn't overlap the eye toggle;
  -- the existing doc._drag mechanism does the actual reorder/move.
  local HW = 20
  ig.invisible_button("##h" .. l.id, HW, row_h)
  local handle_hover = ig.is_item_hovered()
  if not doc._drag and handle_hover and ig.is_mouse_dragging(0) and not in_flight then
    doc._drag = { id = l.id, y0 = y0 }
  end
  local dlh = ig.get_window_draw_list()
  local hl = handle_hover and 0.62 or 0.42
  ig.dl_add_line(dlh, x0 + 6, y0 + 11, x0 + 14, y0 + 11, hl, hl, hl, 1, 1.5)
  ig.dl_add_line(dlh, x0 + 6, y0 + 16, x0 + 14, y0 + 16, hl, hl, hl, 1, 1.5)
  ig.dl_add_line(dlh, x0 + 6, y0 + 21, x0 + 14, y0 + 21, hl, hl, hl, 1, 1.5)
  ig.same_line()

  -- visibility eye
  local vch, vv = ig.checkbox("##v" .. l.id, l.visible)
  if vch then
    doc.coalesce_mutate(function() l.visible = vv end)
  end
  ig.same_line()

  -- thumbnail (shifted right by handle width + one ItemSpacing)
  local thumb_x = x0 + 24 + HW + 6
  local thumb = render.thumb(doc.stack_index(l.id))
  local tid = thumb and render.texid_for(doc._thumb_cache, l.id, thumb)
  if tid then
    ig.dl_add_image(ig.get_window_draw_list(), tid,
                    thumb_x, y0 + 3, thumb_x + 28, y0 + 31, 0, 0, 1, 1)
  end
  ig.dummy(32, 28)
  ig.same_line()

  -- name / type selectable (width shrunk so it still ends at the row edge)
  ig.set_next_item_width(w - 86)
  local hit = ig.selectable(l.name .. "##" .. l.id, selected, 0, w - 88, row_h - 6)
  if hit then panels.set_selected(l.id) end

  -- type badge on the right (drawlist text at SCREEN coords — avoids
  -- SetCursorPos extending the child bounds)
  local dl2 = ig.get_window_draw_list()
  local badge = doc.type_names[l.type]
  local tw_ = ig.calc_text_size(badge)
  ig.dl_add_text(dl2, x0 + w - tw_ - 34, y0 + 8, 0.45, 0.47, 0.52, 1, badge)

  -- context menu
  if ig.begin_popup_context_item() then
    if ig.menu_item("Duplicate") then
      local copy = duplicate(l)
      doc.mutate(function()
        local parent = doc.find_parent(l.id)
        doc.add_layer(copy, parent, true)
      end, "Duplicate layer")
      panels.set_selected(copy.id)
    end
    if ig.menu_item("Group") then
      local g = group_of(l, false)
      panels.set_selected(g.id)
    end
    if ig.menu_item("Delete") then
      doc.mutate(function() doc.remove_layer(l.id) end, "Delete layer")
      if panels.selected() == l.id then panels.set_selected(nil) end
    end
    -- move into group (only for root layers)
    if not doc.find_parent(l.id) then
      ig.separator()
      for _, g in ipairs(doc.layers) do
        if g.type == "group" and g.id ~= l.id then
          if ig.menu_item("Into group: " .. g.name) then move_into_group(l, g.id) end
        end
      end
    end
    ig.end_popup()
  end

  -- drag to reorder (within the same parent list)
  if not doc._drag and ig.is_item_hovered() and ig.is_mouse_dragging(0) and
     not in_flight then
    doc._drag = { id = l.id, y0 = y0 }
  end
  if doc._drag and doc._drag.id == l.id and not ig.is_mouse_down(0) then
    local _, my = ig.get_mouse_pos()
    local delta = math.floor((my - doc._drag.y0) / (ROW_H + 4))
    if delta ~= 0 then
      local parent = doc.find_parent(l.id)
      local list = parent and parent.children or doc.layers
      local idx = nil
      for i, x in ipairs(list) do if x.id == l.id then idx = i break end end
      if idx then
        local ni = math.max(1, math.min(#list, idx + delta))
        if ni ~= idx then
          doc.mutate(function() doc.move_layer(l.id, ni) end, "Reorder")
        end
      end
    end
    doc._drag = nil
  end

  end)
  ig.pop_id()
  if not ok then error(err, 0) end

  -- children (groups)
  if l.children and #l.children > 0 then
    for _, c in ipairs(l.children) do row(c, depth + 1, in_flight) end
  end
end

function panel.frame()
  ig.set_cursor_pos(0, 30)
  add_menu()
  ig.same_line()
  if ig.button("Group") then
    local sel = panels.selected()
    if sel then
      local g = group_of(doc.get_layer(sel), false)
      panels.set_selected(g.id)
    end
  end
  ig.separator()
  -- stack: top layer first (reverse of doc.layers)
  local in_flight = doc._in_flight ~= nil
  for i = #doc.layers, 1, -1 do
    row(doc.layers[i], 0, in_flight)
  end
  if #doc.layers == 0 then
    ig.text_colored("No layers — + Add an image or texture layer.", 0.45, 0.47, 0.52, 1)
  end
end

return panel
