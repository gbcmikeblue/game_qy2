extends Node

## 全局流程控制：暂停、当前玩家引用。
## 阶段 A 只承担这两件事，不参与战斗/掉落等业务规则。
##
## 暂停有三个来源，互不覆盖：
##   1. 设置面板（自己 set_paused(true) / set_paused(false)）；
##   2. 切后台/失焦（本层的 pause_for_background()，恢复时只撤销自己加的那次）；
##   3. 键盘 ui_cancel 手动切换。
## 切后台同时把设置落盘，避免进程被系统杀掉后丢配置。

var player: Node2D = null
var is_paused := false

## 当前暂停是否由「切后台」触发；用于恢复时不去动设置面板等其它来源的暂停。
var _background_paused := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	EventBus.attack_requested.connect(_on_attack_requested)


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_APPLICATION_FOCUS_OUT, NOTIFICATION_APPLICATION_PAUSED:
			pause_for_background()
		NOTIFICATION_APPLICATION_FOCUS_IN, NOTIFICATION_APPLICATION_RESUMED:
			resume_from_background()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		set_paused(not is_paused)


func set_paused(value: bool) -> void:
	is_paused = value
	get_tree().paused = value
	EventBus.game_paused.emit(value)


## 切后台/来电：落盘 + 暂停。已经有别的暂停来源时只落盘，不重复暂停。
func pause_for_background() -> void:
	GameSettings.save_to_disk()
	if is_paused:
		return
	_background_paused = true
	set_paused(true)


## 回到前台：只撤销自己加的那次暂停，设置面板等其它来源的暂停保持不变。
func resume_from_background() -> void:
	if not _background_paused:
		return
	_background_paused = false
	set_paused(false)


func is_background_paused() -> bool:
	return _background_paused


func _on_attack_requested() -> void:
	print("[GameManager] attack requested (combat lands in stage B)")
