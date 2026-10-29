extends Node

## 多分辨率适配验收（《移动端多分辨率适配方案》§1.2 / §5.4）：
## 1. 可见格数恒定：任何屏幕、任何画质档都落在 900 格 ±1%；
## 2. 世界层逻辑渲染分辨率保持屏幕宽高比（不被按轴 clamp 拉扁）；
## 3. 渲染分辨率落在 [960×540, 1920×1080] 等比区间；
## 4. 1:1 条件与 PC 大屏档取值；
## 5. HUD 在安全区矩形内不越界（四种宽高比）。
## 运行：godot --headless --path <项目> res://tests/mobile_layout_check.tscn

const HUD_SCENE := preload("res://scenes/ui/hud.tscn")
const MAIN_SCENE := preload("res://scenes/boot/main.tscn")

## §5.4 设备矩阵，单位是屏幕物理像素。
const SCREENS := [
	{"name": "16:9 中端", "size": Vector2(1920, 1080)},
	{"name": "19.5:9 刘海", "size": Vector2(2340, 1080)},
	{"name": "20:9 宽屏", "size": Vector2(2400, 1080)},
	{"name": "4:3 平板", "size": Vector2(2048, 1536)},
	{"name": "折叠屏展开", "size": Vector2(2208, 1768)},
	{"name": "PC 1440p", "size": Vector2(2560, 1440)},
]

## HUD 锚点契约：贴边的元素必须锚在对应边上（§3.5 硬性要求：不得用相对左上角的绝对坐标）。
const ANCHOR_CONTRACT := {
	"Joystick": {"bottom": 1.0},
	"AttackButton": {"right": 1.0, "bottom": 1.0},
	"SettingsButton": {"right": 1.0},
	"HpBack": {"bottom": 1.0},
	"HpFill": {"bottom": 1.0},
	"HpLabel": {"bottom": 1.0},
	"HintLabel": {"bottom": 1.0, "hcenter": 0.5},
}

## HUD 布局验收用例：逻辑视口尺寸 + 安全区内缩（模拟刘海/手势条/4:3）。
const HUD_CASES := [
	{"name": "1280x720 基准", "size": Vector2(1280, 720), "insets": Vector4(20, 12, 36, 24)},
	{"name": "1600x720 20:9", "size": Vector2(1600, 720), "insets": Vector4(0, 0, 80, 40)},
	{"name": "1280x960 4:3", "size": Vector2(1280, 960), "insets": Vector4(32, 32, 32, 32)},
	{"name": "2340x1080 刘海归一", "size": Vector2(1560, 720), "insets": Vector4(64, 8, 0, 20)},
]

var _failures: Array[String] = []


func _ready() -> void:
	_test_visible_tiles_invariant()
	_test_aspect_preserved()
	_test_render_size_bounds()
	_test_one_to_one_fast_path()
	_test_anchor_contract()
	await _test_hud_safe_layout()
	await _test_ui_scale_layout()
	await _test_debug_label_gate()
	await _test_world_view_wiring()
	_report()


## 可见格数恒定：这是本方案唯一承诺的视野口径。
func _test_visible_tiles_invariant() -> void:
	for entry: Dictionary in SCREENS:
		var screen: Vector2 = entry["size"]
		for tier: String in DisplayAdapter.RENDER_SCALE_TIERS:
			var render := DisplayAdapter.render_size_for(
				screen, float(DisplayAdapter.RENDER_SCALE_TIERS[tier]))
			var tiles := DisplayAdapter.visible_tiles(render)
			var deviation := absf(tiles - DisplayAdapter.BASE_TILES) / DisplayAdapter.BASE_TILES
			_check(deviation <= 0.01,
				"%s / %s：可见格数 %.1f（偏差 %.2f%%）" % [entry["name"], tier, tiles, deviation * 100.0])


## 渲染分辨率必须与屏幕同宽高比，否则世界会被拉伸。
func _test_aspect_preserved() -> void:
	for entry: Dictionary in SCREENS:
		var screen: Vector2 = entry["size"]
		var render := DisplayAdapter.render_size_for(screen, 0.7)
		var expected := screen.x / screen.y
		var actual := render.x / render.y
		_check(absf(actual - expected) / expected <= 0.005,
			"%s：宽高比 %.3f vs 屏幕 %.3f" % [entry["name"], actual, expected])


func _test_render_size_bounds() -> void:
	var min_size := DisplayAdapter.MIN_RENDER_SIZE
	var max_size := DisplayAdapter.MAX_RENDER_SIZE
	for entry: Dictionary in SCREENS:
		var screen: Vector2 = entry["size"]
		for tier: String in DisplayAdapter.RENDER_SCALE_TIERS:
			var render := DisplayAdapter.render_size_for(
				screen, float(DisplayAdapter.RENDER_SCALE_TIERS[tier]))
			var inside := render.x >= min_size.x - 1.0 and render.y >= min_size.y - 1.0 \
				and render.x <= max_size.x + 1.0 and render.y <= max_size.y + 1.0
			_check(inside, "%s / %s：渲染分辨率 %s 在 [%s, %s] 内" % [
				entry["name"], tier, str(render), str(min_size), str(max_size)])


## 1:1 只在「屏幕像素 ÷ 渲染分辨率 = 整数」时成立；同时校验 PC 大屏档的 zoom 取值。
func _test_one_to_one_fast_path() -> void:
	var render_720 := DisplayAdapter.render_size_for(Vector2(1280, 720), 1.0)
	_check(render_720 == Vector2(1280, 720), "1280×720 高档：渲染分辨率与屏幕相同（1:1，%s）" % str(render_720))
	_check(is_equal_approx(DisplayAdapter.zoom_for(render_720), 1.0),
		"1280×720 高档：zoom = %.3f（现状 PC 手感保持）" % DisplayAdapter.zoom_for(render_720))

	var render_1080 := DisplayAdapter.render_size_for(Vector2(1920, 1080), 1.0)
	var zoom_1080 := DisplayAdapter.zoom_for(render_1080)
	_check(render_1080 == Vector2(1920, 1080) and is_equal_approx(zoom_1080, 1.5),
		"1920×1080 大屏档：渲染分辨率 %s，zoom = %.3f（方案 §3.9 要求 1.5）" % [str(render_1080), zoom_1080])

	# 低档在 1080p 屏上应当真的降低采样密度，而不是被上限夹回 1:1。
	var render_low := DisplayAdapter.render_size_for(Vector2(1920, 1080), 0.7)
	_check(render_low.x < 1920.0 and render_low.y < 1080.0,
		"1920×1080 低档：渲染分辨率降到 %s（填充率控制生效）" % str(render_low))


func _test_anchor_contract() -> void:
	var hud := HUD_SCENE.instantiate()
	for node_name: String in ANCHOR_CONTRACT:
		var control := hud.get_node_or_null(NodePath(node_name)) as Control
		if control == null:
			_check(false, "HUD 缺少节点 %s" % node_name)
			continue
		var spec: Dictionary = ANCHOR_CONTRACT[node_name]
		for side: String in spec:
			var actual := 0.0
			match side:
				"right":
					actual = control.anchor_right
				"bottom":
					actual = control.anchor_bottom
				"hcenter":
					actual = control.anchor_left
			_check(is_equal_approx(actual, float(spec[side])),
				"%s 的 %s 锚点为 %.2f（期望 %.2f）" % [node_name, side, actual, float(spec[side])])
	hud.free()


## HUD 必须在「视口内缩安全区」的矩形里，不允许越界压刘海或顶部/底部边缘。
func _test_hud_safe_layout() -> void:
	for entry: Dictionary in HUD_CASES:
		var viewport_size: Vector2 = entry["size"]
		var insets: Vector4 = entry["insets"]
		var sub := SubViewport.new()
		sub.size = Vector2i(viewport_size)
		sub.render_target_update_mode = SubViewport.UPDATE_DISABLED
		add_child(sub)
		var hud := HUD_SCENE.instantiate()
		sub.add_child(hud)
		await get_tree().process_frame

		hud.apply_safe_layout(insets)
		await get_tree().process_frame

		var safe := Rect2(
			Vector2(insets.x, insets.y),
			Vector2(viewport_size.x - insets.x - insets.z, viewport_size.y - insets.y - insets.w))
		for child: Node in hud.get_children():
			if not (child is Control):
				continue
			var control := child as Control
			_check(safe.encloses(control.get_rect()),
				"%s：%s 矩形 %s 在安全区 %s 内" % [entry["name"], control.name, str(control.get_rect()), str(safe)])

		sub.queue_free()
		await get_tree().process_frame


## 界面缩放：整层等比放大后仍在安全区内，且字号跟着变。
func _test_ui_scale_layout() -> void:
	var viewport_size := Vector2(1280, 720)
	var insets := Vector4(20, 12, 36, 24)
	var sub := SubViewport.new()
	sub.size = Vector2i(viewport_size)
	sub.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(sub)
	var hud := HUD_SCENE.instantiate()
	sub.add_child(hud)
	await get_tree().process_frame

	var saved_scale: float = DisplayAdapter.ui_scale
	DisplayAdapter.ui_scale = 1.25
	hud.apply_safe_layout(insets)
	await get_tree().process_frame

	var joystick := hud.get_node("Joystick") as Control
	_check(absf(joystick.size.x - 220.0 * 1.25) <= 1.0,
		"ui_scale 1.25 时摇杆宽度 %.1f（期望 %.1f）" % [joystick.size.x, 220.0 * 1.25])
	# HUD 字号已改为 DisplayAdapter 的文字角色（dp→逻辑像素），ui_scale 放大后不应缩小。
	var hp_label := hud.get_node("HpLabel") as Label
	var scaled_font := hp_label.get_theme_font_size("font_size")
	DisplayAdapter.ui_scale = saved_scale
	hud.apply_safe_layout(insets)
	await get_tree().process_frame
	var base_font := hp_label.get_theme_font_size("font_size")
	DisplayAdapter.ui_scale = 1.25
	hud.apply_safe_layout(insets)
	await get_tree().process_frame
	_check(scaled_font >= base_font,
		"ui_scale 1.25 时字号不缩小（%d → %d）" % [base_font, scaled_font])

	var safe := Rect2(Vector2(insets.x, insets.y),
		Vector2(viewport_size.x - insets.x - insets.z, viewport_size.y - insets.y - insets.w))
	for child: Node in hud.get_children():
		if child is Control:
			_check(safe.encloses((child as Control).get_rect()),
				"ui_scale 1.25：%s 仍在安全区内" % child.name)

	DisplayAdapter.ui_scale = saved_scale
	hud.apply_safe_layout(insets)
	await get_tree().process_frame
	sub.queue_free()
	await get_tree().process_frame


## 调试信息只在调试构建里显示（发布构建不应出现 FPS/坐标等开发信息）。
func _test_debug_label_gate() -> void:
	var sub := SubViewport.new()
	sub.size = Vector2i(1280, 720)
	sub.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(sub)
	var hud := HUD_SCENE.instantiate()
	sub.add_child(hud)
	await get_tree().process_frame
	var debug_label := hud.get_node("DebugLabel") as Label
	_check(debug_label.visible == OS.is_debug_build(),
		"调试信息可见性跟随构建类型（visible=%s，debug=%s）" % [
			str(debug_label.visible), str(OS.is_debug_build())])
	sub.queue_free()
	await get_tree().process_frame


## 端到端：真实场景里世界层尺寸、相机 zoom、可见世界面积与坐标映射是否与适配层一致。
## 这条用相机画布变换反推可见矩形，因此不依赖窗口尺寸，headless 也能跑。
func _test_world_view_wiring() -> void:
	var main := MAIN_SCENE.instantiate()
	add_child(main)
	await get_tree().process_frame
	await get_tree().process_frame

	var world_view = main.world_view
	_check(main.world != null and Vector2(main.world.size) == DisplayAdapter.render_size,
		"世界层 SubViewport 尺寸 = 适配层渲染分辨率 %s（实际 %s）" % [
			str(DisplayAdapter.render_size), str(main.world.size)])

	var player = GameManager.player
	var camera := player.get_node_or_null("Camera") as Camera2D
	_check(camera != null and is_equal_approx(camera.zoom.x, DisplayAdapter.world_zoom),
		"相机 zoom = 适配层归一值 %.3f（实际 %.3f）" % [
			DisplayAdapter.world_zoom, camera.zoom.x if camera != null else -1.0])

	var world_rect: Rect2 = player.get_lock_view_rect()
	var tiles := world_rect.size.x * world_rect.size.y / DisplayAdapter.TILE_AREA
	var deviation := absf(tiles - DisplayAdapter.BASE_TILES) / DisplayAdapter.BASE_TILES
	_check(deviation <= 0.02,
		"真实场景可见世界面积 %.0f×%.0f = %.1f 格（偏差 %.2f%%）" % [
			world_rect.size.x, world_rect.size.y, tiles, deviation * 100.0])

	var probe: Vector2 = player.global_position + Vector2(96.0, -48.0)
	var round_trip: Vector2 = world_view.screen_to_world(world_view.world_to_screen(probe))
	_check(round_trip.distance_to(probe) <= 0.01,
		"屏幕/世界坐标换算可逆（误差 %.4f）" % round_trip.distance_to(probe))

	main.queue_free()
	await get_tree().process_frame


func _check(condition: bool, message: String) -> void:
	if condition:
		print("[PASS] ", message)
	else:
		_failures.append(message)
		print("[FAIL] ", message)


func _report() -> void:
	print("---------- 多分辨率适配验收 ----------")
	if _failures.is_empty():
		print("结果：全部通过")
		get_tree().quit(0)
	else:
		print("结果：%d 项失败" % _failures.size())
		get_tree().quit(1)
