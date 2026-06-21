## The persistent active-unit status box, pinned to the bottom-right during the action
## menu (the FFT layout: status in one corner, the action menu in the other). Unlike the
## floating `StatPanel` — which pops above whatever unit you hover — this one is always
## up while it's a unit's turn, showing that unit's stats so you can read them while
## choosing an action. Hidden in Move mode so it doesn't clutter the field.
##
## A *view* like `ActionMenu`: `Main` owns when to show it and what unit's text to put
## in; the panel only renders. Same screen-space recipe (CanvasLayer → Control →
## styled PanelContainer → Label) and the same chrome constants, so the three HUD boxes
## read as one system.
class_name StatusPanel
extends CanvasLayer

## Chrome matched to ActionMenu/StatPanel so the HUD boxes feel unified.
const _BG_COLOR := Color(0.0, 0.0, 0.0, 0.5)      ## Translucent black, same as the menu.
const _TEXT_COLOR := Color(0.92, 0.92, 0.96)      ## Soft near-white stat text.
const _FONT_SIZE := 30                             ## Readable but below the menu's 40.
const _PADDING := 20                               ## Interior margin, box edge to text.
const _CORNER_RADIUS := 8                          ## Same rounded corners as the menu.
const _SCREEN_MARGIN := 24                         ## Gap from the bottom-right screen corner.

## Full-screen, click-through root we toggle to show/hide the panel.
var _root: Control

## The stat text (multi-line, from `Unit.stats_panel_text`).
var _label: Label


## Godot lifecycle hook: build the (static) UI tree once. Mirrors the other HUD views,
## but the panel is pinned to the bottom-RIGHT corner and grows up-and-left as it sizes
## to its content (the mirror of the action menu's bottom-left anchoring).
func _ready() -> void:
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE  # never eat clicks meant for tiles
	add_child(_root)

	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	panel.offset_right = -_SCREEN_MARGIN    # margin in from the right edge
	panel.offset_bottom = -_SCREEN_MARGIN   # margin up from the bottom edge
	panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN  # expand leftward as it sizes
	panel.grow_vertical = Control.GROW_DIRECTION_BEGIN    # expand upward as it sizes
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = _BG_COLOR
	style.set_content_margin_all(_PADDING)
	style.set_corner_radius_all(_CORNER_RADIUS)
	panel.add_theme_stylebox_override("panel", style)
	_root.add_child(panel)

	_label = Label.new()
	_label.add_theme_font_size_override("font_size", _FONT_SIZE)
	_label.add_theme_color_override("font_color", _TEXT_COLOR)
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(_label)

	hide_panel()


## Show the panel with `text` (the active unit's `stats_panel_text`).
func show_for(text: String) -> void:
	_label.text = text
	_root.visible = true


## Hide the status panel (used when leaving the menu for Move mode).
func hide_panel() -> void:
	_root.visible = false
