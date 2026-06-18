## Shared vocabulary for terrain tiles: the set of terrain types and the flat
## colors used to draw them in the geometry-only prototype.
##
## This script declares `class_name TileTypes`, which registers it as a global
## name across the whole project — any other script can write `TileTypes.Type`
## or `TileTypes.surface_color(...)` without `preload`ing this file. It is never
## instantiated; it is used purely as a namespace for an enum and `static`
## helpers (similar to a C++ namespace of free functions, or a Python module of
## module-level constants/functions).
##
## GDScript note for Python/C++ folks: `extends RefCounted` just gives us a
## concrete base; because everything here is `static` we never call `.new()`.
class_name TileTypes
extends RefCounted

## The kinds of terrain a tile can be. A tile's *type* is gameplay data, not just
## a paint color: water is intended to impede movement / block casting later (see
## docs/GAME_DESIGN.md §7). For now the type only drives the surface color.
##
## GDScript enums are integer-backed (like C++), so we store `Type.GRASS` as an
## int inside each tile dictionary.
enum Type {
	GRASS,  ## Walkable grassland — the default surface.
	WATER,  ## River / canyon water. Intended to impede movement & block casting later.
	SAND,   ## Desert sand — the degraded-time end state.
	STONE,  ## Bare rock, e.g. a dried-out riverbed.
	ROAD,   ## Paved path (unused by the demo map yet; reserved).
}

## The color used for the *exposed sides* of every tile — the "earth" beneath the
## surface. Drawing tile columns in this brown makes height differences read as
## dirt cliffs without needing any textures (see docs/GAME_DESIGN.md §7).
const EARTH := Color(0.40, 0.28, 0.18)

## Return the flat surface color for a given terrain `type`.
##
## Centralizing the palette here means the map generator and the renderer can
## never disagree about what "water" looks like. Returns magenta as a loud
## "unmapped type" signal rather than failing silently.
static func surface_color(type: int) -> Color:
	match type:
		Type.GRASS:
			return Color(0.30, 0.55, 0.32)
		Type.WATER:
			return Color(0.20, 0.42, 0.80)
		Type.SAND:
			return Color(0.85, 0.78, 0.50)
		Type.STONE:
			return Color(0.50, 0.50, 0.53)
		Type.ROAD:
			return Color(0.38, 0.38, 0.40)
		_:
			# Unmapped type: return an obvious debug color instead of crashing.
			return Color.MAGENTA
