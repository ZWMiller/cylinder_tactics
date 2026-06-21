## Shared vocabulary for unit *classes*: the set of classes and the per-class
## visual identity (hat shape + hat color) used to draw them in the geometry-only
## prototype. Later this is also the natural home for class-driven stat templates
## (see docs/GAME_DESIGN.md §2–3) — where a soldier's base HP / move / jump live.
##
## Mirrors `TileTypes.gd`: a `class_name` namespace of an enum + `static` helpers,
## never instantiated. Any script can write `UnitClasses.Class.MAGE` or
## `UnitClasses.hat_color(...)` without preloading this file (that is what
## `class_name` buys you — a project-global name).
##
## Visual language (docs/GAME_DESIGN.md §7): the HAT encodes class — by *both* its
## shape and its color, so class still reads even if two colors are similar. Body
## color is a *separate* channel (allegiance), owned by `Unit`. Current mapping:
##   - Soldier — square (box) hat, steel/silver.
##   - Archer  — pyramid hat, dark green.
##   - Mage    — cone hat, violet.
class_name UnitClasses
extends RefCounted

## The unit classes shared by player and enemy units. Integer-backed, like every
## GDScript enum (so a class stores as a plain int).
enum Class {
	SOLDIER,  ## High-HP melee front-liner.
	ARCHER,   ## Ranged attacker.
	MAGE,     ## Low-HP magic / AoE caster.
}

## Hat dimensions, shared across all three shapes so every hat reads at the same
## scale. Pulled out as constants so the single place that decides "how big is a
## hat" is obvious and easy to retune.
const HAT_RADIUS := 0.34   ## Base radius (cone/pyramid) — half-footprint of the hat.
const HAT_HEIGHT := 0.45   ## Vertical size of the hat.


## Return the flat hat color for a class — the class's identity color. Kept
## distinct from the body/allegiance palette (`Unit.allegiance_color`) so the hat
## and body never blur into each other. Magenta = unmapped class: a loud "you
## forgot to map this" signal rather than a silent wrong default.
static func hat_color(c: int) -> Color:
	match c:
		Class.SOLDIER:
			return Color(0.85, 0.85, 0.88)  # steel / silver
		Class.ARCHER:
			# Dark green — deliberately darker than grass (0.30, 0.55, 0.32) so an
			# archer's hat never camouflages against the grassland surface.
			return Color(0.13, 0.40, 0.18)
		Class.MAGE:
			return Color(0.60, 0.35, 0.85)  # violet
		_:
			return Color.MAGENTA


## Build and return a *fresh* hat mesh for a class (a new mesh per call, so every
## unit owns its own hat geometry and recoloring/reshaping one never touches
## another). Each class picks a shape factory below; `Unit` seats whatever mesh it
## gets back by *measuring* it, so the differing shapes/heights need no `Unit.gd`
## change.
static func new_hat_mesh(c: int) -> Mesh:
	match c:
		Class.SOLDIER:
			return _square_hat()
		Class.ARCHER:
			return _pyramid()
		Class.MAGE:
			return _cone()
		_:
			return _cone()


## Human-readable class name, handy for debug prints now and UI later.
static func display_name(c: int) -> String:
	match c:
		Class.SOLDIER: return "Soldier"
		Class.ARCHER:  return "Archer"
		Class.MAGE:    return "Mage"
		_:             return "Unknown"


# --- Stat layer bridge -------------------------------------------------------
# The visual class enum above and the stat data assets in assets/classes/ are two
# halves of "a class": this section joins them. The hat shape/color stays code (it's
# cheap geometry); the *numbers* live in editable .tres so they can be tuned without
# touching code (docs/DECISION_LOG.md).

## Loaded class DEFINITIONS (base stats + per-level growth), one ClassDef per Class,
## as `.tres` data assets. `preload` resolves them at PARSE time, so a missing or
## renamed file is a loud editor error, not a silent runtime null. Keyed by the Class
## enum (int), so `CLASS_DEFS[Class.MAGE]` is the mage's stat asset.
const CLASS_DEFS := {
	Class.SOLDIER: preload("res://assets/classes/soldier.tres"),
	Class.ARCHER: preload("res://assets/classes/archer.tres"),
	Class.MAGE: preload("res://assets/classes/mage.tres"),
}


## Return the ClassDef (stats + growth asset) for a class, or null if unmapped. The
## single lookup the stat system goes through, so adding a class is "add a .tres + an
## entry above," nothing else.
static func class_def(c: int) -> ClassDef:
	return CLASS_DEFS.get(c)


## Sum the growth a unit has BANKED across its level-ups. `history` is the class held
## at each past level-up (see `Unit.level_history`): one entry per level gained, in
## whatever class the unit was at the time. This is the heart of the FFT-style "your
## stats remember the jobs you leveled in" system — level early as a Mage and those
## MP/MAG gains stay with you even after you switch to Soldier. Returns a fresh
## (zeroed-then-summed) StatBlock; an empty history (a level-1 unit) yields all zeros.
static func banked_growth(history: Array) -> StatBlock:
	var banked := StatBlock.new()
	for cid in history:
		var cd := class_def(cid)
		if cd != null and cd.growth != null:
			banked = banked.combined(cd.growth)
	return banked


# --- Hat shape factories -----------------------------------------------------
# One small builder per hat shape. Classes pick a shape in `new_hat_mesh`. All
# three are sized from HAT_RADIUS / HAT_HEIGHT so they seat identically on the body.

## A cone hat (mage). Godot has no dedicated ConeMesh — a `CylinderMesh` whose top
## radius is 0 tapers to a point, which *is* a cone. Its default high segment count
## makes the taper read as round.
static func _cone() -> CylinderMesh:
	var cone := CylinderMesh.new()
	cone.top_radius = 0.0           # 0 => taper to a point
	cone.bottom_radius = HAT_RADIUS
	cone.height = HAT_HEIGHT
	return cone


## A pyramid hat (archer). Same trick as the cone — a point-topped cylinder — but
## with only 4 radial segments, so the "round" base collapses to a square and the
## sides become four flat triangles: a square-based pyramid.
static func _pyramid() -> CylinderMesh:
	var pyramid := CylinderMesh.new()
	pyramid.top_radius = 0.0
	pyramid.bottom_radius = HAT_RADIUS
	pyramid.height = HAT_HEIGHT
	pyramid.radial_segments = 4     # 4 sides => square base => a pyramid, not a cone
	return pyramid


## A square ("box") hat (soldier) — a simple flat-topped box. Sized so its
## footprint roughly matches the cone/pyramid bases for a consistent silhouette.
static func _square_hat() -> BoxMesh:
	var box := BoxMesh.new()
	box.size = Vector3(HAT_RADIUS * 1.6, HAT_HEIGHT, HAT_RADIUS * 1.6)
	return box
