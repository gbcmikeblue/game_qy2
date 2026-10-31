extends Node

## 键位设置：默认值 -> 读取本地配置 -> 写入 InputMap，并对外提供查询/修改/重置。
## 修改后立刻 apply()（即时生效）并 save_to_disk()（自动保存）。
## 冲突处理：新键已被其它动作占用时，两者交换按键并回报冲突对象。

signal bindings_changed
## 玩家战斗参数（持续攻击阈值）变化。
signal combat_changed
## 显示配置（分辨率档位 / 画质档 / UI 缩放 / 视野档）变化，由 DisplayAdapter 消费。
signal display_changed
## 音频（SFX）设置变化。
signal audio_changed

const SAVE_PATH := "user://keybindings.cfg"
const SECTION := "input"
const COMBAT_SECTION := "combat"
const DISPLAY_SECTION := "display"
const AUDIO_SECTION := "audio"
const ACTIONS := ["move_up", "move_down", "move_left", "move_right", "attack"]
const DEFAULTS := {
	"move_up": KEY_W,
	"move_down": KEY_S,
	"move_left": KEY_A,
	"move_right": KEY_D,
	"attack": KEY_J,
}

## 可在"设置 → 玩家战斗"里调整的阈值；默认值来自 data/actors/player.json。
const COMBAT_KEYS := ["auto_attack_hold_seconds", "auto_attack_tap_count"]
const COMBAT_LIMITS := {
	"auto_attack_hold_seconds": {"min": 0.3, "max": 2.5, "step": 0.1},
	"auto_attack_tap_count": {"min": 2.0, "max": 10.0, "step": 1.0},
}

## 显示配置默认值。resolution_preset 的合法性由 DisplayAdapter 判定（单一来源）。
const DISPLAY_DEFAULTS := {
	"resolution_preset": "auto",
	"quality_tier": "auto",
	"ui_scale": 1.0,
	"view_area_scale": 1.0,
}
const QUALITY_TIERS := ["auto", "low", "medium", "high"]
## 界面缩放上限 1.2：再大时左下角血条会被推上去与调试信息重叠（HUD 720 逻辑高度装不下）。
const UI_SCALES := [0.9, 1.0, 1.1, 1.2]
const VIEW_SCALE_VALUES := [0.8, 1.0, 1.25]
## 音效三档音量（0 等同静音，配合开关使用）。
const SFX_VOLUMES := [0.0, 0.5, 1.0]
const AUDIO_DEFAULTS := {"sfx_enabled": true, "sfx_volume": 0.5}

var bindings: Dictionary = {}
## 用户覆盖值（未设置时用 JSON 里的设计默认值）。
var combat: Dictionary = {}
## 显示配置；非法值在读取与写入时都会被吸附到最近的合法枚举。
var display: Dictionary = {}
## 音频配置：sfx_enabled / sfx_volume（音量吸附到三档）。
var audio: Dictionary = {}


func _ready() -> void:
	reset_to_defaults_quietly()
	display = DISPLAY_DEFAULTS.duplicate()
	audio = AUDIO_DEFAULTS.duplicate()
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


func set_display_value(key: String, value: Variant) -> void:
	if not DISPLAY_DEFAULTS.has(key):
		return
	var normalized: Variant = _normalize_display(key, value)
	if display.get(key) == normalized:
		return
	display[key] = normalized
	save_to_disk()
	display_changed.emit()


func display_value(key: String) -> Variant:
	return display.get(key, DISPLAY_DEFAULTS.get(key))


func display_preset() -> String:
	return String(display_value("resolution_preset"))


func display_quality() -> String:
	var tier := String(display_value("quality_tier"))
	return tier if QUALITY_TIERS.has(tier) else "auto"


func display_ui_scale() -> float:
	return float(display_value("ui_scale"))


func display_view_scale() -> float:
	return float(display_value("view_area_scale"))


## UI 缩放按离散档位加减（面板 +/- 按钮用），不做无级缩放。
func adjust_ui_scale(direction: int) -> void:
	var current := display_ui_scale()
	var index := 0
	for i in UI_SCALES.size():
		if is_equal_approx(float(UI_SCALES[i]), current):
			index = i
			break
	index = clampi(index + direction, 0, UI_SCALES.size() - 1)
	set_display_value("ui_scale", float(UI_SCALES[index]))


func reset_display() -> void:
	display = DISPLAY_DEFAULTS.duplicate()
	save_to_disk()
	display_changed.emit()


## ---------------- 音频 ----------------

func audio_value(key: String) -> Variant:
	return audio.get(key, AUDIO_DEFAULTS.get(key))


func set_audio_value(key: String, value: Variant) -> void:
	match key:
		"sfx_enabled":
			audio[key] = bool(value)
		"sfx_volume":
			audio[key] = _snap_to(clampf(float(value), 0.0, 1.0), SFX_VOLUMES)
		_:
			return
	save_to_disk()
	audio_changed.emit()


func toggle_sfx() -> bool:
	set_audio_value("sfx_enabled", not bool(audio_value("sfx_enabled")))
	return bool(audio_value("sfx_enabled"))


## 音量按档位步进（-1 减、+1 增），到边界不循环。
func adjust_sfx_volume(direction: int) -> void:
	var current := float(audio_value("sfx_volume"))
	var index := 0
	for i in SFX_VOLUMES.size():
		if is_equal_approx(float(SFX_VOLUMES[i]), current):
			index = i
			break
	index = clampi(index + direction, 0, SFX_VOLUMES.size() - 1)
	set_audio_value("sfx_volume", SFX_VOLUMES[index])


func reset_audio() -> void:
	audio = AUDIO_DEFAULTS.duplicate()
	save_to_disk()
	audio_changed.emit()


## 非法值一律吸附到最近的合法枚举，避免手改配置把界面搞坏。
func _normalize_display(key: String, value: Variant) -> Variant:
	match key:
		"resolution_preset":
			var id := String(value).strip_edges()
			return id if not id.is_empty() else String(DISPLAY_DEFAULTS[key])
		"quality_tier":
			var tier := String(value)
			return tier if QUALITY_TIERS.has(tier) else "auto"
		"ui_scale":
			return _snap_to(float(value), UI_SCALES)
		"view_area_scale":
			return _snap_to(float(value), VIEW_SCALE_VALUES)
	return DISPLAY_DEFAULTS[key]


func _snap_to(value: float, values: Array) -> float:
	var best := float(values[0])
	for candidate: float in values:
		if absf(candidate - value) < absf(best - value):
			best = candidate
	return best


func save_to_disk() -> void:
	var config := ConfigFile.new()
	for action: String in ACTIONS:
		config.set_value(SECTION, action, get_key(action))
	for key: String in COMBAT_KEYS:
		if combat.has(key):
			config.set_value(COMBAT_SECTION, key, float(combat[key]))
	for key: String in DISPLAY_DEFAULTS:
		config.set_value(DISPLAY_SECTION, key, display.get(key, DISPLAY_DEFAULTS[key]))
	for key: String in AUDIO_DEFAULTS:
		config.set_value(AUDIO_SECTION, key, audio.get(key, AUDIO_DEFAULTS[key]))
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
	for key: String in DISPLAY_DEFAULTS:
		if not config.has_section_key(DISPLAY_SECTION, key):
			continue
		display[key] = _normalize_display(key, config.get_value(DISPLAY_SECTION, key))
	for key: String in AUDIO_DEFAULTS:
		if not config.has_section_key(AUDIO_SECTION, key):
			continue
		match key:
			"sfx_enabled":
				audio[key] = bool(config.get_value(AUDIO_SECTION, key))
			"sfx_volume":
				audio[key] = _snap_to(float(config.get_value(AUDIO_SECTION, key)), SFX_VOLUMES)


## 移动键汇总文本，用于 HUD 提示（例如 W/A/S/D）。
func movement_keys_text() -> String:
	var parts: Array[String] = []
	for action: String in ["move_up", "move_left", "move_down", "move_right"]:
		parts.append(key_text(action))
	return "/".join(parts)
