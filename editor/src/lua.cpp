// lua.cpp — embedded Lua 5.4: VM lifecycle, module registration, error
// capture. All product logic lives in editor/lua/; this file is the thin
// host. Errors never crash the app: frame errors are logged and the last
// good state keeps rendering.
#include "editor.h"

#include <cstdarg>
#include <cstdio>
#include <cstring>

extern "C" {
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
}

void tex_register(lua_State* L);
void kernels_register(lua_State* L);
void ig_register(lua_State* L);
void file_register(lua_State* L);
void app_register(lua_State* L);

static lua_State* g_L = nullptr;
static char g_lua_dir[1024] = {0};
static char g_tests_dir[1024] = {0};

lua_State* lua_state(void) { return g_L; }

// ── logging ─────────────────────────────────────────────────────────────────
// tw.log(...) routes to app_log (stdout + the in-app console). Panics are
// traced. `tw.log_error` is used by the test suite and console.

static int l_log(lua_State* L) {
  int n = lua_gettop(L);
  lua_getglobal(L, "tostring");
  for (int i = 1; i <= n; i++) {
    lua_pushvalue(L, -1); // tostring
    lua_pushvalue(L, i);
    lua_call(L, 1, 1);
    const char* s = lua_tostring(L, -1);
    if (s) app_log("%s%s", i > 1 ? " " : "", s);
    lua_pop(L, 1);
  }
  return 0;
}

static int l_log_error(lua_State* L) {
  const char* s = luaL_checkstring(L, 1);
  app_log("ERROR: %s", s);
  return 0;
}

// ── protected frame call ────────────────────────────────────────────────────

static void traceback(lua_State* L) {
  lua_getglobal(L, "debug");
  lua_getfield(L, -1, "traceback");
  lua_pushvalue(L, 1);
  lua_pcall(L, 1, 1, 0);
  const char* s = lua_tostring(L, -1);
  app_log("%s", s ? s : "(no traceback)");
  lua_pop(L, 2);
}

void lua_frame(void) {
  if (!g_L) return;
  lua_getglobal(g_L, "tw");
  lua_getfield(g_L, -1, "frame");
  if (lua_pcall(g_L, 0, 0, 0) != LUA_OK) {
    traceback(g_L);
  }
  lua_settop(g_L, 0);
}

// ── console eval ────────────────────────────────────────────────────────────

int lua_run_string(const char* code, char* err, size_t errsz) {
  if (!g_L) return -1;
  int base = lua_gettop(g_L);
  if (luaL_loadstring(g_L, code) != LUA_OK) {
    const char* m = lua_tostring(g_L, -1);
    if (err && errsz) snprintf(err, errsz, "%s", m ? m : "parse error");
    lua_settop(g_L, base);
    return 1;
  }
  if (lua_pcall(g_L, 0, 1, 0) != LUA_OK) {
    const char* m = lua_tostring(g_L, -1);
    if (err && errsz) snprintf(err, errsz, "%s", m ? m : "runtime error");
    lua_settop(g_L, base);
    return 1;
  }
  // push result (if any) as string
  if (!lua_isnoneornil(g_L, -1)) {
    lua_getglobal(g_L, "tostring");
    lua_pushvalue(g_L, -2);
    lua_call(g_L, 1, 1);
    const char* s = lua_tostring(g_L, -1);
    if (err && errsz) snprintf(err, errsz, "%s", s ? s : "");
    lua_pop(g_L, 1);
  } else if (err && errsz) {
    err[0] = 0;
  }
  lua_settop(g_L, base);
  return 0;
}

// ── bootstrap ───────────────────────────────────────────────────────────────

void lua_init(const char* lua_dir, int argc, char** argv) {
  if (g_L) return;
  snprintf(g_lua_dir, sizeof(g_lua_dir), "%s", lua_dir);
  snprintf(g_tests_dir, sizeof(g_tests_dir), "%s/../tests", lua_dir);

  g_L = luaL_newstate();
  if (!g_L) {
    app_log("ERROR: failed to create Lua state");
    return;
  }
  luaL_openlibs(g_L);

  // tw table + subtables (register functions fill them)
  lua_newtable(g_L);
  lua_setglobal(g_L, "tw");
  lua_getglobal(g_L, "tw");
  const char* subs[] = {"tex", "gfx", "ig", "file", "app"};
  for (const char* sub : subs) {
    lua_newtable(g_L);
    lua_setfield(g_L, -2, sub);
  }
  lua_pop(g_L, 1);

  // package.path: lua dir + tests dir, with .lua extension
  char path[2048];
  snprintf(path, sizeof(path), "%s/?.lua;%s/?.lua;%s/?.lua;;", lua_dir,
           g_tests_dir, lua_dir);
  lua_getglobal(g_L, "package");
  lua_pushstring(g_L, path);
  lua_setfield(g_L, -2, "path");
  lua_pop(g_L, 1);

  // tw.args = {...} (argv after the exe name)
  lua_getglobal(g_L, "tw");
  lua_newtable(g_L);
  for (int i = 1; i < argc; i++) {
    lua_pushstring(g_L, argv[i]);
    lua_rawseti(g_L, -2, i);
  }
  lua_setfield(g_L, -2, "args");
  lua_pop(g_L, 1);

  // modules
  tex_register(g_L);
  kernels_register(g_L);
  ig_register(g_L);
  file_register(g_L);
  app_register(g_L);

  // logging
  lua_getglobal(g_L, "tw");
  lua_pushcfunction(g_L, l_log);
  lua_setfield(g_L, -2, "log");
  lua_pushcfunction(g_L, l_log_error);
  lua_setfield(g_L, -2, "log_error");
  lua_pop(g_L, 1);

  // bootstrap: main.lua (app) or testmain.lua (--test)
  const char* boot = "main";
  for (int i = 1; i < argc; i++)
    if (strcmp(argv[i], "--test") == 0) boot = "testmain";

  char chunk[1200];
  snprintf(chunk, sizeof(chunk),
           "local ok, err = pcall(function() return require('%s') end)\n"
           "if not ok then\n"
           "  io.stderr:write('BOOT ERROR: ' .. tostring(err) .. '\\n')\n"
           "  local tb = debug.traceback(err, 2)\n"
           "  io.stderr:write(tb .. '\\n')\n"
           "  os.exit(1)\n"
           "end",
           boot);
  if (luaL_dostring(g_L, chunk) != LUA_OK) {
    const char* m = lua_tostring(g_L, -1);
    app_log("ERROR: lua init: %s", m ? m : "unknown");
    lua_settop(g_L, 0);
  }
}

void lua_shutdown(void) {
  if (g_L) {
    lua_close(g_L);
    g_L = nullptr;
  }
}
