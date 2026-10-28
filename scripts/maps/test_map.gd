extends Node2D
class_name TestMap

## 阶段 A 测试地图：读取 data/maps/test_map_01.json，程序化生成地面、围墙和道具。
## 对外只暴露三件事：实体挂载点、出生点、世界边界（供相机限位）。

const MAP_PATH := "res://data/maps/test_map_01.json"

var grid_size := Vector2i(24, 24)
var player_spawn := Vector2i(12, 14)

var _entities: Node2D
var _prop_defs: Array = []


func _ready() -> void:
	_load_map_data()
	_build_ground()
	_build_entities_root()
	_build_walls()
	_build_props()


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
				_spawn_prop(PropNode.Kind.WALL, Vector2i(u, v), Vector2i.ONE)


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
		_spawn_prop(kind, cell, footprint)


func _spawn_prop(kind: int, cell: Vector2i, footprint: Vector2i) -> void:
	var prop := PropNode.new()
	prop.setup(kind, cell, footprint)
	_entities.add_child(prop)


var _map_data: Dictionary = {}

func _load_map_data() -> void:
	if not FileAccess.file_exists(MAP_PATH):
		push_error("地图配置缺失: %s" % MAP_PATH)
		return
	var file := FileAccess.open(MAP_PATH, FileAccess.READ)
	if file == null:
		push_error("地图配置读取失败: %s" % MAP_PATH)
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("地图配置不是合法 JSON 对象: %s" % MAP_PATH)
		return
	_map_data = parsed as Dictionary

	var size: Array = _map_data.get("grid_size", [24, 24])
	grid_size = Vector2i(int(size[0]), int(size[1]))
	var spawn: Array = _map_data.get("player_spawn", [12, 14])
	player_spawn = Vector2i(int(spawn[0]), int(spawn[1]))
	_prop_defs = _map_data.get("props", [])
