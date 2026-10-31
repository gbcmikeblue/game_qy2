extends Node2D
class_name TestMap

## 地图：按 map_id 读取 data/maps/<id>.json，程序化生成地面、围墙、道具和怪物。
## 对外暴露：实体挂载点、出生点、世界边界、阻挡查询、路径器、刷怪入口。

## 地图数据目录：换图只改 map_id，不需要再新建场景。
const MAP_DIR := "res://data/maps/"
const ENEMY_SCENE := preload("res://scenes/actors/enemy/enemy.tscn")

## 由 main 在 add_child 之前设置；换图即换这个 id。
@export var map_id := "test_map_01"
var grid_size := Vector2i(24, 24)
var player_spawn := Vector2i(12, 14)

var _map_data: Dictionary = {}
var _entities: Node2D
var _prop_defs: Array = []
var _enemy_defs: Array = []
var _blocked: Dictionary = {}
var _pathfinder: GridPathfinder


func _ready() -> void:
	_load_map_data()
	_build_ground()
	_build_entities_root()
	_build_walls()
	_build_props()
	_build_enemies()


func map_path() -> String:
	return MAP_DIR + map_id + ".json"


func get_entity_root() -> Node2D:
	return _entities


func spawn_world_position() -> Vector2:
	return Iso.grid_to_world(player_spawn)


func world_bounds() -> Rect2:
	var left := Iso.grid_to_world(Vector2i(0, grid_size.y - 1)).x - Iso.TILE_W * 0.5
	var right := Iso.grid_to_world(Vector2i(grid_size.x - 1, 0)).x + Iso.TILE_W * 0.5
	var top := -Iso.TILE_H * 0.5
	var bottom := Iso.grid_to_world(grid_size - Vector2i.ONE).y + Iso.TILE_H * 0.5
	return Rect2(left, top, right - left, bottom - top)


func is_blocked(cell: Vector2i) -> bool:
	return _blocked.has(cell)


func get_pathfinder() -> GridPathfinder:
	if _pathfinder == null:
		_pathfinder = GridPathfinder.new()
		_pathfinder.build(grid_size, _blocked.keys())
	return _pathfinder


## 供测试或事件脚本按需刷怪，返回创建的敌人节点。
func spawn_enemy(type_id: String, cell: Vector2i) -> Node:
	var enemy := ENEMY_SCENE.instantiate()
	enemy.setup(type_id, cell, self)
	_entities.add_child(enemy)
	return enemy


func _build_ground() -> void:
	var ground := GroundRenderer.new()
	ground.name = "Ground"
	ground.z_index = -10
	add_child(ground)
	# JSON 数字会被解析成 float，这里统一转成 int 才能和格子索引比较。
	var road: Array = []
	for value: Variant in _map_data.get("road_u", []):
		road.append(int(value))
	ground.setup(grid_size, road)


func _build_entities_root() -> void:
	_entities = Node2D.new()
	_entities.name = "Entities"
	_entities.y_sort_enabled = true
	add_child(_entities)


func _build_walls() -> void:
	for u in grid_size.x:
		for v in grid_size.y:
			var on_edge := u == 0 or v == 0 or u == grid_size.x - 1 or v == grid_size.y - 1
			if on_edge:
				var cell := Vector2i(u, v)
				_blocked[cell] = true
				_spawn_prop(PropNode.Kind.WALL, cell, Vector2i.ONE)


func _build_props() -> void:
	for entry: Dictionary in _prop_defs:
		var type_name := String(entry.get("type", "tree"))
		var cell := Vector2i(int(entry.get("u", 0)), int(entry.get("v", 0)))
		var footprint := Vector2i(int(entry.get("w", 1)), int(entry.get("h", 1)))
		var kind := PropNode.Kind.TREE
		match type_name:
			"tree":
				kind = PropNode.Kind.TREE
			"rock":
				kind = PropNode.Kind.ROCK
			"building":
				kind = PropNode.Kind.BUILDING
			_:
				push_warning("未知的道具类型: %s" % type_name)
				continue
		_mark_blocked(cell, footprint)
		_spawn_prop(kind, cell, footprint)


func _build_enemies() -> void:
	for entry: Dictionary in _enemy_defs:
		var type_id := String(entry.get("type", ""))
		var cell := Vector2i(int(entry.get("u", 0)), int(entry.get("v", 0)))
		var count := maxi(1, int(entry.get("count", 1)))
		for i in count:
			spawn_enemy(type_id, cell)


func _mark_blocked(cell: Vector2i, footprint: Vector2i) -> void:
	for du in footprint.x:
		for dv in footprint.y:
			_blocked[cell + Vector2i(du, dv)] = true


func _spawn_prop(kind: int, cell: Vector2i, footprint: Vector2i) -> void:
	var prop := PropNode.new()
	prop.setup(kind, cell, footprint)
	_entities.add_child(prop)


func _load_map_data() -> void:
	var path := map_path()
	if not FileAccess.file_exists(path):
		push_error("地图配置缺失: %s" % path)
		return
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("地图配置读取失败: %s" % path)
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("地图配置不是合法 JSON 对象: %s" % path)
		return
	_map_data = parsed as Dictionary

	var size: Array = _map_data.get("grid_size", [24, 24])
	grid_size = Vector2i(int(size[0]), int(size[1]))
	var spawn: Array = _map_data.get("player_spawn", [12, 14])
	player_spawn = Vector2i(int(spawn[0]), int(spawn[1]))
	_prop_defs = _map_data.get("props", [])
	_enemy_defs = _map_data.get("enemies", [])
