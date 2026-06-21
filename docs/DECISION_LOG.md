# Decision Log

A running record of critical, hard-to-reverse, or non-obvious decisions made
during Cylinder Tactics. Newest entries at the top. Each entry: the decision,
why, and any alternatives rejected.

---

## 2026-06-21 — Stat HUD, hover-inspect via tile occupancy, tile-marker highlight, EXP on Unit

**Decision:** Made the stat system visible in-game and reworked the active-unit highlight.

- **Hover-to-inspect (`StatPanel`):** resting the cursor on any unit ~1s floats its stat
  block above its head. Units have **no collision of their own** — detection ray-picks the
  *tile* (`Battlefield.tile_at_screen_point`) and looks up its occupant in `_units_by_tile`.
  Hovering a unit = hovering its tile. The panel is a **screen-space** `CanvasLayer` box
  (rounded `StyleBoxFlat` matching the menu), positioned by projecting the unit's head to
  the screen (`Camera3D.unproject_position`) and clamped on-screen.
- **Persistent status box (`StatusPanel`):** a bottom-right box showing the active unit's
  full block during the MENU phase (the FFT two-box layout: menu one corner, status the
  other); hidden in MOVE mode.
- **Active-unit highlight = a tile marker**, not a unit effect: a translucent
  blue(ally)/red(enemy) pad on the active unit's tile via `Battlefield.set_active_tile`
  (same flat-`PlaneMesh` decal trick as the movement-path preview), tracked each frame in
  `Main._process`. The cylinder renders normally.
- **EXP lives on `Unit`** (`current_exp` + `EXP_PER_LEVEL` placeholder), shown in the stat
  block — **not** a `StatBlock` field (see `docs/STATS.md`).

**Why:**
- **Reuse tile occupancy for hover** — `Battlefield` is already the picking/coordinate
  authority and `_units_by_tile` already exists, so unit-hover is free and adds no physics
  bodies to units. The tile under the cursor is the unit on it.
- **Tile marker over a body glow** — it keeps the body's own side/class colors readable and
  reads as "whose tile," the genre convention. We *tried and rejected* two glow approaches
  first: an **inverted-hull additive shell** (looked like a translucent force-field, ground
  showed through — read as a bug) and an **emissive body + `WorldEnvironment` bloom** (the
  whole cylinder became a light source, washing out allegiance). Both are removed.
- **EXP off `StatBlock`** — that schema is summed across base/growth/aptitude/banked;
  experience is mutable per-unit progress like `current_hp`, so summing it there is
  meaningless. Putting it on `Unit` now (with a named threshold) means future leveling code
  has a clean field to read instead of a late, awkward retrofit.

**Rejected:** giving units collision bodies just to hover them (unnecessary — tiles already
have collision); a 3D `Label3D` for the floating panel (can't do the rounded translucent
chrome the HUD uses); inverted-hull and emissive-bloom glows (see above); an `exp` field on
`StatBlock` (wrong layer).

---

## 2026-06-21 — Stat system as Resources; FFT-style per-level-up job banking

**Decision:** Implemented the stat layer as Godot **Resources** (`scripts/stats/`),
not Dictionaries or hardcoded tables, with editable `.tres` data assets:
- `StatBlock` (Resource) — the 11-number schema, reused for class *base*, per-level
  *growth*, per-person *aptitude*, and accumulated *banked* growth. All ops
  (`combined`/`scaled`/`clamped_nonneg`) return **new** instances (Resources are shared
  by reference — the same gotcha as materials in `Unit.gd`).
- `ClassDef` (Resource, one `.tres` per class in `assets/classes/`) — `base` + per-level
  `growth`. Loaded via `UnitClasses.class_def()` (preloaded dict, enum→asset bridge).
- `Recruit` (Resource) — the **person**: `display_name`, innate `aptitude`,
  `starting_class`, `starting_level`. Authored PCs are `.tres` in `assets/recruits/`;
  enemies are minted at spawn by `StatRoll.random_recruit(class, level, rng)`. Both
  feed the identical pipeline ("shared blocks").
- `Unit` gained: `level`, `level_history`, computed `max_stats`, live `current_hp/mp`,
  and methods `init_from_recruit` / `recompute_stats` / `level_up` / `set_class`.

**Effective stats = `current_class.base` + `banked_growth` + `aptitude`** (then floored
at 0). The defining choice is **path-dependent job banking (FFT-style):** `level_history`
records *which class the unit held at each level-up*; `banked_growth` sums that class's
growth per entry. Leveling as a Mage then reclassing to Soldier **keeps** the mage's
banked MP/MATK — so players *craft* characters through their leveling path. `set_class`
swaps the base immediately but preserves history, identity, level, and aptitude.

We store the **history of classes-per-level and recompute from the current tables**
(rather than snapshotting the numbers gained). Chosen so growth/`.tres` stays *tunable* —
retune a table and every existing unit updates, instead of being frozen with stale gains.

**Growth includes real combat stats** (Soldier `+1 HP/+1 PATK`, Archer `+1 PATK/+1 SPD`,
Mage `+1 MP/+1 MATK`), so a single un-promoted class is a viable build — leveling in-class
is genuinely worthwhile, and promotions (deferred, see below) are a *bonus* path, not the
only way to grow. Numbers stay tiny per the small-numbers philosophy.

**Promotions/job tree kept OUT of `ClassDef`:** which class unlocks which, at what level,
is a separate progression graph (prerequisites, multiple unlocks) and will get its own
resource later. `ClassDef` is a thin stat asset only.

**Why Resources/.tres:** they're the idiomatic Godot data asset — Inspector-editable,
serializable, hot-swappable — and a learning goal for the owner. Verified end-to-end
headless (assets load; banking math correct; full project parses clean).

**Rejected:** Dictionary/hardcoded stat tables (no Inspector, not the Godot idiom);
snapshotting per-level gains (freezes numbers against retuning); growth that's HP/MP-only
with combat power gated behind promotions (would make base classes feel like traps);
folding the promotion tree into `ClassDef` (bloats the stat asset, fights SRP).

---

## 2026-06-21 — Stat-block schema + small-numbers design philosophy

**Decision:** Locked the unit stat schema (full detail in `docs/GAME_DESIGN.md` §3),
to live in `scripts/UnitClasses.gd` as class base templates + per-unit overrides:
- **Live now/soon:** `max_hp`, `max_mp`, `move`, `jump`, `speed`, `phys_atk`,
  `mag_atk`, `phys_def`, `mag_def`.
- **Reserved (field now, effects later):** `evasion` (hidden hit-chance input) and
  `temporal_resist` (save vs. hostile time magic + fall-damage mitigation — the
  game's signature stat).
- **Deferred (not in schema):** crit, luck, FFT Brave/Faith.

Two model choices baked in: **(a)** offense and defense are **split** into physical
and magical (`phys_atk`/`mag_atk`, `phys_def`/`mag_def`), Fire-Emblem-style, so class
identity is mechanical, not cosmetic; **(b)** avoidance and toughness are **separate
axes** — a hit% check (accuracy vs. `evasion`) decides *whether* a hit lands, and
defense reduces *how much* — explicitly **not** a D&D single-roll Armor Class that
fuses the two. Combat ships **deterministic first** (always hit; `damage = atk − def`
floored at 1); the evasion dice come later.

**Small-numbers philosophy (committed):** All stats and damage stay in the
single-/low-double-digit range — ~30 HP, ~6-damage hits, ~1 per point of defense. We
reject JRPG number inflation (5-digit hits vs. 4-digit defense) because at that scale
a single point is meaningless. Small numbers make every point a legible tradeoff
(+1 jump, 6 vs 5 damage, a 1-point resist all matter at a glance). This bounds the
whole economy and constrains damage formulas to subtractive/bounded, never a
percentage curve that explodes at high values.

**Why:** Settling the *set* of stats before writing the table avoids a painful
refactor once movement, combat, gear, and spells all read from it; the split-stat +
separate-hit/mitigation model is the genre consensus (FE, Tactics Ogre, Triangle
Strategy) and reads cleanly on a grid. The small-numbers rule is an owner design
preference logged here so every later formula respects it.

**Rejected:** D&D Armor Class (one roll for hit-or-nothing, full damage on hit) —
swingy and fuses avoidance with toughness, less readable on a grid; FFT Brave/Faith
and a Luck/crit stat now — each a whole subsystem, and the committed set already gives
enough spell-design surface; large/inflating number ranges — break the legibility the
owner wants.

---

## 2026-06-19 — Per-turn action menu (Move / End Turn); input gated by phase

**Decision:** A unit's turn runs through a small state machine in `Main` with a
`Phase` enum: `MENU` (a bottom-left action HUD with Move / End Turn) and `MOVE`
(placing a path). Selecting **Move** enters MOVE phase; **End Turn** cycles to the
next unit; committing a move or pressing Escape returns to MENU. The HUD is
`ActionMenu` (`class_name`, extends **CanvasLayer**), built entirely in code as a
*view* — `Main` owns the state (options, highlight index, visibility) and calls
`build` / `set_highlighted` / `set_menu_visible`; the menu holds no game logic.

**Why:**
- **Gates tile input behind an explicit action**, which is how tactics turns work
  (choose an action, then target) — and it makes the active-unit/turn-order seam
  concrete: "End Turn" is the single place a turn ends today, so the real scheduler
  slots in there.
- **CanvasLayer view, code-built:** a HUD belongs in screen space (CanvasLayer),
  separate from the 3D world; keeping it a dumb view avoids coupling UI to turn
  logic, and building it in code matches the project's code-driven convention.
- **Menu keys are handled in `Main._input` (not `_unhandled_input`)** and consumed
  with `set_input_as_handled`, so confirming the menu doesn't also fire the
  Battlefield's placeholder Space/Enter time-shift. This ordering matters: Godot
  delivers `_unhandled_input` to children before parents, and the Battlefield is a
  child of Main — so consuming in `_unhandled_input` was too late, but `_input` runs
  before *any* node's `_unhandled_input`.

**Rejected:** Always-on movement (no menu) — fine for a sandbox but doesn't model
turns; a `.tscn`-authored HUD — against the code-driven workflow and harder to keep
in version control diffs; mouse-clickable menu items — keyboard-only is enough now
(left-click is reserved for the 3D world).

---

## 2026-06-19 — Stepped, tile-by-tile movement with a waypoint + path preview

**Decision:** A move is a path of orthogonally-adjacent tiles (no diagonals) that
the unit walks one tile at a time, bumping up/down to each tile's height, instead
of a single straight-line glide. Three layers, all keyed off the grid:
- `Battlefield.expand_path(waypoints)` densifies sparse waypoint tiles into adjacent
  steps (walk X then Z — a deterministic L-fill; one axis at a time guarantees no
  diagonals).
- `Battlefield.path_to_world_points(tiles)` turns the tile path into a polyline that
  hugs the terrain: stepping **up** rises in place over the lower tile then moves
  on (so the body never clips the cliff face); stepping **down** moves out then
  drops; flat is a single step. `Unit.move_along(points)` walks that polyline.
- Interaction: right-click adds a waypoint, mouse-move previews the route (lit-up
  tiles via `Battlefield.show_path`), left-click commits, Escape clears.

**Why:**
- **Reads as walking, not floating.** A straight diagonal to a hilltop looked wrong;
  per-tile steps with terrain-hugging corners look like climbing/descending.
- **Foundation for jump gating.** Each step is exactly one tile / one height delta,
  so `Battlefield.path_step_heights(tiles)` yields the per-step climbs a future gate
  checks against a unit's jump stat — the move becomes legal/illegal step by step.
- **Waypoints give the player control** over the naive L-fill route and are the
  natural place to hang future sanity checks (occupancy, reachability) per segment.

**Rejected:** Single-target straight glide (the floating look); auto-pathfinding the
whole route now (premature — waypoints + L-fill are enough until obstacles/cost
exist); an arrow gizmo for the preview (tile-lighting is simpler and reads well on a
grid).

---

## 2026-06-19 — Click→tile via physics raycast; coordinate helpers stay on Battlefield

**Decision:** Mouse picking ("which tile did I click?") is done with a **physics
raycast**, not by inverting the grid math. Each tile gets an invisible
`StaticBody3D` + `CollisionShape3D` (its own `BoxShape3D`, resized per state in
`render_state`) tagged with `set_meta("grid_coord", Vector2i(x, z))`.
`Battlefield.tile_at_screen_point(camera, screen_point)` shoots a ray via
`camera.project_ray_origin/normal`, queries `direct_space_state`, and reads the
hit body's metadata. The grid↔world helpers (including this picker) **stay on
`Battlefield`** — we did *not* extract a separate coordinate module (deviating from
the TODO's wording).

**Why:**
- **Raycast is height-correct.** With terrain at varying Z, projecting a click onto
  a ground plane and inverting the math picks the wrong tile when clicking a tall
  cliff (the ray meets the plane behind it). Hitting the real 3D geometry is right
  by construction, and the hit body's metadata gives (x, z) with no inverse math.
- **`Battlefield` is the coordinate authority.** world↔tile depends on instance
  state (`grid_width`, `tile_size`, `height_step`, and the *current* heights). A
  free-standing static module would have to be handed all of that anyway, so a
  separate module buys nothing yet. Extract later if a second owner appears.

**Rejected:** Plane-projection + inverse math (wrong on tall tiles); a standalone
static coordinate autoload (premature — no data of its own).

---

## 2026-06-19 — Active-unit pointer as the turn-order seam

**Decision:** Click-to-move acts on a single `_active_unit` pointer in `Main.gd`.
Today we set it ourselves and **Tab** cycles it among player units; the future turn
scheduler will set the *same* pointer from speed/initiative stats, leaving the
click/movement code unchanged. Movement is a constant-speed walk through a point
queue (`Unit.move_along` + a self-disabling `_process`; see the stepped-movement
entry above), with tile occupancy tracked in a `Vector2i → Unit` dictionary and the
active unit shown via an emission highlight.

**Why:** In turn-based tactics the player doesn't freely select units — the turn
order decides whose turn it is. Modeling "one active unit" now (rather than
free click-to-select) means the turn system slots in by just *setting the pointer*,
instead of replacing the interaction model later.

**Rejected:** Click-a-unit-to-select-it (free selection) — natural for a sandbox,
but contradicts turn order and would be thrown away once turns exist.

---

## 2026-06-18 — Unit = hybrid scene+script; class is a data table

**Decision:** The character "model" is a **hybrid**: `scenes/Unit.tscn` authors the
node layout (a cylinder Body + a Hat `MeshInstance3D`), and `scripts/Unit.gd`
(`class_name Unit`) is the self-contained object that owns identity (allegiance,
class), appearance, `grid_coord`, and later stats/combat. A unit is spawned by
`Unit.tscn.instantiate()` and reskinned via `configure(side, class)`. Class data
(hat color + hat *shape*) lives in `scripts/UnitClasses.gd`, mirroring
`TileTypes.gd`; shapes are square (soldier) / pyramid (archer) / cone (mage).

**Why:**
- **Hybrid, not pure-code** (unlike `Battlefield`, which builds 1,728 procedural
  tiles in code): a unit is a *uniform prefab* stamped out many times, which is
  exactly what Godot scenes/`instantiate()` are for, and it lets the owner tweak the
  model visually in the editor. "Code-driven" still holds — the *spawner* reads data
  and instantiates; only the prefab's node tree is authored as a scene.
- **Per-instance materials + fresh meshes per unit.** Godot materials/meshes are
  shared *state* when shared, so each unit builds its own (`material_override`, a new
  mesh per `new_hat_mesh`). This is what makes independent reskinning possible.
- **Class as a data table**, not hardcoded in `Unit`: keeps the one "what does a
  class look/play like" place (and the future home for stat templates) separate from
  unit behavior. Hat shape is chosen in a single `match`, so diverging a class's
  shape is a one-line change that `Unit` adapts to by measuring the mesh.

**Rejected:** Pure-code unit (everything in `Unit.gd`, no scene) — consistent with
`Battlefield` but loses editor-visual tweaking and the core scene-instancing idiom;
and hardcoding hat appearance in `Unit` — blurs class data into unit behavior.

---

## 2026-06-18 — Core gimmick documented; map = sequence of height states

**Decision:** Recorded the full game-design vision in `docs/GAME_DESIGN.md`
(character classes for player+enemy, class-driven stat blocks, the time-degradation
map shift, shift telegraph + hold-to-preview, and the deferred time-mage powers). The
one structural commitment taken *now*, ahead of building `Battlefield.gd`: a map is
modeled as a **sequence/generator of per-tile height states over time**, not a single
static height array, and the shift gets a small **public API** (peek next state,
apply next shift, apply one tile early).

**Why:** The gimmick's preview feature needs the *next* map state to exist before it
is applied, and the time-mage's powers need to poke the shift externally. Both are
deferred, but baking a single static height array into the terrain generator now would
force a painful retrofit. Designing the data shape correctly is cheap today.

**Rejected:** Treating the battlefield as one fixed height array with the shift as a
private side effect of the turn loop — simpler short-term, but blocks preview and the
time-mage cleanly.

---

## 2026-06-17 — Documentation & workflow conventions

**Decision:** Heavy documentation discipline. Every function gets a docstring
(regardless of simplicity); complex steps in functions and config files get
explanatory comments; components get written up in markdown under `docs/` as we
build them. Discuss and plan multi-step or unclear work before coding.

**Why:** Owner strongly prefers thorough documentation and design discussion over
jumping straight to code.

---

## 2026-06-17 — Code-driven scene construction

**Decision:** Build the grid, terrain, and units from data in GDScript at runtime
rather than hand-placing nodes in the Godot editor.

**Why:** Tactics maps vary in size and per-tile height; generating from a data
array scales far better than manual placement and keeps maps as editable data.

**Rejected:** GUI/Inspector-first scene building — fine for learning individual
nodes, but doesn't scale to procedural maps.

---

## 2026-06-17 — 3D with an orthographic camera

**Decision:** Render the isometric, 2D-feeling battlefield using a 3D scene with
an orthographic camera, not Godot's 2D engine.

**Why:** Terrain needs real Z-height variation and an isometric look; 3D + ortho
gives true height and depth handling for free, while 2D would require faking it.

**Note:** A camera looks down its own -Z axis. Hand-written `Transform3D` bases are
error-prone (a transpose silently aims the camera away — the original black-screen
bug). Prefer Position/Rotation fields or `look_at()`.
