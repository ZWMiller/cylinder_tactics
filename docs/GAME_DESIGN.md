# Cylinder Tactics — Game Design

High-level design vision for Cylinder Tactics. This is a **context document**, not
a spec: it records intent so that implementation decisions ("should X be a class or
a function?", "where does this state live?") can be made with the whole game in mind,
even while we build the base prototype first.

Status legend used throughout:
- **Now** — needed for the base prototype (maps, characters, turn order, basic shift).
- **Later** — deliberately deferred; documented here only so we don't paint
  ourselves into a corner.
- **Open question** — not yet decided; flagged so we decide deliberately, not by accident.

See `docs/TODO.md` for the live task list and `docs/DECISION_LOG.md` for locked-in
decisions and their rationale.

---

## 1. Pillars (what makes this game itself)

1. **FF-Tactics-style turn-based combat** on an isometric grid with real Z-height
   terrain (already the core of the project).
2. **Character classes** (soldier, archer, mage, …) shared by player and enemy units,
   each with class-driven stats and abilities.
3. **Time degradation** — the central gimmick. The world is decaying, so the map
   *shifts* every N turns: tile heights change underfoot, and units caught on a
   dropping tile fall and take damage. The shift is always **telegraphed** and the
   player can **preview** it on demand.
4. **The player's time-mage** — a unique protagonist who can bend the shift itself
   (accelerate it, trigger a single tile early, etc.). This is the player's signature
   toolset and a key source of tactical agency over the gimmick.

---

## 2. Character classes

**Intent:** Soldier, Archer, and Mage to start, with room for more. Classes apply
identically to **player and enemy** units — an enemy archer and a player archer share
the same class definition; only their stat values and AI/controller differ.

A **class** defines the *shape* of a unit:
- base stat profile / growth bias (e.g. soldier = high HP + melee; archer = range;
  mage = low HP + magic + AoE),
- which abilities the unit can use,
- movement characteristics (move range, how it pays for Z-height changes),
- attack profile (range, melee vs. ranged vs. magic).

**Open questions (defer until after prototype):**
- Are classes fixed per unit, or can a unit change/promote class (FFT job system)?
  *Leaning: fixed per unit for now; revisit if we want a job system.*
- Is the time-mage a **class** or a **special unit** that layers time powers on top
  of an ordinary class? See §5 — this is the first real "class vs. function" call.

---

## 3. Stat blocks

**Intent:** Every character has an underlying stat block. Stats **differ per
individual** but are **derived from / bounded by their class** (two soldiers differ,
but both read as soldiers).

### Small-numbers design philosophy (committed)

**Keep every number small and human-intuitable.** Stats and damage live in roughly
the **single- to low-double-digit** range — a unit has ~30 HP, a solid hit does ~6,
a point of defense shaves ~1. We deliberately reject the JRPG inflation curve where
hits read "12,480" against "2,500 defense": at that scale a single point is
meaningless and the player can't feel a tradeoff. Small numbers make every stat
point *matter* — a +1 jump, a 6-damage vs 5-damage hit, a 1-point resist are all
decisions the player can reason about at a glance. This bounds the whole economy:
HP, attack, defense, and damage formulas are all designed to stay legible, not to
grow without limit.

### Committed stat schema

Decided 2026-06-21 (see `docs/DECISION_LOG.md`). Three tiers by how "live" each stat
is — the *set* is fixed, but reserved stats may sit at a default until their system
ships. The genre model we follow is **Fire Emblem-style split offense/defense + a
derived hit chance** (not a D&D single-roll Armor Class): avoidance and toughness are
*separate axes* — hit% decides *whether* you connect, defense reduces *how much*.

**Live now / very soon** (have gameplay effects in the near-term roadmap):
- `max_hp` — health pool.
- `max_mp` — resource for abilities/spells (mages + time-mage; can be 0 for a soldier).
- `move` — tiles reachable per turn.
- `jump` — Z-height a unit can climb/descend in one step (the next gate to ship).
- `speed` — turn order / initiative (see §6).
- `phys_atk` — scales physical damage.
- `mag_atk` — scales magical damage.
- `phys_def` — mitigates physical damage.
- `mag_def` — mitigates magical damage (magic resist).

**Reserved** (field exists now with a sane default; effects land later):
- `evasion` — feeds a *hidden* hit-chance check (hit% = f(attacker accuracy, target
  evasion), shown to the player only as a resulting %). Combat ships **deterministic
  first** (always hit; `damage = atk − def`, floored at 1); the dice come later, but
  the field exists so the formula has a home.
- `temporal_resist` — this game's signature stat, since the whole design is built on
  the time shift. Dual purpose: (1) a save vs. **hostile time magic** (an enemy
  time-mage targeting this unit — §5), and (2) **fall-damage mitigation** from the
  environmental shift (§4). Reserved now; the fall-damage hook arrives with the shift
  re-settle work, ahead of any time powers.

**Deferred** (intentionally *not* in the schema yet — noted so they have an obvious
slot): crit chance, luck, and FFT-style Brave/Faith. The split offense/defense +
evasion set already gives ample spell-design surface (debuff defense, lower evasion,
magic that pierces resist); add these only if a concrete need appears.

**Design guidance:**
- A unit's stat block is **data**, not hardcoded per scene — consistent with the
  project's code-driven workflow. A class is a **base template**; an individual is a
  class template **plus per-unit overrides**. (How to *store* this — a custom
  `Resource` vs. a plain Dictionary — is the next decision; not yet locked.)
- Fall damage from the time shift (§4) reads from stats (`temporal_resist`, and drop
  distance), so it can scale or be resisted — never a hardcoded global constant.
- Damage formulas must respect the small-numbers philosophy above: keep mitigation
  subtractive and bounded, not a percentage curve that explodes at high values.

### Leveling & the job system (built 2026-06-21)

The stat layer lives in `scripts/stats/` as Godot **Resources**, with editable `.tres`
data assets (see `docs/STATS.md` for the full write-up and `docs/DECISION_LOG.md` for
rationale):
- `StatBlock` — the number schema, reused for base / growth / aptitude / banked totals.
- `ClassDef` (`assets/classes/*.tres`) — a class's `base` + per-level `growth`.
- `Recruit` (`assets/recruits/*.tres` for PCs; rolled by `StatRoll` for enemies) — the
  **person**: name + innate aptitude, decoupled from the job.

**Effective stats = class base + banked growth + aptitude.** Leveling is **path-dependent
(FFT-style):** a unit records the class it held at each level-up and permanently *banks*
that class's growth. Reclassing swaps the base but keeps the banked history — so leveling
as a Mage and later switching to Soldier carries the mage's MP/MAG gains along. This is
the intended **job system**: players *craft* a character through the sequence of jobs they
level in. (This resolves §2's "fixed vs. job-change" lean toward **job-change with
persistent per-level banking**.)

**Growth includes combat stats**, deliberately, so an un-promoted class is a viable build
on its own; promotions are a bonus, not a requirement. The **promotion / job-upgrade tree**
(which class unlocks which, at what level) is a *separate* future resource — kept out of
`ClassDef`, which stays a thin stat asset.

**Open question:** Resource model for abilities — MP pool, per-ability cooldowns,
charge/turn economy, or some mix? Especially relevant for time-mage powers (§5).

---

## 4. Time degradation — the map shift (core gimmick)

**Concept:** The world is degrading over time. Every **N turns** the map *shifts*:
the grid keeps (mostly) the same footprint, but **per-tile Z-heights change** — a
tile that was height 5 might become height 2. A unit standing on a tile whose height
**drops** falls to the new height and **takes fall damage** (scaled by drop distance).

This makes terrain a *clock*, not a static board: positions that are strong now may
be exposed, isolated, or lethal after the next shift.

**Behaviors to support (Now / Later):**
- **Now:** A shift event fires every N turns and rewrites tile heights from the next
  map state; units re-settle onto their tile's new height; falling units take damage.
- **Now (telegraph):** The upcoming shift must be **well telegraphed** — the player
  always knows a shift is coming and roughly when (e.g. a turn counter / countdown,
  and visual cues on tiles that are about to change).
- **Now (preview):** A **hold-to-preview** control — while held, show what the map
  *will* look like after the next shift (which tiles rise/fall, by how much, and which
  units would fall / take damage). Releasing returns to the current state. This is a
  read-only "what-if" view, not a committed action.
- **Later:** Tiles rising under a unit, units pushed off the grid edge, tiles
  appearing/disappearing entirely, hazard tiles — all possible extensions. Keep the
  shift representation general enough to allow them; don't hardcode "height only ever
  drops."

**Design guidance / "class vs. function" context:**
- The shift operates on **map/tile state**, so it belongs to the battlefield/grid
  layer, not to any unit. Units *react* to the shift (fall, take damage); they don't
  own it.
- Represent a map as a **sequence (or generator) of height states** over time, so the
  "current map" and the "next map" are both queryable. The preview feature needs the
  next state to exist *before* it is applied — design for this from the start, even
  though only the base apply-shift path ships first. This is the single most important
  structural implication of the gimmick.
- Fall damage and re-settling must run through the same grid<->world height helpers
  the rest of the game uses, so a shift can't desync a unit's grid coord from its
  world position.

**Open questions:**
- Is N fixed, configurable per map, or accelerating as the battle drags on?
- Is the shift sequence **authored per map** (designed encounters) or **procedurally
  generated**? *Authored is easier to telegraph and balance; lean authored first.*
- Do enemies "know" the shift is coming (AI plans around it) or only the player?

---

## 5. The time-mage (player's signature powers) — Later

**Concept:** The main player character is a **time-mage** with abilities that
manipulate the shift mechanic itself, e.g.:
- accelerate the shift (bring the next shift one turn closer),
- trigger a **single tile** to shift immediately (out of the normal cadence),
- (more powers TBD — not yet mapped).

**Explicitly deferred** until the base prototype works (maps, characters, turn order,
basic shift). Documented now only so the systems it touches are built to allow it.

**Design guidance / the key "class vs. function" call:**
- Time powers act on the **shift system** (the map's height-sequence / countdown),
  which is exactly why §4 says the shift must be **externally queryable and mutable**:
  "accelerate the shift" = decrement the countdown; "shift one tile now" = apply one
  tile's next-state early. If the shift is buried as a private side effect of the turn
  loop, these powers become painful to add. Build the shift with a small **public API**
  (peek next state, advance, advance-one-tile) and the time-mage becomes "a unit that
  can call that API," not a special case threaded through everything.
- **Open question — is the time-mage a class or a unit?** Current lean: model it as a
  **unit with a special ability set layered on a normal class** (so it still has class
  stats and can fight), rather than a wholly separate class hierarchy. Revisit when we
  actually implement the powers.

---

## 6. Turn order (relevant to several systems above)

**Intent:** Turn-based loop driving player and enemy units. Likely **speed/initiative
based** (FFT-style) rather than strict side-by-side rounds, but not yet decided.

This matters here because the **shift cadence ("every N turns")** has to be defined
against a concrete notion of "turn" — per-unit activation vs. full round. Pin this
down when the turn loop is built, and make sure the shift counter and the turn system
agree on what a "turn" is.

**Open question:** Does the shift count *rounds* (everyone acted once) or *individual
unit turns*? Decide alongside the turn-order implementation.

---

## 7. Visual language — prototype is geometry + flat color, no sprites/textures

**Intent:** The prototype uses **only geometry and flat colors** — no sprites, no
texture mapping. This is deliberate: it's a Godot learning project, so we build
everything out of primitive meshes and materials first and learn the engine before
touching art. Textures/sprites are a **Later** concern.

**Characters — cylinder + cone "hat":**
- A unit is a **cylinder** with a **cone on top** as a hat.
- The **hat (cone) shape/color indicates the class** (soldier vs. archer vs. mage).
- The **cylinder body color indicates allegiance** (player vs. enemy).
- These are two independent visual channels — class reads off the hat, side reads off
  the body — so any class can appear on either side without ambiguity.

**Terrain — colored tiles by type:**
- Tiles are colored boxes whose color encodes a **terrain type**, e.g. grass = green,
  road = grey, water = blue.
- The **exposed vertical sides** of a tile that stands taller than its neighbors show
  as **brown "earth"** (the dirt under the surface), so height reads clearly without
  textures.

**Terrain types carry gameplay, not just color (design implication):**
- A tile's type is **data with gameplay effects**, not merely a paint color. Example:
  water tiles might **impede movement** (higher move cost or impassable) and/or **block
  casting** (a mage can't cast while standing in water).
- So a tile needs (at least) a **height** *and* a **terrain type**; the type feeds
  movement cost, casting legality, and possibly line-of-sight later. Keep tile data
  general enough to hold this from the start — don't model a tile as just a height.
- This connects to §4: the map's per-tile state is "(height, type)" over time, and a
  shift could in principle change a tile's *type* as well as its height (Later).

**Open questions (defer):**
- Exact palette and which cone shape maps to which class.
- Full list of terrain types and their precise effects (water is the motivating
  example; grass/road are currently cosmetic).
- Whether a shift can change terrain *type*, or only height, in the base prototype.

---

## 8. Implications checklist (carry these into the prototype)

Even though most features are deferred, these structural choices should be respected
now so we don't have to retrofit:

- [ ] Maps are **data** describing a *sequence* of tile-height states over time, not a
      single static height array. The base prototype can use a 2-state sequence
      (before/after one shift) but should not assume only one state exists.
- [ ] A tile carries **at least a height and a terrain type** — not just a height —
      since type drives movement cost, casting legality, and color (§7).
- [ ] The shift system exposes a small **public API**: peek the next state, apply the
      next shift, and (eventually) apply a single tile early.
- [ ] Units store grid coordinate decoupled from world position, and re-settle via the
      shared grid<->world height helpers when a shift changes their tile's height.
- [ ] Stats live in **class templates + per-unit data**, queryable by gameplay
      (movement, combat, fall damage), not hardcoded in scenes.
- [ ] Fall damage is computed from drop distance and unit stats, not a global constant.
- [ ] All visuals are **geometry + flat-color materials** (cylinder+cone units, colored
      boxes, brown earth sides). No sprites or texture mapping in the prototype.
