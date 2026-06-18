## The battlefield: a grid of terrain tiles that can shift between several
## "time-states" as time degrades (see docs/GAME_DESIGN.md §4).
##
## This node is deliberately *generic and size-agnostic* — it knows how to render
## and cycle a list of states, but not what any particular map looks like. The
## actual map data is supplied as `states` (a configuration); if none is provided
## it falls back to `DemoMap` so the scene shows something on F5.
##
## Data model (matches the design doc):
##   - A *tile* is a Dictionary `{ "height": int, "type": int }`, where `type` is a
##     `TileTypes.Type`. We use a plain Dictionary rather than a custom class to
##     keep the prototype simple; we may promote it to a Resource later.
##   - A *state* is a 2D grid of tiles indexed `state[x][z]`.
##   - `states` is the ordered list of states; advancing the shift cycles through
##     them and wraps around (… -> last -> 0 -> …).
##
## Rendering (geometry only, no textures — see docs/GAME_DESIGN.md §7):
##   Each tile is drawn as a brown "earth" column with a thin colored cap on top.
##   Where a tile stands taller than its neighbor, the brown column shows as a
##   dirt cliff; flush neighbors hide their shared sides, so only the colored caps
##   read from above.
class_name Battlefield
extends Node3D

# --- Configuration (editable in the Inspector; this is what @export means) ----

## Number of tiles along the X axis. There is intentionally no upper limit.
@export var grid_width: int = 24

## Number of tiles along the Z axis.
@export var grid_height: int = 24

## World-space width/depth of a single tile. Tiles are placed flush (no gap).
@export var tile_size: float = 1.0

## World-space height of one unit of tile "height". A tile of height H rises
## `H * height_step` above the floor. Kept small so tall hills stay on-screen.
@export var height_step: float = 0.5

## Thickness of the colored surface cap that sits on top of the brown column.
## Thin, so most of a cliff face reads as brown earth.
@export var cap_thickness: float = 0.12

# --- Runtime state -----------------------------------------------------------

## The ordered list of time-states. Leave empty to use the built-in DemoMap, or
## assign your own configuration before this node enters the tree.
var states: Array = []

## Index into `states` of the state currently being displayed.
var _current_index: int = 0

## A single 1x1x1 box mesh shared by every tile instance. We never resize the
## mesh itself — each tile's MeshInstance3D is *scaled* to the size it needs.
## Sharing one mesh across hundreds of tiles is the idiomatic, cheap approach.
var _unit_box: BoxMesh

## The brown material used for every tile's earth column (shared).
var _earth_material: StandardMaterial3D

## Cache of surface materials, one per terrain type, built on demand.
var _surface_materials: Dictionary = {}

## Per-tile node references, indexed `_tiles[x][z]`. Each entry is a Dictionary
## `{ "earth": MeshInstance3D, "surface": MeshInstance3D }`. We build these once
## and then just rescale/recolor them on every shift, rather than rebuilding.
var _tiles: Array = []


## Godot lifecycle hook: runs once when the node enters the scene tree. We set up
## shared resources, fall back to the demo map if no config was supplied, build
## the tile geometry, and render the first state.
func _ready() -> void:
	# Shared 1x1x1 box; individual tiles scale this to their footprint/height.
	_unit_box = BoxMesh.new()
	_unit_box.size = Vector3.ONE

	# One brown material reused by every earth column.
	_earth_material = StandardMaterial3D.new()
	_earth_material.albedo_color = TileTypes.EARTH

	# If nobody supplied a map configuration, use the built-in demo.
	if states.is_empty():
		states = DemoMap.generate(grid_width, grid_height)

	_build_tiles()
	render_state(_current_index)


## Godot input hook for events nothing else consumed. Pressing the "accept"
## action (Space / Enter by default) advances the time-shift, so you can watch
## the map cycle through its states. This is placeholder driving for the
## prototype; the real shift will be tied to the turn counter later.
func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_accept"):
		advance_shift()


# --- Public shift API (see docs/GAME_DESIGN.md §4 / DECISION_LOG) -------------
# Kept deliberately small and public so the preview feature and the time-mage's
# powers can later peek at / nudge the shift without reaching into internals.

## Return the state currently displayed.
func current_state() -> Array:
	return states[_current_index]


## Return the index that the *next* shift will move to (wraps around).
func next_state_index() -> int:
	return (_current_index + 1) % states.size()


## Return the state the map will look like after the next shift, without applying
## it. This is what the hold-to-preview "what-if" view will read from.
func peek_next_state() -> Array:
	return states[next_state_index()]


## Advance the time-shift by one step: move to the next state (wrapping) and
## redraw. Later this will also re-settle units and apply fall damage; for now it
## only changes the terrain.
func advance_shift() -> void:
	_current_index = next_state_index()
	render_state(_current_index)
	print("Battlefield: shifted to time-state %d / %d" % [_current_index + 1, states.size()])


# --- Grid <-> world helpers (seed of the future coordinate-helper module) -----

## World height of the *top surface* of tile (x, z) in the current state. Units
## stand at this Y. This is intentionally derived from tile data, not stored, so
## it stays correct across shifts.
func tile_height(x: int, z: int) -> float:
	return current_state()[x][z]["height"] * height_step


## World position of the center of the top surface of tile (x, z) in the current
## state — i.e. where a unit standing on that tile sits. Movement, line of sight,
## and combat will build on this.
func tile_to_world(x: int, z: int) -> Vector3:
	return Vector3(_grid_to_world_x(x), tile_height(x, z), _grid_to_world_z(z))


# --- Internal helpers --------------------------------------------------------

## X world coordinate of the center of grid column `x`. The grid is centered on
## the origin so the scene's camera (which looks at (0,0,0)) frames it.
func _grid_to_world_x(x: int) -> float:
	return x * tile_size - (grid_width - 1) * tile_size * 0.5


## Z world coordinate of the center of grid row `z`. (Mirror of the X helper.)
func _grid_to_world_z(z: int) -> float:
	return z * tile_size - (grid_height - 1) * tile_size * 0.5


## Return the (cached) surface material for a terrain `type`, creating it the
## first time it is requested.
func _surface_material(type: int) -> StandardMaterial3D:
	if not _surface_materials.has(type):
		var mat := StandardMaterial3D.new()
		mat.albedo_color = TileTypes.surface_color(type)
		_surface_materials[type] = mat
	return _surface_materials[type]


## Create the per-tile geometry once: for every grid cell, a small root node
## holding an "earth" column mesh and a "surface" cap mesh. Sizes/colors are left
## to `render_state`, which runs immediately after and on every shift.
func _build_tiles() -> void:
	_tiles = []
	for x in grid_width:
		var column: Array = []
		for z in grid_height:
			# A root node positioned at the tile's X/Z; its children only move in Y.
			var root := Node3D.new()
			root.name = "Tile_%d_%d" % [x, z]
			root.position = Vector3(_grid_to_world_x(x), 0.0, _grid_to_world_z(z))
			add_child(root)

			# The brown dirt column (sides + underground).
			var earth := MeshInstance3D.new()
			earth.mesh = _unit_box
			earth.material_override = _earth_material
			root.add_child(earth)

			# The thin colored surface cap on top.
			var surface := MeshInstance3D.new()
			surface.mesh = _unit_box
			root.add_child(surface)

			column.append({"earth": earth, "surface": surface})
		_tiles.append(column)


## Draw the state at `index`: rescale and recolor every tile's column + cap to
## match that state's height and type. Because we reuse the tile nodes, a shift
## is just a bulk update of transforms and material overrides.
func render_state(index: int) -> void:
	var state: Array = states[index]
	for x in grid_width:
		for z in grid_height:
			var tile: Dictionary = state[x][z]
			var surface_top: float = tile["height"] * height_step

			# Split the total height into a brown column and a thin colored cap.
			# Clamp so a very short tile still shows a sliver of column.
			var cap_h: float = min(cap_thickness, surface_top * 0.5)
			var column_h: float = max(surface_top - cap_h, 0.02)

			var refs: Dictionary = _tiles[x][z]

			# A scaled 1x1x1 box: scale.y is the height, scale.x/z the footprint.
			# Position is the box *center*, so half the height sits above y=0.
			var earth: MeshInstance3D = refs["earth"]
			earth.scale = Vector3(tile_size, column_h, tile_size)
			earth.position = Vector3(0.0, column_h * 0.5, 0.0)

			var surface: MeshInstance3D = refs["surface"]
			surface.scale = Vector3(tile_size, cap_h, tile_size)
			surface.position = Vector3(0.0, column_h + cap_h * 0.5, 0.0)
			surface.material_override = _surface_material(tile["type"])
