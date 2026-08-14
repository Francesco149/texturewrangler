// file.cpp — IO: stb image load/save, file helpers, path helpers, Lua glue.
// Windows and linux share one POSIX-ish implementation (mingw provides
// unistd/stat); directory listing uses SDL3's portable enumerator.
#include "editor.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <sys/stat.h>
#include <sys/types.h>

#define STB_IMAGE_IMPLEMENTATION
#define STBI_ONLY_PNG
#define STBI_ONLY_JPEG
#define STBI_ONLY_BMP
#define STBI_ONLY_TGA
#define STBI_ONLY_GIF
#define STBI_ONLY_PSD
#define STBI_ONLY_HDR
#define STBI_ONLY_PIC
#define STBI_ONLY_PNM
#include <stb_image.h>

#define STB_IMAGE_WRITE_IMPLEMENTATION
#include <stb_image_write.h>

extern "C" {
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
}

#include <SDL3/SDL.h>

Image* lua_check_image(lua_State* L, int i);
Image* lua_push_image(lua_State* L, Image* img);

// ── image codecs ────────────────────────────────────────────────────────────

Image* file_load_image(const char* path) {
  int w = 0, h = 0, n = 0;
  stbi_uc* data = stbi_load(path, &w, &h, &n, 4);
  if (!data) return nullptr;
  Image* img = tex_alloc(w, h);
  if (!img) {
    stbi_image_free(data);
    return nullptr;
  }
  // stbi gives RGBA straight; pack as 0xRRGGBBAA
  for (int i = 0; i < w * h; i++) {
    uint32_t c = ((uint32_t)data[i * 4] << 24) | ((uint32_t)data[i * 4 + 1] << 16) |
                 ((uint32_t)data[i * 4 + 2] << 8) | (uint32_t)data[i * 4 + 3];
    img->px[i] = c;
  }
  stbi_image_free(data);
  return img;
}

static void write_cb(void* ctx, void* data, int size) {
  fwrite(data, 1, (size_t)size, (FILE*)ctx);
}

int file_save_image(const char* path, const Image* img) {
  if (!img) return -1;
  // stbi wants tightly packed RGBA bytes; alpha is always part of the format
  const char* ext = strrchr(path, '.');
  const int comp = 4;
  uint8_t* buf = (uint8_t*)malloc(sizeof(uint8_t) * 4 * (size_t)img->w * img->h);
  if (!buf) return -1;
  for (int i = 0; i < img->w * img->h; i++) {
    buf[i * 4] = (img->px[i] >> 24) & 0xff;
    buf[i * 4 + 1] = (img->px[i] >> 16) & 0xff;
    buf[i * 4 + 2] = (img->px[i] >> 8) & 0xff;
    buf[i * 4 + 3] = img->px[i] & 0xff;
  }
  int rc = -1;
  if (ext && strcmp(ext, ".tga") == 0) {
    rc = stbi_write_tga_to_func(write_cb, nullptr, img->w, img->h, comp, buf);
  } else if (ext && strcmp(ext, ".bmp") == 0) {
    rc = stbi_write_bmp_to_func(write_cb, nullptr, img->w, img->h, comp, buf);
  } else {
    // default png
    FILE* f = fopen(path, "wb");
    if (f) {
      rc = stbi_write_png_to_func(write_cb, f, img->w, img->h, comp, buf,
                                  img->w * comp);
      fclose(f);
    }
  }
  free(buf);
  return rc > 0 ? 0 : -1;
}

// ── generic file helpers ────────────────────────────────────────────────────

int file_write_all(const char* path, const void* data, size_t len) {
  FILE* f = fopen(path, "wb");
  if (!f) return -1;
  size_t n = fwrite(data, 1, len, f);
  fclose(f);
  return n == len ? 0 : -1;
}

char* file_read_all(const char* path, size_t* len) {
  FILE* f = fopen(path, "rb");
  if (!f) return nullptr;
  fseek(f, 0, SEEK_END);
  long sz = ftell(f);
  fseek(f, 0, SEEK_SET);
  if (sz < 0) {
    fclose(f);
    return nullptr;
  }
  char* buf = (char*)malloc((size_t)sz + 1);
  if (!buf) {
    fclose(f);
    return nullptr;
  }
  size_t n = fread(buf, 1, (size_t)sz, f);
  fclose(f);
  buf[n] = 0;
  if (len) *len = n;
  return buf;
}

int file_mkdirs(const char* path) {
  // recursive: walk components, mkdir each
  char tmp[1024];
  snprintf(tmp, sizeof(tmp), "%s", path);
  size_t len = strlen(tmp);
  if (len == 0) return -1;
  for (size_t i = 1; i < len; i++) {
    if (tmp[i] == '/' || tmp[i] == '\\') {
      tmp[i] = 0;
      mkdir(tmp, 0755);
      tmp[i] = '/';
    }
  }
  return mkdir(tmp, 0755) == 0 ? 0 : (file_exists(tmp) ? 0 : -1);
}

int file_copy(const char* src, const char* dst) {
  FILE* in = fopen(src, "rb");
  if (!in) return -1;
  FILE* out = fopen(dst, "wb");
  if (!out) {
    fclose(in);
    return -1;
  }
  char buf[65536];
  size_t n;
  while ((n = fread(buf, 1, sizeof(buf), in)) > 0) fwrite(buf, 1, n, out);
  fclose(in);
  fclose(out);
  return 0;
}

int file_exists(const char* path) {
  struct stat st;
  return stat(path, &st) == 0;
}

// ── path helpers (static buffers) ───────────────────────────────────────────

const char* path_dirname(const char* p) {
  static char buf[2048];
  snprintf(buf, sizeof(buf), "%s", p);
  char* slash = strrchr(buf, '/');
#ifdef _WIN32
  char* bslash = strrchr(buf, '\\');
  if (bslash && (!slash || bslash > slash)) slash = bslash;
#endif
  if (!slash) {
    buf[0] = '.';
    buf[1] = 0;
    return buf;
  }
  if (slash == buf) {
    buf[1] = 0;
    return buf;
  }
  *slash = 0;
  return buf;
}

const char* path_join(const char* a, const char* b) {
  static char buf[2048];
  snprintf(buf, sizeof(buf), "%s/%s", a, b);
  return buf;
}

const char* path_basename(const char* p) {
  const char* slash = strrchr(p, '/');
#ifdef _WIN32
  const char* bslash = strrchr(p, '\\');
  if (bslash && (!slash || bslash > slash)) slash = bslash;
#endif
  return slash ? slash + 1 : p;
}

// ── Lua glue (tw.file.*) ────────────────────────────────────────────────────

static int l_file_read_text(lua_State* L) {
  const char* path = luaL_checkstring(L, 1);
  size_t len = 0;
  char* buf = file_read_all(path, &len);
  if (!buf) {
    lua_pushnil(L);
    return 1;
  }
  lua_pushlstring(L, buf, len);
  free(buf);
  return 1;
}

static int l_file_write_text(lua_State* L) {
  const char* path = luaL_checkstring(L, 1);
  size_t len = 0;
  const char* s = luaL_checklstring(L, 2, &len);
  lua_pushboolean(L, file_write_all(path, s, len) == 0);
  return 1;
}

static int l_file_exists(lua_State* L) {
  lua_pushboolean(L, file_exists(luaL_checkstring(L, 1)));
  return 1;
}

static int l_file_mkdirs(lua_State* L) {
  lua_pushboolean(L, file_mkdirs(luaL_checkstring(L, 1)) == 0);
  return 1;
}

static int l_file_copy(lua_State* L) {
  lua_pushboolean(L, file_copy(luaL_checkstring(L, 1), luaL_checkstring(L, 2)) == 0);
  return 1;
}

static int l_file_load_image(lua_State* L) {
  Image* img = file_load_image(luaL_checkstring(L, 1));
  lua_push_image(L, img);
  return 1;
}

static int l_file_save_image(lua_State* L) {
  Image* img = lua_check_image(L, 1);
  lua_pushboolean(L, file_save_image(luaL_checkstring(L, 2), img) == 0);
  return 1;
}

struct ListCtx {
  lua_State* L;
  int n;
};

static SDL_EnumerationResult list_cb(void* userdata, const char* dirname,
                                     const char* fname) {
  (void)dirname;
  ListCtx* ctx = (ListCtx*)userdata;
  if (strcmp(fname, ".") == 0 || strcmp(fname, "..") == 0)
    return SDL_ENUM_CONTINUE;
  lua_pushstring(ctx->L, fname);
  lua_rawseti(ctx->L, -2, ++ctx->n);
  return SDL_ENUM_CONTINUE;
}

static int l_file_list(lua_State* L) {
  const char* dir = luaL_checkstring(L, 1);
  lua_newtable(L);
  ListCtx ctx = {L, 0};
  SDL_EnumerateDirectory(dir, list_cb, &ctx);
  lua_pushinteger(L, ctx.n);
  return 2;
}

static int l_file_dirname(lua_State* L) {
  lua_pushstring(L, path_dirname(luaL_checkstring(L, 1)));
  return 1;
}
static int l_file_basename(lua_State* L) {
  lua_pushstring(L, path_basename(luaL_checkstring(L, 1)));
  return 1;
}
static int l_file_join(lua_State* L) {
  lua_pushstring(L, path_join(luaL_checkstring(L, 1), luaL_checkstring(L, 2)));
  return 1;
}
static int l_file_rename(lua_State* L) {
  lua_pushboolean(L, SDL_RenamePath(luaL_checkstring(L, 1),
                                    luaL_checkstring(L, 2)));
  return 1;
}
static int l_file_remove_tree(lua_State* L) {
  lua_pushboolean(L, SDL_RemovePath(luaL_checkstring(L, 1)));
  return 1;
}

static int l_file_home(lua_State* L) {
  const char* h = getenv("USERPROFILE");
  if (!h) h = getenv("HOME");
  lua_pushstring(L, h ? h : ".");
  return 1;
}

void file_register(lua_State* L) {
  lua_getglobal(L, "tw");
  lua_newtable(L);
  lua_pushcfunction(L, l_file_read_text);
  lua_setfield(L, -2, "read_text");
  lua_pushcfunction(L, l_file_write_text);
  lua_setfield(L, -2, "write_text");
  lua_pushcfunction(L, l_file_exists);
  lua_setfield(L, -2, "exists");
  lua_pushcfunction(L, l_file_mkdirs);
  lua_setfield(L, -2, "mkdirs");
  lua_pushcfunction(L, l_file_copy);
  lua_setfield(L, -2, "copy");
  lua_pushcfunction(L, l_file_load_image);
  lua_setfield(L, -2, "load_image");
  lua_pushcfunction(L, l_file_save_image);
  lua_setfield(L, -2, "save_image");
  lua_pushcfunction(L, l_file_list);
  lua_setfield(L, -2, "list");
  lua_pushcfunction(L, l_file_dirname);
  lua_setfield(L, -2, "dirname");
  lua_pushcfunction(L, l_file_basename);
  lua_setfield(L, -2, "basename");
  lua_pushcfunction(L, l_file_join);
  lua_setfield(L, -2, "join");
  lua_pushcfunction(L, l_file_rename);
  lua_setfield(L, -2, "rename");
  lua_pushcfunction(L, l_file_remove_tree);
  lua_setfield(L, -2, "remove_tree");
  lua_pushcfunction(L, l_file_home);
  lua_setfield(L, -2, "home");
  lua_setfield(L, -2, "file");
  lua_pop(L, 1);
}
