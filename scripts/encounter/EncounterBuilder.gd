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
## pieces. THIS IS THE SKELETON (Phase 3 step 2): load-a-map-and-display + the save/load round-trip.
## Placement tools (enemies, deploy/win regions) and the MAPS sequence panel land in later steps;
## today the sequence is edited only by "add a map".
extends AuthoringScene

## Folders each document type lives in (mirrors the layering: maps → sequences → encounters).
const MAPS_DIR := "res://assets/maps"
const SEQUENCES_DIR := "res://assets/sequences"
const ENCOUNTERS_DIR := "res://assets/encounters"

## Placeholder grid shown until a real map is loaded — small + flat so it reads as "nothing yet".
const PLACEHOLDER_SIZE := 8
const PLACEHOLDER_HEIGHT := 1

## The encounter being authored. Starts empty (an empty `MapSequence`, no enemies, no regions);
## "add a map" grows the sequence, and Open replaces it with a loaded one.
var _encounter: Encounter

## `res://` path of the map currently shown on the field (for the HUD + recenter), or "" if none.
var _shown_map_path: String = ""

## The encounter-specific file pickers (built via the base `_make_dialog`, which registers them for
## the dialog-open guard). Add-a-map opens the maps folder; open/save use the encounters folder.
var _map_open_dialog: FileDialog
var _enc_open_dialog: FileDialog
var _enc_save_dialog: FileDialog


# --- AuthoringScene hooks -----------------------------------------------------

## HOOK: seed the display field with the placeholder grid (replaced wholesale once a map loads).
func _initial_states() -> Array:
	return _flat_states(PLACEHOLDER_SIZE, PLACEHOLDER_SIZE, PLACEHOLDER_HEIGHT, TileTypes.Type.GRASS)


## HOOK: create the blank encounter and the file pickers, then draw the HUD. (The base has already
## built the field, camera, theme, and the HUD panel/label by now.)
func _build_ui() -> void:
	_encounter = Encounter.new()
	_encounter.map_sequence = MapSequence.new()

	_map_open_dialog = _make_dialog(FileDialog.FILE_MODE_OPEN_FILE, MAPS_DIR, "Map resource")
	_map_open_dialog.file_selected.connect(_on_map_chosen)
	_enc_open_dialog = _make_dialog(FileDialog.FILE_MODE_OPEN_FILE, ENCOUNTERS_DIR, "Encounter resource")
	_enc_open_dialog.file_selected.connect(_on_encounter_open_chosen)
	_enc_save_dialog = _make_dialog(FileDialog.FILE_MODE_SAVE_FILE, ENCOUNTERS_DIR, "Encounter resource")
	_enc_save_dialog.file_selected.connect(_on_encounter_save_chosen)

	_refresh_label()


# --- Input --------------------------------------------------------------------

## Keyboard commands. M = add a map to the sequence, O = open an encounter, S = save the encounter.
## (Mouse placement of enemies / regions arrives with the placement tools in the next step.)
func _unhandled_input(event: InputEvent) -> void:
	if _dialog_open():
		return
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_M:
				_map_open_dialog.popup_centered(Vector2i(1000, 680))
			KEY_O:
				_enc_open_dialog.popup_centered(Vector2i(1000, 680))
			KEY_S:
				_enc_save_dialog.current_file = "%s.tres" % _encounter_basename()
				_enc_save_dialog.popup_centered(Vector2i(1000, 680))


# --- Map sequence -------------------------------------------------------------

## A chosen `MapData` was picked to add to the sequence: append it, warn (don't block) if the chain
## is now mixed-size, then display it. Appending grows the time-degradation chain (see MapSequence).
func _on_map_chosen(path: String) -> void:
	_encounter.map_sequence.add_map(path)
	if not _encounter.map_sequence.is_uniform_size():
		push_warning("EncounterBuilder: '%s' differs in size from the chain — variable-size shifts are not wired yet." % path)
	_display_map(path)
	_refresh_label()


## Render the map at `path` on the display field (read-only) and reframe the camera. A missing /
## unloadable map is reported and leaves the current view alone.
func _display_map(path: String) -> void:
	var map := MapData.load_from(path)
	if map == null:
		push_warning("EncounterBuilder: could not load map '%s'." % path)
		return
	_field.load_map_data(map)
	_shown_map_path = path
	_recenter_camera()


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
	var enc_err := _encounter.save_to(path)
	print("EncounterBuilder: saved '%s' (seq → %s) [enc err %d, seq err %d]" % [path, seq_path, enc_err, seq_err])
	_refresh_label()


## Open an existing encounter: adopt it as the one being edited and display its first map.
func _on_encounter_open_chosen(path: String) -> void:
	var enc := Encounter.load_from(path)
	if enc == null:
		push_warning("EncounterBuilder: could not load encounter '%s'." % path)
		return
	_encounter = enc
	if _encounter.map_sequence == null:
		_encounter.map_sequence = MapSequence.new()
	var first := _encounter.first_map_path()
	if not first.is_empty():
		_display_map(first)
	print("EncounterBuilder: opened '%s' (%d maps, %d enemies)" % [path, _encounter.map_sequence.size(), _encounter.enemies.size()])
	_refresh_label()


# --- HUD ----------------------------------------------------------------------

## Redraw the HUD readout: the encounter's current makeup + the key help.
func _refresh_label() -> void:
	var seq := _encounter.map_sequence
	var dims := "%dx%d" % [_field.grid_width, _field.grid_height]
	var lines := [
		"ENCOUNTER BUILDER",
		"maps in sequence: %d   (showing: %s, %s)" % [seq.size(), _shown_map_name(), dims],
		"enemies: %d   deploy: %d   win: %d" % [
			_encounter.enemies.size(),
			_encounter.region(Encounter.REGION_DEPLOY).size(),
			_encounter.region(Encounter.REGION_WIN).size()],
		"",
		"M: add map   O: open encounter   S: save encounter",
	]
	_label.text = "\n".join(lines)


## Default filename stem for a Save — the shown map's name if any, else "encounter".
func _encounter_basename() -> String:
	return _basename(_shown_map_path) if not _shown_map_path.is_empty() else "encounter"


## Human-readable name of the shown map (its filename stem), or "none".
func _shown_map_name() -> String:
	return _basename(_shown_map_path) if not _shown_map_path.is_empty() else "none"


## Strip a `res://.../name.tres` path down to just `name`.
func _basename(path: String) -> String:
	return path.get_file().get_basename()
