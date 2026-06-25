# Pre-battle loadout menu

The gear-up screen the game boots into. The player equips each party member, then "Begin Battle"
loads the battle carrying the choices. Code: `scripts/Loadout.gd` + `scenes/Loadout.tscn` (the menu),
`scripts/PartyLoadout.gd` (the cross-scene state autoload). Equipment model: `docs/EQUIPMENT.md`.
Decision rationale: `docs/DECISION_LOG.md` (2026-06-23, "Pre-battle loadout scene").

## Scene flow

```
Loadout.tscn  ──"Begin Battle" (Yes)──▶  Main.tscn (the battle)
   (run/main_scene)                          reads PartyLoadout for the party + gear
```

`Loadout.tscn` is now the project's `run/main_scene`, so the game opens on the menu. Pressing
**B** / clicking **Begin Battle** raises a **Proceed to battle? Yes/No** confirm; only **Yes** calls
`change_scene_to_file("res://scenes/Main.tscn")`.

## `PartyLoadout` (autoload) — the cross-scene bridge

Scene changes free the old scene tree, so anything chosen in the menu must live *outside* it to reach
the battle. `PartyLoadout` is an **autoload singleton** (registered in `project.godot` `[autoload]`)
that persists for the whole program. It owns:

- **`party`** — the roster (the three authored recruits + their start tiles). Moved here out of
  `Main`, so the menu and the battle share one definition of the squad. `Main._ready` iterates
  `PartyLoadout.party` to spawn players.
- **`_loadouts`** — each member's equipment, keyed by their `Recruit`. The value mirrors the five
  mounts on `Unit`: `{ hands: [main, off], head, chest, boots }`.
- **`inventory()`** — the shared catalog: one of every item from `Equipment`'s factories (the
  "unlimited catalog" model — equipping never depletes it; any item type can be worn by several
  members).

Key methods:

- **`ensure_seeded()`** — called once when the menu opens; for any member without a stored loadout,
  mints a throwaway `Unit`, lets `init_from_recruit` equip the **class default kit**, snapshots it,
  and discards the unit. Guarantees every member has gear *before* any editing, so a character the
  player never touches still fights in their default kit (and the slots open populated, not empty).
- **`capture_from(recruit, unit)`** — snapshot a unit's mounts into storage (the menu calls this
  after every equip change).
- **`apply_to(unit, recruit)`** — copy a stored loadout onto a unit, recompute, and refill its pools.
  The menu uses it to sync display units; `Main._spawn_recruit` uses it so battle units wear exactly
  what the menu showed.

**In memory only** — this is the thin first cut of the planned `RunState` (GAME_DESIGN §9). Saving
to disk so gear sticks between sessions is a documented follow-up, not built yet.

## The menu screen

```
┌───────────────────────────────────────────────[Begin Battle ▶ (B)]┐
│ ┌───────┐  Bron            Soldier  Lv 1            ◀ Q     E ▶     │  TOP THIRD
│ │PORTRAIT│  HP   16   +2    MOVE          4                        │  character + stats
│ │ (frame)│  MP    0         JUMP          3                        │  (with live ±N preview)
│ └───────┘  PHY ATK 6  +1    ATTACK POWER 11  +2                    │
│            ...              TOTAL ARMOR  8/6                       │
│                            SET BONUS [x] Chainmail set            │
├──────────────────────────────┬────────────────────────────────────┤
│ EQUIPMENT                     │ INVENTORY                          │  BOTTOM TWO-THIRDS
│ > Main Hand: Straight Sword   │ > Straight Sword   PHY x1.80       │  left = slots,
│   Off Hand:  Shield           │   Bastard Sword    PHY x2.10 (grey)│  right = filtered items
│   Head:      Chain Coif       │   Dagger           PHY x1.20       │
│   Chest:     Chain Hauberk    │   ...                              │
│   Boots:     Chain Greaves    │                                    │
└──────────────────────────────┴────────────────────────────────────┘
```

- **Top third** — portrait frame (placeholder for future art), name / class / level, and the stat
  grid: HP, MP, PHY/MAG ATK, PHY/MAG DEF, EVA, MOVE/JUMP/SPEED, **ATTACK POWER** and **MAGIC POWER**
  (both shown so a weapon's effect on either channel is visible), **TOTAL ARMOR** (phys/mag sums),
  and a **SET BONUS** checkbox (ticked when a full matching set is worn, with the bonus described).
- **Bottom-left** — the five equip slots: Main Hand, Off Hand, Head, Chest, Boots.
- **Bottom-right** — the inventory.

### Live preview (the ±N)

While a slot is being edited, moving the highlight over an inventory item shows, beside each stat,
the **+N / −N** it would change to — green for a gain, red for a loss. This is computed by actually
applying the item to the (hidden) stat unit, reading its stats, and rolling the change back, so the
numbers come from the **same code the battle uses** (`Unit` stats, `CombatResolver.offense`,
`Equipment.set_bonus`) — never a re-implementation. The unit isn't really changed until you confirm.

### Two ways into the inventory

- **Edit a slot** (Enter or click a slot row): the inventory **filters** to items valid for that slot
  (no swords under Head; the off hand excludes two-handers), leads with an **(Empty)** unequip row,
  and shows the live preview. **Enter** equips (and persists); **Esc** backs out unchanged.
- **Browse** (Tab, or click the inventory panel): the **whole catalog**, view-only — scroll to see
  everything, no preview, no change.

Items the character **can't wield** (fails the stat requirement, e.g. a mage and a Bastard Sword)
are shown **greyed** and refuse to equip — consistent with the spell menu's grey-out convention.

## Controls

| Input | Action |
|---|---|
| ↑ / ↓ | Move the cursor in the active panel |
| Enter | Equip-panel: open the slot's inventory · Inventory (editing): equip the item |
| Esc | Back out of the inventory to the slots |
| Tab | Switch the active bottom panel (browse the full catalog) |
| Q / E | Previous / next character (**blocked while a slot is mid-edit**) |
| B | Begin Battle (raises the Yes/No confirm) |
| Mouse | Click slots / rows / arrows / Begin; double-click an item (editing) equips it |

Character switching is refused while a slot is being edited (uncommitted) so the live-preview
snapshot can't be stranded on a unit you've navigated away from — equip or cancel first.

## How the menu computes stats without a battlefield

The scene spawns one **invisible `Unit` per member** (parented in, but never rendered — there's no
`Camera3D` in this scene). The menu drives their real `equip_to_slot` / `recompute_stats` and reads
their numbers, so it reuses all of the combat code instead of duplicating any of it.

## Unit equipment API added for the menu

`Unit` gained slot-targeted equipment methods so the menu can address a specific mount:

- `equip_to_slot(item, LoadoutSlot)` / `clear_slot(LoadoutSlot)` / `item_in_slot(LoadoutSlot)` — the
  `LoadoutSlot` enum (`MAIN_HAND`, `OFF_HAND`, `HEAD`, `CHEST`, `BOOTS`) is the named-slot vocabulary;
  `equip_to_slot` keeps the two-hand invariant (a two-hander spans both hands; an off-hand drops a
  held two-hander).
- `active_weapon()` / `active_set_id()` — readouts for the panel.
- `CombatResolver.offense(attacker, physical)` — the **offense** term `round(atk × weapon.power)`
  exposed publicly (and reused by `compute_damage`), so ATTACK/MAGIC POWER read the exact combat math.

## Extending / follow-ups

- **Save to disk** so loadouts persist between sessions (the `RunState` follow-up).
- **Portrait art** — the top-left frame is a placeholder.
- **Limited inventory / loot** — today the catalog is unlimited; a quantity-tracked inventory arrives
  with the loot system (`docs/TODO.md` run-loop).
- **Enemy/bench/party editing** — only the three fixed PCs are editable for now.
