extends CanvasLayer

## HUD：血条 + 选中目标状态 + 调试信息 + 设置入口。
## 语言切换入口已迁到设置面板（本层不再有 LANG 按钮）。
## 主操作按钮的文案随“选中目标类型”变化（怪物=攻击 / NPC=交互 / 植物=采摘 / 玩家=观察），
## 类型到文案 key 的映射在 data/targets/interactions.json，语言由 Locale 实时切换。

const HP_FILL_MAX := 276.0
const SETTINGS_PANEL := preload("res://scenes/ui/settings_panel.tscn")

@onready var _debug_label: Label = $DebugLabel
@onready var _hp_fill: ColorRect = $HpFill
@onready var _hp_label: Label = $HpLabel
@onready var _attack_button = $AttackButton
@onready var _settings_button: UiButton = $SettingsButton
@onready var _hint_label: Label = $HintLabel

var _lock_line := ""
var _panel: Node = null
var _action_key := ""


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	for label: Label in [_debug_label, _hp_label, _hint_label]:
		label.add_theme_font_override("font", Locale.font)
		label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 0.92))
		label.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.85))
		label.add_theme_constant_override("outline_size", 4)
	# Teko 字身偏窄偏小，字号统一上调一档保证可读性。
	_debug_label.add_theme_font_size_override("font_size", 18)
	_hp_label.add_theme_font_size_override("font_size", 20)
	_hint_label.add_theme_font_size_override("font_size", 16)
	_hint_label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 0.55))

	_settings_button.pressed.connect(_on_settings_pressed)
	Locale.language_changed.connect(_on_texts_changed)
	GameSettings.bindings_changed.connect(_on_texts_changed)
	_refresh_texts()


func _process(_delta: float) -> void:
	_update_health()
	_update_lock()
	_update_action_button()
	_update_debug()


func _on_texts_changed(_arg: Variant = null) -> void:
	_refresh_texts()


func _refresh_texts() -> void:
	_settings_button.set_caption(Locale.t("button.settings"))
	_update_action_button()
	_update_hint()


## 主操作按钮文案：由当前选中目标的类型决定，未选中时回退为“攻击”。
## 文案 key 变化时同步刷新底部提示，避免按钮与提示不一致。
func _update_action_button() -> void:
	var key := "action.attack"
	var player := GameManager.player
	if is_instance_valid(player) and player.has_method("get_selected_action_key"):
		key = player.get_selected_action_key()
	_attack_button.set_caption(Locale.t(key))
	if key != _action_key:
		_action_key = key
		_update_hint()


## 底部提示：移动键 + 当前操作文案/按键，跟随选中目标类型与键位设置变化。
func _update_hint() -> void:
	var player := GameManager.player
	var action_key := "action.attack"
	if is_instance_valid(player) and player.has_method("get_selected_action_key"):
		action_key = player.get_selected_action_key()
	_hint_label.text = Locale.t("hud.hint", [
		GameSettings.movement_keys_text(),
		Locale.t(action_key),
		GameSettings.key_text("attack"),
	])


func _on_settings_pressed() -> void:
	if is_instance_valid(_panel):
		return
	_panel = SETTINGS_PANEL.instantiate()
	add_child(_panel)
	if _panel.has_signal("closed"):
		_panel.closed.connect(_on_panel_closed)


func _on_panel_closed() -> void:
	_panel = null
	_refresh_texts()


func _update_health() -> void:
	var player := GameManager.player
	if not is_instance_valid(player) or not player.has_method("get_hp"):
		return
	var current: int = player.get_hp()
	var maximum: int = player.get_max_hp()
	var ratio := clampf(float(current) / float(maxi(1, maximum)), 0.0, 1.0)
	_hp_fill.size = Vector2(HP_FILL_MAX * ratio, _hp_fill.size.y)
	_hp_label.text = Locale.t("hud.hp", [current, maximum])


## 选中行：只展示当前选中目标（选中由点击完成，与攻击无关）。
func _update_lock() -> void:
	var player := GameManager.player
	if not is_instance_valid(player) or not player.has_method("get_lock_summary"):
		_lock_line = Locale.t("hud.target.none")
		return

	var summary: Dictionary = player.get_lock_summary()
	if int(summary.get("index", 0)) == 0:
		_lock_line = Locale.t("hud.target.none")
	else:
		_lock_line = Locale.t("hud.target", [String(summary.get("name", "-"))])


func _update_debug() -> void:
	var lines: Array[String] = []
	lines.append(Locale.t("hud.fps", [Engine.get_frames_per_second()]))
	lines.append(Locale.t("hud.state", [
		Locale.t("hud.state.paused") if GameManager.is_paused else Locale.t("hud.state.running")
	]))
	lines.append(Locale.t("hud.enemies", [get_tree().get_node_count_in_group("enemies")]))
	lines.append(_lock_line)

	var player := GameManager.player
	if is_instance_valid(player):
		var world: Vector2 = player.global_position
		var grid := Iso.world_to_grid(world)
		lines.append(Locale.t("hud.world", [world.x, world.y]))
		lines.append(Locale.t("hud.grid", [grid.x, grid.y]))
		lines.append(Locale.t("hud.speed", [(player as CharacterBody2D).velocity.length()]))
		lines.append(Locale.t("hud.auto.on") if player.is_auto_approaching() else Locale.t("hud.auto.off"))
		lines.append(Locale.t("hud.auto_attack.on") if player.is_auto_attack_active() else Locale.t("hud.auto_attack.off"))
		if not player.is_alive():
			lines.append(Locale.t("hud.dead"))

	_debug_label.text = "\n".join(lines)
