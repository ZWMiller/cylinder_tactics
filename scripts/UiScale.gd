## Global UI scale — an autoload, so it applies to EVERY scene (battle `Main`, `Loadout`,
## the map designer) and persists across scene changes. It sets the root window's
## `content_scale_factor`: a single multiplier on top of the project's `canvas_items`
## stretch (which already scales the UI with the window from the 1920x1080 base).
##
## Why a separate knob from the stretch: the stretch makes the UI *resolution-reactive*
## automatically; this is the *manual* zoom on top — the seam for a future user-facing
## "UI scale" setting. Everything reads from one number, so a settings menu can later call
## `UiScale.apply(factor)` and the whole UI across all scenes grows/shrinks proportionally,
## paddings and icons included (which bumping a theme's `default_font_size` alone would NOT
## do — that grows text but leaves the boxes around it the same size).
##
## GDScript/Godot note (autoload pattern): registered in `project.godot` under [autoload]
## as `UiScale="*res://scripts/UiScale.gd"`. The engine instances it as a child of the root
## BEFORE the main scene loads, and it's reachable globally by that name (like a singleton).
extends Node

## The global UI multiplier. 1.0 = the stretch-scaled baseline (no extra zoom). This single
## number is the one tuning point — bump it to make ALL UI bigger everywhere. Kept at 1.0
## for now so battle/Loadout look unchanged until the global-theme pass tunes them; the knob
## is live, so changing this (or calling `apply`) takes effect immediately in every scene.
const UI_SCALE := 1.0

## Clamp range so a stray value can't make the UI unusably tiny or huge.
const MIN_SCALE := 0.5
const MAX_SCALE := 3.0


## Apply the configured scale once at startup. Autoloads enter the tree before any scene,
## and `content_scale_factor` sticks on the root window across scene changes, so setting it
## here covers every scene for the whole run.
func _ready() -> void:
	apply(UI_SCALE)


## Set the global UI scale to `factor` (clamped to [MIN_SCALE, MAX_SCALE]). The single
## entry point a settings screen will drive later.
func apply(factor: float) -> void:
	get_window().content_scale_factor = clampf(factor, MIN_SCALE, MAX_SCALE)
