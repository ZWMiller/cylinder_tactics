## A self-contained projectile *effect*: carries a caller-supplied visual from one world point to
## another — along a straight line or a parabolic arc — then frees itself. A sibling of
## `FloatingCombatText`: a presentation effect spawned into the world and decoupled from any
## `Unit`, so the SAME flight serves an arrow, a fireball, a thrown rock, etc. The *look* is
## whatever visual node you hand it (a thin cylinder, a glowing sphere, …) — Projectile only owns
## the *motion*, never the appearance, which is what keeps it reusable across attack types.
##
## Unlike `FloatingCombatText` (fire-and-forget), `launch` is **awaitable**: it returns when the
## projectile lands, so the attacker can sequence damage onto the impact
## (`await Projectile.launch(...)` → apply damage).
##
## The Projectile node is an invisible *holder* that does the moving and aiming; the visual rides
## as its child. That split is what lets it carry any shape: `face_travel` aims the holder's −Z
## (Godot's "forward") along the path, so a visual modelled pointing down its own −Z (an arrow
## shaft) noses along the curve, while a shape with no forward (a sphere) just sets `face_travel`
## false and ignores orientation.
class_name Projectile
extends Node3D


## Fly `visual` from `start` to `end` (world space), parented under `parent`, then free everything.
## Awaitable — resolves when the projectile reaches `end`.
##   visual      — the projectile's appearance (any Node3D, usually a MeshInstance3D). For
##                 `face_travel` it should be modelled pointing down its own −Z (the look-at
##                 forward axis); orientation is ignored otherwise.
##   flight_time — seconds for the whole trip.
##   arc_peak    — world units the path bows *upward* at its midpoint; 0.0 = a straight line. This
##                 is the arrow-vs-fireball knob: an arrow lobs (peak > 0), a fireball flies flat.
##   face_travel — orient the projectile's −Z along its direction of travel (arrows nose along the
##                 path); leave false for shapes with no forward (a glowing sphere).
static func launch(parent: Node, start: Vector3, end: Vector3, visual: Node3D,
		flight_time: float, arc_peak: float = 0.0, face_travel: bool = false) -> void:
	var proj := Projectile.new()
	parent.add_child(proj)
	proj.global_position = start
	proj.add_child(visual)

	# Drive the trip by tweening a 0→1 progress: each step parks the holder on the path and, when
	# asked, aims it a hair further along the SAME path so it follows the curve. Bound to a local
	# so it isn't an inline multi-line argument (which GDScript parses awkwardly mid-call).
	var step := func(t: float) -> void:
		proj.global_position = Projectile._arc_point(start, end, arc_peak, t)
		if face_travel:
			var ahead := Projectile._arc_point(start, end, arc_peak, minf(1.0, t + 0.02))
			if proj.global_position.distance_to(ahead) > 0.0001:
				proj.look_at(ahead, Vector3.UP)
	var flight := proj.create_tween()
	flight.tween_method(step, 0.0, 1.0, flight_time)
	await flight.finished
	proj.queue_free()


## A point on the straight-or-parabolic path from `from` to `to` at `t` in [0,1]: the linear
## interpolation plus a vertical bump that peaks at `peak` world units midway (zero at both ends).
## `peak == 0` collapses to a straight line. `4·t·(1−t)` is the unit parabola — 1 at t=0.5, 0 at
## the ends — so the bump rises and falls smoothly without changing the endpoints.
static func _arc_point(from: Vector3, to: Vector3, peak: float, t: float) -> Vector3:
	var p := from.lerp(to, t)
	p.y += peak * 4.0 * t * (1.0 - t)
	return p
