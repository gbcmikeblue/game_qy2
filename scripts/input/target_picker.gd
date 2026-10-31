extends Node

## 点击/点触选中目标：点敌人只做“选中”，点空白取消选中。
##
## 与攻击完全分离：这里只调用玩家的 select_target()/clear_selection()，
## 不发送任何攻击事件；攻击只能由 ATK 按钮或攻击键触发。
##
## 事件来源：走 _unhandled_input，UI（摇杆/按钮/设置面板）会把事件吃掉，
## 所以在 UI 上点按不会误触发选中。

## 命中判定框（相对敌人脚底）：覆盖躯干、血条与名字，手指点击不用太精准。
const HIT_BOX := Rect2(Vector2(-26.0, -72.0), Vector2(52.0, 88.0))

## 世界层容器（WorldView）。世界在独立 SubViewport 内渲染后，
## 屏幕坐标到世界坐标的映射只有它知道，因此由 main 注入。
var world_view: Node = null


func setup(view: Node) -> void:
	world_view = view


func _unhandled_input(event: InputEvent) -> void:
	if GameManager.is_paused:
		return

	var screen_position := Vector2.ZERO
	var is_release := false
	if event is InputEventScreenTouch:
		var touch := event as InputEventScreenTouch
		if touch.pressed:
			return
		screen_position = touch.position
		is_release = true
	elif event is InputEventMouseButton:
		var mouse := event as InputEventMouseButton
		if mouse.button_index != MOUSE_BUTTON_LEFT or mouse.pressed:
			return
		screen_position = mouse.position
		is_release = true

	if not is_release:
		return

	pick_at_screen(screen_position)
	get_viewport().set_input_as_handled()


## 屏幕坐标 -> 选中/取消选中。返回是否发生了选中变化，便于测试与调试复用。
func pick_at_screen(screen_position: Vector2) -> bool:
	return pick_at_world(_screen_to_world(screen_position))


## 世界坐标 -> 选中/取消选中（与屏幕口径解耦，测试与调试可直接调用）。
func pick_at_world(world_position: Vector2) -> bool:
	var player = GameManager.player
	if not is_instance_valid(player) or not player.is_alive():
		return false

	var before = player.get_selected_target()
	var target = _target_at(player, world_position)
	var selected := false
	if is_instance_valid(target):
		selected = player.select_target(target)
	else:
		player.clear_selection()

	# 点击空白或点到别的目标 -> 中断持续攻击（点同一个目标不算主动中断）。
	if player.get_selected_target() != before:
		player.cancel_auto_attack()
	return selected


func _screen_to_world(screen_position: Vector2) -> Vector2:
	if is_instance_valid(world_view) and world_view.has_method("screen_to_world"):
		return world_view.screen_to_world(screen_position)
	# 没有世界层容器时（例如单独跑拾取逻辑）退回根视口画布变换。
	return get_viewport().get_canvas_transform().affine_inverse() * screen_position


## 命中优先级：判定框内离点击点最近的目标。
## 敌人与 NPC 同等参与（NPC 也能点选，选中后主操作变成「交互」）。
func _target_at(player, world_position: Vector2):
	var best = null
	var best_distance := INF
	for enemy: Node in player.lock_targets():
		var distance := _hit_distance(enemy, world_position)
		if distance < best_distance:
			best = enemy
			best_distance = distance
	for npc: Node in player.get_tree().get_nodes_in_group("npcs"):
		if not (npc is Node2D):
			continue
		var distance := _hit_distance(npc, world_position)
		if distance < best_distance:
			best = npc
			best_distance = distance
	return best


## 命中返回点到目标脚底的距离，未命中返回 INF。
func _hit_distance(node: Node, world_position: Vector2) -> float:
	if not (node is Node2D):
		return INF
	var local: Vector2 = world_position - (node as Node2D).global_position
	if not HIT_BOX.has_point(local):
		return INF
	return local.length()
