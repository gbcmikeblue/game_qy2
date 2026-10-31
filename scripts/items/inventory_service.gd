extends Node

## 运行时背包 / 装备 / 金币 / 等级（Autoload）。
## 所有改动只能经本节点的方法，并在成功后广播状态事件；UI 只读状态、发请求。
## 所有多步操作都保证事务性：任一步失败则回滚到调用前状态。

## 物品种类上限（占格数），可由设置或测试覆盖。
var capacity: int = 24

## [{ "id": StringName, "qty": int }]，列表式背包，无占格坐标。
var items: Array[Dictionary] = []
## slot(String) -> item id(StringName)；空槽不存键。
var equipment: Dictionary = {}
var gold: int = 0
var level: int = 1
var exp: int = 0

## 等级曲线（契约 R5）：exp_to_next = 50 × level^1.5
const EXP_BASE := 50.0
const EXP_POWER := 1.5
## 每级固定成长；基础值仍来自 data/actors/player.json。
const GROWTH := {
	"max_hp": 8.0,
	"max_mp": 4.0,
	"attack": 2.0,
	"defense": 1.0,
}


## 清空运行时状态（读档与测试使用）。
func reset() -> void:
	items.clear()
	equipment.clear()
	gold = 0
	level = 1
	exp = 0
	capacity = 24


# ---------------- 背包 ----------------

## 入包并返回**实际**入包数量；先补已有堆叠，再占新格，满了就只入一部分。
func add_item(item_id: StringName, qty: int = 1) -> int:
	var def := ItemRegistry.get_item(item_id)
	if def == null or qty <= 0:
		return 0

	var remaining := qty
	var max_stack := def.effective_max_stack()

	if def.stackable:
		for entry: Dictionary in items:
			if entry["id"] != item_id:
				continue
			var room := max_stack - int(entry["qty"])
			if room <= 0:
				continue
			var filled := mini(room, remaining)
			entry["qty"] = int(entry["qty"]) + filled
			remaining -= filled
			if remaining <= 0:
				break

	while remaining > 0 and items.size() < capacity:
		var take := mini(max_stack, remaining) if def.stackable else 1
		items.append({"id": item_id, "qty": take})
		remaining -= take

	var added := qty - remaining
	if added > 0:
		EventBus.inventory_changed.emit()
	return added


## 移除指定数量；数量不足时不改动任何数据并返回 false。
func remove_item(item_id: StringName, qty: int = 1) -> bool:
	if qty <= 0 or count_of(item_id) < qty:
		return false

	var remaining := qty
	var index := 0
	while index < items.size() and remaining > 0:
		var entry: Dictionary = items[index]
		if entry["id"] != item_id:
			index += 1
			continue
		var taken := mini(int(entry["qty"]), remaining)
		entry["qty"] = int(entry["qty"]) - taken
		remaining -= taken
		if int(entry["qty"]) <= 0:
			items.remove_at(index)
			continue
		index += 1

	EventBus.inventory_changed.emit()
	return true


func count_of(item_id: StringName) -> int:
	var total := 0
	for entry: Dictionary in items:
		if entry["id"] == item_id:
			total += int(entry["qty"])
	return total


# ---------------- 装备 ----------------

## 装备一件物品；旧件回包失败（包满）时整体回滚，返回 false。
func equip(item_id: StringName) -> bool:
	var def := ItemRegistry.get_item(item_id)
	if def == null or not def.is_equipment():
		return false
	var slot := String(def.slot)
	if not ItemRegistry.slots.has(slot):
		return false
	if count_of(item_id) <= 0:
		return false

	var previous: StringName = equipment.get(slot, &"")
	if not remove_item(item_id, 1):
		return false
	if previous != &"" and add_item(previous, 1) == 0:
		# 旧件放不回背包：把刚取下的一件装回去，保持调用前状态。
		add_item(item_id, 1)
		return false

	equipment[slot] = item_id
	EventBus.equipment_changed.emit(slot, String(item_id))
	return true


## 卸下装备并回包；包满时拒绝且槽位不变。
func unequip(slot: String) -> bool:
	var item_id: StringName = equipment.get(slot, &"")
	if item_id == &"":
		return false
	if add_item(item_id, 1) == 0:
		return false
	equipment.erase(slot)
	EventBus.equipment_changed.emit(slot, "")
	return true


func equipped_in(slot: String) -> StringName:
	return equipment.get(slot, &"")


# ---------------- 属性与成长 ----------------

## 基础属性 = player.json + 等级成长（不含装备）。
func base_stats() -> Dictionary:
	var def := DataRegistry.get_player_def()
	var steps := level - 1
	return {
		"max_hp": float(def.get("max_hp", 100)) + GROWTH["max_hp"] * steps,
		"max_mp": float(def.get("max_mp", 30)) + GROWTH["max_mp"] * steps,
		"attack": float(def.get("attack", 10)) + GROWTH["attack"] * steps,
		"defense": float(def.get("defense", 0)) + GROWTH["defense"] * steps,
		"crit_rate": float(def.get("crit_rate", 0.0)),
		"crit_damage": float(def.get("crit_damage", 1.5)),
	}


## 最终属性 = 基础 + 全部装备加成。
func stats() -> Dictionary:
	var out := base_stats()
	for slot: String in equipment:
		var def := ItemRegistry.get_item(equipment[slot])
		if def == null:
			continue
		out["max_hp"] += def.max_hp_bonus
		out["max_mp"] += def.max_mp_bonus
		out["attack"] += def.attack_bonus
		out["defense"] += def.defense_bonus
	return out


func exp_to_next() -> int:
	return int(round(EXP_BASE * pow(float(level), EXP_POWER)))


## 加经验并结算升级，返回本次升了几级。
func gain_exp(amount: int) -> int:
	if amount <= 0:
		return 0
	exp += amount
	var ups := 0
	while exp >= exp_to_next():
		exp -= exp_to_next()
		level += 1
		ups += 1
	if ups > 0:
		EventBus.level_changed.emit(level, exp)
	return ups


# ---------------- 金币 ----------------

## 入账（掉落、卖店、任务奖励都走这里，保证只有一处广播）。
func add_gold(amount: int) -> void:
	if amount == 0:
		return
	gold = maxi(0, gold + amount)
	EventBus.gold_changed.emit(gold)


# ---------------- 商店 ----------------

## 买入一件：金币不足或放不下时不做任何改动。
func buy(item_id: StringName) -> bool:
	var def := ItemRegistry.get_item(item_id)
	if def == null or def.value <= 0:
		return false
	if gold < def.value:
		return false
	if add_item(item_id, 1) == 0:
		return false
	gold -= def.value
	EventBus.gold_changed.emit(gold)
	return true


## 卖出价 = 基准价一半（向下取整）。
func sell_price(item_id: StringName) -> int:
	var def := ItemRegistry.get_item(item_id)
	if def == null:
		return 0
	return def.value / 2


func sell(item_id: StringName) -> bool:
	var def := ItemRegistry.get_item(item_id)
	if def == null:
		return false
	if not remove_item(item_id, 1):
		return false
	gold += sell_price(item_id)
	EventBus.gold_changed.emit(gold)
	return true
