-- import.lua — image import: drag&drop, clipboard paste, Ctrl+U dialog.
-- All routes land in the same place: copy the file into assets/, create
-- an image layer (creating a project first if none is open), select it.
-- If no project is open, a new one is created named from the file.

local import = {}
local ig = tw.ig

-- stb is built without a webp decoder (see file.cpp STBI_ONLY_*), so webp
-- would silently fail to load — keep the filter honest.
local IMAGE_EXT = { png = true, jpg = true, jpeg = true, bmp = true, tga = true,
                    gif = true }

function import.is_image(path)
  local ext = path:match("%.([%w]+)$")
  return ext and IMAGE_EXT[ext:lower()] or false
end

-- open the native file dialog (async; result routes through on_drop).
-- On Linux the dialog needs the xdg-desktop-portal, which WSLg does not
-- run — SDL reports the failure immediately, so fall back to the in-app
-- file browser (import.browser_frame) instead of silently doing nothing.
function import.open_dialog()
  local ok = tw.app.open_file_dialog("Import image")
  if not ok then
    import.browser.open = true
    import.browser.dir = import.browser.dir or tw.file.home()
  end
end

-- ── in-app file browser (import) ───────────────────────────────────────────
-- A small modal: navigate directories, pick an image file. Works without
-- any desktop portal. Drawn every frame from main.lua.

import.browser = { open = false, dir = nil, sel = nil, last_click = 0 }

function import.browser_frame()
  local b = import.browser
  if not b.open then return end
  ig.open_popup("##import_browser")
  ig.set_next_window_size(560, 420)
  if not ig.begin_popup_modal("##import_browser") then return end
  ig.text("Import image")
  ig.separator()

  local dir = b.dir or tw.file.home()
  b.dir = dir
  local parent = tw.file.dirname(dir)
  local entries, n = tw.file.list(dir)
  local dirs, files = {}, {}
  for i = 1, n do
    local name = entries[i]
    if name ~= "." and name ~= ".." then
      local full = tw.file.join(dir, name)
      if tw.file.is_dir(full) then
        dirs[#dirs + 1] = name
      elseif import.is_image(name) then
        files[#files + 1] = name
      end
    end
  end
  table.sort(dirs)
  table.sort(files)

  -- current path
  ig.text_colored(dir, 0.45, 0.47, 0.52, 1)
  ig.separator()

  local now = os.clock()
  local function pick(row_id, name, action)
    -- single click selects; a second click within 0.4 s runs action
    if ig.selectable(row_id, b.sel == name) then
      if b.sel == name and now - b.last_click < 0.4 then
        b.sel = nil
        b.last_click = 0
        action()
      else
        b.sel = name
        b.last_click = now
      end
    end
  end

  local lw, lh = ig.get_content_region_avail()
  ig.begin_child("##browser_list", lw, lh - 40, 1, 0)
  if parent and parent ~= dir then
    pick("[..]", "..", function() b.dir = parent end)
  end
  for _, d in ipairs(dirs) do
    pick("[dir] " .. d, d, function() b.dir = tw.file.join(dir, d) end)
  end
  for _, f in ipairs(files) do
    pick(f, f, function() import.file(tw.file.join(dir, f)) end)
  end
  ig.end_child()

  -- bottom bar
  if b.sel and b.sel ~= ".." then
    local full = tw.file.join(dir, b.sel)
    if not tw.file.is_dir(full) and ig.button("Import " .. b.sel) then
      import.file(full)
    end
  end
  ig.same_line()
  if ig.button("Cancel") then
    b.open = false
    b.sel = nil
    ig.close_current_popup()
  end
  ig.end_popup()
end

-- main entry: handle one image file path
function import.file(path)
  if not import.is_image(path) then
    tw.log("ignored non-image: " .. path)
    return
  end
  if not doc.loaded then
    -- bootstrap: new project named after the file, canvas = image size
    local base = tw.file.basename(path):gsub("%.[%w]+$", "")
    if base == "" then base = "new-project" end
    new_project(base)
  end
  doc.mutate(function()
    local aid = doc.add_asset(path)
    if not aid then
      tw.log_error("failed to load image: " .. path)
      return
    end
    local a = doc.assets[aid]
    -- first image layer sets the canvas if it's still the default
    if #doc.layers == 0 and doc.canvas[1] == 64 and doc.canvas[2] == 64 then
      doc.canvas = { a.w, a.h }
    end
    local l = doc.new_layer("image", tw.file.basename(path):gsub("%.[%w]+$", ""))
    l.params.asset = aid
    doc.add_layer(l)
    panels.set_selected(l.id)
  end, "Import image")
end

-- clipboard paste → save to assets → image layer
function import.paste()
  local img = tw.app.paste_image()
  if not img then
    tw.log("clipboard has no image")
    return
  end
  local w, h = tw.tex.size(img)
  if not doc.loaded then
    new_project("pasted-texture")
  end
  doc.mutate(function()
    local aid = string.format("a%x", math.floor(os.clock() * 1000) % 0xffff)
    local fname = aid .. ".png"
    doc.assets[aid] = { file = fname, w = w, h = h }
    if doc.path then
      tw.file.mkdirs(doc.path .. "/assets")
      tw.file.save_image(img, doc.path .. "/assets/" .. fname)
    end
    if #doc.layers == 0 then doc.canvas = { w, h } end
    local l = doc.new_layer("image", "pasted")
    l.params.asset = aid
    doc.add_layer(l)
    panels.set_selected(l.id)
  end, "Paste image")
end

function import.handle_shortcuts()
  local io = ig.get_io()
  -- Gate on want_text_input, NOT want_capture_keyboard: with
  -- NavEnableKeyboard enabled, imgui sets WantCaptureKeyboard as soon as
  -- the mouse hovers any window (NavActive), which permanently blocked
  -- every shortcut in the interactive app. want_text_input is true only
  -- while an InputText is being typed in — exactly when shortcuts must
  -- not fire.
  if io.key_ctrl and not io.want_text_input then
    if ig.is_key_pressed(ig.key.U) then
      import.open_dialog()
    elseif ig.is_key_pressed(ig.key.V) then
      import.paste()
    elseif ig.is_key_pressed(ig.key.E) then
      export.all()
    elseif ig.is_key_pressed(ig.key.Z) then
      if io.key_shift then undo.do_redo() else undo.do_undo() end
    elseif ig.is_key_pressed(ig.key.Y) then
      undo.do_redo()
    end
  end
  -- Delete: remove the selected layer (suppressed while typing in a field)
  if not io.want_text_input and ig.is_key_pressed(ig.key.Delete) then
    local sel = panels.selected()
    local l = sel and doc.get_layer(sel)
    if l then
      doc.mutate(function() doc.remove_layer(sel) end, "Delete layer")
      panels.set_selected(nil)
    end
  end
end

-- create a project directory + open it
function new_project(name)
  local dir = doc.projects_dir() .. "/" .. name
  tw.file.mkdirs(dir)
  doc.name = name
  doc.canvas = { 64, 64 }
  doc.layers = {}
  doc.exports = {}
  doc.assets = {}
  doc.path = dir
  doc.loaded = true
  doc.bump_all()
  panels.set_selected(nil)
  undo.clear()
  doc.save()
  tw.log("new project: " .. dir)
end

return import
