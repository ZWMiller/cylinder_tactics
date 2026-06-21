## On-screen action menu (e.g. Move / End Turn) shown in the bottom-left during a
## unit's turn. This is a *view*: `Main` owns the state (which options exist, which
## is highlighted, whether it's visible) and calls these methods to render it; the
## menu has no game logic of its own.
##
## Built in code (not a .tscn) to match the project's code-driven workflow, and as a
## gentle tour of Godot's UI nodes — different from the 3D `Node3D` world:
##   - A **CanvasLayer** draws in screen space, on top of the 3D view and unaffected
##     by the game camera — the right host for a HUD.
##   - **Control** nodes lay out via *anchors* (which screen edge they pin to) plus
##     *offsets* (pixel margins), instead of a 3D transform.
##   - **Containers** (PanelContainer, VBoxContainer) auto-size and arrange their
##     children, so we don't hand-place each label.
class_name ActionMenu
extends CanvasLayer

## Dim (normal) vs bright (highlighted) label colors. Highlight matches the
## active-unit glow so the two read as "the same selection."
const _NORMAL_COLOR := Color(0.78, 0.78, 0.82)
const _HIGHLIGHT_COLOR := Color(1.0, 0.9, 0.4)

## Size/spacing knobs, pulled out so the menu is easy to retune in one place. Sized
## up ~4x from the first pass so it reads as a deliberate HUD, not a tooltip.
const _FONT_SIZE := 40           ## Option text height in px.
const _PADDING := 24             ## Interior margin between the box edge and the text.
const _ITEM_SEPARATION := 14     ## Vertical gap between options.
const _CORNER_RADIUS := 8        ## Slightly rounded corners, so it sits less starkly.
const _SCREEN_MARGIN := 24       ## Gap from the bottom-left screen corner.

## Color of the title (active unit's name) — brighter than the options so it reads as
## a heading, not another selectable row.
const _TITLE_COLOR := Color(0.95, 0.95, 1.0)

## Full-screen, click-through root. We toggle its visibility to show/hide the menu.
var _root: Control

## Heading line showing whose turn it is (the active unit's name).
var _title: Label

## The vertical list the option labels live in.
var _list: VBoxContainer

## The option strings and their Labels, kept index-aligned.
var _options: Array = []
var _labels: Array[Label] = []


## Godot lifecycle hook: build the (static) UI tree once when the layer enters the
## scene. add_child() below runs synchronously, so `_list` is ready immediately after.
func _ready() -> void:
	# Full-screen, click-through root so the menu never eats clicks meant for tiles.
	# MOUSE_FILTER_IGNORE = "pass mouse events through me to whatever is behind."
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	# Translucent black box pinned to the bottom-left corner. The grow directions
	# make it expand up and to the right as it sizes to its contents, so it hugs the
	# corner regardless of how many options there are.
	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	panel.offset_left = _SCREEN_MARGIN     # margin in from the left edge
	panel.offset_bottom = -_SCREEN_MARGIN  # margin up from the bottom edge
	panel.grow_horizontal = Control.GROW_DIRECTION_END
	panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# A PanelContainer's background is a theme "panel" StyleBox; override it with a
	# flat translucent-black box, interior padding, and slightly rounded corners.
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.0, 0.0, 0.0, 0.5)
	style.set_content_margin_all(_PADDING)
	style.set_corner_radius_all(_CORNER_RADIUS)
	panel.add_theme_stylebox_override("panel", style)
	_root.add_child(panel)

	# A single column inside the panel: the title heading on top, the option list
	# below it. Wrapping them lets the panel size to both together.
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", _ITEM_SEPARATION)
	content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(content)

	# Title: the active unit's name. Built once here; its text is set by set_title.
	_title = Label.new()
	_title.add_theme_font_size_override("font_size", _FONT_SIZE)
	_title.add_theme_color_override("font_color", _TITLE_COLOR)
	_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.add_child(_title)

	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", _ITEM_SEPARATION)
	_list.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.add_child(_list)


## Replace the menu's options (one label per entry). Call once after the menu is in
## the tree, before highlighting.
func build(options: Array) -> void:
	_options = options.duplicate()
	for label in _labels:
		label.queue_free()
	_labels.clear()
	for option in _options:
		var label := Label.new()
		label.add_theme_font_size_override("font_size", _FONT_SIZE)
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_list.add_child(label)
		_labels.append(label)


## Visually mark option `index` as highlighted (arrow + bright color); dim the rest.
func set_highlighted(index: int) -> void:
	for i in _labels.size():
		var selected: bool = i == index
		_labels[i].text = ("> " if selected else "   ") + str(_options[i])
		_labels[i].add_theme_color_override("font_color", _HIGHLIGHT_COLOR if selected else _NORMAL_COLOR)


## Set the heading text — the active unit's name, shown above the options so the
## player can see whose turn it is.
func set_title(text: String) -> void:
	_title.text = text


## Show or hide the whole menu (used when entering / leaving the menu phase).
func set_menu_visible(value: bool) -> void:
	_root.visible = value
