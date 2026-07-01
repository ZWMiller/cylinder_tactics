## One playable music cue: the audio itself plus a small PLAY CONSTRUCT describing how it should be
## performed — where to start, whether/where/how-many-times it loops, and how it should end. A
## data-only `Resource`, so each song is an authored `.tres` asset you tune in the Inspector (the
## same data-driven pattern as `Encounter`/`MapData`) rather than in code.
##
## Why a Resource and not just an `AudioStream`: Godot's raw stream only knows the samples. The
## musical intent — "skip the 8-second intro on replay", "loop back to the downbeat", "this short
## clip should play twice then wind down" — lives here, alongside the stream, as one bundle the
## `MusicManager` reads.
##
## The play construct, in plain terms: playback ENTERS the song at `start_position`, plays to the
## end, and then — if `loop` is on — jumps back to `loop_offset` and plays again, doing this
## `loop_count` times (or forever when `loop_count < 0`). When a FINITE plan runs out (a non-looping
## song, or the last scheduled loop), the track "ends": if `end_fade_time > 0` it fades out over that
## many seconds so it sounds like a real ending instead of a hard cut. The `MusicManager` treats that
## ending as a cue to fade in the next random track in the same category — so a battle stays scored
## even from short clips.
##
## GDScript note (vs Python/C++): `extends Resource` + `class_name` makes this a first-class asset
## type. `@export` fields become editable rows when you open the `.tres` in Godot's Inspector and are
## serialized to disk — think of it as a dataclass whose instances are files.
class_name MusicTrack
extends Resource

## Human-readable name, for logs and any future "now playing" UI. Not used by playback.
@export var track_name: String = ""

## The actual audio. For an imported `.mp3`/`.ogg` this is an `AudioStreamMP3`/`AudioStreamOggVorbis`.
## Godot only imports WAV / Ogg Vorbis / MP3 — an `.m4a` won't load, so keep sources in those formats.
@export var stream: AudioStream = null

## Where playback BEGINS, in seconds (0:08.250 → 8.25). A one-shot offset applied on the very first
## play via `AudioStreamPlayer.play(from_position)` — use it to skip a long intro. Independent of the
## loop point: `start_position` is where we ENTER the song; `loop_offset` is where a loop RETURNS to.
@export var start_position: float = 0.0

## Master switch for repetition. Off → the song plays once (from `start_position` to the end) and then
## ends. On → it repeats per `loop_offset` / `loop_count` below.
@export var loop: bool = true

## When `loop` is on, the point (seconds) each repeat jumps back to. This is what enables the classic
## "play the intro once, then loop the body" shape: set it to the end of the intro. 0.0 loops the
## whole song. Ignored when `loop` is off.
@export var loop_offset: float = 0.0

## When `loop` is on, HOW MANY times to loop back before the song ends. `-1` = loop forever (the
## default for a main battle theme). `0` = don't actually loop (equivalent to `loop` off). `1` = play,
## loop back once, then end — the "short clip" construct. A finite count is performed by the
## `MusicManager` counting passes (Godot's engine-level loop can only repeat *forever*, so finite
## plans are managed in code); `-1` uses the seamless engine loop.
@export var loop_count: int = -1

## How long (seconds) to fade the track out when a FINITE plan finishes, so it winds down like an
## ending instead of cutting off. 0.0 = stop the instant it ends (or let it end naturally). Has no
## effect on an infinite (`loop_count < 0`) track, which never reaches an end on its own. The fade
## begins this many seconds before the final pass would end, so it overlaps the tail.
@export var end_fade_time: float = 0.0

## Per-song volume trim in decibels: this track's TARGET level, ramped up to as it fades in. Use it to
## even out songs mastered at different loudness (negative = quieter). 0.0 = the stream's own level.
@export var volume_db: float = 0.0
