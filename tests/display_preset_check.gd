extends Node

## 分辨率档位与显示设置验收（《移动端多分辨率适配方案》§7）：
## 1. 档位表结构合法（id 唯一、尺寸不与「自动」冲突）；
## 2. 每个档位的渲染分辨率 / zoom / 可见格数与方案表一致；
## 3. 放不下的档位会被判定为不可用，并回退到能容纳的最大档；
## 4. 「自动」档按显示器可用区取，不会产出任意宽高比；
## 5. 设置值的非法输入会被吸附到合法枚举，并可持久化；
## 6. 调试构建放开自由缩放（不加最小尺寸、不锁窗口）。
## 运行：godot --headless --path <项目> res://tests/display_preset_check.tscn

const PANEL_SCENE := preload("res://scenes/ui/settings_panel.tscn")

## 期望值（方案 §7 档位表），tiles 全部应等于 900。
const EXPECTED := {
	"720p": {"size": Vector2i(1280, 720), "render": Vector2(1280, 720), "zoom": 1.000},
	"900p": {"size": Vector2i(1600, 900), "render": Vector2(1600, 900), "zoom": 1.250},
	"1080p": {"size": Vector2i(1920, 1080), "render": Vector2(1920, 1080), "zoom": 1.500},
	"1440p": {"size": Vector2i(2560, 1440), "render": Vector2(1920, 1080), "zoom": 1.500},
	"wuxga": {"size": Vector2i(1920, 1200), "render": Vector2(1728, 1080), "zoom": 1.423},
	"vga4x3": {"size": Vector2i(1280, 960), "render": Vector2(1280, 960), "zoom": 1.155},
	"uw21x9": {"size": Vector2i(2560, 1080), "render": Vector2(1920, 810), "zoom": 1.299},
}

var _failures: Array[String] = []
var _saved_display: Dictionary = {}


func _ready() -> void:
	_saved_display = GameSettings.display.duplicate()
	_test_preset_table()
	_test_preset_math()
	_test_fit_and_fallback()
	_test_view_scale()
	_test_settings_validation()
	_test_free_resize()
	await _test_panel_display_section()
	_restore_settings()
	_report()


func _test_preset_table() -> void:
	var ids := DisplayAdapter.preset_ids()
	_check(ids.size() == EXPECTED.size() + 1, "档位数量 = %d（含自动）" % ids.size())
	_check(ids[0] == DisplayAdapter.PRESET_AUTO, "第一项是「自动」档")
	for id: String in ids:
		_check(ids.count(id) == 1, "%s 在档位表中唯一" % id)
		if id == DisplayAdapter.PRESET_AUTO:
			continue
		var size := DisplayAdapter.preset_size(id)
		_check(size.x > 0 and size.y > 0, "%s 有合法窗口尺寸 %s" % [id, str(size)])
		_check(DisplayAdapter.is_known_preset(id), "%s 被 is_known_preset 识别" % id)
		var expected: Dictionary = EXPECTED[id]
		_check(size == expected["size"], "%s 窗口尺寸 = %s（实际 %s）" % [
			id, str(expected["size"]), str(size)])


## 档位数学：渲染分辨率、zoom、可见格数、宽高比保持。
func _test_preset_math() -> void:
	for id: String in EXPECTED:
		var expected: Dictionary = EXPECTED[id]
		var size: Vector2 = Vector2(expected["size"])
		var render := DisplayAdapter.render_size_for(size, 1.0)
		var zoom := DisplayAdapter.zoom_for(render)
		var tiles := DisplayAdapter.visible_tiles(render)
		_check(render.distance_to(expected["render"]) <= 1.0,
			"%s 高档渲染分辨率 = %s（实际 %s）" % [id, str(expected["render"]), str(render)])
		_check(absf(zoom - float(expected["zoom"])) <= 0.002,
			"%s zoom = %.3f（期望 %.3f）" % [id, zoom, float(expected["zoom"])])
		_check(absf(tiles - DisplayAdapter.BASE_TILES) / DisplayAdapter.BASE_TILES <= 0.01,
			"%s 可见格数 %.1f（标准视野恒 900）" % [id, tiles])
		var aspect_error := absf(render.x / render.y - size.x / size.y) / (size.x / size.y)
		_check(aspect_error <= 0.005, "%s 渲染宽高比保持（误差 %.3f%%）" % [id, aspect_error * 100.0])


## 可用性判定与回退：小屏不给大档，放不下的请求回退到能容纳的最大档。
func _test_fit_and_fallback() -> void:
	var laptop := Vector2(1366, 768)
	_check(DisplayAdapter.preset_fits("720p", laptop), "1366×768 屏：720p 可用")
	_check(not DisplayAdapter.preset_fits("1080p", laptop), "1366×768 屏：1080p 置灰")
	_check(DisplayAdapter.largest_fitting_preset(laptop) == "720p",
		"1366×768 屏最大可容纳档 = 720p（实际 %s）" % DisplayAdapter.largest_fitting_preset(laptop))

	var desktop := Vector2(1920, 1080)
	_check(DisplayAdapter.preset_fits("1080p", desktop), "1920×1080 屏：1080p 可用")
	_check(not DisplayAdapter.preset_fits("1440p", desktop), "1920×1080 屏：1440p 置灰")
	_check(DisplayAdapter.largest_fitting_preset(desktop) == "1080p",
		"1920×1080 屏最大可容纳档 = 1080p（实际 %s）" % DisplayAdapter.largest_fitting_preset(desktop))

	var big := Vector2(2560, 1440)
	_check(DisplayAdapter.largest_fitting_preset(big) == "1440p",
		"2560×1440 屏最大可容纳档 = 1440p（实际 %s）" % DisplayAdapter.largest_fitting_preset(big))

	# 放不下的档位请求回退到最大可容纳档，而不是硬塞导致出屏。
	_check(DisplayAdapter.resolve_window_size("1440p", laptop) == Vector2i(1280, 720),
		"1366×768 屏请求 1440p 回退到 720p（实际 %s）" % str(
			DisplayAdapter.resolve_window_size("1440p", laptop)))

	# 「自动」只从档位表里选，不会产出任意宽高比。
	var auto_size := DisplayAdapter.resolve_window_size(DisplayAdapter.PRESET_AUTO,
		Vector2(1920, 1040))
	_check(auto_size == Vector2i(1600, 900),
		"1920×1040 可用区自动档 = 1600×900（实际 %s）" % str(auto_size))
	_check(DisplayAdapter.preset_ids().has(_preset_of_size(auto_size)),
		"自动档结果仍是档位表中的尺寸")


func _preset_of_size(size: Vector2i) -> String:
	for id: String in DisplayAdapter.preset_ids():
		if DisplayAdapter.preset_size(id) == size:
			return id
	return ""


## 视野档：紧凑 / 标准 / 开阔，只改可见格数，不改渲染分辨率。
func _test_view_scale() -> void:
	var render := DisplayAdapter.render_size_for(Vector2(1920, 1080), 1.0)
	for key: String in DisplayAdapter.VIEW_SCALES:
		var scale := float(DisplayAdapter.VIEW_SCALES[key])
		var tiles := DisplayAdapter.visible_tiles(render, scale)
		var expected := DisplayAdapter.BASE_TILES * scale
		_check(absf(tiles - expected) / expected <= 0.01,
			"视野档 %s：可见 %.0f 格（期望 %.0f）" % [key, tiles, expected])
	var zoom_standard := DisplayAdapter.zoom_for(render, 1.0)
	var zoom_wide := DisplayAdapter.zoom_for(render, 1.25)
	_check(zoom_wide < zoom_standard, "开阔档 zoom 更小（%.3f < %.3f）" % [zoom_wide, zoom_standard])


## 设置值校验：非法输入吸附到最近合法枚举，并可落盘往返。
func _test_settings_validation() -> void:
	GameSettings.set_display_value("ui_scale", 0.99)
	_check(is_equal_approx(GameSettings.display_ui_scale(), 1.0),
		"ui_scale 0.99 吸附到 1.0（实际 %.2f）" % GameSettings.display_ui_scale())
	GameSettings.set_display_value("ui_scale", 9.0)
	_check(is_equal_approx(GameSettings.display_ui_scale(), 1.3),
		"ui_scale 越界吸附到 1.3（实际 %.2f）" % GameSettings.display_ui_scale())

	GameSettings.set_display_value("quality_tier", "ultra")
	_check(GameSettings.display_quality() == "auto",
		"未知画质档回落到 auto（实际 %s）" % GameSettings.display_quality())

	GameSettings.set_display_value("view_area_scale", 5.0)
	_check(is_equal_approx(GameSettings.display_view_scale(), 1.25),
		"视野倍率越界吸附到 1.25（实际 %.2f）" % GameSettings.display_view_scale())

	GameSettings.set_display_value("resolution_preset", "")
	_check(GameSettings.display_preset() == DisplayAdapter.PRESET_AUTO,
		"空档位回落到 auto（实际 %s）" % GameSettings.display_preset())

	GameSettings.set_display_value("quality_tier", "low")
	GameSettings.set_display_value("ui_scale", 1.1)
	GameSettings.save_to_disk()
	GameSettings.display.clear()
	GameSettings.load_from_disk()
	_check(GameSettings.display_quality() == "low",
		"画质档落盘往返（实际 %s）" % GameSettings.display_quality())
	_check(is_equal_approx(GameSettings.display_ui_scale(), 1.1),
		"界面缩放落盘往返（实际 %.2f）" % GameSettings.display_ui_scale())


## 调试构建：自由缩放，不加最小尺寸、不锁窗口。
func _test_free_resize() -> void:
	_check(DisplayAdapter.free_resize == OS.is_debug_build(),
		"free_resize 跟随调试构建（%s）" % str(DisplayAdapter.free_resize))
	if DisplayAdapter.free_resize:
		_check(not get_window().unresizable, "调试构建下窗口未被锁定")
		_check(get_window().min_size.x < DisplayAdapter.MIN_WINDOW_SIZE.x,
			"调试构建下未施加最小尺寸（%s）" % str(get_window().min_size))


## 面板：显示区块存在、档位/画质/视野按钮齐全，可滚动内容高度超过可视区。
func _test_panel_display_section() -> void:
	var panel := PANEL_SCENE.instantiate()
	add_child(panel)
	await get_tree().process_frame

	var texts := ""
	for label: Node in panel.find_children("*", "Label", true, false):
		texts += String((label as Label).text) + "\n"
	_check(texts.contains(Locale.t("display.title")), "设置面板含「显示」区块")

	var scroll := _first_scroll(panel)
	_check(scroll != null, "设置面板内容区使用 ScrollContainer")
	if scroll != null:
		var body: Node = scroll.get_child(0)
		_check(body is Control and (body as Control).size.y > scroll.size.y,
			"滚动内容高于可视区（内容 %.0f > 可视 %.0f）" % [
				(body as Control).size.y if body is Control else 0.0, scroll.size.y])

	var buttons := 0
	for node: Node in panel.find_children("*", "Control", true, false):
		if node is UiButton:
			buttons += 1
	_check(buttons > DisplayAdapter.preset_ids().size(), "面板按钮含 %d 个档位 + 其余操作（共 %d）" % [
		DisplayAdapter.preset_ids().size(), buttons])

	panel._close()
	await get_tree().process_frame
	await get_tree().process_frame


func _first_scroll(root: Node) -> ScrollContainer:
	for node: Node in root.find_children("*", "ScrollContainer", true, false):
		return node as ScrollContainer
	return null


func _restore_settings() -> void:
	GameSettings.display = _saved_display.duplicate()
	GameSettings.save_to_disk()


func _check(condition: bool, message: String) -> void:
	if condition:
		print("[PASS] ", message)
	else:
		_failures.append(message)
		print("[FAIL] ", message)


func _report() -> void:
	print("---------- 分辨率档位 / 显示设置验收 ----------")
	if _failures.is_empty():
		print("结果：全部通过")
		get_tree().quit(0)
	else:
		print("结果：%d 项失败" % _failures.size())
		get_tree().quit(1)
