-- perf.lua — lightweight Lua-side profiling: frame duration, composite
-- time, and per-layer-type render time (rolling window, zero allocation
-- beyond the accumulators). The status bar shows frame + composite ms;
-- the console command `perf` prints the per-type breakdown.

local perf = {}

perf.frame_ms = 0        -- last tw.frame duration
perf.comp_ms = 0         -- last frame's composite duration
perf.overlay = false     -- F3: per-type breakdown overlay

local layer_acc = {}     -- type -> { sum = ms, n = count }
local layer_last = {}    -- type -> last ms (for the overlay)
local window = 60

function perf.add_layer(type, ms)
  local a = layer_acc[type]
  if not a then
    a = { sum = 0, n = 0 }
    layer_acc[type] = a
  end
  a.sum = a.sum + ms
  a.n = a.n + 1
  layer_last[type] = ms
  if a.n > window then
    a.sum = a.sum - a.sum / a.n -- decay: keeps the window roughly bounded
    a.n = window
  end
end

function perf.tick(frame_ms, comp_ms)
  perf.frame_ms = frame_ms
  perf.comp_ms = comp_ms
  if tw.ig.is_key_pressed(tw.ig.key.F3) then perf.overlay = not perf.overlay end
end

function perf.breakdown()
  local out = {}
  for t, a in pairs(layer_acc) do
    out[#out + 1] = string.format("%-10s %6.2f ms (%d samples)",
                                  t, a.sum / math.max(1, a.n), a.n)
  end
  table.sort(out)
  return out
end

function perf.draw_overlay(x, y)
  if not perf.overlay then return end
  local ig = tw.ig
  local dl = ig.get_foreground_draw_list()
  local lines = { string.format("frame %6.2f ms  comp %6.2f ms",
                                perf.frame_ms, perf.comp_ms) }
  for _, l in ipairs(perf.breakdown()) do lines[#lines + 1] = l end
  local w, h = 0, 0
  for _, l in ipairs(lines) do
    local tw_, th = ig.calc_text_size(l)
    if tw_ > w then w = tw_ end
    h = h + th
  end
  ig.dl_add_rect_filled(dl, x, y, x + w + 16, y + h + 10, 0.05, 0.05, 0.06, 0.85)
  local cy = y + 5
  for _, l in ipairs(lines) do
    ig.dl_add_text(dl, x + 8, cy, l, 0.7, 0.85, 0.7, 1)
    cy = cy + ig.get_text_line_height()
  end
end

return perf
