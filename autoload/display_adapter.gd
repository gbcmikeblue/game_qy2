extends Node

## 显示适配层：《移动端多分辨率适配方案》§3.1–3.4、§3.6 的唯一换算入口。
##
## 三口径（全文禁止混用）：
##   px  物理像素 —— 屏幕/纹理采样、填充率预算；
##   dp  设备无关单位 —— UI 布局、热区、字号；
##   wu  世界单位 —— 逻辑坐标、碰撞、寻路（1 wu = 1 逻辑像素，格 64×32）。
##
## 本层只做两件事：
##   1. 把屏幕尺寸换算成「世界层逻辑渲染分辨率 + 相机 zoom」，使**可见格数恒定**
##      （归一后任何屏幕都是 900 格，与宽高比无关）；
##   2. 给出 UI 用的 dp 换算与安全区内缩，UI 不吃 render_scale，因此不会被世界缩放带小。

## 屏幕尺寸、安全区、内容缩放或 ui_scale 变化时发出；HUD/世界层据此重排一次。
signal layout_changed

## 逻辑基准：1280×720 恰为 900 格（单格菱形 64×32/2 = 1024 px²）。
const BASE_SIZE := Vector2(1280.0, 720.0)
const TILE_AREA := 1024.0
## 1280×720 ÷ 1024 = 900 格。这是「可见格数恒定」的目标值，任何屏幕都归一到它。
const BASE_TILES := 900.0

## 世界层逻辑渲染分辨率的等比 clamp 区间（§3.2）。clamp 作用在**缩放系数**上，
## 因此不会破坏宽高比（按轴 clamp 会把 20:9 拉成 16:9）。
const MIN_RENDER_SIZE := Vector2(960.0, 540.0)
const MAX_RENDER_SIZE := Vector2(1920.0, 1080.0)

## 画质档位 → 渲染倍率（逻辑渲染分辨率 ÷ 屏幕物理分辨率）。
const RENDER_SCALE_TIERS := {"low": 0.7, "medium": 0.85, "high": 1.0}

## 安全区设计内缩（dp）：系统安全区为空时仍保留的最小边距（§3.4 的 24–40 dp 取中值）。
const SAFE_INSET_DP := 32.0
## 单侧内缩上限（占视口短边比例），防止异常安全区数据把 UI 挤没。
const SAFE_INSET_LIMIT_RATIO := 0.25

## 分辨率档位（桌面窗口物理像素，§7）。窗口只允许在这几档之间切换，
## 避免自由拖拽出任意宽高比导致布局/视野边界情况。
const PRESET_AUTO := "auto"
const PRESETS := [
	{"id": "auto", "size": Vector2i.ZERO},
	{"id": "720p", "size": Vector2i(1280, 720)},
	{"id": "900p", "size": Vector2i(1600, 900)},
	{"id": "1080p", "size": Vector2i(1920, 1080)},
	{"id": "1440p", "size": Vector2i(2560, 1440)},
	{"id": "wuxga", "size": Vector2i(1920, 1200)},
	{"id": "vga4x3", "size": Vector2i(1280, 960)},
	{"id": "uw21x9", "size": Vector2i(2560, 1080)},
]
## 可读下限：低于这个窗口尺寸时 18 号字只剩个位数物理像素。
const MIN_WINDOW_SIZE := Vector2i(1280, 720)
## 视野档（可见格数倍率），标准档 = 基准 900 格。
const VIEW_SCALES := {"compact": 0.8, "standard": 1.0, "wide": 1.25}

## 用户可调 UI 缩放（由 GameSettings 覆盖并持久化）。
var ui_scale := 1.0
## 画质档位：low / medium / high（auto 在启动时解析成具体档）。
var quality_tier := "medium"
## 当前分辨率档位 id（PRESETS 之一）。
var resolution_preset := PRESET_AUTO
## 视野倍率：可见格数 = BASE_TILES × view_area_scale。
var view_area_scale := 1.0
## 调试构建放开自由缩放：不加最小尺寸、不锁窗口、不吸附档位。
var free_resize := false

## 设备 dpi（refresh 时缓存；测试可注入以模拟其它设备）。
var dpi := 96.0
## 屏幕物理像素。
var screen_size := BASE_SIZE
## 根视图逻辑坐标尺寸（HUD 锚点与输入事件的坐标系，canvas_items + expand 下随宽高比变化）。
var logical_size := BASE_SIZE
## 物理像素 / 逻辑坐标。
var content_scale := 1.0
## 世界层逻辑渲染分辨率（SubViewport 尺寸）。
var render_size := BASE_SIZE
## 使可见格数恒为 BASE_TILES 的相机缩放。
var world_zoom := 1.0
## 逻辑坐标下的安全区内缩 (left, top, right, bottom)。
var safe_insets := Vector4.ZERO


func _ready() -> void:
	# 调试构建默认放开自由缩放：开发时随时拖窗口，不受档位与最小尺寸限制。
	free_resize = OS.is_debug_build()
	_sync_from_settings()
	_apply_window_constraints()
	_apply_startup_preset()
	get_window().size_changed.connect(_on_window_resized)
	GameSettings.display_changed.connect(_on_display_settings_changed)
	refresh()
	_log_metrics()


static func is_mobile() -> bool:
	return OS.has_feature("mobile")


## 调试构建启动时打一行关键指标：真机验收直接读 logcat 就能核对安全区/渲染分辨率/zoom，
## 不用靠猜截图。发布构建不输出。
func _log_metrics() -> void:
	if not OS.is_debug_build():
		return
	print("[Display] screen=%s logical=%s render=%s zoom=%.3f tiles=%.0f insets=%s preset=%s quality=%s ui=%.2f view=%.2f free_resize=%s" % [
		str(screen_size), str(logical_size), str(render_size), world_zoom,
		visible_tiles(render_size, view_area_scale), str(safe_insets),
		resolution_preset, quality_tier, ui_scale, view_area_scale, str(free_resize)])


## 窗口缩放后等一帧再算：size_changed 时根视口的逻辑尺寸可能还没更新完。
## 自由缩放模式下这就是唯一要做的事——不做吸附、不改回尺寸。
func _on_window_resized() -> void:
	refresh.call_deferred()


func _sync_from_settings() -> void:
	var preset := GameSettings.display_preset()
	resolution_preset = preset if is_known_preset(preset) else PRESET_AUTO
	var tier := GameSettings.display_quality()
	quality_tier = detect_tier() if tier == "auto" else tier
	ui_scale = GameSettings.display_ui_scale()
	view_area_scale = GameSettings.display_view_scale()


func _apply_window_constraints() -> void:
	if is_mobile():
		return
	var window := get_window()
	if free_resize:
		window.unresizable = false
		window.min_size = Vector2i(64, 64)
		return
	# 发布构建：窗口尺寸只由档位决定，禁止自由拖拽。
	window.unresizable = true
	window.min_size = MIN_WINDOW_SIZE


## 启动时套用已保存的档位。调试构建不强制改窗口尺寸，避免覆盖 `--resolution` 等调试参数。
func _apply_startup_preset() -> void:
	if free_resize or is_mobile():
		return
	set_resolution_preset(resolution_preset)


## 显示器可用区（已扣除任务栏）。取不到时退回屏幕尺寸，再退回可读下限。
func usable_rect() -> Rect2:
	var screen := DisplayServer.window_get_current_screen()
	var rect := Rect2(DisplayServer.screen_get_usable_rect(screen))
	if rect.size.x < 1.0 or rect.size.y < 1.0:
		rect = Rect2(Vector2i.ZERO, DisplayServer.screen_get_size(screen))
	if rect.size.x < 1.0 or rect.size.y < 1.0:
		return Rect2(Vector2.ZERO, Vector2(MIN_WINDOW_SIZE))
	return rect


func usable_size() -> Vector2:
	return usable_rect().size


## 档位可用性判定的边界：显示器物理分辨率（允许窗口铺满整屏，游戏常见做法）。
## 「自动」档反而按可用区取，避免标题栏/任务栏打架。
func screen_limit() -> Vector2:
	var screen := DisplayServer.window_get_current_screen()
	var size := Vector2(DisplayServer.screen_get_size(screen))
	if size.x < 1.0 or size.y < 1.0:
		size = usable_size()
	return size


## 档位对应的目标窗口尺寸（自动档按可用区，其余按整屏判定）。
func target_window_size(id: String) -> Vector2i:
	var limit := usable_size() if id == PRESET_AUTO else screen_limit()
	return resolve_window_size(id, limit)


static func preset_ids() -> Array[String]:
	var ids: Array[String] = []
	for entry: Dictionary in PRESETS:
		ids.append(String(entry["id"]))
	return ids


static func is_known_preset(id: String) -> bool:
	return preset_ids().has(id)


static func preset_size(id: String) -> Vector2i:
	for entry: Dictionary in PRESETS:
		if String(entry["id"]) == id:
			return entry["size"]
	return Vector2i.ZERO


## 档位能否放进显示器可用区。「自动」永远可用。
static func preset_fits(id: String, usable: Vector2) -> bool:
	if id == PRESET_AUTO:
		return true
	var size := preset_size(id)
	if size == Vector2i.ZERO:
		return false
	if usable.x < 1.0 or usable.y < 1.0:
		return true
	return float(size.x) <= usable.x and float(size.y) <= usable.y


## 在可用区里能容纳的最大档位（按面积降序找第一个），用于「保存的档位当前显示器放不下」的回退。
static func largest_fitting_preset(usable: Vector2) -> String:
	var best := "720p"
	var best_area := 0
	for entry: Dictionary in PRESETS:
		var id := String(entry["id"])
		if id == PRESET_AUTO or not preset_fits(id, usable):
			continue
		var size: Vector2i = entry["size"]
		var area := size.x * size.y
		if area > best_area:
			best_area = area
			best = id
	return best


## 档位 -> 实际窗口尺寸。「自动」= 可用区能容纳的最大档（不会产出任意宽高比）；
## 指定档放不下时回退到最大可容纳档，整屏都放不下才夹到可用区。
static func resolve_window_size(id: String, usable: Vector2) -> Vector2i:
	var has_usable := usable.x >= 1.0 and usable.y >= 1.0
	if id == PRESET_AUTO:
		if not has_usable:
			return MIN_WINDOW_SIZE
		return preset_size(largest_fitting_preset(usable))
	if not preset_fits(id, usable) and has_usable:
		return preset_size(largest_fitting_preset(usable))
	return preset_size(id)


## 应用分辨率档位（只改窗口，不落盘：落盘统一走 GameSettings.set_display_value）。
## 移动端全屏由系统决定，只记录选择。
func set_resolution_preset(id: String) -> void:
	if not is_known_preset(id):
		return
	resolution_preset = id
	if not is_mobile():
		var size := target_window_size(id)
		var window := get_window()
		if window.size != size:
			window.size = size
		_center_window(size)
	refresh()


## GameSettings 里的显示配置变了：重新同步并套用，UI/世界层统一从本层取派生值。
func _on_display_settings_changed() -> void:
	var previous := resolution_preset
	_sync_from_settings()
	if previous != resolution_preset:
		set_resolution_preset(resolution_preset)
	else:
		refresh()


func _center_window(size: Vector2i) -> void:
	var rect := usable_rect()
	var position := rect.position + (rect.size - Vector2(size)) * 0.5
	DisplayServer.window_set_position(Vector2i(position.round()))


## 供设置面板/调试调用：画质档、UI 缩放、视野档。
func set_view_area_scale(value: float) -> void:
	if is_equal_approx(value, view_area_scale):
		return
	view_area_scale = clampf(value, 0.5, 2.0)
	refresh()


## 重算全部派生量并广播一次。屏幕旋转、折叠屏展开、ui_scale 变更后都调这里。
func refresh() -> void:
	screen_size = Vector2(DisplayServer.window_get_size())
	if screen_size.x < 1.0 or screen_size.y < 1.0:
		# 无头模式/窗口未创建时退回基准，保证布局计算永远有有效值。
		screen_size = BASE_SIZE
	logical_size = get_window().get_visible_rect().size
	if logical_size.x < 1.0 or logical_size.y < 1.0:
		logical_size = BASE_SIZE
	content_scale = screen_size.x / logical_size.x
	dpi = float(DisplayServer.screen_get_dpi())
	if dpi < 1.0:
		dpi = 96.0
	render_size = render_size_for(screen_size, render_scale())
	world_zoom = zoom_for(render_size, view_area_scale)
	safe_insets = compute_safe_insets(logical_size, screen_size, content_scale, dpi)
	layout_changed.emit()


func set_ui_scale(value: float) -> void:
	var clamped := clampf(value, 0.9, 1.2)
	if is_equal_approx(clamped, ui_scale):
		return
	ui_scale = clamped
	refresh()


func set_quality_tier(tier: String) -> void:
	if not RENDER_SCALE_TIERS.has(tier) or tier == quality_tier:
		return
	quality_tier = tier
	refresh()


## 当前档位对应的渲染倍率。
func render_scale() -> float:
	return float(RENDER_SCALE_TIERS.get(quality_tier, 0.85))


## 渲染倍率 → 世界层逻辑渲染分辨率。等比 clamp，保持与屏幕同宽高比。
static func render_size_for(screen: Vector2, render_scale_value: float) -> Vector2:
	if screen.x < 1.0 or screen.y < 1.0:
		return BASE_SIZE
	var target := screen * clampf(render_scale_value, 0.3, 1.0)
	var shrink := minf(MAX_RENDER_SIZE.x / target.x, MAX_RENDER_SIZE.y / target.y)
	var grow := maxf(MIN_RENDER_SIZE.x / target.x, MIN_RENDER_SIZE.y / target.y)
	var k := 1.0
	if shrink < 1.0:
		k = shrink
	elif grow > 1.0:
		k = grow
	return (target * k).max(Vector2.ONE).round()


## 逻辑渲染分辨率 → 相机 zoom。可见世界面积 = 渲染面积 ÷ zoom² = 基准面积（恒 900 格）。
## 注意：zoom 只由渲染分辨率决定，与宽高比、画质档无关；画质档降低的是采样密度，不是视野。
static func zoom_for(render_size_value: Vector2, view_scale := 1.0) -> float:
	var area := render_size_value.x * render_size_value.y
	if area < 1.0:
		return 1.0
	return sqrt(area / (BASE_SIZE.x * BASE_SIZE.y * maxf(view_scale, 0.1)))


## 调试/验收用：当前渲染分辨率下的可见格数。
static func visible_tiles(render_size_value: Vector2, view_scale := 1.0) -> float:
	var zoom := zoom_for(render_size_value, view_scale)
	return render_size_value.x * render_size_value.y / (zoom * zoom) / TILE_AREA


## dp → 逻辑 UI 单位。物理 px = dp × dpi/160；逻辑单位 = 物理 px ÷ content_scale。
static func dp_to_ui(dp: float, dpi: float, content_scale_value: float, ui_scale_value: float) -> float:
	var px_per_dp := dpi / 160.0 if dpi > 0.0 else 1.0
	return dp * px_per_dp / maxf(content_scale_value, 0.01) * ui_scale_value


## dp → 逻辑 UI 单位（用当前设备的 dpi / content_scale / ui_scale）。
func dp(dp_value: float) -> float:
	return dp_to_ui(dp_value, dpi, content_scale, ui_scale)


## 文字角色表：所有界面共用，避免各处硬编码字号。
## px = 桌面基线（1280×720 逻辑下的设计像素），dp = 移动端可读性下限；
## 实际字号取两者较大值——桌面 96dpi 下 dp 换算出的像素偏小，手机 480dpi 下 dp 才是主导。
const TEXT_ROLES := {
	"title": {"px": 28, "dp": 22.0},
	"section": {"px": 20, "dp": 16.0},
	"body": {"px": 20, "dp": 14.0},
	"helper": {"px": 16, "dp": 12.0},
}


## 角色名 → 逻辑像素（dp 已含 dpi / content_scale / ui_scale）。
## dp 是可读性下限，换算出的像素必须向上取整：四舍五入会把下限吃掉
## （294dpi 下 helper 的 12dp = 22.05px，roundi 成 22px 反算只有 11.97dp，低于下限）。
func text_px(role: String) -> int:
	var spec: Dictionary = TEXT_ROLES.get(role, TEXT_ROLES["body"])
	return maxi(int(spec["px"]), ceili(dp(float(spec["dp"]))))


## 同上，但不吃 ui_scale（调试信息这类不参与界面缩放的元素用）。
func text_px_fixed(role: String) -> int:
	var spec: Dictionary = TEXT_ROLES.get(role, TEXT_ROLES["body"])
	var scaled := dp_to_ui(float(spec["dp"]), dpi, content_scale, 1.0)
	return maxi(int(spec["px"]), ceili(scaled))


## 触控热区补偿：把矩形外扩到物理尺寸不小于 min_dp（逻辑单位，按当前 dpi/content_scale 换算）。
## 控件本身尺寸不变，只放大可点区域，因此不会影响布局。
func expand_hit_rect(rect: Rect2, min_dp: float) -> Rect2:
	var min_size := dp(min_dp)
	var grow := Vector2(
		maxf(0.0, min_size - rect.size.x),
		maxf(0.0, min_size - rect.size.y)) * 0.5
	return rect.grow_individual(grow.x, grow.y, grow.x, grow.y)


## 安全区内缩（逻辑坐标）。取「系统安全区」与「设计内缩」的较大者：
## 系统返回空或全屏时只剩设计内缩，不会因为读不到安全区就没有边距。
static func compute_safe_insets(viewport: Vector2, screen: Vector2,
		content_scale_value: float, dpi_value := -1.0) -> Vector4:
	var dpi := dpi_value if dpi_value > 0.0 else float(DisplayServer.screen_get_dpi())
	var design := dp_to_ui(SAFE_INSET_DP, dpi, content_scale_value, 1.0)
	var insets := Vector4(design, design, design, design)

	var area := DisplayServer.get_display_safe_area()
	if area.size.x > 0 and area.size.y > 0 and screen.x > 0.0:
		# 全屏时安全区坐标与屏幕坐标同源，无需扣窗口位置。
		var origin := Vector2.ZERO
		var window_pos := Vector2(DisplayServer.window_get_position())
		if area.size != Vector2i(screen) and window_pos.length() > 0.0:
			origin = window_pos
		var local := Rect2(Vector2(area.position) - origin, Vector2(area.size))
		insets = Vector4(
			maxf(insets.x, local.position.x / content_scale_value),
			maxf(insets.y, local.position.y / content_scale_value),
			maxf(insets.z, viewport.x - local.end.x / content_scale_value),
			maxf(insets.w, viewport.y - local.end.y / content_scale_value))

	var limit := minf(viewport.x, viewport.y) * SAFE_INSET_LIMIT_RATIO
	return Vector4(
		clampf(insets.x, 0.0, limit), clampf(insets.y, 0.0, limit),
		clampf(insets.z, 0.0, limit), clampf(insets.w, 0.0, limit))


## 首次启动的设备档位探测（用户可在设置里覆盖）：桌面无填充率压力，直接给高档。
## 注意：档位只影响采样密度，不改变可见格数，因此探测失误不会影响玩法。
static func detect_tier() -> String:
	if not is_mobile():
		return "high"
	var adapter := String(RenderingServer.get_video_adapter_name()).to_lower()
	# 旗舰档：Adreno 7xx/8xx/9xx、Immortalis、Apple A1x+（真机样本：Adreno (TM) 830 → high）
	if adapter.contains("adreno 7") or adapter.contains("adreno 8") \
			or adapter.contains("adreno 9") or adapter.contains("immortalis") \
			or adapter.contains("apple a1"):
		return "high"
	if adapter.contains("adreno 5") or adapter.contains("mali-g3") \
			or adapter.contains("mali-g5") or adapter.contains("powervr ge8"):
		return "low"
	return "medium"
