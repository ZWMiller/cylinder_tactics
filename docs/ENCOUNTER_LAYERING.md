# Encounter Layering

**What is an "encounter"?** The whole saved *fight* — the terrain it happens on (including how
that terrain shifts over time), the enemies and where they stand, where the player deploys, and
how you win. It is built up out of several smaller, independently-reusable resources rather than
one giant blob, which keeps each piece shareable but does mean there's a **nesting** worth spelling
out. This doc is the map of that nesting.

> TL;DR of the stack (outermost → innermost):
> **`Encounter` → `MapSequence` → `MapData` → `MapState`**, and off to the side the `Encounter`
> also directly holds **`EnemyPlacement`s** and named **regions** (deploy / win).

---

## 1. The nesting at a glance

```
Encounter                     (assets/encounters/*.tres)   — the whole fight
├── map_sequence : MapSequence (assets/sequences/*.tres)   — terrain over time
│   └── maps[]   : String → MapData (assets/maps/*.tres)   — one terrain snapshot each
│       └── states[] : MapState                            — height/type grid (usually 1)
│       + turns_after[] : int                              — turns before shifting to the next map
│       + anchors[]     : Corner                           — alignment corner (variable-size shifts)
├── enemies[]   : EnemyPlacement                           — who to spawn, and where
│   └── { id, tile, klass, level, overrides }
└── regions     : Dictionary<String, tiles>               — named tile sets
    ├── "deploy" → where the party may start
    └── "win"    → reach-to-win objective tiles
```

The player's party is **not** part of the encounter — who's in the squad and their gear is a
between-battles concern (`PartyLoadout` / the future `RunState`). The encounter only says **where**
the party deploys (the `deploy` region).

---

## 2. Each layer, from the inside out

### `MapState` — one grid of terrain
`scripts/maps/MapState.gd`. The lowest level: flat, row-major arrays of per-tile `heights`, surface
`types`, side `bodies`, etc. for **one** moment of terrain. This is the raw shape a `Battlefield`
renders and walks on. You never author a `MapState` directly; it lives inside a `MapData`.

### `MapData` — one saved map (a "snapshot")
`scripts/maps/MapData.gd` → `assets/maps/*.tres`. A named, variable-size map: its `width`/`height`
and an ordered `states` list. **Authored in the Map Builder.** Reusable across many fights.

> **Two ways to have "multiple states" — don't conflate them.** A `MapData` *can* itself hold
> several internal `MapState`s (the original time-shift mechanism, e.g. the procedural `DemoMap`'s
> grassland → canyon → desert). The **new** authoring model instead expresses the shift as a
> `MapSequence` of *separate, single-state* `MapData` files (see below). Both ultimately feed the
> same runtime idea — "a battle plays through an ordered list of terrain states" — but the sequence
> approach lets you build, view, and reuse each snapshot as its own file. New maps authored for the
> shift should be single-state files chained by a `MapSequence`.

### `MapSequence` — terrain over time (the shift chain)
`scripts/maps/MapSequence.gd` → `assets/sequences/*.tres`. An **ordered chain of maps** plus the
cadence between them:
- `maps[]` — `res://` paths to the `MapData` snapshots, in shift order (`maps[0]` is the start).
- `turns_after[]` — character turns spent on each map before the shift moves to the next (the last
  wraps back to the first). Default 10.
- `anchors[]` — a `Corner` (NW/NE/SW/SE) per map: which corner stays pinned when consecutive maps
  are **different sizes** (a growing/crumbling map). Authored now; only the *deferred* variable-size
  runtime shift reads it (until then chains are effectively same-size — `is_uniform_size()` warns,
  doesn't block).

It's its **own reusable resource** so different encounters can share one degradation chain, the same
way many encounters reuse one `MapData`. A static (non-shifting) battle is just a length-1 sequence.

### `EnemyPlacement` — one enemy
`scripts/encounter/EnemyPlacement.gd`. A pure spec: `tile` (where), `klass` + `level` (what — rolled
into a `Recruit` via `StatRoll`, same path the demo roster used), an optional `id` (a stable handle
so a scripted battle can grab a specific unit by name), and a reserved `overrides` dict (per-stat /
kit tweaks — Phase 3b, currently unread). An `Encounter` owns an `Array[EnemyPlacement]`.

### `Encounter` — the whole fight
`scripts/encounter/Encounter.gd` → `assets/encounters/*.tres`. Ties it together:
- `map_sequence : MapSequence` — the terrain (usually a reference to a shared sequence file; the
  typed field also accepts an embedded one). Start on `first_map_path()`.
- `enemies : Array[EnemyPlacement]` — the opposition.
- `regions : Dictionary` — **named** tile sets, stored as flat `[x,z,x,z,…]` packed arrays. Two keys
  are interpreted by the engine — `"deploy"` (party start zone) and `"win"` (reach-to-win tiles) —
  and any *other* key is free for per-battle scripts (`"shrine"`, `"levers"`, …). Read via
  `region(name)`, which unpacks to `Vector2i`s.

---

## 3. Why so many layers? (the reuse rule)

Each split exists so the inner thing is **reusable without dragging the outer thing along**:

| You want to reuse… | …across… | so it's its own file |
|---|---|---|
| a terrain snapshot | many fights, many chains | `MapData` |
| a whole shift chain | many fights | `MapSequence` |
| a fight | (nothing reuses a fight) | `Encounter` |

The consistent principle: **reference by path, don't embed.** An `Encounter` references a
`MapSequence` by path; a `MapSequence` references `MapData`s by path. So editing a map in the Map
Builder updates every sequence and encounter that points at it — no copies to keep in sync.

---

## 4. Who authors what (two single-purpose tools)

Deliberately **one document type per tool**, so "what does Save write?" is never ambiguous:

| Tool | Scene | Edits | Saves to |
|---|---|---|---|
| **Map Builder** | `scenes/MapDesigner.tscn` | terrain (`MapData`) | `assets/maps/` |
| **Encounter Builder** | `scenes/EncounterBuilder.tscn` *(being built)* | the `MapSequence` chain + `EnemyPlacement`s + regions, saved as an `Encounter` (+ its sequence) | `assets/encounters/` (+ `assets/sequences/`) |

Change terrain? Go to the Map Builder, edit, save. The Encounter Builder only *references* maps —
it never edits terrain.

---

## 5. How a battle consumes an encounter

`BattleBase` (`scripts/BattleBase.gd`) is the reusable battle coordinator (`Main extends BattleBase`
is the demo; a future scripted fight is `Battle5 extends BattleBase`). On `_ready` it:
1. `_resolve_encounter()` — gets the `Encounter` (from the `encounter_path` export / a subclass /
   the quick-test hand-off), or `null` for the legacy demo.
2. `_spawn_from_encounter()` — loads `first_map_path()` into the `Battlefield`
   (`load_map_data`), deploys the party into the `deploy` region, and spawns the `enemies`.
3. **Win condition** — if there's a non-empty `win` region: a player who **ends their turn** on a
   win tile wins, OR wiping all enemies wins. No `win` region → elimination only (the demo).

**Data, not behavior.** An `Encounter` is a pure named-data bag — it holds *no logic*. A per-battle
script *loads* it and provides any reactive behavior (dialogue, moving objectives, puzzles); the
`id`s and named regions are what let that script grab exactly the pieces it needs. See
`docs/DECISION_LOG.md` (2026-06-30).

---

## 6. Deferred / not-yet-wired (so you know what's real today)

- **Sequence runtime chaining** — today the battle loads `maps[0]`; playing *through* the chain on
  shifts (with the per-transition `turns_after` cadence) is pending the Encounter Builder's MAPS area
  + a `TurnManager` change.
- **Variable-size shift** — chains of *different-sized* maps (the `anchors` corners) are authorable
  but the runtime (live grid resize + anchored morph + stranded-unit falloff) is a deferred feature.
- **`EnemyPlacement.overrides`** — per-stat / weapon / armor tweaks and named-character/boss
  placements are Phase 3b; unread for now.
- **The Encounter Builder scene** — being built; the backend above already works (hand-authored
  `assets/encounters/test_church.tres` plays via the `encounter_path` export).

---

## 7. File map

| File | Role |
|---|---|
| `scripts/maps/MapState.gd` | One terrain grid (flat height/type arrays) |
| `scripts/maps/MapData.gd` | One saved map (name, size, `states`) |
| `scripts/maps/MapSequence.gd` | Ordered map chain + `turns_after` + `anchors` (the shift loop) |
| `scripts/encounter/EnemyPlacement.gd` | One enemy spec (tile + class + level + id + overrides) |
| `scripts/encounter/Encounter.gd` | The whole fight (sequence + enemies + regions) |
| `scripts/BattleBase.gd` | Reusable battle coordinator that consumes an `Encounter` |
| `assets/maps/*.tres` | Saved maps |
| `assets/sequences/*.tres` | Saved shift chains |
| `assets/encounters/*.tres` | Saved fights |

See also `docs/BATTLEFIELD.md` (terrain engine), `docs/map_builder_implementation_plan.md` (§10 the
encounter builder), and `docs/DECISION_LOG.md` (the data-model decisions).
