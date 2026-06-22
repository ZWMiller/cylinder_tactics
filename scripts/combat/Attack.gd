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
	BONK,  ## A melee stick-swing on the attacker, aimed at the target.
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
