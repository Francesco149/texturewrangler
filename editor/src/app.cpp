// app.cpp — SDL3 + imgui host: window, renderer, frame loop, events,
// headless screenshot capture, log ring buffer, tw.app.* Lua glue.
#include "editor.h"

#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

#include <SDL3/SDL.h>

#include <imgui.h>
#include <imgui_impl_sdl3.h>
#include <imgui_impl_sdlrenderer3.h>

#include <fonts_embedded.h>

#include <stb_image.h>

extern "C" {
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
}

Image* lua_check_image(lua_State* L, int i);
Image* lua_push_image(lua_State* L, Image* img);

static SDL_Window* g_window = nullptr;
static SDL_Renderer* g_renderer = nullptr;
static bool g_running = true;
static int g_quit_code = 0;

// ── log ring buffer (read by the console panel) ─────────────────────────────
#define LOG_CAP 500
static std::vector<char*> g_log;
static char g_log_buf[4096];

void app_log(const char* fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(g_log_buf, sizeof(g_log_buf), fmt, ap);
  va_end(ap);
  printf("%s\n", g_log_buf);
  fflush(stdout);
  char* copy = strdup(g_log_buf);
  if (g_log.size() >= LOG_CAP) {
    free(g_log[0]);
    g_log.erase(g_log.begin());
  }
  g_log.push_back(copy);
}

void app_quit(int code) {
  g_running = false;
  g_quit_code = code;
}

// ── Lua call helpers (protected) ────────────────────────────────────────────

static void call_lua_void(const char* fname, const char* arg) {
  lua_State* L = lua_state();
  if (!L) return;
  lua_getglobal(L, "tw");
  lua_getfield(L, -1, fname);
  if (!lua_isfunction(L, -1)) {
    lua_pop(L, 2);
    return;
  }
  if (arg) lua_pushstring(L, arg);
  if (lua_pcall(L, arg ? 1 : 0, 0, 0) != LUA_OK) {
    const char* m = lua_tostring(L, -1);
    app_log("ERROR in tw.%s: %s", fname, m ? m : "?");
    lua_pop(L, 1);
  }
  lua_settop(L, 0);
}

// ── screenshot capture (headless --shot and tw.app.screenshot) ──────────────
// Reads the renderer back BEFORE present; writes PNG via stb.

int app_screenshot(const char* path) {
  if (!g_renderer) return -1;
  SDL_Surface* surf = SDL_RenderReadPixels(g_renderer, nullptr);
  if (!surf) {
    app_log("screenshot readback failed: %s", SDL_GetError());
    return -1;
  }
  // Readback format is renderer-dependent; normalize to RGBA32 so the byte
  // copy below (b[0..3] = R,G,B,A) is always correct. SDL3 signature:
  // SDL_ConvertSurface(surface, format) — no flags arg (SDL2 had one).
  SDL_Surface* conv = SDL_ConvertSurface(surf, SDL_PIXELFORMAT_RGBA32);
  SDL_DestroySurface(surf);
  if (!conv) {
    app_log("screenshot format convert failed: %s", SDL_GetError());
    return -1;
  }
  int w = conv->w, h = conv->h;
  Image* img = tex_alloc(w, h);
  if (!img) {
    SDL_DestroySurface(conv);
    return -1;
  }
  for (int y = 0; y < h; y++) {
    const uint8_t* row = (const uint8_t*)conv->pixels + (size_t)y * conv->pitch;
    for (int x = 0; x < w; x++) {
      const uint8_t* b = row + (size_t)x * 4;
      img->px[(size_t)y * w + x] =
          ((uint32_t)b[0] << 24) | ((uint32_t)b[1] << 16) |
          ((uint32_t)b[2] << 8) | (uint32_t)b[3];
    }
  }
  SDL_DestroySurface(conv);
  int rc = file_save_image(path, img);
  tex_free(img);
  return rc;
}

// ── clipboard paste (image) ─────────────────────────────────────────────────
// SDL3 exposes "image/bmp" on Windows (CF_DIB → BMP) and X11; stbi decodes.

static Image* paste_image(void) {
  size_t len = 0;
  void* data = SDL_GetClipboardData("image/bmp", &len);
  if (!data || len == 0) return nullptr;
  int w = 0, h = 0, n = 0;
  stbi_uc* dec = stbi_load_from_memory((const stbi_uc*)data, (int)len, &w, &h,
                                       &n, 4);
  if (!dec) return nullptr;
  Image* img = tex_alloc(w, h);
  if (img) {
    for (int i = 0; i < w * h; i++) {
      img->px[i] = ((uint32_t)dec[i * 4] << 24) | ((uint32_t)dec[i * 4 + 1] << 16) |
                   ((uint32_t)dec[i * 4 + 2] << 8) | (uint32_t)dec[i * 4 + 3];
    }
  }
  stbi_image_free(dec);
  return img;
}

// ── tw.app.* Lua glue ───────────────────────────────────────────────────────

static int l_app_quit(lua_State* L) {
  app_quit((int)luaL_optinteger(L, 1, 0));
  return 0;
}

static int l_app_screenshot(lua_State* L) {
  lua_pushboolean(L, app_screenshot(luaL_checkstring(L, 1)) == 0);
  return 1;
}

static int l_app_paste_image(lua_State* L) {
  lua_push_image(L, paste_image());
  return 1;
}

static int l_app_log_lines(lua_State* L) {
  lua_newtable(L);
  int n = 0;
  for (const char* s : g_log) {
    lua_pushstring(L, s);
    lua_rawseti(L, -2, ++n);
  }
  return 1;
}

static int l_app_os(lua_State* L) {
#ifdef _WIN32
  lua_pushliteral(L, "windows");
#else
  lua_pushliteral(L, "linux");
#endif
  return 1;
}

static int l_app_shot_mode(lua_State* L) {
  lua_pushboolean(L, getenv("TW_SHOT") != nullptr);
  return 1;
}

static int l_app_has_clipboard_image(lua_State* L) {
  size_t len = 0;
  void* data = SDL_GetClipboardData("image/bmp", &len);
  lua_pushboolean(L, data && len > 0);
  return 1;
}

// tw.app.eval(code) -> ok, result_or_error (console REPL)
static int l_app_eval(lua_State* L) {
  const char* code = luaL_checkstring(L, 1);
  char err[4096];
  int rc = lua_run_string(code, err, sizeof(err));
  lua_pushboolean(L, rc == 0);
  lua_pushstring(L, err);
  return 2;
}

// native open-file dialog → routes the picked path through tw.on_drop
// (same import path as drag&drop). SDL3 fires the callback on the main
// thread while events are pumped.
struct DlgCtx {
  char path[2048];
};
static void dialog_cb(void* userdata, const char* const* files, int filter) {
  (void)filter;
  if (files && files[0]) call_lua_void("on_drop", files[0]);
  SDL_free(userdata);
}

static int l_app_open_file_dialog(lua_State* L) {
  (void)L;
  // SDL3 filter patterns are a semicolon-separated list of extensions
  // ("png;jpg"), NOT comma-separated — commas fail SDL's pattern
  // validation and the dialog errors out before opening.
  static const SDL_DialogFileFilter filters[] = {
      {"Images", "png;jpg;jpeg;bmp;tga;gif;webp"},
      {"All files", "*"}};
  DlgCtx* ctx = (DlgCtx*)SDL_malloc(sizeof(DlgCtx));
  ctx->path[0] = 0;
  // The Linux dialog needs the xdg-desktop-portal (absent under WSLg), so
  // it can fail silently — report the failure so Lua can fall back to the
  // in-app file browser. NOTE: on the validation-error path SDL calls the
  // callback SYNCHRONOUSLY with files=NULL, so dialog_cb already freed ctx
  // when we get here — free only in the callback, never here (a second
  // SDL_free was a double free → heap corruption/crash on Ctrl+U).
  SDL_ClearError();
  SDL_ShowOpenFileDialog(dialog_cb, ctx, g_window, filters, 2, nullptr, false);
  const char* err = SDL_GetError();
  if (err && err[0]) {
    app_log("native file dialog unavailable: %s", err);
    lua_pushboolean(L, 0);
    return 1;
  }
  lua_pushboolean(L, 1);
  return 1;
}

// tw.app.open_folder(path) — reveal a directory in the OS file manager
static int l_app_open_folder(lua_State* L) {
  const char* path = luaL_checkstring(L, 1);
  char uri[2048];
  // path may already be an http(s)/file URL; else wrap it
  if (strncmp(path, "http://", 7) == 0 || strncmp(path, "https://", 8) == 0 ||
      strncmp(path, "file://", 7) == 0) {
    snprintf(uri, sizeof(uri), "%s", path);
  } else {
    snprintf(uri, sizeof(uri), "file://%s", path);
  }
  if (!SDL_OpenURL(uri)) {
    app_log("open folder failed: %s", SDL_GetError());
    lua_pushboolean(L, 0);
    return 1;
  }
  lua_pushboolean(L, 1);
  return 1;
}

void app_register(lua_State* L) {
  lua_getglobal(L, "tw");
  lua_newtable(L);
  lua_pushcfunction(L, l_app_quit);
  lua_setfield(L, -2, "quit");
  lua_pushcfunction(L, l_app_screenshot);
  lua_setfield(L, -2, "screenshot");
  lua_pushcfunction(L, l_app_paste_image);
  lua_setfield(L, -2, "paste_image");
  lua_pushcfunction(L, l_app_log_lines);
  lua_setfield(L, -2, "log_lines");
  lua_pushcfunction(L, l_app_os);
  lua_setfield(L, -2, "os");
  lua_pushcfunction(L, l_app_shot_mode);
  lua_setfield(L, -2, "shot_mode");
  lua_pushcfunction(L, l_app_has_clipboard_image);
  lua_setfield(L, -2, "has_clipboard_image");
  lua_pushcfunction(L, l_app_eval);
  lua_setfield(L, -2, "eval");
  lua_pushcfunction(L, l_app_open_file_dialog);
  lua_setfield(L, -2, "open_file_dialog");
  lua_pushcfunction(L, l_app_open_folder);
  lua_setfield(L, -2, "open_folder");
  lua_setfield(L, -2, "app");
  lua_pop(L, 1);
}

// ── main loop ───────────────────────────────────────────────────────────────

int app_main(int argc, char** argv) {
  // parse args
  const char* shot_path = nullptr;
  int frames = 60;
  for (int i = 1; i < argc; i++) {
    if (strcmp(argv[i], "--shot") == 0 && i + 1 < argc) shot_path = argv[++i];
    else if (strcmp(argv[i], "--frames") == 0 && i + 1 < argc) frames = atoi(argv[++i]);
  }
  if (frames < 1) frames = 1;

  if (!SDL_Init(SDL_INIT_VIDEO | SDL_INIT_EVENTS)) {
    app_log("SDL_Init failed: %s", SDL_GetError());
    return 1;
  }

  int win_w = 1280, win_h = 800;
  uint32_t wflags = SDL_WINDOW_RESIZABLE | SDL_WINDOW_HIGH_PIXEL_DENSITY;
  g_window = SDL_CreateWindow("texturewrangler", win_w, win_h, wflags);
  if (!g_window) {
    app_log("SDL_CreateWindow failed: %s", SDL_GetError());
    SDL_Quit();
    return 1;
  }
  g_renderer = SDL_CreateRenderer(g_window, nullptr);
  if (!g_renderer) {
    app_log("SDL_CreateRenderer failed: %s", SDL_GetError());
    return 1;
  }
  // vsync caps the interactive frame rate at the display refresh (was
  // running at ~3000 fps). SDL3 has no CreateRenderer flags — it's a
  // separate call. TW_SHOT is set before SDL init in main.cpp; offscreen
  // drivers have no refresh to sync to, so skip it there.
  if (!getenv("TW_SHOT")) {
    if (!SDL_SetRenderVSync(g_renderer, 1)) {
      app_log("SDL_SetRenderVSync failed: %s", SDL_GetError());
    }
  }
  app_set_renderer(g_renderer);

  IMGUI_CHECKVERSION();
  ImGui::CreateContext();
  ImGuiIO& io = ImGui::GetIO();
  io.IniFilename = nullptr; // no imgui.ini — layout is ours
  io.ConfigFlags |= ImGuiConfigFlags_NavEnableKeyboard;

  // fonts baked in by tools/embed.py: 0 = UI (Inter), 1 = titles, 2 = mono
  {
    ImFontConfig cfg;
    cfg.OversampleH = cfg.OversampleV = 2;
    cfg.PixelSnapH = true;
    cfg.FontDataOwnedByAtlas = false; // embedded static arrays, never free
    ImFont* ui = io.Fonts->AddFontFromMemoryTTF((void*)font_ui, font_ui_len,
                                                16.0f, &cfg);
    ImFont* title = io.Fonts->AddFontFromMemoryTTF((void*)font_ui, font_ui_len,
                                                   20.0f, &cfg);
    ImFont* mono = io.Fonts->AddFontFromMemoryTTF((void*)font_mono, font_mono_len,
                                                  14.0f, &cfg);
    (void)ui;
    (void)title;
    (void)mono;
  }

  ImGui_ImplSDL3_InitForSDLRenderer(g_window, g_renderer);
  ImGui_ImplSDLRenderer3_Init(g_renderer);

  app_log("texturewrangler started (sdl %d.%d.%d)", SDL_MAJOR_VERSION,
          SDL_MINOR_VERSION, SDL_MICRO_VERSION);

  int frame = 0;
  while (g_running) {
    // events
    SDL_Event e;
    while (SDL_PollEvent(&e)) {
      ImGui_ImplSDL3_ProcessEvent(&e);
      if (e.type == SDL_EVENT_QUIT) g_running = false;
      else if (e.type == SDL_EVENT_DROP_FILE) {
        call_lua_void("on_drop", e.drop.data);
        SDL_free((void*)e.drop.data);
      }
    }

    ImGui_ImplSDLRenderer3_NewFrame();
    ImGui_ImplSDL3_NewFrame();
    ImGui::NewFrame();

    lua_frame();

    ImGui::Render();
    SDL_SetRenderDrawColorFloat(g_renderer, 0.08f, 0.08f, 0.1f, 1.0f);
    SDL_RenderClear(g_renderer);
    ImGui_ImplSDLRenderer3_RenderDrawData(ImGui::GetDrawData(), g_renderer);
    SDL_RenderPresent(g_renderer);

    frame++;
    if (shot_path && frame >= frames) {
      if (app_screenshot(shot_path) == 0) app_log("shot written: %s", shot_path);
      g_running = false;
      g_quit_code = 0;
    }
  }

  ImGui_ImplSDLRenderer3_Shutdown();
  ImGui_ImplSDL3_Shutdown();
  ImGui::DestroyContext();
  SDL_DestroyRenderer(g_renderer);
  SDL_DestroyWindow(g_window);
  SDL_Quit();

  for (char* s : g_log) free(s);
  g_log.clear();

  return g_quit_code;
}
