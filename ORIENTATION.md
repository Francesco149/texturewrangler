# texturewrangler — orientation

Non-destructive, procedural retro-texture editor (N64–PS2 era: 32–128px,
power-of-two, 8–32 color palettes). Everything is a layer; every layer is a
parameterized modifier; nothing bakes unless you export. C++ is a slim core
(window, imgui, Lua VM, GPU upload, pixel kernels); ALL product logic, UI,
and document state are embedded Lua 5.4. Full architecture rationale:
[DESIGN.md](DESIGN.md). Original brainstorm: [SEED.md](SEED.md).

## Environment (persist this — never rediscover)

- NixOS under WSL2, Win11 host. Host reachable at `cutestation.soy` (local
  IP works too). Windows binaries run on the host via **WSLInterop**
  (no WSLg tax); the linux build runs under WSLg.
- Everything runs through `nix develop` (flake). Deps: SDL3 (host + mingw
  cross), Dear ImGui 1.92.4 (pinned source), Lua 5.4 source, stb, python3,
  mingw-w64 gcc 15.
- `yt-dlp` lives in the nix store; use `--cookies-from-browser firefox`.
  `yutu` (YouTube API CLI) is at `~/.local/bin/yutu`.
- `~/.local/bin/vision <image> "<question>"` inspects images headlessly
  (vision model) — use it for every UI verification; screenshots render
  offscreen so nothing steals the user's screen.
- Commit convention: `Co-Authored-By: DeepSeek V4 Flash <noreply@opencode.ai>`
  trailer, commits in logical units.

## Build & run (inside `nix develop`)

```sh
make -C editor            # windows cross build → build/texturewrangler.exe
make -C editor linux      # native → build/texturewrangler
make -C editor asan       # ASan+UBSan build
make -C editor package    # windows standalone folder (exe + dlls + lua/)
make -C editor test       # headless test suite (200+ tests)
make -C editor test-asan  # the same under ASan/UBSan
make -C editor shot       # headless UI screenshot → build/shot.png
```

CLI modes (all headless-capable):
```sh
build/texturewrangler                        # project picker
build/texturewrangler --project <dir>        # open a project
build/texturewrangler --demo <dir>           # build the demo project + open
build/texturewrangler --test                 # run tests, exit 0/1
build/texturewrangler --shot out.png [--frames N]   # offscreen UI capture
build/texturewrangler --export               # headless export-all, exit
build/texturewrangler --lua <file.lua>       # run a lua script headless
```

## Code map

```
flake.nix          dev shell: toolchains, pinned sources, MCFG_DLL/SDL3_* envs
DESIGN.md          architecture + research-driven layer decisions
ORIENTATION.md     this file
assets/fonts/      OFL fonts baked in by tools/embed.py (build/fonts_embedded.h)

editor/Makefile    win (default) / linux / asan / test / shot / package
editor/src/        the entire C++ side — keep it slim
  editor.h         the ONLY shared header (Image, kernel/IO/lua/app decls)
  main.cpp         args, lua-dir resolution, --test/--shot dispatch
  app.cpp          SDL3+imgui loop, drops, clipboard paste, dialogs, shots
  lua.cpp          VM embed, tw.* module registration, error capture
  tex.cpp          Image userdata (tw.Image), GPU texture registry (tw.gfx)
  kernels.cpp      all pixel ops + tw.tex.* bindings (resize/blur/grade/
                   quantize+dither/blend/noise/seamless/fill/stamp/stats)
  ig.cpp           imgui → tw.ig.* binding (widgets, drawlist, style, keys)
  file.cpp         stb image IO, file/path helpers, SDL fs, tw.file.*
editor/lua/        the product — ALL of it (panels, model, layers)
  main.lua         bootstrap + frame orchestration (panel layout, pcall
                   safety, shortcuts, autosave tick, perf)
  doc.lua          document model: layer tree, versions, caches, mutations
  render.lua       compositor with per-layer output caching + timings
  undo.lua         snapshot undo/redo + undo.jsonl cross-session journal
  autosave.lua     400ms debounced project.json save + auto-export
  export.lua       final composite + export layers + named locations
  import.lua       drag&drop / paste / Ctrl+U → assets/ + image layer
  panels.lua       tiled layout engine (splitters, panel chrome, toolbar)
  panel_layers.lua layer stack: thumbs, visibility, drag reorder, context
  panel_props.lua  per-layer property editors
  panel_palette.lua palette swatches + recolor (the retro heart)
  panel_export.lua export locations UI
  preview.lua      canvas: 4×4 tile, zoom/pan, checkerboard, paint input
  console.lua      REPL (`perf` prints timing breakdown) + log viewer
  picker.lua       startup project browser
  demo.lua         the demo project (noise→grade→seamless→palette→mood→paint→vignette)
  perf.lua         frame/comp timing, per-layer-type breakdown, F3 overlay
  theme.lua        dark theme (amber accent)
  json.lua         hand-rolled JSON (doc format)
  ui.lua           widget helpers used by layer panels
  layers/*.lua     one file per layer type (render + property panel)
editor/tests/      testlib.lua + test_{json,kernels,doc,composite}.lua
tools/embed.py     fonts → C array header
```

## Mental model

- **Working size flows through the stack.** Composite starts at the project
  canvas (set by the first import, else 64×64). A `downscale` layer resamples
  to its target and everything above works at that size. Remove it → size
  reverts. Export resolution = size at the top (or export layer override).
- **Every layer renders an output; the composite blends bottom-up.** Images/
  paints/noises/fills are independent; grade/palette/seamless TRANSFORM the
  partial composite below them (their opacity/blend fades that transform —
  "remove the modifier → undo the effect").
- **Groups**: self-only (children from transparent) blends like any layer;
  include-below REPLACES the composite (a bake). A downscale inside a group
  resamples back to the entry size on exit.
- **Blend**: W3C compositing. `alpha-mask` = the layer's alpha as a mask;
  `scope` below = mask only the single layer beneath, composite = everything.
  `erase` subtracts alpha.
- **Caching**: `doc._ver[id]` bumps on any mutation (doc.mutate bumps ALL —
  O(n), removes staleness bugs); composite/thumb caches keyed by
  (version, size) skip unchanged prefixes. In-flight paint strokes bypass
  the cache so they show same-frame.
- **Undo**: every doc.mutate pushes a full JSON snapshot (params + strokes —
  tiny) to an in-memory stack AND appends undo.jsonl (cross-session undo).
  Slider drags coalesce to one entry. Paint strokes push one entry per
  stroke, not per point.
- **Palette flow**: first render extracts (median-cut) and stores the
  palette in params (derived data); afterwards it re-maps through it, so
  recoloring an entry updates every pixel of that index. "Regenerate"
  clears it. Dither: none/bayer4/fs/sierra/atkinson.

## Verification workflow (autonomous, no screen stealing)

1. `make -C editor test` — kernels are pixel-exact deterministic; composite
   tests cover groups, masks, downscale flow, paint, palette recolor.
2. `make -C editor test-asan` — same under ASan+UBSan.
3. `build/texturewrangler --demo build/demo --shot build/shot.png --frames 30`
   then `~/.local/bin/vision build/shot.png "…"` — verify layout, panels,
   texture quality, seams.
4. `build/texturewrangler --project build/demo --export` — verify exports;
   `--lua` for pixel-level assertions (see the alpha check pattern).
5. Windows: `make -C editor package`, copy to a C:\ path, run via a .bat
   (cmd.exe can't cd into UNC paths). Exports are md5-identical to linux —
   determinism is a feature, use it.

## Hard-won gotchas (read before touching)

- `path_join`/`path_dirname` use a rotating static buffer ring — nested
  calls alias; the overlap guard + candidate snapshot in find_lua_dir are
  load-bearing. Don't "simplify" them.
- `ig.end` is a Lua reserved word — the binding is `ig.end_`.
- imgui style vars are typed: PushStyleVar float vs ImVec2 asserts if
  mismatched (ig.cpp has the explicit v2 list).
- `text_colored` takes (string, r,g,b,a); `dl_add_text` takes
  (dl, x, y, r,g,b,a, string). Both are footguns.
- `doc.add_layer` puts new layers on TOP (layers[1] = bottom).
- Rect structs are `{x=,y=,w=,h=}` named fields, NOT arrays.
- Lua errors inside panels must not leave Begin/EndChild unbalanced — the
  main.lua `panel()` wrapper pcall's the body; keep early returns balanced
  (a stray end_child in an early return pops the main window).
- The offscreen SDL shot works on linux; on Windows the D3D11/offscreen
  combo renders blank (CPU paths — composite/export/tests — work fine;
  verify those on the host).
- SDL3 `SDL_GetVersion()` returns an int, not a string.
- Embedded fonts are `FontDataOwnedByAtlas=false` — imgui would free()
  static arrays at shutdown otherwise.
- `SDL_RenderReadPixels` in SDL 3.4.12 returns an SDL_Surface (newer API).
- `pkgsCross.mingwW64.buildPackages.sdl3` is the LINUX sdl3 — libraries for
  the target come from `pkgsCross.mingwW64.sdl3` directly; `bin` output
  holds the DLL. mingw links libmcfgthread-2.dll dynamically — the package
  target ships it.

## State

Working: full layer pipeline (10 layer types), non-destructive semantics,
palette workflows, undo/redo journal, autosave, project picker, import
(drop/paste/Ctrl+U), export (final + named captures + locations), paint with
palette-lock and custom brushes, groups, tiled resizable UI, console REPL,
headless testing + shots, ASAN-clean, linux + windows builds (byte-identical
exports). 200+ tests green.

Next ideas: tileset-variation layer (the video's 4×4 grid workflow),
neuquant quantizer, alpha-multiply scope polish, more dither matrices,
per-layer preview in the properties panel, high-DPI scaling pass.
