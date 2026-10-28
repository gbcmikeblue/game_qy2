extends Control

## 触屏技能/攻击按钮占位：按下高亮，抬起广播 attack_requested。

@export var radius := 56.0
@export var caption := "ATK"

var _held := false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		queue_redraw()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if event.pressed:
			_press()
		else:
			_release()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_press()
		else:
			_release()


func _press() -> void:
	_held = true
	queue_redraw()


func _release() -> void:
	if not _held:
		return
	_held = false
	queue_redraw()
	EventBus.attack_requested.emit()


func _draw() -> void:
	var center := size * 0.5
	var fill := Color(0.75, 0.28, 0.24, 0.55) if _held else Color(0.15, 0.15, 0.18, 0.45)
	draw_circle(center, radius, fill)
	draw_arc(center, radius, 0.0, TAU, 40, Color(1.0, 1.0, 1.0, 0.55), 2.5, true)

	var font := ThemeDB.fallback_font
	var font_size := 18
	var width := font.get_string_size(caption, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	draw_string(font, center + Vector2(-width * 0.5, font_size * 0.35), caption, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color(1.0, 1.0, 1.0, 0.9))
