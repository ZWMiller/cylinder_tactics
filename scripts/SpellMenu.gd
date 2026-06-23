## A nested submenu of action choices, shown when a caster picks "Spell". It follows a general HUD
## convention (so future "Item"/other submenus reuse it): a submenu opens **to the right of the
## menu that spawned it**, which stays visible with its triggering option highlighted, and the
## player presses **Left or Esc to back out** to the parent. Here it lists each known spell with the
## **name on the left and MP cost right-aligned** on the same row; unaffordable spells are greyed,
## and picking one flashes a "Not Enough MP" toast beside the menu for ~2s, then it fades.
##
## A *view* like `ActionMenu`/`StatusPanel`: `Main` owns the state (which spells, which is
## highlighted, what's affordable, where to dock) and calls these methods to render; no game logic
## lives here. Same screen-space recipe + chrome as the other HUD boxes. The right-aligned cost is
## why each row is its own `HBoxContainer` (a name `Label` that *expands* to push a cost `Label` to
## the right edge) rather than the action menu's single label per row.
class_name SpellMenu
extends CanvasLayer

## Row colors: normal, highlighted (matches the action menu's selection), and a dim grey for
## unaffordable spells. The toast uses a soft warning red.
const _NORMAL_COLOR := Color(0.78, 0.78, 0.82)
const _HIGHLIGHT_COLOR := Color(1.0, 0.9, 0.4)
const _DISABLED_COLOR := Color(0.5, 0.5, 0.55)
const _TITLE_COLOR := Color(0.95, 0.95, 1.0)
const _WARN_COLOR := Color(1.0, 0.55, 0.5)

## Chrome matched to ActionMenu so the boxes feel unified.
const _FONT_SIZE := 40
const _PADDING := 24
const _ITEM_SEPARATION := 14
const _CORNER_RADIUS := 8
const _SCREEN_MARGIN := 24

## Gap (px) between the parent menu's right edge and this submenu (and between this menu and its
## toast), so nested menus read as distinct boxes rather than touching.
const _NEST_GAP := 16

## Minimum row width (px) so the right-aligned cost has room to sit clear of the name.
const _LIST_MIN_WIDTH := 320

## How long (seconds) the "Not Enough MP" toast stays up, and how long its closing fade takes.
const _WARN_SECONDS := 2.0
const _WARN_FADE := 0.6

## Full-screen, click-through root we toggle to show/hide the menu.
var _root: Control

## The bordered box; kept as a field so we can read its on-screen rect (to dock the toast) and set
## its left offset (to dock the whole submenu beside its parent).
var _panel: PanelContainer

## Heading ("Spells").
var _title: Label

## The column the spell rows live in.
var _list: VBoxContainer

## Per-spell data + the two Labels of each row, kept index-aligned with the spell list.
var _names: Array = []
var _costs: Array = []
var _name_labels: Array[Label] = []
var _cost_labels: Array[Label] = []

## The transient "Not Enough MP" toast: a styled panel (same chrome as the menus) holding the warn
## label, plus the tween currently fading the whole panel (killed if re-triggered).
var _warn_panel: PanelContainer
var _warn: Label
var _warn_tween: Tween


## Godot lifecycle hook: build the (static) UI shell once. A bottom-left, grows-up-and-right panel
## like ActionMenu (its left offset is set later by `open_beside`), plus a toast label parked to the
## panel's right whenever it flashes.
func _ready() -> void:
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE  # never eat clicks meant for tiles
	add_child(_root)

	_panel = PanelContainer.new()
	_panel.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	_panel.offset_left = _SCREEN_MARGIN                  # overwritten by open_beside
	_panel.offset_bottom = -_SCREEN_MARGIN
	_panel.grow_horizontal = Control.GROW_DIRECTION_END  # expand rightward as it sizes
	_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN  # expand upward as it sizes
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.0, 0.0, 0.0, 0.5)
	style.set_content_margin_all(_PADDING)
	style.set_corner_radius_all(_CORNER_RADIUS)
	_panel.add_theme_stylebox_override("panel", style)
	_root.add_child(_panel)

	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", _ITEM_SEPARATION)
	content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(content)

	_title = Label.new()
	_title.text = "Spells"
	_title.add_theme_font_size_override("font_size", _FONT_SIZE)
	_title.add_theme_color_override("font_color", _TITLE_COLOR)
	_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.add_child(_title)

	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", _ITEM_SEPARATION)
	_list.custom_minimum_size.x = _LIST_MIN_WIDTH   # give the right-aligned cost room to spread
	_list.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.add_child(_list)

	# The toast: a translucent panel (same chrome as the menus) with the warning label inside, so it
	# reads against any background — like the other HUD boxes. Bottom-left like the menus; its left
	# offset is set per-flash from the submenu's rect so it sits just to the right. Fading the panel's
	# `modulate` fades the box AND its text together. Hidden until `flash_insufficient`.
	_warn_panel = PanelContainer.new()
	_warn_panel.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	_warn_panel.offset_bottom = -_SCREEN_MARGIN   # bottoms align with the submenu beside it
	_warn_panel.grow_horizontal = Control.GROW_DIRECTION_END
	_warn_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_warn_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var warn_style := StyleBoxFlat.new()
	warn_style.bg_color = Color(0.0, 0.0, 0.0, 0.5)
	warn_style.set_content_margin_all(_PADDING)
	warn_style.set_corner_radius_all(_CORNER_RADIUS)
	_warn_panel.add_theme_stylebox_override("panel", warn_style)
	_warn_panel.visible = false
	_root.add_child(_warn_panel)

	_warn = Label.new()
	_warn.text = "Not Enough MP"
	_warn.add_theme_font_size_override("font_size", _FONT_SIZE)
	_warn.add_theme_color_override("font_color", _WARN_COLOR)
	_warn.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_warn_panel.add_child(_warn)

	set_menu_visible(false)


## Replace the listed spells: `names[i]` paired with `costs[i]` (MP). Rebuilds one row per spell;
## call `refresh` afterward to color/highlight them. Each row is an HBox so the cost right-aligns.
func build(names: Array, costs: Array) -> void:
	_names = names.duplicate()
	_costs = costs.duplicate()
	for row in _list.get_children():
		row.queue_free()
	_name_labels.clear()
	_cost_labels.clear()

	for i in _names.size():
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", _PADDING)  # gap between name and cost
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_list.add_child(row)

		var name_label := Label.new()
		name_label.add_theme_font_size_override("font_size", _FONT_SIZE)
		# Expand so this label eats the slack in the row, shoving the cost label to the right edge.
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(name_label)
		_name_labels.append(name_label)

		var cost_label := Label.new()
		cost_label.add_theme_font_size_override("font_size", _FONT_SIZE)
		cost_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(cost_label)
		_cost_labels.append(cost_label)


## Render the rows for the current selection + affordability: highlight row `index`, dim any spell
## whose `affordable[i]` is false (greyed, but still selectable so picking it can flash the toast).
## The "> " arrow marks the highlighted row regardless of affordability.
func refresh(index: int, affordable: Array) -> void:
	for i in _name_labels.size():
		var selected: bool = i == index
		var can_afford: bool = i < affordable.size() and affordable[i]
		var color: Color
		if not can_afford:
			color = _DISABLED_COLOR
		elif selected:
			color = _HIGHLIGHT_COLOR
		else:
			color = _NORMAL_COLOR
		_name_labels[i].text = ("> " if selected else "   ") + str(_names[i])
		_cost_labels[i].text = "%d MP" % int(_costs[i])
		_name_labels[i].add_theme_color_override("font_color", color)
		_cost_labels[i].add_theme_color_override("font_color", color)


## Dock this submenu just to the right of `anchor_rect` (the parent menu's on-screen rect from
## `ActionMenu.panel_rect`), bottoms aligned. This is the nesting convention — the parent stays put
## and visible; we slide in beside it.
func open_beside(anchor_rect: Rect2) -> void:
	_panel.offset_left = anchor_rect.position.x + anchor_rect.size.x + _NEST_GAP
	set_menu_visible(true)


## Flash the "Not Enough MP" toast just to the right of the submenu: pop it to full opacity, hold,
## then fade over `_WARN_FADE` (total ≈ `_WARN_SECONDS`). Re-triggering kills the prior fade so the
## timer restarts cleanly instead of two tweens fighting.
func flash_insufficient() -> void:
	if _warn_tween != null and _warn_tween.is_valid():
		_warn_tween.kill()
	# Park it beside this submenu using the panel's current rect (valid — the menu is open).
	_warn_panel.offset_left = _panel.get_global_rect().end.x + _NEST_GAP
	_warn_panel.visible = true
	_warn_panel.modulate.a = 1.0
	_warn_tween = create_tween()
	_warn_tween.tween_interval(_WARN_SECONDS - _WARN_FADE)
	_warn_tween.tween_property(_warn_panel, "modulate:a", 0.0, _WARN_FADE)
	_warn_tween.tween_callback(func() -> void: _warn_panel.visible = false)


## Show or hide the whole submenu. Hiding also clears any lingering toast so it doesn't reappear
## when the menu opens again.
func set_menu_visible(value: bool) -> void:
	_root.visible = value
	if not value:
		if _warn_tween != null and _warn_tween.is_valid():
			_warn_tween.kill()
		_warn_panel.visible = false
