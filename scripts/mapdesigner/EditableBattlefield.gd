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

## Sentinel for `set_tile`/`_write_tile`'s `floor_level` meaning "keep the tile's current floor"
## (so an edit that only changes surface/body/bottom leaves an authored Sculpted underside alone).
## A sentinel rather than a magic number because every real floor level (including 0 and negatives)
## is valid; -2³¹ is safely outside any authored range.
const _KEEP_FLOOR := -2147483648

## Twin sentinel for the seam `anchor` (see MapState.anchors): "keep the tile's current anchor", so a
## normal edit (paint, top/floor move) never resets the fixed seam — only New / convert / resize do.
const _KEEP_ANCHOR := -2147483648

## Designer-only grid overlay: a thin dark line around every tile's top edge, so tiles
## (and height steps) read clearly despite sharing a flat surface color. Rebuilt after
## every render because changing a tile's height moves its outline. Lives here, not in
## `Battlefield`, so battle scenes never get it.
var _grid_overlay: MeshInstance3D
var _grid_material: StandardMaterial3D

## Lift the outline a hair above the cap so it doesn't z-fight with the surface.
const _GRID_LIFT := 0.02

## Push a cliff-face post a hair OUTWARD from the face (along its outward normal) so it
## floats just in front of the column instead of z-fighting on its exact corner. This keeps
## every post visible on faces the camera can see, while a post on a back-side face is still
## correctly hidden by the geometry in front of it (normal depth testing — no x-ray). Posts
## only exist where the neighbour is shorter, so "outward" is always open air, never behind
## another column.
const _GRID_FACE_OFFSET := 0.02

# --- Resize preview (designer RESIZE tool) ----------------------------------

## The four sides of the grid a RESIZE edit can grow or shrink. A non-corner edge
## tile touches exactly one side; a corner touches two, and we grow/shrink BOTH at
## once (so working a corner resizes the whole map quickly). See `sides_at`.
enum Side { X_MIN, X_MAX, Z_MIN, Z_MAX }

## Translucent GREEN ghost boxes laid one tile BEYOND a hovered edge — a preview of
## the row/column a left-click would ADD. Each mirrors the height of the edge tile it
## extends, so the preview reads as the terrain continuing outward. Grown-on-demand
## pool, leftovers hidden — same trick as the base overlays. Lazily built on first use.
var _ghost_pool: Array[MeshInstance3D] = []
var _ghost_mesh: BoxMesh
var _ghost_material: StandardMaterial3D

## Translucent RED decals laid OVER a hovered edge row/column — a preview of the tiles
## a right-click would DELETE. Same pooling / lazy build.
var _delete_pool: Array[MeshInstance3D] = []
var _delete_mesh: PlaneMesh
var _delete_material: StandardMaterial3D

## Lift the delete decal a hair above the cap (matches the active-marker lift).
const _DELETE_LIFT := 0.05

# --- Face-aware hover cursor ------------------------------------------------

## A single translucent quad laid over whichever tile FACE is under the cursor. The base
## `set_active_tile` only marks a tile's TOP, so it can't show what you're hovering on the
## underside or a side (now that the PAINT tool targets any face) — this can. One reusable
## node, re-oriented per face; lazily built on first hover.
var _hover_marker: MeshInstance3D
var _hover_material: StandardMaterial3D
var _hover_mesh: PlaneMesh

## Nudge the hover quad this far off the face (and inset from the edges) so it floats just
## in front of the surface instead of z-fighting it.
const _HOVER_LIFT := 0.03


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


## The tile data `{ "height", "type", "body", "bottom" }` at (x, z) in the state currently
## shown. Returns a COPY so callers can read (e.g. to raise a height relative to the
## current one) without aliasing the stored dict. Empty dict if (x, z) is off the grid.
func tile_data(x: int, z: int) -> Dictionary:
	if not _in_bounds(x, z):
		return {}
	return (current_state()[x][z] as Dictionary).duplicate()


## Set the tile at (x, z) in the current state to the given height + surface/body/bottom
## types, then redraw. `bottom_type < 0` means "inherit the body color" (the default for a
## tile whose underside isn't deliberately authored). Redrawing the whole (small) designer
## state per edit is cheap; brush strokes that touch many tiles should use `set_tiles`.
func set_tile(x: int, z: int, height: int, surface_type: int, body_type: int, bottom_type: int = -1, floor_level: int = _KEEP_FLOOR, anchor_level: int = _KEEP_ANCHOR) -> void:
	if not _write_tile(x, z, height, surface_type, body_type, bottom_type, floor_level, anchor_level):
		return
	render_state(_current_index)


## Apply a batch of edits, then redraw ONCE. Each entry is a Dictionary
## `{ "x", "z", "height", "type", "body" }` with an optional `"bottom"` (omitted →
## inherit the body color). This is the efficient path the shape brushes (square/circle/
## line/hill) use — one repaint for the whole footprint.
func set_tiles(edits: Array) -> void:
	var any := false
	for e in edits:
		if _write_tile(e["x"], e["z"], e["height"], e["type"], e["body"], e.get("bottom", -1), e.get("floor", _KEEP_FLOOR), e.get("anchor", _KEEP_ANCHOR)):
			any = true
	if any:
		render_state(_current_index)


## Re-render the current state (e.g. after external mutation). Thin pass-through so the
## designer doesn't reach for the base method name directly.
func redraw() -> void:
	render_state(_current_index)


## Seed the Sculpted layers from the current Auto map — the Auto→Sculpted conversion. Each tile's
## `floor` is baked to what Auto was drawing (the lowest-neighbour level, else the thin-slab minimum)
## so the undersides don't jump, and its seam `anchor` is set to its current top (the seam starts at
## the present surface, so from here the top can only rise and the floor only sink). Runs over EVERY
## state (a multi-state map stays consistent), editing the tile dicts in place — the caller flips the
## mode and redraws. Integer-level: the cosmetic liquid recess is sub-level and intentionally not baked.
func seed_sculpt_from_derived() -> void:
	for state in states:
		for x in grid_width:
			for z in grid_height:
				state[x][z]["floor"] = _derived_floor_level(state, x, z)
				state[x][z]["anchor"] = state[x][z]["height"]


## The integer floor LEVEL Auto mode would draw for tile (x, z) in `state`: the lowest orthogonal
## neighbour's top if any neighbour is lower (cover the cliff), else `top - min_body_depth` (the
## thin-slab minimum on flat ground / the border). The integer-level twin of `Battlefield`'s
## `_column_bottom_in` Auto branch, used only by `seed_sculpt_from_derived`.
func _derived_floor_level(state: Array, x: int, z: int) -> int:
	var top: int = state[x][z]["height"]
	var lowest: int = top
	for dir in _ORTHO_DIRS:
		var d: Vector2i = dir
		var nx: int = x + d.x
		var nz: int = z + d.y
		if nx >= 0 and nx < grid_width and nz >= 0 and nz < grid_height:
			lowest = mini(lowest, state[nx][nz]["height"])
	if lowest < top:
		return lowest
	return top - min_body_depth


# --- internal ---------------------------------------------------------------

## Write one tile's data into the current state WITHOUT redrawing. Returns whether the
## write landed (false if off-grid). Replaces the dict wholesale so all four keys are
## always present and consistent. `bottom_type < 0` inherits the body color, so callers
## that don't care about the underside (height/surface/body tools, brushes) leave it to
## match the sides — the default for an unauthored underside (see TileFaces.face_type).
func _write_tile(x: int, z: int, height: int, surface_type: int, body_type: int, bottom_type: int = -1, floor_level: int = _KEEP_FLOOR, anchor_level: int = _KEEP_ANCHOR) -> bool:
	if not _in_bounds(x, z):
		return false
	var bottom: int = bottom_type if bottom_type >= 0 else body_type
	# Preserve the existing floor when the caller passes the keep-sentinel — so a paint that only
	# touches surface/body/bottom never disturbs an authored (Sculpted) underside. A sentinel rather
	# than a magic 0 because floor 0 (ground level) is a legal authored value. Default a tile that
	# has no floor yet to one level below its top (a 1-thick slab).
	var floor_val: int = floor_level
	if floor_val == _KEEP_FLOOR:
		floor_val = current_state()[x][z].get("floor", height - 1)
	# Same keep-sentinel for the fixed seam anchor; default a brand-new tile's anchor to its top.
	var anchor_val: int = anchor_level
	if anchor_val == _KEEP_ANCHOR:
		anchor_val = current_state()[x][z].get("anchor", height)
	current_state()[x][z] = {"height": height, "type": surface_type, "body": body_type, "bottom": bottom, "floor": floor_val, "anchor": anchor_val}
	return true


## Whether (x, z) is a valid tile index in the current grid.
func _in_bounds(x: int, z: int) -> bool:
	return x >= 0 and x < grid_width and z >= 0 and z < grid_height


## Accumulate a cliff-face post at world corner (wx, wz) spanning Y [y0, y1], tagged with
## the face's outward normal `d`. Posts at the SAME corner and height span merge (their
## normals sum), so a vertical edge shared by two faces is drawn once and the nudge follows
## the combined normal — a convex corner nudges diagonally, a flush seam straight out. The
## key quantises corner + span to millimetres so the same physical edge keys identically
## regardless of which tile contributed it.
func _add_post(posts: Dictionary, wx: float, wz: float, y0: float, y1: float, d: Vector2i) -> void:
	var key := "%d:%d:%d:%d" % [roundi(wx * 1000.0), roundi(wz * 1000.0), roundi(y0 * 1000.0), roundi(y1 * 1000.0)]
	if posts.has(key):
		var p: Dictionary = posts[key]
		p["nx"] += d.x
		p["nz"] += d.y
	else:
		posts[key] = {"x": wx, "z": wz, "y0": y0, "y1": y1, "nx": d.x, "nz": d.y}


## Rebuild the line mesh outlining the WHOLE grid: every tile's top AND underside square,
## plus a vertical post down each exposed cliff corner (where a tile stands taller than the
## neighbour it abuts, or sits at the map border). So steps and cliffs read fully, not just
## the tops, and the underside reads as a grid when the camera orbits beneath the map.
## Cheap (a few hundred–thousand verts even at 24x24), built as one PRIMITIVE_LINES
## ArrayMesh so the whole grid is a single draw. The overlay node persists across loads.
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
	var state := current_state()
	# Cliff-face posts are accumulated per UNIQUE vertical edge (keyed by corner + height
	# span) rather than emitted per face. A convex block corner is traced by two faces whose
	# outward nudges point different ways; emitted separately they'd split into a visible
	# double line. Merging them and nudging along the SUMMED normal gives a convex corner one
	# diagonal post, while a flush seam (two coplanar faces) still nudges straight out.
	var posts := {}
	for x in grid_width:
		for z in grid_height:
			var c := tile_to_world(x, z)   # center of the tile's top surface
			var top := c.y                 # world Y of this tile's surface (= height*step)
			var y := top + _GRID_LIFT
			var x0 := c.x - half
			var x1 := c.x + half
			var z0 := c.z - half
			var z1 := c.z + half
			# Four edges of the top square, as line-segment vertex pairs.
			verts.append_array([Vector3(x0, y, z0), Vector3(x1, y, z0)])
			verts.append_array([Vector3(x1, y, z0), Vector3(x1, y, z1)])
			verts.append_array([Vector3(x1, y, z1), Vector3(x0, y, z1)])
			verts.append_array([Vector3(x0, y, z1), Vector3(x0, y, z0)])

			# The same four edges on the UNDERSIDE, at this tile's column bottom (which the
			# renderer computes from the lowest neighbour / the thin-slab minimum — so the
			# outline meets the drawn geometry), lifted a hair below it so the grid reads
			# when the camera orbits under the map.
			var bb := column_bottom(x, z)
			var yb := bb - _GRID_LIFT
			verts.append_array([Vector3(x0, yb, z0), Vector3(x1, yb, z0)])
			verts.append_array([Vector3(x1, yb, z0), Vector3(x1, yb, z1)])
			verts.append_array([Vector3(x1, yb, z1), Vector3(x0, yb, z1)])
			verts.append_array([Vector3(x0, yb, z1), Vector3(x0, yb, z0)])

			# For each side that DROPS to a shorter neighbour (or the map border), record a
			# post at the two corners of that edge spanning the exposed face up to this tile's
			# top, tagged with the face normal so coincident posts merge. The face bottoms out
			# at the neighbour's top; at the border (off-grid) it bottoms at THIS tile's column
			# bottom, matching the thin slab the renderer draws there (not down to y=0).
			for dir in _ORTHO_DIRS:
				var d: Vector2i = dir   # typed copy — `_ORTHO_DIRS` is untyped (Variant members)
				var nx: int = x + d.x
				var nz: int = z + d.y
				var neighbour_top := bb   # off-grid border: face is exposed only to the slab bottom
				if nx >= 0 and nx < grid_width and nz >= 0 and nz < grid_height:
					# Visible surface, not the integer rim, so the post bottom meets the mesh wall —
					# which now drops to a liquid neighbour's recessed waterline (see Battlefield
					# `_column_bottom_in`). For solid neighbours this is the same rim value.
					neighbour_top = _surface_world_y(state, nx, nz)
				if top - neighbour_top <= 0.001:
					continue   # flush with (or lower than) the neighbour — no exposed face
				# The exposed face only spans the part of THIS column that actually exists, so its
				# bottom is the higher of the neighbour's top and this column's own underside. In Auto
				# mode `bb` is always ≤ the neighbour (the column drops to cover the cliff), so this is
				# just `neighbour_top`; in Sculpted mode a FLOATING slab (floor above the neighbour)
				# correctly starts its outline at the slab's floor instead of drawing down through the
				# open gap below it.
				var face_bottom := maxf(neighbour_top, bb)
				# True (un-nudged) edge midpoint + its two corners along the edge, where
				# perp = (dir.y, dir.x) runs perpendicular to dir. The nudge is applied later,
				# after merging, so it can follow the summed normal.
				var mx := c.x + d.x * half
				var mz := c.z + d.y * half
				var px := d.y * half
				var pz := d.x * half
				_add_post(posts, mx + px, mz + pz, face_bottom, top, d)
				_add_post(posts, mx - px, mz - pz, face_bottom, top, d)

	# Emit one line per merged post, nudged outward along the summed face normal so it floats
	# just in front of the column(s) instead of z-fighting on the exact corner.
	for p in posts.values():
		var n := Vector2(p["nx"], p["nz"])
		if n.length() > 0.0001:
			n = n.normalized()
		var ox := n.x * _GRID_FACE_OFFSET
		var oz := n.y * _GRID_FACE_OFFSET
		var yb: float = p["y0"] + _GRID_LIFT   # meet the neighbour's top square
		var yt: float = p["y1"] + _GRID_LIFT
		verts.append_array([
			Vector3(p["x"] + ox, yb, p["z"] + oz),
			Vector3(p["x"] + ox, yt, p["z"] + oz)])

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	_grid_overlay.mesh = mesh


# --- Resize: grow / shrink the grid (designer RESIZE tool) -------------------

## Which grid sides tile (x, z) lies on (see `Side`). An interior tile returns `[]`;
## a non-corner edge tile returns one side; a corner returns the two it touches. The
## designer turns this into a grow/shrink that acts on every returned side at once, so
## hovering a corner extends or trims the map along both axes in one click. Off-grid
## (or out-of-bounds) tiles return `[]`.
func sides_at(x: int, z: int) -> Array:
	var sides: Array = []
	if not _in_bounds(x, z):
		return sides
	if x == 0:
		sides.append(Side.X_MIN)
	if x == grid_width - 1:
		sides.append(Side.X_MAX)
	if z == 0:
		sides.append(Side.Z_MIN)
	if z == grid_height - 1:
		sides.append(Side.Z_MAX)
	return sides


## Grow the map by one tile on each given side, mirroring the adjacent row/column so
## the new tiles continue the existing terrain. Rebuilds the grid.
func grow_sides(sides: Array) -> void:
	_resize(
		1 if sides.has(Side.X_MIN) else 0,
		1 if sides.has(Side.X_MAX) else 0,
		1 if sides.has(Side.Z_MIN) else 0,
		1 if sides.has(Side.Z_MAX) else 0)


## Shrink the map by removing the edge row/column on each given side. Returns false
## and changes nothing if that would drop either dimension below 1 tile (so a corner
## shrink on a 1-wide or 1-tall map is simply refused).
func shrink_sides(sides: Array) -> bool:
	return _resize(
		-1 if sides.has(Side.X_MIN) else 0,
		-1 if sides.has(Side.X_MAX) else 0,
		-1 if sides.has(Side.Z_MIN) else 0,
		-1 if sides.has(Side.Z_MAX) else 0)


## Rebuild EVERY state with the given per-side deltas: +1 adds a row/column on that
## side, -1 removes the edge one, 0 leaves it. Added tiles copy the nearest surviving
## tile (clamping the index onto the surviving range mirrors the edge into the new
## row/column — and the corner tile into a corner grow); removed tiles are dropped.
## Returns false without touching anything if either new dimension would be < 1.
## Operates on all states so a multi-state map stays one consistent rectangular size.
func _resize(dx_min: int, dx_max: int, dz_min: int, dz_max: int) -> bool:
	var new_w := grid_width + dx_min + dx_max
	var new_h := grid_height + dz_min + dz_max
	if new_w < 1 or new_h < 1:
		return false
	# A positive delta pads (adds) that side; a negative one crops (removes) it.
	var left_pad := maxi(dx_min, 0)
	var top_pad := maxi(dz_min, 0)
	# Surviving old-index range after cropping. Clamping the mapped index onto this
	# range is what mirrors the nearest edge tile into any padded row/column.
	var x_lo := maxi(-dx_min, 0)                    # crop from the x==0 side
	var x_hi := grid_width - 1 - maxi(-dx_max, 0)   # crop from the x==max side
	var z_lo := maxi(-dz_min, 0)
	var z_hi := grid_height - 1 - maxi(-dz_max, 0)
	var new_states: Array = []
	for state in states:
		var grid: Array = []
		for nx in new_w:
			var ox := clampi(x_lo + (nx - left_pad), x_lo, x_hi)
			var col: Array = []
			for nz in new_h:
				var oz := clampi(z_lo + (nz - top_pad), z_lo, z_hi)
				col.append((state[ox][oz] as Dictionary).duplicate())
			grid.append(col)
		new_states.append(grid)
	load_states(new_states)
	return true


# --- Resize preview overlays (the hover ghosts the RESIZE tool shows) --------

## Show both resize previews for the hovered `sides`: the GREEN ghost row/column a
## left-click would ADD (beyond the edge) and the RED overlay a right-click would
## DELETE (on the edge). Showing both at once is what lets the single RESIZE tool skip
## a separate add/delete mode — the colors and positions say which click does what.
func show_resize_preview(sides: Array) -> void:
	_show_add_ghost(sides)
	_show_delete_overlay(sides)


## Hide both resize previews.
func clear_resize_preview() -> void:
	for g in _ghost_pool:
		g.visible = false
	for d in _delete_pool:
		d.visible = false


## Highlight the given `face` of tile (x, z) with a translucent `color` quad — the designer
## hover cursor, face-aware so you can see what you're pointing at on the top, the underside,
## or a side. The quad is oriented onto that face (TOP/BOTTOM flat; the four sides vertical,
## spanning the full column height) and nudged out by `_HOVER_LIFT`. Off-grid hides it.
func set_hover_face(tile: Vector2i, face: int, color: Color) -> void:
	if not _in_bounds(tile.x, tile.y):
		clear_hover_face()
		return
	if _hover_marker == null:
		_hover_mesh = PlaneMesh.new()
		_hover_mesh.size = Vector2.ONE   # unit quad; scaled per use
		_hover_material = StandardMaterial3D.new()
		_hover_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_hover_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		# Double-sided so the quad shows whether the camera is above, below, or beside it.
		_hover_material.cull_mode = BaseMaterial3D.CULL_DISABLED
		_hover_marker = MeshInstance3D.new()
		_hover_marker.name = "HoverFace"
		_hover_marker.mesh = _hover_mesh
		_hover_marker.material_override = _hover_material
		add_child(_hover_marker)
	_hover_material.albedo_color = color
	_orient_face_quad(_hover_marker, tile, face)


## Orient + size the unit quad `m` onto `face` of tile (`tile`), nudged `_HOVER_LIFT` off the
## surface and inset from the tile edges, then show it. Shared by the single-tile hover cursor
## (`set_hover_face`) and the multi-tile brush footprint (`show_footprint`), so both highlight any
## face — top, underside, or a side — identically. A PlaneMesh lies in its local XZ plane (normal
## +local Y); each branch rotates it onto the target face and scales it to that face's dimensions
## (the four sides span the full visible column height). `m`'s mesh must be a 1x1 unit quad.
func _orient_face_quad(m: MeshInstance3D, tile: Vector2i, face: int) -> void:
	var c := tile_to_world(tile.x, tile.y)   # center of the TOP surface
	var top := c.y                            # world Y of the surface
	var bb := column_bottom(tile.x, tile.y)   # world Y of the drawn column's underside
	var depth := maxf(top - bb, 0.02)         # visible side-face height
	var mid := (top + bb) * 0.5               # vertical center of the block
	var half := tile_size * 0.5
	var inset := tile_size * 0.96             # sit just inside the tile edges
	match face:
		TileFaces.Face.TOP:
			m.rotation = Vector3.ZERO
			m.scale = Vector3(inset, 1.0, inset)
			m.position = Vector3(c.x, top + _HOVER_LIFT, c.z)
		TileFaces.Face.BOTTOM:
			m.rotation = Vector3.ZERO
			m.scale = Vector3(inset, 1.0, inset)
			m.position = Vector3(c.x, bb - _HOVER_LIFT, c.z)
		TileFaces.Face.EAST, TileFaces.Face.WEST:
			# Rotate 90° about Z: local X→world Y (face height), local Z→world Z (depth).
			m.rotation = Vector3(0.0, 0.0, PI / 2.0)
			m.scale = Vector3(depth, 1.0, inset)
			var sx: float = (half + _HOVER_LIFT) if face == TileFaces.Face.EAST else (-half - _HOVER_LIFT)
			m.position = Vector3(c.x + sx, mid, c.z)
		_:   # NORTH (−Z) / SOUTH (+Z)
			# Rotate 90° about X: local X→world X (width), local Z→world Y (face height).
			m.rotation = Vector3(PI / 2.0, 0.0, 0.0)
			m.scale = Vector3(inset, 1.0, depth)
			var sz: float = (-half - _HOVER_LIFT) if face == TileFaces.Face.NORTH else (half + _HOVER_LIFT)
			m.position = Vector3(c.x, mid, c.z + sz)
	m.visible = true


## Hide the face hover cursor.
func clear_hover_face() -> void:
	if _hover_marker != null:
		_hover_marker.visible = false


# --- Brush footprint preview (designer Phase 2 brushes) ---------------------

## Translucent top-face quads, one per tile, laid over a brush's footprint so the user
## can SEE which tiles a Square/Circle/Line/Hill brush will touch before committing — the
## multi-tile cousin of the single-tile `set_hover_face` cursor. Same grown-on-demand pool /
## hide-leftovers pattern as the resize overlays; lazily built on first use.
var _footprint_pool: Array[MeshInstance3D] = []
var _footprint_mesh: PlaneMesh
var _footprint_material: StandardMaterial3D


## Highlight every tile in `tiles` (grid coords) with a translucent `color` quad on the given
## `face` — the brush footprint preview, face-aware so a shape brush shows whether it will paint
## tile TOPS (surface), a SIDE (body), or the UNDERSIDE (bottom), matching where it will actually
## write. Off-grid coords are skipped. Reuses/grows a pool and hides any leftover quads from a
## larger previous footprint, so it never reallocates per frame. Each quad is the shared unit mesh,
## oriented onto the face by `_orient_face_quad` (the same placement the single-tile cursor uses).
func show_footprint(tiles: Array, face: int, color: Color) -> void:
	if _footprint_material == null:
		_footprint_mesh = PlaneMesh.new()
		_footprint_mesh.size = Vector2.ONE   # unit quad; oriented + scaled per face
		_footprint_material = StandardMaterial3D.new()
		_footprint_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_footprint_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		# Double-sided so side/underside quads read from any orbit angle (matches the hover cursor).
		_footprint_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_footprint_material.albedo_color = color
	var shown := 0
	for t in tiles:
		var tile: Vector2i = t
		if not _in_bounds(tile.x, tile.y):
			continue
		_orient_face_quad(_claim_footprint(shown), tile, face)
		shown += 1
	for i in range(shown, _footprint_pool.size()):
		_footprint_pool[i].visible = false


## Hide the whole footprint preview.
func clear_footprint() -> void:
	for q in _footprint_pool:
		q.visible = false


## Grow the footprint-quad pool until it has a quad at `i`, then return it.
func _claim_footprint(i: int) -> MeshInstance3D:
	while i >= _footprint_pool.size():
		var m := MeshInstance3D.new()
		m.mesh = _footprint_mesh
		m.material_override = _footprint_material
		m.visible = false
		add_child(m)
		_footprint_pool.append(m)
	return _footprint_pool[i]


## Lay green ghost boxes one tile beyond each added side (plus the diagonal corner box
## when two orthogonal sides are added), each scaled to the height of the edge tile it
## mirrors, so the preview looks like the terrain extended outward.
func _show_add_ghost(sides: Array) -> void:
	if _ghost_material == null:
		_ghost_mesh = BoxMesh.new()
		_ghost_mesh.size = Vector3.ONE
		_ghost_material = StandardMaterial3D.new()
		_ghost_material.albedo_color = Color(0.25, 1.0, 0.35, 0.45)
		_ghost_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_ghost_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var cells := _ghost_cells(sides)
	for i in cells.size():
		var cell: Dictionary = cells[i]
		var box := _claim_ghost(i)
		# Mirror the edge tile's DRAWN block (top down to its column bottom), so the ghost
		# previews a thin slab matching the new render model instead of a full-height cube.
		var src_top: float = current_state()[cell["sx"]][cell["sz"]]["height"] * height_step
		var src_bottom: float = column_bottom(cell["sx"], cell["sz"])
		var h: float = maxf(src_top - src_bottom, 0.05)   # keep a flat (height-0) edge previewable
		box.scale = Vector3(tile_size, h, tile_size)
		# `_grid_to_world_x/z` apply the centering formula to ANY int, including the
		# out-of-grid -1 / max indices, so the ghost sits exactly one tile past the edge.
		box.position = Vector3(_grid_to_world_x(cell["gx"]), src_bottom + h * 0.5, _grid_to_world_z(cell["gz"]))
		box.visible = true
	for i in range(cells.size(), _ghost_pool.size()):
		_ghost_pool[i].visible = false


## Lay red translucent decals over the edge row/column on each hovered side — the tiles
## a right-click would remove.
func _show_delete_overlay(sides: Array) -> void:
	if _delete_material == null:
		_delete_mesh = PlaneMesh.new()
		_delete_mesh.size = Vector2(tile_size * 0.96, tile_size * 0.96)
		_delete_material = StandardMaterial3D.new()
		_delete_material.albedo_color = Color(1.0, 0.25, 0.25, 0.5)
		_delete_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_delete_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var cells := _delete_cells(sides)
	for i in cells.size():
		var t: Vector2i = cells[i]
		var d := _claim_delete(i)
		d.position = tile_to_world(t.x, t.y) + Vector3(0.0, _DELETE_LIFT, 0.0)
		d.visible = true
	for i in range(cells.size(), _delete_pool.size()):
		_delete_pool[i].visible = false


## The ghost cells for the added `sides`. Each entry is `{gx, gz, sx, sz}`: the ghost's
## (out-of-grid) position and the surviving tile (`sx, sz`) whose height it mirrors.
## Pairs of orthogonal sides also emit the diagonal corner cell, so a corner grow
## previews its whole L of new tiles, not just the two straight runs.
func _ghost_cells(sides: Array) -> Array:
	var cells: Array = []
	var w := grid_width
	var h := grid_height
	var west := sides.has(Side.X_MIN)
	var east := sides.has(Side.X_MAX)
	var north := sides.has(Side.Z_MIN)
	var south := sides.has(Side.Z_MAX)
	if west:
		for z in h:
			cells.append({"gx": -1, "gz": z, "sx": 0, "sz": z})
	if east:
		for z in h:
			cells.append({"gx": w, "gz": z, "sx": w - 1, "sz": z})
	if north:
		for x in w:
			cells.append({"gx": x, "gz": -1, "sx": x, "sz": 0})
	if south:
		for x in w:
			cells.append({"gx": x, "gz": h, "sx": x, "sz": h - 1})
	if west and north:
		cells.append({"gx": -1, "gz": -1, "sx": 0, "sz": 0})
	if west and south:
		cells.append({"gx": -1, "gz": h, "sx": 0, "sz": h - 1})
	if east and north:
		cells.append({"gx": w, "gz": -1, "sx": w - 1, "sz": 0})
	if east and south:
		cells.append({"gx": w, "gz": h, "sx": w - 1, "sz": h - 1})
	return cells


## The edge tiles a delete on the given `sides` would remove. A corner tile can appear
## for two sides; drawing the red decal over it twice is harmless.
func _delete_cells(sides: Array) -> Array:
	var cells: Array = []
	if sides.has(Side.X_MIN):
		for z in grid_height:
			cells.append(Vector2i(0, z))
	if sides.has(Side.X_MAX):
		for z in grid_height:
			cells.append(Vector2i(grid_width - 1, z))
	if sides.has(Side.Z_MIN):
		for x in grid_width:
			cells.append(Vector2i(x, 0))
	if sides.has(Side.Z_MAX):
		for x in grid_width:
			cells.append(Vector2i(x, grid_height - 1))
	return cells


## Grow the ghost-box pool until it has a box at `i`, then return it.
func _claim_ghost(i: int) -> MeshInstance3D:
	while i >= _ghost_pool.size():
		var m := MeshInstance3D.new()
		m.mesh = _ghost_mesh
		m.material_override = _ghost_material
		m.visible = false
		add_child(m)
		_ghost_pool.append(m)
	return _ghost_pool[i]


## Grow the delete-decal pool until it has a decal at `i`, then return it.
func _claim_delete(i: int) -> MeshInstance3D:
	while i >= _delete_pool.size():
		var m := MeshInstance3D.new()
		m.mesh = _delete_mesh
		m.material_override = _delete_material
		m.visible = false
		add_child(m)
		_delete_pool.append(m)
	return _delete_pool[i]
