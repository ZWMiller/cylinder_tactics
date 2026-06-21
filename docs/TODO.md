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

## Next

### Do first — make the new stat system visible/usable, then verify
- [ ] **Wire `Main.gd` to spawn leveled, classed characters.** Demo units are still
      spawned via `configure(side, class)` (appearance-only, baseline level-1 stats).
      Spawn PCs from authored `Recruit.tres` via `Unit.init_from_recruit`, and enemies via
      `StatRoll.random_recruit(class, level, rng)`, so units carry real classes, levels,
      and stat blocks. Everything below depends on this.
- [ ] **Action menu: show the active character's name**, and add a **"Stats" option** that
      displays the unit's full stat block (for now even a print / simple panel is fine) so
      the owner can verify class/level/aptitude/banked-growth in-game before moving on.
      `Unit.stats_summary()` already returns a one-line summary to start from.

### Then
- [ ] **Jump-height gate** — NOW UNBLOCKED (units have a real `jump` stat in `max_stats`).
      Reject a move when any `Battlefield.path_step_heights(path)` step exceeds the active
      unit's `max_stats.jump`. Tint the preview red / refuse the commit when illegal.
- [ ] Movement range limit — clicks currently move the active unit *anywhere*; gate by
      grid distance + Z cost against `max_stats.move` (Battlefield helpers own reachability)
- [ ] Turn order / turn-based loop — will *set* `_active_unit` from `max_stats.speed`,
      replacing the temporary Tab cycle
- [ ] Re-settle units + apply fall damage inside `advance_shift()` (terrain-only today) —
      fall damage should read `max_stats.temporal_resist` (the reserved hook), not a global
- [ ] Promotion / job-upgrade tree — a separate resource (which class unlocks which, at
      what level); deliberately kept out of `ClassDef`. See `docs/STATS.md`.

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
