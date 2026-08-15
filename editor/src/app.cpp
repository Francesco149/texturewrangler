// app.cpp — SDL3 + imgui host: window, renderer, frame loop, events,
// headless screenshot capture, log ring buffer, tw.app.* Lua glue.
#include "editor.h"

#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <csignal>
#include <vector>

#include <SDL3/SDL.h>

#include <imgui.h>
#include <imgui_impl_sdl3.h>
#include <imgui_impl_sdlrenderer3.h>

#include <fonts_embedded.h>

#include <stb_image.h>

#ifndef __MINGW32__
#include <execinfo.h>
#endif

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

// ── crash trail ─────────────────────────────────────────────────────────────
// Every log line is ALSO written to <exe dir>/texturewrangler-debug.log and
// crash handlers append the exception + a stack, so a hard crash leaves
// evidence even with no console attached. On Windows the exception is
// CONTINUED so WER can write a local minidump (see ORIENTATION.md).
static FILE* g_log_file = nullptr;

#ifdef _WIN32
#include <windows.h>
#include <io.h>
typedef USHORT(WINAPI* RtlCaptureStackBackTrace_t)(ULONG, ULONG, PVOID*,
                                                   PULONG);
static void dump_stack_win(FILE* f) {
  HMODULE ntdll = GetModuleHandleA("ntdll.dll");
  if (!ntdll) return;
  auto fn = (RtlCaptureStackBackTrace_t)GetProcAddress(
      ntdll, "RtlCaptureStackBackTrace");
  if (!fn) return;
  PVOID bt[40];
  USHORT n = fn(0, 40, bt, NULL);
  uintptr_t base = (uintptr_t)GetModuleHandleA(NULL);
  fprintf(f, "  module base: 0x%zx\n", (size_t)base);
  for (USHORT i = 0; i < n; i++)
    fprintf(f, "  #%d 0x%zx (rva 0x%zx)\n", (int)i, (size_t)bt[i],
            (size_t)bt[i] - base);
}
static LONG WINAPI seh_handler(EXCEPTION_POINTERS* ep) {
  fprintf(g_log_file ? g_log_file : stderr,
          "\n==== CRASH: exception 0x%08lx at 0x%p ====\n",
          ep->ExceptionRecord->ExceptionCode,
          ep->ExceptionRecord->ExceptionAddress);
  if (g_log_file) {
    dump_stack_win(g_log_file);
    fflush(g_log_file);
  }
  // continue so WER writes the local dump
  return EXCEPTION_CONTINUE_SEARCH;
}
// vectored exception handler: logs fatal exceptions with a stack (heap
// corruption 0xC0000374 is detected at the NEXT alloc after the damage, so
// the code may be far from the fault). The exception is CONTINUED so WER
// still writes a local minidump for full-stack analysis.
static LONG WINAPI veh_handler(EXCEPTION_POINTERS* ep) {
  DWORD code = ep->ExceptionRecord->ExceptionCode;
  if (code == 0xC0000005 /* AV */ || code == 0xC00000FD /* stack ovf */ ||
      code == 0xC0000374 /* heap corruption */ ||
      code == 0xC0000409 /* fail fast */ || code == 0xC0000094 /* div 0 */) {
    fprintf(g_log_file ? g_log_file : stderr,
            "\n==== CRASH: exception 0x%08lx at 0x%p ====\n", code,
            ep->ExceptionRecord->ExceptionAddress);
    if (g_log_file) {
      dump_stack_win(g_log_file);
      fflush(g_log_file);
    }
  }
  return EXCEPTION_CONTINUE_SEARCH;
}
#endif

static void crash_handler(int sig) {
  printf("\n==== CRASH: signal %d ====\n", sig);
  fflush(stdout);
  if (g_log_file) {
    fprintf(g_log_file, "\n==== CRASH: signal %d ====\n", sig);
#ifndef __MINGW32__
    void* bt[32];
    int n = backtrace(bt, 32);
    backtrace_symbols_fd(bt, n, fileno(g_log_file));
#endif
    fflush(g_log_file);
  }
  _Exit(1);
}

void app_log(const char* fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(g_log_buf, sizeof(g_log_buf), fmt, ap);
  va_end(ap);
  printf("%s\n", g_log_buf);
  fflush(stdout);
  if (g_log_file) {
    fprintf(g_log_file, "%s\n", g_log_buf);
    fflush(g_log_file);
  }
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
  if (!dec) {
    // SDL_GetClipboardData's buffer is SDL-owned (SDL_malloc) — free it
    // with SDL_free, not free() (a mismatched free corrupts the heap).
    SDL_free(data);
    return nullptr;
  }
  Image* img = tex_alloc(w, h);
  if (img) {
    for (int i = 0; i < w * h; i++) {
      img->px[i] = ((uint32_t)dec[i * 4] << 24) | ((uint32_t)dec[i * 4 + 1] << 16) |
                   ((uint32_t)dec[i * 4 + 2] << 8) | (uint32_t)dec[i * 4 + 3];
    }
  }
  stbi_image_free(dec);
  // SDL_GetClipboardData's buffer is SDL-owned (SDL_malloc) — free it with
  // SDL_free (not free(); a mismatched free corrupts the heap).
  SDL_free(data);
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
      {"Images", "png;jpg;jpeg;bmp;tga;gif"},
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

  // crash trail: log tee + handlers. The log file lands next to the exe
  // (texturewrangler-debug.log) so hard crashes leave evidence. NOTE:
  // SDL_GetBasePath's buffer is owned by SDL (freed at SDL_Quit) — never
  // SDL_free it (double-free).
  signal(SIGSEGV, crash_handler);
  signal(SIGABRT, crash_handler);
#ifdef _WIN32
  SetUnhandledExceptionFilter(seh_handler);
  AddVectoredExceptionHandler(1, veh_handler);
#endif
  if (const char* base = SDL_GetBasePath()) {
    char lp[1024];
    snprintf(lp, sizeof(lp), "%stexturewrangler-debug.log", base);
    g_log_file = fopen(lp, "a");
    if (g_log_file) app_log("log file: %s", lp);
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
        // SDL3 owns e.drop.data: it is an SDL_CreateTemporaryString, freed
        // automatically by SDL's event processing. Do NOT SDL_free it —
        // the app freeing it is a DOUBLE-FREE (heap corruption crash on
        // Windows; the string is ~100 bytes, the same class as the
        // Lua-object blocks the GC freed, which pointed us at the wrong
        // suspect for a long time).
        call_lua_void("on_drop", e.drop.data);
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
