## A short-lived 3D text popup that rises off a point in the world and fades — the floating
## "-2" damage number over a struck unit. Generic on purpose (text + color), so the same effect
## can later show heals ("+3", green), misses ("miss"), status procs, etc. — combat just calls
## `spawn` with different arguments.
##
## A `Label3D` (billboarded, depth-test off) so it lives in the 3D scene and always faces the
## camera, reading the same from any orbit angle. It is parented to the *battlefield*, NOT the
## target, and frees itself when its tween finishes — so it completes its full rise/fade even if
## the target dies and is freed mid-float. Fire-and-forget: nothing awaits it.
class_name FloatingCombatText
extends Label3D

## How far (world units) the number drifts upward over its life.
const _RISE := 1.2

## Total seconds on screen (rise happens across all of it; the fade is the tail).
const _LIFETIME := 1.5

## Seconds of fade at the end of the life (it holds full opacity, then fades out over this).
const _FADE_TIME := 0.6


## Create a popup showing `text` in `color` at `world_pos`, parented to `parent`, and start its
## rise+fade. Static so callers don't manage the node — it cleans itself up. Example:
##   FloatingCombatText.spawn(battlefield, head_pos, "-2", Color(1, 0.5, 0.45))
static func spawn(parent: Node, world_pos: Vector3, text: String, color: Color) -> void:
	var popup := FloatingCombatText.new()
	popup.text = text
	popup.modulate = color
	# Big, billboarded, outlined, and drawn over everything so the number reads against the
	# colourful terrain and the unit it floats above.
	popup.font_size = 64
	popup.pixel_size = 0.01
	popup.outline_size = 16
	popup.outline_modulate = Color(0.0, 0.0, 0.0, color.a)
	popup.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	popup.no_depth_test = true
	parent.add_child(popup)
	popup.global_position = world_pos
	popup._play()


## Run the rise + fade, then free. The rise eases out (a quick pop that slows as it settles);
## the colour/outline hold full opacity and then fade over the final `_FADE_TIME` (a delayed
## tail), so the number is readable first and disappears at the end — all within `_LIFETIME`.
func _play() -> void:
	var faded := modulate
	faded.a = 0.0
	var faded_outline := outline_modulate
	faded_outline.a = 0.0

	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(self, "position:y", position.y + _RISE, _LIFETIME) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tween.tween_property(self, "modulate", faded, _FADE_TIME).set_delay(_LIFETIME - _FADE_TIME)
	tween.tween_property(self, "outline_modulate", faded_outline, _FADE_TIME).set_delay(_LIFETIME - _FADE_TIME)
	await tween.finished
	queue_free()
