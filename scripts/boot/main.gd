extends Node2D

## 启动入口：世界层（SubViewport）-> 地图 -> 玩家挂到地图的 y_sort 实体容器 -> 相机限位 -> 叠加 HUD。
## 同时注入表现层（伤害飘字）使用的 FxLayer。
##
## 分层约定（《移动端多分辨率适配方案》§3.5）：
##   世界（地图/玩家/敌人/飘字）全部在 WorldView 的 SubViewport 内，尺寸与 zoom 由 DisplayAdapter 给；
##   HUD 是独立 CanvasLayer，只跟窗口逻辑坐标与安全区，不吃 render_scale。

const MAP_SCENE := preload("res://scenes/maps/test_map.tscn")
const PLAYER_SCENE := preload("res://scenes/actors/player/player.tscn")
const HUD_SCENE := preload("res://scenes/ui/hud.tscn")
const WORLD_VIEW := preload("res://scenes/boot/world_view.tscn")
const TARGET_PICKER := preload("res://scripts/input/target_picker.gd")
const LOOT_SERVICE := preload("res://scripts/items/loot_service.gd")

var map
var player
var world_view
var world: SubViewport
var loot_service: Node


func _ready() -> void:
	_build_world_view()
	_build_fx_layer()

	map = MAP_SCENE.instantiate()
	world.add_child(map)

	player = PLAYER_SCENE.instantiate()
	var spawn: Vector2 = map.spawn_world_position()
	player.position = spawn
	player.spawn_point = spawn
	# 玩家必须和道具、敌人处于同一个 y_sort 容器，遮挡关系才成立。
	map.get_entity_root().add_child(player)
	# 锁定后的自动接近需要地图的寻路与阻挡信息。
	player.setup_navigation(map)
	GameManager.player = player

	_build_loot_service()
	_apply_camera_limits()
	# 世界点击拾取：选中只改选中状态，攻击由 ATK 按钮/攻击键单独触发。
	var picker := Node.new()
	picker.name = "TargetPicker"
	picker.set_script(TARGET_PICKER)
	add_child(picker)
	picker.call("setup", world_view)

	add_child(HUD_SCENE.instantiate())

	DisplayAdapter.layout_changed.connect(_apply_layout)
	_apply_layout()

	# 主菜单选了「读取存档」：等玩家、地图、HUD 都就绪后再恢复，
	# 否则位置与血量会写到还不存在的节点上。
	var pending := SaveService.consume_pending_slot()
	if pending > 0 and not SaveService.load_slot(pending):
		push_warning("读档失败（槽 %d），按新游戏继续" % pending)


func _exit_tree() -> void:
	if DisplayAdapter.layout_changed.is_connected(_apply_layout):
		DisplayAdapter.layout_changed.disconnect(_apply_layout)


func _build_world_view() -> void:
	world_view = WORLD_VIEW.instantiate()
	add_child(world_view)
	world = world_view.view


## 掉落服务：监听敌人死亡，生成地面掉落物并结算金币/经验。
## 掉落物挂在实体容器里，跟随 y_sort 遮挡。
func _build_loot_service() -> void:
	loot_service = LOOT_SERVICE.new()
	loot_service.name = "LootService"
	loot_service.entity_root = map.get_entity_root()
	add_child(loot_service)


func _build_fx_layer() -> void:
	var layer := Node2D.new()
	layer.name = "FxLayer"
	layer.z_index = 100
	world.add_child(layer)
	CombatFx.layer = layer


## 屏幕/档位变化：重设世界层渲染分辨率，并按「可见格数恒定」重算相机 zoom。
## 只在离散档位与窗口尺寸变化时执行，不逐帧改，避免缩放抖动。
func _apply_layout() -> void:
	if not is_instance_valid(world_view):
		return
	world_view.set_render_size(DisplayAdapter.render_size)
	var camera := player.get_node_or_null("Camera") as Camera2D
	if camera == null:
		return
	camera.zoom = Vector2.ONE * DisplayAdapter.world_zoom
	camera.reset_smoothing()


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
