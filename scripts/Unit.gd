## A single combat unit: a cylinder body (color = allegiance) wearing a hat
## (shape + color = class). See docs/GAME_DESIGN.md §7 for the visual language and
## docs/UNIT.md for this component.
##
## This script is attached to the root of `scenes/Unit.tscn`, so `Unit` IS the
## self-contained object you interact with in the scene: it owns its appearance
## now and will own its stats, grid coordinate, and combat methods later. The
## `.tscn` only authors the *node layout* (a Body and a Hat mesh child); this
## script owns *identity* (which side, which class) and applies it to that layout.
##
## Reskinning (the requirement that drove this design): every unit builds its OWN
## materials in code. Godot materials are *resources* — if two units shared one
## `StandardMaterial3D`, recoloring one would recolor the other. Giving each unit
## its own material (via `material_override`) keeps units independently skinnable,
## so you can spawn many and tint each freely. This is a key Godot gotcha worth
## remembering: shared resources are shared *state*, not just shared definitions.
class_name Unit
extends Node3D

## Emitted when a walk started by `move_along` reaches its last point and the unit goes
## idle. Carries the unit itself so a listener bound to several units can tell them apart.
## The enemy AI uses this to end an enemy's turn only *after* it finishes stepping there.
signal move_finished(unit: Unit)

## The two sides. Body color reads allegiance, independent of class — so a player
## archer and an enemy archer share a hat but differ in body color.
enum Allegiance {
	PLAYER,  ## The player's side.
	ENEMY,   ## The opposing side.
}

## What the unit's *current weapon* does, which decides whether the "Attack" action runs the
## melee pipeline or the ranged one (see `basic_attack`). A per-unit value (not a `StatBlock`
## field) because, like `current_hp`/`ct`, it's live unit state — eventually set by the equipped
## weapon item; for now defaulted from the class (archers carry a bow). It does NOT *sum* across
## base/growth/aptitude the way stat numbers do, which is exactly why it lives here off the
## shared, summed `StatBlock` template.
enum WeaponType {
	MELEE,   ## Reach-1 physical strike (the bonk) — soldiers, mages for now.
	RANGED,  ## A bow: the 3..6 arcing arrow shot.
}

# --- Identity (editable in the Inspector AND settable from code via configure) -

## Which side this unit fights for; drives the body color.
@export var allegiance: Allegiance = Allegiance.PLAYER

## This unit's class; drives the hat shape + color (see UnitClasses).
@export var unit_class: UnitClasses.Class = UnitClasses.Class.SOLDIER

## What the current weapon does (see WeaponType). Defaulted from the class wherever the class
## is (re)applied — `_apply_appearance` — so archers come up RANGED and everyone else MELEE,
## without re-deriving it in four places. The "Attack" action reads this to pick the pipeline.
var weapon_type: WeaponType = WeaponType.MELEE

## The spells this unit knows — `Attack` profiles surfaced under the "Spell" menu (each costs MP).
## Defaulted from the class wherever the class is applied (mage → Fireball), the same way as
## `weapon_type`; a real spell-learning/job system will later grow this list independently of
## class. The "Spell" menu option only appears when this is non-empty (see `has_spells`).
var known_spells: Array[Attack] = []

## The unit's tile address on the battlefield grid, deliberately *decoupled* from
## its world position (docs/GAME_DESIGN.md §8). The mover (Main, later the turn
## system) updates this; `move_to` only handles the *visual* glide.
var grid_coord: Vector2i = Vector2i.ZERO

# --- Equipment (weapons + armor that feed the combat math) -------------------
# The mount points: two hands (a weapon and a shield/offhand, or one two-hander filling
# both) plus head/chest/boots armor. Gear supplies the multiplicative damage model's
# weapon `power` and summed `armor_phys/mag` (see docs/EQUIPMENT.md and `CombatResolver`),
# and may carry stat-rider `modifiers` folded into `max_stats`. Set at spawn from the class
# default loadout; a real inventory/equip UI lands with the loot system.

## The five distinct equip MOUNTS as the loadout UI addresses them: the two hands plus the three
## armor pieces. The combat code stores hands as an array + three named armor vars, but the menu
## (and `equip_to_slot` / `clear_slot` / `item_in_slot`) speak in these named slots so "the off
## hand" is an explicit target, not "whichever hand `equip` happened to pick". Values map to:
## MAIN_HAND→hands[0], OFF_HAND→hands[1], HEAD/CHEST/BOOTS→the armor vars.
enum LoadoutSlot { MAIN_HAND, OFF_HAND, HEAD, CHEST, BOOTS }

## The two hand mounts, front = main hand. A two-handed weapon sits in `hands[0]` with
## `hands[1]` left null. Entries are `Equipment` or null. Iterated for weapon power, armor,
## and modifiers, so it stays a plain list rather than two named vars.
var hands: Array[Equipment] = [null, null]

## The three armor mounts. Each is an `Equipment` (slot HEAD/CHEST/BOOTS) or null.
var armor_head: Equipment = null
var armor_chest: Equipment = null
var armor_boots: Equipment = null

# --- Stats (class base + per-person aptitude + banked level-up growth) ---------
# Effective max stats = current class base + banked growth + aptitude:
#   - `unit_class` (above) selects the base profile (and appearance),
#   - `recruit` carries the per-person aptitude + identity (null for legacy spawns),
#   - `level_history` records the class held at each past level-up — the FFT-style
#     bank that makes a unit's stats remember the jobs it leveled in.
# See docs/GAME_DESIGN.md §3 and the stat scripts under scripts/stats/.

## The person behind this unit (authored PC or rolled enemy): innate aptitude + name.
## May be null for units spawned the old appearance-only way via `configure`.
var recruit: Recruit = null

## This unit's level. Level 1 = class base only; each `level_up` appends to history.
@export var level: int = 1

## Class held at each past level-up — one int per level gained (length == level − 1).
## Summed into banked growth by `UnitClasses.banked_growth`; written by `level_up` /
## seeded by `init_from_recruit`.
var level_history: Array[int] = []

## Computed effective MAX stats — the read-only result of `recompute_stats`. Don't
## edit directly; change an input (class, level, aptitude) and recompute.
var max_stats: StatBlock = null

## Experience needed to gain one level. A flat placeholder until a real leveling curve
## is designed — exposed now so EXP can be shown as "current / next", and so future
## leveling code reads one named threshold instead of a magic number. See docs/STATS.md.
const EXP_PER_LEVEL := 100

## Live, per-unit pools — the ONLY mutable stat state, kept off the shared templates
## (the shared-by-reference gotcha in the class docstring).
var current_hp: int = 0
var current_mp: int = 0

## Experience banked toward the next level. A live per-unit counter (like `current_hp`),
## deliberately NOT a `StatBlock` field: experience is mutable progress, not a class-
## derived stat that sums across base/growth/aptitude — so it lives here, off the shared
## templates. Tracked + displayed only for now; spending it on a level-up is wired when
## the leveling system lands (see `level_up`).
var current_exp: int = 0

## Charge Time — the FFT-style initiative counter `TurnManager` ticks up by this unit's
## `speed` each beat; at `CT_THRESHOLD` the unit takes its turn, then `CT_THRESHOLD` is
## subtracted (excess carries over), so faster units act *more often*. Like `current_exp`
## this is mutable per-unit progress, deliberately NOT a `StatBlock` field — `speed` (the
## charge rate) is the class-derived stat; `ct` (the accumulated charge) is live state. The
## scheduler owns it; it lives here so it travels with the unit.
var ct: int = 0

# --- Movement (visual glide between tiles) -----------------------------------

## Glide speed in world units per second. Constant speed (via `move_toward`) gives
## a predictable arrival, unlike the ease-out of a `lerp`.
const MOVE_SPEED := 6.0

## "Bonk" melee animation tunables — a brown stick that winds up, swings on the attacker toward
## the target, pauses on impact, then recoils. Kept here with the other Unit presentation so the
## look lives next to the body. Tuned slow + readable: wind up, slow swing, beat, recoil.
const _BONK_STICK_COLOR := Color(0.40, 0.26, 0.13)        ## Brown, like a wooden cudgel.
const _BONK_STICK_SIZE := Vector3(0.14, 0.14, 0.75)       ## Chunky rod, long along +Z (toward target).
const _BONK_RAISED_DEG := -55.0                            ## Stick angle wound back, pre-swing.
const _BONK_STRUCK_DEG := 35.0                             ## Stick angle at the bottom of the swing.
const _BONK_RECOIL_DEG := -20.0                            ## Settle angle after the hit.
const _BONK_LOAD_TIME := 0.18                              ## Seconds held wound-back before swinging (the "load").
const _BONK_DOWN_TIME := 0.28                              ## Seconds for the (slow, accelerating) downswing.
const _BONK_HOLD_TIME := 0.18                              ## Seconds paused at impact — a readable beat.
const _BONK_UP_TIME := 0.18                                ## Seconds for the recoil.

## Arrow projectile tunables — a thin black rod that arcs from the attacker's head to the
## target's head. The flight time is constant (not distance-scaled) so it reads the same at any
## range; the arc rises this many world units above the straight chord at its peak.
const _ARROW_COLOR := Color(0.04, 0.04, 0.04)             ## Near-black shaft.
const _ARROW_LENGTH := 0.6                                 ## Long axis of the rod.
const _ARROW_RADIUS := 0.04                                ## Thin — reads as a shaft, not a pole.
const _ARROW_FLIGHT_TIME := 0.55                           ## Seconds from loose to impact.
const _ARROW_ARC_HEIGHT := 2.2                             ## Peak rise above the start→end chord.

## Fireball projectile tunables — a glowing red-orange orb that flies STRAIGHT (no arc) to the
## target. The bloom comes from a bright HDR emission (energy ≫ 1) lifting it over the
## WorldEnvironment's glow threshold; tune `_FIREBALL_GLOW_ENERGY` (and the env glow) for more/less.
const _FIREBALL_COLOR := Color(1.0, 0.35, 0.06)           ## Firey red-orange.
const _FIREBALL_RADIUS := 0.30                             ## Orb size.
const _FIREBALL_GLOW_ENERGY := 6.0                         ## Emission multiplier — high, for strong bloom.
const _FIREBALL_FLIGHT_TIME := 0.45                        ## Seconds from cast to impact (flat, quick).

## Death animation tunables — tip over sideways, then fade out (both eased slow for readability).
const _DEATH_FALL_TIME := 0.55                             ## Seconds to topple to the ground.
const _DEATH_FADE_TIME := 0.80                             ## Seconds to fade to transparent.

## The remaining points this unit is walking through, front first (in the parent's
## local space). Built from `Battlefield.path_to_world_points`, so the unit steps
## up/down tile by tile instead of gliding in a straight line. Empty when stopped.
var _move_queue: Array[Vector3] = []

## True while a walk is in progress. Gates `_process` so an idle unit costs nothing,
## and lets callers (Main) avoid interrupting a move in progress.
var _is_moving: bool = false

# --- Cached child references (resolved once the node is in the tree) ----------
# `@onready` runs the assignment just before `_ready`, so these are valid for the
# whole lifetime; `$Body` / `$Hat` are the children authored in Unit.tscn.
@onready var _body: MeshInstance3D = $Body
@onready var _hat: MeshInstance3D = $Hat


## Godot lifecycle hook: runs once when the unit enters the scene tree. Applies
## the current allegiance/class to the meshes and materials.
func _ready() -> void:
	_apply_appearance()
	# Units spawned appearance-only (configure() with no recruit) still need valid
	# stats, so derive a baseline from the class and fill the pools to full. A unit set
	# up via init_from_recruit already has max_stats, so we don't clobber it here.
	if max_stats == null:
		recompute_stats()
		current_hp = max_stats.max_hp
		current_mp = max_stats.max_mp
		_apply_default_loadout()   # gear the appearance-only path too (needs max_stats first)
	# Idle until something calls `move_to`; no need to run `_process` every frame.
	set_process(false)


## Walk this unit through `points` in order (parent-local positions), at a constant
## speed, stopping at the last. Pass the polyline from
## `Battlefield.path_to_world_points` so the unit steps up/down tile by tile. The
## caller owns `grid_coord`/occupancy. An empty list is a no-op.
func move_along(points: Array) -> void:
	if points.is_empty():
		return
	_move_queue = points.duplicate()
	_is_moving = true
	set_process(true)


## True while a walk is in progress, so the input handler can avoid starting a new
## move (or changing the active unit) mid-step.
func is_moving() -> bool:
	return _is_moving


## Godot lifecycle hook: runs every frame, but only while a walk is active (we
## toggle it off when idle). Advances toward the next queued point at a constant
## speed; on arrival, pops it and aims at the next. `move_toward` clamps exactly to
## the target on the final step, so the equality check lands precisely.
func _process(delta: float) -> void:
	if _move_queue.is_empty():
		_is_moving = false
		set_process(false)
		# Announce arrival so turn/AI code can react (e.g. end an enemy's turn) without
		# polling `is_moving()` every frame.
		move_finished.emit(self)
		return
	var target: Vector3 = _move_queue[0]
	position = position.move_toward(target, MOVE_SPEED * delta)
	if position.is_equal_approx(target):
		position = target  # snap, so floating-point drift doesn't accumulate
		_move_queue.pop_front()


## Alpha of the active-tile marker, so the tile cap reads through the highlight rather
## than being painted over. Tune for a stronger/fainter pad.
const ACTIVE_MARKER_ALPHA := 0.6

## The highlight color for a side — a bright, saturated version of the allegiance hue,
## used by `Main` to tint the active-unit tile marker (blue ally / red enemy) so whose
## turn it is reads at a glance. Brighter than `allegiance_color` (the body) so the
## marker stands out from the unit standing on it; translucent so the surface shows
## through. Magenta = unmapped side.
static func active_color(side: Allegiance) -> Color:
	match side:
		Allegiance.PLAYER:
			return Color(0.35, 0.6, 1.0, ACTIVE_MARKER_ALPHA)   # bright blue
		Allegiance.ENEMY:
			return Color(1.0, 0.35, 0.35, ACTIVE_MARKER_ALPHA)  # bright red
		_:
			return Color(Color.MAGENTA, ACTIVE_MARKER_ALPHA)


## Set this unit's side and class in one call, then refresh its look. The
## convenient entry point for code-spawning many units from data:
##   var u := UNIT_SCENE.instantiate(); u.configure(Allegiance.ENEMY, Class.MAGE)
## Safe to call before the unit is in the tree (the values are stored and applied
## by `_ready`) or after (it re-applies immediately).
func configure(side: Allegiance, klass: UnitClasses.Class) -> void:
	allegiance = side
	unit_class = klass
	if is_node_ready():
		_apply_appearance()


# --- Stats & class (the job system) ------------------------------------------

## Set this unit up from a `Recruit` — the rich spawn path shared by authored PCs and
## rolled enemies. Adopts the recruit's starting class + level, seeds the level history
## as if it leveled the whole way in that class, computes max stats, and fills HP/MP to
## full. After this the unit is combat-ready.
func init_from_recruit(r: Recruit) -> void:
	recruit = r
	unit_class = r.starting_class
	level = maxi(1, r.starting_level)
	# A freshly spawned unit has no real per-level job history, so assume it leveled
	# entirely in its starting class. (PCs usually start at level 1 → empty history.)
	level_history.clear()
	for _i in range(level - 1):
		level_history.append(unit_class)
	if is_node_ready():
		_apply_appearance()
	recompute_stats()
	current_hp = max_stats.max_hp
	current_mp = max_stats.max_mp
	# Gear depends on `max_stats` (requirement checks), so equip the class default loadout last.
	_apply_default_loadout()


## Recompute `max_stats` from current class base + banked level-up growth + aptitude,
## then clamp the live pools so they never exceed the new maxes. Call after anything
## that changes the inputs (reclass, level-up). Pure recompute — it does NOT heal.
func recompute_stats() -> void:
	var cd := UnitClasses.class_def(unit_class)
	# Defensive: an unmapped class has no asset. Fall back to an empty block so the
	# unit still functions (zeroed) instead of crashing on a null base.
	var base: StatBlock = cd.base if cd != null and cd.base != null else StatBlock.new()
	var banked := UnitClasses.banked_growth(level_history)
	# Effective = class base + banked growth + aptitude + equipment riders, then floored at 0.
	# Equipment modifiers (e.g. the Rapier's +1 speed) fold in here like aptitude, so re-equipping
	# is just another recompute.
	max_stats = base.combined(banked).combined(_aptitude()).combined(_equipment_modifiers()).clamped_nonneg()
	current_hp = mini(current_hp, max_stats.max_hp)
	current_mp = mini(current_mp, max_stats.max_mp)


## Gain one level IN THE CURRENT CLASS: bank this class's growth and raise the live
## pools by the max-stat increase (so a level-up actually heals you by the gain). This
## is where the "level as a mage, keep the mage gains" history entry is written.
func level_up() -> void:
	level += 1
	level_history.append(unit_class)
	var prev_hp_max: int = max_stats.max_hp if max_stats != null else 0
	var prev_mp_max: int = max_stats.max_mp if max_stats != null else 0
	recompute_stats()
	current_hp += maxi(0, max_stats.max_hp - prev_hp_max)
	current_mp += maxi(0, max_stats.max_mp - prev_mp_max)


## Reclass / job change: swap the class (base + appearance) while KEEPING this unit's
## identity, level, banked history, and aptitude. The base changes immediately, but
## growth banked under previous jobs persists — the core of the job system. Current
## HP/MP are clamped down by `recompute_stats` if the new base is frailer.
func set_class(klass: int) -> void:
	unit_class = klass
	if is_node_ready():
		_apply_appearance()
	recompute_stats()


## The per-person aptitude offsets, or an empty (all-zero) block if this unit has no
## recruit. Centralizes the null-guard so `recompute_stats` stays clean.
func _aptitude() -> StatBlock:
	if recruit != null and recruit.aptitude != null:
		return recruit.aptitude
	return StatBlock.new()


## One-line stat summary for debug prints: who, class, level, experience, charge, and block.
func stats_summary() -> String:
	var block: String = max_stats.describe() if max_stats != null else "(no stats)"
	return "%s — L%d %s (EXP %d/%d, CT %d/%d): %s" % [
		display_name(), level, UnitClasses.display_name(unit_class),
		current_exp, EXP_PER_LEVEL, ct, TurnManager.CT_THRESHOLD, block,
	]


## This unit's display name. Authored PCs and rolled enemies both carry a `recruit`
## (the rolled ones get a name sampled from `UnitNames`), so this is the recruit name;
## only legacy appearance-only spawns fall back to the bare class label.
func display_name() -> String:
	return recruit.display_name if recruit != null else UnitClasses.display_name(unit_class)


## Multi-line stat readout for the floating hover/inspect panel — the same numbers as
## `stats_summary`, laid out over a few lines so it reads at a glance above the unit's
## head. HP/MP show current/max so the panel stays meaningful once combat spends them.
func stats_panel_text() -> String:
	if max_stats == null:
		return "%s\n(no stats)" % display_name()
	var s := max_stats
	# CT (Charge Time) is live initiative progress, shown beside SPD (its charge rate) as
	# current/threshold — TurnManager.CT_THRESHOLD is the bar a unit fills to take its turn.
	return "%s — L%d %s\nEXP %d/%d\nHP %d/%d   MP %d/%d\nMOV %d  JMP %d  SPD %d  CT %d/%d\nPATK %d  MATK %d\nPDEF %d  MDEF %d  EVA %d\n%s" % [
		display_name(), level, UnitClasses.display_name(unit_class),
		current_exp, EXP_PER_LEVEL,
		current_hp, s.max_hp, current_mp, s.max_mp,
		s.move, s.jump, s.speed, ct, TurnManager.CT_THRESHOLD,
		s.phys_atk, s.mag_atk, s.phys_def, s.mag_def, s.evasion,
		equipment_summary(),
	]


# --- Combat ------------------------------------------------------------------

## The basic attack this unit performs from the "Attack" action, chosen by its current
## `weapon_type`: a bow gives the 3..6 arrow shot, anything else the reach-1 melee bonk. This is
## the seam the menu uses — pick the weapon, get the matching pipeline (range band, targeting,
## animation) for free. Returns a fresh profile each call.
func basic_attack() -> Attack:
	match weapon_type:
		WeaponType.RANGED:
			return Attack.physical_ranged()
		_:
			return Attack.physical_melee()


## The damage multiplier from the equipped weapon matching `power_channel` (an `Attack.Power`):
## a physical attack reads an equipped physical weapon, a magical attack an equipped staff/wand.
## Returns 1.0 (the unarmed baseline — raw atk stat *is* the damage) when no matching weapon is
## held, so a weaponless unit still fights. `CombatResolver` multiplies the atk stat by this.
func weapon_power_for(power_channel: int) -> float:
	var want := Equipment.Channel.PHYSICAL if power_channel == Attack.Power.PHYSICAL else Equipment.Channel.MAGICAL
	for h in hands:
		if h != null and h.channel == want:
			return h.power
	return 1.0


## Sum of this unit's armor in one channel (`physical` → armor_phys, else armor_mag) across every
## equipped piece — hands (shields) plus the three armor slots. Empty mounts contribute 0. This is
## the `armor_*_total` the mitigation formula multiplies by the defense stat and the scale knob.
func armor_total(physical: bool) -> float:
	var total := 0.0
	for e in _all_equipment():
		total += e.armor_phys if physical else e.armor_mag
	return total


## The accuracy multiplier from the equipped weapon for `power_channel`, defaulting to 1.0.
## A dormant hook for the future hit-chance formula (see `CombatResolver.hit_chance`); nothing
## reads it yet, but it travels with the gear so evasion can plug in without re-plumbing.
func weapon_accuracy_for(power_channel: int) -> float:
	var want := Equipment.Channel.PHYSICAL if power_channel == Attack.Power.PHYSICAL else Equipment.Channel.MAGICAL
	for h in hands:
		if h != null and h.channel == want:
			return h.accuracy
	return 1.0


## Whether this unit meets `item`'s requirement floors (checked field-by-field against the
## current effective `max_stats`). A null/absent requirement is always satisfiable; before stats
## are computed we allow it (spawn equips after `recompute_stats`). This is the strength/speed/
## magic gate — a frail mage fails a Bastard Sword's phys_atk floor.
func can_equip(item: Equipment) -> bool:
	if item == null or item.requirements == null or max_stats == null:
		return true
	var r := item.requirements
	var s := max_stats
	return s.max_hp >= r.max_hp and s.max_mp >= r.max_mp and s.move >= r.move \
		and s.jump >= r.jump and s.speed >= r.speed and s.phys_atk >= r.phys_atk \
		and s.mag_atk >= r.mag_atk and s.phys_def >= r.phys_def and s.mag_def >= r.mag_def


## Equip `item` into its slot and recompute stats (its modifiers may change them). Returns false
## without changing anything if requirements aren't met. A two-handed weapon fills both hands; a
## one-hander bumps off a held two-hander first, then takes the first free hand (else the main).
func equip(item: Equipment) -> bool:
	if not can_equip(item):
		return false
	match item.slot:
		Equipment.Slot.HAND:
			if item.hands >= 2:
				hands[0] = item
				hands[1] = null   # a two-hander occupies both mounts
			else:
				if hands[0] != null and hands[0].hands >= 2:
					hands[0] = null   # drop the held two-hander to free a hand
				if hands[0] == null:
					hands[0] = item
				elif hands[1] == null:
					hands[1] = item
				else:
					hands[0] = item   # both full → replace main hand
		Equipment.Slot.HEAD:
			armor_head = item
		Equipment.Slot.CHEST:
			armor_chest = item
		Equipment.Slot.BOOTS:
			armor_boots = item
	recompute_stats()
	return true


## Equip `item` into an EXPLICIT mount (`LoadoutSlot`), the loadout menu's targeted counterpart to
## `equip` (which auto-picks a hand). Returns false without changing anything if requirements aren't
## met. The hand rules keep the two-hand invariant intact:
##   - MAIN_HAND: place the item in the main hand; a two-hander also clears the off hand (it spans both).
##   - OFF_HAND: a two-hander can't be an off-hand, so it goes to the main hand (clearing the off);
##     otherwise, if a two-hander is currently held it's dropped to free the hand, then the item takes
##     the off hand.
## Armor slots simply replace. Recomputes stats afterward (modifiers/set bonus may shift them).
func equip_to_slot(item: Equipment, slot: LoadoutSlot) -> bool:
	if not can_equip(item):
		return false
	match slot:
		LoadoutSlot.MAIN_HAND:
			hands[0] = item
			if item.hands >= 2:
				hands[1] = null
		LoadoutSlot.OFF_HAND:
			if item.hands >= 2:
				hands[0] = item
				hands[1] = null
			else:
				if hands[0] != null and hands[0].hands >= 2:
					hands[0] = null   # a two-hander can't share with an off-hand; drop it
				hands[1] = item
		LoadoutSlot.HEAD:
			armor_head = item
		LoadoutSlot.CHEST:
			armor_chest = item
		LoadoutSlot.BOOTS:
			armor_boots = item
	recompute_stats()
	return true


## Empty a single mount (the menu's "remove gear" path) and recompute. Removing is always allowed —
## a bare slot is a valid choice.
func clear_slot(slot: LoadoutSlot) -> void:
	match slot:
		LoadoutSlot.MAIN_HAND:
			hands[0] = null
		LoadoutSlot.OFF_HAND:
			hands[1] = null
		LoadoutSlot.HEAD:
			armor_head = null
		LoadoutSlot.CHEST:
			armor_chest = null
		LoadoutSlot.BOOTS:
			armor_boots = null
	recompute_stats()


## What's currently in a given mount (or null) — the menu reads this to label each slot row.
func item_in_slot(slot: LoadoutSlot) -> Equipment:
	match slot:
		LoadoutSlot.MAIN_HAND:
			return hands[0]
		LoadoutSlot.OFF_HAND:
			return hands[1]
		LoadoutSlot.HEAD:
			return armor_head
		LoadoutSlot.CHEST:
			return armor_chest
		LoadoutSlot.BOOTS:
			return armor_boots
	return null


## The equipped OFFENSIVE weapon (first hand item with a damage channel), or null if fighting
## unarmed. Drives the menu's weapon-name readout (offense numbers come from `offense_power`).
func active_weapon() -> Equipment:
	for h in hands:
		if h != null and h.channel != Equipment.Channel.NONE:
			return h
	return null


## The `set_id` of the full armor set this unit is wearing (head + chest + boots all matching), or
## &"" if the set is incomplete/mixed. The single source of "is a set active" — `_active_set_bonus`
## (the stat rider) and the menu's SET BONUS checkbox both read it.
func active_set_id() -> StringName:
	if armor_head == null or armor_chest == null or armor_boots == null:
		return &""
	var id := armor_head.set_id
	if id == &"" or armor_chest.set_id != id or armor_boots.set_id != id:
		return &""
	return id


## Every non-null equipped piece, hands then armor — the one place that enumerates the mounts, so
## armor-summing and modifier-folding share a single definition of "what's equipped".
func _all_equipment() -> Array[Equipment]:
	var out: Array[Equipment] = []
	for h in hands:
		if h != null:
			out.append(h)
	for a in [armor_head, armor_chest, armor_boots]:
		if a != null:
			out.append(a)
	return out


## The summed stat riders folded into `max_stats` by `recompute_stats`: each piece's own `modifiers`
## (e.g. Rapier +1 speed) PLUS the set bonus if a full matching armor set is worn. Empty block when
## nothing applies.
func _equipment_modifiers() -> StatBlock:
	var sum := StatBlock.new()
	for e in _all_equipment():
		if e.modifiers != null:
			sum = sum.combined(e.modifiers)
	var bonus := _active_set_bonus()
	if bonus != null:
		sum = sum.combined(bonus)
	return sum


## The set bonus a unit currently earns, or null. Requires all three armor slots filled with the
## SAME non-empty `set_id` (e.g. full Cloth) — a partial set grants nothing. Set bonuses are defined
## centrally in `Equipment.set_bonus`.
func _active_set_bonus() -> StatBlock:
	var id := active_set_id()
	if id == &"":
		return null
	return Equipment.set_bonus(id)


## A short gear line for the inspect panel: the active weapon (name × power) and the summed
## armor (phys/mag), so the equipment driving the combat math is visible on hover.
func equipment_summary() -> String:
	var weapon := "unarmed"
	for h in hands:
		if h != null and h.channel != Equipment.Channel.NONE:
			weapon = "%s x%.2f" % [h.display_name, h.power]
			break
	var line := "GEAR %s\nARMOR %d/%d" % [weapon, int(armor_total(true)), int(armor_total(false))]
	# Show the active set name so the set bonus reads as "on" at a glance (e.g. "[cloth set]").
	var set_id := active_set_id()
	if set_id != &"":
		line += "  [%s set]" % set_id
	return line


## Whether this unit knows at least one spell — gates the "Spell" action in the turn menu so it
## only appears for casters.
func has_spells() -> bool:
	return not known_spells.is_empty()


## Spend `amount` MP, never below 0. Called when a spell commits (after the caller has confirmed
## the unit could afford it). Like `apply_damage`, this just mutates the live pool; affordability
## is decided by the caller (the spell menu greys out what you can't pay for).
func spend_mp(amount: int) -> void:
	current_mp = maxi(0, current_mp - amount)


## Subtract `amount` from this unit's live HP, never below 0. The attacker's resolver computed
## the number; this just applies it. Death is detected separately via `is_alive` so the caller
## can sequence the death animation.
func apply_damage(amount: int) -> void:
	current_hp = maxi(0, current_hp - amount)


## True while this unit still has HP. Once false the unit is dead and should be removed (after
## its death animation) — see `Main._kill_unit`.
func is_alive() -> bool:
	return current_hp > 0


## Play the attack animation for `anim_kind`, aimed at `target_position` (world space), and
## return when it finishes. The animation is intentionally decoupled from the mechanics so the
## caller can sequence it around the damage step and stack other reactions; switching on the
## kind keeps room for future projectiles/spells that reuse the same call.
func play_attack_animation(anim_kind: int, target_position: Vector3) -> void:
	match anim_kind:
		Attack.AnimKind.BONK:
			await _play_bonk(target_position)
		Attack.AnimKind.ARROW:
			await _play_arrow(target_position)
		Attack.AnimKind.FIREBALL:
			await _play_fireball(target_position)
		_:
			await _play_bonk(target_position)


## The melee "bonk": spawn a thin brown stick on this unit, oriented at the target, swing it
## down then recoil, and remove it. Built under a pivot node so a single rotation drives the
## swing; the pivot is yawed to face the target so the arc reads as a strike toward it.
func _play_bonk(target_position: Vector3) -> void:
	var pivot := Node3D.new()
	add_child(pivot)
	pivot.position = Vector3(0.0, _mesh_height(_body.mesh) * 0.7, 0.0)  # roughly chest height
	# Yaw the pivot so its local +Z points at the target; the swing (around local X) then arcs
	# in the vertical plane toward the target.
	var to_target := target_position - global_position
	to_target.y = 0.0
	if to_target.length() > 0.01:
		pivot.rotation.y = atan2(to_target.x, to_target.z)

	var stick := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = _BONK_STICK_SIZE
	stick.mesh = mesh
	stick.material_override = _solid_material(_BONK_STICK_COLOR)
	stick.position = Vector3(0.0, 0.0, _BONK_STICK_SIZE.z * 0.5)  # extend forward, toward target
	pivot.add_child(stick)

	pivot.rotation.x = deg_to_rad(_BONK_RAISED_DEG)  # wind back
	# Sequence: hold wound-back (load) → accelerate down into the hit → pause on impact (a beat)
	# → recoil. Each step is its own tween segment so the timings read distinctly.
	var swing := create_tween()
	swing.tween_interval(_BONK_LOAD_TIME)
	swing.tween_property(pivot, "rotation:x", deg_to_rad(_BONK_STRUCK_DEG), _BONK_DOWN_TIME) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)   # accelerate into the strike
	swing.tween_interval(_BONK_HOLD_TIME)
	swing.tween_property(pivot, "rotation:x", deg_to_rad(_BONK_RECOIL_DEG), _BONK_UP_TIME) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	await swing.finished
	pivot.queue_free()


## The arrow shot: loose a thin black rod that arcs from this unit's head to the target's head,
## then return when it lands. `target_position` is the target's *base* (what
## `play_attack_animation` is handed); both endpoints are lifted by a body-height so the shot goes
## head-to-head (units are uniform, so our own body height stands in for theirs). The *motion* is
## delegated to the generic `Projectile` effect — we only build the look (an archer's arrow) and
## hand it the launch/land points; a future fireball spawns a glowing sphere through the same call
## with `arc_peak = 0` for a flat shot.
func _play_arrow(target_position: Vector3) -> void:
	var lift := Vector3.UP * _mesh_height(_body.mesh)
	var start := global_position + lift
	var end := target_position + lift
	# arc_peak > 0 → it lobs; face_travel → the shaft noses along its path (built pointing down −Z).
	await Projectile.launch(get_parent(), start, end, _make_arrow_visual(),
		_ARROW_FLIGHT_TIME, _ARROW_ARC_HEIGHT, true)


## Build the arrow's visual: a thin black rod laid along its own local −Z (rotate the Y-aligned
## cylinder −90° about X) so `Projectile`'s `face_travel` look-at — which aims −Z — points the shaft
## along its flight. Returned detached; `Projectile` parents and moves it.
func _make_arrow_visual() -> MeshInstance3D:
	var rod := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius = _ARROW_RADIUS
	mesh.bottom_radius = _ARROW_RADIUS
	mesh.height = _ARROW_LENGTH
	rod.mesh = mesh
	rod.material_override = _solid_material(_ARROW_COLOR)
	rod.rotation.x = -PI / 2.0
	return rod


## The fireball cast: hurl a glowing orb in a STRAIGHT line from this unit's head to the target's
## head, then return when it lands. Same head-to-head framing as the arrow (both endpoints lifted a
## body-height), but delegated to `Projectile` with `arc_peak = 0` (no lob) and `face_travel = false`
## (a sphere has no nose to point). The orb's bloom is its own emissive material; `Projectile` only
## moves it.
func _play_fireball(target_position: Vector3) -> void:
	var lift := Vector3.UP * _mesh_height(_body.mesh)
	var start := global_position + lift
	var end := target_position + lift
	await Projectile.launch(get_parent(), start, end, _make_fireball_visual(),
		_FIREBALL_FLIGHT_TIME, 0.0, false)


## Build the fireball's visual: a glowing red-orange sphere. Emission is enabled and driven well
## past 1.0 (HDR) so it clears the WorldEnvironment's glow threshold and blooms; the albedo matches
## so the core reads solid. Returned detached; `Projectile` parents and flies it.
func _make_fireball_visual() -> MeshInstance3D:
	var orb := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = _FIREBALL_RADIUS
	mesh.height = _FIREBALL_RADIUS * 2.0   # height = diameter, or the sphere comes out squashed
	orb.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = _FIREBALL_COLOR
	mat.emission_enabled = true
	mat.emission = _FIREBALL_COLOR
	mat.emission_energy_multiplier = _FIREBALL_GLOW_ENERGY
	orb.material_override = mat
	return orb


## Play the death animation — topple sideways onto the ground, then fade to transparent — and
## return when done. Pure presentation: the caller frees the unit and clears its occupancy
## afterward. Fading needs the materials in alpha-blend mode, so we flip that first.
func play_death_animation() -> void:
	var fall := create_tween()
	fall.set_trans(Tween.TRANS_QUAD)
	fall.set_ease(Tween.EASE_OUT)
	fall.tween_property(self, "rotation_degrees:z", -90.0, _DEATH_FALL_TIME)  # tip onto its side
	await fall.finished

	# Fade both meshes out together. Tween the whole albedo color (to alpha 0) so we don't rely
	# on sub-component tween paths; flip each material to alpha blending first so it shows.
	var body_mat := _body.material_override as StandardMaterial3D
	var hat_mat := _hat.material_override as StandardMaterial3D
	body_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	hat_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var body_clear := body_mat.albedo_color
	var hat_clear := hat_mat.albedo_color
	body_clear.a = 0.0
	hat_clear.a = 0.0
	var fade := create_tween()
	fade.set_parallel(true)
	fade.tween_property(body_mat, "albedo_color", body_clear, _DEATH_FADE_TIME)
	fade.tween_property(hat_mat, "albedo_color", hat_clear, _DEATH_FADE_TIME)
	await fade.finished


# --- Appearance --------------------------------------------------------------

## Apply allegiance (body color) and class (hat shape + color) to the meshes.
## Central so both `_ready` and `configure` share exactly one code path.
func _apply_appearance() -> void:
	# Body: keep the cylinder authored in the scene; only swap in our own material.
	_body.material_override = _solid_material(allegiance_color(allegiance))

	# Hat: the class can change the *shape*, so swap the mesh, then recolor it.
	_hat.mesh = UnitClasses.new_hat_mesh(unit_class)
	_hat.material_override = _solid_material(UnitClasses.hat_color(unit_class))

	# The class also picks the default combat loadout (until equipment / spell-learning exist), so
	# set both here on the one code path that applies a class — a reclass swaps the weapon and the
	# starting spell list to the new class's defaults.
	weapon_type = default_weapon_for_class(unit_class)
	known_spells = default_spells_for_class(unit_class)

	_layout()


## The default weapon a fresh unit of `klass` carries: archers come up with a bow (RANGED),
## everyone else with a melee weapon. A `static` lookup (no unit state needed) so spawn code
## and `_apply_appearance` share one rule; equipment will later override the stored field.
static func default_weapon_for_class(klass: int) -> WeaponType:
	return WeaponType.RANGED if klass == UnitClasses.Class.ARCHER else WeaponType.MELEE


## The spells a fresh unit of `klass` starts knowing: the Mage opens with Fireball; other classes
## know none for now. Returns a fresh, typed list each call (the `Attack` profiles are rebuilt) so
## no two units share a spell resource. A spell-learning system will later add to a unit's list
## beyond this class default.
static func default_spells_for_class(klass: int) -> Array[Attack]:
	var spells: Array[Attack] = []
	if klass == UnitClasses.Class.MAGE:
		spells.append(Attack.fireball())
	return spells


## The starting gear a fresh unit of `klass` carries (until inventory/loot exists): the three
## battle archetypes from the balance pass — a Soldier with sword + shield + chainmail (the
## all-rounder), an Archer with bow + leather, a Mage with staff + cloth. Returns fresh
## `Equipment` instances each call so no two units share an item resource.
static func default_loadout_for_class(klass: int) -> Array[Equipment]:
	var kit: Array[Equipment] = []
	match klass:
		UnitClasses.Class.SOLDIER:
			kit.append(Equipment.straight_sword())
			kit.append(Equipment.shield())
			kit.append_array(Equipment.chainmail_set())
		UnitClasses.Class.ARCHER:
			kit.append(Equipment.bow())
			kit.append_array(Equipment.leather_set())
		UnitClasses.Class.MAGE:
			kit.append(Equipment.staff())
			kit.append_array(Equipment.cloth_set())
	return kit


## Clear any held gear and equip this unit's class default loadout. Called at spawn AFTER stats
## exist (equip checks requirements against `max_stats`). Items whose requirements aren't met are
## silently skipped — e.g. a rolled enemy mage that rolled below the staff's MAG floor simply
## casts unarmed (power 1.0) rather than crashing.
func _apply_default_loadout() -> void:
	hands = [null, null]
	armor_head = null
	armor_chest = null
	armor_boots = null
	for item in default_loadout_for_class(unit_class):
		equip(item)


## Seat the body's feet at local y=0 and rest the hat on top of the body. Both
## positions are derived from the actual mesh sizes, so resizing a mesh in the
## editor (or swapping the hat for a taller/blockier shape) keeps everything
## aligned with no manual repositioning.
func _layout() -> void:
	# A primitive mesh is centered on its own origin, so a body of height H must be
	# lifted by H/2 for its base to sit at y=0.
	var body_h := _mesh_height(_body.mesh)
	_body.position = Vector3(0.0, body_h * 0.5, 0.0)
	# The hat's base rests on the body's top (y = body_h); lift the hat by half its
	# own height so its base — not its center — lands there.
	_hat.position = Vector3(0.0, body_h + _mesh_height(_hat.mesh) * 0.5, 0.0)


## Build a fresh solid-color material. Each unit gets its own (see the class
## docstring) so recoloring one unit never bleeds onto another.
func _solid_material(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	return mat


## Body/allegiance color. Kept here, not in `UnitClasses`, because it is the
## *other* visual channel — allegiance, not class. Magenta = unmapped side.
static func allegiance_color(side: Allegiance) -> Color:
	match side:
		Allegiance.PLAYER:
			return Color(0.25, 0.45, 0.80)  # blue
		Allegiance.ENEMY:
			return Color(0.75, 0.25, 0.25)  # red
		_:
			return Color.MAGENTA


## Vertical extent of a primitive `mesh`, so the hat can be seated on the body
## regardless of its shape. Handles the shapes a hat/body might use (cone and
## cylinder share `CylinderMesh`; a future square hat is a `BoxMesh`). Returns 0
## for an unknown mesh rather than guessing a wrong size.
static func _mesh_height(mesh: Mesh) -> float:
	if mesh is CylinderMesh:
		return mesh.height
	if mesh is BoxMesh:
		return mesh.size.y
	return 0.0
