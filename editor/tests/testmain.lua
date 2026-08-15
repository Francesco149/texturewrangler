-- testmain.lua — headless test runner (texturewrangler --test).
-- Mirrors main.lua's globals so the suites exercise the real modules.

local json = require("json")

doc = require("doc")
undo = require("undo")
render = require("render")
autosave = require("autosave")
export = require("export")
import = require("import")
panels = require("panels")
perf = require("perf")

for _, t in ipairs({ "image", "paint", "noise", "grade", "palette",
                     "downscale", "crop", "seamless", "fill", "group", "export" }) do
  render.register(t, require("layers." .. t))
end

local ok, err = pcall(function()
  local suites = { "test_json", "test_kernels", "test_doc", "test_composite",
                   "test_golden" }
  for _, s in ipairs(suites) do
    local m = require(s)
    local t = require("testlib")
    t.run_module(s, m)
  end
end)
if not ok then
  io.stderr:write("TEST RUNNER ERROR: " .. tostring(err) .. "\n")
  if debug and debug.traceback then
    io.stderr:write(debug.traceback(err, 2) .. "\n")
  end
  os.exit(1)
end

local t = require("testlib")
t.summary()
os.exit(t.failed > 0 and 1 or 0)
