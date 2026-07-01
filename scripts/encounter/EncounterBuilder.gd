## The ENCOUNTER BUILDER — the second single-purpose authoring tool (run with F6), sibling to the
## Map Builder. Where the Map Builder edits *terrain* (`MapData`), this edits a *fight*: which map(s)
## the battle plays through (a `MapSequence`), which enemies stand where (`EnemyPlacement`s), and the
## named deploy / win tile regions. It saves an `Encounter` to `assets/encounters/`. See
## docs/ENCOUNTER_LAYERING.md for how those pieces nest.
##
## It NEVER edits terrain — it only *references* maps built in the Map Builder and displays them
## read-only (WYSIWYG, via the same `Battlefield` renderer battles use). So there's no ambiguity
## about "what does Save write": this tool always saves the encounter (+ its sequence).
##
## The common editor scaffolding (display field, camera, theme, HUD panel, dialog factory, input
## guard) lives in `AuthoringScene`, which this extends; here we only add the encounter-specific
## pieces: the three placement tools (ENEMY / DEPLOY / WIN), their on-map overlays, and the enemy
## inspector. Still to come (later steps): the MAPS sequence panel, per-stat overrides / bosses.
extends AuthoringScene

## Folders each document type lives in (mirrors the layering: maps → sequences → encounters).
const MAPS_DIR := "res://assets/maps"
const SEQUENCES_DIR := "res://assets/sequences"
const ENCOUNTERS_DIR := "res://assets/encounters"

## Placeholder grid shown until a real map is loaded — small + flat so it reads as "nothing yet".
const PLACEHOLDER_SIZE := 8
const PLACEHOLDER_HEIGHT := 1

## What a left-click places/paints. ENEMY drops/selects an enemy unit; DEPLOY and WIN toggle a tile
## in the player-start and reach-to-win regions. Switched with the 1 / 2 / 3 keys.
enum Tool { ENEMY, DEPLOY, WIN }

## The classes a newly-placed enemy can be, cycled with C (each enemy's class is then editable in the
## inspector). Order is cosmetic — matches the class enum.
const PLACE_CLASSES: Array[int] = [UnitClasses.Class.SOLDIER, UnitClasses.Class.ARCHER, UnitClasses.Class.MAGE]

## Overlay colors: the per-tool hover pad, the enemy token (+ its selected highlight), and the two
## region decals. Kept together so the palette reads at a glance (and matches the ally/enemy feel).
const HOVER_COLORS := {
	Tool.ENEMY: Color(1.0, 0.4, 0.35, 0.5),
	Tool.DEPLOY: Color(0.35, 0.6, 1.0, 0.5),
	Tool.WIN: Color(1.0, 0.85, 0.2, 0.5),
}
const ENEMY_COLOR := Color(0.85, 0.2, 0.2)
const ENEMY_SELECTED_COLOR := Color(1.0, 0.75, 0.2)
const DEPLOY_DECAL_COLOR := Color(0.35, 0.6, 1.0, 0.45)
const WIN_DECAL_COLOR := Color(1.0, 0.85, 0.2, 0.5)

## The encounter being authored. Starts empty (an empty `MapSequence`, no enemies, no regions);
## "add a map" grows the sequence, and Open replaces it with a loaded one.
var _encounter: Encounter

## `res://` path of the map currently shown on the field (for the HUD + recenter), or "" if none.
var _shown_map_path: String = ""

## The active placement tool, the class the next placed enemy takes, and the enemy currently
## selected (its inspector open / token highlighted), or null.
var _tool: int = Tool.ENEMY
var _place_class: int = UnitClasses.Class.SOLDIER
var _selected_enemy: EnemyPlacement = null

## Root for all the on-map overlays (enemy tokens + region decals), rebuilt wholesale by
## `_redraw_overlays`. A plain Node3D under this scene (world = field space, both at origin).
var _overlay_root: Node3D

## Shared overlay resources, built once in `_build_ui` and reused per marker.
var _token_mesh: CylinderMesh
var _decal_mesh: PlaneMesh
var _enemy_mat: StandardMaterial3D
var _enemy_selected_mat: StandardMaterial3D
var _deploy_mat: StandardMaterial3D
var _win_mat: StandardMaterial3D

## The encounter-specific file pickers + the enemy inspector (all registered for the dialog guard).
var _map_open_dialog: FileDialog
var _enc_open_dialog: FileDialog
var _enc_save_dialog: FileDialog
var _inspector: AcceptDialog
var _class_option: OptionButton
var _level_spin: SpinBox


# --- AuthoringScene hooks -----------------------------------------------------

## HOOK: seed the display field with the placeholder grid (replaced wholesale once a map loads).
func _initial_states() -> Array:
	return _flat_states(PLACEHOLDER_SIZE, PLACEHOLDER_SIZE, PLACEHOLDER_HEIGHT, TileTypes.Type.GRASS)


## HOOK: create the blank encounter, the overlay resources + root, the file pickers, the inspector,
## then draw the HUD. (The base has already built the field, camera, theme, and HUD panel by now.)
func _build_ui() -> void:
	_encounter = Encounter.new()
	_encounter.map_sequence = MapSequence.new()

	_build_overlay_resources()
	_overlay_root = Node3D.new()
	_overlay_root.name = "Overlays"
	add_child(_overlay_root)

	_map_open_dialog = _make_dialog(FileDialog.FILE_MODE_OPEN_FILE, MAPS_DIR, "Map resource")
	_map_open_dialog.file_selected.connect(_on_map_chosen)
	_enc_open_dialog = _make_dialog(FileDialog.FILE_MODE_OPEN_FILE, ENCOUNTERS_DIR, "Encounter resource")
	_enc_open_dialog.file_selected.connect(_on_encounter_open_chosen)
	_enc_save_dialog = _make_dialog(FileDialog.FILE_MODE_SAVE_FILE, ENCOUNTERS_DIR, "Encounter resource")
	_enc_save_dialog.file_selected.connect(_on_encounter_save_chosen)

	_build_inspector()
	_refresh_label()


## HOOK: per-frame hover — highlight the tile under the cursor in the active tool's color (unless a
## dialog owns input). Uses the base field's active-tile pad, recolored per tool.
func _authoring_process(dialog_open: bool) -> void:
	if dialog_open:
		_field.clear_active_tile()
		return
	var tile := _pick_tile(get_viewport().get_mouse_position())
	if tile == Battlefield.INVALID_TILE:
		_field.clear_active_tile()
	else:
		_field.set_active_tile(tile, HOVER_COLORS[_tool])


# --- Input --------------------------------------------------------------------

## Keyboard: 1/2/3 pick the tool, C cycles the enemy class to place, M/O/S manage files.
func _unhandled_input(event: InputEvent) -> void:
	if _dialog_open():
		return
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_1: _set_tool(Tool.ENEMY)
			KEY_2: _set_tool(Tool.DEPLOY)
			KEY_3: _set_tool(Tool.WIN)
			KEY_C: _cycle_place_class()
			KEY_M:
				_map_open_dialog.popup_centered(Vector2i(1000, 680))
			KEY_O:
				_enc_open_dialog.popup_centered(Vector2i(1000, 680))
			KEY_S:
				_enc_save_dialog.current_file = "%s.tres" % _encounter_basename()
				_enc_save_dialog.popup_centered(Vector2i(1000, 680))
	elif event is InputEventMouseButton and event.pressed:
		var tile := _pick_tile(event.position)
		if tile == Battlefield.INVALID_TILE:
			return
		if event.button_index == MOUSE_BUTTON_LEFT:
			_apply_primary(tile)
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			_apply_secondary(tile)


## Pick the tile under a screen point. TOP-only today — this is the SINGLE place to make placement
## face-aware later: swap to `_field.tile_and_face_at_screen_point` and thread the returned face
## through `_apply_primary` into the placement's `face`. Returns `Battlefield.INVALID_TILE` on a miss.
func _pick_tile(pos: Vector2) -> Vector2i:
	return _field.tile_at_screen_point(_camera, pos)


## Left-click on a tile: place/select an enemy, or add the tile to the active region.
func _apply_primary(tile: Vector2i) -> void:
	match _tool:
		Tool.ENEMY: _place_or_select_enemy(tile)
		Tool.DEPLOY: _set_region_tile(Encounter.REGION_DEPLOY, tile, true)
		Tool.WIN: _set_region_tile(Encounter.REGION_WIN, tile, true)


## Right-click on a tile: delete the enemy there, or remove the tile from the active region.
func _apply_secondary(tile: Vector2i) -> void:
	match _tool:
		Tool.ENEMY: _remove_enemy_at(tile)
		Tool.DEPLOY: _set_region_tile(Encounter.REGION_DEPLOY, tile, false)
		Tool.WIN: _set_region_tile(Encounter.REGION_WIN, tile, false)


# --- Tool / class selection ---------------------------------------------------

## Switch the active placement tool and refresh the HUD (the hover color follows next frame).
func _set_tool(tool: int) -> void:
	_tool = tool
	_refresh_label()


## Cycle the class a newly-placed enemy takes (existing enemies are edited in the inspector).
func _cycle_place_class() -> void:
	var i := PLACE_CLASSES.find(_place_class)
	_place_class = PLACE_CLASSES[(i + 1) % PLACE_CLASSES.size()]
	_refresh_label()


# --- Enemies ------------------------------------------------------------------

## Left-click with the ENEMY tool: if an enemy already stands on `tile`, select it AND open the
## inspector to edit it; otherwise just drop a new one of the current place-class (level 1) and
## select it (no inspector — so you can place a row quickly; click one again to edit it).
func _place_or_select_enemy(tile: Vector2i) -> void:
	var existing := _enemy_at(tile)
	if existing != null:
		_select_enemy(existing)
		return
	var e := EnemyPlacement.new()
	e.tile = tile
	e.face = TileFaces.Face.TOP   # TOP today; becomes the picked face when face-aware placement lands (see _pick_tile)
	e.klass = _place_class
	e.level = 1
	_encounter.enemies.append(e)
	_selected_enemy = e
	_redraw_overlays()
	_refresh_label()


## Remove the enemy on `tile`, if any (right-click). Clears the selection if it was the one removed.
func _remove_enemy_at(tile: Vector2i) -> void:
	var e := _enemy_at(tile)
	if e == null:
		return
	_encounter.enemies.erase(e)
	if _selected_enemy == e:
		_selected_enemy = null
	_redraw_overlays()
	_refresh_label()


## The enemy placement standing on `tile`, or null. Linear scan — encounters have few enemies.
func _enemy_at(tile: Vector2i) -> EnemyPlacement:
	for e in _encounter.enemies:
		if e.tile == tile:
			return e
	return null


## Mark `e` as selected (highlight its token) and open the inspector to edit its class + level.
func _select_enemy(e: EnemyPlacement) -> void:
	_selected_enemy = e
	_redraw_overlays()
	_open_inspector(e)


# --- Regions ------------------------------------------------------------------

## Add (`present` = true) or remove `tile` from the named region, then redraw. Idempotent — adding a
## tile already in the region, or removing an absent one, is a no-op.
func _set_region_tile(name: String, tile: Vector2i, present: bool) -> void:
	var tiles := _encounter.region(name)
	var has := tiles.has(tile)
	if present and not has:
		tiles.append(tile)
	elif not present and has:
		tiles.erase(tile)
	else:
		return
	_encounter.set_region(name, tiles)
	_redraw_overlays()
	_refresh_label()


# --- Overlays -----------------------------------------------------------------

## Build the shared meshes + materials used by every token / decal (once, in `_build_ui`).
func _build_overlay_resources() -> void:
	var ts: float = _field.tile_size
	_token_mesh = CylinderMesh.new()
	_token_mesh.top_radius = ts * 0.26
	_token_mesh.bottom_radius = ts * 0.26
	_token_mesh.height = ts * 1.1
	_decal_mesh = PlaneMesh.new()
	_decal_mesh.size = Vector2(ts * 0.92, ts * 0.92)   # a near-tile-sized flat pad, like the path markers
	_enemy_mat = _flat_material(ENEMY_COLOR, false)
	_enemy_selected_mat = _flat_material(ENEMY_SELECTED_COLOR, false)
	_deploy_mat = _flat_material(DEPLOY_DECAL_COLOR, true)
	_win_mat = _flat_material(WIN_DECAL_COLOR, true)


## An unshaded material of `color`; `transparent` toggles alpha blending (for the flat region decals
## vs the opaque enemy cylinders). Unshaded so overlays read the same under any lighting.
func _flat_material(color: Color, transparent: bool) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	if transparent:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return m


## Rebuild all on-map overlays from the current encounter: a colored decal per deploy/win tile and a
## cylinder token (labeled with class + level) per enemy, the selected one highlighted. Cheap wholesale
## rebuild (encounters are small); called after any placement edit and after the shown map changes
## (tile heights move, so markers must be repositioned).
func _redraw_overlays() -> void:
	for child in _overlay_root.get_children():
		child.queue_free()
	for tile in _encounter.region(Encounter.REGION_DEPLOY):
		_add_decal(tile, _deploy_mat)
	for tile in _encounter.region(Encounter.REGION_WIN):
		_add_decal(tile, _win_mat)
	for e in _encounter.enemies:
		_add_enemy_token(e)


## Add a flat region decal on `tile`'s surface (a hair above it so it doesn't z-fight the cap).
func _add_decal(tile: Vector2i, mat: StandardMaterial3D) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = _decal_mesh
	mi.material_override = mat
	mi.position = _field.tile_to_world(tile.x, tile.y) + Vector3(0.0, 0.05, 0.0)
	_overlay_root.add_child(mi)


## Add an enemy token (a cylinder standing on the tile) plus a floating "Class Ln" label, tinting the
## cylinder gold if it's the selected enemy.
func _add_enemy_token(e: EnemyPlacement) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = _token_mesh
	mi.material_override = _enemy_selected_mat if e == _selected_enemy else _enemy_mat
	var base := _field.tile_to_world(e.tile.x, e.tile.y)
	mi.position = base + Vector3(0.0, _token_mesh.height * 0.5, 0.0)   # stand ON the surface
	_overlay_root.add_child(mi)

	var label := Label3D.new()
	label.text = "%s L%d" % [UnitClasses.display_name(e.klass), e.level]
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.pixel_size = 0.006
	label.modulate = Color.WHITE
	label.outline_size = 8
	label.position = base + Vector3(0.0, _token_mesh.height + 0.4, 0.0)
	_overlay_root.add_child(label)


# --- Enemy inspector ----------------------------------------------------------

## Build the enemy inspector dialog: a class dropdown + a level spinner, plus a Delete button. Edits
## apply to `_selected_enemy` on OK. (Per-stat overrides / boss placement are a later step.)
func _build_inspector() -> void:
	_inspector = AcceptDialog.new()
	_inspector.title = "Enemy"
	_inspector.ok_button_text = "Apply"
	_inspector.theme = _ui_theme
	_inspector.min_size = Vector2i(440, 240)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8)
	_inspector.add_child(vb)

	var class_label := Label.new()
	class_label.text = "Class"
	vb.add_child(class_label)
	_class_option = OptionButton.new()
	for c in PLACE_CLASSES:
		_class_option.add_item(UnitClasses.display_name(c), c)
	vb.add_child(_class_option)

	var level_label := Label.new()
	level_label.text = "Level"
	vb.add_child(level_label)
	_level_spin = SpinBox.new()
	_level_spin.min_value = 1
	_level_spin.max_value = 99
	vb.add_child(_level_spin)

	# A destructive "Delete" as a secondary dialog button (fires `custom_action`, not `confirmed`).
	_inspector.add_button("Delete", true, "delete")
	_inspector.confirmed.connect(_on_inspector_apply)
	_inspector.custom_action.connect(_on_inspector_action)
	add_child(_inspector)
	register_dialog(_inspector)


## Populate + pop the inspector for `e`.
func _open_inspector(e: EnemyPlacement) -> void:
	_class_option.select(_class_option.get_item_index(e.klass))
	_level_spin.value = e.level
	_inspector.popup_centered()


## Apply (OK): write the dropdown class + spinner level back to the selected enemy, then redraw.
func _on_inspector_apply() -> void:
	if _selected_enemy == null:
		return
	_selected_enemy.klass = _class_option.get_selected_id()
	_selected_enemy.level = int(_level_spin.value)
	_redraw_overlays()
	_refresh_label()


## A dialog button other than OK was pressed — currently only "delete", which removes the selected
## enemy and closes the inspector.
func _on_inspector_action(action: StringName) -> void:
	if action == "delete" and _selected_enemy != null:
		_encounter.enemies.erase(_selected_enemy)
		_selected_enemy = null
		_redraw_overlays()
		_refresh_label()
	_inspector.hide()


# --- Map sequence -------------------------------------------------------------

## A chosen `MapData` was picked to add to the sequence: append it, warn (don't block) if the chain
## is now mixed-size, then display it. Appending grows the time-degradation chain (see MapSequence).
func _on_map_chosen(path: String) -> void:
	_encounter.map_sequence.add_map(path)
	if not _encounter.map_sequence.is_uniform_size():
		push_warning("EncounterBuilder: '%s' differs in size from the chain — variable-size shifts are not wired yet." % path)
	_display_map(path)
	_refresh_label()


## Render the map at `path` on the display field (read-only), reframe the camera, and reposition the
## overlays (tile heights just changed). A missing / unloadable map leaves the current view alone.
func _display_map(path: String) -> void:
	var map := MapData.load_from(path)
	if map == null:
		push_warning("EncounterBuilder: could not load map '%s'." % path)
		return
	_field.load_map_data(map)
	_shown_map_path = path
	_recenter_camera()
	_redraw_overlays()


# --- Save / Open --------------------------------------------------------------

## Save the encounter to `path`. Its `MapSequence` is written as its OWN reusable resource first
## (to `assets/sequences/`, or back to its existing file if it already has one), so the encounter
## `.tres` references it rather than embedding it — keeping chains shareable across encounters.
func _on_encounter_save_chosen(path: String) -> void:
	var seq := _encounter.map_sequence
	var seq_path := seq.resource_path
	if seq_path.is_empty():
		seq_path = "%s/%s_seq.tres" % [SEQUENCES_DIR, _basename(path)]
	var seq_err := ResourceSaver.save(seq, seq_path)
	# Associate the in-memory sequence with its file, so the encounter serializes an EXTERNAL
	# reference to it (shareable across encounters) instead of inlining a copy. Without this,
	# ResourceSaver.save above leaves the sequence path-less and the encounter embeds it.
	seq.take_over_path(seq_path)
	var enc_err := _encounter.save_to(path)
	print("EncounterBuilder: saved '%s' (seq → %s) [enc err %d, seq err %d]" % [path, seq_path, enc_err, seq_err])
	_refresh_label()


## Open an existing encounter: adopt it as the one being edited, display its first map, and draw its
## placements.
func _on_encounter_open_chosen(path: String) -> void:
	var enc := Encounter.load_from(path)
	if enc == null:
		push_warning("EncounterBuilder: could not load encounter '%s'." % path)
		return
	_encounter = enc
	if _encounter.map_sequence == null:
		_encounter.map_sequence = MapSequence.new()
	_selected_enemy = null
	var first := _encounter.first_map_path()
	if not first.is_empty():
		_display_map(first)     # also redraws overlays
	else:
		_redraw_overlays()
	print("EncounterBuilder: opened '%s' (%d maps, %d enemies)" % [path, _encounter.map_sequence.size(), _encounter.enemies.size()])
	_refresh_label()


# --- HUD ----------------------------------------------------------------------

## Redraw the HUD readout: the active tool, the encounter's makeup, and the key help.
func _refresh_label() -> void:
	var seq := _encounter.map_sequence
	var dims := "%dx%d" % [_field.grid_width, _field.grid_height]
	var lines := [
		"ENCOUNTER BUILDER",
		"tool: %s        placing: %s" % [_tool_name(), UnitClasses.display_name(_place_class)],
		"maps: %d (showing %s, %s)   enemies: %d   deploy: %d   win: %d" % [
			seq.size(), _shown_map_name(), dims, _encounter.enemies.size(),
			_encounter.region(Encounter.REGION_DEPLOY).size(),
			_encounter.region(Encounter.REGION_WIN).size()],
		"",
		"1 Enemy  2 Deploy  3 Win   C: place-class   L-click add/select   R-click remove",
		"M: add map   O: open encounter   S: save encounter",
	]
	_label.text = "\n".join(lines)


## The active tool's display name.
func _tool_name() -> String:
	match _tool:
		Tool.ENEMY: return "ENEMY"
		Tool.DEPLOY: return "DEPLOY"
		Tool.WIN: return "WIN"
	return "?"


## Default filename stem for a Save — the shown map's name if any, else "encounter".
func _encounter_basename() -> String:
	return _basename(_shown_map_path) if not _shown_map_path.is_empty() else "encounter"


## Human-readable name of the shown map (its filename stem), or "none".
func _shown_map_name() -> String:
	return _basename(_shown_map_path) if not _shown_map_path.is_empty() else "none"


## Strip a `res://.../name.tres` path down to just `name`.
func _basename(path: String) -> String:
	return path.get_file().get_basename()
