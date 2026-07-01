# Cylinder Tactics

A *Final Fantasy Tactics*–style turn-based tactics game: 2D-feeling, isometric battles on
grids of varying size with terrain at different heights. It's built in **3D with an
orthographic camera** (not a 2D engine), which is what gives the flat, iso look while keeping
real height and depth.

**Early prototype / learning project.** Art is deliberately placeholder — units are cylinders,
terrain is boxes floating in the void, no animation yet. The focus so far is systems: movement,
turn order, combat, a time-degradation map shift, a pre-battle loadout, and in-game tools for
authoring maps and encounters.

## Tech assumptions

- **Engine:** [Godot **4.6**](https://godotengine.org/), Forward+ renderer.
- **Language:** **GDScript** (Godot's native language — *not* C#).
- **Windows:** rendering driver pinned to **d3d12**; physics engine is **Jolt**.
- No build step and no external dependencies — Godot runs the project directly.

## Running it

1. Open the project folder in the Godot 4.6 editor.
2. **F5** runs the game. It boots the pre-battle loadout menu (`scenes/Loadout.tscn`), then
   launches a battle (`scenes/Main.tscn`).
3. **F6** runs the *current* scene — used for the standalone authoring tools:
   - `scenes/MapDesigner.tscn` — paint terrain/heights and save maps.
   - `scenes/EncounterBuilder.tscn` — place enemies, deploy zones, and win-objective tiles, and
     save a playable encounter.

## Project layout

| Path       | What's in it |
| ---------- | ------------ |
| `scripts/` | All GDScript. Gameplay logic, resources, and the authoring tools. |
| `scenes/`  | Godot scenes (`.tscn`) — battle, loadout, unit, and the authoring tools. |
| `assets/`  | Data resources (`.tres`): classes, recruits, maps, sequences, encounters + UI art. |
| `docs/`    | Design docs and per-component write-ups (see below). |

## How development works here

- **Code-driven, not editor-placed.** The grid, terrain, and units are generated from data in
  GDScript **at runtime**, rather than hand-placing nodes in the Godot editor. Maps and encounters
  are authored with the in-game tools above and saved as data resources, not built by dragging
  nodes around.
- **Heavy documentation is a deliberate style.** Every function gets a `##` doc-comment, non-trivial
  steps get *why* comments, and components are written up in `docs/` as they're built.

## Documentation

Start with the design docs in `docs/`:

- `GAME_DESIGN.md` — the whole game vision (classes, the time-degradation map shift, and the
  structural choices to respect now).
- `DEMO_PLAN.md` — the scripted vertical-slice demo the project is currently working toward.
- `TODO.md` — the live task list, sequenced toward that demo.
- `DECISION_LOG.md` — locked-in decisions and their rationale.

Per-component docs (`BATTLEFIELD.md`, `UNIT.md`, `STATS.md`, `EQUIPMENT.md`, `LOADOUT.md`,
`ENCOUNTER_LAYERING.md`, `FACES.md`, …) go deeper on individual systems.

> `CLAUDE.md` in the repo root is guidance for AI-assisted development (Claude Code) and isn't
> needed to build or play the game.
