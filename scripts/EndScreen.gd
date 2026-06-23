## The end-of-battle overlay: a single huge centered word over the whole screen. On a **win**, "YOU
## WIN" fades in and then slowly cycles through the rainbow forever; on a **loss**, the screen first
## fades to black, then a deep-red "YOU LOSE" fades in and holds. A full-screen `CanvasLayer` view
## like the other HUD boxes — `Main` decides when to show it; this only renders/animates.
##
## How the color is driven: the label's `font_color` is left white and we animate the CanvasItem
## `modulate` instead. `modulate` multiplies the drawn pixels, so setting it to a color tints the
## white text to exactly that color, and tweening `modulate` gives BOTH the fade (its alpha) and the
## smooth color cycle (its RGB) from one tweenable property. A black font outline survives the tint
## (black × anything = black), so the giant text stays readable over the colorful map.
class_name EndScreen
extends CanvasLayer

## Giant headline text + a proportional black outline for readability over the busy battlefield.
const _FONT_SIZE := 200
const _OUTLINE := 16

## The win text's rainbow, walked in order and looped. Tweening `modulate` between adjacent entries
## fades smoothly (not a hard jump) through red→yellow→green→cyan→blue→magenta→(back to red).
const _WIN_COLORS := [
	Color(1, 0, 0), Color(1, 1, 0), Color(0, 1, 0),
	Color(0, 1, 1), Color(0, 0, 1), Color(1, 0, 1),
]

## The single deep red for the loss text (no cycle).
const _LOSE_COLOR := Color(0.5, 0.0, 0.0)

## Seconds for the headline to fade in, the black screen to fade in (loss), and EACH step of the
## color cycle (adjacent color → adjacent color).
const _FADE_IN := 2.0
const _CYCLE_STEP := 1.4

## Full-screen, click-through root.
var _root: Control

## The black curtain that fades in behind the loss text (unused on a win).
var _black: ColorRect

## The headline label ("YOU WIN" / "YOU LOSE").
var _label: Label


## Godot lifecycle hook: build the overlay once, hidden until `show_win`/`show_lose`. The black
## curtain is added before the label so the label draws on top of it (later child = in front).
func _ready() -> void:
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	_black = ColorRect.new()
	_black.set_anchors_preset(Control.PRESET_FULL_RECT)
	_black.color = Color(0, 0, 0, 1)
	_black.modulate.a = 0.0      # faded in on a loss
	_black.visible = false
	_black.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_black)

	_label = Label.new()
	_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_label.add_theme_font_size_override("font_size", _FONT_SIZE)
	_label.add_theme_color_override("font_color", Color.WHITE)  # tinted via modulate
	_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_label.add_theme_constant_override("outline_size", _OUTLINE)
	_label.visible = false
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_label)


## Victory: fade "YOU WIN" in (at the first rainbow color), then start the endless color cycle.
func show_win() -> void:
	_label.text = "YOU WIN"
	_label.visible = true
	_label.modulate = _with_alpha(_WIN_COLORS[0], 0.0)
	var fade := create_tween()
	fade.tween_property(_label, "modulate", _with_alpha(_WIN_COLORS[0], 1.0), _FADE_IN)
	fade.tween_callback(_start_color_cycle)


## Defeat: fade the screen to black, then fade the deep-red "YOU LOSE" in over it and hold.
func show_lose() -> void:
	_black.visible = true
	var t := create_tween()
	t.tween_property(_black, "modulate:a", 1.0, _FADE_IN)
	t.tween_callback(_show_lose_text)


## Build the looping rainbow tween: from the current color, fade through each next color in turn and
## back around. `set_loops()` (no count) repeats it forever; each step keeps full alpha so only the
## hue changes, not the opacity.
func _start_color_cycle() -> void:
	var cycle := create_tween().set_loops()
	for i in _WIN_COLORS.size():
		var next: Color = _WIN_COLORS[(i + 1) % _WIN_COLORS.size()]
		cycle.tween_property(_label, "modulate", _with_alpha(next, 1.0), _CYCLE_STEP)


## Reveal the loss headline (called once the black curtain is up): deep red, faded in, then held.
func _show_lose_text() -> void:
	_label.text = "YOU LOSE"
	_label.visible = true
	_label.modulate = _with_alpha(_LOSE_COLOR, 0.0)
	var t := create_tween()
	t.tween_property(_label, "modulate", _with_alpha(_LOSE_COLOR, 1.0), _FADE_IN)


## A copy of `c` with its alpha set to `a` — used to build the modulate targets (the tween needs a
## full Color, and we vary alpha for the fades while keeping the RGB hue).
func _with_alpha(c: Color, a: float) -> Color:
	return Color(c.r, c.g, c.b, a)
