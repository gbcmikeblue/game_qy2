extends Control

## 主菜单：新游戏 / 读取存档（3 槽）/ 设置 / 退出。
##
## 与面板同样的适配方式：设计尺寸 720×520 + 整体 scale + 安全区内缩居中。
## 真正的场景切换收口在 _enter_game()，测试可以把 game_launcher 换成空实现，
## 只验证「请求了什么」而不真切场景（切场景会销毁测试节点）。

signal game_requested

const GAME_SCENE := "res://scenes/boot/main.tscn"
const SETTINGS_PANEL := preload("res://scenes/ui/settings_panel.tscn")

const DESIGN := Vector2(720.0, 520.0)
const WIDTH_RATIO := 0.92
const HEIGHT_RATIO := 0.92
const MIN_SCALE := 0.6
const MAX_SCALE := 1.4
const BODY_MIN_DP := 14.0

const FONT_TITLE := 40
const FONT_BODY := 20
const FONT_HELPER := 17

const SLOT_ROWS := 3

var _frame: ColorRect
var _title: Label
var _new_game: UiButton
var _load_title: Label
var _slot_labels: Array[Label] = []
var _slot_buttons: Array[UiButton] = []
var _settings: UiButton
var _quit: UiButton
var _panel: Node = null

## 测试注入点：默认走 change_scene_to_file。
var game_launcher: Callable = Callable()


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build()
	Locale.language_changed.connect(_refresh_texts)
	DisplayAdapter.layout_changed.connect(_layout)
	_layout()
	_refresh_all()


func _exit_tree() -> void:
	if Locale.language_changed.is_connected(_refresh_texts):
		Locale.language_changed.disconnect(_refresh_texts)
	if DisplayAdapter.layout_changed.is_connected(_layout):
		DisplayAdapter.layout_changed.disconnect(_layout)


# ---------------- 构建 ----------------

func _build() -> void:
	var dim := ColorRect.new()
	dim.color = Color(0.06, 0.07, 0.10, 1.0)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(dim)

	_frame = ColorRect.new()
	_frame.color = Color(0.10, 0.12, 0.16, 0.98)
	_frame.size = DESIGN
	_frame.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_frame)

	_title = _label(Vector2(0.0, 40.0), Vector2(DESIGN.x, 60.0), FONT_TITLE)
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

	_new_game = _button(Vector2(210.0, 140.0), Vector2(300.0, 56.0))
	_new_game.pressed.connect(_on_new_game_pressed)

	_load_title = _label(Vector2(210.0, 212.0), Vector2(300.0, 30.0), FONT_HELPER)

	for index in SLOT_ROWS:
		var y := 248.0 + float(index) * 54.0
		var label := _label(Vector2(210.0, y + 6.0), Vector2(210.0, 34.0), FONT_HELPER)
		_slot_labels.append(label)
		var button := _button(Vector2(430.0, y), Vector2(80.0, 44.0))
		button.pressed.connect(_on_load_pressed.bind(index + 1))
		_slot_buttons.append(button)

	_settings = _button(Vector2(210.0, 424.0), Vector2(140.0, 48.0))
	_settings.pressed.connect(_on_settings_pressed)
	_quit = _button(Vector2(370.0, 424.0), Vector2(140.0, 48.0))
	_quit.pressed.connect(_on_quit_pressed)


func _layout() -> void:
	if not is_instance_valid(_frame):
		return
	var viewport := get_viewport().get_visible_rect().size
	var insets := DisplayAdapter.safe_insets
	var usable := Vector2(
		maxf(1.0, viewport.x - insets.x - insets.z),
		maxf(1.0, viewport.y - insets.y - insets.w))
	var by_space := minf(usable.x * WIDTH_RATIO / DESIGN.x, usable.y * HEIGHT_RATIO / DESIGN.y)
	var readable := DisplayAdapter.dp(BODY_MIN_DP) / float(FONT_BODY)
	var upper := minf(maxf(MAX_SCALE, readable * 1.1), 1.8)
	var factor := clampf(minf(by_space, upper), MIN_SCALE, upper)
	_frame.size = DESIGN
	_frame.scale = Vector2(factor, factor)
	var scaled := _frame.size * factor
	_frame.position = (Vector2(insets.x, insets.y) + (usable - scaled) * 0.5).round()


# ---------------- 文案与槽位 ----------------

func _refresh_texts() -> void:
	_title.text = Locale.t("menu.title")
	_new_game.set_caption(Locale.t("menu.new_game"))
	_load_title.text = Locale.t("menu.load_title")
	_settings.set_caption(Locale.t("button.settings"))
	_quit.set_caption(Locale.t("menu.quit"))
	for button: UiButton in _slot_buttons:
		button.set_caption(Locale.t("inv.load.action"))


func _refresh_slots() -> void:
	for index in _slot_labels.size():
		var slot := index + 1
		var info := SaveService.slot_info(slot)
		if info.is_empty():
			_slot_labels[index].text = Locale.t("inv.slot.empty")
		else:
			_slot_labels[index].text = Locale.t("inv.slot.summary", [
				int(info["level"]), int(info["gold"]), int(info["inventory_size"])])
		_slot_buttons[index].set_disabled(info.is_empty())


func _refresh_all() -> void:
	_refresh_texts()
	_refresh_slots()


# ---------------- 交互 ----------------

func _on_new_game_pressed() -> void:
	InventoryService.reset()
	SaveService.pending_slot = 0
	_enter_game()


func _on_load_pressed(slot: int) -> void:
	if not SaveService.has_save(slot):
		return
	# 玩家此时还不存在，读档必须推到游戏场景里做（见 main.gd）。
	SaveService.pending_slot = slot
	_enter_game()


func _enter_game() -> void:
	game_requested.emit()
	if game_launcher.is_valid():
		game_launcher.call()
		return
	get_tree().change_scene_to_file(GAME_SCENE)


func _on_settings_pressed() -> void:
	if is_instance_valid(_panel):
		return
	_panel = SETTINGS_PANEL.instantiate()
	add_child(_panel)
	if _panel.has_signal("closed"):
		_panel.closed.connect(_on_settings_closed)


func _on_settings_closed() -> void:
	_panel = null
	_refresh_all()


func _on_quit_pressed() -> void:
	get_tree().quit()


# ---------------- 验收接口 ----------------

func request_new_game() -> void:
	_on_new_game_pressed()


func request_load(slot: int) -> bool:
	if not SaveService.has_save(slot):
		return false
	_on_load_pressed(slot)
	return true


func slot_text(index: int) -> String:
	if index < 0 or index >= _slot_labels.size():
		return ""
	return _slot_labels[index].text


func load_disabled(index: int) -> bool:
	if index < 0 or index >= _slot_buttons.size():
		return true
	return _slot_buttons[index].is_disabled()


func refresh() -> void:
	_refresh_all()


# ---------------- 控件工厂 ----------------

func _label(position: Vector2, size: Vector2, font_size: int) -> Label:
	var label := Label.new()
	label.position = position
	label.size = size
	label.add_theme_font_override("font", Locale.font)
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 0.92))
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_frame.add_child(label)
	return label


func _button(position: Vector2, size: Vector2) -> UiButton:
	var button := UiButton.new()
	button.position = position
	button.size = size
	button.font_size = FONT_BODY
	_frame.add_child(button)
	return button
