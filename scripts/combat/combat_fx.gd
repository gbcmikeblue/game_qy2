class_name CombatFx
extends RefCounted

## 战斗表现入口：战斗逻辑只管要不要飘字，不关心飘字挂在哪。
## layer 由 main.gd 在启动时注入。

static var layer: Node2D = null

const HIT_COLOR := Color(1.0, 1.0, 1.0)
const CRIT_COLOR := Color(1.0, 0.84, 0.33)
const HURT_COLOR := Color(1.0, 0.42, 0.42)


static func show_damage(world_position: Vector2, amount: int, is_crit: bool) -> void:
	_spawn(str(amount) + ("!" if is_crit else ""), CRIT_COLOR if is_crit else HIT_COLOR, world_position)


static func show_hurt(world_position: Vector2, amount: int) -> void:
	_spawn(str(amount), HURT_COLOR, world_position)


static func _spawn(text: String, color: Color, world_position: Vector2) -> void:
	if layer == null or not is_instance_valid(layer):
		return
	var number := DamageNumber.new()
	number.setup(text, color)
	# 加一点水平抖动，避免多个目标同时受击时数字完全重叠看不清。
	number.position = world_position + Vector2(randf_range(-14.0, 14.0), -58.0)
	layer.add_child(number)
