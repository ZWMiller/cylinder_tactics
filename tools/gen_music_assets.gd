## Music asset generator / updater: builds the battle `MusicTrack` `.tres` files and the
## `battle_playlist.tres` that references them, with correct stream UIDs (it `load()`s the
## already-imported mp3s and lets `ResourceSaver` wire the references). Run headless:
##
##     godot --headless --script res://tools/gen_music_assets.gd
##
## SAFE TO RE-RUN. It is ADDITIVE, not destructive: an existing track `.tres` is left untouched (so
## start/loop/volume you tuned in the Inspector survives), and only MISSING tracks are created with
## conservative defaults (loop the whole song forever from 0:00). The playlist keeps its own flags
## (shuffle/auto_advance/avoid_repeat) if it already exists — only its track list is refreshed. So to
## add a song: import the mp3, add a row to `TRACKS`, re-run; existing tuning is preserved.
extends SceneTree

## [mp3 path, output .tres path, display name] for each battle track. Add a row to register a new song.
const TRACKS := [
	["res://assets/music/battle_music/Dirge at Sea.mp3",
		"res://assets/music/battle_music/dirge_at_sea.tres", "Dirge at Sea"],
	["res://assets/music/battle_music/Eminor-Clockworks-Gmajor.mp3",
		"res://assets/music/battle_music/eminor_clockworks.tres", "Eminor Clockworks"],
	["res://assets/music/battle_music/moving_on_boss_theme.mp3",
		"res://assets/music/battle_music/moving_on_boss.tres", "Moving On (Boss)"],
	["res://assets/music/battle_music/tactical_strike_default_battle.mp3",
		"res://assets/music/battle_music/tactical_strike.tres", "Tactical Strike"],
]

const PLAYLIST_PATH := "res://assets/music/battle_playlist.tres"


func _initialize() -> void:
	var tracks: Array[MusicTrack] = []
	for entry in TRACKS:
		var tres_path: String = entry[1]
		# Preserve an already-authored track: reuse it untouched so Inspector tuning isn't clobbered.
		if ResourceLoader.exists(tres_path):
			var existing := load(tres_path) as MusicTrack
			if existing != null:
				tracks.append(existing)
				print("kept existing %s" % tres_path)
				continue
		# New song: build one with conservative defaults and save it.
		var stream := load(entry[0]) as AudioStream
		if stream == null:
			push_error("gen_music_assets: could not load stream '%s'." % entry[0])
			continue
		var track := MusicTrack.new()
		track.track_name = entry[2]
		track.stream = stream
		track.start_position = 0.0
		track.loop = true
		track.loop_offset = 0.0
		track.loop_count = -1        # loop the whole song forever; tune to a finite plan later
		track.end_fade_time = 0.0
		track.volume_db = 0.0
		var err := ResourceSaver.save(track, tres_path)
		print("created %s -> %s (err %d)" % [entry[2], tres_path, err])
		tracks.append(load(tres_path) as MusicTrack)   # reload so the playlist refs the saved asset

	# Reuse the existing playlist (keeping its flags) and just refresh its track list; otherwise make one.
	var playlist: MusicPlaylist = null
	if ResourceLoader.exists(PLAYLIST_PATH):
		playlist = load(PLAYLIST_PATH) as MusicPlaylist
	if playlist == null:
		playlist = MusicPlaylist.new()
		playlist.playlist_name = "Battle"
		playlist.shuffle = true
		playlist.auto_advance = true
		playlist.avoid_repeat = true
	playlist.tracks = tracks
	var perr := ResourceSaver.save(playlist, PLAYLIST_PATH)
	print("saved playlist -> %s (err %d, %d tracks)" % [PLAYLIST_PATH, perr, tracks.size()])

	quit()
