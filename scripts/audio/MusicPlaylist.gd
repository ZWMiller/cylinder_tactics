## A named MUSIC CONTEXT — the set of tracks for one situation (a normal battle, a boss fight, camp)
## plus the policy for how to move through them. A data-only `Resource`, so each context is an
## authored `.tres` you build in the Inspector; switching contexts (e.g. normal battle → boss when the
## god appears in the demo) is just handing a different playlist to the one `MusicManager`, which
## crossfades to it. This is why we model contexts as DATA rather than as `MusicManager` subclasses:
## the conductor's machinery (crossfade, loop counting, end-fade) is identical everywhere — only the
## track list and these few policy flags change.
##
## GDScript note: `Array[MusicTrack]` is a TYPED array (like `list[MusicTrack]` with enforcement).
## Godot type-checks assignments and, in the Inspector, gives each element a `MusicTrack` slot you can
## drag a track `.tres` into.
class_name MusicPlaylist
extends Resource

## Human-readable name, for logs / debugging. Not used by playback.
@export var playlist_name: String = ""

## The tracks this context can play, as `MusicTrack` resources. Order matters only when `shuffle` is
## off (then they play top-to-bottom).
@export var tracks: Array[MusicTrack] = []

## Pick tracks at random (true) or play them in listed order (false). Random suits a battle pool;
## a scripted sequence would turn this off.
@export var shuffle: bool = true

## When a track finishes its finite play construct, automatically fade in the NEXT track from this
## playlist (true) — keeping a fight scored from short clips. False = let it end and stay silent
## (fine for a single infinite theme, e.g. a boss loop that just plays until the context changes).
@export var auto_advance: bool = true

## When shuffling, avoid playing the same track twice in a row (ignored with a single-track playlist).
@export var avoid_repeat: bool = true
