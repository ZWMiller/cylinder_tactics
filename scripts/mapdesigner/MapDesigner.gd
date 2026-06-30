## The in-game map designer (Phase 1): paint heights and terrain types onto a grid by
## mouse and save the result as a `MapData` `.tres`, or load one back to edit. Run it
## with F6 on `scenes/MapDesigner.tscn`.
##
## It renders through an `EditableBattlefield` (a `Battlefield` subclass) so what you
## build looks EXACTLY like a battle map — same two-layer body/cap columns and picking,
## no duplicated rendering. This script owns only the *interaction*: a current tool, an
## active terrain type, mouse painting, and New/Save/Load.
##
## Scope note: this is the single-state cut. Painting now supports the Phase-2 brush macros
## (SINGLE / SQUARE / CIRCLE / LINE / HILL with a configurable size + click-drag height),
## all routed through `EditableBattlefield.set_tiles` for one redraw per edit. Multi-state
## (shift-sequence) editing and the encounter layer are still deferred (Phases 3-4).
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

## Brush size (radius, in tiles) clamps for the SQUARE / CIRCLE / HILL brushes. 0 = a single
## tile; each step out adds a ring, so a CIRCLE of size 2 is a 5-tile-wide disc.
const MIN_BRUSH_SIZE := 0
const MAX_BRUSH_SIZE := 8

## Screen pixels of vertical mouse drag that equal one height level, for the click-drag
## height edit (and the Hill brush's peak). Smaller = more sensitive. Tuned by feel.
const DRAG_PX_PER_LEVEL := 16.0

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

## The brush SHAPE — which tiles one edit touches. Orthogonal to the Tool: the brush picks
## the footprint, the tool (HEIGHT / PAINT) decides what happens to each tile in it. Cycled
## with `B`; SQUARE / CIRCLE / HILL also read the brush size (`-` / `=`).
##   SINGLE  — one tile (the classic per-tile edit; PAINT stays face-aware here).
##   SQUARE  — a (2·size+1)² block centered on the tile.
##   CIRCLE  — a disc of radius `size`.
##   LINE    — a 1-wide tile line dragged from press to release (Bresenham). PAINT draws the
##             type along it; HEIGHT flattens it to the start tile's height.
##   HILL    — a falloff dome/bowl (peak at center, fading to the rim). Inherently a HEIGHT
##             brush, so it ignores the Tool. Drag UP raises a hill; drag DOWN digs a valley
##             (a sunken bowl) — now that heights aren't floored at the start level, the same
##             brush carves terrain both directions.
## RESIZE ignores the brush entirely (it edits grid EDGES, not tiles).
enum Brush { SINGLE, SQUARE, CIRCLE, LINE, HILL }

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
var _brush: int = Brush.SINGLE        ## Active brush shape (see Brush).
var _brush_size: int = 1              ## Radius for SQUARE / CIRCLE / HILL (tiles out from center).
var _active_type: int = TileTypes.Type.GRASS  ## Terrain type the PAINT tool paints.
var _map_name: String = "Untitled"    ## Saved into the MapData; not the filename.

# --- Drag session (left-button press → drag → release) ----------------------
# A left-click on a painting tool opens a drag: we snapshot the state, then re-derive the
# whole edit from the snapshot every frame as the mouse moves (vertical distance → height
# levels for HEIGHT/HILL; the hovered tile → the line/paint footprint). Re-deriving from a
# fixed base (rather than accumulating) is what lets a drag be scrubbed freely — pull a line
# back, drag a hill down past flat — without the edit compounding on itself.

# --- Undo history -----------------------------------------------------------
# A small ring of recent map snapshots so any edit can be taken back with `U`. Each entry
# captures BOTH the full state stack and the map name, so it reverts brush strokes, resizes,
# AND a New/Load/Rename. Pushed BEFORE a change lands (so the top of the stack is the state to
# return to); capped at UNDO_DEPTH, dropping the oldest. One push per interaction (a whole
# drag is a single undo step, not one per frame), so `U` walks back edits at a human pace.
const UNDO_DEPTH := 5
var _undo_stack: Array = []   ## Most-recent snapshot is last; each is { "states", "name" }.

var _dragging: bool = false                              ## A left-drag is in progress.
var _drag_start_tile: Vector2i = Battlefield.INVALID_TILE  ## Tile under the initial press.
var _drag_start_face: int = TileFaces.Face.TOP           ## Face picked at the press — which layer a PAINT brush writes for the whole stroke.
var _drag_start_y: float = 0.0                           ## Mouse Y at press (height-drag origin).
var _drag_levels: int = 0                                ## Current height delta from the vertical drag.
var _drag_base: Array = []                               ## Deep snapshot of the state at press (restore source).
var _drag_last_footprint: Array = []                     ## Tiles written last apply (restored as the footprint shrinks).

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
var _new_sculpted_check: CheckBox   ## New dialog: on = Sculpted depth, off = Auto (the default).
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
	add_child(_field)   # enters the tree → base _ready builds + renders the seeded grid

	# Frame the freshly built grid centered. A new map starts every tile at NEW_TILE_HEIGHT
	# (world y well above 0), so without this the map floats up out of the camera's y=0 look-at
	# (the off-center bug). Recentred again on every New / Load / Undo / Resize below.
	_recenter_camera()

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
		_clear_cursors()
		return
	# Face-aware pick: the PAINT cursor highlights whichever FACE is under the mouse.
	var pick := _field.tile_and_face_at_screen_point(_camera, get_viewport().get_mouse_position())
	var tile: Vector2i = pick["tile"]
	# A live drag owns the feedback: update the edit + the footprint preview, ignore hover.
	if _dragging:
		_field.clear_hover_face()
		_field.clear_resize_preview()
		_update_drag(tile)
		return
	if _tool == Tool.RESIZE:
		# No paint cursor in resize mode; the green/red edge previews carry the meaning.
		_field.clear_hover_face()
		_field.clear_footprint()
		var sides := _field.sides_at(tile.x, tile.y)   # [] off-grid or on an interior tile
		if sides.is_empty():
			_field.clear_resize_preview()
		else:
			_field.show_resize_preview(sides)
		return
	# Painting tools: make sure no stale resize ghost lingers, then show the brush cursor.
	_field.clear_resize_preview()
	_update_hover_preview(tile, pick["face"])


## Show the brush cursor for the hovered tile (not dragging). The SINGLE brush under PAINT
## keeps the face-aware single-quad cursor (so you can still aim at a side/underside); every
## other brush shows its multi-tile footprint highlighted on the tile tops.
func _update_hover_preview(tile: Vector2i, face: int) -> void:
	if tile == Battlefield.INVALID_TILE:
		_clear_cursors()
		return
	if _brush == Brush.SINGLE and _tool == Tool.PAINT:
		_field.clear_footprint()
		_field.set_hover_face(tile, face, HOVER_COLOR)
	else:
		_field.clear_hover_face()
		_field.show_footprint(_brush_footprint(tile), _footprint_face(face), HOVER_COLOR)


## Which face a shape brush's footprint should preview on (and paint). A PAINT shape brush follows
## whichever face the cursor picked; a Sculpted FLOOR edit (HEIGHT tool on the underside) previews on
## the BOTTOM; every other height edit (HEIGHT on top, HILL) previews flat on the TOP.
func _footprint_face(picked_face: int) -> int:
	if _tool == Tool.PAINT and _brush != Brush.HILL:
		return picked_face
	if _editing_floor_for(picked_face):
		return TileFaces.Face.BOTTOM
	return TileFaces.Face.TOP


## Whether an edit aimed at `face` should move the authored FLOOR instead of the top: only in
## Sculpted mode, with the HEIGHT tool, when pointing at the underside. This is the single rule that
## turns "HEIGHT tool on the bottom face" into bottom-surface sculpting; HILL stays top-only (it
## ignores the tool), and PAINT routes by face through `_paint_layers` instead.
func _editing_floor_for(face: int) -> bool:
	return _field.is_sculpted_depth() and _tool == Tool.HEIGHT and face == TileFaces.Face.BOTTOM


## Clamp a new TOP height. In Sculpted mode the top can never drop BELOW the tile's fixed seam
## `anchor` (its starting height) — so the top only ever rises above the impassable 1-level seam,
## decoupled from the floor. Auto mode has no seam (clamps to the plain band).
func _clamp_top(height: int, anchor: int) -> int:
	var lo := MIN_HEIGHT
	if _field.is_sculpted_depth():
		lo = maxi(MIN_HEIGHT, anchor)
	return clampi(height, lo, MAX_HEIGHT)


## Clamp a new FLOOR level. The floor can never rise ABOVE `anchor - 1` (one below the seam), so the
## seam band `[anchor-1, anchor]` is always solid and the floor only ever sinks below it. This is
## what makes a disconnected/floating slab impossible: raising the top can't drag the floor's ceiling
## up with it (the ceiling is the fixed anchor, not the live top).
func _clamp_floor(floor_level: int, anchor: int) -> int:
	return clampi(floor_level, MIN_HEIGHT, anchor - 1)


## Hide every designer cursor (face quad, footprint quads, resize ghosts) at once.
func _clear_cursors() -> void:
	_field.clear_hover_face()
	_field.clear_footprint()
	_field.clear_resize_preview()


## Keyboard (tools / palette / file ops) and mouse painting. Uses `_unhandled_input` so
## any open FileDialog consumes its own events first.
func _unhandled_input(event: InputEvent) -> void:
	# While a dialog is open it owns input — ignore stray hotkeys/clicks that leak
	# through (text fields consume their own typing before _unhandled_input runs).
	if _dialog_open():
		return
	if event is InputEventKey and event.pressed and not event.echo:
		_handle_key(event.keycode)
	elif event is InputEventMouseButton:
		_handle_mouse_button(event)


## Route a mouse button. Left opens/closes a drag (or does the immediate RESIZE / face-paint
## that don't drag); right is a one-shot lower/dig (height brushes only). The pick is resolved
## once here from the cursor; off-grid presses are no-ops.
func _handle_mouse_button(event: InputEventMouseButton) -> void:
	var pick := _field.tile_and_face_at_screen_point(_camera, get_viewport().get_mouse_position())
	var tile: Vector2i = pick["tile"]
	if event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			if _tool == Tool.RESIZE:
				_apply_resize(tile, true)            # grow the hovered edge — no drag
			elif _tool == Tool.PAINT and _brush == Brush.SINGLE:
				_paint_single_face(tile, pick["face"])  # face-aware one-tile paint — no drag
			else:
				_begin_drag(tile, pick["face"])
		elif _dragging:
			_end_drag()
	elif event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		if _tool == Tool.RESIZE:
			_apply_resize(tile, false)               # shrink the hovered edge
		else:
			_apply_secondary(tile, pick["face"])     # quick lower / dig (floor on the underside)


## Dispatch a key press to a tool/palette/file action.
func _handle_key(keycode: int) -> void:
	match keycode:
		KEY_TAB:
			_tool = (_tool + 1) % Tool.size()
			_refresh_label()
		KEY_B:
			# Cycle the brush shape (Single → Square → Circle → Line → Hill → …).
			_brush = (_brush + 1) % Brush.size()
			_refresh_label()
		KEY_U:
			_undo()
		KEY_MINUS:
			_brush_size = clampi(_brush_size - 1, MIN_BRUSH_SIZE, MAX_BRUSH_SIZE)
			_refresh_label()
		KEY_EQUAL:
			_brush_size = clampi(_brush_size + 1, MIN_BRUSH_SIZE, MAX_BRUSH_SIZE)
			_refresh_label()
		KEY_BRACKETRIGHT:
			_select_type((PALETTE.find(_active_type) + 1) % PALETTE.size())
		KEY_BRACKETLEFT:
			_select_type((PALETTE.find(_active_type) - 1 + PALETTE.size()) % PALETTE.size())
		KEY_N:
			# Prefill the dialog with the current map's name/size/mode, then let the user edit.
			_new_name_edit.text = _map_name
			_new_width_spin.value = _field.grid_width
			_new_height_spin.value = _field.grid_height
			_new_sculpted_check.button_pressed = _field.is_sculpted_depth()
			_new_dialog.popup_centered()
		KEY_M:
			_toggle_depth_mode()   # convert the CURRENT map between Auto and Sculpted (undoable)
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


## Paint `_active_type` onto the clicked `face` of tile (x, z), leaving its other faces
## untouched — the SINGLE-brush PAINT path (no drag). TOP sets the surface type, BOTTOM the
## underside type, and any of the four sides the (shared) body type. This match is the single
## place "clicked face → which layer" lives — it's what grows when N/S/E/W become
## independently typed (each side would target its own field instead of all sharing `body`).
func _paint_single_face(tile: Vector2i, face: int) -> void:
	if tile == Battlefield.INVALID_TILE:
		return
	var t := _field.tile_data(tile.x, tile.y)
	if t.is_empty():
		return
	_push_undo()
	var bottom: int = t.get("bottom", t["body"])
	var layers := _paint_layers(face, t["type"], t["body"], bottom, _active_type)
	# Painting a face never moves the underside — keep the tile's authored floor (set_tile defaults
	# to preserving it, so we don't pass one).
	_field.set_tile(tile.x, tile.y, t["height"], layers[0], layers[1], layers[2])


## The (surface, body, bottom) terrain types after painting `active` onto `face` of a tile whose
## current layers are `surface`/`body`/`bottom`. The single place the "clicked face → which layer"
## rule lives: TOP repaints the surface, BOTTOM the underside, and any of the four sides the
## (shared) body. Returns `[surface, body, bottom]`. Shared by the SINGLE-brush face paint and the
## shape-brush stroke so both layer the same way. This match is what grows when N/S/E/W become
## independently typed (each side would target its own field instead of all sharing `body`).
func _paint_layers(face: int, surface: int, body: int, bottom: int, active: int) -> Array:
	match face:
		TileFaces.Face.TOP:
			return [active, body, bottom]
		TileFaces.Face.BOTTOM:
			return [surface, body, active]
		_:
			return [surface, active, bottom]


# --- Brush drag engine ------------------------------------------------------

## Open a drag session on a left press over `tile`. Snapshots the whole state so every later
## frame can re-derive the edit from the original terrain (see the `_drag_*` block). Applies
## the initial footprint immediately (delta 0), so a press already shows the brush in place.
func _begin_drag(tile: Vector2i, face: int) -> void:
	if tile == Battlefield.INVALID_TILE:
		return
	_push_undo()   # one undo step for the whole stroke (snapshot before it lands)
	_dragging = true
	_drag_start_tile = tile
	# Lock the paint face for the whole stroke from the press — so dragging across faces (or off
	# the geometry mid-stroke) doesn't flip which layer (surface/body/bottom) the brush writes.
	_drag_start_face = face
	_drag_start_y = get_viewport().get_mouse_position().y
	_drag_levels = 0
	_drag_base = _snapshot_state()
	_drag_last_footprint = []
	_update_drag(tile)


## Re-derive and apply the drag's edit for the current hovered `tile`. Vertical mouse travel
## since the press becomes a height delta (up = raise); the rest of the footprint follows the
## brush. Called every frame while dragging.
func _update_drag(tile: Vector2i) -> void:
	_drag_levels = int(round((_drag_start_y - get_viewport().get_mouse_position().y) / DRAG_PX_PER_LEVEL))
	var edits := _build_drag_edits(tile)
	_apply_drag_edits(edits)
	# Preview the footprint over whatever the edit just touched, on the locked paint face.
	var footprint: Array = []
	for e in edits:
		footprint.append(Vector2i(e["x"], e["z"]))
	_field.show_footprint(footprint, _footprint_face(_drag_start_face), HOVER_COLOR)


## Finish the drag. A press-and-release with no vertical movement reads as a plain CLICK: for
## the height-style brushes that means apply the discrete default (a Hill stamps a dome of
## height = brush size; the others nudge +1), matching the old single-click feel. Paint/Line
## already applied on press, so they need nothing extra.
func _end_drag() -> void:
	if _is_height_step_brush() and _drag_levels == 0:
		_drag_levels = _brush_size if _brush == Brush.HILL else 1
		_apply_drag_edits(_build_drag_edits(_drag_start_tile))
	_dragging = false
	_drag_last_footprint = []
	_field.clear_footprint()


## Whether the active brush edits HEIGHT on a click (so a no-drag click should apply a discrete
## step): any HILL, or a HEIGHT-tool brush that isn't LINE (LINE flattens regardless of drag).
func _is_height_step_brush() -> bool:
	if _brush == Brush.HILL:
		return true
	return _tool == Tool.HEIGHT and _brush != Brush.LINE


## A one-shot right-click: lower (HEIGHT brushes) or dig a bowl (HILL) under `tile`, by one
## step / one brush-size, read straight from the current state (no drag snapshot). Paint and
## Line ignore right-click — there's no "un-paint", and a line needs a drag to have length.
func _apply_secondary(tile: Vector2i, face: int) -> void:
	if tile == Battlefield.INVALID_TILE:
		return
	var center := _field.tile_data(tile.x, tile.y)
	if center.is_empty():
		return
	var floor_edit := _editing_floor_for(face)   # right-click on the underside lowers the FLOOR
	var edits: Array = []
	if _brush == Brush.HILL:
		# Dig a bowl in the TOP: a downward dome (negative peak = -brush size) sunk from the center
		# tile (HILL ignores the face). Source reads live tile data, wrapped to take a Vector2i.
		edits = _dome_edits(tile, center["height"], -_brush_size, func(t: Vector2i) -> Dictionary: return _field.tile_data(t.x, t.y))
	elif _tool == Tool.HEIGHT and _brush != Brush.LINE:
		for t in _brush_footprint(tile):
			var d := _field.tile_data(t.x, t.y)
			if d.is_empty():
				continue
			var fl: int = d.get("floor", d["height"] - 1)
			var anchor: int = d.get("anchor", d["height"])
			if floor_edit:
				# Lower the underside by one level (never above the seam), top untouched.
				edits.append(_tile_edit(t, d["height"], d["type"], d["body"], d.get("bottom", d["body"]), _clamp_floor(fl - 1, anchor), anchor))
			else:
				# Lower the top by one level (never below the seam), underside untouched.
				edits.append(_tile_edit(t, _clamp_top(d["height"] - 1, anchor), d["type"], d["body"], d.get("bottom", d["body"]), fl, anchor))
	if not edits.is_empty():
		_push_undo()
		_field.set_tiles(edits)


# --- Drag edit construction -------------------------------------------------

## Build the complete tile-edit list for the current drag state, hovering `tile`. Reads the
## pre-drag snapshot (`_drag_base`) as the source so the edit never compounds. Routes by brush:
## HILL → falloff dome; LINE → painted/flattened line; the rest → footprint paint or height
## shift. Each entry is a full `{x,z,height,type,body,bottom}` dict for `set_tiles`.
func _build_drag_edits(tile: Vector2i) -> Array:
	if _brush == Brush.HILL:
		var c := _base_tile(_drag_start_tile)
		return _dome_edits(_drag_start_tile, c["height"], _drag_levels, _base_tile)
	var edits: Array = []
	var floor_edit := _editing_floor_for(_drag_start_face)   # sculpting the underside this stroke?
	for t in _drag_footprint(tile):
		var b := _base_tile(t)
		if b.is_empty():
			continue
		var bottom: int = b.get("bottom", b["body"])
		var floor_level: int = b.get("floor", b["height"] - 1)
		var anchor: int = b.get("anchor", b["height"])   # fixed seam — both clamps reference it
		if _tool == Tool.PAINT:
			# Write the active type into the layer the LOCKED press face targets (top=surface,
			# sides=body, underside=bottom) — the shape-brush twin of the single-face paint. The
			# underside LEVEL is untouched (painting never moves geometry).
			var layers := _paint_layers(_drag_start_face, b["type"], b["body"], bottom, _active_type)
			edits.append(_tile_edit(t, b["height"], layers[0], layers[1], layers[2], floor_level, anchor))
		elif _brush == Brush.LINE:
			if floor_edit:
				# Flatten the underside LINE to the floor the drag started on (clamped under the seam).
				var flat_floor: int = _base_tile(_drag_start_tile).get("floor", _base_tile(_drag_start_tile)["height"] - 1)
				edits.append(_tile_edit(t, b["height"], b["type"], b["body"], bottom, _clamp_floor(flat_floor, anchor), anchor))
			else:
				# Flatten the TOP line to the height the drag STARTED on (level a path across bumps).
				var flat: int = _base_tile(_drag_start_tile)["height"]
				edits.append(_tile_edit(t, _clamp_top(flat, anchor), b["type"], b["body"], bottom, floor_level, anchor))
		elif floor_edit:
			# HEIGHT tool on the underside: shift the FLOOR by the drag (never above the seam), top untouched.
			edits.append(_tile_edit(t, b["height"], b["type"], b["body"], bottom, _clamp_floor(floor_level + _drag_levels, anchor), anchor))
		else:
			# HEIGHT tool on the top: shift the height (never below the seam), underside untouched.
			edits.append(_tile_edit(t, _clamp_top(b["height"] + _drag_levels, anchor), b["type"], b["body"], bottom, floor_level, anchor))
	return edits


## The dome/bowl edit set centered on `center`, raising each tile toward `base_h + peak` with a
## linear falloff to the rim (radius = brush size). `peak` can be negative (a bowl). `source` is
## the read function for each tile's other layers (`_base_tile` while dragging, `tile_data` for
## the right-click dig) so the dome preserves surface/body/bottom. Tiles read from the disc.
func _dome_edits(center: Vector2i, base_h: int, peak: int, source: Callable) -> Array:
	var edits: Array = []
	var radius := float(_brush_size + 1)   # +1 so the rim tile still gets a sliver, not zero
	for t in _disc_tiles(center, _brush_size):
		var src: Dictionary = source.call(t)
		if src.is_empty():
			continue
		var dist := Vector2(t.x - center.x, t.y - center.y).length()
		# Linear falloff: full peak at the center, fading to ~0 at the rim. round() keeps it
		# on the integer height grid; a negative peak digs symmetrically.
		var contrib := int(round(peak * (1.0 - dist / radius)))
		# HILL sculpts the TOP only (it ignores the tool/face); keep the authored floor + seam and
		# clamp the new top to the seam so a dug bowl can't drop below it in Sculpted mode.
		var src_floor: int = src.get("floor", src["height"] - 1)
		var src_anchor: int = src.get("anchor", src["height"])
		var target := _clamp_top(base_h + contrib, src_anchor)
		edits.append(_tile_edit(t, target, src["type"], src["body"], src.get("bottom", src["body"]), src_floor, src_anchor))
	return edits


## Apply a drag's `edits` in ONE redraw, first restoring any tile that was in the LAST applied
## footprint but isn't now — so scrubbing a line shorter or sliding a paint brush leaves no
## trail. Restored values come from the pre-drag snapshot. Records the new footprint.
func _apply_drag_edits(edits: Array) -> void:
	var new_keys := {}
	for e in edits:
		new_keys[Vector2i(e["x"], e["z"])] = true
	var batch: Array = []
	for t in _drag_last_footprint:
		var tile: Vector2i = t
		if not new_keys.has(tile):
			var b := _base_tile(tile)
			batch.append(_tile_edit(tile, b["height"], b["type"], b["body"], b.get("bottom", b["body"]), b.get("floor", b["height"] - 1), b.get("anchor", b["height"])))
	batch.append_array(edits)
	_field.set_tiles(batch)
	_drag_last_footprint = new_keys.keys()


# --- Brush footprint geometry -----------------------------------------------

## The footprint for the HOVER cursor at `center` (not dragging): a single tile for SINGLE and
## LINE (a line has no length until you drag), otherwise the brush's full shape.
func _brush_footprint(center: Vector2i) -> Array:
	match _brush:
		Brush.SQUARE:
			return _square_tiles(center, _brush_size)
		Brush.CIRCLE, Brush.HILL:
			return _disc_tiles(center, _brush_size)
		_:
			return [center]   # SINGLE, LINE


## The footprint during a DRAG hovering `tile`. LINE spans press→hover; the height brushes stay
## anchored at the press tile (so vertical drag doesn't drag the shape around), while PAINT
## brushes follow the cursor so you can paint a swath as you move.
func _drag_footprint(tile: Vector2i) -> Array:
	if _brush == Brush.LINE:
		return _line_tiles(_drag_start_tile, tile)
	if _tool == Tool.PAINT and tile != Battlefield.INVALID_TILE:
		return _brush_footprint(tile)
	return _brush_footprint(_drag_start_tile)


## All tiles within Chebyshev (chessboard) distance `r` of center — a (2r+1)² square.
func _square_tiles(center: Vector2i, r: int) -> Array:
	var tiles: Array = []
	for dx in range(-r, r + 1):
		for dz in range(-r, r + 1):
			tiles.append(Vector2i(center.x + dx, center.y + dz))
	return tiles


## All tiles within Euclidean distance `r` (+½ so the rim reads round, not clipped) — a disc.
func _disc_tiles(center: Vector2i, r: int) -> Array:
	var tiles: Array = []
	var limit := (r + 0.5) * (r + 0.5)
	for dx in range(-r, r + 1):
		for dz in range(-r, r + 1):
			if dx * dx + dz * dz <= limit:
				tiles.append(Vector2i(center.x + dx, center.y + dz))
	return tiles


## The 1-wide tile line from `a` to `b` (Bresenham). Used by the LINE brush while dragging.
func _line_tiles(a: Vector2i, b: Vector2i) -> Array:
	var tiles: Array = []
	var x := a.x
	var z := a.y
	var dx := absi(b.x - a.x)
	var dz := absi(b.y - a.y)
	var sx := 1 if b.x > a.x else -1
	var sz := 1 if b.y > a.y else -1
	var err := dx - dz
	while true:
		tiles.append(Vector2i(x, z))
		if x == b.x and z == b.y:
			break
		var e2 := 2 * err
		if e2 > -dz:
			err -= dz
			x += sx
		if e2 < dx:
			err += dx
			z += sz
	return tiles


# --- Drag snapshot helpers --------------------------------------------------

## A deep copy of the current state's tile dicts, so a drag can restore from it without the
## live edits aliasing back into the snapshot. Indexed `[x][z]`.
func _snapshot_state() -> Array:
	var snap: Array = []
	for column in _field.current_state():
		var col: Array = []
		for t in column:
			col.append((t as Dictionary).duplicate())
		snap.append(col)
	return snap


## The pre-drag snapshot tile at (x, z); empty dict if off-grid. Matches `tile_data`'s shape so
## the two are interchangeable as a `source` Callable for `_dome_edits`.
func _base_tile(tile: Vector2i) -> Dictionary:
	if tile.x < 0 or tile.x >= _field.grid_width or tile.y < 0 or tile.y >= _field.grid_height:
		return {}
	return _drag_base[tile.x][tile.y]


## A `set_tiles` edit entry — the one place the dict shape is spelled out. `floor` is the authored
## bottom level and `anchor` the fixed seam (both Sculpted-only; Auto maps carry them along
## harmlessly — the renderer ignores both). Every edit preserves the tile's existing `anchor` (it's
## only (re)set on New / convert / resize), so callers pass the base tile's anchor straight through.
func _tile_edit(tile: Vector2i, height: int, type: int, body: int, bottom: int, floor_level: int, anchor: int) -> Dictionary:
	return {"x": tile.x, "z": tile.y, "height": height, "type": type, "body": body, "bottom": bottom, "floor": floor_level, "anchor": anchor}


## Grow or shrink the map at the hovered edge `tile`. Left-click (`primary`) ADDS a
## row/column on every side the tile touches (two for a corner); right-click DELETES
## them. A delete that would leave the map smaller than 1 tile is refused. No-op on an
## interior tile (it touches no side). Clears the preview and refreshes the size readout.
func _apply_resize(tile: Vector2i, primary: bool) -> void:
	var sides := _field.sides_at(tile.x, tile.y)
	if sides.is_empty():
		return   # interior tile — nothing to resize from here
	_push_undo()
	var changed := true
	if primary:
		_field.grow_sides(sides)
	elif not _field.shrink_sides(sides):
		print("MapDesigner: can't shrink — map already at its minimum size")
		changed = false
	if not changed:
		_undo_stack.pop_back()   # the shrink was refused — discard the unused snapshot
	_field.clear_resize_preview()   # the edit recentered the grid; recompute next hover
	if changed:
		_recenter_camera()          # the grid moved/regrew — reframe it centered
	_refresh_label()


## Point the designer camera at the current grid's center so the whole map frames centered.
## Called on every STRUCTURAL change (New / Load / Undo / Resize, and the initial build) — NOT
## on per-tile brush edits, which would make the view jump around while you paint. The center's
## Y tracks the terrain's height band (see `Battlefield.grid_center_world`), which is what fixes
## a high-altitude map (new maps start at level 20) rendering above the camera's look-at.
func _recenter_camera() -> void:
	_camera.snap_to(_field.grid_center_world())


## Convert the CURRENT map between Auto and Sculpted depth (the `M` key) — the "switchable later"
## path, made fully undoable by snapshotting first. Auto→Sculpted bakes the currently-derived
## undersides into authored floors so nothing visually jumps; Sculpted→Auto just resumes deriving
## (the authored floors stay in the tile dicts, so flipping back restores them — they're only
## dropped when an Auto map is SAVED). One `U` reverts the whole convert.
func _toggle_depth_mode() -> void:
	_push_undo()
	var to_sculpted := not _field.is_sculpted_depth()
	if to_sculpted:
		_field.seed_sculpt_from_derived()   # freeze derived undersides as floors + set the seam anchors
	_field.set_sculpted_depth(to_sculpted)
	_field.redraw()
	_refresh_label()
	print("MapDesigner: depth mode → %s" % ("SCULPTED" if to_sculpted else "AUTO"))


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
			# floor = one level below the top → a 1-thick slab if this map is (or becomes) Sculpted;
			# ignored while Auto. anchor = the top → the seam starts at the surface, so from here the
			# top only rises and the floor only sinks (no floating slabs). Both ignored while Auto.
			column.append({"height": NEW_TILE_HEIGHT, "type": TileTypes.Type.GRASS, "body": TileTypes.Type.DIRT, "bottom": TileTypes.Type.DIRT, "floor": NEW_TILE_HEIGHT - 1, "anchor": NEW_TILE_HEIGHT})
		grid.append(column)
	return [grid]


# --- Undo -------------------------------------------------------------------

## Capture the current map (all states + name) onto the undo ring, dropping the oldest if the
## ring is full. Call this BEFORE applying a change so the snapshot is the pre-edit state.
func _push_undo() -> void:
	# Capture the depth MODE too, so undoing a mode convert (or any edit made under a mode) restores
	# the right one. Floors ride inside the cloned states, so a convert that baked/changed them is
	# fully reversible (this is the "switch must be undoable" requirement).
	_undo_stack.append({"states": _clone_states(_field.states), "name": _map_name, "sculpted": _field.is_sculpted_depth()})
	if _undo_stack.size() > UNDO_DEPTH:
		_undo_stack.pop_front()


## Restore the most recent snapshot (name + states), rebuilding the field. No-op (with a note)
## when the history is empty. Undo is one-directional for now — no redo.
func _undo() -> void:
	if _undo_stack.is_empty():
		print("MapDesigner: nothing to undo")
		return
	var snap: Dictionary = _undo_stack.pop_back()
	_map_name = snap["name"]
	# Restore the mode BEFORE load_states (which redraws), so the underside renders in the right mode.
	_field.set_sculpted_depth(snap.get("sculpted", false))
	_field.load_states(snap["states"])
	_recenter_camera()   # the restored map may differ in size/height — reframe it centered
	_refresh_label()
	print("MapDesigner: undo (%d left)" % _undo_stack.size())


## A deep copy of a whole `states` stack (every grid → every column → every tile dict), so a
## snapshot can't be aliased by later in-place edits. The nested form `load_states` consumes.
func _clone_states(states: Array) -> Array:
	var out: Array = []
	for grid in states:
		var g: Array = []
		for column in grid:
			var c: Array = []
			for t in column:
				c.append((t as Dictionary).duplicate())
			g.append(c)
		out.append(g)
	return out


# --- Save / load ------------------------------------------------------------

## Pack the field's current state into a MapData and write it to `path`.
func _on_save_path_chosen(path: String) -> void:
	# Persist the depth mode so the map reloads (here and in battle) with the same underside model;
	# from_states only writes the floors array for a Sculpted map (Auto stays compact).
	var mode := MapData.DepthMode.SCULPTED if _field.is_sculpted_depth() else MapData.DepthMode.AUTO
	var data := MapData.from_states(_field.states, _map_name, mode)
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
	_push_undo()   # loading replaces the map — keep the previous one undoable
	_map_name = data.map_name
	# Adopt the saved depth mode BEFORE load_states (which redraws) so the underside renders right.
	_field.set_sculpted_depth(data.depth_mode == MapData.DepthMode.SCULPTED)
	_field.load_states(data.to_states())
	_recenter_camera()   # the loaded map may sit at any height band — frame it centered
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
	# Depth mode: off = Auto (underside follows the terrain — the default), on = Sculpted (author the
	# underside independently for slabs / floating tiles / gaps). See MapData.DepthMode.
	_new_sculpted_check = CheckBox.new()
	_new_sculpted_check.text = "Sculpted depth (author underside separately)"
	vb.add_child(_new_sculpted_check)
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
	_push_undo()   # an accidental New is undoable (restores the old map + name + mode)
	var w := int(_new_width_spin.value)
	var h := int(_new_height_spin.value)
	_map_name = _clean_name(_new_name_edit.text)
	# Set the depth mode BEFORE load_states (which redraws) so the first render matches the choice.
	_field.set_sculpted_depth(_new_sculpted_check.button_pressed)
	_field.load_states(_new_flat_states(w, h))
	_recenter_camera()   # frame the new (high-altitude) blank map centered
	_refresh_label()


## Apply the typed name to the current map (tiles untouched).
func _on_rename_confirmed() -> void:
	_push_undo()   # a rename is undoable too (the snapshot carries the old name)
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
	var depth: String = "Sculpted" if _field.is_sculpted_depth() else "Auto"
	var lines := [
		"MAP DESIGNER  —  %s  (%dx%d)" % [_map_name, w, h],
		"Depth: %s            [M] convert mode" % depth,
		"Tool: %s            [Tab] cycle tool" % Tool.keys()[_tool],
		"Brush: %s (size %d)   [B] cycle brush, - / = size" % [Brush.keys()[_brush], _brush_size],
		"Type: %s            [ and ] cycle, 1-0 quick-pick" % TileTypes.Type.keys()[_active_type],
		"",
		"HEIGHT tool: L-click raise / drag up-down to set, R-click lower",
	]
	# Only mention underside sculpting when it's actually available (Sculpted maps), to avoid
	# implying the bottom is editable on an Auto map (where the HEIGHT tool there is a no-op).
	if _field.is_sculpted_depth():
		lines.append("   (point at the UNDERSIDE to sculpt the floor; top & bottom are independent)")
	lines.append_array([
		"PAINT tool: L-click paints the active type over the brush footprint",
		"   (face-aware: top=surface, sides=body, underside=bottom)",
		"Brushes: SINGLE / SQUARE / CIRCLE / LINE (drag) / HILL (drag up=hill, down=valley)",
		"RESIZE tool: hover an edge — L-click adds, R-click deletes (corner = both sides)",
		"Camera: wheel zoom, Q/E orbit, middle-drag free-orbit (drag down to go under)",
		"[U] undo (last %d)   [N] new   [R] rename   [S] save   [L] load" % UNDO_DEPTH,
	])
	_label.text = "\n".join(lines)
