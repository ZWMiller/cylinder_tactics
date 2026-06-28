# Tile faces

The "face work" lets a unit eventually stand on and walk across any face of a tile's
box — not just the top, but the sides and the underside. This is the engine support
behind the meta-god's "walk on the bottom of the map" reveal, which then becomes a
**permanent** part of the battle problem-solving space (see `docs/GAME_DESIGN.md` §11
and the 2026-06-27 decision-log entries).

The work is split into two layers by risk:

- **Layer A — the face *model*** (data, addressing, picking). Cheap, additive, no
  gameplay change. Baked in early so the map/encounter builder is "face-ready" and we
  don't build it twice.
- **Layer B — the face *gameplay*** (gravity re-point along a face normal, per-face
  movement reachability, unit orientation, face-to-face traversal). The deep change to
  the coordinate core. Deferred; it *reads* the Layer A data.

This document covers what exists today (the start of Layer A) and what is deferred.

## Built: `TileFaces` + face-aware picking (Layer A, first slice)

### `scripts/TileFaces.gd`

A static namespace (`class_name TileFaces`, never instantiated), mirroring `TileTypes`:

- `enum Face { TOP, NORTH, SOUTH, EAST, WEST, BOTTOM }` — the six faces. `TOP` is the
  implicit "you stand here" today; the rest are reserved for Layer B. Integer-backed and
  append-only, like `TileTypes.Type`, so any future saved data stays stable.
- `from_normal(world_normal) -> Face` — maps a physics hit normal to a face by its
  **dominant axis + sign** (tiles are axis-aligned boxes, so the normal is ~±X/±Y/±Z).
  Largest-magnitude component wins, which tolerates floating-point noise in the normal.
- `normal(face) -> Vector3` — the inverse (face → outward unit normal). Unused by Layer A;
  it lives here for Layer B's "gravity points into this face" math, next to its inverse.
- `display_name(face) -> String` — for debug prints and any future telegraph/HUD text.

**Axis convention** (matches `Battlefield`'s grid helpers): `+Y` = up = `TOP`; the Z axis
runs along grid rows with `NORTH = -Z` (Godot's `Vector3.FORWARD`); the X axis runs along
grid columns with `EAST = +X`. The N/S/E/W labels are a fixed, consistent naming — they
need not match a real compass, only stay consistent so Layer B can re-point gravity.

### Face-aware picking on `Battlefield`

- `tile_and_face_at_screen_point(camera, screen_point) -> Dictionary` returns
  `{ "tile": Vector2i, "face": TileFaces.Face }`. On a miss, `tile == INVALID_TILE` (and
  `face` is a `TOP` placeholder), so existing `tile == INVALID_TILE` checks keep working.
- `tile_at_screen_point(...)` is now a thin wrapper that returns just `.tile`, so the many
  callers that only want the tile are untouched and there is **one** ray path.

The face comes straight from the physics hit `normal`. This is the key cost-saver: the
existing **single collision box per tile** is enough — its six faces already have distinct
normals, so we did **not** add a collider per face. (See the 2026-06-27 "collision finding"
in `docs/DECISION_LOG.md`.)

Nothing acts on the face yet (gameplay still uses the tile, i.e. `TOP` implicitly), so this
slice is a zero-behavior-change, fully reversible foundation.

## Built: per-face tile types + bottom-cap rendering (Layer A, second slice)

The tile data model and renderer now carry a *type per face*, so the underside (and, later,
each side) can be authored independently — the engine support for the meta-god reveal's
"wrong" underside and walkable faces.

- **`TileFaces.face_type(tile, face) -> int`** is the single resolver from a face to the
  terrain type shown on it. Today: `TOP` → the tile's `type` (also the gameplay surface),
  the four sides → the shared `body`, `BOTTOM` → a new `bottom` field (falling back to
  `body`, then `DIRT`). **Every** renderer/gameplay caller routes through this one function,
  so making N/S/E/W independently typed later is a one-function change plus storage — not a
  reshape.
- **Saved format** (`MapState`/`MapData`): a new `bottoms` flat `PackedInt32Array` parallel
  to `heights`/`types`/`bodies`, with the same "absent → fall back" back-compat rule (a map
  saved before this field loads with its underside matching its sides). Per-side arrays would
  be added the same additive way.
- **Rendering** (`Battlefield`): each tile is now three stacked caps/column — a **bottom
  cap** at the base, the body column, and the top cap — summing to the same height (picking
  unchanged). With `bottom == body` (the default) the underside is invisible, so normal maps
  and battles are visually unchanged; only an *authored* underside differs.
- **Authoring** (map designer): `SURFACE`/`BODY` collapsed into one **face-aware `PAINT`
  tool** — it paints the active type onto whichever face you click (top → surface, side →
  body, underside → bottom), routed by the picked face from `tile_and_face_at_screen_point`.
  To reach the underside the designer camera's `min_pitch` is lowered (scene-local, battle
  unaffected) so you can orbit **beneath** the map; the battle camera keeps its top-down clamp.

Still no *gameplay* on non-top faces — `bottom`/side types are cosmetic until Layer B.

### Verifying it

- **Deterministic:** `from_normal` was checked headless against known ±axis normals (with
  noise) and round-tripped against `normal()` — all six faces map correctly.
- **Interactive (the real Layer A gate):** set `Main._DEBUG_PICK_FACE = true` and hover in
  a battle. Confirm a tall cliff's exposed brown **side** reports `NORTH/SOUTH/EAST/WEST`,
  and that rotating the camera under the map and hovering the underside reports `BOTTOM`.
  If side/bottom picks come back unreliable on tall/occluded geometry, *that* is the signal
  we genuinely need per-face colliders — caught cheaply before anything depends on it.

## Deferred

**Rest of Layer A** (later builder-pass slices): a tile *address* of `(tile, face)` threaded
through unit placements and authored mechanics (defaulted `TOP`, so face-authoring UI is
additive); **independently-typed sides** (N/S/E/W each their own type — the `face_type`
resolver and the flat-array format are already shaped for this additive step).
*(Done in the slices above: bottom-cap rendering + the per-face type model.)*

**Layer B** (the coordinate-core change): gravity re-point along a face normal, per-face
reachability/jump-gating (the BFS assumes one 2D grid + height on one axis today), unit
orientation on a face, and the **traversal model** — walkable-rim (gravity rotates as you
cross an edge) vs. god/ability teleport onto a face — which decides whether reachability
spans faces in one search or treats each face as its own grid. Decide at Layer B kickoff.
