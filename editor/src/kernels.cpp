// kernels.cpp — RGBA8 pixel kernels + their Lua glue (tw.tex.*).
//
// All kernels are pure: inputs never mutate, results are fresh images
// (caller frees). Deterministic for a given seed — the test suite relies
// on exact outputs. Straight (non-premultiplied) alpha throughout.
//
// Pixel layout: 0xRRGGBBAA. Helpers unpack to float4 0..1 on demand.

#include "editor.h"

#include <cmath>
#include <cstdlib>
#include <cstring>

extern "C" {
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
}

Image* lua_check_image(lua_State* L, int i);
Image* lua_push_image(lua_State* L, Image* img);

// ── color helpers ───────────────────────────────────────────────────────────

static inline void unpack(uint32_t c, float* r, float* g, float* b, float* a) {
  *r = ((c >> 24) & 0xff) / 255.0f;
  *g = ((c >> 16) & 0xff) / 255.0f;
  *b = ((c >> 8) & 0xff) / 255.0f;
  *a = (c & 0xff) / 255.0f;
}

static inline uint32_t pack(float r, float g, float b, float a) {
  auto q = [](float v) -> uint32_t {
    v = v < 0 ? 0 : (v > 1 ? 1 : v);
    return (uint32_t)(v * 255.0f + 0.5f);
  };
  return (q(r) << 24) | (q(g) << 16) | (q(b) << 8) | q(a);
}

static inline float clampf(float v, float lo, float hi) {
  return v < lo ? lo : (v > hi ? hi : v);
}

// rgb 0..1 ↔ hsl (h 0..360, s/l 0..1)
static void rgb2hsl(float r, float g, float b, float* h, float* s, float* l) {
  float mx = r > g ? (r > b ? r : b) : (g > b ? g : b);
  float mn = r < g ? (r < b ? r : b) : (g < b ? g : b);
  float d = mx - mn;
  *l = (mx + mn) * 0.5f;
  if (d < 1e-6f) {
    *h = 0;
    *s = 0;
    return;
  }
  *s = *l > 0.5f ? d / (2.0f - mx - mn) : d / (mx + mn);
  if (mx == r) *h = 60.0f * fmodf((g - b) / d, 6.0f);
  else if (mx == g) *h = 60.0f * ((b - r) / d + 2.0f);
  else *h = 60.0f * ((r - g) / d + 4.0f);
  if (*h < 0) *h += 360.0f;
}

static float hsl_hue2rgb(float p, float q, float t) {
  if (t < 0) t += 1;
  if (t > 1) t -= 1;
  if (t < 1.0f / 6.0f) return p + (q - p) * 6.0f * t;
  if (t < 0.5f) return q;
  if (t < 2.0f / 3.0f) return p + (q - p) * (2.0f / 3.0f - t) * 6.0f;
  return p;
}

static void hsl2rgb(float h, float s, float l, float* r, float* g, float* b) {
  if (s < 1e-6f) {
    *r = *g = *b = l;
    return;
  }
  float q = l < 0.5f ? l * (1.0f + s) : l + s - l * s;
  float p = 2.0f * l - q;
  float hh = h / 360.0f;
  *r = hsl_hue2rgb(p, q, hh + 1.0f / 3.0f);
  *g = hsl_hue2rgb(p, q, hh);
  *b = hsl_hue2rgb(p, q, hh - 1.0f / 3.0f);
}

// ── samplers (clamp edge) ───────────────────────────────────────────────────

static inline uint32_t fetch_clamp(const Image* s, int x, int y) {
  if (x < 0) x = 0;
  if (y < 0) y = 0;
  if (x >= s->w) x = s->w - 1;
  if (y >= s->h) y = s->h - 1;
  return s->px[(size_t)y * s->w + x];
}

static void sample_bilinear(const Image* s, float fx, float fy, float* r,
                            float* g, float* b, float* a) {
  if (fx < 0) fx = 0;
  if (fy < 0) fy = 0;
  if (fx > s->w - 1) fx = (float)(s->w - 1);
  if (fy > s->h - 1) fy = (float)(s->h - 1);
  int x0 = (int)fx, y0 = (int)fy;
  int x1 = x0 + 1 < s->w ? x0 + 1 : x0;
  int y1 = y0 + 1 < s->h ? y0 + 1 : y0;
  float tx = fx - x0, ty = fy - y0;
  float c00[4], c10[4], c01[4], c11[4];
  unpack(fetch_clamp(s, x0, y0), &c00[0], &c00[1], &c00[2], &c00[3]);
  unpack(fetch_clamp(s, x1, y0), &c10[0], &c10[1], &c10[2], &c10[3]);
  unpack(fetch_clamp(s, x0, y1), &c01[0], &c01[1], &c01[2], &c01[3]);
  unpack(fetch_clamp(s, x1, y1), &c11[0], &c11[1], &c11[2], &c11[3]);
  for (int i = 0; i < 4; i++) {
    float top = c00[i] * (1 - tx) + c10[i] * tx;
    float bot = c01[i] * (1 - tx) + c11[i] * tx;
    float v = top * (1 - ty) + bot * ty;
    if (i == 0) *r = v; else if (i == 1) *g = v; else if (i == 2) *b = v; else *a = v;
  }
}

static float cubic_w(float t) { // Catmull-Rom
  if (t < 0) t = -t;
  float t2 = t * t, t3 = t2 * t;
  return 0.5f * (2 * t2 - t3 + (t < 1 ? (2 - 3 * t2 + t3) : (4 - 8 * t + 5 * t2 - t3)));
}

static void sample_catmull(const Image* s, float fx, float fy, float* r,
                           float* g, float* b, float* a) {
  int x0 = (int)floorf(fx) - 1, y0 = (int)floorf(fy) - 1;
  float acc[4] = {0, 0, 0, 0}, wsum = 0;
  for (int j = 0; j < 4; j++) {
    float wy = cubic_w(fy - (y0 + j));
    for (int i = 0; i < 4; i++) {
      float wx = cubic_w(fx - (x0 + i));
      float w = wx * wy;
      float c[4];
      unpack(fetch_clamp(s, x0 + i, y0 + j), &c[0], &c[1], &c[2], &c[3]);
      for (int k = 0; k < 4; k++) acc[k] += c[k] * w;
      wsum += w;
    }
  }
  if (wsum > 0) for (int k = 0; k < 4; k++) acc[k] /= wsum;
  *r = acc[0]; *g = acc[1]; *b = acc[2]; *a = acc[3];
}

// ── resize ──────────────────────────────────────────────────────────────────

Image* k_resize(const Image* src, int w, int h, const char* filter) {
  if (!src || w <= 0 || h <= 0) return nullptr;
  Image* out = tex_alloc(w, h);
  if (!out) return nullptr;
  bool bilinear = strcmp(filter, "bilinear") == 0;
  bool bicubic = strcmp(filter, "bicubic") == 0;
  bool aniso = strcmp(filter, "aniso") == 0 || strcmp(filter, "anisotropic") == 0;
  // box/aniso: area average (downscale); upscale falls back to bilinear
  bool box = strcmp(filter, "box") == 0;
  bool is_down = w <= src->w && h <= src->h;

  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      uint32_t c;
      if (!bilinear && !bicubic && !box && !aniso) {
        // nearest: center-aligned source coordinate
        int sx = (int)floorf((x + 0.5f) * src->w / w - 0.5f);
        int sy = (int)floorf((y + 0.5f) * src->h / h - 0.5f);
        c = fetch_clamp(src, sx, sy);
      } else if (bicubic) {
        float fx = (x + 0.5f) * src->w / w - 0.5f;
        float fy = (y + 0.5f) * src->h / h - 0.5f;
        float r, g, b, a;
        sample_catmull(src, fx, fy, &r, &g, &b, &a);
        c = pack(r, g, b, a);
      } else if (box && is_down) {
        // exact area average over the source box
        int x0 = (int)((int64_t)x * src->w / w), x1 = (int)((int64_t)(x + 1) * src->w / w);
        int y0 = (int)((int64_t)y * src->h / h), y1 = (int)((int64_t)(y + 1) * src->h / h);
        if (x1 <= x0) x1 = x0 + 1;
        if (y1 <= y0) y1 = y0 + 1;
        double acc[4] = {0, 0, 0, 0};
        for (int sy = y0; sy < y1; sy++)
          for (int sx = x0; sx < x1; sx++) {
            float c4[4];
            unpack(fetch_clamp(src, sx, sy), &c4[0], &c4[1], &c4[2], &c4[3]);
            for (int k = 0; k < 4; k++) acc[k] += c4[k];
          }
        double n = (double)(x1 - x0) * (y1 - y0);
        c = pack((float)(acc[0] / n), (float)(acc[1] / n), (float)(acc[2] / n),
                 (float)(acc[3] / n));
      } else if (aniso && is_down) {
        // anisotropic approx: area coverage via 2x2 bilinear taps per box
        float x0f = (float)x * src->w / w, x1f = (float)(x + 1) * src->w / w;
        float y0f = (float)y * src->h / h, y1f = (float)(y + 1) * src->h / h;
        float acc[4] = {0, 0, 0, 0};
        for (int sj = 0; sj < 2; sj++)
          for (int si = 0; si < 2; si++) {
            float fx = x0f + (x1f - x0f) * (si + 0.25f) / 2.0f;
            float fy = y0f + (y1f - y0f) * (sj + 0.25f) / 2.0f;
            float r, g, b, a;
            sample_bilinear(src, fx - 0.5f, fy - 0.5f, &r, &g, &b, &a);
            acc[0] += r; acc[1] += g; acc[2] += b; acc[3] += a;
          }
        c = pack(acc[0] * 0.25f, acc[1] * 0.25f, acc[2] * 0.25f, acc[3] * 0.25f);
      } else {
        float fx = (x + 0.5f) * src->w / w - 0.5f;
        float fy = (y + 0.5f) * src->h / h - 0.5f;
        float r, g, b, a;
        sample_bilinear(src, fx, fy, &r, &g, &b, &a);
        c = pack(r, g, b, a);
      }
      out->px[(size_t)y * w + x] = c;
    }
  }
  return out;
}

// ── blur (separable) ────────────────────────────────────────────────────────

Image* k_blur(const Image* src, float radius, const char* type) {
  if (!src) return nullptr;
  int r = (int)ceilf(radius);
  if (r < 1) return tex_clone(src);
  bool gauss = strcmp(type, "gaussian") == 0;

  Image* tmp = tex_alloc(src->w, src->h);
  Image* out = tex_alloc(src->w, src->h);
  if (!tmp || !out) {
    tex_free(tmp);
    tex_free(out);
    return nullptr;
  }

  // kernel
  int ksz = gauss ? (int)(radius * 3.0f) * 2 + 1 : r * 2 + 1;
  if (ksz < 1) ksz = 1;
  float* kern = (float*)malloc(sizeof(float) * ksz);
  float ksum = 0;
  if (gauss) {
    float sigma = radius;
    for (int i = 0; i < ksz; i++) {
      float d = i - ksz / 2;
      kern[i] = expf(-(d * d) / (2 * sigma * sigma));
      ksum += kern[i];
    }
  } else {
    for (int i = 0; i < ksz; i++) kern[i] = 1.0f;
    ksum = (float)ksz;
  }
  for (int i = 0; i < ksz; i++) kern[i] /= ksum;

  // horizontal pass: src -> tmp
  for (int y = 0; y < src->h; y++) {
    for (int x = 0; x < src->w; x++) {
      double acc[4] = {0, 0, 0, 0};
      for (int i = 0; i < ksz; i++) {
        int sx = x + i - ksz / 2;
        float c[4];
        unpack(fetch_clamp(src, sx, y), &c[0], &c[1], &c[2], &c[3]);
        for (int k = 0; k < 4; k++) acc[k] += c[k] * kern[i];
      }
      tmp->px[(size_t)y * src->w + x] = pack((float)acc[0], (float)acc[1],
                                             (float)acc[2], (float)acc[3]);
    }
  }
  // vertical pass: tmp -> out
  for (int y = 0; y < src->h; y++) {
    for (int x = 0; x < src->w; x++) {
      double acc[4] = {0, 0, 0, 0};
      for (int i = 0; i < ksz; i++) {
        int sy = y + i - ksz / 2;
        float c[4];
        unpack(fetch_clamp(tmp, x, sy), &c[0], &c[1], &c[2], &c[3]);
        for (int k = 0; k < 4; k++) acc[k] += c[k] * kern[i];
      }
      out->px[(size_t)y * src->w + x] = pack((float)acc[0], (float)acc[1],
                                             (float)acc[2], (float)acc[3]);
    }
  }
  free(kern);
  tex_free(tmp);
  return out;
}

// ── grade ───────────────────────────────────────────────────────────────────

Image* k_grade(const Image* src, float brightness, float contrast, float gamma,
               float saturation, float vibrance, float hue, float temperature,
               float tint, uint32_t colorize, float colorize_strength) {
  if (!src) return nullptr;
  Image* out = tex_alloc(src->w, src->h);
  if (!out) return nullptr;

  // hue rotation matrix (luminance-preserving)
  float hrad = hue * 3.14159265f / 180.0f;
  float ca = cosf(hrad), sa = sinf(hrad);
  const float m[9] = {
      .213f + ca * .787f - sa * .213f, .715f - ca * .715f - sa * .715f,
      .072f - ca * .072f + sa * .928f,
      .213f - ca * .213f + sa * .143f, .715f + ca * .285f + sa * .140f,
      .072f - ca * .072f - sa * .283f,
      .213f - ca * .213f - sa * .787f, .715f - ca * .715f + sa * .715f,
      .072f + ca * .928f + sa * .072f};

  float cr = ((colorize >> 24) & 0xff) / 255.0f;
  float cg = ((colorize >> 16) & 0xff) / 255.0f;
  float cb = ((colorize >> 8) & 0xff) / 255.0f;

  float cont = 1.0f + contrast;
  float gamm = gamma < 0.1f ? 0.1f : gamma;
  float temp = temperature * 0.18f;
  float tnt = tint * 0.18f;

  for (int i = 0; i < src->w * src->h; i++) {
    float r, g, b, a;
    unpack(src->px[i], &r, &g, &b, &a);
    r += temp; b -= temp;          // temperature
    g += tnt;                      // tint (magenta < 0)
    r += brightness; g += brightness; b += brightness;
    r = (r - 0.5f) * cont + 0.5f;  // contrast
    g = (g - 0.5f) * cont + 0.5f;
    b = (b - 0.5f) * cont + 0.5f;
    r = powf(clampf(r, 0, 1), 1.0f / gamm);  // gamma
    g = powf(clampf(g, 0, 1), 1.0f / gamm);
    b = powf(clampf(b, 0, 1), 1.0f / gamm);
    float luma = 0.299f * r + 0.587f * g + 0.114f * b;
    r = luma + (r - luma) * saturation;  // saturation
    g = luma + (g - luma) * saturation;
    b = luma + (b - luma) * saturation;
    float mx = r > g ? (r > b ? r : b) : (g > b ? g : b);
    float mn = r < g ? (r < b ? r : b) : (g < b ? g : b);
    float sat = mx - mn;
    if (vibrance != 0 && sat > 1e-6f) {  // vibrance: boost the desaturated
      float boost = 1.0f + vibrance * (1.0f - sat);
      r = luma + (r - luma) * boost;
      g = luma + (g - luma) * boost;
      b = luma + (b - luma) * boost;
    }
    if (hue != 0) {  // hue rotate
      float nr = r * m[0] + g * m[1] + b * m[2];
      float ng = r * m[3] + g * m[4] + b * m[5];
      float nb = r * m[6] + g * m[7] + b * m[8];
      r = nr; g = ng; b = nb;
    }
    if (colorize_strength > 0) {  // colorize (the video's "color infusion")
      r = r + (cr - r) * colorize_strength;
      g = g + (cg - g) * colorize_strength;
      b = b + (cb - b) * colorize_strength;
    }
    out->px[i] = pack(r, g, b, a);
  }
  return out;
}

// ── palette extraction + quantization ───────────────────────────────────────

struct ColorBox {
  int lo[4], hi[4]; // inclusive index ranges into the sorted color array
};

static int color_cmp_r(const void* a, const void* b) {
  uint32_t ca = *(const uint32_t*)a, cb = *(const uint32_t*)b;
  return (ca >> 24) - (cb >> 24);
}
static int color_cmp_g(const void* a, const void* b) {
  uint32_t ca = *(const uint32_t*)a, cb = *(const uint32_t*)b;
  return ((ca >> 16) & 0xff) - ((cb >> 16) & 0xff);
}
static int color_cmp_b(const void* a, const void* b) {
  uint32_t ca = *(const uint32_t*)a, cb = *(const uint32_t*)b;
  return ((ca >> 8) & 0xff) - ((cb >> 8) & 0xff);
}
static int color_cmp_a(const void* a, const void* b) {
  uint32_t ca = *(const uint32_t*)a, cb = *(const uint32_t*)b;
  return (ca & 0xff) - (cb & 0xff);
}

// median-cut: colors -> palette of `ncolors` entries. Returns 0 on success.
// If the image has fewer unique colors, palette has that many.
// Algorithm: unique colors → sorted copy → recursively split the box with
// the largest per-channel range (re-sorting each box's slice by its widest
// channel at split time) → palette = per-box average.
static int extract_palette(const Image* src, int ncolors, int nch,
                           uint32_t* palette, int* pal_n) {
  // collect unique colors
  int uniq = 0;
  uint32_t* u = (uint32_t*)malloc(sizeof(uint32_t) * (size_t)src->w * src->h);
  if (!u) return -1;
  for (int i = 0; i < src->w * src->h; i++) {
    bool found = false;
    for (int j = 0; j < uniq; j++)
      if (u[j] == src->px[i]) { found = true; break; }
    if (!found) u[uniq++] = src->px[i];
  }
  if (uniq == 0) {
    free(u);
    *pal_n = 0;
    return 0;
  }
  if (uniq <= ncolors) {
    memcpy(palette, u, sizeof(uint32_t) * uniq);
    *pal_n = uniq;
    free(u);
    return 0;
  }

  struct Box { int lo, hi; };
  Box* boxes = (Box*)malloc(sizeof(Box) * (size_t)ncolors * 2);
  if (!boxes) {
    free(u);
    return -1;
  }
  qsort(u, uniq, sizeof(uint32_t), color_cmp_r);
  int nb = 1;
  boxes[0] = {0, uniq - 1};

  // widest channel of a box (bounded by nch)
  auto box_widest = [&](const Box& b, int* range_out) -> int {
    int mn[4] = {255, 255, 255, 255}, mx[4] = {0, 0, 0, 0};
    for (int j = b.lo; j <= b.hi; j++) {
      uint32_t c = u[j];
      for (int k = 0; k < 4; k++) {
        int v = (int)((c >> ((3 - k) * 8)) & 0xff);
        if (v < mn[k]) mn[k] = v;
        if (v > mx[k]) mx[k] = v;
      }
    }
    int best = -1, bestk = 0;
    for (int k = 0; k < nch; k++) {
      int rng = mx[k] - mn[k];
      if (rng > best) {
        best = rng;
        bestk = k;
      }
    }
    *range_out = best;
    return bestk;
  };

  while (nb < ncolors) {
    int best = -1, bi = -1, ch = 0;
    for (int i = 0; i < nb; i++) {
      int rng;
      int c = box_widest(boxes[i], &rng);
      if (rng > best) {
        best = rng;
        bi = i;
        ch = c;
      }
    }
    if (bi < 0 || best <= 0) break; // nothing splittable
    int lo = boxes[bi].lo, hi = boxes[bi].hi;
    qsort(u + lo, hi - lo + 1, sizeof(uint32_t),
          ch == 0 ? color_cmp_r : (ch == 1 ? color_cmp_g
                               : (ch == 2 ? color_cmp_b : color_cmp_a)));
    int mid = (lo + hi + 1) / 2;
    boxes[bi].hi = mid - 1;
    boxes[nb++] = {mid, hi};
  }

  // average each box
  *pal_n = 0;
  for (int i = 0; i < nb; i++) {
    double acc[4] = {0, 0, 0, 0};
    int n = boxes[i].hi - boxes[i].lo + 1;
    if (n <= 0) continue;
    for (int j = boxes[i].lo; j <= boxes[i].hi; j++) {
      acc[0] += (u[j] >> 24) & 0xff;
      acc[1] += (u[j] >> 16) & 0xff;
      acc[2] += (u[j] >> 8) & 0xff;
      acc[3] += u[j] & 0xff;
    }
    palette[*pal_n] = pack((float)(acc[0] / n / 255.0), (float)(acc[1] / n / 255.0),
                           (float)(acc[2] / n / 255.0), (float)(acc[3] / n / 255.0));
    (*pal_n)++;
  }
  free(boxes);
  free(u);
  return 0;
}

static int nearest_pal(const uint32_t* pal, int n, uint32_t c, int nch) {
  int rr = (c >> 24) & 0xff, gg = (c >> 16) & 0xff, bb = (c >> 8) & 0xff;
  int aa = c & 0xff;
  int best = 0;
  int64_t bestd = INT64_MAX;
  for (int i = 0; i < n; i++) {
    int dr = rr - (int)((pal[i] >> 24) & 0xff);
    int dg = gg - (int)((pal[i] >> 16) & 0xff);
    int db = bb - (int)((pal[i] >> 8) & 0xff);
    int da = aa - (int)(pal[i] & 0xff);
    int64_t d = (int64_t)dr * dr + (int64_t)dg * dg + (int64_t)db * db;
    if (nch == 4) d += (int64_t)da * da;
    if (d < bestd) {
      bestd = d;
      best = i;
    }
  }
  return best;
}

// bayer ordered-dither threshold matrices
static const uint8_t BAYER2[4] = {0, 2, 3, 1};
static const uint8_t BAYER4[16] = {0, 8, 2, 10, 12, 4, 14, 6,
                                   3, 11, 1, 9, 15, 7, 13, 5};
static const uint8_t BAYER8[64] = {
    0, 32, 8, 40, 2, 34, 10, 42, 48, 16, 56, 24, 50, 18, 58, 26,
    12, 44, 4, 36, 14, 46, 6, 38, 60, 28, 52, 20, 62, 30, 54, 22,
    3, 35, 11, 43, 1, 33, 9, 41, 51, 19, 59, 27, 49, 17, 57, 25,
    15, 47, 7, 39, 13, 45, 5, 37, 63, 31, 55, 23, 61, 29, 53, 21};

// map with optional dither; returns fresh image
static Image* map_palette_impl(const Image* src, const uint32_t* pal, int n,
                               const char* dither, int nch) {
  Image* out = tex_alloc(src->w, src->h);
  if (!out) return nullptr;
  bool fs = strcmp(dither, "fs") == 0;
  bool atk = strcmp(dither, "atkinson") == 0;
  bool sierra = strcmp(dither, "sierra") == 0;
  bool bayer = strcmp(dither, "bayer2") == 0 || strcmp(dither, "bayer4") == 0 ||
               strcmp(dither, "bayer8") == 0;
  int bayer_n = bayer ? (dither[5] - '0') : 0;

  if (!fs && !atk && !sierra && !bayer) {
    for (int i = 0; i < src->w * src->h; i++) {
      out->px[i] = pal[nearest_pal(pal, n, src->px[i], nch)];
    }
    return out;
  }

  if (bayer) {
    for (int y = 0; y < src->h; y++) {
      for (int x = 0; x < src->w; x++) {
        uint32_t c = src->px[(size_t)y * src->w + x];
        float th = ((bayer_n == 2 ? BAYER2[(y & 1) * 2 + (x & 1)]
                     : bayer_n == 4 ? BAYER4[(y & 3) * 4 + (x & 3)]
                                    : BAYER8[(y & 7) * 8 + (x & 7)]) /
                    (float)(bayer_n * bayer_n)) -
                   0.5f;
        int rr = (int)clampf(((c >> 24) & 0xff) + th * 64, 0, 255);
        int gg = (int)clampf(((c >> 16) & 0xff) + th * 64, 0, 255);
        int bb = (int)clampf(((c >> 8) & 0xff) + th * 64, 0, 255);
        int aa = (c & 0xff);
        uint32_t q = ((uint32_t)rr << 24) | ((uint32_t)gg << 16) |
                     ((uint32_t)bb << 8) | (uint32_t)aa;
        out->px[(size_t)y * src->w + x] = pal[nearest_pal(pal, n, q, nch)];
      }
    }
    return out;
  }

  // error diffusion (serpentine scan)
  float* err = (float*)calloc((size_t)src->w * src->h * 4, sizeof(float));
  if (!err) {
    tex_free(out);
    return nullptr;
  }
  auto dither_pixel = [&](int x, int y, float er, float eg, float eb, float ea,
                          float frac) {
    if (x < 0 || x >= src->w || y < 0 || y >= src->h) return;
    size_t i = ((size_t)y * src->w + x) * 4;
    err[i] += er * frac;
    err[i + 1] += eg * frac;
    err[i + 2] += eb * frac;
    err[i + 3] += ea * frac;
  };
  for (int y = 0; y < src->h; y++) {
    bool ltr = (y & 1) == 0;
    for (int xi = 0; xi < src->w; xi++) {
      int x = ltr ? xi : src->w - 1 - xi;
      size_t idx = (size_t)y * src->w + x;
      float r, g, b, a;
      unpack(src->px[idx], &r, &g, &b, &a);
      size_t ei = idx * 4;
      r += err[ei]; g += err[ei + 1]; b += err[ei + 2]; a += err[ei + 3];
      uint32_t quant = pack(r, g, b, a);
      int pi = nearest_pal(pal, n, quant, nch);
      out->px[idx] = pal[pi];
      float nr, ng, nb, na;
      unpack(out->px[idx], &nr, &ng, &nb, &na);
      float er = r - nr, eg = g - ng, eb = b - nb, ea = a - na;
      int sgn = ltr ? 1 : -1;
      if (fs) {
        dither_pixel(x + sgn, y, er, eg, eb, ea, 7.0f / 16.0f);
        dither_pixel(x - sgn, y + 1, er, eg, eb, ea, 3.0f / 16.0f);
        dither_pixel(x, y + 1, er, eg, eb, ea, 5.0f / 16.0f);
        dither_pixel(x + sgn, y + 1, er, eg, eb, ea, 1.0f / 16.0f);
      } else if (atk) {
        dither_pixel(x + sgn, y, er, eg, eb, ea, 1.0f / 8.0f);
        dither_pixel(x + 2 * sgn, y, er, eg, eb, ea, 1.0f / 8.0f);
        dither_pixel(x - sgn, y + 1, er, eg, eb, ea, 1.0f / 8.0f);
        dither_pixel(x, y + 1, er, eg, eb, ea, 1.0f / 8.0f);
        dither_pixel(x + sgn, y + 1, er, eg, eb, ea, 1.0f / 8.0f);
        dither_pixel(x, y + 2, er, eg, eb, ea, 1.0f / 8.0f);
      } else if (sierra) {
        dither_pixel(x + sgn, y, er, eg, eb, ea, 5.0f / 32.0f);
        dither_pixel(x + 2 * sgn, y, er, eg, eb, ea, 3.0f / 32.0f);
        dither_pixel(x - 2 * sgn, y + 1, er, eg, eb, ea, 2.0f / 32.0f);
        dither_pixel(x - sgn, y + 1, er, eg, eb, ea, 4.0f / 32.0f);
        dither_pixel(x, y + 1, er, eg, eb, ea, 5.0f / 32.0f);
        dither_pixel(x + sgn, y + 1, er, eg, eb, ea, 4.0f / 32.0f);
        dither_pixel(x + 2 * sgn, y + 1, er, eg, eb, ea, 2.0f / 32.0f);
        dither_pixel(x - sgn, y + 2, er, eg, eb, ea, 2.0f / 32.0f);
        dither_pixel(x, y + 2, er, eg, eb, ea, 3.0f / 32.0f);
        dither_pixel(x + sgn, y + 2, er, eg, eb, ea, 2.0f / 32.0f);
      }
    }
  }
  free(err);
  return out;
}

Image* k_quantize(const Image* src, int colors, const char* method,
                  const char* dither, int alpha_mode, uint32_t** pal,
                  int* pal_n) {
  (void)method; // median-cut is the v1 extractor; neuquant later
  *pal = nullptr;
  *pal_n = 0;
  if (!src || colors < 2) return nullptr;
  int nch = alpha_mode ? 4 : 3;
  uint32_t* palette = (uint32_t*)malloc(sizeof(uint32_t) * (size_t)colors);
  if (!palette) return nullptr;
  int n = 0;
  if (extract_palette(src, colors, nch, palette, &n) != 0) {
    free(palette);
    return nullptr;
  }
  if (n == 0) {
    free(palette);
    return tex_clone(src);
  }
  Image* out = map_palette_impl(src, palette, n, dither, nch);
  if (!out) {
    free(palette);
    return nullptr;
  }
  *pal = palette;
  *pal_n = n;
  return out;
}

Image* k_map_palette(const Image* src, const uint32_t* pal, int pal_n,
                     const char* dither, int alpha_mode) {
  if (!src || !pal || pal_n < 1) return nullptr;
  return map_palette_impl(src, pal, pal_n, dither, alpha_mode ? 4 : 3);
}

// ── blend ───────────────────────────────────────────────────────────────────

// W3C compositing: co = αs(1-αb)Cs + αb(1-αs)Cb + αs·αb·B(Cb,Cs); αo = αs+αb(1-αs)
static void blend_modes(const char* mode, bool* use_w3c) {
  *use_w3c = strcmp(mode, "normal") == 0 || strcmp(mode, "multiply") == 0 ||
             strcmp(mode, "screen") == 0 || strcmp(mode, "overlay") == 0 ||
             strcmp(mode, "hardlight") == 0 || strcmp(mode, "softlight") == 0 ||
             strcmp(mode, "darken") == 0 || strcmp(mode, "lighten") == 0 ||
             strcmp(mode, "difference") == 0 || strcmp(mode, "exclusion") == 0 ||
             strcmp(mode, "dodge") == 0 || strcmp(mode, "burn") == 0 ||
             strcmp(mode, "hue") == 0 || strcmp(mode, "saturation") == 0 ||
             strcmp(mode, "color") == 0 || strcmp(mode, "luminosity") == 0;
}

static void blend_fn(const char* mode, float cb[3], float cs[3]) {
  if (strcmp(mode, "normal") == 0) {
    for (int i = 0; i < 3; i++) cb[i] = cs[i]; // B(Cb,Cs) = Cs
  } else if (strcmp(mode, "multiply") == 0) {
    for (int i = 0; i < 3; i++) cb[i] *= cs[i];
  } else if (strcmp(mode, "screen") == 0) {
    for (int i = 0; i < 3; i++) cb[i] = cb[i] + cs[i] - cb[i] * cs[i];
  } else if (strcmp(mode, "overlay") == 0) {
    for (int i = 0; i < 3; i++)
      cb[i] = cb[i] <= 0.5f ? 2 * cb[i] * cs[i]
                            : 1 - 2 * (1 - cb[i]) * (1 - cs[i]);
  } else if (strcmp(mode, "hardlight") == 0) {
    for (int i = 0; i < 3; i++)
      cb[i] = cs[i] <= 0.5f ? 2 * cb[i] * cs[i]
                            : 1 - 2 * (1 - cb[i]) * (1 - cs[i]);
  } else if (strcmp(mode, "softlight") == 0) {
    for (int i = 0; i < 3; i++)
      cb[i] = (1 - 2 * cs[i]) * cb[i] * cb[i] + 2 * cs[i] * cb[i];
  } else if (strcmp(mode, "darken") == 0) {
    for (int i = 0; i < 3; i++) cb[i] = cb[i] < cs[i] ? cb[i] : cs[i];
  } else if (strcmp(mode, "lighten") == 0) {
    for (int i = 0; i < 3; i++) cb[i] = cb[i] > cs[i] ? cb[i] : cs[i];
  } else if (strcmp(mode, "difference") == 0) {
    for (int i = 0; i < 3; i++) cb[i] = fabsf(cb[i] - cs[i]);
  } else if (strcmp(mode, "exclusion") == 0) {
    for (int i = 0; i < 3; i++) cb[i] = cb[i] + cs[i] - 2 * cb[i] * cs[i];
  } else if (strcmp(mode, "dodge") == 0) {
    for (int i = 0; i < 3; i++)
      cb[i] = cs[i] >= 1 ? 1 : (cb[i] < 1e-6f ? 0 : cb[i] / (1 - cs[i]));
  } else if (strcmp(mode, "burn") == 0) {
    for (int i = 0; i < 3; i++)
      cb[i] = cs[i] <= 0 ? 0 : (1 - (1 - cb[i]) / cs[i]);
  } else if (strcmp(mode, "hue") == 0 || strcmp(mode, "saturation") == 0 ||
             strcmp(mode, "color") == 0 || strcmp(mode, "luminosity") == 0) {
    float bh, bs, bl, sh, ss, sl;
    rgb2hsl(cb[0], cb[1], cb[2], &bh, &bs, &bl);
    rgb2hsl(cs[0], cs[1], cs[2], &sh, &ss, &sl);
    if (strcmp(mode, "hue") == 0) sh = bh, ss = bs;
    else if (strcmp(mode, "saturation") == 0) ss = bs, sh = bh, sl = bl;
    else if (strcmp(mode, "color") == 0) sl = bl;
    // luminosity: keep bh,bs, take sl
    hsl2rgb(sh, ss, sl, &cb[0], &cb[1], &cb[2]);
  }
}

Image* k_blend(const Image* base, const Image* src, const char* mode,
               float opacity) {
  if (!base || !src) return nullptr;
  if (base->w != src->w || base->h != src->h) return nullptr;
  if (opacity <= 0) return tex_clone(base);
  Image* out = tex_alloc(base->w, base->h);
  if (!out) return nullptr;

  if (strcmp(mode, "alphamask") == 0) {
    for (int i = 0; i < base->w * base->h; i++) {
      float ar, ag, ab, aa;
      unpack(src->px[i], &ar, &ag, &ab, &aa);
      aa *= opacity;
      float br, bg, bb, ba;
      unpack(base->px[i], &br, &bg, &bb, &ba);
      out->px[i] = pack(br * aa, bg * aa, bb * aa, ba * aa);
    }
    return out;
  }
  if (strcmp(mode, "erase") == 0) {
    for (int i = 0; i < base->w * base->h; i++) {
      float ar, ag, ab, aa;
      unpack(src->px[i], &ar, &ag, &ab, &aa);
      float br, bg, bb, ba;
      unpack(base->px[i], &br, &bg, &bb, &ba);
      out->px[i] = pack(br, bg, bb, ba * (1 - aa * opacity));
    }
    return out;
  }
  if (strcmp(mode, "replace") == 0) { // hard replace (used by export layers)
    for (int i = 0; i < base->w * base->h; i++) out->px[i] = src->px[i];
    return out;
  }

  bool w3c = false;
  blend_modes(mode, &w3c);
  if (!w3c) { // unknown mode → normal
    mode = "normal";
    w3c = true;
  }
  for (int i = 0; i < base->w * base->h; i++) {
    float sr, sg, sb, sa, br, bg, bb, ba;
    unpack(src->px[i], &sr, &sg, &sb, &sa);
    unpack(base->px[i], &br, &bg, &bb, &ba);
    sa *= opacity;
    float ao = sa + ba * (1 - sa);
    if (ao <= 1e-6f) {
      out->px[i] = 0;
      continue;
    }
    float cb_orig[3] = {br, bg, bb}, cs[3] = {sr, sg, sb};
    float cb[3] = {br, bg, bb};
    blend_fn(mode, cb, cs); // cb = B(Cb,Cs); normal → Cs
    float co[3];
    for (int k = 0; k < 3; k++) {
      // co = αs(1-αb)Cs + αb(1-αs)Cb + αsαb·B(Cb,Cs);  (Cb = ORIGINAL backdrop)
      co[k] = (sa * (1 - ba) * cs[k] + ba * (1 - sa) * cb_orig[k] +
               sa * ba * cb[k]) / ao;
      if (co[k] < 0) co[k] = 0;
      if (co[k] > 1) co[k] = 1;
    }
    out->px[i] = pack(co[0], co[1], co[2], ao);
  }
  return out;
}

// ── noise ───────────────────────────────────────────────────────────────────

static inline uint32_t hash3(int x, int y, int seed) {
  uint32_t h = (uint32_t)x * 374761393u + (uint32_t)y * 668265263u +
               (uint32_t)seed * 1274126177u;
  h = (h ^ (h >> 13)) * 1274126177u;
  return h ^ (h >> 16);
}

static inline float hash01(int x, int y, int seed) {
  return (hash3(x, y, seed) & 0xffffff) / 16777215.0f;
}

static float value_noise(float fx, float fy, int lx, int ly, int seed) {
  int x0 = (int)floorf(fx), y0 = (int)floorf(fy);
  float tx = fx - x0, ty = fy - y0;
  tx = tx * tx * (3 - 2 * tx); // smoothstep
  ty = ty * ty * (3 - 2 * ty);
  // wrap lattice so the noise tiles with period lx*scale x ly*scale
  auto lat = [&](int x, int y) -> float {
    int wx = x % lx; if (wx < 0) wx += lx;
    int wy = y % ly; if (wy < 0) wy += ly;
    return hash01(wx, wy, seed);
  };
  float v00 = lat(x0, y0), v10 = lat(x0 + 1, y0);
  float v01 = lat(x0, y0 + 1), v11 = lat(x0 + 1, y0 + 1);
  return v00 * (1 - tx) * (1 - ty) + v10 * tx * (1 - ty) +
         v01 * (1 - tx) * ty + v11 * tx * ty;
}

static float perlin_noise(float fx, float fy, int lx, int ly, int seed) {
  int x0 = (int)floorf(fx), y0 = (int)floorf(fy);
  float tx = fx - x0, ty = fy - y0;
  float sx = tx * tx * (3 - 2 * tx), sy = ty * ty * (3 - 2 * ty);
  auto lat = [&](int x, int y) -> uint32_t {
    int wx = x % lx; if (wx < 0) wx += lx;
    int wy = y % ly; if (wy < 0) wy += ly;
    return hash3(wx, wy, seed);
  };
  auto grad = [&](int x, int y, float dx, float dy) -> float {
    uint32_t h = lat(x, y) & 7;
    float gx = (h & 1) ? 1.0f : -1.0f;
    float gy = (h & 2) ? 1.0f : -1.0f;
    if (h & 4) { float t = gx; gx = gy; gy = -t; }
    return gx * dx + gy * dy;
  };
  float n00 = grad(x0, y0, tx, ty), n10 = grad(x0 + 1, y0, tx - 1, ty);
  float n01 = grad(x0, y0 + 1, tx, ty - 1), n11 = grad(x0 + 1, y0 + 1, tx - 1, ty - 1);
  return n00 * (1 - sx) * (1 - sy) + n10 * sx * (1 - sy) + n01 * (1 - sx) * sy +
         n11 * sx * sy;
}

Image* k_noise(int w, int h, const char* type, float scale, int octaves,
               int seed, uint32_t tint, int colorize_mode, int alpha_from) {
  if (w <= 0 || h <= 0) return nullptr;
  Image* out = tex_alloc(w, h);
  if (!out) return nullptr;
  bool perlin = strcmp(type, "perlin") == 0;
  bool fbm = strcmp(type, "fbm") == 0;
  float sc = scale < 1 ? 1 : scale;
  int lx = (int)ceilf(w / sc), ly = (int)ceilf(h / sc);
  if (lx < 1) lx = 1;
  if (ly < 1) ly = 1;
  if (octaves < 1) octaves = 1;
  float tr = ((tint >> 24) & 0xff) / 255.0f;
  float tg = ((tint >> 16) & 0xff) / 255.0f;
  float tb = ((tint >> 8) & 0xff) / 255.0f;

  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      float fx = (float)x / sc, fy = (float)y / sc;
      float n = 0;
      if (fbm) {
        float amp = 1, freq = 1, sum = 0, norm = 0;
        for (int o = 0; o < octaves; o++) {
          n += amp * value_noise(fx * freq, fy * freq, lx * (int)freq,
                                 ly * (int)freq, seed + o * 131);
          sum += amp;
          amp *= 0.5f;
          freq *= 2;
        }
        n = n / sum;
      } else {
        n = perlin ? perlin_noise(fx, fy, lx, ly, seed)
                   : value_noise(fx, fy, lx, ly, seed);
        if (perlin) n = n * 0.5f + 0.5f;
      }
      float a = alpha_from ? n : 1.0f;
      float r = n, g = n, b = n;
      if (colorize_mode == 1) { // tinted
        r = r + (tr - r) * 0.6f;
        g = g + (tg - g) * 0.6f;
        b = b + (tb - b) * 0.6f;
      }
      out->px[(size_t)y * w + x] = pack(r, g, b, a);
    }
  }
  return out;
}

// ── seamless tiling ─────────────────────────────────────────────────────────

Image* k_seamless(const Image* src, int blend, const char* mode) {
  if (!src) return nullptr;
  bool bleed = strcmp(mode, "bleed") == 0;
  int offx = bleed ? 1 : src->w / 2;
  int offy = bleed ? 1 : src->h / 2;
  if (offx < 1) offx = 1;
  if (offy < 1) offy = 1;
  int b = blend < 0 ? 0 : blend;
  if (b > src->w / 2) b = src->w / 2;
  if (b > src->h / 2) b = src->h / 2;
  if (b < 1) return tex_clone(src);
  Image* out = tex_alloc(src->w, src->h);
  if (!out) return nullptr;
  for (int y = 0; y < src->h; y++) {
    for (int x = 0; x < src->w; x++) {
      // mask: 1 at the four edges, feathering to 0 over `b` px
      float wx = 0, wy = 0;
      if (x < b) wx = (float)(b - x) / b;
      else if (x >= src->w - b) wx = (float)(x - (src->w - b) + 1) / b;
      if (y < b) wy = (float)(b - y) / b;
      else if (y >= src->h - b) wy = (float)(y - (src->h - b) + 1) / b;
      float w = wx > wy ? wx : wy;
      if (w <= 0) {
        out->px[(size_t)y * src->w + x] = src->px[(size_t)y * src->w + x];
        continue;
      }
      int sx = (x + offx) % src->w, sy = (y + offy) % src->h;
      uint32_t a = src->px[(size_t)y * src->w + x];
      uint32_t q = src->px[(size_t)sy * src->w + sx];
      float ar, ag, ab, aa, qr, qg, qb, qa;
      unpack(a, &ar, &ag, &ab, &aa);
      unpack(q, &qr, &qg, &qb, &qa);
      out->px[(size_t)y * src->w + x] =
          pack(ar * (1 - w) + qr * w, ag * (1 - w) + qg * w,
               ab * (1 - w) + qb * w, aa * (1 - w) + qa * w);
    }
  }
  return out;
}

// ── fill / gradient ─────────────────────────────────────────────────────────

Image* k_fill(int w, int h, const char* type, uint32_t c0, uint32_t c1,
              float angle, float cx, float cy, float rx, float ry) {
  if (w <= 0 || h <= 0) return nullptr;
  Image* out = tex_alloc(w, h);
  if (!out) return nullptr;
  float r0[4], r1[4];
  unpack(c0, &r0[0], &r0[1], &r0[2], &r0[3]);
  unpack(c1, &r1[0], &r1[1], &r1[2], &r1[3]);
  bool solid = strcmp(type, "solid") == 0;
  bool linear = strcmp(type, "linear") == 0;
  bool radial = strcmp(type, "radial") == 0;
  bool conic = strcmp(type, "conic") == 0;
  float ca = cosf(angle * 3.14159265f / 180.0f), sa = sinf(angle * 3.14159265f / 180.0f);
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      float t = 0;
      if (solid) {
        t = 0; // solid → c0
      } else if (linear) {
        float dx = x - cx, dy = y - cy;
        t = (dx * ca + dy * sa) / (rx > 0 ? rx : 1);
      } else if (radial) {
        float dx = (x - cx) / (rx > 0 ? rx : 1), dy = (y - cy) / (ry > 0 ? ry : 1);
        t = sqrtf(dx * dx + dy * dy);
      } else if (conic) {
        t = (atan2f((float)(y - cy), (float)(x - cx)) / 6.2831853f) + 0.5f + angle / 360.0f;
        t = t - floorf(t); // conic wraps
      } else {
        // linear / radial: clamp 0..1
        if (t < 0) t = 0;
        if (t > 1) t = 1;
      }
      float r = r0[0] + (r1[0] - r0[0]) * t;
      float g = r0[1] + (r1[1] - r0[1]) * t;
      float b = r0[2] + (r1[2] - r0[2]) * t;
      float a = r0[3] + (r1[3] - r0[3]) * t;
      out->px[(size_t)y * w + x] = pack(r, g, b, a);
    }
  }
  return out;
}

// ── paint stamp ─────────────────────────────────────────────────────────────

void k_stamp(Image* dst, float cx, float cy, float radius, float hardness,
             uint32_t color, const Image* stamp, float stamp_scale, int mode) {
  if (!dst) return;
  float cr = ((color >> 24) & 0xff) / 255.0f;
  float cg = ((color >> 16) & 0xff) / 255.0f;
  float cb = ((color >> 8) & 0xff) / 255.0f;
  float ca = (color & 0xff) / 255.0f;

  if (stamp) {
    // stamp drawn into a box of stamp_scale px
    float box = stamp_scale > 1 ? stamp_scale : 1;
    float sx0 = cx - box / 2, sy0 = cy - box / 2;
    int x0 = (int)floorf(sx0), y0 = (int)floorf(sy0);
    int x1 = (int)ceilf(sx0 + box), y1 = (int)ceilf(sy0 + box);
    for (int y = y0; y <= y1; y++) {
      for (int x = x0; x <= x1; x++) {
        if (x < 0 || y < 0 || x >= dst->w || y >= dst->h) continue;
        float u = (x - sx0) / box * stamp->w;
        float v = (y - sy0) / box * stamp->h;
        float sr, sg, sb, sa;
        sample_bilinear(stamp, u - 0.5f, v - 0.5f, &sr, &sg, &sb, &sa);
        float cov = sa * ca;
        if (cov <= 0) continue;
        size_t i = (size_t)y * dst->w + x;
        if (mode == 1) { // erase
          float da = (dst->px[i] & 0xff) / 255.0f;
          float na = da * (1 - cov);
          dst->px[i] = (dst->px[i] & 0xffffff00u) | (uint32_t)(na * 255.0f + 0.5f);
          continue;
        }
        // max-alpha accumulate: paint never darkens overlaps
        float da = (dst->px[i] & 0xff) / 255.0f;
        float nr = cr * sr, ng = cg * sg, nb = cb * sb;
        if (cov >= da) {
          dst->px[i] = pack(nr, ng, nb, cov);
        }
      }
    }
    return;
  }

  // soft circle
  float hd = 1.0f - hardness;
  if (hd < 0.01f) hd = 0.01f;
  int x0 = (int)floorf(cx - radius), y0 = (int)floorf(cy - radius);
  int x1 = (int)ceilf(cx + radius), y1 = (int)ceilf(cy + radius);
  for (int y = y0; y <= y1; y++) {
    for (int x = x0; x <= x1; x++) {
      if (x < 0 || y < 0 || x >= dst->w || y >= dst->h) continue;
      float dx = x + 0.5f - cx, dy = y + 0.5f - cy;
      float d = sqrtf(dx * dx + dy * dy) / radius;
      if (d >= 1) continue;
      float cov = (1 - d) / hd;
      if (cov > 1) cov = 1;
      cov *= ca;
      if (cov <= 0) continue;
      size_t i = (size_t)y * dst->w + x;
      if (mode == 1) {
        float da = (dst->px[i] & 0xff) / 255.0f;
        float na = da * (1 - cov);
        dst->px[i] = (dst->px[i] & 0xffffff00u) | (uint32_t)(na * 255.0f + 0.5f);
        continue;
      }
      float da = (dst->px[i] & 0xff) / 255.0f;
      if (cov >= da) {
        dst->px[i] = pack(cr, cg, cb, cov);
      }
    }
  }
}

// ── stats ───────────────────────────────────────────────────────────────────

void k_stats(const Image* src, double* avg, int* unique, int* minmax) {
  if (!src) {
    for (int i = 0; i < 4; i++) avg[i] = 0;
    *unique = 0;
    for (int i = 0; i < 8; i++) minmax[i] = 0;
    return;
  }
  double sum[4] = {0, 0, 0, 0};
  int mm[4][2] = {{255, 0}, {255, 0}, {255, 0}, {255, 0}};
  // unique count via simple open-addressing set
  int cap = 1 << 16;
  uint32_t* set = (uint32_t*)calloc(cap, sizeof(uint32_t));
  int uniq = 0;
  for (int i = 0; i < src->w * src->h; i++) {
    uint32_t c = src->px[i];
    sum[0] += (c >> 24) & 0xff;
    sum[1] += (c >> 16) & 0xff;
    sum[2] += (c >> 8) & 0xff;
    sum[3] += c & 0xff;
    for (int k = 0; k < 4; k++) {
      int v = (c >> ((3 - k) * 8)) & 0xff;
      if (v < mm[k][0]) mm[k][0] = v;
      if (v > mm[k][1]) mm[k][1] = v;
    }
    uint32_t h = (c * 2654435761u) & (cap - 1);
    while (set[h] != 0 && set[h] != c) h = (h + 1) & (cap - 1);
    if (set[h] == 0) {
      set[h] = c;
      uniq++;
    }
  }
  free(set);
  double n = (double)(src->w * src->h);
  for (int i = 0; i < 4; i++) avg[i] = sum[i] / n;
  *unique = uniq;
  for (int k = 0; k < 4; k++) {
    minmax[k * 2] = mm[k][0];
    minmax[k * 2 + 1] = mm[k][1];
  }
}

// ── Lua glue ────────────────────────────────────────────────────────────────

static const char* opt_string(lua_State* L, int i, const char* def) {
  return lua_isnoneornil(L, i) ? def : luaL_checkstring(L, i);
}

static uint32_t check_color(lua_State* L, int i) {
  int ai = lua_absindex(L, i);
  luaL_checktype(L, ai, LUA_TTABLE);
  lua_getfield(L, ai, "r");
  lua_getfield(L, ai, "g");
  lua_getfield(L, ai, "b");
  lua_getfield(L, ai, "a");
  int r = (int)luaL_optinteger(L, -4, 255);
  int g = (int)luaL_optinteger(L, -3, 255);
  int b = (int)luaL_optinteger(L, -2, 255);
  int a = (int)luaL_optinteger(L, -1, 255);
  lua_pop(L, 4);
  return ((uint32_t)r << 24) | ((uint32_t)g << 16) | ((uint32_t)b << 8) |
         (uint32_t)a;
}

static void push_color(lua_State* L, uint32_t c) {
  lua_newtable(L);
  lua_pushinteger(L, (c >> 24) & 0xff);
  lua_setfield(L, -2, "r");
  lua_pushinteger(L, (c >> 16) & 0xff);
  lua_setfield(L, -2, "g");
  lua_pushinteger(L, (c >> 8) & 0xff);
  lua_setfield(L, -2, "b");
  lua_pushinteger(L, c & 0xff);
  lua_setfield(L, -2, "a");
}

static int l_k_resize(lua_State* L) {
  Image* img = lua_check_image(L, 1);
  int w = (int)luaL_checkinteger(L, 2);
  int h = (int)luaL_checkinteger(L, 3);
  const char* filter = opt_string(L, 4, "bilinear");
  lua_push_image(L, k_resize(img, w, h, filter));
  return 1;
}

static int l_k_blur(lua_State* L) {
  Image* img = lua_check_image(L, 1);
  float r = (float)luaL_checknumber(L, 2);
  const char* type = opt_string(L, 3, "gaussian");
  lua_push_image(L, k_blur(img, r, type));
  return 1;
}

static int l_k_grade(lua_State* L) {
  Image* img = lua_check_image(L, 1);
  luaL_checktype(L, 2, LUA_TTABLE);
  auto num = [&](const char* k, float def) {
    lua_getfield(L, 2, k);
    float v = lua_isnoneornil(L, -1) ? def : (float)lua_tonumber(L, -1);
    lua_pop(L, 1);
    return v;
  };
  float brightness = num("brightness", 0);
  float contrast = num("contrast", 0);
  float gamma = num("gamma", 1);
  float saturation = num("saturation", 1);
  float vibrance = num("vibrance", 0);
  float hue = num("hue", 0);
  float temperature = num("temperature", 0);
  float tint = num("tint", 0);
  lua_getfield(L, 2, "colorize");
  uint32_t col = 0;
  float strength = 0;
  if (lua_istable(L, -1)) {
    lua_pushvalue(L, -1);
    col = check_color(L, -1);
    lua_pop(L, 1);
    lua_getfield(L, -2, "colorize_strength");
    strength = (float)luaL_optnumber(L, -1, 0);
    lua_pop(L, 1);
  }
  lua_pop(L, 1);
  lua_push_image(L, k_grade(img, brightness, contrast, gamma, saturation,
                            vibrance, hue, temperature, tint, col, strength));
  return 1;
}

static int l_k_quantize(lua_State* L) {
  Image* img = lua_check_image(L, 1);
  int colors = (int)luaL_checkinteger(L, 2);
  const char* method = opt_string(L, 3, "mediancut");
  const char* dither = opt_string(L, 4, "none");
  int alpha_mode = luaL_optinteger(L, 5, 0);
  uint32_t* pal = nullptr;
  int n = 0;
  Image* out = k_quantize(img, colors, method, dither, alpha_mode, &pal, &n);
  lua_push_image(L, out);
  lua_newtable(L);
  for (int i = 0; i < n; i++) {
    push_color(L, pal[i]);
    lua_rawseti(L, -2, i + 1);
  }
  free(pal);
  return 2; // img, palette
}

static int l_k_map_palette(lua_State* L) {
  Image* img = lua_check_image(L, 1);
  luaL_checktype(L, 2, LUA_TTABLE);
  int n = (int)lua_rawlen(L, 2);
  if (n < 1) {
    lua_push_image(L, tex_clone(img));
    return 1;
  }
  uint32_t* pal = (uint32_t*)malloc(sizeof(uint32_t) * (size_t)n);
  if (!pal) return luaL_error(L, "oom");
  for (int i = 0; i < n; i++) {
    lua_rawgeti(L, 2, i + 1);
    pal[i] = check_color(L, -1);
    lua_pop(L, 1);
  }
  const char* dither = opt_string(L, 3, "none");
  int alpha_mode = luaL_optinteger(L, 4, 0);
  Image* out = k_map_palette(img, pal, n, dither, alpha_mode);
  free(pal);
  lua_push_image(L, out);
  return 1;
}

static int l_k_blend(lua_State* L) {
  Image* base = lua_check_image(L, 1);
  Image* src = lua_check_image(L, 2);
  const char* mode = opt_string(L, 3, "normal");
  float opacity = (float)luaL_optnumber(L, 4, 1);
  lua_push_image(L, k_blend(base, src, mode, opacity));
  return 1;
}

static int l_k_noise(lua_State* L) {
  int w = (int)luaL_checkinteger(L, 1);
  int h = (int)luaL_checkinteger(L, 2);
  const char* type = opt_string(L, 3, "value");
  float scale = (float)luaL_optnumber(L, 4, 8);
  int octaves = (int)luaL_optinteger(L, 5, 1);
  int seed = (int)luaL_optinteger(L, 6, 0);
  uint32_t tint = 0xffffffff;
  if (lua_istable(L, 7)) tint = check_color(L, 7);
  int cmode = (int)luaL_optinteger(L, 8, 0);
  int afrom = lua_toboolean(L, 9) ? 1 : 0;
  lua_push_image(L, k_noise(w, h, type, scale, octaves, seed, tint, cmode, afrom));
  return 1;
}

static int l_k_seamless(lua_State* L) {
  Image* img = lua_check_image(L, 1);
  int blend = (int)luaL_optinteger(L, 2, 8);
  const char* mode = opt_string(L, 3, "offset");
  lua_push_image(L, k_seamless(img, blend, mode));
  return 1;
}

static int l_k_fill(lua_State* L) {
  int w = (int)luaL_checkinteger(L, 1);
  int h = (int)luaL_checkinteger(L, 2);
  const char* type = opt_string(L, 3, "solid");
  uint32_t c0 = lua_istable(L, 4) ? check_color(L, 4) : 0xffffffff;
  uint32_t c1 = lua_istable(L, 5) ? check_color(L, 5) : 0x00000000;
  float angle = (float)luaL_optnumber(L, 6, 0);
  float cx = (float)luaL_optnumber(L, 7, w / 2.0);
  float cy = (float)luaL_optnumber(L, 8, h / 2.0);
  float rx = (float)luaL_optnumber(L, 9, w);
  float ry = (float)luaL_optnumber(L, 10, h);
  lua_push_image(L, k_fill(w, h, type, c0, c1, angle, cx, cy, rx, ry));
  return 1;
}

static int l_k_stamp(lua_State* L) {
  Image* dst = lua_check_image(L, 1);
  float cx = (float)luaL_checknumber(L, 2);
  float cy = (float)luaL_checknumber(L, 3);
  float radius = (float)luaL_checknumber(L, 4);
  float hardness = (float)luaL_optnumber(L, 5, 0.5);
  uint32_t color = 0xffffffff;
  if (lua_istable(L, 6)) color = check_color(L, 6);
  Image* stamp = nullptr;
  if (lua_isuserdata(L, 7)) stamp = lua_check_image(L, 7);
  float sscale = (float)luaL_optnumber(L, 8, radius * 2);
  int mode = (int)luaL_optinteger(L, 9, 0);
  k_stamp(dst, cx, cy, radius, hardness, color, stamp, sscale, mode);
  return 0;
}

static int l_k_stats(lua_State* L) {
  Image* img = lua_check_image(L, 1);
  double avg[4];
  int unique = 0, mm[8];
  k_stats(img, avg, &unique, mm);
  lua_newtable(L);
  lua_pushnumber(L, avg[0]);
  lua_setfield(L, -2, "r");
  lua_pushnumber(L, avg[1]);
  lua_setfield(L, -2, "g");
  lua_pushnumber(L, avg[2]);
  lua_setfield(L, -2, "b");
  lua_pushnumber(L, avg[3]);
  lua_setfield(L, -2, "a");
  lua_pushinteger(L, unique);
  lua_setfield(L, -2, "unique");
  lua_pushinteger(L, mm[0]);
  lua_setfield(L, -2, "min_r");
  lua_pushinteger(L, mm[1]);
  lua_setfield(L, -2, "max_r");
  lua_pushinteger(L, mm[2]);
  lua_setfield(L, -2, "min_g");
  lua_pushinteger(L, mm[3]);
  lua_setfield(L, -2, "max_g");
  lua_pushinteger(L, mm[4]);
  lua_setfield(L, -2, "min_b");
  lua_pushinteger(L, mm[5]);
  lua_setfield(L, -2, "max_b");
  lua_pushinteger(L, mm[6]);
  lua_setfield(L, -2, "min_a");
  lua_pushinteger(L, mm[7]);
  lua_setfield(L, -2, "max_a");
  return 1;
}

void kernels_register(lua_State* L) {
  lua_getglobal(L, "tw");
  lua_getfield(L, -1, "tex");
  lua_pushcfunction(L, l_k_resize);
  lua_setfield(L, -2, "resize");
  lua_pushcfunction(L, l_k_blur);
  lua_setfield(L, -2, "blur");
  lua_pushcfunction(L, l_k_grade);
  lua_setfield(L, -2, "grade");
  lua_pushcfunction(L, l_k_quantize);
  lua_setfield(L, -2, "quantize");
  lua_pushcfunction(L, l_k_map_palette);
  lua_setfield(L, -2, "map_palette");
  lua_pushcfunction(L, l_k_blend);
  lua_setfield(L, -2, "blend");
  lua_pushcfunction(L, l_k_noise);
  lua_setfield(L, -2, "noise");
  lua_pushcfunction(L, l_k_seamless);
  lua_setfield(L, -2, "seamless");
  lua_pushcfunction(L, l_k_fill);
  lua_setfield(L, -2, "fill");
  lua_pushcfunction(L, l_k_stamp);
  lua_setfield(L, -2, "stamp");
  lua_pushcfunction(L, l_k_stats);
  lua_setfield(L, -2, "stats");
  lua_pop(L, 2);
}
