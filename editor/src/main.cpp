// main.cpp — entry point: arg parsing, lua dir resolution, mode dispatch.
//   texturewrangler                  → interactive editor
//   texturewrangler --project <dir>  → open a project directly
//   texturewrangler --test           → headless Lua test suite (no window)
//   texturewrangler --shot <png> [--frames N] → render UI headless, capture
#include "editor.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>

static bool has_arg(int argc, char** argv, const char* name) {
  for (int i = 1; i < argc; i++)
    if (strcmp(argv[i], name) == 0) return true;
  return false;
}

static const char* arg_value(int argc, char** argv, const char* name,
                             const char* def) {
  for (int i = 1; i < argc - 1; i++)
    if (strcmp(argv[i], name) == 0) return argv[i + 1];
  return def;
}

// find editor/lua next to the binary (dev: build/../editor/lua; standalone:
// exe_dir/lua). Falls back to $TW_ROOT/editor/lua.
static const char* find_lua_dir(const char* argv0) {
  static char dir[2048];
  const char* exe = path_dirname(argv0);
  const char* cands[4] = {path_join(exe, "lua"),
                          path_join(path_join(exe, ".."), "lua"),
                          path_join(path_join(exe, ".."), "editor/lua"),
                          path_join(path_join(path_join(exe, ".."), ".."),
                                    "editor/lua")};
  for (const char* c : cands) {
    // snapshot into dir BEFORE path_join may clobber the ring slot c
    snprintf(dir, sizeof(dir), "%s", c);
    if (file_exists(path_join(c, "main.lua"))) return dir;
  }
  const char* root = getenv("TW_ROOT");
  if (root) {
    snprintf(dir, sizeof(dir), "%s/editor/lua", root);
    if (file_exists(path_join(dir, "main.lua"))) return dir;
  }
  // last resort: cwd/editor/lua (useful when run via `make test`)
  snprintf(dir, sizeof(dir), "%s", path_join("editor", "lua"));
  return dir;
}

int main(int argc, char** argv) {
  if (has_arg(argc, argv, "--test")) {
    // headless: no SDL, no window. testmain.lua runs the suite and calls
    // os.exit(code) with the pass/fail result.
    lua_init(find_lua_dir(argv[0]), argc, argv);
    lua_shutdown();
    return 0;
  }

  if (has_arg(argc, argv, "--shot")) {
    // headless screenshot: offscreen SDL driver, no window stealing
#ifdef _WIN32
    _putenv("SDL_VIDEODRIVER=offscreen");
    _putenv("TW_SHOT=1");
#else
    setenv("SDL_VIDEODRIVER", "offscreen", 1);
    setenv("TW_SHOT", "1", 1);
#endif
  }

  lua_init(find_lua_dir(argv[0]), argc, argv);
  return app_main(argc, argv);
}
