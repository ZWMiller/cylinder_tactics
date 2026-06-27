## Shared vocabulary for the six faces of a tile's box.
##
## This is Layer A of the "face work" (see docs/GAME_DESIGN.md §11 and the
## 2026-06-27 decision-log entry): the *data/identity* of a face, with no gameplay
## attached yet. Today every unit implicitly stands on `Face.TOP`; the other five
## are reserved so that walking on a tile's sides / underside (Layer B: gravity
## re-point + per-face reachability) becomes content, not a coordinate-core rewrite.
##
## Like `TileTypes`, this script declares a `class_name`, so any script can write
## `TileFaces.Face` or `TileFaces.from_normal(...)` without `preload`ing it. It is
## never instantiated — it is purely a namespace for an enum and `static` helpers
## (a C++ namespace of free functions / a Python module of module-level functions).
##
## GDScript note for Python/C++ folks: `extends RefCounted` just gives a concrete
## base; because everything here is `static` we never call `.new()`.
class_name TileFaces
extends RefCounted

## The six faces of a tile's axis-aligned box.
##
## TOP is today's implicit "you stand here"; BOTTOM is the underside we will make
## look intentionally "unfinished"; the four sides are the brown earth cliffs.
##
## GDScript enums are integer-backed (like C++). New faces would be appended at the
## END so any future saved data (which would store the backing int) keeps meaning —
## do not reorder these. The current order is also a convenient grouping: TOP/BOTTOM
## (the ±Y caps) then the four horizontal sides.
enum Face { TOP, NORTH, SOUTH, EAST, WEST, BOTTOM }

## Map a world-space surface normal to the tile face it belongs to.
##
## Tiles are axis-aligned boxes, so a ray that hits one comes back with a normal
## that is essentially ±X, ±Y, or ±Z — we just pick the dominant axis and its sign.
## Using the largest-magnitude component (rather than exact equality) keeps this
## robust against tiny floating-point noise in the physics normal.
##
## Axis convention matches the grid helpers in `Battlefield`: +Y is up (TOP),
## the Z axis runs along grid rows (NORTH = −Z, the lower row index direction),
## and the X axis runs along grid columns (EAST = +X). The N/S/E/W labels are a
## fixed naming for the four sides; they do not need to match a compass, only to be
## consistent so Layer B can re-point gravity per face.
static func from_normal(world_normal: Vector3) -> Face:
	var n := world_normal.normalized()
	var ax := absf(n.x)
	var ay := absf(n.y)
	var az := absf(n.z)
	# Vertical caps dominate first (the common case: standing on / under a tile).
	if ay >= ax and ay >= az:
		return Face.TOP if n.y >= 0.0 else Face.BOTTOM
	# Then the column axis (X) vs the row axis (Z).
	if ax >= az:
		return Face.EAST if n.x >= 0.0 else Face.WEST
	return Face.NORTH if n.z < 0.0 else Face.SOUTH


## The outward unit normal of a face — the inverse of `from_normal`.
##
## Not used by Layer A (the picker only needs `from_normal`), but it is the natural
## companion and Layer B's "gravity points into this face" math will read it, so it
## lives here from the start next to its inverse.
static func normal(face: Face) -> Vector3:
	match face:
		Face.TOP:
			return Vector3.UP
		Face.BOTTOM:
			return Vector3.DOWN
		Face.EAST:
			return Vector3.RIGHT
		Face.WEST:
			return Vector3.LEFT
		Face.NORTH:
			return Vector3.FORWARD  # Godot's FORWARD is -Z, matching NORTH = -Z above.
		Face.SOUTH:
			return Vector3.BACK
	# Unreachable for a valid enum value; satisfies the typed return.
	return Vector3.UP


## Human-readable face name, for debug prints and (later) any HUD/telegraph text.
static func display_name(face: Face) -> String:
	match face:
		Face.TOP:
			return "TOP"
		Face.BOTTOM:
			return "BOTTOM"
		Face.NORTH:
			return "NORTH"
		Face.SOUTH:
			return "SOUTH"
		Face.EAST:
			return "EAST"
		Face.WEST:
			return "WEST"
	return "?"
