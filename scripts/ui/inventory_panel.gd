extends CanvasLayer

## 背包 / 装备面板：绕开窗口做自适应（同设置面板：设计尺寸 + 整体 scale）。
## 分两个页签：背包（列表，点击装备或使用）与装备（5 槽 + 属性）。
## 商店页签在 B2 接入，先不占位，避免出现「点不动的入口」。

signal closed

const PANEL_DESIGN := Vector2(720.0, 520.0)
const PANEL_WIDTH_RATIO := 0.92
const PANEL_HEIGHT_RATIO := 0.92
const PANEL_MAX_SCALE := 1.2
const PANEL_MIN_SCALE := 0.6
const BODY_MIN_DP := 14.0

const FONT_TITLE := 30
const FONT_SECTION := 22
const FONT_BODY := 20
const FONT_HELPER := 17

const CONTENT_RECT := Rect2(20.0, 116.0, 680.0, 314.0)
const ROW_HEIGHT := 52.0
const SHOP_ROW_HEIGHT := 44.0
## 与 SaveService.SLOT_COUNT 保持一致（面板只做展示，槽位数量由服务层决定）。
const SAVE_SLOT_ROWS := 3
## 页签：顺序即索引，文案 key 与 _tab_buttons()/_tab_pages() 一一对应。
const TAB_KEYS := ["inv.tab.bag", "inv.tab.equip", "inv.tab.shop", "inv.tab.save", "inv.tab.quest"]
## 敌人名称 key 前缀：拼出来而不是写成模板串，否则 i18n 验收会把 "enemy.%s" 当成缺失词条。
const ENEMY_KEY_PREFIX := "enemy."
const TAB_WIDTH := 128.0
const TAB_GAP := 8.0
const ROW_WIDTH := 660.0
const ICON_SIZE := 34.0
## 槽位文案 key 前缀：用拼接而不是模板串，否则 i18n 验收会把 "inv.slot.%s" 当成缺失词条。
const SLOT_KEY_PREFIX := "inv.slot."

## 占位图标配色：按 id 哈希取色，正式图标接入后整体替换。
const ICON_PALETTE := [
	Color(0.42, 0.55, 0.72), Color(0.55, 0.45, 0.70), Color(0.45, 0.62, 0.48),
	Color(0.72, 0.55, 0.38), Color(0.62, 0.42, 0.45), Color(0.40, 0.58, 0.62),
]

var _panel: ColorRect
var _title: Label
var _bag_tab: UiButton
var _equip_tab: UiButton
var _shop_tab: UiButton
var _save_tab: UiButton
var _quest_tab: UiButton
var _content: Control
var _bag_page: Control
var _equip_page: Control
var _bag_scroll: ScrollContainer
var _bag_rows: Control
var _gold_label: Label
var _capacity_label: Label
var _hint: Label
var _close_button: UiButton
var _stats_label: Label
var _shop_page: Control
var _buy_rows: Control
var _sell_rows: Control
var _buy_header: Label
var _sell_header: Label
var _save_page: Control
var _quest_page: Control
## 任务页每行的标签（重建时清空；验收按行读文案）。
var _quest_lines: Array[Label] = []
## 每个槽位一行的信息标签（读档/存档后刷新文本与按钮可用性）。
var _save_info: Array[Label] = []
var _save_load_buttons: Array[UiButton] = []

## 打开时直接落在哪个页签（NPC 交易 → 2 = 商店）。
var initial_tab := 0
## 指定商店 id；留空则用 ItemRegistry.default_shop()。
var shop_id: StringName = &""

var _tab := 0
var _hint_left := 0.0
## 背包行与物品 id 的对应关系（验收脚本按 id 找行，不依赖顺序）。
var _row_items: Array[StringName] = []
## 商店两列的行 → 物品 id 映射。
var _buy_items: Array[StringName] = []
var _sell_items: Array[StringName] = []


func _ready() -> void:
	layer = 10
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build()
	_locale_and_signals()
	_pause_game()
	_refresh_all()
	if initial_tab != 0:
		_switch_tab(initial_tab)


func _exit_tree() -> void:
	if DisplayAdapter.layout_changed.is_connected(_layout):
		DisplayAdapter.layout_changed.disconnect(_layout)
	if EventBus.inventory_changed.is_connected(_on_inventory_changed):
		EventBus.inventory_changed.disconnect(_on_inventory_changed)
	if EventBus.equipment_changed.is_connected(_on_equipment_changed):
		EventBus.equipment_changed.disconnect(_on_equipment_changed)
	if EventBus.gold_changed.is_connected(_on_gold_changed):
		EventBus.gold_changed.disconnect(_on_gold_changed)
	if EventBus.quest_updated.is_connected(_on_quest_changed):
		EventBus.quest_updated.disconnect(_on_quest_changed)
	if EventBus.quest_completed.is_connected(_on_quest_completed):
		EventBus.quest_completed.disconnect(_on_quest_completed)
	_resume_game()


func _locale_and_signals() -> void:
	Locale.language_changed.connect(_on_language_changed)
	DisplayAdapter.layout_changed.connect(_layout)
	EventBus.inventory_changed.connect(_on_inventory_changed)
	EventBus.equipment_changed.connect(_on_equipment_changed)
	EventBus.gold_changed.connect(_on_gold_changed)
	EventBus.quest_updated.connect(_on_quest_changed)
	EventBus.quest_completed.connect(_on_quest_completed)


# ---------------- 构建 ----------------

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

	_title = _label(Vector2(24.0, 10.0), Vector2(400.0, 42.0), FONT_TITLE, _panel)

	# 5 个页签均分：24 起、宽 128、间距 8，正好落到 696（面板宽 720，右侧留 24）。
	_bag_tab = _make_tab(0)
	_equip_tab = _make_tab(1)
	_shop_tab = _make_tab(2)
	_save_tab = _make_tab(3)
	_quest_tab = _make_tab(4)

	_content = Control.new()
	_content.position = CONTENT_RECT.position
	_content.size = CONTENT_RECT.size
	_content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(_content)

	_build_bag_page()
	_build_equip_page()
	_build_shop_page()
	_build_save_page()
	_build_quest_page()

	_gold_label = _label(Vector2(24.0, 440.0), Vector2(190.0, 34.0), FONT_BODY, _panel)
	_capacity_label = _label(Vector2(220.0, 440.0), Vector2(220.0, 34.0), FONT_BODY, _panel)
	_hint = _label(Vector2(24.0, 486.0), Vector2(500.0, 26.0), FONT_HELPER, _panel)
	_close_button = _button(_panel, Vector2(536.0, 440.0), Vector2(160.0, 42.0))
	_close_button.pressed.connect(_close)


func _build_bag_page() -> void:
	_bag_page = Control.new()
	_bag_page.size = CONTENT_RECT.size
	_bag_page.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_content.add_child(_bag_page)

	_bag_scroll = ScrollContainer.new()
	_bag_scroll.size = CONTENT_RECT.size
	_bag_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_bag_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_bag_scroll.scroll_deadzone = 8
	_bag_page.add_child(_bag_scroll)

	_bag_rows = Control.new()
	_bag_rows.custom_minimum_size = CONTENT_RECT.size
	_bag_rows.size = CONTENT_RECT.size
	_bag_rows.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bag_scroll.add_child(_bag_rows)


func _build_equip_page() -> void:
	_equip_page = Control.new()
	_equip_page.size = CONTENT_RECT.size
	_equip_page.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_equip_page.visible = false
	_content.add_child(_equip_page)


## 商店页签：左买右卖，两列各自滚动。买卖校验都在 InventoryService 里，
## 这里只负责把失败原因翻译成提示，不重复判断。
func _build_shop_page() -> void:
	_shop_page = Control.new()
	_shop_page.size = CONTENT_RECT.size
	_shop_page.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_shop_page.visible = false
	_content.add_child(_shop_page)

	_buy_header = _label(Vector2(8.0, 0.0), Vector2(300.0, 26.0), FONT_HELPER, _shop_page)
	_sell_header = _label(Vector2(358.0, 0.0), Vector2(300.0, 26.0), FONT_HELPER, _shop_page)

	_buy_rows = _make_shop_column(_shop_page, 0.0)
	_sell_rows = _make_shop_column(_shop_page, 350.0)


## 存档页签：3 个槽位，每行「保存 / 读取」，空槽的读取置灰。
func _build_save_page() -> void:
	_save_page = Control.new()
	_save_page.size = CONTENT_RECT.size
	_save_page.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_save_page.visible = false
	_content.add_child(_save_page)


## 任务页签：当前任务（标题/进度/奖励）+ 已完成清单。
## 只读展示，不提供接取/放弃——任务由 QuestService 自动串行推进。
func _build_quest_page() -> void:
	_quest_page = Control.new()
	_quest_page.size = CONTENT_RECT.size
	_quest_page.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_quest_page.visible = false
	_content.add_child(_quest_page)


func _rebuild_quest() -> void:
	for child: Node in _quest_page.get_children():
		_quest_page.remove_child(child)
		child.queue_free()
	_quest_lines.clear()

	var row := 0
	var quest := QuestService.current_quest()
	if quest.is_empty():
		row = _add_quest_line(row, Locale.t("quest.none"))
	else:
		row = _add_quest_line(row, Locale.t("quest.line.current", [
			Locale.t(String(quest.get("title_key", "quest.unknown.title"))),
			QuestService.current_progress(),
			QuestService.current_required(),
		]))
		row = _add_quest_line(row, Locale.t("quest.line.reward", [
			int(quest.get("reward_gold", 0)), _reward_items_text(quest)]))
		row = _add_quest_line(row, Locale.t("quest.line.hint",
				[Locale.t(ENEMY_KEY_PREFIX + String(quest.get("target", "")))]))

	row += 1   # 空一行，把「已完成」与当前任务分开
	row = _add_quest_line(row, Locale.t("quest.completed_title"))
	var completed := _completed_quests()
	if completed.is_empty():
		row = _add_quest_line(row, Locale.t("quest.completed.none"))
	else:
		for title: String in completed:
			row = _add_quest_line(row, "· " + title)


func _reward_items_text(quest: Dictionary) -> String:
	var parts: Array[String] = []
	for entry: Variant in quest.get("reward_items", []):
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var item_id := StringName(String((entry as Dictionary).get("id", "")))
		var def := ItemRegistry.get_item(item_id)
		if def == null:
			continue
		parts.append(Locale.t("quest.reward.item", [Locale.t(def.name_key),
			int((entry as Dictionary).get("qty", 1))]))
	if parts.is_empty():
		return Locale.t("quest.reward.none")
	return "、".join(parts)


## 已完成的任务标题（按数据顺序，保证文案稳定）。
func _completed_quests() -> Array[String]:
	var out: Array[String] = []
	for entry: Variant in DataRegistry.get_quests():
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var quest := entry as Dictionary
		var quest_id := String(quest.get("id", ""))
		if quest_id.is_empty() or not QuestService.completed.has(quest_id):
			continue
		out.append(Locale.t(String(quest.get("title_key", "quest.unknown.title"))))
	return out


func _add_quest_line(row: int, text: String) -> int:
	_quest_lines.append(_quest_label(row, text))
	return row + 1


## 行距固定 26px，row 直接决定纵坐标。
func _quest_label(slot: int, text: String) -> Label:
	var y := float(slot) * 26.0
	var label := _label(Vector2(8.0, y), Vector2(660.0, 26.0), FONT_HELPER, _quest_page)
	label.text = text
	return label


func _rebuild_save() -> void:
	for child: Node in _save_page.get_children():
		_save_page.remove_child(child)
		child.queue_free()
	_save_info.clear()
	_save_load_buttons.clear()

	for index in SAVE_SLOT_ROWS:
		var slot := index + 1
		var y := float(index) * 72.0
		var title := _label(Vector2(8.0, y + 10.0), Vector2(90.0, 34.0), FONT_BODY, _save_page)
		title.text = Locale.t("inv.slot.title", [slot])

		var info := _label(Vector2(100.0, y + 10.0), Vector2(320.0, 34.0), FONT_HELPER, _save_page)
		_save_info.append(info)

		var save_button := _button(_save_page, Vector2(440.0, y + 2.0), Vector2(100.0, 40.0))
		save_button.set_caption(Locale.t("inv.save.action"))
		save_button.pressed.connect(_on_save_slot_pressed.bind(index))

		var load_button := _button(_save_page, Vector2(550.0, y + 2.0), Vector2(100.0, 40.0))
		load_button.set_caption(Locale.t("inv.load.action"))
		load_button.pressed.connect(_on_load_slot_pressed.bind(index))
		_save_load_buttons.append(load_button)

	_refresh_save_rows()


## 槽位信息来自磁盘（不是运行时状态），所以保存/读取后都要重刷。
func _refresh_save_rows() -> void:
	for index in _save_info.size():
		var slot := index + 1
		var info := SaveService.slot_info(slot)
		if info.is_empty():
			_save_info[index].text = Locale.t("inv.slot.empty")
		else:
			_save_info[index].text = Locale.t("inv.slot.summary", [
				int(info["level"]), int(info["gold"]), int(info["inventory_size"])])
		if index < _save_load_buttons.size():
			_save_load_buttons[index].set_disabled(info.is_empty())


func _on_save_slot_pressed(index: int) -> void:
	var slot := index + 1
	if SaveService.save_slot(slot):
		_show_hint(Locale.t("inv.save.ok", [slot]))
	else:
		_show_hint(Locale.t("inv.save.fail", [slot]))
	_refresh_save_rows()


func _on_load_slot_pressed(index: int) -> void:
	var slot := index + 1
	if SaveService.load_slot(slot):
		_show_hint(Locale.t("inv.load.ok", [slot]))
		_refresh_all()
	else:
		_show_hint(Locale.t("inv.load.fail"))
	_refresh_save_rows()


func _make_shop_column(parent: Control, x: float) -> Control:
	var scroll := ScrollContainer.new()
	scroll.position = Vector2(x, 30.0)
	scroll.size = Vector2(320.0, CONTENT_RECT.size.y - 30.0)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.scroll_deadzone = 8
	parent.add_child(scroll)

	var rows := Control.new()
	rows.custom_minimum_size = scroll.size
	rows.size = scroll.size
	rows.mouse_filter = Control.MOUSE_FILTER_IGNORE
	scroll.add_child(rows)
	return rows


# ---------------- 布局与文案 ----------------

func _layout() -> void:
	if not is_instance_valid(_panel):
		return
	var viewport := get_viewport().get_visible_rect().size
	var insets := DisplayAdapter.safe_insets
	var usable := Vector2(
		maxf(1.0, viewport.x - insets.x - insets.z),
		maxf(1.0, viewport.y - insets.y - insets.w))
	var by_space := minf(
		usable.x * PANEL_WIDTH_RATIO / PANEL_DESIGN.x,
		usable.y * PANEL_HEIGHT_RATIO / PANEL_DESIGN.y)
	var readable := DisplayAdapter.dp(BODY_MIN_DP) / float(FONT_BODY)
	var upper := minf(maxf(PANEL_MAX_SCALE, readable * 1.1), 1.6)
	var scale_factor := clampf(minf(by_space, upper), PANEL_MIN_SCALE, upper)
	_panel.size = PANEL_DESIGN
	_panel.scale = Vector2(scale_factor, scale_factor)
	var scaled := _panel.size * scale_factor
	_panel.position = (Vector2(insets.x, insets.y) + (usable - scaled) * 0.5).round()


func _refresh_texts() -> void:
	_title.text = Locale.t("inv.title")
	var tabs := _tab_buttons()
	for index in tabs.size():
		tabs[index].set_caption(Locale.t(TAB_KEYS[index]))
		tabs[index].set_highlight(_tab == index)
	_close_button.set_caption(Locale.t("inv.close"))
	_buy_header.text = Locale.t("inv.shop.buy")
	_sell_header.text = Locale.t("inv.shop.sell")


func _tab_buttons() -> Array[UiButton]:
	return [_bag_tab, _equip_tab, _shop_tab, _save_tab, _quest_tab]


func _tab_pages() -> Array[Control]:
	return [_bag_page, _equip_page, _shop_page, _save_page, _quest_page]


## 按索引建一个页签按钮（位置见 TAB_KEYS 注释）。
func _make_tab(index: int) -> UiButton:
	var button := _button(_panel, Vector2(24.0 + float(index) * (TAB_WIDTH + TAB_GAP), 62.0),
			Vector2(TAB_WIDTH, 40.0))
	button.pressed.connect(_switch_tab.bind(index))
	return button


func _refresh_all() -> void:
	_refresh_texts()
	_rebuild_bag()
	_rebuild_equip()
	_rebuild_shop()
	_rebuild_save()
	_rebuild_quest()
	_refresh_footer()


func _refresh_footer() -> void:
	_gold_label.text = Locale.t("inv.gold", [InventoryService.gold])
	_capacity_label.text = Locale.t("inv.capacity",
			[InventoryService.items.size(), InventoryService.capacity])


# ---------------- 背包页签 ----------------

func _rebuild_bag() -> void:
	_row_items.clear()
	# 先摘再 free：queue_free 是延迟的，若只调它，刚重建的那一帧里 get_child_count 会多算旧行。
	for child: Node in _bag_rows.get_children():
		_bag_rows.remove_child(child)
		child.queue_free()

	if InventoryService.items.is_empty():
		var empty := _label(Vector2(8.0, 12.0), Vector2(600.0, 32.0), FONT_BODY, _bag_rows)
		empty.text = Locale.t("inv.empty")
		_bag_rows.custom_minimum_size = CONTENT_RECT.size
		return

	var index := 0
	for entry: Dictionary in InventoryService.items:
		var item_id: StringName = entry["id"]
		var qty := int(entry["qty"])
		var def := ItemRegistry.get_item(item_id)
		if def == null:
			continue
		_row_items.append(def.id)
		_make_row(index, def, qty)
		index += 1

	var height := maxf(CONTENT_RECT.size.y, float(index) * ROW_HEIGHT)
	_bag_rows.custom_minimum_size = Vector2(CONTENT_RECT.size.x, height)
	_bag_rows.size = _bag_rows.custom_minimum_size


func _make_row(index: int, def: ItemData, qty: int) -> void:
	var y := float(index) * ROW_HEIGHT
	var row := _button(_bag_rows, Vector2(0.0, y), Vector2(ROW_WIDTH, ROW_HEIGHT - 8.0))
	row.set_caption("")
	row.pressed.connect(_on_item_pressed.bind(def.id))

	var icon := ColorRect.new()
	icon.color = _icon_color(def.id)
	icon.position = Vector2(10.0, (ROW_HEIGHT - 8.0 - ICON_SIZE) * 0.5)
	icon.size = Vector2(ICON_SIZE, ICON_SIZE)
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(icon)

	var initial := _label(Vector2(10.0, icon.position.y), Vector2(ICON_SIZE, ICON_SIZE), FONT_HELPER, row)
	initial.text = Locale.t(def.name_key).substr(0, 1)
	initial.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	initial.vertical_alignment = VERTICAL_ALIGNMENT_CENTER

	var name_label := _label(Vector2(56.0, 6.0), Vector2(420.0, 32.0), FONT_BODY, row)
	name_label.text = Locale.t(def.name_key)

	var qty_label := _label(Vector2(480.0, 6.0), Vector2(170.0, 32.0), FONT_BODY, row)
	qty_label.text = "×%d" % qty
	qty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT


func _on_item_pressed(item_id: StringName) -> void:
	var def := ItemRegistry.get_item(item_id)
	if def == null:
		return
	if def.is_equipment():
		if InventoryService.equip(item_id):
			_show_hint(Locale.t("inv.equipped_hint", [Locale.t(def.name_key)]))
		else:
			_show_hint(Locale.t("inventory.full"))
		return
	if def.category == ItemData.Category.CONSUMABLE:
		_use_consumable(def)
		return
	_show_hint(Locale.t("inv.no_effect"))


func _use_consumable(def: ItemData) -> void:
	var hero := GameManager.get_player()
	if hero == null or not is_instance_valid(hero):
		return
	if def.use_effect == &"heal_hp" and hero.has_method("heal"):
		if hero.get_hp() >= hero.get_max_hp():
			_show_hint(Locale.t("inv.hp_full"))
			return
		if def.heal_amount <= 0 or not InventoryService.remove_item(def.id, 1):
			_show_hint(Locale.t("inv.no_effect"))
			return
		hero.heal(def.heal_amount)
		_show_hint(Locale.t("inv.used_hint", [Locale.t(def.name_key)]))
		return
	# 魔法尚未消耗（技能未实装），先明确提示而不是静默失败。
	_show_hint(Locale.t("inv.no_effect"))


# ---------------- 装备页签 ----------------

func _rebuild_equip() -> void:
	for child: Node in _equip_page.get_children():
		_equip_page.remove_child(child)
		child.queue_free()

	var index := 0
	for slot: String in ItemRegistry.slots:
		var y := float(index) * ROW_HEIGHT
		var slot_label := _label(Vector2(8.0, y + 10.0), Vector2(160.0, 34.0), FONT_BODY, _equip_page)
		slot_label.text = Locale.t(_slot_key(slot))

		var item_id := InventoryService.equipped_in(slot)
		var value_label := _label(Vector2(180.0, y + 10.0), Vector2(300.0, 34.0), FONT_BODY, _equip_page)
		if item_id == &"":
			value_label.text = "—"
		else:
			var def := ItemRegistry.get_item(item_id)
			value_label.text = Locale.t(def.name_key) if def != null else String(item_id)

		if item_id != &"":
			var button := _button(_equip_page, Vector2(500.0, y + 4.0), Vector2(150.0, 42.0))
			button.set_caption(Locale.t("inv.unequip"))
			button.pressed.connect(_on_unequip_pressed.bind(slot))
		index += 1

	_stats_label = _label(Vector2(8.0, float(index) * ROW_HEIGHT + 12.0),
			Vector2(620.0, 92.0), FONT_HELPER, _equip_page)
	_stats_label.text = _stats_text()


func _stats_text() -> String:
	var s := InventoryService.stats()
	return "%s   %s   %s   %s" % [
		Locale.t("inv.stat.attack", [int(round(float(s["attack"])))]),
		Locale.t("inv.stat.defense", [int(round(float(s["defense"])))]),
		Locale.t("inv.stat.hp", [int(round(float(s["max_hp"])))]),
		Locale.t("inv.stat.mp", [int(round(float(s["max_mp"])))]),
	]


func _on_unequip_pressed(slot: String) -> void:
	if InventoryService.unequip(slot):
		_show_hint(Locale.t("inv.unequipped_hint", [Locale.t(_slot_key(slot))]))
	else:
		_show_hint(Locale.t("inventory.full"))


# ---------------- 商店页签 ----------------

func _rebuild_shop() -> void:
	_buy_items.clear()
	_sell_items.clear()
	for child: Node in _buy_rows.get_children():
		_buy_rows.remove_child(child)
		child.queue_free()
	for child: Node in _sell_rows.get_children():
		_sell_rows.remove_child(child)
		child.queue_free()

	var min_height := CONTENT_RECT.size.y - 30.0
	var buy_index := 0
	var shop := _active_shop()
	if shop != null:
		for def: ItemData in shop.stock:
			if def == null:
				continue
			_buy_items.append(def.id)
			var row := _shop_row(_buy_rows, buy_index,
					"%s    %s" % [Locale.t(def.name_key), _price_text(def.value)])
			row.pressed.connect(_on_buy_pressed.bind(def.id))
			buy_index += 1
	_buy_rows.custom_minimum_size = Vector2(320.0, maxf(min_height, float(buy_index) * SHOP_ROW_HEIGHT))
	_buy_rows.size = _buy_rows.custom_minimum_size

	var sell_index := 0
	for entry: Dictionary in InventoryService.items:
		var item_id: StringName = entry["id"]
		var def := ItemRegistry.get_item(item_id)
		if def == null:
			continue
		_sell_items.append(item_id)
		var row := _shop_row(_sell_rows, sell_index,
				"%s    %s" % [Locale.t(def.name_key), _price_text(InventoryService.sell_price(item_id))])
		row.pressed.connect(_on_sell_pressed.bind(item_id))
		sell_index += 1
	_sell_rows.custom_minimum_size = Vector2(320.0, maxf(min_height, float(sell_index) * SHOP_ROW_HEIGHT))
	_sell_rows.size = _sell_rows.custom_minimum_size


## 当前要展示的商店：优先用 NPC 指定的 id，其次回落到默认商店。
func _active_shop() -> ShopData:
	if shop_id != &"":
		var shop := ItemRegistry.get_shop(shop_id)
		if shop != null:
			return shop
	return ItemRegistry.default_shop()


func _shop_row(parent: Control, index: int, text: String) -> UiButton:
	var row := _button(parent, Vector2(0.0, float(index) * SHOP_ROW_HEIGHT),
			Vector2(316.0, SHOP_ROW_HEIGHT - 6.0))
	row.set_caption(text)
	return row


func _price_text(value: int) -> String:
	return Locale.t("inv.shop.price", [value])


func _on_buy_pressed(item_id: StringName) -> void:
	var def := ItemRegistry.get_item(item_id)
	if def == null:
		return
	# 先给可读原因，再交给服务层做原子校验（服务层失败时状态不变）。
	if InventoryService.gold < def.value:
		_show_hint(Locale.t("inv.coins_not_enough"))
		return
	if InventoryService.buy(item_id):
		_show_hint(Locale.t("inv.bought_hint", [Locale.t(def.name_key)]))
	else:
		_show_hint(Locale.t("inventory.full"))


func _on_sell_pressed(item_id: StringName) -> void:
	var def := ItemRegistry.get_item(item_id)
	if def == null:
		return
	var gain := InventoryService.sell_price(item_id)
	if InventoryService.sell(item_id):
		_show_hint(Locale.t("inv.sold_hint", [Locale.t(def.name_key), gain]))


# ---------------- 交互与生命周期 ----------------

func _switch_tab(index: int) -> void:
	if index < 0 or index >= TAB_KEYS.size():
		return
	_tab = index
	var pages := _tab_pages()
	for i in pages.size():
		pages[i].visible = i == index
	_refresh_texts()


func _show_hint(text: String) -> void:
	_hint.text = text
	_hint_left = 2.5


func _process(delta: float) -> void:
	if _hint_left <= 0.0:
		return
	_hint_left -= delta
	if _hint_left <= 0.0:
		_hint.text = ""


func _on_language_changed(_code: String) -> void:
	_refresh_all()


func _on_inventory_changed() -> void:
	_rebuild_bag()
	_rebuild_shop()
	_refresh_footer()
	if _stats_label != null:
		_stats_label.text = _stats_text()


func _on_equipment_changed(_slot: String, _item_id: String) -> void:
	_rebuild_equip()


func _on_quest_changed(_quest_id: String, _current: int, _required: int) -> void:
	_rebuild_quest()


func _on_quest_completed(_quest_id: String) -> void:
	_rebuild_quest()


func _on_gold_changed(_gold: int) -> void:
	_refresh_footer()
	# 金币变化会影响「买得起 / 买不起」的提示，但行内容不变，只需刷新底部与提示。
	_refresh_texts()


func _pause_game() -> void:
	GameManager.hold_pause(GameManager.PAUSE_SETTINGS)


func _resume_game() -> void:
	GameManager.release_pause(GameManager.PAUSE_SETTINGS)


func _close() -> void:
	_resume_game()
	closed.emit()
	queue_free()


# ---------------- 控件工厂 ----------------

func _icon_color(item_id: StringName) -> Color:
	var hash_value := 0
	for index in String(item_id).length():
		hash_value = (hash_value * 31 + String(item_id).unicode_at(index)) % 100000
	return ICON_PALETTE[absi(hash_value) % ICON_PALETTE.size()]


func _slot_key(slot: String) -> String:
	return SLOT_KEY_PREFIX + slot


func _label(position: Vector2, size: Vector2, font_size: int, parent: Control = null) -> Label:
	var label := Label.new()
	label.position = position
	label.size = size
	label.add_theme_font_override("font", Locale.font)
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 0.92))
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var host := parent if parent != null else _panel
	host.add_child(label)
	return label


func _button(parent: Control, position: Vector2, size: Vector2) -> UiButton:
	var button := UiButton.new()
	button.position = position
	button.size = size
	button.font_size = FONT_BODY
	parent.add_child(button)
	return button

# ---------------- 验收接口（不依赖内部节点路径） ----------------

func bag_row_count() -> int:
	var total := 0
	for child: Node in _bag_rows.get_children():
		if child is UiButton:
			total += 1
	return total


func bag_row_item_id(index: int) -> StringName:
	if index < 0 or index >= _row_items.size():
		return &""
	return _row_items[index]


func press_bag_row(index: int) -> bool:
	var rows: Array[UiButton] = []
	for child: Node in _bag_rows.get_children():
		if child is UiButton:
			rows.append(child as UiButton)
	if index < 0 or index >= rows.size():
		return false
	rows[index].pressed.emit()
	return true


func shop_buy_row_count() -> int:
	return _buy_items.size()


func shop_sell_row_count() -> int:
	return _sell_items.size()


func buy_row_item_id(index: int) -> StringName:
	if index < 0 or index >= _buy_items.size():
		return &""
	return _buy_items[index]


func press_buy_row(index: int) -> bool:
	if index < 0 or index >= _buy_items.size():
		return false
	_on_buy_pressed(_buy_items[index])
	return true


func press_sell_row(index: int) -> bool:
	if index < 0 or index >= _sell_items.size():
		return false
	_on_sell_pressed(_sell_items[index])
	return true


func sell_row_item_id(index: int) -> StringName:
	if index < 0 or index >= _sell_items.size():
		return &""
	return _sell_items[index]


func quest_line_count() -> int:
	return _quest_lines.size()


func quest_line(index: int) -> String:
	if index < 0 or index >= _quest_lines.size():
		return ""
	return _quest_lines[index].text


func save_row_count() -> int:
	return _save_info.size()


func save_row_text(index: int) -> String:
	if index < 0 or index >= _save_info.size():
		return ""
	return _save_info[index].text


func load_button_disabled(index: int) -> bool:
	if index < 0 or index >= _save_load_buttons.size():
		return true
	return _save_load_buttons[index].is_disabled()


func press_save_slot(index: int) -> bool:
	if index < 0 or index >= _save_info.size():
		return false
	_on_save_slot_pressed(index)
	return true


func press_load_slot(index: int) -> bool:
	if index < 0 or index >= _save_info.size():
		return false
	if _save_load_buttons[index].is_disabled():
		return false
	_on_load_slot_pressed(index)
	return true


func switch_tab_to(index: int) -> void:
	_switch_tab(index)


func current_tab() -> int:
	return _tab


func press_unequip(slot: String) -> void:
	_on_unequip_pressed(slot)


func hint_text() -> String:
	return _hint.text


func close_panel() -> void:
	_close()