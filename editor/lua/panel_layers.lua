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
                    "downscale", "crop", "seamless", "fill", "group", "export" }
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
    doc._parent[g.id] = parent and parent.id or nil
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
  -- indent children under their group so membership reads at a glance;
  -- root rows reset to the left edge. imgui items don't advance the
  -- cursor x (only SameLine does), so each row must position itself —
  -- and everything in the row (handle, thumb, name, badge) derives from
  -- x0 = the shifted cursor.
  local cx, cy = ig.get_cursor_pos()
  ig.set_cursor_pos(depth > 0 and 14 * depth or 0, cy)
  local x0, y0 = ig.get_cursor_screen_pos()
  local avail_w = ig.get_content_region_avail()
  local selected = panels.selected() == l.id
  panels._row_y0s = panels._row_y0s or {}
  panels._row_y0s[l.id] = y0

  -- the row being dragged: amber tint so it reads as "moving"
  if doc._drag and doc._drag.id == l.id then
    local dlh = ig.get_window_draw_list()
    ig.dl_add_rect_filled(dlh, x0, y0, x0 + avail_w, y0 + ROW_H,
                          0.92, 0.62, 0.35, 0.16)
  end

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

  -- group/child hints: an expanded (∨) marker on group rows, and a faint
  -- vertical guide at the indent column for children.
  if l.type == "group" then
    local gy = y0 + row_h / 2
    ig.dl_add_line(dlh, x0 + 78, gy - 3, x0 + 81, gy + 1, 0.62, 0.64, 0.7, 1, 1.5)
    ig.dl_add_line(dlh, x0 + 81, gy + 1, x0 + 84, gy - 3, 0.62, 0.64, 0.7, 1, 1.5)
  elseif depth > 0 then
    ig.dl_add_line(dlh, x0 - 7, y0, x0 - 7, y0 + row_h, 0.30, 0.32, 0.38, 1, 1)
  end

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
        doc.add_layer(copy, parent and parent.id, true)
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

  -- drag to reorder (within the same parent list). START detection lives
  -- here; the live TARGET computation runs in panel.frame() AFTER the row
  -- pass, where every row's y0 is fresh for THIS frame (computing it here
  -- read stale y0s for rows below the dragged one — they hadn't rendered
  -- yet — which made the reorder ping-pong between two slots).
  if not doc._drag and (ig.is_item_hovered() or handle_hover) and
     ig.is_mouse_dragging(0) and not in_flight then
    doc._drag = { id = l.id, y0 = y0 }
  end
  if doc._drag and doc._drag.id == l.id and not ig.is_mouse_down(0) then
    doc._drag = nil
  end

  end)
  ig.pop_id()
  if not ok then error(err, 0) end

  -- children (groups). Snapshot before iterating — context-menu actions
  -- mutate the tree mid-frame, and the live list would re-render the same
  -- layer (duplicate imgui ids). Top-first, matching the root stack, so a
  -- drag "down" means the same thing inside a group as outside.
  if l.children and #l.children > 0 then
    local kids = {}
    for i = #l.children, 1, -1 do kids[#kids + 1] = l.children[i] end
    for _, c in ipairs(kids) do row(c, depth + 1, in_flight) end
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
  -- stack: top layer first (reverse of doc.layers). Snapshot first — the
  -- context menu can mutate the tree mid-frame, and iterating the live
  -- list then skips rows or renders a layer twice (duplicate imgui ids).
  local in_flight = doc._in_flight ~= nil
  local top_down = {}
  for i = #doc.layers, 1, -1 do top_down[#top_down + 1] = doc.layers[i] end
  for _, l in ipairs(top_down) do
    row(l, 0, in_flight)
  end

  -- live reorder decision, AFTER the pass: every row's _row_y0s is now
  -- fresh for this frame, so the nearest-midpoint target is consistent
  -- with what was drawn. (Computing it inside the dragged row's render
  -- read y0s from the previous frame's layout for rows below it, which
  -- made the reorder ping-pong between two slots.)
  if doc._drag then
    if ig.is_mouse_down(0) then
      local d = doc._drag
      local l = doc.get_layer(d.id)
      if l then
        doc._coalescing = true -- one undo entry for the whole drag
        local parent = doc.find_parent(l.id)
        local list = parent and parent.children or doc.layers
        local idx = nil
        for i, x in ipairs(list) do if x.id == d.id then idx = i break end end
        if idx then
          local _, my = ig.get_mouse_pos()
          -- target = the same-list row whose midpoint the cursor is nearest
          local best, bestd = nil, 1e9
          for i, x in ipairs(list) do
            local yy = panels._row_y0s[x.id]
            if yy then
              local dd = math.abs(yy + ROW_H / 2 - my)
              if dd < bestd then best, bestd = i, dd end
            end
          end
          if best and best ~= idx then
            panel._pending_move = { id = d.id, to = best }
          end
        end
      end
    else
      doc._drag = nil
    end
  end
  -- apply the deferred move AFTER rows rendered, so the list stays stable
  -- while the UI draws.
  if panel._pending_move then
    local pm = panel._pending_move
    panel._pending_move = nil
    doc.coalesce_mutate(function() doc.move_layer(pm.id, pm.to) end)
  end
  if #doc.layers == 0 then
    ig.text_colored("No layers — + Add an image or texture layer.", 0.45, 0.47, 0.52, 1)
  end
end

return panel
