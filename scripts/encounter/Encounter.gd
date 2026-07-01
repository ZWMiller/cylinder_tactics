## A saved BATTLE: which terrain map to fight on, which enemies stand where, and the tile
## regions that define deployment + victory. This is the "encounter builder" output — the
## authored fight the designer saves and the battle engine quick-loads to playtest.
##
## Design stance (settled 2026-06-30, see docs/DECISION_LOG.md): an `Encounter` is a PURE
## NAMED DATA BAG, never logic. The code owns the data, not the other way round — a per-battle
## script (a plain fight uses the generic `BattleBase`; a scripted fight is `Battle5 extends
## BattleBase`) LOADS an `Encounter`, reads its named parts into variables, spawns from them,
## and holds any reactive behavior (dialogue, moving objectives, puzzles) itself. So there is
## deliberately NO "battle_script" field here: the reference points script → data. What makes
## the bag script-friendly is that everything is addressable by NAME — enemies carry an `id`,
## and tiles are grouped into NAMED regions — so a script can grab exactly the piece it wants.
##
## Terrain lives in a SEPARATE `MapData` .tres referenced by `map_path`, not embedded, so one
## map is reusable across many encounters and `MapData`/`Battlefield` stay untouched. This is
## the concrete first cut of the planned `Encounter` resource (see docs/TODO.md "toward a
## reusable Battle.tscn").
class_name Encounter
extends Resource

## Well-known region names (keys into `regions`). Conventions, not a closed set — a script may
## define its own regions ("shrine", "levers", …) and read them by name; only these two are
## interpreted by the generic loader/win-check.
const REGION_DEPLOY := "deploy"   ## where the player's party may start (their deploy zone)
const REGION_WIN := "win"         ## reach-to-win objective tiles (see `has_win_region`)

## `res://` path to the terrain `MapData` this fight is on. The battle loads it via
## `MapData.load_from(map_path)`. Empty means "no map chosen yet" (an incomplete encounter).
@export var map_path: String = ""

## The enemies to spawn, each a self-describing `EnemyPlacement` (tile + class + level). Order
## is not significant. Players are NOT stored here — they come from the party/`PartyLoadout` and
## deploy into the `REGION_DEPLOY` region.
@export var enemies: Array[EnemyPlacement] = []

## Named tile-regions: `String` name → flat `PackedInt32Array` of `[x0,z0, x1,z1, …]` pairs.
##
## Why flat int pairs (not `Array[Vector2i]`): same reason `MapState` stores flat arrays — a
## `PackedInt32Array` serializes to one compact, diff-able line in the `.tres`, whereas a nested
## array of `Vector2i` round-trips messily. Use `region()` / `set_region()` to work in `Vector2i`
## and let this handle the packing. `REGION_DEPLOY` and `REGION_WIN` are the interpreted keys;
## any other key is free for per-battle scripts.
@export var regions: Dictionary = {}


## Return region `name` as a list of tile coordinates (empty if the region is absent). Unpacks
## the flat `[x,z,x,z,…]` storage back into `Vector2i`s for callers that think in tiles.
func region(name: String) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var flat: PackedInt32Array = regions.get(name, PackedInt32Array())
	var i := 0
	# Step in pairs; a trailing odd int (shouldn't happen) is ignored by the `i + 1` guard.
	while i + 1 < flat.size():
		out.append(Vector2i(flat[i], flat[i + 1]))
		i += 2
	return out


## Store `tiles` (an array of `Vector2i`) under region `name`, packing to the flat form. Used by
## the designer when the player paints/edits a deploy or objective region.
func set_region(name: String, tiles: Array) -> void:
	var flat := PackedInt32Array()
	for t in tiles:
		flat.append(int(t.x))
		flat.append(int(t.y))
	regions[name] = flat


## True if this encounter defines any victory tiles — i.e. its win condition includes
## "an ally reaches the objective", not just "defeat everyone". Drives the battle's win check:
## with a win region, reaching it (or a full wipe) wins; without one, it's elimination-only.
func has_win_region() -> bool:
	var flat: PackedInt32Array = regions.get(REGION_WIN, PackedInt32Array())
	return flat.size() >= 2


## Save this encounter to `path` (e.g. `res://assets/encounters/node5.tres`). Returns an `Error`
## (`OK` on success). Thin wrapper over `ResourceSaver` so every save goes through one place,
## mirroring `MapData.save_to`.
func save_to(path: String) -> Error:
	return ResourceSaver.save(self, path)


## Load an `Encounter` from `path`, or `null` if it is missing / not an `Encounter` — the caller
## then falls back (e.g. the legacy demo battle) instead of crashing. Mirrors `MapData.load_from`.
static func load_from(path: String) -> Encounter:
	if not ResourceLoader.exists(path):
		return null
	return load(path) as Encounter
