-- autosave.lua — seamless saving: write project.json ~0.4s after the last
-- change, every change, no dialogs. Also drives auto-export of any export
-- location with auto=true (debounced the same way, so a Godot project's
-- texture refreshes as you edit).

local autosave = {}

local DEBOUNCE_FRAMES = 24 -- ~0.4s at 60fps
local last_change_frame = 0
local last_export_frame = 0

function autosave.tick(frame_n)
  if not doc.loaded or not doc.path then return end
  if doc.dirty and frame_n - last_change_frame >= DEBOUNCE_FRAMES then
    doc.save()
    last_change_frame = frame_n
  end
  local any_auto = false
  for _, e in ipairs(doc.exports) do
    if e.auto then any_auto = true; break end
  end
  if any_auto and doc.dirty and frame_n - last_export_frame >= DEBOUNCE_FRAMES then
    pcall(export.auto_export)
    last_export_frame = frame_n
  end
end

-- save immediately (window close, export, tests)
function autosave.flush()
  if doc.loaded and doc.path then doc.save() end
end

return autosave
