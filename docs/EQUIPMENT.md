# Equipment & the damage model

How weapons and armor plug into combat. Code: `scripts/items/Equipment.gd` (the resource +
in-code catalog), `scripts/combat/CombatResolver.gd` (the math), `scripts/Unit.gd` (slots,
requirements, default loadouts). Decision rationale: `docs/DECISION_LOG.md` (2026-06-23).

## The damage model (multiplicative)

```
offense    = round(atk_stat × equipped_weapon.power)        # unarmed power = 1.0
mitigation = round(def_stat × Σ(equipped armor) × scale)    # unarmored Σ = 0 → 0 mitigation
damage     = max(1, offense − mitigation)
```

- `round` = round-half-up, `floor(x + 0.5)` (a forgiving round, shared by offense and mitigation).
- **Channel** comes off the `Attack`: physical uses `phys_atk`/`phys_def` and a physical weapon;
  magical uses `mag_atk`/`mag_def` and a staff/wand. So an equipped staff is what makes a Fireball
  hit hard — `weapon.power` *is* the spell power.
- **Asymmetric baselines, on purpose:**
  - Unarmed **offense** = 1.0 → your raw attack stat *is* your damage; a weapon scales it up.
  - Unarmored **mitigation** = 0 → the defense *stat* is a multiplier on armor and does nothing
    without it. An undefended unit eats full hits ("crazy damage to the unarmored").

### The two scale knobs

`CombatResolver.ARMOR_PHYS_SCALE = 0.16` and `ARMOR_MAG_SCALE = 0.18` are the global dials for
"how effective is armor relative to damage." Armor pieces are authored as chunky numbers; the knob
converts the *summed* armor into felt mitigation. Move one knob to retune all armor of that channel;
edit one piece to fix just that piece. Two knobs so physical and magical lethality tune separately.

## Weapons

| Weapon | Slot | Channel | power | Requirement | Notes |
|---|---|---|---|---|---|
| Dagger | 1H | physical | 1.2 | phys_atk ≥ 1 | universal fallback |
| Rapier | 1H | physical | 1.5 | speed ≥ 7 | +1 speed rider |
| Straight Sword | 1H | physical | 1.8 | phys_atk ≥ 5 | soldier staple |
| Bow | 2H | physical | 2.0 | speed ≥ 7, phys_atk ≥ 4 | ranged (archer) |
| Bastard Sword | 2H | physical | 2.1 | phys_atk ≥ 7 | level-1 soldier can wield, archer can't |
| Magic Wand | 1H | magical | 1.2 | mag_atk ≥ 5 | sub-staff spell power |
| Magic Staff | 2H | magical | 1.55 | mag_atk ≥ 8 | level-1 mage can wield |
| Shield | 1H | none | — | none | +2 armor_phys / +1 armor_mag |

A weapon's `power` multiplies the wielder's attack stat. `accuracy` (1.0 on everything) is a dormant
hook for the future hit formula (`attacker_acc × weapon.accuracy − dodge`); `hit_chance` still mocks 1.0.

### Who can wield what (level-1 class stats)

| | Dagger | Rapier | Straight | Bow | Bastard | Shield | Wand | Staff |
|---|---|---|---|---|---|---|---|---|
| Soldier | ✓ | ✗ | ✓ | ✗ | ✓ | ✓ | ✗ | ✗ |
| Archer | ✓ | ✓ | ✓ | ✓ | ✗ | ✓ | ✗ | ✗ |
| Mage | ✓ | ✗ | ✗ | ✗ | ✗ | ✓ | ✓ | ✓ |

Requirements are checked against effective `max_stats`, so leveling/aptitude can open new weapons,
and a rolled enemy that rolls below a floor simply goes without (fights unarmed in that channel).

## Armor

Five mounts contribute to the armor sums: **two hands** (shields), **head/chest/boots**. A 2H weapon
fills both hands (no shield). Each armor *set* totals the same **14** defense budget, split along the
phys↔mag axis — armor is a trade-off, not a ladder.

| Set (per piece phys/mag) | Head | Chest | Boots | **Σ phys** | **Σ mag** |
|---|---|---|---|---|---|
| **Cloth** | 1/3 | 3/4 | 1/2 | 5 | 9 |
| **Leather** | 2/2 | 3/4 | 1/2 | 6 | 8 |
| **Chainmail** | 2/2 | 4/3 | 2/1 | 8 | 6 |
| **Plate** | 3/2 | 4/2 | 2/1 | 9 | 5 |
| **Shield** (hand) | — | — | — | +2 | +1 |

Because mitigation is `def_stat × Σarmor × knob`, the class defense stat decides how much a set is
worth: a soldier (high phys_def) gets more from phys-heavy armor, a mage (high mag_def) from mag-heavy
— but a mixed enemy comp rewards the balanced **Chainmail**, which is the point.

### Set bonuses

Wearing a full matching armor set (head + chest + boots, same `set_id`) grants a bonus rider folded
into `max_stats`; a partial set grants nothing. Defined centrally in `Equipment.set_bonus`, checked by
`Unit._active_set_bonus`, and shown on the inspect panel as `[<set> set]`.

| Set | Full-set bonus |
|---|---|
| **Cloth** | +1 mag_atk, +1 evasion (dodge) |
| Leather / Chainmail / Plate | none yet |

`evasion` is the reserved "dodge" stat: stored and displayed (EVA on the panel) now, but inert until
the accuracy/dodge hit formula is built — the same dormant hook as `Equipment.accuracy`. Add more set
bonuses by extending the `match` in `Equipment.set_bonus`.

### Mitigation by class × set (phys / mag, round-half-up)

| | Cloth | Leather | Chainmail | Plate |
|---|---|---|---|---|
| **Soldier** (pdef5/mdef2) | 4 / 4 | 5 / 3 | 6 / 2 | 7 / 2 |
| **Archer** (pdef3/mdef3) | 2 / 5 | 3 / 4 | 4 / 3 | 4 / 3 |
| **Mage** (pdef2/mdef5) | 2 / 8 | 2 / 7 | 3 / 5 | 3 / 5 |

## Feel check (verified against the live pipeline)

| Attack (offense) | net result |
|---|---|
| Bastard Sword, Bron → Plate Soldier | 10 |
| Bow, Dart → Plate Soldier | 5 |
| Staff-Fireball, Wisp → Plate Soldier | 12 |
| Staff-Fireball, Wisp → Cloth Mage | 6 |
| Wand-Fireball, Wisp → Cloth Mage | 3 |

The rock-paper texture: the **plate soldier** walls physical but melts to magic; the **cloth mage**
soaks magic but folds to a blade; **chainmail** has no hole and no peak — the genuine third pick.

## Default loadouts (until inventory/loot lands)

`Unit.default_loadout_for_class` equips a class kit at spawn (after stats exist, so requirements can
be checked): **Soldier** = Straight Sword + Shield + Chainmail; **Archer** = Bow + Leather; **Mage**
= Staff + Cloth. Hover a unit (StatPanel) to see its `GEAR`/`ARMOR` line.

## Extending

- New item → add a `static` factory in `Equipment.gd` (mirror an existing one). Authoring `.tres`
  items + an equip UI comes with the loot/inventory system (see `docs/TODO.md` run-loop section).
- Stat riders (e.g. Rapier's +1 speed) go in an item's `modifiers` StatBlock, folded into `max_stats`
  by `Unit.recompute_stats` exactly like aptitude.
- Retune feel: the two `ARMOR_*_SCALE` knobs first (global), then individual `power` / `armor_*`.
