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
