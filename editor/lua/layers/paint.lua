-- layers/paint.lua — paint layer: replayable strokes (polylines + params),
-- so undo is cheap and files stay tiny. Strokes store paint-time canvas
-- size and are scaled to the current working size at render, so a
-- downscale below keeps them aligned. Custom brush: stamp from another
-- layer's output (any layer, hidden ones included).

local M = {}

local function render_strokes(l, size)
  local img = tw.tex.new(size[1], size[2], { r = 0, g = 0, b = 0, a = 0 })
  local p = l.params
  local stamp = nil
  if p.stamp_layer then
    local sl = doc.get_layer(p.stamp_layer)
    if sl and sl.id ~= l.id then
      stamp = render.layer(sl, size, nil, nil)
    end
  end
  for _, s in ipairs(p.strokes or {}) do
    local pts = s.points
    if #pts < 1 then goto continue end
    -- stroke points are canvas-normalized (0..1); scale by current size.
    -- brush size was stored in px at paint time; rescale by size ratio.
    local sc = 1
    if s.canvas and s.canvas[1] > 0 then
      sc = size[1] / s.canvas[1]
    end
    local radius = (s.size or 6) / 2 * sc
    if radius < 0.1 then goto continue end
    local mode = s.eraser and 1 or 0
    local color = s.color or { r = 255, g = 255, b = 255, a = 255 }
    local hardness = s.hardness or 0.5
    for i = 1, #pts do
      local px = pts[i].x * size[1]
      local py = pts[i].y * size[2]
      if i == 1 then
        tw.tex.stamp(img, px, py, radius, hardness, color, stamp,
                     (s.size or 6) * sc, mode)
      else
        local prev = pts[i - 1]
        local dx = px - prev.x * size[1]
        local dy = py - prev.y * size[2]
        local dist = math.sqrt(dx * dx + dy * dy)
        local step = math.max(0.5, radius * 0.25)
        local n = math.max(1, math.ceil(dist / step))
        for j = 1, n do
          local t = j / n
          tw.tex.stamp(img, prev.x * size[1] + dx * t, prev.y * size[2] + dy * t,
                       radius, hardness, color, stamp, (s.size or 6) * sc, mode)
        end
      end
    end
    ::continue::
  end
  return img
end

function M.render(l, size)
  return render_strokes(l, size)
end

-- palette-lock: the palette of the nearest palette layer at/below this
-- layer in the stack (its extracted palette), or nil.
function M.palette_for_paint(l)
  local idx = doc.stack_index(l.id)
  if not idx then return nil end
  for i = idx, 1, -1 do
    local x = doc.layers[i]
    if x.type == "palette" and x.params.palette and #x.params.palette > 0 then
      return x.params.palette
    end
  end
  return nil
end

function M.panel(l, ui)
  local p = l.params
  ui.color("Color", p.color, function(v) p.color = v end)
  local pal = M.palette_for_paint(l)
  if pal then
    ui.check("Palette-lock", p.palette_lock, function(v) p.palette_lock = v end)
    if p.palette_lock and #pal > 0 then
      ui.text("Palette:")
      local cols = math.max(1, math.floor(ui.avail_w() / 26))
      for i, c in ipairs(pal) do
        if (i - 1) % cols ~= 0 then ui.same_line() end
        if ui.color_swatch("pal" .. i, c) then
          ui.mutate(function()
            p.color = { r = c.r, g = c.g, b = c.b, a = 255 }
          end, "Pick color")
        end
      end
      ui.new_line()
    end
  end
  ui.slider("Size", p.size, 1, 256, function(v) p.size = math.floor(v) end)
  ui.slider("Hardness", p.hardness, 0, 1, function(v) p.hardness = v end)
  ui.check("Eraser", p.eraser, function(v) p.eraser = v end)
  -- custom brush: pick a layer to use as the stamp
  local layers = {}
  local names = {}
  local current = 0
  for _, x in ipairs(doc.all_layers()) do
    if x.type ~= "group" and x.id ~= l.id then
      layers[#layers + 1] = x.id
      names[#names + 1] = x.name
      if x.id == p.stamp_layer then current = #layers end
    end
  end
  names[#names + 1] = "(none)"
  layers[#layers + 1] = nil
  ui.combo("Brush source", names, current, function(v)
    ui.mutate(function() p.stamp_layer = layers[v] end, "Brush source")
  end)
  ui.text(string.format("%d stroke(s)", #(p.strokes or {})))
  if #(p.strokes or {}) > 0 and ui.button("Clear strokes") then
    ui.mutate(function() p.strokes = {} end, "Clear paint")
  end
end

return M
