## The battlefield: a grid of terrain tiles that can shift between several
## "time-states" as time degrades (see docs/GAME_DESIGN.md §4).
##
## This node is deliberately *generic and size-agnostic* — it knows how to render
## and cycle a list of states, but not what any particular map looks like. The
## actual map data is supplied as `states` (a configuration); if none is provided
## it falls back to `SmallDemoMap` so the scene shows something on F5.
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

# --- Constants ---------------------------------------------------------------

## Sentinel returned by `tile_at_screen_point` when a click misses the grid.
## (-1, -1) is never a real tile coordinate, so callers test against this.
const INVALID_TILE := Vector2i(-1, -1)

## How far the mouse-pick ray is cast into the scene, in world units. The grid is
## only a few units tall, so anything comfortably longer than the camera distance
## works; 1000 is plenty and cheap.
const _PICK_RAY_LENGTH := 1000.0

## Thickness (world units) of the move-range outline strip across the edge it traces —
## thin, so it reads as a drawn border line rather than a filled band. Used as the strip's
## depth for both the horizontal top edges and the vertical cliff-face connectors.
const _RANGE_BORDER_WIDTH := 0.09

## Vertical thickness (world units) of a horizontal outline strip. Just enough to read as
## a solid line from the ortho camera without poking visibly above the tile surface.
const _RANGE_STRIP_THICKNESS := 0.04

## The four orthogonal grid steps (no diagonals), reused by the reachability flood and
## the range-outline edge test. `.y` is the grid Z axis (tiles are addressed (x, z)).
const _ORTHO_DIRS := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]

# --- Configuration (editable in the Inspector; this is what @export means) ----

## Optional saved map to load — a `MapData` resource (e.g. authored in the map
## designer, or a hand-built `.tres`). When assigned this WINS over a directly-set
## `states` and over the SmallDemoMap fallback, and its dimensions overwrite the
## `grid_width`/`grid_height` below (maps are variable-size; the data is the
## authority). Leave null to fall back to `states` or the built-in SmallDemoMap.
@export var map_data: MapData

## Number of tiles along the X axis. NOTE: this is only the size used to GENERATE the
## SmallDemoMap fallback — once a real map loads (`map_data` or an assigned `states`), it is
## overwritten with that map's width in `_ready`. There is intentionally no upper limit.
@export var grid_width: int = 12

## Number of tiles along the Z axis. Like `grid_width`, this only sizes the SmallDemoMap
## fallback; a loaded map's height replaces it.
@export var grid_height: int = 12

## World-space width/depth of a single tile. Tiles are placed flush (no gap).
@export var tile_size: float = 1.0

## World-space height of one unit of tile "height". A tile of height H rises
## `H * height_step` above the floor. Kept small so tall hills stay on-screen.
@export var height_step: float = 0.5

## Thickness of the colored surface cap that sits on top of the brown column.
## Thin, so most of a cliff face reads as brown earth.
@export var cap_thickness: float = 0.12

## How many height *levels* of body to always draw beneath a tile's top, even where it
## has no lower neighbour (flat ground, the map border). Keeps a flat map from rendering
## as a paper-thin sheet — and is the minimum underside thickness. A tile that DOES have a
## lower neighbour draws down to that neighbour instead (covering the cliff), so this only
## sets the floor for the no-cliff case. Bump it for chunkier slabs.
@export var min_body_depth: int = 1

## How far (world units) a LIQUID tile's surface is drawn BELOW its solid rim height, so water/
## lava/quicksand reads as a shallow basin rather than a flat-topped block. Purely cosmetic: the
## tile's gameplay height (used for jump/range/path math) stays the integer value — only the drawn
## cap and the things that sit ON the surface (markers, a standing unit) drop by this much. Kept
## well under `height_step` so the recess is a dip, not a full level.
@export var liquid_recess: float = 0.15

## Extra depth (world units) a UNIT sinks below a liquid tile's (already-recessed) surface, so the
## cylinder stands *in* the water instead of on top of it. Added on top of `liquid_recess` for the
## unit only — the surface markers stay at the water line. See `unit_stand_world`.
@export var liquid_sink: float = 0.22

# --- Time-shift cascade animation (see _begin_shift_animation) ----------------
# A shift no longer snaps the whole map at once; it sweeps a diagonal wave from corner (0,0), each
# tile morphing its OWN height + color over a few frames without waiting for its neighbours — so the
# map looks like it's transforming step by step. Units are held CONSTANT (and Main fades them
# translucent) through the whole cascade and resolved in one pass after it finishes (re-settle +
# fall damage then). These tune the feel (frame counts at a nominal 60fps).

## Frames a single tile takes to change ONE height level — the morph *rate*. A tile that moves N
## levels animates over `N * shift_frames_per_level` frames, so bigger changes take longer.
@export var shift_frames_per_level: float = 5.0

## Frames of delay added per diagonal step out from the start corner — the cascade *stagger*. Tile
## (x, z) begins its morph at `(x + z) * shift_cascade_frames`, so the wavefront flows across the map.
## Smaller = a tighter, faster sweep; larger = a slower, more drawn-out wave. This wants to be a fair
## bit larger than a single tile's morph time so the change clearly "floods" across rather than the
## far tiles starting as the near ones finish — which reads worst on SMALL maps (few diagonals, so a
## small total spread). Bumped from an initial 2.0 for exactly that.
@export var shift_cascade_frames: float = 4.0

## Minimum frames a tile's color morph takes when ONLY its type changed (no height move to pace it),
## so a recolor still eases in rather than snapping.
@export var shift_color_morph_frames: float = 8.0

# --- Runtime state -----------------------------------------------------------

## The ordered list of time-states. Leave empty to use the built-in SmallDemoMap, or
## assign your own configuration before this node enters the tree.
var states: Array = []

## Index into `states` of the state currently being displayed.
var _current_index: int = 0

## Whether this map authors its column undersides independently of the tops — the SCULPTED depth
## mode (`MapData.DepthMode`). False (AUTO, the default) means the underside is derived from the
## neighbours in `_column_bottom_in`, exactly as it always was; true means each column is drawn
## `[floor, top]` from the per-tile authored `floor` level. Adopted from `map_data` in `_ready`;
## procedurally-built maps (DemoMap / an assigned `states`) stay AUTO. The map designer flips it
## directly via `set_sculpted_depth` (its `EditableBattlefield` has no `map_data`).
var _sculpted_depth: bool = false

# --- Time-shift cascade runtime (set up in _begin_shift_animation, ticked in _process) ----

## Fired when a shift's cascade morph has fully played out and the map is rendered in its new state.
## `Main` awaits this during the transition cinematic so the unit re-settle + fall damage happen only
## after the wave has finished (and so it can hold on the finished map before zooming back in).
signal shift_animation_finished

## True while a cascade morph is playing. Gates `_process` and answers `is_shifting()` (the race-free
## check `Main` uses before awaiting `shift_animation_finished`).
var _shift_active: bool = false

## The state we are morphing FROM and TO. `_shift_to` is also the now-current state (the logical shift
## already happened; the cascade is the visual catch-up). Held so each frame can interpolate between
## them per tile.
var _shift_from: Array = []
var _shift_to: Array = []

## Frames elapsed since the cascade began (accumulated as `delta * 60`, a nominal-60fps frame count),
## and the total frames until every tile has finished (max tile `start + duration`).
var _shift_elapsed: float = 0.0
var _shift_total: float = 0.0

## Per-tile cascade schedule, indexed `[x][z]`: the frame each tile BEGINS morphing (its wavefront
## delay) and how many frames its morph lasts (paced by height change / color change).
var _shift_start: Array = []
var _shift_dur: Array = []

## Scratch per-frame grid of each tile's interpolated height LEVEL (float), filled before drawing so a
## tile's neighbour-aware column depth reads the neighbours' *animating* heights (cliffs morph too).
var _anim_level: Array = []

## Scratch per-frame grid of each tile's interpolated FLOOR level (float). Only used in SCULPTED
## depth mode, where the bottom is authored and so must morph across a time-shift in its own right
## (the time-degradation gimmick reshapes the underside too, not just the top). Parallel to
## `_anim_level`; left untouched (and unread) on Auto maps, whose bottom is derived from neighbours.
var _anim_floor: Array = []

## A single 1x1x1 box mesh shared by every tile instance. We never resize the
## mesh itself — each tile's MeshInstance3D is *scaled* to the size it needs.
## Sharing one mesh across hundreds of tiles is the idiomatic, cheap approach.
var _unit_box: BoxMesh

## The brown material used for every tile's earth column (shared).
var _earth_material: StandardMaterial3D

## Cache of surface materials, one per terrain type, built on demand.
var _surface_materials: Dictionary = {}

## Per-tile node references, indexed `_tiles[x][z]`. Each entry is a Dictionary
## `{ "earth": MeshInstance3D, "surface": MeshInstance3D, "collision": CollisionShape3D }`.
## We build these once and then just rescale/recolor them on every shift, rather
## than rebuilding.
var _tiles: Array = []

# --- Movement-path preview overlay (see show_path / clear_path) ---------------

## Shared flat mesh laid over a tile to "light it up" as part of a previewed path.
var _path_marker_mesh: PlaneMesh

## Shared translucent material for LEGAL path-marker tiles (blue) — steps the active
## unit is allowed to take. Per-marker `material_override` swaps in the illegal one below
## for tiles that fail the move budget / jump gate / occupancy (see show_path).
var _path_marker_material: StandardMaterial3D

## Shared translucent material for ILLEGAL path-marker tiles (red) — a step that exceeds
## the unit's jump, runs past its move budget, or ends on an occupied tile.
var _path_illegal_material: StandardMaterial3D

## A reusable pool of marker nodes. We grow it on demand and hide the leftovers,
## so sweeping the mouse around to preview routes never allocates per frame.
var _path_markers: Array[MeshInstance3D] = []

# --- Attack-range overlay (see show_attack_range / clear_attack_range) ---------

## Shared translucent ORANGE material for attack-range tiles — a filled marker on every tile a
## unit can strike from where it stands. Distinct from the move-range outline (blue/black) so
## "where I can hit" reads differently from "where I can walk".
var _attack_marker_material: StandardMaterial3D

## Grown-on-demand pool of attack-range markers (same pooling as the path markers), reusing the
## shared `_path_marker_mesh` plane.
var _attack_markers: Array[MeshInstance3D] = []

# --- Move-range outline overlay (see show_move_range / clear_move_range) -------

## A 1x1x1 box, scaled per segment into a thin horizontal sliver (a top edge) or a thin
## vertical sliver (a cliff-face connector). A box rather than a flat plane lets the one
## shared mesh form BOTH, so the outline can drop down terrain steps and stay continuous.
var _range_strip_mesh: BoxMesh

## Shared bright-blue material for the move-range outline (all segments look alike).
var _range_material: StandardMaterial3D

## Grown-on-demand pool of outline strips, leftovers hidden — same no-per-frame-alloc
## trick as the path markers.
var _range_markers: Array[MeshInstance3D] = []

# --- Active-unit tile marker (see set_active_tile / clear_active_tile) --------

## A single flat overlay laid on the active unit's tile — the FFT-style "whose turn
## it is" highlight. One reusable node (only one unit is active at a time), recolored
## per side and repositioned as the active unit changes or walks.
var _active_marker: MeshInstance3D

## The active marker's own material, so its color can be set per allegiance without
## touching any other overlay.
var _active_marker_material: StandardMaterial3D


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

	# Shared resources for the movement-path preview overlay (see show_path). A flat
	# PlaneMesh lies in the XZ plane (facing up) by default, so it reads as a decal on
	# the tile surface. Slightly inset from the tile so a path shows a thin border.
	_path_marker_mesh = PlaneMesh.new()
	_path_marker_mesh.size = Vector2(tile_size * 0.9, tile_size * 0.9)
	# Translucent, unshaded cyan so the highlight reads the same under any lighting.
	_path_marker_material = StandardMaterial3D.new()
	_path_marker_material.albedo_color = Color(0.30, 0.80, 1.0, 0.5)
	_path_marker_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_path_marker_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

	# The red twin used for path tiles the move can't legally reach (jump too tall,
	# beyond the move budget, or an occupied destination). Same flat translucent decal.
	_path_illegal_material = StandardMaterial3D.new()
	_path_illegal_material.albedo_color = Color(1.0, 0.30, 0.30, 0.5)
	_path_illegal_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_path_illegal_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

	# Orange fill for the attack-range overlay — every tile in striking distance (see
	# show_attack_range). Same flat translucent decal recipe as the path markers.
	_attack_marker_material = StandardMaterial3D.new()
	_attack_marker_material.albedo_color = Color(1.0, 0.55, 0.10, 0.5)
	_attack_marker_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_attack_marker_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

	# Move-range outline: one shared 1x1 flat strip (scaled per edge segment) and one
	# opaque BLACK material. Drawn only along the border of the reachable region (see
	# show_move_range), so the interior stays clear. Black (not blue) so the border reads
	# like a crisp menu line against any backdrop — a blue outline washed out against the
	# sky where the region met the grid edge. Opaque + unshaded keeps it a flat, even line.
	_range_strip_mesh = BoxMesh.new()
	_range_strip_mesh.size = Vector3.ONE
	_range_material = StandardMaterial3D.new()
	_range_material.albedo_color = Color(0.05, 0.05, 0.05)
	_range_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

	# The active-unit tile highlight: one flat plane, nearly tile-sized, recolored per
	# side. Same decal trick as the path markers — a PlaneMesh lying in the XZ plane,
	# unshaded and translucent so it reads as a marker on the surface, not a slab.
	var active_mesh := PlaneMesh.new()
	active_mesh.size = Vector2(tile_size * 0.96, tile_size * 0.96)
	_active_marker_material = StandardMaterial3D.new()
	_active_marker_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_active_marker_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_active_marker = MeshInstance3D.new()
	_active_marker.mesh = active_mesh
	_active_marker.material_override = _active_marker_material
	_active_marker.visible = false
	add_child(_active_marker)

	# Resolve the map source, in priority order: an assigned MapData resource (the
	# saved/designed format), then a directly-assigned `states` (procedural callers),
	# then the built-in SmallDemoMap so the scene always shows something on F5.
	if map_data != null:
		states = map_data.to_states()
		# A saved map carries its own depth mode; procedural fallbacks stay AUTO (derived underside).
		_sculpted_depth = map_data.depth_mode == MapData.DepthMode.SCULPTED
	elif states.is_empty():
		states = SmallDemoMap.generate(grid_width, grid_height)

	# Maps are variable-size, so the loaded data — not the exports — is the authority
	# on dimensions. Adopt them before building tiles, since all the grid math
	# (placement, BFS bounds, centering) reads grid_width/grid_height.
	_adopt_dimensions_from_states()

	_build_tiles()
	render_state(_current_index)

	# `_process` only does work mid-shift (the cascade morph). Stay idle until `advance_shift` arms it.
	set_process(false)


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


## Advance the time-shift by one step: move to the next state (wrapping) and play the cascade morph
## into it. The logical state advances immediately (so `current_state` / picking / `Main`'s re-settle
## all read the NEW terrain right away — input is gated during the cinematic anyway); the cascade is a
## purely visual catch-up that sweeps across the tiles over the next frames. Terrain only — this node
## stays unit-agnostic. Re-settling units onto the new heights and applying fall damage is coordinated
## by `Main` AFTER the cascade finishes (it awaits `shift_animation_finished`), via
## `_capture_unit_heights` / `_resettle_units_after_shift`.
func advance_shift() -> void:
	var from_state: Array = states[_current_index]
	_current_index = next_state_index()
	print("Battlefield: shifting to time-state %d / %d" % [_current_index + 1, states.size()])
	_begin_shift_animation(from_state, states[_current_index])


## Whether a cascade morph is currently playing. `Main` checks this before awaiting
## `shift_animation_finished` so it never blocks forever on a wave that already finished (e.g. a
## no-op shift that completed synchronously).
func is_shifting() -> bool:
	return _shift_active


## Set up the cascade that morphs every tile from `from_state` to `to_state`. Computes each tile's
## start frame (a diagonal wavefront out from corner (0,0)) and morph duration (paced by how many
## height levels it moves, with a floor when only its color changes), then arms `_process` to tick it.
## A shift where nothing actually changes finishes immediately (no wave to play).
func _begin_shift_animation(from_state: Array, to_state: Array) -> void:
	_shift_from = from_state
	_shift_to = to_state
	_shift_elapsed = 0.0
	_shift_total = 0.0
	_shift_start = []
	_shift_dur = []
	_anim_level = []
	_anim_floor = []
	for x in grid_width:
		var start_col: Array = []
		var dur_col: Array = []
		var level_col: Array = []
		var floor_col: Array = []
		for z in grid_height:
			var from_tile: Dictionary = from_state[x][z]
			var to_tile: Dictionary = to_state[x][z]
			var dh: int = abs(to_tile["height"] - from_tile["height"])
			# In Sculpted mode the authored floor also moves, so pace the morph by whichever face
			# (top or bottom) travels further — a tile whose floor alone changes still animates.
			if _sculpted_depth:
				var df: int = abs(_floor_of(to_tile) - _floor_of(from_tile))
				dh = maxi(dh, df)
			var dur: float = dh * shift_frames_per_level
			if _tile_color_changes(from_tile, to_tile):
				dur = maxf(dur, shift_color_morph_frames)
			var start: float = (x + z) * shift_cascade_frames
			start_col.append(start)
			dur_col.append(dur)
			level_col.append(float(from_tile["height"]))   # seed at FROM so frame 0 looks unchanged
			floor_col.append(float(_floor_of(from_tile)))
			_shift_total = maxf(_shift_total, start + dur)
		_shift_start.append(start_col)
		_shift_dur.append(dur_col)
		_anim_level.append(level_col)
		_anim_floor.append(floor_col)
	if _shift_total <= 0.0:
		_finish_shift_animation()   # nothing changed — snap to the new state and announce
		return
	_shift_active = true
	set_process(true)


## Whether any visible face of the tile (top / sides / underside) changes terrain type across the
## shift — i.e. whether there's a color to morph. Drives the color-morph duration floor.
func _tile_color_changes(from_tile: Dictionary, to_tile: Dictionary) -> bool:
	for face in [TileFaces.Face.TOP, TileFaces.Face.NORTH, TileFaces.Face.BOTTOM]:
		if TileFaces.face_type(from_tile, face) != TileFaces.face_type(to_tile, face):
			return true
	return false


## Per-frame tick of the cascade (only while `_shift_active`). Advances the frame clock, redraws the
## whole map at the current interpolation, and finishes once every tile's morph has played out.
func _process(delta: float) -> void:
	if not _shift_active:
		return
	_shift_elapsed += delta * 60.0   # treat one "frame" as 1/60s so the export tuning reads in frames
	# First fill every tile's interpolated height, THEN draw — so each tile's neighbour-aware column
	# depth sees its neighbours' animating heights (cliffs grow/shrink smoothly with the wave).
	for x in grid_width:
		for z in grid_height:
			var t := _tile_progress(x, z)
			_anim_level[x][z] = lerpf(float(_shift_from[x][z]["height"]), float(_shift_to[x][z]["height"]), t)
			# Morph the authored floor too (Sculpted only — Auto derives the bottom each frame).
			if _sculpted_depth:
				_anim_floor[x][z] = lerpf(float(_floor_of(_shift_from[x][z])), float(_floor_of(_shift_to[x][z])), t)
	for x in grid_width:
		for z in grid_height:
			_draw_shift_tile(x, z)
	if _shift_elapsed >= _shift_total:
		_finish_shift_animation()


## How far tile (x, z) is through its own morph this frame, 0→1. Before its wavefront arrives it's 0;
## after its duration it's 1; a zero-duration (unchanged) tile is simply 1.
func _tile_progress(x: int, z: int) -> float:
	var dur: float = _shift_dur[x][z]
	if dur <= 0.0:
		return 1.0
	return clampf((_shift_elapsed - _shift_start[x][z]) / dur, 0.0, 1.0)


## Draw one tile mid-morph: interpolate its height (and the liquid recess) and lerp each face's color
## between the from- and to-type, using per-tile morph materials so other tiles of the same type are
## untouched. Routes through the same `_apply_tile_geometry` the static render uses.
func _draw_shift_tile(x: int, z: int) -> void:
	var t := _tile_progress(x, z)
	var from_tile: Dictionary = _shift_from[x][z]
	var to_tile: Dictionary = _shift_to[x][z]

	# Visible top: animated rim minus the liquid recess, itself eased in as a tile turns liquid.
	var own_top: float = _anim_level[x][z] * height_step
	var recess := lerpf(_recess_for(from_tile["type"]), _recess_for(to_tile["type"]), t)
	var surface_top: float = own_top - recess

	# Column underside. SCULPTED: the authored floor, morphing in its own right (mirrors
	# `_column_bottom_in`'s sculpted branch on the animating value). AUTO: the lowest animating
	# neighbour (mirrors the derived branch on floats), so cliff faces grow/shrink through the morph.
	var base_y: float
	if _sculpted_depth:
		base_y = _anim_floor[x][z] * height_step
	else:
		var lowest: float = own_top
		for dir in _ORTHO_DIRS:
			var d: Vector2i = dir
			var nx: int = x + d.x
			var nz: int = z + d.y
			if nx >= 0 and nx < grid_width and nz >= 0 and nz < grid_height:
				lowest = minf(lowest, _anim_level[nx][nz] * height_step)
		base_y = lowest if lowest < own_top else own_top - float(min_body_depth) * height_step

	var refs: Dictionary = _tiles[x][z]
	var body_mat := _anim_material(refs, "body_mat", from_tile, to_tile, TileFaces.Face.NORTH, t)
	var surface_mat := _anim_material(refs, "surface_mat", from_tile, to_tile, TileFaces.Face.TOP, t)
	var bottom_mat := _anim_material(refs, "bottom_mat", from_tile, to_tile, TileFaces.Face.BOTTOM, t)
	_apply_tile_geometry(refs, base_y, surface_top, body_mat, surface_mat, bottom_mat)


## The liquid surface recess for a terrain `type` (0 for solid ground) — the amount the visible cap
## drops; lerped during a morph so water "fills in" as a tile becomes liquid.
func _recess_for(type: int) -> float:
	return liquid_recess if TileTypes.is_liquid(type) else 0.0


## A tile's authored bottom LEVEL (Sculpted mode), defaulting to one level below its top when the
## tile carries no `floor` (Auto/legacy data). One accessor so the shift cascade and the column
## drawer agree on the value. Only consulted in Sculpted mode.
func _floor_of(tile: Dictionary) -> int:
	return tile.get("floor", tile["height"] - 1)


## Get (creating once, cached in the tile's `refs`) a per-tile morph material for `key`, set to the
## color of `face` lerped between the from- and to-type. Per-tile so morphing one tile never tints
## the shared per-type materials (and thus every other tile of that type). Reused across shifts; the
## static `render_state` swaps the shared materials back in when the cascade finishes.
func _anim_material(refs: Dictionary, key: String, from_tile: Dictionary, to_tile: Dictionary, face: int, t: float) -> StandardMaterial3D:
	if not refs.has(key):
		refs[key] = StandardMaterial3D.new()
	var mat: StandardMaterial3D = refs[key]
	var from_col := TileTypes.surface_color(TileFaces.face_type(from_tile, face))
	var to_col := TileTypes.surface_color(TileFaces.face_type(to_tile, face))
	mat.albedo_color = from_col.lerp(to_col, t)
	return mat


## End the cascade: stop ticking and render the final state cleanly (which restores the shared,
## cached per-type materials over the per-tile morph ones), then announce completion.
func _finish_shift_animation() -> void:
	_shift_active = false
	set_process(false)
	render_state(_current_index)
	shift_animation_finished.emit()


# --- Grid <-> world helpers (seed of the future coordinate-helper module) -----

## World height of a tile's integer RIM (its `height` level in world units) in the current state.
## This is the gameplay surface — jump, movement range, and pathing all compare against it. NOTE: it
## is *not* where a unit's feet sit on a liquid (those recess; see `_surface_world_y` /
## `unit_stand_world`), nor where surface markers draw (`tile_to_world`). Derived from tile data, not
## stored, so it stays correct across shifts.
func tile_height(x: int, z: int) -> float:
	return current_state()[x][z]["height"] * height_step


## World position of the center of a tile's VISIBLE top surface in the current state — i.e. where
## a marker (path/attack/active) sits and the surface a unit's feet meet. For a liquid tile this is
## the recessed water line (see `liquid_recess`), NOT the integer rim — that's why it reads from
## `_surface_world_y` rather than the integer `tile_height`. Movement, targeting overlays, and the
## camera all build on this.
func tile_to_world(x: int, z: int) -> Vector3:
	return Vector3(_grid_to_world_x(x), _surface_world_y(current_state(), x, z), _grid_to_world_z(z))


## World-space center the camera should look at to frame the WHOLE map centered. X and Z are
## the origin (the grid is centered there by `_grid_to_world_x/z`), but Y is NOT zero: it's the
## midpoint between the lowest and highest visible tile surface in the current state. The grid is
## only centered on origin in the ground plane — a map authored high up (the designer's tiles
## start at height level 20, i.e. world y≈10) would otherwise float well above a fixed y=0 look-at,
## reading as "off-center up". Callers (the designer camera) target this so framing tracks the
## actual terrain height band instead of assuming the ground sits at y=0.
func grid_center_world() -> Vector3:
	var state := current_state()
	var lo := INF
	var hi := -INF
	for x in grid_width:
		for z in grid_height:
			var y := _surface_world_y(state, x, z)
			lo = minf(lo, y)
			hi = maxf(hi, y)
	return Vector3(0.0, (lo + hi) * 0.5, 0.0)


## Where a UNIT'S origin rests when standing on tile (x, z): the visible surface, dropped a further
## `liquid_sink` on liquids so the cylinder sits *in* the water rather than on it. Solid tiles match
## `tile_to_world` exactly. This is the seam used for spawn placement and the walk path (see
## `path_to_world_points`), kept separate from `tile_to_world` so only the unit sinks, not the
## surface markers that mark the water line.
func unit_stand_world(x: int, z: int) -> Vector3:
	var p := tile_to_world(x, z)
	if TileTypes.is_liquid(surface_type(x, z)):
		p.y -= liquid_sink
	return p


## The surface (cap) terrain `TileTypes.Type` of tile (x, z) in the current state — the gameplay
## type that drives move cost, casting legality, hazard damage, and the liquid tag. The single
## accessor `Main` reads for those rules, so it never reaches into the raw state dictionary.
func surface_type(x: int, z: int) -> int:
	return current_state()[x][z]["type"]


## The integer height LEVEL of tile (x, z) in the current state (the raw value before `height_step`
## world scaling) — the same units a `jump` stat is in. Public twin of the internal `_height_units`,
## exposed so `Main` can measure how far a unit fell across a time-shift (in levels) for fall damage.
func height_level(x: int, z: int) -> int:
	return current_state()[x][z]["height"]


## World Y of a tile's VISIBLE top within `state`: the integer rim (`height * height_step`) for
## solid terrain, dropped by `liquid_recess` for a liquid surface so water sits in a shallow basin.
## Shared by `tile_to_world` (current state) and `render_state` (any state) so the drawn cap, the
## collision box, and everything that sits on the surface agree on one height. Note this is
## deliberately NOT used by the jump/range math — those stay on the integer `tile_height` so the
## cosmetic recess never changes which steps are legal.
func _surface_world_y(state: Array, x: int, z: int) -> float:
	var top: float = state[x][z]["height"] * height_step
	if TileTypes.is_liquid(state[x][z]["type"]):
		top -= liquid_recess
	return top


## World Y of tile (x, z)'s column UNDERSIDE in the current state — where its drawn body
## (and its bottom cap) bottoms out. Public so the designer's grid overlay can outline the
## underside at the same level the renderer uses. See `_column_bottom_in`.
func column_bottom(x: int, z: int) -> float:
	return _column_bottom_in(current_state(), x, z)


## Whether this map is in SCULPTED depth mode (authored undersides). See `_sculpted_depth`.
func is_sculpted_depth() -> bool:
	return _sculpted_depth


## Switch the depth mode (the designer's convert action calls this; battles use the value adopted
## from `map_data`). Caller is responsible for re-rendering — `EditableBattlefield` redraws after.
func set_sculpted_depth(sculpted: bool) -> void:
	_sculpted_depth = sculpted


## World Y of a tile's column underside within a given `state` (used by `render_state`,
## which draws an arbitrary state, and by `column_bottom` for the current one).
##
## The body only drops to the LOWEST orthogonally-adjacent surface, so a side face spans
## exactly the exposed cliff instead of always running to y=0 — and a tile beside a carved
## pit drops to the pit's top, covering the pit wall. With no lower neighbour (flat ground,
## or the map edge — off-grid neighbours are treated as no cliff), it falls back to a thin
## `min_body_depth`-level slab so the tile isn't paper-thin.
func _column_bottom_in(state: Array, x: int, z: int) -> float:
	# SCULPTED maps author the bottom outright: each column is exactly [floor, top], with no
	# neighbour derivation (so deliberate gaps / floating slabs are kept, not filled). The floor is
	# an integer level like `height`; world it the same way. Auto maps fall through to the derived
	# logic below.
	if _sculpted_depth:
		return state[x][z].get("floor", state[x][z]["height"] - 1) * height_step
	# Work in VISIBLE-surface space for BOTH this tile and its neighbours (not integer rims). A
	# liquid cap sits `liquid_recess` below its rim (see `_surface_world_y`); comparing recessed
	# neighbours against an integer-rim own-top invented a false `liquid_recess` cliff, so a flat
	# field of equal-height liquid (e.g. a square-brushed pool) collapsed every column to ~0
	# height. Using each tile's own visible surface keeps a flat liquid field flush (no false
	# cliff → thin-slab fallback) while still extending a solid wall the extra recess down to meet
	# a lower liquid neighbour's waterline. For solid tiles `_surface_world_y` == the rim, so
	# solid-to-solid behaviour is unchanged.
	var top: float = _surface_world_y(state, x, z)
	var lowest: float = top
	for dir in _ORTHO_DIRS:
		var d: Vector2i = dir
		var nx: int = x + d.x
		var nz: int = z + d.y
		if nx >= 0 and nx < grid_width and nz >= 0 and nz < grid_height:
			var nt: float = _surface_world_y(state, nx, nz)
			if nt < lowest:
				lowest = nt
	if lowest < top:
		return lowest                       # cover the cliff down to the lowest neighbour
	return top - float(min_body_depth) * height_step   # flat/border: a thin minimum slab


## Densify a sparse list of waypoint tiles into a list of orthogonally *adjacent*
## tiles (no diagonals), so movement can step one tile at a time. Between two
## consecutive waypoints we walk along X until aligned, then along Z — a
## deterministic L-shaped fill. Waypoints exist precisely so the player can shape
## the route by inserting their own corners instead of accepting this naive path.
## Returns a path that starts at `waypoints[0]` and ends at the last waypoint.
static func expand_path(waypoints: Array) -> Array:
	var path: Array[Vector2i] = []
	if waypoints.is_empty():
		return path
	path.append(waypoints[0])
	for i in range(1, waypoints.size()):
		# Copy the latest tile (Vector2i is a value type) and walk it to the goal,
		# one axis at a time — so every appended step is orthogonally adjacent.
		var cur: Vector2i = path[path.size() - 1]
		var goal: Vector2i = waypoints[i]
		while cur.x != goal.x:
			cur.x += signi(goal.x - cur.x)  # signi() => +1/-1 step toward the goal
			path.append(cur)
		while cur.y != goal.y:
			cur.y += signi(goal.y - cur.y)
			path.append(cur)
	return path


## Convert a dense (adjacent) tile path into the world-space points a unit walks
## through to "step" along the ground. Instead of one straight diagonal line (which
## makes a unit float up to a hilltop), each step bumps up/down at the tile
## boundary. Returns the points *after* the start tile (the unit is already there).
func path_to_world_points(tiles: Array) -> Array:
	var points: Array[Vector3] = []
	for i in range(1, tiles.size()):
		# Walk at the UNIT'S standing height (sunk into liquids), not the bare surface, so a unit
		# wading through water dips down step by step instead of skating across its surface.
		var a: Vector3 = unit_stand_world(tiles[i - 1].x, tiles[i - 1].y)
		var b: Vector3 = unit_stand_world(tiles[i].x, tiles[i].y)
		if b.y > a.y:
			# Stepping UP: rise in place over tile A to B's height, then move onto B.
			# Rising above its own tile first keeps the body off the cliff face.
			points.append(Vector3(a.x, b.y, a.z))
			points.append(b)
		elif b.y < a.y:
			# Stepping DOWN: move out over tile B at the old height, then drop onto B.
			points.append(Vector3(b.x, a.y, b.z))
			points.append(b)
		else:
			# Same height: a single flat step.
			points.append(b)
	return points


## The vertical change (in world units) of each adjacent step along `tiles`. This
## is the input a future jump/move gate checks against a unit's jump stat: any
## abs(step) larger than the unit can manage makes that step — and the path —
## illegal. Returning the data now (rather than the gate) keeps movement simple
## while letting the gate be added as a one-liner later.
func path_step_heights(tiles: Array) -> Array:
	var heights: Array[float] = []
	for i in range(1, tiles.size()):
		heights.append(tile_height(tiles[i].x, tiles[i].y) - tile_height(tiles[i - 1].x, tiles[i - 1].y))
	return heights


## The integer height "level" of tile (x, z) in the current state — the raw value
## before `height_step` world scaling. The jump gate compares these directly against a
## unit's `jump` stat, which is also expressed in height-levels (not world units).
func _height_units(x: int, z: int) -> int:
	return current_state()[x][z]["height"]


## Flood of every tile the active unit can both REACH and legally STOP on from `start`, spending at
## most `move_points`. The cost to ENTER a tile is that tile's terrain `move_cost` (1 for most
## ground, 2 for liquids) — NOT a flat 1 per step — so wading costs more than walking. A step is
## walkable only when the height change to the neighbour is within `jump` AND the neighbour isn't in
## `solid` (impassable — e.g. an enemy unit). Tiles in `occupied` (any unit standing there) can be
## walked THROUGH but not stopped on, so they still expand the flood yet are left out of the
## returned set. Returns `{ Vector2i: cost }`, always including `start` at cost 0. This is the data
## the move-range outline draws from.
##
## Because step costs now VARY, a plain BFS no longer guarantees the first arrival is cheapest, so
## this is a small Dijkstra: each pass pops the cheapest unfinalized ("unvisited") tile and relaxes
## its neighbours. The grids are small and the reachable region is bounded by the move budget, so
## the linear-scan min-extraction is plenty fast (no heap needed).
func reachable_tiles(start: Vector2i, move_points: int, jump: int, solid: Dictionary, occupied: Dictionary) -> Dictionary:
	# `dist` is the best known cost to each tile (the Dijkstra frontier + settled set); `visited`
	# marks tiles whose cost is finalized; `result` mirrors `dist` but excludes tiles you can't stop
	# on (occupied), since those expand the flood but aren't valid destinations.
	var dist := {start: 0}
	var visited := {}
	var result := {start: 0}
	while true:
		# Pop the cheapest tile we haven't finalized yet (Dijkstra's "next nearest").
		var cur: Vector2i = start
		var cur_cost := -1
		var found := false
		for t in dist:
			if visited.has(t):
				continue
			if not found or dist[t] < cur_cost:
				cur = t
				cur_cost = dist[t]
				found = true
		if not found:
			break   # every reachable tile is finalized
		visited[cur] = true
		if cur_cost >= move_points:
			continue   # no budget left to step further from here
		for dir in _ORTHO_DIRS:
			var n: Vector2i = cur + dir
			if n.x < 0 or n.x >= grid_width or n.y < 0 or n.y >= grid_height:
				continue   # off the grid
			if visited.has(n):
				continue   # already finalized at its cheapest cost
			if solid.has(n):
				continue   # impassable tile (enemy unit)
			if abs(_height_units(n.x, n.y) - _height_units(cur.x, cur.y)) > jump:
				continue   # climb/drop is taller than this unit's jump
			var nc: int = cur_cost + TileTypes.move_cost(surface_type(n.x, n.y))
			if nc > move_points:
				continue   # can't afford to enter this tile
			if not dist.has(n) or nc < dist[n]:
				dist[n] = nc
				# Reachable, but only a legal STOP if no one is standing there.
				if not occupied.has(n):
					result[n] = nc
	return result


## Shortest legal step-path from `start` to `dest` (both inclusive), as a list of
## orthogonally adjacent tiles, or `[]` if `dest` can't be reached within the limits. Each
## step obeys the SAME rule as `reachable_tiles` — costs 1, walkable only when the height
## change is within `jump` and the neighbour isn't `solid`. The path may pass *through*
## occupied tiles (you can walk past an ally); the caller picks `dest` from the reachable
## set, which already excludes occupied tiles, so `_occupied` isn't needed here — it's
## accepted only so this mirrors `reachable_tiles`' signature.
##
## Dijkstra with parent links (the variable per-tile `move_cost` rules out plain BFS, exactly as in
## `reachable_tiles`): we settle tiles cheapest-first, recording where each was reached most cheaply
## *from*, and once `dest` is finalized we walk that chain back to `start` and flip it. The enemy AI
## hands the result to `Unit.move_along`; the player builds its route from waypoints + `expand_path`.
func find_path(start: Vector2i, dest: Vector2i, move_points: int, jump: int, solid: Dictionary, _occupied: Dictionary) -> Array:
	var path: Array[Vector2i] = []
	if start == dest:
		return [start]   # already there — a one-tile path (no steps to walk)
	var dist := {start: 0}
	var visited := {}
	var came_from := {start: start}   # tile -> the tile we reached it most cheaply from
	while true:
		# Pop the cheapest unfinalized tile (Dijkstra's next nearest).
		var cur: Vector2i = start
		var cur_cost := -1
		var found := false
		for t in dist:
			if visited.has(t):
				continue
			if not found or dist[t] < cur_cost:
				cur = t
				cur_cost = dist[t]
				found = true
		if not found:
			break   # exhausted everything reachable within budget without settling dest
		visited[cur] = true
		if cur == dest:
			break   # dest finalized at its cheapest cost — stop and rebuild the route
		if cur_cost >= move_points:
			continue   # no budget left to step further from here
		for dir in _ORTHO_DIRS:
			var n: Vector2i = cur + dir
			if n.x < 0 or n.x >= grid_width or n.y < 0 or n.y >= grid_height:
				continue   # off the grid
			if visited.has(n):
				continue   # already finalized at its cheapest cost
			if solid.has(n):
				continue   # impassable tile (enemy unit)
			if abs(_height_units(n.x, n.y) - _height_units(cur.x, cur.y)) > jump:
				continue   # climb/drop taller than this unit's jump
			var nc: int = cur_cost + TileTypes.move_cost(surface_type(n.x, n.y))
			if nc > move_points:
				continue   # can't afford to enter this tile
			if not dist.has(n) or nc < dist[n]:
				dist[n] = nc
				came_from[n] = cur
	if not visited.has(dest):
		return path   # unreachable within the move budget — empty path
	# Reconstruct dest -> … -> start via parents, then reverse to walk order.
	var node: Vector2i = dest
	while node != start:
		path.append(node)
		node = came_from[node]
	path.append(start)
	path.reverse()
	return path


## Per-tile legality for a concrete, already-expanded `tiles` path (parallel to it). The
## start tile (index 0) is always legal — the unit is standing on it. Walking outward, a
## step stays legal only while every prior step was legal AND: the cumulative cost so far
## (each tile costs its own terrain `move_cost`, so liquids count double) is within
## `move_points`, the height change is within `jump`, and it doesn't enter a `solid` tile;
## additionally the FINAL tile must not be `occupied` (you can pass through an ally but not
## stop on one). Once a tile is illegal, every later tile is too. This drives the blue/red
## split in the path preview, and the commit gate reuses it (a path with any `false` is refused).
func classify_path(tiles: Array, move_points: int, jump: int, solid: Dictionary, occupied: Dictionary) -> Array:
	var flags: Array[bool] = []
	if tiles.is_empty():
		return flags
	flags.append(true)   # tiles[0] is the unit's current tile — always fine
	var last := tiles.size() - 1
	var legal_so_far := true
	var cost := 0   # cumulative move points spent ENTERING tiles[1..i] (matches the Dijkstra cost)
	for i in range(1, tiles.size()):
		var ok := legal_so_far
		if ok:
			cost += TileTypes.move_cost(surface_type(tiles[i].x, tiles[i].y))
			var climb: int = abs(_height_units(tiles[i].x, tiles[i].y) - _height_units(tiles[i - 1].x, tiles[i - 1].y))
			if cost > move_points:
				ok = false            # past the move budget
			elif climb > jump:
				ok = false            # step too tall for this unit's jump
			elif solid.has(tiles[i]):
				ok = false            # stepped into an impassable (enemy) tile
			elif i == last and occupied.has(tiles[i]):
				ok = false            # can't stop on a tile a unit already holds
		flags.append(ok)
		legal_so_far = legal_so_far and ok
	return flags


## Light up each tile in `tiles` with a translucent overlay marker — the live
## movement-path preview. Reuses a pool of marker meshes (grown on demand, leftovers
## hidden) so dragging the mouse to preview routes is cheap. Empty list hides all.
##
## `legal_flags` (parallel to `tiles`, from `classify_path`) colours each tile: blue
## where the move is allowed, red where it isn't. When omitted, every tile shows blue —
## handy for callers that don't gate (none do today, but it keeps the API forgiving).
func show_path(tiles: Array, legal_flags: Array = []) -> void:
	# Grow the pool until there is a marker for every path tile.
	while _path_markers.size() < tiles.size():
		var marker := MeshInstance3D.new()
		marker.mesh = _path_marker_mesh
		marker.material_override = _path_marker_material
		marker.visible = false
		add_child(marker)
		_path_markers.append(marker)
	# Place + show one marker per tile (lifted slightly to avoid z-fighting with the
	# colored cap), and hide any pool markers this path doesn't need.
	for i in _path_markers.size():
		var marker: MeshInstance3D = _path_markers[i]
		if i < tiles.size():
			marker.position = tile_to_world(tiles[i].x, tiles[i].y) + Vector3(0.0, 0.03, 0.0)
			# Default to legal/blue; paint red where the legality flag says illegal.
			var legal: bool = legal_flags[i] if i < legal_flags.size() else true
			marker.material_override = _path_marker_material if legal else _path_illegal_material
			marker.visible = true
		else:
			marker.visible = false


## Hide the movement-path preview overlay.
func clear_path() -> void:
	for marker in _path_markers:
		marker.visible = false


## Every tile within `[min_range, max_range]` Manhattan steps of `origin`, clipped to the grid.
## Generic targeting math shared by all attacks: melee passes 1..1, a bow 3..6, a spell its own
## band. `min_range > 1` excludes point-blank tiles (so ranged attacks can't hit adjacent).
## Height is ignored for now — this is flat grid distance. Drives the orange attack overlay and
## the click-to-target validation.
func tiles_in_range(origin: Vector2i, min_range: int, max_range: int) -> Array:
	var result: Array[Vector2i] = []
	for dx in range(-max_range, max_range + 1):
		for dz in range(-max_range, max_range + 1):
			var dist: int = abs(dx) + abs(dz)
			if dist < min_range or dist > max_range:
				continue
			var t := Vector2i(origin.x + dx, origin.y + dz)
			if t.x < 0 or t.x >= grid_width or t.y < 0 or t.y >= grid_height:
				continue
			result.append(t)
	return result


## Fill each tile in `tiles` with the translucent orange attack-range marker. Same
## grown-on-demand / hide-leftovers pooling as the path preview. Empty list hides all.
func show_attack_range(tiles: Array) -> void:
	while _attack_markers.size() < tiles.size():
		var marker := MeshInstance3D.new()
		marker.mesh = _path_marker_mesh   # reuse the shared inset plane
		marker.material_override = _attack_marker_material
		marker.visible = false
		add_child(marker)
		_attack_markers.append(marker)
	for i in _attack_markers.size():
		var marker: MeshInstance3D = _attack_markers[i]
		if i < tiles.size():
			marker.position = tile_to_world(tiles[i].x, tiles[i].y) + Vector3(0.0, 0.03, 0.0)
			marker.visible = true
		else:
			marker.visible = false


## Hide the attack-range overlay.
func clear_attack_range() -> void:
	for marker in _attack_markers:
		marker.visible = false


## Draw the move-range OUTLINE: a bright border tracing the silhouette of the reachable
## region. For every reachable tile we lay a thin strip along each side that faces a
## NON-reachable tile (or the grid edge), so the interior stays clear and only "the shape
## of where I can go" is drawn. `reachable` is the dict from `reachable_tiles` (its keys
## are the reachable tiles). Reuses a grown-on-demand strip pool; pass an empty dict (or
## call `clear_move_range`) to hide it.
func show_move_range(reachable: Dictionary) -> void:
	var seg := 0   # index of the next free strip in the pool
	# As we lay the horizontal top lines we also record, per grid corner, the lowest and
	# highest top-line that touches it. Where those differ, the outline changes height at
	# that corner, so a thin vertical post is dropped there to keep the line continuous —
	# this spans multi-level drops for free (every level's line touches the same corner).
	# Corners are keyed in a DOUBLED integer lattice so tile centers (even) and corners
	# (odd) both have integer keys; see `_edge_corner_keys`.
	var corner_lo := {}
	var corner_hi := {}
	for tile in reachable:
		var here: Vector2i = tile
		var here_top := tile_height(here.x, here.y)
		for dir in _ORTHO_DIRS:
			if reachable.has(here + dir):
				continue   # interior edge — neighbour is reachable too, no border here
			# Top line: a horizontal sliver along this edge at the tile's surface height.
			_place_range_top(_claim_range_marker(seg), here, dir, here_top)
			seg += 1
			# Register both endpoint corners of this edge at this tile's height.
			for ckey in _edge_corner_keys(here, dir):
				if corner_lo.has(ckey):
					corner_lo[ckey] = minf(corner_lo[ckey], here_top)
					corner_hi[ckey] = maxf(corner_hi[ckey], here_top)
				else:
					corner_lo[ckey] = here_top
					corner_hi[ckey] = here_top
	# Vertical posts wherever the outline steps between heights at a corner.
	for ckey in corner_lo:
		if corner_hi[ckey] - corner_lo[ckey] <= 0.001:
			continue   # outline stays at one height here — nothing to bridge
		_place_range_post(_claim_range_marker(seg), ckey, corner_lo[ckey], corner_hi[ckey])
		seg += 1
	# Hide any strips left over from a previous, larger outline.
	for i in range(seg, _range_markers.size()):
		_range_markers[i].visible = false


## Grow the outline-strip pool until it has a strip at `index`, then return it. Same
## grown-on-demand / hide-leftovers pooling as the path markers, factored out because a
## single boundary edge can now spawn two strips (a top line and a cliff connector).
func _claim_range_marker(index: int) -> MeshInstance3D:
	while index >= _range_markers.size():
		var m := MeshInstance3D.new()
		m.mesh = _range_strip_mesh
		m.material_override = _range_material
		m.visible = false
		add_child(m)
		_range_markers.append(m)
	return _range_markers[index]


## Lay the horizontal top sliver along the `dir` edge of tile `here`, centered on the edge
## line at the tile's surface `top` (lifted a hair to clear the cap). Thin across the edge,
## full tile width along it; an X-facing edge runs along Z, a Z-facing edge along X.
func _place_range_top(marker: MeshInstance3D, here: Vector2i, dir: Vector2i, top: float) -> void:
	var center := tile_to_world(here.x, here.y)
	marker.position = Vector3(
		center.x + dir.x * tile_size * 0.5,
		top + 0.05,
		center.z + dir.y * tile_size * 0.5)
	if dir.x != 0:
		marker.scale = Vector3(_RANGE_BORDER_WIDTH, _RANGE_STRIP_THICKNESS, tile_size)
	else:
		marker.scale = Vector3(tile_size, _RANGE_STRIP_THICKNESS, _RANGE_BORDER_WIDTH)
	marker.visible = true


## The two endpoint corners of tile `here`'s `dir`-facing edge, as keys in the doubled
## integer lattice (a tile center (x, z) is key (2x, 2z); its corners are the odd keys
## one step away). The edge midpoint is the center plus `dir`; its two ends are that
## midpoint plus/minus the perpendicular step. Shared corners get identical keys from
## adjacent tiles, which is what lets the height-step detection in `show_move_range` work.
func _edge_corner_keys(here: Vector2i, dir: Vector2i) -> Array:
	var mid := Vector2i(here.x * 2, here.y * 2) + dir
	var perp := Vector2i(dir.y, dir.x)   # rotate the step 90° to run along the edge
	return [mid + perp, mid - perp]


## Stand a thin vertical post at grid corner `ckey` (a doubled-lattice key), spanning Y
## from `y_low` to `y_high`, to connect outline top-lines that meet there at different
## heights. Thin in both X and Z so it reads as a corner of the line, not a wall/face.
func _place_range_post(marker: MeshInstance3D, ckey: Vector2i, y_low: float, y_high: float) -> void:
	# Halving the doubled key recovers the corner's (half-integer) grid index. We can't
	# reuse `_grid_to_world_x/z` here: they take an `int`, which would TRUNCATE 12.5 to 12
	# and park the post at a tile center. So apply the same centering formula in float.
	var gx := ckey.x * 0.5
	var gz := ckey.y * 0.5
	marker.position = Vector3(
		gx * tile_size - (grid_width - 1) * tile_size * 0.5,
		(y_low + y_high) * 0.5,
		gz * tile_size - (grid_height - 1) * tile_size * 0.5)
	marker.scale = Vector3(_RANGE_BORDER_WIDTH, y_high - y_low, _RANGE_BORDER_WIDTH)
	marker.visible = true


## Hide the move-range outline overlay.
func clear_move_range() -> void:
	for marker in _range_markers:
		marker.visible = false


## Highlight `tile` as the active unit's tile, tinted `color` (the caller picks the
## allegiance hue). Lifted a hair more than the path markers (0.04 vs 0.03) so the two
## never z-fight when they overlap. Call again to move/recolor it; cheap to call every
## frame so the marker can track a walking unit.
func set_active_tile(tile: Vector2i, color: Color) -> void:
	_active_marker_material.albedo_color = color
	_active_marker.position = tile_to_world(tile.x, tile.y) + Vector3(0.0, 0.04, 0.0)
	_active_marker.visible = true


## Hide the active-unit tile highlight (e.g. when there is no active unit).
func clear_active_tile() -> void:
	_active_marker.visible = false


## Ray-pick the tile under a screen point (e.g. the mouse position) using `camera`.
## Returns the tile's (x, z) as a `Vector2i`, or `INVALID_TILE` if the ray misses
## the grid. Heights are handled for free: the ray hits the actual 3D tile
## geometry, so clicking the top of a tall cliff selects that cliff, not a tile
## behind it — which is why we use physics here instead of inverting the math.
##
## Godot note: a camera turns a 2D screen point into a 3D ray via
## `project_ray_origin` (where the ray starts) and `project_ray_normal` (its
## direction). We then ask the physics world for the first body that ray hits and
## read the grid coordinate we stamped onto it in `_build_tiles`.
##
## This is a thin wrapper over `tile_and_face_at_screen_point` (one ray path); it
## drops the face for the many callers that only care which tile was hit.
func tile_at_screen_point(camera: Camera3D, screen_point: Vector2) -> Vector2i:
	return tile_and_face_at_screen_point(camera, screen_point)["tile"]


## Ray-pick the tile AND the face under a screen point.
##
## Returns a dictionary `{ "tile": Vector2i, "face": TileFaces.Face }`. On a miss,
## `tile` is `INVALID_TILE` (and `face` is `TOP`, an unused placeholder) — so a
## caller can keep its existing `tile == INVALID_TILE` check and simply ignore the
## face. This is Layer A of the face work (docs/GAME_DESIGN.md §11): nothing acts on
## the face yet, but picking now reports it so later face-walking has it for free.
##
## The face comes straight from the physics hit `normal` (see `TileFaces.from_normal`),
## so a single collision box per tile is enough — we deliberately did NOT add a
## collider per face (see the 2026-06-27 collision finding in the decision log).
func tile_and_face_at_screen_point(camera: Camera3D, screen_point: Vector2) -> Dictionary:
	var from: Vector3 = camera.project_ray_origin(screen_point)
	var to: Vector3 = from + camera.project_ray_normal(screen_point) * _PICK_RAY_LENGTH

	# The "space state" is the physics world we can run instantaneous queries
	# against from ordinary code (outside the physics step).
	var space := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(from, to)
	var hit := space.intersect_ray(query)

	# `intersect_ray` returns {} on a miss, or a dict with "collider" + "normal"
	# (the world-space surface normal at the hit point) on a hit.
	if hit.is_empty():
		return {"tile": INVALID_TILE, "face": TileFaces.Face.TOP}
	var collider: Object = hit["collider"]
	if collider != null and collider.has_meta("grid_coord"):
		# Which face was struck falls straight out of the hit normal — no extra
		# colliders needed, because the box's six faces have distinct normals.
		var face: TileFaces.Face = TileFaces.from_normal(hit["normal"])
		return {"tile": collider.get_meta("grid_coord"), "face": face}
	return {"tile": INVALID_TILE, "face": TileFaces.Face.TOP}


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


## Set `grid_width`/`grid_height` from the resolved `states` data, so a loaded map's
## own size drives the grid (variable-size maps). States are rectangular `state[x][z]`,
## so width is the number of X columns and height the length of any column. Assumes at
## least one non-empty state — guaranteed here because `_ready` always resolves a map
## (MapData, an assigned `states`, or the SmallDemoMap fallback) before calling this.
func _adopt_dimensions_from_states() -> void:
	grid_width = states[0].size()
	grid_height = (states[0][0] as Array).size()


## Replace the currently-shown map with `data` (a saved `MapData`) and rebuild from scratch.
## The battle coordinator calls this at runtime to load an `Encounter`'s map: the scene's own
## `_ready` already built the fallback demo map (a child readies *before* its parent), so an
## encounter map is loaded by tearing that down and re-running the same resolve → adopt → build
## → render path `_ready` uses. Resets the view to the first state.
##
## (The map designer has its own `EditableBattlefield.load_states` for the nested-form New/Load
## path; this base method is the MapData-driven twin the main game needs and does not touch it.)
func load_map_data(data: MapData) -> void:
	# Free the existing per-tile root nodes (recovered from each tile's `earth` mesh's parent, so
	# no extra bookkeeping is needed). `free()` not `queue_free()` so the new tiles — which reuse
	# the same "Tile_x_z" names — don't transiently collide with the old ones still in the tree.
	for column in _tiles:
		for refs in column:
			var root: Node = refs["earth"].get_parent()
			if is_instance_valid(root):
				root.free()
	_tiles = []

	# Adopt the new data exactly as `_ready` resolves a `map_data` (size + depth mode come from it).
	map_data = data
	states = data.to_states()
	_sculpted_depth = data.depth_mode == MapData.DepthMode.SCULPTED
	_current_index = 0
	_adopt_dimensions_from_states()
	_build_tiles()
	render_state(_current_index)


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

			# A matching colored cap on the UNDERSIDE, so the bottom face can carry its
			# own terrain type independent of the top/sides (see docs/FACES.md — the
			# meta-god reveal's authored underside). Mirrors `surface`; colored in
			# `render_state` via `TileFaces.face_type(tile, BOTTOM)`.
			var bottom := MeshInstance3D.new()
			bottom.mesh = _unit_box
			root.add_child(bottom)

			# An invisible collision box so mouse-clicks can be ray-picked back to
			# this tile (see `tile_at_screen_point`). The body carries its own grid
			# coordinate as metadata, so a ray hit maps straight to (x, z) with no
			# inverse math. Each tile owns its own BoxShape3D resource because the
			# shape is *resized per state* in `render_state` — a shared shape would
			# resize every tile at once.
			var body := StaticBody3D.new()
			body.set_meta("grid_coord", Vector2i(x, z))
			var collision := CollisionShape3D.new()
			collision.shape = BoxShape3D.new()
			body.add_child(collision)
			root.add_child(body)

			column.append({"earth": earth, "surface": surface, "bottom": bottom, "collision": collision})
		_tiles.append(column)


## Draw the state at `index`: rescale and recolor every tile's column + cap to
## match that state's height and type. Because we reuse the tile nodes, a shift
## is just a bulk update of transforms and material overrides. Each tile resolves its
## heights + per-face materials (the cached, shared ones) and hands them to the single
## `_apply_tile_geometry` drawer — the same drawer the cascade morph uses with animated
## values, so the static and animated renders can never disagree about a tile's shape.
func render_state(index: int) -> void:
	var state: Array = states[index]
	for x in grid_width:
		for z in grid_height:
			var tile: Dictionary = state[x][z]
			# The VISIBLE top: a liquid surface is recessed below its integer rim (see
			# `_surface_world_y`), so water reads as a basin. The cap, column, and click box all
			# build from this; `base_y` below still uses integer neighbour heights for the cliffs.
			var surface_top: float = _surface_world_y(state, x, z)
			# The column's UNDERSIDE: only as deep as the lowest adjacent surface (so a side
			# face spans exactly the exposed cliff, not all the way to y=0), with a thin
			# minimum slab on flat ground / borders. A carved-down tile's neighbours are
			# taller, so THEIR underside drops to this tile's top — covering the pit wall.
			var base_y: float = _column_bottom_in(state, x, z)
			_apply_tile_geometry(
				_tiles[x][z], base_y, surface_top,
				_face_material(tile, TileFaces.Face.NORTH),   # body / sides
				_face_material(tile, TileFaces.Face.TOP),     # surface cap
				_face_material(tile, TileFaces.Face.BOTTOM))  # underside cap


## Draw ONE tile's geometry into its `refs` nodes from already-resolved values: the column
## underside `base_y`, the visible `surface_top`, and the three face materials. Stacks a thin
## bottom cap, a body column, and a thin top cap from `base_y` up to `surface_top`, and keeps the
## click box spanning the whole visible block. Factored out of `render_state` so the cascade morph
## (`_draw_shift_tile`) reuses the exact same layout math with interpolated heights/colors.
func _apply_tile_geometry(refs: Dictionary, base_y: float, surface_top: float,
		body_mat: StandardMaterial3D, surface_mat: StandardMaterial3D, bottom_mat: StandardMaterial3D) -> void:
	var total: float = maxf(surface_top - base_y, 0.02)
	# Dividing by 3 reserves room for BOTH caps even on a very short block; a normal block still
	# gets the full `cap_thickness`. The three layers (bottom cap / column / top cap) stack up.
	var cap_h: float = min(cap_thickness, total / 3.0)
	var column_h: float = max(total - 2.0 * cap_h, 0.02)

	# Underside cap: a thin slab at the block's base.
	var bottom: MeshInstance3D = refs["bottom"]
	bottom.scale = Vector3(tile_size, cap_h, tile_size)
	bottom.position = Vector3(0.0, base_y + cap_h * 0.5, 0.0)
	bottom.material_override = bottom_mat

	# A scaled 1x1x1 box: scale.y is the height, scale.x/z the footprint. Position is the box
	# *center*; the column sits ABOVE the bottom cap.
	var earth: MeshInstance3D = refs["earth"]
	earth.scale = Vector3(tile_size, column_h, tile_size)
	earth.position = Vector3(0.0, base_y + cap_h + column_h * 0.5, 0.0)
	earth.material_override = body_mat

	var surface: MeshInstance3D = refs["surface"]
	surface.scale = Vector3(tile_size, cap_h, tile_size)
	surface.position = Vector3(0.0, surface_top - cap_h * 0.5, 0.0)
	surface.material_override = surface_mat

	# Keep the click-collision box in sync with the VISIBLE block ([base_y, top]), so picking stays
	# correct after a shift AND a click on the underside / a side face lands on real geometry.
	var collision: CollisionShape3D = refs["collision"]
	var pick_h: float = max(total, 0.02)
	(collision.shape as BoxShape3D).size = Vector3(tile_size, pick_h, tile_size)
	collision.position = Vector3(0.0, base_y + pick_h * 0.5, 0.0)


## The cached, shared material for a tile's `face` (the steady-state, non-morph material). DIRT
## reuses the one brown `_earth_material`; every other type gets a per-type cached material. This is
## the resolver `render_state` uses; the morph uses per-tile lerp materials instead (`_anim_material`).
func _face_material(tile: Dictionary, face: int) -> StandardMaterial3D:
	var type: int = TileFaces.face_type(tile, face)
	return _earth_material if type == TileTypes.Type.DIRT else _surface_material(type)
