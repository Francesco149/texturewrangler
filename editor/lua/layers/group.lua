-- layers/group.lua — nested stack: children composite as one unit, then
-- the group blends into the parent stack like any layer (opacity + blend).
-- include_below=true → children composite starts from everything below the
-- group; false → from transparent. A downscale inside a group changes the
-- internal working size; the group output is resampled back to the entry
-- size so the parent stack size stays invariant.

local M = {}

function M.render(l, size, below, cache)
  local start = (l.params.include_below and below) or nil
  local out = nil
  local function walk(children, entry_img)
    local img = entry_img
    local csize = { size[1], size[2] }
    for i, cl in ipairs(children) do
      local token = (doc._ver[cl.id] or 0) * 131 + csize[1] * 7 + csize[2]
      local c = cache and cache[cl.id]
      if not cl.visible then
        -- hidden child: contributes nothing; keep the entry size and the
        -- accumulated composite (a hidden downscale must NOT resize).
        if cache then
          cache[cl.id] = { token = token, img = img, size = { csize[1], csize[2] },
                           out = nil }
        end
      elseif c and c.token == token and c.size[1] == csize[1] and
             c.size[2] == csize[2] then
        img = c.img
      else
        if c and c.texid then pcall(tw.gfx.release, c.texid) end
        local co, newsize = render.layer(cl, csize, img, cache)
        if co then
          if cl.type == "downscale" or
             (cl.type == "group" and cl.params.include_below) then
            img = co
          elseif cl.blend == "alphamask" and cl.params.scope == "below" and i >= 2 then
            local below = cache and cache[children[i - 1].id]
            local below_out = below and below.out
            if below_out then
              local masked = tw.tex.blend(below_out, co, "alphamask", cl.opacity or 1)
              local prev = (i >= 3 and cache and cache[children[i - 2].id] and
                            cache[children[i - 2].id].img) or nil
              img = prev and tw.tex.blend(prev, masked, "normal", 1) or masked
            else
              img = img and tw.tex.blend(img, co, "alphamask", cl.opacity or 1) or co
            end
          else
            img = img and tw.tex.blend(img, co, cl.blend or "normal",
                                       cl.opacity or 1) or co
          end
        end
        if newsize then csize = newsize end
        if cache then
          cache[cl.id] = { token = token, img = img, size = { csize[1], csize[2] },
                           out = co }
        end
      end
    end
    return img
  end
  out = walk(l.children or {}, start)
  if not out then return nil end
  local w, h = tw.tex.size(out)
  if w ~= size[1] or h ~= size[2] then
    out = tw.tex.resize(out, size[1], size[2], "bilinear")
  end
  return out
end

function M.panel(l, ui)
  ui.check("Include layers below", l.params.include_below, function(v)
    l.params.include_below = v
  end)
  ui.text("Drag layers onto the group row to nest them.")
end

return M
