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

## The actions offered at the start of a turn, in menu order. "Attack" enters the targeting phase
## (orange reach overlay; click an enemy in range to strike) with the unit's basic weapon attack.
## "Spell" opens the nested spell submenu, but ONLY for casters — so the menu is built per active
## unit (see `_menu_options_for`), not from a single fixed list. "Stats" inspects the active unit
## (prints its block + pins the floating panel) so the stat system is verifiable.
const _ACTION_MOVE := "Move"
const _ACTION_ATTACK := "Attack"
const _ACTION_SPELL := "Spell"
const _ACTION_STATS := "Stats"
const _ACTION_END := "End Turn"

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

## How far above a struck unit's origin the floating damage number spawns, in world units.
const DAMAGE_NUMBER_HEIGHT := 1.8

## Color of the floating damage number (a soft red so it reads as "ouch" against the terrain).
const DAMAGE_NUMBER_COLOR := Color(1.0, 0.5, 0.45)

## The input phases of a turn: choosing an action, browsing the spell submenu, placing a move, or
## aiming an attack. SPELL_MENU is a sub-state of the menu (the action menu stays visible beside it).
enum Phase { MENU, SPELL_MENU, MOVE, ATTACK }

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
## class/level by `StatRoll`. Level 1 (matching the PCs) for a fair test fight while the
## combat AI is shaken out; bump for a tougher encounter later.
@onready var _enemy_roster := [
	[10, 13, UnitClasses.Class.SOLDIER, 1],
	[12, 13, UnitClasses.Class.ARCHER, 1],
	[14, 13, UnitClasses.Class.MAGE, 1],
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

## The nested spell submenu, docked to the right of the action menu when a caster picks "Spell".
## Created in code in `_ready`.
var _spell_menu: SpellMenu

## The bottom-right active-unit status box, shown during the menu phase. Created in
## code in `_ready`.
var _status_panel: StatusPanel

## The top-right "turns until the map shifts" countdown box. Created in code in `_ready`.
var _shift_counter: ShiftCounter

## The full-screen win/lose overlay, shown once one side is wiped out. Created in code in `_ready`.
var _end_screen: EndScreen

## True once the battle has been decided (one side wiped). Latches the end sequence: it gates all
## turn/input/process work so the loop halts and the camera/overlay own the screen.
var _game_over: bool = false

## Which input phase we're in right now (see Phase).
var _phase: Phase = Phase.MENU

## The action-menu options for the CURRENT active unit, built per turn by `_menu_options_for`
## (casters get a "Spell" entry, others don't). Indexed by `_menu_index`.
var _menu_options: Array = []

## Which menu option is highlighted (index into `_menu_options`).
var _menu_index: int = 0

## Which spell row is highlighted while in the SPELL_MENU phase (index into the active unit's
## `known_spells`). Stale outside that phase.
var _spell_index: int = 0

## Per-turn action budget: a unit may commit up to this many actions per turn, of which at most one
## may be an attack/spell. So a turn is two moves, or a move + one attack/spell (either order) — see
## `_is_action_enabled`. Only COMMITTED actions count (cancelling out of targeting doesn't); Stats
## and End Turn are free.
const MAX_ACTIONS_PER_TURN := 2

## How many actions the active unit has committed this turn, and whether one of them was an
## attack/spell. Reset at the start of each unit's turn (`_on_active_unit_changed`); bumped by the
## move and attack commits. Drive which menu options are enabled.
var _actions_taken: int = 0
var _offensive_taken: bool = false

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

## The attack being aimed during the ATTACK phase (the active unit's `basic_attack` for now),
## and the set of tiles it can reach `{ Vector2i: true }` — snapshotted when the phase opens so
## the click handler can validate a target in O(1). Both stale outside the ATTACK phase.
var _attack_profile: Attack = null
var _attack_tiles: Dictionary = {}

## True while an attack is resolving (its animation + damage + any death are playing out). Gates
## player input via `_is_player_turn` so clicks don't queue a second attack mid-swing.
var _resolving_action: bool = false

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
	# Options are built per active unit (casters get "Spell"), so we don't build a fixed list here.

	_spell_menu = SpellMenu.new()
	add_child(_spell_menu)      # runs SpellMenu._ready synchronously, building its UI

	_stat_panel = StatPanel.new()
	add_child(_stat_panel)            # runs StatPanel._ready synchronously, building its UI

	_status_panel = StatusPanel.new()
	add_child(_status_panel)          # runs StatusPanel._ready synchronously, building its UI

	_shift_counter = ShiftCounter.new()
	add_child(_shift_counter)         # runs ShiftCounter._ready synchronously, building its UI

	_end_screen = EndScreen.new()
	add_child(_end_screen)            # runs EndScreen._ready synchronously, building its UI (hidden)

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
	# Once the battle is decided, the end cinematic owns the camera/screen — stop the marker,
	# camera-follow, and hover-inspect work so nothing fights it.
	if _game_over:
		return
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
	# Battle decided → ignore all gameplay input (the end screen is up); camera input still flows
	# through CameraController's own handler.
	if _game_over:
		return
	# Debug: T manually plays the map-shift cinematic to preview the terrain cycle. Handled
	# before the menu gate so it works regardless of phase; `_debug_request_shift` guards it.
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_T:
		_debug_request_shift()
		get_viewport().set_input_as_handled()
		return
	if not _is_player_turn():
		return
	# Keyboard-driven menu phases handle their navigation here (and consume it); the pointer-driven
	# MOVE/ATTACK phases fall through to `_unhandled_input`.
	match _phase:
		Phase.MENU:
			_menu_key_input(event)
		Phase.SPELL_MENU:
			_spell_menu_key_input(event)


## Action-menu navigation: Up/Down move the highlight, Enter activates. Consumes the keys it uses.
func _menu_key_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_up"):
		_set_menu_index(_menu_index - 1)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_down"):
		_set_menu_index(_menu_index + 1)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_accept"):
		_activate_menu_option()
		get_viewport().set_input_as_handled()


## Spell-submenu navigation: Up/Down move the highlight, Enter casts (or flashes "Not Enough MP"),
## and Left/Esc back out to the parent action menu — the nesting convention. Consumes its keys.
func _spell_menu_key_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_up"):
		_set_spell_index(_spell_index - 1)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_down"):
		_set_spell_index(_spell_index + 1)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_accept"):
		_activate_spell_option()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_cancel") or event.is_action_pressed("ui_left"):
		_exit_spell_menu()
		get_viewport().set_input_as_handled()


## Godot input hook for events nothing else consumed. The MOVE and ATTACK phases react here
## (menu keys are handled earlier in `_input`); in MENU phase tile clicks do nothing.
func _unhandled_input(event: InputEvent) -> void:
	if not _is_player_turn():
		return
	match _phase:
		Phase.MOVE:
			_move_input(event)
		Phase.ATTACK:
			_attack_input(event)


# --- Menu phase --------------------------------------------------------------


## Set the highlighted option, wrapping around the ends, and update the HUD. Moving
## the highlight also dismisses a pinned stats panel — navigating away closes it.
func _set_menu_index(index: int) -> void:
	_menu_index = wrapi(index, 0, _menu_options.size())  # wrapi keeps it in [0, size)
	_menu.set_highlighted(_menu_index)
	_unpin_stats()


## The action-menu options for `unit`, in order. "Spell" appears only for casters (so the menu is
## per-unit, not a fixed list); everything else is universal. Built fresh each turn by
## `_on_active_unit_changed`.
func _menu_options_for(unit: Unit) -> Array:
	var options := [_ACTION_MOVE, _ACTION_ATTACK]
	if unit.has_spells():
		options.append(_ACTION_SPELL)
	options.append(_ACTION_STATS)
	options.append(_ACTION_END)
	return options


## Whether `action` can be chosen right now, given the per-turn budget (see MAX_ACTIONS_PER_TURN):
## Move needs an unused action slot; Attack/Spell need a slot AND that no attack/spell was already
## used this turn; Stats and End Turn are always free. This is both the gate for activation and the
## source of the menu's greying, so what's greyed is exactly what's refused.
func _is_action_enabled(action: String) -> bool:
	match action:
		_ACTION_MOVE:
			return _actions_taken < MAX_ACTIONS_PER_TURN
		_ACTION_ATTACK, _ACTION_SPELL:
			return _actions_taken < MAX_ACTIONS_PER_TURN and not _offensive_taken
		_:
			return true   # Stats / End Turn never count against the budget


## Push the current enabled/disabled state of every menu option to the HUD (greys what
## `_is_action_enabled` refuses). Called whenever the budget might have changed — turn start and
## after each committed action.
func _refresh_menu_enabled() -> void:
	var states: Array = []
	for option in _menu_options:
		states.append(_is_action_enabled(option))
	_menu.set_enabled(states)


## The first option the cursor may legally rest on (first enabled) — used after a commit so the
## highlight doesn't land on a freshly-greyed option. Stats/End Turn are always enabled, so this
## always finds one; falls back to 0 defensively.
func _first_enabled_index() -> int:
	for i in _menu_options.size():
		if _is_action_enabled(_menu_options[i]):
			return i
	return 0


## Run the highlighted option: move, basic attack, open the spell submenu, inspect stats, or end
## the turn. "Attack" aims the unit's weapon attack; "Spell" defers the profile choice to the
## submenu (each spell is its own `Attack`). A disabled (greyed) option is a no-op — the budget
## already spent it.
func _activate_menu_option() -> void:
	var action: String = _menu_options[_menu_index]
	if not _is_action_enabled(action):
		return
	match action:
		_ACTION_MOVE:
			_enter_move_phase()
		_ACTION_ATTACK:
			_enter_attack_phase(_active_unit.basic_attack())
		_ACTION_SPELL:
			_enter_spell_menu()
		_ACTION_STATS:
			_inspect_active_unit()
		_ACTION_END:
			_turn_manager.end_turn()


# --- Spell submenu (nested off the action menu) ------------------------------

## Open the spell submenu: stay in a menu state, keep the action menu visible with "Spell"
## highlighted, and dock the spell list to its right (the nesting convention). The submenu is
## rebuilt for the active unit's `known_spells` each time it opens.
func _enter_spell_menu() -> void:
	_phase = Phase.SPELL_MENU
	_spell_index = 0
	var names: Array = []
	var costs: Array = []
	for spell in _active_unit.known_spells:
		names.append(spell.display_name)
		costs.append(spell.mp_cost)
	_spell_menu.build(names, costs)
	_refresh_spell_menu()
	# Dock beside the action menu's current box (it's visible and laid out, so its rect is valid).
	_spell_menu.open_beside(_menu.panel_rect())


## Move the spell highlight (wrapping) and re-render affordability.
func _set_spell_index(index: int) -> void:
	_spell_index = wrapi(index, 0, _active_unit.known_spells.size())
	_refresh_spell_menu()


## Re-render the spell rows: highlight the current one and grey out any the active unit can't
## currently afford (live MP vs each spell's cost).
func _refresh_spell_menu() -> void:
	var affordable: Array = []
	for spell in _active_unit.known_spells:
		affordable.append(_active_unit.current_mp >= spell.mp_cost)
	_spell_menu.refresh(_spell_index, affordable)


## Pick the highlighted spell: if the unit can afford it, enter the targeting phase with that
## spell's `Attack` profile (MP is spent later, on commit); otherwise flash "Not Enough MP" and
## stay in the submenu.
func _activate_spell_option() -> void:
	var spell: Attack = _active_unit.known_spells[_spell_index]
	if _active_unit.current_mp < spell.mp_cost:
		_spell_menu.flash_insufficient()
		return
	_enter_attack_phase(spell)


## Back out of the spell submenu to the parent action menu (Left/Esc): hide the submenu and return
## to the MENU phase, leaving the action menu as it was (still highlighting "Spell").
func _exit_spell_menu() -> void:
	_phase = Phase.MENU
	_spell_menu.set_menu_visible(false)


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
	_actions_taken += 1   # a committed move spends one of the turn's action slots
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


# --- Attack phase ------------------------------------------------------------

## Switch from the menu into aiming an attack with `profile` (the unit's weapon attack from
## "Attack", or a chosen spell from the submenu) + snapshot its reachable tiles. The display is
## split in two so a ranged shot or spell reads clearly: the whole reach *band* gets the black
## move-range OUTLINE ("everywhere this attack covers"), while only the tiles holding an enemy in
## that band are *filled* orange ("what you can actually hit"). Clicking an in-range enemy commits
## (see `_attack_input`); Escape returns to the menu. `_attack_tiles` indexes the full band so the
## click check is O(1); the per-tile enemy test in `_try_attack` still decides a legal target.
func _enter_attack_phase(profile: Attack) -> void:
	_phase = Phase.ATTACK
	_menu.set_menu_visible(false)
	_spell_menu.set_menu_visible(false)   # if we came from the spell submenu
	_status_panel.hide_panel()
	_unpin_stats()
	_clear_plan()   # drop any move overlays before drawing the attack reach

	_attack_profile = profile
	var tiles := _battlefield.tiles_in_range(
		_active_unit.grid_coord, _attack_profile.min_range, _attack_profile.max_range)

	# Index the whole band for O(1) target validation on click, and outline it the same way the
	# move range is drawn (show_move_range keys on a dict's tiles) so the reach silhouette — outer
	# edge plus the point-blank hole for ranged — shows "all around the unit".
	_attack_tiles = {}
	var band := {}
	for t in tiles:
		_attack_tiles[t] = true
		band[t] = true
	_battlefield.show_move_range(band)

	# Fill orange ONLY the band tiles that hold a viable target (an enemy of the active unit), so
	# the orange squares mark exactly who can be hit, not the empty reach.
	var targets: Array[Vector2i] = []
	for t in tiles:
		var occupant: Unit = _units_by_tile.get(t)
		if occupant != null and occupant.allegiance != _active_unit.allegiance:
			targets.append(t)
	_battlefield.show_attack_range(targets)


## Attack-phase input: left-click an in-range enemy to strike; Escape backs out to the menu.
func _attack_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_try_attack(event.position)
	elif event.is_action_pressed("ui_cancel"):  # Escape: cancel back to the menu
		_start_turn()


## Validate a click during the attack phase and, if it lands on an enemy inside the reach,
## commit the attack. Clicks outside the range, on empty tiles, on the attacker, or on an ally
## do nothing (you can only strike an enemy in range).
func _try_attack(screen_point: Vector2) -> void:
	var tile := _battlefield.tile_at_screen_point(_camera, screen_point)
	if tile == Battlefield.INVALID_TILE or not _attack_tiles.has(tile):
		return
	var target: Unit = _units_by_tile.get(tile)
	if target == null or target == _active_unit or target.allegiance == _active_unit.allegiance:
		return
	await _commit_attack(_active_unit, target, _attack_profile)
	_start_turn()   # back to the menu (Attack/Spell now greyed by the spent offensive action)


## Resolve and play out one attack, awaitable so the caller can sequence what comes next (the
## player returns to the menu, the enemy AI ends its turn). The mechanics (hit roll + damage) are
## computed up front by `CombatResolver`; the *presentation* is sequenced separately and awaited —
## attack animation, then apply damage on impact, then a death animation if it was lethal — so
## other reactions can be slotted in later. Shared by both sides (so enemy arrow/fireball/bonk
## animations come for free). Input is gated by `_resolving_action` for the duration so the player
## can't queue a second attack mid-swing.
func _commit_attack(attacker: Unit, target: Unit, attack: Attack) -> void:
	_resolving_action = true
	_battlefield.clear_attack_range()
	_battlefield.clear_move_range()   # the band outline drawn in _enter_attack_phase

	# Spend an action slot and mark the offensive action used (a turn allows only one attack/spell),
	# so the menu greys Attack/Spell when we return to it.
	_actions_taken += 1
	_offensive_taken = true

	# Pay the cost up front (the spell menu already confirmed it was affordable). 0 for basic
	# weapon attacks, so this is a no-op for melee/arrow — only spells spend MP.
	if attack.mp_cost > 0:
		attacker.spend_mp(attack.mp_cost)

	var outcome := CombatResolver.resolve(attacker, target, attack, _rng)
	print("%s attacks %s with %s — roll %.2f vs %.2f → %s (%d dmg)" % [
		attacker.display_name(), target.display_name(), attack.display_name,
		outcome["roll"], outcome["chance"], "HIT" if outcome["hit"] else "MISS", outcome["damage"]])

	# Presentation: swing first, then land the damage, then topple the target if it died.
	await attacker.play_attack_animation(attack.anim, target.global_position)
	if outcome["hit"]:
		target.apply_damage(outcome["damage"])
		_spawn_damage_number(target, outcome["damage"])  # floats independently of the turn flow
		if not target.is_alive():
			await _kill_unit(target)

	_resolving_action = false


## Pop a floating "-N" damage number above `target` and let it rise/fade on its own. Parented
## to the battlefield (not the target) so it finishes even if the target dies and is freed; not
## awaited, so it drifts while the turn carries on. Generic effect — see `FloatingCombatText`.
func _spawn_damage_number(target: Unit, amount: int) -> void:
	var head := target.global_position + Vector3.UP * DAMAGE_NUMBER_HEIGHT
	FloatingCombatText.spawn(_battlefield, head, "-%d" % amount, DAMAGE_NUMBER_COLOR)


## Play a unit's death animation, then remove it from the battle: free its tile, drop it from
## the turn schedule (so it never gets another turn), and free the node. Awaited by the attack
## sequence so the turn doesn't resume until the body has toppled and faded.
func _kill_unit(unit: Unit) -> void:
	await unit.play_death_animation()
	_units_by_tile.erase(unit.grid_coord)
	_turn_manager.unregister(unit)
	# If we were inspecting the unit that just died, drop the hover so next frame doesn't touch
	# the freed instance and the panel closes cleanly.
	if _hover_unit == unit:
		_hover_unit = null
		_hide_stat_panel()
	unit.queue_free()
	# A death may have wiped a side — check now (after the unit is off the board) and, if so, kick
	# off the win/lose sequence.
	_check_battle_end()


## After a death, see whether one side has been wiped out and, if so, end the battle. Only one unit
## dies per attack and the attacker's side always survives, so a wipe means: no enemies left → the
## player WON; no players left → the player LOST. No-op once the game is already over.
func _check_battle_end() -> void:
	if _game_over:
		return
	var players_alive := false
	var enemies_alive := false
	for u in _units_by_tile.values():
		if u.allegiance == Unit.Allegiance.PLAYER:
			players_alive = true
		else:
			enemies_alive = true
	if not enemies_alive:
		_end_battle(true)
	elif not players_alive:
		_end_battle(false)


## Latch the battle as decided and play the end sequence. Sets `_game_over` (which gates the turn
## loop, input, and per-frame work everywhere), clears the gameplay HUD, then fires the cinematic
## fire-and-forget so this returns immediately (the kill/attack call chain unwinds cleanly while the
## celebration plays on its own).
func _end_battle(win: bool) -> void:
	_game_over = true
	_menu.set_menu_visible(false)
	_spell_menu.set_menu_visible(false)
	_status_panel.hide_panel()
	_hide_stat_panel()
	_shift_counter.set_count(-1)          # negative hides the countdown box
	_battlefield.clear_active_tile()
	_clear_plan()                         # drop any lingering move/attack overlays
	_play_end_sequence(win)


## The end cinematic: pull the camera back to the whole-map framing, then — on a win — spin the
## camera forever and fade the rainbow "YOU WIN" in; on a loss, fade the screen to black with a deep
## red "YOU LOSE". Runs detached (not awaited) so it owns the screen for the rest of the session.
func _play_end_sequence(win: bool) -> void:
	if win:
		_camera.start_victory_orbit()     # begin the slow spin as we pull back
	_camera.focus_on(Vector3.ZERO)        # recenter on the whole map (follow is gated off now)
	await _camera.zoom_to(_camera.home_ortho_size(), MAP_ZOOM_TIME)
	if win:
		_end_screen.show_win()
	else:
		_end_screen.show_lose()


# --- Turn / active-unit management -------------------------------------------

## Begin (or restart) the active unit's turn: enter the menu phase with "Move"
## highlighted, and clear any half-planned move. Called when a unit becomes active,
## after a move commits, and when cancelling out of move mode.
func _start_turn() -> void:
	# If the battle just ended (e.g. the attack that returns here killed the last enemy), don't
	# re-open the menu over the end screen.
	if _game_over:
		return
	_phase = Phase.MENU
	_clear_plan()
	_unpin_stats()
	_spell_menu.set_menu_visible(false)   # close any nested submenu when returning to the menu
	_hovered_tile = Battlefield.INVALID_TILE
	_menu.set_menu_visible(true)
	# Grey out whatever the per-turn budget now forbids, and put the cursor on the first option that
	# is still choosable (so it doesn't start on a just-greyed action after the unit acted).
	_refresh_menu_enabled()
	_menu_index = _first_enabled_index()
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
	_battlefield.clear_attack_range()


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
	# Battle's over — ignore any further hand-offs from the (still-ticking) turn manager so the end
	# sequence isn't interrupted by a menu opening or an enemy turn starting.
	if _game_over:
		return
	_active_unit = unit
	if unit == null:
		_battlefield.clear_active_tile()
		return
	# Fresh turn → fresh action budget (per-turn limit; see MAX_ACTIONS_PER_TURN).
	_actions_taken = 0
	_offensive_taken = false
	_menu.set_title(unit.display_name())  # show whose turn it is
	# Build the action menu for THIS unit (casters get "Spell"); the list can differ per unit, so
	# rebuild on each hand-off rather than reusing a fixed set.
	_menu_options = _menu_options_for(unit)
	_menu.build(_menu_options)
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


## Drive an enemy's turn with a simple offense AI, reusing the player's own action functions so the
## computer obeys the identical rules ("a fair fight"). The loop, within the per-turn budget (≤2
## actions, ≤1 attack), with a pause between beats so it reads as deliberate, not a teleport:
##   1. If a target is already in range of its best attack, strike and end (no move).
##   2. Otherwise move toward the nearest enemy (the same reachable outline + path preview the
##      player sees), then try to strike from the new position.
##   3. If still out of range after that move, spend the second action closing further, then end.
## "Best attack" prefers an affordable spell over the basic weapon attack. Attacks run through the
## shared `_commit_attack`, so enemy arrow/fireball/bonk animations (with their pauses) come for
## free. The leading `await` also defers the work past the signal that began this turn, so ending
## it never re-enters the turn manager from inside its own emission.
func _take_enemy_turn(unit: Unit) -> void:
	# Hide any stale player menu (and nested submenu) from the previous turn before the opening pause.
	_menu.set_menu_visible(false)
	_spell_menu.set_menu_visible(false)
	_status_panel.hide_panel()
	await get_tree().create_timer(ENEMY_TURN_DELAY).timeout

	# The attack this enemy will try all turn — a spell it can afford if any, else its weapon.
	var attack := _enemy_choose_attack(unit)

	# 1) Already in range? Strike without moving, then end the turn.
	var target := _enemy_target_in_range(unit, attack)
	if target != null:
		await _enemy_attack(unit, attack, target)
		_turn_manager.end_turn()
		return

	# Need to close in. With no enemies left there's nothing to do.
	var prey := _nearest_enemy(unit)
	if prey == null:
		_turn_manager.end_turn()
		return

	# 2) Move toward the prey, then try to strike from the new position.
	await _enemy_move_toward(unit, prey, attack)
	await get_tree().create_timer(ENEMY_TURN_DELAY).timeout
	target = _enemy_target_in_range(unit, attack)
	if target != null:
		await _enemy_attack(unit, attack, target)
		_turn_manager.end_turn()
		return

	# 3) Still out of range — spend the second action closing further, then end.
	await _enemy_move_toward(unit, prey, attack)
	_turn_manager.end_turn()


## The attack an enemy uses this turn: the first spell it can currently afford (offense prefers
## magic), otherwise its basic weapon attack. Returns a fresh `Attack` (range band + anim + cost).
func _enemy_choose_attack(unit: Unit) -> Attack:
	for spell in unit.known_spells:
		if unit.current_mp >= spell.mp_cost:
			return spell
	return unit.basic_attack()


## The nearest enemy of `unit` that is *within `attack`'s range band right now* (hittable without
## moving), or null. Distance is flat grid (Manhattan), matching `tiles_in_range`.
func _enemy_target_in_range(unit: Unit, attack: Attack) -> Unit:
	var best: Unit = null
	var best_dist := 1 << 30
	for other in _units_by_tile.values():
		if other.allegiance == unit.allegiance:
			continue
		var dist := _grid_distance(unit.grid_coord, other.grid_coord)
		if dist >= attack.min_range and dist <= attack.max_range and dist < best_dist:
			best_dist = dist
			best = other
	return best


## The nearest enemy of `unit` by flat grid distance, ignoring range (the prey to close on), or
## null if none remain.
func _nearest_enemy(unit: Unit) -> Unit:
	var best: Unit = null
	var best_dist := 1 << 30
	for other in _units_by_tile.values():
		if other.allegiance == unit.allegiance:
			continue
		var dist := _grid_distance(unit.grid_coord, other.grid_coord)
		if dist < best_dist:
			best_dist = dist
			best = other
	return best


## Move `unit` one step of its turn toward `prey`: enter the move phase (compute reachability + show
## the outline the player sees), pick a destination, preview the path, then walk it and wait for
## arrival. Destination = the reachable tile that puts `prey` inside `attack`'s range band with the
## least movement if one exists; otherwise the reachable tile that gets closest to `prey`. A no-op
## (nowhere better to stand) just clears the overlays.
func _enemy_move_toward(unit: Unit, prey: Unit, attack: Attack) -> void:
	_enter_move_phase()   # snapshots _reachable / _move_solid / _move_occupied and shows the outline
	await get_tree().create_timer(ENEMY_TURN_DELAY).timeout

	var dest := _enemy_pick_destination(unit, prey, attack)
	if dest == unit.grid_coord:
		_clear_plan()
		return
	var path := _battlefield.find_path(
		unit.grid_coord, dest, unit.max_stats.move, unit.max_stats.jump,
		_move_solid, _move_occupied)
	if path.size() < 2:
		_clear_plan()
		return

	# Preview the route under the same blue/red legality rules the player follows, then walk it.
	var flags := _battlefield.classify_path(
		path, unit.max_stats.move, unit.max_stats.jump, _move_solid, _move_occupied)
	_battlefield.show_path(path, flags)
	await get_tree().create_timer(ENEMY_TURN_DELAY).timeout
	_perform_move(path)   # clears the overlays and starts the walk
	await unit.move_finished


## Pick where an enemy should move from the reachable set (`_reachable`, just computed by
## `_enter_move_phase`): prefer a tile that brings `prey` inside `attack`'s range band, choosing the
## one needing the least movement; failing that, the reachable tile that minimizes distance to
## `prey` (close in for next turn). Returns the current tile if neither beats standing still.
func _enemy_pick_destination(unit: Unit, prey: Unit, attack: Attack) -> Vector2i:
	var in_range_tile := Battlefield.INVALID_TILE
	var in_range_cost := 1 << 30
	var closer_tile := unit.grid_coord
	var closer_dist := _grid_distance(unit.grid_coord, prey.grid_coord)
	for tile in _reachable:
		var dist := _grid_distance(tile, prey.grid_coord)
		if dist >= attack.min_range and dist <= attack.max_range:
			var cost: int = _reachable[tile]
			if cost < in_range_cost:
				in_range_cost = cost
				in_range_tile = tile
		if dist < closer_dist:
			closer_dist = dist
			closer_tile = tile
	return in_range_tile if in_range_tile != Battlefield.INVALID_TILE else closer_tile


## Telegraph then resolve an enemy strike on `target`: flash the orange marker on the target tile,
## brief pause, then run the shared `_commit_attack` (which clears the marker and plays the attack's
## own animation). Awaitable so the caller ends the turn only after it resolves.
func _enemy_attack(unit: Unit, attack: Attack, target: Unit) -> void:
	_battlefield.show_attack_range([target.grid_coord])
	await get_tree().create_timer(ENEMY_TURN_DELAY).timeout
	await _commit_attack(unit, target, attack)


## Flat grid (Manhattan) distance between two tiles — the same metric `tiles_in_range` uses, so the
## AI's range checks agree with the targeting overlay.
func _grid_distance(a: Vector2i, b: Vector2i) -> int:
	return abs(a.x - b.x) + abs(a.y - b.y)


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
	_spell_menu.set_menu_visible(false)
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


## True only while a PLAYER unit holds the turn AND no map-transition cinematic is playing AND the
## battle is still on — the gate for all player input (menu keys and move placement), so input does
## nothing during an enemy's self-driven AI turn, while the map is shifting, or after the battle ends.
func _is_player_turn() -> bool:
	return _active_unit != null \
		and _active_unit.allegiance == Unit.Allegiance.PLAYER \
		and not _map_transition_playing \
		and not _resolving_action \
		and not _game_over
