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

**Open questions:**
- ~~Are classes fixed per unit, or can a unit change/promote class?~~ **Resolved (§3):**
  job-change with **persistent per-level banking** (FFT-style) — reclass swaps the base but
  keeps the growth banked from earlier jobs.
- Is the time-mage a **class** or a **special unit** that layers time powers on top
  of an ordinary class? See §5 — still open, the first real "class vs. function" call.

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
  first** (always hit; the dice come later), but the field exists so the formula has a
  home. *Status:* still reserved — `CombatResolver.hit_chance` mocks 1.0 today.
- `temporal_resist` — this game's signature stat, since the whole design is built on the
  time shift: a save vs. **hostile time magic** (an enemy time-mage targeting this unit —
  §5). It *originally* doubled as fall-damage mitigation, but the shipped shift re-settle
  uses a **jump-based** fall formula instead (see the §4 / §8 note), so `temporal_resist`
  is now reserved **solely** for time magic and stays inert until those powers land.

**Deferred** (intentionally *not* in the schema yet — noted so they have an obvious
slot): crit chance, luck, and FFT-style Brave/Faith. The split offense/defense +
evasion set already gives ample spell-design surface (debuff defense, lower evasion,
magic that pierces resist); add these only if a concrete need appears.

**Design guidance:**
- A unit's stat block is **data**, not hardcoded per scene — consistent with the
  project's code-driven workflow. A class is a **base template**; an individual is a
  class template **plus per-unit overrides**. (*Locked:* stored as custom Godot
  `Resource`s — `StatBlock` / `ClassDef` / `Recruit` — see the subsection below.)
- Fall damage from the time shift (§4) is computed from **drop distance vs. the unit's
  `jump`** (`fall_levels − jump`), stat-driven and bounded — never a hardcoded global
  constant. (This replaced the earlier `temporal_resist`-based idea; see `docs/DECISION_LOG.md`.)
- Damage formulas must respect the small-numbers philosophy above. The **shipped** model
  (equipment, `docs/DECISION_LOG.md` 2026-06-23) is **multiplicative** — `offense =
  round(atk × weapon.power)`, `mitigation = round(def × Σarmor × scale)` — deliberately
  tuned to keep results in the single/low-double digits, **not** a percentage curve that
  explodes at high values. (This superseded the subtractive `atk − def` melee first pass.)

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
- **Now (telegraph) — DONE:** The upcoming shift is telegraphed — a turn-counted
  countdown (`ShiftCounter` "Shift in: N") plus the pre-shift cinematic. (Per-tile visual
  cues on tiles about to change are still a nice-to-have.)
- **Intended-now, still TODO (preview):** A **hold-to-preview** control — while held, show
  what the map *will* look like after the next shift (which tiles rise/fall, by how much,
  and which units would fall / take damage). Releasing returns to the current state. A
  read-only "what-if" view, not a committed action. The data exists (`peek_next_state`);
  the view was intended for the base prototype but hasn't been built yet (see `docs/TODO.md`).
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

**Built (`TurnManager`, DECISION_LOG 2026-06-21).** A turn-based loop driving player and
enemy units, **speed/initiative based** (FFT-style **Charge Time**) rather than strict
side-by-side rounds: each unit banks `ct`, ticks up by `speed`, acts at 100, and carries
the overflow — so faster units act *more often*, not merely earlier.

This mattered because the **shift cadence ("every N turns")** has to be defined against a
concrete notion of "turn". **Resolved:** the shift counts **individual unit turns**
(completed character activations), *not* full rounds — `TurnManager` fires the shift every
Nth completed turn (`register_map_transition_speed`, default 10).

---

## 7. Visual language — prototype is geometry + flat color, no sprites/textures

**Intent:** The prototype uses **only geometry and flat colors** — no sprites, no
texture mapping. This is deliberate: it's a Godot learning project, so we build
everything out of primitive meshes and materials first and learn the engine before
touching art. Textures/sprites are a **Later** concern.

**Characters — cylinder + class "hat":**
- A unit is a **cylinder** with a **hat on top**.
- The **hat shape indicates the class** — as built: square/box = soldier, pyramid = archer,
  cone = mage (not always a cone; the shape is the class channel).
- The **cylinder body color indicates allegiance** (player vs. enemy).
- These are two independent visual channels — class reads off the hat, side reads off
  the body — so any class can appear on either side without ambiguity.

**Terrain — colored tiles by type:**
- Tiles are colored boxes whose color encodes a **terrain type**, e.g. grass = green,
  road = grey, water = blue.
- The **exposed vertical sides** of a tile that stands taller than its neighbors show
  as **brown "earth"** (the dirt under the surface), so height reads clearly without
  textures.

**Terrain types carry gameplay, not just color (BUILT — `TileTypes` property table):**
- A tile's type is **data with gameplay effects**, not merely a paint color. This shipped:
  `TileTypes` holds per-type `move_cost`, `is_liquid`, `can_cast`, `hazard_damage`; movement
  is Dijkstra over `move_cost`, liquids block casting, and lava deals hazard damage. Types
  now include DIRT / LAVA / BUILDING / ROOF / QUICKSAND etc. (so "grass/road are cosmetic"
  below is outdated — terrain is live).
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

These structural choices had to be respected from the start so we wouldn't have to
retrofit. **As of 2026-07 all are honored in code** — kept here as the invariants to
*preserve*, not as open work:

- [x] Maps are **data** describing a *sequence* of tile-height states over time, not a
      single static height array (`MapData` / `MapState`; the shift cycles the states).
- [x] A tile carries **at least a height and a terrain type** — not just a height — and
      in fact a two-layer (surface + body) type; drives movement cost, casting, color (§7).
- [x] The shift system exposes a small **public API**: `peek_next_state` / `advance_shift`
      (apply-a-single-tile-early is still reserved for the time-mage, §5).
- [x] Units store grid coordinate decoupled from world position, and re-settle via the
      shared grid<->world height helpers when a shift changes their tile's height.
- [x] Stats live in **class templates + per-unit data** (`ClassDef` + `Recruit`),
      queryable by gameplay (movement, combat, fall damage), not hardcoded in scenes.
- [x] Fall damage is computed from drop distance and unit stats (`fall_levels − jump`),
      not a global constant.
- [x] All visuals are **geometry + flat-color materials** (cylinder + per-class hat units,
      colored boxes, brown earth sides). No sprites or texture mapping in the prototype.

---

## 9. Meta-structure — roguelite campaign (future discussion)

**Status: Later / mostly Open.** Captured here so the prototype doesn't paint us into a
corner; **not to be designed in earnest until a single battle is fun *and* a "battle end →
pick a reward → next battle" loop exists** (see `docs/TODO.md`). One decision is locked; the
rest is an explicit future discussion.

**Concept.** The core gameplay stays the FF-Tactics battle. Wrap it in a roguelite
"choose-your-own-adventure": each **act** plays out over a branching **node map**
(Slay-the-Spire / Inscryption style) you move through, making choices. Most nodes are
**battles** (some scripted/story, some skirmishes), interspersed with non-battle nodes —
**rest "tents"** (heal, à la StS), shops, and events. The story spans **multiple acts** with
scripted battles, and could branch into **different storylines / multiple final acts** based
on choices.

**Decided (locked): persistent party across a campaign-shaped map.** Your party carries over
between battles and across the map — runs are *chapters*, not fresh starts. Characters
**accrue levels by playing**, and you spend **loot** (between battles/runs) to upgrade them:
weapons, stat boosts, spells, jobs. You keep a **bench** of units and **swap** the active
squad between battles.

**The roguelite hook — in-run build modifiers.** Slay-the-Spire-style relics/cards that change
*how combat behaves*: "all melee now deals poison," "archers crit more," etc. This is the most
replayable, most distinctive layer — and it maps cleanly onto the **generic combat pipeline**
(`Attack` profiles + `CombatResolver` + the resolve→animate→damage sequence), as on-hit /
damage-modifier / status hooks. Treat this as a headline feature, not a side system.

**How it maps to the architecture (why we can defer it safely):**
- The planned **`Encounter` resource** *is* a battle node's payload; the reusable
  **`Battle.tscn`** is the node you enter. A map is "a graph of `Encounter`s + rest/shop/event
  nodes."
- Make `Battle.tscn` **return a result** (survivors, loot, XP) so a run controller consumes it.
- A new **`RunState`** layer (above the battle) holds the persistent party + bench, inventory /
  gold, active build-modifiers, and map position. Battles read/write it instead of `Main`
  hardcoding rosters.
- Loot already has homes: weapons = stat-modifier resources or `Attack` profiles, spells =
  `Attack` resources, jobs = `ClassDef`. Build-modifiers = a new relic/hook system on the
  combat pipeline.

**Open questions / tensions to resolve in the future discussion:**
- **Pacing.** Tactics battles are long (10–20 min) vs. StS's 1–3 min fights; a full act of
  big battles is a multi-hour run. Mitigate with shorter maps, lighter skirmishes between
  elite/boss battles, or fewer-but-meatier nodes. Structural, not a tuning pass.
- **Permadeath rules** with a persistent party + bench — do fallen/benched units die for good?
- **Power creep.** Persistent levels *and* per-run build modifiers can trivialize later
  battles; decide what (if anything) resets per act/run.
- **Narrative scope** (the biggest solo-dev trap). Branching stories / multiple endings are a
  content black hole. Build the tree to *support* branches but **author one linear act first**.
- Meta layer (cross-run unlocks/upgrades) — needed at all with a persistent party, or does
  between-battle loot cover it?

---

## 10. Art direction — target look (watercolor + ink) — Later

**Status: Later / direction set, not built.** §7 is the *prototype* look (geometry + flat
color). This is the **target aesthetic** once we move past placeholder art: a **hand-drawn
watercolor-and-ink storybook** style, with the map *assembling itself on screen* as a
signature load moment. Captured now so the move to sprites/textures (and the engine choices
that enable it) is made with this end-state in mind, not retrofitted.

**The look.** Everything reads as **paint and ink on paper**: loose hand-drawn ink outlines,
soft watercolor washes (irregular edges, pigment pooling darker at the borders, color
variation within a wash), all unified by a **paper-grain overlay** multiplied over the whole
screen — map, units, and UI alike. Units become **watercolor sprites** (see the 2.5D /
sprite notes: billboarded 2D sprites in the 3D world) painted in the same medium.

**The signature load sequence ("the map draws itself in").** A battle loads as if being
sketched and painted onto graph paper:
1. **Graph paper** background.
2. The map's tile **outlines scribble in** — loose, *boiling* (frame-to-frame jittering)
   pencil lines that animate as if being drawn.
3. **Color floods in** — watercolor washes bleed into the tiles (an organic, noise-edged
   "pigment spreading on wet paper" reveal, not a hard wipe).
4. The graph paper **crossfades to a scenic watercolor backdrop** (sky / mountains / sunset),
   chosen per battle.
5. **Sprites appear** in the same painted vocabulary.

**Why it fits this project.** The map is already generated **from data, tile by tile, in
code** (§8), so we own the reveal order and timing — the "draw-in" is choreography layered on
the existing generator, using the same sequencing patterns as the shift cinematic. **Reuse
candidate:** the *same* scribble-and-recolor effect could fire on the **time-shift** (§4) —
the decaying world being literally *re-sketched* — tying the core gimmick to the art language.
Build the reveal as a reusable "(re)draw these tiles" routine, not a one-off intro.

**Effects, by difficulty (de-risk in this order):**
- *Easy / high payoff:* flat watercolor tile textures + the paper-grain overlay + **unshaded**
  rendering — nail the *static* look first.
- *Easy:* graph-paper → scenic backdrop crossfade (per-battle backdrop is `Encounter` data).
- *Medium:* the color flood-in (a noise-masked dissolve tuned to look like bleeding pigment),
  driven by the per-tile generation timing.
- *Hard / the ambitious flourish, prototype cheaply first:* the **scribbled, boiling, draw-on
  pencil outline** (wobbly stroke texture + time-varying noise "boil" + a draw-on reveal). This
  is where most iteration goes; prove the rest sells the direction before committing to it.

**Decisions this locks in (consequences for §7's successor):**
- **Unshaded / flat**, not lit 3D — watercolor reads as paint on paper, so the directional
  light + shadows get dropped or heavily stylized.
- **Ink outlines on everything** (units *and* terrain) or the look is half-committed.
- **Limited, harmonious palette per scene** (sunset warm, mountain cool, …).
- Keep terrain materials/shaders **shared per terrain type** across the ~hundreds of tiles
  (performance), unlike units which stay per-instance (independent skinning, §7).

**Open questions (defer):**
- The load sequence plays **every battle** — make it **skippable / fast-forward to finished**
  after first view (tactics intros wear out fast). Decide total duration and the reveal
  choreography (radiate from a point? sweep? scattered "raindrops" of color?).
- Pixel-art vs. painterly-hi-res (drives texture filtering, texel density tied to the ortho
  `size`, and how much continuous unit movement shimmers — see the sprite/texture notes).
- Whether the shift truly reuses the draw-in effect, or just shares its visual vocabulary.
- Treatment of UI/HUD and the existing overlays (move-range outline, damage numbers,
  win/lose screen) in the painted style so they don't read as a different medium.
- **(See §11.)** Whether the watercolor look is the *genuine* target aesthetic, or a
  god-introduced **intrusion** weaponized to unsettle the player — §11 reframes §10.

---

## 11. The meta-god reveal — the antagonist who breaks the game (Later)

**Status: Later / one decision locked, the rest Open.** A second signature idea alongside the
time shift: the game is secretly **meta**. The "kill god" premise these tactics games always
carry becomes literal antagonism — partway through, the **god starts cheating**, breaking the
spatial, UI, and even *graphical* rules of the game, and mocks the **player** (not the player's
characters) in a fourth-wall, *Stanley Parable*-style voice: "Oh, you thought a god rolls over
and dies because your pixel swords beat my pixel swords?" Captured now so the systems it rides
on — the shift (§4), the time-mage (§5), the art language (§10) — are built to *allow* it, not
retrofitted. **Do not design in earnest until a single battle is fun and the shift ships.**

### Locked decision: **decay first, god revealed later**

The early game presents the §4 map shift as impersonal "**the world is decaying**." The mid-game
**rug-pull** is that the decay was the **god** all along. The reveal *is* the unification of the
two signature systems — so the shift must be authored to be **re-skinned mid-campaign** from a
neutral mechanic into the god's hand. (Decided 2026-06-27; see `docs/DECISION_LOG.md`.)

### The aesthetic conceit — "the real game, built around a PS1 game"

The base game wears a deliberately **low-fi, blocky** skin (the current geometry-and-flat-color
prototype is literally this — placeholder art *is* the early aesthetic). The god's intrusions
**violate that established style on purpose**: things appear that **don't belong** to the game's
graphical vocabulary — a sudden **watercolor** flourish, a jarringly **"realistic" 3D asset** —
specifically to make the player feel *wrong-footed* ("how is that even in this game?"). The
wrongness is the point: a low-fi world being overwritten by a higher power who doesn't respect
its rules, visual or mechanical.

**This recontextualizes §10.** The watercolor "the map draws itself" sequence may not be a
neutral *target look* — it could be a **god move**, introduced *at* the player to make them feel
dumb ("you thought your blocky little world was all there was?"). **Open question:** is watercolor
(a) the genuine end-state aesthetic, (b) a weaponized intrusion, or (c) **both** — it begins as an
unsettling intrusion and is later *earned* as the real look. Lean (c); decide at reveal design.

### Three structural constraints to respect NOW (so the reveal is a re-skin, not a rebuild)

1. **Shift *presentation* is a swappable skin over shift *mechanics*.** `advance_shift`, the
   telegraph, the cinematic, and `ShiftCounter` stay agnostic about *why* the map changes. Early:
   neutral "decay" copy. Post-reveal: the **same** events get a face, a voice, and mocking text.
   Keep cinematic text / HUD copy / (future) VO hooks as data, not hardcoded strings.
2. **The previewed future is a *queryable state that something could later tamper with*.** §4
   already requires the next state to exist before it's applied. Don't assume the preview is
   *incorruptible*: the first time the god **lies in the preview** can *be* the reveal — the moment
   a trustworthy mechanic does something an impersonal mechanic can't. Build the tampering later;
   just don't bake in "preview always tells the truth."
3. **Grid↔world placement stays the single chokepoint, and "height" generalizes to a *face
   normal*.** All world placement already flows through `Battlefield`'s grid↔world helpers, and
   picking is a raycast against real geometry (§DECISION_LOG 2026-06-19). Generalizing the buried
   assumption "height is +Y" into "height is along a **face normal** (origin + basis)" is the lever
   that turns *walking on the walls / underside* from a coordinate-core rewrite into content: a
   "face" of the map becomes just another coordinate frame; unit cylinders go horizontal because
   their up-axis follows the face normal; the raycast picker already works at any orientation.

### Near-term build intent — "walk to the bottom of the map" (a feel test)

Wanted **soon**, ahead of the full reveal, just to *feel* it. Two pieces:
- **Generalize grid↔world to a face normal** (constraint 3) so a unit can stand on / walk across a
  non-top face (side, underside) with gravity re-pointed along that face. Reachability/jump-gating
  (`reachable_tiles`, `classify_path`, the BFS) currently assume one 2D grid with height on one
  axis — they need to operate per-face.
- **Tile blocks gain a bottom cap.** Today a tile is two-layer: a surface/cap `type` + a side
  `body` type (a full vertical stack was rejected as overkill — §DECISION_LOG 2026-06-24). The
  **underside** needs its own renderable cap so it can be made to look **intentionally
  "wrong/unfinished"** — raw, ugly, un-textured graph-paper backside (which dovetails with §10:
  the underside is the storybook load sequence *frozen un-painted*). Extend the two-layer model to
  three faces (top cap / sides / **bottom cap**), don't special-case it.

### The god's cheats — bucketed by build cost

**Nearly free (reuse shipped systems):** warp terrain mid-fight (= the shift); **grey out / disable
menu actions** (reuse `_is_action_enabled` + the disabled render path); **fast-forward the shift
clock** to punish a preview (mutate `map_transition_countdown`); **hide or lie in** the stat
panels (they're dumb views — feed them garbage). **Medium:** punch a hole / lava-pentagram that
**summons enemies mid-battle** (a shift state + hazard tile + registering a unit with
`TurnManager` mid-fight); **revive a "dead" enemy** ("I never said it stayed dead" — needs a corpse
registry instead of freeing the node); a **vertical duplicate map** whose archers shoot across
(rendering is trivial in 3D; the work is cross-grid targeting/LOS). **Expensive (the showpiece):**
**walk on the sides / underside** (the face-normal generalization above); a **sphere of tiles**
(curved adjacency — a *separate*, much-later stunt, not part of the face generalization).

### Meta-puzzles layered on the battle puzzle

The god's constraints should be **solvable by the player in-world**, not just suffered — a meta-puzzle
*on top of* the tactics puzzle. The motivating example: a **"realistic" vine grows out of the board
and wraps the action menu**, disabling that action. The solution isn't a battle move — if the player
**rotates the camera**, the vine visibly **strains**; *wiggling* the camera back and forth **snaps**
it and frees the action. **The pattern:** the god imposes an intrusive, off-style asset as a
constraint; the player breaks it via an *unexpected* use of an *existing* control (here, the
`CameraController` the player already owns). Reuses systems already built; the discovery is the fun.

### Player counter-powers = the time-mage (§5), escalating

The player isn't only a victim. The §5 time-mage powers — bending the shift, breaking the map's
rules — are **the player's answer to the god breaking those same rules**. "Walking on the walls" is
the player *learning to cheat back*. The meta-escalation and the deferred time-mage kit are the
**same feature** seen from two sides; build §5 with the god in mind. (Some rule-breaks may be
*always available* to the player — they simply never think to try until the god demonstrates them.)

### The reveal structure (campaign shape, ties to §9)

A candidate arc: the player **hunts a mocking mini-boss across 3–4 "normal" maps**, during which
the cheats are **seeded subtly as "decay glitches"** (a tile that shifts one beat too conveniently
for the enemy; a menu option that flickers). The payoff is a mini-boss **arena that spawns
"empty,"** the boss taunting from nowhere — the player must discover they can **walk around the
side to reveal the unfinished underside** (lava pentagram, summoned enemies, the boss portalling
*through* the board to strike from the top). **Craft risk:** an empty arena reads as a *bug*, not a
puzzle — the god **mocking the player for not looking everywhere** must double as the hint.

### Resolved: the weird mechanics are PERMANENT core, not set-pieces (decided 2026-06-27)

The god's rule-breaks **do not revert** after the reveal. Walking on faces, the broken/altered
menus, mid-fight summons, etc. become a **permanent part of the battle problem-solving space**,
**authored in the map/encounter builder** like any other mechanic — the game must **stand alone
past the reveal**, so "the god did a weird thing in one fight" is not enough; the weird thing
becomes a tool both sides reason about in ordinary battles. This makes **faces (and friends) core
infrastructure the builder sits on**, not a deferred party trick. (Resolves the prior open question
on permanence; ties to the §5 time-mage kit, which is the player's version of the same powers.)

### Build sequencing: split "the face work" into Layer A (model) and Layer B (gameplay)

Because faces are core *and* builder-authored, "the face work" is **two layers with different risk
and timing**. The dividing line: **anything that, baked wrong, forces a builder rewrite is Layer A
and is decided/baked NOW; the deep math is Layer B and is deferred**, built on top of A and
validated with the finished builder (one-click test fights). Build the builder **once**, face-ready.

**Layer A — face *model* (data / addressing / collision): bake into the current builder pass.**
*Status: largely built (2026-06/07).* The `Face` enum, face-carrying `EnemyPlacement.face`,
`(tile, face)` picking, and bottom-cap tiles all exist and default to `TOP`; the remaining
Layer-A work is the additive **face-authoring UI**. Layer B (below) is still deferred — it's
the demo's long pole (see `docs/TODO.md` / `docs/DEMO_PLAN.md`).
- A **`Face` enum** (`TOP, NORTH, SOUTH, EAST, WEST, BOTTOM`); a tile *address* becomes
  `(Vector2i tile, Face face)`, **defaulting `TOP`** everywhere today (the reserve-a-slot-default-it
  pattern used for `evasion`/`temporal_resist` and the shift's reserved behaviors).
- **Unit placements and authored mechanics carry a `face`**, defaulted `TOP`. The current builder UI
  only ever sets `TOP`; face-authoring tools are **additive** later, not a rewrite, *because the data
  already holds a face*.
- **Bottom caps** — extend the two-layer tile (top cap / side `body`, §DECISION_LOG 2026-06-24) to
  **three faces (top cap / side / bottom cap)** so the underside can be made intentionally
  "wrong/unfinished". Pure rendering/data, no gravity — fold in now while touching the tile model.
- **Picking returns `(tile, face)`** — wire now even though only `TOP` is acted on (see collision note).

**Layer B — face *gameplay*: deferred focused effort.** Gravity re-point along a face normal,
per-face reachability/jump-gating (the BFS currently assumes one 2D grid with height on one axis),
unit orientation on a face, and face-to-face traversal (how a unit crosses the rim — *step over a
walkable lip* vs. *god teleports you onto a face* — decide at Layer B kickoff). Layer B **reads** the
face data Layer A produces.

**Collision finding (probably saves work):** we likely do **not** need physically separate colliders
per face. (1) Godot's raycast already returns the **hit `normal`**, so the existing *single box per
tile* can yield *which face* was clicked (map world-normal → `Face`) — face identity for picking and
authoring is free from the picker we already have. (2) Units have **no collision** and movement is a
**scripted point-queue walk** (§DECISION_LOG 2026-06-19), so "walking along a side" is a
coordinate/gravity problem (Layer B), **not** a collider problem. **Verify** the one risk before
assuming the heavier model: that exposed side/bottom faces get hit cleanly by the ray on tall/occluded
geometry. Lean: per-face *identity* + *addressing/placement data*, not per-face *physics shapes*.

### Open questions (defer)

- Watercolor: genuine target look, weaponized intrusion, or both-then-earned (lean both — see above).
- How heavy-handed the fourth-wall voice gets, and how far the "metagame" hooks reach (commenting on
  reloads / alt-tabbing is on-theme; pulling the real OS username is likely a step too far).
- Whether seeded "decay glitches" are authored per encounter (§DECISION_LOG encounter builder) or a
  generic "glitch" layer the shift can roll.
- **Layer B traversal model:** walkable-rim (gravity rotates as you cross an edge) vs. god/ability
  teleport onto a face — drives whether reachability spans faces in one BFS or treats each face as its
  own grid. Decide at Layer B kickoff.

---

## 12. Meta play — subverting player expectation, and the in-game god's direct voice — Later / Open

**Status: Later / vision capture (2026-07-01).** A design *stance* that generalizes §11: treat
**playing with the player's expectations** as a recurring tool across many battles — not a
one-time reveal — and personify the meta layer as an **in-game god** that breaks the fourth wall
to interact with the **player** (not the player's characters) **directly**. §11 (the meta-god
reveal) is the tentpole *instance* of this stance; this section is the general principle it
belongs to. **Do not design in earnest until a single battle is fun and the shift ships** (same
gate as §9 / §11).

### The principle — battles that set up an expectation, then break it

Each such battle teaches or implies a rule, then violates it in a way that is **fair in
hindsight** (the player could have seen it coming). The subversion is the *content*, not a bug.
Candidate patterns, authored per encounter:
- **The rug-pull tutorial** — a "normal" fight that teaches the basics and is **scripted to
  betray you** (DEMO_PLAN Scene 1: learn the rules, then lose by design).
- **The lying win condition** — the stated/obvious objective isn't the real one (DEMO_PLAN
  Scene 4: "kill everything" ≠ win; the real answer is "kill the summoner," discovered in play).
- **The empty arena** — a fight that appears to have no enemies / no path until the player looks
  somewhere the game never taught them to (walk around the side to the underside, §11).
- **Broken conventions** — a later fight that violates a convention every earlier fight
  established (a disabled menu action, a "dead" enemy that revives, terrain that moves *for* the
  enemy). Reuses the §11 cheat buckets.

### The god as the vehicle — a direct, fourth-wall voice

The god is the **personification** of the expectation-breaker: it addresses the player, mocks,
misleads, and (occasionally) hints, in a *Stanley Parable*-style narration. It is the named face
the impersonal "decay" (§4) becomes at the reveal (§11) — but as a **design device** it can
recur well beyond that single moment (seeded "glitch" asides before the reveal, running
commentary after). Route every intervention through the **same data-driven hooks** §11 lists
(dialogue lines as data, the disabled-action path, the shift re-skin, stat-panel lies) so a "god
moment" is **authored content in the encounter builder**, not a special case in code.

### Design guidance

- **Use it sparingly.** Over-used, the trick stops surprising and reads as gimmick — or as a
  bug. Space the big subversions; let ordinary tactics carry most fights.
- **Fair in hindsight.** Every meta-twist needs a discoverable tell, so the payoff is "I should
  have seen that," not "that was unfair." The god *mocking the player for not noticing* doubles
  as the tell (the §11 craft risk).
- **Content, not one-offs.** Because the weird mechanics are permanent core (§11, decided
  2026-06-27), an expectation-subversion is a **reusable authored beat** — the demo proves the
  vocabulary; the campaign reuses it.

### Open questions (defer)

- **Same entity as §11's meta-god, or a broader recurring device?** Lean: the *same* being, but
  its voice can appear (as glitches / narration) earlier and outlast the single reveal — the
  reveal is when it stops hiding, not its first or last appearance.
- **Always present vs. introduced at the reveal** — does the god narrate (subtly) from the first
  battle, or only exist after the mid-game rug-pull?
- **Antagonist-only, or unreliable ally?** Does it ever genuinely *help* (a real hint, a spared
  unit) to make the mockery land harder, or is it purely hostile?
- **One meta-entity or several?** (A pantheon / rival narrators is a content black hole — flag,
  don't build.)
- How far the meta-voice reaches *outside* the fiction (commenting on reloads / alt-tab is
  on-theme; pulling real OS/user data is likely a step too far — mirrors §11's open question).
