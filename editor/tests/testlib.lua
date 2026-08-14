-- testlib.lua — tiny assertion harness for the headless suite (--test).
-- Deterministic kernels → exact pixel comparisons. Failures print and
-- count; the runner exits 1 if any failed.

local t = {}
t.passed = 0
t.failed = 0
t.failures = {}

function t.ok(v, msg)
  if v then
    t.passed = t.passed + 1
  else
    t.failed = t.failed + 1
    t.failures[#t.failures + 1] = msg or "assertion failed"
    io.write("  FAIL: ", msg or "?", "\n")
  end
end

function t.eq(a, b, msg)
  if a == b then
    t.passed = t.passed + 1
  else
    t.failed = t.failed + 1
    t.failures[#t.failures + 1] = (msg or "eq") .. "  got " .. tostring(a) ..
                                  " want " .. tostring(b)
    io.write(string.format("  FAIL: %s  (got %s want %s)\n", msg or "eq",
                           tostring(a), tostring(b)))
  end
end

function t.near(a, b, eps, msg)
  if math.abs(a - b) <= (eps or 1e-6) then
    t.passed = t.passed + 1
  else
    t.failed = t.failed + 1
    t.failures[#t.failures + 1] = (msg or "near") .. "  got " .. tostring(a) ..
                                  " want " .. tostring(b)
    io.write(string.format("  FAIL: %s  (got %s want %s)\n", msg or "near",
                           tostring(a), tostring(b)))
  end
end

function t.true_(v, msg)
  t.ok(v, msg or "expected true")
end

function t.false_(v, msg)
  t.ok(not v, msg or "expected false")
end

-- pixel helpers
function t.pixel_eq(img, x, y, r, g, b, a, msg)
  local pr, pg, pb, pa = tw.tex.get(img, x, y)
  if pr == r and pg == g and pb == b and pa == (a or 255) then
    t.passed = t.passed + 1
  else
    t.failed = t.failed + 1
    t.failures[#t.failures + 1] = (msg or "pixel") .. " got " .. pr .. "," ..
                                  pg .. "," .. pb .. "," .. pa
    io.write(string.format("  FAIL: %s (got %d,%d,%d,%d want %d,%d,%d,%d)\n",
                           msg or "pixel", pr, pg, pb, pa, r, g, b, a or 255))
  end
end

-- every pixel of img equals (r,g,b,a)
function t.all_pixels(img, r, g, b, a, msg)
  local w, h = tw.tex.size(img)
  local ok = true
  for y = 0, h - 1 do
    for x = 0, w - 1 do
      local pr, pg, pb, pa = tw.tex.get(img, x, y)
      if pr ~= r or pg ~= g or pb ~= b or pa ~= (a or 255) then
        ok = false
        io.write(string.format("  FAIL: %s at %d,%d got %d,%d,%d,%d\n", msg or "all_pixels",
                               x, y, pr, pg, pb, pa))
        break
      end
    end
    if not ok then break end
  end
  t.ok(ok, msg or "all_pixels equal")
end

function t.run(name, fn)
  local ok, err = pcall(fn)
  if ok then
    t.passed = t.passed + 1
  else
    t.failed = t.failed + 1
    t.failures[#t.failures + 1] = name .. ": " .. tostring(err)
    io.write(string.format("  FAIL: %s threw: %s\n", name, tostring(err)))
  end
end

function t.run_module(name, m)
  io.write("== " .. name .. " ==\n")
  for k, v in pairs(m) do
    if k:sub(1, 4) == "test" then t.run(name .. "." .. k, v) end
  end
end

function t.summary()
  io.write(string.format("\n%d passed, %d failed\n", t.passed, t.failed))
  if t.failed > 0 then
    io.write("failures:\n")
    for _, f in ipairs(t.failures) do io.write("  - " .. f .. "\n") end
  end
end

return t
