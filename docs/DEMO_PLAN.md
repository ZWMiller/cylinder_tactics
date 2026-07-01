# Demo plan — the "proof of concept" vertical slice

**Status: target set (2026-06-27), not built.** This is the first end-to-end thing worth
showing other people: a scripted vertical slice that proves how the game *feels* and lands the
**meta-god reveal** (see `docs/GAME_DESIGN.md` §11). The goal is explicitly **to send/show it to
friends and gather feedback on the idea** — so it favors a tight, authored experience over
breadth or systemic completeness. It is a slice, not the game.

This document records the intended demo. It is a **target**, not a spec — beats and lore will
change. Collaborator notes (dependencies, risks) are marked _(note: …)_ so the vision stays the
owner's; the analysis is advisory.

---

## 1. Foundational capabilities to build first

The demo can't be authored until these exist. They are the near-term work, ahead of the scripted
content:

1. **Map/encounter builder working** — author a fight visually: place units, a player **start
   zone**, and **win-objective tiles**, save it, one-click playtest. (Already the planned
   Encounter Builder direction — `docs/DECISION_LOG.md` 2026-06-25.)
2. **A fun single battle** — the core combat loop has to actually feel good on its own; everything
   else wraps this.
3. **In-scene dialog text boxes** — a reusable dialog/textbox system for character lines and the
   god's fourth-wall mocking. _(note: net-new system; it's load-bearing for the whole demo —
   tutorial banter, the god's interruptions, and the cutscene all ride on it. Build it generic:
   speaker name + text + advance, usable from a battle AND a cutscene.)_

---

## 2. The demo sequence (scene by scene)

### Scene 1 — Scripted tutorial battle (you lose)

A straight, classic "tactics game" fight that teaches the basics (move, attack, turn order). It is
**scripted to end in defeat**: you lose and your character dies. Dialog runs between you and the
first mini-boss, **The Bishop**, throughout.

_(note: needs a **scripted/authored encounter** with forced-outcome hooks — a battle that can be
rigged to end in a loss regardless of play, plus dialog triggers on turns/events. The
mechanics-vs-presentation split already in combat helps here.)_

### Scene 2 — Cutscene: you are a time wizard; the "in-between" hub

A cutscene reveals the player is a **time wizard** (exact lore TBD). You **respawn** in the
**"in-between runs" area** of the roguelite. The premise lands: you must **try again to undo the
curse of the god** that is causing the world to **infinitely decay**. _(note: this is the narrative
home of the §4 "decay" framing and the "decay first, god revealed later" lock — the player is told
it's a curse/decay here; the god owning it is the later reveal. The hub = the thin `RunState` /
between-battles layer, GAME_DESIGN §9; a first cut exists as the `PartyLoadout` autoload.)_

### Scene 3 — The run: two battles with upgrade picks

A run begins. The **first two battles** each end with an **upgrade to pick** (the roguelite
reward), and use a non-elimination **win condition**, e.g. **"clear the road and reach the victory
tile."** _(note: needs the **win-objective tile** system — `Main._check_battle_end` is
elimination-only today (DECISION_LOG 2026-06-22) and must learn objective/reach-tile victory — and
a first **reward-pick** screen between battles. Both are small, contained, and reusable.)_

### Scene 4 — The Bishop battle (the reveal centerpiece)

The climax. Beats in order:

1. You fight **The Bishop** and are about to win.
2. On the **final killing blow**, **time stops mid-animation**. The **god cuts in** and mocks the
   player: killing this Bishop is irrelevant — *why would you think fighting a god is a fair
   fight?*
3. The animation **resumes** and all enemies die — **but the battle does not end.**
4. **New enemies are added to the turn queue.** The first sign something is wrong: when the first
   new enemy takes its turn, the **camera snaps to the *underside* of the map**, revealing a
   **lava pentagram on plain grey slate tiles**.
5. Those enemies **walk around the edges of the map** (onto the faces). **Except one** — a
   **summoner** at the center of the pentagram that keeps **spawning low-level, easy-to-kill
   enemies.**
6. Seeing the enemies walk around the map, the player should **intuit the win condition: kill the
   summoner** (not the endless adds).
7. When the **summoner dies**, the **god returns** and mocks again — roughly: *"oh, so maybe
   there's another being controlling this pixel simulacrum of life? Obviously not a very smart
   being, if it thought pixels killing pixels would make a difference…"*
8. The god then **takes control of the scene** to flaunt the mechanic's range: **walls warp into
   place with enemies standing sideways on them**, **tiles get destroyed**, etc. — teasing the
   other ways this could be used. This is the demo's closing beat — the "imagine where this goes"
   hook for feedback.

_(note: this scene is where the **face mechanic earns its keep** — and it depends on **Layer B**
(the deferred face *gameplay*: gravity re-point, per-face movement, the camera looking under the
map), not just the Layer A model just built. See §3 for the dependency picture. The "time stops on
the killing blow" beat leans on the existing mechanics-vs-presentation split to freeze presentation
mid-resolve; "battle doesn't stop / new enemies added" is the mid-battle spawn + TurnManager
register noted in §11's cheats.)_

---

## 3. Systems this leans on (existing / in-progress / net-new)

A quick map so the build order is legible. "Net-new" items are the real new work.

| Beat / capability | System | State |
| --- | --- | --- |
| Author every battle below | Encounter builder (placements, start zone, objective tiles) | In progress (direction set) |
| Core combat feeling good | Battle loop, combat pipeline | Built; needs polish |
| All dialog + god mocking | **Dialog/textbox system** | **Net-new** |
| Cutscene (Scene 2) | **Cutscene/scripted-scene system** | **Net-new** |
| "Reach the victory tile" / "kill the summoner" wins | **Win-condition system** (beyond elimination) | **Reach-tile DONE** (2026-06-30: win-objective tiles + `BattleBase` win check — ally ends turn on a `win` tile OR elimination). "Kill a specific target" (the summoner) variant still net-new. |
| Upgrade pick after a battle | **Reward-pick screen** + run state | Partial (`PartyLoadout`/RunState thin cut) |
| "In-between runs" hub | RunState / between-battles layer (GAME_DESIGN §9) | Partial |
| Time-stop on the killing blow | Freeze presentation mid-resolve | Achievable via existing mechanics/presentation split |
| Battle continues; new enemies enqueue | Mid-battle spawn + `TurnManager` register | Small addition |
| Enemies walk the edges / sideways on walls; camera under the map | **Faces — Layer B gameplay** (gravity, per-face movement, under-map camera) | **Net-new, deep** (Layer A model done) |
| Underside lava pentagram on slate | Bottom-cap tiles + authored underside | Net-new (Layer A slice) |

_(note: the **critical-path dependency** is **Layer B**. The demo's whole payoff — enemies walking
around/under the map, sideways on warped walls, the camera dropping below the board — is the
deferred coordinate-core work. Everything else (dialog, cutscene, win conditions, reward picks,
mid-battle spawns, time-stop) is comparatively contained. So the demo's schedule is essentially
"the contained content systems" + "Layer B." Worth deciding early whether to **prototype Layer B
cheaply** (the throwaway face spike) to de-risk the climax before authoring the rest.)_

---

## 4. Open questions / risks (defer, but noted)

- **Lore** for the time-wizard / curse / god — unwritten.
- **Layer B scope** is the long pole; the climax can't ship without it. Decide the traversal model
  (walkable-rim vs. teleport-onto-face — GAME_DESIGN §11 open question) before authoring Scene 4.
- **Readability of the reveal:** beats 4–6 must teach "kill the summoner" without a text prompt —
  the god mocking the player for not noticing is both characterization and the hint (GAME_DESIGN
  §11 craft risk).
- **Forced-loss tutorial (Scene 1):** make sure a rigged-to-lose fight still feels like it taught
  something and isn't just frustrating.
- **Demo length / pacing:** tactics battles are long; six-ish battles plus cutscenes is already a
  sizable sitting. Keep individual fights short.
