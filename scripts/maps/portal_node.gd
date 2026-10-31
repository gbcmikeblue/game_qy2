class_name PortalNode
extends Node2D

## 传送点：玩家走进半径内即触发一次换图请求。
##
## 触发条件是「距离」而不是 Area2D 重叠：验收里玩家是直接摆位的，
## 距离判定同样成立，也不需要额外的物理层配置。
## 触发后自身进入已触发状态，避免同一帧内重复发信号（换图由 main 负责）。

const TRIGGER_RADIUS := 24.0
## 建图后先等一小会儿再武装，防止「落点就在传送点上」导致立刻又传走。
const ARM_DELAY := 0.6

const RING_COLOR := Color(0.45, 0.78, 1.0, 0.85)
const CORE_COLOR := Color(0.20, 0.42, 0.70, 0.55)
const USED_COLOR := Color(0.45, 0.78, 1.0, 0.25)

var target_map := ""
var target_cell := Vector2i.ZERO

var _cooldown := ARM_DELAY
var _used := false


func setup(p_target_map: String, p_target_cell: Vector2i) -> void:
	target_map = p_target_map
	target_cell = p_target_cell
	queue_redraw()


func _ready() -> void:
	add_to_group("portals")
	z_index = -2


func _process(delta: float) -> void:
	_cooldown = maxf(0.0, _cooldown - delta)
	if _used or _cooldown > 0.0:
		return
	var player := GameManager.get_player()
	if player == null or not is_instance_valid(player):
		return
	if global_position.distance_to(player.global_position) > TRIGGER_RADIUS:
		return
	_used = true
	queue_redraw()
	EventBus.portal_entered.emit(target_map, target_cell)


## 允许再次触发（换图回来后由 main 统一重置）。
func rearm(delay := ARM_DELAY) -> void:
	_used = false
	_cooldown = delay
	queue_redraw()


func is_triggered() -> bool:
	return _used


func _draw() -> void:
	var color := USED_COLOR if _used else RING_COLOR
	draw_circle(Vector2.ZERO, 18.0, CORE_COLOR)
	draw_arc(Vector2.ZERO, 18.0, 0.0, TAU, 24, color, 3.0, true)
	if _used:
		return
	# 四段短弧表示"可以进入"，避免和地面装饰混淆。
	for i in 4:
		var angle := float(i) * TAU / 4.0 + TAU / 8.0
		var from := Vector2(cos(angle), sin(angle)) * 11.0
		var to := Vector2(cos(angle), sin(angle)) * 15.0
		draw_line(from, to, color, 2.0, true)
