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

## The authored player characters (hand-made `Recruit.tres` with real aptitudes), one
## per class. `preload` resolves them at parse time, so a renamed/missing file is a
## loud editor error rather than a silent runtime null.
const RECRUIT_BRON := preload("res://assets/recruits/bron.tres")  # Soldier
const RECRUIT_DART := preload("res://assets/recruits/dart.tres")  # Archer
const RECRUIT_WISP := preload("res://assets/recruits/wisp.tres")  # Mage

## The actions offered at the start of a turn, in menu order. "Stats" inspects the
## active unit (prints its block + pins the floating panel) so the new stat system is
## verifiable in-game.
const MENU_OPTIONS := ["Move", "Stats", "End Turn"]

## How long (seconds) the cursor must rest on a unit before its stat panel pops up.
const HOVER_DELAY := 1.0

## How far above a unit's origin to float its stat panel, in world units.
const STAT_PANEL_HEIGHT := 2.6

## The two input phases of a turn: choosing an action, or placing a move.
enum Phase { MENU, MOVE }

## Authored player units: [grid_x, grid_z, Recruit]. Each spawns via
## `Unit.init_from_recruit`, so it carries a real class, level, aptitude and stat
## block — not the old appearance-only baseline.
@onready var _player_roster := [
	[10, 10, RECRUIT_BRON],
	[12, 10, RECRUIT_DART],
	[14, 10, RECRUIT_WISP],
]

## Enemy units: [grid_x, grid_z, class, level]. Unlike PCs these have no authored
## file — each is rolled into a random `Recruit` (random name + aptitude) at the given
## class/level by `StatRoll`. Level 3 so banked level-up growth is visible in-game.
@onready var _enemy_roster := [
	[10, 13, UnitClasses.Class.SOLDIER, 3],
	[12, 13, UnitClasses.Class.ARCHER, 3],
	[14, 13, UnitClasses.Class.MAGE, 3],
]

## RNG for rolling enemies. Fixed seed (not `randomize()`) for now so each run spawns
## the same foes — reproducible while we test; swap to `randomize()` for variety later.
var _rng := RandomNumberGenerator.new()

## The terrain grid, cached so the click handler can ray-pick tiles against it.
@onready var _battlefield: Battlefield = $Battlefield

## The orthographic camera, needed to turn a mouse position into a pick ray.
@onready var _camera: Camera3D = $Camera3D

## The bottom-left action HUD. Created in code in `_ready`.
var _menu: ActionMenu

## The bottom-right active-unit status box, shown during the menu phase. Created in
## code in `_ready`.
var _status_panel: StatusPanel

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

## The active unit's movement constraints for the in-progress Move, snapshotted when the
## move phase opens (occupancy and the unit's start tile don't change until it actually
## moves, so we compute these once instead of per mouse-move):
##   - `_reachable`  : { Vector2i: cost } the unit can reach + stop on (drives the outline)
##   - `_move_solid` : tiles it cannot enter at all (enemy units)
##   - `_move_occupied` : tiles it can pass through but not stop on (any unit)
## `_move_solid`/`_move_occupied` feed the per-tile blue/red legality of the path preview.
var _reachable: Dictionary = {}
var _move_solid: Dictionary = {}
var _move_occupied: Dictionary = {}

## Floating HUD box that shows a unit's stat block above its head. One reusable view,
## repositioned/retexted per target; hidden when nothing is being inspected.
var _stat_panel: StatPanel

## The unit the cursor is currently resting on (or null). Drives the hover dwell timer.
var _hover_unit: Unit = null

## Seconds the cursor has rested on `_hover_unit` — counts up to HOVER_DELAY, then the
## panel shows. Reset whenever the hovered unit changes.
var _hover_elapsed: float = 0.0

## True while the "Stats" menu option is pinning the panel to the active unit. Pinned
## mode wins over hover, so moving the mouse doesn't dismiss a deliberately-opened panel.
var _stats_pinned: bool = false


## Godot lifecycle hook. A parent's `_ready` runs *after* its children's, so the
## Battlefield's tiles already exist. Build the HUD, spawn the roster, then start the
## first player unit's turn (which opens the menu).
func _ready() -> void:
	_menu = ActionMenu.new()
	add_child(_menu)            # runs ActionMenu._ready synchronously, building its UI
	_menu.build(MENU_OPTIONS)

	_stat_panel = StatPanel.new()
	add_child(_stat_panel)            # runs StatPanel._ready synchronously, building its UI

	_status_panel = StatusPanel.new()
	add_child(_status_panel)          # runs StatusPanel._ready synchronously, building its UI

	_rng.seed = 12345          # fixed seed: same rolled enemies every run while testing

	# Players from authored recruits; enemies rolled from class+level into recruits.
	for entry in _player_roster:
		_spawn_recruit(entry[0], entry[1], Unit.Allegiance.PLAYER, entry[2])
	for entry in _enemy_roster:
		var foe := StatRoll.random_recruit(entry[2], entry[3], _rng)
		_spawn_recruit(entry[0], entry[1], Unit.Allegiance.ENEMY, foe)

	if not _player_units.is_empty():
		_set_active_unit(_player_units[0])


## Godot lifecycle hook: runs every frame. Drives the hover-to-inspect panel — after
## the cursor rests on a unit for HOVER_DELAY it shows that unit's stats; the panel
## follows whichever unit it's bound to. When the "Stats" option has pinned the panel,
## hover detection is skipped so the pin sticks.
func _process(delta: float) -> void:
	# Keep the active-unit tile marker glued to the active unit's tile (it walks; the
	# map can shift) — independent of the stat-panel logic below.
	_update_active_marker()

	if _stats_pinned:
		_position_stat_panel(_active_unit)
		return

	# Hovering a unit = hovering the tile it stands on. Units have no collision of
	# their own, but their tile does, so we ray-pick the tile and look up its occupant
	# — reusing the Battlefield as the single coordinate/picking authority.
	var tile := _battlefield.tile_at_screen_point(_camera, get_viewport().get_mouse_position())
	var unit: Unit = _units_by_tile.get(tile)

	if unit != _hover_unit:
		# Moved onto a different unit (or off all units): restart the dwell timer.
		_hover_unit = unit
		_hover_elapsed = 0.0
		_hide_stat_panel()
	elif unit != null and not _stat_panel.is_open():
		# Still resting on the same unit and not yet shown — count toward the delay.
		_hover_elapsed += delta
		if _hover_elapsed >= HOVER_DELAY:
			_show_stat_panel(unit)

	if _stat_panel.is_open():
		_position_stat_panel(unit)


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


## Set the highlighted option, wrapping around the ends, and update the HUD. Moving
## the highlight also dismisses a pinned stats panel — navigating away closes it.
func _set_menu_index(index: int) -> void:
	_menu_index = wrapi(index, 0, MENU_OPTIONS.size())  # wrapi keeps it in [0, size)
	_menu.set_highlighted(_menu_index)
	_unpin_stats()


## Run the highlighted option: enter move mode, inspect stats, or end the turn.
func _activate_menu_option() -> void:
	match MENU_OPTIONS[_menu_index]:
		"Move":
			_enter_move_phase()
		"Stats":
			_inspect_active_unit()
		"End Turn":
			_cycle_active_unit()


## "Stats" action: print the active unit's full block (for console verification) and
## pin the floating panel to it so the owner can read the stats in-world. Pinned until
## the player navigates the menu or the turn changes.
func _inspect_active_unit() -> void:
	if _active_unit == null:
		return
	print(_active_unit.stats_summary())
	_stats_pinned = true
	_show_stat_panel(_active_unit)


## Drop a pinned stats panel (if any) and reset hover so it can re-trigger cleanly.
func _unpin_stats() -> void:
	if not _stats_pinned:
		return
	_stats_pinned = false
	_hover_unit = null
	_hide_stat_panel()


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
	# Expand the waypoint route into adjacent steps, classify each as legal/illegal
	# against the unit's move budget + jump + occupancy, and light the tiles blue/red.
	var tile_path := Battlefield.expand_path(_planned_route(_hovered_tile))
	var flags := _battlefield.classify_path(
		tile_path, _active_unit.max_stats.move, _active_unit.max_stats.jump,
		_move_solid, _move_occupied)
	_battlefield.show_path(tile_path, flags)


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

	# Densify into adjacent tile steps; bail (stay in move mode) if nowhere to go.
	var tile_path := Battlefield.expand_path(route)
	if tile_path.size() < 2:
		return

	# Gate the move: every step must clear the jump height, stay within the move budget,
	# avoid enemy tiles, and not end on an occupied tile. `classify_path` flags each tile;
	# if any is illegal we refuse and stay in move mode — the preview is already showing
	# the player exactly which tiles (the red ones) made it illegal.
	var flags := _battlefield.classify_path(
		tile_path, _active_unit.max_stats.move, _active_unit.max_stats.jump,
		_move_solid, _move_occupied)
	if flags.has(false):
		return

	var final_tile: Vector2i = tile_path.back()
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
	_unpin_stats()
	_hovered_tile = Battlefield.INVALID_TILE
	_menu.set_menu_visible(true)
	_menu.set_highlighted(_menu_index)
	# Show the active unit's persistent status box alongside the menu (FFT layout).
	if _active_unit != null:
		_status_panel.show_for(_active_unit.stats_panel_text())


## Switch from the menu into placing a move: hide the menu (and the status box) and
## start fresh.
func _enter_move_phase() -> void:
	_phase = Phase.MOVE
	_menu.set_menu_visible(false)
	_status_panel.hide_panel()
	_clear_plan()
	_unpin_stats()
	_hovered_tile = Battlefield.INVALID_TILE
	# Snapshot the unit's reach for this turn and outline it on the map.
	_compute_move_constraints()
	_battlefield.show_move_range(_reachable)


## Snapshot what limits the active unit's move THIS turn: the set of tiles it can reach
## and stop on (for the range outline) plus the solid/occupied tile sets (for the
## blue/red path legality). Computed once when move mode opens because none of it changes
## until the unit actually moves — occupancy is fixed and the unit is still on its start
## tile. Other units' tiles are classified by side: ANY unit blocks stopping, but only an
## ENEMY blocks passage (you may walk through an ally, just not stop on one).
func _compute_move_constraints() -> void:
	_move_solid = {}
	_move_occupied = {}
	for tile in _units_by_tile:
		var u: Unit = _units_by_tile[tile]
		if u == _active_unit:
			continue
		_move_occupied[tile] = true
		if u.allegiance != _active_unit.allegiance:
			_move_solid[tile] = true
	_reachable = _battlefield.reachable_tiles(
		_active_unit.grid_coord, _active_unit.max_stats.move, _active_unit.max_stats.jump,
		_move_solid, _move_occupied)


## Drop any planned waypoints and hide the path preview + move-range outline (back to a
## clean slate). Called on every entry to and exit from move mode, so both overlays are
## consistently cleared when leaving and freshly redrawn when re-entering.
func _clear_plan() -> void:
	_planned_waypoints.clear()
	_battlefield.clear_path()
	_battlefield.clear_move_range()


## Instantiate one unit from a `Recruit`, stand it on tile (x, z), and register it in
## the occupancy map (and the player roster if it's ours). Both authored PCs and rolled
## enemies arrive here as a Recruit, so they share one rich spawn path.
func _spawn_recruit(x: int, z: int, side: Unit.Allegiance, recruit: Recruit) -> void:
	var unit: Unit = UNIT_SCENE.instantiate()
	# Set allegiance (the body-color channel) before add_child so the unit's own _ready
	# colors the body correctly; class/level/stats are adopted from the recruit next.
	unit.allegiance = side
	unit.grid_coord = Vector2i(x, z)
	_battlefield.add_child(unit)        # fires Unit._ready (appearance + baseline stats)
	unit.init_from_recruit(recruit)     # adopt real class/level/aptitude → max_stats, reskin
	# Initial placement is instant (set position directly); only later moves walk.
	unit.position = _battlefield.tile_to_world(x, z)

	_units_by_tile[unit.grid_coord] = unit
	if side == Unit.Allegiance.PLAYER:
		_player_units.append(unit)


# --- Stat inspect panel (hover + "Stats" action) -----------------------------

## Fill the panel with `unit`'s stats and reveal it. Position is set each frame by
## `_position_stat_panel` so it tracks a unit that's moving.
func _show_stat_panel(unit: Unit) -> void:
	if unit == null:
		return
	_stat_panel.show_text(unit.stats_panel_text())


## Hide the floating stat panel.
func _hide_stat_panel() -> void:
	_stat_panel.hide_panel()


## Park the panel above `unit`'s head (or hide it if there's no target). The panel is
## a screen-space HUD box, so we project the unit's head — a point STAT_PANEL_HEIGHT
## world units above its origin — onto the screen and place the box there. Called every
## frame while the panel is up so it follows a walking unit.
func _position_stat_panel(unit: Unit) -> void:
	if unit == null:
		_hide_stat_panel()
		return
	var head := unit.global_position + Vector3.UP * STAT_PANEL_HEIGHT
	_stat_panel.place_above(_camera.unproject_position(head))


## Make `unit` the active one: swap the pointer, mark its tile (the FFT-style "whose
## turn" highlight, tinted by side), set the menu title, and start its turn. The marker
## is kept tracking the unit's tile each frame in `_process`.
func _set_active_unit(unit: Unit) -> void:
	_active_unit = unit
	if _active_unit != null:
		_menu.set_title(_active_unit.display_name())  # show whose turn it is
		_update_active_marker()
	else:
		_battlefield.clear_active_tile()
	_start_turn()


## Place/recolor the active-unit tile marker on the active unit's current tile. Cheap,
## and called every frame from `_process` so the marker follows the unit as it walks and
## stays correct after a time-shift changes tile heights.
func _update_active_marker() -> void:
	if _active_unit == null:
		return
	_battlefield.set_active_tile(_active_unit.grid_coord, Unit.active_color(_active_unit.allegiance))


## Advance the active unit to the next player unit (wrapping) — i.e. "End Turn". A
## placeholder for the turn order that will eventually decide whose turn it is.
func _cycle_active_unit() -> void:
	if _player_units.is_empty():
		return
	# find() returns -1 if the active unit isn't a player unit, so this lands on
	# index 0 — a sensible default.
	var idx := _player_units.find(_active_unit)
	_set_active_unit(_player_units[(idx + 1) % _player_units.size()])
