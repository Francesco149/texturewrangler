-- import.lua — image import: drag&drop, clipboard paste, Ctrl+U dialog.
-- All routes land in the same place: copy the file into assets/, create
-- an image layer (creating a project first if none is open), select it.
-- If no project is open, a new one is created named from the file.

local import = {}
local ig = tw.ig

local IMAGE_EXT = { png = true, jpg = true, jpeg = true, bmp = true, tga = true,
                    gif = true, webp = true }

function import.is_image(path)
  local ext = path:match("%.([%w]+)$")
  return ext and IMAGE_EXT[ext:lower()] or false
end

-- open the native file dialog (async; result routes through on_drop)
function import.open_dialog()
  tw.app.open_file_dialog("Import image")
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
  if io.key_ctrl and not io.want_capture_keyboard then
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
