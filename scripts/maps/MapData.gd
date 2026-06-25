## A saved map: a name, its grid dimensions, and the ordered list of time-states the
## map shifts through (see docs/GAME_DESIGN.md §4 — "maps are a *sequence* of states").
## This is the on-disk format the map designer writes and `Battlefield` loads, the
## persistent twin of the procedural `DemoMap` generator.
##
## A map carries its OWN `width`/`height`, which is what makes maps **variable-size**:
## `Battlefield` adopts these dimensions from the loaded data instead of a fixed export,
## so every map can be a different size (see `Battlefield._adopt_dimensions_from_states`).
##
## Two representations, bridged here:
##   - On disk / in this resource: each state is a `MapState` sub-resource holding two
##     flat `PackedInt32Array`s (compact, diff-able `.tres`). See `MapState` for why.
##   - At runtime: `Battlefield` wants the nested `state[x][z] = { "height", "type" }`
##     form. `to_states()` rebuilds it; `from_states()` goes the other way (the designer
##     and any code that builds a map procedurally save through it).
##
## Layout convention (must match `MapState`): flat index `i = x * height + z`, i.e.
## row-major in X — the X column is the outer loop, Z the inner, mirroring the nested
## `state[x][z]` ordering so the two never disagree about which cell an index names.
class_name MapData
extends Resource

## Human-readable map name (shown in the designer's load list / debug prints). Not the
## filename — a map saved as `arena.tres` can still be named "The Arena".
@export var map_name: String = "Untitled"

## Grid dimensions in tiles. Authoritative: `Battlefield` sizes itself to these. Kept as
## stored fields (rather than re-derived) so a freshly-loaded resource knows its size
## before any unpacking, and so the Inspector shows it.
@export var width: int = 0
@export var height: int = 0

## The ordered time-states the shift cycles through (`… → last → 0 → …`). A one-element
## list is a static map; the demo map has three (grassland → canyon → desert).
@export var states: Array[MapState] = []


## Rebuild the runtime nested form `Battlefield` consumes: an Array (one per state) of
## `grid[x][z] = { "height": int, "type": int, "body": int }`. Inverse of `from_states`.
## A `bodies` array missing entirely (a map saved before bodies existed) falls back to
## `TileTypes.DEFAULT_BODY` per tile, so older maps render with brown dirt sides as before.
func to_states() -> Array:
	var result: Array = []
	for st in states:
		var has_bodies := st.bodies.size() == st.heights.size()
		var grid: Array = []
		for x in width:
			var column: Array = []
			for z in height:
				# Row-major flat index — must match the packing in `from_states`.
				var idx := x * height + z
				column.append({
					"height": st.heights[idx],
					"type": st.types[idx],
					"body": st.bodies[idx] if has_bodies else TileTypes.DEFAULT_BODY,
				})
			grid.append(column)
		result.append(grid)
	return result


## Build a `MapData` from the runtime nested form (`Array` of `grid[x][z]` dictionaries),
## flattening each state into a `MapState`. This is how procedurally-generated maps
## (`DemoMap`) and the designer's in-memory grid become a saveable resource. Dimensions
## are read from the first state; all states are assumed to share them.
static func from_states(p_states: Array, p_name: String = "Untitled") -> MapData:
	var data := MapData.new()
	data.map_name = p_name
	if p_states.is_empty():
		return data   # an empty map — width/height stay 0
	data.width = p_states[0].size()
	data.height = (p_states[0][0] as Array).size()
	for grid in p_states:
		var st := MapState.new()
		# Pre-size the flat arrays so we can assign by index instead of appending.
		st.heights.resize(data.width * data.height)
		st.types.resize(data.width * data.height)
		st.bodies.resize(data.width * data.height)
		for x in data.width:
			for z in data.height:
				var idx := x * data.height + z
				var tile: Dictionary = grid[x][z]
				st.heights[idx] = tile["height"]
				st.types[idx] = tile["type"]
				# Tolerate tiles without an explicit body (older procedural output).
				st.bodies[idx] = tile.get("body", TileTypes.DEFAULT_BODY)
		data.states.append(st)
	return data


## Save this map to `path` (e.g. `res://assets/maps/arena.tres`). Returns an `Error`
## code (`OK` on success) so the designer can report failures. Thin wrapper over
## `ResourceSaver` kept here so every save goes through one place.
func save_to(path: String) -> Error:
	return ResourceSaver.save(self, path)


## Load a `MapData` from `path`, or `null` if the file is missing or isn't a MapData.
## The designer uses this for its "open existing map" path; null lets the caller fall
## back (e.g. start a blank map) instead of crashing on a bad path.
static func load_from(path: String) -> MapData:
	if not ResourceLoader.exists(path):
		return null
	return load(path) as MapData
