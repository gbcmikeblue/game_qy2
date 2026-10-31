class_name UiButton
extends Control

## 通用菜单按钮：自绘矩形 + 文本，点击后发出 pressed 信号。
## 用于语言切换、设置入口与设置面板内的按钮（与战斗按钮解耦）。

signal pressed

@export var caption := ""
@export var font_size := 18
@export var highlight := false
## 圆形图标按钮（设置 / 背包 / 任务等功能入口）：只画圆底 + 程序化图标，不画文字。
@export var circular := false
## 图标种类：settings / bag / quest；空则退回文字按钮。
@export var icon := ""

var _held := false
## 禁用态：置灰且不响应（用于当前显示器放不下的分辨率档位）。
var _disabled := false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	Locale.language_changed.connect(_on_language_changed)


func set_disabled(value: bool) -> void:
	if _disabled == value:
		return
	_disabled = value
	if _disabled:
		_held = false
	queue_redraw()


func is_disabled() -> bool:
	return _disabled


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
	if _disabled:
		return
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


## 圆形按钮的命中区也是圆的：方形热区会让"点在角上"也触发，手机上误触明显。
func _has_point(point: Vector2) -> bool:
	if not circular:
		return Rect2(Vector2.ZERO, size).has_point(point)
	return point.distance_to(size * 0.5) <= minf(size.x, size.y) * 0.5


func _draw() -> void:
	var rect := Rect2(Vector2.ZERO, size)
	var fill := Color(0.16, 0.20, 0.26, 0.92)
	if highlight:
		fill = Color(0.24, 0.40, 0.28, 0.95)
	if _held:
		fill = fill.lightened(0.12)
	var dim := 1.0
	if _disabled:
		fill = Color(0.12, 0.13, 0.15, 0.55)
		dim = 0.45
	if circular:
		var center := size * 0.5
		var radius := minf(size.x, size.y) * 0.5
		draw_circle(center, radius, fill)
		draw_arc(center, radius - 1.0, 0.0, TAU, 40, Color(1.0, 1.0, 1.0, 0.55 * dim), 2.0, true)
		_draw_icon(center, radius * 0.52, Color(1.0, 1.0, 1.0, 0.92 * dim))
		return
	draw_rect(rect, fill, true)
	draw_rect(rect, Color(1.0, 1.0, 1.0, 0.55 * dim), false, 2.0)

	var font := Locale.font
	if font == null:
		return
	var text_size := font.get_string_size(caption, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
	var pos := Vector2((size.x - text_size.x) * 0.5, (size.y + text_size.y * 0.55) * 0.5)
	draw_string(font, pos, caption, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size,
			Color(1.0, 1.0, 1.0, 0.95 * dim))

## 程序化图标：不引入任何贴图，缩放后依然清晰（素材接入时替换这里即可）。
func _draw_icon(center: Vector2, r: float, color: Color) -> void:
	match icon:
		"settings":
			draw_arc(center, r * 0.55, 0.0, TAU, 24, color, 2.0, true)
			draw_circle(center, r * 0.16, color)
			for i in 8:
				var angle := TAU * float(i) / 8.0
				var dir := Vector2(cos(angle), sin(angle))
				draw_line(center + dir * r * 0.68, center + dir * r * 0.98, color, 2.0)
		"bag":
			var body := Rect2(center + Vector2(-r * 0.62, -r * 0.16), Vector2(r * 1.24, r * 0.82))
			draw_rect(body, color, false, 2.0)
			draw_arc(center + Vector2(0.0, -r * 0.16), r * 0.36, PI, TAU, 16, color, 2.0, true)
		"quest":
			var sheet := Rect2(center + Vector2(-r * 0.54, -r * 0.66), Vector2(r * 1.08, r * 1.32))
			draw_rect(sheet, color, false, 2.0)
			for i in 3:
				var y := sheet.position.y + r * 0.32 * float(i + 1)
				draw_line(Vector2(sheet.position.x + r * 0.16, y),
						Vector2(sheet.end.x - r * 0.16, y), color, 1.6)
		_:
			draw_circle(center, r * 0.45, color)
