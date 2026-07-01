# Music system

How the game plays, loops, crossfades, and switches battle music. Built 2026-07-01. All code lives
in `scripts/audio/`; the data assets live under `assets/music/`.

## The idea in one line

> **One conductor (`MusicManager`) plays audio; each situation is a `MusicPlaylist` of `MusicTrack`s,
> and every song carries its own play construct (where to start, how it loops, how it ends).**

The variation between contexts (normal battle vs. boss vs. camp) is **data, not code**: it's which
tracks and a few policy flags — never a `MusicManager` subclass. That's the deliberate call (see
"Why not subclasses" below).

## Pieces (all in `scripts/audio/`)

| Type | Kind | Role |
|------|------|------|
| `MusicTrack` | `Resource` (`.tres`) | One song + its play construct (start offset, loop, finite/infinite, end-fade, volume trim). |
| `MusicPlaylist` | `Resource` (`.tres`) | A named context: a list of `MusicTrack`s + how to move through them (shuffle / auto-advance / avoid-repeat). |
| `MusicManager` | autoload `Node` | The single conductor. Owns two players, crossfades, performs each play construct, advances playlists. |

The data assets:
- `assets/music/battle_music/*.tres` — the four battle `MusicTrack`s.
- `assets/music/battle_playlist.tres` — the shared battle `MusicPlaylist`.
- `assets/music/battle_music/*.mp3`, `assets/music/overworld_title_menu/*.mp3` — the raw audio.

`MusicManager` is registered as an autoload in `project.godot`, so it persists across the
`Loadout → Main` scene swap — music started in a battle keeps playing instead of cutting on load.

## How Godot handles the audio (quick primer)

- An **`AudioStreamPlayer`** node plays an **`AudioStream`** resource (an imported `.mp3`/`.ogg`/`.wav`).
  We use two players so we can crossfade one out while the other fades in.
- **Buses** are mixer channels. We create a dedicated **`Music`** bus in code (feeds `Master`) so a
  future options menu can have a music-only volume slider. Volume is in **decibels** (0 = full,
  negative = quieter); a fade is just tweening `volume_db`.
- **Format caveat:** Godot only imports **WAV, Ogg Vorbis, and MP3**. An `.m4a`/AAC will NOT import —
  convert to `.ogg` (best for looping) or `.mp3` first.

## The play construct (`MusicTrack` fields)

Playback *enters* the song at `start_position`, plays to the end, and — if `loop` is on — jumps back
to `loop_offset` and plays again, `loop_count` times (or forever). When a finite plan runs out, the
track *ends*: if `end_fade_time > 0` it fades out so it sounds like a real ending.

| Field | Meaning |
|-------|---------|
| `start_position` | Seconds to begin at on first play (0:08.250 → `8.25`). Skips an intro. One-shot. |
| `loop` | Master repeat switch. Off = play once and end. |
| `loop_offset` | Seconds each repeat returns to. Enables "intro once, then loop the body". |
| `loop_count` | How many times to loop back. `-1` = forever; `0` = don't loop; `1` = play + one loop, then end. |
| `end_fade_time` | On a *finite* plan, fade out over this many seconds so it winds down instead of cutting. |
| `volume_db` | Per-song volume trim (its fade-in target). Use to even out loudness. |

**Key Godot fact:** looping is a property of the *stream*, not the play call, and the engine loop can
only repeat **forever**. So infinite tracks use the seamless engine loop; **finite** plans keep the
stream's loop OFF and `MusicManager` counts passes via the `finished` signal, re-`play()`ing from
`loop_offset` until the count is spent. That's the only way to stop after N loops.

Example — a short clip that plays twice then winds down:
`start_position=0, loop=true, loop_offset=4.0, loop_count=1, end_fade_time=3.0`.

## Playlist policy (`MusicPlaylist` fields)

| Field | Meaning |
|-------|---------|
| `tracks` | The `MusicTrack`s this context can play. |
| `shuffle` | Random (true) vs. authored order (false). |
| `auto_advance` | When a track ends, fade in the next one from this playlist — continuous music from short clips. False = go silent (fine for a single infinite theme). |
| `avoid_repeat` | When shuffling, don't play the same track twice in a row. |

## Wiring into a battle

`BattleBase` starts music on load and fades it out when the fight ends:
- `_ready()` → `_start_battle_music()` → `MusicManager.play_playlist(...)`.
- `_end_battle()` → `MusicManager.fade_out()` (to silence — decided 2026-07-01).

Each battle can pick its own music **without** subclassing gymnastics via the exported
`music_playlist` on `BattleBase`: leave it null to use the shared `DEFAULT_BATTLE_PLAYLIST`, or set it
(in the Inspector on the battle's scene, or `music_playlist = preload(...)` in a subclass before
`super._ready()`).

**Switching pools mid-fight** (the demo's god reveal → boss music) is a direct call the battle script
makes at the trigger moment: `MusicManager.play_playlist(boss_playlist)`. The two-player rig
crossfades from the current track to the boss theme for free.

## Adding or tuning a song

1. Drop the `.mp3`/`.ogg` into `assets/music/battle_music/` and let Godot import it (focus the editor
   or `godot --headless --editor --quit`).
2. Add a row to `TRACKS` in `tools/gen_music_assets.gd` and run:
   `godot --headless --script res://tools/gen_music_assets.gd`.
   It is **additive** — existing track `.tres` are kept (your Inspector tuning survives); only missing
   ones are created (defaults: loop forever from 0:00). The playlist's track list is refreshed.
3. Tune the new track with the **Music Tuner** (below) — or directly in the `.tres` Inspector.

## Tuning tracks: the Music Tuner (F6)

`scenes/MusicTuner.tscn` (`scripts/audio/MusicTuner.gd`) is a standalone tool — open it and press **F6**.
It drives the real `MusicManager`, so what you hear is what a battle plays. It:

- lists every `MusicTrack` under `assets/music/` in a picker,
- exposes all play-construct fields as live editors (start, loop, loop offset, loop count, end fade,
  volume trim),
- **▶ Play / Restart** — (re)play from `start_position` with the current values; needed to hear
  `start_position` / `loop_count` / `end_fade_time` changes (those only act on a fresh play),
- **⟳ Reload (live)** — apply `loop_offset` / `volume_db` to the *currently playing* track without
  restarting (loop-offset is heard at the next loop; volume immediately),
- **Seek** — a scrub bar plus **→ loop seam** / **→ end** buttons that jump to just before the
  transition so you audition the seam / fade in seconds instead of waiting minutes,
- a readout of playback position, track length, and current loop pass,
- **💾 Save** — writes the edited values back to the `.tres`.

It is not built on `AuthoringScene` (that base is 3D map-editor scaffolding); it's a plain `Control`.

## Why not `BattleMusicManager` / `BossMusicManager` subclasses

An autoload is a **single global instance**; multiple subclass instances would fight over the players
and the Music bus. And the boss switch is just *crossfading from playlist A to B on the same two
players* — trivial with one conductor (`play_playlist(boss)`), awkward across two crossfaders. The
conductor's machinery is identical for every context; only the track list and a couple of flags
differ — i.e. the variation is data. So: composition (playlists as resources) over inheritance. This
mirrors the `MusicTrack`/`Encounter`/`MapData` data-driven pattern.
