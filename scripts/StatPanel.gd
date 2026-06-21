## A floating stat readout that hovers above a unit (on hover-dwell, or pinned by the
## "Stats" action). A *view* like `ActionMenu`: `Main` owns the state (which unit, where
## on screen) and calls these methods to render; the panel has no game logic.
##
## Why screen-space (a CanvasLayer + Control), not a 3D `Label3D`: we want the SAME
## chrome as the action menu — a translucent-black, rounded `StyleBoxFlat` box — and that
## styling is a Control feature, not something a 3D label offers. So instead of living in
## the world, the panel lives on the HUD and is *positioned* each frame from the unit's
## head projected to the screen (`Camera3D.unproject_position` in `Main`). It reuses the
## exact visual constants below so it reads as a sibling of the menu.
class_name StatPanel
extends CanvasLayer

## Match the action menu's look so the two HUD boxes feel like one system.
const _BG_COLOR := Color(0.0, 0.0, 0.0, 0.5)      ## Translucent black, same as ActionMenu.
const _TEXT_COLOR := Color(0.92, 0.92, 0.96)      ## Soft near-white stat text.
const _FONT_SIZE := 36                             ## A touch under the menu's 40 — it's denser text.
const _PADDING := 20                               ## Interior margin, box edge to text.
const _CORNER_RADIUS := 8                          ## Same rounded corners as the menu.
const _ANCHOR_GAP := 12                            ## Pixels between the box's bottom and the head point.
const _SCREEN_MARGIN := 12                         ## Min gap kept from every screen edge when clamped.

## Full-screen, click-through root we toggle to show/hide the panel.
var _root: Control

## The rounded translucent box; auto-sizes to the label inside it.
var _panel: PanelContainer

## The stat text itself.
var _label: Label


## Godot lifecycle hook: build the (static) UI tree once. Mirrors ActionMenu's setup —
## a click-through Control root holding a styled PanelContainer holding a Label.
func _ready() -> void:
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE  # never eat clicks meant for tiles
	add_child(_root)

	# PanelContainer pinned to top-left and positioned by `place_above`; it sizes itself
	# to its child, so we never hand-size the box.
	_panel = PanelContainer.new()
	_panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = _BG_COLOR
	style.set_content_margin_all(_PADDING)
	style.set_corner_radius_all(_CORNER_RADIUS)
	_panel.add_theme_stylebox_override("panel", style)
	_root.add_child(_panel)

	_label = Label.new()
	_label.add_theme_font_size_override("font_size", _FONT_SIZE)
	_label.add_theme_color_override("font_color", _TEXT_COLOR)
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(_label)

	hide_panel()


## Set the panel's text and reveal it. Position is applied separately by `place_above`.
func show_text(text: String) -> void:
	_label.text = text
	_root.visible = true


## Hide the panel.
func hide_panel() -> void:
	_root.visible = false


## True while the panel is showing — lets `Main` gate the dwell timer.
func is_open() -> bool:
	return _root.visible


## Place the box so it's centered horizontally on `screen_point` and floats just above
## it (the point is the unit's head projected to the screen). `reset_size` snaps the
## box to its content size *this* frame, so the centering uses the correct width even
## right after the text changes. Finally clamp the box fully on-screen so a unit near a
## screen edge (e.g. atop a hill at the top of the view) doesn't push it out of sight.
func place_above(screen_point: Vector2) -> void:
	_panel.reset_size()
	var size := _panel.size
	var pos := screen_point - Vector2(size.x * 0.5, size.y + _ANCHOR_GAP)
	# Keep the whole box within [margin, screen - size - margin]. max(..., margin)
	# guards the degenerate case where the box is wider/taller than the screen.
	var screen := get_viewport().get_visible_rect().size
	pos.x = clampf(pos.x, _SCREEN_MARGIN, maxf(_SCREEN_MARGIN, screen.x - size.x - _SCREEN_MARGIN))
	pos.y = clampf(pos.y, _SCREEN_MARGIN, maxf(_SCREEN_MARGIN, screen.y - size.y - _SCREEN_MARGIN))
	_panel.position = pos
