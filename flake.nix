{
  description = "texturewrangler — non-destructive retro texture editor (SDL3 + imgui + embedded Lua)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };

        # ── Windows cross-toolchain ───────────────────────────────────────
        # texturewrangler is a 64-bit Windows PE cross-compiled with
        # mingw-w64 and run natively on the Windows host via WSLInterop
        # (no WSLg tax). Same proven pattern as teidraw/slopstudio/cosmic2d.
        # NOTE: compilers come from `.buildPackages` (they run on the build
        # host); LIBRARIES for the windows target come from the cross set
        # itself (`pkgsCross.mingwW64.sdl3` — using `.buildPackages.sdl3`
        # silently gives the LINUX sdl3 and drags pipewire's chain).
        mingw = pkgs.pkgsCross.mingwW64.buildPackages;
        mingwPkgs = pkgs.pkgsCross.mingwW64;

        # ── Dear ImGui, pinned ≥1.92 ──────────────────────────────────────
        # nixpkgs ships 1.91.x; we pin 1.92.4 like teidraw (dynamic font
        # atlas → crisp text at any zoom). Source-vendored into the binary.
        imguiSrc = pkgs.fetchFromGitHub {
          owner = "ocornut";
          repo = "imgui";
          rev = "v1.92.4";
          hash = "sha256-DyQ2fh749S41UFdLto7TtxsnBsd7CBzAUFq36LeZZ5Y=";
        };

        # ── Lua 5.4 source (embedded; compiled as C into both targets) ───
        # runCommand unpacks the nixpkgs lua5_4 source tarball so the
        # Makefile can compile it directly (mingw on windows, host cc on
        # linux) — same trick as slopstudio's layout engine.
        luaSrc = pkgs.runCommand "lua-5.4-src" { } ''
          mkdir -p $out
          tar xzf ${pkgs.lua5_4.src} --strip-components=1 -C $out
        '';
      in {
        devShells.default = pkgs.mkShell {
          name = "texturewrangler-dev";

          packages = with pkgs; [
            mingw.gcc            # x86_64-w64-mingw32-{gcc,g++} → Win64 PE
            mingw.binutils       # + windres for the icon resource
            gnumake
            pkg-config           # resolves sdl3 for `make linux`
            python3              # tools/embed.py (fonts/icon → C arrays)
            stb                  # stb_image / stb_image_write (decode + export)
            lua5_4               # host lua: scripts + ad-hoc kernel checks
            git
            jq
          ];

          # linux-target SDL3, resolved through the pkg-config hook
          buildInputs = with pkgs; [ sdl3 ];

          shellHook = ''
            export TW_ROOT=$PWD

            # Dear ImGui source checkout (compiled directly into the binary).
            export IMGUI_DIR=${imguiSrc}

            # Embedded Lua 5.4 sources (compiled as C, both targets).
            export LUA_SRC=${luaSrc}

            # stb_image / stb_image_write headers.
            export STB_INC=${pkgs.stb}/include

            # SDL3 for the Windows cross target (DLL + import lib) and the
            # host SDL3 for the linux build (resolved via pkg-config).
            export SDL3_CROSS_INC=${mingwPkgs.sdl3.dev}/include
            export SDL3_CROSS_LIB=${mingwPkgs.sdl3}/lib
            export SDL3_CROSS_DLL=${mingwPkgs.sdl3.out}/bin/SDL3.dll
            # mingw pthread runtime (linked dynamically by default): locate
            # the dll through the cross compiler's own -L search dir
            export MCFG_LIBDIR=$(x86_64-w64-mingw32-g++ -### -x c++ /dev/null -o /dev/null 2>&1 \
              | tr ' ' '\n' | grep -m1 -oE '^-L/nix/store/[^ ]*mcfgthread[^ ]*/lib' | cut -c3-)
            export MCFG_DLL=$(dirname "$MCFG_LIBDIR")/bin/libmcfgthread-2.dll

            # mingw cross-compiler handles (used by editor/Makefile).
            export MINGW_CC=x86_64-w64-mingw32-gcc
            export MINGW_CXX=x86_64-w64-mingw32-g++
            export MINGW_STRIP=x86_64-w64-mingw32-strip
            export MINGW_WINDRES=x86_64-w64-mingw32-windres

            echo "texturewrangler dev shell"
            echo "  imgui:   $IMGUI_DIR"
            echo "  lua:     $LUA_SRC"
            echo "  sdl3:    pkg-config (linux) + $SDL3_CROSS_LIB (windows)"
            echo "  mingw:   $(command -v $MINGW_CXX || echo '(missing)')"
            echo "  build:   make -C editor        # windows (default)"
            echo "           make -C editor linux  # native linux"
            echo "           make -C editor asan   # ASAN+UBSAN linux build"
          '';
        };

        formatter = pkgs.nixfmt-rfc-style;
      });
}
