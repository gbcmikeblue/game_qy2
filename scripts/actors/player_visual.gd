extends Node2D

## 玩家占位视觉：原点在脚底，所有绘制都向上生长，保证 y_sort 按脚底排序。

const C_SHADOW := Color(0.0, 0.0, 0.0, 0.30)
const C_LEG := Color(0.212, 0.212, 0.271)
const C_TORSO := Color(0.239, 0.416, 0.651)
const C_TORSO_HURT := Color(1.0, 0.55, 0.55)
const C_SKIN := Color(0.855, 0.702, 0.549)
const C_HP_BACK := Color(0.0, 0.0, 0.0, 0.65)
const C_HP := Color(0.839, 0.263, 0.263)
const C_HP_LOW := Color(0.95, 0.55, 0.20)

var _facing := Vector2.DOWN
var _hp := 100
var _max_hp := 100
var _flash_left := 0.0
var _dead := false


func _ready() -> void:
	Locale.language_changed.connect(_on_language_changed)


func _exit_tree() -> void:
	if Locale.language_changed.is_connected(_on_language_changed):
		Locale.language_changed.disconnect(_on_language_changed)


func _on_language_changed(_code: String) -> void:
	queue_redraw()


func set_facing(direction: Vector2) -> void:
	if direction.length() < 0.01:
		return
	var normalized := direction.normalized()
	if normalized.distance_to(_facing) < 0.05:
		return
	_facing = normalized
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


func _process(delta: float) -> void:
	if _flash_left > 0.0:
		_flash_left = maxf(0.0, _flash_left - delta)
		queue_redraw()


func _draw() -> void:
	var torso := C_TORSO_HURT if _flash_left > 0.0 else C_TORSO

	draw_colored_polygon(_ellipse(Vector2(0.0, -2.0), 11.0, 5.5), C_SHADOW)

	if _dead:
		draw_colored_polygon(_ellipse(Vector2(0.0, -8.0), 18.0, 7.0), C_LEG)
		draw_colored_polygon(_ellipse(Vector2(0.0, -11.0), 13.0, 6.0), torso)
		draw_circle(Vector2(-11.0, -12.0), 6.0, C_SKIN)
		_draw_name_and_bar()
		return

	draw_rect(Rect2(-6.0, -22.0, 5.0, 20.0), C_LEG)
	draw_rect(Rect2(1.0, -22.0, 5.0, 20.0), C_LEG)
	draw_rect(Rect2(-8.0, -42.0, 16.0, 22.0), torso)
	draw_circle(Vector2(0.0, -50.0), 8.0, C_SKIN)
	draw_circle(Vector2(0.0, -50.0) + _facing * 3.0, 2.2, Color(0.157, 0.157, 0.196))
	_draw_name_and_bar()


func _draw_name_and_bar() -> void:
	var ratio := clampf(float(_hp) / float(_max_hp), 0.0, 1.0)
	draw_rect(Rect2(-14.0, -70.0, 28.0, 5.0), C_HP_BACK)
	var bar_color := C_HP if ratio > 0.3 else C_HP_LOW
	draw_rect(Rect2(-13.0, -69.0, 26.0 * ratio, 3.0), bar_color)

	var font := Locale.font
	var text := Locale.t("actor.hero")
	var width := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x
	draw_string(font, Vector2(-width * 0.5, -75.0), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(1.0, 1.0, 1.0, 0.92))


func _ellipse(center: Vector2, rx: float, ry: float) -> PackedVector2Array:
	var points := PackedVector2Array()
	for i in 16:
		var angle := TAU * float(i) / 16.0
		points.append(center + Vector2(cos(angle) * rx, sin(angle) * ry))
	return points
