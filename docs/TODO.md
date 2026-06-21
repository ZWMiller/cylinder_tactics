# Cylinder Tactics — TODO

A 2D-feel, isometric, turn-based tactics game (FF Tactics clone), built in 3D
with an orthographic camera. Characters are cylinders; terrain is boxes.
Workflow: **code-driven** (generate grid/terrain/units from data in GDScript).

## Done
- [x] Base scene (`scenes/Main.tscn`): environment, light, ortho camera, box, cylinder
- [x] Fixed black screen — camera basis was transposed, so it faced away from the scene
- [x] `Battlefield.gd` — code-driven 24×24 grid of (height, type) tiles, geometry-only
      (brown earth columns + colored caps), centered on origin. See `docs/BATTLEFIELD.md`
- [x] Time-shift v1 — map is a *sequence* of states; Space cycles grassland→canyon→desert
      via the small shift API (`peek_next_state` / `advance_shift`). `scripts/maps/DemoMap.gd`
- [x] `TileTypes.gd` — terrain enum + flat-color palette (shared vocabulary)
- [x] `Unit` scene + script — cylinder body (color = allegiance) + per-class hat
      (square/pyramid/cone = soldier/archer/mage). Hybrid scene+script; per-instance
      materials so units reskin independently. `UnitClasses.gd` = class table.
      Demo units spawn via `Main.gd`. See `docs/UNIT.md`
- [x] Click→tile picking — per-tile collision box (tagged with `grid_coord` meta) +
      `Battlefield.tile_at_screen_point()` physics raycast (height-correct). Decided
      *not* to extract a separate coordinate module; helpers stay on `Battlefield`
      (the coordinate authority). See `docs/DECISION_LOG.md` 2026-06-19.
- [x] Click-to-move units — single `_active_unit` pointer (the turn-order seam; Tab
      cycles it as a stand-in), tile-occupancy map, active-unit highlight.
      `Unit.grid_coord` now drives placement. See DECISION_LOG.
- [x] Stepped, tile-by-tile movement (no diagonals) — units walk the route bumping
      up/down to each tile's height instead of floating in a straight line. Right-click
      adds waypoints, mouse-move previews the lit-up path, left-click commits, Escape
      clears. `Battlefield.expand_path` / `path_to_world_points` / `show_path`,
      `Unit.move_along`. Per-step heights exposed for the future jump gate. See DECISION_LOG.
- [x] Per-turn action menu — bottom-left HUD (`ActionMenu.gd`, a CanvasLayer view)
      with Move / End Turn; Up/Down highlight, Enter activates. Input is gated by a
      `Phase` enum in `Main` (MENU vs MOVE): movement only works after choosing Move;
      End Turn cycles the active unit. See DECISION_LOG.
- [x] Class-driven stat blocks + job system — Resources in `scripts/stats/`
      (`StatBlock`/`ClassDef`/`Recruit`/`StatRoll`) + `.tres` data in `assets/classes/`
      and `assets/recruits/`. Effective = class base + banked level-up growth + aptitude;
      FFT-style per-level-up job banking (`Unit.level_history`); authored PCs vs rolled
      enemies. Reserved `evasion`/`temporal_resist` fields. See `docs/STATS.md`.
- [x] Spawn leveled, classed characters — `Main` now spawns PCs from authored
      `Recruit.tres` (`RECRUIT_BRON/DART/WISP`) and enemies via
      `StatRoll.random_recruit(class, level, rng)` (level 3, fixed seed), both through one
      `_spawn_recruit` → `Unit.init_from_recruit` path. Rolled foes get names sampled from
      the new `scripts/UnitNames.gd` pool (25 male + 25 female) instead of "Foe 0123".
- [x] Stat HUD + inspection — `ActionMenu` shows the active unit's name + a "Stats"
      option; `StatPanel` floats a unit's stat block above its head on ~1s hover (any
      ally/enemy; detection reuses tile occupancy, so units need no collision);
      `StatusPanel` is a persistent bottom-right status box during the menu phase
      (FFT layout). `Unit.stats_panel_text()` / `stats_summary()` format the readout.
- [x] Active-unit highlight = FFT-style tile marker — a translucent blue(ally)/red(enemy)
      pad on the active unit's tile via `Battlefield.set_active_tile`, tracked each frame
      in `Main._process`. Replaced an earlier body-emission + bloom approach.
- [x] EXP tracking — `Unit.current_exp` + `EXP_PER_LEVEL` placeholder, shown in the stat
      block. Lives on `Unit` (mutable progress), deliberately NOT a `StatBlock` field.

## Next

### Then
- [ ] **Jump-height gate** — NOW UNBLOCKED (units have a real `jump` stat in `max_stats`).
      Reject a move when any `Battlefield.path_step_heights(path)` step exceeds the active
      unit's `max_stats.jump`. Tint the preview red / refuse the commit when illegal.
- [ ] Movement range limit — clicks currently move the active unit *anywhere*; gate by
      grid distance + Z cost against `max_stats.move` (Battlefield helpers own reachability)
- [ ] Turn order / turn-based loop — will *set* `_active_unit` from `max_stats.speed`,
      replacing the temporary Tab cycle. **Do this as the first `TurnManager` extraction**
      (see the Architecture section) rather than growing the logic inside `Main`.
- [ ] Re-settle units + apply fall damage inside `advance_shift()` (terrain-only today) —
      fall damage should read `max_stats.temporal_resist` (the reserved hook), not a global
- [ ] Promotion / job-upgrade tree — a separate resource (which class unlocks which, at
      what level); deliberately kept out of `ClassDef`. See `docs/STATS.md`.

## Architecture — toward a reusable `Battle.tscn`

`Main.gd` is currently the single coordinator (a "God node"): it holds encounter setup,
turn/active-unit state, the MENU/MOVE input state machine, path planning, and the
hover-inspect logic. That's fine and intended for the prototype — **don't refactor
speculatively** (per `CLAUDE.md`: clarity over premature abstraction). The trigger to
start splitting is the **Turn order** item above: it will bloat the active-unit logic, so
let it *motivate* the first extraction instead of refactoring for its own sake.

Goal: a single reusable **`Battle.tscn`** (Battlefield + camera + HUD + coordinator
nodes) parameterized by **data** (map states + roster), so every level is the same scene
with a different `Encounter` resource — no per-battle `Main` rewrite. The Godot idiom is
**node composition + signals**, not imported modules: each subsystem becomes its own node
that *announces* events (e.g. `signal active_unit_changed(unit)`) so listeners react
without the announcer knowing them. Reusable pieces already exist (`Battlefield`, `Unit`,
`ActionMenu`/`StatPanel`/`StatusPanel`, the stat resources); these extractions carve the
rest out of `Main`, roughly in order:

- [ ] **`TurnManager` (do first, with Turn order)** — owns `_active_unit`, `_player_units`,
      and (new) the speed-based turn queue; replaces `_cycle_active_unit` + the Tab cycle.
      Emits `active_unit_changed(unit)` / `turn_ended(unit)`. Listeners (HUD title, status
      box, active-tile marker) react to the signal instead of `Main` hard-wiring them.
- [ ] **`Encounter` resource** — the per-battle *data*: map `states` (or a map generator
      ref) + the roster (PC recruits + enemy class/level rows) + RNG seed. This is what
      makes `Battle.tscn` reusable: swap the resource, get a different fight.
- [ ] **`EncounterSpawner` node** — consumes an `Encounter`: builds the battlefield states
      and spawns units (today's `_spawn_recruit`, rosters, RNG). Owns the
      `_units_by_tile` occupancy map (or hands it to a shared `BattleState`).
- [ ] **`BattleInputController` node** — the MENU/MOVE `Phase` state machine, path planning
      (`_planned_waypoints`, preview), and hover-inspect. Talks to `TurnManager` (whose
      turn) and `Battlefield` (picking/overlays); emits `move_committed(unit, tiles)`.
- [ ] **`HUD` node** — groups `ActionMenu` + `StatPanel` + `StatusPanel` under one parent
      that subscribes to the signals above (active-unit → title/status; hover → StatPanel),
      so the views are wired in one place instead of scattered through `Main`.
- [ ] **`Battle.tscn` + thin `Battle.gd`** — composes the above and is handed an
      `Encounter`. `Main` shrinks to a launcher (pick an encounter → load `Battle.tscn`),
      or disappears in favor of a menu/level-select scene.

Decision to log when the first extraction lands: the move to **node composition + signals**
as the battle architecture (and what each node owns / which signals exist).

## Polish / nice-to-have
- [ ] Distinguish committed-waypoint tiles from the hover tail in the path preview
      (e.g. a stronger color), and maybe a destination marker
- [ ] Tune `Unit.MOVE_SPEED` and the step cadence once real maps exist

## Later / backlog
- [ ] Tile selection + highlight on hover/click
- [ ] Unit movement tile-to-tile (with movement range based on grid distance + Z cost)
- [ ] Turn order / turn-based loop
- [ ] Multiple grid sizes
- [ ] Basic combat (attack range, damage)
- [ ] Character classes (soldier/archer/mage) + class-driven stat blocks — see `docs/GAME_DESIGN.md` §2–3
- [ ] Time-degradation map shift every N turns (tiles drop, units fall + take damage) — see `docs/GAME_DESIGN.md` §4
- [ ] Shift telegraph + hold-to-preview "what-if" view — see `docs/GAME_DESIGN.md` §4
- [ ] Time-mage powers (accelerate shift, shift one tile early, …) — deferred, see `docs/GAME_DESIGN.md` §5

See `docs/GAME_DESIGN.md` for the full game-design vision and the structural choices
to respect now (maps as height *sequences*, a shift API, data-driven stats).

## Owner onboarding / learning (revisit next session)
- [x] **Line-by-line walkthrough of Godot's invocation pattern**, using "place one
      unit" (player archer at tile 12,10) as the worked example. Mapped each step to
      exact lines: `Main.gd:12` `preload` (parse-time blueprint) -> `:41`
      `instantiate()` (the `new`, no `_ready` yet) -> `:44` `configure` stashes
      identity (guarded by `is_node_ready()` in `Unit.gd:61`) -> `:46` `add_child` is
      the seam that fires `Unit._ready` (`Unit.gd:49`) -> `_apply_appearance`/`_layout`
      read the fields, swap the hat mesh via `UnitClasses.new_hat_mesh`, build
      per-unit materials -> `:47` `tile_to_world` places it -> engine draws every
      frame (no explicit render call). Key takeaway: `add_child` is the boundary
      between "constructing data" and "engine owns the lifecycle."
      - Analogies that landed: PackedScene ≈ class blueprint/prefab you clone;
        `_ready` ≈ engine-invoked constructor-ish hook; `UnitClasses` statics ≈ a
        module of free functions.

## Notes / things learned
- A camera looks down its own -Z axis. A transposed rotation matrix = inverse
  rotation, which silently aims the camera the wrong way (classic black-screen bug).
- Prefer setting Position/Rotation separately, or `look_at(Vector3.ZERO, Vector3.UP)`
  in code, instead of hand-writing `Transform3D(...)` matrices.
- Godot ignores unrecognized files (like this one). Drop an empty `.gdignore` in a
  folder to make Godot skip it entirely.
