extends Control

## 触屏按钮：按下高亮，抬起广播一次攻击请求。支持禁用态（无可用操作时置灰且不响应）。
## 目标选中不经过按钮：它由世界点击拾取器负责，选中与攻击完全分离。
##
## 触控契约（方案 §3.7）：
## 1. 多指并发——只认第一根按下并持有按钮的手指（event.index），其余手指的按下/抬起一律忽略，
##    避免"摇杆 + 攻击 + 目标选择"三指同时操作时重复触发；
## 2. 单指幂等——移动端的「触摸模拟鼠标」会给同一次点按投递两条事件路径，
##    因此按下/抬起都按 _held 去重，单指只产生一次 attack_pressed 与一次 attack_requested；
## 3. 热区补偿——控件物理尺寸不足 44dp 时命中区自动外扩（绘制尺寸不变）。

## 最小可点物理尺寸（dp）。
const MIN_TOUCH_DP := 44.0

@export var radius := 56.0
@export var caption := "ATK"
## 按钮动作：attack = 主操作；skill = 技能（只在抬起时广播一次 skill_requested）。
@export var action := "attack"

var _held := false
var _disabled := false
## 当前持有按钮的手指编号；-1 表示无人持有。
var _touch_index := -1
## 技能冷却进度（0 = 就绪，1 = 刚进入冷却），用环形覆盖表示。
var _cooldown_ratio := 0.0


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
		_touch_index = -1
	queue_redraw()


func is_disabled() -> bool:
	return _disabled


## 冷却进度：只有技能按钮会用（0 表示不进环形）。
func set_cooldown(ratio: float) -> void:
	var next := clampf(ratio, 0.0, 1.0)
	if is_equal_approx(next, _cooldown_ratio):
		return
	_cooldown_ratio = next
	queue_redraw()


func cooldown_ratio() -> float:
	return _cooldown_ratio


func _gui_input(event: InputEvent) -> void:
	if _disabled:
		return
	if event is InputEventScreenTouch:
		var touch := event as InputEventScreenTouch
		if touch.pressed:
			if _touch_index == -1 and not _held:
				_touch_index = touch.index
				_press()
		elif touch.index == _touch_index:
			_release()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_press()
		else:
			_release()


func _press() -> void:
	if _held:
		return
	_held = true
	queue_redraw()
	# 按下即通知，用于"长按达到秒数触发持续攻击"；动作本身仍只在抬起时触发。
	# 技能按钮没有「长按连发」语义，按下时什么也不发。
	if action == "attack":
		EventBus.attack_pressed.emit()


func _release() -> void:
	if not _held:
		return
	_held = false
	_touch_index = -1
	queue_redraw()
	if action == "skill":
		EventBus.skill_requested.emit("heavy_strike")
	else:
		EventBus.attack_requested.emit()


func _draw() -> void:
	var center := size * 0.5
	var dim := 0.3 if _disabled else 1.0
	var fill := Color(0.75, 0.28, 0.24, 0.55) if _held else Color(0.15, 0.15, 0.18, 0.45)
	if _disabled:
		fill = Color(0.12, 0.12, 0.14, 0.25)
	draw_circle(center, radius, fill)
	draw_arc(center, radius, 0.0, TAU, 40, Color(1.0, 1.0, 1.0, 0.55 * dim), 2.5, true)
	if _cooldown_ratio > 0.0:
		var sweep := TAU * _cooldown_ratio
		draw_arc(center, radius - 4.0, -PI * 0.5, -PI * 0.5 + sweep, 32,
				Color(0.55, 0.75, 1.0, 0.78), 5.0, true)

	var font := Locale.font
	# 与 HUD/设置面板同一套文字角色。
	var font_size := DisplayAdapter.text_px("body")
	var width := font.get_string_size(caption, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	draw_string(font, center + Vector2(-width * 0.5, font_size * 0.35), caption,
			HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color(1.0, 1.0, 1.0, 0.9 * dim))
