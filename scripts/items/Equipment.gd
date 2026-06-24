## A wearable/wieldable ITEM — the data that plugs equipment into the combat math.
## One generic resource covers weapons, shields, and armor; which fields matter depends
## on the `slot`/`channel`. Like `Attack`, this is pure data the rest of the system reads:
## `CombatResolver` reads `power`/`armor_*`, `Unit` reads `requirements`/`modifiers`.
##
## THE DAMAGE MODEL this exists to serve (multiplicative — see docs/EQUIPMENT.md):
##   physical damage = phys_atk × weapon.power − phys_def × armor_phys_total × ARMOR_PHYS_SCALE
##   magical  damage = mag_atk  × spell.power  − mag_def  × armor_mag_total  × ARMOR_MAG_SCALE
## A weapon's `power` is the multiplier on the wielder's raw attack stat (unarmed baseline
## is 1.0); armor's `armor_phys`/`armor_mag` are SUMMED across every equipped piece and then
## multiplied by the wearer's defense stat. So the stat decides how *well* you use the gear,
## and the gear decides how much there is to use — neither alone is your offense/defense.
##
## A `Resource` so items can later be authored as `.tres` and dropped on units; for now the
## catalog is built in code via the `static` factories below (the same pattern as
## `Attack.fireball()` — authored data assets come when loot/inventory lands).
class_name Equipment
extends Resource

## Where the item mounts. A unit has two HAND mounts (weapon/shield; a two-hander fills
## both) and one each of HEAD/CHEST/BOOTS. Armor totals sum across HAND (shields) + the
## three armor slots, so a shield contributes to mitigation just like a breastplate.
enum Slot { HAND, HEAD, CHEST, BOOTS }

## Which damage channel a weapon's `power` multiplies — or NONE for non-offensive gear
## (shields, armor). PHYSICAL weapons scale `phys_atk`; MAGICAL weapons (staff/wand) scale
## `mag_atk`, so an equipped staff is what makes a Fireball hit hard. `Unit.weapon_power_for`
## matches an attack's channel to the right equipped weapon.
enum Channel { NONE, PHYSICAL, MAGICAL }

## Menu / log label.
@export var display_name: String = "Equipment"

## Which mount this occupies (see Slot).
@export var slot: Slot = Slot.HAND

## How many hands a HAND-slot item needs: 1 (leaves the other hand free for a shield/offhand)
## or 2 (a two-hander that occupies both). Ignored for armor slots.
@export var hands: int = 1

## Which attack channel this weapon powers (see Channel). NONE for shields/armor.
@export var channel: Channel = Channel.NONE

## The damage multiplier on the wielder's attack stat (weapon_power / spell_power are the
## same field, read per channel). 1.0 ≈ "raw stat is the damage"; >1 scales it up. Unused
## when channel is NONE.
@export var power: float = 1.0

## Physical / magical mitigation this piece contributes. SUMMED across all equipped gear,
## then multiplied by the wearer's phys_def/mag_def and the global scale knob. 0 for weapons.
@export var armor_phys: float = 0.0
@export var armor_mag: float = 0.0

## Which armor SET this piece belongs to (e.g. &"cloth"), or &"" for none. When a unit wears a
## full matching set (head + chest + boots all this id), it gains the set's bonus rider — see
## `set_bonus` and `Unit._active_set_bonus`. Weapons/shields leave this empty.
@export var set_id: StringName = &""

## Hit-chance multiplier for the future accuracy formula (≈ attacker_accuracy × weapon.accuracy
## − target_dodge). Wired onto the data now and left at 1.0 on every item; `CombatResolver.hit_chance`
## still mocks 1.0, so this is a dormant seam until evasion lands.
@export var accuracy: float = 1.0

## Minimum stats to wield/wear this, as a `StatBlock` of floors (e.g. a Bastard Sword's
## requirements has phys_atk = 7, everything else 0). `Unit.can_equip` checks each field, so
## a low-strength mage can't lift a two-handed broadsword. Null = no requirement.
@export var requirements: StatBlock = null

## Stat riders folded into the wearer's effective stats like aptitude (e.g. the Rapier's +1
## speed). Most starter gear has none. Null = no modifiers.
@export var modifiers: StatBlock = null


# --- Catalog (built in code, like the Attack factories) ----------------------
# Tuned against the level-1 class stats in assets/classes/ — see docs/EQUIPMENT.md for the
# full numbers table and the balance reasoning behind each tier and requirement gate.

## Build a StatBlock from a {field: value} dict — the shared helper for both requirement
## floors and stat-rider modifiers (a StatBlock defaults every field to 0, so we only set
## the ones that matter). `set()` by name keeps this generic over the stat schema.
static func _block(fields: Dictionary) -> StatBlock:
	var sb := StatBlock.new()
	for field in fields:
		sb.set(field, fields[field])
	return sb

## Assemble a weapon: a HAND item with a damage channel + multiplier and a requirement floor.
static func _weapon(name: String, hand_count: int, chan: Channel, pwr: float, req: StatBlock) -> Equipment:
	var e := Equipment.new()
	e.display_name = name
	e.slot = Slot.HAND
	e.hands = hand_count
	e.channel = chan
	e.power = pwr
	e.requirements = req
	return e

## Assemble an armor piece: a HEAD/CHEST/BOOTS item contributing phys/mag mitigation, no offense.
## `set` tags it for the set-bonus check (empty = no set).
static func _armor(name: String, armor_slot: Slot, phys: float, mag: float, set := &"") -> Equipment:
	var e := Equipment.new()
	e.display_name = name
	e.slot = armor_slot
	e.channel = Channel.NONE
	e.armor_phys = phys
	e.armor_mag = mag
	e.set_id = set
	return e


## The bonus rider a unit gains ONLY while wearing a full matching set (head + chest + boots), keyed
## by `set_id`. Returns a fresh `StatBlock` or null. Built in code (a StatBlock can't be `const`).
## Cloth = +1 mag_atk / +1 evasion (the reserved "dodge" stat — stored & shown now, but inert until
## the accuracy/dodge hit formula lands). Other sets have no bonus yet — add cases here.
static func set_bonus(set: StringName) -> StatBlock:
	match set:
		&"cloth":
			return _block({"mag_atk": 1, "evasion": 1})
		_:
			return null

# Weapons --------------------------------------------------------------------

## 1H, almost no requirement, low power — the universal fallback (even a mage can hold one).
static func dagger() -> Equipment:
	return _weapon("Dagger", 1, Channel.PHYSICAL, 1.2, _block({"phys_atk": 1}))

## 1H finesse blade gated on SPEED (archers/quick units), medium power, +1 speed rider.
static func rapier() -> Equipment:
	var e := _weapon("Rapier", 1, Channel.PHYSICAL, 1.5, _block({"speed": 7}))
	e.modifiers = _block({"speed": 1})
	return e

## 1H, medium strength gate, medium power — the soldier's bread-and-butter blade.
static func straight_sword() -> Equipment:
	return _weapon("Straight Sword", 1, Channel.PHYSICAL, 1.8, _block({"phys_atk": 5}))

## 2H ranged, gated on speed + a little strength, medium power — the archer's weapon.
static func bow() -> Equipment:
	return _weapon("Bow", 2, Channel.PHYSICAL, 2.0, _block({"speed": 7, "phys_atk": 4}))

## 2H, high strength gate (wieldable by a level-1 Soldier, not an Archer), high power.
static func bastard_sword() -> Equipment:
	return _weapon("Bastard Sword", 2, Channel.PHYSICAL, 2.1, _block({"phys_atk": 7}))

## 1H caster weapon, medium MAG gate, good (sub-staff) spell power.
static func wand() -> Equipment:
	return _weapon("Magic Wand", 1, Channel.MAGICAL, 1.2, _block({"mag_atk": 5}))

## 2H caster weapon, high MAG gate (wieldable by a level-1 Mage), highest spell power.
static func staff() -> Equipment:
	return _weapon("Magic Staff", 2, Channel.MAGICAL, 1.55, _block({"mag_atk": 8}))

## 1H, no requirement, adds a small amount of BOTH armor channels — a defensive offhand.
static func shield() -> Equipment:
	var e := Equipment.new()
	e.display_name = "Shield"
	e.slot = Slot.HAND
	e.hands = 1
	e.channel = Channel.NONE
	e.armor_phys = 2.0
	e.armor_mag = 1.0
	return e

# Armor sets (head / chest / boots; per-piece phys / mag) ---------------------
# Each set totals the same defensive budget, split differently along the phys↔mag axis:
# Cloth Σ5/9, Leather Σ6/8, Chainmail Σ8/6, Plate Σ9/5. See docs/EQUIPMENT.md.

static func cloth_head() -> Equipment:    return _armor("Cloth Hood", Slot.HEAD, 1.0, 3.0, &"cloth")
static func cloth_chest() -> Equipment:   return _armor("Cloth Robe", Slot.CHEST, 3.0, 4.0, &"cloth")
static func cloth_boots() -> Equipment:   return _armor("Cloth Shoes", Slot.BOOTS, 1.0, 2.0, &"cloth")
static func cloth_set() -> Array[Equipment]:
	return [cloth_head(), cloth_chest(), cloth_boots()]

static func leather_head() -> Equipment:  return _armor("Leather Cap", Slot.HEAD, 2.0, 2.0, &"leather")
static func leather_chest() -> Equipment: return _armor("Leather Vest", Slot.CHEST, 3.0, 4.0, &"leather")
static func leather_boots() -> Equipment: return _armor("Leather Boots", Slot.BOOTS, 1.0, 2.0, &"leather")
static func leather_set() -> Array[Equipment]:
	return [leather_head(), leather_chest(), leather_boots()]

static func chainmail_head() -> Equipment:  return _armor("Chain Coif", Slot.HEAD, 2.0, 2.0, &"chainmail")
static func chainmail_chest() -> Equipment: return _armor("Chain Hauberk", Slot.CHEST, 4.0, 3.0, &"chainmail")
static func chainmail_boots() -> Equipment: return _armor("Chain Greaves", Slot.BOOTS, 2.0, 1.0, &"chainmail")
static func chainmail_set() -> Array[Equipment]:
	return [chainmail_head(), chainmail_chest(), chainmail_boots()]

static func plate_head() -> Equipment:    return _armor("Plate Helm", Slot.HEAD, 3.0, 2.0, &"plate")
static func plate_chest() -> Equipment:   return _armor("Plate Cuirass", Slot.CHEST, 4.0, 2.0, &"plate")
static func plate_boots() -> Equipment:   return _armor("Plate Sabatons", Slot.BOOTS, 2.0, 1.0, &"plate")
static func plate_set() -> Array[Equipment]:
	return [plate_head(), plate_chest(), plate_boots()]
