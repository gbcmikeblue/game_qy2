@tool
class_name LootEntry
extends Resource

## 掉落表条目：chance 决定是否进入本次候选池，weight 决定在池中的相对概率。

@export var item: ItemData = null
@export var weight: float = 1.0
@export var min_qty: int = 1
@export var max_qty: int = 1
## 1 = 必进候选池，0 = 永不掉落（用于临时关掉某条）。
@export var chance: float = 1.0


## 本次掉落的数量；min/max 写反时自动纠正，至少为 1。
func quantity(rng: RandomNumberGenerator) -> int:
	var low := maxi(1, min_qty)
	var high := maxi(low, max_qty)
	return rng.randi_range(low, high)
