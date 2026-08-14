-- panel_props.lua — properties of the selected layer: common controls
-- (name, visible, opacity, blend, alpha-mask scope) + the type-specific
-- panel from layers/<type>.lua.

local panel = {}
local ig = tw.ig
local ui = require("ui")
local colors = require("colors")

local BLENDS = { "normal", "multiply", "screen", "overlay", "hardlight",
                 "softlight", "darken", "lighten", "difference", "exclusion",
                 "dodge", "burn", "hue", "saturation", "color", "luminosity",
                 "alphamask", "erase" }

local function fmt_blend(b)
  return b:gsub("^%l", string.upper):gsub("_", " ")
end

local function blend_index(b)
  for i, x in ipairs(BLENDS) do if x == b then return i end end
  return 1
end

local function blend_items()
  local out = {}
  for _, b in ipairs(BLENDS) do out[#out + 1] = fmt_blend(b) end
  return out
end

function panel.frame()
  ig.set_cursor_pos(0, 30)

  local sel = panels.selected()
  local l = sel and doc.get_layer(sel)
  if not l then
    ig.text_colored("Select a layer to edit its properties.", 0.45, 0.47, 0.52, 1)
    return
  end

  local u = ui.new({
    mutate = function(fn) doc.mutate(fn) end,
    coalesce = function(fn) doc.coalesce_mutate(fn) end,
  })

  -- common controls
  u.input("Name", l.name, function(v)
    l.name = v == "" and doc.type_names[l.type] or v
  end)
  u.check("Visible", l.visible, function(v) l.visible = v end)
  u.slider("Opacity", l.opacity, 0, 1, function(v) l.opacity = v end)
  u.combo("Blend", blend_items(), blend_index(l.blend), function(v)
    l.blend = BLENDS[v]
  end)
  if l.blend == "alphamask" then
    u.combo("Mask scope", { "Layer below", "Whole composite" },
            l.params.scope == "below" and 1 or 2, function(v)
      l.params.scope = v == 1 and "below" or "composite"
    end)
  end
  u.separator()

  -- type-specific
  local impl = require("layers." .. l.type)
  if impl and impl.panel then
    pcall(impl.panel, l, u)
  end

end

return panel
