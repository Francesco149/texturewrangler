-- render.lua — the compositing engine with per-layer output caching.
--
-- Model: working size flows through the stack (a downscale layer changes
-- it for everything above); every layer renders an output image; the
-- composite accumulates bottom-up by blending each output into the result
-- (downscale layers REPLACE the result). Adjustment layers (grade,
-- palette, seamless) transform the partial composite below them — their
-- opacity/blend then fade/mix that transformation, which gives "undo the
-- effect" semantics for free.
--
-- Cache: per-layer {token, img, size, texid}. token = f(version, size);
-- doc.bump() propagates versions up the tree, so ANY change below a layer
-- invalidates it and everything above. In-flight paint strokes bypass the
-- cache so they show up the same frame.

local render = {}
local tex = tw.tex

local function transparent(w, h)
  return tex.new(w, h, { r = 0, g = 0, b = 0, a = 0 })
end

local layer_impls = {}
function render.register(type, impl)
  layer_impls[type] = impl
end

-- render one layer's own output; returns img (or nil) and optional newsize
function render.layer(l, size, below, cache)
  local impl = layer_impls[l.type]
  if not impl then return nil end
  local t0 = os.clock()
  local ok, out, newsize = pcall(impl.render, l, size, below, cache)
  if ok then
    perf.add_layer(l.type, (os.clock() - t0) * 1000)
  else
    tw.log_error(("layer %q (%s): %s"):format(l.name or "?", l.type, tostring(out)))
  end
  return out, newsize
end

-- composite a layer list bottom-up (limit_idx optional; 1-based)
local function composite_list(layers, limit_idx, size0, cache, force_from)
  local img = nil
  local size = { size0[1], size0[2] }
  for i, l in ipairs(layers) do
    if limit_idx and i > limit_idx then break end
    local forced = force_from and i >= force_from
    local token = (doc._ver[l.id] or 0) * 131 + size[1] * 7 + size[2]
    local c = cache and cache[l.id]
    if not forced and c and c.token == token and c.size[1] == size[1] and
       c.size[2] == size[2] then
      img = c.img
    else
      if c and c.texid then pcall(tw.gfx.release, c.texid) end
      local out, newsize = render.layer(l, size, img, cache)
      if out then
        if l.type == "downscale" or
           (l.type == "group" and l.params.include_below) then
          -- downscale / include-below group: the output IS the composite
          img = out
        elseif l.blend == "alphamask" and l.params.scope == "below" and i >= 2 then
          -- mask applies to the single layer directly below: its output is
          -- multiplied by this layer's alpha, then composited normally
          -- over the stack up to i-2.
          local below = cache and cache[layers[i - 1].id]
          local below_out = below and below.out
          if below_out then
            local masked = tex.blend(below_out, out, "alphamask", l.opacity or 1)
            img = (i >= 3 and cache and cache[layers[i - 2].id] and
                   cache[layers[i - 2].id].img) or nil
            img = img and tex.blend(img, masked, "normal", 1) or masked
          else
            img = tex.blend(img, out, "alphamask", l.opacity or 1)
          end
        else
          img = img and tex.blend(img, out, l.blend or "normal", l.opacity or 1)
                   or out
        end
      end
      if newsize then size = newsize end
      if cache then
        cache[l.id] = { token = token, img = img, size = { size[1], size[2] },
                        out = out }
      end
    end
  end
  return img
end

-- full / partial composite of the document stack
function render.composite(limit_idx, size0, cache)
  local t0 = os.clock()
  local img = composite_list(doc.layers, limit_idx, size0,
                             cache or doc._cache,
                             doc._in_flight and doc.stack_index(doc._in_flight))
  perf.comp_ms = (os.clock() - t0) * 1000
  return img
end

-- 36px thumbnail of the partial composite at layer stack index i
local THUMB = 36
function render.thumb(i)
  return composite_list(doc.layers, i, { THUMB, THUMB }, doc._thumb_cache,
                        doc._in_flight and doc.stack_index(doc._in_flight))
end

-- layer-only output (preview mode "layer only")
function render.layer_only(id, size)
  local l = doc.get_layer(id)
  if not l then return nil end
  return render.layer(l, size, nil, nil)
end

-- re-upload a cached image to the GPU, returning texid (creating as needed)
function render.texid_for(cache, id, img)
  local e = cache[id]
  if not e or not e.img or e.img ~= img then return nil end
  if e.texid then
    e.texid = tw.gfx.update(e.texid, img)
  else
    e.texid = tw.gfx.register(img)
  end
  return e.texid
end

return render
