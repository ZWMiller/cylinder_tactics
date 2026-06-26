# Map Builder & Terrain Implementation Plan

**Working branch:** `update-maps-and-tiles` (cut from `main`).
**Purpose of this doc:** a self-contained pickup point so we can continue the map/terrain
work cold, without re-discussing the ideas. Read this, then skim the linked docs
(`BATTLEFIELD.md`, `TODO.md` "Map & tiles overhaul", `DECISION_LOG.md`).

---

## 1. Why we're doing this

Playtesting felt off because the demo map is a giant 24×24 field with cosmetic-only
terrain. The goal of this effort: **smaller, more interesting maps with terrain that
actually affects gameplay**, plus a **visual in-game map designer** so authoring maps is
fast and customizable instead of tuning procedural constants.

Owner's high-level wants (captured from the conversation):
- Shrink maps; make them interesting; real terrain types.
- A map designer to build maps by sight and save them to a file — supporting **new file**,
  **load existing to edit**, and **save**.
- Terrain types carry gameplay: **movement cost**, **casting legality**, **liquids you sink
  into**, and **line-of-sight / projectile collision**.
- Two-layer tiles (a building body with a different-colored roof on top).

---

## 2. The agreed sequence (the spine)

The **saved map format is the linchpin**: once it exists, variable size falls out, the
designer is "draw → save", and authoring maps is visual.

1. ✅ **Map format + load/save + variable size** — DONE (commit `2b53438`).
2. ✅ **Terrain property table + two-layer tiles** — DONE (commit `aca6e55`).
3. 🔄 **Map designer** — Phase 1 DONE (see §5). §6 fixes #1–#4 all DONE (editable size+name,
   swatch bar, FileDialog size + project-wide UI scale, full cliff-face grid outline). Next:
   **Phase 2 (brushes, §9)**, then **Phase 3 (Encounter layer — place enemies / start zone /
   win tiles, §10)** which turns the map designer into an *encounter builder*, then **Phase 4
   (multi-state, §11)**.
4. ⬜ **Wire terrain gameplay** — move cost / casting / hazard / liquid depth (see §7).
5. ⬜ **Line-of-sight + projectile collision** (see §8).
6. ⬜ **Author new demo maps** in the designer; retire the procedural 24×24 cycle.

Do NOT leapfrog to the run-loop / roguelite work (`TODO.md` "After the single battle is
fun") — that's gated behind this and the combat being fun.

---

## 3. What's already built & committed

### Saved map format (`scripts/maps/`)
- **`MapData`** (`class_name MapData extends Resource`): `map_name`, `width`, `height`,
  `states: Array[MapState]`. Methods:
  - `to_states()` → runtime nested form `Array` of `grid[x][z] = {height, type, body}`.
  - `static from_states(states, name)` → pack nested form into a MapData.
  - `save_to(path)` → `Error` (wraps `ResourceSaver`); `static load_from(path)` → MapData|null.
- **`MapState`** (sub-resource): one time-state as **three flat `PackedInt32Array`s** —
  `heights`, `types` (surface/cap), `bodies` (side). Row-major index `i = x * height + z`.
  Flat arrays chosen because nested dicts serialize to ugly, un-diffable `.tres`.
- **`Battlefield`** gained an optional `@export var map_data: MapData` (wins over a
  directly-assigned `states`, which wins over the `DemoMap` fallback) and
  `_adopt_dimensions_from_states()` — **grid size now comes from the data**, so maps are
  variable-size. Existing behavior unchanged when no map is assigned.
- Verified end-to-end (generate → save → load → deep-compare): round-trips exactly.

### Terrain vocabulary + two-layer tiles (`scripts/TileTypes.gd`)
- **Single source-of-truth property table** keyed by `Type`, each row:
  `color`, `move_cost` (default 1; liquids 2), `liquid` (bool), `can_cast` (bool),
  `hazard` (int — **reserved, not yet read**; lava=2 placeholder, tune later).
  Accessors: `surface_color`, `is_liquid`, `move_cost`, `can_cast`, `hazard_damage`.
- **Types:** `GRASS, WATER, SAND, STONE, ROAD` (originals) + appended `DIRT` (default body),
  `LAVA`, `BUILDING`, `BUILDING_STONE`, `ROOF`, `QUICKSAND`. Liquids = water/lava/quicksand.
  **Append new types at the END** (saved maps store the backing int).
- **Two-layer tiles**: a tile is `{height, type, body}`. `type` = surface/cap (drives the
  top color AND all gameplay); `body` = column/side color only (cosmetic), default `DIRT`.
  Lets one tile be stucco walls (`body=BUILDING`) + slate roof (`type=ROOF`).
  **Gameplay always reads the surface `type`, never `body`.**
- `Battlefield.render_state` colors the column by body (`DIRT` reuses the shared brown
  material; other bodies use the cached per-type material). `DemoMap` updated: desert sand
  uses `body=SAND`; everything else `body=DIRT`.

### Map designer — Phase 1 (this session, **uncommitted at time of writing → committing now**)
See §5 for the full description.

---

## 4. Key architecture decisions (so we don't relitigate)

- **Map format = custom Godot Resource (`.tres`)**, not JSON. Idiomatic, inspector-editable,
  one-line load. Compact via flat `PackedInt32Array`s.
- **Designer reuses `Battlefield` via a subclass, NOT a standalone renderer.** The designer
  must be WYSIWYG — what you paint must look exactly like a battle (same two-layer columns,
  height scaling, picking). A second renderer would drift (e.g. when we add liquid sink-in).
  Resolution: **`EditableBattlefield extends Battlefield`** adds all editing methods and only
  *calls* existing base methods — **`Battlefield.gd` is untouched**. Battle scenes use the
  base class / a different instance, so they're literally unaffected. (Owner explicitly asked
  this be a deliberate choice — it is. Logged in `DECISION_LOG.md`.)
- **Two-layer tiles (body + cap), not a full vertical block stack.** Handles the
  building+roof case with a contained change; full N-block stacking was judged overkill for
  the geometry prototype.
- **Designer is an in-game scene** (run with F6), not a Godot `EditorPlugin` — simpler API,
  reuses runtime rendering, fits the learning project.
- **Single-state first** for the designer; multi-state (shift-sequence) editing is later.

---

## 5. Map designer Phase 1 — what exists now

**Files:**
- `scenes/MapDesigner.tscn` — root `Node3D` (MapDesigner.gd) + WorldEnvironment +
  DirectionalLight3D + Camera3D (CameraController). The editable field is created in code
  (so we don't build the throwaway 24×24 DemoMap first).
- `scripts/mapdesigner/EditableBattlefield.gd` (`extends Battlefield`):
  - `load_states(new_states)` — replace/rebuild for New/Load/resize (frees old tile roots via
    `earth.get_parent()`, then base build+render).
  - `set_tile(x,z,height,type,body)` — write one tile + redraw current state.
  - `set_tiles(edits)` — batch write, redraw ONCE (the efficient path the **brushes** will use).
  - `tile_data(x,z)` — read a COPY of `{height,type,body}` (empty if off-grid).
  - `redraw()` — re-render current state.
  - **Grid overlay**: overrides `render_state` to draw a dark line around every tile's top
    edge (a single `PRIMITIVE_LINES` ArrayMesh, rebuilt each render). Makes tiles + height
    steps readable despite the shared flat color. Designer-only.
- `scripts/mapdesigner/MapDesigner.gd` (`extends Node3D`): the interaction layer.
  - Tools: `Tool { HEIGHT, SURFACE, BODY }`; **Tab** cycles.
  - Active paint type from `PALETTE` (all 11 types); **`[` / `]`** cycle, **`1`–`0`**
    quick-pick first ten.
  - Paint on click: HEIGHT — L raise / R lower (one level, clamped 0–20); SURFACE/BODY —
    L paints active type. Routed through per-tile calls now; **brushes will compute a tile
    SET and call `set_tiles`**.
  - Hover cursor reuses `Battlefield.set_active_tile`.
  - **`N`** new (hardcoded 10×10 grass), **`S`** save (FileDialog), **`L`** load (FileDialog).
    Saves to `res://assets/maps/*.tres`.
  - HUD: a `CanvasLayer` → dark translucent `PanelContainer` → 28px white `Label` with the
    tool/type/help text.

**Confirmed working** by the owner; a real `assets/maps/wall_moat_test.tres` was saved
(walls, a moat, water/stone/road types, two-layer bodies) and the `.tres` is clean.

---

## 6. ⭐ START HERE TOMORROW — the requested fixes

1. ✅ **Editable map size + name** — DONE.
   - **New-map dialog** (`N`): an `AcceptDialog` with a name `LineEdit` + width/length
     `SpinBox`es (1–64), prefilled with the current map's name/size. Confirming builds a
     fresh flat grid. **Rename dialog** (`R`): name-only `AcceptDialog` that rewrites
     `_map_name` (written into the `.tres` on save) without touching tiles.
   - **Live resize via a new `RESIZE` tool** (joins the Tab cycle HEIGHT/SURFACE/BODY/RESIZE).
     Hover an edge tile: **L-click adds**, **R-click deletes** that row/column. **Corners do
     BOTH touching sides at once** (grow/shrink the whole map fast). WYSIWYG hover preview:
     a translucent **green ghost** row/column appears just beyond the edge (mirrors the edge
     tile's height so terrain continues) = what L adds; a translucent **red overlay** on the
     edge row = what R deletes. Both shown together, so the one tool needs no separate
     add/delete mode. A shrink that would drop a dimension below 1 is refused.
   - Implementation: `EditableBattlefield` gained `sides_at` / `grow_sides` / `shrink_sides`
     (→ the `_resize(dx_min,dx_max,dz_min,dz_max)` core: rebuilds **every** state, added
     tiles clamp-copy the nearest surviving tile to mirror the edge/corner, dropped tiles
     cropped) + `show_resize_preview` / `clear_resize_preview` (lazily-built, pooled green
     ghost boxes + red decals, same grown-on-demand/hide-leftovers pattern as the base
     overlays). `MapDesigner` added the `RESIZE` tool branch, `_apply_resize`, the two
     dialogs, and a `_dialog_open()` guard that suspends hover/hotkeys while a dialog is up.
   - **Verify in the designer (F6):** New at a custom size/name; rename; RESIZE tool grow/
     shrink each edge and a corner; confirm the green ghost mirrors terrain and the red
     overlay marks the doomed row; save → reload and check the size/name round-trip.

2. ✅ **Swatch/palette bar (ARPG skill-bar style)** — DONE.
   - A horizontal bar across the top (`MapDesigner._build_swatch_bar`): one clickable colored
     `Panel` per PALETTE type (color = `TileTypes.surface_color`), captioned with its
     number-key label ("1"–"9", "0", and "[ ]" for QUICKSAND, which has no digit). **Selectable
     two ways — click the swatch OR press its number key** (both route through `_select_type`).
     The active type gets a bright thick border; `_refresh_swatches` recolors each swatch's own
     StyleBoxFlat. The bar spans the top but has `MOUSE_FILTER_IGNORE` so only the swatches
     catch clicks (painting near the top still works); each swatch is `STOP` so its click
     doesn't leak to the paint handler. Hovering a swatch shows the type name as a tooltip.

3. ✅ **Save/Load FileDialog readability + a project-wide UI scale fix** — DONE.
   - Root cause was bigger than the dialog: the project had **no stretch mode**, so the whole
     2D UI rendered at fixed native pixels and shrank on displays larger than the 1920×1080
     base. Fixed globally in `project.godot`: `display/window/stretch/mode="canvas_items"` +
     `aspect="expand"`. Now the UI scales with the window from the 1080p base (3D stays native;
     mouse-picking unaffected — everything stays in base-space coords). **This also scales the
     battle/Loadout HUDs — eyeball them (F5).**
   - Designer fonts **centralized** into `FONT_HUD` / `FONT_SWATCH` / `FONT_DIALOG` constants
     (tune in one place) and bumped. The four dialogs share one `Theme` whose `default_font_size`
     enlarges ALL their text at once — including the FileDialog file list / buttons we can't
     reach per-control. FileDialogs got `min_size = 900×620` and `popup_centered(1000×680)`
     instead of the tiny `popup_centered_ratio(0.6)`.

4. ✅ **Grid outline extended to EVERY visible edge (always-on in the builder)** — DONE.
   - `_rebuild_grid_overlay` now, in addition to the 4 top-square edges, drops a **vertical
     post at the two corners of each side that DROPS** — i.e. where the tile is taller than its
     orthogonal neighbour (`top - neighbour_top > 0`), or at the grid border (neighbour treated
     as ground, so the outer walls outline down to y≈0). Each post runs from the neighbour's
     top up to this tile's top; combined with the neighbour's own top square (its bottom edge)
     this fully boxes in the cliff face. Only the *taller* side draws (the shorter neighbour
     skips it). Posts are accumulated per UNIQUE vertical edge (`_add_post`, keyed by corner +
     height span quantised to mm) and merged across faces, then each is nudged a hair OUTWARD
     along the SUMMED face normal (`_GRID_FACE_OFFSET`) so it floats just in front of the
     column instead of z-fighting on the exact corner. Two subtleties this handles: a flush
     seam (two coplanar faces) merges to one straight-out nudge so the seam line is visible
     (was z-fighting away); a convex block corner (two perpendicular faces) merges to ONE
     diagonal post instead of splitting into a double line. Depth testing stays ON, so
     back-side posts are still correctly occluded (x-ray was tried and rejected — it revealed
     lines behind hills). Still one `PRIMITIVE_LINES` ArrayMesh.
   - SEPARATE (main game, not the builder): a player **view setting to toggle the grid on/off
     in battle** — see TODO.md. Different feature; don't conflate with the builder's.

---

## 7. Next: wire terrain gameplay (after the designer fixes)

Read the property table (already authored in `TileTypes`) in actual play:
- **Movement cost**: `reachable_tiles` / `find_path` / `classify_path` currently charge a
  flat 1 per step (`Battlefield.gd`). Change to charge `TileTypes.move_cost(neighbor.type)`
  per entered tile (BFS becomes uniform-cost → needs a priority/Dijkstra-ish flood, or keep
  small int costs and a bucketed BFS). Liquids cost 2. Watch the existing `move_points`
  budget + the path legality classifier; both must agree.
- **Casting legality**: in the attack/spell phase, block casting when the caster stands on a
  `not TileTypes.can_cast(type)` tile (liquids). Surface a message like the existing
  "Not Enough MP" toast.
- **Hazard damage**: apply `TileTypes.hazard_damage(type)` (lava=2) on entering / ending a
  turn on the tile. Decide on-enter vs on-turn-start. Reserved field already exists.
- **Liquid depth (sink-in)** — owner specifically wants this: render a liquid tile's surface
  **recessed** and place the unit's cylinder **inside** it (lowered Y) so it reads as standing
  *in* water, not on top. A single global sink-depth constant to start (revisit per-type:
  quicksand deeper than water). Touches tile rendering (`render_state`) + unit placement
  (`tile_to_world` / wherever units get their standing Y). Since gameplay reads the surface
  type and `is_liquid`, the hook is clean.

---

## 8. Then: line-of-sight + projectile collision

- Tall terrain should **block** arrows/fireballs and targeting. This is a **height-based**
  geometric check between attacker and target (NOT a per-type property — a height-5 grass
  column blocks just like a building). Add a grid/height LoS test; projectiles
  (`scripts/Projectile.gd`) and the attack-target validation respect it.
- Most novel/complex chunk; its own step. Consider a Bresenham-style march over the line of
  tiles comparing intervening heights to the attacker/target line.

---

## 9. Phase 2 designer — the brush system (owner's detailed ask)

After the §6 fixes, build the brush macros. Owner wants:
- **Brush shapes**: `Single`, `Square` (N×N), `Circle` (radius N), `Line` (drag A→B), and a
  **Hill** macro (click + drag UP creates a dome of configurable width N with height
  **falloff** from the center). Possibly more later.
- **Configurable brush size N** (per-tool where it applies).
- **Click-and-drag height** alongside the L/R single-click raise/lower (drag vertically to
  raise/lower the whole footprint; Hill uses drag distance for peak height).
- Implementation seam already in place: `MapDesigner` should compute the affected **tile
  set** (or a tile→height-delta map for Hill) from the brush shape+size centered on the
  hovered tile, then apply via `EditableBattlefield.set_tiles(edits)` (one redraw). The Hill
  brush is special: per-tile target height depends on distance from center (reuse the
  falloff idea from `DemoMap._hill`).

---

## 10. Phase 3 designer — the Encounter layer (turn the map builder into an Encounter Builder)

**Owner's ask (2026-06-25):** the saved map should carry not just the *terrain* but the
*fight* — author the whole encounter visually in the designer, save it, then quick-load it
into the existing battle engine to playtest. This is expected to make designing fights *much*
faster ("place things how I want, save, go test"). It also becomes the visual front-end for
the planned `Encounter` resource (see `TODO.md` "toward a reusable `Battle.tscn`").

**What you place (new editing "layers" on top of terrain painting):**
1. **Enemy units** — drop an enemy on a tile, then edit its spec: **class / weapon type**,
   **armor type**, **level**, and **per-stat overrides** (specific HP / MP / Speed / Move, and
   likely others — absolute or delta on top of the rolled/class block). Allegiance = enemy.
2. **Named characters / bosses** — place a *specific authored* character instead of a rolled
   enemy (e.g. a boss). Boss *creation* is a later system; for now a placement references a
   named id / `Recruit`. Ties to the existing `Recruit` / `ClassDef` / `StatRoll` data and the
   planned `Boss extends Unit`.
3. **Player start zone** — paint a set of tiles marking where the player may deploy. Later the
   pre-battle flow lets the player choose each character's start tile *within* this zone.
4. **Battle-end / objective tiles** — paint tiles that end the battle as a **win if any player
   unit reaches one** (reach-the-goal objective, so the win condition isn't always "defeat
   everyone"). Keep it extensible — later: escort / survive-N-turns / etc.

**⭐ The key decision to settle when we start (data model):** today `MapData` = pure terrain
(states). The encounter adds placements. Options:
- **(A)** extend `MapData` to also hold the encounter (enemy placements, start zone, end tiles)
  — matches the owner's "the map state contains the encounter build" framing; one file.
- **(B)** a separate **`Encounter` resource** (already in the architecture plan) that
  *references* a `MapData` + holds the placements — keeps maps reusable across fights and lines
  up with the reusable-`Battle.tscn` direction (`Encounter` → `EncounterSpawner` → battle).
- **Likely resolution:** keep `MapData` terrain-only and introduce `Encounter` (references a
  map + placements); the builder edits/saves an `Encounter`, and `Main`/`Battle.tscn` consume
  the *same authored file* we test. Decide for real at Phase 3 kickoff. Placement shapes,
  roughly: enemy `{tile, class, weapon, armor, level, overrides:{hp?,mp?,spd?,move?}, name?}`;
  start zone = `Array[Vector2i]`; end tiles = `Array[Vector2i]` (+ a future condition type).

**Builder UX (sketch — design pass at kickoff, like we did for RESIZE):** a **layer/mode
switch** (Terrain vs Encounter) that re-skins the top palette; in Encounter mode, click a tile
to place/select a unit and open a small **inspector panel** (reuse the dialog + shared-`Theme`
pattern) for its spec; start-zone and end-tiles are tile-set paints drawn as translucent
colored overlays (reuse the marker-pool overlay trick). Unit markers could reuse the real
`Unit` cylinder+hat for WYSIWYG, or a lightweight token to start.

**Payoff / integration:** a **quick-test** path — save the encounter, then a thin launcher
loads it into the existing `Main`/`Battle` flow (player roster from `PartyLoadout`, enemies +
objectives from the encounter). Surfaces the **win-condition system**: today
`Main._check_battle_end` is elimination-only and will need to learn objective tiles. This phase
is effectively the authoring tool for the `Encounter` / `EncounterSpawner` / "`Battle.tscn`
returns a result" architecture items — build it with those in mind.

**Sequencing:** depends on the `Encounter` resource (architecture section), so expect to land a
first cut of that here. Independent of multi-state editing (Phase 4) — either order is fine.

---

## 11. Phase 4 designer — multi-state editing (later)

The shift-sequence (a map is an ordered list of states; the time-degradation gimmick cycles
them). Designer needs: switch between states, add / duplicate-current / delete a state. The
`MapData.states` array + `Battlefield._current_index` already model this; the designer just
needs UI + to edit `field.states[i]`. Authoring the grassland→canyon→desert-style sequences
needs this.

---

## 12. How to run & verify (important gotchas)

- **Run the designer:** open `scenes/MapDesigner.tscn` in the editor, then **F6** (or
  right-click the scene in FileSystem → **Run Scene**). **F5** runs the project main scene
  (`Loadout.tscn` → battle), NOT the designer. F6 runs whatever scene tab is active.
- **Syntax-check a script (reliable, exits cleanly):**
  `godot --headless --check-only --script res://path/to/Script.gd --path .`
  This catches missing-function calls etc. **Use this**, not the alternatives below.
- **Gotchas learned this session:**
  - `godot --headless --editor --quit` reports "no errors" even when a referenced script has
    a parse error, because it doesn't fully parse a script until its scene is opened. Don't
    trust it for parse-checking. Use `--check-only --script`.
  - `godot --headless --script some_scenetree.gd` test scripts tended to **not exit cleanly**
    in this environment (hung / exit 255). Avoid one-off SceneTree test scripts; prefer
    `--check-only` + just running the scene.
  - New `class_name`s aren't registered (so `--script` can't see them) until an editor
    import pass runs; opening the editor / `--editor --quit` registers them and generates the
    **`.gd.uid`** sidecars. This repo **tracks `.gd.uid`** files — commit them with scripts.
  - `godot` is on PATH in **PowerShell**, not necessarily in the Bash tool (got exit 127).

---

## 13. File map (quick reference)

| File | Role |
|------|------|
| `scripts/maps/MapData.gd` | Saved map resource (name, size, states) + round-trip + save/load |
| `scripts/maps/MapState.gd` | One state: flat heights / types / bodies arrays |
| `scripts/maps/DemoMap.gd` | Procedural 3-state demo (now sets `body`) |
| `scripts/TileTypes.gd` | Type enum + property table + accessors |
| `scripts/Battlefield.gd` | Grid engine: render, picking, movement BFS, overlays (UNTOUCHED by designer) |
| `scripts/mapdesigner/EditableBattlefield.gd` | `extends Battlefield`; editing API + grid overlay |
| `scripts/mapdesigner/MapDesigner.gd` | Designer interaction (tools, palette, save/load, HUD) |
| `scenes/MapDesigner.tscn` | The designer scene (F6) |
| `assets/maps/*.tres` | Saved maps (`wall_moat_test.tres` is an owner scratch map) |
| `docs/BATTLEFIELD.md` | Battlefield + format reference (kept current) |
| `docs/TODO.md` | Live task list — "Map & tiles overhaul" section |
| `docs/DECISION_LOG.md` | Locked decisions incl. the subclass call |
