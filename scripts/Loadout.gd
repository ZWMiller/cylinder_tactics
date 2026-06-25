## The pre-battle equipment menu (the scene the game boots into). The player gears up each party
## member here, then "Begin Battle" loads `Main.tscn` carrying the choices through the `PartyLoadout`
## autoload. A learning-project note for the Python/C++ mind: this is a screen-space UI built entirely
## from Godot `Control` nodes (anchors + containers), the 2D cousin of the 3D `Node3D` battle scene.
##
## Layout (mirrors the brief):
##   - TOP third  — the active character: a portrait frame, name/class/level, and a stat grid. When a
##                  weapon/armor is highlighted in the inventory, each stat shows a live "+N/-N" of the
##                  change it WOULD make (computed, then rolled back — the unit isn't actually changed
##                  until you confirm).
##   - BOTTOM-LEFT  — the five equip slots (main hand, off hand, head, chest, boots).
##   - BOTTOM-RIGHT — the inventory: filtered to the selected slot's valid items while editing, or the
##                    whole catalog while browsing (Tab).
##
## Controls: ↑/↓ move within the active panel; Enter selects a slot / equips the highlighted item;
## Esc backs out of the inventory; Tab switches which bottom panel is active (browse the catalog
## without changing gear); Q/E switch character; B (or the button) begins the battle (after a Yes/No
## confirm). Character switching is blocked while a slot is mid-edit, so the live-preview snapshot
## can't be stranded on a unit you've navigated away from.
##
## HOW STATS ARE COMPUTED WITHOUT DUPLICATION: this scene spawns one real (but invisible — no camera
## in this scene) `Unit` per member and drives its actual `equip_to_slot`/`recompute_stats`. So every
## number shown comes from the SAME code the battle uses (`Unit` stats, `CombatResolver.offense`,
## `Equipment.set_bonus`) — the menu never re-implements the math, it just reads it.
extends Control

## Where "Begin Battle" goes.
const BATTLE_SCENE := "res://scenes/Main.tscn"

## The five equip mounts in display order, paired with their row labels. The enum values come from
## `Unit.LoadoutSlot` (the combat code's own slot vocabulary) so selecting "Off Hand" here maps
## straight onto `Unit.equip_to_slot(item, Unit.LoadoutSlot.OFF_HAND)`.
const SLOTS: Array[int] = [
	Unit.LoadoutSlot.MAIN_HAND, Unit.LoadoutSlot.OFF_HAND,
	Unit.LoadoutSlot.HEAD, Unit.LoadoutSlot.CHEST, Unit.LoadoutSlot.BOOTS,
]
const SLOT_NAMES: Array[String] = ["Main Hand", "Off Hand", "Head", "Chest", "Boots"]

## The numeric stat rows, as [derive-key, display label]. Split into two visual columns (like the FFT
## character sheet). The derive-keys index the dict `_derive` returns; ARMOR is listed here for layout
## but formats its value specially (two channels). SET BONUS is a checkbox handled outside this list.
const _LEFT_STATS: Array = [
	["HP", "HP"], ["MP", "MP"],
	["PATK", "PHY ATK"], ["MATK", "MAG ATK"],
	["PDEF", "PHY DEF"], ["MDEF", "MAG DEF"], ["EVA", "EVA"],
]
const _RIGHT_STATS: Array = [
	["MOV", "MOVE"], ["JMP", "JUMP"], ["SPD", "SPEED"],
	["ATKPOW", "ATTACK POWER"], ["MAGPOW", "MAGIC POWER"],
	["ARMOR", "TOTAL ARMOR"],
]

# --- Chrome (matched to the battle HUD so the two read as one game) ----------
const _BG_COLOR := Color(0.10, 0.11, 0.15)         ## Dark slate backdrop (not pure black, per brief).
const _PANEL_COLOR := Color(0.0, 0.0, 0.0, 0.5)    ## Translucent panel fill, same as the battle menu.
const _PANEL_BORDER := Color(0.35, 0.38, 0.48)     ## Idle panel border.
const _PANEL_BORDER_ACTIVE := Color(1.0, 0.85, 0.4) ## Active (focused) panel border — gold, like the menu highlight.
const _TEXT := Color(0.86, 0.86, 0.90)             ## Normal text.
const _TITLE := Color(0.96, 0.96, 1.0)             ## Headings.
const _DIM := Color(0.55, 0.55, 0.6)               ## Greyed / disabled rows.
const _HIGHLIGHT := Color(1.0, 0.9, 0.4)           ## Highlighted row (cursor).
const _EQUIPPED := Color(0.55, 0.85, 1.0)          ## An inventory item already worn in the slot.
const _GAIN := Color(0.5, 1.0, 0.55)               ## Positive stat delta.
const _LOSS := Color(1.0, 0.55, 0.5)               ## Negative stat delta.

## Which bottom panel currently takes the cursor.
enum Focus { EQUIP, INVENTORY }

# --- State -------------------------------------------------------------------

## One invisible `Unit` per party member (index-aligned with `PartyLoadout.party`), used purely to
## hold and compute equipment/stats. Built in `_ready`, never rendered.
var _units: Array[Unit] = []

## Which party member is being viewed/edited (index into `PartyLoadout.party` and `_units`).
var _member: int = 0

## Which bottom panel has the cursor, and — when it's the inventory — whether we're EDITING a chosen
## slot (filtered list, live preview, Enter equips) or just BROWSING the whole catalog (Tab, no change).
var _focus: Focus = Focus.EQUIP
var _editing: bool = false

## The highlighted equip slot (index into SLOTS) and, while editing, the slot the inventory is filling.
var _slot_index: int = 0
var _selected_slot: int = 0

## The inventory list currently shown (each entry an `Equipment`, or null for the "(Empty)" unequip
## row that leads the list in edit mode) and the highlighted row index.
var _inv_items: Array = []
var _inv_index: int = 0

## True while the "Proceed to battle?" confirm overlay is up — gates the menu's own key handling so
## only the overlay's Yes/No responds.
var _confirming: bool = false

# --- Node references resolved in _ready (the bits we update as state changes) -
var _name_label: Label
var _class_label: Label
var _val: Dictionary = {}            ## stat key -> the value Label
var _dlt: Dictionary = {}            ## stat key -> the delta Label
var _set_check: CheckBox             ## SET BONUS checkbox (text = the set + its bonus)
var _slot_labels: Array[Label] = []  ## the five equip-slot rows
var _equip_panel: PanelContainer
var _inv_panel: PanelContainer
var _inv_vbox: VBoxContainer
var _inv_scroll: ScrollContainer
var _inv_rows: Array[Label] = []     ## current inventory row Labels (rebuilt on every list change)
var _hint_label: Label               ## shown in the inventory panel before a slot/browse is chosen
var _confirm_overlay: Control        ## the Yes/No "proceed to battle" modal


## Build the UI, spawn the (hidden) stat units, and show the first member. A parent's `_ready` runs
## after children's, but this scene authors nothing in the .tscn, so there's no ordering subtlety.
func _ready() -> void:
	# Guarantee every member has a stored loadout (seeded from their class default) BEFORE the menu
	# shows anything — so a character the player never touches still fights in default gear and the
	# slots open populated rather than empty. Idempotent; only seeds members not already set.
	PartyLoadout.ensure_seeded()

	_build_ui()
	_spawn_stat_units()
	_show_member(0)


# --- Stat units (invisible compute-only units) -------------------------------

## Spawn one `Unit` per party member to hold equipment and compute stats, applying each member's
## stored loadout. They're parented into the tree (so `init_from_recruit` runs its full path) but
## hidden — and with no Camera3D in this scene they wouldn't render anyway. The menu manipulates
## these and reads their numbers; on confirm it copies the result back into `PartyLoadout`.
func _spawn_stat_units() -> void:
	var holder := Node.new()
	holder.name = "StatUnits"
	add_child(holder)
	for entry in PartyLoadout.party:
		var recruit: Recruit = entry["recruit"]
		var unit: Unit = PartyLoadout.UNIT_SCENE.instantiate()
		unit.allegiance = Unit.Allegiance.PLAYER
		unit.visible = false
		holder.add_child(unit)              # fires Unit._ready (appearance + baseline)
		unit.init_from_recruit(recruit)     # real class/level/aptitude → max_stats + default kit
		PartyLoadout.apply_to(unit, recruit) # overlay the stored loadout (== default on first run)
		_units.append(unit)


## The unit backing the member currently on screen.
func _current_unit() -> Unit:
	return _units[_member]


## The recruit (the persistence key) for the member currently on screen.
func _current_recruit() -> Recruit:
	return PartyLoadout.party[_member]["recruit"]


# --- Input -------------------------------------------------------------------

## Keyboard handling for the whole menu (mouse uses the per-control signals wired in `_build_ui`).
## Raw keycodes (not input-map actions) because Q/E/Tab/B aren't standard UI actions; using raw keys
## for all of them keeps the scheme in one readable place. While the battle-confirm overlay is up,
## only its Yes/No answers are accepted.
func _input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	# Cache the viewport up front and bail if it's already gone: confirming Yes changes scenes, after
	# which this (being-freed) node may still receive a queued event with no viewport — so never call
	# get_viewport() again after a handler that might have left for the battle.
	var vp := get_viewport()
	if vp == null:
		return
	if _confirming:
		match event.keycode:
			KEY_ENTER, KEY_KP_ENTER, KEY_Y:
				vp.set_input_as_handled()   # mark handled BEFORE the scene change (vp is freed after)
				_on_confirm_yes()
			KEY_ESCAPE, KEY_N:
				_on_confirm_no()
				vp.set_input_as_handled()
		return
	match event.keycode:
		KEY_Q: _change_member(-1)
		KEY_E: _change_member(1)
		KEY_TAB: _toggle_panel()
		KEY_B: _begin_battle()
		KEY_UP: _move_cursor(-1)
		KEY_DOWN: _move_cursor(1)
		KEY_ENTER, KEY_KP_ENTER: _confirm()
		KEY_ESCAPE: _cancel()
		_: return   # leave anything else for default handling
	vp.set_input_as_handled()


## Move the cursor in whichever panel is active (wrapping). In the inventory while editing, each move
## refreshes the live stat preview; the highlighted row is scrolled into view.
func _move_cursor(dir: int) -> void:
	if _focus == Focus.EQUIP:
		_slot_index = wrapi(_slot_index + dir, 0, SLOTS.size())
		_refresh_slots()
	elif not _inv_items.is_empty():
		_inv_index = wrapi(_inv_index + dir, 0, _inv_items.size())
		_refresh_inventory_rows()
		_scroll_to_inv_row()
		_refresh_preview()


## Enter: from the equip panel, pick the highlighted slot (open the filtered inventory for it); from
## the inventory while editing, equip the highlighted item. Browsing, Enter does nothing (view-only).
func _confirm() -> void:
	if _focus == Focus.EQUIP:
		_enter_slot_edit(_slot_index)
	elif _editing:
		_equip_highlighted()


## Esc: back out of the inventory to the equip panel without changing anything.
func _cancel() -> void:
	if _focus == Focus.INVENTORY:
		_back_to_equip()


## Tab: toggle the active bottom panel. From the equip slots it opens the whole-catalog BROWSE view
## (look without changing); from the inventory it returns to the slots.
func _toggle_panel() -> void:
	if _focus == Focus.EQUIP:
		_enter_browse()
	else:
		_back_to_equip()


# --- Slot / inventory flow ---------------------------------------------------

## Open the inventory in EDIT mode for `slot_index`: filter to that slot's valid items (with an
## "(Empty)" unequip row first), highlight the currently-worn item, and start previewing.
func _enter_slot_edit(slot_index: int) -> void:
	_slot_index = slot_index
	_selected_slot = slot_index
	_editing = true
	_focus = Focus.INVENTORY
	_build_items_for_slot(slot_index)
	_inv_index = _index_of_worn_item()
	_refresh_inventory_rows()
	_refresh_panels()
	_scroll_to_inv_row()
	_refresh_preview()


## Open the inventory in BROWSE mode: the entire catalog, no preview, no equipping — just looking.
func _enter_browse() -> void:
	_editing = false
	_focus = Focus.INVENTORY
	_inv_items = []
	_inv_items.assign(PartyLoadout.inventory())   # full catalog, no "(Empty)" row
	_inv_index = 0
	_refresh_inventory_rows()
	_refresh_panels()
	_scroll_to_inv_row()
	_refresh_stats()   # browse shows the unit's real stats, no deltas


## Return focus to the equip slots, dropping any preview.
func _back_to_equip() -> void:
	_focus = Focus.EQUIP
	_editing = false
	_refresh_inventory_rows()   # de-highlight the list
	_refresh_panels()
	_refresh_stats()


## Equip the highlighted inventory item into the slot being edited, then persist and return to the
## slots. The "(Empty)" row (null) unequips. An item the unit can't wield is refused (it's greyed).
func _equip_highlighted() -> void:
	var item: Equipment = _inv_items[_inv_index]
	var unit := _current_unit()
	if item == null:
		unit.clear_slot(SLOTS[_selected_slot])
	elif unit.can_equip(item):
		unit.equip_to_slot(item, SLOTS[_selected_slot])
	else:
		return   # requirements unmet — leave the menu in edit mode so the player can pick another
	# Persist the new loadout so it survives the scene change into battle.
	PartyLoadout.capture_from(_current_recruit(), unit)
	_back_to_equip()
	_refresh_slots()


## Build `_inv_items` for a slot: an "(Empty)" unequip option (null) followed by every catalog item
## valid for that slot. "Valid" = matching `Equipment.Slot`, plus off-hand excludes two-handers
## (they can't be an off-hand). Wieldability (stat requirements) is NOT filtered here — unusable items
## still show, greyed (see `_refresh_inventory_rows`).
func _build_items_for_slot(slot_index: int) -> void:
	var slot: int = SLOTS[slot_index]
	_inv_items = [null]   # the "(Empty)" row leads the list
	for item in PartyLoadout.inventory():
		if _item_fits_slot(item, slot):
			_inv_items.append(item)


## Whether `item` can mount in `slot` (a `Unit.LoadoutSlot`). Hands take HAND items; the off hand
## additionally rejects two-handers; armor slots take their matching `Equipment.Slot`.
func _item_fits_slot(item: Equipment, slot: int) -> bool:
	match slot:
		Unit.LoadoutSlot.MAIN_HAND:
			return item.slot == Equipment.Slot.HAND
		Unit.LoadoutSlot.OFF_HAND:
			return item.slot == Equipment.Slot.HAND and item.hands == 1
		Unit.LoadoutSlot.HEAD:
			return item.slot == Equipment.Slot.HEAD
		Unit.LoadoutSlot.CHEST:
			return item.slot == Equipment.Slot.CHEST
		Unit.LoadoutSlot.BOOTS:
			return item.slot == Equipment.Slot.BOOTS
	return false


## Index in `_inv_items` of the item currently worn in the edited slot (matched by name, since a
## default-kit item and the catalog copy are different instances), or 0 (the "(Empty)" row) if the
## slot is bare or holds something not in this filtered list.
func _index_of_worn_item() -> int:
	var worn := _current_unit().item_in_slot(SLOTS[_selected_slot])
	if worn != null:
		for i in _inv_items.size():
			if _inv_items[i] != null and _inv_items[i].display_name == worn.display_name:
				return i
	return 0


# --- Member switching --------------------------------------------------------

## Switch to the previous/next party member (wrapping), resetting focus to the equip slots. BLOCKED
## while a slot is mid-edit (uncommitted): switching then would strand the preview snapshot/restore on
## a unit we've navigated away from. The player must equip (Enter) or cancel (Esc) first.
func _change_member(dir: int) -> void:
	if _editing:
		return
	_show_member(wrapi(_member + dir, 0, _units.size()))


## Show `index`'s character: reset to the equip panel and repaint the heading, slots, and stats.
func _show_member(index: int) -> void:
	_member = index
	_focus = Focus.EQUIP
	_editing = false
	_inv_items = []
	_refresh_member_heading()
	_refresh_slots()
	_refresh_inventory_rows()
	_refresh_panels()
	_refresh_stats()


# --- Begin battle (with confirm) ---------------------------------------------

## "Begin Battle" (button or B): raise the Yes/No confirm overlay. The actual scene change only
## happens on Yes (`_on_confirm_yes`); No dismisses it back to the menu.
func _begin_battle() -> void:
	if _confirming:
		return
	_confirming = true
	_confirm_overlay.visible = true


## Confirmed → launch the battle, carrying the loadouts via the `PartyLoadout` autoload (which
## survives the scene change). Everything chosen here is already captured in `PartyLoadout`.
func _on_confirm_yes() -> void:
	get_tree().change_scene_to_file(BATTLE_SCENE)


## Declined → hide the overlay and return to the menu unchanged.
func _on_confirm_no() -> void:
	_confirming = false
	_confirm_overlay.visible = false


# --- Rendering: heading + stats ----------------------------------------------

## Repaint the name + class/level heading for the current member.
func _refresh_member_heading() -> void:
	var unit := _current_unit()
	_name_label.text = unit.display_name()
	_class_label.text = "%s   Lv %d" % [UnitClasses.display_name(unit.unit_class), unit.level]


## Repaint the whole stat grid. With no argument it shows the unit's real stats; while editing the
## inventory, `_refresh_preview` calls this with the hypothetical stats so each row can show a delta.
func _refresh_stats(preview: Dictionary = {}) -> void:
	var current := _derive(_current_unit())
	var previewing := not preview.is_empty()

	# The plain numeric rows: value is always the unit's CURRENT number; the delta column shows the
	# change the highlighted item WOULD make (per the brief: "show beside them a +N or -N").
	for key in ["HP", "MP", "PATK", "MATK", "PDEF", "MDEF", "EVA", "MOV", "JMP", "SPD", "ATKPOW", "MAGPOW"]:
		_val[key].text = str(current[key])
		_set_delta(_dlt[key], (preview[key] - current[key]) if previewing else 0)

	# TOTAL ARMOR is two channels (phys/mag); show "P/M" and a per-channel delta, each colored on its
	# OWN sign (a piece can raise phys while lowering mag — they shouldn't share one color).
	_val["ARMOR"].text = "%d/%d" % [current["ARM_P"], current["ARM_M"]]
	if previewing and (preview["ARM_P"] != current["ARM_P"] or preview["ARM_M"] != current["ARM_M"]):
		var dp: int = preview["ARM_P"] - current["ARM_P"]
		var dm: int = preview["ARM_M"] - current["ARM_M"]
		_dlt["ARMOR"].text = "%s/%s" % [_delta_chip(dp), _delta_chip(dm)]
	else:
		_dlt["ARMOR"].text = ""

	# SET BONUS: the checkbox reflects the would-be state while previewing, else the current one, and
	# its text describes the active set's bonus (reusing the global Equipment.set_bonus values).
	var shown_set: StringName = preview["SET"] if previewing else current["SET"]
	_set_check.button_pressed = shown_set != &""
	_set_check.text = _set_bonus_text(shown_set)
	# Tint the checkbox text when a hovered item would turn a set on or off.
	var changed: bool = previewing and preview["SET"] != current["SET"]
	_set_check.add_theme_color_override("font_color", _HIGHLIGHT if changed else _TEXT)
	_set_check.add_theme_color_override("font_disabled_color", _HIGHLIGHT if changed else _TEXT)


## Recompute the preview after the highlighted inventory row changes (edit mode only): apply the
## hypothetical item to the unit, derive its stats, roll back, and show the deltas. Browsing or on the
## equip panel, there's nothing to preview — show the plain stats.
func _refresh_preview() -> void:
	if _focus == Focus.INVENTORY and _editing and not _inv_items.is_empty():
		_refresh_stats(_derive_if(_current_unit(), _selected_slot, _inv_items[_inv_index]))
	else:
		_refresh_stats()


## All the numbers the panel shows, pulled from the SAME code the battle uses: `Unit.max_stats`,
## `CombatResolver.offense` (ATTACK/MAGIC POWER), `Unit.armor_total`, `Unit.active_set_id`.
func _derive(unit: Unit) -> Dictionary:
	var s := unit.max_stats
	return {
		"HP": s.max_hp, "MP": s.max_mp,
		"PATK": s.phys_atk, "MATK": s.mag_atk,
		"PDEF": s.phys_def, "MDEF": s.mag_def, "EVA": s.evasion,
		"MOV": s.move, "JMP": s.jump, "SPD": s.speed,
		"ATKPOW": CombatResolver.offense(unit, true),
		"MAGPOW": CombatResolver.offense(unit, false),
		"ARM_P": int(unit.armor_total(true)), "ARM_M": int(unit.armor_total(false)),
		"SET": unit.active_set_id(),
	}


## Derive the stats `unit` WOULD have with `item` in `slot_index` (null = the slot emptied), WITHOUT
## permanently changing it: snapshot the five mounts, apply the hypothetical, derive, then restore.
## An item the unit can't wield leaves it unchanged, so the preview equals the current stats (delta 0).
func _derive_if(unit: Unit, slot_index: int, item: Equipment) -> Dictionary:
	var snap := _snapshot(unit)
	if item == null:
		unit.clear_slot(SLOTS[slot_index])
	elif unit.can_equip(item):
		unit.equip_to_slot(item, SLOTS[slot_index])
	var derived := _derive(unit)
	_restore(unit, snap)
	return derived


## Capture a unit's five mounts so a preview can be rolled back. Hands is a list (duplicate it);
## armor entries are immutable Equipment (store by reference).
func _snapshot(unit: Unit) -> Dictionary:
	return {"hands": unit.hands.duplicate(), "head": unit.armor_head, "chest": unit.armor_chest, "boots": unit.armor_boots}


## Restore a snapshot taken by `_snapshot` and recompute, undoing a hypothetical preview.
func _restore(unit: Unit, snap: Dictionary) -> void:
	unit.hands = (snap["hands"] as Array).duplicate()
	unit.armor_head = snap["head"]
	unit.armor_chest = snap["chest"]
	unit.armor_boots = snap["boots"]
	unit.recompute_stats()


## One BBCode-colored "+N"/"-N" chip for the (RichText) ARMOR delta — green for a gain, red for a
## loss, neutral for an unchanged channel — so each armor channel is colored on its own sign.
func _delta_chip(diff: int) -> String:
	var color: Color = _TEXT if diff == 0 else (_GAIN if diff > 0 else _LOSS)
	return "[color=#%s]%+d[/color]" % [color.to_html(false), diff]


## Write the delta Label: blank for no change, else "+N"/"-N" tinted green (gain) or red (loss).
func _set_delta(label: Label, diff: int) -> void:
	if diff == 0:
		label.text = ""
		return
	label.text = "%+d" % diff
	label.add_theme_color_override("font_color", _GAIN if diff > 0 else _LOSS)


## Human text for a set bonus: "<set> set: +1 MAG, +1 EVA", or "none" when no full set is worn. Reads
## the global `Equipment.set_bonus` (the same values the combat code folds in), so this never invents
## numbers. Only the non-zero fields are listed.
func _set_bonus_text(set_id: StringName) -> String:
	if set_id == &"":
		return "none"
	var bonus := Equipment.set_bonus(set_id)
	var parts: Array[String] = []
	if bonus != null:
		for pair in [["phys_atk", "PATK"], ["mag_atk", "MATK"], ["phys_def", "PDEF"], ["mag_def", "MDEF"],
				["evasion", "EVA"], ["max_hp", "HP"], ["max_mp", "MP"], ["move", "MOV"], ["jump", "JMP"], ["speed", "SPD"]]:
			var v: int = bonus.get(pair[0])
			if v != 0:
				parts.append("%+d %s" % [v, pair[1]])
	var label := str(set_id).capitalize()
	return "%s set: %s" % [label, ", ".join(parts)] if not parts.is_empty() else "%s set" % label


# --- Rendering: slots + inventory + panel focus ------------------------------

## Repaint the five equip-slot rows: each shows "<slot>: <item or (empty)>", with the cursor row
## highlighted while the equip panel is active.
func _refresh_slots() -> void:
	var unit := _current_unit()
	for i in _slot_labels.size():
		var item := unit.item_in_slot(SLOTS[i])
		var name_text := item.display_name if item != null else "(empty)"
		# Show the off hand as locked when a two-hander fills the main hand (it can't hold anything).
		if SLOTS[i] == Unit.LoadoutSlot.OFF_HAND and item == null and unit.hands[0] != null and unit.hands[0].hands >= 2:
			name_text = "— (two-handed)"
		var selected: bool = _focus == Focus.EQUIP and i == _slot_index
		_slot_labels[i].text = "%s %-9s  %s" % [">" if selected else " ", SLOT_NAMES[i] + ":", name_text]
		_slot_labels[i].add_theme_color_override("font_color", _HIGHLIGHT if selected else _TEXT)


## Rebuild the inventory rows from `_inv_items`. A leading "(Empty)" row (null) unequips; items the
## current unit can't wield are greyed; the worn item is tinted; the cursor row is highlighted while
## the inventory panel is active. The hint shows only when there's no list yet (fresh equip panel).
func _refresh_inventory_rows() -> void:
	for row in _inv_rows:
		row.queue_free()
	_inv_rows.clear()

	_hint_label.visible = _inv_items.is_empty()
	var unit := _current_unit()
	var active: bool = _focus == Focus.INVENTORY
	# While editing, what's currently worn in the slot (for the "already equipped" tint).
	var slot_item: Equipment = unit.item_in_slot(SLOTS[_selected_slot]) if _editing else null
	for i in _inv_items.size():
		var item: Equipment = _inv_items[i]
		var label := Label.new()
		label.add_theme_font_size_override("font_size", _INV_FONT)
		label.mouse_filter = Control.MOUSE_FILTER_STOP   # rows are clickable
		label.gui_input.connect(_on_inv_row_input.bind(i))

		var selected: bool = active and i == _inv_index
		var worn: bool = item != null and slot_item != null and item.display_name == slot_item.display_name
		var usable: bool = item == null or unit.can_equip(item)

		label.text = ("> " if selected else "  ") + _inv_row_text(item)
		var color := _TEXT
		if not usable:
			color = _DIM
		elif selected:
			color = _HIGHLIGHT
		elif worn:
			color = _EQUIPPED
		label.add_theme_color_override("font_color", color)
		_inv_vbox.add_child(label)
		_inv_rows.append(label)


## One inventory row's text: the "(Empty)" unequip option, or an item's name plus a compact stat —
## a weapon's channel × power, or a piece's armor phys/mag.
func _inv_row_text(item: Equipment) -> String:
	if item == null:
		return "(Empty)"
	var detail := ""
	if item.channel == Equipment.Channel.PHYSICAL:
		detail = "PHY x%.2f" % item.power
	elif item.channel == Equipment.Channel.MAGICAL:
		detail = "MAG x%.2f" % item.power
	else:
		detail = "ARM %d/%d" % [int(item.armor_phys), int(item.armor_mag)]
	return "%-16s %s" % [item.display_name, detail]


## Scroll the inventory so the highlighted row is visible (no-op when browsing a short list).
func _scroll_to_inv_row() -> void:
	if _inv_index >= 0 and _inv_index < _inv_rows.size():
		_inv_scroll.ensure_control_visible(_inv_rows[_inv_index])


## Repaint the two bottom panels' focus state: the active one gets a gold border + bright title.
func _refresh_panels() -> void:
	_set_panel_active(_equip_panel, _focus == Focus.EQUIP)
	_set_panel_active(_inv_panel, _focus == Focus.INVENTORY)


## Swap a panel's border style to mark it active/idle (a fresh StyleBox so the two panels differ).
func _set_panel_active(panel: PanelContainer, active: bool) -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = _PANEL_COLOR
	style.set_corner_radius_all(8)
	style.set_content_margin_all(18)
	style.set_border_width_all(3 if active else 1)
	style.border_color = _PANEL_BORDER_ACTIVE if active else _PANEL_BORDER
	panel.add_theme_stylebox_override("panel", style)


# --- Mouse handlers ----------------------------------------------------------

## Click a slot row → select it and open its inventory (same as Enter on the equip panel).
func _on_slot_input(event: InputEvent, slot_index: int) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_enter_slot_edit(slot_index)


## Click an inventory row → make the inventory active and highlight that row (previewing if editing);
## a double-click in edit mode equips it (mouse equivalent of Enter).
func _on_inv_row_input(event: InputEvent, row_index: int) -> void:
	if not (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT):
		return
	if _focus != Focus.INVENTORY:
		return   # rows only act once the inventory is the active panel (Tab or a slot opened it)
	_inv_index = row_index
	_refresh_inventory_rows()
	_refresh_preview()
	if _editing and event.double_click:
		_equip_highlighted()


## Click empty space in the inventory panel while on the equip side → open browse mode.
func _on_inv_panel_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if _focus == Focus.EQUIP:
			_enter_browse()


# --- UI construction ---------------------------------------------------------
# Font sizes pulled out so the menu retunes in one place; kept in step with the battle HUD (sized up
# so the text reads at a glance on large/high-DPI displays rather than as tiny rows).
const _STAT_FONT := 34
const _SLOT_FONT := 38
const _INV_FONT := 32
const _TITLE_FONT := 56
const _SUBTITLE_FONT := 40
const _HELP_FONT := 26


## Assemble the whole screen: backdrop, top character panel, bottom equip + inventory panels, the
## Begin Battle button, and the (hidden) confirm overlay. Stores references later refreshes update.
func _build_ui() -> void:
	var bg := ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = _BG_COLOR
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	_build_top_panel()
	_build_equip_panel()
	_build_inventory_panel()
	_build_begin_button()
	_build_confirm_overlay()   # added last so it draws on top of everything


## Anchor a control to a fractional rect of the screen with a uniform pixel margin — the layout
## primitive for the three big panels (top third, bottom-left half, bottom-right half).
func _anchor_frac(c: Control, l: float, t: float, r: float, b: float, margin: float) -> void:
	c.anchor_left = l
	c.anchor_top = t
	c.anchor_right = r
	c.anchor_bottom = b
	c.offset_left = margin
	c.offset_top = margin
	c.offset_right = -margin
	c.offset_bottom = -margin


## TOP THIRD: portrait frame + name/class/level + the two stat columns (with delta cells) + the
## SET BONUS checkbox.
func _build_top_panel() -> void:
	var panel := PanelContainer.new()
	_anchor_frac(panel, 0.0, 0.0, 1.0, 0.34, 16.0)
	_style_panel(panel)
	add_child(panel)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 28)
	panel.add_child(row)

	# Portrait placeholder: a bordered square where the character art will go later.
	var portrait := Panel.new()
	portrait.custom_minimum_size = Vector2(240, 240)
	var pstyle := StyleBoxFlat.new()
	pstyle.bg_color = Color(0.0, 0.0, 0.0, 0.35)
	pstyle.set_border_width_all(2)
	pstyle.border_color = _PANEL_BORDER
	pstyle.set_corner_radius_all(6)
	portrait.add_theme_stylebox_override("panel", pstyle)
	var plabel := Label.new()
	plabel.text = "PORTRAIT"
	plabel.set_anchors_preset(Control.PRESET_CENTER)
	plabel.add_theme_color_override("font_color", _DIM)
	portrait.add_child(plabel)
	row.add_child(portrait)

	# Identity + stats column.
	var info := VBoxContainer.new()
	info.add_theme_constant_override("separation", 6)
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(info)

	_name_label = Label.new()
	_name_label.add_theme_font_size_override("font_size", _TITLE_FONT)
	_name_label.add_theme_color_override("font_color", _TITLE)
	info.add_child(_name_label)

	_class_label = Label.new()
	_class_label.add_theme_font_size_override("font_size", _SUBTITLE_FONT)
	_class_label.add_theme_color_override("font_color", _TEXT)
	info.add_child(_class_label)

	# Two stat columns side by side, plus the set-bonus checkbox under them.
	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 48)
	info.add_child(cols)
	cols.add_child(_make_stat_grid(_LEFT_STATS))
	cols.add_child(_make_stat_grid(_RIGHT_STATS))

	_set_check = CheckBox.new()
	_set_check.disabled = true                       # display-only (state is driven in code)
	_set_check.focus_mode = Control.FOCUS_NONE
	_set_check.add_theme_font_size_override("font_size", _STAT_FONT)
	# A disabled CheckBox dims its text by default; force readable colors so the bonus stays legible.
	_set_check.add_theme_color_override("font_color", _TEXT)
	_set_check.add_theme_color_override("font_disabled_color", _TEXT)
	var set_row := HBoxContainer.new()
	set_row.add_theme_constant_override("separation", 10)
	var set_name := Label.new()
	set_name.text = "SET BONUS"
	set_name.add_theme_font_size_override("font_size", _STAT_FONT)
	set_name.add_theme_color_override("font_color", _TITLE)
	set_row.add_child(set_name)
	set_row.add_child(_set_check)
	info.add_child(set_row)


## Build one stat column as a GridContainer of [name, value, delta] rows, registering the value/delta
## Labels in `_val`/`_dlt` keyed by the derive-key so refreshes can find them.
func _make_stat_grid(defs: Array) -> GridContainer:
	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 16)
	grid.add_theme_constant_override("v_separation", 6)
	for def in defs:
		var key: String = def[0]
		var name_label := Label.new()
		name_label.text = def[1]
		name_label.add_theme_font_size_override("font_size", _STAT_FONT)
		name_label.add_theme_color_override("font_color", _TEXT)
		grid.add_child(name_label)

		var value_label := Label.new()
		value_label.add_theme_font_size_override("font_size", _STAT_FONT)
		value_label.add_theme_color_override("font_color", _TITLE)
		value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		value_label.custom_minimum_size = Vector2(100, 0)
		grid.add_child(value_label)
		_val[key] = value_label

		# ARMOR's delta carries two independently-colored channels (phys/mag), so it's a RichTextLabel
		# (BBCode color per part); every other stat's delta is a single-color plain Label.
		if key == "ARMOR":
			var armor_delta := RichTextLabel.new()
			armor_delta.bbcode_enabled = true
			armor_delta.fit_content = true
			armor_delta.scroll_active = false
			armor_delta.autowrap_mode = TextServer.AUTOWRAP_OFF
			armor_delta.add_theme_font_size_override("normal_font_size", _STAT_FONT)
			armor_delta.custom_minimum_size = Vector2(140, 0)
			grid.add_child(armor_delta)
			_dlt[key] = armor_delta
		else:
			var delta_label := Label.new()
			delta_label.add_theme_font_size_override("font_size", _STAT_FONT)
			delta_label.custom_minimum_size = Vector2(120, 0)
			grid.add_child(delta_label)
			_dlt[key] = delta_label
	return grid


## BOTTOM-LEFT: the "Equipment" panel listing the five mounts as selectable rows.
func _build_equip_panel() -> void:
	_equip_panel = PanelContainer.new()
	_anchor_frac(_equip_panel, 0.0, 0.34, 0.5, 1.0, 16.0)
	add_child(_equip_panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	_equip_panel.add_child(box)

	var title := Label.new()
	title.text = "EQUIPMENT"
	title.add_theme_font_size_override("font_size", _SUBTITLE_FONT)
	title.add_theme_color_override("font_color", _TITLE)
	box.add_child(title)

	for i in SLOT_NAMES.size():
		var label := Label.new()
		label.add_theme_font_size_override("font_size", _SLOT_FONT)
		label.mouse_filter = Control.MOUSE_FILTER_STOP
		label.gui_input.connect(_on_slot_input.bind(i))
		box.add_child(label)
		_slot_labels.append(label)

	var help := Label.new()
	help.text = "↑/↓ select   Enter: change   Tab: browse inventory   Q/E: character"
	help.add_theme_font_size_override("font_size", _HELP_FONT)
	help.add_theme_color_override("font_color", _DIM)
	box.add_child(help)


## BOTTOM-RIGHT: the scrollable inventory panel (filled by `_refresh_inventory_rows`).
func _build_inventory_panel() -> void:
	_inv_panel = PanelContainer.new()
	_anchor_frac(_inv_panel, 0.5, 0.34, 1.0, 1.0, 16.0)
	_inv_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_inv_panel.gui_input.connect(_on_inv_panel_input)
	add_child(_inv_panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	_inv_panel.add_child(box)

	var title := Label.new()
	title.text = "INVENTORY"
	title.add_theme_font_size_override("font_size", _SUBTITLE_FONT)
	title.add_theme_color_override("font_color", _TITLE)
	box.add_child(title)

	_hint_label = Label.new()
	_hint_label.text = "Select a slot to change it, or press Tab to browse all gear."
	_hint_label.add_theme_font_size_override("font_size", _HELP_FONT)
	_hint_label.add_theme_color_override("font_color", _DIM)
	box.add_child(_hint_label)

	_inv_scroll = ScrollContainer.new()
	_inv_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_inv_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(_inv_scroll)

	_inv_vbox = VBoxContainer.new()
	_inv_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_inv_vbox.add_theme_constant_override("separation", 4)
	_inv_scroll.add_child(_inv_vbox)


## The "Begin Battle" button + the prev/next character arrows, anchored along the top edge.
func _build_begin_button() -> void:
	var begin := Button.new()
	begin.text = "Begin Battle  ▶  (B)"
	begin.add_theme_font_size_override("font_size", _SUBTITLE_FONT)
	begin.anchor_left = 1.0
	begin.anchor_right = 1.0
	begin.offset_left = -500
	begin.offset_top = 28
	begin.offset_right = -36
	begin.offset_bottom = 104
	begin.pressed.connect(_begin_battle)
	add_child(begin)

	# Prev / next character arrows (mouse twins of Q / E), tucked under the Begin button.
	var prev := Button.new()
	prev.text = "◀ Q"
	prev.add_theme_font_size_override("font_size", _HELP_FONT)
	prev.anchor_left = 1.0
	prev.anchor_right = 1.0
	prev.offset_left = -500
	prev.offset_top = 120
	prev.offset_right = -280
	prev.offset_bottom = 176
	prev.pressed.connect(_change_member.bind(-1))
	add_child(prev)

	var next := Button.new()
	next.text = "E ▶"
	next.add_theme_font_size_override("font_size", _HELP_FONT)
	next.anchor_left = 1.0
	next.anchor_right = 1.0
	next.offset_left = -256
	next.offset_top = 120
	next.offset_right = -36
	next.offset_bottom = 176
	next.pressed.connect(_change_member.bind(1))
	add_child(next)


## The "Proceed to battle?" confirm overlay: a full-screen dimmer (blocking clicks behind it) with a
## centered Yes/No panel. Hidden until "Begin Battle" raises it. Yes launches the battle; No dismisses.
func _build_confirm_overlay() -> void:
	_confirm_overlay = Control.new()
	_confirm_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_confirm_overlay.mouse_filter = Control.MOUSE_FILTER_STOP   # swallow clicks meant for the menu behind
	_confirm_overlay.visible = false
	add_child(_confirm_overlay)

	var dim := ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0.0, 0.0, 0.0, 0.6)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_confirm_overlay.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_confirm_overlay.add_child(center)

	var panel := PanelContainer.new()
	_style_panel(panel)
	center.add_child(panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 20)
	panel.add_child(box)

	var prompt := Label.new()
	prompt.text = "Proceed to battle?"
	prompt.add_theme_font_size_override("font_size", _SUBTITLE_FONT)
	prompt.add_theme_color_override("font_color", _TITLE)
	prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(prompt)

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 24)
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_child(buttons)

	var yes := Button.new()
	yes.text = "Yes (Y)"
	yes.add_theme_font_size_override("font_size", _SUBTITLE_FONT)
	yes.custom_minimum_size = Vector2(160, 56)
	yes.pressed.connect(_on_confirm_yes)
	buttons.add_child(yes)

	var no := Button.new()
	no.text = "No (N)"
	no.add_theme_font_size_override("font_size", _SUBTITLE_FONT)
	no.custom_minimum_size = Vector2(160, 56)
	no.pressed.connect(_on_confirm_no)
	buttons.add_child(no)


## Apply the shared translucent panel chrome (the top panel uses this; the two bottom panels get
## their border styled by `_set_panel_active` for the focus indicator).
func _style_panel(panel: PanelContainer) -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = _PANEL_COLOR
	style.set_corner_radius_all(8)
	style.set_content_margin_all(18)
	style.set_border_width_all(1)
	style.border_color = _PANEL_BORDER
	panel.add_theme_stylebox_override("panel", style)
