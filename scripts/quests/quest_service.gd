extends Node

## 任务服务（Autoload）：单条激活式任务链。
##
## 设计取舍：
##   · 一次只有一条「当前任务」，完成后自动接取下一条（还没有任务面板与任务 NPC）；
##   · 进度按「击杀目标类型计数」，监听 enemy_defeated；
##   · 奖励只发一次（用 completed 字典挡重复结算，掉线/重放都不会双发）；
##   · 状态随存档走（SaveService 的 payload 里带 quests 字段）。

## 当前任务 id；空表示全部完成。
var active_id := ""
## 任务 id -> 已完成计数
var progress: Dictionary = {}
## 任务 id -> true（已结算）
var completed: Dictionary = {}


func _ready() -> void:
	EventBus.enemy_defeated.connect(_on_enemy_defeated)
	_activate_next()


func _exit_tree() -> void:
	if EventBus.enemy_defeated.is_connected(_on_enemy_defeated):
		EventBus.enemy_defeated.disconnect(_on_enemy_defeated)


## 清空进度并回到第一条任务（新游戏 / 测试用）。
func reset() -> void:
	active_id = ""
	progress.clear()
	completed.clear()
	_activate_next()


func current_quest() -> Dictionary:
	if active_id.is_empty():
		return {}
	return DataRegistry.get_quest(active_id)


func current_progress() -> int:
	return int(progress.get(active_id, 0))


func current_required() -> int:
	return int(current_quest().get("required", 0))


## HUD 用的一行文案；没有任务时返回空串。
func progress_text() -> String:
	var quest := current_quest()
	if quest.is_empty():
		return ""
	return Locale.t("quest.progress", [
		Locale.t(String(quest.get("title_key", "quest.unknown.title"))),
		current_progress(),
		current_required(),
	])


func _on_enemy_defeated(enemy_id: String, _world_position: Vector2) -> void:
	if active_id.is_empty() or completed.has(active_id):
		return
	var quest := current_quest()
	if quest.is_empty():
		return
	if String(quest.get("target", "")) != enemy_id:
		return

	var count := current_progress() + 1
	progress[active_id] = count
	EventBus.quest_updated.emit(active_id, count, current_required())

	if count >= current_required():
		_complete(quest)


func _complete(quest: Dictionary) -> void:
	var quest_id := String(quest.get("id", ""))
	if completed.has(quest_id):
		return
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

	EventBus.quest_completed.emit(quest_id)
	_activate_next()


## 依次找第一条未完成的任务并接取；全部完成则 active_id 留空。
func _activate_next() -> void:
	active_id = ""
	for entry: Variant in DataRegistry.get_quests():
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var quest_id := String((entry as Dictionary).get("id", ""))
		if quest_id.is_empty() or completed.has(quest_id):
			continue
		active_id = quest_id
		break
	if active_id.is_empty():
		return
	if not progress.has(active_id):
		progress[active_id] = 0
	EventBus.quest_updated.emit(active_id, current_progress(), current_required())


# ---------------- 存档 ----------------

func snapshot() -> Dictionary:
	return {
		"active": active_id,
		"progress": progress.duplicate(),
		"completed": completed.duplicate(),
	}


func restore(data: Dictionary) -> void:
	progress.clear()
	completed.clear()
	active_id = ""

	var raw_completed: Variant = data.get("completed", {})
	if typeof(raw_completed) == TYPE_DICTIONARY:
		for key: Variant in (raw_completed as Dictionary):
			completed[String(key)] = true

	var raw_progress: Variant = data.get("progress", {})
	if typeof(raw_progress) == TYPE_DICTIONARY:
		for key: Variant in (raw_progress as Dictionary):
			progress[String(key)] = maxi(0, int((raw_progress as Dictionary)[key]))

	var saved_active := String(data.get("active", ""))
	if not saved_active.is_empty() and not completed.has(saved_active) \
			and not DataRegistry.get_quest(saved_active).is_empty():
		active_id = saved_active
		if not progress.has(active_id):
			progress[active_id] = 0
		EventBus.quest_updated.emit(active_id, current_progress(), current_required())
	else:
		_activate_next()
