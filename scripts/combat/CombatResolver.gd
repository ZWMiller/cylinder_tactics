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


## How strongly armor mitigates each channel — the two global tuning KNOBS for "how effective
## is armor relative to damage", one per channel so physical and magical lethality tune
## independently. A piece's `armor_phys`/`armor_mag` are authored as chunky numbers; these
## scales convert the summed armor into felt mitigation, so retuning the whole game's armor is
## one number, and fixing one off-feeling piece is a local edit. See docs/EQUIPMENT.md.
const ARMOR_PHYS_SCALE := 0.16
const ARMOR_MAG_SCALE := 0.18


## Probability [0,1] that `attacker` hits `target` with `attack`. **MOCK: always 1.0** for the
## deterministic-first pass (per docs/GAME_DESIGN.md — "always hit; the dice come later"). The
## real version will fold in evasion / height / status — and the equipment hooks are already in
## place for it: `Equipment.accuracy` (per weapon) and a future dodge stat will drive roughly
## `attacker_accuracy × weapon.accuracy − target_dodge`. For now this stays the one named seam.
static func hit_chance(_attacker: Unit, _target: Unit, _attack: Attack) -> float:
	return 1.0


## Damage `attacker` deals to `target` with `attack`, via the MULTIPLICATIVE model
## (docs/EQUIPMENT.md / DECISION_LOG.md):
##   offense    = round(atk_stat × equipped_weapon.power)      # unarmed power = 1.0
##   mitigation = round(def_stat × summed_armor × scale_knob)
##   damage     = max(1, offense − mitigation)
## "round" is round-half-up (`floor(x + 0.5)`) so fractional results land forgivingly rather than
## always truncating down. Floored at 1 so an attack always chips at least a point, never heals.
## The channel (physical vs magical) is read off the `Attack`, selecting the atk/def stat pair,
## the matching equipped weapon, and the armor channel + scale knob.
static func compute_damage(attacker: Unit, target: Unit, attack: Attack) -> int:
	return maxi(1, offense(attacker, attack.power == Attack.Power.PHYSICAL) - _mitigation(target, attack))


## The OFFENSE term on its own — `round(atk_stat × equipped_weapon.power)`, the number mitigation is
## later subtracted from. `physical` picks the channel: true → ATTACK POWER (`phys_atk` × a physical
## weapon), false → MAGIC POWER (`mag_atk` × a staff/wand). An unmatched channel falls back to the
## unarmed 1.0 baseline via `Unit.weapon_power_for` (the raw stat IS the damage). Exposed publicly so
## UI — the loadout panel's ATTACK/MAGIC POWER readouts — reads the EXACT same math the damage calc
## uses instead of re-deriving it; `compute_damage` calls it too, so the formula lives here only.
static func offense(attacker: Unit, physical: bool) -> int:
	var channel: int = Attack.Power.PHYSICAL if physical else Attack.Power.MAGICAL
	var atk: int = attacker.max_stats.phys_atk if physical else attacker.max_stats.mag_atk
	return _round_half_up(float(atk) * attacker.weapon_power_for(channel))


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


## The target's mitigation for this attack: defense stat × summed armor in the matching channel ×
## that channel's scale knob, round-half-up. An unarmored target sums to 0 armor → 0 mitigation
## (full damage), so the defense STAT only pays off when there's armor to multiply.
static func _mitigation(target: Unit, attack: Attack) -> int:
	var physical := attack.power == Attack.Power.PHYSICAL
	var def_stat := target.max_stats.phys_def if physical else target.max_stats.mag_def
	var armor := target.armor_total(physical)
	var scale := ARMOR_PHYS_SCALE if physical else ARMOR_MAG_SCALE
	return _round_half_up(float(def_stat) * armor * scale)


## Round half up (`floor(x + 0.5)`): the shared, forgiving rounding for offense and mitigation,
## so a 13.95 lands as 14 rather than truncating to 13. Returns an int.
static func _round_half_up(x: float) -> int:
	return int(floor(x + 0.5))
