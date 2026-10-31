@tool
class_name LootTable
extends Resource

## 掉落表：guaranteed 每次必出，entries 按 chance + weight 抽取 rolls 次。
## 抽取用外部传入的 RandomNumberGenerator，保证可 seed、可复现。

## 供 enemies.json 的 "loot" 字段引用。
@export var id: StringName = &""
@export var rolls: int = 1
@export var entries: Array[LootEntry] = []
@export var guaranteed: Array[LootEntry] = []
@export var gold_min: int = 0
@export var gold_max: int = 0


## 返回 {items: Array[{id, qty}], gold: int}；同名掉落自动合并数量。
func roll(rng: RandomNumberGenerator) -> Dictionary:
	var merged: Dictionary = {}

	for entry: LootEntry in guaranteed:
		_append(merged, entry, rng)

	for i in maxi(0, rolls):
		var pool: Array[LootEntry] = []
		var total := 0.0
		for entry: LootEntry in entries:
			if entry == null or entry.item == null:
				continue
			if entry.chance < 1.0 and rng.randf() > entry.chance:
				continue
			pool.append(entry)
			total += maxf(0.0, entry.weight)
		if pool.is_empty() or total <= 0.0:
			continue
		var pick := rng.randf() * total
		for entry: LootEntry in pool:
			pick -= maxf(0.0, entry.weight)
			if pick <= 0.0:
				_append(merged, entry, rng)
				break

	var items: Array[Dictionary] = []
	for item_id: StringName in merged:
		items.append({"id": item_id, "qty": int(merged[item_id])})

	var gold := 0
	if gold_max > 0:
		gold = rng.randi_range(maxi(0, gold_min), maxi(gold_min, gold_max))

	return {"items": items, "gold": gold}


func _append(merged: Dictionary, entry: LootEntry, rng: RandomNumberGenerator) -> void:
	if entry == null or entry.item == null:
		return
	var item_id: StringName = entry.item.id
	merged[item_id] = int(merged.get(item_id, 0)) + entry.quantity(rng)
