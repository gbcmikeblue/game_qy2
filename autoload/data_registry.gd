extends Node

## 数据注册表：启动时读取 data/ 下的配置并校验，运行时只做只读查询。
## 数值一律放 JSON，脚本里不出现硬编码平衡值。

const ENEMY_DEF_PATH := "res://data/actors/enemies.json"
const PLAYER_DEF_PATH := "res://data/actors/player.json"
const CLASSES_PATH := "res://data/actors/classes.json"
const INTERACTION_PATH := "res://data/targets/interactions.json"

var enemies: Dictionary = {}
var player_def: Dictionary = {}
## 职业定义：id -> {id, display_name_key, slots[]}（槽位是装备系统的唯一来源）。
var classes: Dictionary = {}
## 目标类型 -> 主操作按钮文案（i18n key）；新增交互对象只改 JSON。
var interactions: Dictionary = {}
var interaction_fallback := "monster"


func _ready() -> void:
	_load_enemy_defs()
	_load_player_def()
	_load_class_defs()
	_load_interactions()


func get_enemy_def(id: String) -> Dictionary:
	return enemies.get(id, {})


func get_player_def() -> Dictionary:
	return player_def


func get_class_def(class_id: String) -> Dictionary:
	return classes.get(class_id, {})


## 该职业允许的装备槽位（顺序即 UI 顺序）。职业缺失时返回空数组，物品校验会因此报错。
func get_class_slots(class_id: String) -> Array[String]:
	var out: Array[String] = []
	var def := get_class_def(class_id)
	for slot: Variant in def.get("slots", []):
		out.append(String(slot))
	return out


## 默认职业：classes.json 里第一个（本期只有 warrior）。
func default_class_id() -> String:
	for key: Variant in classes:
		return String(key)
	return ""


## 目标类型对应的按钮文案 i18n key（未知类型回退到 fallback）。
func get_interaction_action(kind: String) -> String:
	var entry: Dictionary = interactions.get(kind, {})
	if entry.is_empty():
		entry = interactions.get(interaction_fallback, {})
	return String(entry.get("action_key", "action.attack"))


func has_interaction_kind(kind: String) -> bool:
	return interactions.has(kind)


func get_interaction_kinds() -> Array:
	return interactions.keys()


func _load_enemy_defs() -> void:
	var parsed: Variant = _read_json(ENEMY_DEF_PATH)
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	for entry: Variant in (parsed as Dictionary).get("enemies", []):
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var item := entry as Dictionary
		var id := String(item.get("id", ""))
		if id.is_empty():
			push_error("敌人配置缺少 id：%s" % str(item))
			continue
		enemies[id] = item


func _load_player_def() -> void:
	var parsed: Variant = _read_json(PLAYER_DEF_PATH)
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	player_def = (parsed as Dictionary).get("player", {})


func _load_class_defs() -> void:
	var parsed: Variant = _read_json(CLASSES_PATH)
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	for entry: Variant in (parsed as Dictionary).get("classes", []):
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var item := entry as Dictionary
		var id := String(item.get("id", ""))
		if id.is_empty():
			push_error("职业配置缺少 id：%s" % str(item))
			continue
		var slots: Array = item.get("slots", [])
		if slots.is_empty():
			push_error("职业 %s 没有配置 slots" % id)
			continue
		classes[id] = item


func _load_interactions() -> void:
	var parsed: Variant = _read_json(INTERACTION_PATH)
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var data := parsed as Dictionary
	interaction_fallback = String(data.get("fallback", "monster"))
	var kinds: Variant = data.get("kinds", {})
	if typeof(kinds) == TYPE_DICTIONARY:
		interactions = kinds as Dictionary
	if interactions.is_empty():
		push_error("交互配置为空：%s" % INTERACTION_PATH)


func _read_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		push_error("配置缺失: %s" % path)
		return null
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("配置读取失败: %s" % path)
		return null
	var text := file.get_as_text()
	file.close()
	return JSON.parse_string(text)
