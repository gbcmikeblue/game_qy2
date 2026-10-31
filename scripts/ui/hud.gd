extends CanvasLayer

## HUD：血条 + 选中目标状态 + 调试信息 + 设置入口。
## 语言切换入口已迁到设置面板（本层不再有 LANG 按钮）。
## 主操作按钮的文案随"选中目标类型"变化（怪物=攻击 / NPC=交互 / 植物=采摘 / 玩家=观察），
## 类型到文案 key 的映射在 data/targets/interactions.json，语言由 Locale 实时切换。

## 血条填充相对 HpBack 的内缩（左右各 2 逻辑像素），宽度按 HpBack 的实时宽度算比例，
## 不再依赖硬编码的像素总宽（原 HP_FILL_MAX = 276 是 280-4 的写死值）。
const HP_FILL_INSET := 2.0
## 字号统一走 DisplayAdapter 的文字角色（dp → 逻辑像素），与设置面板同一套规范。
## 调试信息不参与 ui_scale，避免大字号下撑高压到左下角血条（见 NO_UI_SCALE）。
## 调试信息不参与界面缩放：它的行数会撑高控件，放大后会压到左下角血条区。
const NO_UI_SCALE := ["DebugLabel"]
const SETTINGS_PANEL := preload("res://scenes/ui/settings_panel.tscn")
const INVENTORY_PANEL := preload("res://scenes/ui/inventory_panel.tscn")

@onready var _debug_label: Label = $DebugLabel
@onready var _hp_back: ColorRect = $HpBack
@onready var _hp_fill: ColorRect = $HpFill
@onready var _hp_label: Label = $HpLabel
@onready var _attack_button = $AttackButton
@onready var _skill_button = $SkillButton
@onready var _skill2_button = $Skill2Button
@onready var _settings_button: UiButton = $SettingsButton
@onready var _inventory_button: UiButton = $InventoryButton
@onready var _hint_label: Label = $HintLabel
@onready var _quest_label: Label = $QuestLabel

var _lock_line := ""
var _panel: Node = null
var _action_key := ""
## 各控件相对锚点的原始边距（来自 hud.tscn），安全区变化时以它为准重算，避免累加漂移。
var _base_offsets: Dictionary = {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	for label: Label in [_debug_label, _hp_label, _hint_label, _quest_label]:
		label.add_theme_font_override("font", Locale.font)
		label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 0.92))
		label.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.85))
		label.add_theme_constant_override("outline_size", 4)
	_hint_label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 0.55))
	# 调试信息行数会撑高控件，裁到自己盒子里，避免任何情况下压到血条。
	_debug_label.clip_text = true
	# 发布构建不显示调试信息（FPS/坐标/状态），只在调试构建里给开发者看。
	_debug_label.visible = OS.is_debug_build()

	for child: Node in get_children():
		if child is Control:
			var control := child as Control
			_base_offsets[control] = Vector4(
				control.offset_left, control.offset_top, control.offset_right, control.offset_bottom)
	DisplayAdapter.layout_changed.connect(_on_layout_changed)
	_on_layout_changed()

	_settings_button.pressed.connect(_on_settings_pressed)
	_inventory_button.pressed.connect(_on_inventory_pressed)
	Locale.language_changed.connect(_on_texts_changed)
	GameSettings.bindings_changed.connect(_on_texts_changed)
	EventBus.quest_updated.connect(_on_quest_changed)
	EventBus.quest_completed.connect(_on_quest_completed)
	_refresh_texts()
	_refresh_quest()


func _exit_tree() -> void:
	if DisplayAdapter.layout_changed.is_connected(_on_layout_changed):
		DisplayAdapter.layout_changed.disconnect(_on_layout_changed)
	if EventBus.quest_updated.is_connected(_on_quest_changed):
		EventBus.quest_updated.disconnect(_on_quest_changed)
	if EventBus.quest_completed.is_connected(_on_quest_completed):
		EventBus.quest_completed.disconnect(_on_quest_completed)


## 任务行：没有任务时留空（不占视觉），有任务时显示「任务：标题 2/3」。
func _refresh_quest() -> void:
	_quest_label.text = QuestService.progress_text()


func _on_quest_changed(_quest_id: String, _current: int, _required: int) -> void:
	_refresh_quest()


func _on_quest_completed(quest_id: String) -> void:
	_refresh_quest()
	var hero := GameManager.get_player()
	if hero is Node2D:
		var quest := DataRegistry.get_quest(quest_id)
		var title := Locale.t(String(quest.get("title_key", "quest.unknown.title")))
		CombatFx.show_text((hero as Node2D).global_position + Vector2(0.0, -40.0),
				Locale.t("quest.completed", [title]), Color(1.0, 0.9, 0.45))


## 字号 dp 化：与设置面板共用角色表，真机上正文 ≥14dp、辅助说明 ≥12dp。
func _apply_fonts() -> void:
	_debug_label.add_theme_font_size_override("font_size",
		DisplayAdapter.text_px_fixed("helper"))
	_hp_label.add_theme_font_size_override("font_size", DisplayAdapter.text_px("body"))
	_hint_label.add_theme_font_size_override("font_size", DisplayAdapter.text_px("helper"))
	_quest_label.add_theme_font_size_override("font_size", DisplayAdapter.text_px("helper"))
	_settings_button.font_size = DisplayAdapter.text_px("helper")
	_settings_button.queue_redraw()
	_inventory_button.font_size = DisplayAdapter.text_px("helper")
	_inventory_button.queue_redraw()


## HUD 锚定「视口矩形内缩 safe_insets 后的矩形」：元素本身仍用边锚点，
## 这里只按锚定方向把边距整体推/收一个安全区量，尺寸保持不变（§3.4）。
## 旋转、折叠屏展开、分屏都会触发 layout_changed，重排只改边距，不重建节点、不丢状态。
## 视口尺寸 / 安全区 / ui_scale 变化：字号与控件一起重排一次（不重建节点、不丢状态）。
func _on_layout_changed() -> void:
	_apply_fonts()
	apply_safe_layout(DisplayAdapter.safe_insets)


## 按给定安全区内缩重算所有子控件的边距（语义见 DisplayAdapter.compute_safe_insets）。
## 单独抽出来是为了让验收脚本能在固定视口尺寸下复用同一条布局路径。
## 边距先乘 ui_scale（整层等比放大/缩小），再叠加安全区位移。
func apply_safe_layout(insets: Vector4) -> void:
	var scale := DisplayAdapter.ui_scale
	for child: Node in get_children():
		if not (child is Control) or not _base_offsets.has(child):
			continue
		var control := child as Control
		var base: Vector4 = _base_offsets[control]
		var own_scale := 1.0 if NO_UI_SCALE.has(String(control.name)) else scale
		var dx := _axis_shift(control.anchor_left, control.anchor_right, insets.x, insets.z)
		var dy := _axis_shift(control.anchor_top, control.anchor_bottom, insets.y, insets.w)
		control.offset_left = base.x * own_scale + dx
		control.offset_right = base.z * own_scale + dx
		control.offset_top = base.y * own_scale + dy
		control.offset_bottom = base.w * own_scale + dy


## 按锚点方向求位移：贴左边→+起始内缩，贴右边→-结束内缩，居中→按差值取半。
func _axis_shift(start_anchor: float, end_anchor: float,
		start_inset: float, end_inset: float) -> float:
	if is_equal_approx(start_anchor, end_anchor):
		if is_zero_approx(start_anchor):
			return start_inset
		if is_equal_approx(start_anchor, 1.0):
			return -end_inset
		if is_equal_approx(start_anchor, 0.5):
			return (start_inset - end_inset) * 0.5
	return 0.0


## 暂停门控（§3.7）：暂停/切后台时主操作按钮置灰且不响应，避免暂停态下误触攻击。
## 切后台的暂停由 GameManager 负责，HUD 只消费状态。
func _update_skill_button() -> void:
	var player := GameManager.player
	if not is_instance_valid(player) or not player.has_method("get_skill_cooldown_left"):
		return
	_skill_button.set_cooldown(_cooldown_ratio_of(player, "heavy_strike"))
	_skill2_button.set_cooldown(_cooldown_ratio_of(player, "whirlwind"))


## 单个技能的冷却比例（0..1），两个技能按钮共用。
func _cooldown_ratio_of(player: Node, skill_id: String) -> float:
	var total := maxf(0.001, float(player.get_skill_cooldown_total(skill_id)))
	return clampf(float(player.get_skill_cooldown_left(skill_id)) / total, 0.0, 1.0)


func _update_interaction_gate() -> void:
	_attack_button.set_disabled(GameManager.is_paused)
	if _skill_button != null:
		_skill_button.set_disabled(GameManager.is_paused)
		_skill2_button.set_disabled(GameManager.is_paused)


func _process(_delta: float) -> void:
	_update_health()
	_update_lock()
	_update_action_button()
	_update_interaction_gate()
	_update_skill_button()
	_update_debug()


func _on_texts_changed(_arg: Variant = null) -> void:
	_refresh_texts()


func _refresh_texts() -> void:
	_settings_button.set_caption(Locale.t("button.settings"))
	_inventory_button.set_caption(Locale.t("button.inventory"))
	_skill_button.set_caption(Locale.t("button.skill.heavy"))
	_skill2_button.set_caption(Locale.t("button.skill.whirlwind"))
	_update_action_button()
	_update_hint()


## 主操作按钮文案：由当前选中目标的类型决定，未选中时回退为"攻击"。
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


func _on_inventory_pressed() -> void:
	if is_instance_valid(_panel):
		return
	_panel = INVENTORY_PANEL.instantiate()
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
	# 宽度按 HpBack 的实时宽度取比例（锚点化后血条宽度随安全区/视口变化）。
	var full_width := maxf(0.0, _hp_back.size.x - HP_FILL_INSET * 2.0)
	_hp_fill.size = Vector2(full_width * ratio, _hp_fill.size.y)
	if player.has_method("get_mp"):
		_hp_label.text = Locale.t("hud.hp_mp", [current, maximum,
				int(player.get_mp()), int(player.get_max_mp())])
	else:
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
	if not _debug_label.visible:
		return
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
		# 字号放大后调试块会压到左下角血条，这里把 9 行合并成 6 行。
		lines.append("%s  %s" % [
			Locale.t("hud.world", [world.x, world.y]), Locale.t("hud.grid", [grid.x, grid.y])])
		lines.append("%s  %s  %s" % [
			Locale.t("hud.speed", [(player as CharacterBody2D).velocity.length()]),
			Locale.t("hud.auto.on") if player.is_auto_approaching() else Locale.t("hud.auto.off"),
			Locale.t("hud.auto_attack.on") if player.is_auto_attack_active()
				else Locale.t("hud.auto_attack.off"),
		])
		if not player.is_alive():
			lines.append(Locale.t("hud.dead"))

	_debug_label.text = "\n".join(lines)
