class_name UiButton
extends Control

## 通用菜单按钮：自绘矩形 + 文本，点击后发出 pressed 信号。
## 用于语言切换、设置入口与设置面板内的按钮（与战斗按钮解耦）。

signal pressed

@export var caption := ""
@export var font_size := 18
@export var highlight := false

var _held := false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	Locale.language_changed.connect(_on_language_changed)


func _exit_tree() -> void:
	if Locale.language_changed.is_connected(_on_language_changed):
		Locale.language_changed.disconnect(_on_language_changed)


func set_caption(text: String) -> void:
	if caption == text:
		return
	caption = text
	queue_redraw()


func set_highlight(value: bool) -> void:
	if highlight == value:
		return
	highlight = value
	queue_redraw()


func is_highlighted() -> bool:
	return highlight


func _on_language_changed(_code: String) -> void:
	queue_redraw()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if event.pressed:
			_held = true
			queue_redraw()
		elif _held:
			_held = false
			queue_redraw()
			pressed.emit()
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_held = true
			queue_redraw()
		elif _held:
			_held = false
			queue_redraw()
			pressed.emit()


func _draw() -> void:
	var rect := Rect2(Vector2.ZERO, size)
	var fill := Color(0.16, 0.20, 0.26, 0.92)
	if highlight:
		fill = Color(0.24, 0.40, 0.28, 0.95)
	if _held:
		fill = fill.lightened(0.12)
	draw_rect(rect, fill, true)
	draw_rect(rect, Color(1.0, 1.0, 1.0, 0.55), false, 2.0)

	var font := Locale.font
	if font == null:
		return
	var text_size := font.get_string_size(caption, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
	var pos := Vector2((size.x - text_size.x) * 0.5, (size.y + text_size.y * 0.55) * 0.5)
	draw_string(font, pos, caption, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color(1.0, 1.0, 1.0, 0.95))
