## A class/job DEFINITION as an editable data asset: its level-1 `base` numbers and
## its per-level `growth`. One `.tres` instance per class lives in `assets/classes/`
## (soldier.tres, archer.tres, mage.tres) and is loaded by `UnitClasses.class_def`.
##
## This is intentionally a *thin stat asset*: it answers only "what are a soldier's
## numbers and how do they grow?". It deliberately does NOT hold the job-progression
## TREE (which class promotes into which, at what level) — that is a separate concern
## with its own shape (prerequisites, multiple unlocks) and will get its own resource
## later (docs/DECISION_LOG.md). Keeping them apart is single-responsibility: bloating
## the stat asset with a graph would make both harder to tune.
##
## Growth philosophy (docs/GAME_DESIGN.md §3): `growth` includes REAL combat stats,
## not just survivability, so leveling within a class is genuinely worthwhile and no
## class is a trap that "needs" a promotion to be useful. Numbers stay small and are
## tunable right here in the Inspector / .tres.
class_name ClassDef
extends Resource

## Which class this defines — a `UnitClasses.Class` enum value, stored as the int the
## enum is backed by. Lets a loaded `.tres` map back to the enum (and thus to the
## hat shape/color in `UnitClasses`) without a name string.
@export var class_id: int = 0

## Human-readable name for debug + future UI. Authored per file so it travels with
## the asset rather than being re-derived from the enum.
@export var display_name: String = "Class"

## The level-1 starting profile for this class — the floor every unit of this class
## begins from before aptitude and banked growth are folded in.
@export var base: StatBlock

## What ONE level-up *in this class* adds. A unit banks this profile each time it
## gains a level while set to this class; the per-level-up history is summed in
## `Unit.recompute_stats`. Keep these tiny (typically one or two +1s) — see the
## small-numbers philosophy. Unlisted fields default to 0 (no growth).
@export var growth: StatBlock
