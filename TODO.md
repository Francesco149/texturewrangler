# texturewrangler — session 1 issue queue

Feedback from the first hands-on session (Windows build, `C:\tmp\twtest` run).
**This file is the work list for the next session; delete it once every item
below is fixed and verified.** Each item has: symptom, confirmed root cause
(where diagnosed), the fix, and acceptance criteria. Items with a confirmed
root cause are marked **[RC]** and should be mechanical; the crash item is
**[OPEN]**.

---

## 1. [RC] Textures render red-tinted AND semi-transparent — GPU channel order

**Symptom**: every texture displays with a red tint and partial transparency
(the demo looked "maroon", an imported rock photo looked "red"; the user
confirmed both symptoms together). Export/PNG output is CORRECT — only the
on-screen preview is wrong.

**Root cause (confirmed by probe)**: `tw.Image` pixels are packed `0xRRGGBBAA`
(little-endian memory bytes `[AA, BB, GG, RR]`). `tex.cpp` uploads the raw
buffer with `SDL_PIXELFORMAT_RGBA32`, whose memory byte order is `[R, G, B, A]`
→ the GPU sees `R=alpha`, `G=B`, `B=G`, `A=R`. For an opaque gray noise pixel
`0x808080FF` the GPU sees `R=255` (red tint) and `A=0x80` (50% alpha) — both
symptoms at once. A pure-red fill was invariant under the swap (bad first
probe); a green fill displayed as dark red-brown and a pure-green CPU export
confirmed the display-only bug.

**Fix (exact)**:
1. `editor/src/tex.cpp` `l_gfx_register` + `l_gfx_update`: change
   `SDL_PIXELFORMAT_RGBA32` → `SDL_PIXELFORMAT_ABGR8888`
   (ABGR8888 memory order is `[A, B, G, R]` — matches our packed buffer).
2. `editor/src/app.cpp` `app_screenshot`: the readback surface format is
   renderer-dependent; make it explicit — after `SDL_RenderReadPixels`,
   `SDL_ConvertSurface(surf, SDL_PIXELFORMAT_RGBA32, 0)` (SDL3 signature)
   so the byte copy `b[0..3] = R,G,B,A` is always right. Do NOT rely on the
   surface's native format.

**Acceptance**: headless probe — build a pure-green fill project
(see `/tmp` red_probe pattern), `--shot` it, `magick … -format
"%[pixel:p{50,50}]" info:` must read `0,255,0`; the demo granite must no
longer look maroon or translucent; the checkerboard margins must look the
same (gray is swap-invariant — use color to verify).

**Also check**: the layer-list thumbnails go through the same `gfx_*` path —
fixed by the same change.

---

## 2. [OPEN] Crash on Windows when dropping a 1024×1024 JPG (ambientCG rock)

**Symptom**: dragging `Rocks017_1K-JPG` (from
`C:\Users\headpats\Documents\assets\placeholders\ambientcg\Rocks017_1K-JPG`)
onto the app crashed it after ~2 seconds, while showing the red tint. On
reopen the import worked but stayed red-tinted.

**Already ruled out** (headless, ASAN-clean on Linux): the full CPU flow at
1024×1024 — JPG decode → asset copy → image layer → 60 composites + 60
thumbnails + export — and the GPU display path (30-frame shot of a
1024×1024 project) — no ASAN findings. So the crash is either Windows-
specific (D3D11 renderer path, SDL3.dll, WSLInterop) or interaction-
specific (drop → picker → new-project transition, pan/zoom at 1024², or
the channel-order texture state).

**Next session, on the host**:
1. Reproduce with the current package. If it crashes, run the exe from a
   console (`texturewrangler.exe` is `-mconsole`) and capture stderr —
   `app_log` lines plus any assertion text land there.
2. Test the drop while the PICKER is showing (no project) vs with a project
   open — the picker→`new_project` transition is a distinct code path.
3. Test panning/zooming at 1024×1024 fit (the 4×4 tiled draw rects are
   4096×4096 scaled down; check for float/rect edge cases in `preview.lua`).
4. Suspects to inspect if it reproduces: `import.file`'s `new_project`
   bootstrapping, the preview `render.texid_for` texture churn at 1024²
   (4 MB upload per frame), and the drop callback re-entrancy
   (`call_lua_void` inside the SDL event loop).
5. If it does NOT reproduce after the channel-order fix (#1), the red-tint
   rendering state may have been the trigger — re-verify before digging.

**Acceptance**: dropping the same JPG on Windows runs indefinitely
(30+ seconds of interaction), import visible, no crash, no console errors.

---

## 3. [RC] Picker shows a "debug window" with default imgui styling

**Symptom**: the new/open-project screen renders inside an imgui debug
window with default styling, through which the real UI is visible.

**Root cause**: `picker.frame()` uses a top-level `BeginChild` WITHOUT a
parent `Begin` — imgui auto-creates its `Debug##Default` window (unthemed
decorations). The editor path already wraps everything in a fullscreen
`Begin("##main", NoTitleBar|NoResize|NoMove|NoScrollbar|NoCollapse|
NoSavedSettings)` (see `main.lua editor_frame`); the picker does not.

**Fix**: mirror the editor: in `main.lua`, wrap the picker in the same
fullscreen `##main` window (or move the picker into the same wrapper —
cleanest: one helper that begins/ends `##main` for both paths). Keep
`picker.body()` inside the `pcall` so `EndChild` balance holds.

**Acceptance**: headless `--shot` with no `--project` shows a themed full-
screen picker (no default-style window chrome, no second window behind).

---

## 4. [RC] Vsync off — 3000 fps on the host

**Symptom**: the app ran at ~3000 fps (screen tearing; wasted GPU).

**Fix (exact)**: `editor/src/app.cpp`, `SDL_CreateRenderer`:
add `SDL_RENDERER_PRESENTVSYNC` to the flags.

**Note**: `--shot` uses the offscreen driver; if vsync ever stalls headless
shots, gate it on `!TW_SHOT` (env is set before SDL init in `main.cpp`).

**Acceptance**: interactive run caps at the display refresh rate; headless
`--shot` still completes.

---

## 5. [RC] Toolbar buttons overlap the project name

**Symptom**: top-left reads like "P[import button]s[export button]" — the
buttons collide with the project name.

**Root cause**: `panels.lua toolbar()` hardcodes `ig.same_line(140)` after
the name; a long project name ("demo-granite") extends past x=140.

**Fix**: measure the name with `ig.calc_text_size(name)` and
`ig.same_line(name_w + 24)` instead of a fixed offset (also account for the
font size of `push_font(1)`).

**Acceptance**: a long project name never overlaps the Undo/Redo/Import
buttons; short names still align.

---

## 6. [RC] Preview header: info text overlaps the zoom combo

**Symptom**: at 1024×1024 the right-aligned `1024×1024 · final` info
overlaps the "Fit" zoom combo (the user described the Fit button being
covered).

**Root cause**: `preview.lua` pushes the info text with
`ig.same_line(avail - itw - 8)` — negative/zero spacing when the panel is
narrow or the text is long.

**Fix**: make the info compact (`"%d×%d"` only — the mode is already in the
mode combo) and guard: only draw it when `avail - itw > 120`; otherwise
skip it. Alternatively drop the mode word entirely.

**Acceptance**: at 64×64 and 1024×1024 canvas, at narrow and wide panel
widths, the zoom combo and info text never overlap.

---

## 7. [RC] Toggling a layer's visibility does nothing

**Symptom**: hiding a layer has no effect on the composite.

**Root cause**: `render.lua composite_list()` (and the group walk in
`layers/group.lua`) never checks `l.visible` — invisible layers render and
blend like visible ones. The checkbox correctly mutates the flag (undo +
bump happen), the renderer just ignores it.

**Fix**: at the top of the per-layer loop in BOTH `composite_list` and the
group walk: `if not l.visible then ... skip (keep img/size unchanged, no
cache write ... or write the cache with the unchanged img so later layers
don't recompute)`. Simplest correct: skip the layer entirely — do NOT touch
`img`; cache the entry as `{token, img, size, out=nil}` so the chain stays
consistent (a hidden downscale must NOT change the working size!).

**Acceptance**: new tests: hiding the top layer → composite equals the stack
without it; hiding a downscale layer → size does NOT change; hiding a group
→ group contributes nothing; toggling visibility back re-renders. Plus a
manual check on the host.

---

## 8. [RC] Tile preview: replace the 4×4 checkbox with a 1/2/4 combo

**Symptom**: the user wanted 2×2; we shipped only 4×4. Keep 4×4, add 2×2
(and 1×1), as a combo.

**Fix**: `preview.lua`: replace the `4×4 tile` checkbox with
`ui.combo`-style `Tile: 1×1 / 2×2 / 4×4` (state field `preview.state.tiles`
= 1|2|4, default 2). `zoom_fit` and the draw loops use `n = tiles` instead
of the boolean.

**Acceptance**: combo shows three options; 2×2 default; shot at 2×2 shows
a 2×2 grid; zoom-fit math still centers correctly.

---

## 9. [RC] Layer rows need a drag handle

**Symptom**: no affordance for reordering layers (drag currently only works
by dragging the name row, undiscoverable).

**Fix**: `panel_layers.lua row()`: draw a `≡` handle at the row's left edge
(drawlist text or a small button) and start the drag from it (the existing
`doc._drag` mechanism already handles reorder + move). Also consider making
the whole row draggable but showing a cursor change — the handle is the
explicit ask.

**Acceptance**: hover shows a handle; dragging the handle reorders the
layer; drag still works from the row body.

---

## 10. [RC] Noise panel: Monochrome/Tinted combo is off-by-one

**Symptom**: switching Monochrome → Tinted → Monochrome leaves the colorize
color showing on Monochrome (opposite behavior).

**Root cause**: `layers/noise.lua` uses `ui.combo("Color", {…}, p.colorize,
…)` where `p.colorize` is 0/1 but the combo's `current` is expected 1-based
(`ui.lua` clamps 0→1, and `on_change` receives `v = new+1` — so selecting
"Tinted" stores 2, which the kernel treats as monochrome; the state gets
stuck).

**Fix (exact)**: `ui.combo("Color", {"Monochrome","Tinted"}, p.colorize + 1,
function(v) p.colorize = v - 1 end)`.

**Acceptance**: Tinted shows the tint color blended; back to Monochrome
shows gray; params serialize/round-trip as 0/1.

---

## 11. Edge-case tests: effects with nothing below them

**Ask**: add tests for effects that might misbehave or crash when no layers
are below them. Current fallbacks: grade/palette/seamless render a
transparent image when `below` is nil; alpha-mask `scope=below` at index 1
falls back to composite scope; downscale at index 1 resizes transparent.

**Add to `editor/tests/test_composite.lua`**:
- grade / palette / seamless as the FIRST layer (below=nil) → no crash,
  output is transparent (or quantize of transparent).
- downscale as the first layer → composite is transparent at the new size.
- alpha-mask `scope=below` as the first layer → falls back to composite
  scope, no crash.
- paint as the first layer → stroke renders over transparent.
- export layer as the only layer → composite nil, no crash.
- group as the only layer (include_below both ways) → no crash.
- visibility-hidden stack → composite nil.
- undo to an empty stack after removals → no crash, composite nil.
- 1×1 canvas through every layer type → no crash.

**Acceptance**: new tests green + ASAN-clean; the suite still runs in
`--test` and `test-asan`.

---

## Cross-cutting notes

- Every fix must keep `make -C editor test` (200+ tests) green and
  `test-asan` clean; UI changes get a `--demo build/demo --shot` +
  `~/.local/bin/vision` pass; Windows changes get the `make package` +
  `C:\tmp\twtest` host run (bat pattern from this session).
- The demo project's "maroon + translucent" look was entirely #1 — after
  the fix the demo should read as the intended icy-gray granite.
- Commit in logical units, co-signed
  (`Co-Authored-By: DeepSeek V4 Flash <noreply@opencode.ai>`).
- Delete this file when every item above is fixed and verified.
