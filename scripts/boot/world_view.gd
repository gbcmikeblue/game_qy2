extends CanvasLayer

## 世界层容器（《移动端多分辨率适配方案》§3.2 / §3.5）：
## 世界在「逻辑渲染分辨率」的 SubViewport 里渲染，再以 nearest 采样铺满整个窗口；
## 因此 render_scale 只降低世界的采样密度，不会连带缩小 UI。
##
## 同时它也是唯一知道「世界坐标 ↔ 屏幕逻辑坐标」映射的地方：
## 窗口坐标 → 显示矩形 → SubViewport → 相机画布变换，逐层反解。

## 世界层画在 HUD（默认 layer 1）之下。
const DISPLAY_LAYER := -1

@onready var view: SubViewport = $World
@onready var display: TextureRect = $Display


func _ready() -> void:
	layer = DISPLAY_LAYER
	display.texture = view.get_texture()


## 设置世界层的逻辑渲染分辨率（由 DisplayAdapter.render_size 给出）。
func set_render_size(size: Vector2) -> void:
	var target := Vector2i(maxi(1, roundi(size.x)), maxi(1, roundi(size.y)))
	if view.size != target:
		view.size = target


## 世界坐标 -> 根视图逻辑坐标（HUD 与输入事件用的坐标系）。
func world_to_screen(world: Vector2) -> Vector2:
	return _display_transform() * view.get_canvas_transform() * world


## 根视图逻辑坐标 -> 世界坐标。
func screen_to_world(screen: Vector2) -> Vector2:
	return view.get_canvas_transform().affine_inverse() * _display_transform().affine_inverse() * screen


## SubViewport 像素 -> 窗口逻辑坐标的等比映射（display 铺满视口、原点在 0,0）。
func _display_transform() -> Transform2D:
	var source := Vector2(view.size)
	var dest := display.size
	if source.x < 1.0 or source.y < 1.0 or dest.x < 1.0 or dest.y < 1.0:
		return Transform2D.IDENTITY
	return Transform2D(0.0, dest / source, 0.0, Vector2.ZERO)
