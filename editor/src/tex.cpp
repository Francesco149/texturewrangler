// tex.cpp — Image buffer lifecycle, Lua image userdata, GPU texture upload.
#include "editor.h"

#include <cstdlib>
#include <cstring>

#include <SDL3/SDL.h>

extern "C" {
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
}

// ── buffer lifecycle ────────────────────────────────────────────────────────

Image* tex_alloc(int w, int h) {
  if (w <= 0 || h <= 0) return nullptr;
  Image* img = (Image*)calloc(1, sizeof(Image));
  if (!img) return nullptr;
  img->w = w;
  img->h = h;
  img->px = (uint32_t*)malloc(sizeof(uint32_t) * (size_t)w * (size_t)h);
  if (!img->px) {
    free(img);
    return nullptr;
  }
  return img;
}

Image* tex_clone(const Image* src) {
  if (!src) return nullptr;
  Image* img = tex_alloc(src->w, src->h);
  if (img) memcpy(img->px, src->px, sizeof(uint32_t) * (size_t)src->w * src->h);
  return img;
}

void tex_free(Image* img) {
  if (!img) return;
  free(img->px);
  free(img);
}

void tex_clear(Image* img, uint32_t rgba) {
  if (!img) return;
  for (int i = 0; i < img->w * img->h; i++) img->px[i] = rgba;
}

uint32_t tex_pixel(const Image* img, int x, int y) {
  if (x < 0) x = 0;
  if (y < 0) y = 0;
  if (x >= img->w) x = img->w - 1;
  if (y >= img->h) y = img->h - 1;
  return img->px[(size_t)y * img->w + x];
}

void tex_set(Image* img, int x, int y, uint32_t rgba) {
  if (x < 0 || y < 0 || x >= img->w || y >= img->h) return;
  img->px[(size_t)y * img->w + x] = rgba;
}

// ── Lua image userdata ──────────────────────────────────────────────────────
// type tw.Image: light wrapper over an owned Image*. All kernels and IO
// functions accept it; __gc frees it. Immutable by convention (kernels
// return fresh images); k_stamp is the one mutable path and it owns its
// target (never shared).

static const char* IMG_MT = "tw.Image";

Image* lua_check_image(lua_State* L, int i) {
  Image** p = (Image**)luaL_checkudata(L, i, IMG_MT);
  luaL_argcheck(L, p && *p, i, "expected tw.Image");
  return *p;
}

static int l_image_gc(lua_State* L) {
  Image** p = (Image**)luaL_checkudata(L, 1, IMG_MT);
  if (p && *p) {
    tex_free(*p);
    *p = nullptr;
  }
  return 0;
}

Image* lua_push_image(lua_State* L, Image* img) {
  if (!img) {
    lua_pushnil(L);
    return nullptr;
  }
  Image** p = (Image**)lua_newuserdatauv(L, sizeof(Image*), 0);
  *p = img;
  luaL_setmetatable(L, IMG_MT);
  return img;
}

// tw.tex.new(w, h[, rgba]) -> img
static int l_tex_new(lua_State* L) {
  int w = (int)luaL_checkinteger(L, 1);
  int h = (int)luaL_checkinteger(L, 2);
  uint32_t c = 0x00000000;
  if (lua_gettop(L) >= 3) {
    if (lua_istable(L, 3)) {
      lua_getfield(L, 3, "r");
      lua_getfield(L, 3, "g");
      lua_getfield(L, 3, "b");
      lua_getfield(L, 3, "a");
      int r = (int)lua_tointeger(L, -4), g = (int)lua_tointeger(L, -3);
      int b = (int)lua_tointeger(L, -2), a = (int)lua_tointeger(L, -1);
      c = ((uint32_t)r << 24) | ((uint32_t)g << 16) | ((uint32_t)b << 8) | (uint32_t)a;
      lua_pop(L, 4);
    } else {
      c = (uint32_t)luaL_checkinteger(L, 3);
    }
  }
  Image* img = tex_alloc(w, h);
  if (img) tex_clear(img, c);
  lua_push_image(L, img);
  return 1;
}

// tw.tex.size(img) -> w, h
static int l_tex_size(lua_State* L) {
  Image* img = lua_check_image(L, 1);
  lua_pushinteger(L, img->w);
  lua_pushinteger(L, img->h);
  return 2;
}

// tw.tex.get(img, x, y) -> r, g, b, a   (clamped coords)
static int l_tex_get(lua_State* L) {
  Image* img = lua_check_image(L, 1);
  int x = (int)luaL_checkinteger(L, 2);
  int y = (int)luaL_checkinteger(L, 3);
  uint32_t c = tex_pixel(img, x, y);
  lua_pushinteger(L, (c >> 24) & 0xff);
  lua_pushinteger(L, (c >> 16) & 0xff);
  lua_pushinteger(L, (c >> 8) & 0xff);
  lua_pushinteger(L, c & 0xff);
  return 4;
}

// tw.tex.set(img, x, y, r, g, b, a)
static int l_tex_set(lua_State* L) {
  Image* img = lua_check_image(L, 1);
  int x = (int)luaL_checkinteger(L, 2);
  int y = (int)luaL_checkinteger(L, 3);
  uint32_t c = ((uint32_t)luaL_checkinteger(L, 4) << 24) |
               ((uint32_t)luaL_checkinteger(L, 5) << 16) |
               ((uint32_t)luaL_checkinteger(L, 6) << 8) |
               (uint32_t)luaL_checkinteger(L, 7);
  tex_set(img, x, y, c);
  return 0;
}

// tw.tex.to_string(img) -> "w x h" (debug aid)
static int l_tex_tostring(lua_State* L) {
  Image* img = lua_check_image(L, 1);
  lua_pushfstring(L, "tw.Image(%d x %d)", img->w, img->h);
  return 1;
}

// ── GPU upload ──────────────────────────────────────────────────────────────
// gfx registry: Lua keeps {id=integer} handles; C++ owns the SDL textures.
// Nearest scale mode so pixel art stays crisp; the imgui SDL-renderer
// backend draws with the texture's own scale mode.
struct TexEntry {
  intptr_t id;      // == SDL_Texture* bitcast
  int w, h;
  bool dirty;
  TexEntry* next;
};

static TexEntry* g_tex_head = nullptr;
static intptr_t g_tex_next_id = 0x1000;

static SDL_Renderer* g_renderer = nullptr; // set by app.cpp

void app_set_renderer(SDL_Renderer* r) { g_renderer = r; }

// tw.gfx.register(img) -> id  (create texture)
static int l_gfx_register(lua_State* L) {
  Image* img = lua_check_image(L, 1);
  if (!g_renderer) {
    lua_pushnil(L);
    return 1;
  }
  SDL_Texture* t = SDL_CreateTexture(g_renderer, SDL_PIXELFORMAT_RGBA32,
                                     SDL_TEXTUREACCESS_STATIC, img->w, img->h);
  if (!t) {
    lua_pushnil(L);
    return 1;
  }
  SDL_SetTextureScaleMode(t, SDL_SCALEMODE_NEAREST);
  SDL_UpdateTexture(t, nullptr, img->px, img->w * 4);
  TexEntry* e = (TexEntry*)calloc(1, sizeof(TexEntry));
  e->id = (intptr_t)t;
  e->w = img->w;
  e->h = img->h;
  e->dirty = false;
  e->next = g_tex_head;
  g_tex_head = e;
  lua_pushinteger(L, e->id);
  return 1;
}

// tw.gfx.update(id, img)  (re-upload content, recreate if size changed)
static int l_gfx_update(lua_State* L) {
  intptr_t id = (intptr_t)luaL_checkinteger(L, 1);
  Image* img = lua_check_image(L, 2);
  SDL_Texture* t = (SDL_Texture*)id;
  float fw = 0, fh = 0;
  SDL_GetTextureSize(t, &fw, &fh);
  int w = (int)fw, h = (int)fh;
  if (w != img->w || h != img->h) {
    SDL_DestroyTexture(t);
    t = SDL_CreateTexture(g_renderer, SDL_PIXELFORMAT_RGBA32,
                          SDL_TEXTUREACCESS_STATIC, img->w, img->h);
    SDL_SetTextureScaleMode(t, SDL_SCALEMODE_NEAREST);
    // fix registry entry id
    for (TexEntry* e = g_tex_head; e; e = e->next) {
      if (e->id == id) {
        e->id = (intptr_t)t;
        e->w = img->w;
        e->h = img->h;
        break;
      }
    }
    id = (intptr_t)t;
  }
  SDL_UpdateTexture(t, nullptr, img->px, img->w * 4);
  lua_pushinteger(L, id);
  return 1;
}

// tw.gfx.release(id)
static int l_gfx_release(lua_State* L) {
  intptr_t id = (intptr_t)luaL_checkinteger(L, 1);
  TexEntry** pp = &g_tex_head;
  while (*pp) {
    if ((*pp)->id == id) {
      TexEntry* e = *pp;
      *pp = e->next;
      SDL_DestroyTexture((SDL_Texture*)id);
      free(e);
      break;
    }
    pp = &(*pp)->next;
  }
  return 0;
}

void gfx_free_tex(intptr_t id) {
  if (!id) return;
  SDL_DestroyTexture((SDL_Texture*)id);
}

// ── registration ────────────────────────────────────────────────────────────

void tex_register(lua_State* L) {
  luaL_newmetatable(L, IMG_MT);
  lua_pushcfunction(L, l_image_gc);
  lua_setfield(L, -2, "__gc");
  lua_pushcfunction(L, l_tex_tostring);
  lua_setfield(L, -2, "__tostring");
  lua_pop(L, 1);

  lua_getglobal(L, "tw");
  lua_getfield(L, -1, "tex");
  lua_pushcfunction(L, l_tex_new);
  lua_setfield(L, -2, "new");
  lua_pushcfunction(L, l_tex_size);
  lua_setfield(L, -2, "size");
  lua_pushcfunction(L, l_tex_get);
  lua_setfield(L, -2, "get");
  lua_pushcfunction(L, l_tex_set);
  lua_setfield(L, -2, "set");
  lua_pushcfunction(L, l_tex_tostring);
  lua_setfield(L, -2, "tostring");
  lua_pop(L, 1);

  lua_getfield(L, -1, "gfx");
  lua_pushcfunction(L, l_gfx_register);
  lua_setfield(L, -2, "register");
  lua_pushcfunction(L, l_gfx_update);
  lua_setfield(L, -2, "update");
  lua_pushcfunction(L, l_gfx_release);
  lua_setfield(L, -2, "release");
  lua_pop(L, 2);
}
