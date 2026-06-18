## One concrete battlefield *configuration*: the three-state "degrading time"
## demo map (see docs/GAME_DESIGN.md §4 for the narrative).
##
## The three states form a cycle:
##   0. Grassland with a hill rising out of one corner.
##   1. A river has carved a canyon down through that hill and now cuts across the
##      grassland (water tiles sunk into a channel; the cut through the hill
##      exposes tall brown canyon walls).
##   2. The world has dried to desert: the hill is much lower and spread out, and
##      the river is gone — its channel is now an empty stone riverbed.
## After state 2 the shift wraps back to state 0.
##
## Coordinate note (important): everything in this file is in **grid indices**
## (x, z), integer tile addresses from 0..width-1 / 0..height-1. Grid index (0, 0)
## is a *corner tile* of the grid. That is NOT the world origin: Battlefield
## centers the grid on the world origin, so the center tile maps to world (0,0,0)
## and corner (0, 0) maps to a far corner out in world space. So "the hill is at
## grid corner (0, 0)" and "the grid is centered on the origin" are both true.
##
## Everything is generated *procedurally from parameters* rather than hand-typed,
## so a 24x24 map is 1,728 tiles we never have to write out by hand, and the
## terrain is easy to retune. Swap this generator (or assign Battlefield.states
## directly) to get a different map.
##
## Like TileTypes, this is a `class_name` namespace of `static` functions; it is
## never instantiated.
class_name DemoMap
extends RefCounted

# --- Tuning parameters -------------------------------------------------------
# Heights are integer "levels"; Battlefield multiplies them by its height_step to
# get world units. Keeping them as ints matches the design's "a height-5 tile
# becomes height 2" framing.

const GROUND_HEIGHT := 1   ## Baseline height of flat grassland / desert floor.

const HILL_PEAK := 6       ## Extra height at the hill's corner in the grassland state.
const HILL_FALLOFF := 1.0  ## Height lost per tile of distance from the corner.

const DESERT_HILL_PEAK := 3    ## The desert hill is lower...
const DESERT_HILL_FALLOFF := 0.4  ## ...and spreads out more slowly.

const CANYON_FLOOR := 1    ## Height of the river/canyon bottom in the canyon state.
const RIVER_HALF_WIDTH := 1.0  ## A tile is "river" if within this many tiles of the path center (=> 3 wide).


## Generate the full list of states for a `width` x `height` grid. This is the
## entry point Battlefield calls.
static func generate(width: int, height: int) -> Array:
	return [
		_state_grassland(width, height),
		_state_canyon(width, height),
		_state_desert(width, height),
	]


# --- Shared terrain shape functions ------------------------------------------

## Extra height contributed by the corner hill at grid index (x, z), for a given
## peak and falloff. The hill is anchored at grid corner (0, 0) (the first tile,
## not the world origin); height fades with Manhattan distance from that corner
## and never goes negative.
static func _hill(x: int, z: int, peak: float, falloff: float) -> int:
	var distance := x + z
	return int(round(max(0.0, peak - distance * falloff)))


## The X grid index of the river's center as it crosses row `z`. The river runs
## diagonally from the hill corner out across the map, with a gentle meander so
## it doesn't read as a straight line. (Returns a float; tiles near it count as
## river — see `_is_river`.)
static func _river_center_x(z: int) -> float:
	return 2.0 + 0.8 * z + 2.0 * sin(z * 0.4)


## Whether grid index (x, z) lies within the river's channel for this map.
static func _is_river(x: int, z: int) -> bool:
	return abs(x - _river_center_x(z)) <= RIVER_HALF_WIDTH


# --- State builders ----------------------------------------------------------

## State 0 — grassland with a hill in grid corner (0, 0). All grass; height is the
## flat ground plus the corner hill.
static func _state_grassland(width: int, height: int) -> Array:
	var state: Array = []
	for x in width:
		var column: Array = []
		for z in height:
			var h := GROUND_HEIGHT + _hill(x, z, HILL_PEAK, HILL_FALLOFF)
			column.append({"height": h, "type": TileTypes.Type.GRASS})
		state.append(column)
	return state


## State 1 — the river has cut a canyon through the hill and across the grassland.
## The land still has the grassland hill, but every river-channel tile is sunk to
## the canyon floor and turned to water. Where the channel passes through the
## tall hill, the surrounding land towers over the floor, giving brown canyon
## walls for free.
static func _state_canyon(width: int, height: int) -> Array:
	var state: Array = []
	for x in width:
		var column: Array = []
		for z in height:
			if _is_river(x, z):
				column.append({"height": CANYON_FLOOR, "type": TileTypes.Type.WATER})
			else:
				var h := GROUND_HEIGHT + _hill(x, z, HILL_PEAK, HILL_FALLOFF)
				column.append({"height": h, "type": TileTypes.Type.GRASS})
		state.append(column)
	return state


## State 2 — the desert end state. Everything is sand, the hill is much lower and
## more spread out, and the former river is a dry stone riverbed sunk one level
## below the surrounding sand.
static func _state_desert(width: int, height: int) -> Array:
	var state: Array = []
	for x in width:
		var column: Array = []
		for z in height:
			var ground := GROUND_HEIGHT + _hill(x, z, DESERT_HILL_PEAK, DESERT_HILL_FALLOFF)
			if _is_river(x, z):
				# Dry riverbed: stone, carved a little below the surrounding sand.
				var bed: int = max(GROUND_HEIGHT, ground - 1)
				column.append({"height": bed, "type": TileTypes.Type.STONE})
			else:
				column.append({"height": ground, "type": TileTypes.Type.SAND})
		state.append(column)
	return state
