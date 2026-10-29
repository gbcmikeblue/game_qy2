extends Control

## 虚拟摇杆：触屏/鼠标拖动，写入 InputManager.touch_vector（-1..1）。
## 只负责采集输入，不直接驱动角色。
##
## 触控契约（方案 §3.7）：
## 1. 多指并发——只认第一根按住的手指（event.index），后续手指的按下/抬起一律忽略；
## 2. 触摸与鼠标双路径——移动端「触摸模拟鼠标」会重复投递同一次按下/抬起，
##    因此一旦由触摸接管，鼠标路径的事件全部忽略，避免拖动中途被模拟鼠标抬起打断；
## 3. 热区补偿——控件物理尺寸不足 44dp 时命中区自动外扩。

## 最小可点物理尺寸（dp）。
const MIN_TOUCH_DP := 44.0

@export var base_radius := 84.0
@export var knob_radius := 38.0

var value := Vector2.ZERO

## 当前持有的指针：触摸为手指编号，鼠标为 0，-1 表示空闲。
var _pointer := -1
## 当前持有者是否是一根手指（用于把模拟鼠标事件挡在外面）。
var _is_touch := false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		queue_redraw()


## 热区补偿：控件本身够大时命中区就是自身矩形，不够大时向外扩到 44dp。
func _has_point(point: Vector2) -> bool:
	if not Rect2(Vector2.ZERO, size).has_point(point):
		return DisplayAdapter.expand_hit_rect(Rect2(Vector2.ZERO, size), MIN_TOUCH_DP).has_point(point)
	return true


func _gui_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		var touch := event as InputEventScreenTouch
		if touch.pressed:
			if _pointer == -1:
				_pointer = touch.index
				_is_touch = true
				_update_value(touch.position)
		elif _is_touch and touch.index == _pointer:
			_release()
	elif event is InputEventScreenDrag:
		var drag := event as InputEventScreenDrag
		if _is_touch and drag.index == _pointer:
			_update_value(drag.position)
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		# 触摸已接管时，模拟鼠标的按下/抬起不参与（否则拖动会被中途抬起打断）。
		if _is_touch:
			return
		var mouse := event as InputEventMouseButton
		if mouse.pressed:
			_pointer = 0
			_update_value(mouse.position)
		elif _pointer == 0:
			_release()
	elif event is InputEventMouseMotion and not _is_touch and _pointer == 0:
		_update_value((event as InputEventMouseMotion).position)


func _update_value(local_position: Vector2) -> void:
	var offset := local_position - size * 0.5
	value = offset.limit_length(base_radius) / base_radius
	InputManager.touch_vector = value
	queue_redraw()


func _release() -> void:
	_pointer = -1
	_is_touch = false
	value = Vector2.ZERO
	InputManager.touch_vector = Vector2.ZERO
	queue_redraw()


func _draw() -> void:
	var center := size * 0.5
	draw_circle(center, base_radius, Color(0.0, 0.0, 0.0, 0.25))
	draw_arc(center, base_radius, 0.0, TAU, 48, Color(1.0, 1.0, 1.0, 0.30), 2.0, true)
	draw_line(center - Vector2(base_radius * 0.5, 0.0), center + Vector2(base_radius * 0.5, 0.0), Color(1.0, 1.0, 1.0, 0.12), 1.0)
	draw_line(center - Vector2(0.0, base_radius * 0.5), center + Vector2(0.0, base_radius * 0.5), Color(1.0, 1.0, 1.0, 0.12), 1.0)

	var knob := center + value * base_radius
	draw_circle(knob, knob_radius, Color(1.0, 1.0, 1.0, 0.30))
	draw_arc(knob, knob_radius, 0.0, TAU, 32, Color(1.0, 1.0, 1.0, 0.55), 2.0, true)
