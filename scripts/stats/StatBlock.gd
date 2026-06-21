## A unit's raw stat numbers — the single data schema shared across the whole stat
## system. The SAME type is reused several ways, which is the point:
##   - a CLASS BASE profile (a soldier's level-1 numbers),
##   - a per-level GROWTH profile (what ONE level-up in that class adds — tiny),
##   - a per-person APTITUDE profile (innate offsets that make one recruit differ
##     from another; these may be NEGATIVE),
##   - the BANKED growth a unit has accumulated across its level-ups.
## Final/effective stats are just these added together (see `Unit.recompute_stats`).
##
## Why a `Resource` (and not a Dictionary or a plain object): a Resource is Godot's
## serializable *data asset*. Its `@export` fields show up in the Inspector and can
## be saved as a `.tres` file, so a class's numbers live as editable data on disk,
## consistent with the project's data-driven workflow. For a Python/C++ mind: think
## a `@dataclass` the engine can serialize to a (text) file and edit in a GUI.
##
## GODOT GOTCHA (same one we hit with materials in Unit.gd): Resources are shared by
## *reference* when assigned. If two units pointed at one StatBlock and one mutated
## it, both would change. So every method here returns a BRAND-NEW StatBlock instead
## of mutating in place, and live per-unit values (current HP) are kept off the
## shared template entirely. Treat a StatBlock as immutable once authored.
class_name StatBlock
extends Resource

# --- The schema (see docs/GAME_DESIGN.md §3 for the committed list) -----------
# Kept as ints on purpose: the small-numbers design philosophy (≈30 HP, ≈6-damage
# hits) means whole, human-countable values, never an inflating curve.

@export var max_hp: int = 0           ## Health pool.
@export var max_mp: int = 0           ## Ability/spell resource (0 for a plain soldier).
@export var move: int = 0             ## Tiles reachable per turn.
@export var jump: int = 0             ## Z-height climbable/descendable in one step.
@export var speed: int = 0            ## Turn order / initiative.
@export var phys_atk: int = 0         ## Scales physical damage dealt.
@export var mag_atk: int = 0          ## Scales magical damage dealt.
@export var phys_def: int = 0         ## Mitigates physical damage taken.
@export var mag_def: int = 0          ## Mitigates magical damage taken (magic resist).
@export var evasion: int = 0          ## Reserved: feeds a hidden hit-chance check.
@export var temporal_resist: int = 0  ## Reserved: resist time magic + fall damage.


## Return a NEW StatBlock equal to `self + other`, field by field. The workhorse for
## folding profiles together (base + banked growth, then + aptitude). Returns a fresh
## instance so neither operand is mutated — see the shared-by-reference note above.
func combined(other: StatBlock) -> StatBlock:
	var out := StatBlock.new()
	out.max_hp = max_hp + other.max_hp
	out.max_mp = max_mp + other.max_mp
	out.move = move + other.move
	out.jump = jump + other.jump
	out.speed = speed + other.speed
	out.phys_atk = phys_atk + other.phys_atk
	out.mag_atk = mag_atk + other.mag_atk
	out.phys_def = phys_def + other.phys_def
	out.mag_def = mag_def + other.mag_def
	out.evasion = evasion + other.evasion
	out.temporal_resist = temporal_resist + other.temporal_resist
	return out


## Return a NEW StatBlock equal to `self * factor`, field by field. Not used by the
## per-level-up banking path (which sums whole growth profiles, one per level), but
## handy for previews — e.g. "what would N straight levels in THIS class add?".
func scaled(factor: int) -> StatBlock:
	var out := StatBlock.new()
	out.max_hp = max_hp * factor
	out.max_mp = max_mp * factor
	out.move = move * factor
	out.jump = jump * factor
	out.speed = speed * factor
	out.phys_atk = phys_atk * factor
	out.mag_atk = mag_atk * factor
	out.phys_def = phys_def * factor
	out.mag_def = mag_def * factor
	out.evasion = evasion * factor
	out.temporal_resist = temporal_resist * factor
	return out


## Return a NEW StatBlock with every field floored at 0. Run on the FINAL effective
## stats so a harsh aptitude (e.g. a −2 to a class with low base) can't drive a stat
## negative. We never want a "−1 move" unit; offsets bend the numbers, not break them.
func clamped_nonneg() -> StatBlock:
	var out := StatBlock.new()
	out.max_hp = maxi(0, max_hp)
	out.max_mp = maxi(0, max_mp)
	out.move = maxi(0, move)
	out.jump = maxi(0, jump)
	out.speed = maxi(0, speed)
	out.phys_atk = maxi(0, phys_atk)
	out.mag_atk = maxi(0, mag_atk)
	out.phys_def = maxi(0, phys_def)
	out.mag_def = maxi(0, mag_def)
	out.evasion = maxi(0, evasion)
	out.temporal_resist = maxi(0, temporal_resist)
	return out


## One-line summary for debug prints (e.g. when verifying a recruit's effective
## block). Not used in gameplay; purely a developer convenience.
func describe() -> String:
	return "HP %d  MP %d  MOV %d  JMP %d  SPD %d  PATK %d  MATK %d  PDEF %d  MDEF %d  EVA %d  TRES %d" % [
		max_hp, max_mp, move, jump, speed,
		phys_atk, mag_atk, phys_def, mag_def, evasion, temporal_resist,
	]
