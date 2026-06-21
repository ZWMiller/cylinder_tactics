## A small pool of "fantasy medieval" given names to draw from when a unit needs a
## name but has no authored identity — chiefly the rolled enemies minted by
## `StatRoll`, which otherwise would all read as a bland "Foe 0123".
##
## Shaped like the project's other shared-vocabulary files (`TileTypes`,
## `UnitClasses`): a `class_name` namespace of constants + `static` helpers, never
## instantiated. Any script can read `UnitNames.MALE` or call
## `UnitNames.random_name(rng)` without preloading this file — that is what
## `class_name` buys (a project-global name).
##
## Kept as plain GDScript constant arrays (not a `.tres`) on purpose: a flat word
## list has no per-entry fields to author in the Inspector, so a code constant is the
## simplest editable home. To add names, just extend an array below.
class_name UnitNames
extends RefCounted

## Masculine-coded names. Sampling takes the RNG as a parameter (never a global) so a
## seeded run reproduces the same roster — the same reproducibility argument as
## `StatRoll.random_aptitude`.
const MALE := [
	"Aldric", "Bran", "Cedric", "Doran", "Edmund",
	"Garrick", "Hadrian", "Ivo", "Joran", "Kael",
	"Leoric", "Magnus", "Ned", "Osric", "Perrin",
	"Roderick", "Soren", "Theron", "Ulric", "Varic",
	"Wymond", "Aldous", "Brom", "Corvin", "Dunmar",
]

## Feminine-coded names, same length as MALE so neither is over-represented when we
## pick a gendered pool at random.
const FEMALE := [
	"Adela", "Brigid", "Cara", "Delphine", "Elara",
	"Fiora", "Gwen", "Helena", "Isolde", "Junia",
	"Katarin", "Lirien", "Maeve", "Nessa", "Orla",
	"Petra", "Quenna", "Rowena", "Sabine", "Talia",
	"Ursel", "Verena", "Wyn", "Ysolde", "Zara",
]


## Pick one random name from either pool. Picks a gender first (50/50) then a name
## within it, so both pools stay equally likely regardless of their sizes. `rng` is
## passed in (not a global) so a seeded encounter spawns the same names every run.
static func random_name(rng: RandomNumberGenerator) -> String:
	var pool: Array = MALE if rng.randf() < 0.5 else FEMALE
	return pool[rng.randi_range(0, pool.size() - 1)]
