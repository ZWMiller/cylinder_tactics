## The game-wide MUSIC CONDUCTOR — an autoload (registered in project.godot, like `PartyLoadout`) so
## it persists across scene changes; music started in the battle keeps playing through the
## `Loadout → Main` swap instead of cutting on every scene load. Nothing else owns audio playback.
##
## It is the single mechanism; the CONTENT is data. Callers hand it a `MusicPlaylist` (the tracks for
## a context + how to move through them) and it:
##   - Crossfades by ping-ponging TWO `AudioStreamPlayer`s: the incoming one ramps up from silence
##     while the outgoing one ramps down — a clean handoff with no gap or click. Switching contexts
##     (normal battle → boss when the god appears) is just `play_playlist(boss)`; the same two
##     players cross it over. That's why contexts are playlists, not manager subclasses.
##   - Performs each track's PLAY CONSTRUCT (see `MusicTrack`): the start offset, a finite or infinite
##     loop, and an end-of-track wind-down fade. Finite loops are COUNTED here because Godot's engine
##     loop can only repeat forever — so "play twice then end" keeps the stream's own loop off,
##     listens for `finished`, and re-`play()`s from the loop point until the passes run out.
##   - When a finite track ends and the playlist's `auto_advance` is on, fades in the next track from
##     the SAME playlist, so short clips still score a whole fight. `fade_out()` (battle over) instead
##     fades to silence and does NOT advance.
##
## GDScript note (vs Python/C++): as an autoload, Godot instantiates this once and exposes it globally
## by its autoload name (`MusicManager`) — no manual singleton boilerplate.
extends Node

## Volume floor for fades, in decibels. -60 dB is effectively silent; we fade to/from this rather
## than toggling `playing` so ramps are smooth. (dB is logarithmic: 0 = full, negative = quieter.)
const SILENCE_DB := -60.0

## Default crossfade / fade-out duration in seconds when a caller doesn't specify one.
const DEFAULT_FADE := 2.0

## Name of the dedicated audio bus we route music through. Kept separate from "Master" so a future
## options menu can offer a music-only volume slider without touching sound effects.
const MUSIC_BUS := "Music"

## The two players we alternate between for crossfades. Only one is audible at a time; the other is
## the spare the next incoming track is prepared on.
var _player_a: AudioStreamPlayer
var _player_b: AudioStreamPlayer

## Role pointers into the pair above: `_active` is the audible player, `_idle` the spare. A crossfade
## prepares the incoming track on `_idle`, then swaps the two.
var _active: AudioStreamPlayer
var _idle: AudioStreamPlayer

## The playlist currently scoring, and the track playing from it. `null` = nothing is scored. The
## playlist is retained so a finite track that ends can pull the next one (per its policy).
var _playlist: MusicPlaylist = null
var _current_track: MusicTrack = null

## How many full passes of `_current_track` have COMPLETED — drives finite loop counting and final-
## pass detection for the end fade. Reset when a new track starts.
var _passes_done: int = 0

## Cursor for a non-shuffled playlist: index of the last track handed out (advances then wraps).
var _seq_index: int = -1

## The last track handed out, so a shuffled playlist can avoid an immediate repeat.
var _last_track: MusicTrack = null

## True once the end-of-track wind-down fade has begun, so the stream's natural `finished` isn't also
## treated as a completion. Reset per track.
var _ending: bool = false

## True between a `fade_out()` and the next `play_playlist()`, marking music as deliberately silenced
## (battle over) — suppresses auto-advance so nothing fades back in over the end screen.
var _stopping: bool = false

## The live fade tween, kept so a new fade can cancel a half-finished one instead of fighting it.
var _fade_tween: Tween = null

## RNG for shuffle. `randomize()` (not a fixed seed) so playlists vary run to run.
var _rng := RandomNumberGenerator.new()


## Autoload lifecycle: build the music bus and the two players once, at game start — before any scene
## calls `play_playlist`, so the pair is always ready.
func _ready() -> void:
	_rng.randomize()
	_ensure_music_bus()
	_player_a = _make_player()
	_player_b = _make_player()
	_active = _player_a
	_idle = _player_b


## Create the dedicated "Music" audio bus (feeding Master) if absent — in code, so we don't need a
## hand-authored `default_bus_layout.tres`. A settings slider can later drive this bus's volume.
func _ensure_music_bus() -> void:
	if AudioServer.get_bus_index(MUSIC_BUS) != -1:
		return
	var idx := AudioServer.bus_count
	AudioServer.add_bus(idx)
	AudioServer.set_bus_name(idx, MUSIC_BUS)
	AudioServer.set_bus_send(idx, "Master")   # route Music → Master


## Build one crossfade player: routed to the Music bus, started silent, and wired so its `finished`
## signal reports WHICH player fired (via `bind`) — only the active player's completion advances the
## play construct.
func _make_player() -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.bus = MUSIC_BUS
	p.volume_db = SILENCE_DB
	add_child(p)
	p.finished.connect(_on_player_finished.bind(p))
	return p


# --- Public API --------------------------------------------------------------

## Start scoring with `playlist`: pick its first track (random or first-in-order) and crossfade it in
## over `fade` seconds. The entry point a battle calls on load, and what the demo's boss reveal calls
## to switch pools mid-fight. Passing a fresh playlist resets the shuffle/sequence bookkeeping.
func play_playlist(playlist: MusicPlaylist, fade: float = DEFAULT_FADE) -> void:
	if playlist == null or playlist.tracks.is_empty():
		push_warning("MusicManager: play_playlist called with an empty/!null playlist.")
		return
	_playlist = playlist
	_seq_index = -1
	_last_track = null
	var track := _next_track()
	if track == null or track.stream == null:
		push_warning("MusicManager: playlist '%s' has no playable track." % playlist.playlist_name)
		return
	_crossfade_to(track, fade)


## Fade the current track down to silence over `fade` seconds and stop, scoring nothing afterward.
## Called when a battle ends (win/lose) — distinct from a track ending on its own, which advances the
## playlist. Safe to call when nothing is playing.
func fade_out(fade: float = DEFAULT_FADE) -> void:
	_stopping = true          # suppress auto-advance from any in-flight completion
	_ending = false
	_playlist = null
	_current_track = null
	_kill_fade()
	if _active == null or not _active.playing:
		return
	var outgoing := _active
	_fade_tween = create_tween()
	_fade_tween.tween_property(outgoing, "volume_db", SILENCE_DB, fade)
	_fade_tween.tween_callback(outgoing.stop)


## Play a SINGLE track through its full play construct (start offset, loop, finite plan, end fade) with
## NO playlist behind it — so when a finite plan ends it just stops instead of advancing. Useful for a
## one-off theme/stinger, and the basis of the music tuner's audition. `fade` crossfades from whatever
## was playing.
func play_track(track: MusicTrack, fade: float = DEFAULT_FADE) -> void:
	if track == null or track.stream == null:
		push_warning("MusicManager: play_track called with an empty/null track.")
		return
	_playlist = null          # no pool → a finite track just stops when done
	_last_track = track
	_crossfade_to(track, fade)


## Jump the currently-playing track to `seconds` — for auditioning a loop seam or end fade in the
## tuner without waiting for playback to arrive there. No-op if nothing is playing.
func seek(seconds: float) -> void:
	if _active != null and _active.playing:
		_active.seek(maxf(seconds, 0.0))


## Re-apply the current track's loop settings and volume trim to the LIVE stream WITHOUT restarting, so
## a tweak to `loop_offset` (heard at the next loop) or `volume_db` (immediate) takes effect while the
## song keeps playing. A `start_position` change still needs a restart (`play_track`) since it only
## acts on the initial play.
func reapply_current() -> void:
	if _current_track == null or _active == null:
		return
	_apply_loop_settings(_current_track)
	_active.volume_db = _current_track.volume_db


## Hard-stop all music immediately (no fade) — the blunt counterpart to `fade_out`, for the tuner's
## Stop button. Clears the current context so nothing auto-advances afterward.
func stop() -> void:
	_stopping = true
	_ending = false
	_playlist = null
	_current_track = null
	_kill_fade()
	if _player_a != null:
		_player_a.stop()
	if _player_b != null:
		_player_b.stop()


## True while a track is audibly playing. For the tuner's readout.
func is_playing() -> bool:
	return _active != null and _active.playing


## Current playback head of the active track, in seconds (0 when stopped). For the tuner's readout/scrub.
func playback_position() -> float:
	return _active.get_playback_position() if is_playing() else 0.0


## Length of the active track's stream, in seconds (0 when stopped). For the tuner's readout/scrub.
func track_length() -> float:
	if is_playing() and _active.stream != null:
		return _active.stream.get_length()
	return 0.0


## Which pass (1-based) of the current track's play construct is underway — 1 on the first play, 2
## after the first loop-back, etc. For the tuner's readout.
func current_pass() -> int:
	return _passes_done + 1


# --- Crossfade / playback ----------------------------------------------------

## Start `track` on the idle player and cross it over the active one: incoming ramps up from silence
## to the track's trim volume, outgoing ramps down to silence then stops. Resets the play-construct
## bookkeeping for the new track.
func _crossfade_to(track: MusicTrack, fade: float) -> void:
	_current_track = track
	_passes_done = 0
	_ending = false
	_stopping = false

	# Prepare the incoming track on the idle player.
	var incoming := _idle
	incoming.stream = track.stream
	_apply_loop_settings(track)          # engine-level loop only for the infinite case
	incoming.volume_db = SILENCE_DB
	incoming.play(track.start_position)  # enter the song at its authored offset

	# Swap roles: the player we just started is now the audible one.
	var outgoing := _active
	_active = incoming
	_idle = outgoing

	# Ramp incoming up and outgoing down in parallel, then stop the outgoing player once faded.
	_kill_fade()
	_fade_tween = create_tween()
	_fade_tween.set_parallel(true)
	_fade_tween.tween_property(incoming, "volume_db", track.volume_db, fade)
	if outgoing.playing:
		_fade_tween.tween_property(outgoing, "volume_db", SILENCE_DB, fade)
	# `chain()` breaks out of parallel so the stop runs AFTER the ramps. Guard against a newer
	# crossfade having reclaimed `outgoing` in the meantime.
	_fade_tween.chain().tween_callback(func() -> void:
		if outgoing != _active:
			outgoing.stop())


## Copy the track's loop intent onto its stream. Godot stores loop state on the imported
## `AudioStreamMP3`/`AudioStreamOggVorbis` and can only loop FOREVER — so we enable the engine loop
## only for a truly infinite track. For a finite plan we leave the stream's loop OFF and count passes
## ourselves (via `finished`), the only way to stop after N repeats.
func _apply_loop_settings(track: MusicTrack) -> void:
	var native_infinite := track.loop and track.loop_count < 0
	var s := track.stream
	if s is AudioStreamMP3:
		s.loop = native_infinite
		s.loop_offset = track.loop_offset
	elif s is AudioStreamOggVorbis:
		s.loop = native_infinite
		s.loop_offset = track.loop_offset


## Per-frame check that drives the end-of-track wind-down fade. Acts only when a FINITE track is on
## its final pass and close enough to the end that `end_fade_time` should begin — then it starts the
## fade so the song tapers instead of hard-stopping. Cheap early-outs keep it idle otherwise.
func _process(_delta: float) -> void:
	if _current_track == null or _ending or _stopping:
		return
	if _current_track.end_fade_time <= 0.0:
		return
	if not _is_final_pass():
		return
	if _active == null or not _active.playing or _active.stream == null:
		return
	var remaining := _active.stream.get_length() - _active.get_playback_position()
	if remaining <= _current_track.end_fade_time:
		_begin_end_fade()


## Begin fading the active track out over its `end_fade_time`, then treat it as ended. Sets `_ending`
## so the stream's own `finished` (which may fire mid-fade) is ignored — the fade's completion is the
## single "this track is done" trigger.
func _begin_end_fade() -> void:
	_ending = true
	_kill_fade()
	_fade_tween = create_tween()
	_fade_tween.tween_property(_active, "volume_db", SILENCE_DB, _current_track.end_fade_time)
	_fade_tween.tween_callback(_on_track_ended)


## A player reached the end of its (non-looping) stream. Only the ACTIVE player's completion advances
## the play construct — a stale idle player finishing is ignored. With passes left, jump back to the
## loop point and play again; once the passes are spent (and no end fade already handled it), the
## track is done.
func _on_player_finished(player: AudioStreamPlayer) -> void:
	if player != _active or _stopping or _ending or _current_track == null:
		return
	_passes_done += 1
	var total := _total_passes(_current_track)
	if total < 0:
		return   # infinite track: shouldn't reach here (engine loops it), guard anyway
	if _passes_done < total:
		_active.play(_current_track.loop_offset)   # loop back for another pass
	else:
		_on_track_ended()                          # finite plan complete (no end fade case)


## The current finite track has finished its plan. If the playlist wants continuous music, fade in the
## next track from it; otherwise stay silent. Suppressed after a deliberate `fade_out`. This is the
## "one ends, the next fades in" behavior for scoring a fight from short clips.
func _on_track_ended() -> void:
	if _stopping:
		return
	# No pool behind us (a one-off `play_track`), or the playlist doesn't chain: just go quiet.
	if _playlist == null or not _playlist.auto_advance:
		_current_track = null
		return
	var next := _next_track()
	if next != null and next.stream != null:
		_crossfade_to(next, DEFAULT_FADE)


# --- Track selection & helpers ----------------------------------------------

## Choose the next track from the current playlist per its policy: sequential (wrapping) when
## `shuffle` is off, otherwise random — avoiding an immediate repeat when `avoid_repeat` is on and
## there's more than one track. Records the pick so the next call can dodge it.
func _next_track() -> MusicTrack:
	var tracks := _playlist.tracks
	if tracks.is_empty():
		return null
	if not _playlist.shuffle:
		_seq_index = (_seq_index + 1) % tracks.size()
		_last_track = tracks[_seq_index]
		return _last_track
	var choice: MusicTrack = tracks[_rng.randi_range(0, tracks.size() - 1)]
	if _playlist.avoid_repeat:
		while tracks.size() > 1 and choice == _last_track:
			choice = tracks[_rng.randi_range(0, tracks.size() - 1)]
	_last_track = choice
	return choice


## Total passes a track plays before it ends: 1 for a non-looping (or `loop_count == 0`) song,
## `loop_count + 1` for a finite loop, and -1 (sentinel for "never ends") for an infinite one.
func _total_passes(track: MusicTrack) -> int:
	if not track.loop or track.loop_count == 0:
		return 1
	if track.loop_count < 0:
		return -1
	return track.loop_count + 1


## Whether the active track is on its LAST scheduled pass (so the end fade may run). Always false for
## an infinite track, which has no last pass.
func _is_final_pass() -> bool:
	var total := _total_passes(_current_track)
	if total < 0:
		return false
	return _passes_done == total - 1


## Cancel any in-flight fade tween so a new fade starts clean instead of two tweens fighting over the
## same `volume_db`.
func _kill_fade() -> void:
	if _fade_tween != null and _fade_tween.is_valid():
		_fade_tween.kill()
