## The turn scheduler: decides *whose turn it is* and in what order, driven by each unit's
## `speed`. This is the first piece carved out of `Main` toward a reusable `Battle.tscn`
## (see docs/TODO.md "Architecture"): it owns the active-unit pointer and the turn queue so
## `Main` no longer does, and it *announces* the hand-off via a signal rather than calling
## listeners directly. That inversion — the announcer doesn't know its listeners — is the
## Godot idiom (node composition + signals) we're adopting as the battle architecture.
##
## Scheduling model — FFT-style Charge Time (CT):
##   Every unit carries a `ct` counter (on `Unit`). On each "tick" all units gain CT equal
##   to their `speed`; the first to reach `CT_THRESHOLD` acts. When its turn ends we subtract
##   `CT_THRESHOLD` (the overflow carries forward), then tick again for the next actor. The
##   payoff over a plain speed-sorted order is that a faster unit reaches the threshold again
##   sooner, so it acts *more often* — not merely earlier — which is what the future
##   time-mage haste/slow powers will modulate.
##
## GDScript/engine note: this is a plain `Node` (no visuals). `Main` `add_child`s one and
## connects to its signals — the same code-instantiated pattern as the HUD panels. A signal
## here is like a typed callback list: `emit` invokes every connected `Callable`.
class_name TurnManager
extends Node

## CT a unit must accumulate to take a turn. 100 is the FFT convention; with small `speed`
## values (~1-10) a unit charges up over several ticks, and the leftover above 100 carries
## into its next turn so fractional-speed differences still matter over time.
const CT_THRESHOLD := 100

## Default cadence of the map time-shift: the map "takes its turn" every Nth *character* turn.
## Deliberately counted in completed turns, NOT CT — the shift is a steady wall-clock-ish
## pressure on the battle, independent of how fast any unit charges. A map overrides this via
## `register_map_transition_speed`.
const DEFAULT_MAP_TRANSITION_SPEED := 10

## Fired when a new unit takes the turn (after the queue picks it). Listeners — the menu
## title, the status box, the active-tile marker, and the player/enemy turn branch in
## `Main` — react to this instead of `Main` hard-wiring them. `unit` is null only when the
## roster is empty (no combatants left to act).
signal active_unit_changed(unit: Unit)

## Fired when the active unit's turn ends, just before the next is chosen. Unused by `Main`
## today, but part of the announced vocabulary the future HUD/effects will hang off (e.g.
## end-of-turn status ticks), so it exists from the start.
signal turn_ended(unit: Unit)

## Fired when the map "takes its turn" — every `_map_transition_speed` character turns. A
## listener (Main) runs the actual map time-shift; the scheduler only counts turns and
## announces, staying ignorant of the battlefield (node-composition + signals). Because the
## transition is a cinematic that must play uninterrupted, `end_turn` does NOT pick the next
## actor when this fires — it waits for the listener to call `continue_after_transition`.
signal map_transition_due()

## Fired at the end of each turn with the number of turns now remaining until the next map
## shift (0 on the shift turn itself). Drives the `ShiftCounter` HUD.
signal map_transition_countdown(turns_remaining: int)

## Every combatant in the encounter, both sides, in registration order. That order is also
## the final tie-break when two units are equally ready, so it stays stable and deterministic.
var _units: Array[Unit] = []

## Whose turn it currently is (the single source of truth; `Main` mirrors it for the input
## code's convenience but never writes it).
var _active_unit: Unit = null

## Character turns between map time-shifts (see `register_map_transition_speed`). <= 0 disables
## automatic shifts entirely.
var _map_transition_speed: int = DEFAULT_MAP_TRANSITION_SPEED

## Completed character turns since the last map shift. Counts up in `end_turn`; when it
## reaches `_map_transition_speed` it resets and `map_transition_due` fires.
var _turns_since_transition: int = 0


## Add a unit to the schedule with a cleared charge. Called once per spawn by `Main`; both
## sides register, unlike the old players-only cycle, so enemies now take real turns too.
func register(unit: Unit) -> void:
	_units.append(unit)
	unit.ct = 0


## Remove a unit from the schedule (e.g. on death — not wired yet, but the queue must not
## keep handing turns to a corpse). Harmless if the unit was never registered.
func unregister(unit: Unit) -> void:
	_units.erase(unit)


## The unit whose turn it is, or null if none. The read-only accessor `Main` uses.
func active() -> Unit:
	return _active_unit


## Configure how many character turns pass before the map takes its turn (a time-shift). Each
## map sets its own pace by calling this during setup; left alone it uses
## `DEFAULT_MAP_TRANSITION_SPEED` (10). A value <= 0 disables automatic shifts. Resets the
## running count so a freshly-set cadence starts from zero.
func register_map_transition_speed(turns: int) -> void:
	_map_transition_speed = turns
	_turns_since_transition = 0


## How many character turns remain until the next map shift, or -1 if shifts are disabled
## (cadence <= 0). Main reads this to seed the HUD and to reset it after a shift.
func turns_until_transition() -> int:
	if _map_transition_speed <= 0:
		return -1
	return _map_transition_speed - _turns_since_transition


## Resume the turn loop after the map's cinematic transition has finished. `end_turn` stops
## before choosing the next actor when a shift is due (so the transition plays without a unit
## acting underneath it); the transition handler calls this to hand control back.
func continue_after_transition() -> void:
	_advance_to_next_actor()


## Start the battle's turn loop: charge up to the first actor and announce it. Call once
## after every unit is registered.
func begin() -> void:
	_advance_to_next_actor()


## End the active unit's turn: bank its overflow charge (subtract the threshold so excess
## carries over), announce the end, then charge up to and announce the next actor. This is
## what "End Turn" calls for a player, and what the AI calls once an enemy finishes moving.
func end_turn() -> void:
	if _active_unit != null:
		_active_unit.ct -= CT_THRESHOLD
		turn_ended.emit(_active_unit)
		if _consume_turn_for_map_shift():
			# The map takes its turn now. Don't pick the next actor — the transition cinematic
			# plays first and calls `continue_after_transition` when it's done.
			map_transition_due.emit()
			return
	_advance_to_next_actor()


## Tick the map-shift counter for one completed character turn and report whether the map
## should now shift. Emits the running countdown for the HUD; when the count reaches the
## registered cadence it resets and returns true (the shift turn — countdown shows 0). A
## cadence <= 0 means shifts are disabled, so nothing counts. Called between the ending turn
## and choosing the next actor, so a shift lands "between" characters in the order.
func _consume_turn_for_map_shift() -> bool:
	if _map_transition_speed <= 0:
		return false
	_turns_since_transition += 1
	map_transition_countdown.emit(_map_transition_speed - _turns_since_transition)
	if _turns_since_transition >= _map_transition_speed:
		_turns_since_transition = 0
		return true
	return false


## Tick CT forward until a unit is ready, make it active, and announce the change. With no
## units we announce null (nobody's turn). The `maxi(1, speed)` floor guarantees forward
## progress even if a unit somehow has 0/negative speed, so this loop can never spin forever.
func _advance_to_next_actor() -> void:
	if _units.is_empty():
		_set_active(null)
		return
	var next := _ready_unit()
	while next == null:
		for u in _units:
			u.ct += maxi(1, u.max_stats.speed)
		next = _ready_unit()
	_set_active(next)


## The unit that should act now, or null if none has reached the threshold yet. Among ready
## units we pick the highest CT, breaking ties by higher `speed` then earlier registration
## (the linear scan keeps the earlier unit unless a *strictly* better one appears, so the
## tie-break is deterministic without needing a stable sort).
func _ready_unit() -> Unit:
	var best: Unit = null
	for u in _units:
		if u.ct < CT_THRESHOLD:
			continue
		if best == null \
				or u.ct > best.ct \
				or (u.ct == best.ct and u.max_stats.speed > best.max_stats.speed):
			best = u
	return best


## Set the active unit and fire the hand-off signal in one place, so every path that changes
## whose turn it is announces it the same way.
func _set_active(unit: Unit) -> void:
	_active_unit = unit
	active_unit_changed.emit(unit)
