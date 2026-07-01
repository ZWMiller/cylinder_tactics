## One enemy placed on the map by the encounter designer: WHERE it stands and WHAT it is.
##
## This is the authored counterpart to the hardcoded `_enemy_roster` rows that used to live
## in `Main` — a row like `[3, 7, SOLDIER, 1]` becomes an `EnemyPlacement`. It is deliberately
## a pure data bag (a "person spec"): the battle code reads it and rolls a `Recruit` from
## `class + level` via `StatRoll`, exactly the same spawn path the demo roster used. Nothing
## here contains behavior — the reactive per-battle logic lives in the battle script that
## loads the encounter, not in this file.
##
## GDScript note: this is a `Resource` sub-object embedded in an `Encounter` (an `Encounter`
## owns an `Array[EnemyPlacement]`), the same nesting pattern `MapData` uses for its `MapState`s
## and the recruit `.tres` files use for their `StatBlock`s.
class_name EnemyPlacement
extends Resource

## Optional stable handle for this enemy, so a per-battle script can grab a specific unit by
## NAME (e.g. `get_enemy("god_avatar")`) instead of by fragile grid coordinates that break the
## moment the placement is nudged in the designer. Empty for a plain, anonymous foe. Unused by
## the generic battle loader today — baked in now so scripted encounters need no format change.
@export var id: String = ""

## The tile this enemy spawns on, as grid coordinates `(x, z)`. Must be in-bounds for the
## encounter's map; the loader places the unit here with `Unit.grid_coord = tile`.
@export var tile: Vector2i = Vector2i.ZERO

## The class this enemy rolls as — a `UnitClasses.Class` value stored as its backing int (the
## same "class as int" convention `Recruit.starting_class` uses). Fed to `StatRoll.random_recruit`.
@export var klass: int = 0

## The level this enemy enters play at. `StatRoll` rolls stats appropriate to this level; 1 is a
## fair test-fight default (matching the demo). Bump for a tougher encounter.
@export var level: int = 1

## RESERVED for Phase 3b — per-stat overrides (absolute or delta HP / MP / Speed / Move, and a
## specific weapon/armor kit) layered on top of the rolled block. Empty and UNREAD in 3a; the
## loader rolls a plain class/level foe. Declared now so adding overrides later doesn't reshape
## saved encounters. See docs/TODO.md "Phase 3" and docs/map_builder_implementation_plan.md §10.
@export var overrides: Dictionary = {}
