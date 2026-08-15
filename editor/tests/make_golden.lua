-- make_golden.lua — golden test maintenance CLI.
--   texturewrangler --lua editor/tests/make_golden.lua check   → compare (exit 1 on mismatch)
--   texturewrangler --lua editor/tests/make_golden.lua bless   → regenerate golden (intentional ONLY)
--
-- The golden dir is editor/tests/golden/ (next to this script's module).
-- `make test` runs the comparison as part of the suite — a mismatch fails
-- the build. Re-blessing is a deliberate act: run `make test-bless` and
-- commit the regenerated files after reviewing the diff.

local golden = require("golden_project")

local src = debug.getinfo(1, "S").source
local script_path = src:match("^@(.*)$") or src
local dir = script_path:match("^(.*)/[^/]+$") .. "/golden"

local mode = "check"
for i = 1, #tw.args do
  if tw.args[i] == "bless" then mode = "bless" end
  if tw.args[i] == "check" then mode = "check" end
end
if mode == "bless" then
  golden.build(dir)
  local img = golden.render()
  tw.file.save_image(img, dir .. "/composite.png")
  -- undo.jsonl is journal noise from building; never commit it
  os.remove(dir .. "/undo.jsonl")
  local w, h = tw.tex.size(img)
  print("GOLDEN RE-BLESSED: " .. dir .. "/composite.png (" .. w .. "x" .. h ..
        ") — commit only if this change is intentional")
elseif mode == "check" then
  golden.build(dir)
  local img = golden.render()
  local gold = tw.file.load_image(dir .. "/composite.png")
  if not gold then
    print("GOLDEN MISSING: " .. dir .. "/composite.png — run `make test-bless`")
    os.exit(1)
  end
  local n = golden.diff(img, gold)
  if n == -1 then
    print("GOLDEN MISMATCH: size differs")
    os.exit(1)
  elseif n > 0 then
    print("GOLDEN MISMATCH: " .. n .. " pixel(s) differ — if the change is " ..
          "intentional run `make test-bless` and review, else fix the regression")
    os.exit(1)
  end
  print("GOLDEN MATCH: " .. n .. " pixels differ")
else
  print("usage: texturewrangler --lua editor/tests/make_golden.lua <check|bless>")
  os.exit(1)
end
