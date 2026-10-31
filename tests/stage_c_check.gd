extends Node

## 阶段 C 验收：物品 → 掉落 → 背包 → 装备 → 存档。
## 断言编号与 doc/阶段C-数据契约-评审稿.md §9 一致，每完成一步补一组。
## 当前覆盖「数据」组（1–3）。运行：
##   godot --headless --path <项目> res://tests/stage_c_check.tscn

const ITEMS_DIR := "res://data/items/items"
const LOOT_DIR := "res://data/items/loot"

var _failures: Array[String] = []


func _ready() -> void:
	_test_registry_load()
	_test_slot_validation()
	_test_stack_normalization()
	_test_i18n_coverage()
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
