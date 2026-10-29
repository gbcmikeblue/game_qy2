extends Control

## 触屏按钮：按下高亮，抬起广播一次攻击请求。支持禁用态（无可用操作时置灰且不响应）。
## 目标选中不经过按钮：它由世界点击拾取器负责，选中与攻击完全分离。

@export var radius := 56.0
@export var caption := "ATK"

var _held := false
var _disabled := false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		queue_redraw()


## 文案变化需要主动重绘（直接改 caption 属性不会触发 _draw）。
func set_caption(text: String) -> void:
	if caption == text:
		return
	caption = text
	queue_redraw()


func set_disabled(value: bool) -> void:
	if _disabled == value:
		return
	_disabled = value
	if _disabled:
		_held = false
	queue_redraw()


func is_disabled() -> bool:
	return _disabled


func _gui_input(event: InputEvent) -> void:
	if _disabled:
		return
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
	# 按下即通知，用于“长按达到秒数触发持续攻击”；动作本身仍只在抬起时触发。
	EventBus.attack_pressed.emit()


func _release() -> void:
	if not _held:
		return
	_held = false
	queue_redraw()
	EventBus.attack_requested.emit()


func _draw() -> void:
	var center := size * 0.5
	var dim := 0.3 if _disabled else 1.0
	var fill := Color(0.75, 0.28, 0.24, 0.55) if _held else Color(0.15, 0.15, 0.18, 0.45)
	if _disabled:
		fill = Color(0.12, 0.12, 0.14, 0.25)
	draw_circle(center, radius, fill)
	draw_arc(center, radius, 0.0, TAU, 40, Color(1.0, 1.0, 1.0, 0.55 * dim), 2.5, true)

	var font := Locale.font
	var font_size := 20
	var width := font.get_string_size(caption, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	draw_string(font, center + Vector2(-width * 0.5, font_size * 0.35), caption,
			HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color(1.0, 1.0, 1.0, 0.9 * dim))
