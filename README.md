# texturewrangler

Non-destructive, procedural retro-texture editor for the N64–PS2 era:
32–128px, power-of-two textures, 8–32 color palettes. Everything is a layer;
every layer is a parameterized modifier; nothing bakes unless you export.

> **⚠ Proof-of-concept prototype.** This project is a prototype to explore
> different workflows for quick, low-friction texture editing. It tries to
> address the pains of doing that in a normal editor like GIMP — or worse,
> jumping between different tools for every step of the job.

## Why

Retro textures are small, constrained, and need a very specific loop: resize
to working size, tile seamlessly, quantize to a palette, dither, paint with
palette-locked colors, export. In a normal editor every step is a separate,
destructive, manual chore — and the "right" way often means bouncing between
GIMP, a tiling tool, a palette tool, and a converter. This prototype explores
what a single, non-destructive tool for that whole loop looks like:

- **Nothing bakes until you export.** Layers are parameterized modifiers, so
  changing anything re-renders the stack below it. A downscale layer resizes
  the working size; remove it and the size reverts.
- **Retro constraints as first-class layers.** Palette layers re-map live —
  recolor one entry and every pixel of that index updates. Seamless layers
  tile in one click. Dithering is a layer property.
- **One tool for the whole job.** Import/export, tiling, quantization,
  paint with custom brushes and palette-lock, groups, project picker — no
  tool-hopping.
- **Undo that reaches across sessions** (journal), autosave, deterministic
  exports (byte-identical across linux and windows), headless test suite.

## What works

Proof-of-concept, but functional: 10 layer types (image, paint, noise, grade,
palette, downscale, crop, seamless, fill, group, export), tiled resizable UI,
palette workflows, project picker, paint, groups, 350+ headless tests, linux
+ windows builds. Architecture: [DESIGN.md](DESIGN.md). Build/run/debug
details: [ORIENTATION.md](ORIENTATION.md).

## Nightly builds

CI rebuilds daily and publishes the Windows package under a rolling
[`nightly` release](../../releases/tag/nightly) (tag auto-bumped to the
newest commit). Linux gets no prebuilt artifact — see below.

## Linux: build from the flake, or package for your distro

Requires [Nix](https://nixos.org/) with flakes:

```sh
nix develop
make -C editor linux      # → build/texturewrangler
make -C editor test       # headless test suite
```

The linux build links the SDL3 shared library pinned in the flake dev shell
(SDL3 3.x), so it is not a standalone artifact. To ship it, package it for
your distro: depend on SDL3 (3.x), install `build/texturewrangler` together
with the `editor/lua/` runtime directory, and add a desktop entry. For one
worked example of a store-independent linux build — bundling SDL3's closure
next to the binary with `patchelf` and shipping a portable tarball — see
[cosmic2d](https://github.com/Francesco149/cosmic2d).

## Windows build (cross-compiled from nix)

```sh
nix develop
make -C editor            # → build/texturewrangler.exe (mingw cross)
make -C editor package    # → build/texturewrangler-win64/ (exe + dlls + lua/)
```

## Run

```sh
build/texturewrangler                  # project picker
build/texturewrangler --project <dir>  # open a project
build/texturewrangler --demo <dir>     # build the demo project + open
```

## License

MIT — see [LICENSE](LICENSE).
