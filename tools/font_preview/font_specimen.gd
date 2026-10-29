extends Control

## 字体标本：按项目真实视觉规格（字号角色 / 深色面板 / 描边 HUD / 调试等宽）并排对比候选字体。
## 只用于选型，不参与游戏运行。
##
## 用法：
##   godot --path <项目> res://tools/font_preview/font_specimen.tscn            交互对比
##   godot --path <项目> res://tools/font_preview/font_specimen.tscn -- --shots 逐款截图后退出
##
## 字体来源：user://fonts/*.ttf|*.otf（由同目录 fetch_fonts.ps1 下载），
## 外加项目内置的 Locale.BUNDLED_FONT 作为「现状基线」。
## 快捷键：1-9 切换 · F 切换系统中文回退 · F11 下一款 · F12 截图 · S 全部截图

const FONT_DIR := "user://fonts"
const SHOT_DIR := "user://font_specimen"
## 当前项目全局字体（跟随 Locale，避免换字后标本工具指向旧文件）。

const TEXT := Color(1.0, 1.0, 1.0, 0.92)
const TEXT_DIM := Color(1.0, 1.0, 1.0, 0.55)
const PANEL_BG := Color(0.10, 0.12, 0.16, 0.98)
const GROUP_BG := Color(0.07, 0.08, 0.10, 0.95)
const WORLD_BG := Color(0.18, 0.22, 0.18, 1.0)
const BTN_FILL := Color(0.16, 0.20, 0.26, 0.92)
const BTN_HI := Color(0.24, 0.40, 0.28, 0.95)
const BORDER := Color(1.0, 1.0, 1.0, 0.55)
const HP_RED := Color(0.839, 0.263, 0.263, 1.0)
const ROW_SEL := Color(0.24, 0.40, 0.28, 0.40)

## 候选元数据（文件主干小写 → 展示名 / 授权 / 定位）。
const CANDIDATES := {
	"smileysans-oblique": {
		"name": "得意黑 Smiley Sans", "license": "SIL OFL 1.1", "role": "标题 / 按钮"},
	"notosanssc-regular": {
		"name": "思源黑体 Noto Sans SC", "license": "SIL OFL 1.1", "role": "正文 / 设置面板"},
	"lxgwwenkailite-regular": {
		"name": "霞鹜文楷 LXGW WenKai", "license": "SIL OFL 1.1", "role": "叙事 / 提示"},
	"notoserifsc-semibold": {
		"name": "思源宋体 Noto Serif SC", "license": "SIL OFL 1.1", "role": "标题 / 氛围"},
	"notosansmonocjksc-regular": {
		"name": "思源等宽 Noto Sans Mono", "license": "SIL OFL 1.1", "role": "调试 / 数字"},
}

## 缺字检测样本：界面里真实出现过的汉字 + 常用符号。
const SAMPLE_CJK := "设置语言按键绑定玩家战斗显示画质视野界面缩放恢复默认保存关闭攻击交互采摘观察生命状态敌人坐标速度自动接近持续目标死亡复活森林狼石野猪洞穴蝙蝠勇者向上移动左右查看已交换当前显示器放不下该档位"
const SAMPLE_SYM := "0123456789×（）「」·｜%.,:-/"

var _entries: Array[Dictionary] = []
var _index := 0
var _face: Font = null
var _system: SystemFont = null
var _fallback_on := true
var _content: Control = null
var _zh: Dictionary = {}
var _en: Dictionary = {}


func _ready() -> void:
	get_window().title = "字体标本 / FONT SPECIMEN"
	_zh = _read_json("res://data/i18n/zh.json")
	_en = _read_json("res://data/i18n/en.json")
	var bg := ColorRect.new()
	bg.color = Color(0.05, 0.055, 0.07, 1.0)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	_scan()
	if _entries.is_empty():
		push_error("没有可用字体")
		return
	_select(0)
	if OS.get_cmdline_user_args().has("--shots"):
		_shots()


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed as Dictionary if typeof(parsed) == TYPE_DICTIONARY else {}


## 项目当前全局字体打头，其余按 user://fonts/ 里的文件名排序（同名文件去重）。
func _scan() -> void:
	_entries.clear()
	_entries.append(_entry_for(Locale.BUNDLED_FONT, "内置字体（现状）",
			"SIL OFL 1.1", "当前项目全局字体"))
	var dir := DirAccess.open(FONT_DIR)
	if dir == null:
		return
	var found: Array[Dictionary] = []
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while not file_name.is_empty():
		if not dir.current_is_dir() and file_name != Locale.BUNDLED_FONT.get_file():
			var lower := file_name.to_lower()
			if lower.ends_with(".ttf") or lower.ends_with(".otf"):
				found.append(_entry_for(FONT_DIR + "/" + file_name))
		file_name = dir.get_next()
	dir.list_dir_end()
	found.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return String(a["label"]) < String(b["label"]))
	_entries.append_array(found)


func _entry_for(path: String, forced_name := "", forced_license := "",
		forced_role := "") -> Dictionary:
	var file_name := path.get_file()
	var stem := file_name.get_basename().to_lower()
	var meta: Dictionary = CANDIDATES.get(stem, {})
	return {
		"path": path,
		"label": forced_name if not forced_name.is_empty()
				else String(meta.get("name", file_name.get_basename())),
		"license": forced_license if not forced_license.is_empty()
				else String(meta.get("license", "未登记 · 自行核对")),
		"role": forced_role if not forced_role.is_empty()
				else String(meta.get("role", "自定义字体")),
	}


func _system_face() -> SystemFont:
	if _system == null:
		_system = SystemFont.new()
		_system.font_names = PackedStringArray([
			"Microsoft YaHei UI", "Microsoft YaHei", "Noto Sans CJK SC",
			"Source Han Sans SC", "PingFang SC", "WenQuanYi Micro Hei", "sans-serif"])
	return _system


func _load_face(entry: Dictionary) -> Font:
	var file := FontFile.new()
	var err := file.load_dynamic_font(String(entry["path"]))
	if err != OK:
		push_warning("字体加载失败: %s" % entry["path"])
		entry["metrics"] = {}
		return _system_face()
	# 度量必须在挂回退之前算：挂上系统中文后 has_char/宽度都会被回退字体蒙混。
	# 关掉隐式系统回退：否则缺字宽度会被系统字体顶替，度量与「回退关」的画面都失真。
	file.allow_system_fallback = false
	entry["metrics"] = _measure(file)
	if _fallback_on:
		var fallbacks: Array[Font] = [_system_face()]
		file.fallbacks = fallbacks
	return file


## 单款字体的客观指标：字形覆盖 + 字宽 + 行高 + 数字等宽，用于横向比较。
func _measure(face: Font) -> Dictionary:
	var missing := 0
	var missing_preview := ""
	var sample := SAMPLE_CJK + SAMPLE_SYM
	for i in sample.length():
		var code := sample.unicode_at(i)
		if face.has_char(code):
			continue
		missing += 1
		if missing_preview.length() < 8:
			missing_preview += sample[i]
	var long_line := "主流桌面 / 独显，世界与界面都按 1:1 采样。"
	return {
		"missing": missing,
		"missing_preview": missing_preview if not missing_preview.is_empty() else "无",
		"cjk_width": _width(face, "国", 20) if face.has_char(0x56FD) else 0.0,
		"latin_x": _width(face, "x", 20),
		"latin_10": _width(face, "ABCDEFGHIJ", 20),
		"ascent": face.get_ascent(20),
		"descent": face.get_descent(20),
		"height": face.get_height(20),
		"long_width": _width(face, long_line, 20) if missing == 0 else 0.0,
		"tabular": is_equal_approx(_width(face, "0000000000", 20),
				_width(face, "1111111111", 20)),
		"font_name": face.get_font_name(),
		"style": face.get_font_style_name(),
	}


func _width(face: Font, text: String, font_size: int) -> float:
	return face.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x


func _select(index: int) -> void:
	if _entries.is_empty():
		return
	_index = clampi(index, 0, _entries.size() - 1)
	_face = _load_face(_entries[_index])
	print("FONT %d/%d %s | %s" % [_index + 1, _entries.size(),
			_entries[_index]["label"], _entries[_index].get("metrics", {})])
	_build()


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var key := event as InputEventKey
	if key.keycode >= KEY_1 and key.keycode <= KEY_9:
		_select(key.keycode - KEY_1)
	elif key.keycode == KEY_F:
		_fallback_on = not _fallback_on
		_select(_index)
	elif key.keycode == KEY_F11:
		_select((_index + 1) % _entries.size())
	elif key.keycode == KEY_F12:
		_save_current()
	elif key.keycode == KEY_S:
		_shots()
	elif key.keycode == KEY_ESCAPE:
		get_tree().quit()


# ---------------------------------------------------------------- 构建


func _build() -> void:
	if is_instance_valid(_content):
		remove_child(_content)
		_content.free()
	_content = Control.new()
	_content.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_content)
	_build_sidebar()
	_build_panel()
	_build_right()


func _build_sidebar() -> void:
	var origin := Vector2(16.0, 16.0)
	_label(_content, Rect2(origin, Vector2(284.0, 30.0)), "字体标本", 22)
	_label(_content, Rect2(origin + Vector2(0.0, 32.0), Vector2(284.0, 20.0)),
			"FONT SPECIMEN", 13, TEXT_DIM)
	_label(_content, Rect2(origin + Vector2(0.0, 54.0), Vector2(284.0, 36.0)),
			"1-9 切换  F 中文回退  F12 截图  S 全部", 12, TEXT_DIM, 0, true)

	var top := 108.0
	for i in mini(_entries.size(), 9):
		var entry: Dictionary = _entries[i]
		var selected := i == _index
		_box(_content, Rect2(Vector2(16.0, top + float(i) * 46.0), Vector2(284.0, 42.0)),
				ROW_SEL if selected else BTN_FILL, BORDER if selected else Color(0, 0, 0, 0), 2.0)
		_label(_content, Rect2(Vector2(24.0, top + float(i) * 46.0 + 2.0), Vector2(268.0, 22.0)),
				"%d  %s" % [i + 1, entry["label"]], 15)
		_label(_content, Rect2(Vector2(24.0, top + float(i) * 46.0 + 21.0), Vector2(268.0, 18.0)),
				"%s · %s" % [entry["license"], entry["role"]], 12, TEXT_DIM)

	var y := top + float(mini(_entries.size(), 9)) * 46.0 + 14.0
	var metrics := _metrics()
	var info := [
		"当前：%s %s" % [metrics.get("font_name", "?"), metrics.get("style", "")],
		"系统中文回退：%s（F 切换）" % ("开" if _fallback_on else "关"),
		"字号：30 / 22 / 20 / 17",
		"汉字宽 %s  拉丁「x」宽 %s" % [
			_num(metrics.get("cjk_width", 0.0)), _num(metrics.get("latin_x", 0.0))],
		"行高 %.1f（ascent %.1f + descent %.1f）" % [
			metrics.get("height", 0.0), metrics.get("ascent", 0.0),
			metrics.get("descent", 0.0)],
		"缺字 %d / %d：%s" % [metrics.get("missing", 0),
			SAMPLE_CJK.length() + SAMPLE_SYM.length(), metrics.get("missing_preview", "?")],
	]
	_label(_content, Rect2(Vector2(16.0, y), Vector2(284.0, 150.0)),
			"\n".join(info), 14, TEXT, 0, true)


func _build_panel() -> void:
	var pos := Vector2(316.0, 16.0)
	_box(_content, Rect2(pos, Vector2(540.0, 688.0)), PANEL_BG, Color(1, 1, 1, 0.18), 2.0)

	# 标题 / 语言（对应 settings_panel.gd 的 FONT_TITLE 30 / FONT_SECTION 22 / FONT_BODY 20）
	_label(_content, Rect2(pos + Vector2(24.0, 12.0), Vector2(492.0, 44.0)),
			"设置  SETTINGS", 30)
	_label(_content, Rect2(pos + Vector2(24.0, 62.0), Vector2(200.0, 34.0)),
			"语言  LANGUAGE", 22)
	_button(_content, Rect2(pos + Vector2(228.0, 58.0), Vector2(128.0, 38.0)), "EN", 20, true)
	_button(_content, Rect2(pos + Vector2(368.0, 58.0), Vector2(140.0, 38.0)), "中文", 20)

	_label(_content, Rect2(pos + Vector2(24.0, 106.0), Vector2(492.0, 34.0)),
			"按键绑定  KEY BINDINGS", 22)

	var actions := ["向上移动  MOVE UP", "向下移动  MOVE DOWN",
			"向左移动  MOVE LEFT", "向右移动  MOVE RIGHT", "攻击  ATTACK"]
	var keys := ["W", "S", "A", "D", "J"]
	for i in actions.size():
		var row_y := 146.0 + float(i) * 40.0
		_label(_content, Rect2(pos + Vector2(36.0, row_y), Vector2(300.0, 34.0)),
				actions[i], 20)
		_button(_content, Rect2(pos + Vector2(352.0, row_y - 2.0), Vector2(160.0, 34.0)),
				keys[i], 20)

	_label(_content, Rect2(pos + Vector2(24.0, 346.0), Vector2(492.0, 28.0)),
			"点击按键后按下新键即可修改。Press a new key to rebind.", 17, TEXT_DIM)

	_label(_content, Rect2(pos + Vector2(24.0, 382.0), Vector2(492.0, 34.0)),
			"显示  DISPLAY", 22)
	_button(_content, Rect2(pos + Vector2(24.0, 420.0), Vector2(246.0, 38.0)),
			"1280×720（16:9）", 20)
	_button(_content, Rect2(pos + Vector2(282.0, 420.0), Vector2(246.0, 38.0)),
			"1920×1080（16:9）", 20, true)
	_label(_content, Rect2(pos + Vector2(24.0, 466.0), Vector2(492.0, 62.0)),
			"主流桌面 / 独显，世界与界面都按 1:1 采样。Mainstream desktop; world and UI sampled 1:1.",
			17, Color(0.80, 0.88, 1.0, 1.0), 0, true)

	_label(_content, Rect2(pos + Vector2(24.0, 534.0), Vector2(492.0, 34.0)),
			"画质档  QUALITY", 22)
	_button(_content, Rect2(pos + Vector2(24.0, 572.0), Vector2(156.0, 38.0)), "流畅  LOW", 20)
	_button(_content, Rect2(pos + Vector2(192.0, 572.0), Vector2(156.0, 38.0)), "均衡  MED", 20, true)
	_button(_content, Rect2(pos + Vector2(360.0, 572.0), Vector2(156.0, 38.0)), "高清  HIGH", 20)
	_label(_content, Rect2(pos + Vector2(24.0, 626.0), Vector2(492.0, 34.0)),
			"界面缩放  1.0 倍", 20)


func _build_right() -> void:
	var x := 872.0

	# 1) HUD 实况：白字 92% + 4px 黑描边（hud.gd 的实际参数）
	var hud_pos := Vector2(x, 16.0)
	_box(_content, Rect2(hud_pos, Vector2(392.0, 236.0)), WORLD_BG)
	_label(_content, Rect2(hud_pos + Vector2(20.0, 10.0), Vector2(200.0, 22.0)),
			"HUD 实况", 14, TEXT_DIM)
	_label(_content, Rect2(hud_pos + Vector2(20.0, 38.0), Vector2(300.0, 30.0)),
			"生命 92/120  HP 92/120", 20, TEXT, 4)
	_box(_content, Rect2(hud_pos + Vector2(20.0, 74.0), Vector2(252.0, 22.0)),
			Color(0.0, 0.0, 0.0, 0.45))
	_box(_content, Rect2(hud_pos + Vector2(22.0, 76.0), Vector2(200.0, 18.0)), HP_RED)
	_label(_content, Rect2(hud_pos + Vector2(20.0, 106.0), Vector2(352.0, 52.0)),
			"移动 WASD   点击选中目标   ATTACK J", 16, Color(1, 1, 1, 0.55), 4, true)
	_circle(_content, Rect2(hud_pos + Vector2(268.0, 148.0), Vector2(88.0, 88.0)),
			"攻击  J", 18, Color(0.15, 0.15, 0.18, 0.45))

	# 2) 调试信息：等宽 / 数字对齐
	var dbg_pos := Vector2(x, 264.0)
	_box(_content, Rect2(dbg_pos, Vector2(392.0, 184.0)), GROUP_BG)
	_label(_content, Rect2(dbg_pos + Vector2(16.0, 10.0), Vector2(360.0, 22.0)),
			"调试信息（数字对齐）", 14, TEXT_DIM)
	var debug_text := "\n".join([
		"帧率 60  FPS 60",
		"状态 运行中  RUNNING",
		"敌人 3  ENEMIES 3",
		"选中 森林狼  TARGET FOREST WOLF",
		"世界 1234.5, 678.9  坐标 12, 7",
		"速度 148.3   自动接近 开   持续攻击 关",
	])
	_label(_content, Rect2(dbg_pos + Vector2(16.0, 36.0), Vector2(360.0, 138.0)),
			debug_text, 16)

	# 3) 度量：选型时最容易被忽略的一栏
	var met_pos := Vector2(x, 460.0)
	_box(_content, Rect2(met_pos, Vector2(392.0, 244.0)), GROUP_BG)
	_label(_content, Rect2(met_pos + Vector2(16.0, 10.0), Vector2(360.0, 22.0)),
			"度量 / 覆盖", 14, TEXT_DIM)
	var m := _metrics()
	var metrics := [
		"字体 %s / %s" % [m.get("font_name", "?"), m.get("style", "")],
		"授权 %s  定位 %s" % [_entries[_index]["license"], _entries[_index]["role"]],
		"@20px  ascent %.1f + descent %.1f = %.1f" % [
			m.get("ascent", 0.0), m.get("descent", 0.0), m.get("height", 0.0)],
		"@20px  汉字 %s  拉丁 x %s  10 字宽 %s" % [
			_num(m.get("cjk_width", 0.0)), _num(m.get("latin_x", 0.0)),
			_num(m.get("latin_10", 0.0))],
		"数字等宽：%s" % ("是" if m.get("tabular", false) else "否（比例数字）"),
		"长句宽 %s / 可用 492（正文 20px）" % _num(m.get("long_width", 0.0)),
		"缺字 %d 个：%s" % [m.get("missing", 0), m.get("missing_preview", "?")],
	]
	_label(_content, Rect2(met_pos + Vector2(16.0, 36.0), Vector2(360.0, 200.0)),
			"\n".join(metrics), 14, TEXT, 0, true)


# ---------------------------------------------------------------- 绘制辅助


func _label(parent: Control, rect: Rect2, text: String, font_size: int,
		color := TEXT, outline := 0, wrap := false) -> Label:
	var label := Label.new()
	# 顺序要紧：先开自动换行，再设字体与尺寸，否则 Control 会按整行宽度抬高最小尺寸，
	# 后面的 size 赋值就变成「比最小尺寸还小」，换行永远不生效。
	if wrap:
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.text = text
	label.add_theme_font_override("font", _face)
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	if outline > 0:
		label.add_theme_constant_override("outline_size", outline)
		label.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.85))
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(label)
	label.position = rect.position
	label.size = rect.size
	return label


func _button(parent: Control, rect: Rect2, caption: String, font_size: int,
		highlight := false) -> void:
	var button := SpecButton.new()
	button.face = _face
	button.caption = caption
	button.font_size = font_size
	button.highlight = highlight
	button.position = rect.position
	button.size = rect.size
	parent.add_child(button)


func _box(parent: Control, rect: Rect2, fill: Color,
		border := Color(0, 0, 0, 0), width := 0.0) -> void:
	var box := SpecBox.new()
	box.fill = fill
	box.border = border
	box.line_width = width
	box.position = rect.position
	box.size = rect.size
	parent.add_child(box)


func _circle(parent: Control, rect: Rect2, caption: String, font_size: int,
		fill: Color) -> void:
	var circle := SpecCircle.new()
	circle.face = _face
	circle.caption = caption
	circle.font_size = font_size
	circle.fill = fill
	circle.position = rect.position
	circle.size = rect.size
	parent.add_child(circle)


func _metrics() -> Dictionary:
	if _entries.is_empty():
		return {}
	return _entries[_index].get("metrics", {})


## 0 表示该字形本字体没有（宽度无意义），显示破折号而不是误导性的数字。
func _num(value: float) -> String:
	return "—" if value <= 0.0 else "%.1f" % value


# ---------------------------------------------------------------- 截图


func _shots() -> void:
	# 固定窗口尺寸，保证每款字体的截图可以直接叠图对比。
	get_window().size = Vector2i(1280, 720)
	for frame in 3:
		await get_tree().process_frame
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SHOT_DIR))
	for i in _entries.size():
		_select(i)
		for frame in 3:
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var path := "%s/%02d_%s.png" % [SHOT_DIR, i + 1, _slug(String(_entries[i]["label"]))]
		var err := get_viewport().get_texture().get_image().save_png(path)
		print("SHOT %s err=%d" % [ProjectSettings.globalize_path(path), err])
	get_tree().quit()


func _save_current() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SHOT_DIR))
	await RenderingServer.frame_post_draw
	var path := "%s/%02d_%s.png" % [SHOT_DIR, _index + 1, _slug(String(_entries[_index]["label"]))]
	var err := get_viewport().get_texture().get_image().save_png(path)
	print("SHOT %s err=%d" % [ProjectSettings.globalize_path(path), err])


func _slug(text: String) -> String:
	var out := ""
	for i in text.length():
		var c := text[i]
		var keep := (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") \
				or (c >= "0" and c <= "9")
		out += c if keep else "_"
	return out


# ---------------------------------------------------------------- 内联控件


class SpecBox extends Control:
	var fill := Color.WHITE
	var border := Color(0, 0, 0, 0)
	var line_width := 0.0

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), fill, true)
		if line_width > 0.0:
			draw_rect(Rect2(Vector2.ZERO, size), border, false, line_width)


class SpecButton extends Control:
	var face: Font = null
	var caption := ""
	var font_size := 20
	var highlight := false
	var fill := Color(0.16, 0.20, 0.26, 0.92)
	var fill_highlight := Color(0.24, 0.40, 0.28, 0.95)
	var border := Color(1.0, 1.0, 1.0, 0.55)

	func _draw() -> void:
		var rect := Rect2(Vector2.ZERO, size)
		draw_rect(rect, fill_highlight if highlight else fill, true)
		draw_rect(rect, border, false, 2.0)
		if face == null:
			return
		var text_size := face.get_string_size(caption, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
		var pos := Vector2((size.x - text_size.x) * 0.5, (size.y + text_size.y * 0.55) * 0.5)
		draw_string(face, pos, caption, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size,
				Color(1.0, 1.0, 1.0, 0.95))


class SpecCircle extends Control:
	var face: Font = null
	var caption := ""
	var font_size := 18
	var fill := Color(0.15, 0.15, 0.18, 0.45)

	func _draw() -> void:
		var center := size * 0.5
		var radius := minf(size.x, size.y) * 0.5
		draw_circle(center, radius, fill)
		draw_arc(center, radius, 0.0, TAU, 40, Color(1.0, 1.0, 1.0, 0.55), 2.5, true)
		if face == null:
			return
		var text_size := face.get_string_size(caption, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
		draw_string(face, center + Vector2(-text_size.x * 0.5, font_size * 0.35), caption,
				HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color(1.0, 1.0, 1.0, 0.9))
