-- main.lua — bootstrap + per-frame orchestration. Everything the app
-- does flows from here: picker vs editor, panel layout, shortcuts,
-- autosave tick, theme.

local json = require("json")

-- globals on purpose: the console REPL reaches them by name
doc = require("doc")
undo = require("undo")
render = require("render")
autosave = require("autosave")
export = require("export")
import = require("import")
panels = require("panels")
preview = require("preview")
console = require("console")
picker = require("picker")
theme = require("theme")
layer_panel = require("panel_layers")
props_panel = require("panel_props")
palette_panel = require("panel_palette")
export_panel = require("panel_export")

for _, t in ipairs({ "image", "paint", "noise", "grade", "palette",
                     "downscale", "seamless", "fill", "group", "export" }) do
  render.register(t, require("layers." .. t))
end

local frame_n = 0

-- ── startup ─────────────────────────────────────────────────────────────────

local function arg_value(name)
  local args = tw.args
  for i = 1, #args do
    if args[i] == name and args[i + 1] then return args[i + 1] end
  end
  return nil
end

local project_dir = arg_value("--project")
if project_dir then
  if doc.load(project_dir) then
    undo.load_journal()
    tw.log("opened " .. project_dir)
  else
    tw.log_error("failed to open project: " .. project_dir)
  end
end

-- drop / dialog / paste routing (called from C++ on events)
function tw.on_drop(path)
  if path then import.file(path) end
end

-- console helper: reload the whole Lua side without restarting
function tw.reload()
  tw.log("reload: re-running main.lua")
  local ok, err = pcall(function()
    local m = require("main")
    return m
  end)
  if not ok then tw.log_error("reload failed: " .. tostring(err)) end
end

-- ── frame ───────────────────────────────────────────────────────────────────

local function split_v(rect, frac)
  local h1 = math.floor(rect.h * frac)
  return { x = rect.x, y = rect.y, w = rect.w, h = h1 },
         { x = rect.x, y = rect.y + h1, w = rect.w, h = rect.h - h1 }
end

local function panel(id, rect, title, fn, opts)
  local open = panels.begin(id, rect, title, opts)
  if open then fn() end
  panels.end_()
end

local function editor_frame()
  panels.tick_splitters()
  local r = panels.rects()
  panels.toolbar(r.top)

  local layers_r, palette_r = split_v(r.left, 0.62)
  local props_r, export_r = split_v(r.right, 0.62)

  panel("##layers", layers_r, "Layers", function()
    layer_panel.frame()
  end)
  panel("##palette", palette_r, "Palette", function()
    palette_panel.frame()
  end)
  panel("##props", props_r, "Properties", function()
    props_panel.frame()
  end)
  panel("##exports", export_r, "Export", function()
    export_panel.frame()
  end)
  panel("##console", r.bottom, "Console", function()
    console.frame()
  end)
  panel("##preview", r.center, "Preview", function()
    preview.frame(r.center)
  end)

  import.handle_shortcuts()
end

function tw.frame()
  frame_n = frame_n + 1
  theme.apply()
  console.poll_logs()

  if doc.loaded then
    editor_frame()
  else
    picker.frame()
  end

  doc._coalescing = false
  autosave.tick(frame_n)
  theme.frame_end()
end

tw.log("texturewrangler lua ready")
