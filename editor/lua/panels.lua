-- panels.lua — tiled layout: draggable splitters, panel chrome, the top
-- toolbar and status strip. No floating windows, ever: every panel is a
-- positioned child region inside the fullscreen main window.

local panels = {}
local ig = tw.ig

panels.layout = { left_w = 300, right_w = 350, bottom_h = 210 }

panels.state = { sel = nil } -- selected layer id

function panels.set_selected(id)
  panels.state.sel = id
end
function panels.selected()
  return panels.state.sel
end

-- ── geometry ────────────────────────────────────────────────────────────────

local TOP_H = 34

function panels.rects()
  local io = ig.get_io()
  local w, h = io.display_w, io.display_h
  local lw = panels.layout.left_w
  local rw = panels.layout.right_w
  local bh = panels.layout.bottom_h
  local top = TOP_H
  local R = function(x, y, w2, h2)
    return { x = x, y = y, w = w2, h = h2 }
  end
  return {
    top = R(0, 0, w, top),
    left = R(0, top, lw, h - top - bh),
    right = R(w - rw, top, rw, h - top - bh),
    bottom = R(0, h - bh, w, bh),
    center = R(lw, top, w - lw - rw, h - top - bh),
  }
end

-- splitter drag handling; call before computing rects
function panels.tick_splitters()
  local io = ig.get_io()
  local dw, dh = io.display_w, io.display_h
  local r = panels.rects()
  local mx, my = ig.get_mouse_pos()
  local l = panels.layout
  if not l.drag then
    if ig.is_mouse_down(0) and math.abs(mx - (r.left.x + r.left.w)) < 5 then
      l.drag = "left"
    elseif ig.is_mouse_down(0) and math.abs(mx - r.right.x) < 5 then
      l.drag = "right"
    elseif ig.is_mouse_down(0) and math.abs(my - r.bottom.y) < 5 then
      l.drag = "bottom"
    end
  end
  if l.drag then
    if l.drag == "left" then
      l.left_w = math.max(190, math.min(dw - 420, mx))
    elseif l.drag == "right" then
      l.right_w = math.max(230, math.min(dw - 420, dw - mx))
    elseif l.drag == "bottom" then
      l.bottom_h = math.max(130, math.min(dh - 220, dh - my))
    end
    if not ig.is_mouse_down(0) then l.drag = nil end
  end
end

-- ── panel chrome ────────────────────────────────────────────────────────────
-- begin: position a child at rect, draw a header (bg + title + optional
-- right-aligned action callback), return the body child open flag.

-- small helper: draw a filled rect on a draw list
local function dl_add_rect_filled(dl, x0, y0, x1, y1, r, g, b, a)
  ig.dl_add_rect_filled(dl, x0, y0, x1, y1, r, g, b, a)
end
panels.dl_rect = dl_add_rect_filled

function panels.begin(id, rect, title, opts)
  opts = opts or {}
  ig.set_next_window_pos(rect.x, rect.y)
  ig.set_next_window_size(rect.w, rect.h)
  local open = ig.begin_child(id, rect.w, rect.h, 0, 0)
  if title then
    local dl = ig.get_window_draw_list()
    local y0 = rect.y
    dl_add_rect_filled(dl, rect.x, y0, rect.x + rect.w, y0 + 26, 0.10, 0.105, 0.125, 1)
    dl_add_rect_filled(dl, rect.x, y0 + 24, rect.x + rect.w, y0 + 26, 0.92, 0.62, 0.35, 1)
    ig.set_cursor_pos(8, 5)
    ig.text(title)
    if opts.header then
      local w = rect.w
      -- run the header action at the right side
      ig.set_cursor_pos(w - opts.header_w - 8, 3)
      opts.header()
    end
    ig.set_cursor_pos(8, 30)
  else
    ig.set_cursor_pos(4, 4)
  end
  return open
end

function panels.end_()
  ig.end_child()
end


-- ── top toolbar ─────────────────────────────────────────────────────────────

function panels.toolbar(rect)
  ig.set_next_window_pos(rect.x, rect.y)
  ig.set_next_window_size(rect.w, rect.h)
  ig.begin_child("##toolbar", rect.w, rect.h, 0, 0)
  local dl = ig.get_window_draw_list()
  panels.dl_rect(dl, rect.x, rect.y, rect.x + rect.w, rect.y + rect.h,
                 0.07, 0.073, 0.09, 1)
  ig.set_cursor_pos(10, 8)
  if doc.loaded then
    ig.push_font(1)
    ig.text(doc.name)
    ig.pop_font()
    ig.same_line(140)
    if ig.button("Undo") then undo.do_undo() end
    ig.same_line()
    if ig.button("Redo") then undo.do_redo() end
    ig.same_line(20)
    if ig.button("Import (Ctrl+U)") then import.open_dialog() end
    ig.same_line()
    if ig.button("Export (Ctrl+E)") then export.all() end
    ig.same_line()
    if ig.button("Project") then panels.state.show_project = not panels.state.show_project end
    -- right side: status info
    local io = ig.get_io()
    local fps = io.delta_time > 0 and math.floor(1 / io.delta_time) or 0
    local sz = string.format("%d×%d", doc.canvas[1], doc.canvas[2])
    local info = sz .. "  ·  " .. fps .. " fps"
    local tw_ = ig.calc_text_size(info)
    ig.set_cursor_pos(rect.w - tw_ - 14, 8)
    ig.text_colored(info, 0.45, 0.47, 0.52, 1)
  else
    ig.push_font(1)
    ig.text("texturewrangler")
    ig.pop_font()
  end
  ig.end_child()
end

-- ── status strip (bottom of the console panel, drawn by console.lua) ───────

return panels
