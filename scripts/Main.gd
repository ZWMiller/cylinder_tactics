## The demo battle — and the first, simplest example of the `BattleBase` inheritance pattern.
##
## Everything that makes a battle run (spawning, the turn loop, input, combat, win/lose) lives in
## `BattleBase`; `Main` just IS a battle with the default demo setup, so for now it adds nothing
## and inherits it all. This is exactly the shape a real scripted fight will take — e.g. a future
## `Battle5 extends BattleBase` that loads its own `Encounter` and overrides hooks to add dialogue
## or a moving objective. `Main` is that same relationship with zero custom behavior.
##
## `Main.tscn` still references this script by path and is the project's `run/main_scene`, so F5
## launches this battle. (`Main` is NOT a reserved Godot name — the scene is only "the main scene"
## because `project.godot` points `run/main_scene` at it.)
##
## Kept as its own file (rather than attaching `BattleBase` directly to `Main.tscn`) so the demo
## has a named home to grow overrides in, and so the base stays a clean, battle-agnostic parent.
class_name Main
extends BattleBase
