extends Node

## 数据注册表：启动时读取 data/ 下的配置并校验，运行时只做只读查询。
## 数值一律放 JSON，脚本里不出现硬编码平衡值。

const ENEMY_DEF_PATH := "res://data/actors/enemies.json"
const PLAYER_DEF_PATH := "res://data/actors/player.json"

var enemies: Dictionary = {}
var player_def: Dictionary = {}


func _ready() -> void:
	_load_enemy_defs()
	_load_player_def()


func get_enemy_def(id: String) -> Dictionary:
	return enemies.get(id, {})


func get_player_def() -> Dictionary:
	return player_def


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
