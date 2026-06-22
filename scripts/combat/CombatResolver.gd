## The combat *mechanics* — pure number-crunching, deliberately separate from presentation
## (the animations live on `Unit`, the targeting/flow lives in `Main`). One generic pipeline
## that every attack runs through; an attack's `Attack` profile supplies the differing values.
##
## A module of `static` functions (like `UnitClasses` / `StatRoll`), so there's nothing to
## instantiate — call `CombatResolver.resolve(...)`. Kept side-effect free: it computes an
## outcome and returns it; the caller applies damage and plays animations. That split is what
## lets the same resolution feed a player attack, an enemy attack, or a scripted event later.
class_name CombatResolver
extends RefCounted


## Probability [0,1] that `attacker` hits `target` with `attack`. **MOCK: always 1.0** for the
## deterministic-first pass (per docs/GAME_DESIGN.md — "always hit; the dice come later"). The
## real version will fold in evasion / height / status; it lives here as one named seam so the
## formula has a home and the rest of the pipeline (roll, damage) is already wired around it.
static func hit_chance(_attacker: Unit, _target: Unit, _attack: Attack) -> float:
	return 1.0


## Damage `attacker` deals to `target` with `attack`: `atk − def`, floored at 1 (the agreed
## subtractive formula, small-numbers philosophy — docs/DECISION_LOG.md). Floored at 1 so an
## attack always chips at least a point, never heals.
static func compute_damage(attacker: Unit, target: Unit, attack: Attack) -> int:
	return maxi(1, _offense(attacker, attack) - _defense(target, attack))


## Resolve one attack into an outcome the caller acts on. Rolls the dice against `hit_chance`
## and computes damage on a hit. Returns a Dictionary:
##   { "hit": bool, "chance": float, "roll": float, "damage": int }
## (damage is 0 on a miss). A plain Dictionary keeps this first pass light; promote to a small
## class if outcomes grow richer (crits, status, multi-hit).
static func resolve(attacker: Unit, target: Unit, attack: Attack, rng: RandomNumberGenerator) -> Dictionary:
	var chance := hit_chance(attacker, target, attack)
	var roll := rng.randf()
	var hit := roll < chance
	return {
		"hit": hit,
		"chance": chance,
		"roll": roll,
		"damage": compute_damage(attacker, target, attack) if hit else 0,
	}


## The attacker's offensive stat for this attack's power channel.
static func _offense(unit: Unit, attack: Attack) -> int:
	return unit.max_stats.phys_atk if attack.power == Attack.Power.PHYSICAL else unit.max_stats.mag_atk


## The target's defensive stat for this attack's power channel.
static func _defense(unit: Unit, attack: Attack) -> int:
	return unit.max_stats.phys_def if attack.power == Attack.Power.PHYSICAL else unit.max_stats.mag_def
