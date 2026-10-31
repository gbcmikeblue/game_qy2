extends Node

## 物品注册表（Autoload）：扫描 data/items/ 下的 .tres，建 id → 资源索引并校验。
## 与 DataRegistry（只读 JSON）分工：物品/装备/掉落表只在这里查，不读 JSON。
## 校验失败只跳过该条并 push_error，不阻塞游戏启动（方便策划边填边跑）。

const ITEMS_DIR := "res://data/items/items"
const LOOT_DIR := "res://data/items/loot"
const SHOP_DIR := "res://data/items/shop"
const DEFAULT_LOOT := &"default_basic"
const DEFAULT_SHOP := &"basic"

## StringName -> ItemData
var items: Dictionary = {}
## StringName -> LootTable
var loot_tables: Dictionary = {}
## StringName -> ShopData
var shops: Dictionary = {}
## 当前职业允许的槽位（来自 classes.json，顺序即 UI 顺序）。
var slots: Array[String] = []


func _ready() -> void:
	reload()


## 重新扫描（测试与热更使用）；先读槽位，再校验物品。
func reload() -> void:
	items.clear()
	loot_tables.clear()
	shops.clear()
	slots = DataRegistry.get_class_slots(DataRegistry.default_class_id())

	for path: String in _list_tres(ITEMS_DIR):
		var res: Resource = load(path)
		if not (res is ItemData):
			push_error("物品资源类型错误：%s" % path)
			continue
		var item := res as ItemData
		var error := item.validate(slots)
		if not error.is_empty():
			push_error("物品校验失败（%s）：%s" % [path, error])
			continue
		if items.has(item.id):
			push_error("物品 id 重复：%s（%s）" % [item.id, path])
			continue
		items[item.id] = item

	for path: String in _list_tres(LOOT_DIR):
		var res: Resource = load(path)
		if not (res is LootTable):
			push_error("掉落表资源类型错误：%s" % path)
			continue
		var table := res as LootTable
		if table.id == &"":
			push_error("掉落表缺少 id：%s" % path)
			continue
		if loot_tables.has(table.id):
			push_error("掉落表 id 重复：%s（%s）" % [table.id, path])
			continue
		loot_tables[table.id] = table

	for path: String in _list_tres(SHOP_DIR):
		var res: Resource = load(path)
		if not (res is ShopData):
			push_error("商店资源类型错误：%s" % path)
			continue
		var shop := res as ShopData
		if shop.id == &"":
			push_error("商店缺少 id：%s" % path)
			continue
		if shops.has(shop.id):
			push_error("商店 id 重复：%s（%s）" % [shop.id, path])
			continue
		shops[shop.id] = shop


func get_item(item_id: StringName) -> ItemData:
	return items.get(item_id, null)


func has_item(item_id: StringName) -> bool:
	return items.has(item_id)


## 查不到时回落到默认掉落表，保证刷怪流程不因配置缺失中断。
func get_loot(loot_id: StringName) -> LootTable:
	var table: LootTable = loot_tables.get(loot_id, null)
	if table != null:
		return table
	return loot_tables.get(DEFAULT_LOOT, null)


func item_count() -> int:
	return items.size()


func shop_count() -> int:
	return shops.size()


func get_shop(shop_id: StringName) -> ShopData:
	return shops.get(shop_id, null)


## 当前唯一商店（basic）；接入 NPC 后改为按 NPC 指定，这里只作 UI 默认值。
func default_shop() -> ShopData:
	var shop := get_shop(DEFAULT_SHOP)
	if shop != null:
		return shop
	for key: StringName in shops:
		return shops[key]
	return null


func loot_count() -> int:
	return loot_tables.size()


## 目录下的 .tres 路径，排序保证扫描顺序稳定（测试可断言数量）。
func _list_tres(dir_path: String) -> Array[String]:
	var out: Array[String] = []
	var dir := DirAccess.open(dir_path)
	if dir == null:
		push_error("物品目录不存在：%s" % dir_path)
		return out
	for file_name: String in dir.get_files():
		if file_name.ends_with(".tres"):
			out.append(dir_path.path_join(file_name))
	out.sort()
	return out
