extends Node

## 字体可读性验收（方案 §7.9）：
## 1. 设置面板在多种设备口径下，正文 ≥14dp、辅助说明 ≥12dp、区块标题 ≥15dp、总标题 ≥20dp；
## 2. 字号层级严格递减：标题 > 区块 > 正文 > 辅助；
## 3. 面板缩放后的整体矩形落在安全区内，且内容高于滚动视口（可滚动，不挤压字号）；
## 4. HUD 的正文/辅助说明同样达到 dp 下限，且标签盒高度装得下字号。
## 运行：godot --headless --path <项目> res://tests/settings_readability_check.tscn

const PANEL_SCENE := preload("res://scenes/ui/settings_panel.tscn")
const HUD_SCENE := preload("res://scenes/ui/hud.tscn")

## 正文/辅助/区块/标题的 dp 下限。
const MIN_BODY_DP := 14.0
const MIN_HELPER_DP := 12.0
const MIN_SECTION_DP := 15.0
const MIN_TITLE_DP := 20.0

## 设备口径：逻辑视口 / dpi / content_scale / 安全区内缩。
const CASES := [
	{
		"name": "手机 1563x720（真机 2510x1156@480dpi）",
		"logical": Vector2(1563, 720), "dpi": 418.9, "content_scale": 1.606,
		"insets": Vector4(89.67, 59.78, 59.78, 59.78),
	},
	{
		"name": "手机 1280x720（1280x720@294dpi）",
		"logical": Vector2(1280, 720), "dpi": 294.0, "content_scale": 1.0,
		"insets": Vector4(32, 32, 32, 32),
	},
	{
		"name": "4:3 平板 1280x960（2048x1536@264dpi）",
		"logical": Vector2(1280, 960), "dpi": 264.0, "content_scale": 1.6,
		"insets": Vector4(32, 32, 32, 32),
	},
	{
		"name": "桌面 1280x720",
		"logical": Vector2(1280, 720), "dpi": 96.0, "content_scale": 1.0,
		"insets": Vector4(19.2, 19.2, 19.2, 19.2),
	},
	{
		"name": "桌面 21:9 1707x720",
		"logical": Vector2(1707, 720), "dpi": 110.0, "content_scale": 1.5,
		"insets": Vector4(19.2, 19.2, 19.2, 19.2),
	},
]

var _failures: Array[String] = []
var _saved_dpi := 96.0
var _saved_content_scale := 1.0
var _saved_insets := Vector4.ZERO


func _ready() -> void:
	_saved_dpi = DisplayAdapter.dpi
	_saved_content_scale = DisplayAdapter.content_scale
	_saved_insets = DisplayAdapter.safe_insets

	for entry: Dictionary in CASES:
		await _check_case(entry)

	_restore()
	_report()


func _check_case(entry: Dictionary) -> void:
	DisplayAdapter.dpi = float(entry["dpi"])
	DisplayAdapter.content_scale = float(entry["content_scale"])
	DisplayAdapter.safe_insets = entry["insets"]

	var logical: Vector2 = entry["logical"]
	var insets: Vector4 = entry["insets"]
	var scale_physical := float(entry["content_scale"]) / (float(entry["dpi"]) / 160.0)

	var sub := SubViewport.new()
	sub.size = Vector2i(logical)
	sub.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(sub)

	var panel := PANEL_SCENE.instantiate()
	sub.add_child(panel)
	await get_tree().process_frame

	var k: float = panel._panel.scale.x
	var title_dp := float(panel.FONT_TITLE) * k * scale_physical
	var section_dp := float(panel.FONT_SECTION) * k * scale_physical
	var body_dp := float(panel.FONT_BODY) * k * scale_physical
	var helper_dp := float(panel.FONT_HELPER) * k * scale_physical

	_check(body_dp >= MIN_BODY_DP,
		"%s：正文 %.1fdp ≥ %.0fdp（面板缩放 %.2f）" % [entry["name"], body_dp, MIN_BODY_DP, k])
	_check(helper_dp >= MIN_HELPER_DP,
		"%s：辅助说明 %.1fdp ≥ %.0fdp" % [entry["name"], helper_dp, MIN_HELPER_DP])
	_check(section_dp >= MIN_SECTION_DP,
		"%s：区块标题 %.1fdp ≥ %.0fdp" % [entry["name"], section_dp, MIN_SECTION_DP])
	_check(title_dp >= MIN_TITLE_DP,
		"%s：总标题 %.1fdp ≥ %.0fdp" % [entry["name"], title_dp, MIN_TITLE_DP])

	_check(title_dp > section_dp and section_dp > body_dp and body_dp > helper_dp,
		"%s：字号层级递减 %.1f > %.1f > %.1f > %.1f" % [
			entry["name"], title_dp, section_dp, body_dp, helper_dp])

	# 面板整体（含缩放）必须落在安全区内。
	var safe := Rect2(Vector2(insets.x, insets.y),
		Vector2(logical.x - insets.x - insets.z, logical.y - insets.y - insets.w))
	var panel_rect := Rect2(panel._panel.position, panel._panel.size * k)
	_check(safe.encloses(panel_rect),
		"%s：面板 %s 在安全区 %s 内" % [entry["name"], str(panel_rect), str(safe)])

	# 内容高于滚动视口 → 靠滚动而不是压缩字号。
	var scroll: ScrollContainer = panel._scroll
	var body_height: float = (scroll.get_child(0) as Control).size.y
	_check(body_height > scroll.size.y,
		"%s：滚动内容 %.0f > 视口 %.0f" % [entry["name"], body_height, scroll.size.y])

	# 实际标签字号与角色常量一致（防止漏改硬编码）。
	var min_font := 99999
	var max_font := 0
	for node: Node in panel.find_children("*", "Label", true, false):
		var fs := (node as Label).get_theme_font_size("font_size")
		min_font = mini(min_font, fs)
		max_font = maxi(max_font, fs)
	_check(min_font == panel.FONT_HELPER and max_font == panel.FONT_TITLE,
		"%s：标签字号落在角色表内（最小 %d，最大 %d）" % [entry["name"], min_font, max_font])

	# 放大字号后不能出现空文本行（曾经战斗阈值行只剩 -/+ 按钮）。
	var blank := 0
	for key: String in GameSettings.COMBAT_KEYS:
		if String(panel._combat_labels[key].text).is_empty() or String(
				panel._combat_values[key].text).is_empty():
			blank += 1
	_check(blank == 0, "%s：战斗阈值行的标签与数值均非空（空行 %d）" % [entry["name"], blank])

	await _check_hud(sub, entry, scale_physical)

	panel._close()
	await get_tree().process_frame
	sub.queue_free()
	await get_tree().process_frame


func _check_hud(sub: SubViewport, entry: Dictionary, scale_physical: float) -> void:
	var hud := HUD_SCENE.instantiate()
	sub.add_child(hud)
	await get_tree().process_frame

	var hp := hud.get_node("HpLabel") as Label
	var hint := hud.get_node("HintLabel") as Label
	var hp_dp := float(hp.get_theme_font_size("font_size")) * scale_physical
	var hint_dp := float(hint.get_theme_font_size("font_size")) * scale_physical
	_check(hp_dp >= MIN_BODY_DP, "%s：HUD 血条文字 %.1fdp ≥ %.0fdp" % [entry["name"], hp_dp, MIN_BODY_DP])
	_check(hint_dp >= MIN_HELPER_DP,
		"%s：HUD 提示文字 %.1fdp ≥ %.0fdp" % [entry["name"], hint_dp, MIN_HELPER_DP])

	# 盒高要装得下字号（否则 Label 会被最小尺寸撑出边界、压到别的元素）。
	_check(hint.size.y >= float(hint.get_theme_font_size("font_size")) * 1.15,
		"%s：提示文字盒高 %.0f 装得下 %.0f 号字" % [
			entry["name"], hint.size.y, hint.get_theme_font_size("font_size")])
	_check(hp.size.y >= float(hp.get_theme_font_size("font_size")) * 1.15,
		"%s：血条文字盒高 %.0f 装得下 %.0f 号字" % [
			entry["name"], hp.size.y, hp.get_theme_font_size("font_size")])

	hud.queue_free()
	await get_tree().process_frame


func _restore() -> void:
	DisplayAdapter.dpi = _saved_dpi
	DisplayAdapter.content_scale = _saved_content_scale
	DisplayAdapter.safe_insets = _saved_insets
	GameManager.clear_pauses()


func _check(condition: bool, message: String) -> void:
	if condition:
		print("[PASS] ", message)
	else:
		_failures.append(message)
		print("[FAIL] ", message)


func _report() -> void:
	print("---------- 字体可读性验收 ----------")
	if _failures.is_empty():
		print("结果：全部通过")
		get_tree().quit(0)
	else:
		print("结果：%d 项失败" % _failures.size())
		get_tree().quit(1)
