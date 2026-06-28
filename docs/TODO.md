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
- [x] Movement range + jump gate — picking "Move" outlines the unit's reachable region
      (`Battlefield.reachable_tiles` BFS: 1 move-point/step, step legal iff `|Δheight| ≤
      jump`, walk through allies but not enemies, can't stop on an occupied tile). The path
      preview is coloured per tile blue(legal)/red(illegal) via `Battlefield.classify_path`,
      and the same classifier gates the commit (any red tile refuses the move). Range drawn
      as an **outline** (border strips on edges facing outside the region), not a fill. See
      `docs/DECISION_LOG.md`.
- [x] Camera polish + turn-counted map shift — `CameraController` follows the active unit's
      live position (gentle trailing lag) and plays a one-time battle intro (open 90° off-axis,
      slow orbit in, hold, punch-in on the first unit). The map time-shift is now driven by the
      turn count: `TurnManager` counts completed character turns (NOT CT) and every Nth
      (`register_map_transition_speed`, default 10) fires `map_transition_due` + pauses the turn
      loop; `Main` plays a cinematic (zoom out to whole map → hold → shift → hold → zoom back in)
      then resumes via `continue_after_transition`. New `ShiftCounter` HUD (top-right "Shift in:
      N") telegraphs the countdown. Debug **T** key previews the cinematic. See `docs/DECISION_LOG.md`.
- [x] Combat — first pass (melee) — generic attack pipeline: `Attack` resource profile
      (`min_range`/`max_range`, `power` phys/mag, `anim`), `CombatResolver` (static `hit_chance`
      [mock 1.0] / `compute_damage` `atk−def` floored at 1 / `resolve`). "Attack" menu →
      `Phase.ATTACK`: orange reach fill (`Battlefield.tiles_in_range` + `show_attack_range`),
      click an in-range enemy to commit. `Main._commit_attack` resolves mechanics, then
      sequences presentation separately — `Unit.play_attack_animation` (the "bonk" stick swing)
      → apply damage → floating `-N` (`FloatingCombatText`, self-freeing Label3D) → death
      (`Unit.play_death_animation` topple+fade) → remove from board + turn order. See
      `docs/DECISION_LOG.md`.
- [x] Win/lose end screen — after a death, `Main._check_battle_end` polls for a wiped side. Win →
      camera pulls back + spins a slow indefinite 360° (`CameraController.start_victory_orbit`) while
      a huge "YOU WIN" fades in and smoothly cycles the rainbow; lose → camera pulls back, screen
      fades to black, big deep-red "YOU LOSE", held. `EndScreen.gd` (font tinted via `modulate` so
      one tween drives both fade + color cycle). `_game_over` latches and gates the turn loop /
      input / per-frame work. (No restart menu yet — holds until quit.) See `docs/DECISION_LOG.md`.
- [x] Per-turn action economy — a turn = up to 2 committed actions, at most one an attack/spell
      (move+move, or move+attack/spell either order). Stats/End Turn are free; cancelling spends
      nothing. `Main._actions_taken`/`_offensive_taken` (reset per turn) + `_is_action_enabled`
      drive both the menu greying (`ActionMenu.set_enabled`) and activation refusal. See
      `docs/DECISION_LOG.md`.
- [x] **Move undo** — a player can take back movement (and reclaim the move slot) until they do
      something that changes the battle for others. Anchor-based (`_set_undo_anchor` at turn start +
      after an attack/spell; `_undo_move` rewinds tile/actions/HP to it); "Undo Move" is a permanent
      menu option that greys out until a move is available (built once per turn — rebuilding mid-turn
      mis-sized the panel). Halts an in-flight walk, cancels a pending on-enter hazard via a move
      token, and floats a green "+N" (`_spawn_heal_number`, reusing `FloatingCombatText`) for any HP
      refunded. ("Stats" pulled from the menu for now; hover still works.) See `docs/DECISION_LOG.md`.

- [x] **Pre-battle loadout menu** — split into two scenes: `Loadout.tscn` (now the `run/main_scene`)
      runs before `Main.tscn`. Top third = active character portrait frame + full stat grid with live
      **±N preview** when hovering gear (incl. ATTACK + MAGIC POWER, TOTAL ARMOR, SET BONUS checkbox);
      bottom-left = the 5 equip slots; bottom-right = inventory (slot-filtered while editing, full
      catalog on Tab/browse), greyed if a requirement is unmet. Choices persist across the scene
      change via a new **`PartyLoadout` autoload** (roster + per-member loadout + shared catalog) —
      the thin first cut of `RunState`; `Main` reads it instead of hardcoding the roster/default kits.
      Class defaults are seeded up front so no one starts gear-less; "Begin Battle" needs a Yes/No
      confirm; switching characters is blocked mid-edit. `Unit` gained slot-targeted
      `equip_to_slot`/`clear_slot`/`item_in_slot` + `CombatResolver.offense`. See `docs/LOADOUT.md`.

## Next

### Map & tiles overhaul (current focus — branch `update-maps-and-tiles`)
Goal: smaller, more interesting maps and real terrain-type gameplay, so playtesting feels
better. Sequenced so the **saved map format is the linchpin** — once it exists, variable
size falls out, the designer is "draw → save", and authoring new maps is visual instead of
tuning falloff constants. Decided: in-game designer scene (new / load-existing / edit /
save), maps saved as a custom `MapData` Resource (`.tres`).
- [x] **Map format + load/save + variable size** — `MapData` / `MapState` resources
      (`scripts/maps/`): a map carries its own `width`/`height` and an ordered list of
      states stored as flat `PackedInt32Array`s (compact, diff-able `.tres`).
      `to_states()`/`from_states()` bridge the runtime nested form; `save_to`/`load_from`
      wrap `ResourceSaver`/`load`. `Battlefield` gained a `map_data` export (wins over
      `states`/DemoMap) and `_adopt_dimensions_from_states()` so grid size now comes from
      the data, not the exports. See `docs/BATTLEFIELD.md`.
- [~] **Map designer scene** — in-game scene (`scenes/MapDesigner.tscn`, run with F6).
      **Phase 1 DONE:** `EditableBattlefield extends Battlefield` (additive editing API +
      designer-only grid overlay, `Battlefield.gd` untouched) + `MapDesigner.gd` (Height/
      Surface/Body tools, terrain palette, hover cursor, New/Save/Load to `.tres`, HUD).
      **§6 fixes:** (1) ✅ editable map size + name — DONE: New/Rename dialogs + a live
      **RESIZE tool** (Tab cycle; hover an edge, L adds / R deletes, corners do both; green
      ghost + red overlay preview). (2) ✅ swatch/skill-bar palette across the top — DONE:
      clickable colored swatches, number-key labels, active-type highlight (click OR number
      key selects). (3) ✅ FileDialog readability — DONE, and root-caused to a project-wide
      gap: enabled `canvas_items` stretch (1080p base) so the whole 2D UI scales with the
      window instead of shrinking on big displays; designer fonts centralized into constants +
      a shared dialog Theme. (4) ✅ grid outline extended down cliff faces — DONE: vertical posts
      at every dropped/border edge so steps read fully, not just tile tops. Also: Save dialog
      now prefills the filename from the map name. **Then Phase 2:** brush macros (Single/Square/
      Circle/Line/**Hill**, configurable size N, click-drag height) via `set_tiles`. **Phase 3 —
      Encounter layer:** turn the builder into an *encounter builder* — place enemies (class/
      weapon/armor/level + per-stat HP/MP/Speed/Move overrides), named characters/bosses, a
      player **start zone**, and **win-objective tiles** (reach-the-tile victory, not just
      elimination); save the whole fight and quick-load to test. Visual front-end for the
      `Encounter` resource; key open question = embed in `MapData` vs a separate `Encounter`
      that references the map. See `docs/map_builder_implementation_plan.md` §10. **Phase 4
      (later):** multi-state editing.
- [x] **Terrain vocabulary + property table + two-layer tiles** — `TileTypes` now holds a
      single-source-of-truth table per type: `color`, `move_cost`, `is_liquid`, `can_cast`,
      `hazard_damage` (reserved, lava placeholder). New types: `DIRT` (default body), `LAVA`,
      `BUILDING`, `BUILDING_STONE`, `ROOF`, `QUICKSAND` (liquids: water/lava/quicksand).
      Tiles are now **two-layer** — a surface/cap `type` (gameplay + top color) plus a `body`
      type (side color, defaults `DIRT`), so one tile can be a stucco building with a slate
      roof. `MapState` gained a `bodies` array; `Battlefield` colors the column by body.
- [x] **Wire terrain gameplay** — the `TileTypes` property table now drives play:
      - **Movement cost:** `reachable_tiles`/`find_path` went BFS → **Dijkstra** (variable per-tile
        `move_cost` — liquids cost 2 to enter — breaks BFS's "first arrival is cheapest"), and
        `classify_path` accumulates entered-tile cost instead of using the path index. Jump/solid/
        occupied rules unchanged.
      - **Casting legality:** spells are gated by `TileTypes.can_cast` of the caster's tile via
        `Main._can_cast_from` — the player's spell pick flashes a **"Can't Cast Here"** toast
        (`SpellMenu.flash_warning`, generalized from `flash_insufficient`) and the enemy AI
        (`_enemy_choose_attack`) falls back to its weapon when standing in liquid.
      - **Hazard damage (lava):** ticks **both** on-enter (after a move lands —
        `_apply_hazard_after_move` for the player, inline in `_enemy_move_toward` for the AI) **and**
        at **turn start** (`_begin_turn`, deferred a frame past the hand-off). `_resolve_hazard` deals
        the damage + floats a "-N"; a lethal tick on the active unit advances the turn via new
        `TurnManager.notify_active_died` (can't reuse `end_turn` — it'd deref the freed unit).
      - **Liquid depth:** a liquid tile's surface is drawn recessed (`Battlefield.liquid_recess`) and
        a unit standing on it sinks a further `liquid_sink` (`unit_stand_world`, used for spawn +
        walk path), so it reads as standing *in* water. Gameplay heights stay integer — the recess is
        cosmetic only (new `_surface_world_y`; jump/range math untouched).
      Verified: headless parse + full editor import clean.
- [ ] **Line-of-sight + projectile collision** — tall terrain blocks arrows/fireballs and
      targeting (a grid/height LoS check between attacker and target; projectiles respect it).
      Most novel/complex; its own chunk.
- [~] **Author new demo maps** — small, deliberately interesting battle maps (chokepoints, high
      ground, mixed terrain) as height-state sequences; retire/retune the procedural 24×24 demo cycle.
      **Done so far:** `SmallDemoMap.gd` — a 12×12 procedural cousin of `DemoMap` with a hill in all
      four corners (height set by nearest corner) and the same grassland→canyon(river)→desert(stone
      riverbed) cycle; now the Battlefield fallback, with the demo roster repositioned to the flat
      center. **Still TODO:** hand-author maps in the designer (this one is still procedural).

### Next up — ranged + magic attacks, and a Spells menu
The melee pipeline was built generic for exactly this; most of the work is *data + a projectile
animation + a conditional menu*, not new mechanics.
- [x] **Arrow (ranged physical) + Fireball (magic) attacks** — *both done.* Arrow:
      `Attack.physical_ranged()` (band `3..6`, physical, `ARROW`), via a per-unit `weapon_type`
      (`Unit.WeaponType`, archer → RANGED) that makes `Unit.basic_attack()` (renamed from
      `physical_attack`) pick melee vs ranged. Fireball: `Attack.fireball()` (band `2..5`,
      `MAGICAL` so `CombatResolver` reads `mag_atk`/`mag_def`, `FIREBALL` anim, `mp_cost 5`). The
      attack phase outlines the whole reach band (move-range black outline) and fills orange **only**
      the band tiles holding an enemy. Damage is plain `atk−def` for now (item-based ranged/spell
      tuning later).
- [x] **Projectile animations** — *both done* via a shared, awaitable `scripts/Projectile.gd`
      effect (sibling of `FloatingCombatText`): carries a caller-supplied *visual* node A→B with a
      parabolic arc (`arc_peak`) or straight line, and optional `face_travel` orientation. Arrow =
      a thin rod that lobs + noses along its arc; Fireball = a bloomed, firey-orange glowing
      **sphere** flying flat (`arc_peak 0`, `face_travel` off). Bloom needed WorldEnvironment
      **glow** enabled (HDR threshold 1.0 so only the emissive orb blooms). Bonk + death stay on
      `Unit` (reach a future `Boss` via `extends Unit`).
- [x] **Per-unit spell list + conditional "Spell" menu** — *done.* `Unit.known_spells`
      (mage starts with Fireball, defaulted in `_apply_appearance`); the action menu is built per
      active unit (`_menu_options_for`) so **"Spell"** shows only for casters. New **nested-submenu
      convention** (`SpellMenu.gd`): a submenu docks to the *right* of the menu that spawned it
      (which stays visible/highlighted), and **Left/Esc** backs out. Spell rows show name (left) +
      MP cost (right-aligned); unaffordable spells are greyed and selecting one flashes a
      "Not Enough MP" toast (~2s, fades). Picking an affordable spell enters `Phase.ATTACK` with its
      profile; MP is spent on commit (`Unit.spend_mp`).
- [x] **(stretch) enemy attacks** — *done.* Simple offense AI in `Main._take_enemy_turn`: pick the
      best available attack (affordable spell first, else weapon), strike if a target is already in
      range, else move toward the nearest enemy (least movement into the range band, or just closer)
      and try again, else move once more — all within the 2-action / 1-offensive budget. Reuses the
      shared `_commit_attack` (so enemy arrow/fireball/bonk animations + pauses come for free) and
      the player's move-phase overlays. Enemies reset to **level 1** for a fair test fight. Known v1
      limitation: a ranged enemy with no in-range reachable tile just walks *closer*, so it can
      step inside its own min-range and need a turn to re-kite. See `docs/DECISION_LOG.md`.

### After the single battle is fun — the run loop
Sequenced deliberately: finish a *complete, fun single battle* first, then a minimal
between-battles loop, and only **then** open the big game-flow discussion. Don't leapfrog.
- [ ] **Battle → reward → next battle loop** — `Battle.tscn` (the planned reusable battle
      scene) **returns a result** (who survived, loot/XP earned). After a win, show a **reward
      select** screen, then launch the next battle with the carried-over party. Needs the
      `Encounter` resource + a thin `RunState` (persistent party/bench, inventory) feeding the
      roster instead of `Main` hardcoding it. This is the spine the whole campaign hangs on.
- [ ] **★ BIG — resolve the "flow of the game" (roguelite campaign).** Design discussion +
      decisions for the meta-structure: a Slay-the-Spire-style branching **node map** per
      **act**, rest "tents" / shops / events between battles, a unit **bench** with swapping,
      **loot → upgrades** (weapons / stat boosts / spells / jobs), in-run **build modifiers**
      ("poison melee", "archer crits") hooked into the combat pipeline, and **multi-act story**
      (possibly branching endings). **Decided:** *persistent party across a campaign-shaped map*
      (party carries over; runs are chapters). Everything else is open — see `docs/GAME_DESIGN.md`
      §9 for the full capture, the architecture mapping (`Encounter`/`RunState`/`Battle.tscn`
      returns a result), and the tensions to resolve (pacing, permadeath, power creep, narrative
      scope). **Do NOT start until the two items above are done.**

### Then
- [x] Turn order / turn-based loop — extracted as `TurnManager` (the first split off `Main`,
      via node composition + signals). FFT-style **Charge Time**: each `Unit` banks `ct`,
      ticks up by `speed`, acts at 100, carries the overflow — faster units act more often
      (shown as `CT n/100` on the stat panel). Emits `active_unit_changed` / `turn_ended`;
      `Main._on_active_unit_changed` reacts. Both sides take real turns. Enemies run the
      **player's own** move functions (enter move phase → reachable outline → preview the
      chosen path with `classify_path`/`show_path` → `_perform_move` → end) with
      `ENEMY_TURN_DELAY` pauses; only `_ai_pick_move` (random reachable tile) is
      enemy-specific. Added `Battlefield.find_path` (legal BFS route for the AI),
      `Unit.move_finished`, and a `CameraController.focus_on` slew that follows the active
      unit. See `docs/DECISION_LOG.md`.
- [x] **Re-settle units + apply fall damage on a time-shift** — coordinated by `Main` around the
      shift (not inside `advance_shift`, which stays unit-agnostic): `_capture_unit_heights` snapshots
      each unit's tile level *before* the terrain moves, then `_resettle_units_after_shift` slides
      every unit onto its tile's new surface (`unit_stand_world` — a rise "pops up", a drop "falls",
      and a tile that just became liquid sinks the unit in). Fall damage (`_fall_damage`) = `fall_levels
      − jump`, zero unless the excess is ≥ 1 level, round-half-down; a lethal fall is killed mid-
      cinematic. Owner's jump-based formula was chosen over the older `temporal_resist` idea noted here.
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

- [x] **`TurnManager`** — owns `_active_unit` + the CT (speed) turn queue; replaced
      `_cycle_active_unit`/`_player_units`. Emits `active_unit_changed(unit)` / `turn_ended(unit)`
      (+ `map_transition_due` / `map_transition_countdown`). `Main._on_active_unit_changed`
      reacts (title, status, marker, player/enemy branch) instead of `Main` hard-wiring them.
      First extraction landed — the rest below remain.
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

The move to **node composition + signals** as the battle architecture landed with the
`TurnManager` extraction — logged in `docs/DECISION_LOG.md` (2026-06-21).

## Polish / nice-to-have
- [ ] **Battle grid-outline view setting** — a player-toggleable option to show/hide a dark
      outline around every tile edge during battle (off by default). The map builder already
      draws this (always-on, via `EditableBattlefield._rebuild_grid_overlay`, now covering tile
      tops AND cliff-face posts on every dropped/border edge); promote that complete overlay
      into the base `Battlefield` as an optional layer the main game can switch on/off, so the
      board reads clearly for players who want it.
- [ ] **Persist loadouts to disk** — `PartyLoadout` keeps the party's gear in memory only, so it
      resets each launch. Save/load it (`ResourceSaver`/JSON in `user://`) so choices stick between
      sessions. The natural home is the `RunState` work (it would own this) — see the run-loop item.
- [ ] **Loadout menu polish** — character portrait art (the frame is a placeholder); maybe show
      MOV/JMP/SPD only if they ever change; a "reset to default kit" option; controller/gamepad nav.
- [ ] **Menu polish pass (all scenes)** — more loadout-menu font/proportion/layout fixes (the bump in
      `38539f1` was a first pass), and a general look-and-feel polish across every menu/HUD (loadout +
      battle action/spell/status/shift/end screens) so they read as one consistent, tuned UI.
- [ ] **★ Global UI theme system** — extract the look-and-feel into one shared place so the whole game
      inherits it (today every scene sets fonts/colors via scattered per-widget `add_theme_*_override`
      calls; the map designer's local `_ui_theme` was the first taste). Plan: a **project-default
      `Theme` `.tres`** assigned via `gui/theme/custom` (fonts + styleboxes — every `Control` inherits
      automatically), plus a **`UiPalette.gd`** of semantic color constants (ally/enemy/accent/hazard/
      panel-bg/highlight, the way `TileTypes` centralizes terrain colors). Keep **scale** separate from
      **look**: the `UiScale` autoload (already wired, `content_scale_factor`, default 1.0) stays the
      one scale knob — wire a user "UI scale" setting to `UiScale.apply()` later. The real work is the
      **migration**: remove the inline overrides scene-by-scene so they inherit the theme, with a visual
      check on each (battle HUD, Loadout, designer) — a cross-cutting refactor, do it as its own focused
      pass (not speculatively). Folds together with the menu-polish item above. Decided 2026-06-25.
- [x] **Equipment + multiplicative damage model** — weapons/armor now carry a chunk of the damage
      budget (the fix for "everything does 1 damage"). `offense = round(atk × weapon.power)`,
      `mitigation = round(def × Σarmor × scale)`, two global knobs (`ARMOR_PHYS_SCALE 0.16` /
      `ARMOR_MAG_SCALE 0.18`). Two hand + three armor slots on `Unit`; 8 weapons + 4 equal-budget
      armor sets + shield with wield requirements; `Equipment` resource + in-code catalog
      (`scripts/items/Equipment.gd`); accuracy hook wired (dormant). Class default loadouts at spawn.
      See `docs/EQUIPMENT.md` + `docs/DECISION_LOG.md` (2026-06-23).
- [ ] **Combat balance pass — playtest tuning.** The equipment math above replaces the old
      bottom-out-at-1 subtractive formula; the next step is *feel it in real fights* and tune the two
      `ARMOR_*_SCALE` knobs + individual `power`/`armor_*` values. Open questions to validate in play:
      does a plate soldier feel right vs medium weapons (currently ~5–7/hit)? is the wand too chippy?
      do HP pools (~16–35) and the 2-action/1-offensive budget give a satisfying round count? Revisit
      the small-numbers philosophy in `docs/GAME_DESIGN.md` only if the multiplicative spread fights it.
- [ ] Live-update visible stat blocks (HP/MP/CT) — the `StatPanel` (hover) and `StatusPanel`
      (status box) call `Unit.stats_panel_text()` once when shown, so a block on screen when a
      unit takes damage / spends MP / charges CT shows stale numbers. Refresh while visible
      (re-fetch the text each frame, or — better — have `Unit` emit a `stats_changed` signal that
      the open panels listen to and re-render). Same applies to the active unit's status box mid-turn.
- [ ] Distinguish committed-waypoint tiles from the hover tail in the path preview
      (e.g. a stronger color), and maybe a destination marker
- [ ] Tune `Unit.MOVE_SPEED` and the step cadence once real maps exist

## Later / backlog
- [ ] Tile selection + highlight on hover/click
- [ ] Unit movement tile-to-tile (with movement range based on grid distance + Z cost)
- [ ] Turn order / turn-based loop
- [ ] Multiple grid sizes
- [x] Basic combat (attack range, damage) — melee first pass done (see "Done" above); ranged +
      magic are the "Next up" items.
- [ ] Character classes (soldier/archer/mage) + class-driven stat blocks — see `docs/GAME_DESIGN.md` §2–3
- [x] Time-degradation map shift every N turns — trigger + cadence + cinematic (turn-counted in
      `TurnManager`, cinematic in `Main`) **and** units now re-settle + take fall damage on the shift
      (see the "Re-settle units + apply fall damage" item above). §4
- [~] Shift telegraph + hold-to-preview "what-if" view — *basic telegraph done* (the
      `ShiftCounter` countdown); **still TODO: the hold-to-preview "what-if" terrain view**
      (`Battlefield.peek_next_state` already exposes the data). See `docs/GAME_DESIGN.md` §4
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
