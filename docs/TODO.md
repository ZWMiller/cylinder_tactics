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

## Next
- [ ] `Unit` scene + script — cylinder (+ cone hat for class) that knows its grid coordinate
- [ ] Promote grid <-> world helpers out of `Battlefield` into a shared coordinate module
      (tile -> world done; still need click/ray -> tile)
- [ ] Re-settle units + apply fall damage inside `advance_shift()` (currently terrain-only)

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

## Notes / things learned
- A camera looks down its own -Z axis. A transposed rotation matrix = inverse
  rotation, which silently aims the camera the wrong way (classic black-screen bug).
- Prefer setting Position/Rotation separately, or `look_at(Vector3.ZERO, Vector3.UP)`
  in code, instead of hand-writing `Transform3D(...)` matrices.
- Godot ignores unrecognized files (like this one). Drop an empty `.gdignore` in a
  folder to make Godot skip it entirely.
