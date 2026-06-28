## One time-state of a map: a full grid of tile heights + terrain types, stored in
## a shape that saves cleanly to a `.tres` file.
##
## Why flat arrays (the key design choice): at runtime `Battlefield` works with the
## map as a *nested* `state[x][z] = { "height": int, "type": int }` structure (see
## `Battlefield.gd`). That nested-array-of-Dictionaries does NOT serialize to a
## readable, diff-able `.tres` — Godot can only persist `@export`ed properties, and a
## ragged nest of dictionaries round-trips badly. So on disk we instead keep two
## **flat** `PackedInt32Array`s (which `.tres` writes as a single compact
## `PackedInt32Array(…)` line): one for heights, one for terrain types, laid out
## row-major in X. `MapData.to_states()` rebuilds the nested form the engine wants.
##
## GDScript note (vs. Python/C++): a `Resource` is Godot's serializable data object —
## think "a struct the engine can save/load and edit in the Inspector." `class_name`
## registers it globally; an instance is normally an `.tres` asset on disk. Here it is
## a *sub-resource* embedded inside a `MapData` (a map owns an ordered list of states),
## the same nesting pattern the recruit `.tres` files already use for their StatBlocks.
class_name MapState
extends Resource

## Flat, row-major tile heights — index `i = x * map_height + z` (see `MapData` for the
## width/height that close over this). Integer "levels", the same units a tile's
## `height` carries at runtime and that `Unit.jump` compares against (not world units).
@export var heights: PackedInt32Array = PackedInt32Array()

## Flat, row-major terrain types parallel to `heights` (same indexing). Each entry is a
## `TileTypes.Type` stored as its backing int. This is the SURFACE/cap type — the tile
## you stand on, which drives both the cap color and gameplay (move cost, liquid, casting).
@export var types: PackedInt32Array = PackedInt32Array()

## Flat, row-major BODY (side) types parallel to `heights` — the column color only
## (cosmetic), letting a tile be e.g. stucco-sided with a slate-roof cap. A `TileTypes.Type`
## per entry. May be empty on maps saved before this field existed; `MapData.to_states`
## then fills in `TileTypes.DEFAULT_BODY` (brown dirt), so old maps look unchanged.
##
## NOTE (per-face terrain — see `TileFaces.face_type`): all four side faces
## (N/S/E/W) share this one `bodies` value today. When sides become independently
## typed, that is an *additive* change — new parallel arrays (`norths`/`souths`/…)
## with the same "absent → fall back to `bodies`" rule — not a reshape of this format.
@export var bodies: PackedInt32Array = PackedInt32Array()

## Flat, row-major BOTTOM (underside) cap types parallel to `heights` — the color of
## the tile's underside, which `Battlefield` draws as a separate cap so the map's bottom
## can be authored independently of its top/sides (the underside of the world; see
## docs/FACES.md and the meta-god reveal in docs/GAME_DESIGN.md §11). A `TileTypes.Type`
## per entry. Same back-compat rule as `bodies`: empty on maps saved before this field
## existed, in which case `MapData.to_states` falls back to the tile's body type, so an
## old map's underside simply matches its sides and nothing changes visually.
@export var bottoms: PackedInt32Array = PackedInt32Array()
