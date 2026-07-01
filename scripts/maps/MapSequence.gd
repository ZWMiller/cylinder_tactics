## An ordered CHAIN of terrain maps plus the cadence between them — the time-degradation loop
## (see docs/GAME_DESIGN.md §4) expressed as separate, individually-authored `MapData` files rather
## than hidden internal states of one file. A battle loads the first map, then every `turns_after`
## character turns the shift transitions to the next; the last entry wraps back to the first.
##
## This is the terrain-over-time layer, sitting between `MapData` (one snapshot) and `Encounter` (a
## fight ON a sequence): it references maps by `res://` path and knows nothing about units. It is a
## SEPARATE, reusable resource saved to `assets/sequences/` — different encounters can point at the
## same chain, the same way many encounters can reuse one `MapData`.
##
## Sizes may DIFFER between maps in the chain (a map that grows or crumbles over time — a deliberate
## escalation). When they do, consecutive maps are aligned by each entry's **anchor corner** (which
## corner stays pinned across the transition), so the size change appears/vanishes on the opposite
## side and any unit left on a vanished tile falls. NOTE: this variable-size RUNTIME shift (live grid
## resize + anchored morph + stranded-unit falloff) is a DEFERRED feature — see docs/TODO.md. Until
## it lands, chains are practically same-size (the battle loads `maps[0]`, and the builder only
## *warns* — via `is_uniform_size()` — on a difference rather than blocking it). The anchor is
## authored now so the format is ready and no encounters need re-saving when the runtime arrives.
##
## Storage: PARALLEL packed arrays (compact, diff-able `.tres`, the `MapState` rationale) sharing one
## length — `maps[i]` shifts to `maps[i+1]` after `turns_after[i]` turns, aligned by `anchors[i]`.
## Mutate through the helpers so the arrays never desync.
class_name MapSequence
extends Resource

## Which corner of a map stays PINNED across a size-changing transition (the alignment origin). In
## grid coords x increases east and z increases south, so: NW = (0, 0), NE = (max x, 0),
## SW = (0, max z), SE = (max x, max z). Stored per entry as the enum's backing int; default NW.
## Only consulted by the (deferred) variable-size shift; ignored while a chain is uniform-size.
enum Corner { NW, NE, SW, SE }

## Default per-transition cadence (character turns) for a newly-added map — the current global shift
## speed. The Encounter Builder seeds each new entry with this; the author can retune it.
const DEFAULT_TURNS_AFTER := 10

## Ordered `res://` paths of the chain's `MapData` files. `maps[0]` is where the battle starts.
@export var maps: PackedStringArray = PackedStringArray()

## Per-entry cadence, parallel to `maps`: `turns_after[i]` = character turns on `maps[i]` before the
## shift moves to the next (the last wraps to the first). Kept the same length as `maps`.
@export var turns_after: PackedInt32Array = PackedInt32Array()

## Per-entry alignment corner (a `Corner` value), parallel to `maps` — the corner pinned when this
## map's size differs from its neighbour's. Defaults to `NW` for every added map. Unused until the
## variable-size runtime shift lands.
@export var anchors: PackedInt32Array = PackedInt32Array()


## How many maps are in the chain. Length 0 = unfilled; 1 = a static battle (never shifts);
## ≥ 2 = a real time-degradation loop.
func size() -> int:
	return maps.size()


## True if this chain actually shifts (two or more maps). A single-map sequence stays static.
func is_multi() -> bool:
	return maps.size() >= 2


## The `res://` path of the map the battle starts on (`maps[0]`), or `""` if the chain is empty.
func first_map_path() -> String:
	return maps[0] if maps.size() > 0 else ""


## Append `path` to the chain with a cadence + anchor corner (defaults), keeping all three arrays in
## step. Used by the builder's MAPS area. Does NOT validate size — the caller decides whether to warn
## (a size difference is allowed; the runtime just doesn't animate it yet).
func add_map(path: String, turns: int = DEFAULT_TURNS_AFTER, anchor: int = Corner.NW) -> void:
	maps.append(path)
	turns_after.append(turns)
	anchors.append(anchor)


## Remove the entry at `index` from all three arrays, a no-op if out of range. Used by the builder.
func remove_at(index: int) -> void:
	if index < 0 or index >= maps.size():
		return
	maps.remove_at(index)
	turns_after.remove_at(index)
	anchors.remove_at(index)


## True if every map in the chain is the same grid size (so the current same-size runtime shift can
## play it), or trivially true for a 0/1-map chain. Loads each `MapData` to compare `width`/`height`
## against the first; a missing/unloadable map counts as non-uniform. The Encounter Builder calls
## this to WARN (not block) when a mismatched map is added, until the variable-size shift exists.
func is_uniform_size() -> bool:
	if maps.size() < 2:
		return true
	var first := MapData.load_from(maps[0])
	if first == null:
		return false
	for i in range(1, maps.size()):
		var m := MapData.load_from(maps[i])
		if m == null or m.width != first.width or m.height != first.height:
			return false
	return true
