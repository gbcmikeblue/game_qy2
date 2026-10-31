extends CanvasLayer

## NPC 对话面板（底部对话框）：显示台词 + 按情境给按钮（交易 / 接取 / 交付 / 离开）。
##
## 与背包面板的区别：
##   · 只做「一次交互」，不承载数据列表，所以固定在底部而不是居中大面板；
##   · 按钮由数据决定（有商店才显示交易、有可接任务才显示接取），不在场景里写死；
##   · 暂停原因用 PAUSE_DIALOGUE，与设置/背包各自独立，谁先关谁释放自己那条。

signal closed
signal trade_requested(shop_id: StringName)

const DESIGN := Vector2(720.0, 200.0)
const WIDTH_RATIO := 0.94
const HEIGHT_RATIO := 0.42
const MIN_SCALE := 0.6
const MAX_SCALE := 1.4
const BODY_MIN_DP := 14.0

const FONT_NAME := 22
const FONT_BODY := 19
const FONT_BUTTON := 18
const BODY_MIN_DP_REF := 19.0

const BUTTON_WIDTH := 108.0
const BUTTON_HEIGHT := 38.0
const BUTTON_GAP := 8.0

## 由 main 在 add_child 之前注入。
var npc: Node2D = null
var speaker_name_key := ""
var dialogue_key := ""
var shop_id: StringName = &""
var quest_giver := false

var _panel: ColorRect
var _name_label: Label
var _body_label: Label
var _actions_host: Control
var _hint: Label
var _actions: Array[String] = []
var _buttons: Array[UiButton] = []
var _hint_left := 0.0


func _ready() -> void:
	layer = 10
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build()
	_locale_and_signals()
	_pause_game()
	_refresh_all()


func _exit_tree() -> void:
	if Locale.language_changed.is_connected(_on_language_changed):
		Locale.language_changed.disconnect(_on_language_changed)
	if DisplayAdapter.layout_changed.is_connected(_layout):
		DisplayAdapter.layout_changed.disconnect(_layout)
	if EventBus.quest_updated.is_connected(_on_quest_changed):
		EventBus.quest_updated.disconnect(_on_quest_changed)
	_resume_game()


func _process(delta: float) -> void:
	if _hint_left <= 0.0:
		return
	_hint_left -= delta
	if _hint_left <= 0.0:
		_hint.text = ""


# ---------------- 构建 ----------------

func _build() -> void:
	var dim := ColorRect.new()
	dim.color = Color(0.02, 0.03, 0.05, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)

	_panel = ColorRect.new()
	_panel.color = Color(0.10, 0.12, 0.16, 0.97)
	_panel.size = DESIGN
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_panel)

	_name_label = _label(Vector2(24.0, 14.0), Vector2(360.0, 30.0), FONT_NAME)
	_name_label.add_theme_color_override("font_color", Color(1.0, 0.86, 0.55))

	_body_label = _label(Vector2(24.0, 50.0), Vector2(520.0, 108.0), FONT_BODY)
	_body_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART

	_actions_host = Control.new()
	_actions_host.position = Vector2(560.0, 16.0)
	_actions_host.size = Vector2(BUTTON_WIDTH, DESIGN.y - 32.0)
	_actions_host.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(_actions_host)

	_hint = _label(Vector2(24.0, DESIGN.y - 34.0), Vector2(520.0, 26.0), FONT_BUTTON)
	_hint.add_theme_color_override("font_color", Color(0.70, 0.90, 0.70))


func _layout() -> void:
	if not is_instance_valid(_panel):
		return
	var viewport := get_viewport().get_visible_rect().size
	var insets := DisplayAdapter.safe_insets
	var usable := Vector2(
		maxf(1.0, viewport.x - insets.x - insets.z),
		maxf(1.0, viewport.y - insets.y - insets.w))
	var by_space := minf(usable.x * WIDTH_RATIO / DESIGN.x, usable.y * HEIGHT_RATIO / DESIGN.y)
	var readable := DisplayAdapter.dp(BODY_MIN_DP) / BODY_MIN_DP_REF
	var upper := minf(maxf(MAX_SCALE, readable * 1.1), 1.8)
	var factor := clampf(minf(by_space, upper), MIN_SCALE, upper)
	_panel.size = DESIGN
	_panel.scale = Vector2(factor, factor)
	var scaled := DESIGN * factor
	# 底部对齐（留安全区），水平居中。
	_panel.position = Vector2(
		insets.x + (usable.x - scaled.x) * 0.5,
		insets.y + usable.y - scaled.y - 12.0).round()


func _locale_and_signals() -> void:
	Locale.language_changed.connect(_on_language_changed)
	DisplayAdapter.layout_changed.connect(_layout)
	EventBus.quest_updated.connect(_on_quest_changed)
	_layout()


func _pause_game() -> void:
	GameManager.hold_pause(GameManager.PAUSE_DIALOGUE)


func _resume_game() -> void:
	GameManager.release_pause(GameManager.PAUSE_DIALOGUE)


# ---------------- 文案与按钮 ----------------

func _refresh_all() -> void:
	_refresh_texts()
	_refresh_actions()


func _refresh_texts() -> void:
	var name_key := speaker_name_key if not speaker_name_key.is_empty() else "npc.merchant.name"
	_name_label.text = Locale.t(name_key)
	var body := dialogue_key if not dialogue_key.is_empty() else "dialogue.default"
	_body_label.text = Locale.t(body)


## 按钮由情境决定，顺序固定：交易 → 接取 → 交付 → 离开。
func _refresh_actions() -> void:
	for child: Node in _actions_host.get_children():
		_actions_host.remove_child(child)
		child.queue_free()
	_actions.clear()
	_buttons.clear()

	if shop_id != &"":
		_actions.append("trade")
	if quest_giver and not QuestService.available_quests().is_empty():
		_actions.append("accept")
	if quest_giver and not QuestService.turn_in_quests().is_empty():
		_actions.append("turn_in")
	_actions.append("leave")

	for index in _actions.size():
		var button := _button(Vector2(0.0, float(index) * (BUTTON_HEIGHT + BUTTON_GAP)),
				Vector2(BUTTON_WIDTH, BUTTON_HEIGHT))
		button.set_caption(_action_caption(_actions[index]))
		button.pressed.connect(_on_action_pressed.bind(_actions[index]))
		_buttons.append(button)


func _action_caption(action: String) -> String:
	match action:
		"trade":
			return Locale.t("dialogue.trade")
		"accept":
			return Locale.t("dialogue.accept")
		"turn_in":
			return Locale.t("dialogue.turn_in")
		_:
			return Locale.t("dialogue.leave")


func _on_action_pressed(action: String) -> void:
	match action:
		"trade":
			trade_requested.emit(shop_id)
			_close()
		"accept":
			_accept_quest()
		"turn_in":
			_turn_in_quest()
		_:
			_close()


func _accept_quest() -> void:
	var available := QuestService.available_quests()
	if available.is_empty():
		_show_hint(Locale.t("dialogue.no_quest"))
		return
	var quest: Dictionary = available[0]
	if QuestService.accept(String(quest["id"])):
		_show_hint(Locale.t("dialogue.accepted",
				[Locale.t(String(quest.get("title_key", "quest.unknown.title")))]))
		_refresh_actions()


func _turn_in_quest() -> void:
	var ready := QuestService.turn_in_quests()
	if ready.is_empty():
		return
	var quest: Dictionary = ready[0]
	if QuestService.turn_in(String(quest["id"])):
		_show_hint(Locale.t("dialogue.turned_in",
				[Locale.t(String(quest.get("title_key", "quest.unknown.title")))]))
		_refresh_actions()


func _show_hint(text: String) -> void:
	_hint.text = text
	_hint_left = 2.5


func _on_language_changed() -> void:
	_refresh_all()


## 任务进度变化（例如在对话中交付后）也要刷新按钮可用性。
func _on_quest_changed(_quest_id: String, _current: int, _required: int) -> void:
	_refresh_actions()


func _close() -> void:
	_resume_game()
	closed.emit()
	queue_free()


# ---------------- 验收接口 ----------------

func action_count() -> int:
	return _actions.size()


func action_at(index: int) -> String:
	if index < 0 or index >= _actions.size():
		return ""
	return _actions[index]


func press_action(action: String) -> bool:
	if not _actions.has(action):
		return false
	_on_action_pressed(action)
	return true


func body_text() -> String:
	return _body_label.text


func hint_text() -> String:
	return _hint.text


func close_panel() -> void:
	_close()


# ---------------- 控件工厂 ----------------

func _label(position: Vector2, size: Vector2, font_size: int) -> Label:
	var label := Label.new()
	label.position = position
	label.size = size
	label.add_theme_font_override("font", Locale.font)
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 0.92))
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(label)
	return label


func _button(position: Vector2, size: Vector2) -> UiButton:
	var button := UiButton.new()
	button.position = position
	button.size = size
	button.font_size = FONT_BUTTON
	_actions_host.add_child(button)
	return button
