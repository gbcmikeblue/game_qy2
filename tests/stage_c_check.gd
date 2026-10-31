extends Node

## 阶段 C 验收：物品 → 掉落 → 背包 → 装备 → 存档。
## 断言编号与 doc/阶段C-数据契约-评审稿.md §9 一致，每完成一步补一组。
## 当前覆盖「数据」组（1–3）。运行：
##   godot --headless --path <项目> res://tests/stage_c_check.tscn

const ITEMS_DIR := "res://data/items/items"
const LOOT_DIR := "res://data/items/loot"
const LOOT_SERVICE := preload("res://scripts/items/loot_service.gd")
const PLAYER_SCENE := preload("res://scenes/actors/player/player.tscn")

var _failures: Array[String] = []


## 掉落管线的假玩家：只需要位置与生死，不依赖真实角色场景。
class DummyTarget extends Node2D:
	var hp := 100

	func is_alive() -> bool:
		return hp > 0

	func take_damage(amount: int, _source: Node = null) -> bool:
		hp = maxi(0, hp - amount)
		return true

	func get_defense() -> float:
		return 0.0


func _ready() -> void:
	_test_registry_load()
	_test_slot_validation()
	_test_stack_normalization()
	_test_i18n_coverage()
	_test_inventory_stack()
	_test_inventory_capacity()
	_test_inventory_remove()
	_test_equipment_stats()
	_test_equipment_swap()
	_test_unequip_full_bag()
	_test_level_growth()
	_test_loot_determinism()
	_test_loot_chance()
	_test_loot_guaranteed()
	await _test_kill_to_inventory()
	await _test_equipment_affects_player()
	InventoryService.reset()
	_report()


# ---------------- 1. 数据：注册表载入 ----------------

func _test_registry_load() -> void:
	var files := _count_tres(ITEMS_DIR)
	_check(files > 0, "物品目录至少有 1 个 .tres（实际 %d）" % files)
	_check(ItemRegistry.item_count() == files,
			"物品全部载入且无跳过：文件 %d = 已载入 %d" % [files, ItemRegistry.item_count()])

	var seen := {}
	var duplicated := 0
	for item_id: StringName in ItemRegistry.items:
		if seen.has(item_id):
			duplicated += 1
		seen[item_id] = true
	_check(duplicated == 0, "物品 id 无重复（重复 %d）" % duplicated)

	var loot_files := _count_tres(LOOT_DIR)
	_check(ItemRegistry.loot_count() == loot_files,
			"掉落表全部载入：文件 %d = 已载入 %d" % [loot_files, ItemRegistry.loot_count()])

	var wolf := ItemRegistry.get_loot(&"wolf_basic")
	_check(wolf != null and wolf.id == &"wolf_basic", "按 id 能取到掉落表 wolf_basic")
	_check(ItemRegistry.get_loot(&"not_exist") == ItemRegistry.get_loot(&"default_basic"),
			"未知掉落表回落到 default_basic")


# ---------------- 2. 数据：槽位来自 classes.json ----------------

func _test_slot_validation() -> void:
	var slots := DataRegistry.get_class_slots(DataRegistry.default_class_id())
	_check(slots == ItemRegistry.slots, "ItemRegistry 的槽位取自 classes.json（%s）" % str(slots))
	_check(slots.size() == 5, "warrior 配置了 5 个槽位（实际 %d）" % slots.size())

	var bad_slot := 0
	var equipment_without_slot := 0
	var non_equipment_with_slot := 0
	for item_id: StringName in ItemRegistry.items:
		var item: ItemData = ItemRegistry.items[item_id]
		if item.is_equipment():
			if item.slot == &"":
				equipment_without_slot += 1
			elif not slots.has(String(item.slot)):
				bad_slot += 1
		elif not item.slot.is_empty():
			non_equipment_with_slot += 1
	_check(bad_slot == 0, "装备 slot 全部在职业槽位集合内（越界 %d）" % bad_slot)
	_check(equipment_without_slot == 0, "没有缺 slot 的装备（%d）" % equipment_without_slot)
	_check(non_equipment_with_slot == 0, "非装备没有误填 slot（%d）" % non_equipment_with_slot)

	# 反例：非法槽位必须被 validate 拒绝，而不是静默通过。
	var broken := ItemData.new()
	broken.id = &"test_broken"
	broken.name_key = "item.test_broken.name"
	broken.category = ItemData.Category.EQUIPMENT
	broken.slot = &"ring"
	_check(not broken.validate(slots).is_empty(), "非法槽位被 validate 拒绝")


# ---------------- 3. 数据：不可堆叠上限恒为 1 ----------------

func _test_stack_normalization() -> void:
	var sword := ItemRegistry.get_item(&"wep_rusty_sword")
	_check(sword != null and not sword.stackable and sword.effective_max_stack() == 1,
			"装备不可堆叠，上限恒为 1")

	var fang := ItemRegistry.get_item(&"mat_wolf_fang")
	_check(fang != null and fang.stackable and fang.effective_max_stack() == 99,
			"材料可堆叠，上限 99（实际 %d）" % (fang.effective_max_stack() if fang != null else -1))

	var fake := ItemData.new()
	fake.id = &"test_stack"
	fake.name_key = "item.test_stack.name"
	fake.stackable = false
	fake.max_stack = 50
	_check(fake.effective_max_stack() == 1, "stackable=false 时即使写了 50 也按 1 处理")


# ---------------- 4–6. 背包：堆叠 / 容量 / 移除 ----------------

func _test_inventory_stack() -> void:
	InventoryService.reset()
	_check(InventoryService.add_item(&"mat_wolf_fang", 3) == 3, "入包 3 个狼牙返回 3")
	_check(InventoryService.items.size() == 1 and InventoryService.count_of(&"mat_wolf_fang") == 3,
			"同类材料占 1 格、数量 3")
	_check(InventoryService.add_item(&"mat_wolf_fang", 2) == 2, "再加 2 个返回 2")
	_check(InventoryService.items.size() == 1 and InventoryService.count_of(&"mat_wolf_fang") == 5,
			"先补堆叠：仍 1 格、数量 5（实际 %d 格 / %d 个）"
					% [InventoryService.items.size(), InventoryService.count_of(&"mat_wolf_fang")])


func _test_inventory_capacity() -> void:
	InventoryService.reset()
	InventoryService.capacity = 1
	_check(InventoryService.add_item(&"wep_rusty_sword", 1) == 1, "第 1 格放下短剑")
	_check(InventoryService.add_item(&"shl_wooden", 1) == 0, "满包时返回实际入包 0")

	InventoryService.reset()
	InventoryService.capacity = 2
	var added := InventoryService.add_item(&"con_medkit", 150)
	_check(added == 150 and InventoryService.items.size() == 2,
			"超过堆叠上限自动开新格（入包 %d、占 %d 格）" % [added, InventoryService.items.size()])
	InventoryService.reset()


func _test_inventory_remove() -> void:
	InventoryService.reset()
	InventoryService.add_item(&"mat_wolf_fang", 2)
	_check(not InventoryService.remove_item(&"mat_wolf_fang", 3), "数量不足时移除返回 false")
	_check(InventoryService.count_of(&"mat_wolf_fang") == 2, "失败后数量不变（仍 2）")
	_check(InventoryService.remove_item(&"mat_wolf_fang", 2), "数量足够时移除成功")
	_check(InventoryService.items.is_empty(), "移除到 0 后不留空格")


# ---------------- 7–9. 装备：属性 / 换装 / 卸装 ----------------

func _test_equipment_stats() -> void:
	InventoryService.reset()
	InventoryService.add_item(&"wep_rusty_sword", 1)
	var before := InventoryService.stats()
	_check(InventoryService.equip(&"wep_rusty_sword"), "装备短剑成功")
	var after := InventoryService.stats()
	_check(is_equal_approx(float(after["attack"]) - float(before["attack"]), 4.0),
			"装备后攻击 +4（%.1f → %.1f）" % [float(before["attack"]), float(after["attack"])])
	_check(InventoryService.count_of(&"wep_rusty_sword") == 0, "装备后背包里少一件")


func _test_equipment_swap() -> void:
	InventoryService.reset()
	InventoryService.add_item(&"wep_rusty_sword", 1)
	InventoryService.add_item(&"wep_iron_axe", 1)
	InventoryService.equip(&"wep_rusty_sword")
	var slots_before := InventoryService.items.size()

	_check(InventoryService.equip(&"wep_iron_axe"), "换成铁斧成功")
	_check(InventoryService.equipped_in("weapon") == &"wep_iron_axe", "武器槽已换成铁斧")
	_check(InventoryService.count_of(&"wep_rusty_sword") == 1, "旧件回到背包")
	# 换装是「取新件 + 回旧件」，背包格数必须守恒（不可能因满包失败）。
	_check(InventoryService.items.size() == slots_before,
			"换装前后背包格数不变（%d → %d）" % [slots_before, InventoryService.items.size()])


func _test_unequip_full_bag() -> void:
	InventoryService.reset()
	InventoryService.add_item(&"shl_wooden", 1)
	InventoryService.equip(&"shl_wooden")
	InventoryService.capacity = 1
	InventoryService.add_item(&"con_medkit", 1)   # 占用唯一的格子

	_check(not InventoryService.unequip("shield"), "包满时卸装被拒绝")
	_check(InventoryService.equipped_in("shield") == &"shl_wooden", "拒绝后槽位保持原值")

	InventoryService.reset()
	InventoryService.capacity = 2
	InventoryService.add_item(&"shl_wooden", 1)
	InventoryService.equip(&"shl_wooden")
	_check(InventoryService.unequip("shield"), "有空位时卸装成功")
	_check(InventoryService.equipped_in("shield") == &"", "成功后槽位清空")
	_check(InventoryService.count_of(&"shl_wooden") == 1, "卸下后回到背包")
	InventoryService.reset()


# ---------------- 10. 成长：升级后属性上限增加 ----------------

func _test_level_growth() -> void:
	InventoryService.reset()
	var before := InventoryService.stats()
	var need := InventoryService.exp_to_next()
	_check(need > 0, "1 级升 2 级需要 %d 经验" % need)

	var ups := InventoryService.gain_exp(need)
	var after := InventoryService.stats()
	_check(ups == 1 and InventoryService.level == 2, "满经验升 1 级（当前 %d 级）" % InventoryService.level)
	_check(is_equal_approx(float(after["max_hp"]) - float(before["max_hp"]), 8.0),
			"升级后生命上限 +8（%.0f → %.0f）" % [float(before["max_hp"]), float(after["max_hp"])])
	_check(is_equal_approx(float(after["max_mp"]) - float(before["max_mp"]), 4.0),
			"升级后魔法上限 +4（%.0f → %.0f）" % [float(before["max_mp"]), float(after["max_mp"])])
	_check(InventoryService.exp < InventoryService.exp_to_next(), "溢出经验结转到下一级")


# ---------------- 11–13. 掉落表 ----------------

func _test_loot_determinism() -> void:
	var table := ItemRegistry.get_loot(&"wolf_basic")
	_check(table != null, "取到 wolf_basic 掉落表")
	if table == null:
		return
	var first := table.roll(_seeded(12345))
	var second := table.roll(_seeded(12345))
	_check(_roll_signature(first) == _roll_signature(second),
			"固定种子下掉落结果可复现（%s）" % _roll_signature(first))
	_check(not first["items"].is_empty(), "wolf_basic 至少掉一件（guaranteed）")


func _test_loot_chance() -> void:
	var never := LootTable.new()
	never.entries.append(_make_entry(&"con_medkit", 0.0, 1, 1))
	var always := LootTable.new()
	always.entries.append(_make_entry(&"con_medkit", 1.0, 1, 1))

	var rng := _seeded(7)
	var never_hits := 0
	var always_hits := 0
	for i in 50:
		if not never.roll(rng)["items"].is_empty():
			never_hits += 1
		if not always.roll(rng)["items"].is_empty():
			always_hits += 1
	_check(never_hits == 0, "chance=0 的条目永不掉落（命中 %d/50）" % never_hits)
	_check(always_hits == 50, "chance=1 的条目每次都掉（命中 %d/50）" % always_hits)


func _test_loot_guaranteed() -> void:
	var table := LootTable.new()
	table.rolls = 0
	table.guaranteed.append(_make_entry(&"mat_wolf_fang", 1.0, 2, 3))
	var rng := _seeded(99)
	var in_range := 0
	for i in 30:
		var qty := _qty_of(table.roll(rng)["items"], &"mat_wolf_fang")
		if qty >= 2 and qty <= 3:
			in_range += 1
	_check(in_range == 30, "guaranteed 每次必出且数量落在 [2,3]（%d/30）" % in_range)


# ---------------- 20. 集成：击杀 → 掉落 → 自动拾取 ----------------

func _test_kill_to_inventory() -> void:
	InventoryService.reset()
	var dummy := DummyTarget.new()
	add_child(dummy)
	# 用 player_provider 注入假玩家：这正是 Q04 重构留下的接缝。
	GameManager.player_provider = func() -> Node2D: return dummy

	var root := Node2D.new()
	add_child(root)
	var service: Node = LOOT_SERVICE.new()
	service.name = "TestLootService"
	service.seed_override = 2026
	service.entity_root = root
	add_child(service)

	var picked: Array = []
	var on_picked := func(_id: String, _qty: int) -> void: picked.append(true)
	EventBus.item_picked_up.connect(on_picked)

	var drops: int = service.settle("forest_wolf", Vector2.ZERO)
	_check(drops >= 1, "击杀森林狼至少生成 1 个掉落物（%d）" % drops)
	_check(InventoryService.gold >= 2 and InventoryService.gold <= 5,
			"金币按表入账（2–5，实际 %d）" % InventoryService.gold)
	_check(InventoryService.exp == 12, "经验按敌人配置入账（exp=%d）" % InventoryService.exp)

	# 假玩家就站在掉落点上，下一帧应自动拾取（保证掉落物必掉一件狼牙）。
	await get_tree().process_frame
	await get_tree().process_frame
	_check(InventoryService.count_of(&"mat_wolf_fang") >= 1,
			"靠近后自动拾取进背包（狼牙 %d）" % InventoryService.count_of(&"mat_wolf_fang"))
	_check(not picked.is_empty(), "拾取时广播 item_picked_up（%d 次）" % picked.size())

	GameManager.player_provider = Callable()
	if EventBus.item_picked_up.is_connected(on_picked):
		EventBus.item_picked_up.disconnect(on_picked)
	service.queue_free()
	root.queue_free()
	dummy.queue_free()


# ---------------- 21. 接线：装备与等级真正影响战斗 ----------------

func _test_equipment_affects_player() -> void:
	InventoryService.reset()
	InventoryService.add_item(&"wep_rusty_sword", 1)
	InventoryService.add_item(&"arm_leather", 1)

	var hero = PLAYER_SCENE.instantiate()
	add_child(hero)
	await get_tree().process_frame

	var base_attack: float = hero.attack
	var base_max_hp: int = hero.get_max_hp()
	_check(is_equal_approx(base_attack, float(InventoryService.stats()["attack"])),
			"玩家初始攻击取自已结算属性（%.1f）" % base_attack)

	# 1) 装备武器 → 攻击 +4，且伤害真的按新攻击算
	InventoryService.equip(&"wep_rusty_sword")
	_check(is_equal_approx(hero.attack - base_attack, 4.0),
			"装备武器后玩家攻击 +4（%.1f → %.1f）" % [base_attack, hero.attack])

	var dummy := DummyTarget.new()
	add_child(dummy)
	dummy.global_position = hero.global_position
	var expected := maxi(1, int(round(hero.attack - dummy.get_defense())))
	var hit := CombatService.strike(hero, dummy, {"attack": hero.attack, "max_range": 999.0})
	_check(int(hit["damage"]) == expected,
			"伤害按装备后的攻击结算（实际 %d，期望 %d）" % [int(hit["damage"]), expected])
	dummy.queue_free()

	# 2) 装备 +HP 的护甲 → 上限 +10，当前血量同步补齐（决策 D2）
	InventoryService.equip(&"arm_leather")
	_check(hero.get_max_hp() == base_max_hp + 10,
			"装备 +HP 后生命上限 +10（%d → %d）" % [base_max_hp, hero.get_max_hp()])
	_check(hero.get_hp() == hero.get_max_hp(),
			"上限增加时当前血量同步补齐（%d/%d）" % [hero.get_hp(), hero.get_max_hp()])

	# 3) 升级 → 上限再 +8
	var ups := InventoryService.gain_exp(InventoryService.exp_to_next())
	_check(ups == 1, "升到 2 级")
	_check(hero.get_max_hp() == base_max_hp + 10 + 8,
			"升级后生命上限再 +8（当前 %d）" % hero.get_max_hp())
	_check(hero.get_hp() == hero.get_max_hp(), "升级同样补齐当前血量")

	# 4) 卸装 → 上限回落，当前血量被夹紧而不是变成负数/溢出
	InventoryService.unequip("armor")
	_check(hero.get_max_hp() == base_max_hp + 8, "卸下护甲后上限回落 10")
	_check(hero.get_hp() <= hero.get_max_hp(), "上限回落后当前血量被夹紧（%d/%d）"
			% [hero.get_hp(), hero.get_max_hp()])

	remove_child(hero)
	hero.queue_free()
	InventoryService.reset()


func _make_entry(item_id: StringName, chance: float, low: int, high: int) -> LootEntry:
	var entry := LootEntry.new()
	entry.item = ItemRegistry.get_item(item_id)
	entry.chance = chance
	entry.min_qty = low
	entry.max_qty = high
	return entry


func _seeded(value: int) -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	rng.seed = value
	return rng


func _roll_signature(result: Dictionary) -> String:
	var parts: Array[String] = []
	for entry: Dictionary in result["items"]:
		parts.append("%s×%d" % [entry["id"], int(entry["qty"])])
	parts.sort()
	return "%s|g%d" % [",".join(parts), int(result["gold"])]


func _qty_of(entries: Array, item_id: StringName) -> int:
	for entry: Dictionary in entries:
		if entry["id"] == item_id:
			return int(entry["qty"])
	return 0


# ---------------- 附加：文案覆盖（中英都要有） ----------------

func _test_i18n_coverage() -> void:
	var original: String = Locale.current
	var missing := 0
	for lang: String in ["zh", "en"]:
		Locale.set_language(lang)
		for item_id: StringName in ItemRegistry.items:
			var item: ItemData = ItemRegistry.items[item_id]
			if not Locale.has_key(item.name_key):
				missing += 1
			if not item.desc_key.is_empty() and not Locale.has_key(item.desc_key):
				missing += 1
	Locale.set_language(original)
	_check(missing == 0, "所有物品的 name/desc 在中英文案表里都有（缺失 %d）" % missing)


# ---------------- 辅助 ----------------

func _count_tres(dir_path: String) -> int:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return 0
	var total := 0
	for file_name: String in dir.get_files():
		if file_name.ends_with(".tres"):
			total += 1
	return total


func _check(condition: bool, message: String) -> void:
	if condition:
		print("[PASS] ", message)
	else:
		_failures.append(message)
		print("[FAIL] ", message)


func _report() -> void:
	print("---------- 阶段 C 验收 ----------")
	if _failures.is_empty():
		print("结果：全部通过")
		get_tree().quit(0)
	else:
		print("结果：%d 项失败" % _failures.size())
		for failure: String in _failures:
			print("  - ", failure)
		get_tree().quit(1)
