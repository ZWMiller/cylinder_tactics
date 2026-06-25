## Shared vocabulary for terrain tiles: the set of terrain types and the per-type
## properties used to draw them and (soon) to drive gameplay.
##
## This script declares `class_name TileTypes`, which registers it as a global
## name across the whole project — any other script can write `TileTypes.Type`
## or `TileTypes.surface_color(...)` without `preload`ing this file. It is never
## instantiated; it is used purely as a namespace for an enum and `static`
## helpers (similar to a C++ namespace of free functions, or a Python module of
## module-level constants/functions).
##
## Two-layer tiles: a tile carries a SURFACE type (the cap you stand on — drives
## color AND gameplay: move cost, liquid, casting, hazard) and a BODY type (the
## column/side color only — cosmetic). That split is what lets one tile be a stucco
## building with a slate roof on top: body = BUILDING, surface = ROOF. Natural
## terrain uses body = DIRT, so its exposed sides read as the brown earth cliffs.
##
## GDScript note for Python/C++ folks: `extends RefCounted` just gives us a
## concrete base; because everything here is `static` we never call `.new()`.
class_name TileTypes
extends RefCounted

## The kinds of terrain a tile can be. A tile's *type* is gameplay data, not just
## a paint color: liquids impede movement, block casting, and (lava) will deal
## hazard damage (see the property table below and docs/GAME_DESIGN.md §7).
##
## GDScript enums are integer-backed (like C++), so we store `Type.GRASS` as an
## int inside each tile dictionary / packed map array. New types are appended at the
## END so existing saved maps (which store the backing int) keep meaning the same
## tile — do not reorder the originals.
enum Type {
	GRASS,           ## Walkable grassland — the default surface.
	WATER,           ## River / lake water. Liquid: sink-in, no casting, 2 move to enter.
	SAND,            ## Desert sand.
	STONE,           ## Bare rock, e.g. a dried-out riverbed.
	ROAD,            ## Paved path.
	# --- appended (two-layer + new terrain) -------------------------------------
	DIRT,            ## Bare earth — the DEFAULT body/side color (brown). Also a valid surface.
	LAVA,            ## Molten rock. Liquid (sink-in, no cast, 2 move) + hazard damage.
	BUILDING,        ## Stucco building surface (beige).
	BUILDING_STONE,  ## Dressed-stone building surface (light grey).
	ROOF,            ## Dark slate shingle roof.
	QUICKSAND,       ## Liquid sand: sink-in, no cast, 2 move to enter.
}

## The brown "earth" color. Kept as a named constant because it is the canonical
## dirt color (the `DIRT` type uses it) and the renderer references it directly for
## the default body material. Drawing tile columns in this brown makes height
## differences read as dirt cliffs without textures (see docs/GAME_DESIGN.md §7).
const EARTH := Color(0.40, 0.28, 0.18)

## Movement cost (move points) to enter a tile whose type doesn't override it — the
## value all non-liquid terrain uses today.
const DEFAULT_MOVE_COST := 1

## The default BODY (side) type for a tile when none is specified: bare earth, so a
## tile's exposed sides read as brown dirt cliffs unless authored as a built block.
const DEFAULT_BODY := Type.DIRT

## The single source of truth for what each terrain type *is*. One row per `Type`,
## each a Dictionary of properties:
##   - `color`     (Color) — flat color drawn on the tile (cap if surface, sides if body).
##   - `move_cost` (int)   — move points to ENTER this tile as a surface (default 1; liquids 2).
##   - `liquid`    (bool)  — a "sink into" tile: the unit stands recessed in it, can't cast
##                           while on it, and it costs extra to enter (the liquid tag).
##   - `can_cast`  (bool)  — may a unit cast a spell while standing here (false on liquids).
##   - `hazard`    (int)   — damage taken for standing on this tile. RESERVED: the field is
##                           authored now (lava) but not yet read; the terrain-gameplay step
##                           wires it. Tune values in the balance pass.
##
## Centralizing everything here means the map generator, the designer, the renderer,
## and the movement/casting rules can never disagree about what "water" is. The
## accessor `static` functions below read from this table with safe fallbacks, so a
## type accidentally missing a row degrades loudly (magenta) rather than crashing.
const _TERRAIN := {
	Type.GRASS:          {"color": Color(0.30, 0.55, 0.32), "move_cost": 1, "liquid": false, "can_cast": true,  "hazard": 0},
	Type.WATER:          {"color": Color(0.20, 0.42, 0.80), "move_cost": 2, "liquid": true,  "can_cast": false, "hazard": 0},
	Type.SAND:           {"color": Color(0.85, 0.78, 0.50), "move_cost": 1, "liquid": false, "can_cast": true,  "hazard": 0},
	Type.STONE:          {"color": Color(0.50, 0.50, 0.53), "move_cost": 1, "liquid": false, "can_cast": true,  "hazard": 0},
	Type.ROAD:           {"color": Color(0.38, 0.38, 0.40), "move_cost": 1, "liquid": false, "can_cast": true,  "hazard": 0},
	Type.DIRT:           {"color": EARTH,                    "move_cost": 1, "liquid": false, "can_cast": true,  "hazard": 0},
	# Lava's hazard is a PLACEHOLDER (not yet read) — tune in the combat balance pass.
	Type.LAVA:           {"color": Color(0.90, 0.30, 0.10), "move_cost": 2, "liquid": true,  "can_cast": false, "hazard": 2},
	Type.BUILDING:       {"color": Color(0.84, 0.76, 0.62), "move_cost": 1, "liquid": false, "can_cast": true,  "hazard": 0},
	Type.BUILDING_STONE: {"color": Color(0.66, 0.64, 0.62), "move_cost": 1, "liquid": false, "can_cast": true,  "hazard": 0},
	Type.ROOF:           {"color": Color(0.18, 0.19, 0.22), "move_cost": 1, "liquid": false, "can_cast": true,  "hazard": 0},
	Type.QUICKSAND:      {"color": Color(0.66, 0.58, 0.36), "move_cost": 2, "liquid": true,  "can_cast": false, "hazard": 0},
}


## Return the flat surface color for a given terrain `type`. Returns magenta as a
## loud "unmapped type" signal rather than failing silently.
static func surface_color(type: int) -> Color:
	if _TERRAIN.has(type):
		return _TERRAIN[type]["color"]
	# Unmapped type: return an obvious debug color instead of crashing.
	return Color.MAGENTA


## Whether `type` is a *liquid* — a tile a unit sinks into (recessed placement), can't
## cast a spell from, and pays extra move to enter. The single tag the sink-in rendering
## and the casting/movement rules all branch on. Unmapped types are treated as solid.
static func is_liquid(type: int) -> bool:
	return _TERRAIN.has(type) and _TERRAIN[type]["liquid"]


## Move points needed to ENTER a tile of `type` (the per-tile step cost, not a flat 1).
## Falls back to `DEFAULT_MOVE_COST` for any unmapped type.
static func move_cost(type: int) -> int:
	if _TERRAIN.has(type):
		return _TERRAIN[type]["move_cost"]
	return DEFAULT_MOVE_COST


## Whether a unit may cast a spell while standing on a tile of `type`. False on liquids.
## Unmapped types default to castable (the permissive, non-blocking choice).
static func can_cast(type: int) -> bool:
	if _TERRAIN.has(type):
		return _TERRAIN[type]["can_cast"]
	return true


## Damage a unit takes for standing on a tile of `type` (e.g. lava). RESERVED: authored
## now but not yet read by combat — wired in the terrain-gameplay step. 0 for safe tiles.
static func hazard_damage(type: int) -> int:
	if _TERRAIN.has(type):
		return _TERRAIN[type]["hazard"]
	return 0
