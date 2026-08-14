-- theme.lua — dark theme, tuned after cosmic2d/slopstudio: deep neutral
-- surfaces, one warm accent, clear active states, compact spacing.

local theme = {}

local ig = tw.ig

theme.accent = { 0.92, 0.62, 0.35, 1 }    -- warm amber
theme.accent_dim = { 0.55, 0.38, 0.22, 1 }
theme.bg = { 0.082, 0.086, 0.10, 1 }
theme.bg_panel = { 0.10, 0.105, 0.125, 1 }
theme.bg_child = { 0.118, 0.125, 0.15, 1 }
theme.fg = { 0.82, 0.83, 0.86, 1 }
theme.fg_dim = { 0.45, 0.47, 0.52, 1 }
theme.selection = { 0.25, 0.30, 0.38, 1 }

function theme.apply()
  local c = ig.col
  local v = ig.var

  ig.push_style_color(c.Text, theme.fg[1], theme.fg[2], theme.fg[3], theme.fg[4])
  ig.push_style_color(c.TextDisabled, theme.fg_dim[1], theme.fg_dim[2], theme.fg_dim[3], theme.fg_dim[4])
  ig.push_style_color(c.WindowBg, theme.bg[1], theme.bg[2], theme.bg[3], theme.bg[4])
  ig.push_style_color(c.ChildBg, theme.bg_child[1], theme.bg_child[2], theme.bg_child[3], theme.bg_child[4])
  ig.push_style_color(c.PopupBg, theme.bg_panel[1], theme.bg_panel[2], theme.bg_panel[3], theme.bg_panel[4])
  ig.push_style_color(c.Border, 0.16, 0.17, 0.20, 1)
  ig.push_style_color(c.BorderShadow, 0, 0, 0, 0)
  ig.push_style_color(c.FrameBg, 0.15, 0.16, 0.19, 1)
  ig.push_style_color(c.FrameBgHovered, 0.21, 0.23, 0.27, 1)
  ig.push_style_color(c.FrameBgActive, 0.26, 0.28, 0.33, 1)
  ig.push_style_color(c.TitleBg, theme.bg_panel[1], theme.bg_panel[2], theme.bg_panel[3], theme.bg_panel[4])
  ig.push_style_color(c.TitleBgActive, theme.bg_panel[1], theme.bg_panel[2], theme.bg_panel[3], theme.bg_panel[4])
  ig.push_style_color(c.CheckMark, theme.accent[1], theme.accent[2], theme.accent[3], theme.accent[4])
  ig.push_style_color(c.SliderGrab, theme.accent[1], theme.accent[2], theme.accent[3], theme.accent[4])
  ig.push_style_color(c.SliderGrabActive, 1, 0.78, 0.55, 1)
  ig.push_style_color(c.Button, 0.16, 0.18, 0.22, 1)
  ig.push_style_color(c.ButtonHovered, theme.accent_dim[1], theme.accent_dim[2], theme.accent_dim[3], 1)
  ig.push_style_color(c.ButtonActive, theme.accent[1], theme.accent[2], theme.accent[3], 1)
  ig.push_style_color(c.Header, 0.20, 0.23, 0.28, 1)
  ig.push_style_color(c.HeaderHovered, 0.25, 0.29, 0.35, 1)
  ig.push_style_color(c.HeaderActive, theme.selection[1], theme.selection[2], theme.selection[3], 1)
  ig.push_style_color(c.Separator, 0.18, 0.19, 0.22, 1)
  ig.push_style_color(c.SeparatorHovered, theme.accent_dim[1], theme.accent_dim[2], theme.accent_dim[3], 1)
  ig.push_style_color(c.SeparatorActive, theme.accent[1], theme.accent[2], theme.accent[3], 1)
  ig.push_style_color(c.ResizeGrip, 0.2, 0.22, 0.26, 1)
  ig.push_style_color(c.ResizeGripHovered, theme.accent_dim[1], theme.accent_dim[2], theme.accent_dim[3], 1)
  ig.push_style_color(c.ResizeGripActive, theme.accent[1], theme.accent[2], theme.accent[3], 1)
  ig.push_style_color(c.Tab, 0.13, 0.14, 0.17, 1)
  ig.push_style_color(c.TabHovered, 0.23, 0.26, 0.31, 1)
  ig.push_style_color(c.TabActive, theme.selection[1], theme.selection[2], theme.selection[3], 1)
  ig.push_style_color(c.TableHeaderBg, 0.13, 0.14, 0.17, 1)
  ig.push_style_color(c.TableBorderStrong, 0.20, 0.21, 0.25, 1)
  ig.push_style_color(c.TableBorderLight, 0.15, 0.16, 0.19, 1)
  ig.push_style_color(c.TableRowBg, 0, 0, 0, 0)
  ig.push_style_color(c.TableRowBgAlt, 1, 1, 1, 0.02)
  ig.push_style_color(c.TextSelectedBg, 0.30, 0.42, 0.55, 0.5)
  ig.push_style_color(c.ModalWindowDimBg, 0, 0, 0, 0.55)

  ig.push_style_var(v.WindowPadding, 8, 8)
  ig.push_style_var(v.WindowRounding, 0)
  ig.push_style_var(v.WindowBorderSize, 1)
  ig.push_style_var(v.ChildRounding, 4)
  ig.push_style_var(v.ChildBorderSize, 1)
  ig.push_style_var(v.PopupRounding, 4)
  ig.push_style_var(v.FramePadding, 6, 4)
  ig.push_style_var(v.FrameRounding, 3)
  ig.push_style_var(v.FrameBorderSize, 0)
  ig.push_style_var(v.ItemSpacing, 6, 5)
  ig.push_style_var(v.ItemInnerSpacing, 4, 4)
  ig.push_style_var(v.IndentSpacing, 14)
  ig.push_style_var(v.ScrollbarSize, 10)
  ig.push_style_var(v.ScrollbarRounding, 5)
  ig.push_style_var(v.GrabMinSize, 8)
  ig.push_style_var(v.GrabRounding, 3)
end

-- pop all the pushes above (called once per frame after the UI)
theme.frame_end = function()
  ig.pop_style_var(16)
  ig.pop_style_color(37)
end

return theme
