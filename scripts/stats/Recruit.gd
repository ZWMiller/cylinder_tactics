## A PERSON (as opposed to a job): the per-individual data that makes one unit differ
## from another of the same class. The "person vs. job" split is what gives us a
## job/FFT system — a Recruit keeps its identity (`display_name`, innate `aptitude`)
## across class changes, while `ClassDef` supplies the swappable job numbers.
##
## Authored PCs are `.tres` instances in `assets/recruits/` (bron.tres, …), hand-
## editable in the Inspector. Enemies don't get an authored file — `StatRoll` mints a
## Recruit with a randomized aptitude at spawn instead. Both paths feed the exact same
## machinery (a Recruit + a class + a level → effective stats), which is the "shared
## blocks" requirement: nothing about combat cares whether a unit was authored or rolled.
##
## `aptitude` is a `StatBlock` of OFFSETS (often negative) added on top of the class
## base — e.g. "+3 HP, +1 PHYS_ATK, −1 SPEED" reads as a brawny, slightly slow person
## who makes a great Soldier but a mediocre Mage. That signal is exactly how the player
## decides which class fits a recruit.
class_name Recruit
extends Resource

## Display name of this individual (shown in future roster UI / debug prints).
@export var display_name: String = "Recruit"

## Innate per-person stat offsets, folded on top of whatever class the unit currently
## holds. Persists through reclassing — the person stays themselves across jobs.
@export var aptitude: StatBlock

## The class this recruit starts as — a `UnitClasses.Class` enum value (int). Just a
## starting point; the player can reclass later. Also used to seed an enemy's assumed
## level history when one is spawned directly above level 1.
@export var starting_class: int = 0

## The level this recruit enters play at. Authored PCs almost always start at 1 and
## level up during the game; rolled enemies are spawned straight in at an encounter's
## level (a "level-5 random mage"). When >1, the unit assumes it leveled the whole way
## in `starting_class` — see `Unit` for how that seeds `level_history`.
@export var starting_level: int = 1
