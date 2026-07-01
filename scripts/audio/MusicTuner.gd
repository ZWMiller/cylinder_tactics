## MUSIC TUNER — a standalone F6 authoring tool for dialing in each `MusicTrack`'s play construct
## (start offset, loop point, finite plan, end-fade, volume trim) against the REAL `MusicManager`, so
## what you hear here is exactly what a battle will play. It closes the "minutes per test" loop: pick a
## track, tweak the fields live, and Play / Reload / Seek to hear the seam or fade in seconds — then
## Save back to the `.tres`.
##
## It is NOT built on `AuthoringScene` (that base is 3D map-editor scaffolding — battlefield, orbit
## camera, tile picking — none of which a pure audio/UI tool needs). It is a plain `Control` scene, its
## whole UI built in code in `_ready` (the project's code-driven-UI convention). Audio is driven by the
## `MusicManager` autoload, which is live in any F6 run.
##
## GDScript note (vs Python/C++): the many `.connect(Callable)` calls wire UI signals to handler
## methods — Godot's observer pattern. `set_value_no_signal` updates a control WITHOUT re-emitting its
## `value_changed`, which we use to reflect playback into the scrub bar without it looking like a user
## edit (avoids a feedback loop).
extends Control

## Root folder scanned (recursively) for `MusicTrack` `.tres` assets to list in the picker. Any `.tres`
## that isn't a `MusicTrack` (e.g. the `MusicPlaylist`) is skipped.
const MUSIC_DIR := "res://assets/music"

## Fade used when (re)starting a track here — short so auditioning feels immediate, not a slow swell.
const AUDITION_FADE := 0.15

## Seconds of lead-in the convenience "seek to …" buttons leave before the loop point / end, so you
## drop in just BEFORE the seam and actually hear the transition.
const SEEK_LEAD := 3.0

## The discovered tracks: each entry is { "path": String, "track": MusicTrack, "name": String }. The
## picker's item index maps 1:1 into this array.
var _tracks: Array[Dictionary] = []

## The track currently selected in the picker (the one Play/Reload/Save act on), and its `res://` path.
var _track: MusicTrack = null
var _track_path: String = ""

## Guard set true while pushing a track's values INTO the field editors, so their `value_changed`
## handlers don't write the same values straight back (harmless, but avoids churn / confusion).
var _syncing: bool = false

## True while the user is dragging the scrub bar, so `_process` stops overwriting its handle position
## with the live playback head until they let go (then we seek to where they dropped it).
var _scrubbing: bool = false

# --- UI references (built in `_build_ui`) ------------------------------------
var _track_option: OptionButton
var _name_edit: LineEdit
var _start_spin: SpinBox
var _loop_check: CheckBox
var _loopoff_spin: SpinBox
var _count_spin: SpinBox
var _fade_spin: SpinBox
var _vol_spin: SpinBox
var _readout: Label
var _scrub: HSlider
var _seek_spin: SpinBox
var _status: Label


## Build the UI, discover the track assets, and select the first one so the tool opens ready to play.
func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_build_ui()
	_scan_tracks()
	if _tracks.is_empty():
		_status.text = "No MusicTrack .tres found under %s — generate them first." % MUSIC_DIR
	else:
		_select_track(0)


## Per-frame: mirror the live playback head into the readout and scrub bar (unless the user is
## dragging the scrub). Keeps the scrub's range synced to the current track length.
func _process(_delta: float) -> void:
	var playing := MusicManager.is_playing()
	var pos := MusicManager.playback_position()
	var length := MusicManager.track_length()
	if length > 0.0:
		_scrub.max_value = length
		if not _scrubbing:
			_scrub.set_value_no_signal(pos)   # reflect position without looking like a user seek
	_readout.text = "pos %6.2f / %6.2f s    pass %d    %s" % [
		pos, length, MusicManager.current_pass(), "▶ playing" if playing else "■ stopped"]


# --- Track discovery / selection ---------------------------------------------

## Recursively scan `MUSIC_DIR` for `MusicTrack` `.tres` files and (re)populate the picker.
func _scan_tracks() -> void:
	_tracks.clear()
	_track_option.clear()
	_gather_tracks(MUSIC_DIR)
	for i in _tracks.size():
		_track_option.add_item(_tracks[i]["name"], i)


## Depth-first walk of `dir_path`, appending every `.tres` that loads as a `MusicTrack` to `_tracks`.
## Hidden folders (leading ".", e.g. `.godot`) are skipped.
func _gather_tracks(dir_path: String) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		var full := dir_path.path_join(entry)
		if dir.current_is_dir():
			if not entry.begins_with("."):
				_gather_tracks(full)
		elif entry.ends_with(".tres"):
			var res := load(full)
			if res is MusicTrack:
				var label: String = res.track_name if res.track_name != "" else entry
				_tracks.append({"path": full, "track": res, "name": label})
		entry = dir.get_next()
	dir.list_dir_end()


## Make `idx` the active track: cache it + its path and load its values into the field editors.
func _select_track(idx: int) -> void:
	if idx < 0 or idx >= _tracks.size():
		return
	_track = _tracks[idx]["track"]
	_track_path = _tracks[idx]["path"]
	_track_option.select(idx)
	_sync_fields_from_track()
	_status.text = "Loaded %s" % _track_path


## Push the selected track's field values into the editors (guarded so it doesn't echo back).
func _sync_fields_from_track() -> void:
	_syncing = true
	_name_edit.text = _track.track_name
	_start_spin.value = _track.start_position
	_loop_check.button_pressed = _track.loop
	_loopoff_spin.value = _track.loop_offset
	_count_spin.value = _track.loop_count
	_fade_spin.value = _track.end_fade_time
	_vol_spin.value = _track.volume_db
	_syncing = false


# --- Field edit handlers (write straight into the in-memory track) -----------
# Editing a field updates the MusicTrack resource immediately; Play/Reload/Save then use those values.

func _on_pick(idx: int) -> void:
	_select_track(idx)

func _on_name_changed(text: String) -> void:
	if not _syncing and _track != null:
		_track.track_name = text

func _on_start_changed(v: float) -> void:
	if not _syncing and _track != null:
		_track.start_position = v

func _on_loop_toggled(on: bool) -> void:
	if not _syncing and _track != null:
		_track.loop = on

func _on_loopoff_changed(v: float) -> void:
	if not _syncing and _track != null:
		_track.loop_offset = v

func _on_count_changed(v: float) -> void:
	if not _syncing and _track != null:
		_track.loop_count = int(v)

func _on_fade_changed(v: float) -> void:
	if not _syncing and _track != null:
		_track.end_fade_time = v

func _on_vol_changed(v: float) -> void:
	if not _syncing and _track != null:
		_track.volume_db = v


# --- Transport handlers ------------------------------------------------------

## Play / restart the selected track from its `start_position` with the current field values — the way
## to hear `start_position` / `loop_count` / `end_fade_time` changes (which only act on a fresh play).
func _on_play() -> void:
	if _track == null:
		return
	MusicManager.play_track(_track, AUDITION_FADE)
	_status.text = "Playing %s" % _track.track_name

## Apply loop-point / volume tweaks to the CURRENTLY playing track without restarting (hear a
## `loop_offset` change at the next loop; a `volume_db` change immediately).
func _on_reload() -> void:
	MusicManager.reapply_current()
	_status.text = "Re-applied loop/volume to the live track"

## Stop playback immediately.
func _on_stop() -> void:
	MusicManager.stop()
	_status.text = "Stopped"

## Persist the edited values back to the track's `.tres`.
func _on_save() -> void:
	if _track == null:
		return
	var err := ResourceSaver.save(_track, _track_path)
	_status.text = ("Saved %s" % _track_path) if err == OK else ("SAVE FAILED (err %d)" % err)
	# Refresh the picker label in case the name changed.
	var idx := _track_option.get_selected_id()
	if idx >= 0:
		_tracks[idx]["name"] = _track.track_name if _track.track_name != "" else _track_path.get_file()
		_track_option.set_item_text(idx, _tracks[idx]["name"])

## Seek to the value in the seek box.
func _on_seek() -> void:
	MusicManager.seek(_seek_spin.value)

## Jump to just before the loop point, so the next thing you hear is the loop seam.
func _on_seek_loop() -> void:
	MusicManager.seek(maxf(_track.loop_offset - SEEK_LEAD, 0.0))

## Jump to just before the end (accounting for the end-fade lead), to audition how the track finishes.
func _on_seek_end() -> void:
	var length := MusicManager.track_length()
	if length > 0.0:
		MusicManager.seek(maxf(length - (_track.end_fade_time + SEEK_LEAD), 0.0))


# --- UI construction ---------------------------------------------------------

## Build the whole tool UI in code: a dark panel holding the picker, the field editors, the playback
## readout + scrub bar, and the transport / seek buttons.
func _build_ui() -> void:
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.09, 0.10, 0.13)
	panel.add_theme_stylebox_override("panel", sb)
	add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 24)
	margin.add_theme_constant_override("margin_top", 20)
	margin.add_theme_constant_override("margin_right", 24)
	margin.add_theme_constant_override("margin_bottom", 20)
	panel.add_child(margin)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 12)
	margin.add_child(col)

	var title := Label.new()
	title.text = "Music Tuner"
	title.add_theme_font_size_override("font_size", 30)
	col.add_child(title)

	# Track picker row.
	var pick_row := HBoxContainer.new()
	pick_row.add_theme_constant_override("separation", 10)
	col.add_child(pick_row)
	var pick_label := Label.new()
	pick_label.text = "Track:"
	pick_row.add_child(pick_label)
	_track_option = OptionButton.new()
	_track_option.custom_minimum_size = Vector2(360, 0)
	_track_option.item_selected.connect(_on_pick)
	pick_row.add_child(_track_option)

	# Field editors, in a two-column grid (label | control).
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 14)
	grid.add_theme_constant_override("v_separation", 8)
	col.add_child(grid)

	_name_edit = LineEdit.new()
	_name_edit.custom_minimum_size = Vector2(360, 0)
	_name_edit.text_changed.connect(_on_name_changed)
	_row(grid, "Name", _name_edit)

	_start_spin = _make_spin(0.0, 3600.0, 0.05, " s")
	_start_spin.value_changed.connect(_on_start_changed)
	_row(grid, "Start position", _start_spin)

	_loop_check = CheckBox.new()
	_loop_check.text = "loops"
	_loop_check.toggled.connect(_on_loop_toggled)
	_row(grid, "Loop", _loop_check)

	_loopoff_spin = _make_spin(0.0, 3600.0, 0.05, " s")
	_loopoff_spin.value_changed.connect(_on_loopoff_changed)
	_row(grid, "Loop offset", _loopoff_spin)

	_count_spin = _make_spin(-1.0, 99.0, 1.0, "")
	_count_spin.value_changed.connect(_on_count_changed)
	_row(grid, "Loop count (-1 = forever)", _count_spin)

	_fade_spin = _make_spin(0.0, 30.0, 0.1, " s")
	_fade_spin.value_changed.connect(_on_fade_changed)
	_row(grid, "End fade time", _fade_spin)

	_vol_spin = _make_spin(-60.0, 6.0, 0.5, " dB")
	_vol_spin.value_changed.connect(_on_vol_changed)
	_row(grid, "Volume trim", _vol_spin)

	# Playback readout + scrub bar.
	_readout = Label.new()
	_readout.add_theme_font_size_override("font_size", 20)
	col.add_child(_readout)

	_scrub = HSlider.new()
	_scrub.min_value = 0.0
	_scrub.max_value = 1.0
	_scrub.step = 0.01
	_scrub.custom_minimum_size = Vector2(560, 0)
	_scrub.drag_started.connect(func() -> void: _scrubbing = true)
	_scrub.drag_ended.connect(func(_changed: bool) -> void:
		_scrubbing = false
		MusicManager.seek(_scrub.value))
	col.add_child(_scrub)

	# Transport buttons.
	var transport := HBoxContainer.new()
	transport.add_theme_constant_override("separation", 10)
	col.add_child(transport)
	transport.add_child(_make_button("▶ Play / Restart", _on_play))
	transport.add_child(_make_button("⟳ Reload (live)", _on_reload))
	transport.add_child(_make_button("■ Stop", _on_stop))
	transport.add_child(_make_button("💾 Save", _on_save))

	# Seek controls.
	var seek_row := HBoxContainer.new()
	seek_row.add_theme_constant_override("separation", 10)
	col.add_child(seek_row)
	var seek_label := Label.new()
	seek_label.text = "Seek to:"
	seek_row.add_child(seek_label)
	_seek_spin = _make_spin(0.0, 3600.0, 0.05, " s")
	seek_row.add_child(_seek_spin)
	seek_row.add_child(_make_button("Go", _on_seek))
	seek_row.add_child(_make_button("→ loop seam", _on_seek_loop))
	seek_row.add_child(_make_button("→ end", _on_seek_end))

	# Status line + help.
	_status = Label.new()
	_status.add_theme_color_override("font_color", Color(0.7, 0.85, 1.0))
	col.add_child(_status)

	var help := Label.new()
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	help.custom_minimum_size = Vector2(700, 0)
	help.add_theme_color_override("font_color", Color(0.6, 0.6, 0.65))
	help.text = ("Tweak fields → Play/Restart to hear start/loop-count/end-fade changes, or Reload to "
		+ "apply loop-offset/volume to the live track. Use \"→ loop seam\" / \"→ end\" to jump near the "
		+ "transition. Save writes back to the .tres.")
	col.add_child(help)


## Add a `label`-then-`control` row to the two-column grid.
func _row(grid: GridContainer, label: String, control: Control) -> void:
	var l := Label.new()
	l.text = label
	grid.add_child(l)
	grid.add_child(control)


## A configured `SpinBox` (numeric field with up/down arrows). `suffix` shows a unit after the value.
func _make_spin(min_v: float, max_v: float, step: float, suffix: String) -> SpinBox:
	var s := SpinBox.new()
	s.min_value = min_v
	s.max_value = max_v
	s.step = step
	s.suffix = suffix
	s.custom_minimum_size = Vector2(160, 0)
	return s


## A `Button` wired to `handler`.
func _make_button(text: String, handler: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.pressed.connect(handler)
	return b
