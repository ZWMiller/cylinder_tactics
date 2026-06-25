## A `Battlefield` that can be EDITED at runtime — the renderer behind the map
## designer. It exists so the designer shows tiles *identically* to how battles render
## them (same two-layer body/cap columns, height scaling, picking) without duplicating
## any of that code: it just inherits it.
##
## Why a subclass (deliberate — see docs/DECISION_LOG.md): the battle scenes use the
## base `Battlefield`, which has no business knowing how to repaint itself mid-game.
## All the editing surface lives here instead, so the base class stays exactly as the
## battle scenes rely on it. This class ONLY adds methods and ONLY calls existing base
## methods (`_build_tiles`, `render_state`, `_adopt_dimensions_from_states`) — it edits
## nothing in `Battlefield.gd`. A scene that never loads this script is unaffected.
##
## GDScript note (vs C++/Python): `extends Battlefield` is plain single inheritance.
## There's no access control — a subclass can read/call the base's `_`-prefixed members
## (`_tiles`, `_current_index`, `render_state`), which is exactly what lets this stay a
## thin additive layer. The `_` is a "treat as internal" convention, not enforcement.
class_name EditableBattlefield
extends Battlefield

## Designer-only grid overlay: a thin dark line around every tile's top edge, so tiles
## (and height steps) read clearly despite sharing a flat surface color. Rebuilt after
## every render because changing a tile's height moves its outline. Lives here, not in
## `Battlefield`, so battle scenes never get it.
var _grid_overlay: MeshInstance3D
var _grid_material: StandardMaterial3D

## Lift the outline a hair above the cap so it doesn't z-fight with the surface.
const _GRID_LIFT := 0.02


## Render like the base, then (re)draw the tile-edge grid on top. Virtual dispatch means
## every base call site (`_ready`, `set_tile`, `load_states`) refreshes the grid for free.
func render_state(index: int) -> void:
	super(index)
	_rebuild_grid_overlay()


## Replace the whole map with `new_states` (the nested `state[x][z] = {height,type,body}`
## form) and rebuild from scratch — used for New, Load, and any resize. Frees the old
## tile geometry first (recovering each tile's root node from its stored `earth` mesh's
## parent, so the base needs no extra bookkeeping), then runs the base build/render path.
## Resets the view to the first state.
func load_states(new_states: Array) -> void:
	# Immediately free the existing per-tile root nodes (and their children). `free()`
	# rather than `queue_free()` so the new tiles, which reuse the same "Tile_x_z" names,
	# don't transiently collide with the old ones still in the tree.
	for column in _tiles:
		for refs in column:
			var root: Node = refs["earth"].get_parent()
			if is_instance_valid(root):
				root.free()
	_tiles = []

	states = new_states
	_current_index = 0
	_adopt_dimensions_from_states()   # variable-size: the new data drives grid_width/height
	_build_tiles()
	render_state(_current_index)


## The tile data `{ "height", "type", "body" }` at (x, z) in the state currently shown.
## Returns a COPY so callers can read (e.g. to raise a height relative to the current
## one) without aliasing the stored dict. Empty dict if (x, z) is off the grid.
func tile_data(x: int, z: int) -> Dictionary:
	if not _in_bounds(x, z):
		return {}
	return (current_state()[x][z] as Dictionary).duplicate()


## Set the tile at (x, z) in the current state to the given height + surface/body types,
## then redraw. Redrawing the whole (small) designer state per edit is cheap; brush
## strokes that touch many tiles should use `set_tiles` to redraw only once.
func set_tile(x: int, z: int, height: int, surface_type: int, body_type: int) -> void:
	if not _write_tile(x, z, height, surface_type, body_type):
		return
	render_state(_current_index)


## Apply a batch of edits, then redraw ONCE. Each entry is a Dictionary
## `{ "x", "z", "height", "type", "body" }`. This is the efficient path the shape
## brushes (square/circle/line/hill) use — one repaint for the whole footprint.
func set_tiles(edits: Array) -> void:
	var any := false
	for e in edits:
		if _write_tile(e["x"], e["z"], e["height"], e["type"], e["body"]):
			any = true
	if any:
		render_state(_current_index)


## Re-render the current state (e.g. after external mutation). Thin pass-through so the
## designer doesn't reach for the base method name directly.
func redraw() -> void:
	render_state(_current_index)


# --- internal ---------------------------------------------------------------

## Write one tile's data into the current state WITHOUT redrawing. Returns whether the
## write landed (false if off-grid). Replaces the dict wholesale so the three keys are
## always present and consistent.
func _write_tile(x: int, z: int, height: int, surface_type: int, body_type: int) -> bool:
	if not _in_bounds(x, z):
		return false
	current_state()[x][z] = {"height": height, "type": surface_type, "body": body_type}
	return true


## Whether (x, z) is a valid tile index in the current grid.
func _in_bounds(x: int, z: int) -> bool:
	return x >= 0 and x < grid_width and z >= 0 and z < grid_height


## Rebuild the line mesh outlining every tile's top square at its current surface height.
## Cheap (a few hundred verts even at 24x24), built as a single PRIMITIVE_LINES ArrayMesh
## so the whole grid is one draw. The overlay node persists across map loads.
func _rebuild_grid_overlay() -> void:
	if _grid_material == null:
		_grid_material = StandardMaterial3D.new()
		_grid_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_grid_material.albedo_color = Color(0.08, 0.08, 0.08)
	if _grid_overlay == null:
		_grid_overlay = MeshInstance3D.new()
		_grid_overlay.name = "GridOverlay"
		_grid_overlay.material_override = _grid_material
		add_child(_grid_overlay)

	var verts := PackedVector3Array()
	var half := tile_size * 0.5
	for x in grid_width:
		for z in grid_height:
			var c := tile_to_world(x, z)   # center of the tile's top surface
			var y := c.y + _GRID_LIFT
			var x0 := c.x - half
			var x1 := c.x + half
			var z0 := c.z - half
			var z1 := c.z + half
			# Four edges of the top square, as line-segment vertex pairs.
			verts.append_array([Vector3(x0, y, z0), Vector3(x1, y, z0)])
			verts.append_array([Vector3(x1, y, z0), Vector3(x1, y, z1)])
			verts.append_array([Vector3(x1, y, z1), Vector3(x0, y, z1)])
			verts.append_array([Vector3(x0, y, z1), Vector3(x0, y, z0)])

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	_grid_overlay.mesh = mesh
