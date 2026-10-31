extends Node2D

## 敌人占位视觉：按配置颜色/体型绘制，原点在脚底。含名字、血条、受击闪白。

const C_HP_BACK := Color(0.0, 0.0, 0.0, 0.65)
const C_HP := Color(0.824, 0.267, 0.267)
const C_OUTLINE := Color(0.0, 0.0, 0.0, 0.45)
const C_EYE := Color(0.95, 0.78, 0.35)

var _body_color := Color(0.45, 0.45, 0.45)
var _body_radius := 11.0
var _display_name := "ENEMY"
var _id := ""
var _hp := 10
var _max_hp := 10
var _flash_left := 0.0
var _dead := false

# 锁定/预览高亮：透明度平滑过渡，避免切换目标时高亮硬跳。
var _locked := false
var _lock_alpha := 0.0
var _lock_pulse := 0.0

const C_LOCK := Color(1.0, 0.84, 0.28)


func _ready() -> void:
	Locale.language_changed.connect(_on_language_changed)


func _exit_tree() -> void:
	if Locale.language_changed.is_connected(_on_language_changed):
		Locale.language_changed.disconnect(_on_language_changed)


func _on_language_changed(_code: String) -> void:
	queue_redraw()


## 敌人名优先用语言表（enemy.<id>），没有对应条目时回退到配置里的 display_name。
func _name_text() -> String:
	if not _id.is_empty():
		var key := "enemy." + _id
		if Locale.has_key(key):
			return Locale.t(key)
	return _display_name


func configure(def: Dictionary) -> void:
	_id = String(def.get("id", ""))
	_display_name = String(def.get("display_name", "ENEMY"))
	_body_radius = float(def.get("body_radius", 11.0))
	var raw_color: Variant = def.get("color", [0.45, 0.45, 0.45])
	if raw_color is Array and (raw_color as Array).size() >= 3:
		var array := raw_color as Array
		_body_color = Color(float(array[0]), float(array[1]), float(array[2]))
	queue_redraw()


func set_health(current: int, maximum: int) -> void:
	_hp = maxi(0, current)
	_max_hp = maxi(1, maximum)
	queue_redraw()


func flash() -> void:
	_flash_left = 0.16
	queue_redraw()


func set_dead(value: bool) -> void:
	_dead = value
	queue_redraw()


func set_locked(value: bool) -> void:
	_locked = value


func _process(delta: float) -> void:
	if _flash_left > 0.0:
		_flash_left = maxf(0.0, _flash_left - delta)
		queue_redraw()

	var lock_goal := 1.0 if _locked and not _dead else 0.0
	if not is_equal_approx(_lock_alpha, lock_goal):
		_lock_alpha = move_toward(_lock_alpha, lock_goal, delta * 6.0)
		queue_redraw()

	if _lock_alpha > 0.01:
		_lock_pulse += delta * 4.0
		queue_redraw()


func _draw() -> void:
	var color := _body_color
	if _flash_left > 0.0:
		color = Color(1.0, 0.92, 0.9)
	if _dead:
		color = _body_color.darkened(0.45)

	if _lock_alpha > 0.01:
		_draw_lock_marker()

	var height := _body_radius * 2.0
	if _dead:
		draw_colored_polygon(_ellipse(Vector2(0.0, -3.0), _body_radius * 1.25, _body_radius * 0.5), Color(0.0, 0.0, 0.0, 0.3))
		draw_colored_polygon(_ellipse(Vector2(0.0, -6.0), _body_radius, _body_radius * 0.45), color)
		return

	draw_colored_polygon(_ellipse(Vector2(0.0, -3.0), _body_radius * 1.15, _body_radius * 0.55), Color(0.0, 0.0, 0.0, 0.28))
	# 身体
	draw_colored_polygon(_ellipse(Vector2(0.0, -height * 0.55), _body_radius, _body_radius * 0.75), color)
	# 头
	draw_circle(Vector2(0.0, -height * 1.05), _body_radius * 0.62, color.lightened(0.08))
	# 眼睛
	draw_circle(Vector2(-_body_radius * 0.22, -height * 1.08), 1.8, C_EYE)
	draw_circle(Vector2(_body_radius * 0.22, -height * 1.08), 1.8, C_EYE)
	draw_polyline(Iso.closed(PackedVector2Array([
		Vector2(-_body_radius, -height * 0.55),
		Vector2(0.0, -height * 1.32),
		Vector2(_body_radius, -height * 0.55),
		Vector2(0.0, -height * 0.2),
	])), C_OUTLINE, 1.0)

	var bar_width := _body_radius * 2.4
	var bar_y := -height * 1.62
	draw_rect(Rect2(-bar_width * 0.5, bar_y, bar_width, 5.0), C_HP_BACK)
	var ratio := float(_hp) / float(_max_hp)
	draw_rect(Rect2(-bar_width * 0.5 + 1.0, bar_y + 1.0, (bar_width - 2.0) * ratio, 3.0), C_HP)

	var font := Locale.font
	var text := _name_text()
	var width := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x
	var name_color := Color(1.0, 1.0, 1.0, 0.85)
	if _lock_alpha > 0.01:
		name_color = name_color.lerp(C_LOCK, _lock_alpha)
	draw_string(font, Vector2(-width * 0.5, bar_y - 4.0), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, name_color)


## 选中高亮：脚下脉动双环 + 头顶下指三角 + 名字染色，被怪物包围时也能一眼分辨当前目标。
func _draw_lock_marker() -> void:
	var pulse := 1.0 + sin(_lock_pulse) * 0.08
	var ring_radius := _body_radius * 2.2 * pulse
	var color := Color(C_LOCK.r, C_LOCK.g, C_LOCK.b, 0.95 * _lock_alpha)
	var center := Vector2(0.0, -2.0)
	draw_polyline(_ellipse_closed(center, ring_radius, ring_radius * 0.52), color, 3.0)
	draw_polyline(_ellipse_closed(center, ring_radius + 5.0, (ring_radius + 5.0) * 0.52),
			Color(color.r, color.g, color.b, color.a * 0.45), 1.5)

	var top_y := -_body_radius * 2.1 - 24.0
	draw_colored_polygon(PackedVector2Array([
		Vector2(0.0, top_y),
		Vector2(-7.5, top_y - 12.0),
		Vector2(7.5, top_y - 12.0),
	]), color)


func _ellipse_closed(center: Vector2, rx: float, ry: float) -> PackedVector2Array:
	var points := _ellipse(center, rx, ry)
	points.append(points[0])
	return points


func _ellipse(center: Vector2, rx: float, ry: float) -> PackedVector2Array:
	var points := PackedVector2Array()
	for i in 16:
		var angle := TAU * float(i) / 16.0
		points.append(center + Vector2(cos(angle) * rx, sin(angle) * ry))
	return points
