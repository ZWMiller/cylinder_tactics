## A single combat unit: a cylinder body (color = allegiance) wearing a hat
## (shape + color = class). See docs/GAME_DESIGN.md §7 for the visual language and
## docs/UNIT.md for this component.
##
## This script is attached to the root of `scenes/Unit.tscn`, so `Unit` IS the
## self-contained object you interact with in the scene: it owns its appearance
## now and will own its stats, grid coordinate, and combat methods later. The
## `.tscn` only authors the *node layout* (a Body and a Hat mesh child); this
## script owns *identity* (which side, which class) and applies it to that layout.
##
## Reskinning (the requirement that drove this design): every unit builds its OWN
## materials in code. Godot materials are *resources* — if two units shared one
## `StandardMaterial3D`, recoloring one would recolor the other. Giving each unit
## its own material (via `material_override`) keeps units independently skinnable,
## so you can spawn many and tint each freely. This is a key Godot gotcha worth
## remembering: shared resources are shared *state*, not just shared definitions.
class_name Unit
extends Node3D

## The two sides. Body color reads allegiance, independent of class — so a player
## archer and an enemy archer share a hat but differ in body color.
enum Allegiance {
	PLAYER,  ## The player's side.
	ENEMY,   ## The opposing side.
}

# --- Identity (editable in the Inspector AND settable from code via configure) -

## Which side this unit fights for; drives the body color.
@export var allegiance: Allegiance = Allegiance.PLAYER

## This unit's class; drives the hat shape + color (see UnitClasses).
@export var unit_class: UnitClasses.Class = UnitClasses.Class.SOLDIER

## The unit's tile address on the battlefield grid, deliberately *decoupled* from
## its world position (docs/GAME_DESIGN.md §8). The mover (Main, later the turn
## system) updates this; `move_to` only handles the *visual* glide.
var grid_coord: Vector2i = Vector2i.ZERO

# --- Stats (class base + per-person aptitude + banked level-up growth) ---------
# Effective max stats = current class base + banked growth + aptitude:
#   - `unit_class` (above) selects the base profile (and appearance),
#   - `recruit` carries the per-person aptitude + identity (null for legacy spawns),
#   - `level_history` records the class held at each past level-up — the FFT-style
#     bank that makes a unit's stats remember the jobs it leveled in.
# See docs/GAME_DESIGN.md §3 and the stat scripts under scripts/stats/.

## The person behind this unit (authored PC or rolled enemy): innate aptitude + name.
## May be null for units spawned the old appearance-only way via `configure`.
var recruit: Recruit = null

## This unit's level. Level 1 = class base only; each `level_up` appends to history.
@export var level: int = 1

## Class held at each past level-up — one int per level gained (length == level − 1).
## Summed into banked growth by `UnitClasses.banked_growth`; written by `level_up` /
## seeded by `init_from_recruit`.
var level_history: Array[int] = []

## Computed effective MAX stats — the read-only result of `recompute_stats`. Don't
## edit directly; change an input (class, level, aptitude) and recompute.
var max_stats: StatBlock = null

## Live, per-unit pools — the ONLY mutable stat state, kept off the shared templates
## (the shared-by-reference gotcha in the class docstring).
var current_hp: int = 0
var current_mp: int = 0

# --- Movement (visual glide between tiles) -----------------------------------

## Glide speed in world units per second. Constant speed (via `move_toward`) gives
## a predictable arrival, unlike the ease-out of a `lerp`.
const MOVE_SPEED := 6.0

## The remaining points this unit is walking through, front first (in the parent's
## local space). Built from `Battlefield.path_to_world_points`, so the unit steps
## up/down tile by tile instead of gliding in a straight line. Empty when stopped.
var _move_queue: Array[Vector3] = []

## True while a walk is in progress. Gates `_process` so an idle unit costs nothing,
## and lets callers (Main) avoid interrupting a move in progress.
var _is_moving: bool = false

# --- Cached child references (resolved once the node is in the tree) ----------
# `@onready` runs the assignment just before `_ready`, so these are valid for the
# whole lifetime; `$Body` / `$Hat` are the children authored in Unit.tscn.
@onready var _body: MeshInstance3D = $Body
@onready var _hat: MeshInstance3D = $Hat


## Godot lifecycle hook: runs once when the unit enters the scene tree. Applies
## the current allegiance/class to the meshes and materials.
func _ready() -> void:
	_apply_appearance()
	# Units spawned appearance-only (configure() with no recruit) still need valid
	# stats, so derive a baseline from the class and fill the pools to full. A unit set
	# up via init_from_recruit already has max_stats, so we don't clobber it here.
	if max_stats == null:
		recompute_stats()
		current_hp = max_stats.max_hp
		current_mp = max_stats.max_mp
	# Idle until something calls `move_to`; no need to run `_process` every frame.
	set_process(false)


## Walk this unit through `points` in order (parent-local positions), at a constant
## speed, stopping at the last. Pass the polyline from
## `Battlefield.path_to_world_points` so the unit steps up/down tile by tile. The
## caller owns `grid_coord`/occupancy. An empty list is a no-op.
func move_along(points: Array) -> void:
	if points.is_empty():
		return
	_move_queue = points.duplicate()
	_is_moving = true
	set_process(true)


## True while a walk is in progress, so the input handler can avoid starting a new
## move (or changing the active unit) mid-step.
func is_moving() -> bool:
	return _is_moving


## Godot lifecycle hook: runs every frame, but only while a walk is active (we
## toggle it off when idle). Advances toward the next queued point at a constant
## speed; on arrival, pops it and aims at the next. `move_toward` clamps exactly to
## the target on the final step, so the equality check lands precisely.
func _process(delta: float) -> void:
	if _move_queue.is_empty():
		_is_moving = false
		set_process(false)
		return
	var target: Vector3 = _move_queue[0]
	position = position.move_toward(target, MOVE_SPEED * delta)
	if position.is_equal_approx(target):
		position = target  # snap, so floating-point drift doesn't accumulate
		_move_queue.pop_front()


## Toggle the "this is the active unit" highlight — a soft glow on the body so the
## player can see whose turn it is. Uses the body's own material (each unit has its
## own, so this never lights up other units).
func set_active(active: bool) -> void:
	var mat := _body.material_override as StandardMaterial3D
	if mat == null:
		return
	mat.emission_enabled = active
	if active:
		mat.emission = Color(1.0, 0.95, 0.4)  # warm yellow glow
		mat.emission_energy_multiplier = 0.5


## Set this unit's side and class in one call, then refresh its look. The
## convenient entry point for code-spawning many units from data:
##   var u := UNIT_SCENE.instantiate(); u.configure(Allegiance.ENEMY, Class.MAGE)
## Safe to call before the unit is in the tree (the values are stored and applied
## by `_ready`) or after (it re-applies immediately).
func configure(side: Allegiance, klass: UnitClasses.Class) -> void:
	allegiance = side
	unit_class = klass
	if is_node_ready():
		_apply_appearance()


# --- Stats & class (the job system) ------------------------------------------

## Set this unit up from a `Recruit` — the rich spawn path shared by authored PCs and
## rolled enemies. Adopts the recruit's starting class + level, seeds the level history
## as if it leveled the whole way in that class, computes max stats, and fills HP/MP to
## full. After this the unit is combat-ready.
func init_from_recruit(r: Recruit) -> void:
	recruit = r
	unit_class = r.starting_class
	level = maxi(1, r.starting_level)
	# A freshly spawned unit has no real per-level job history, so assume it leveled
	# entirely in its starting class. (PCs usually start at level 1 → empty history.)
	level_history.clear()
	for _i in range(level - 1):
		level_history.append(unit_class)
	if is_node_ready():
		_apply_appearance()
	recompute_stats()
	current_hp = max_stats.max_hp
	current_mp = max_stats.max_mp


## Recompute `max_stats` from current class base + banked level-up growth + aptitude,
## then clamp the live pools so they never exceed the new maxes. Call after anything
## that changes the inputs (reclass, level-up). Pure recompute — it does NOT heal.
func recompute_stats() -> void:
	var cd := UnitClasses.class_def(unit_class)
	# Defensive: an unmapped class has no asset. Fall back to an empty block so the
	# unit still functions (zeroed) instead of crashing on a null base.
	var base: StatBlock = cd.base if cd != null and cd.base != null else StatBlock.new()
	var banked := UnitClasses.banked_growth(level_history)
	max_stats = base.combined(banked).combined(_aptitude()).clamped_nonneg()
	current_hp = mini(current_hp, max_stats.max_hp)
	current_mp = mini(current_mp, max_stats.max_mp)


## Gain one level IN THE CURRENT CLASS: bank this class's growth and raise the live
## pools by the max-stat increase (so a level-up actually heals you by the gain). This
## is where the "level as a mage, keep the mage gains" history entry is written.
func level_up() -> void:
	level += 1
	level_history.append(unit_class)
	var prev_hp_max: int = max_stats.max_hp if max_stats != null else 0
	var prev_mp_max: int = max_stats.max_mp if max_stats != null else 0
	recompute_stats()
	current_hp += maxi(0, max_stats.max_hp - prev_hp_max)
	current_mp += maxi(0, max_stats.max_mp - prev_mp_max)


## Reclass / job change: swap the class (base + appearance) while KEEPING this unit's
## identity, level, banked history, and aptitude. The base changes immediately, but
## growth banked under previous jobs persists — the core of the job system. Current
## HP/MP are clamped down by `recompute_stats` if the new base is frailer.
func set_class(klass: int) -> void:
	unit_class = klass
	if is_node_ready():
		_apply_appearance()
	recompute_stats()


## The per-person aptitude offsets, or an empty (all-zero) block if this unit has no
## recruit. Centralizes the null-guard so `recompute_stats` stays clean.
func _aptitude() -> StatBlock:
	if recruit != null and recruit.aptitude != null:
		return recruit.aptitude
	return StatBlock.new()


## One-line stat summary for debug prints: who, class, level, and the effective block.
func stats_summary() -> String:
	var who: String = recruit.display_name if recruit != null else "(no recruit)"
	var block: String = max_stats.describe() if max_stats != null else "(no stats)"
	return "%s — L%d %s: %s" % [who, level, UnitClasses.display_name(unit_class), block]


# --- Appearance --------------------------------------------------------------

## Apply allegiance (body color) and class (hat shape + color) to the meshes.
## Central so both `_ready` and `configure` share exactly one code path.
func _apply_appearance() -> void:
	# Body: keep the cylinder authored in the scene; only swap in our own material.
	_body.material_override = _solid_material(allegiance_color(allegiance))

	# Hat: the class can change the *shape*, so swap the mesh, then recolor it.
	_hat.mesh = UnitClasses.new_hat_mesh(unit_class)
	_hat.material_override = _solid_material(UnitClasses.hat_color(unit_class))

	_layout()


## Seat the body's feet at local y=0 and rest the hat on top of the body. Both
## positions are derived from the actual mesh sizes, so resizing a mesh in the
## editor (or swapping the hat for a taller/blockier shape) keeps everything
## aligned with no manual repositioning.
func _layout() -> void:
	# A primitive mesh is centered on its own origin, so a body of height H must be
	# lifted by H/2 for its base to sit at y=0.
	var body_h := _mesh_height(_body.mesh)
	_body.position = Vector3(0.0, body_h * 0.5, 0.0)
	# The hat's base rests on the body's top (y = body_h); lift the hat by half its
	# own height so its base — not its center — lands there.
	_hat.position = Vector3(0.0, body_h + _mesh_height(_hat.mesh) * 0.5, 0.0)


## Build a fresh solid-color material. Each unit gets its own (see the class
## docstring) so recoloring one unit never bleeds onto another.
func _solid_material(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	return mat


## Body/allegiance color. Kept here, not in `UnitClasses`, because it is the
## *other* visual channel — allegiance, not class. Magenta = unmapped side.
static func allegiance_color(side: Allegiance) -> Color:
	match side:
		Allegiance.PLAYER:
			return Color(0.25, 0.45, 0.80)  # blue
		Allegiance.ENEMY:
			return Color(0.75, 0.25, 0.25)  # red
		_:
			return Color.MAGENTA


## Vertical extent of a primitive `mesh`, so the hat can be seated on the body
## regardless of its shape. Handles the shapes a hat/body might use (cone and
## cylinder share `CylinderMesh`; a future square hat is a `BoxMesh`). Returns 0
## for an unknown mesh rather than guessing a wrong size.
static func _mesh_height(mesh: Mesh) -> float:
	if mesh is CylinderMesh:
		return mesh.height
	if mesh is BoxMesh:
		return mesh.size.y
	return 0.0
