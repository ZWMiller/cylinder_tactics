## A single attack/ability *profile* — the data that parameterizes one swing, shot, or spell.
## This is the "different settings" knob the combat system is built around: melee, arrows, and
## spells are all the SAME mechanical pipeline (range → target → hit roll → damage → animation),
## differing only in the values here. Today only a basic physical melee exists
## (`physical_melee`); a bow would be `min_range 3 / max_range 6`, a fire spell would use
## `MAGICAL` power and a projectile animation, etc.
##
## A `Resource` so attacks can later be authored as `.tres` files (per class/ability) and
## dropped onto units, the same data-driven pattern as `StatBlock` / `ClassDef`. For now they
## are built in code. Kept as pure data (no `Unit` reference): `CombatResolver` reads the
## stats and `Unit` plays the animation, each interpreting these fields.
class_name Attack
extends Resource

## Which attack/defense stat pair this attack uses. Physical reads `phys_atk` vs `phys_def`;
## magical reads `mag_atk` vs `mag_def`. `CombatResolver` maps this to the actual numbers.
enum Power {
	PHYSICAL,  ## phys_atk vs phys_def — swords, fists, arrows.
	MAGICAL,   ## mag_atk vs mag_def — spells.
}

## Which presentation to play when this attack lands. `Unit.play_attack_animation` switches on
## it, so adding a projectile later is a new case here + a new branch there — the mechanics
## don't change.
enum AnimKind {
	BONK,      ## A melee stick-swing on the attacker, aimed at the target.
	ARROW,     ## A projectile that arcs from the attacker to the target's head.
	FIREBALL,  ## A glowing orb that flies straight (no arc) from the attacker to the target.
}

## Player-facing name (the menu label / log text).
@export var display_name: String = "Attack"

## Closest and farthest tile distance (inclusive, Manhattan) this attack can reach. Melee is
## 1..1; a bow might be 3..6 (can't hit point-blank, reaches far). `min_range > 1` is what makes
## ranged attacks unable to hit adjacent foes.
@export var min_range: int = 1
@export var max_range: int = 1

## Which stat pair drives the damage (see Power).
@export var power: Power = Power.PHYSICAL

## Which animation to play (see AnimKind).
@export var anim: AnimKind = AnimKind.BONK

## MP spent to use this attack. 0 for basic weapon attacks (melee/arrow); spells cost MP, which is
## checked before they can be selected and deducted on commit. Kept on the attack profile (not the
## caster) so cost travels with the ability — the same generic pipeline gates a free swing and a
## costed spell, differing only by this number.
@export var mp_cost: int = 0


## The default basic melee attack every unit can perform for now: reach 1, physical, bonk.
## A stand-in until attacks are authored per class/ability; built in code so there's no
## `.tres` to maintain yet.
static func physical_melee() -> Attack:
	var a := Attack.new()
	a.display_name = "Attack"
	a.min_range = 1
	a.max_range = 1
	a.power = Power.PHYSICAL
	a.anim = AnimKind.BONK
	return a


## The basic ranged (bow) attack: a physical shot with a range *band* that excludes
## point-blank — reaches tiles 3..6 away but can't hit an adjacent foe, so an archer wants
## distance. Damage is still `phys_atk − phys_def` for now (same as melee); weapon items will
## later tune ranged power down. Built in code, like `physical_melee`, until attacks are
## authored as `.tres`.
static func physical_ranged() -> Attack:
	var a := Attack.new()
	a.display_name = "Shoot"
	a.min_range = 3
	a.max_range = 6
	a.power = Power.PHYSICAL
	a.anim = AnimKind.ARROW
	return a


## The basic offensive spell: Fireball — a `MAGICAL` shot (so `CombatResolver` reads
## `mag_atk − mag_def`) with a 2..5 range band, costing 5 MP, animated as a glowing orb flying
## straight to the target. The Mage starts knowing this (see `Unit.default_spells_for_class`).
## Built in code for now, like the weapon attacks, until abilities are authored as `.tres`.
static func fireball() -> Attack:
	var a := Attack.new()
	a.display_name = "Fireball"
	a.min_range = 2
	a.max_range = 5
	a.power = Power.MAGICAL
	a.anim = AnimKind.FIREBALL
	a.mp_cost = 5
	return a
