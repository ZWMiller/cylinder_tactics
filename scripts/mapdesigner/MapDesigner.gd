## The in-game map designer (Phase 1): paint heights and terrain types onto a grid by
## mouse and save the result as a `MapData` `.tres`, or load one back to edit. Run it
## with F6 on `scenes/MapDesigner.tscn`.
##
## It renders through an `EditableBattlefield` (a `Battlefield` subclass) so what you
## build looks EXACTLY like a battle map — same two-layer body/cap columns and picking,
## no duplicated rendering. This script owns only the *interaction*: a current tool, an
## active terrain type, mouse painting, and New/Save/Load.
##
## Scope note: this is the single-state, single-tile first cut. The brush macros
## (square/circle/line/hill, configurable size, click-drag height) and multi-state
## (shift-sequence) editing are deliberately deferred — painting already routes through
## a tile-set entry point so the brushes slot in without reworking this.
extends Node3D

# --- Tunables ---------------------------------------------------------------

## Grid size of a freshly-created map (New). Variable per map; just the starting size.
const NEW_MAP_WIDTH := 10
const NEW_MAP_HEIGHT := 10

## Height clamps while editing — keep tiles from going below ground or absurdly tall.
const MIN_HEIGHT := 0
const MAX_HEIGHT := 40

## Starting height for every tile of a freshly-created map. Sits in the MIDDLE of the
## [MIN_HEIGHT, MAX_HEIGHT] band so a new map can be carved DOWN (pits, ravines — now
## that the underside matters) as easily as raised UP, ~20 levels either way.
const NEW_TILE_HEIGHT := 20

## Where maps are saved/loaded by default (authored content lives in the project).
const MAPS_DIR := "res://assets/maps"

## Translucent white cursor laid on the hovered tile (reuses Battlefield's active marker).
const HOVER_COLOR := Color(1.0, 1.0, 1.0, 0.45)

## Designer UI font sizes, in design pixels at the project's 1920x1080 base. The
## project's `canvas_items` stretch scales them with the window, so these are tuned ONCE
## here and stay proportional on every resolution — no per-display fiddling.
const FONT_HUD := 26      ## the top-left tool / help readout
const FONT_SWATCH := 22   ## the number-key caption on each terrain swatch
const FONT_DIALOG := 24   ## all text inside the New / Rename / Save / Load dialogs (via theme)

## Max width (1080p-base px) of the top-left help panel; longer lines wrap so it grows
## downward instead of sprawling across toward the swatch bar.
const HUD_PANEL_WIDTH := 520

## Which tile attribute the mouse edits. RESIZE is the odd one out — it doesn't paint a
## tile, it grows/shrinks the grid at the hovered edge (L adds, R deletes; corners do
## both). It rides the same Tab cycle and L/R-click convention as the painting tools.
## SURFACE and BODY collapsed into one face-aware PAINT tool: it paints the active
## terrain type onto WHICHEVER face you click — top, a side, or (orbiting under the map)
## the underside — routed by the picked face normal (see `_paint_face` / `TileFaces`).
enum Tool { HEIGHT, PAINT, RESIZE }

## The terrain types offered for painting, in palette order. Number keys 1-9 then 0
## quick-select the first ten; `[` / `]` cycle through all of them (so QUICKSAND, the
## eleventh, is reachable even without a number key).
const PALETTE: Array[int] = [
	TileTypes.Type.GRASS, TileTypes.Type.WATER, TileTypes.Type.SAND, TileTypes.Type.STONE,
	TileTypes.Type.ROAD, TileTypes.Type.DIRT, TileTypes.Type.LAVA, TileTypes.Type.BUILDING,
	TileTypes.Type.BUILDING_STONE, TileTypes.Type.ROOF, TileTypes.Type.QUICKSAND,
]

# --- Runtime state ----------------------------------------------------------

## The editable battlefield we paint on (created in code so we never build the throwaway
## DemoMap fallback first). Holds the authoritative map state.
var _field: EditableBattlefield

## The orbit camera (in the scene); used both for input and for ray-picking tiles.
@onready var _camera: CameraController = $Camera3D

var _tool: int = Tool.HEIGHT          ## Active editing tool.
var _active_type: int = TileTypes.Type.GRASS  ## Terrain type the SURFACE/BODY tools paint.
var _map_name: String = "Untitled"    ## Saved into the MapData; not the filename.

## HUD label + the save/open file pickers, all built in code.
var _hud_layer: CanvasLayer    ## Shared CanvasLayer the HUD text + swatch bar live on.
var _label: Label
var _save_dialog: FileDialog
var _open_dialog: FileDialog

## The terrain swatch bar across the top: one clickable colored `Panel` per PALETTE
## entry, parallel to `PALETTE`. Click a swatch (or press its number key) to select
## that paint type; the active one is highlighted (see `_refresh_swatches`).
var _swatches: Array[Panel] = []

## The New-map dialog (name + width + length) and its inputs, and the Rename dialog
## (name only) and its input. Both built in code; popped from the N / R keys.
var _new_dialog: AcceptDialog
var _new_name_edit: LineEdit
var _new_width_spin: SpinBox
var _new_height_spin: SpinBox
var _rename_dialog: AcceptDialog
var _rename_edit: LineEdit

## One shared Theme applied to every dialog Window. Setting its `default_font_size` is
## what enlarges ALL their text at once — including the file list / buttons / path bar
## inside the FileDialogs, which we otherwise can't reach to override per-control.
var _ui_theme: Theme


## Build the field (seeded with a blank map), the HUD, and the file dialogs.
func _ready() -> void:
	_field = EditableBattlefield.new()
	_field.name = "EditableBattlefield"
	# Seed the starting map BEFORE entering the tree, so the base _ready builds this
	# blank grid directly instead of the 24x24 DemoMap fallback.
	_field.states = _new_flat_states(NEW_MAP_WIDTH, NEW_MAP_HEIGHT)
	add_child(_field)

	# Let the designer camera orbit BENEATH the map (battle keeps the default top-down
	# clamp). Lowering `min_pitch` below 0 is what makes the underside reachable for the
	# face-aware PAINT tool — you fly under the board to click the BOTTOM face. Set here
	# (scene-local) rather than on the shared CameraController default, so battles are
	# unaffected. Stops short of straight-down (-90) where `look_at` would degenerate.
	_camera.min_pitch = -80.0

	# One theme drives every dialog's font size (built before the dialogs that use it).
	_ui_theme = Theme.new()
	_ui_theme.default_font_size = FONT_DIALOG

	_build_hud()
	_build_swatch_bar()
	_build_dialogs()
	_build_new_dialog()
	_build_rename_dialog()
	_refresh_label()


## Each frame, show the hover feedback for the active tool. While any dialog is open we
## suppress all hover feedback (the dialog owns input). The RESIZE tool shows the
## add/delete edge previews instead of the paint cursor; every other tool shows the
## white tile cursor.
func _process(_delta: float) -> void:
	# Suspend the camera's Q/E key-orbit while a dialog is open (its raw-keyboard polling
	# would otherwise spin the view as you type 'q'/'e' into a name/filename field).
	var dialog_open := _dialog_open()
	_camera.key_orbit_enabled = not dialog_open
	if dialog_open:
		_field.clear_hover_face()
		_field.clear_resize_preview()
		return
	# Face-aware pick: the PAINT cursor highlights whichever FACE is under the mouse.
	var pick := _field.tile_and_face_at_screen_point(_camera, get_viewport().get_mouse_position())
	var tile: Vector2i = pick["tile"]
	if _tool == Tool.RESIZE:
		# No paint cursor in resize mode; the green/red edge previews carry the meaning.
		_field.clear_hover_face()
		var sides := _field.sides_at(tile.x, tile.y)   # [] off-grid or on an interior tile
		if sides.is_empty():
			_field.clear_resize_preview()
		else:
			_field.show_resize_preview(sides)
		return
	# Painting tools: face hover cursor, and make sure no stale resize ghost lingers.
	_field.clear_resize_preview()
	if tile == Battlefield.INVALID_TILE:
		_field.clear_hover_face()
	else:
		_field.set_hover_face(tile, pick["face"], HOVER_COLOR)


## Keyboard (tools / palette / file ops) and mouse painting. Uses `_unhandled_input` so
## any open FileDialog consumes its own events first.
func _unhandled_input(event: InputEvent) -> void:
	# While a dialog is open it owns input — ignore stray hotkeys/clicks that leak
	# through (text fields consume their own typing before _unhandled_input runs).
	if _dialog_open():
		return
	if event is InputEventKey and event.pressed and not event.echo:
		_handle_key(event.keycode)
	elif event is InputEventMouseButton and event.pressed:
		# Left = primary (raise / paint), Right = secondary (lower, height tool only).
		if event.button_index == MOUSE_BUTTON_LEFT:
			_paint_under_mouse(true)
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			_paint_under_mouse(false)


## Dispatch a key press to a tool/palette/file action.
func _handle_key(keycode: int) -> void:
	match keycode:
		KEY_TAB:
			_tool = (_tool + 1) % Tool.size()
			_refresh_label()
		KEY_BRACKETRIGHT:
			_select_type((PALETTE.find(_active_type) + 1) % PALETTE.size())
		KEY_BRACKETLEFT:
			_select_type((PALETTE.find(_active_type) - 1 + PALETTE.size()) % PALETTE.size())
		KEY_N:
			# Prefill the dialog with the current map's name/size, then let the user edit.
			_new_name_edit.text = _map_name
			_new_width_spin.value = _field.grid_width
			_new_height_spin.value = _field.grid_height
			_new_dialog.popup_centered()
		KEY_R:
			_rename_edit.text = _map_name
			_rename_dialog.popup_centered()
		KEY_S:
			# Default the filename to the map's name so saving doesn't make you retype it.
			_save_dialog.current_file = _map_name + ".tres"
			_save_dialog.popup_centered(Vector2i(1000, 680))
		KEY_L:
			_open_dialog.popup_centered(Vector2i(1000, 680))
		_:
			# Number keys 1-9 then 0 quick-select palette slots 0-9.
			var digit := _digit_for_keycode(keycode)
			if digit >= 0 and digit < PALETTE.size():
				_select_type(digit)


## Apply the current tool to the tile under the mouse. `primary` = left click.
func _paint_under_mouse(primary: bool) -> void:
	# Face-aware pick: we need both the tile AND which of its faces is under the cursor
	# (the PAINT tool routes by face). `tile_and_face_at_screen_point` derives the face
	# from the physics hit normal — see docs/FACES.md (Layer A).
	var pick := _field.tile_and_face_at_screen_point(_camera, get_viewport().get_mouse_position())
	var tile: Vector2i = pick["tile"]
	if tile == Battlefield.INVALID_TILE:
		return
	# RESIZE acts on the grid, not a tile's data, so handle it before reading tile data.
	if _tool == Tool.RESIZE:
		_apply_resize(tile, primary)
		return
	var t := _field.tile_data(tile.x, tile.y)
	if t.is_empty():
		return
	match _tool:
		Tool.HEIGHT:
			# Left raises, right lowers — by one level, clamped. Preserve the underside.
			var delta := 1 if primary else -1
			var new_h: int = clampi(t["height"] + delta, MIN_HEIGHT, MAX_HEIGHT)
			_field.set_tile(tile.x, tile.y, new_h, t["type"], t["body"], t.get("bottom", t["body"]))
		Tool.PAINT:
			if primary:
				_paint_face(tile, t, pick["face"])


## Paint `_active_type` onto the clicked `face` of tile (x, z), leaving its other faces
## untouched. TOP sets the surface type, BOTTOM the underside type, and any of the four
## sides the (shared) body type. This match is the single place "clicked face → which
## layer" lives — it's what grows when N/S/E/W become independently typed (each side
## would target its own field instead of all sharing `body`).
func _paint_face(tile: Vector2i, t: Dictionary, face: int) -> void:
	var bottom: int = t.get("bottom", t["body"])
	match face:
		TileFaces.Face.TOP:
			_field.set_tile(tile.x, tile.y, t["height"], _active_type, t["body"], bottom)
		TileFaces.Face.BOTTOM:
			_field.set_tile(tile.x, tile.y, t["height"], t["type"], t["body"], _active_type)
		_:
			# NORTH / SOUTH / EAST / WEST all paint the one body type today.
			_field.set_tile(tile.x, tile.y, t["height"], t["type"], _active_type, bottom)


## Grow or shrink the map at the hovered edge `tile`. Left-click (`primary`) ADDS a
## row/column on every side the tile touches (two for a corner); right-click DELETES
## them. A delete that would leave the map smaller than 1 tile is refused. No-op on an
## interior tile (it touches no side). Clears the preview and refreshes the size readout.
func _apply_resize(tile: Vector2i, primary: bool) -> void:
	var sides := _field.sides_at(tile.x, tile.y)
	if sides.is_empty():
		return   # interior tile — nothing to resize from here
	if primary:
		_field.grow_sides(sides)
	elif not _field.shrink_sides(sides):
		print("MapDesigner: can't shrink — map already at its minimum size")
	_field.clear_resize_preview()   # the edit recentered the grid; recompute next hover
	_refresh_label()


## Set the active paint type to PALETTE[index] and refresh the HUD (text + swatch bar).
func _select_type(index: int) -> void:
	_active_type = PALETTE[index]
	_refresh_label()
	_refresh_swatches()


## Map a number-row keycode to a palette slot: keys 1-9 → slots 0-8, key 0 → slot 9.
## Returns -1 for any non-digit key. Lets the digit row quick-pick the common terrains.
func _digit_for_keycode(keycode: int) -> int:
	if keycode == KEY_0:
		return 9
	if keycode >= KEY_1 and keycode <= KEY_9:
		return keycode - KEY_1
	return -1


# --- New-map data -----------------------------------------------------------

## A single-state map of `w` x `h` flat grass tiles (height `NEW_TILE_HEIGHT`, dirt sides) — the blank
## canvas a New starts from. Returns the nested `states` form the field renders.
func _new_flat_states(w: int, h: int) -> Array:
	var grid: Array = []
	for x in w:
		var column: Array = []
		for z in h:
			column.append({"height": NEW_TILE_HEIGHT, "type": TileTypes.Type.GRASS, "body": TileTypes.Type.DIRT, "bottom": TileTypes.Type.DIRT})
		grid.append(column)
	return [grid]


# --- Save / load ------------------------------------------------------------

## Pack the field's current state into a MapData and write it to `path`.
func _on_save_path_chosen(path: String) -> void:
	var data := MapData.from_states(_field.states, _map_name)
	# res:// is writable when running from the editor (F6); ensure the folder exists.
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var err := data.save_to(path)
	print("MapDesigner: saved '%s' (%dx%d) -> %s [err %d]" % [_map_name, data.width, data.height, path, err])


## Load a MapData from `path` and rebuild the field to edit it.
func _on_load_path_chosen(path: String) -> void:
	var data := MapData.load_from(path)
	if data == null:
		print("MapDesigner: failed to load ", path)
		return
	_map_name = data.map_name
	_field.load_states(data.to_states())
	print("MapDesigner: loaded '%s' (%dx%d) from %s" % [_map_name, data.width, data.height, path])
	_refresh_label()


# --- HUD --------------------------------------------------------------------

## Build the on-screen help/status panel on its own CanvasLayer. A dark translucent
## panel sits behind the text so it stays readable over the light-blue sky / pale tiles.
func _build_hud() -> void:
	_hud_layer = CanvasLayer.new()
	add_child(_hud_layer)

	var panel := PanelContainer.new()
	panel.position = Vector2(12, 12)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.0, 0.0, 0.0, 0.6)
	sb.set_corner_radius_all(4)
	sb.set_content_margin_all(10)   # padding between the panel edge and the text
	panel.add_theme_stylebox_override("panel", sb)
	_hud_layer.add_child(panel)

	_label = Label.new()
	_label.add_theme_color_override("font_color", Color.WHITE)
	_label.add_theme_font_size_override("font_size", FONT_HUD)
	# Cap the panel width and wrap long lines, so the help text grows DOWN the left edge
	# instead of stretching across toward the swatch bar. Width is in 1080p-base pixels
	# (the project stretch scales it with the window). The PanelContainer shrink-wraps to
	# this, so the wrapped label sets both the panel's width and its height.
	_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_label.custom_minimum_size = Vector2(HUD_PANEL_WIDTH, 0)
	panel.add_child(_label)


## Build the terrain swatch bar — an ARPG-style skill bar across the top. One colored,
## clickable `Panel` per PALETTE type, labeled with its number-key binding. The bar
## spans the top but ignores mouse input itself (only the swatches catch clicks), so
## clicks elsewhere along the top still reach the 3D viewport for painting.
func _build_swatch_bar() -> void:
	var bar := HBoxContainer.new()
	bar.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	bar.offset_top = 8
	bar.alignment = BoxContainer.ALIGNMENT_CENTER
	bar.add_theme_constant_override("separation", 6)
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud_layer.add_child(bar)

	_swatches.clear()
	for i in PALETTE.size():
		var swatch := _make_swatch(i, PALETTE[i])
		bar.add_child(swatch)
		_swatches.append(swatch)
	_refresh_swatches()


## One swatch: a fixed-size `Panel` filled with the terrain's color, captioned with its
## number-key label, that selects PALETTE[`index`] when left-clicked. The caption uses a
## black outline so it stays legible on any swatch color; the label and bar ignore the
## mouse so the click lands on the panel (whose STOP filter also keeps it from leaking
## through to the painting handler).
func _make_swatch(index: int, type: int) -> Panel:
	var p := Panel.new()
	p.custom_minimum_size = Vector2(60, 60)
	p.mouse_filter = Control.MOUSE_FILTER_STOP
	p.tooltip_text = TileTypes.Type.keys()[type]   # hover shows the type name
	# Per-swatch StyleBoxFlat we own outright, so `_refresh_swatches` can recolor its
	# border to mark the active type without disturbing anything else.
	var sb := StyleBoxFlat.new()
	sb.bg_color = TileTypes.surface_color(type)
	sb.set_corner_radius_all(4)
	sb.set_border_width_all(2)
	sb.border_color = Color(0.0, 0.0, 0.0, 0.7)
	p.add_theme_stylebox_override("panel", sb)

	var lbl := Label.new()
	lbl.text = _swatch_key_label(index)
	lbl.add_theme_font_size_override("font_size", FONT_SWATCH)
	lbl.add_theme_color_override("font_color", Color.WHITE)
	lbl.add_theme_color_override("font_outline_color", Color.BLACK)
	lbl.add_theme_constant_override("outline_size", 4)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_child(lbl)

	# `.bind(index)` curries the slot index onto the signal callback (Godot's idiom for
	# passing extra args to a connection — like functools.partial).
	p.gui_input.connect(_on_swatch_gui_input.bind(index))
	return p


## The key-binding caption for swatch `index`: "1".."9" for the first nine, "0" for the
## tenth, and "[ ]" for any beyond (only QUICKSAND today — it has no digit, reachable
## via the `[`/`]` cycle). Mirrors `_digit_for_keycode`.
func _swatch_key_label(index: int) -> String:
	if index < 9:
		return str(index + 1)
	if index == 9:
		return "0"
	return "[ ]"


## A swatch was interacted with: select its type on a left-click. STOP mouse_filter
## already keeps this click from reaching the paint handler.
func _on_swatch_gui_input(event: InputEvent, index: int) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_select_type(index)


## Highlight the swatch of the active type (bright thick border) and reset the rest to a
## thin dark border. Mutates each swatch's own StyleBoxFlat in place, which repaints it.
func _refresh_swatches() -> void:
	for i in _swatches.size():
		var sb: StyleBoxFlat = _swatches[i].get_theme_stylebox("panel")
		var active: bool = PALETTE[i] == _active_type
		sb.set_border_width_all(4 if active else 2)
		sb.border_color = Color(1.0, 1.0, 1.0, 0.95) if active else Color(0.0, 0.0, 0.0, 0.7)


## Create (once) the save and open file pickers, scoped to the maps folder. Both get the
## shared theme (so the file list / buttons are legible) and a generous min_size — the
## old `popup_centered_ratio` rendered them uselessly small.
func _build_dialogs() -> void:
	_save_dialog = FileDialog.new()
	_save_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	_save_dialog.access = FileDialog.ACCESS_RESOURCES
	_save_dialog.current_dir = MAPS_DIR
	_save_dialog.add_filter("*.tres", "Map resource")
	_save_dialog.theme = _ui_theme
	_save_dialog.min_size = Vector2i(900, 620)
	_save_dialog.file_selected.connect(_on_save_path_chosen)
	add_child(_save_dialog)

	_open_dialog = FileDialog.new()
	_open_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_open_dialog.access = FileDialog.ACCESS_RESOURCES
	_open_dialog.current_dir = MAPS_DIR
	_open_dialog.add_filter("*.tres", "Map resource")
	_open_dialog.theme = _ui_theme
	_open_dialog.min_size = Vector2i(900, 620)
	_open_dialog.file_selected.connect(_on_load_path_chosen)
	add_child(_open_dialog)


## Build the New-map dialog: a name field plus width/length spinners. Confirming
## replaces the current map with a fresh flat grid of that size (the old map is
## discarded — same as the previous hardcoded New, just now sized + named by the user).
func _build_new_dialog() -> void:
	_new_dialog = AcceptDialog.new()
	_new_dialog.title = "New Map"
	_new_dialog.ok_button_text = "Create"
	_new_dialog.theme = _ui_theme   # font size for all its labels / inputs / buttons
	_new_dialog.min_size = Vector2i(460, 300)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8)
	_new_dialog.add_child(vb)
	vb.add_child(_field_label("Name"))
	_new_name_edit = LineEdit.new()
	_new_name_edit.text = "Untitled"
	vb.add_child(_new_name_edit)
	vb.add_child(_field_label("Width (X tiles)"))
	_new_width_spin = _make_spin(NEW_MAP_WIDTH)
	vb.add_child(_new_width_spin)
	vb.add_child(_field_label("Length (Z tiles)"))
	_new_height_spin = _make_spin(NEW_MAP_HEIGHT)
	vb.add_child(_new_height_spin)
	_new_dialog.confirmed.connect(_on_new_confirmed)
	add_child(_new_dialog)


## Build the Rename dialog: a single name field that rewrites the current map's name
## (kept in `_map_name`, written into the `.tres` on save) without touching its tiles.
func _build_rename_dialog() -> void:
	_rename_dialog = AcceptDialog.new()
	_rename_dialog.title = "Rename Map"
	_rename_dialog.ok_button_text = "Rename"
	_rename_dialog.theme = _ui_theme
	_rename_dialog.min_size = Vector2i(440, 200)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8)
	_rename_dialog.add_child(vb)
	vb.add_child(_field_label("Map name"))
	_rename_edit = LineEdit.new()
	vb.add_child(_rename_edit)
	# Let Enter in the field accept the dialog, not just clicking the button.
	_rename_dialog.register_text_enter(_rename_edit)
	_rename_dialog.confirmed.connect(_on_rename_confirmed)
	add_child(_rename_dialog)


## A caption above a dialog input. Font size comes from the dialog's shared theme.
func _field_label(text: String) -> Label:
	var lbl := Label.new()
	lbl.text = text
	return lbl


## A 1-step integer SpinBox for a grid dimension, seeded with `value`. Capped at a
## sane upper bound so a fat-fingered entry can't spawn a colossal grid. Font size comes
## from the dialog's shared theme.
func _make_spin(value: int) -> SpinBox:
	var spin := SpinBox.new()
	spin.min_value = 1
	spin.max_value = 64
	spin.step = 1
	spin.value = value
	return spin


## Create a fresh flat map at the chosen size + name, discarding the current one.
func _on_new_confirmed() -> void:
	var w := int(_new_width_spin.value)
	var h := int(_new_height_spin.value)
	_map_name = _clean_name(_new_name_edit.text)
	_field.load_states(_new_flat_states(w, h))
	_refresh_label()


## Apply the typed name to the current map (tiles untouched).
func _on_rename_confirmed() -> void:
	_map_name = _clean_name(_rename_edit.text)
	_refresh_label()


## Trim a typed map name and fall back to "Untitled" if it's blank.
func _clean_name(raw: String) -> String:
	var trimmed := raw.strip_edges()
	return trimmed if not trimmed.is_empty() else "Untitled"


## Whether any modal dialog (new / rename / save / open) is currently shown. Used to
## suspend hover feedback and hotkeys while a dialog owns input.
func _dialog_open() -> bool:
	return _new_dialog.visible or _rename_dialog.visible \
		or _save_dialog.visible or _open_dialog.visible


## Re-render the status/help text from the current tool + active type + map size.
func _refresh_label() -> void:
	var w: int = _field.grid_width
	var h: int = _field.grid_height
	_label.text = "\n".join([
		"MAP DESIGNER  —  %s  (%dx%d)" % [_map_name, w, h],
		"Tool: %s            [Tab] cycle tool" % Tool.keys()[_tool],
		"Type: %s            [ and ] cycle, 1-0 quick-pick" % TileTypes.Type.keys()[_active_type],
		"",
		"HEIGHT tool: L-click raise, R-click lower",
		"PAINT tool: L-click paints the active type on the clicked FACE",
		"   top=surface, sides=body, underside=bottom (orbit under the map to reach it)",
		"RESIZE tool: hover an edge — L-click adds, R-click deletes (corner = both sides)",
		"Camera: wheel zoom, Q/E orbit, middle-drag free-orbit (drag down to go under)",
		"[N] new   [R] rename   [S] save   [L] load",
	])
