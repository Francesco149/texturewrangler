// editor.h — texturewrangler native core.
//
// Deliberately small and plain: the C++ side owns the window, imgui, the
// Lua VM, the GPU upload path and the pixel kernels. All product logic,
// UI, and document state live in Lua (editor/lua/). Keep this header the
// ONLY shared surface between TUs; everything else is file-local.
#pragma once

#include <cstdint>
#include <cstddef>

struct lua_State;

// ── Image ──────────────────────────────────────────────────────────────────
// RGBA8, straight (non-premultiplied) alpha, row-major, top-left origin.
// Owned by the caller; free with tex_free(). Kernel results are fresh
// images (never alias inputs). Lua exposes these as `tw.Image` userdata
// with __gc; C++ never keeps images alive across frames.
struct Image {
  int w = 0;
  int h = 0;
  uint32_t* px = nullptr; // w*h u32s, 0xRRGGBBAA
};

// tex.cpp — buffer lifecycle + Lua image userdata + GPU upload
Image* tex_alloc(int w, int h);
Image* tex_clone(const Image* src);
void tex_free(Image* img);
void tex_clear(Image* img, uint32_t rgba);
uint32_t tex_pixel(const Image* img, int x, int y); // clamped, no wrap
void tex_set(Image* img, int x, int y, uint32_t rgba);

// GPU: create-or-update an SDL texture for img, return ImTextureID
// (SDL_Texture* as intptr). Nearest sampling; recreated on size change.
intptr_t gfx_upload(const Image* img);
void gfx_free_tex(intptr_t id);

// kernels.cpp — pure pixel ops. All take/return Image* (fresh), read Lua
// args, push results. Deterministic for a given seed.
Image* k_resize(const Image* src, int w, int h, const char* filter);
Image* k_blur(const Image* src, float radius, const char* type);
Image* k_grade(const Image* src, float brightness, float contrast, float gamma,
               float saturation, float vibrance, float hue, float temperature,
               float tint, uint32_t colorize, float colorize_strength);
// quantize: extracts `colors` palette, writes *pal (malloc'd, caller frees),
// returns mapped image (dither applied if any).
Image* k_quantize(const Image* src, int colors, const char* method,
                  const char* dither, int alpha_mode, uint32_t** pal,
                  int* pal_n);
// map_palette: re-map src through an existing palette (recolor).
Image* k_map_palette(const Image* src, const uint32_t* pal, int pal_n,
                     const char* dither, int alpha_mode);
// blend: dst_base blended with src_layer per mode+opacity → new image.
// mode: normal multiply screen overlay hardlight softlight darken lighten
//       difference exclusion dodge burn hue saturation color luminosity
//       alphamask erase
Image* k_blend(const Image* base, const Image* src, const char* mode,
               float opacity);
Image* k_noise(int w, int h, const char* type, float scale, int octaves,
               int seed, uint32_t tint, int colorize_mode, int alpha_from);
Image* k_seamless(const Image* src, int blend, const char* mode);
Image* k_fill(int w, int h, const char* type, uint32_t c0, uint32_t c1,
              float angle, float cx, float cy, float rx, float ry);
// stamp: paint into dst in place (dst must be mutable, not shared).
// mode: 0=paint (max-alpha accumulate), 1=erase (subtract alpha).
// stamp==null → soft circle of `color`; else stamp image (scaled) used as
// RGBA source; color multiplies it.
void k_stamp(Image* dst, float cx, float cy, float radius, float hardness,
             uint32_t color, const Image* stamp, float stamp_scale, int mode);
// stats: average color, unique color count, per-channel min/max.
void k_stats(const Image* src, double* avg, int* unique, int* minmax);

// lua.cpp — embedded Lua 5.4
void lua_init(const char* root_dir, int argc, char** argv); // may exit (--test)
void lua_frame(void);  // run the Lua UI pass, catch + log errors
void lua_shutdown(void);
lua_State* lua_state(void);
int lua_run_string(const char* code, char* err, size_t errsz); // console eval

// app.cpp — SDL3 + imgui host loop
int app_main(int argc, char** argv); // entry after arg parsing in main.cpp
void app_log(const char* fmt, ...);  // console-visible log
void app_quit(int code);
void app_set_renderer(struct SDL_Renderer* r); // tex.cpp gfx registry needs it

// file.cpp — IO (stb_image/stb_image_write + POSIX/win32 file helpers)
Image* file_load_image(const char* path);                    // nil-safe
int file_save_image(const char* path, const Image* img);     // PNG by ext
int file_write_all(const char* path, const void* data, size_t len);
char* file_read_all(const char* path, size_t* len);          // malloc'd
int file_mkdirs(const char* path);                           // recursive
int file_copy(const char* src, const char* dst);
int file_exists(const char* path);
// path helpers (static buffers, not thread safe)
const char* path_dirname(const char* p);
const char* path_join(const char* a, const char* b);
const char* path_basename(const char* p);
