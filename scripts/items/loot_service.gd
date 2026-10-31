extends Node

## 掉落服务：监听敌人死亡 → 查掉落表 → 生成地面掉落物 → 结算金币与经验。
## 敌人本身不碰背包（分层约定：AI 只管状态机，奖励由服务层记账）。

## 掉落物挂载点（地图的 y_sort 实体容器），由 main 注入。
var entity_root: Node2D = null
## 非 0 时固定随机种子（测试复现用）。
var seed_override: int = 0

var rng := RandomNumberGenerator.new()


func _ready() -> void:
	if seed_override != 0:
		rng.seed = seed_override
	else:
		rng.randomize()
	EventBus.enemy_defeated.connect(_on_enemy_defeated)


func _exit_tree() -> void:
	if EventBus.enemy_defeated.is_connected(_on_enemy_defeated):
		EventBus.enemy_defeated.disconnect(_on_enemy_defeated)


## 一次击杀的完整奖励结算。返回生成的掉落物数量，便于测试与调试。
func settle(enemy_id: String, world_position: Vector2) -> int:
	var def := DataRegistry.get_enemy_def(enemy_id)
	if def.is_empty():
		push_error("掉落服务收到未知敌人：%s" % enemy_id)
		return 0

	var spawned := 0
	var table := ItemRegistry.get_loot(StringName(String(def.get("loot", ""))))
	if table != null:
		var result := table.roll(rng)
		for entry: Dictionary in result.get("items", []):
			_spawn_drop(StringName(entry["id"]), int(entry["qty"]), world_position)
			spawned += 1
		InventoryService.add_gold(int(result.get("gold", 0)))

	var exp := int(def.get("exp", 0))
	if exp > 0:
		InventoryService.gain_exp(exp)

	return spawned


func _on_enemy_defeated(enemy_id: String, world_position: Vector2) -> void:
	settle(enemy_id, world_position)


## 掉落物在同一点附近散开，避免完全重叠。
func _spawn_drop(item_id: StringName, qty: int, world_position: Vector2) -> void:
	var drop := LootDrop.new()
	drop.setup(item_id, qty)
	var offset := Vector2(rng.randf_range(-16.0, 16.0), rng.randf_range(-8.0, 8.0))
	drop.position = world_position + offset
	# 显式标注类型：三元里 Node2D 与 Node 混合会被推断成 Variant，本项目把该警告当错误。
	var parent: Node = entity_root if entity_root != null else self
	parent.add_child(drop)
