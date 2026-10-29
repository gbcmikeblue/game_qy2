class_name DamageNumber
extends Node2D

## 伤害飘字：上浮 + 淡出，挂在专门的 FxLayer 上，不参与 y_sort。

const DURATION := 0.8
const RISE_SPEED := 34.0
const FONT_SIZE := 18

var _text := ""
var _color := Color.WHITE
var _life := 0.0


func setup(text: String, color: Color) -> void:
	_text = text
	_color = color


func _process(delta: float) -> void:
	_life += delta
	position.y -= RISE_SPEED * delta
	modulate.a = clampf(1.0 - _life / DURATION, 0.0, 1.0)
	queue_redraw()
	if _life >= DURATION:
		queue_free()


func _draw() -> void:
	if _text.is_empty():
		return
	var font := Locale.font
	var width := font.get_string_size(_text, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE).x
	draw_string(font, Vector2(-width * 0.5, 0.0), _text, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, _color)
