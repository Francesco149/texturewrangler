-- colors.lua — color helpers shared by panels and layers.
-- Colors are {r,g,b,a} 0..255 in the doc; imgui wants 0..1 floats.

local colors = {}

function colors.to01(c)
  return { c.r / 255, c.g / 255, c.b / 255, (c.a or 255) / 255 }
end

function colors.from01(r, g, b, a)
  return { r = math.floor(r * 255 + 0.5), g = math.floor(g * 255 + 0.5),
           b = math.floor(b * 255 + 0.5), a = math.floor((a or 1) * 255 + 0.5) }
end

function colors.hex(c)
  local function h(v) return string.format("%02x", math.max(0, math.min(255, v))) end
  return "#" .. h(c.r or 0) .. h(c.g or 0) .. h(c.b or 0)
end

function colors.from_hex(s)
  s = s:gsub("^#", "")
  if #s == 3 then
    s = s:sub(1,1)..s:sub(1,1)..s:sub(2,2)..s:sub(2,2)..s:sub(3,3)..s:sub(3,3)
  end
  if #s ~= 6 then return { r = 0, g = 0, b = 0, a = 255 } end
  return { r = tonumber(s:sub(1, 2), 16), g = tonumber(s:sub(3, 4), 16),
           b = tonumber(s:sub(5, 6), 16), a = 255 }
end

-- css-ish named colors used by fills/noise tint defaults
colors.named = {
  white = { r = 255, g = 255, b = 255, a = 255 },
  black = { r = 0, g = 0, b = 0, a = 255 },
  red = { r = 255, g = 0, b = 0, a = 255 },
  green = { r = 0, g = 255, b = 0, a = 255 },
  blue = { r = 0, g = 0, b = 255, a = 255 },
  transparent = { r = 0, g = 0, b = 0, a = 0 },
}

return colors
