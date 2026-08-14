-- console.lua — embedded Lua REPL + log viewer. Errors never kill the
-- app: they land here. `tw.reload()` re-runs lua/main.lua without a
-- restart; the console shows the boot log.

local console = {}
local ig = tw.ig

console.input = ""

function console.log_line(s)
  console.history[#console.history + 1] = s
  if #console.history > 2000 then
    table.remove(console.history, 1)
  end
  console.scroll_bottom = true
end
console.history = {}
console.scroll_bottom = true

local boot_printed = false

function console.frame()
  ig.set_cursor_pos(0, 30)

  -- log area
  local lw, lh = ig.get_content_region_avail()
  ig.begin_child("##log", lw, lh - 34, 1, 0)
  ig.set_cursor_pos(4, 4)
  for _, s in ipairs(console.history) do
    ig.text(s)
  end
  if console.scroll_bottom then
    ig.set_scroll_here_y(1)
    console.scroll_bottom = false
  end
  ig.end_child()

  -- input line
  local changed, v = ig.input_text("##cmd", console.input, 512)
  if changed then console.input = v end
  local run = ig.is_key_pressed(ig.key.Enter) and ig.is_window_hovered(0)
  if run and console.input ~= "" then
    local code = console.input
    console.input = ""
    console.log_line("> " .. code)
    if code == "perf" then
      console.log_line(string.format("frame %.2f ms  comp %.2f ms",
                                     perf.frame_ms, perf.comp_ms))
      for _, l in ipairs(perf.breakdown()) do console.log_line(l) end
      console.scroll_bottom = true
    else
      local ok, res = tw.app.eval(code)
      if not ok then
        console.log_line("ERROR: " .. res)
      elseif res ~= "" then
        console.log_line(res)
      end
    end
  end
end

-- pull C++-side log lines into the console once per frame
function console.poll_logs()
  local lines = tw.app.log_lines()
  local start = console._logged or 0
  for i = start + 1, #lines do
    console.log_line(lines[i])
  end
  console._logged = #lines
end

return console
