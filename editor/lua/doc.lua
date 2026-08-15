-- doc.lua — the document model: layer tree, params, serialization, undo
-- hooks. Everything is pure data (params + polyline strokes; images live
-- in assets/ referenced by id) so the whole doc round-trips through JSON.
-- Mutation discipline: UI mutations go through doc.mutate(fn, label) which
-- snapshots for undo + marks dirty for autosave. Rendering never mutates
-- the doc (the one exception: palette layers store their derived palette
-- in params — deterministic, idempotent).

local json = require("json")

local doc = {}

doc.name = "untitled"
doc.canvas = { 64, 64 }
doc.layers = {}           -- array, index 1 = BOTTOM
doc.exports = {}          -- { {name=, path=, auto=bool, format=} }
doc.assets = {}           -- id -> { file = "x.png", w = n, h = n }
doc.path = nil            -- absolute project dir (nil = unsaved new project)
doc.dirty = false
doc.loaded = false

doc._ver = {}             -- layer id -> version int (bumped on any change)
doc._parent = {}          -- layer id -> parent layer id (groups)
doc._cache = {}           -- id -> { token=, img=, size=, texid= }  (full-res)
doc._thumb_cache = {}     -- id -> same (32px thumbnails)
doc._asset_cache = {}     -- asset id -> decoded Image
doc._in_flight = nil      -- paint stroke layer id being drawn right now
doc._coalescing = false   -- slider-drag undo coalescing

-- layer ids must be unique across SESSIONS, not just this process: the
-- old format (clock+process-local counter) restarted at 0 in every
-- process, so two sessions doing similar startup work minted IDENTICAL
-- ids (the second process's "l1d1" silently collided with the first's —
-- doc.get_layer then returned the wrong layer and group/delete corrupted
-- the doc). time() separates sessions; the "_" separates the counter so
-- deserialize can resume past loaded ids; the clock adds entropy.
local id_counter = 0
local function new_id()
  id_counter = id_counter + 1
  return string.format("l%x%x_%x", os.time() % 0xffff,
                       math.floor(os.clock() * 1000) % 0xffff, id_counter)
end

-- ── layer factory ───────────────────────────────────────────────────────────

local defaults = {
  image = { asset = nil, filter = "bilinear", offset = { 0, 0 } },
  paint = { color = { r = 235, g = 158, b = 89, a = 255 }, size = 6,
            hardness = 0.5, eraser = false, stamp_layer = nil,
            palette_lock = false, strokes = {} },
  noise = { type = "value", scale = 8, octaves = 1, seed = 1,
            tint = { r = 255, g = 255, b = 255, a = 255 },
            colorize = 0, alpha_from = false },
  grade = { brightness = 0, contrast = 0, gamma = 1, saturation = 1,
            vibrance = 0, hue = 0, temperature = 0, tint = 0,
            colorize = { r = 255, g = 255, b = 255, a = 255 },
            colorize_strength = 0 },
  palette = { colors = 16, method = "mediancut", dither = "none",
              alpha_mode = 0, palette = nil },
  downscale = { size = { 64, 64 }, filter = "aniso" },
  crop = { x = 0, y = 0, w = 0, h = 0 },
  seamless = { blend = 8, mode = "offset" },
  fill = { type = "solid", c0 = { r = 255, g = 255, b = 255, a = 255 },
           c1 = { r = 0, g = 0, b = 0, a = 0 }, angle = 0,
           cx = 0.5, cy = 0.5, rx = 0.5, ry = 0.5 },
  group = { include_below = false },
  export = { export_name = nil, size = nil, format = "png" },
}

doc.type_names = {
  image = "Image", paint = "Paint", noise = "Noise", grade = "Grade",
  palette = "Palette", downscale = "Downscale", seamless = "Seamless",
  fill = "Fill", group = "Group", export = "Export", crop = "Crop",
}

local function deepcopy(t)
  if type(t) ~= "table" then return t end
  local r = {}
  for k, v in pairs(t) do r[k] = deepcopy(v) end
  return r
end

-- unique display name for auto-named layers: "Group", "Group 2", ...
-- (explicit names — imports, duplicates — are kept as given)
function doc.unique_name(base)
  local taken = {}
  for _, l in ipairs(doc.all_layers()) do taken[l.name] = true end
  if not taken[base] then return base end
  local i = 2
  while taken[base .. " " .. i] do i = i + 1 end
  return base .. " " .. i
end

function doc.new_layer(type, name)
  local d = deepcopy(defaults[type] or {})
  local n = name or (doc.type_names[type] or type)
  if not name then n = doc.unique_name(n) end
  return { id = new_id(), type = type,
           name = n,
           visible = true, opacity = 1, blend = "normal", params = d,
           children = type == "group" and {} or nil }
end

-- ── tree ops ────────────────────────────────────────────────────────────────

function doc.all_layers()
  -- flat bottom→top walk (groups flattened in place)
  local out = {}
  local function walk(list)
    for _, l in ipairs(list) do
      out[#out + 1] = l
      if l.children then walk(l.children) end
    end
  end
  walk(doc.layers)
  return out
end

function doc.get_layer(id)
  for _, l in ipairs(doc.all_layers()) do
    if l.id == id then return l end
  end
  return nil
end

-- parent layer of a layer (nil if root). doc._parent maps id→parent id;
-- callers want the parent LAYER (its .children list) — returning the bare
-- id here made every caller's `parent.children` silently fall back to the
-- ROOT list for grouped layers (drag reorder no-op, group/delete corrupting
-- the wrong list).
function doc.find_parent(id)
  local pid = doc._parent[id]
  if not pid then return nil end
  return doc.get_layer(pid)
end

-- flat index of a layer in doc.layers (groups count as one)
function doc.stack_index(id)
  for i, l in ipairs(doc.layers) do
    if l.id == id then return i end
  end
  return nil
end

function doc.add_layer(layer, parent_id, at_top)
  -- default: insert at the TOP of the stack (layers[1] = bottom)
  local parent = parent_id and doc.get_layer(parent_id) or nil
  local list = parent and parent.children or doc.layers
  if at_top == false then
    table.insert(list, 1, layer)
  else
    table.insert(list, #list + 1, layer)
  end
  doc._parent[layer.id] = parent_id or nil
  if layer.children then
    for _, c in ipairs(layer.children) do doc._parent[c.id] = layer.id end
  end
  doc.bump(layer)
end

function doc.remove_layer(id)
  local l = doc.get_layer(id)
  if not l then return end
  local parent = doc.find_parent(id)
  local list = parent and parent.children or doc.layers
  for i, x in ipairs(list) do
    if x.id == id then table.remove(list, i); break end
  end
  local function drop(layer)
    doc._ver[layer.id] = nil
    doc._parent[layer.id] = nil
    doc.drop_cache(layer.id)
    if layer.children then
      for _, c in ipairs(layer.children) do drop(c) end
    end
  end
  drop(l)
  if parent then doc.bump(parent) end
  doc.bump_all()
end

function doc.move_layer(id, to_index)
  local parent = doc.find_parent(id)
  local list = parent and parent.children or doc.layers
  local from = nil
  for i, x in ipairs(list) do if x.id == id then from = i; break end end
  if not from then return end
  local l = table.remove(list, from)
  table.insert(list, math.max(1, math.min(#list + 1, to_index)), l)
  doc.bump_all()
end

-- ── versions + caches ───────────────────────────────────────────────────────

function doc.bump(layer)
  doc._ver[layer.id] = (doc._ver[layer.id] or 0) + 1
  -- propagate up through parents (parent output depends on children)
  local p = doc._parent[layer.id]
  while p do
    doc._ver[p] = (doc._ver[p] or 0) + 1
    p = doc._parent[p]
  end
end

function doc.bump_all()
  for _, l in ipairs(doc.all_layers()) do
    doc._ver[l.id] = (doc._ver[l.id] or 0) + 1
  end
end

function doc.drop_cache(id)
  local function drop(cache)
    local e = cache[id]
    if e and e.texid then pcall(tw.gfx.release, e.texid) end
    cache[id] = nil
  end
  drop(doc._cache)
  drop(doc._thumb_cache)
end

function doc.clear_caches()
  for _, l in ipairs(doc.all_layers()) do doc.drop_cache(l.id) end
  for k in pairs(doc._asset_cache) do doc._asset_cache[k] = nil end
end

-- mutation with undo snapshot + dirty flag. Every mutation invalidates
-- the whole render cache (bump_all) — O(n) at our stack sizes, and it
-- removes an entire class of "forgot to bump" staleness bugs.
function doc.mutate(fn, label)
  undo.push(label or "edit")
  local ok, err = pcall(fn)
  if not ok then
    undo.rollback()
    error(err, 0)
  end
  doc.bump_all()
  doc.dirty = true
end

-- coalesced mutation (slider drags: one undo entry per interaction)
function doc.coalesce_mutate(fn)
  if doc._coalescing then
    pcall(fn)
  else
    doc._coalescing = true
    doc.mutate(fn)
  end
  doc.bump_all()
  doc.dirty = true
end

-- ── assets ─────────────────────────────────────────────────────────────────

function doc.add_asset(src_path)
  local ext = src_path:match("%.([%w]+)$") or "png"
  if ext:lower() == "jpeg" then ext = "jpg" end
  local aid = string.format("a%x", math.floor(os.clock() * 1000) % 0xffff)
  local fname = aid .. "." .. ext
  local img = tw.file.load_image(src_path)
  if not img then return nil end
  local w, h = tw.tex.size(img)
  doc.assets[aid] = { file = fname, w = w, h = h }
  if doc.path then
    tw.file.mkdirs(doc.path .. "/assets")
    tw.file.copy(src_path, doc.path .. "/assets/" .. fname)
  end
  doc._asset_cache[aid] = img
  return aid
end

function doc.asset_image(aid)
  local a = doc.assets[aid]
  if not a then return nil end
  local img = doc._asset_cache[aid]
  if img then return img end
  if doc.path then
    img = tw.file.load_image(doc.path .. "/assets/" .. a.file)
    if img then doc._asset_cache[aid] = img end
  end
  return img
end

-- ── serialize / load ────────────────────────────────────────────────────────

function doc.serialize()
  return {
    name = doc.name,
    canvas = { doc.canvas[1], doc.canvas[2] },
    version = 1,
    layers = doc.layers,
    exports = doc.exports,
    assets = doc.assets,
  }
end

function doc.deserialize(t)
  doc.name = t.name or "untitled"
  doc.canvas = { t.canvas and t.canvas[1] or 64, t.canvas and t.canvas[2] or 64 }
  doc.layers = deepcopy(t.layers or {})
  doc.exports = deepcopy(t.exports or {})
  doc.assets = deepcopy(t.assets or {})
  doc._parent = {}
  local function index(list, parent_id)
    for _, l in ipairs(list) do
      doc._parent[l.id] = parent_id or nil
      doc._ver[l.id] = 0
      -- resume the id counter past every id in the doc, so layers created
      -- in THIS process can't collide with ones loaded from disk (the
      -- counter is the "_"-separated trailing hex group)
      local c = l.id and l.id:match("_(%x+)$")
      if c then
        local n = tonumber(c, 16)
        if n and n > id_counter then id_counter = n end
      end
      if l.children then index(l.children, l.id) end
    end
  end
  index(doc.layers, nil)
  doc.clear_caches()
  doc.dirty = false
  doc.loaded = true
  -- default selection: the top-most root layer
  if #doc.layers > 0 and not panels.selected() then
    panels.set_selected(doc.layers[#doc.layers].id)
  end
end

function doc.save()
  if not doc.path then return false end
  tw.file.mkdirs(doc.path)
  local ok = tw.file.write_text(doc.path .. "/project.json",
                                json.encode(doc.serialize()))
  doc.dirty = false
  -- thumbnail for the picker (64px, cheap)
  pcall(function()
    local img = render.composite(nil, doc.canvas, doc._cache)
    if img then
      local w, h = tw.tex.size(img)
      local thumb = (w == 64 and h == 64) and img or tw.tex.resize(img, 64, 64, "box")
      tw.file.save_image(thumb, doc.path .. "/thumb.png")
    end
  end)
  return ok
end

function doc.load(path)
  doc.path = path
  local text = tw.file.read_text(path .. "/project.json")
  if not text then return false end
  local ok, data = pcall(json.decode, text)
  if not ok then
    tw.log_error("project.json parse error: " .. tostring(data))
    return false
  end
  doc.deserialize(data)
  return true
end

-- new project in the standard projects dir
function doc.projects_dir()
  local home = tw.file.home()
  return home .. "/texturewrangler/projects"
end

-- paint stroke plumbing (called from the preview panel) ──────────────────

-- w, h = the working size the stroke is authored in (the displayed
-- composite size at paint time). Defaults to doc.canvas for programmatic
-- callers (demo.lua). Storing the WORKING size (not doc.canvas) is what
-- keeps brush px and stroke placement correct when a downscale layer makes
-- the working size differ from the project canvas.
function doc.paint_begin(layer_id, w, h)
  local l = doc.get_layer(layer_id)
  if not l or l.type ~= "paint" then return false end
  -- snapshot BEFORE the stroke lands: doc.mutate's push is a no-op here
  -- because the stroke is added incrementally across begin/append, and
  -- pushing at paint_end would capture the POST-stroke state, making the
  -- first Ctrl+Z restore the doc to itself (undo appeared dead).
  undo.push("Paint")
  doc._in_flight = layer_id
  local p = l.params
  local stroke = { points = {}, size = p.size, hardness = p.hardness,
                   color = deepcopy(p.color), eraser = p.eraser,
                   stamp_layer = p.stamp_layer,
                   canvas = { w or doc.canvas[1], h or doc.canvas[2] } }
  p.strokes[#p.strokes + 1] = stroke
  return true
end

function doc.paint_append(x, y)
  local l = doc._in_flight and doc.get_layer(doc._in_flight)
  if not l then return end
  local s = l.params.strokes[#l.params.strokes]
  local px = x / doc.canvas[1]
  local py = y / doc.canvas[2]
  local last = s.points[#s.points]
  if last and (last.x - px) ^ 2 + (last.y - py) ^ 2 < 0.0001 then return end
  s.points[#s.points + 1] = { x = px, y = py }
end

function doc.paint_end()
  if not doc._in_flight then return end
  local l = doc.get_layer(doc._in_flight)
  doc._in_flight = nil
  if l then
    -- the undo entry was already pushed at paint_begin; here we only need
    -- the mutate tail (cache invalidation + dirty) so the stroke shows.
    doc.bump_all()
    doc.dirty = true
  end
end

return doc
