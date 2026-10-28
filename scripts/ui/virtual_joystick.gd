extends Control

## 虚拟摇杆：触屏/鼠标拖动，写入 InputManager.touch_vector（-1..1）。
## 只负责采集输入，不直接驱动角色。

@export var base_radius := 84.0
@export var knob_radius := 38.0

var value := Vector2.ZERO

var _pointer := -1


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		queue_redraw()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if event.pressed and _pointer == -1:
			_pointer = event.index
			_update_value(event.position)
		elif not event.pressed and event.index == _pointer:
			_release()
	elif event is InputEventScreenDrag:
		if event.index == _pointer:
			_update_value(event.position)
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_pointer = 0
			_update_value(event.position)
		else:
			_release()
	elif event is InputEventMouseMotion and _pointer == 0:
		_update_value(event.position)


func _update_value(local_position: Vector2) -> void:
	var offset := local_position - size * 0.5
	value = offset.limit_length(base_radius) / base_radius
	InputManager.touch_vector = value
	queue_redraw()


func _release() -> void:
	_pointer = -1
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
