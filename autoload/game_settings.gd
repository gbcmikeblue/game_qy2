extends Node

## 键位设置：默认值 -> 读取本地配置 -> 写入 InputMap，并对外提供查询/修改/重置。
## 修改后立刻 apply()（即时生效）并 save_to_disk()（自动保存）。
## 冲突处理：新键已被其它动作占用时，两者交换按键并回报冲突对象。

signal bindings_changed
## 玩家战斗参数（持续攻击阈值）变化。
signal combat_changed

const SAVE_PATH := "user://keybindings.cfg"
const SECTION := "input"
const COMBAT_SECTION := "combat"
const ACTIONS := ["move_up", "move_down", "move_left", "move_right", "attack"]
const DEFAULTS := {
	"move_up": KEY_W,
	"move_down": KEY_S,
	"move_left": KEY_A,
	"move_right": KEY_D,
	"attack": KEY_J,
}

## 可在“设置 → 玩家战斗”里调整的阈值；默认值来自 data/actors/player.json。
const COMBAT_KEYS := ["auto_attack_hold_seconds", "auto_attack_tap_count"]
const COMBAT_LIMITS := {
	"auto_attack_hold_seconds": {"min": 0.3, "max": 2.5, "step": 0.1},
	"auto_attack_tap_count": {"min": 2.0, "max": 10.0, "step": 1.0},
}

var bindings: Dictionary = {}
## 用户覆盖值（未设置时用 JSON 里的设计默认值）。
var combat: Dictionary = {}


func _ready() -> void:
	reset_to_defaults_quietly()
	load_from_disk()
	apply()


func get_key(action: String) -> int:
	return int(bindings.get(action, 0))


func key_text(action: String) -> String:
	var code := get_key(action)
	return OS.get_keycode_string(code) if code != 0 else "-"


## 设置单个动作的按键：返回 {"ok": bool, "swapped": String}
func set_key(action: String, keycode: int) -> Dictionary:
	if not ACTIONS.has(action) or keycode == 0:
		return {"ok": false, "swapped": ""}

	var swapped := ""
	for other: String in ACTIONS:
		if other == action:
			continue
		if int(bindings.get(other, 0)) == keycode:
			bindings[other] = get_key(action)
			swapped = other
			break

	bindings[action] = keycode
	apply()
	save_to_disk()
	bindings_changed.emit()
	return {"ok": true, "swapped": swapped}


func reset_defaults() -> void:
	reset_to_defaults_quietly()
	apply()
	save_to_disk()
	bindings_changed.emit()


## 不触发信号、不落盘的默认值恢复（用于初始化与重置前的中间状态）。
func reset_to_defaults_quietly() -> void:
	for action: String in ACTIONS:
		bindings[action] = int(DEFAULTS[action])


func apply() -> void:
	for action: String in ACTIONS:
		if not InputMap.has_action(action):
			InputMap.add_action(action, 0.2)
		InputMap.action_erase_events(action)
		var event := InputEventKey.new()
		event.physical_keycode = get_key(action)
		InputMap.action_add_event(action, event)


## 取战斗阈值：用户设置优先，否则用调用方给的默认值（来自 player.json）。
func combat_value(key: String, fallback: float) -> float:
	return float(combat.get(key, fallback))


func set_combat_value(key: String, value: float) -> void:
	if not COMBAT_LIMITS.has(key):
		return
	var cfg: Dictionary = COMBAT_LIMITS[key]
	var clamped := clampf(value, float(cfg["min"]), float(cfg["max"]))
	if combat.has(key) and is_equal_approx(float(combat[key]), clamped):
		return
	combat[key] = clamped
	save_to_disk()
	combat_changed.emit()


## 供设置面板的 +/- 按钮使用：按步长加减并夹紧到合法区间。
func adjust_combat(key: String, direction: int, fallback: float) -> void:
	var cfg: Dictionary = COMBAT_LIMITS.get(key, {})
	if cfg.is_empty():
		return
	var step := float(cfg["step"])
	set_combat_value(key, combat_value(key, fallback) + float(direction) * step)


func reset_combat() -> void:
	if combat.is_empty():
		return
	combat.clear()
	save_to_disk()
	combat_changed.emit()


func save_to_disk() -> void:
	var config := ConfigFile.new()
	for action: String in ACTIONS:
		config.set_value(SECTION, action, get_key(action))
	for key: String in COMBAT_KEYS:
		if combat.has(key):
			config.set_value(COMBAT_SECTION, key, float(combat[key]))
	config.save(SAVE_PATH)


func load_from_disk() -> void:
	var config := ConfigFile.new()
	if config.load(SAVE_PATH) != OK:
		return
	# 用哨兵值做默认，避免 ConfigFile 在缺键时打错误日志。
	for action: String in ACTIONS:
		var value: Variant = config.get_value(SECTION, action, -1)
		if int(value) > 0:
			bindings[action] = int(value)
	for key: String in COMBAT_KEYS:
		var value: Variant = config.get_value(COMBAT_SECTION, key, -1.0)
		if float(value) >= 0.0:
			combat[key] = float(value)


## 移动键汇总文本，用于 HUD 提示（例如 W/A/S/D）。
func movement_keys_text() -> String:
	var parts: Array[String] = []
	for action: String in ["move_up", "move_left", "move_down", "move_right"]:
		parts.append(key_text(action))
	return "/".join(parts)
