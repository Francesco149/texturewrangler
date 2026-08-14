# texturewrangler — design

Non-destructive procedural texture editor, hyper-focused on retro textures
(N64–PS2 era: 32–128px, power-of-two, 8–32 color palettes). Everything is a
layer; every layer is a parameterized modifier; nothing is ever baked unless
you ask for an export.

## Principles

1. **Responsiveness is the feature.** Param drag → result on screen in the
   same frame. The compositing engine is CPU-side C++ on RGBA8 buffers; the
   whole stack of a 256×256 project re-composites in well under 1ms, so the
   preview rebuilds every frame a parameter changes, unconditionally.
2. **C++ stays slim.** C++ owns: window/events, imgui, the Lua VM, the GPU
   texture upload path, and the pixel kernels. Everything else — document
   model, panels, layer logic, undo, autosave, import/export plumbing — is
   Lua. No C++ object graphs, no shared_ptr spaghetti, no crash surface.
3. **LLM-first code.** Few files, flat layout, plain C-style C++ where
   possible, one obvious file per concern, Lua modules mirror the UI panels.
   Orientation doc (ORIENTATION.md) is the fresh-session entry point.
4. **No footguns.** Trivial Makefile (no config system), deps from the nix
   flake, deterministic kernels, headless `--test`/`--shot` modes so every
   change is verifiable without a human looking at a screen.

## Shape

```
┌────────────────────────────────────────────────────────────┐
│ editor/                                                     │
│  src/  main.cpp  app.cpp  ig.cpp  kernels.cpp  lua.cpp     │
│        tex.cpp   file.cpp                                   │
│  lua/  main.lua  doc.lua  undo.lua  autosave.lua  json.lua │
│        panels*.lua  layers/*.lua  console.lua  picker.lua  │
│  tests/  test_*.lua                                         │
│  Makefile                                                   │
└────────────────────────────────────────────────────────────┘
flake.nix   → dev shell: SDL3, pinned imgui, Lua 5.4 source,
              stb, mingw-w64 cross toolchain, glslang-free (no shaders)
```

Binary: `build/texturewrangler` (linux) / `build/texturewrangler.exe`
(windows, mingw cross from WSL2, runs on the Win11 host via WSLInterop).
Both use **SDL3 + imgui_impl_sdl3 + imgui_impl_sdlrenderer3** — one
windowing/GPU path on both platforms (SDL_Renderer is D3D11-backed on
Windows, GL on Linux). No custom shaders anywhere: compositing is CPU, the
GPU only blits the result.

## Document model

A project is a directory:

```
<projects-dir>/furry-cobblestone/
  project.json      # everything: name, canvas, layers, exports, settings
  assets/           # imported images, copied in (projects are portable)
  undo.jsonl        # cross-session undo journal (append-only snapshots)
  export/           # default export location
```

`project.json` is the human- *and* LLM-editable source of truth (like
teidraw's board.json / slopstudio's .slop.json). Pure data, no code:

```json
{
  "name": "furry-cobblestone",
  "canvas": [64, 64],
  "version": 1,
  "layers": [ … ],     // ordered bottom → top; groups nest via "children"
  "exports": [ … ],    // named extra export locations
  "settings": { "tilePreview": true }
}
```

Layer shape (base fields, type-specific params in `params`):

```json
{
  "id": "l_7f3a", "type": "palette", "name": "Quantize",
  "visible": true, "opacity": 1.0, "blend": "normal",
  "params": { "colors": 16, "dither": "fs" }
}
```

IDs are stable, short, random hex — undo, exports, and layer references
(custom brush, group membership) key off them.

## Compositing model

**Working size flows through the stack.** The composite starts at the
project canvas size (set by the first imported image, else 64×64). A
downscale layer resamples the partial composite to its target size and the
working size becomes that for everything above it. Remove the downscale →
working size reverts → "back to full-res original". Export resolution =
working size at the top of the stack (or the export layer's override).

**Render recursion.** `composite(node, size, below)`:

- bottom-up over visible children; each child renders its output at `size`
  (`render_layer` per type, inputs: the partial composite `below` and the
  group context), then blends: `result = blend(result, out, mode, opacity)`.
- group: `out = composite(group.children, size, include_below ? below :
  transparent)` — the group's own output is one image, then blended as a
  layer (group has opacity/blend like any layer).
- palette/grade/etc. are "global-ish" but still ordered: they apply to the
  partial composite at their position, which is exactly what makes
  *remove the modifier → undo the effect* true.

**Blend modes** (straight alpha, standard formulas): normal, multiply,
screen, overlay, hard-light, soft-light, darken, lighten, difference,
exclusion, color-dodge, color-burn, hue, saturation, color, luminosity,
**alpha-multiply** (uses the layer's alpha as a mask on the destination;
`scope` param: `below` = only the layer directly beneath, `composite` =
everything below the layer), plus `erase` (destination alpha *= 1-src).

**Preview at layer N** = composite of layers 0..N. **Layer-only preview** =
`render_layer(N)` output alone. Both available in the preview panel via a
mode toggle. Layer stack rows show a live thumbnail of each layer's own
output.

## Layer types (v1)

| type | params | notes |
|---|---|---|
| `image` | asset id, filter (bilinear default), offset/scale | pasted/dropped file, copied into `assets/` |
| `paint` | brush size, hardness (feather), color, eraser, custom brush layer id, palette-lock | strokes stored as polylines (replayable → cheap undo, tiny files); stamp = soft circle or another layer's output |
| `noise` | type (value/Perlin/fbm), scale, octaves, seed, colorize, alpha | deterministic per seed; wraps for tiling |
| `grade` | brightness, contrast (pivot), gamma, saturation, vibrance, hue, temperature, tint, colorize (hue+strength) | the "one control to rule them all" — one layer, all grading in one panel |
| `palette` | colors (2..256, pow2 quick-presets), quantize (median-cut / neuquant), dither (none / bayer2..8 / fs / sierra / atkinson), alpha mode (rgb-keep / rgba) | recolor panel: click palette entry → edit → all pixels of that index update (index structure preserved) |
| `downscale` | size (w,h), filter (nearest / bilinear / bicubic / box / anisotropic) | changes working size downstream |
| `seamless` | blend width, mode (offset-crossfade / edge-bleed) | makes the partial composite tile |
| `fill` | solid color or linear/radial/conic gradient | vignettes, masks, alpha ramp |
| `group` | include-below bool | nests children; children composite as one unit |
| `export` | name, size override, format (png/tga/bmp) | marker: captures composite at its position; pick by name when exporting |

Custom brush: any layer (including hidden ones) can be a paint stamp —
grayscale→alpha or direct RGBA. "Only palette colors" paint lock uses the
palette of the current partial composite's palette layer (nearest palette
layer at or below the paint layer).

## UX

- **Everything tiled.** ImGui dockspace, no floating windows. Panels:
  Layers (left), Properties (right), Preview (center), Palette, Console,
  Project. All resizable/dockable via splitter drags.
- **Preview**: 4×4 tiled by default (toggle to single tile), checkerboard
  transparency, zoom (fit / 1× / 2× / 4×, Ctrl+wheel), alt-drag pan,
  mode toggle [Final | At layer | Layer only]. Nearest sampling at 1:1+.
- **Layer stack**: thumbnails, visibility eye, opacity slider, blend combo,
  drag to reorder, double-click rename, context menu (duplicate, group,
  delete). Click → select (properties + preview-at-layer follow).
- **Palette panel**: shows the palette of the current partial composite
  (if a palette layer is active at/below selection) — swatches, count,
  click-to-recolor, "regenerate" parameters (mirrors the palette layer).
- **Picker on startup**: project list with thumbnails + random-name new
  project ("furry-cobblestone" style, dictionary words, rename anytime,
  also while open via Project panel). Recent list. Standard dir:
  `%USERPROFILE%/texturewrangler/projects` (win) / `~/texturewrangler/
  projects` (linux), overridable in settings.json.
- **Import**: drag&drop anywhere (SDL3 drop event), clipboard paste
  (SDL3 image/bmp clipboard → stb), Ctrl+U file dialog. All copied into
  `assets/`.
- **Export**: menu + panel. Default = final composite → project `export/`
  folder (no export layer needed; implicit top-of-stack). Export layers add
  named captures; extra locations = absolute paths (e.g. a Godot project's
  texture) with optional auto-export-on-change (debounced 500ms).
- **No dialogs for saving**: autosave 400ms after any change, always.
  Undo journal persists across restarts (like teidraw).
- **Theme**: dark, styled after cosmic2d/slopstudio (rounded, subdued
  accent, clear active states). Ctrl+U opens the import dialog.

## Debug infra (embedded Lua)

- Console panel: REPL, `tw.log()`, stack traces, `tw.reload()` re-runs
  lua/main.lua without restarting.
- Error handling: any Lua error during a frame is caught, printed to the
  console, and the last good state keeps rendering (no hard crash).
- C++ side logs through the same console.

## C++ surface (kept minimal)

```
main.cpp    entry, arg parsing (--test, --shot, --project)
app.cpp     SDL3 + imgui init, frame loop, drop/paste/event routing
ig.cpp      imgui → Lua binding (subset: windows, dockspace, widgets,
            drawlist, style, fonts, textures)  [cosmic2d ig.cpp pattern]
kernels.cpp RGBA8 pixel kernels (below), exposed to Lua as tw.tex.*
tex.cpp     Image buffer (w,h,px), GPU texture upload/delete, imgui image
lua.cpp     Lua 5.4 VM, module loading, error capture, debug hook
file.cpp    stb_image read/write, file copy, mkdir, project dirs
```

Kernels (all deterministic, all take/return `Image`):

- resample: nearest, bilinear, bicubic (Catmull-Rom), box (area), aniso
- blur: box, gaussian (separable)
- grade: brightness/contrast/gamma/saturation/vibrance/hue/temp/tint/
  colorize — one pass, straight math on linear-ish RGB (sRGB approx: ops
  applied in gamma space like paint.net/gimp default)
- quantize: median-cut + neuquant palette extract, nearest-color map,
  dither: bayer (2/4/8), Floyd-Steinberg, Sierra, Atkinson (serpentine
  scan), alpha modes
- blend: all modes above, straight alpha
- noise: value/Perlin/fbm, hash-seeded, wrap=repeat
- seamless: offset-crossfade, edge-bleed (strip blend widths)
- fill/gradient: linear/radial/conic
- paint: soft circle stamp, max-alpha accumulation, arbitrary stamp image
- color ops for panel: histogram, unique-color count, average

Everything operates on plain `Image { int w, h; uint32_t* px; }` (RGBA8
straight alpha). No allocation in the hot loops; buffers are reused.

## Testing strategy

1. **Kernel tests** — `texturewrangler --test`: Lua test suite
   (`tests/test_*.lua`) driving `tw.tex.*` with pixel-exact expectations
   (deterministic kernels → golden values). Covers every filter, blend
   mode, quantize+dither, noise seed determinism, seamless edge wrap,
   paint alpha accumulation, doc serialization round-trip, undo.
2. **ASAN** — `make asan` (linux, -fsanitize=address,undefined) then run
   `--test` + a scripted composite of every layer type. Leak/bounds checks
   on the kernel paths.
3. **Headless UI shots** — `texturewrangler --shot out.png --frames N`
   renders the real UI offscreen (SDL_VIDEODRIVER=offscreen); vision-check
   the pngs (layout, theme, panels, preview correctness: tile seams,
   checkerboard, palette swatches). No screen stealing.
4. **Edge cases** — 1×1 canvases, non-square sizes, opacity 0/1, empty
   layers, groups-with-groups, custom brush referencing a deleted layer,
   import of a corrupt image, downscale to larger size, palette 2 colors,
   undo across autosave.

## Build

`nix develop` → `make -C editor` (windows default) | `make -C editor linux`
| `make -C editor asan` | `make -C editor shot`. Windows output lands in a
standalone folder: exe + required DLLs (SDL3.dll, runtime) — see
`tools/package.sh`. Everything (imgui, lua) compiles from flake-pinned
source into the binary; no runtime deps beyond SDL3.dll.

Compile-time flags: `-O2 -g`, warnings on, one TU per concern, imgui
compiled once (only main-ish TUs rebuild on edits).

## Decisions from research

- **Order-of-operations discipline** (from the RetrO video): the tool can't
  enforce it, but the default palette-layer placement + grade-before-blur
  presets and the preview make the recommended chain
  (downscale → grade → blur/paint → palette) the path of least resistance.
- **Palette-first workflows**: recolor-after-quantize and per-layer color
  budgets (video's 5+11=16 trick) are supported natively — palette layers
  can be split with groups/export layers capturing partial results.
- **Overlay color-infusion** (video's main mood trick) = grade.colorize +
  blend mode, no extra layers needed.
- **Tile-variation sets** (4×4 grid, shared edges) = four image layers +
  seamless layer on the shared base; a future `tileset` layer can automate
  the grid-slice workflow.
