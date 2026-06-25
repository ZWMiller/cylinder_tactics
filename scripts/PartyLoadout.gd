## Persistent pre-battle party state — the data the loadout menu writes and the battle reads.
##
## Registered as an AUTOLOAD singleton (see project.godot `[autoload]`), so a single instance
## lives for the whole program and SURVIVES `change_scene_to_file`. That is the whole point:
## `Loadout.tscn` (the gear-up menu) and `Main.tscn` (the battle) are separate scenes — when we
## swap from one to the other Godot frees the old scene tree, so anything the player chose has to
## live OUTSIDE that tree to carry over. An autoload node is the idiomatic Godot home for exactly
## this "global, cross-scene state" (the Python/C++ analogy: a module-level singleton).
##
## It owns three things:
##   - `party`     — WHO is in the squad (the roster, moved here out of `Main` so both scenes agree).
##   - `_loadouts` — WHAT each member has equipped, keyed by their `Recruit` (persists across scenes).
##   - the `inventory()` catalog — every item the player can choose from.
##
## This is deliberately the THIN first cut of the planned `RunState` (see docs/GAME_DESIGN.md §9 and
## docs/TODO.md): persistent party + inventory, in memory only. Saving it to disk (so gear sticks
## between sessions) is a documented follow-up, not built yet.
##
## NOTE (no `class_name`): an autoload already publishes its node name (`PartyLoadout`) as a global,
## so adding a matching `class_name` would clash with it. Other scripts just reference `PartyLoadout`.
extends Node

## The unit prefab, so `ensure_seeded` can mint a throwaway unit per member to read its CLASS DEFAULT
## loadout (the default kit depends on computed stats, so we need a real unit to derive it). Same
## scene the battle stamps out.
const UNIT_SCENE := preload("res://scenes/Unit.tscn")

# --- The roster (the party that fights) --------------------------------------
# Authored player characters, preloaded so a renamed/missing file is a loud editor error. These
# moved here from `Main` so the loadout menu and the battle share ONE definition of the squad.

const RECRUIT_BRON := preload("res://assets/recruits/bron.tres")  # Soldier
const RECRUIT_DART := preload("res://assets/recruits/dart.tres")  # Archer
const RECRUIT_WISP := preload("res://assets/recruits/wisp.tres")  # Mage

## The squad, in display/spawn order: each entry is the person plus their battlefield start tile.
## `Main` spawns players from this list; `Loadout` lets the player gear each one up. A dictionary
## per entry (rather than a bare array) so the fields read by name at every use site.
var party: Array = [
	{"recruit": RECRUIT_BRON, "x": 10, "z": 10},
	{"recruit": RECRUIT_DART, "x": 12, "z": 10},
	{"recruit": RECRUIT_WISP, "x": 14, "z": 10},
]

# --- Stored loadouts ---------------------------------------------------------

## Each member's chosen equipment, keyed by their `Recruit` resource (the same preloaded instance
## is shared across scenes via Godot's resource cache, so it's a stable key). The value mirrors the
## five mounts on `Unit`: `{ "hands": [main, off], "head": Equipment, "chest": Equipment,
## "boots": Equipment }`, each entry an `Equipment` or null. Populated once by `ensure_seeded`
## (from the class defaults) and thereafter overwritten by the menu as the player edits.
var _loadouts: Dictionary = {}

## The shared inventory: one of every catalog item (the "unlimited catalog" model — see the
## DECISION_LOG). Built lazily once and reused, so the menu and any future shop read a stable list
## (equipping never removes from it; the same item type can be worn by several members).
var _inventory: Array[Equipment] = []


## The full inventory list the menu offers, built once on first access. Order = weapons (light→heavy,
## then casters, then shield), then the four armor sets head→chest→boots. Built from the same code
## catalog the combat balance was tuned against (`Equipment` factories).
func inventory() -> Array[Equipment]:
	if _inventory.is_empty():
		_inventory = [
			Equipment.dagger(),
			Equipment.rapier(),
			Equipment.straight_sword(),
			Equipment.bow(),
			Equipment.bastard_sword(),
			Equipment.wand(),
			Equipment.staff(),
			Equipment.shield(),
		]
		_inventory.append_array(Equipment.cloth_set())
		_inventory.append_array(Equipment.leather_set())
		_inventory.append_array(Equipment.chainmail_set())
		_inventory.append_array(Equipment.plate_set())
	return _inventory


## Guarantee every party member has a stored loadout BEFORE any menu-ing — seeding the CLASS DEFAULT
## kit for anyone not already set. Call this once when the loadout menu opens (it's idempotent). The
## point: a member the player never touches still goes to battle in their default gear, and the menu
## opens showing real equipment rather than empty slots — the player can then override it, or even
## strip it bare (their choice), but no one starts geared-by-accident-with-nothing.
##
## Why a throwaway unit: the class default loadout is requirement-checked against computed stats, so
## the cheapest correct way to learn "what would this recruit equip by default" is to mint a unit,
## let `init_from_recruit` equip the default kit, snapshot it, and discard the unit. The unit is never
## added to the tree (no appearance/layout runs — `init_from_recruit` guards that on `is_node_ready`),
## so this is pure data work.
func ensure_seeded() -> void:
	for entry in party:
		var recruit: Recruit = entry["recruit"]
		if _loadouts.has(recruit):
			continue
		var probe: Unit = UNIT_SCENE.instantiate()
		probe.init_from_recruit(recruit)   # equips the class default loadout (stats-gated)
		capture_from(recruit, probe)        # persist that default as this member's starting loadout
		probe.free()                        # not in the tree — free immediately, nothing to clean up


## Whether `recruit` already has a stored loadout. After `ensure_seeded` this is true for every
## party member; useful for the battle spawn (apply if present, else the unit keeps its own default).
func has_loadout(recruit: Recruit) -> bool:
	return _loadouts.has(recruit)


## Snapshot `unit`'s current five mounts into storage for `recruit`. The hands array is duplicated
## (it's a mutable list) while the armor entries are stored by reference (`Equipment` is immutable
## data, so sharing the instance is safe and lets identity comparisons work in the menu). Called by
## `ensure_seeded` (to persist the default) and by the menu after every equip change.
func capture_from(recruit: Recruit, unit: Unit) -> void:
	_loadouts[recruit] = {
		"hands": unit.hands.duplicate(),
		"head": unit.armor_head,
		"chest": unit.armor_chest,
		"boots": unit.armor_boots,
	}


## Apply `recruit`'s stored loadout onto `unit`, then recompute its stats and refill its pools to
## full (this is pre-battle prep — units enter the fight topped up). No-op returning false if nothing
## is stored (so a unit spawned without going through the menu keeps its own default kit). Assigns
## the mounts directly (rather than re-running `equip`) so the battle reproduces EXACTLY what the menu
## showed — the loadout was already requirement-validated there against the same recruit/class/level.
func apply_to(unit: Unit, recruit: Recruit) -> bool:
	if not _loadouts.has(recruit):
		return false
	var data: Dictionary = _loadouts[recruit]
	unit.hands = (data["hands"] as Array).duplicate()
	unit.armor_head = data["head"]
	unit.armor_chest = data["chest"]
	unit.armor_boots = data["boots"]
	unit.recompute_stats()
	unit.current_hp = unit.max_stats.max_hp
	unit.current_mp = unit.max_stats.max_mp
	return true
