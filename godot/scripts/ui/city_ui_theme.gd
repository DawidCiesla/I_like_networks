extends RefCounted
class_name CityUITheme

## Builds the shared city-management UI theme with compact charcoal-blue
## surfaces, restrained separators, and a warm, legible selection accent.

const COLOR_PANEL := Color8(31, 39, 47, 240)
const COLOR_PANEL_DARK := Color8(22, 28, 35, 246)
const COLOR_PANEL_HOVER := Color8(43, 53, 62, 244)
const COLOR_PANEL_PRESSED := Color8(52, 61, 67, 248)
const COLOR_BORDER := Color8(143, 157, 168, 62)
const COLOR_ACCENT := Color8(224, 169, 98)
const COLOR_ACCENT_SOFT := Color8(224, 169, 98, 92)
const COLOR_TEXT := Color8(235, 239, 242)
const COLOR_TEXT_MUTED := Color8(164, 177, 187)
const COLOR_TEXT_DISABLED := Color8(109, 122, 132)

static func create_theme() -> Theme:
	var theme := Theme.new()
	var ui_font := SystemFont.new()
	ui_font.font_names = PackedStringArray(["Arial", "Helvetica Neue", "Helvetica", "sans-serif"])
	theme.default_font = ui_font
	theme.default_font_size = 13

	var panel := _panel_style()
	var dark_panel := _dark_panel_style()
	theme.set_stylebox("panel", "PanelContainer", panel)
	theme.set_stylebox("panel", "Panel", panel.duplicate())
	theme.set_stylebox("panel", "PopupPanel", dark_panel)
	theme.set_stylebox("panel", "PopupMenu", dark_panel.duplicate())

	theme.set_color("font_color", "Label", COLOR_TEXT)
	theme.set_color("font_hover_color", "Label", Color.WHITE)
	theme.set_color("font_disabled_color", "Label", COLOR_TEXT_DISABLED)
	theme.set_font_size("font_size", "Label", 13)

	_set_button_theme(theme)
	_set_input_theme(theme)
	_set_tab_theme(theme)
	return theme


## Use this on a title strip or selected section when a panel needs a visible
## warm accent edge without changing the shared theme.
static func create_accent_panel_style() -> StyleBoxFlat:
	var style := _panel_style()
	style.border_color = COLOR_ACCENT_SOFT
	style.border_width_left = 2
	return style


static func _panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = COLOR_PANEL
	style.border_color = COLOR_BORDER
	style.set_border_width_all(1)
	style.set_corner_radius_all(5)
	style.shadow_color = Color(0.0, 0.0, 0.0, 0.16)
	style.shadow_size = 3
	style.shadow_offset = Vector2(0, 1)
	style.content_margin_left = 9.0
	style.content_margin_top = 7.0
	style.content_margin_right = 9.0
	style.content_margin_bottom = 7.0
	return style


static func _dark_panel_style() -> StyleBoxFlat:
	var style := _panel_style()
	style.bg_color = COLOR_PANEL_DARK
	style.shadow_size = 2
	return style


static func _button_style(background: Color, border: Color, border_width: int = 1) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = background
	style.border_color = border
	style.set_border_width_all(border_width)
	style.set_corner_radius_all(4)
	style.content_margin_left = 8.0
	style.content_margin_top = 5.0
	style.content_margin_right = 8.0
	style.content_margin_bottom = 5.0
	return style


static func _set_button_theme(theme: Theme) -> void:
	theme.set_color("font_color", "Button", COLOR_TEXT)
	theme.set_color("font_hover_color", "Button", Color.WHITE)
	theme.set_color("font_pressed_color", "Button", COLOR_ACCENT)
	theme.set_color("font_disabled_color", "Button", COLOR_TEXT_DISABLED)
	theme.set_font_size("font_size", "Button", 12)
	theme.set_stylebox("normal", "Button", _button_style(Color8(37, 46, 55, 242), COLOR_BORDER))
	theme.set_stylebox("hover", "Button", _button_style(COLOR_PANEL_HOVER, COLOR_ACCENT, 1))
	theme.set_stylebox("pressed", "Button", _button_style(COLOR_PANEL_PRESSED, COLOR_ACCENT, 1))
	theme.set_stylebox("disabled", "Button", _button_style(Color8(27, 33, 39, 210), Color8(106, 118, 128, 54)))
	var focus := _button_style(Color(0, 0, 0, 0), COLOR_ACCENT, 1)
	focus.draw_center = false
	theme.set_stylebox("focus", "Button", focus)


static func _set_input_theme(theme: Theme) -> void:
	theme.set_color("font_color", "LineEdit", COLOR_TEXT)
	theme.set_color("font_placeholder_color", "LineEdit", COLOR_TEXT_MUTED)
	theme.set_color("font_selected_color", "LineEdit", Color.WHITE)
	theme.set_color("selection_color", "LineEdit", Color(COLOR_ACCENT, 0.32))
	theme.set_stylebox("normal", "LineEdit", _button_style(COLOR_PANEL_DARK, COLOR_BORDER))
	theme.set_stylebox("focus", "LineEdit", _button_style(COLOR_PANEL_DARK, COLOR_ACCENT, 1))
	theme.set_stylebox("read_only", "LineEdit", _button_style(Color8(26, 32, 38, 220), Color8(106, 118, 128, 54)))


static func _set_tab_theme(theme: Theme) -> void:
	theme.set_color("font_selected_color", "TabBar", Color.WHITE)
	theme.set_color("font_unselected_color", "TabBar", COLOR_TEXT_MUTED)
	theme.set_color("font_hovered_color", "TabBar", COLOR_TEXT)
	theme.set_stylebox("tab_selected", "TabBar", _button_style(COLOR_PANEL_HOVER, COLOR_ACCENT, 1))
	theme.set_stylebox("tab_unselected", "TabBar", _button_style(COLOR_PANEL_DARK, COLOR_BORDER))
	theme.set_stylebox("tab_hovered", "TabBar", _button_style(COLOR_PANEL_HOVER, COLOR_ACCENT))
	theme.set_stylebox("tab_disabled", "TabBar", _button_style(Color8(27, 33, 39, 210), Color8(106, 118, 128, 54)))
