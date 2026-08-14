-- undo.lua — snapshot-based undo/redo with a cross-session journal.
-- Each push appends one line to undo.jsonl ({label, state-json-string});
-- on load the last MAX entries become the starting undo stack, so Ctrl+Z
-- reaches back into previous sessions. Snapshots are the serialized doc
-- (params + strokes only — pixels live in assets/, so entries are tiny).

local json = require("json")

local undo = {}
undo.stack = {} -- {label=, state=} (state = json string)
undo.redo = {}
undo.label = nil
undo.ptr = 0 -- rollback marker: stack depth before the in-flight mutate

local MAX = 512

function undo.push(label)
  local state = json.encode(doc.serialize())
  undo.stack[#undo.stack + 1] = { label = label, state = state }
  undo.redo = {}
  if #undo.stack > MAX then
    table.remove(undo.stack, 1)
  end
  undo.label = label
  undo.ptr = #undo.stack
  -- journal (best-effort; failure just means no cross-session undo)
  if doc.path then
    pcall(function()
      local f = io.open(doc.path .. "/undo.jsonl", "a")
      if f then
        f:write(json.encode({ label = label, s = state }), "\n")
        f:close()
      end
    end)
  end
end

-- called after a failed mutate: drop the snapshot we just pushed
function undo.rollback()
  undo.stack[undo.ptr] = nil
  undo.ptr = 0
end

local function restore(state, label)
  local ok, data = pcall(json.decode, state)
  if not ok then
    tw.log_error("undo restore failed: " .. tostring(data))
    return
  end
  doc.deserialize(data)
  undo.label = label
  doc.dirty = true
end

function undo.do_undo()
  local e = table.remove(undo.stack)
  if not e then return false end
  undo.redo[#undo.redo + 1] = { label = undo.label,
                                state = json.encode(doc.serialize()) }
  restore(e.state, e.label)
  return true
end

function undo.do_redo()
  local e = table.remove(undo.redo)
  if not e then return false end
  undo.stack[#undo.stack + 1] = { label = e.label,
                                  state = json.encode(doc.serialize()) }
  restore(e.state, e.label)
  return true
end

function undo.can_undo()
  return #undo.stack > 0
end
function undo.can_redo()
  return #undo.redo > 0
end

-- load journal history into the undo stack (after doc.load)
function undo.load_journal()
  undo.stack = {}
  undo.redo = {}
  if not doc.path then return end
  local text = tw.file.read_text(doc.path .. "/undo.jsonl")
  if not text then return end
  local entries = {}
  for line in text:gmatch("[^\n]+") do
    local ok, e = pcall(json.decode, line)
    if ok and e and e.s then entries[#entries + 1] = e end
  end
  local from = math.max(1, #entries - MAX + 1)
  for i = from, #entries do
    undo.stack[#undo.stack + 1] = { label = entries[i].label, state = entries[i].s }
  end
end

function undo.clear()
  undo.stack = {}
  undo.redo = {}
end

return undo
