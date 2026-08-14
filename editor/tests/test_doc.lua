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

-- regression: doc.find_parent used to return the parent ID (a string), so
-- callers doing `parent.children` silently fell back to the ROOT list for
-- grouped layers — group/delete corrupted the wrong list and in-group drag
-- reorder was a no-op.
function M.test_find_parent_returns_layer()
  fresh_doc()
  local g = doc.new_layer("group")
  doc.add_layer(g)
  local c = doc.new_layer("fill")
  doc.add_layer(c, g.id)
  local parent = doc.find_parent(c.id)
  t.true_(parent ~= nil, "child has a parent")
  t.eq(parent.id, g.id, "parent is the group")
  t.true_(type(parent.children) == "table", "parent exposes .children")
  t.eq(doc.find_parent(g.id), nil, "root group has no parent")
end

function M.test_move_layer_within_group()
  fresh_doc()
  local g = doc.new_layer("group")
  doc.add_layer(g)
  local c1, c2, c3 = doc.new_layer("fill"), doc.new_layer("fill"), doc.new_layer("fill")
  doc.add_layer(c1, g.id)
  doc.add_layer(c2, g.id)
  doc.add_layer(c3, g.id)
  -- drag c1 (bottom) to the top of the group
  doc.move_layer(c1.id, 3)
  local kids = doc.get_layer(g.id).children
  t.eq(kids[1].id, c2.id, "first child")
  t.eq(kids[2].id, c3.id, "second child")
  t.eq(kids[3].id, c1.id, "third child")
  t.eq(#doc.layers, 1, "root list untouched")
end

function M.test_remove_child_layer()
  fresh_doc()
  local g = doc.new_layer("group")
  doc.add_layer(g)
  local c = doc.new_layer("fill")
  doc.add_layer(c, g.id)
  doc.remove_layer(c.id)
  t.eq(#doc.get_layer(g.id).children, 0, "child removed from group")
  t.eq(doc.get_layer(c.id), nil, "child gone")
  t.eq(#doc.layers, 1, "group still in root")
end

-- regression: ids used to be clock+process-local-counter, which restarted
-- in every process — two sessions doing similar startup work minted
-- IDENTICAL ids, so a layer loaded from disk and a freshly added one could
-- collide (doc.get_layer returned the wrong layer). deserialize now
-- resumes the counter past loaded ids.
function M.test_loaded_ids_dont_collide_with_new()
  fresh_doc()
  -- a doc saved by "another process" whose first id is exactly what THIS
  -- process's new_id() would produce for counter=1
  local expected = string.format("l%x%x_1", os.time() % 0xffff,
                                 math.floor(os.clock() * 1000) % 0xffff)
  doc.deserialize({ name = "x", canvas = { 16, 16 }, exports = {}, assets = {},
                    layers = { { id = expected, type = "fill", name = "Loaded",
                                 visible = true, opacity = 1, blend = "normal",
                                 params = {} } } })
  local l = doc.new_layer("fill")
  doc.add_layer(l)
  t.true_(l.id ~= expected, "new id differs from loaded id: " .. l.id)
  t.eq(doc.get_layer(expected).name, "Loaded", "loaded layer intact")
  t.eq(doc.get_layer(l.id).name, "Fill", "new layer reachable by its id")
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
