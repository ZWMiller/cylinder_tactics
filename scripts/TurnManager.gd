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

## Fired when a new unit takes the turn (after the queue picks it). Listeners — the menu
## title, the status box, the active-tile marker, and the player/enemy turn branch in
## `Main` — react to this instead of `Main` hard-wiring them. `unit` is null only when the
## roster is empty (no combatants left to act).
signal active_unit_changed(unit: Unit)

## Fired when the active unit's turn ends, just before the next is chosen. Unused by `Main`
## today, but part of the announced vocabulary the future HUD/effects will hang off (e.g.
## end-of-turn status ticks), so it exists from the start.
signal turn_ended(unit: Unit)

## Every combatant in the encounter, both sides, in registration order. That order is also
## the final tie-break when two units are equally ready, so it stays stable and deterministic.
var _units: Array[Unit] = []

## Whose turn it currently is (the single source of truth; `Main` mirrors it for the input
## code's convenience but never writes it).
var _active_unit: Unit = null


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
	_advance_to_next_actor()


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
