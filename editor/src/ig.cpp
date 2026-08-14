// ig.cpp — Dear ImGui → Lua binding (tw.ig.*).
//
// Deliberately a small, flat surface: windows/children, widgets, tables,
// popups, draw list, style, input state. Everything Lua-side UI needs;
// nothing more. Widget return convention: `changed, value(s)` (changed is
// false when the user didn't touch it this frame). Draw lists are
// lightuserdata handles into a per-frame registry.
#include "editor.h"

#include <string>
#include <vector>

#include <imgui.h>
#include <imgui_stdlib.h>

extern "C" {
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
}

// ── helpers ─────────────────────────────────────────────────────────────────

static ImVec2 check_v2(lua_State* L, int i) {
  return ImVec2((float)luaL_checknumber(L, i), (float)luaL_checknumber(L, i + 1));
}
static void push_v2(lua_State* L, ImVec2 v) {
  lua_pushnumber(L, v.x);
  lua_pushnumber(L, v.y);
}
static ImVec4 check_v4(lua_State* L, int i) {
  return ImVec4((float)luaL_checknumber(L, i), (float)luaL_checknumber(L, i + 1),
                (float)luaL_checknumber(L, i + 2),
                (float)luaL_checknumber(L, i + 3));
}
static void push_v4(lua_State* L, ImVec4 v) {
  lua_pushnumber(L, v.x);
  lua_pushnumber(L, v.y);
  lua_pushnumber(L, v.z);
  lua_pushnumber(L, v.w);
}
static const char* opt_str(lua_State* L, int i, const char* def) {
  return lua_isnoneornil(L, i) ? def : luaL_checkstring(L, i);
}
static bool opt_bool(lua_State* L, int i, bool def) {
  return lua_isnoneornil(L, i) ? def : lua_toboolean(L, i);
}
static ImU32 col32(lua_State* L, int i) {
  float r = (float)luaL_checknumber(L, i);
  float g = (float)luaL_checknumber(L, i + 1);
  float b = (float)luaL_checknumber(L, i + 2);
  float a = luaL_optnumber(L, i + 3, 1);
  return IM_COL32((int)(r * 255), (int)(g * 255), (int)(b * 255), (int)(a * 255));
}

// draw list handles: registry array of ImDrawList*, lightuserdata index
static std::vector<ImDrawList*> g_dl;
static const char* DL_MT = "tw.DrawList";

static ImDrawList* check_dl(lua_State* L, int i) {
  int idx = (int)(intptr_t)lua_touserdata(L, i);
  if (idx < 0 || idx >= (int)g_dl.size()) luaL_error(L, "bad draw list");
  return g_dl[idx];
}
static int l_dl_gc(lua_State* L) {
  (void)L;
  return 0; // registry cleared per frame; handles are borrowed
}

// ── window / layout ─────────────────────────────────────────────────────────

static int l_begin(lua_State* L) {
  const char* name = luaL_checkstring(L, 1);
  ImGuiWindowFlags flags = (ImGuiWindowFlags)luaL_optinteger(L, 2, 0);
  bool open = ImGui::Begin(name, nullptr, flags);
  lua_pushboolean(L, open);
  return 1;
}
static int l_end(lua_State* L) {
  ImGui::End();
  return 0;
}
static int l_begin_child(lua_State* L) {
  const char* name = luaL_checkstring(L, 1);
  float w = (float)luaL_optnumber(L, 2, 0);
  float h = (float)luaL_optnumber(L, 3, 0);
  ImGuiChildFlags cflags = (ImGuiChildFlags)luaL_optinteger(L, 4, 0);
  ImGuiWindowFlags wflags = (ImGuiWindowFlags)luaL_optinteger(L, 5, 0);
  bool open = ImGui::BeginChild(name, ImVec2(w, h), cflags, wflags);
  lua_pushboolean(L, open);
  return 1;
}
static int l_end_child(lua_State* L) {
  ImGui::EndChild();
  return 0;
}
static int l_same_line(lua_State* L) {
  ImGui::SameLine((float)luaL_optnumber(L, 1, 0), (float)luaL_optnumber(L, 2, -1));
  return 0;
}
static int l_separator(lua_State* L) {
  ImGui::Separator();
  return 0;
}
static int l_spacing(lua_State* L) {
  ImGui::Spacing();
  return 0;
}
static int l_dummy(lua_State* L) {
  ImGui::Dummy(ImVec2((float)luaL_checknumber(L, 1), (float)luaL_checknumber(L, 2)));
  return 0;
}
static int l_indent(lua_State* L) {
  ImGui::Indent((float)luaL_optnumber(L, 1, 0));
  return 0;
}
static int l_unindent(lua_State* L) {
  ImGui::Unindent((float)luaL_optnumber(L, 1, 0));
  return 0;
}
static int l_text(lua_State* L) {
  ImGui::TextUnformatted(luaL_checkstring(L, 1));
  return 0;
}
static int l_text_colored(lua_State* L) {
  const char* s = luaL_checkstring(L, 1);
  ImVec4 c((float)luaL_checknumber(L, 2), (float)luaL_checknumber(L, 3),
           (float)luaL_checknumber(L, 4), (float)luaL_checknumber(L, 5));
  ImGui::TextColored(c, "%s", s);
  return 0;
}
static int l_label_text(lua_State* L) {
  ImGui::LabelText("%s", luaL_checkstring(L, 1), "%s", luaL_checkstring(L, 2));
  return 0;
}
static int l_bullet_text(lua_State* L) {
  ImGui::BulletText("%s", luaL_checkstring(L, 1));
  return 0;
}
static int l_align_text(lua_State* L) {
  ImGui::AlignTextToFramePadding();
  return 0;
}
static int l_new_line(lua_State* L) {
  ImGui::NewLine();
  return 0;
}
static int l_begin_group(lua_State* L) {
  ImGui::BeginGroup();
  return 0;
}
static int l_end_group(lua_State* L) {
  ImGui::EndGroup();
  return 0;
}

// ── widgets ─────────────────────────────────────────────────────────────────

static int l_button(lua_State* L) {
  bool hit = ImGui::Button(luaL_checkstring(L, 1),
                           ImVec2((float)luaL_optnumber(L, 2, 0),
                                  (float)luaL_optnumber(L, 3, 0)));
  lua_pushboolean(L, hit);
  return 1;
}
static int l_small_button(lua_State* L) {
  lua_pushboolean(L, ImGui::SmallButton(luaL_checkstring(L, 1)));
  return 1;
}
static int l_arrow_button(lua_State* L) {
  lua_pushboolean(L, ImGui::ArrowButton(luaL_checkstring(L, 1),
                                        (ImGuiDir)luaL_checkinteger(L, 2)));
  return 1;
}
static int l_checkbox(lua_State* L) {
  bool v = lua_toboolean(L, 2);
  bool changed = ImGui::Checkbox(luaL_checkstring(L, 1), &v);
  lua_pushboolean(L, changed);
  lua_pushboolean(L, v);
  return 2;
}
static int l_radio_button(lua_State* L) {
  bool active = lua_toboolean(L, 2);
  if (ImGui::RadioButton(luaL_checkstring(L, 1), active)) {
    lua_pushboolean(L, true);
    return 1;
  }
  lua_pushboolean(L, false);
  return 1;
}
static int l_combo(lua_State* L) {
  const char* label = luaL_checkstring(L, 1);
  luaL_checktype(L, 2, LUA_TTABLE);
  int current = (int)luaL_checkinteger(L, 3);
  int n = (int)lua_rawlen(L, 2);
  if (current < 0) current = 0;
  if (current >= n) current = n - 1;
  const char* preview = "";
  if (n > 0) {
    lua_rawgeti(L, 2, current + 1);
    preview = lua_tostring(L, -1);
  }
  bool changed = false;
  if (ImGui::BeginCombo(label, preview)) {
    for (int i = 0; i < n; i++) {
      lua_rawgeti(L, 2, i + 1);
      const char* item = lua_tostring(L, -1);
      if (ImGui::Selectable(item ? item : "", i == current)) {
        current = i;
        changed = true;
      }
      lua_pop(L, 1);
    }
    ImGui::EndCombo();
  }
  if (n > 0) lua_pop(L, 1);
  lua_pushboolean(L, changed);
  lua_pushinteger(L, current);
  return 2;
}
static int l_slider_float(lua_State* L) {
  float v = (float)luaL_checknumber(L, 2);
  bool changed = ImGui::SliderFloat(luaL_checkstring(L, 1), &v,
                                    (float)luaL_checknumber(L, 3),
                                    (float)luaL_checknumber(L, 4),
                                    opt_str(L, 5, "%.3f"));
  lua_pushboolean(L, changed);
  lua_pushnumber(L, v);
  return 2;
}
static int l_slider_int(lua_State* L) {
  int v = (int)luaL_checkinteger(L, 2);
  bool changed = ImGui::SliderInt(luaL_checkstring(L, 1), &v,
                                  (int)luaL_checkinteger(L, 3),
                                  (int)luaL_checkinteger(L, 4),
                                  opt_str(L, 5, "%d"));
  lua_pushboolean(L, changed);
  lua_pushinteger(L, v);
  return 2;
}
static int l_drag_float(lua_State* L) {
  float v = (float)luaL_checknumber(L, 2);
  bool changed = ImGui::DragFloat(luaL_checkstring(L, 1), &v,
                                  (float)luaL_optnumber(L, 3, 0.01f),
                                  (float)luaL_optnumber(L, 4, 0),
                                  (float)luaL_optnumber(L, 5, 0),
                                  opt_str(L, 6, "%.3f"));
  lua_pushboolean(L, changed);
  lua_pushnumber(L, v);
  return 2;
}
static int l_input_int(lua_State* L) {
  int v = (int)luaL_checkinteger(L, 2);
  bool changed = ImGui::InputInt(luaL_checkstring(L, 1), &v,
                                 (int)luaL_optinteger(L, 3, 1));
  lua_pushboolean(L, changed);
  lua_pushinteger(L, v);
  return 2;
}
static int l_input_float(lua_State* L) {
  float v = (float)luaL_checknumber(L, 2);
  bool changed = ImGui::InputFloat(luaL_checkstring(L, 1), &v,
                                   (float)luaL_optnumber(L, 3, 0.01f));
  lua_pushboolean(L, changed);
  lua_pushnumber(L, v);
  return 2;
}
static int l_input_text(lua_State* L) {
  const char* label = luaL_checkstring(L, 1);
  static std::string buf;
  buf = luaL_checkstring(L, 2);
  int maxlen = (int)luaL_optinteger(L, 3, 1024);
  bool changed = ImGui::InputText(label, &buf, (size_t)maxlen);
  lua_pushboolean(L, changed);
  lua_pushstring(L, buf.c_str());
  return 2;
}
static int l_color_edit4(lua_State* L) {
  float c[4] = {(float)luaL_checknumber(L, 2), (float)luaL_checknumber(L, 3),
                (float)luaL_checknumber(L, 4), (float)luaL_checknumber(L, 5)};
  ImGuiColorEditFlags flags = (ImGuiColorEditFlags)luaL_optinteger(L, 6, 0);
  bool changed = ImGui::ColorEdit4(luaL_checkstring(L, 1), c, flags);
  lua_pushboolean(L, changed);
  for (int i = 0; i < 4; i++) lua_pushnumber(L, c[i]);
  return 5;
}
static int l_color_edit3(lua_State* L) {
  float c[3] = {(float)luaL_checknumber(L, 2), (float)luaL_checknumber(L, 3),
                (float)luaL_checknumber(L, 4)};
  ImGuiColorEditFlags flags = (ImGuiColorEditFlags)luaL_optinteger(L, 5, 0);
  bool changed = ImGui::ColorEdit3(luaL_checkstring(L, 1), c, flags);
  lua_pushboolean(L, changed);
  for (int i = 0; i < 3; i++) lua_pushnumber(L, c[i]);
  return 4;
}
static int l_color_button(lua_State* L) {
  const char* id = luaL_checkstring(L, 1);
  ImVec4 c = check_v4(L, 2);
  bool hit = ImGui::ColorButton(id, c,
                                ImGuiColorEditFlags_NoTooltip | ImGuiColorEditFlags_NoPicker,
                                ImVec2((float)luaL_optnumber(L, 6, 0),
                                       (float)luaL_optnumber(L, 7, 0)));
  lua_pushboolean(L, hit);
  return 1;
}
static int l_set_next_item_width(lua_State* L) {
  ImGui::SetNextItemWidth((float)luaL_checknumber(L, 1));
  return 0;
}
static int l_begin_disabled(lua_State* L) {
  ImGui::BeginDisabled(lua_toboolean(L, 1));
  return 0;
}
static int l_end_disabled(lua_State* L) {
  ImGui::EndDisabled();
  return 0;
}
static int l_progress_bar(lua_State* L) {
  ImGui::ProgressBar((float)luaL_checknumber(L, 1),
                     ImVec2((float)luaL_optnumber(L, 2, 0),
                            (float)luaL_optnumber(L, 3, 0)),
                     lua_isnoneornil(L, 4) ? nullptr : luaL_checkstring(L, 4));
  return 0;
}

// ── tables ──────────────────────────────────────────────────────────────────

static int l_begin_table(lua_State* L) {
  bool open = ImGui::BeginTable(
      luaL_checkstring(L, 1), (int)luaL_checkinteger(L, 2),
      (ImGuiTableFlags)luaL_optinteger(L, 3, 0),
      ImVec2((float)luaL_optnumber(L, 4, 0), (float)luaL_optnumber(L, 5, 0)));
  lua_pushboolean(L, open);
  return 1;
}
static int l_table_setup_column(lua_State* L) {
  ImGui::TableSetupColumn(luaL_checkstring(L, 1),
                          (ImGuiTableColumnFlags)luaL_optinteger(L, 2, 0),
                          (float)luaL_optnumber(L, 3, 0));
  return 0;
}
static int l_table_headers_row(lua_State* L) {
  ImGui::TableHeadersRow();
  return 0;
}
static int l_table_next_row(lua_State* L) {
  ImGui::TableNextRow();
  return 0;
}
static int l_table_set_column_index(lua_State* L) {
  ImGui::TableSetColumnIndex((int)luaL_checkinteger(L, 1));
  return 0;
}
static int l_end_table(lua_State* L) {
  ImGui::EndTable();
  return 0;
}

// ── selectable / tree / list ────────────────────────────────────────────────

static int l_selectable(lua_State* L) {
  bool hit = ImGui::Selectable(
      luaL_checkstring(L, 1), lua_toboolean(L, 2),
      (ImGuiSelectableFlags)luaL_optinteger(L, 3, 0),
      ImVec2((float)luaL_optnumber(L, 4, 0), (float)luaL_optnumber(L, 5, 0)));
  lua_pushboolean(L, hit);
  return 1;
}
static int l_tree_node(lua_State* L) {
  bool open = ImGui::TreeNodeEx(luaL_checkstring(L, 1),
                                ImGuiTreeNodeFlags_DefaultOpen |
                                    (ImGuiTreeNodeFlags)luaL_optinteger(L, 2, 0));
  lua_pushboolean(L, open);
  return 1;
}
static int l_tree_pop(lua_State* L) {
  ImGui::TreePop();
  return 0;
}
static int l_begin_list_box(lua_State* L) {
  bool open = ImGui::BeginListBox(luaL_checkstring(L, 1),
                                  ImVec2((float)luaL_optnumber(L, 2, 0),
                                         (float)luaL_optnumber(L, 3, 0)));
  lua_pushboolean(L, open);
  return 1;
}
static int l_end_list_box(lua_State* L) {
  ImGui::EndListBox();
  return 0;
}

// ── popups / menus / tooltips ───────────────────────────────────────────────

static int l_begin_popup_context_item(lua_State* L) {
  bool open = ImGui::BeginPopupContextItem(
      lua_isnoneornil(L, 1) ? nullptr : luaL_checkstring(L, 1),
      (ImGuiPopupFlags)luaL_optinteger(L, 2, 1));
  lua_pushboolean(L, open);
  return 1;
}
static int l_open_popup(lua_State* L) {
  ImGui::OpenPopup(luaL_checkstring(L, 1));
  return 0;
}
static int l_begin_popup(lua_State* L) {
  bool open = ImGui::BeginPopup(luaL_checkstring(L, 1));
  lua_pushboolean(L, open);
  return 1;
}
static int l_begin_popup_modal(lua_State* L) {
  bool open = ImGui::BeginPopupModal(luaL_checkstring(L, 1), nullptr,
                                     (ImGuiWindowFlags)luaL_optinteger(L, 2, 0));
  lua_pushboolean(L, open);
  return 1;
}
static int l_end_popup(lua_State* L) {
  ImGui::EndPopup();
  return 0;
}
static int l_close_current_popup(lua_State* L) {
  ImGui::CloseCurrentPopup();
  return 0;
}
static int l_begin_menu(lua_State* L) {
  bool open = ImGui::BeginMenu(luaL_checkstring(L, 1), opt_bool(L, 2, true));
  lua_pushboolean(L, open);
  return 1;
}
static int l_menu_item(lua_State* L) {
  bool hit = ImGui::MenuItem(luaL_checkstring(L, 1),
                             lua_isnoneornil(L, 2) ? nullptr : luaL_checkstring(L, 2),
                             lua_toboolean(L, 3), opt_bool(L, 4, true));
  lua_pushboolean(L, hit);
  return 1;
}
static int l_set_tooltip(lua_State* L) {
  ImGui::SetTooltip("%s", luaL_checkstring(L, 1));
  return 0;
}
static int l_begin_tooltip(lua_State* L) {
  ImGui::BeginTooltip();
  return 0;
}
static int l_end_tooltip(lua_State* L) {
  ImGui::EndTooltip();
  return 0;
}

// ── draw list ───────────────────────────────────────────────────────────────

static int push_dl(lua_State* L, ImDrawList* dl) {
  g_dl.push_back(dl);
  lua_pushlightuserdata(L, (void*)(intptr_t)(g_dl.size() - 1));
  luaL_setmetatable(L, DL_MT);
  return 1;
}
static int l_get_window_draw_list(lua_State* L) {
  return push_dl(L, ImGui::GetWindowDrawList());
}
static int l_get_foreground_draw_list(lua_State* L) {
  return push_dl(L, ImGui::GetForegroundDrawList());
}
static int l_dl_add_image(lua_State* L) {
  ImDrawList* dl = check_dl(L, 1);
  ImTextureID tex = (ImTextureID)(intptr_t)luaL_checkinteger(L, 2);
  ImVec2 a((float)luaL_checknumber(L, 3), (float)luaL_checknumber(L, 4));
  ImVec2 b((float)luaL_checknumber(L, 5), (float)luaL_checknumber(L, 6));
  ImVec2 ua((float)luaL_optnumber(L, 7, 0), (float)luaL_optnumber(L, 8, 0));
  ImVec2 ub((float)luaL_optnumber(L, 9, 1), (float)luaL_optnumber(L, 10, 1));
  ImU32 col = IM_COL32_WHITE;
  if (lua_gettop(L) >= 14) col = col32(L, 11);
  dl->AddImage(tex, a, b, ua, ub, col);
  return 0;
}
static int l_dl_add_rect_filled(lua_State* L) {
  ImDrawList* dl = check_dl(L, 1);
  ImVec2 a((float)luaL_checknumber(L, 2), (float)luaL_checknumber(L, 3));
  ImVec2 b((float)luaL_checknumber(L, 4), (float)luaL_checknumber(L, 5));
  ImU32 col = col32(L, 6);
  float rounding = (float)luaL_optnumber(L, 10, 0);
  dl->AddRectFilled(a, b, col, rounding);
  return 0;
}
static int l_dl_add_rect(lua_State* L) {
  ImDrawList* dl = check_dl(L, 1);
  ImVec2 a((float)luaL_checknumber(L, 2), (float)luaL_checknumber(L, 3));
  ImVec2 b((float)luaL_checknumber(L, 4), (float)luaL_checknumber(L, 5));
  ImU32 col = col32(L, 6);
  float rounding = (float)luaL_optnumber(L, 10, 0);
  float thickness = (float)luaL_optnumber(L, 11, 1);
  dl->AddRect(a, b, col, rounding, 0, thickness);
  return 0;
}
static int l_dl_add_line(lua_State* L) {
  ImDrawList* dl = check_dl(L, 1);
  ImVec2 a((float)luaL_checknumber(L, 2), (float)luaL_checknumber(L, 3));
  ImVec2 b((float)luaL_checknumber(L, 4), (float)luaL_checknumber(L, 5));
  ImU32 col = col32(L, 6);
  float thickness = (float)luaL_optnumber(L, 10, 1);
  dl->AddLine(a, b, col, thickness);
  return 0;
}
static int l_dl_add_text(lua_State* L) {
  ImDrawList* dl = check_dl(L, 1);
  ImVec2 pos((float)luaL_checknumber(L, 2), (float)luaL_checknumber(L, 3));
  ImU32 col = col32(L, 4);
  dl->AddText(pos, col, luaL_checkstring(L, 8));
  return 0;
}
static int l_dl_add_circle_filled(lua_State* L) {
  ImDrawList* dl = check_dl(L, 1);
  ImVec2 c((float)luaL_checknumber(L, 2), (float)luaL_checknumber(L, 3));
  float rad = (float)luaL_checknumber(L, 4);
  ImU32 col = col32(L, 5);
  dl->AddCircleFilled(c, rad, col, (int)luaL_optinteger(L, 9, 24));
  return 0;
}
static int l_dl_push_clip_rect(lua_State* L) {
  ImDrawList* dl = check_dl(L, 1);
  ImVec2 a((float)luaL_checknumber(L, 2), (float)luaL_checknumber(L, 3));
  ImVec2 b((float)luaL_checknumber(L, 4), (float)luaL_checknumber(L, 5));
  dl->PushClipRect(a, b, lua_toboolean(L, 6));
  return 0;
}
static int l_dl_pop_clip_rect(lua_State* L) {
  ImDrawList* dl = check_dl(L, 1);
  dl->PopClipRect();
  return 0;
}

// ── style ───────────────────────────────────────────────────────────────────

static int l_push_style_color(lua_State* L) {
  ImGui::PushStyleColor((ImGuiCol)luaL_checkinteger(L, 1), check_v4(L, 2));
  return 0;
}
static int l_pop_style_color(lua_State* L) {
  ImGui::PopStyleColor((int)luaL_optinteger(L, 1, 1));
  return 0;
}
static int l_push_style_var(lua_State* L) {
  ImGuiStyleVar v = (ImGuiStyleVar)luaL_checkinteger(L, 1);
  // imgui asserts if the wrong PushStyleVar variant is used for a var
  auto is_v2 = [](ImGuiStyleVar x) {
    switch (x) {
      case ImGuiStyleVar_WindowPadding:
      case ImGuiStyleVar_WindowMinSize:
      case ImGuiStyleVar_WindowTitleAlign:
      case ImGuiStyleVar_FramePadding:
      case ImGuiStyleVar_ItemSpacing:
      case ImGuiStyleVar_ItemInnerSpacing:
      case ImGuiStyleVar_CellPadding:
      case ImGuiStyleVar_ButtonTextAlign:
      case ImGuiStyleVar_SelectableTextAlign:
      case ImGuiStyleVar_SeparatorTextAlign:
      case ImGuiStyleVar_SeparatorTextPadding:
        return true;
      default:
        return false;
    }
  };
  if (is_v2(v)) {
    ImGui::PushStyleVar(v, check_v2(L, 2));
  } else {
    ImGui::PushStyleVar(v, (float)luaL_checknumber(L, 2));
  }
  return 0;
}
static int l_pop_style_var(lua_State* L) {
  ImGui::PopStyleVar((int)luaL_optinteger(L, 1, 1));
  return 0;
}
static int l_push_font(lua_State* L) {
  int i = (int)luaL_checkinteger(L, 1);
  if (i >= 0 && i < (int)ImGui::GetIO().Fonts->Fonts.Size) {
    ImGui::PushFont(ImGui::GetIO().Fonts->Fonts[i]);
  }
  return 0;
}
static int l_pop_font(lua_State* L) {
  ImGui::PopFont();
  return 0;
}
static int l_has_font(lua_State* L) {
  int i = (int)luaL_checkinteger(L, 1);
  lua_pushboolean(L, i >= 0 && i < (int)ImGui::GetIO().Fonts->Fonts.Size);
  return 1;
}
static int l_set_next_window_pos(lua_State* L) {
  ImGui::SetNextWindowPos(ImVec2((float)luaL_checknumber(L, 1),
                                 (float)luaL_checknumber(L, 2)));
  return 0;
}
static int l_set_next_window_size(lua_State* L) {
  ImGui::SetNextWindowSize(ImVec2((float)luaL_checknumber(L, 1),
                                  (float)luaL_checknumber(L, 2)));
  return 0;
}

// ── state / info ────────────────────────────────────────────────────────────

static int l_is_item_clicked(lua_State* L) {
  lua_pushboolean(L, ImGui::IsItemClicked((ImGuiMouseButton)luaL_optinteger(L, 1, 0)));
  return 1;
}
static int l_is_item_active(lua_State* L) {
  lua_pushboolean(L, ImGui::IsItemActive());
  return 1;
}
static int l_is_item_hovered(lua_State* L) {
  lua_pushboolean(L, ImGui::IsItemHovered());
  return 1;
}
static int l_is_item_edited(lua_State* L) {
  lua_pushboolean(L, ImGui::IsItemEdited());
  return 1;
}
static int l_is_window_hovered(lua_State* L) {
  lua_pushboolean(L, ImGui::IsWindowHovered(
                         (ImGuiHoveredFlags)luaL_optinteger(L, 1, 0)));
  return 1;
}
static int l_is_window_focused(lua_State* L) {
  lua_pushboolean(L, ImGui::IsWindowFocused(
                         (ImGuiFocusedFlags)luaL_optinteger(L, 1, 0)));
  return 1;
}
static int l_is_mouse_down(lua_State* L) {
  lua_pushboolean(L, ImGui::IsMouseDown((ImGuiMouseButton)luaL_checkinteger(L, 1)));
  return 1;
}
static int l_is_mouse_clicked(lua_State* L) {
  lua_pushboolean(L, ImGui::IsMouseClicked((ImGuiMouseButton)luaL_checkinteger(L, 1),
                                           opt_bool(L, 2, false)));
  return 1;
}
static int l_is_mouse_dragging(lua_State* L) {
  lua_pushboolean(L, ImGui::IsMouseDragging((ImGuiMouseButton)luaL_checkinteger(L, 1),
                                            (float)luaL_optnumber(L, 2, 4)));
  return 1;
}
static int l_get_mouse_pos(lua_State* L) {
  ImVec2 p = ImGui::GetMousePos();
  push_v2(L, p);
  return 2;
}
static int l_get_mouse_drag_delta(lua_State* L) {
  ImVec2 d = ImGui::GetMouseDragDelta((ImGuiMouseButton)luaL_checkinteger(L, 1),
                                      (float)luaL_optnumber(L, 2, -1));
  push_v2(L, d);
  return 2;
}
static int l_get_content_region_avail(lua_State* L) {
  push_v2(L, ImGui::GetContentRegionAvail());
  return 2;
}
static int l_get_cursor_pos(lua_State* L) {
  push_v2(L, ImGui::GetCursorPos());
  return 2;
}
static int l_set_cursor_pos(lua_State* L) {
  ImGui::SetCursorPos(ImVec2((float)luaL_checknumber(L, 1),
                             (float)luaL_checknumber(L, 2)));
  return 0;
}
static int l_get_cursor_screen_pos(lua_State* L) {
  push_v2(L, ImGui::GetCursorScreenPos());
  return 2;
}
static int l_get_frame_height(lua_State* L) {
  lua_pushnumber(L, ImGui::GetFrameHeight());
  return 1;
}
static int l_get_frame_height_with_spacing(lua_State* L) {
  lua_pushnumber(L, ImGui::GetFrameHeightWithSpacing());
  return 1;
}
static int l_get_window_pos(lua_State* L) {
  push_v2(L, ImGui::GetWindowPos());
  return 2;
}
static int l_get_window_size(lua_State* L) {
  push_v2(L, ImGui::GetWindowSize());
  return 2;
}
static int l_calc_text_size(lua_State* L) {
  push_v2(L, ImGui::CalcTextSize(luaL_checkstring(L, 1)));
  return 2;
}
static int l_get_text_line_height(lua_State* L) {
  lua_pushnumber(L, ImGui::GetTextLineHeight());
  return 1;
}
static int l_get_font_size(lua_State* L) {
  lua_pushnumber(L, ImGui::GetFontSize());
  return 1;
}
static int l_set_scroll_here_y(lua_State* L) {
  ImGui::SetScrollHereY((float)luaL_optnumber(L, 1, 0.5));
  return 0;
}
static int l_get_scroll_y(lua_State* L) {
  lua_pushnumber(L, ImGui::GetScrollY());
  return 1;
}
static int l_set_scroll_y(lua_State* L) {
  ImGui::SetScrollY((float)luaL_checknumber(L, 1));
  return 0;
}
static int l_get_id(lua_State* L) {
  lua_pushinteger(L, (intptr_t)ImGui::GetID(luaL_checkstring(L, 1)));
  return 1;
}
static int l_push_id(lua_State* L) {
  ImGui::PushID(luaL_checkstring(L, 1));
  return 0;
}
static int l_pop_id(lua_State* L) {
  ImGui::PopID();
  return 0;
}
static int l_is_key_pressed(lua_State* L) {
  lua_pushboolean(L, ImGui::IsKeyPressed((ImGuiKey)luaL_checkinteger(L, 1),
                                         opt_bool(L, 2, false)));
  return 1;
}
static int l_is_key_down(lua_State* L) {
  lua_pushboolean(L, ImGui::IsKeyDown((ImGuiKey)luaL_checkinteger(L, 1)));
  return 1;
}
static int l_get_io(lua_State* L) {
  const ImGuiIO& io = ImGui::GetIO();
  lua_newtable(L);
  lua_pushnumber(L, io.DisplaySize.x);
  lua_setfield(L, -2, "display_w");
  lua_pushnumber(L, io.DisplaySize.y);
  lua_setfield(L, -2, "display_h");
  lua_pushnumber(L, io.DeltaTime);
  lua_setfield(L, -2, "delta_time");
  lua_pushnumber(L, io.MouseWheel);
  lua_setfield(L, -2, "mouse_wheel");
  lua_pushboolean(L, io.WantCaptureMouse);
  lua_setfield(L, -2, "want_capture_mouse");
  lua_pushboolean(L, io.WantCaptureKeyboard);
  lua_setfield(L, -2, "want_capture_keyboard");
  lua_pushboolean(L, io.KeyCtrl);
  lua_setfield(L, -2, "key_ctrl");
  lua_pushboolean(L, io.KeyShift);
  lua_setfield(L, -2, "key_shift");
  lua_pushboolean(L, io.KeyAlt);
  lua_setfield(L, -2, "key_alt");
  lua_pushboolean(L, io.KeySuper);
  lua_setfield(L, -2, "key_super");
  return 1;
}

// ── registration ────────────────────────────────────────────────────────────

#define REG(name) lua_pushcfunction(L, l_##name); lua_setfield(L, -2, #name)

void ig_register(lua_State* L) {
  luaL_newmetatable(L, DL_MT);
  lua_pushcfunction(L, l_dl_gc);
  lua_setfield(L, -2, "__gc");
  lua_pop(L, 1);

  lua_getglobal(L, "tw");
  lua_newtable(L);
  REG(begin);
  lua_pushcfunction(L, l_end);
  lua_setfield(L, -2, "end_");
  REG(begin_child);
  REG(end_child);
  REG(same_line);
  REG(separator);
  REG(spacing);
  REG(dummy);
  REG(indent);
  REG(unindent);
  REG(text);
  REG(text_colored);
  REG(label_text);
  REG(bullet_text);
  REG(align_text);
  REG(new_line);
  REG(begin_group);
  REG(end_group);
  REG(button);
  REG(small_button);
  REG(arrow_button);
  REG(checkbox);
  REG(radio_button);
  REG(combo);
  REG(slider_float);
  REG(slider_int);
  REG(drag_float);
  REG(input_int);
  REG(input_float);
  REG(input_text);
  REG(color_edit4);
  REG(color_edit3);
  REG(color_button);
  REG(set_next_item_width);
  REG(begin_disabled);
  REG(end_disabled);
  REG(progress_bar);
  REG(begin_table);
  REG(table_setup_column);
  REG(table_headers_row);
  REG(table_next_row);
  REG(table_set_column_index);
  REG(end_table);
  REG(selectable);
  REG(tree_node);
  REG(tree_pop);
  REG(begin_list_box);
  REG(end_list_box);
  REG(begin_popup_context_item);
  REG(open_popup);
  REG(begin_popup);
  REG(begin_popup_modal);
  REG(end_popup);
  REG(close_current_popup);
  REG(begin_menu);
  REG(menu_item);
  REG(set_tooltip);
  REG(begin_tooltip);
  REG(end_tooltip);
  REG(get_window_draw_list);
  REG(get_foreground_draw_list);
  REG(dl_add_image);
  REG(dl_add_rect_filled);
  REG(dl_add_rect);
  REG(dl_add_line);
  REG(dl_add_text);
  REG(dl_add_circle_filled);
  REG(dl_push_clip_rect);
  REG(dl_pop_clip_rect);
  REG(push_style_color);
  REG(pop_style_color);
  REG(push_style_var);
  REG(pop_style_var);
  REG(push_font);
  REG(pop_font);
  REG(has_font);
  REG(set_next_window_pos);
  REG(set_next_window_size);
  REG(is_item_clicked);
  REG(is_item_active);
  REG(is_item_hovered);
  REG(is_item_edited);
  REG(is_window_hovered);
  REG(is_window_focused);
  REG(is_mouse_down);
  REG(is_mouse_clicked);
  REG(is_mouse_dragging);
  REG(get_mouse_pos);
  REG(get_mouse_drag_delta);
  REG(get_content_region_avail);
  REG(get_cursor_pos);
  REG(set_cursor_pos);
  REG(get_cursor_screen_pos);
  REG(get_frame_height);
  REG(get_frame_height_with_spacing);
  REG(get_window_pos);
  REG(get_window_size);
  REG(calc_text_size);
  REG(get_text_line_height);
  REG(get_font_size);
  REG(set_scroll_here_y);
  REG(get_scroll_y);
  REG(set_scroll_y);
  REG(get_id);
  REG(push_id);
  REG(pop_id);
  REG(is_key_pressed);
  REG(is_key_down);
  REG(get_io);
  lua_setfield(L, -2, "ig");
  lua_pop(L, 1);

  // key constants (tw.ig.key = {...})
  lua_getglobal(L, "tw");
  lua_getfield(L, -1, "ig");
  lua_newtable(L);
#define KEY(name) lua_pushinteger(L, ImGuiKey_##name); lua_setfield(L, -2, #name)
  KEY(A); KEY(B); KEY(C); KEY(D); KEY(E); KEY(F); KEY(G); KEY(H); KEY(I);
  KEY(J); KEY(K); KEY(L); KEY(M); KEY(N); KEY(O); KEY(P); KEY(Q); KEY(R);
  KEY(S); KEY(T); KEY(U); KEY(V); KEY(W); KEY(X); KEY(Y); KEY(Z);
  KEY(0); KEY(1); KEY(2); KEY(3); KEY(4); KEY(5); KEY(6); KEY(7); KEY(8); KEY(9);
  KEY(F1); KEY(F2); KEY(F3); KEY(F4); KEY(F5); KEY(F6);
  KEY(F7); KEY(F8); KEY(F9); KEY(F10); KEY(F11); KEY(F12);
  KEY(Space); KEY(Enter); KEY(Escape); KEY(Tab); KEY(Delete); KEY(Backspace);
  KEY(UpArrow); KEY(DownArrow); KEY(LeftArrow); KEY(RightArrow); KEY(Home); KEY(End); KEY(PageUp);
  KEY(PageDown); KEY(Minus); KEY(Equal); KEY(LeftBracket); KEY(RightBracket);
  KEY(Semicolon); KEY(Apostrophe); KEY(Comma); KEY(Period); KEY(Slash);
  KEY(Backslash); KEY(GraveAccent);
#undef KEY
  lua_setfield(L, -2, "key");
  lua_pop(L, 2);

  // style enums (tw.ig.col / tw.ig.var / tw.ig.flags)
  lua_getglobal(L, "tw");
  lua_getfield(L, -1, "ig");
  lua_newtable(L);
#define COL(name) lua_pushinteger(L, ImGuiCol_##name); lua_setfield(L, -2, #name)
  COL(Text); COL(TextDisabled); COL(WindowBg); COL(ChildBg); COL(PopupBg);
  COL(Border); COL(BorderShadow); COL(FrameBg); COL(FrameBgHovered);
  COL(FrameBgActive); COL(TitleBg); COL(TitleBgActive); COL(CheckMark);
  COL(SliderGrab); COL(SliderGrabActive); COL(Button); COL(ButtonHovered);
  COL(ButtonActive); COL(Header); COL(HeaderHovered); COL(HeaderActive);
  COL(Separator); COL(SeparatorHovered); COL(SeparatorActive);
  COL(ResizeGrip); COL(ResizeGripHovered); COL(ResizeGripActive);
  COL(Tab); COL(TabHovered); COL(TabActive); COL(TableHeaderBg);
  COL(TableBorderStrong); COL(TableBorderLight); COL(TableRowBg);
  COL(TableRowBgAlt); COL(TextSelectedBg); COL(DragDropTarget);
  COL(NavHighlight); COL(ModalWindowDimBg);
#undef COL
  lua_setfield(L, -2, "col");
  lua_newtable(L);
#define VAR(name) lua_pushinteger(L, ImGuiStyleVar_##name); lua_setfield(L, -2, #name)
  VAR(Alpha); VAR(WindowPadding); VAR(WindowRounding); VAR(WindowBorderSize);
  VAR(ChildRounding); VAR(ChildBorderSize); VAR(PopupRounding);
  VAR(FramePadding); VAR(FrameRounding); VAR(FrameBorderSize);
  VAR(ItemSpacing); VAR(ItemInnerSpacing); VAR(IndentSpacing);
  VAR(ScrollbarSize); VAR(ScrollbarRounding); VAR(GrabMinSize);
  VAR(GrabRounding); VAR(ButtonTextAlign); VAR(SelectableTextAlign);
  VAR(SeparatorTextBorderSize); VAR(SeparatorTextAlign);
#undef VAR
  lua_setfield(L, -2, "var");
  lua_newtable(L);
#define FLAG(name) lua_pushinteger(L, ImGuiWindowFlags_##name); lua_setfield(L, -2, #name)
  FLAG(NoTitleBar); FLAG(NoResize); FLAG(NoMove); FLAG(NoScrollbar);
  FLAG(NoScrollWithMouse); FLAG(NoCollapse); FLAG(NoSavedSettings);
  FLAG(NoInputs); FLAG(NoBringToFrontOnFocus); FLAG(NoBackground);
#undef FLAG
  lua_setfield(L, -2, "wflag");
  lua_pop(L, 2);
}
