extends Node

## 触控契约验收（《移动端多分辨率适配方案》§3.7 / §7.6）：
## 1. 单指只产生一次 attack_pressed 与一次 attack_requested；
## 2. 多指并发：只有第一根按住的手指生效，其余手指按下/抬起都不影响状态；
## 3. 触摸模拟鼠标双路径幂等：同一次点按只算一次；
## 4. 禁用态不响应；
## 5. 摇杆：第二根手指不改变方向，模拟鼠标抬起不打断触摸拖动；
## 6. 热区补偿：物理尺寸不足 44dp 时命中区外扩，达标时保持原矩形；
## 7. 暂停门控：暂停时主操作按钮不响应；
## 8. 切后台自动暂停：落盘 + 不误伤其它暂停来源。
## 运行：godot --headless --path <项目> res://tests/touch_contract_check.tscn

const HUD_SCENE := preload("res://scenes/ui/hud.tscn")

var _failures: Array[String] = []
var _pressed_count := 0
var _requested_count := 0

var _sub: SubViewport
var _hud
var _button
var _stick


func _ready() -> void:
	EventBus.attack_pressed.connect(_on_pressed)
	EventBus.attack_requested.connect(_on_requested)
	await _build_hud()

	_test_button_single_finger()
	_test_button_multi_finger()
	_test_button_touch_mouse_idempotent()
	_test_button_disabled()
	_test_joystick_finger_isolation()
	_test_hit_area()
	await _test_pause_gate()
	_test_background_pause()
	_cleanup()
	_report()


func _build_hud() -> void:
	_sub = SubViewport.new()
	_sub.size = Vector2i(1280, 720)
	_sub.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(_sub)
	_hud = HUD_SCENE.instantiate()
	_sub.add_child(_hud)
	await get_tree().process_frame
	_button = _hud.get_node("AttackButton")
	_stick = _hud.get_node("Joystick")


func _test_button_single_finger() -> void:
	_reset_counts()
	_button._gui_input(_touch(1, true))
	_button._gui_input(_touch(1, false))
	_check(_pressed_count == 1, "单指：按下广播一次（实际 %d）" % _pressed_count)
	_check(_requested_count == 1, "单指：抬起请求一次（实际 %d）" % _requested_count)


func _test_button_multi_finger() -> void:
	_reset_counts()
	_button._gui_input(_touch(1, true))
	_button._gui_input(_touch(2, true))
	_check(_pressed_count == 1, "多指：第二根手指按下不重复广播（实际 %d）" % _pressed_count)

	_button._gui_input(_touch(2, false))
	_check(_requested_count == 0, "多指：非持有手指抬起不触发攻击（实际 %d）" % _requested_count)
	_check(_pressed_count == 1, "多指：非持有手指抬起后按钮仍按住")

	_button._gui_input(_touch(1, false))
	_check(_requested_count == 1, "多指：持有手指抬起才触发攻击（实际 %d）" % _requested_count)


func _test_button_touch_mouse_idempotent() -> void:
	_reset_counts()
	_button._gui_input(_touch(0, true))
	_button._gui_input(_mouse(true))
	_check(_pressed_count == 1, "幂等：触摸 + 模拟鼠标只广播一次按下（实际 %d）" % _pressed_count)

	_button._gui_input(_mouse(false))
	_button._gui_input(_touch(0, false))
	_check(_requested_count == 1, "幂等：同一次点按只请求一次攻击（实际 %d）" % _requested_count)


func _test_button_disabled() -> void:
	_reset_counts()
	_button.set_disabled(true)
	_button._gui_input(_touch(3, true))
	_button._gui_input(_touch(3, false))
	_check(_pressed_count == 0 and _requested_count == 0, "禁用态：按下与抬起都不响应")
	_button.set_disabled(false)


func _test_joystick_finger_isolation() -> void:
	var center: Vector2 = _stick.size * 0.5
	_stick._gui_input(_touch_at(1, true, center + Vector2(60.0, 0.0)))
	_check(InputManager.touch_vector.x > 0.5, "摇杆：第一根手指拖动生效（x=%.2f）" % InputManager.touch_vector.x)

	_stick._gui_input(_touch_at(2, true, center + Vector2(-60.0, 0.0)))
	_check(InputManager.touch_vector.x > 0.5, "摇杆：第二根手指按下不改变方向（x=%.2f）" % InputManager.touch_vector.x)

	_stick._gui_input(_mouse(false))
	_check(InputManager.touch_vector.x > 0.5, "摇杆：模拟鼠标抬起不打断触摸拖动（x=%.2f）" % InputManager.touch_vector.x)

	_stick._gui_input(_touch_at(1, false, center))
	_check(InputManager.touch_vector == Vector2.ZERO, "摇杆：持有手指抬起后归零")


func _test_hit_area() -> void:
	var min_size: float = DisplayAdapter.dp(_button.MIN_TOUCH_DP)
	var small := Rect2(Vector2.ZERO, Vector2(10.0, 10.0))
	var grown := DisplayAdapter.expand_hit_rect(small, 44.0)
	_check(is_equal_approx(grown.size.x, min_size) and is_equal_approx(grown.size.y, min_size),
		"热区补偿：10×10 外扩到 %.1f（44dp）" % min_size)
	_check(grown.position.x < 0.0 and grown.position.y < 0.0, "热区补偿：从中心向两侧生长")

	var big := Rect2(Vector2.ZERO, Vector2(400.0, 400.0))
	_check(DisplayAdapter.expand_hit_rect(big, 44.0) == big, "热区补偿：已达标的矩形不变")
	_check(not _button._has_point(Vector2(-5.0, _button.size.y * 0.5)),
		"实际按钮尺寸已达标，命中区不外扩")
	_check(_button._has_point(_button.size * 0.5), "实际按钮中心可点")


func _test_pause_gate() -> void:
	GameManager.set_paused(true)
	await get_tree().process_frame
	await get_tree().process_frame
	_reset_counts()
	_button._gui_input(_touch(7, true))
	_button._gui_input(_touch(7, false))
	_check(_pressed_count == 0 and _requested_count == 0, "暂停门控：主操作按钮不响应（HUD 已置灰）")

	GameManager.set_paused(false)
	await get_tree().process_frame
	await get_tree().process_frame
	_reset_counts()
	_button._gui_input(_touch(8, true))
	_button._gui_input(_touch(8, false))
	_check(_requested_count == 1, "解除暂停后按钮恢复响应（实际 %d）" % _requested_count)


func _test_background_pause() -> void:
	GameManager.set_paused(false)
	GameManager.pause_for_background()
	_check(GameManager.is_paused, "切后台会暂停")
	_check(GameManager.is_background_paused(), "切后台暂停被标记为后台来源")
	GameManager.resume_from_background()
	_check(not GameManager.is_paused, "回前台自动恢复")
	_check(not GameManager.is_background_paused(), "回前台清掉后台标记")

	# 其它来源已经暂停时（例如设置面板），切后台/回前台不得改动它。
	GameManager.set_paused(true)
	GameManager.pause_for_background()
	_check(GameManager.is_background_paused(), "后台原因与其它原因各自持有")
	GameManager.resume_from_background()
	_check(GameManager.is_paused, "释放后台原因后其它原因的暂停仍然生效")
	GameManager.set_paused(false)
	_check(not GameManager.is_paused, "清空原因后恢复运行")

	# 手动暂停（ESC）不得顶掉设置面板的暂停。
	GameManager.hold_pause(GameManager.PAUSE_SETTINGS)
	GameManager.set_paused(true)
	GameManager.set_paused(false)
	_check(GameManager.is_paused, "手动暂停释放后设置面板的暂停仍在")
	_check(GameManager.pause_reasons() == ["settings"], "剩余暂停原因只有 settings（%s）"
		% str(GameManager.pause_reasons()))

	# 同一原因重复持有只广播一次状态变化。
	var emitted := 0
	var counter := func(_paused: bool) -> void: emitted += 1
	EventBus.game_paused.connect(counter)
	GameManager.clear_pauses()
	GameManager.hold_pause(GameManager.PAUSE_MANUAL)
	GameManager.hold_pause(GameManager.PAUSE_MANUAL)
	EventBus.game_paused.disconnect(counter)
	_check(emitted == 1, "同一原因重复持有只广播一次暂停状态（实际 %d）" % emitted)
	GameManager.clear_pauses()

	var config := ConfigFile.new()
	var loaded := config.load(GameSettings.SAVE_PATH) == OK
	_check(loaded and config.has_section("display"), "切后台会把设置落盘（含 display 节）")


func _touch(index: int, pressed: bool) -> InputEventScreenTouch:
	return _touch_at(index, pressed, _button.size * 0.5)


func _touch_at(index: int, pressed: bool, position: Vector2) -> InputEventScreenTouch:
	var event := InputEventScreenTouch.new()
	event.index = index
	event.pressed = pressed
	event.position = position
	return event


func _mouse(pressed: bool) -> InputEventMouseButton:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.position = Vector2.ZERO
	return event


func _on_pressed() -> void:
	_pressed_count += 1


func _on_requested() -> void:
	_requested_count += 1


func _reset_counts() -> void:
	_pressed_count = 0
	_requested_count = 0


func _cleanup() -> void:
	GameManager.set_paused(false)
	InputManager.touch_vector = Vector2.ZERO
	if EventBus.attack_pressed.is_connected(_on_pressed):
		EventBus.attack_pressed.disconnect(_on_pressed)
	if EventBus.attack_requested.is_connected(_on_requested):
		EventBus.attack_requested.disconnect(_on_requested)


func _check(condition: bool, message: String) -> void:
	if condition:
		print("[PASS] ", message)
	else:
		_failures.append(message)
		print("[FAIL] ", message)


func _report() -> void:
	print("---------- 触控契约验收 ----------")
	if _failures.is_empty():
		print("结果：全部通过")
		get_tree().quit(0)
	else:
		print("结果：%d 项失败" % _failures.size())
		get_tree().quit(1)
