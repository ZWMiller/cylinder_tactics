## Top-level scene script. Spawns the demo units and runs a tiny per-unit turn flow:
##
##   - At the start of a unit's turn an action MENU (bottom-left) opens. Up/Down move
##     the highlight, Enter activates: "Move" enters move mode; "End Turn" passes to
##     the next unit.
##   - In MOVE mode: mouse-move previews the path (lit-up tiles) from the active unit
##     through any right-click waypoints to the tile under the cursor; left-click
##     commits the walk (stepping up/down tile by tile); Escape returns to the menu.
##
## The active-unit pointer (`_active_unit`) is the seam the future turn system will
## own; today "End Turn" just cycles player units in spawn order. The per-step path is
## also the foundation for jump-height gating later (Battlefield.path_step_heights).
##
## This is still demo glue: real spawning will come from map/encounter data with the
## turn loop. It lives here so `Battlefield` stays focused on terrain.
extends Node3D

## The unit scene we stamp out copies of. `preload` loads the resource at parse
## time, so each `.instantiate()` is just a cheap clone of an already-loaded scene.
const UNIT_SCENE := preload("res://scenes/Unit.tscn")

## The actions offered at the start of a turn, in menu order.
const MENU_OPTIONS := ["Move", "End Turn"]

## The two input phases of a turn: choosing an action, or placing a move.
enum Phase { MENU, MOVE }

## One demo unit per row entry: [grid_x, grid_z, allegiance, class]. A player row
## and an enemy row, each showing all three classes, so both visual channels read
## at a glance (body color = side, hat shape+color = class).
@onready var _demo_roster := [
	[10, 10, Unit.Allegiance.PLAYER, UnitClasses.Class.SOLDIER],
	[12, 10, Unit.Allegiance.PLAYER, UnitClasses.Class.ARCHER],
	[14, 10, Unit.Allegiance.PLAYER, UnitClasses.Class.MAGE],
	[10, 13, Unit.Allegiance.ENEMY, UnitClasses.Class.SOLDIER],
	[12, 13, Unit.Allegiance.ENEMY, UnitClasses.Class.ARCHER],
	[14, 13, Unit.Allegiance.ENEMY, UnitClasses.Class.MAGE],
]

## The terrain grid, cached so the click handler can ray-pick tiles against it.
@onready var _battlefield: Battlefield = $Battlefield

## The orthographic camera, needed to turn a mouse position into a pick ray.
@onready var _camera: Camera3D = $Camera3D

## The bottom-left action HUD. Created in code in `_ready`.
var _menu: ActionMenu

## Which input phase we're in right now (see Phase).
var _phase: Phase = Phase.MENU

## Which menu option is highlighted (index into MENU_OPTIONS).
var _menu_index: int = 0

## Which unit currently takes its turn. We set this ourselves for now; later the turn
## scheduler will. Highlighted via `Unit.set_active` so it's visible on screen.
var _active_unit: Unit = null

## Every player-controlled unit, in spawn order, so "End Turn" can cycle them (a
## stand-in for real turn order until that system exists).
var _player_units: Array[Unit] = []

## Which unit occupies each tile, keyed by grid coordinate (Vector2i). Lets us block
## moving onto an occupied tile now, and will resolve attacks by tile later.
var _units_by_tile: Dictionary = {}

## Committed waypoints for the active unit's pending move — intermediate tiles the
## route must pass through, in order. Route = current tile -> these -> destination.
var _planned_waypoints: Array[Vector2i] = []

## The tile under the mouse right now, so we only recompute the path preview when it
## actually changes (mouse-move fires far more often than the hovered tile changes).
var _hovered_tile: Vector2i = Battlefield.INVALID_TILE


## Godot lifecycle hook. A parent's `_ready` runs *after* its children's, so the
## Battlefield's tiles already exist. Build the HUD, spawn the roster, then start the
## first player unit's turn (which opens the menu).
func _ready() -> void:
	_menu = ActionMenu.new()
	add_child(_menu)            # runs ActionMenu._ready synchronously, building its UI
	_menu.build(MENU_OPTIONS)

	for entry in _demo_roster:
		_spawn(entry[0], entry[1], entry[2], entry[3])
	if not _player_units.is_empty():
		_set_active_unit(_player_units[0])


## Godot's earliest input hook — runs before any node's `_unhandled_input`. We handle
## menu navigation here (not in `_unhandled_input`) so that consuming the confirm key
## reliably beats the Battlefield's placeholder Space/Enter time-shift: because the
## Battlefield is a *child*, it would otherwise receive `_unhandled_input` first.
## We only touch the menu keys during MENU phase and consume just those, leaving all
## other input (mouse, camera) to flow normally.
func _input(event: InputEvent) -> void:
	if _active_unit == null or _phase != Phase.MENU:
		return
	if event.is_action_pressed("ui_up"):
		_set_menu_index(_menu_index - 1)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_down"):
		_set_menu_index(_menu_index + 1)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_accept"):
		_activate_menu_option()
		get_viewport().set_input_as_handled()


## Godot input hook for events nothing else consumed. Only the MOVE phase reacts here
## (menu keys are handled earlier in `_input`); in MENU phase tile clicks do nothing.
func _unhandled_input(event: InputEvent) -> void:
	if _active_unit == null or _phase != Phase.MOVE:
		return
	_move_input(event)


# --- Menu phase --------------------------------------------------------------


## Set the highlighted option, wrapping around the ends, and update the HUD.
func _set_menu_index(index: int) -> void:
	_menu_index = wrapi(index, 0, MENU_OPTIONS.size())  # wrapi keeps it in [0, size)
	_menu.set_highlighted(_menu_index)


## Run the highlighted option: enter move mode, or end the turn.
func _activate_menu_option() -> void:
	match MENU_OPTIONS[_menu_index]:
		"Move":
			_enter_move_phase()
		"End Turn":
			_cycle_active_unit()


# --- Move phase --------------------------------------------------------------

## Mouse-move previews; left-click commits; right-click adds a waypoint; Escape backs
## out to the menu.
func _move_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_update_hover(event.position)
	elif event is InputEventMouseButton and event.pressed:
		match event.button_index:
			MOUSE_BUTTON_LEFT:
				_commit_move(event.position)
			MOUSE_BUTTON_RIGHT:
				_add_waypoint(event.position)
	elif event.is_action_pressed("ui_cancel"):  # Escape: cancel back to the menu
		_start_turn()


## Update which tile the mouse is over and refresh the path preview when it changes.
func _update_hover(screen_point: Vector2) -> void:
	if _active_unit.is_moving():
		return
	var tile := _battlefield.tile_at_screen_point(_camera, screen_point)
	if tile == _hovered_tile:
		return  # still over the same tile — nothing to redraw
	_hovered_tile = tile
	_refresh_path_preview()


## Light up the path the active unit *would* take to the hovered tile, routed through
## any committed waypoints. Hides the preview when there's nothing valid to show.
func _refresh_path_preview() -> void:
	if _active_unit.is_moving() or _hovered_tile == Battlefield.INVALID_TILE:
		_battlefield.clear_path()
		return
	_battlefield.show_path(Battlefield.expand_path(_planned_route(_hovered_tile)))


## Build the route tile list: current tile -> committed waypoints -> `destination`
## (skipping a destination that just repeats the current end of the plan).
func _planned_route(destination: Vector2i) -> Array:
	var route: Array[Vector2i] = [_active_unit.grid_coord]
	route.append_array(_planned_waypoints)
	if destination != route.back():
		route.append(destination)
	return route


## Add the tile under the cursor as a waypoint the pending move must pass through.
func _add_waypoint(screen_point: Vector2) -> void:
	if _active_unit.is_moving():
		return
	var tile := _battlefield.tile_at_screen_point(_camera, screen_point)
	if tile == Battlefield.INVALID_TILE:
		return
	# Ignore a repeat of the current end of the plan (e.g. a double right-click).
	var last: Vector2i = _planned_waypoints.back() if not _planned_waypoints.is_empty() else _active_unit.grid_coord
	if tile == last:
		return
	_planned_waypoints.append(tile)
	_hovered_tile = tile
	_refresh_path_preview()


## Commit the move: walk the active unit along current tile -> waypoints -> the
## clicked destination, stepping tile by tile, then return to the action menu. Blocks
## only if the *destination* is occupied; per-tile reachability/jump gates come later.
func _commit_move(screen_point: Vector2) -> void:
	if _active_unit.is_moving():
		return
	var destination := _battlefield.tile_at_screen_point(_camera, screen_point)
	if destination == Battlefield.INVALID_TILE:
		return

	var route := _planned_route(destination)
	var final_tile: Vector2i = route.back()
	# Don't stack two units. (Intermediate-tile checks come with reachability later.)
	if _units_by_tile.has(final_tile) and _units_by_tile[final_tile] != _active_unit:
		return

	# Densify into adjacent tile steps; bail (stay in move mode) if nowhere to go.
	var tile_path := Battlefield.expand_path(route)
	if tile_path.size() < 2:
		return

	# Future jump gate hooks here: compare Battlefield.path_step_heights(tile_path)
	# against the unit's jump stat and reject the move if any step is too tall. For
	# now just surface the tallest step so the data is visible while we test.
	var tallest := 0.0
	for step in _battlefield.path_step_heights(tile_path):
		tallest = max(tallest, abs(step))
	print("Move: %d tiles, tallest step %.2f" % [tile_path.size(), tallest])

	# Update occupancy to the destination, then walk the stepped polyline.
	_units_by_tile.erase(_active_unit.grid_coord)
	_active_unit.grid_coord = final_tile
	_units_by_tile[final_tile] = _active_unit
	_active_unit.move_along(_battlefield.path_to_world_points(tile_path))

	# Back to the menu (so you can End Turn). The unit keeps walking meanwhile.
	_start_turn()


# --- Turn / active-unit management -------------------------------------------

## Begin (or restart) the active unit's turn: enter the menu phase with "Move"
## highlighted, and clear any half-planned move. Called when a unit becomes active,
## after a move commits, and when cancelling out of move mode.
func _start_turn() -> void:
	_phase = Phase.MENU
	_menu_index = 0
	_clear_plan()
	_hovered_tile = Battlefield.INVALID_TILE
	_menu.set_menu_visible(true)
	_menu.set_highlighted(_menu_index)


## Switch from the menu into placing a move: hide the menu and start fresh.
func _enter_move_phase() -> void:
	_phase = Phase.MOVE
	_menu.set_menu_visible(false)
	_clear_plan()
	_hovered_tile = Battlefield.INVALID_TILE


## Drop any planned waypoints and hide the path preview (back to a clean slate).
func _clear_plan() -> void:
	_planned_waypoints.clear()
	_battlefield.clear_path()


## Instantiate one unit, skin it, stand it on tile (x, z), and register it in the
## occupancy map (and the player roster if it's ours).
func _spawn(x: int, z: int, side: Unit.Allegiance, klass: UnitClasses.Class) -> void:
	var unit: Unit = UNIT_SCENE.instantiate()
	# configure() before add_child: the values are stored now and applied by the
	# unit's own _ready when it enters the tree on the next line.
	unit.configure(side, klass)
	unit.grid_coord = Vector2i(x, z)
	_battlefield.add_child(unit)
	# Initial placement is instant (set position directly); only later moves walk.
	unit.position = _battlefield.tile_to_world(x, z)

	_units_by_tile[unit.grid_coord] = unit
	if side == Unit.Allegiance.PLAYER:
		_player_units.append(unit)


## Make `unit` the active one: clear the previous unit's highlight, swap the pointer,
## highlight the new one, and start its turn (which opens the menu).
func _set_active_unit(unit: Unit) -> void:
	if _active_unit != null:
		_active_unit.set_active(false)
	_active_unit = unit
	if _active_unit != null:
		_active_unit.set_active(true)
	_start_turn()


## Advance the active unit to the next player unit (wrapping) — i.e. "End Turn". A
## placeholder for the turn order that will eventually decide whose turn it is.
func _cycle_active_unit() -> void:
	if _player_units.is_empty():
		return
	# find() returns -1 if the active unit isn't a player unit, so this lands on
	# index 0 — a sensible default.
	var idx := _player_units.find(_active_unit)
	_set_active_unit(_player_units[(idx + 1) % _player_units.size()])
