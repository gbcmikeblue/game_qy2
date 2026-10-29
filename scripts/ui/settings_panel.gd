extends CanvasLayer

## 设置面板：语言 + 按键绑定 + 玩家战斗 + 显示（分辨率档位 / 画质 / 视野 / 界面缩放）。
## 面板打开时暂停游戏（自身 PROCESS_MODE_ALWAYS 继续工作），关闭时恢复。
## 文本全部走 Locale.t()，语言切换后面板内容即时刷新。
##
## 布局（§7）：标题/语言/提示/页脚固定，中间内容区放进 ScrollContainer。
## 所有坐标都是「设计尺寸 640×668」坐标系里的值，整体靠 scale 适配视口。

signal closed

## 面板设计尺寸（1280×720 逻辑基准下的排版坐标系，内部子控件都按它摆位）。
const PANEL_DESIGN := Vector2(640.0, 668.0)
## 面板占视口的相对尺寸与最大放大倍数（§3.5：居中锚点 + 相对尺寸，小屏不溢界、大屏不过小）。
const PANEL_WIDTH_RATIO := 0.7
const PANEL_HEIGHT_RATIO := 0.75
const PANEL_MAX_SCALE := 1.2
const PANEL_MIN_SCALE := 0.4

## 固定区：标题/语言在上，提示与页脚在下；中间给滚动区。
const HEADER_HEIGHT := 108.0
const SCROLL_RECT := Rect2(12.0, 108.0, 616.0, 444.0)
const NOTICE_RECT := Rect2(28.0, 558.0, 584.0, 26.0)
const FOOTER_TOP := 596.0

## 滚动内容（坐标相对内容容器，宽度 600）。
const BODY_WIDTH := 600.0
const BINDING_TITLE_TOP := 0.0
const BINDING_ROW_TOP := 40.0
const ROW_HEIGHT := 40.0
const COMBAT_TITLE_TOP := 254.0
const COMBAT_ROW_TOP := 292.0
const HINT_TOP := 382.0
const DISPLAY_TITLE_TOP := 420.0
const PRESET_GRID_TOP := 456.0
const PRESET_COLUMNS := 2
const PRESET_BUTTON_WIDTH := 286.0
const PRESET_BUTTON_HEIGHT := 40.0
const PRESET_ROW_HEIGHT := 46.0
const PRESET_INFO_TOP := 644.0
const QUALITY_TITLE_TOP := 704.0
const QUALITY_ROW_TOP := 738.0
const VIEW_TITLE_TOP := 788.0
const VIEW_ROW_TOP := 822.0
const UI_SCALE_ROW_TOP := 872.0
const FREE_NOTE_TOP := 918.0
const BODY_HEIGHT := 1000.0

const CAPTURE_TIMEOUT := 6.0
const NOTICE_DURATION := 2.0

var _panel: ColorRect
var _scroll: ScrollContainer
var _body: Control
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
var _display_title: Label
var _preset_info: Label
var _quality_title: Label
var _view_title: Label
var _ui_scale_label: Label
var _ui_scale_value: Label
var _free_note: Label
var _preset_buttons: Dictionary = {}
var _quality_buttons: Dictionary = {}
var _view_buttons: Dictionary = {}
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
	GameSettings.display_changed.connect(_refresh_display)
	DisplayAdapter.layout_changed.connect(_layout)
	_refresh_texts()
	_pause_game()


func _exit_tree() -> void:
	if Locale.language_changed.is_connected(_on_language_changed):
		Locale.language_changed.disconnect(_on_language_changed)
	if GameSettings.bindings_changed.is_connected(_on_bindings_changed):
		GameSettings.bindings_changed.disconnect(_on_bindings_changed)
	if GameSettings.combat_changed.is_connected(_refresh_combat):
		GameSettings.combat_changed.disconnect(_refresh_combat)
	if GameSettings.display_changed.is_connected(_refresh_display):
		GameSettings.display_changed.disconnect(_refresh_display)
	if DisplayAdapter.layout_changed.is_connected(_layout):
		DisplayAdapter.layout_changed.disconnect(_layout)
	_resume_game()


## 居中 + 相对尺寸：面板宽度占视口 70%、高度占 75%，内部按设计尺寸等比缩放。
## 安全区内缩后居中，避免刘海/手势条压住面板边缘的按钮。
func _layout() -> void:
	if not is_instance_valid(_panel):
		return
	var viewport := get_viewport().get_visible_rect().size
	var insets := DisplayAdapter.safe_insets
	var usable := Vector2(
		maxf(1.0, viewport.x - insets.x - insets.z),
		maxf(1.0, viewport.y - insets.y - insets.w))
	var scale_factor := minf(
		usable.x * PANEL_WIDTH_RATIO / PANEL_DESIGN.x,
		usable.y * PANEL_HEIGHT_RATIO / PANEL_DESIGN.y)
	scale_factor = clampf(scale_factor, PANEL_MIN_SCALE, PANEL_MAX_SCALE)
	# 面板本体保持设计尺寸，用 scale 整体缩放：内部子控件坐标一个不用改。
	_panel.size = PANEL_DESIGN
	_panel.scale = Vector2(scale_factor, scale_factor)
	var scaled := _panel.size * scale_factor
	_panel.position = (Vector2(insets.x, insets.y) + (usable - scaled) * 0.5).round()


func _build() -> void:
	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.62)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)

	_panel = ColorRect.new()
	_panel.color = Color(0.10, 0.12, 0.16, 0.98)
	_panel.size = PANEL_DESIGN
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_panel)
	_layout()

	# 中间内容可滚动：设置项变多后不再挤爆固定高度。
	_scroll = ScrollContainer.new()
	_scroll.position = SCROLL_RECT.position
	_scroll.size = SCROLL_RECT.size
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_scroll.scroll_deadzone = 8
	_panel.add_child(_scroll)

	_body = Control.new()
	_body.custom_minimum_size = Vector2(BODY_WIDTH, BODY_HEIGHT)
	_body.size = Vector2(BODY_WIDTH, BODY_HEIGHT)
	_body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_scroll.add_child(_body)

	_title = _label(Vector2(28.0, 14.0), Vector2(560.0, 40.0), 28, _panel)
	_language_label = _label(Vector2(28.0, 62.0), Vector2(240.0, 32.0), 20, _panel)
	var index := 0
	for code: String in Locale.SUPPORTED:
		var button := _button(_panel, Vector2(300.0 + float(index) * 150.0, 58.0),
				Vector2(132.0, 40.0))
		button.pressed.connect(_on_language_pressed.bind(code))
		_language_buttons.append(button)
		index += 1

	_notice = _label(NOTICE_RECT.position, NOTICE_RECT.size, 16, _panel)

	_reset_button = _button(_panel, Vector2(28.0, FOOTER_TOP), Vector2(168.0, 42.0))
	_reset_button.pressed.connect(_on_reset_pressed)
	_save_button = _button(_panel, Vector2(212.0, FOOTER_TOP), Vector2(140.0, 42.0))
	_save_button.pressed.connect(_on_save_pressed)
	_close_button = _button(_panel, Vector2(368.0, FOOTER_TOP), Vector2(160.0, 42.0))
	_close_button.pressed.connect(_close)

	_binding_title = _label(Vector2(28.0, BINDING_TITLE_TOP), Vector2(560.0, 32.0), 20)
	var row := 0
	for action: String in GameSettings.ACTIONS:
		var y := BINDING_ROW_TOP + float(row) * ROW_HEIGHT
		_row_labels[action] = _label(Vector2(40.0, y), Vector2(300.0, 34.0), 18)
		var key_button := _button(_body, Vector2(352.0, y - 2.0), Vector2(208.0, 34.0))
		key_button.pressed.connect(_on_key_pressed.bind(action))
		_row_buttons[action] = key_button
		row += 1

	_combat_title = _label(Vector2(28.0, COMBAT_TITLE_TOP), Vector2(560.0, 32.0), 20)
	var combat_row := 0
	for key: String in GameSettings.COMBAT_KEYS:
		var y := COMBAT_ROW_TOP + float(combat_row) * ROW_HEIGHT
		_combat_labels[key] = _label(Vector2(40.0, y), Vector2(300.0, 34.0), 18)
		var minus := _button(_body, Vector2(348.0, y - 2.0), Vector2(44.0, 34.0))
		minus.set_caption("-")
		minus.pressed.connect(_on_combat_step.bind(key, -1))
		var value := _label(Vector2(400.0, y), Vector2(124.0, 34.0), 18)
		value.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_combat_values[key] = value
		var plus := _button(_body, Vector2(532.0, y - 2.0), Vector2(44.0, 34.0))
		plus.set_caption("+")
		plus.pressed.connect(_on_combat_step.bind(key, 1))
		combat_row += 1

	_hint = _label(Vector2(28.0, HINT_TOP), Vector2(560.0, 26.0), 15)

	_build_display_section()


## 「显示」区块：分辨率档位（2 列网格）+ 档位说明 + 画质 + 视野 + 界面缩放 + 窗口状态提示。
func _build_display_section() -> void:
	_display_title = _label(Vector2(28.0, DISPLAY_TITLE_TOP), Vector2(560.0, 32.0), 20)

	var ids := DisplayAdapter.preset_ids()
	for i in ids.size():
		var column := i % PRESET_COLUMNS
		var line := i / PRESET_COLUMNS
		var position := Vector2(
			float(column) * (PRESET_BUTTON_WIDTH + 14.0),
			PRESET_GRID_TOP + float(line) * PRESET_ROW_HEIGHT)
		var button := _button(_body, position, Vector2(PRESET_BUTTON_WIDTH, PRESET_BUTTON_HEIGHT))
		var id := ids[i]
		button.pressed.connect(_on_preset_pressed.bind(id))
		_preset_buttons[id] = button

	_preset_info = _label(Vector2(28.0, PRESET_INFO_TOP), Vector2(560.0, 58.0), 16)
	_preset_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_preset_info.add_theme_color_override("font_color", Color(0.80, 0.88, 1.0, 1.0))

	_quality_title = _label(Vector2(28.0, QUALITY_TITLE_TOP), Vector2(560.0, 32.0), 20)
	var quality_row := 0
	for tier: String in GameSettings.QUALITY_TIERS:
		var button := _button(_body,
				Vector2(float(quality_row) * 145.0, QUALITY_ROW_TOP), Vector2(136.0, 36.0))
		button.pressed.connect(_on_quality_pressed.bind(tier))
		_quality_buttons[tier] = button
		quality_row += 1

	_view_title = _label(Vector2(28.0, VIEW_TITLE_TOP), Vector2(560.0, 32.0), 20)
	var view_row := 0
	for key: String in DisplayAdapter.VIEW_SCALES:
		var button := _button(_body,
				Vector2(float(view_row) * 191.0, VIEW_ROW_TOP), Vector2(182.0, 36.0))
		button.pressed.connect(_on_view_pressed.bind(key))
		_view_buttons[key] = button
		view_row += 1

	_ui_scale_label = _label(Vector2(40.0, UI_SCALE_ROW_TOP), Vector2(280.0, 34.0), 18)
	var minus := _button(_body, Vector2(348.0, UI_SCALE_ROW_TOP - 2.0), Vector2(44.0, 34.0))
	minus.set_caption("-")
	minus.pressed.connect(_on_ui_scale_step.bind(-1))
	_ui_scale_value = _label(Vector2(400.0, UI_SCALE_ROW_TOP), Vector2(124.0, 34.0), 18)
	_ui_scale_value.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var plus := _button(_body, Vector2(532.0, UI_SCALE_ROW_TOP - 2.0), Vector2(44.0, 34.0))
	plus.set_caption("+")
	plus.pressed.connect(_on_ui_scale_step.bind(1))

	_free_note = _label(Vector2(28.0, FREE_NOTE_TOP), Vector2(560.0, 48.0), 15)
	_free_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART


## 建标签：默认加进滚动内容，header/footer 里的固定标签显式传 _panel。
func _label(position: Vector2, size: Vector2, font_size: int, parent: Control = null) -> Label:
	var label := Label.new()
	label.position = position
	label.size = size
	label.add_theme_font_override("font", Locale.font)
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 0.92))
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var host := parent if parent != null else _body
	host.add_child(label)
	return label


func _button(parent: Control, position: Vector2, size: Vector2) -> UiButton:
	var button := UiButton.new()
	button.position = position
	button.size = size
	parent.add_child(button)
	return button


func _refresh_texts() -> void:
	_title.text = Locale.t("settings.title")
	_language_label.text = Locale.t("settings.language")
	_binding_title.text = Locale.t("settings.bindings")
	_hint.text = Locale.t("settings.hint")
	_combat_title.text = Locale.t("settings.combat")
	_display_title.text = Locale.t("display.title")
	_quality_title.text = Locale.t("display.quality")
	_view_title.text = Locale.t("display.view")
	_ui_scale_label.text = Locale.t("display.ui_scale")

	for i in _language_buttons.size():
		var code: String = Locale.SUPPORTED[i]
		_language_buttons[i].set_caption(Locale.language_label(code))
		_language_buttons[i].set_highlight(code == Locale.current)

	for action: String in GameSettings.ACTIONS:
		var label: Label = _row_labels[action]
		label.text = Locale.t("action." + action)

	for key: String in GameSettings.COMBAT_KEYS:
		_combat_labels[key].text = Locale.t("settings." + key)

	for tier: String in _quality_buttons:
		_quality_buttons[tier].set_caption(Locale.t("display.quality." + tier))
	for key: String in _view_buttons:
		_view_buttons[key].set_caption(Locale.t("display.view." + key))
	for id: String in _preset_buttons:
		_preset_buttons[id].set_caption(Locale.t("display.preset." + id))

	_reset_button.set_caption(Locale.t("settings.reset"))
	_save_button.set_caption(Locale.t("settings.save"))
	_close_button.set_caption(Locale.t("settings.close"))

	_refresh_bindings()
	_refresh_combat()
	_refresh_display()
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


## 显示区块：高亮当前档位、禁用放不下的档位、刷新档位说明与窗口状态提示。
func _refresh_display() -> void:
	var screen_limit := DisplayAdapter.screen_limit()
	# 用「实际生效」的档位高亮：保存值在当前显示器放不下时 DisplayAdapter 会回退。
	var current_preset := DisplayAdapter.resolution_preset
	for id: String in _preset_buttons:
		var button: UiButton = _preset_buttons[id]
		button.set_disabled(not DisplayAdapter.preset_fits(id, screen_limit))
		button.set_highlight(id == current_preset)

	var current_quality := GameSettings.display_quality()
	for tier: String in _quality_buttons:
		_quality_buttons[tier].set_highlight(
			tier == current_quality or (tier == "auto" and current_quality == "auto"))

	var view_scale := GameSettings.display_view_scale()
	for key: String in _view_buttons:
		_view_buttons[key].set_highlight(is_equal_approx(
			float(DisplayAdapter.VIEW_SCALES[key]), view_scale))

	_ui_scale_value.text = Locale.t("display.ui_scale.value", [GameSettings.display_ui_scale()])

	var window_size := DisplayAdapter.target_window_size(current_preset)
	var render := DisplayAdapter.render_size_for(
		Vector2(window_size), DisplayAdapter.render_scale())
	var tiles := DisplayAdapter.visible_tiles(render, DisplayAdapter.view_area_scale)
	_preset_info.text = "%s\n%s" % [
		Locale.t("display.preset." + current_preset + ".hint"),
		Locale.t("display.info", [window_size.x, window_size.y,
			int(render.x), int(render.y), int(round(tiles))]),
	]
	_free_note.text = Locale.t("display.free_resize") if DisplayAdapter.free_resize \
		else Locale.t("display.locked")


func _combat_current(key: String) -> float:
	var fallback := float(DataRegistry.get_player_def().get(key, 0.0))
	return GameSettings.combat_value(key, fallback)


func _on_combat_step(key: String, direction: int) -> void:
	GameSettings.adjust_combat(
		key, direction, float(DataRegistry.get_player_def().get(key, 0.0)))
	_show_notice(Locale.t("settings.saved"))


func _on_preset_pressed(id: String) -> void:
	if not DisplayAdapter.preset_fits(id, DisplayAdapter.screen_limit()):
		_show_notice(Locale.t("display.unavailable"))
		return
	GameSettings.set_display_value("resolution_preset", id)
	_show_notice(Locale.t("display.applied"))


func _on_quality_pressed(tier: String) -> void:
	GameSettings.set_display_value("quality_tier", tier)
	_show_notice(Locale.t("display.applied"))


func _on_view_pressed(key: String) -> void:
	GameSettings.set_display_value(
		"view_area_scale", float(DisplayAdapter.VIEW_SCALES[key]))
	_show_notice(Locale.t("display.applied"))


func _on_ui_scale_step(direction: int) -> void:
	GameSettings.adjust_ui_scale(direction)
	_show_notice(Locale.t("display.applied"))


func _refresh_bindings() -> void:
	for action: String in GameSettings.ACTIONS:
		var button: UiButton = _row_buttons[action]
		button.set_caption(Locale.t("settings.press") if action == _capturing
			else GameSettings.key_text(action))
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
	GameSettings.reset_display()
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
