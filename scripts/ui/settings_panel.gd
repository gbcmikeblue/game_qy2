extends CanvasLayer

## 设置面板：语言切换 + 按键绑定（查看 / 改键 / 保存 / 恢复默认）。
## 面板打开时暂停游戏（自身 PROCESS_MODE_ALWAYS 继续工作），关闭时恢复。
## 文本全部走 Locale.t()，语言切换后面板内容即时刷新。

signal closed

const PANEL_POS := Vector2(320.0, 26.0)
const PANEL_SIZE := Vector2(640.0, 668.0)
const ROW_HEIGHT := 40.0
const ROW_TOP := 196.0
## “玩家战斗”区块的排版起点（按键绑定 5 行之后）。
const COMBAT_TITLE_TOP := 404.0
const COMBAT_ROW_TOP := 444.0
const CAPTURE_TIMEOUT := 6.0
const NOTICE_DURATION := 2.0

var _panel: ColorRect
var _title: Label
var _language_label: Label
var _binding_title: Label
var _hint: Label
var _notice: Label
var _language_buttons: Array[UiButton] = []
var _row_labels: Dictionary = {}
var _row_buttons: Dictionary = {}
var _combat_title: Label
var _combat_labels: Dictionary = {}
var _combat_values: Dictionary = {}
var _reset_button: UiButton
var _save_button: UiButton
var _close_button: UiButton

var _capturing := ""
var _capture_time := 0.0
var _notice_time := 0.0
var _paused_by_panel := false


func _ready() -> void:
	layer = 10
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build()
	Locale.language_changed.connect(_on_language_changed)
	GameSettings.bindings_changed.connect(_on_bindings_changed)
	GameSettings.combat_changed.connect(_refresh_combat)
	_refresh_texts()
	_pause_game()


func _exit_tree() -> void:
	if Locale.language_changed.is_connected(_on_language_changed):
		Locale.language_changed.disconnect(_on_language_changed)
	if GameSettings.bindings_changed.is_connected(_on_bindings_changed):
		GameSettings.bindings_changed.disconnect(_on_bindings_changed)
	if GameSettings.combat_changed.is_connected(_refresh_combat):
		GameSettings.combat_changed.disconnect(_refresh_combat)
	_resume_game()


func _build() -> void:
	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.62)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)

	_panel = ColorRect.new()
	_panel.color = Color(0.10, 0.12, 0.16, 0.98)
	_panel.position = PANEL_POS
	_panel.size = PANEL_SIZE
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_panel)

	_title = _label(Vector2(28.0, 20.0), Vector2(560.0, 40.0), 28)
	_language_label = _label(Vector2(28.0, 84.0), Vector2(240.0, 32.0), 20)

	var index := 0
	for code: String in Locale.SUPPORTED:
		var button := UiButton.new()
		button.position = Vector2(300.0 + index * 150.0, 80.0)
		button.size = Vector2(132.0, 40.0)
		button.pressed.connect(_on_language_pressed.bind(code))
		_panel.add_child(button)
		_language_buttons.append(button)
		index += 1

	_binding_title = _label(Vector2(28.0, 148.0), Vector2(560.0, 32.0), 20)

	var row := 0
	for action: String in GameSettings.ACTIONS:
		var y := ROW_TOP + row * ROW_HEIGHT
		_row_labels[action] = _label(Vector2(40.0, y), Vector2(320.0, 34.0), 18)
		var key_button := UiButton.new()
		key_button.position = Vector2(392.0, y - 2.0)
		key_button.size = Vector2(208.0, 34.0)
		key_button.pressed.connect(_on_key_pressed.bind(action))
		_panel.add_child(key_button)
		_row_buttons[action] = key_button
		row += 1

	# 玩家战斗：持续攻击阈值（长按秒数 / 连点次数）
	_combat_title = _label(Vector2(28.0, COMBAT_TITLE_TOP), Vector2(560.0, 32.0), 20)
	var combat_row := 0
	for key: String in GameSettings.COMBAT_KEYS:
		var y := COMBAT_ROW_TOP + float(combat_row) * ROW_HEIGHT
		_combat_labels[key] = _label(Vector2(40.0, y), Vector2(300.0, 34.0), 18)

		var minus := UiButton.new()
		minus.position = Vector2(348.0, y - 2.0)
		minus.size = Vector2(44.0, 34.0)
		minus.set_caption("-")
		minus.pressed.connect(_on_combat_step.bind(key, -1))
		_panel.add_child(minus)

		var value := _label(Vector2(400.0, y), Vector2(124.0, 34.0), 18)
		value.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_combat_values[key] = value

		var plus := UiButton.new()
		plus.position = Vector2(532.0, y - 2.0)
		plus.size = Vector2(44.0, 34.0)
		plus.set_caption("+")
		plus.pressed.connect(_on_combat_step.bind(key, 1))
		_panel.add_child(plus)

		combat_row += 1

	_hint = _label(Vector2(28.0, 536.0), Vector2(584.0, 26.0), 15)
	_notice = _label(Vector2(28.0, 562.0), Vector2(584.0, 26.0), 16)

	_reset_button = _footer_button(Vector2(28.0, 600.0), Vector2(168.0, 42.0))
	_reset_button.pressed.connect(_on_reset_pressed)
	_save_button = _footer_button(Vector2(212.0, 600.0), Vector2(140.0, 42.0))
	_save_button.pressed.connect(_on_save_pressed)
	_close_button = _footer_button(Vector2(368.0, 600.0), Vector2(160.0, 42.0))
	_close_button.pressed.connect(_close)


func _label(position: Vector2, size: Vector2, font_size: int) -> Label:
	var label := Label.new()
	label.position = position
	label.size = size
	label.add_theme_font_override("font", Locale.font)
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 0.92))
	_panel.add_child(label)
	return label


func _footer_button(position: Vector2, size: Vector2) -> UiButton:
	var button := UiButton.new()
	button.position = position
	button.size = size
	_panel.add_child(button)
	return button


func _refresh_texts() -> void:
	_title.text = Locale.t("settings.title")
	_language_label.text = Locale.t("settings.language")
	_binding_title.text = Locale.t("settings.bindings")
	_hint.text = Locale.t("settings.hint")

	for i in _language_buttons.size():
		var code: String = Locale.SUPPORTED[i]
		_language_buttons[i].set_caption(Locale.language_label(code))
		_language_buttons[i].set_highlight(code == Locale.current)

	for action: String in GameSettings.ACTIONS:
		var label: Label = _row_labels[action]
		label.text = Locale.t("action." + action)

	_reset_button.set_caption(Locale.t("settings.reset"))
	_save_button.set_caption(Locale.t("settings.save"))
	_close_button.set_caption(Locale.t("settings.close"))

	_combat_title.text = Locale.t("settings.combat")
	for key: String in GameSettings.COMBAT_KEYS:
		_combat_labels[key].text = Locale.t("settings." + key)

	_refresh_bindings()
	_refresh_combat()
	if _notice_time <= 0.0:
		_notice.text = Locale.t("settings.cancel") if not _capturing.is_empty() else ""


## 战斗阈值显示（含单位），语言切换后跟着刷新。
func _refresh_combat() -> void:
	for key: String in GameSettings.COMBAT_KEYS:
		var value := _combat_current(key)
		if key == "auto_attack_hold_seconds":
			_combat_values[key].text = Locale.t("settings.hold.value", [value])
		else:
			_combat_values[key].text = Locale.t("settings.taps.value", [int(round(value))])


## 用户设置优先，否则用 player.json 里的设计默认值。
func _combat_current(key: String) -> float:
	var fallback := float(DataRegistry.get_player_def().get(key, 0.0))
	return GameSettings.combat_value(key, fallback)


func _on_combat_step(key: String, direction: int) -> void:
	GameSettings.adjust_combat(key, direction, float(DataRegistry.get_player_def().get(key, 0.0)))
	_show_notice(Locale.t("settings.saved"))


func _refresh_bindings() -> void:
	for action: String in GameSettings.ACTIONS:
		var button: UiButton = _row_buttons[action]
		button.set_caption(Locale.t("settings.press") if action == _capturing else GameSettings.key_text(action))
		button.set_highlight(action == _capturing)


func _on_language_pressed(code: String) -> void:
	Locale.set_language(code)


func _on_key_pressed(action: String) -> void:
	_capturing = action
	_capture_time = 0.0
	_notice_time = 0.0
	_notice.text = Locale.t("settings.cancel")
	_refresh_bindings()


func _on_reset_pressed() -> void:
	_capturing = ""
	GameSettings.reset_defaults()
	GameSettings.reset_combat()
	_refresh_combat()
	_show_notice(Locale.t("settings.reset.done"))


func _on_save_pressed() -> void:
	GameSettings.save_to_disk()
	_show_notice(Locale.t("settings.saved"))


func _on_language_changed(_code: String) -> void:
	_refresh_texts()


func _on_bindings_changed() -> void:
	_refresh_bindings()


func _input(event: InputEvent) -> void:
	if _capturing.is_empty():
		return
	if not (event is InputEventKey):
		return
	var key := event as InputEventKey
	if not key.pressed or key.echo:
		return

	if key.physical_keycode == KEY_ESCAPE:
		_cancel_capture()
		get_viewport().set_input_as_handled()
		return

	var action := _capturing
	_capturing = ""
	var result := GameSettings.set_key(action, key.physical_keycode)
	_refresh_bindings()
	var swapped := String(result.get("swapped", ""))
	if swapped.is_empty():
		_show_notice(Locale.t("settings.saved"))
	else:
		_show_notice(Locale.t("settings.swapped", [Locale.t("action." + swapped)]))
	get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	if not _capturing.is_empty():
		_capture_time += delta
		if _capture_time >= CAPTURE_TIMEOUT:
			_cancel_capture()

	if _notice_time > 0.0:
		_notice_time = maxf(0.0, _notice_time - delta)
		if _notice_time <= 0.0:
			_notice.text = Locale.t("settings.cancel") if not _capturing.is_empty() else ""


func _cancel_capture() -> void:
	_capturing = ""
	_notice_time = 0.0
	_notice.text = ""
	_refresh_bindings()


func _show_notice(text: String) -> void:
	_notice.text = text
	_notice_time = NOTICE_DURATION


func _pause_game() -> void:
	if GameManager.is_paused:
		return
	GameManager.set_paused(true)
	_paused_by_panel = true


func _resume_game() -> void:
	if not _paused_by_panel:
		return
	_paused_by_panel = false
	GameManager.set_paused(false)


func _close() -> void:
	_resume_game()
	closed.emit()
	queue_free()
