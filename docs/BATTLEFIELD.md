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

## Configuration

Inspector-exported on the `Battlefield` node: `grid_width`, `grid_height` (default
24×24, no upper limit), `tile_size`, `height_step`, `cap_thickness`. To use a different
map, assign `Battlefield.states` before the node enters the tree, or swap the
`DemoMap.generate(...)` call in `_ready()`. With `states` left empty it falls back to
`DemoMap`.

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
