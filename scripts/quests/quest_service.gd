extends Node

## 任务服务（Autoload）：可并行接取 + 前置任务隐藏 + 交付发奖。
##
## 设计取舍：
##   · **可并行**：接一条任务不会挡住其它任务；只要没有 requires 关系就能同时进行。
##   · **关联任务**：`requires` 指向的前置任务未完成时，该任务不出现在可接列表（隐藏）。
##   · 一次只有一条"当前任务"用于 HUD 单行显示（active_id = 最近接取的那条），
##     但进度按 id 分别记录，互不影响。
##   · 达标只是「可交付」，奖励在 turn_in 时才发（玩家要回去找 NPC）。
##   · 状态随存档走（accepted / progress / completed / active）。

## HUD 焦点的任务 id（最近接取的那条）；空表示没有进行中的任务。
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


## 前置任务是否已完成（没有 requires 视为满足）。
func is_unlocked(quest_id: String) -> bool:
	var quest := DataRegistry.get_quest(quest_id)
	if quest.is_empty():
		return false
	var requires := String(quest.get("requires", ""))
	return requires.is_empty() or completed.has(requires)


## 所有进行中（已接取、未交付）的任务，按数据顺序。
func active_quests() -> Array:
	var out: Array = []
	for entry: Variant in DataRegistry.get_quests():
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var quest := entry as Dictionary
		var quest_id := String(quest.get("id", ""))
		if quest_id.is_empty() or not accepted.has(quest_id) or completed.has(quest_id):
			continue
		out.append(quest)
	return out


func is_ready_to_turn_in(quest_id: String) -> bool:
	var quest := DataRegistry.get_quest(quest_id)
	if quest.is_empty() or completed.has(quest_id) or not accepted.has(quest_id):
		return false
	return int(progress.get(quest_id, 0)) >= int(quest.get("required", 0))


## 可接取的任务：未接取、未完成、前置已完成（关联任务未解锁时不出现）。
func available_quests() -> Array:
	var out: Array = []
	for entry: Variant in DataRegistry.get_quests():
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var quest := entry as Dictionary
		var quest_id := String(quest.get("id", ""))
		if quest_id.is_empty() or accepted.has(quest_id) or completed.has(quest_id):
			continue
		if not is_unlocked(quest_id):
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


## HUD 用的一行文案：显示当前任务，若还有别的进行中任务则追加数量。
func progress_text() -> String:
	var quest := current_quest()
	if quest.is_empty():
		return ""
	var title := Locale.t(String(quest.get("title_key", "quest.unknown.title")))
	var current := current_progress()
	var required := current_required()
	var line := ""
	if current >= required:
		line = Locale.t("quest.progress.ready", [title, current, required])
	else:
		line = Locale.t("quest.progress", [title, current, required])
	var extra := active_quests().size() - 1
	if extra > 0:
		line += " " + Locale.t("quest.progress.more", [extra])
	return line


# ---------------- 接取 / 交付 ----------------

func accept(quest_id: String) -> bool:
	var quest := DataRegistry.get_quest(quest_id)
	if quest.is_empty() or accepted.has(quest_id) or completed.has(quest_id):
		return false
	# 关联任务必须等前置完成（未解锁时连列表都看不到，这里再挡一次）。
	if not is_unlocked(quest_id):
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
		active_id = _pick_active()
	EventBus.quest_completed.emit(quest_id)
	return true


## 交付后把 HUD 焦点挪到另一条进行中的任务（没有则清空）。
func _pick_active() -> String:
	for entry: Variant in active_quests():
		if typeof(entry) == TYPE_DICTIONARY:
			return String((entry as Dictionary).get("id", ""))
	return ""


# ---------------- 进度 ----------------

## 一次击杀可以同时推进多条任务（并行接取时各自计数）。
func _on_enemy_defeated(enemy_id: String, _world_position: Vector2) -> void:
	for entry: Variant in active_quests():
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var quest := entry as Dictionary
		if String(quest.get("target", "")) != enemy_id:
			continue
		var quest_id := String(quest["id"])
		var required := int(quest.get("required", 0))
		var current := int(progress.get(quest_id, 0))
		if current >= required:
			continue   # 已达标：等交付，不再累加
		var next := current + 1
		progress[quest_id] = next
		EventBus.quest_updated.emit(quest_id, next, required)


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

	for key: Variant in _keys_of(data.get("accepted", {})):
		accepted[key] = true
	for key: Variant in _keys_of(data.get("completed", {})):
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
	else:
		active_id = _pick_active()


## 兼容旧的布尔字典（值可能是 true 或字符串），统一取 key。
func _keys_of(raw: Variant) -> Array:
	var out: Array = []
	if typeof(raw) != TYPE_DICTIONARY:
		return out
	for key: Variant in (raw as Dictionary):
		out.append(String(key))
	return out
