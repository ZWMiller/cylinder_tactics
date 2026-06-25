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
3. 🔄 **Map designer** — Phase 1 DONE (this session, see §5). Phase 2 (brushes) + Phase 3
   (multi-state) pending. **Plus the 3 fixes in §6 — start here tomorrow.**
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

## 6. ⭐ START HERE TOMORROW — the 3 requested fixes

1. **Can't change map size or name in the builder.**
   - New map is hardcoded `NEW_MAP_WIDTH/HEIGHT = 10`; there's no name editing and no resize.
   - Need: a **New-map dialog** (enter width, height — and probably name) before generating,
     and a way to **rename** the current map (its `map_name` goes into the `.tres`). Possibly
     also resize an existing map (pad/crop). At minimum: width/height/name inputs on New.
   - Likely a small `Control` popup (`AcceptDialog` with `SpinBox`es + a `LineEdit`), or
     inline HUD fields. Keep it simple.

2. **Swatch/palette bar (ARPG skill-bar style).**
   - A horizontal bar across the top showing each terrain type as a **colored swatch** with
     its **number-key label**, highlighting the currently-active type. Colors come from
     `TileTypes.surface_color(type)`. Should track `[`/`]`/number-key selection. Purely a HUD
     addition in `MapDesigner._build_hud` (+ a refresh on type change). 11 types; number keys
     cover 10, so show the binding (or `[ ]` hint) for QUICKSAND.

3. **Save/Load FileDialog is tiny — unreadable.**
   - Currently `popup_centered_ratio(0.6)`; it renders very small. Fix by setting an explicit
     `min_size` (e.g. `Vector2i(900, 600)`) and/or `popup_centered(Vector2i(900,600))`, and
     bump the dialog's font size (theme override) so filenames are legible on hi-res.

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

## 10. Phase 3 designer — multi-state editing (later)

The shift-sequence (a map is an ordered list of states; the time-degradation gimmick cycles
them). Designer needs: switch between states, add / duplicate-current / delete a state. The
`MapData.states` array + `Battlefield._current_index` already model this; the designer just
needs UI + to edit `field.states[i]`. Authoring the grassland→canyon→desert-style sequences
needs this.

---

## 11. How to run & verify (important gotchas)

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

## 12. File map (quick reference)

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
