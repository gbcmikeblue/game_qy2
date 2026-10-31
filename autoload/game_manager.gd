extends Node

## 全局流程控制：暂停、当前玩家引用。
## 阶段 A 只承担这两件事，不参与战斗/掉落等业务规则。
##
## 暂停用「原因集合」表达（方案 §7.7）：设置面板、切后台、键盘手动各持有一个原因，
## 只要有任一原因存在就暂停，最后一个原因释放时才真正恢复。
## 这样三个来源不会互相覆盖（旧实现里 ESC 或回前台会把设置面板的暂停顶掉）。
## 切后台同时把设置落盘，避免进程被系统杀掉后丢配置。

## 暂停原因。
const PAUSE_SETTINGS := "settings"
const PAUSE_BACKGROUND := "background"
const PAUSE_MANUAL := "manual"

var player: Node2D = null
## 目标玩家查询入口：单机返回 player；接权威服务器后换成「按会话下发实体」，
## 调用方（敌人 AI 等）不需要改代码。为空的 Callable 表示用单机默认值。
var player_provider: Callable = Callable()
## 派生状态：等价于「原因集合非空」。对外只读，改动请走 hold_pause/release_pause。
var is_paused := false


## 查询当前玩家。所有「谁是我的目标」都应走这里，而不是直接读 player 字段。
func get_player() -> Node2D:
	if player_provider.is_valid():
		var resolved: Variant = player_provider.call()
		return resolved as Node2D
	return player

var _reasons: Dictionary = {}


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
	if not event.is_action_pressed("ui_cancel"):
		return
	# ESC 只切换「手动」这一个原因：设置面板打开时按 ESC 不会把面板的暂停顶掉。
	if _reasons.has(PAUSE_MANUAL):
		release_pause(PAUSE_MANUAL)
	else:
		hold_pause(PAUSE_MANUAL)


## 增加一个暂停原因（重复调用无副作用）。
func hold_pause(reason: String) -> void:
	if _reasons.has(reason):
		return
	_reasons[reason] = true
	_sync_pause()


## 释放一个暂停原因（重复调用无副作用）。
func release_pause(reason: String) -> void:
	if not _reasons.has(reason):
		return
	_reasons.erase(reason)
	_sync_pause()


## 清空全部原因（测试收尾 / 场景重置用）。
func clear_pauses() -> void:
	if _reasons.is_empty():
		return
	_reasons.clear()
	_sync_pause()


func pause_reasons() -> Array[String]:
	var reasons: Array[String] = []
	for reason: String in _reasons:
		reasons.append(reason)
	return reasons


## 兼容旧调用：true = 加「手动」原因，false = 清空全部原因。
func set_paused(value: bool) -> void:
	if value:
		hold_pause(PAUSE_MANUAL)
	else:
		clear_pauses()


## 切后台/来电：落盘 + 加「后台」原因。
func pause_for_background() -> void:
	GameSettings.save_to_disk()
	hold_pause(PAUSE_BACKGROUND)


## 回到前台：只释放「后台」这一个原因，设置面板等其它原因照旧保持暂停。
func resume_from_background() -> void:
	release_pause(PAUSE_BACKGROUND)


func is_background_paused() -> bool:
	return _reasons.has(PAUSE_BACKGROUND)


## 只有状态真的变化时才写 get_tree().paused 并广播，避免重复事件打断战斗状态机。
func _sync_pause() -> void:
	var paused := not _reasons.is_empty()
	if paused == is_paused:
		return
	is_paused = paused
	get_tree().paused = paused
	# 真机验收靠 logcat 判断切后台/回前台是否按预期暂停（发布构建不输出）。
	if OS.is_debug_build():
		print("[Pause] paused=%s reasons=%s" % [str(paused), str(pause_reasons())])
	EventBus.game_paused.emit(paused)


func _on_attack_requested() -> void:
	print("[GameManager] attack requested (combat lands in stage B)")
