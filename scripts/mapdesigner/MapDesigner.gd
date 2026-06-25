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
const MAX_HEIGHT := 20

## Where maps are saved/loaded by default (authored content lives in the project).
const MAPS_DIR := "res://assets/maps"

## Translucent white cursor laid on the hovered tile (reuses Battlefield's active marker).
const HOVER_COLOR := Color(1.0, 1.0, 1.0, 0.45)

## Which tile attribute the mouse edits.
enum Tool { HEIGHT, SURFACE, BODY }

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
var _label: Label
var _save_dialog: FileDialog
var _open_dialog: FileDialog


## Build the field (seeded with a blank map), the HUD, and the file dialogs.
func _ready() -> void:
	_field = EditableBattlefield.new()
	_field.name = "EditableBattlefield"
	# Seed the starting map BEFORE entering the tree, so the base _ready builds this
	# blank grid directly instead of the 24x24 DemoMap fallback.
	_field.states = _new_flat_states(NEW_MAP_WIDTH, NEW_MAP_HEIGHT)
	add_child(_field)

	_build_hud()
	_build_dialogs()
	_refresh_label()


## Each frame, highlight the tile under the mouse (or clear the cursor when off-grid).
func _process(_delta: float) -> void:
	var tile := _field.tile_at_screen_point(_camera, get_viewport().get_mouse_position())
	if tile == Battlefield.INVALID_TILE:
		_field.clear_active_tile()
	else:
		_field.set_active_tile(tile, HOVER_COLOR)


## Keyboard (tools / palette / file ops) and mouse painting. Uses `_unhandled_input` so
## any open FileDialog consumes its own events first.
func _unhandled_input(event: InputEvent) -> void:
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
			_field.load_states(_new_flat_states(NEW_MAP_WIDTH, NEW_MAP_HEIGHT))
			_map_name = "Untitled"
			_refresh_label()
		KEY_S:
			_save_dialog.popup_centered_ratio(0.6)
		KEY_L:
			_open_dialog.popup_centered_ratio(0.6)
		_:
			# Number keys 1-9 then 0 quick-select palette slots 0-9.
			var digit := _digit_for_keycode(keycode)
			if digit >= 0 and digit < PALETTE.size():
				_select_type(digit)


## Apply the current tool to the tile under the mouse. `primary` = left click.
func _paint_under_mouse(primary: bool) -> void:
	var tile := _field.tile_at_screen_point(_camera, get_viewport().get_mouse_position())
	if tile == Battlefield.INVALID_TILE:
		return
	var t := _field.tile_data(tile.x, tile.y)
	if t.is_empty():
		return
	match _tool:
		Tool.HEIGHT:
			# Left raises, right lowers — by one level, clamped.
			var delta := 1 if primary else -1
			var new_h: int = clampi(t["height"] + delta, MIN_HEIGHT, MAX_HEIGHT)
			_field.set_tile(tile.x, tile.y, new_h, t["type"], t["body"])
		Tool.SURFACE:
			if primary:
				_field.set_tile(tile.x, tile.y, t["height"], _active_type, t["body"])
		Tool.BODY:
			if primary:
				_field.set_tile(tile.x, tile.y, t["height"], t["type"], _active_type)


## Set the active paint type to PALETTE[index] and refresh the HUD.
func _select_type(index: int) -> void:
	_active_type = PALETTE[index]
	_refresh_label()


## Map a number-row keycode to a palette slot: keys 1-9 → slots 0-8, key 0 → slot 9.
## Returns -1 for any non-digit key. Lets the digit row quick-pick the common terrains.
func _digit_for_keycode(keycode: int) -> int:
	if keycode == KEY_0:
		return 9
	if keycode >= KEY_1 and keycode <= KEY_9:
		return keycode - KEY_1
	return -1


# --- New-map data -----------------------------------------------------------

## A single-state map of `w` x `h` flat grass tiles (height 1, dirt sides) — the blank
## canvas a New starts from. Returns the nested `states` form the field renders.
func _new_flat_states(w: int, h: int) -> Array:
	var grid: Array = []
	for x in w:
		var column: Array = []
		for z in h:
			column.append({"height": 1, "type": TileTypes.Type.GRASS, "body": TileTypes.Type.DIRT})
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
	var layer := CanvasLayer.new()
	add_child(layer)

	var panel := PanelContainer.new()
	panel.position = Vector2(12, 12)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.0, 0.0, 0.0, 0.6)
	sb.set_corner_radius_all(4)
	sb.set_content_margin_all(10)   # padding between the panel edge and the text
	panel.add_theme_stylebox_override("panel", sb)
	layer.add_child(panel)

	_label = Label.new()
	_label.add_theme_color_override("font_color", Color.WHITE)
	# Large, readable on high-res displays — the default ~16px is far too small here.
	_label.add_theme_font_size_override("font_size", 28)
	panel.add_child(_label)


## Create (once) the save and open file pickers, scoped to the maps folder.
func _build_dialogs() -> void:
	_save_dialog = FileDialog.new()
	_save_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	_save_dialog.access = FileDialog.ACCESS_RESOURCES
	_save_dialog.current_dir = MAPS_DIR
	_save_dialog.add_filter("*.tres", "Map resource")
	_save_dialog.file_selected.connect(_on_save_path_chosen)
	add_child(_save_dialog)

	_open_dialog = FileDialog.new()
	_open_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_open_dialog.access = FileDialog.ACCESS_RESOURCES
	_open_dialog.current_dir = MAPS_DIR
	_open_dialog.add_filter("*.tres", "Map resource")
	_open_dialog.file_selected.connect(_on_load_path_chosen)
	add_child(_open_dialog)


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
		"SURFACE / BODY tool: L-click paints the active type",
		"Camera: wheel zoom, Q/E orbit, middle-drag free-orbit",
		"[N] new   [S] save   [L] load",
	])
