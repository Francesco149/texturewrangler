-- test_json.lua — JSON encode/decode round-trips and hand-written decode.

local json = require("json")
local t = require("testlib")

local M = {}

function M.test_roundtrip_simple()
  local v = { name = "furry-cobblestone", canvas = { 64, 64 }, ok = true }
  local dec = json.decode(json.encode(v))
  t.eq(dec.name, "furry-cobblestone", "name")
  t.eq(dec.canvas[1], 64, "canvas w")
  t.eq(dec.canvas[2], 64, "canvas h")
  t.eq(dec.ok, true, "bool")
end

function M.test_roundtrip_nested()
  local v = { layers = { { id = "l1", type = "paint", params = {
    strokes = { { points = { { x = 0.1, y = 0.2 }, { x = 0.3, y = 0.4 } },
                 color = { r = 1, g = 2, b = 3, a = 255 }, size = 6 } } } } } }
  local dec = json.decode(json.encode(v))
  t.eq(dec.layers[1].params.strokes[1].points[2].x, 0.3, "nested point x")
  t.eq(dec.layers[1].params.strokes[1].color.b, 3, "nested color")
end

function M.test_string_escapes()
  local v = { s = 'quote " backslash \\ newline \n tab \t' }
  local dec = json.decode(json.encode(v))
  t.eq(dec.s, v.s, "escape roundtrip")
end

function M.test_numbers()
  local v = { a = 1.5, b = -2, c = 0, d = 1e10 }
  local dec = json.decode(json.encode(v))
  t.near(dec.a, 1.5, 1e-9, "float")
  t.eq(dec.b, -2, "negative")
  t.eq(dec.c, 0, "zero")
  t.near(dec.d, 1e10, 1e3, "sci")
end

function M.test_decode_handwritten()
  local s = '{"a":[1,2,3],"b":{"c":"x\\n y"},"d":null,"e":true}'
  local v = json.decode(s)
  t.eq(v.a[3], 3, "array")
  t.eq(v.b.c, "x\n y", "escaped newline")
  t.eq(v.e, true, "true")
end

function M.test_encode_array_vs_object()
  t.eq(json.encode({ 1, 2, 3 }), "[1,2,3]", "array")
  t.eq(json.encode({ x = 1 }), '{"x":1}', "object")
end

function M.test_unicode()
  local v = { s = "héllo wörld — 日本語" }
  local dec = json.decode(json.encode(v))
  t.eq(dec.s, v.s, "unicode roundtrip")
end

function M.test_empty()
  t.eq(json.encode({}), "{}", "empty object")
  t.eq(json.encode({}), "{}", "empty table")
  local v = json.decode("[]")
  t.eq(#v, 0, "empty array")
end

return M
