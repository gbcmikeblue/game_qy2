extends Node

## 输入汇总层：
## 1. 把键盘和触屏摇杆合并成唯一的 move_vector。
## 2. 把“攻击 / 目标选择”统一转成 EventBus 事件，使 UI 按钮与键盘走同一条路径，
##    避免出现两套触发逻辑互相串台。
## 键盘映射（桌面测试用）：WASD / 方向键 移动，SPACE 攻击，F 按住选择目标。

const ACTIONS := {
	"move_left": [KEY_A, KEY_LEFT],
	"move_right": [KEY_D, KEY_RIGHT],
	"move_up": [KEY_W, KEY_UP],
	"move_down": [KEY_S, KEY_DOWN],
}
const ATTACK_KEYS := [KEY_SPACE]
const SELECT_KEYS := [KEY_F]

## 虚拟摇杆写入（范围 -1..1），由 VirtualJoystick 设置。
var touch_vector := Vector2.ZERO
## 合并后的移动向量，长度不超过 1（斜向不加速）。
var move_vector := Vector2.ZERO


func _ready() -> void:
	_register_actions()
	_register_action("attack", ATTACK_KEYS)
	_register_action("target_select", SELECT_KEYS)


func _physics_process(_delta: float) -> void:
	var merged := Input.get_vector("move_left", "move_right", "move_up", "move_down")
	if touch_vector.length() > 0.08:
		merged = touch_vector
	move_vector = merged.limit_length(1.0)

	if Input.is_action_just_pressed("attack"):
		EventBus.attack_requested.emit()
	if Input.is_action_just_pressed("target_select"):
		EventBus.target_select_pressed.emit()
	if Input.is_action_just_released("target_select"):
		EventBus.target_select_released.emit()


func _register_actions() -> void:
	for action: String in ACTIONS.keys():
		_register_action(action, ACTIONS[action])


func _register_action(action: String, keys: Array) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action, 0.2)
	for key: int in keys:
		var event := InputEventKey.new()
		event.physical_keycode = key
		if not InputMap.action_has_event(action, event):
			InputMap.action_add_event(action, event)
