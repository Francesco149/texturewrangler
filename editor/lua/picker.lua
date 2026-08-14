-- picker.lua — the front door: list of projects in the standard dir with
-- thumbnails, create (random dictionary name, rename anytime), open,
-- delete. Shows when no project is loaded.

local picker = {}
local ig = tw.ig
local words = require("words")

local function list_projects()
  local dir = doc.projects_dir()
  local entries, n = tw.file.list(dir)
  local out = {}
  for i = 1, n do
    local name = entries[i]
    local pdir = dir .. "/" .. name
    if tw.file.exists(pdir .. "/project.json") then
      out[#out + 1] = { name = name, dir = pdir }
    end
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

function picker.frame(rect)
  local io = ig.get_io()
  local w, h = io.display_w, io.display_h

  ig.set_next_window_pos(0, 0)
  ig.set_next_window_size(w, h)
  ig.begin_child("##picker", w, h, 0, 0)
  local dl = ig.get_window_draw_list()
  ig.dl_add_rect_filled(dl, 0, 0, w, h, 0.082, 0.086, 0.10, 1)

  ig.push_font(1)
  local title = "texturewrangler"
  local tw_ = ig.calc_text_size(title)
  ig.set_cursor_pos((w - tw_) / 2, 40)
  ig.text(title)
  ig.pop_font()
  ig.set_cursor_pos((w - 320) / 2, 76)
  ig.text_colored("non-destructive retro texture editor", 0.45, 0.47, 0.52, 1)

  -- new project
  ig.set_cursor_pos((w - 260) / 2, 110)
  if ig.button("+ New project", 260, 32) then
    local name = words.random_name()
    new_project(name)
    return
  end
  ig.set_cursor_pos((w - 260) / 2, 148)
  ig.text_colored(doc.projects_dir(), 0.4, 0.42, 0.47, 1)

  -- project grid
  local projects = list_projects()
  ig.set_cursor_pos(40, 190)
  ig.text(string.format("%d project(s)", #projects))
  ig.separator()

  local card_w = 200
  local card_h = 190
  local gap = 16
  local x0, y0 = 40, 230
  for i, p in ipairs(projects) do
    local col = (i - 1) % 4
    local row = math.floor((i - 1) / 4)
    local cx = x0 + col * (card_w + gap)
    local cy = y0 + row * (card_h + gap)

    ig.set_cursor_pos(cx, cy)
    ig.dummy(card_w, card_h)
    if ig.is_item_hovered() and ig.is_mouse_clicked(0) then
      open_project(p.dir)
      return
    end
    if ig.is_item_hovered() and ig.is_mouse_clicked(1) then
      picker.menu = i
    end
    -- card bg
    local dl = ig.get_window_draw_list()
    local hovered = ig.is_item_hovered()
    ig.dl_add_rect_filled(dl, cx, cy, cx + card_w, cy + card_h,
                          hovered and 0.16 or 0.115, hovered and 0.17 or 0.12,
                          hovered and 0.20 or 0.145, 1, 6)
    -- thumbnail
    local tid = nil
    if tw.file.exists(p.dir .. "/thumb.png") then
      if not picker.thumbs[p.dir] then
        local img = tw.file.load_image(p.dir .. "/thumb.png")
        if img then
          picker.thumbs[p.dir] = tw.gfx.register(img)
        end
      end
      tid = picker.thumbs[p.dir]
    end
    if tid then
      ig.dl_add_image(dl, tid, cx + 10, cy + 10, cx + card_w - 10, cy + 120,
                      0, 0, 1, 1)
    else
      ig.dl_add_rect_filled(dl, cx + 10, cy + 10, cx + card_w - 10, cy + 120,
                            0.05, 0.052, 0.06, 1, 4)
    end
    -- name
    ig.dl_add_text(dl, cx + 10, cy + 130, p.name, 0.82, 0.83, 0.86, 1)
    ig.dl_add_text(dl, cx + 10, cy + 150, "open / delete", 0.4, 0.42, 0.47, 1)
  end

  -- context menu on a project card
  if picker.menu then
    local p = projects[picker.menu]
    if p then
      ig.open_popup("##projmenu")
      if ig.begin_popup("##projmenu") then
        if ig.menu_item("Open") then
          open_project(p.dir)
          return
        end
        if ig.menu_item("Rename...") then
          picker.renaming = p
        end
        if ig.menu_item("Delete") then
          picker.deleting = p
        end
        ig.end_popup()
      end
    end
    picker.menu = nil
  end

  -- rename dialog
  if picker.renaming then
    local p = picker.renaming
    ig.open_popup("##renameproj")
    if ig.begin_popup_modal("##renameproj") then
      ig.text("Rename " .. p.name)
      local ch, v = ig.input_text("##newname", picker.new_name or p.name, 128)
      if ch then picker.new_name = v end
      if ig.button("Rename") and picker.new_name and picker.new_name ~= "" then
        local new = doc.projects_dir() .. "/" .. picker.new_name
        pcall(tw.file.rename, p.dir, new)
        picker.renaming = nil
        picker.new_name = nil
        ig.close_current_popup()
      end
      ig.same_line()
      if ig.button("Cancel") then
        picker.renaming = nil
        picker.new_name = nil
        ig.close_current_popup()
      end
      ig.end_popup()
    end
  end

  -- delete dialog
  if picker.deleting then
    local p = picker.deleting
    ig.open_popup("##deleteproj")
    if ig.begin_popup_modal("##deleteproj") then
      ig.text("Delete project " .. p.name .. "?")
      ig.text_colored("Removes the folder permanently.", 0.8, 0.4, 0.4, 1)
      if ig.button("Delete") then
        pcall(tw.file.remove_tree, p.dir)
        picker.deleting = nil
        ig.close_current_popup()
      end
      ig.same_line()
      if ig.button("Cancel") then
        picker.deleting = nil
        ig.close_current_popup()
      end
      ig.end_popup()
    end
  end

  ig.end_child()
end

picker.thumbs = {}

function picker.reset_thumbs()
  picker.thumbs = {}
end

function open_project(dir)
  if not doc.load(dir) then
    tw.log_error("failed to open project: " .. dir)
  end
end

return picker
