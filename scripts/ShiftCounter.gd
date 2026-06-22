## The map-shift countdown box, pinned to the top-right corner. Shows how many character
## turns remain until the map "takes its turn" (the time-shift). It ticks down by one at the
## end of every turn, reaching 0 on the very turn the shift fires (see `TurnManager` /
## `Main._on_shift_countdown`).
##
## A *view* like `ActionMenu` / `StatusPanel`: `Main` decides the number to show; this only
## renders. Same screen-space recipe (CanvasLayer → Control → styled PanelContainer → Label)
## and the same chrome constants, so it reads as part of the one HUD system.
class_name ShiftCounter
extends CanvasLayer

## Chrome matched to the other HUD boxes so they feel unified.
const _BG_COLOR := Color(0.0, 0.0, 0.0, 0.5)      ## Translucent black, same as the menu.
const _TEXT_COLOR := Color(0.92, 0.92, 0.96)      ## Soft near-white text.
const _FONT_SIZE := 28                             ## Compact — it's a small status readout.
const _PADDING := 18                               ## Interior margin, box edge to text.
const _CORNER_RADIUS := 8                          ## Same rounded corners as the menu.
const _SCREEN_MARGIN := 24                         ## Gap from the top-right screen corner.

## Full-screen, click-through root we toggle to show/hide the box.
var _root: Control

## The countdown text.
var _label: Label


## Godot lifecycle hook: build the (static) UI tree once. Mirrors the other HUD views, but
## pinned to the top-RIGHT corner, growing down-and-left as it sizes to its content.
func _ready() -> void:
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE  # never eat clicks meant for tiles
	add_child(_root)

	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	panel.offset_right = -_SCREEN_MARGIN   # margin in from the right edge
	panel.offset_top = _SCREEN_MARGIN      # margin down from the top edge
	panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN  # expand leftward as it sizes
	panel.grow_vertical = Control.GROW_DIRECTION_END      # expand downward as it sizes
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


## Show `turns` as the remaining count. A negative value means shifts are disabled (the map
## has no transition cadence), so we hide the box entirely rather than show a meaningless
## number.
func set_count(turns: int) -> void:
	if turns < 0:
		_root.visible = false
		return
	_label.text = "Shift in: %d" % turns
	_root.visible = true
