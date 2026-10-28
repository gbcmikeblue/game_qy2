extends Node2D

## 启动入口：装载地图 -> 把玩家挂到地图的 y_sort 实体容器下 -> 用地图边界限制相机 -> 叠加 HUD。

const MAP_SCENE := preload("res://scenes/maps/test_map.tscn")
const PLAYER_SCENE := preload("res://scenes/actors/player/player.tscn")
const HUD_SCENE := preload("res://scenes/ui/hud.tscn")

var map: Node2D
var player: Node2D


func _ready() -> void:
	map = MAP_SCENE.instantiate()
	add_child(map)

	player = PLAYER_SCENE.instantiate()
	player.position = map.spawn_world_position()
	# 玩家必须和道具处于同一个 y_sort 容器，遮挡关系才成立。
	map.get_entity_root().add_child(player)
	GameManager.player = player

	_apply_camera_limits()
	add_child(HUD_SCENE.instantiate())


func _apply_camera_limits() -> void:
	var camera := player.get_node_or_null("Camera") as Camera2D
	if camera == null:
		push_warning("玩家节点缺少 Camera，跳过相机限位")
		return
	var bounds: Rect2 = map.world_bounds()
	camera.limit_left = int(bounds.position.x)
	camera.limit_top = int(bounds.position.y)
	camera.limit_right = int(bounds.end.x)
	camera.limit_bottom = int(bounds.end.y)
	camera.reset_smoothing()
