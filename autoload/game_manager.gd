extends Node

## 全局流程控制：暂停、当前玩家引用。
## 阶段 A 只承担这两件事，不参与战斗/掉落等业务规则。

var player: Node2D = null
var is_paused := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	EventBus.attack_requested.connect(_on_attack_requested)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		set_paused(not is_paused)


func set_paused(value: bool) -> void:
	is_paused = value
	get_tree().paused = value
	EventBus.game_paused.emit(value)


func _on_attack_requested() -> void:
	print("[GameManager] attack requested (combat lands in stage B)")
