-- ui.lua — widget helper used by the layer property panels. All mutations
-- flow through mutate (undo snapshot) or coalesce (one undo per drag).
-- combo convention: current is a 1-based index or a string; on_change
-- receives the new 1-based index.

local colors = require("colors")

local ui = {}

function ui.new(ctx)
  local ig = tw.ig
  local u = {}

  u.mutate = ctx.mutate
  u.coalesce = ctx.coalesce

  function u.label(label, value) ig.label_text(label, value) end
  function u.text(s) ig.text(s) end
  function u.text_colored(s, r, g, b, a) ig.text_colored(s, r, g, b, a) end
  function u.same_line() ig.same_line() end
  function u.new_line() ig.new_line() end
  function u.separator() ig.separator() end
  function u.spacing() ig.spacing() end
  function u.button(label) return ig.button(label) end
  function u.small_button(label) return ig.small_button(label) end
  function u.avail_w()
    local w = ig.get_content_region_avail()
    return w
  end

  function u.combo(label, items, current, on_change)
    local idx = 1
    if type(current) == "number" then
      idx = math.max(1, math.min(#items, math.floor(current)))
    else
      for i, v in ipairs(items) do
        if v == current then idx = i; break end
      end
    end
    local changed, new = ig.combo(label, items, idx - 1)
    if changed then u.coalesce(function() on_change(new + 1) end) end
  end

  function u.slider(label, v, min, max, on_change)
    local changed, nv = ig.slider_float(label, v, min, max)
    if changed then u.coalesce(function() on_change(nv) end) end
  end

  function u.check(label, v, on_change)
    local changed, nv = ig.checkbox(label, v)
    if changed then u.mutate(function() on_change(nv) end) end
  end

  function u.color(label, c, on_change)
    local c01 = colors.to01(c)
    local changed, r, g, b, a =
      ig.color_edit4(label, c01[1], c01[2], c01[3], c01[4])
    if changed then
      u.coalesce(function() on_change(colors.from01(r, g, b, a)) end)
    end
  end

  function u.color_swatch(id, c, w, h)
    local c01 = colors.to01(c)
    return ig.color_button(id, c01[1], c01[2], c01[3], c01[4], w or 22, h or 22)
  end

  function u.input(label, s, on_change)
    local changed, ns = ig.input_text(label, s, 128)
    if changed then u.mutate(function() on_change(ns) end) end
  end

  return u
end

return ui
