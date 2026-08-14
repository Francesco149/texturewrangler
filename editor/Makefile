# editor/Makefile — texturewrangler, three targets from one tree:
#   make            → ../build/texturewrangler.exe  (Win64 PE, mingw-w64 cross; default)
#   make linux      → ../build/texturewrangler      (native Linux, SDL3)
#   make asan       → ../build/texturewrangler-asan (Linux, ASan+UBSan)
# Dear ImGui + Lua 5.4 + stb are compiled directly into the binary from
# flake-pinned sources ($IMGUI_DIR / $LUA_SRC / $STB_INC). Run inside
# `nix develop` so $MINGW_CXX / $SDL3_CROSS_* / pkg-config are set.
# NOTE: `:=` (not `?=`) for the compilers — the dev shell exports CXX=g++,
# which must lose to the mingw cross-compiler (CLI `make WIN_CXX=` still wins).

IMGUI ?= $(IMGUI_DIR)
LUA   ?= $(LUA_SRC)
STBI  ?= $(STB_INC)

BUILD := ../build
OBJ   := $(BUILD)/obj
OUT   := $(BUILD)/texturewrangler.exe

# fonts baked into the binary by tools/embed.py (no runtime files)
FONTS_H := $(BUILD)/fonts_embedded.h
FONT_UI  := ../assets/fonts/InterVariable.ttf
FONT_MONO := ../assets/fonts/JetBrainsMono-Regular.ttf

# ── sources ────────────────────────────────────────────────────────────────
SRC := src/main.cpp src/app.cpp src/ig.cpp src/kernels.cpp src/tex.cpp \
       src/lua.cpp src/file.cpp

IMGUI_CORE := imgui.cpp imgui_draw.cpp imgui_tables.cpp imgui_widgets.cpp \
              imgui_stdlib.cpp
IMGUI_BACKEND := imgui_impl_sdl3.cpp imgui_impl_sdlrenderer3.cpp

# Lua 5.4 core, compiled AS C — every src/*.c EXCEPT the CLI mains
# (lua.c interpreter, luac.c compiler → duplicate main()).
LUA_C := $(filter-out $(LUA)/src/lua.c $(LUA)/src/luac.c,$(wildcard $(LUA)/src/*.c))

CXXFLAGS_COMMON := -std=c++17 -O2 -g -Wall -Wno-unknown-pragmas \
  -I src -I $(BUILD) -I $(IMGUI) -I $(IMGUI)/backends -I $(IMGUI)/misc/cpp \
  -I $(LUA)/src -I $(STBI) -I $(STBI)/stb

OBJ_CXX := $(addprefix $(OBJ)/,$(notdir $(SRC:.cpp=.o)) \
             $(IMGUI_CORE:.cpp=.o) $(IMGUI_BACKEND:.cpp=.o))
OBJ_LUA := $(addprefix $(OBJ)/lua/,$(notdir $(LUA_C:.c=.o)))

# ══ windows (default) ═══════════════════════════════════════════════════════
WIN_CXX := $(MINGW_CXX)
WIN_CC   := $(MINGW_CC)

WIN_CXXFLAGS := $(CXXFLAGS_COMMON) -DUNICODE -D_UNICODE -D_WIN32_WINNT=0x0A00 \
  -I $(SDL3_CROSS_INC)
WIN_LDFLAGS  := -static-libgcc -static-libstdc++ -mconsole
# SDL3 cross import lib + the Win32 libs SDL3's .dll.a references
WIN_LIBS := -L$(SDL3_CROSS_LIB) -lSDL3 \
  -lgdi32 -limm32 -lole32 -loleaut32 -lversion -lwinmm -luuid -ldxgi -ld3d11 \
  -lsetupapi -lcomdlg32 -lshell32 -luser32 -lkernel32 -latomic

win: $(OUT)
$(OUT): $(OBJ_CXX) $(OBJ_LUA) | $(BUILD)
	$(WIN_CXX) $(OBJ_CXX) $(OBJ_LUA) -o $(OUT) $(WIN_LDFLAGS) $(WIN_LIBS)
	@echo "built $(OUT)"

# ══ linux ═══════════════════════════════════════════════════════════════════
# (rules below, in the "linux variant" section — separate obj tree so the
# windows and linux builds can coexist; `make linux` is an alias)
LINUX_CXX := $(CXX)

SDL3_CFLAGS ?= $(shell pkg-config --cflags sdl3 2>/dev/null)
SDL3_LIBS   ?= $(shell pkg-config --libs sdl3 2>/dev/null)

# every -L dir doubles as an rpath so dev binaries find their nix .so's
, := ,
LIN_RPATH := $(patsubst -L%,-Wl$(,)-rpath$(,)%,$(filter -L%,$(SDL3_LIBS)))

LINUX_OUT := $(BUILD)/texturewrangler
LINUX_CXXFLAGS := $(CXXFLAGS_COMMON) $(SDL3_CFLAGS)
LINUX_LDFLAGS  := -static-libgcc -static-libstdc++
LINUX_LIBS := $(SDL3_LIBS) -lm -ldl -lpthread $(LIN_RPATH)

# ══ asan (linux, ASan+UBSan) ════════════════════════════════════════════════
ASAN_OUT := $(BUILD)/texturewrangler-asan
ASAN_CXXFLAGS := $(CXXFLAGS_COMMON) $(SDL3_CFLAGS) \
  -O1 -g -fno-omit-frame-pointer -fsanitize=address,undefined
ASAN_LDFLAGS  := -fsanitize=address,undefined
ASAN_OBJ := $(addprefix $(BUILD)/asan-obj/,$(notdir $(SRC:.cpp=.o)) \
              $(IMGUI_CORE:.cpp=.o) $(IMGUI_BACKEND:.cpp=.o) \
              $(addprefix lua/,$(notdir $(LUA_C:.c=.o))))

asan: $(ASAN_OUT)
$(ASAN_OUT): $(ASAN_OBJ) | $(BUILD)
	$(LINUX_CXX) $(ASAN_OBJ) -o $(ASAN_OUT) $(ASAN_LDFLAGS) $(LINUX_LIBS)
	@echo "built $(ASAN_OUT)"

$(BUILD)/asan-obj/%.o: src/%.cpp src/editor.h | $(BUILD)/asan-obj
	$(LINUX_CXX) $(ASAN_CXXFLAGS) -c $< -o $@
$(BUILD)/asan-obj/%.o: $(IMGUI)/%.cpp | $(BUILD)/asan-obj
	$(LINUX_CXX) $(ASAN_CXXFLAGS) -c $< -o $@
$(BUILD)/asan-obj/%.o: $(IMGUI)/backends/%.cpp | $(BUILD)/asan-obj
	$(LINUX_CXX) $(ASAN_CXXFLAGS) -c $< -o $@
$(BUILD)/asan-obj/%.o: $(IMGUI)/misc/cpp/%.cpp | $(BUILD)/asan-obj
	$(LINUX_CXX) $(ASAN_CXXFLAGS) -c $< -o $@
$(BUILD)/asan-obj/lua/%.o: $(LUA)/src/%.c | $(BUILD)/asan-obj/lua
	$(CC) -O1 -g -fsanitize=address,undefined -std=c11 -I $(LUA)/src -c $< -o $@

# ══ generic object rules ════════════════════════════════════════════════════
$(OBJ)/%.o: src/%.cpp src/editor.h | $(OBJ)
	$(WIN_CXX) $(WIN_CXXFLAGS) -c $< -o $@
$(OBJ)/%.o: $(IMGUI)/%.cpp | $(OBJ)
	$(WIN_CXX) $(WIN_CXXFLAGS) -c $< -o $@
$(OBJ)/%.o: $(IMGUI)/backends/%.cpp | $(OBJ)
	$(WIN_CXX) $(WIN_CXXFLAGS) -c $< -o $@
$(OBJ)/%.o: $(IMGUI)/misc/cpp/%.cpp | $(OBJ)
	$(WIN_CXX) $(WIN_CXXFLAGS) -c $< -o $@
$(OBJ)/lua/%.o: $(LUA)/src/%.c | $(OBJ)/lua
	$(WIN_CC) -O2 -std=c11 -I $(LUA)/src -c $< -o $@

# ══ linux variant of the same generic rules (separate obj tree) ═════════════
OBJL := $(BUILD)/obj-linux
OBJL_CXX := $(addprefix $(OBJL)/,$(notdir $(SRC:.cpp=.o)) \
              $(IMGUI_CORE:.cpp=.o) $(IMGUI_BACKEND:.cpp=.o))
OBJL_LUA := $(addprefix $(OBJL)/lua/,$(notdir $(LUA_C:.c=.o)))

linux: linux-build
linux-build: $(LINUX_OUT)

$(LINUX_OUT): $(OBJL_CXX) $(OBJL_LUA) | $(BUILD)
	$(LINUX_CXX) $(OBJL_CXX) $(OBJL_LUA) -o $(LINUX_OUT) $(LINUX_LDFLAGS) $(LINUX_LIBS)
	@echo "built $(LINUX_OUT)"

$(OBJL)/%.o: src/%.cpp src/editor.h | $(OBJL)
	$(LINUX_CXX) $(LINUX_CXXFLAGS) -c $< -o $@
$(OBJL)/%.o: $(IMGUI)/%.cpp | $(OBJL)
	$(LINUX_CXX) $(LINUX_CXXFLAGS) -c $< -o $@
$(OBJL)/%.o: $(IMGUI)/backends/%.cpp | $(OBJL)
	$(LINUX_CXX) $(LINUX_CXXFLAGS) -c $< -o $@
$(OBJL)/%.o: $(IMGUI)/misc/cpp/%.cpp | $(OBJL)
	$(LINUX_CXX) $(LINUX_CXXFLAGS) -c $< -o $@
$(OBJL)/lua/%.o: $(LUA)/src/%.c | $(OBJL)/lua
	$(CC) -O2 -std=c11 -I $(LUA)/src -c $< -o $@

# ══ shared ══════════════════════════════════════════════════════════════════
$(FONTS_H): ../tools/embed.py $(FONT_UI) $(FONT_MONO) | $(BUILD)
	python3 ../tools/embed.py $@ \
	  font_ui=$(FONT_UI) font_mono=$(FONT_MONO)

$(OBJ)/app.o: src/app.cpp src/editor.h $(FONTS_H) | $(OBJ)
	$(WIN_CXX) $(WIN_CXXFLAGS) -c src/app.cpp -o $@
$(OBJL)/app.o: src/app.cpp src/editor.h $(FONTS_H) | $(OBJL)
	$(LINUX_CXX) $(LINUX_CXXFLAGS) -c src/app.cpp -o $@
$(BUILD)/asan-obj/app.o: src/app.cpp src/editor.h $(FONTS_H) | $(BUILD)/asan-obj
	$(LINUX_CXX) $(ASAN_CXXFLAGS) -c src/app.cpp -o $@

$(BUILD):
	mkdir -p $(BUILD)
$(OBJ):
	mkdir -p $(OBJ)
$(OBJ)/lua:
	mkdir -p $(OBJ)/lua
$(OBJL):
	mkdir -p $(OBJL)
$(OBJL)/lua:
	mkdir -p $(OBJL)/lua
$(BUILD)/asan-obj:
	mkdir -p $(BUILD)/asan-obj
$(BUILD)/asan-obj/lua:
	mkdir -p $(BUILD)/asan-obj/lua

# headless screenshot of the editor UI (linux build, offscreen driver)
shot: linux-build
	cd .. && SDL_VIDEODRIVER=offscreen ./build/texturewrangler --shot build/shot.png --frames 10

# headless kernel + model test suite
test: linux-build
	cd .. && ./build/texturewrangler --test

test-asan: asan
	cd .. && ASAN_OPTIONS=detect_leaks=0 ./build/texturewrangler-asan --test

run: linux-build
	cd .. && ./build/texturewrangler

# standalone windows folder: exe + SDL3.dll
package: win
	mkdir -p $(BUILD)/texturewrangler-win64
	cp $(OUT) $(BUILD)/texturewrangler-win64/
	cp $(SDL3_CROSS_DLL) $(BUILD)/texturewrangler-win64/
	@echo "packaged $(BUILD)/texturewrangler-win64/"

clean:
	rm -rf $(OBJ) $(OBJL) $(BUILD)/asan-obj $(OUT) $(LINUX_OUT) $(ASAN_OUT) \
	       $(BUILD)/texturewrangler-win64

.PHONY: win linux linux-build asan shot test test-asan run package clean
