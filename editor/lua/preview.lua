-- preview.lua — the main canvas: composite preview with 4×4 tiling
-- (toggleable), checkerboard transparency, zoom (fit/1×/2×/4×/ctrl+wheel),
-- alt-drag pan, and paint input when the selected layer is a paint layer.
-- View mode: Final | At layer | Layer only.

local preview = {}
local ig = tw.ig

preview.state = {
  mode = "final", -- "final" | "at" | "layer"
  tile = true,
  zoom = "fit", -- "fit" or pixel zoom factor
  zoom_val = 1,
  ox = 0,
  oy = 0,
}

local cb_texid = nil

local function checkerboard()
  if cb_texid then return cb_texid end
  local img = tw.tex.new(16, 16, { r = 60, g = 62, b = 68, a = 255 })
  for y = 0, 15 do
    for x = 0, 15 do
      local on = ((math.floor(x / 8) + math.floor(y / 8)) % 2) == 0
      local v = on and 52 or 72
      tw.tex.set(img, x, y, v, v, v, 255)
    end
  end
  cb_texid = tw.gfx.register(img)
  return cb_texid
end

-- the image to display for the current mode + selection
local function view_image()
  local sel = panels.selected()
  if preview.state.mode == "layer" and sel then
    return render.layer_only(sel, doc.canvas), nil
  elseif preview.state.mode == "at" and sel then
    local idx = doc.stack_index(sel)
    if idx then return render.composite(idx, doc.canvas, doc._cache), idx end
  end
  return render.composite(nil, doc.canvas, doc._cache), nil
end

local function zoom_fit(avail_w, avail_h, img_w, img_h)
  local n = preview.state.tile and 4 or 1
  local s = math.min(avail_w / (img_w * n), avail_h / (img_h * n))
  return math.max(0.01, s)
end

function preview.frame(rect)
  local img, cache_idx = view_image()
  if not img then
    img = tw.tex.new(64, 64, { r = 0, g = 0, b = 0, a = 0 })
  end
  local w, h = tw.tex.size(img)
  local texid
  if preview.state.mode == "layer" then
    texid = preview.state.texid
    if not texid then
      texid = tw.gfx.register(img)
      preview.state.texid = texid
    else
      texid = tw.gfx.update(texid, img)
    end
    preview.state.texid = texid
  else
    -- final/at: the composite is cached per layer; texid lives in the cache
    local list = doc.layers
    local last = cache_idx or #list
    local l = last >= 1 and list[last] or nil
    texid = l and render.texid_for(doc._cache, l.id, img) or nil
    if not texid then
      texid = preview.state.texid
      if not texid then
        texid = tw.gfx.register(img)
      else
        texid = tw.gfx.update(texid, img)
      end
      preview.state.texid = texid
    end
  end

  -- header row
  ig.set_cursor_pos(0, 30)
  local modes = { "Final", "At layer", "Layer only" }
  local mode_idx = { final = 1, at = 2, layer = 3 }[preview.state.mode]
  local changed, mi = ig.combo("##mode", modes, mode_idx - 1)
  if changed then
    preview.state.mode = ({ "final", "at", "layer" })[mi + 1]
  end
  ig.same_line()
  local tch, tv = ig.checkbox("4×4 tile", preview.state.tile)
  if tch then preview.state.tile = tv end
  ig.same_line()
  local zooms = { "Fit", "1×", "2×", "4×" }
  local zi = { fit = 1, ["1"] = 2, ["2"] = 3, ["4"] = 4 }[preview.state.zoom] or 1
  local zch, znew = ig.combo("##zoom", zooms, zi - 1)
  if zch then
    preview.state.zoom = ({ "fit", "1", "2", "4" })[znew + 1]
    preview.state.zoom_val = ({ 0, 1, 2, 4 })[znew + 1]
  end

  -- content area below the header
  local cw, ch = ig.get_content_region_avail()
  local x0, y0 = ig.get_cursor_screen_pos()
  local avail_w, avail_h = cw - 8, ch - 8

  -- zoom + pan state
  local io = ig.get_io()
  local st = preview.state
  local scale
  if st.zoom == "fit" then
    scale = zoom_fit(avail_w, avail_h, w, h)
    st.ox, st.oy = 0, 0
  else
    scale = st.zoom_val
  end
  local n = st.tile and 4 or 1
  local img_w, img_h = w * n * scale, h * n * scale

  -- ctrl+wheel zoom at cursor
  if ig.is_window_hovered(0) then
    if io.key_ctrl and io.mouse_wheel ~= 0 then
      local mx, my = ig.get_mouse_pos()
      local old = scale
      st.zoom_val = st.zoom_val * (io.mouse_wheel > 0 and 1.15 or 0.87)
      st.zoom_val = math.max(0.05, math.min(64, st.zoom_val))
      st.zoom = "fit"
      if st.zoom_val ~= 0 then
        -- re-anchor the cursor point
        local nx = img_w * (st.zoom_val / old)
        local ny = img_h * (st.zoom_val / old)
        local fx = (mx - st.ox) / img_w
        local fy = (my - st.oy) / img_h
        st.ox = mx - fx * nx
        st.oy = my - fy * ny
      end
    end
    -- pan: alt+drag or middle drag
    if (io.key_alt and ig.is_mouse_dragging(0)) or ig.is_mouse_dragging(2) then
      local dx, dy = ig.get_mouse_drag_delta(ig.is_mouse_dragging(0) and 0 or 2, 0)
      st.ox = st.ox + dx
      st.oy = st.oy + dy
    end
  end

  -- centered placement
  local px = x0 + (avail_w - img_w) / 2 + st.ox
  local py = y0 + (avail_h - img_h) / 2 + st.oy

  local dl = ig.get_window_draw_list()
  -- checkerboard behind the image area
  local cb = checkerboard()
  ig.dl_push_clip_rect(dl, x0, y0, x0 + avail_w, y0 + avail_h, true)
  for cy = 0, math.ceil(avail_h / 16) do
    for cx = 0, math.ceil(avail_w / 16) do
      ig.dl_add_image(dl, cb, x0 + cx * 16, y0 + cy * 16,
                      x0 + (cx + 1) * 16, y0 + (cy + 1) * 16,
                      0, 0, 1, 1)
    end
  end
  -- the image (tiled n×n)
  for ty = 0, n - 1 do
    for tx = 0, n - 1 do
      ig.dl_add_image(dl, texid,
                      px + tx * w * scale, py + ty * h * scale,
                      px + (tx + 1) * w * scale, py + (ty + 1) * h * scale,
                      0, 0, 1, 1)
    end
  end
  -- border
  ig.dl_add_rect(dl, px - 1, py - 1, px + img_w + 1, py + img_h + 1,
                 0.25, 0.27, 0.32, 1, 0, 1)
  ig.dl_pop_clip_rect(dl)

  -- paint input (selected layer is a paint layer, click in canvas)
  local sel = panels.selected()
  local sel_layer = sel and doc.get_layer(sel)
  if sel_layer and sel_layer.type == "paint" and not io.want_capture_mouse then
    local mx, my = ig.get_mouse_pos()
    local in_canvas = mx >= px and mx < px + img_w and my >= py and my < py + img_h
    if ig.is_mouse_clicked(0) and in_canvas and not ig.is_mouse_dragging(2) and
       not (io.key_alt and ig.is_mouse_dragging(0)) then
      doc.paint_begin(sel)
      doc.paint_append((mx - px) / scale, (my - py) / scale)
    elseif doc._in_flight and ig.is_mouse_dragging(0) and in_canvas then
      doc.paint_append((mx - px) / scale, (my - py) / scale)
    elseif doc._in_flight and not ig.is_mouse_down(0) then
      doc.paint_end()
    end
  end

  -- bottom-left info: resolution + mode
  ig.set_cursor_pos(8, 0)
  ig.text_colored(string.format("%d×%d  ·  %s", w, h,
                                ({ final = "final", at = "at layer", layer = "layer only" })[preview.state.mode]),
                  0.45, 0.47, 0.52, 1)
end

return preview
