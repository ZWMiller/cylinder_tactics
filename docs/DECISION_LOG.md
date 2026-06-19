# Decision Log

A running record of critical, hard-to-reverse, or non-obvious decisions made
during Cylinder Tactics. Newest entries at the top. Each entry: the decision,
why, and any alternatives rejected.

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
