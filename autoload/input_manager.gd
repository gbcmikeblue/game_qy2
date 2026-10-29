extends Node

## 输入汇总层：
## 1. 把键盘和触屏摇杆合并成唯一的 move_vector。
## 2. 攻击只在这里转发成 attack_requested 事件（ATK 按钮与攻击键共用同一条路径）。
## 3. 目标选中不走这里：它由点击/点触的世界拾取器直接调用玩家接口（选中与攻击分离）。
##
## 按键绑定由 GameSettings 统一注册到 InputMap（可在设置面板里改），这里只消费 action。

## 虚拟摇杆写入（范围 -1..1），由 VirtualJoystick 设置。
var touch_vector := Vector2.ZERO
## 合并后的移动向量，长度不超过 1（斜向不加速）。
var move_vector := Vector2.ZERO


func _physics_process(_delta: float) -> void:
	var merged := Input.get_vector("move_left", "move_right", "move_up", "move_down")
	if touch_vector.length() > 0.08:
		merged = touch_vector
	move_vector = merged.limit_length(1.0)

	if Input.is_action_just_pressed("attack"):
		EventBus.attack_requested.emit()
