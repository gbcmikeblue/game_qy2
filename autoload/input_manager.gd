extends Node

## 输入汇总层：把键盘和触屏摇杆合并成唯一的 move_vector。
## 玩家控制器只读 move_vector，不关心输入来自键盘还是虚拟摇杆。

const ACTIONS := {
	"move_left": [KEY_A, KEY_LEFT],
	"move_right": [KEY_D, KEY_RIGHT],
	"move_up": [KEY_W, KEY_UP],
	"move_down": [KEY_S, KEY_DOWN],
}

## 虚拟摇杆写入（范围 -1..1），由 VirtualJoystick 设置。
var touch_vector := Vector2.ZERO
## 合并后的移动向量，长度不超过 1（斜向不加速）。
var move_vector := Vector2.ZERO


func _ready() -> void:
	_register_actions()


func _physics_process(_delta: float) -> void:
	var merged := Input.get_vector("move_left", "move_right", "move_up", "move_down")
	if touch_vector.length() > 0.08:
		merged = touch_vector
	move_vector = merged.limit_length(1.0)


func _register_actions() -> void:
	for action: String in ACTIONS.keys():
		if not InputMap.has_action(action):
			InputMap.add_action(action, 0.2)
		for key: int in ACTIONS[action]:
			var event := InputEventKey.new()
			event.physical_keycode = key
			if not InputMap.action_has_event(action, event):
				InputMap.action_add_event(action, event)
