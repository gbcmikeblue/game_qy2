extends Node2D

## 启动入口：装载地图 -> 玩家挂到地图的 y_sort 实体容器 -> 相机限位 -> 叠加 HUD。
## 同时注入表现层（伤害飘字）使用的 FxLayer。

const MAP_SCENE := preload("res://scenes/maps/test_map.tscn")
const PLAYER_SCENE := preload("res://scenes/actors/player/player.tscn")
const HUD_SCENE := preload("res://scenes/ui/hud.tscn")
const TARGET_PICKER := preload("res://scripts/input/target_picker.gd")

var map
var player


func _ready() -> void:
	_build_fx_layer()

	map = MAP_SCENE.instantiate()
	add_child(map)

	player = PLAYER_SCENE.instantiate()
	var spawn: Vector2 = map.spawn_world_position()
	player.position = spawn
	player.spawn_point = spawn
	# 玩家必须和道具、敌人处于同一个 y_sort 容器，遮挡关系才成立。
	map.get_entity_root().add_child(player)
	# 锁定后的自动接近需要地图的寻路与阻挡信息。
	player.setup_navigation(map)
	GameManager.player = player

	_apply_camera_limits()
	# 世界点击拾取：选中只改选中状态，攻击由 ATK 按钮/攻击键单独触发。
	var picker := Node.new()
	picker.name = "TargetPicker"
	picker.set_script(TARGET_PICKER)
	add_child(picker)
	add_child(HUD_SCENE.instantiate())


func _build_fx_layer() -> void:
	var layer := Node2D.new()
	layer.name = "FxLayer"
	layer.z_index = 100
	add_child(layer)
	CombatFx.layer = layer


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
