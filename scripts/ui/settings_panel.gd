extends CanvasLayer

## 设置面板：语言 + 按键绑定 + 玩家战斗 + 显示（分辨率档位 / 画质 / 视野 / 界面缩放）。
## 面板打开时暂停游戏（自身 PROCESS_MODE_ALWAYS 继续工作），关闭时恢复。
## 文本全部走 Locale.t()，语言切换后面板内容即时刷新。
##
## 布局（§7）：标题/语言/提示/页脚固定，中间内容区放进 ScrollContainer。
## 所有坐标都是「设计尺寸 640×668」坐标系里的值，整体靠 scale 适配视口。

signal closed

## 面板框架设计尺寸：只包含「标题 + 滚动视口 + 提示 + 页脚」，
## 高度远小于内容高度（内容靠 ScrollContainer 滚动）。
## 这样面板缩放由「字要多大」决定，而不是被整块内容压到 0.67 倍导致 7dp 字号。
const PANEL_DESIGN := Vector2(640.0, 480.0)
## 面板占可用区的比例（内容可滚动后不再需要留大边距）。
const PANEL_WIDTH_RATIO := 0.92
const PANEL_HEIGHT_RATIO := 0.95
const PANEL_MAX_SCALE := 1.2
const PANEL_MIN_SCALE := 0.6
## 正文可读性下限（dp）。手机上为满足它会临时抬高缩放上限。
const BODY_MIN_DP := 14.0

## 文字角色（设计单位，随面板整体缩放）。正文 20 号在手机上面板缩放约 1.19 → 14.6dp。
const FONT_TITLE := 30
const FONT_SECTION := 22
const FONT_BODY := 20
const FONT_HELPER := 17

## 固定区：标题/语言在上，提示与页脚在下；中间给滚动区。
const SCROLL_RECT := Rect2(12.0, 104.0, 616.0, 290.0)
const NOTICE_RECT := Rect2(28.0, 400.0, 584.0, 28.0)
const FOOTER_TOP := 436.0

## 滚动内容（坐标相对内容容器，宽度 600）。
const BODY_WIDTH := 600.0
const BINDING_TITLE_TOP := 0.0
const BINDING_ROW_TOP := 40.0
const ROW_HEIGHT := 40.0
const COMBAT_TITLE_TOP := 254.0
const COMBAT_ROW_TOP := 292.0
const HINT_TOP := 382.0
const DISPLAY_TITLE_TOP := 420.0
const PRESET_COLUMNS := 2
const PRESET_BUTTON_WIDTH := 286.0
const PRESET_BUTTON_HEIGHT := 40.0
const PRESET_ROW_HEIGHT := 46.0
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
var _audio_title: Label
var _sfx_toggle: UiButton
var _sfx_volume_label: Label
var _sfx_volume_value: Label
var _preset_buttons: Dictionary = {}
var _quality_buttons: Dictionary = {}
var _view_buttons: Dictionary = {}
var _reset_button: UiButton
var _save_button: UiButton
var _close_button: UiButton

var _capturing := ""
var _capture_time := 0.0
var _notice_time := 0.0


func _ready() -> void:
	layer = 10
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build()
	Locale.language_changed.connect(_on_language_changed)
	GameSettings.bindings_changed.connect(_on_bindings_changed)
	GameSettings.combat_changed.connect(_refresh_combat)
	GameSettings.display_changed.connect(_refresh_display)
	GameSettings.audio_changed.connect(_refresh_audio)
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
	if GameSettings.audio_changed.is_connected(_refresh_audio):
		GameSettings.audio_changed.disconnect(_refresh_audio)
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
	# 空间允许的最大缩放。
	var by_space := minf(
		usable.x * PANEL_WIDTH_RATIO / PANEL_DESIGN.x,
		usable.y * PANEL_HEIGHT_RATIO / PANEL_DESIGN.y)
	# 可读性要求的最小缩放：正文至少要 BODY_MIN_DP。
	var readable := DisplayAdapter.dp(BODY_MIN_DP) / float(FONT_BODY)
	# 上限按「口径」而不是平台判定：dp 越大（手机）越需要更大的缩放，
	# 桌面（96dpi，1 逻辑像素 ≈ 1.67dp）则停在 1.2 就够大。绝对上限 1.6 防止离谱。
	var upper := minf(maxf(PANEL_MAX_SCALE, readable * 1.1), 1.6)
	var scale_factor := clampf(minf(by_space, upper), PANEL_MIN_SCALE, upper)
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

	_title = _label(Vector2(28.0, 8.0), Vector2(560.0, 46.0), FONT_TITLE, _panel)
	_language_label = _label(Vector2(28.0, 60.0), Vector2(240.0, 34.0), FONT_SECTION, _panel)
	var index := 0
	for code: String in Locale.SUPPORTED:
		var button := _button(_panel, Vector2(300.0 + float(index) * 150.0, 56.0),
				Vector2(132.0, 40.0))
		button.pressed.connect(_on_language_pressed.bind(code))
		_language_buttons.append(button)
		index += 1

	_notice = _label(NOTICE_RECT.position, NOTICE_RECT.size, FONT_HELPER, _panel)

	_reset_button = _button(_panel, Vector2(28.0, FOOTER_TOP), Vector2(168.0, 42.0))
	_reset_button.pressed.connect(_on_reset_pressed)
	_save_button = _button(_panel, Vector2(212.0, FOOTER_TOP), Vector2(140.0, 42.0))
	_save_button.pressed.connect(_on_save_pressed)
	_close_button = _button(_panel, Vector2(368.0, FOOTER_TOP), Vector2(160.0, 42.0))
	_close_button.pressed.connect(_close)

	_binding_title = _label(Vector2(28.0, BINDING_TITLE_TOP), Vector2(560.0, 32.0), FONT_SECTION)
	var row := 0
	for action: String in GameSettings.ACTIONS:
		var y := BINDING_ROW_TOP + float(row) * ROW_HEIGHT
		_row_labels[action] = _label(Vector2(40.0, y), Vector2(300.0, 34.0), FONT_BODY)
		var key_button := _button(_body, Vector2(352.0, y - 2.0), Vector2(208.0, 34.0))
		key_button.pressed.connect(_on_key_pressed.bind(action))
		_row_buttons[action] = key_button
		row += 1

	_combat_title = _label(Vector2(28.0, COMBAT_TITLE_TOP), Vector2(560.0, 32.0), FONT_SECTION)
	var combat_row := 0
	for key: String in GameSettings.COMBAT_KEYS:
		var y := COMBAT_ROW_TOP + float(combat_row) * ROW_HEIGHT
		_combat_labels[key] = _label(Vector2(40.0, y), Vector2(300.0, 34.0), FONT_BODY)
		var minus := _button(_body, Vector2(348.0, y - 2.0), Vector2(44.0, 34.0))
		minus.set_caption("-")
		minus.pressed.connect(_on_combat_step.bind(key, -1))
		var value := _label(Vector2(400.0, y), Vector2(124.0, 34.0), FONT_BODY)
		value.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_combat_values[key] = value
		var plus := _button(_body, Vector2(532.0, y - 2.0), Vector2(44.0, 34.0))
		plus.set_caption("+")
		plus.pressed.connect(_on_combat_step.bind(key, 1))
		combat_row += 1

	_hint = _label(Vector2(28.0, HINT_TOP), Vector2(560.0, 26.0), FONT_HELPER)

	_build_display_section()


## 「显示」区块：分辨率档位（仅桌面）+ 档位说明 + 画质 + 视野 + 界面缩放 + 窗口状态提示。
## 移动端没有窗口尺寸可选，整块档位区直接跳过并把后面的行往上收（方案 §7.3）。
func _build_display_section() -> void:
	_display_title = _label(Vector2(28.0, DISPLAY_TITLE_TOP), Vector2(560.0, 32.0), FONT_SECTION)
	var y := DISPLAY_TITLE_TOP + 36.0

	if not DisplayAdapter.is_mobile():
		var ids := DisplayAdapter.preset_ids()
		for i in ids.size():
			var column := i % PRESET_COLUMNS
			var line := i / PRESET_COLUMNS
			var position := Vector2(
				float(column) * (PRESET_BUTTON_WIDTH + 14.0),
				y + float(line) * PRESET_ROW_HEIGHT)
			var button := _button(_body, position,
				Vector2(PRESET_BUTTON_WIDTH, PRESET_BUTTON_HEIGHT))
			var id := ids[i]
			button.pressed.connect(_on_preset_pressed.bind(id))
			_preset_buttons[id] = button

		var rows := ceili(float(ids.size()) / float(PRESET_COLUMNS))
		y += float(rows) * PRESET_ROW_HEIGHT + 6.0
		_preset_info = _label(Vector2(28.0, y), Vector2(560.0, 58.0), FONT_HELPER)
		_preset_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_preset_info.add_theme_color_override("font_color", Color(0.80, 0.88, 1.0, 1.0))
		y += 64.0

	_quality_title = _label(Vector2(28.0, y), Vector2(560.0, 32.0), FONT_SECTION)
	y += 34.0
	var quality_row := 0
	for tier: String in GameSettings.QUALITY_TIERS:
		var button := _button(_body,
				Vector2(float(quality_row) * 145.0, y), Vector2(136.0, 36.0))
		button.pressed.connect(_on_quality_pressed.bind(tier))
		_quality_buttons[tier] = button
		quality_row += 1
	y += 44.0

	_view_title = _label(Vector2(28.0, y), Vector2(560.0, 32.0), FONT_SECTION)
	y += 34.0
	var view_row := 0
	for key: String in DisplayAdapter.VIEW_SCALES:
		var button := _button(_body, Vector2(float(view_row) * 191.0, y), Vector2(182.0, 36.0))
		button.pressed.connect(_on_view_pressed.bind(key))
		_view_buttons[key] = button
		view_row += 1
	y += 44.0

	_ui_scale_label = _label(Vector2(40.0, y), Vector2(280.0, 34.0), FONT_BODY)
	var minus := _button(_body, Vector2(348.0, y - 2.0), Vector2(44.0, 34.0))
	minus.set_caption("-")
	minus.pressed.connect(_on_ui_scale_step.bind(-1))
	_ui_scale_value = _label(Vector2(400.0, y), Vector2(124.0, 34.0), FONT_BODY)
	_ui_scale_value.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var plus := _button(_body, Vector2(532.0, y - 2.0), Vector2(44.0, 34.0))
	plus.set_caption("+")
	plus.pressed.connect(_on_ui_scale_step.bind(1))
	y += 42.0

	_free_note = _label(Vector2(28.0, y), Vector2(560.0, 48.0), FONT_HELPER)
	_free_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART

	# 音频（只做 SFX，BGM 未做）：开关 + 三档音量。
	y += 56.0
	_audio_title = _label(Vector2(28.0, y), Vector2(560.0, 32.0), FONT_SECTION)
	y += 34.0
	_sfx_toggle = _button(_body, Vector2(28.0, y - 2.0), Vector2(182.0, 36.0))
	_sfx_toggle.pressed.connect(_on_sfx_toggle)
	y += 44.0
	_sfx_volume_label = _label(Vector2(40.0, y), Vector2(280.0, 34.0), FONT_BODY)
	var vol_minus := _button(_body, Vector2(348.0, y - 2.0), Vector2(44.0, 34.0))
	vol_minus.set_caption("-")
	vol_minus.pressed.connect(_on_sfx_volume_step.bind(-1))
	_sfx_volume_value = _label(Vector2(400.0, y), Vector2(124.0, 34.0), FONT_BODY)
	_sfx_volume_value.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var vol_plus := _button(_body, Vector2(532.0, y - 2.0), Vector2(44.0, 34.0))
	vol_plus.set_caption("+")
	vol_plus.pressed.connect(_on_sfx_volume_step.bind(1))
	y += 44.0

	# 内容变长后同步滚动区高度，否则底部音频项会被裁掉。
	_body.custom_minimum_size = Vector2(BODY_WIDTH, maxf(BODY_HEIGHT, y + 40.0))
	_body.size = _body.custom_minimum_size


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
	button.font_size = FONT_BODY
	parent.add_child(button)
	return button


func _on_sfx_toggle() -> void:
	GameSettings.toggle_sfx()
	_refresh_audio()


func _on_sfx_volume_step(direction: int) -> void:
	GameSettings.adjust_sfx_volume(direction)
	_refresh_audio()


## 音频行：开关文案 + 音量百分比（0% 也允许，等同静音）。
func _refresh_audio() -> void:
	if _sfx_toggle == null or _sfx_volume_value == null:
		return
	var on := bool(GameSettings.audio_value("sfx_enabled"))
	_sfx_toggle.set_caption(Locale.t("settings.sfx.on" if on else "settings.sfx.off"))
	_sfx_toggle.set_highlight(on)
	_sfx_volume_value.text = Locale.t("settings.sfx.volume.value",
			[int(round(float(GameSettings.audio_value("sfx_volume")) * 100.0))])


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
	_audio_title.text = Locale.t("settings.audio")
	_sfx_volume_label.text = Locale.t("settings.sfx.volume")
	_refresh_audio()

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

	# 档位说明只在桌面存在（移动端跳过整块档位区）。
	if is_instance_valid(_preset_info):
		var window_size := DisplayAdapter.target_window_size(current_preset)
		var render := DisplayAdapter.render_size_for(
			Vector2(window_size), DisplayAdapter.render_scale())
		var tiles := DisplayAdapter.visible_tiles(render, DisplayAdapter.view_area_scale)
		_preset_info.text = "%s\n%s" % [
			Locale.t("display.preset." + current_preset + ".hint"),
			Locale.t("display.info", [window_size.x, window_size.y,
				int(render.x), int(render.y), int(round(tiles))]),
		]

	_free_note.text = _window_note_text()


## 窗口状态提示：移动端由系统全屏决定；桌面区分调试自由缩放与发布锁定。
func _window_note_text() -> String:
	if DisplayAdapter.is_mobile():
		return Locale.t("display.mobile")
	return Locale.t("display.free_resize") if DisplayAdapter.free_resize \
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


## 面板只持有自己的「设置」暂停原因：切后台、手动 ESC 等其它原因不影响它，
## 反过来它关闭时也不会把别的暂停原因一起解掉。
func _pause_game() -> void:
	GameManager.hold_pause(GameManager.PAUSE_SETTINGS)


func _resume_game() -> void:
	GameManager.release_pause(GameManager.PAUSE_SETTINGS)


func _close() -> void:
	_resume_game()
	closed.emit()
	queue_free()
