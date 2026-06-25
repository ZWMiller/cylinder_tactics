# Battlefield

The terrain grid and the first implementation of the **time-shift** gimmick. Lives in
`scripts/Battlefield.gd` (node) with two supporting scripts. Driven entirely from data
in code, per the project's code-driven workflow.

## Files

| File | `class_name` | Role |
|------|--------------|------|
| `scripts/TileTypes.gd` | `TileTypes` | Shared terrain vocabulary: the `Type` enum + flat colors. Pure `static` namespace. |
| `scripts/Battlefield.gd` | `Battlefield` | Generic, size-agnostic grid engine: holds states, builds tile geometry, renders/cycles. |
| `scripts/maps/DemoMap.gd` | `DemoMap` | One concrete map *configuration*: the 3-state grassland→canyon→desert cycle, generated procedurally. |
| `scripts/maps/MapData.gd` | `MapData` | The **saved map format** (a `Resource`): name + dimensions + an ordered list of states. Round-trips to/from the runtime nested form and saves to `.tres`. |
| `scripts/maps/MapState.gd` | `MapState` | One time-state inside a `MapData`, as two flat `PackedInt32Array`s (heights + types). Sub-resource; never instantiated standalone. |

`class_name` registers each script globally, so they reference each other by name
(e.g. `TileTypes.Type.GRASS`) with no `preload`. None of the three is instantiated as
an object except `Battlefield`, which is a `Node3D` in `scenes/Main.tscn`.

## Data model

- **Tile** — a `Dictionary` `{ "height": int, "type": int }` (`type` is a
  `TileTypes.Type`). A tile carries height *and* type, never just a height — type will
  drive movement cost / casting rules later (see `docs/GAME_DESIGN.md` §7).
  *(Kept as a Dictionary for prototype simplicity; may become a Resource later.)*
- **State** — a 2D grid of tiles indexed `state[x][z]`.
- **`states`** — the ordered list of states. The shift cycles through them and wraps
  (`… → last → 0 → …`). This is the "map is a *sequence* of states" commitment from
  the decision log, realized.

## Coordinates (two systems — don't conflate them)

- **Grid indices** `(x, z)`: integer tile addresses, `0 … width-1` / `0 … height-1`.
  Grid index `(0,0)` is a **corner tile**. The demo hill is anchored here.
- **World coordinates**: meters. The grid is **centered on the world origin**, so the
  *center* tile maps to `(0,0,0)` and the camera (which looks at the origin) frames it.
  Grid corner `(0,0)` therefore sits at a far world corner (≈ `(-11.5, …, -11.5)` for
  24×24), *not* at the origin.

Helpers `tile_to_world(x, z)` and `tile_height(x, z)` convert grid → world and are the
seed of the future shared coordinate-helper module (movement / LoS / combat).

## Rendering (geometry only — no textures)

Each tile is two scaled instances of a single shared 1×1×1 `BoxMesh`:
- a **brown "earth" column** (`TileTypes.EARTH`) for the body/sides, and
- a thin **colored surface cap** (`TileTypes.surface_color(type)`) on top.

Height differences expose the brown column as a dirt cliff; flush neighbors hide their
shared sides. One shared mesh + per-instance scale/`material_override` keeps ~1,150
tile pieces cheap. A tile of height `H` rises `H * height_step` world units.

## Shift API (intentionally small and public)

So the future hold-to-preview view and the time-mage's powers can peek at / nudge the
shift without reaching into internals:

- `current_state()` — the state on screen now.
- `next_state_index()` / `peek_next_state()` — what the next shift will show (this is
  what preview will read), without applying it.
- `advance_shift()` — move to the next state (wrapping) and redraw. *Later* this will
  also re-settle units and apply fall damage; today it only changes terrain.

## Movement: reachability, legality & overlays

The grid owns movement math (it's the coordinate/occupancy authority); `Main` only
snapshots constraints and renders. Heights compare in raw integer *levels* (same units
as a unit's `jump` stat), and each orthogonal step costs 1 `move` point.

- `reachable_tiles(start, move, jump, solid, occupied)` — uniform-cost BFS of every tile
  the unit can reach **and stop on**. A step needs `|Δheight| ≤ jump` and a non-`solid`
  neighbour; `occupied` tiles (any unit) are walked *through* but excluded from the
  result. `solid` = enemy tiles (impassable); `occupied` = all units (can't stop on).
- `classify_path(tiles, move, jump, solid, occupied)` — per-tile blue/red legality for a
  concrete expanded path (over-budget / jump-too-tall / into `solid` / final tile
  `occupied` → illegal, and everything after a failure too). Drives both the preview and
  the commit gate (any `false` ⇒ move refused).
- `show_move_range(reachable)` / `clear_move_range()` — draws the reachable region as a
  black **outline**: horizontal top-lines on edges facing outside the region, plus thin
  vertical **corner posts** wherever the outline steps between heights (so it follows
  terraces continuously). Corners are tracked in a doubled-integer lattice.
- `show_path(tiles, legal_flags)` / `clear_path()` — the path preview; blue legal tiles,
  red illegal ones (per `classify_path`).

## Saved map format (`MapData` / `MapState`)

The persistent, on-disk twin of the procedural `DemoMap` — what the map designer writes
and what `Battlefield` can load. A **`MapData`** resource carries `map_name`, its own
`width`/`height`, and `states: Array[MapState]` (the shift sequence). A **`MapState`**
stores one state as two flat `PackedInt32Array`s — `heights` and `types` — laid out
row-major in X (`index = x * height + z`).

- **Why flat arrays:** Godot only serializes `@export`ed properties, and the runtime
  nested `state[x][z] = {height, type}` form (a ragged nest of Dictionaries) round-trips
  to an ugly, un-diff-able `.tres`. Flat `PackedInt32Array`s write as one compact line
  each, so a saved map is small and reviewable in git.
- **Bridging the two forms:** `MapData.to_states()` rebuilds the nested form the engine
  uses; `MapData.from_states(states, name)` packs the nested form back into a `MapData`
  (how `DemoMap` output or the designer's grid becomes saveable). The two share the
  `index = x * height + z` convention so they never disagree about which cell an index
  names.
- **Save/load:** `data.save_to("res://assets/maps/foo.tres")` returns an `Error`;
  `MapData.load_from(path)` returns the map or `null` if missing / wrong type. Authored
  maps live under `res://assets/maps/`.

## Configuration

Inspector-exported on the `Battlefield` node: `map_data` (optional `MapData` to load),
`grid_width`, `grid_height`, `tile_size`, `height_step`, `cap_thickness`.

**Maps are variable-size.** The map source is resolved in `_ready()` in priority order:
an assigned **`map_data`** resource → a directly-assigned **`states`** array → the
built-in **`DemoMap`** fallback. Once a map is resolved, `_adopt_dimensions_from_states()`
overwrites `grid_width`/`grid_height` with that map's actual size — so those two exports
now only size the *DemoMap fallback*; a loaded map's own dimensions win. To use a
different map: assign a `MapData` (`.tres`) to `map_data`, assign `states` before the node
enters the tree, or swap the `DemoMap.generate(...)` call in `_ready()`.

## The demo map (3 states)

0. **Grassland** — flat grass with a hill rising from grid corner `(0,0)`.
1. **Canyon** — a river has carved a channel diagonally from the hill across the
   grassland; channel tiles are sunk to the canyon floor and turned to water, so the
   cut through the hill shows tall brown walls.
2. **Desert** — all sand, the hill lower and spread out, the river now a dry stone
   riverbed sunk below the sand.

All three are generated procedurally from parameters in `DemoMap.gd` (hill falloff,
river path, etc.) rather than hand-authored, so 1,728 tiles cost no hand-typing.

## Running it

Press **F5** in the editor. Press **Space / Enter** (`ui_accept`) to advance the
time-shift and cycle through the three states; the console prints the new state index.
This key-driven shift is placeholder driving for the prototype — the real shift will be
tied to the turn counter once the turn loop exists.

**Camera** (`scripts/CameraController.gd`, on the `Camera3D` node): an orbiting
orthographic rig that always looks at the world origin.
- **Mouse wheel** — zoom in / out (changes ortho `size`)
- **Q / E** — orbit left / right
- **Middle-mouse drag** — free orbit (yaw + pitch)

Aimed in code via `look_at`, not a hand-authored transform, per the project's
camera convention. Speeds, zoom/pitch clamps, and the starting angles are exported
on the node for tweaking in the Inspector.
