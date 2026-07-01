# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Start here (read on session start)

Before working, read **`docs/GAME_DESIGN.md`** — it's the quick-start context builder
for the whole game vision: character classes, class-driven stat blocks, the
time-degradation map shift (the core gimmick), the shift telegraph/preview, and the
deferred time-mage powers. It also lists the structural choices to respect *now*
(maps as a *sequence* of height states, a small shift API, data-driven stats). Then
skim `docs/TODO.md` (live task list, sequenced toward the demo), `docs/DECISION_LOG.md`
(locked-in decisions), and `docs/DEMO_PLAN.md` (the scripted vertical-slice demo that the
TODO's "Next" section is now ordered around). Deeper per-component docs also live in `docs/`
(e.g. `BATTLEFIELD.md`, `STATS.md`, `EQUIPMENT.md`, `LOADOUT.md`, `ENCOUNTER_LAYERING.md`,
`FACES.md`).

## Project

Cylinder Tactics — a Final Fantasy Tactics-style game: 2D-feeling, isometric,
turn-based battles on grids of varying size with terrain at different Z heights.
Built in **3D with an orthographic camera** (not 2D). Placeholder art only:
units are cylinders, terrain is boxes floating in the void — no animation yet.

This is the owner's first Godot project and a **learning project**. Favor clear,
idiomatic GDScript and explain Godot concepts when introducing them, rather than
optimizing or abstracting prematurely.

The owner is well versed in **Python and C++**, with **light C#** experience.

## Collaboration style

- **Discuss and plan before coding** anything unclear or multi-step. Prefer a short
  design conversation over jumping straight to implementation.
- **Ask for clarification when unsure** rather than guessing or inventing behavior.
- When a core code decision **deviates from patterns common in Python, C++, or C#**,
  call it out and document it (GDScript has its own idioms — note where they differ).
- Log critical/hard-to-reverse decisions in `docs/DECISION_LOG.md` as they happen.

## Documentation & code style

The owner strongly prefers heavy documentation. Hold to this consistently:

- **Every function gets a docstring**, no matter how trivial. In GDScript use `##`
  doc-comments above the function (these feed Godot's built-in help system).
- **Comment any non-trivial step** inside functions and in config files — explain
  the *why*, not just the *what*.
- **Document components in markdown under `docs/`** as they are built; the owner will
  often request this explicitly.

## Tech stack

- **Godot 4.6**, Forward+ renderer, GDScript (native, not C#).
- Windows rendering driver pinned to **d3d12**; physics engine is **Jolt**.
- Boot scene: `scenes/Loadout.tscn` (the `run/main_scene` in `project.godot`) — the pre-battle
  loadout menu, which then launches `scenes/Main.tscn` (the battle; a thin `Main extends BattleBase`).
- Authoring tools are their own scenes, run with **F6**: `scenes/MapDesigner.tscn` (terrain) and
  `scenes/EncounterBuilder.tscn` (fights) share `scenes/AuthoringScene.tscn` as a base;
  `scenes/MusicTuner.tscn` (per-track loop/start/volume tuning) is a standalone `Control` (see `docs/MUSIC.md`).

## Working conventions

- **Workflow is code-driven.** Generate the grid, terrain, and units from data in
  GDScript at runtime rather than hand-placing nodes in the editor. Scripts live in
  `scripts/`, scenes in `scenes/`, art/resources in `assets/`.
- **Edit files in this main checkout**, not a git worktree — the running Godot
  editor watches these files on disk and auto-reloads them. Files written elsewhere
  won't be seen by the editor.
- **Avoid hand-writing `Transform3D(...)` matrices in `.tscn` files.** A transposed
  basis silently aims the camera the wrong way (the original black-screen bug). Set
  Position/Rotation separately, or aim cameras in code with
  `look_at(Vector3.ZERO, Vector3.UP)`. Remember a camera looks down its own -Z axis.

## Running / testing

- No build step — Godot runs the project directly. In the editor: **F5** runs the
  project (boots `Loadout.tscn`), **F6** runs the current scene (e.g. an authoring tool).
- No test framework is set up yet. If one is added, document the run command here.
- **Headless parse check** (run from PowerShell, not Bash): `godot --headless --check-only
  --script <file.gd>` parse-checks one script; after writing a NEW module also do an import pass
  (`godot --headless --editor --quit`). Note autoloads (e.g. `PartyLoadout`) show false-positive
  "Identifier not found" under a single-script check — verify those by running the game (F5).

## Architecture

The grid is the core abstraction (grid <-> world helpers on `Battlefield` are the shared seam:
tile→world placement and a click/ray→tile pick that movement, LoS, and combat build on). Much of
the prototype is now built — turn order (`TurnManager`, CT/speed queue), the melee/ranged/magic
combat pipeline, the map time-shift, a pre-battle loadout + equipment model, and the two authoring
tools. The current direction is a reusable, data-parameterized battle: `BattleBase` reads an
`Encounter` resource (map + enemies + deploy/win regions) so each fight is data, not a new script.
**Check `docs/TODO.md` for what's built vs. pending, and `docs/DECISION_LOG.md` for why.**
