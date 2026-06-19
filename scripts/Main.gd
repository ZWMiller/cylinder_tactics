## Top-level scene script. For now its only job is to drop a handful of
## demonstration units onto the battlefield so the unit model + per-class hats +
## allegiance reskinning are visible on F5.
##
## This is intentionally throwaway demo glue: real unit spawning will come from
## map / encounter data alongside the turn system (docs/TODO.md). It lives here so
## `Battlefield` stays focused on terrain and doesn't gain a dependency on `Unit`.
extends Node3D

## The unit scene we stamp out copies of. `preload` loads the resource at parse
## time, so each `.instantiate()` is just a cheap clone of an already-loaded scene.
const UNIT_SCENE := preload("res://scenes/Unit.tscn")

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


## Godot lifecycle hook. A parent's `_ready` runs *after* its children's, so by now
## the Battlefield has already built its tiles and its `tile_to_world` helper is
## usable — we can place units on real tile surfaces immediately.
func _ready() -> void:
	var battlefield: Battlefield = $Battlefield
	for entry in _demo_roster:
		_spawn(battlefield, entry[0], entry[1], entry[2], entry[3])


## Instantiate one unit, skin it, and stand it on tile (x, z). The unit is parented
## under the battlefield so it shares the grid's frame, and positioned with the
## same `tile_to_world` helper movement/combat will use — so it sits exactly on the
## tile's top surface.
func _spawn(battlefield: Battlefield, x: int, z: int, side: Unit.Allegiance, klass: UnitClasses.Class) -> void:
	var unit: Unit = UNIT_SCENE.instantiate()
	# configure() before add_child: the values are stored now and applied by the
	# unit's own _ready when it enters the tree on the next line.
	unit.configure(side, klass)
	unit.grid_coord = Vector2i(x, z)
	battlefield.add_child(unit)
	unit.position = battlefield.tile_to_world(x, z)
