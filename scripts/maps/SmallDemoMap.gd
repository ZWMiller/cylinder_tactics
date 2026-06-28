## A second concrete battlefield *configuration*: a SMALL (12x12) three-state "degrading
## time" demo, the same shape of cycle as `DemoMap` but tuned for tighter, more playtestable
## fights — and with a hill rising out of EACH of the four corners instead of just one.
##
## The three states form a cycle (identical logic to `DemoMap`, see docs/GAME_DESIGN.md §4):
##   0. Grassland with a hill in every corner; a flat-ish diamond in the middle.
##   1. A river has carved a canyon diagonally across the map, cutting through two of the
##      corner hills (water sunk into the channel; the cut through a hill exposes tall brown
##      canyon walls for free, via Battlefield's neighbour-aware column depth).
##   2. The world has dried to desert: the corner hills are much lower and spread out, and the
##      river is gone — its channel is now a dry STONE riverbed sunk below the sand.
## After state 2 the shift wraps back to state 0.
##
## Coordinate note (same as DemoMap): everything here is in **grid indices** (x, z), integer
## tile addresses 0..width-1 / 0..height-1. The four corners are (0,0), (width-1,0), (0,height-1),
## (width-1,height-1); Battlefield centers the grid on the world origin, so those corners map to
## the far edges of the board in world space.
##
## Like `DemoMap` / `TileTypes`, this is a `class_name` namespace of `static` functions, never
## instantiated. It is generic on width/height (the four-corner hill needs the dimensions to find
## the far corners), so the 12x12 size lives in the caller (Battlefield's fallback) rather than here.
class_name SmallDemoMap
extends RefCounted

# --- Tuning parameters -------------------------------------------------------
# Heights are integer "levels"; Battlefield multiplies them by its height_step for world units.
# Kept identical to DemoMap so this reads as "the same map, smaller + four-cornered".

const GROUND_HEIGHT := 1   ## Baseline height of flat grassland / desert floor.

const HILL_PEAK := 6       ## Extra height at each corner in the grassland state.
const HILL_FALLOFF := 1.0  ## Height lost per tile of distance from the nearest corner.

const DESERT_HILL_PEAK := 3       ## The desert corner hills are lower...
const DESERT_HILL_FALLOFF := 0.4  ## ...and spread out more slowly.

const CANYON_FLOOR := 1         ## Height of the river/canyon bottom in the canyon state.
const RIVER_HALF_WIDTH := 1.0   ## A tile is "river" if within this many tiles of the path center (=> 3 wide).


## Generate the full list of states for a `width` x `height` grid — the entry point Battlefield
## calls. (Designed for 12x12, but works at any size.)
static func generate(width: int, height: int) -> Array:
	return [
		_state_grassland(width, height),
		_state_canyon(width, height),
		_state_desert(width, height),
	]


# --- Shared terrain shape functions ------------------------------------------

## Extra height contributed by the FOUR-corner hills at grid index (x, z), for a given peak and
## falloff. Each corner grows its own pyramid; a tile's hill height is set by its NEAREST corner
## (Manhattan distance), so the hills fade toward a flat diamond in the middle and never go negative.
static func _hill(x: int, z: int, width: int, height: int, peak: float, falloff: float) -> int:
	var d0 := x + z                                 # distance to (0, 0)
	var d1 := (width - 1 - x) + z                   # distance to (width-1, 0)
	var d2 := x + (height - 1 - z)                  # distance to (0, height-1)
	var d3 := (width - 1 - x) + (height - 1 - z)    # distance to (width-1, height-1)
	var nearest := mini(mini(d0, d1), mini(d2, d3))
	return int(round(max(0.0, peak - nearest * falloff)))


## The X grid index of the river's center as it crosses row `z`. The river runs diagonally across
## the map (upper-left toward lower-right) with a gentle meander so it doesn't read as a straight
## line — cutting through two of the corner hills on its way. Returns a float; tiles near it count
## as river (see `_is_river`). Tuned for a 12-wide map.
static func _river_center_x(z: int) -> float:
	return 2.0 + 0.6 * z + 1.2 * sin(z * 0.5)


## Whether grid index (x, z) lies within the river's channel for this map.
static func _is_river(x: int, z: int) -> bool:
	return abs(x - _river_center_x(z)) <= RIVER_HALF_WIDTH


# --- State builders ----------------------------------------------------------

## State 0 — grassland with a hill in every corner. All grass; height is the flat ground plus the
## four-corner hill contribution.
static func _state_grassland(width: int, height: int) -> Array:
	var state: Array = []
	for x in width:
		var column: Array = []
		for z in height:
			var h := GROUND_HEIGHT + _hill(x, z, width, height, HILL_PEAK, HILL_FALLOFF)
			column.append({"height": h, "type": TileTypes.Type.GRASS})
		state.append(column)
	return state


## State 1 — the river has cut a canyon diagonally across the grassland. The land still has the
## four corner hills, but every river-channel tile is sunk to the canyon floor and turned to water.
## Where the channel passes through a tall corner hill, the surrounding land towers over the floor,
## giving brown canyon walls for free.
static func _state_canyon(width: int, height: int) -> Array:
	var state: Array = []
	for x in width:
		var column: Array = []
		for z in height:
			if _is_river(x, z):
				column.append({"height": CANYON_FLOOR, "type": TileTypes.Type.WATER, "body": TileTypes.Type.DIRT})
			else:
				var h := GROUND_HEIGHT + _hill(x, z, width, height, HILL_PEAK, HILL_FALLOFF)
				column.append({"height": h, "type": TileTypes.Type.GRASS, "body": TileTypes.Type.DIRT})
		state.append(column)
	return state


## State 2 — the desert end state. Everything is sand, the corner hills are much lower and more
## spread out, and the former river is a dry STONE riverbed sunk one level below the surrounding sand.
static func _state_desert(width: int, height: int) -> Array:
	var state: Array = []
	for x in width:
		var column: Array = []
		for z in height:
			var ground := GROUND_HEIGHT + _hill(x, z, width, height, DESERT_HILL_PEAK, DESERT_HILL_FALLOFF)
			if _is_river(x, z):
				# Dry riverbed: stone, carved a little below the surrounding sand.
				var bed: int = max(GROUND_HEIGHT, ground - 1)
				column.append({"height": bed, "type": TileTypes.Type.STONE, "body": TileTypes.Type.DIRT})
			else:
				column.append({"height": ground, "type": TileTypes.Type.SAND, "body": TileTypes.Type.SAND})
		state.append(column)
	return state
