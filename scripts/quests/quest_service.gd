extends Node

## 任务服务（Autoload）：接取 → 计数 → 交付发奖。
##
## 设计取舍：
##   · 任务必须由 NPC 接取（`accept`），不再自动串行——否则「找谁接任务」这件事不存在；
##   · 一次只有一条进行中的任务（active_id），但已完成/已接取状态按 id 全量记录；
##   · 达标后只是「可交付」，奖励在 `turn_in` 时才发（玩家要回去找 NPC）；
##   · 奖励只发一次（completed 兜底，重复 turn_in 无效）；
##   · 状态随存档走（SaveService 的 payload 里带 quests 字段）。

## 进行中的任务 id；空表示当前没有接任务。
var active_id := ""
## 任务 id -> 已接取（含已完成）
var accepted: Dictionary = {}
## 任务 id -> 击杀计数
var progress: Dictionary = {}
## 任务 id -> true（已交付并结算）
var completed: Dictionary = {}


func _ready() -> void:
	EventBus.enemy_defeated.connect(_on_enemy_defeated)


func _exit_tree() -> void:
	if EventBus.enemy_defeated.is_connected(_on_enemy_defeated):
		EventBus.enemy_defeated.disconnect(_on_enemy_defeated)


## 清空全部进度（新游戏 / 测试用）。注意：不再自动接取任何任务。
func reset() -> void:
	active_id = ""
	accepted.clear()
	progress.clear()
	completed.clear()


# ---------------- 查询 ----------------

func current_quest() -> Dictionary:
	if active_id.is_empty():
		return {}
	return DataRegistry.get_quest(active_id)


func current_progress() -> int:
	return int(progress.get(active_id, 0))


func current_required() -> int:
	return int(current_quest().get("required", 0))


func is_ready_to_turn_in(quest_id: String) -> bool:
	var quest := DataRegistry.get_quest(quest_id)
	if quest.is_empty() or completed.has(quest_id):
		return false
	return int(progress.get(quest_id, 0)) >= int(quest.get("required", 0))


## 可接取的任务（未接取、未完成）。NPC 对话框据此决定是否显示「接取任务」。
func available_quests() -> Array:
	var out: Array = []
	for entry: Variant in DataRegistry.get_quests():
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var quest := entry as Dictionary
		var quest_id := String(quest.get("id", ""))
		if quest_id.is_empty() or accepted.has(quest_id) or completed.has(quest_id):
			continue
		out.append(quest)
	return out


## 可交付的任务（已接取、达标、未结算）。
func turn_in_quests() -> Array:
	var out: Array = []
	for entry: Variant in DataRegistry.get_quests():
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var quest := entry as Dictionary
		var quest_id := String(quest.get("id", ""))
		if is_ready_to_turn_in(quest_id):
			out.append(quest)
	return out


## HUD 用的一行文案；没有任务时返回空串。
func progress_text() -> String:
	var quest := current_quest()
	if quest.is_empty():
		return ""
	var title := Locale.t(String(quest.get("title_key", "quest.unknown.title")))
	var current := current_progress()
	var required := current_required()
	if current >= required:
		return Locale.t("quest.progress.ready", [title, current, required])
	return Locale.t("quest.progress", [title, current, required])


# ---------------- 接取 / 交付 ----------------

func accept(quest_id: String) -> bool:
	var quest := DataRegistry.get_quest(quest_id)
	if quest.is_empty() or accepted.has(quest_id) or completed.has(quest_id):
		return false
	if not active_id.is_empty() and not completed.has(active_id):
		# 一次只做一条：已有进行中的任务时拒绝，避免进度与提示混乱。
		return false
	accepted[quest_id] = true
	active_id = quest_id
	if not progress.has(quest_id):
		progress[quest_id] = 0
	EventBus.quest_updated.emit(quest_id, 0, int(quest.get("required", 0)))
	return true


func turn_in(quest_id: String) -> bool:
	if not is_ready_to_turn_in(quest_id):
		return false
	var quest := DataRegistry.get_quest(quest_id)
	completed[quest_id] = true

	var gold := int(quest.get("reward_gold", 0))
	if gold > 0:
		InventoryService.add_gold(gold)
	for entry: Variant in quest.get("reward_items", []):
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var item_id := StringName(String((entry as Dictionary).get("id", "")))
		var qty := maxi(1, int((entry as Dictionary).get("qty", 1)))
		if ItemRegistry.get_item(item_id) == null:
			push_warning("任务奖励引用了未知物品：%s" % item_id)
			continue
		InventoryService.add_item(item_id, qty)

	if active_id == quest_id:
		active_id = ""
	EventBus.quest_completed.emit(quest_id)
	return true


# ---------------- 进度 ----------------

func _on_enemy_defeated(enemy_id: String, _world_position: Vector2) -> void:
	if active_id.is_empty() or completed.has(active_id):
		return
	var quest := current_quest()
	if quest.is_empty() or String(quest.get("target", "")) != enemy_id:
		return
	if current_progress() >= current_required():
		return   # 已达标：等交付，不再累加

	var count := current_progress() + 1
	progress[active_id] = count
	EventBus.quest_updated.emit(active_id, count, current_required())


# ---------------- 存档 ----------------

func snapshot() -> Dictionary:
	return {
		"active": active_id,
		"accepted": accepted.duplicate(),
		"progress": progress.duplicate(),
		"completed": completed.duplicate(),
	}


func restore(data: Dictionary) -> void:
	accepted.clear()
	progress.clear()
	completed.clear()
	active_id = ""

	for key: Variant in _true_keys(data.get("accepted", {})):
		accepted[key] = true
	for key: Variant in _true_keys(data.get("completed", {})):
		completed[key] = true
	var raw_progress: Variant = data.get("progress", {})
	if typeof(raw_progress) == TYPE_DICTIONARY:
		for key: Variant in (raw_progress as Dictionary):
			progress[String(key)] = maxi(0, int((raw_progress as Dictionary)[key]))

	# 已交付的任务一定算已接取，防止旧档只存了 completed。
	for key: Variant in completed.keys():
		accepted[key] = true

	var saved_active := String(data.get("active", ""))
	if not saved_active.is_empty() and not completed.has(saved_active) \
			and not DataRegistry.get_quest(saved_active).is_empty():
		active_id = saved_active
		accepted[saved_active] = true
		if not progress.has(active_id):
			progress[active_id] = 0
		EventBus.quest_updated.emit(active_id, current_progress(), current_required())


## 兼容旧的布尔字典（值可能是 true 或字符串），统一取 key。
func _true_keys(raw: Variant) -> Array:
	var out: Array = []
	if typeof(raw) != TYPE_DICTIONARY:
		return out
	for key: Variant in (raw as Dictionary):
		out.append(String(key))
	return out
