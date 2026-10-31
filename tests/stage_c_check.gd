extends Node

## 阶段 C 验收：物品 → 掉落 → 背包 → 装备 → 存档。
## 断言编号与 doc/阶段C-数据契约-评审稿.md §9 一致，每完成一步补一组。
## 当前覆盖「数据」组（1–3）。运行：
##   godot --headless --path <项目> res://tests/stage_c_check.tscn

const ITEMS_DIR := "res://data/items/items"
const LOOT_DIR := "res://data/items/loot"
const LOOT_SERVICE := preload("res://scripts/items/loot_service.gd")
const PLAYER_SCENE := preload("res://scenes/actors/player/player.tscn")
const MAIN_MENU := preload("res://scenes/ui/main_menu.tscn")
const GAME_SCENE := preload("res://scenes/boot/main.tscn")
const INVENTORY_PANEL := preload("res://scenes/ui/inventory_panel.tscn")

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
	# 验收不写用户的自动存档：本文件里会升级、会装备，会触发 level_changed 自动存档。
	SaveService.autosave_enabled = false
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
	await _test_inventory_panel()
	await _test_shop()
	await _test_save()
	await _test_save_panel()
	await _test_main_menu()
	await _test_multi_map()
	await _test_portals()
	await _test_npc()
	SaveService.autosave_enabled = true
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


# ---------------- 24. UI：背包/装备面板可操作 ----------------

func _test_inventory_panel() -> void:
	InventoryService.reset()
	InventoryService.add_item(&"wep_rusty_sword", 1)
	InventoryService.add_item(&"con_medkit", 2)

	var panel = INVENTORY_PANEL.instantiate()
	add_child(panel)
	await get_tree().process_frame

	_check(panel.current_tab() == 0, "面板默认停在背包页签")
	_check(panel.bag_row_count() == 2, "背包行数 = 物品种类数（%d）" % panel.bag_row_count())

	# 点击第 1 行（武器）→ 装备，行数减一
	_check(panel.press_bag_row(0), "点击背包行返回成功")
	_check(InventoryService.equipped_in("weapon") == &"wep_rusty_sword", "点击武器行后已装备")
	_check(panel.bag_row_count() == 1, "装备后背包少一行（%d）" % panel.bag_row_count())

	# 切到装备页并卸下
	panel.switch_tab_to(1)
	_check(panel.current_tab() == 1, "可以切到装备页签")
	panel.press_unequip("weapon")
	_check(InventoryService.equipped_in("weapon") == &"", "装备页卸下成功")
	_check(panel.bag_row_count() == 2, "卸下后物品回到背包（%d 行）" % panel.bag_row_count())

	# 使用消耗品：先扣血才能验证回血
	var hero = PLAYER_SCENE.instantiate()
	add_child(hero)
	# 面板通过 GameManager.get_player() 找玩家，这里显式登记。
	GameManager.player = hero
	await get_tree().process_frame
	hero.take_damage(50)
	var hp_before: int = hero.get_hp()
	panel.switch_tab_to(0)
	# 按 id 找行，不假设列表顺序（装备/卸下会改变顺序）。
	var medkit_index := -1
	for i in panel.bag_row_count():
		if panel.bag_row_item_id(i) == &"con_medkit":
			medkit_index = i
			break
	_check(medkit_index >= 0, "能在列表里定位到医疗包")
	panel.press_bag_row(medkit_index)
	_check(InventoryService.count_of(&"con_medkit") == 1, "使用医疗包后数量减 1")
	_check(hero.get_hp() > hp_before, "使用医疗包后回血（%d → %d）" % [hp_before, hero.get_hp()])

	GameManager.player = null
	remove_child(hero)
	hero.queue_free()
	panel.close_panel()
	await get_tree().process_frame
	InventoryService.reset()


# ---------------- 18–19. 商店：买入 / 卖出 / 金币不足 / 包满 ----------------

func _test_shop() -> void:
	InventoryService.reset()
	var panel = INVENTORY_PANEL.instantiate()
	add_child(panel)
	await get_tree().process_frame
	panel.switch_tab_to(2)
	_check(panel.current_tab() == 2, "可以切到商店页签")

	var shop := ItemRegistry.default_shop()
	_check(shop != null and not shop.stock.is_empty(), "存在默认商店且货架非空")
	if shop == null or shop.stock.is_empty():
		panel.close_panel()
		return
	_check(panel.shop_buy_row_count() == shop.stock.size(),
			"买入列行数 = 货架商品数（%d / %d）" % [panel.shop_buy_row_count(), shop.stock.size()])

	# panel 是 Node（instantiate 返回类型未知），必须显式标注，否则 Variant 推断会被当错误。
	var first_id: StringName = panel.buy_row_item_id(0)
	var def := ItemRegistry.get_item(first_id)

	# 1) 金币不足：金币与背包都不变，并给出提示
	InventoryService.gold = 0
	var count_before := InventoryService.count_of(first_id)
	panel.press_buy_row(0)
	_check(InventoryService.gold == 0 and InventoryService.count_of(first_id) == count_before,
			"金币不足时买入不改动金币与背包")
	_check(panel.hint_text() == Locale.t("inv.coins_not_enough"), "提示「金币不足」")

	# 2) 金币刚好够：扣钱 + 入包
	InventoryService.gold = def.value
	panel.press_buy_row(0)
	_check(InventoryService.gold == 0, "买入后扣掉对应金币（余 %d）" % InventoryService.gold)
	_check(InventoryService.count_of(first_id) == count_before + 1, "买入后物品进背包")

	# 3) 卖出：半价加金币、物品减少
	var price := InventoryService.sell_price(first_id)
	var sell_index := -1
	for i in panel.shop_sell_row_count():
		if panel.sell_row_item_id(i) == first_id:
			sell_index = i
			break
	_check(sell_index >= 0, "卖出列能定位到刚买入的物品")
	panel.press_sell_row(sell_index)
	_check(InventoryService.gold == price, "卖出按半价加金币（+%d）" % price)
	_check(InventoryService.count_of(first_id) == count_before, "卖出后物品数量回落")
	_check(price == def.value / 2, "卖出价 = 基准价一半（%d / %d）" % [price, def.value])

	# 4) 包满：金币充足也买不进，且不扣钱
	InventoryService.reset()
	InventoryService.capacity = 1
	InventoryService.add_item(&"wep_iron_axe", 1)
	InventoryService.gold = 999
	var bought_before := InventoryService.count_of(first_id)
	panel.press_buy_row(0)
	_check(InventoryService.count_of(first_id) == bought_before, "包满时买入不入包")
	_check(InventoryService.gold == 999, "包满时买入不扣金币（余 %d）" % InventoryService.gold)

	InventoryService.capacity = 24
	panel.close_panel()
	await get_tree().process_frame
	InventoryService.reset()


# ---------------- 14–17 / 22. 存档：往返 / 槽位隔离 / 篡改 / 半截写 ----------------

func _test_save() -> void:
	for slot in range(1, SaveService.SLOT_COUNT + 1):
		SaveService.delete_slot(slot)

	var hero = PLAYER_SCENE.instantiate()
	add_child(hero)
	GameManager.player = hero
	await get_tree().process_frame

	# ---- 14 + 22：往返一致，且读档不触发死亡 ----
	InventoryService.reset()
	InventoryService.add_item(&"mat_wolf_fang", 7)
	InventoryService.add_item(&"wep_rusty_sword", 1)
	InventoryService.equip(&"wep_rusty_sword")
	InventoryService.gold = 123
	InventoryService.exp = 40
	hero.global_position = Vector2(320, 256)
	hero.set_hp(77)

	_check(SaveService.save_slot(1), "1 号槽写入成功")
	_check(SaveService.has_save(1), "存档文件已生成")

	InventoryService.reset()
	hero.global_position = Vector2.ZERO
	hero.set_hp(hero.get_max_hp())

	_check(SaveService.load_slot(1), "1 号槽读取成功")
	_check(InventoryService.gold == 123, "金币往返一致（%d）" % InventoryService.gold)
	_check(InventoryService.count_of(&"mat_wolf_fang") == 7,
			"背包数量往返一致（%d）" % InventoryService.count_of(&"mat_wolf_fang"))
	_check(InventoryService.equipped_in("weapon") == &"wep_rusty_sword", "装备往返一致")
	_check(InventoryService.exp == 40, "经验往返一致（%d）" % InventoryService.exp)
	_check(int(round(hero.global_position.x)) == 320 and int(round(hero.global_position.y)) == 256,
			"坐标往返一致（%s）" % str(hero.global_position))
	_check(hero.get_hp() == 77, "血量往返一致（%d）" % hero.get_hp())
	_check(hero.get_hp() > 0 and hero.is_alive(), "读档后不触发死亡判定")

	# ---- 15：3 个槽位互不覆盖 ----
	InventoryService.reset()
	InventoryService.gold = 10
	SaveService.save_slot(1)
	InventoryService.gold = 20
	SaveService.save_slot(2)

	SaveService.load_slot(1)
	_check(InventoryService.gold == 10, "1 号槽内容不受 2 号槽影响（%d）" % InventoryService.gold)
	SaveService.load_slot(2)
	_check(InventoryService.gold == 20, "2 号槽独立保存（%d）" % InventoryService.gold)

	# ---- 16：篡改内容后 CRC 不匹配，拒绝载入且不改运行时 ----
	InventoryService.reset()
	InventoryService.gold = 55
	SaveService.save_slot(3)
	var path := SaveService.slot_path(3)
	var parsed: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	parsed["payload"]["player"]["gold"] = 9999
	var handle := FileAccess.open(path, FileAccess.WRITE)
	handle.store_string(JSON.stringify(parsed))
	handle.close()

	var gold_before: int = InventoryService.gold
	_check(not SaveService.load_slot(3), "被篡改的存档拒绝载入")
	_check(InventoryService.gold == gold_before, "拒绝载入后运行时状态不变（%d）" % InventoryService.gold)

	# ---- 17：临时文件写一半（未 rename）不影响旧档 ----
	InventoryService.reset()
	InventoryService.gold = 33
	SaveService.save_slot(2)
	var tmp_path := SaveService.slot_path(2) + ".tmp"
	var tmp_file := FileAccess.open(tmp_path, FileAccess.WRITE)
	tmp_file.store_string("{\"schema_version\":1,\"crc\":0,\"payload\":{")
	tmp_file.close()

	InventoryService.reset()
	_check(SaveService.load_slot(2), "存在半截临时文件时旧档仍可读")
	_check(InventoryService.gold == 33, "旧档内容未被半截写破坏（%d）" % InventoryService.gold)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp_path))
	_check(not FileAccess.file_exists(tmp_path), "半截临时文件可清理")

	# 收尾：不留下任何存档文件与假玩家
	for slot in range(1, SaveService.SLOT_COUNT + 1):
		SaveService.delete_slot(slot)
	_check(not SaveService.has_save(1) and not SaveService.has_save(2), "清理后无残留存档")
	GameManager.player = null
	remove_child(hero)
	hero.queue_free()
	InventoryService.reset()


# ---------------- 存档页签：空槽置灰 / 保存摘要 / 读取恢复 ----------------

func _test_save_panel() -> void:
	for slot in range(1, SaveService.SLOT_COUNT + 1):
		SaveService.delete_slot(slot)

	var hero = PLAYER_SCENE.instantiate()
	add_child(hero)
	GameManager.player = hero
	await get_tree().process_frame

	var panel = INVENTORY_PANEL.instantiate()
	add_child(panel)
	await get_tree().process_frame
	panel.switch_tab_to(3)

	_check(panel.current_tab() == 3, "可以切到存档页签")
	_check(panel.save_row_count() == 3, "存档页有 3 个槽位（%d）" % panel.save_row_count())
	_check(panel.load_button_disabled(0), "空槽的读取按钮置灰")
	_check(panel.save_row_text(0) == Locale.t("inv.slot.empty"), "空槽显示「未存档」")

	InventoryService.reset()
	InventoryService.gold = 88
	InventoryService.add_item(&"mat_wolf_fang", 3)
	_check(panel.press_save_slot(0), "点击保存写入 1 号槽")
	_check(not panel.load_button_disabled(0), "保存后读取按钮可用")
	_check(panel.save_row_text(0).contains("88"), "槽位摘要显示金币（%s）" % panel.save_row_text(0))

	InventoryService.reset()
	_check(InventoryService.gold == 0, "清空后金币归零")
	_check(panel.press_load_slot(0), "点击读取恢复存档")
	_check(InventoryService.gold == 88 and InventoryService.count_of(&"mat_wolf_fang") == 3,
			"读档恢复金币与背包（%d / %d）" % [InventoryService.gold, InventoryService.count_of(&"mat_wolf_fang")])

	SaveService.delete_slot(1)
	panel.close_panel()
	await get_tree().process_frame
	GameManager.player = null
	remove_child(hero)
	hero.queue_free()
	InventoryService.reset()


# ---------------- 主菜单：空槽置灰 / 读档请求 / 新游戏清状态 ----------------

func _test_main_menu() -> void:
	for slot in range(1, SaveService.SLOT_COUNT + 1):
		SaveService.delete_slot(slot)
	InventoryService.reset()

	var menu = MAIN_MENU.instantiate()
	add_child(menu)
	await get_tree().process_frame
	var launches: Array = []
	# 替换真实场景切换：真切换会销毁测试节点。
	menu.game_launcher = func() -> void: launches.append(true)

	_check(menu.slot_text(0) == Locale.t("inv.slot.empty"), "主菜单空槽显示「未存档」")
	_check(menu.load_disabled(0), "主菜单空槽的读取按钮置灰")
	_check(not menu.request_load(1), "空槽不能发起读档")
	_check(launches.is_empty(), "空槽不会请求进入游戏")

	InventoryService.gold = 77
	InventoryService.add_item(&"mat_wolf_fang", 2)
	SaveService.save_slot(2)
	menu.refresh()
	_check(not menu.load_disabled(1), "有档的槽位按钮可用")
	_check(menu.slot_text(1).contains("77"), "槽位摘要显示金币（%s）" % menu.slot_text(1))

	_check(menu.request_load(2), "有档时可以发起读档")
	_check(SaveService.pending_slot == 2, "读档请求写入 pending_slot（%d）" % SaveService.pending_slot)
	_check(launches.size() == 1, "读档会请求进入游戏")
	_check(SaveService.consume_pending_slot() == 2, "pending_slot 可被游戏场景取出")

	InventoryService.gold = 5
	menu.request_new_game()
	_check(InventoryService.gold == 0, "新游戏清空运行时金币")
	_check(SaveService.pending_slot == 0, "新游戏不留下待读档")
	_check(launches.size() == 2, "新游戏同样请求进入游戏")

	SaveService.delete_slot(2)
	menu.queue_free()
	await get_tree().process_frame
	InventoryService.reset()


# ---------------- 多地图：切图重建 / 玩家与引用重挂 / 存档带地图 ----------------

func _test_multi_map() -> void:
	SaveService.delete_slot(3)
	InventoryService.reset()
	var game = GAME_SCENE.instantiate()
	add_child(game)
	await get_tree().process_frame

	_check(String(game.map.map_id) == "test_map_01", "初始地图是 test_map_01（%s）" % game.map.map_id)
	var size_before: Vector2i = game.map.grid_size
	var hero = GameManager.player
	_check(hero != null, "玩家已创建")
	if hero == null:
		remove_child(game)
		game.queue_free()
		return

	var switched: bool = game.switch_map("test_map_02")
	_check(switched, "切图到 test_map_02 成功")
	_check(String(game.map.map_id) == "test_map_02", "当前地图已切换（%s）" % game.map.map_id)
	_check(game.map.grid_size != size_before,
			"新图尺寸不同（%s → %s）" % [str(size_before), str(game.map.grid_size)])
	_check(hero.get_parent() == game.map.get_entity_root(), "玩家挂到新图的实体容器")
	var spawn_offset: float = hero.global_position.distance_to(game.map.spawn_world_position())
	_check(spawn_offset < 2.0, "玩家落在新图出生点（偏差 %.1f）" % spawn_offset)
	_check(game.map.get_pathfinder() != null, "新图寻路已建好")
	_check(String(SaveService.current_map_id) == "test_map_02", "存档记录的地图同步更新")

	# 在新图存档 → 切回旧图 → 读档：应自动切回存档所在地图
	InventoryService.gold = 42
	_check(SaveService.save_slot(3), "在新图存档成功")
	game.switch_map("test_map_01")
	_check(String(game.map.map_id) == "test_map_01", "已切回 test_map_01")
	_check(SaveService.load_slot(3), "读取该槽成功")
	_check(String(game.map.map_id) == "test_map_02",
			"读档自动切回存档所在地图（%s）" % game.map.map_id)
	_check(InventoryService.gold == 42, "读档金币一致（%d）" % InventoryService.gold)

	SaveService.delete_slot(3)
	SaveService.map_switcher = Callable()
	remove_child(game)
	game.queue_free()
	await get_tree().process_frame
	InventoryService.reset()


# ---------------- 传送点：踩上去换图 / 落点正确 / 不回弹 ----------------

func _test_portals() -> void:
	InventoryService.reset()
	var game = GAME_SCENE.instantiate()
	add_child(game)
	await get_tree().process_frame

	var portals: Array[Node] = []
	for node: Node in game.map.get_entity_root().get_children():
		if node is PortalNode:
			portals.append(node)
	_check(portals.size() == 1, "test_map_01 有 1 个传送点（实际 %d）" % portals.size())
	if portals.is_empty():
		GameManager.player = null
		remove_child(game)
		game.queue_free()
		return

	var portal := portals[0] as PortalNode
	var target_id := portal.target_map
	var target_cell := portal.target_cell
	_check(String(game.map.map_id) != target_id, "传送目标不是当前地图（%s）" % target_id)

	# 站到传送点中心，等过了武装时间自动触发。
	var hero = GameManager.player
	hero.global_position = portal.global_position
	for i in 90:
		await get_tree().physics_frame
		if String(game.map.map_id) == target_id:
			break
	_check(String(game.map.map_id) == target_id,
			"踩上传送点后切到目标地图（当前 %s）" % game.map.map_id)

	var offset: float = hero.global_position.distance_to(Iso.grid_to_world(target_cell))
	_check(offset < 2.0, "落在目标落点（偏差 %.1f）" % offset)

	# 落点故意与目标图的传送点隔开两格，且 main 有免疫窗口：不应立刻被弹回。
	for i in 5:
		await get_tree().physics_frame
	_check(String(game.map.map_id) == target_id, "换图后没有被立刻弹回")

	SaveService.map_switcher = Callable()
	GameManager.player = null
	remove_child(game)
	game.queue_free()
	await get_tree().process_frame
	InventoryService.reset()


# ---------------- NPC：靠近交互 / 主操作文案 / 打开商店页 ----------------

func _test_npc() -> void:
	InventoryService.reset()
	var game = GAME_SCENE.instantiate()
	add_child(game)
	await get_tree().process_frame

	var npcs: Array[Node] = []
	for node: Node in game.map.get_entity_root().get_children():
		if node is NpcNode:
			npcs.append(node)
	_check(npcs.size() == 1, "test_map_01 有 1 个 NPC（实际 %d）" % npcs.size())
	if npcs.is_empty():
		remove_child(game)
		game.queue_free()
		return

	var npc := npcs[0] as NpcNode
	var hero = GameManager.player

	# 远处：不可交互，主操作仍是攻击
	hero.global_position = npc.global_position + Vector2(400.0, 0.0)
	await get_tree().physics_frame
	_check(hero.nearest_npc() == null, "离得远时找不到可交互 NPC")
	_check(String(hero.get_selected_action_key()) == "action.attack",
			"远景时主操作仍是攻击（%s）" % hero.get_selected_action_key())

	# 靠近：主操作变成交互，按一次发出 npc 交互请求
	var kinds: Array = []
	var on_action := func(kind: String, _target: Node) -> void: kinds.append(kind)
	EventBus.target_action_requested.connect(on_action)
	hero.global_position = npc.global_position + Vector2(20.0, 0.0)
	_check(hero.nearest_npc() == npc, "靠近后能定位到该 NPC")
	_check(String(hero.get_selected_action_key()) == "action.interact",
			"靠近后主操作变成交互（%s）" % hero.get_selected_action_key())
	hero.perform_action()
	_check(kinds.size() == 1 and String(kinds[0]) == "npc", "按主操作发出 npc 交互请求")

	# main 收到请求后打开面板，并直接落在商店页
	await get_tree().process_frame
	var panel = game._shop_panel
	_check(panel != null and is_instance_valid(panel), "交互后打开了商店面板")
	if panel != null and is_instance_valid(panel):
		_check(panel.current_tab() == 2, "面板直接落在商店页签（%d）" % panel.current_tab())
		_check(panel.shop_buy_row_count() > 0, "商店有货架（%d 件）" % panel.shop_buy_row_count())
		panel.close_panel()

	EventBus.target_action_requested.disconnect(on_action)
	GameManager.player = null
	remove_child(game)
	game.queue_free()
	await get_tree().process_frame
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
