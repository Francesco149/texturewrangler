-- test_golden.lua — golden composite regression: load the golden project,
-- render the final composite (fresh + through the cache), and require the
-- result to be pixel-identical to the committed tests/golden/composite.png.
-- Any change in the compositing pipeline (blend math, cache behavior,
-- resize, palette, groups) shows up here. Re-bless deliberately:
--   make test-bless   (regenerates project + golden; commit after review)

local t = require("testlib")

local M = {}

local src = debug.getinfo(1, "S").source
local module_path = src:match("^@(.*)$") or src
local dir = module_path:match("^(.*)/[^/]+$") .. "/golden"

local function golden_diff(a, b)
  local w, h = tw.tex.size(a)
  local bw, bh = tw.tex.size(b)
  if w ~= bw or h ~= bh then return -1 end
  local n = 0
  for y = 0, h - 1 do
    for x = 0, w - 1 do
      local r1, g1, b1, a1 = tw.tex.get(a, x, y)
      local r2, g2, b2, a2 = tw.tex.get(b, x, y)
      if r1 ~= r2 or g1 ~= g2 or b1 ~= b2 or a1 ~= a2 then n = n + 1 end
    end
  end
  return n
end

function M.test_golden_composite()
  local ok = doc.load(dir)
  t.true_(ok, "golden project loads from " .. dir)
  if not ok then return end
  -- fresh render
  local img = render.composite(nil, doc.canvas, doc._cache)
  t.true_(img ~= nil, "golden composite exists")
  -- cache-hit render must be identical (the downscale cache regression)
  local img2 = render.composite(nil, doc.canvas, doc._cache)
  t.true_(img2 == img, "cache-hit composite identical to fresh render")
  -- pixel-exact vs the committed golden
  local gold = tw.file.load_image(dir .. "/composite.png")
  t.true_(gold ~= nil, "golden composite.png exists — run `make test-bless` if missing")
  if not gold then return end
  local n = golden_diff(img, gold)
  t.eq(n, 0, "composite is pixel-exact with the golden (" .. n .. " px differ)")
end

return M
