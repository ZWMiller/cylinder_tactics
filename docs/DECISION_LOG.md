# Decision Log

A running record of critical, hard-to-reverse, or non-obvious decisions made
during Cylinder Tactics. Newest entries at the top. Each entry: the decision,
why, and any alternatives rejected.

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
