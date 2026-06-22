## Orbiting orthographic camera rig for reviewing the battlefield in "gameplay"
## mode. The camera always looks at the world origin (where the grid is centered)
## and is positioned on a sphere around it, described by yaw / pitch / distance.
## Zoom changes the orthographic `size` rather than the distance, since distance
## doesn't affect framing under an orthographic projection.
##
## The transform is computed in code with `look_at` every time something changes,
## rather than being hand-authored in the scene — a hand-written Transform3D basis
## is what caused the original black-screen bug (see CLAUDE.md / DECISION_LOG).
##
## Controls:
##   - Mouse wheel        : zoom in / out
##   - Q / E              : orbit left / right
##   - Middle-mouse drag  : free orbit (yaw + pitch)
##
## The look-at `target` can be slewed to follow the active unit via `focus_on` (see Main):
## only the target moves, so the isometric angle and zoom are preserved — the view just
## glides to re-center on whoever's turn it is.
class_name CameraController
extends Camera3D

# --- Tunables (editable in the Inspector) ------------------------------------

## The point the camera orbits and looks at. The grid is centered on the origin.
@export var target: Vector3 = Vector3.ZERO

## How far the camera sits from the target. Affects only clipping, not framing
## (orthographic), but should stay large enough to keep the camera outside the
## terrain.
@export var distance: float = 45.0

## Horizontal orbit angle, in degrees. 45° gives the classic isometric view.
@export var yaw: float = 45.0

## Vertical orbit angle, in degrees. ~35° matches a true isometric tilt.
@export var pitch: float = 35.0

## Orthographic view size (smaller = more zoomed in). This is the `size` the
## rig drives; the exported camera `size` is just the editor preview.
@export var ortho_size: float = 34.0

## Degrees per second of orbit when holding Q / E.
@export var key_orbit_speed: float = 90.0

## Degrees of orbit per pixel of middle-mouse drag.
@export var mouse_orbit_speed: float = 0.3

## Orthographic size change per mouse-wheel notch.
@export var zoom_step: float = 3.0

## How quickly the camera slews toward a new `focus_on` target. Used as the per-second rate
## of an exponential ease (higher = snappier); the actual lerp factor is `follow_speed *
## delta`, clamped to 1, so it's frame-rate independent. Because Main feeds the active unit's
## *live* position, this also sets how far the camera trails a walking unit: the steady-state
## lag is roughly `Unit.MOVE_SPEED / follow_speed` world units, so ~1.5 tiles here — a gentle
## "panning to keep up" feel. Lower it for more lag, raise it to hug the unit more tightly.
@export var follow_speed: float = 4.0

## Clamps so you can't zoom through the world or flip the camera over the poles.
@export var min_ortho_size: float = 6.0
@export var max_ortho_size: float = 90.0
@export var min_pitch: float = 10.0
@export var max_pitch: float = 85.0

# --- Runtime state -----------------------------------------------------------

## True while the middle mouse button is held (free-orbit drag in progress).
var _orbiting: bool = false

## Where the camera is gliding toward — the look-at point `_process` eases `target` into.
## Starts at the authored `target` (no motion until `focus_on` is called).
var _desired_target: Vector3 = Vector3.ZERO


## Force orthographic projection and place the camera for the first time.
func _ready() -> void:
	projection = PROJECTION_ORTHOGONAL
	_desired_target = target
	_update_transform()


## Slew the view to center on `point`, keeping the current angle and zoom (only the look-at
## target moves). Main calls this with the active unit's tile each frame; the actual glide
## happens in `_process`, so repeated calls with the same point are free.
func focus_on(point: Vector3) -> void:
	_desired_target = point


## Handle discrete events: wheel zoom, and starting/ending a middle-mouse orbit
## drag plus the drag motion itself.
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		match event.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				_zoom(-zoom_step)
			MOUSE_BUTTON_WHEEL_DOWN:
				_zoom(zoom_step)
			MOUSE_BUTTON_MIDDLE:
				_orbiting = event.pressed
	elif event is InputEventMouseMotion and _orbiting:
		# Drag right/left orbits horizontally; drag up/down changes the tilt.
		yaw -= event.relative.x * mouse_orbit_speed
		pitch += event.relative.y * mouse_orbit_speed
		_update_transform()


## Per-frame updates: held-key orbiting (Q / E) and easing `target` toward the focus set by
## `focus_on`. Both only refresh the transform when something actually changed, so an idle
## camera does no work.
func _process(delta: float) -> void:
	var changed: bool = false

	var turn: float = 0.0
	if Input.is_physical_key_pressed(KEY_Q):
		turn += key_orbit_speed * delta
	if Input.is_physical_key_pressed(KEY_E):
		turn -= key_orbit_speed * delta
	if turn != 0.0:
		yaw += turn
		changed = true

	# Glide toward the active-unit focus. `lerp` with a clamped `follow_speed * delta` factor
	# is an exponential ease (fast then settling); snap the last sliver so it fully arrives
	# and stops refreshing rather than creeping forever.
	if not target.is_equal_approx(_desired_target):
		target = target.lerp(_desired_target, clampf(follow_speed * delta, 0.0, 1.0))
		if target.distance_to(_desired_target) < 0.001:
			target = _desired_target
		changed = true

	if changed:
		_update_transform()


## Apply a zoom delta to the orthographic size, clamped, then refresh.
func _zoom(amount: float) -> void:
	ortho_size = clampf(ortho_size + amount, min_ortho_size, max_ortho_size)
	_update_transform()


## Recompute the camera's position on the orbit sphere and aim it at the target.
## Yaw/pitch are converted to a direction vector; the camera is placed `distance`
## along it and then `look_at` points its -Z axis back at the target.
func _update_transform() -> void:
	pitch = clampf(pitch, min_pitch, max_pitch)
	var p := deg_to_rad(pitch)
	var y := deg_to_rad(yaw)
	var dir := Vector3(cos(p) * sin(y), sin(p), cos(p) * cos(y))
	position = target + dir * distance
	look_at(target, Vector3.UP)
	size = ortho_size
