class_name GroundRenderer
extends Node2D

## 阶段 A 的程序化地面：用菱形多边形直接绘制，无贴图依赖。
## 后续接入正式美术时，本节点应替换为 TileMapLayer，逻辑坐标仍走 Iso。

const C_GRASS_DARK := Color(0.216, 0.290, 0.204)
const C_GRASS_LIGHT := Color(0.278, 0.365, 0.251)
const C_ROAD_DARK := Color(0.400, 0.330, 0.220)
const C_ROAD_LIGHT := Color(0.510, 0.430, 0.300)
const C_GRID_LINE := Color(0.0, 0.0, 0.0, 0.10)

var grid_size := Vector2i(24, 24)
var road_u: Array = []
var show_grid := false


func setup(p_grid_size: Vector2i, p_road_u: Array) -> void:
	grid_size = p_grid_size
	road_u = p_road_u
	queue_redraw()


func _draw() -> void:
	for v in grid_size.y:
		for u in grid_size.x:
			var center := Iso.grid_to_world(Vector2i(u, v))
			var noise := _hash01(u, v)
			var is_road := road_u.has(u)
			var color := C_ROAD_DARK.lerp(C_ROAD_LIGHT, noise) if is_road \
					else C_GRASS_DARK.lerp(C_GRASS_LIGHT, noise)
			var quad := Iso.diamond(center)
			draw_colored_polygon(quad, color)
			if show_grid:
				draw_polyline(Iso.closed(quad), C_GRID_LINE, 1.0)


func _hash01(u: int, v: int) -> float:
	var h := (u * 73856093) ^ (v * 19349663)
	return float(absi(h) % 1000) / 1000.0
