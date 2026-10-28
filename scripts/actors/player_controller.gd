extends CharacterBody2D

## 玩家移动：输入只来自 InputManager.move_vector（键盘或虚拟摇杆）。
## 移动方向使用屏幕空间向量并归一化，因此斜向不会更快。

@export var max_speed := 150.0
@export var acceleration := 1400.0
@export var deceleration := 1800.0

@onready var _visual: Node2D = $Visual


func _ready() -> void:
	motion_mode = CharacterBody2D.MOTION_MODE_FLOATING


func _physics_process(delta: float) -> void:
	var direction: Vector2 = InputManager.move_vector
	if direction.length() > 1.0:
		direction = direction.normalized()

	var target := direction * max_speed
	var rate := acceleration if direction.length() > 0.01 else deceleration
	velocity = velocity.move_toward(target, rate * delta)
	move_and_slide()

	if _visual != null and _visual.has_method("set_facing"):
		_visual.set_facing(direction)
