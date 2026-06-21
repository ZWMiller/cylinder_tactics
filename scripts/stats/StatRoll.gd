## The ROLLED path for making units differ — used for enemies, which (unlike authored
## PCs) have no hand-made `Recruit.tres`. At spawn we mint a `Recruit` with a small,
## random `aptitude`, so a wave of enemy archers are all "archers" yet none are stat
## clones. Mirrors how authored PCs work — same `Recruit` + `StatBlock` types — so the
## rest of the game treats rolled and authored units identically ("shared blocks").
##
## A `class_name` static namespace (an enum-free cousin of `UnitClasses`): never
## instantiated, just a home for free functions. Roll RANGES are deliberately tiny to
## respect the small-numbers philosophy — aptitude nudges a unit, it doesn't reinvent it.
class_name StatRoll
extends RefCounted

## How far each rolled stat may swing from 0, by stat. Survivability (HP) gets the
## widest swing so enemies feel meaningfully tougher/frailer; the rest stay within ±1
## so no single roll warps a class. Stats absent here are never rolled (stay 0) — we
## don't randomize move/jump/evasion/temporal_resist for generic enemies.
const ROLL_RANGES := {
	"max_hp": 2,    # ±2
	"max_mp": 1,    # ±1
	"speed": 1,
	"phys_atk": 1,
	"mag_atk": 1,
	"phys_def": 1,
	"mag_def": 1,
}


## Build and return a fresh random `aptitude` StatBlock using `rng`. Taking the RNG as
## a parameter (rather than reaching for a global) keeps rolls reproducible — pass a
## seeded `RandomNumberGenerator` and you get the same enemies, which is gold for
## debugging an encounter.
static func random_aptitude(rng: RandomNumberGenerator) -> StatBlock:
	var apt := StatBlock.new()
	# `rng.randi_range(-r, r)` picks an int in [-r, r] inclusive — a symmetric nudge
	# around 0, so rolls are as likely to weaken as strengthen. We `set()` by field
	# name to stay in lockstep with ROLL_RANGES (one source of truth for what rolls).
	for field in ROLL_RANGES:
		var r: int = ROLL_RANGES[field]
		apt.set(field, rng.randi_range(-r, r))
	return apt


## Mint a complete rolled `Recruit` for an enemy: a `class_id` (which job) at `level`
## (how far leveled). This is the one-call enemy factory — "give me a level-5 random
## mage" is `random_recruit(UnitClasses.Class.MAGE, 5, rng)`. The class and level ride
## along on the returned Recruit (`starting_class` / `starting_level`), so the spawner
## hands it straight to a `Unit` with no extra bookkeeping; the unit assumes the
## recruit leveled the whole way in `class_id` when seeding its level history.
## The name is sampled from `UnitNames` so rolled foes read as people, not "Foe 0123".
static func random_recruit(class_id: int, level: int, rng: RandomNumberGenerator) -> Recruit:
	var r := Recruit.new()
	r.display_name = UnitNames.random_name(rng)
	r.aptitude = random_aptitude(rng)
	r.starting_class = class_id
	r.starting_level = maxi(1, level)  # a unit is at least level 1
	return r
