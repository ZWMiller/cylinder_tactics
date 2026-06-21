# Stat system

How a unit's numbers are defined, varied per individual, and changed by leveling and
reclassing. Built 2026-06-21. Design intent lives in `docs/GAME_DESIGN.md` §3; locked
decisions in `docs/DECISION_LOG.md`.

## The idea in one line

> **Effective stats = current class's base + banked level-up growth + per-person aptitude.**

Three independent inputs, added together, then floored at 0. Each input has its own home,
so each can vary independently: the **class** is a swappable job, the **aptitude** is the
person, and the **banked growth** is the history of how they leveled.

## Pieces (all in `scripts/stats/`)

| Type | Kind | Role |
|------|------|------|
| `StatBlock` | `Resource` | The 11-number schema. Reused for *base*, *growth*, *aptitude*, and *banked* totals. |
| `ClassDef` | `Resource` (`.tres`) | A class/job: its level-1 `base` and per-level `growth`. |
| `Recruit` | `Resource` (`.tres` or rolled) | The *person*: `display_name`, innate `aptitude`, `starting_class`, `starting_level`. |
| `StatRoll` | static namespace | Mints a randomized `Recruit` for enemies at spawn. |

The data assets:
- `assets/classes/soldier.tres`, `archer.tres`, `mage.tres` — the `ClassDef`s.
- `assets/recruits/bron.tres`, `wisp.tres`, `dart.tres` — authored PC `Recruit`s.

`UnitClasses.gd` bridges the visual class enum to the stat assets (`class_def()`,
`banked_growth()`). `Unit.gd` owns the per-unit live state and the verbs that change it.

## Why Resources (and a Godot gotcha)

A `Resource` is Godot's serializable **data asset** — `@export` fields show in the
Inspector and save to a `.tres` text file. Think of it as a `@dataclass` the engine can
edit in a GUI. That's why class numbers live in `.tres`: **tune them without touching
code.**

**Gotcha (the same one materials hit in `Unit.gd`):** Resources are shared *by reference*.
If two units pointed at one `StatBlock` and one mutated it, both would change. So:
- every `StatBlock` op (`combined`, `scaled`, `clamped_nonneg`) returns a **new** block,
- shared templates (a `ClassDef.base`) are treated as **read-only**,
- the only mutable per-unit stat state is `current_hp` / `current_mp`, which live on the
  `Unit`, never on a shared template.

## The schema (`StatBlock`)

`max_hp, max_mp, move, jump, speed, phys_atk, mag_atk, phys_def, mag_def, evasion,
temporal_resist`. All small integers (the **small-numbers philosophy** — see GAME_DESIGN
§3). `evasion` and `temporal_resist` are reserved: fields exist now, effects land with
combat and the time shift respectively.

## Leveling = a job history you bank (FFT-style)

`Unit.level_history` is an array holding **the class the unit was when it gained each
level** (one entry per level above 1). `UnitClasses.banked_growth(history)` sums each of
those classes' `growth`. So:

- `level_up()` appends the *current* class to the history and recomputes (and heals the
  HP/MP gained).
- `set_class(klass)` swaps the base + appearance but **keeps the history** — the growth
  you banked under old jobs persists.

That persistence is the whole job system: level early as a Mage, switch to Soldier, and
your Soldier still carries the mage's MP/MAG. Players **craft** characters by choosing
*what to be while leveling*.

We store *which class at each level* and recompute from the current tables (not a snapshot
of numbers), so retuning a `growth` table updates every existing unit — keeping the data
tunable.

> **Not here yet:** the **promotion / job tree** (which classes unlock at which level) is a
> separate future resource, deliberately kept out of `ClassDef`.

## Two ways to make units differ

- **Authored (PCs):** hand-made `Recruit.tres` with a deliberate aptitude (Bron is brawny,
  Wisp is frail-but-clever, Dart is nimble). Edit in the Inspector.
- **Rolled (enemies):** `StatRoll.random_recruit(class_id, level, rng)` mints a `Recruit`
  with a small random aptitude — "give me a level-5 random Mage" in one call. Pass a seeded
  RNG for reproducible encounters.

Both produce a `Recruit`, and `Unit.init_from_recruit()` consumes either identically.

## Spawning a unit from a recruit

```gdscript
var u := UNIT_SCENE.instantiate()
u.init_from_recruit(load("res://assets/recruits/bron.tres"))  # or StatRoll.random_recruit(...)
add_child(u)            # _ready runs; appearance + stats already set
# later:
u.level_up()            # gain a level in the current class
u.set_class(UnitClasses.Class.MAGE)   # reclass; banked growth persists
print(u.stats_summary())
```

Units spawned the old appearance-only way (`configure(side, class)`, no recruit) still get
valid stats: `Unit._ready` derives a baseline from the class base and fills the pools.

## Adding content

- **A new class:** add `assets/classes/<name>.tres` (a `ClassDef` with `base` + `growth`),
  add its enum value in `UnitClasses.Class`, and add one entry to `UnitClasses.CLASS_DEFS`.
  (Hat shape/color also live in `UnitClasses` — see `docs/UNIT.md`.)
- **A new PC:** add `assets/recruits/<name>.tres` (a `Recruit`).
- **Retune anything:** just edit the `.tres` numbers; no code change.

## First-draft numbers (all tunable in `.tres`)

| | Soldier | Archer | Mage |
|--|--|--|--|
| base HP / MP | 32 / 0 | 24 / 4 | 18 / 12 |
| base PATK / MATK | 7 / 1 | 6 / 2 | 2 / 8 |
| base PDEF / MDEF | 5 / 2 | 3 / 3 | 2 / 5 |
| move / jump / speed | 4 / 2 / 5 | 5 / 3 / 7 | 3 / 2 / 6 |
| growth / level | +1 HP, +1 PATK | +1 PATK, +1 SPD | +1 MP, +1 MATK |
