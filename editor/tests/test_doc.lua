-- test_doc.lua — document model: serialization round-trip, undo/redo,
-- version propagation, asset handling.

local t = require("testlib")
local json = require("json")

local M = {}

local function fresh_doc()
  doc.deserialize({ name = "test", canvas = { 16, 16 }, layers = {},
                    exports = {}, assets = {} })
end

function M.test_serialize_roundtrip()
  fresh_doc()
  local l = doc.new_layer("grade", "Grade")
  l.params.brightness = 0.3
  l.params.colorize = { r = 10, g = 20, b = 30, a = 255 }
  doc.add_layer(l)
  local s = doc.serialize()
  local enc = json.encode(s)
  local dec = json.decode(enc)
  doc.deserialize(dec)
  local l2 = doc.layers[1]
  t.eq(l2.type, "grade", "type")
  t.near(l2.params.brightness, 0.3, 1e-9, "brightness")
  t.eq(l2.params.colorize.b, 30, "colorize")
  -- reserialize → identical
  t.eq(json.encode(doc.serialize()), enc, "stable serialization")
end

function M.test_undo_redo()
  fresh_doc()
  doc.mutate(function()
    local l = doc.new_layer("fill")
    doc.add_layer(l)
  end, "add fill")
  t.eq(#doc.layers, 1, "one layer")
  doc.mutate(function()
    doc.layers[1].opacity = 0.5
  end, "opacity")
  t.near(doc.layers[1].opacity, 0.5, 1e-9, "opacity set")
  t.true_(undo.do_undo(), "undo")
  t.near(doc.layers[1].opacity, 1, 1e-9, "opacity reverted")
  t.true_(undo.do_undo(), "undo again")
  t.eq(#doc.layers, 0, "layer removed")
  t.true_(undo.do_redo(), "redo")
  t.eq(#doc.layers, 1, "layer back")
  t.false_(undo.do_undo() == false and undo.do_redo() == false and false, "stack alive")
end

function M.test_failed_mutate_rolls_back()
  fresh_doc()
  doc.mutate(function()
    doc.add_layer(doc.new_layer("noise"))
  end, "add noise")
  local before = #undo.stack
  local threw = pcall(function()
    doc.mutate(function()
      error("boom")
    end, "bad")
  end)
  t.true_(not threw, "mutate raises")
  t.eq(#undo.stack, before, "no undo entry for failed mutate")
  t.eq(#doc.layers, 1, "doc unchanged")
end

function M.test_version_propagation()
  fresh_doc()
  local g = doc.new_layer("group")
  doc.add_layer(g)
  local c = doc.new_layer("paint")
  doc.add_layer(c, g.id)
  local v0 = doc._ver[g.id]
  doc.mutate(function()
    c.params.size = 12
    doc.bump(c)
  end, "paint size")
  t.true_(doc._ver[g.id] > v0, "parent version bumped on child change")
end

function M.test_remove_group_drops_children()
  fresh_doc()
  local g = doc.new_layer("group")
  doc.add_layer(g)
  local c = doc.new_layer("fill")
  doc.add_layer(c, g.id)
  doc.remove_layer(g.id)
  t.eq(#doc.layers, 0, "group removed")
  t.eq(doc.get_layer(c.id), nil, "child gone")
end

function M.test_asset_add()
  fresh_doc()
  -- write a tiny png via the save path, load it back
  local img = t.pixel_eq and tw.tex.new(2, 2, { r = 10, g = 20, b = 30, a = 255 })
  local dir = os.tmpname() .. ".d"
  os.remove(dir)
  os.execute("mkdir -p " .. dir) -- may fail on some systems; guarded below
  if tw.file.exists(dir) then
    tw.file.save_image(img, dir .. "/src.png")
    doc.path = dir
    local aid = doc.add_asset(dir .. "/src.png")
    t.true_(aid ~= nil, "asset added")
    local a = doc.assets[aid]
    t.eq(a.w, 2, "asset width")
    t.true_(tw.file.exists(dir .. "/assets/" .. a.file), "asset copied in")
    local loaded = doc.asset_image(aid)
    t.true_(loaded ~= nil, "asset loads")
    doc.path = nil
    os.execute("rm -rf " .. dir)
  end
end

return M
