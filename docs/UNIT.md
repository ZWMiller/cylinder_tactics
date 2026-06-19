# Unit — the character "model"

The on-board character: a **cylinder body** wearing a **hat**, built as a small
reusable scene you stamp out copies of and reskin. Implements the visual language
in `docs/GAME_DESIGN.md` §7.

## Two independent visual channels

A unit encodes two things at once, on two separate parts, so any class can appear
on either side without ambiguity:

| Channel        | Part         | Encodes     | How it varies                                  |
| -------------- | ------------ | ----------- | ---------------------------------------------- |
| **Allegiance** | cylinder body| player/enemy| body **color** (blue = player, red = enemy)    |
| **Class**      | hat          | soldier/…   | hat **shape _and_ color**                      |

Current class hats:

| Class   | Hat shape          | Hat color          |
| ------- | ------------------ | ------------------ |
| Soldier | square (box)       | steel / silver     |
| Archer  | pyramid            | dark green*        |
| Mage    | cone               | violet             |

\* deliberately darker than the grass surface so an archer never camouflages.

Class reads off the hat, side reads off the body — they never collide, so a player
mage and an enemy mage share a hat but differ in body color, and a player soldier
vs. player mage share a body color but differ in hat.

## Files

- **`scenes/Unit.tscn`** — the *node layout* only: a `Body` (`MeshInstance3D`,
  cylinder) and a `Hat` (`MeshInstance3D`). Authored with real meshes so the unit
  previews correctly in the editor; at runtime `Unit.gd` swaps the hat mesh and
  recolors both. This is the **hybrid** approach — visual structure as an editable
  scene, behavior/identity in script.
- **`scripts/Unit.gd`** (`class_name Unit`) — the self-contained object: owns its
  `allegiance`, `unit_class`, `grid_coord`, and (later) stats/combat. Applies the
  appearance and seats the hat on the body.
- **`scripts/UnitClasses.gd`** (`class_name UnitClasses`) — the class table: maps
  each class to a hat color + hat-shape factory. Mirrors `TileTypes.gd`, and is the
  intended home for class-driven stat templates later (`GAME_DESIGN.md` §2–3).
- **`scripts/Main.gd`** — throwaway demo glue that spawns a player row and an enemy
  row of all three classes on F5. Real spawning will come from encounter data.

## How to spawn and reskin

```gdscript
const UNIT_SCENE := preload("res://scenes/Unit.tscn")

var u: Unit = UNIT_SCENE.instantiate()
u.configure(Unit.Allegiance.ENEMY, UnitClasses.Class.MAGE)  # side + class in one call
add_child(u)
u.position = battlefield.tile_to_world(x, z)                # stand on a tile
```

`configure()` is safe before or after the unit enters the tree.

### Why each unit owns its materials (the reskin gotcha)

Godot materials are **resources**, i.e. shared *state* when shared. If two units
referenced one `StandardMaterial3D`, recoloring one would recolor the other. So
`Unit` builds a **fresh material per instance** (`material_override`); that is what
makes "spawn many, tint each freely" work. Same reason `UnitClasses.new_hat_mesh`
returns a **new mesh per call**.

## Adding or changing a hat shape

Hat geometry is decided in **one place** — `UnitClasses.new_hat_mesh` — by a
`match` on class. To change a class's shape, point its line at a different shape
factory (`_cone` / `_pyramid` / `_square_hat`, or a new one). `Unit` seats the hat
by **measuring** whatever mesh it gets (`Unit._mesh_height`), so a taller or
blockier hat needs no change in `Unit.gd`.

Shape trick worth knowing: a `CylinderMesh` with `top_radius = 0` tapers to a point
— a **cone**; give it `radial_segments = 4` and the round base collapses to a
square — a **pyramid**. (Godot has no dedicated Cone/Pyramid primitive.)

## Known limitations / next steps

- Units do **not** re-settle when the map shifts (Space) yet — their Y stays put,
  so they'll float/sink until `Battlefield.advance_shift()` re-seats them and
  applies fall damage (see `docs/TODO.md`).
- `grid_coord` is stored but not yet used for movement/selection.
- Stats are not modeled yet; `UnitClasses` is where class stat templates will go.
