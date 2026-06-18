# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

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
- Main scene: `scenes/Main.tscn` (set as `run/main_scene` in `project.godot`).

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
  project, **F6** runs the current scene.
- No test framework is set up yet. If one is added, document the run command here.

## Architecture (intended)

The grid is the core abstraction. Planned pieces (not all built yet — check
`docs/TODO.md` for current status):

- A battlefield generator that takes a 2D array of per-tile heights and spawns one
  box mesh per tile at the correct `(x, height, z)`, producing terrain with varying Z.
  See `docs/TODO.md` for the live task list and `docs/DECISION_LOG.md` for rationale.
- A unit (cylinder) that stores its grid coordinate, decoupled from world position.
- Grid <-> world coordinate helpers — the most important shared utility: convert a
  tile to a world position, and a 3D click/ray back to a tile. Movement range, line
  of sight, and combat will all build on these.
