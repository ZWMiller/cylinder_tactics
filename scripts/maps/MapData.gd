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

## How a map's column UNDERSIDES are determined — the "depth mode", chosen at New and saved here.
##   AUTO     — the underside FOLLOWS the terrain: `Battlefield` derives each column's bottom from
##              its neighbours (drop to the lowest adjacent surface, else a thin slab). The classic
##              solid-ground look, where the top is the only authored surface. Default, and how
##              every legacy map (no stored mode → 0 → AUTO) loads.
##   SCULPTED — the underside is authored INDEPENDENTLY of the top (`MapState.floors`): each column
##              is drawn exactly `[floor, height]`, so thick slabs, floating tiles, and deliberate
##              gaps are all possible. Editing the top leaves the bottom alone and vice-versa.
## Authoring/visual only for now — gameplay still walks on tops (walkable undersides are the
## separate Phase 5 work; see docs/TODO.md).
enum DepthMode { AUTO, SCULPTED }

## This map's depth mode (see `DepthMode`), stored as the enum's backing int. Absent/0 on a legacy
## resource reads as AUTO, so old maps keep their derived undersides with no migration.
@export var depth_mode: int = DepthMode.AUTO

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
## `grid[x][z] = { "height": int, "type": int, "body": int, "bottom": int }`. Inverse of
## `from_states`. A `bodies` array missing entirely (a map saved before bodies existed)
## falls back to `TileTypes.DEFAULT_BODY` per tile; a missing `bottoms` array falls back
## to that tile's body — so older maps render with brown dirt sides and matching
## undersides exactly as before.
func to_states() -> Array:
	var result: Array = []
	for st in states:
		var has_bodies := st.bodies.size() == st.heights.size()
		var has_bottoms := st.bottoms.size() == st.heights.size()
		var has_floors := st.floors.size() == st.heights.size()
		var has_anchors := st.anchors.size() == st.heights.size()
		var grid: Array = []
		for x in width:
			var column: Array = []
			for z in height:
				# Row-major flat index — must match the packing in `from_states`.
				var idx := x * height + z
				var body: int = st.bodies[idx] if has_bodies else TileTypes.DEFAULT_BODY
				column.append({
					"height": st.heights[idx],
					"type": st.types[idx],
					"body": body,
					# Unauthored/legacy undersides inherit the side color (see MapState).
					"bottom": st.bottoms[idx] if has_bottoms else body,
					# Authored bottom LEVEL (Sculpted maps only). Absent on Auto/legacy maps, where
					# the renderer derives the bottom from neighbours and ignores this; a default of
					# one level below the top keeps a column 1-thick if it's ever read by mistake.
					"floor": st.floors[idx] if has_floors else st.heights[idx] - 1,
					# Fixed seam anchor (Sculpted editing constraint). Absent → the tile's own top, so
					# a loaded map re-anchors at its current height. See MapState.anchors.
					"anchor": st.anchors[idx] if has_anchors else st.heights[idx],
				})
			grid.append(column)
		result.append(grid)
	return result


## Build a `MapData` from the runtime nested form (`Array` of `grid[x][z]` dictionaries),
## flattening each state into a `MapState`. This is how procedurally-generated maps
## (`DemoMap`) and the designer's in-memory grid become a saveable resource. Dimensions
## are read from the first state; all states are assumed to share them.
static func from_states(p_states: Array, p_name: String = "Untitled", p_depth_mode: int = DepthMode.AUTO) -> MapData:
	var data := MapData.new()
	data.map_name = p_name
	data.depth_mode = p_depth_mode
	if p_states.is_empty():
		return data   # an empty map — width/height stay 0
	data.width = p_states[0].size()
	data.height = (p_states[0][0] as Array).size()
	# Only Sculpted maps carry authored floors; an Auto map leaves the `floors` array empty so its
	# `.tres` stays as compact as before and the renderer derives the underside on load.
	var sculpted := p_depth_mode == DepthMode.SCULPTED
	for grid in p_states:
		var st := MapState.new()
		# Pre-size the flat arrays so we can assign by index instead of appending.
		st.heights.resize(data.width * data.height)
		st.types.resize(data.width * data.height)
		st.bodies.resize(data.width * data.height)
		st.bottoms.resize(data.width * data.height)
		if sculpted:
			st.floors.resize(data.width * data.height)
			st.anchors.resize(data.width * data.height)
		for x in data.width:
			for z in data.height:
				var idx := x * data.height + z
				var tile: Dictionary = grid[x][z]
				st.heights[idx] = tile["height"]
				st.types[idx] = tile["type"]
				# Tolerate tiles without an explicit body (older procedural output).
				var body: int = tile.get("body", TileTypes.DEFAULT_BODY)
				st.bodies[idx] = body
				# An unauthored underside is saved inheriting the side color.
				st.bottoms[idx] = tile.get("bottom", body)
				if sculpted:
					# Default a missing floor to one level below the top (a 1-thick slab).
					st.floors[idx] = tile.get("floor", tile["height"] - 1)
					# Default a missing seam anchor to the tile's top (its starting height).
					st.anchors[idx] = tile.get("anchor", tile["height"])
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
