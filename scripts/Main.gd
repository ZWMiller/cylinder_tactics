## Top-level scene script. Spawns the demo units and runs a tiny per-unit turn flow:
##
##   - At the start of a unit's turn an action MENU (bottom-left) opens. Up/Down move
##     the highlight, Enter activates: "Move" enters move mode; "End Turn" passes to
##     the next unit.
##   - In MOVE mode: mouse-move previews the path (lit-up tiles) from the active unit
##     through any right-click waypoints to the tile under the cursor; left-click
##     commits the walk (stepping up/down tile by tile); Escape returns to the menu.
##
## Whose turn it is now lives in `TurnManager` (the first node carved out of this "God
## node" toward a reusable Battle.tscn): it picks the active unit by FFT-style Charge Time
## (speed-driven) and announces each hand-off via `active_unit_changed`, which we react to
## in `_on_active_unit_changed`. Player turns open the menu; enemy turns are driven by the
## placeholder AI in `_take_enemy_turn` (random legal move). The per-step path is also the
## foundation for jump-height gating later (Battlefield.path_step_heights).
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

## How long (seconds) to pause before an enemy acts, so its AI turn reads as a deliberate
## action rather than an instant teleport. The pause also lets the turn hand-off finish
## before the move starts (see `_take_enemy_turn`), keeping the flow re-entrancy-free.
const ENEMY_TURN_DELAY := 0.4

## Battle intro: after the establishing orbit settles, hold this long (seconds) before the
## first unit becomes active and the camera punches in. See `_ready` / `_on_active_unit_changed`.
const INTRO_HOLD := 1.0

## How many mouse-wheel notches the intro punches in by on the very first active unit. Only
## that first activation auto-zooms; after that the player owns the zoom.
const INTRO_ZOOM_CLICKS := 4

## Map-transition cinematic timing (seconds): how long to hold on the wide map view both
## before and after the terrain shifts, and how long each zoom-out / zoom-in takes.
const MAP_TRANSITION_HOLD := 1.0
const MAP_ZOOM_TIME := 1.0

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

## The orthographic camera rig, needed to turn a mouse position into a pick ray and to slew
## the view onto the active unit's tile (`CameraController.focus_on`).
@onready var _camera: CameraController = $Camera3D

## The bottom-left action HUD. Created in code in `_ready`.
var _menu: ActionMenu

## The bottom-right active-unit status box, shown during the menu phase. Created in
## code in `_ready`.
var _status_panel: StatusPanel

## The top-right "turns until the map shifts" countdown box. Created in code in `_ready`.
var _shift_counter: ShiftCounter

## Which input phase we're in right now (see Phase).
var _phase: Phase = Phase.MENU

## Which menu option is highlighted (index into MENU_OPTIONS).
var _menu_index: int = 0

## The turn scheduler that decides whose turn it is (speed/CT order). Created in `_ready`,
## the same code-instantiated pattern as the HUD panels. The owner of turn state.
var _turn_manager: TurnManager

## A mirror of `_turn_manager.active()`, updated only in `_on_active_unit_changed`. The
## move/menu/hover code reads it for convenience; the turn manager remains the source of
## truth (this is never written elsewhere).
var _active_unit: Unit = null

## True once the battle-intro punch-in has fired, so only the *very first* active unit
## auto-zooms; every activation after that leaves the zoom to the player.
var _intro_zoom_done: bool = false

## True while the map-transition cinematic is playing. Gates player input and suspends the
## per-frame camera-follow so the cinematic can own the camera (zoom out → shift → zoom in)
## without a unit acting or the follow fighting it.
var _map_transition_playing: bool = false

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

	_shift_counter = ShiftCounter.new()
	add_child(_shift_counter)         # runs ShiftCounter._ready synchronously, building its UI

	_rng.seed = 12345          # fixed seed: same rolled enemies every run while testing

	# The turn scheduler owns whose turn it is; we just listen for the hand-off. Built
	# before spawning so each spawned unit can register itself with it.
	_turn_manager = TurnManager.new()
	add_child(_turn_manager)
	_turn_manager.active_unit_changed.connect(_on_active_unit_changed)
	# The map "takes its turn" every N character turns (default 10); we run the actual
	# time-shift. A specific map would set its own cadence via register_map_transition_speed.
	_turn_manager.map_transition_due.connect(_on_map_transition_due)
	_turn_manager.map_transition_countdown.connect(_on_shift_countdown)
	# Seed the countdown HUD with the starting value (full cadence; -1 hides it if disabled).
	_shift_counter.set_count(_turn_manager.turns_until_transition())

	# Players from authored recruits; enemies rolled from class+level into recruits.
	for entry in _player_roster:
		_spawn_recruit(entry[0], entry[1], Unit.Allegiance.PLAYER, entry[2])
	for entry in _enemy_roster:
		var foe := StatRoll.random_recruit(entry[2], entry[3], _rng)
		_spawn_recruit(entry[0], entry[1], Unit.Allegiance.ENEMY, foe)

	# Battle intro: a slow establishing orbit from 90° away into the authored angle, a short
	# hold, THEN start the turn loop. No unit is active during the orbit/hold, so the camera
	# stays on the wide map shot. `begin()` charges up to the first actor and emits
	# active_unit_changed, which starts that unit's turn and triggers the one-time punch-in.
	await _camera.play_intro_orbit()
	await get_tree().create_timer(INTRO_HOLD).timeout
	_turn_manager.begin()


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


## Godot's earliest input hook — runs before any node's `_unhandled_input`. We handle menu
## navigation here so consuming the confirm key happens before children see it. We only touch
## the menu keys during MENU phase and consume just those, leaving other input (mouse, camera)
## to flow normally. The debug time-shift key is handled up front so it works in any phase.
func _input(event: InputEvent) -> void:
	# Debug: T manually plays the map-shift cinematic to preview the terrain cycle. Handled
	# before the menu gate so it works regardless of phase; `_debug_request_shift` guards it.
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_T:
		_debug_request_shift()
		get_viewport().set_input_as_handled()
		return
	if not _is_player_turn() or _phase != Phase.MENU:
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
	if not _is_player_turn() or _phase != Phase.MOVE:
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
			_turn_manager.end_turn()


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


## Player "commit move": build the route from current tile -> waypoints -> the clicked
## destination, gate it, walk it, then return to the action menu. The gate refuses an
## illegal route (the preview already shows which red tiles broke it) by staying in move
## mode. The actual move is handed to `_perform_move`, the shared action the enemy AI also
## uses — this function is just the *player's* way of choosing the destination.
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

	_perform_move(tile_path)
	# Back to the menu (so you can End Turn). The unit keeps walking meanwhile.
	_start_turn()


## Carry out a validated, expanded `tile_path` for the active unit: move its occupancy/grid
## address to the final tile, clear the planning overlays, and start the stepped walk. This
## is the shared "a unit moves" action — the player commit (above) and the enemy AI both
## build a `tile_path` their own way and hand it here, so movement behaves identically for
## both sides and future, smarter AI can drive the very same action a player does.
func _perform_move(tile_path: Array) -> void:
	_relocate_unit(_active_unit, tile_path.back())
	_clear_plan()   # committed: drop waypoints and hide the path/range overlays
	_active_unit.move_along(_battlefield.path_to_world_points(tile_path))


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
## ENEMY blocks passage (you may walk through an ally, just not stop on one). The enemy AI
## reuses these snapshotted sets (it enters the same move phase), so both sides see the
## same board.
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
## the occupancy map and the turn schedule. Both authored PCs and rolled enemies arrive
## here as a Recruit, so they share one rich spawn path — and both sides join the turn
## order (the turn manager, not allegiance, decides who acts when).
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
	_turn_manager.register(unit)


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


## React to the turn manager handing the turn to `unit` (its `active_unit_changed` signal).
## Mirror it into `_active_unit` (the input code reads that), retitle the menu and move the
## tile marker, then branch by side: a PLAYER gets the action menu; an ENEMY is driven by
## the placeholder AI. `unit` is null only if the roster empties, in which case we just
## clear the marker. This replaces the old `_set_active_unit`, which `Main` called itself.
func _on_active_unit_changed(unit: Unit) -> void:
	_active_unit = unit
	if unit == null:
		_battlefield.clear_active_tile()
		return
	_menu.set_title(unit.display_name())  # show whose turn it is
	_update_active_marker()
	# One-time intro punch-in: the first unit to ever go active gets a zoom-in; after that the
	# player controls the zoom. The pan onto the unit is the normal `focus_on` slew.
	if not _intro_zoom_done:
		_intro_zoom_done = true
		_camera.zoom_in_steps(INTRO_ZOOM_CLICKS)
	if unit.allegiance == Unit.Allegiance.PLAYER:
		_start_turn()
	else:
		_take_enemy_turn(unit)


## Drive an enemy's turn as the SAME sequence a player performs — just self-driven with no
## menus — so the player sees the computer obey the identical movement rules ("a fair
## fight") and we can build smarter AI on the player's own action functions later. The
## beats, with a pause between each so it reads as a deliberate turn, not a teleport:
##   1. enter the move phase (`_enter_move_phase`) — pops the reachable-tile outline,
##   2. pick a random reachable tile and show the chosen path the same way the player
##      previews theirs (`classify_path` + `show_path`, the very same legal-path overlay),
##   3. walk it via the shared `_perform_move`, then end the turn when the walk lands
##      (or end immediately if there was nowhere to go).
## `await` also defers the work past the signal that triggered this turn, so ending a turn
## never re-enters the turn manager from inside its own emission.
func _take_enemy_turn(unit: Unit) -> void:
	# Hide any stale player menu from the previous turn before the opening pause.
	_menu.set_menu_visible(false)
	_status_panel.hide_panel()
	await get_tree().create_timer(ENEMY_TURN_DELAY).timeout

	# Beat 1: the same move phase a player enters — shows the "available blocks" outline and
	# snapshots the reachability/occupancy the AI will pick from (_reachable/_move_*).
	_enter_move_phase()
	await get_tree().create_timer(ENEMY_TURN_DELAY).timeout

	# Beat 2: choose where to go. No legal destination → drop the outline and pass.
	var path := _ai_pick_move(unit)
	if path.size() < 2:
		_clear_plan()
		_turn_manager.end_turn()
		return

	# Show the chosen route with the player's own legal-path preview, so the move the enemy
	# is about to make is on screen under the same blue/red rules the player follows.
	var flags := _battlefield.classify_path(
		path, unit.max_stats.move, unit.max_stats.jump, _move_solid, _move_occupied)
	_battlefield.show_path(path, flags)
	await get_tree().create_timer(ENEMY_TURN_DELAY).timeout

	# Beat 3: walk it via the shared action (which clears the overlays), then end the turn
	# when the walk finishes (one-shot: the connection drops after it fires).
	unit.move_finished.connect(_on_enemy_move_finished, CONNECT_ONE_SHOT)
	_perform_move(path)


## The AI's destination policy: from the reachable set `_enter_move_phase` just computed into
## `_reachable`, pick a random tile (preferring to actually move over standing still) and
## return the legal step-path to it, or `[]` if there's nowhere to go. Reuses the player's
## snapshotted constraints (`_move_solid`/`_move_occupied`) so the enemy obeys the identical
## jump/occupancy rules. This is the one enemy-specific piece — swap it for smarter logic
## later and the rest of the turn (range outline, path preview, move, end) is unchanged.
func _ai_pick_move(unit: Unit) -> Array:
	var candidates: Array = _reachable.keys()
	candidates.erase(unit.grid_coord)   # drop "stay put" so the unit moves when it can
	if candidates.is_empty():
		return []
	var dest: Vector2i = candidates[_rng.randi_range(0, candidates.size() - 1)]
	return _battlefield.find_path(
		unit.grid_coord, dest, unit.max_stats.move, unit.max_stats.jump,
		_move_solid, _move_occupied)


## The active enemy finished walking — end its turn so the schedule advances. Bound one-shot
## in `_take_enemy_turn`; the arg is the unit the signal reports (unused — it's the active one).
func _on_enemy_move_finished(_unit: Unit) -> void:
	_turn_manager.end_turn()


## The map's turn came up (every N character turns, per the turn manager) — play the
## transition cinematic, then hand control back so the next unit can act. The turn manager
## deliberately paused the loop before choosing the next actor, so nothing moves underneath
## the cinematic; `continue_after_transition` resumes it.
func _on_map_transition_due() -> void:
	await _play_map_transition()
	_turn_manager.continue_after_transition()


## The map-transition cinematic: register the current zoom, pull out to the whole-map view,
## hold, shift the terrain, hold, then zoom back in to the (still-active) unit at the zoom we
## started from. `_map_transition_playing` gates input and suspends the per-frame camera
## follow for the duration so the choreography owns the camera.
func _play_map_transition() -> void:
	_map_transition_playing = true
	# Clear the player UI so the wide shot is unobstructed; the next turn restores it.
	_menu.set_menu_visible(false)
	_status_panel.hide_panel()

	var restore_zoom: float = _camera.ortho_size   # register where to zoom back to
	# Pull back to the whole-map framing (recenter on the map; the follow is suspended).
	_camera.focus_on(Vector3.ZERO)
	await _camera.zoom_to(_camera.home_ortho_size(), MAP_ZOOM_TIME)
	await get_tree().create_timer(MAP_TRANSITION_HOLD).timeout

	# The shift itself (terrain only today; unit re-settle + fall damage is a separate TODO).
	_battlefield.advance_shift()
	await get_tree().create_timer(MAP_TRANSITION_HOLD).timeout

	# Release the camera so the per-frame follow re-centers on the active unit, and zoom back
	# in to the registered level as it pans.
	_map_transition_playing = false
	await _camera.zoom_to(restore_zoom, MAP_ZOOM_TIME)
	# Refresh the countdown to the full cadence now that the shift has happened.
	_shift_counter.set_count(_turn_manager.turns_until_transition())


## Update the top-right countdown box when the turn manager reports turns-until-shift.
func _on_shift_countdown(turns_remaining: int) -> void:
	_shift_counter.set_count(turns_remaining)


## Debug helper (T key): play the map-transition cinematic on demand to preview the terrain
## cycle, instead of waiting out the turn cadence. Allowed only from a player's turn (so it
## can't collide with an enemy's AI turn or a transition already in flight — `_is_player_turn`
## is false in both cases), and restores the player's menu afterward since the cinematic hides
## it. Deliberately does NOT touch the turn counter: it's a preview, so the scheduled shift
## cadence is unaffected (the terrain state does advance, same as the old Space shortcut did).
func _debug_request_shift() -> void:
	if not _is_player_turn():
		return
	await _play_map_transition()
	_start_turn()


## Place/recolor the active-unit tile marker on the active unit's tile, and aim the camera at
## the unit. Called every frame from `_process` so both track the unit as it walks and stay
## correct after a time-shift. The marker sits on the destination tile (`grid_coord`, which a
## commit sets immediately), but the camera follows the unit's *live* `global_position` — so
## it pans *with* the character at walking pace and trails slightly, instead of jumping ahead
## to the destination and waiting. The camera only moves when the focus changes (see
## `CameraController._process`), so calling this every frame is free when nothing moved.
func _update_active_marker() -> void:
	if _active_unit == null:
		return
	_battlefield.set_active_tile(_active_unit.grid_coord, Unit.active_color(_active_unit.allegiance))
	# During a map-transition cinematic the camera is choreographed by `_play_map_transition`,
	# so don't fight it with the per-frame follow; the marker still tracks the tile.
	if not _map_transition_playing:
		_camera.focus_on(_active_unit.global_position)


## Move `unit`'s occupancy entry and grid address to `dest` — the bookkeeping half of a move
## (the visual walk is the caller's separate `move_along`, run from `_perform_move`). Kept as
## one helper so occupancy stays consistent however a unit moves.
func _relocate_unit(unit: Unit, dest: Vector2i) -> void:
	_units_by_tile.erase(unit.grid_coord)
	unit.grid_coord = dest
	_units_by_tile[dest] = unit


## True only while a PLAYER unit holds the turn AND no map-transition cinematic is playing —
## the gate for all player input (menu keys and move placement), so input does nothing during
## an enemy's self-driven AI turn or while the map is shifting.
func _is_player_turn() -> bool:
	return _active_unit != null \
		and _active_unit.allegiance == Unit.Allegiance.PLAYER \
		and not _map_transition_playing
