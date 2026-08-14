-- main.lua — bootstrap + per-frame orchestration. Everything the app
-- does flows from here: picker vs editor, panel layout, shortcuts,
-- autosave tick, theme.

local json = require("json")
local ig = tw.ig

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
perf = require("perf")
layer_panel = require("panel_layers")
props_panel = require("panel_props")
palette_panel = require("panel_palette")
export_panel = require("panel_export")

for _, t in ipairs({ "image", "paint", "noise", "grade", "palette",
                     "downscale", "crop", "seamless", "fill", "group", "export" }) do
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
if not project_dir then
  local demo_dir = arg_value("--demo")
  if demo_dir then
    local demo = require("demo")
    if demo.build(demo_dir) then project_dir = demo_dir end
  end
end
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

-- headless script: texturewrangler --lua <file.lua> [--project <dir>]
local lua_script = arg_value("--lua")
if lua_script then
  local f = io.open(lua_script, "r")
  if f then
    local code = f:read("*a")
    f:close()
    local chunk, lerr = load(code, lua_script)
    if not chunk then
      tw.log_error("script load: " .. tostring(lerr))
      os.exit(1)
    end
    local ok, rerr = pcall(chunk)
    if not ok then
      tw.log_error("script: " .. tostring(rerr))
      os.exit(1)
    end
  else
    tw.log_error("cannot open script: " .. lua_script)
    os.exit(1)
  end
  os.exit(0)
end

-- headless export: texturewrangler --project <dir> --export
local export_mode = false
for i = 1, #tw.args do
  if tw.args[i] == "--export" then export_mode = true end
end
if export_mode then
  local n = export.all()
  tw.log("exported " .. n .. " file(s)")
  os.exit(0)
end

-- ── frame ───────────────────────────────────────────────────────────────────

local function split_v(rect, frac)
  local h1 = math.floor(rect.h * frac)
  return { x = rect.x, y = rect.y, w = rect.w, h = h1 },
         { x = rect.x, y = rect.y + h1, w = rect.w, h = rect.h - h1 }
end

local function panel(id, rect, title, fn, opts)
  local open = panels.begin(id, rect, title, opts)
  if open then
    local ok, err = pcall(fn)
    if not ok then
      tw.log_error("panel " .. id .. ": " .. tostring(err))
    end
  end
  panels.end_()
end

-- fullscreen undecorated main window: all panels dock as children. Shared
-- by the editor and the picker — a BeginChild without a parent Begin would
-- otherwise get imgui's auto-created Debug##Default window (unthemed chrome).
local MAIN_FLAGS = ig.wflag.NoTitleBar + ig.wflag.NoResize + ig.wflag.NoMove +
                   ig.wflag.NoScrollbar + ig.wflag.NoCollapse + ig.wflag.NoSavedSettings

local function begin_main(w, h)
  ig.set_next_window_pos(0, 0)
  ig.set_next_window_size(w, h)
  ig.begin("##main", MAIN_FLAGS)
end

-- the Project toolbar button: a hover-menu. Opens on click or hover
-- (armed), and closes when the mouse leaves both the button and the menu.
-- The old version called open_popup every frame while the flag was set,
-- which re-opened a just-closed popup on the next frame ("can never go
-- away") and re-anchored it to the cursor every frame (draggable feel).
local function project_popup_frame()
  local st = panels.state
  if not st.project_popup then return end
  if not st.project_popup_open then
    ig.open_popup("##project")
    st.project_popup_open = true
  end
  if ig.begin_popup("##project") then
    local popup_hover = ig.is_window_hovered()
    ig.text(doc.name)
    ig.text_colored(doc.path or "(unsaved)", 0.45, 0.47, 0.52, 1)
    ig.separator()
    if ig.menu_item("Export all") then export.all() end
    if doc.path and ig.menu_item("Open folder") then
      tw.app.open_folder(doc.path)
    end
    if ig.menu_item("Save now") then doc.save() end
    ig.end_popup()
    if not popup_hover and not st.project_btn_hover then
      ig.close_current_popup()
      st.project_popup = false
      st.project_popup_open = false
    end
  else
    -- closed (escape, click elsewhere, item click) — drop the flag so the
    -- popup is not re-opened next frame.
    st.project_popup = false
    st.project_popup_open = false
  end
end

local function editor_frame()
  panels.tick_splitters()
  local r = panels.rects()

  begin_main(r.top.w + r.center.w + r.right.w, r.center.h + r.bottom.h + r.top.h)
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
  end, { collapsible = true })
panel("##preview", r.center, "Preview", function()
    preview.frame(r.center)
  end)
  panels.draw_splitter_highlight()
  project_popup_frame()
  import.browser_frame()
  ig.end_()

  import.handle_shortcuts()
end

function tw.frame()
  frame_n = frame_n + 1
  local t0 = os.clock()
  theme.apply()
  console.poll_logs()
  local ok, err = pcall(function()
    if doc.loaded then
      editor_frame()
    else
      local io = ig.get_io()
      begin_main(io.display_w, io.display_h)
      picker.frame()
      ig.end_()
    end
  end)
  if not ok then
    tw.log_error("frame: " .. tostring(err))
  end
  doc._coalescing = false
  autosave.tick(frame_n)
  theme.frame_end()
  perf.tick((os.clock() - t0) * 1000, perf.comp_ms)
  perf.draw_overlay(12, 40)
end

tw.log("texturewrangler lua ready")
