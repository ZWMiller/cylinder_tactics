## Shared base for the in-game AUTHORING TOOLS (the Map Builder and the Encounter Builder) — the
## common 3D "editor scene" scaffolding both need, in ONE place: a display battlefield, the orbit
## camera + centering, a shared dialog Theme, the HUD panel skeleton, a file-dialog factory, and the
## dialog-open input guard. Both tools' SCENES also inherit `scenes/AuthoringScene.tscn` (the shared
## WorldEnvironment + light + camera nodes), so backgrounds / camera / lighting live in one place
## too — change them once and both tools follow.
##
## Pattern (GDScript's take on an abstract base with virtual hooks — like a C++ base with `virtual`
## methods, or a Python ABC with overridable methods): this base owns the fixed *sequence* of
## startup steps in `_ready` (the classic "template method") and calls small overridable HOOKS at the
## points that differ between tools — `_initial_states()`, `_setup_camera()`, `_build_ui()`, and the
## per-frame `_authoring_process()`. GDScript methods are all virtual, so a subclass fills in its
## part just by defining the same-named function; it does NOT override `_ready`/`_process` itself.
class_name AuthoringScene
extends Node3D

const FONT_HUD := 26      ## top-left status / help readout
const FONT_DIALOG := 24   ## all text inside dialogs (applied via the shared theme)
const HUD_PANEL_WIDTH := 560

## The display battlefield — an `EditableBattlefield` for its readable grid outline. Created in code
## in `_ready` (seeded by the `_initial_states` hook) so we never build the throwaway DemoMap first.
var _field: EditableBattlefield

## The orbit camera — a node in the (inherited) scene. Used for framing and tile ray-picking.
@onready var _camera: CameraController = $Camera3D

## One shared Theme applied to every dialog Window (sizes their file lists / buttons legibly — the
## thing we otherwise can't reach to override per-control inside a FileDialog).
var _ui_theme: Theme

## HUD: a CanvasLayer holding a dark panel + the main status `Label`. Subclasses add their own extra
## HUD (a swatch bar, etc.) onto `_hud_layer` and drive `_label`'s text via their own refresh.
var _hud_layer: CanvasLayer
var _label: Label

## Every dialog built through `_make_dialog` / passed to `register_dialog`, so `_dialog_open()` can
## tell when a picker owns input (suspending hover + the camera's key-orbit).
var _dialogs: Array[Window] = []


## Template startup: build the field (seeded by the subclass), frame it, set up the theme + HUD, then
## let the subclass build its own UI. Subclasses fill the HOOKS below, not this method.
func _ready() -> void:
	_field = EditableBattlefield.new()
	_field.name = "Battlefield"
	_field.states = _initial_states()   # HOOK: subclass supplies the starting grid
	add_child(_field)                    # base _ready builds + renders the seeded grid
	_recenter_camera()
	_setup_camera()                      # HOOK: subclass camera tweaks (e.g. orbit under the map)

	_ui_theme = Theme.new()
	_ui_theme.default_font_size = FONT_DIALOG

	_build_hud()
	_build_ui()                          # HOOK: subclass swatch bar / palette / dialogs / labels


## Per-frame: suspend the camera's key-orbit while a dialog owns input, then hand off to the
## subclass's per-frame work (hover cursors, drag, placement previews).
func _process(_delta: float) -> void:
	var dialog_open := _dialog_open()
	_camera.key_orbit_enabled = not dialog_open
	_authoring_process(dialog_open)


# --- Overridable hooks (safe defaults so the base is runnable on its own) -----

## HOOK: the starting map the field displays. Default is a small blank grid; subclasses return their
## own (a New map for the Map Builder, a placeholder for the Encounter Builder).
func _initial_states() -> Array:
	return _flat_states(8, 8, 1, TileTypes.Type.GRASS)

## HOOK: subclass camera setup after the initial framing (default: none).
func _setup_camera() -> void:
	pass

## HOOK: build the subclass's own UI — extra HUD, swatch bar, dialogs — after the base HUD exists.
func _build_ui() -> void:
	pass

## HOOK: subclass per-frame work; `dialog_open` is true while a picker owns input (default: none).
func _authoring_process(_dialog_open: bool) -> void:
	pass


# --- Shared helpers ----------------------------------------------------------

## Reframe the camera on the field, centered (instant, non-glide). Call after any STRUCTURAL change
## (initial build, New, Load, Undo, Resize) so the map never floats out of the camera's y=0 look-at.
func _recenter_camera() -> void:
	_camera.snap_to(_field.grid_center_world())


## True while any registered dialog is open — suspends hover + the camera's Q/E key-orbit (whose
## raw-keyboard polling would otherwise spin the view as you type into a name / filename field).
func _dialog_open() -> bool:
	for d in _dialogs:
		if is_instance_valid(d) and d.visible:
			return true
	return false


## Build the top-left HUD: a CanvasLayer → dark rounded panel → the main status `Label`, word-wrapped
## to HUD_PANEL_WIDTH so help text grows DOWN the left edge instead of stretching across the top.
## Subclasses set `_label.text` from their own refresh.
func _build_hud() -> void:
	_hud_layer = CanvasLayer.new()
	add_child(_hud_layer)
	var panel := PanelContainer.new()
	panel.position = Vector2(12, 12)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.0, 0.0, 0.0, 0.6)
	sb.set_corner_radius_all(4)
	sb.set_content_margin_all(10)
	panel.add_theme_stylebox_override("panel", sb)
	_hud_layer.add_child(panel)
	_label = Label.new()
	_label.add_theme_color_override("font_color", Color.WHITE)
	_label.add_theme_font_size_override("font_size", FONT_HUD)
	_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_label.custom_minimum_size = Vector2(HUD_PANEL_WIDTH, 0)
	panel.add_child(_label)


## Create a themed `.tres` FileDialog in `mode`, opening in `dir`, filtered to `*.tres` (labeled
## `desc`), registered for `_dialog_open` and added as a child. Returns it so the caller can connect
## its `file_selected` and pop it up.
func _make_dialog(mode: FileDialog.FileMode, dir: String, desc: String) -> FileDialog:
	var d := FileDialog.new()
	d.file_mode = mode
	d.access = FileDialog.ACCESS_RESOURCES
	d.current_dir = dir
	d.add_filter("*.tres", desc)
	d.theme = _ui_theme
	d.min_size = Vector2i(900, 620)
	_dialogs.append(d)
	add_child(d)
	return d


## Register an already-built dialog (e.g. an AcceptDialog created inline) so `_dialog_open` accounts
## for it. Returns it for chaining. Use for dialogs not created through `_make_dialog`.
func register_dialog(d: Window) -> Window:
	_dialogs.append(d)
	return d


## A single-state grid of `w` x `h` flat tiles at top height `top` of `surface_type` (dirt sides), in
## the nested `state[x][z]` form the field renders — the shared "blank canvas" both tools seed from.
## Includes the Sculpted `floor`/`anchor` fields (ignored on Auto maps): floor one level down, anchor
## at the top, so the seam starts at the surface.
func _flat_states(w: int, h: int, top: int, surface_type: int) -> Array:
	var grid: Array = []
	for x in w:
		var column: Array = []
		for z in h:
			column.append({
				"height": top, "type": surface_type,
				"body": TileTypes.Type.DIRT, "bottom": TileTypes.Type.DIRT,
				"floor": top - 1, "anchor": top,
			})
		grid.append(column)
	return [grid]
