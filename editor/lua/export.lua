-- export.lua — write composites to disk. Default location: the project's
-- export/ folder. Extra named locations (doc.exports) can point anywhere
-- (e.g. a Godot project's texture) and opt into auto-export on change.
-- Exporting the final composite never needs an export layer (implicit top).

local export = {}

local function sanitize(name)
  return (name:gsub('[^%w%._-]', "_"))
end

local function loc_dir(e)
  -- relative paths resolve against the project dir; absolute as-is
  if e.path:match("^/") or e.path:match("^[A-Za-z]:[\\/]") then
    return e.path
  end
  return doc.path .. "/" .. e.path
end

local function default_dir()
  return doc.path .. "/export"
end

local function save_file(img, dir, fname, format)
  tw.file.mkdirs(dir)
  local path = dir .. "/" .. fname
  local ok = tw.file.save_image(img, path)
  if ok then
    tw.log("exported " .. path)
  else
    tw.log_error("export failed: " .. path)
  end
  return ok
end

-- write img to a single named location (dir, auto flag); returns bool
local function save_location(img, loc, fname, format)
  local dir = loc.path and loc_dir(loc) or default_dir()
  return save_file(img, dir, fname, format or "png")
end

-- final composite → every location (named locations get project-name file)
function export.final_composite()
  local img = render.composite(nil, doc.canvas, doc._cache)
  if not img then return 0 end
  local n = 0
  if save_file(img, default_dir(), doc.name .. ".png", "png") then n = n + 1 end
  for _, loc in ipairs(doc.exports or {}) do
    if save_location(img, loc, doc.name .. ".png", "png") then n = n + 1 end
  end
  return n
end

-- one export layer's capture → every location (file named after the layer)
function export.layer_capture(layer)
  local idx = doc.stack_index(layer.id)
  if not idx then return 0 end
  local img = render.composite(idx, doc.canvas, doc._cache)
  if not img then return 0 end
  local p = layer.params
  if p.size and p.size[1] > 0 and p.size[2] > 0 then
    img = tw.tex.resize(img, p.size[1], p.size[2], "box")
  end
  local fname = sanitize(p.export_name or layer.name) .. "." .. (p.format or "png")
  local n = 0
  if save_file(img, default_dir(), fname, p.format or "png") then n = n + 1 end
  for _, loc in ipairs(doc.exports or {}) do
    if save_location(img, loc, fname, p.format or "png") then n = n + 1 end
  end
  return n
end

-- everything: final + all export layers (Export button / Ctrl+E)
function export.all()
  local n = export.final_composite()
  for _, l in ipairs(doc.all_layers()) do
    if l.type == "export" then n = n + export.layer_capture(l) end
  end
  return n
end

-- auto locations only (driven by autosave debounce)
function export.auto_export()
  local any = false
  for _, loc in ipairs(doc.exports or {}) do
    if loc.auto then
      local img = render.composite(nil, doc.canvas, doc._cache)
      if img and save_location(img, loc, doc.name .. ".png", "png") then
        any = true
      end
      for _, l in ipairs(doc.all_layers()) do
        if l.type == "export" then export.layer_capture(l) end
      end
    end
  end
  return any
end

return export
