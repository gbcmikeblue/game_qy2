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
const INVENTORY_PANEL := preload("res://scenes/ui/inventory_panel.tscn")
const DIALOGUE_PANEL := preload("res://scenes/ui/dialogue_panel.tscn")

var map
var player
var world_view
var world: SubViewport
var loot_service: Node
## NPC 交互：先对话，再从对话里进商店（同一时间只允许一个面板）。
var _dialogue_panel: Node = null
var _shop_panel: Node = null

## 换图/读档后的短暂"传送免疫"，避免落点就在传送点上时立刻又被传走。
const PORTAL_GRACE := 0.8
var _portal_grace := 0.0


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

	# 供存档服务查询/切换地图：读档时若存档在别的地图，先切图再恢复位置。
	SaveService.current_map_id = String(map.map_id)
	SaveService.map_switcher = switch_map

	# 走进传送点由 main 统一换图：地图只负责摆放与发信号。
	EventBus.portal_entered.connect(_on_portal_entered)
	EventBus.target_action_requested.connect(_on_target_action)

	# 主菜单选了「读取存档」：等玩家、地图、HUD 都就绪后再恢复，
	# 否则位置与血量会写到还不存在的节点上。
	var pending := SaveService.consume_pending_slot()
	if pending > 0:
		if SaveService.load_slot(pending):
			_portal_grace = PORTAL_GRACE
		else:
			push_warning("读档失败（槽 %d），按新游戏继续" % pending)


## 换图：保留玩家节点与状态，只重建地图，并把依赖地图的引用重新接上
## （实体挂载点、寻路、掉落挂载点、相机限位）。spawn_cell 为 (-1,-1) 时用新图出生点。
func switch_map(next_id: String, spawn_cell := Vector2i(-1, -1)) -> bool:
	if map != null and String(map.map_id) == next_id:
		return false

	player.clear_targets()
	map.get_entity_root().remove_child(player)
	world.remove_child(map)
	map.queue_free()

	map = MAP_SCENE.instantiate()
	map.map_id = next_id
	world.add_child(map)

	map.get_entity_root().add_child(player)
	var cell: Vector2i = spawn_cell if spawn_cell != Vector2i(-1, -1) else map.player_spawn
	player.global_position = Iso.grid_to_world(cell)
	player.spawn_point = player.global_position
	player.velocity = Vector2.ZERO
	player.setup_navigation(map)

	if loot_service != null:
		loot_service.entity_root = map.get_entity_root()

	SaveService.current_map_id = next_id
	_apply_camera_limits()
	_apply_layout()
	return true


func _exit_tree() -> void:
	if DisplayAdapter.layout_changed.is_connected(_apply_layout):
		DisplayAdapter.layout_changed.disconnect(_apply_layout)
	if EventBus.portal_entered.is_connected(_on_portal_entered):
		EventBus.portal_entered.disconnect(_on_portal_entered)
	if EventBus.target_action_requested.is_connected(_on_target_action):
		EventBus.target_action_requested.disconnect(_on_target_action)


func _process(delta: float) -> void:
	_portal_grace = maxf(0.0, _portal_grace - delta)


## 传送点触发：换到目标地图与落点，并给一小段免疫，避免在门口来回弹。
func _on_portal_entered(target_map: String, target_cell: Vector2i) -> void:
	if _portal_grace > 0.0:
		return
	if switch_map(target_map, target_cell):
		_portal_grace = PORTAL_GRACE


## 主操作命中 NPC：打开背包面板并直接落在商店页签。
## 目前 NPC 只卖东西（没有对话系统），所以交互直接进交易。
func _on_target_action(kind: String, target: Node) -> void:
	# 只认真正的 NPC 节点：kind 为 "npc" 但实体不是 NpcNode 的情况（测试替身、
	# 将来可能出现的"伪装 NPC"敌人）不应弹出对话。
	if kind != "npc" or target == null or not is_instance_valid(target) or not (target is NpcNode):
		return
	if is_instance_valid(_dialogue_panel) or is_instance_valid(_shop_panel):
		return
	open_dialogue(target as NpcNode)


## 打开 NPC 对话；「交易」由对话面板发信号后再进商店。
func open_dialogue(npc: NpcNode) -> void:
	_dialogue_panel = DIALOGUE_PANEL.instantiate()
	_dialogue_panel.npc = npc
	_dialogue_panel.speaker_name_key = npc.display_name_key
	_dialogue_panel.dialogue_key = npc.dialogue_key
	_dialogue_panel.shop_id = npc.shop_id
	_dialogue_panel.quest_giver = npc.quest_giver
	add_child(_dialogue_panel)
	if _dialogue_panel.has_signal("closed"):
		_dialogue_panel.closed.connect(_on_dialogue_closed)
	if _dialogue_panel.has_signal("trade_requested"):
		_dialogue_panel.trade_requested.connect(_on_dialogue_trade)


func _on_dialogue_closed() -> void:
	_dialogue_panel = null


func _on_dialogue_trade(shop_id: StringName) -> void:
	if is_instance_valid(_shop_panel):
		return
	_shop_panel = INVENTORY_PANEL.instantiate()
	_shop_panel.shop_id = shop_id
	_shop_panel.initial_tab = 2
	add_child(_shop_panel)
	if _shop_panel.has_signal("closed"):
		_shop_panel.closed.connect(_on_shop_panel_closed)


func _on_shop_panel_closed() -> void:
	_shop_panel = null


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
