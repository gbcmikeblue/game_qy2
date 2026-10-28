class_name GridPathfinder
extends RefCounted

## 逻辑网格寻路：只处理格子层面的可通行性，输出格子路径。
## 世界坐标转换由调用方走 Iso，避免出现第二套坐标公式。

const MAX_SPIRAL_RADIUS := 4

var _astar := AStarGrid2D.new()
var _size := Vector2i.ZERO


func build(size: Vector2i, blocked_cells: Array) -> void:
	_size = size
	_astar.region = Rect2i(Vector2i.ZERO, size)
	_astar.cell_size = Vector2.ONE
	_astar.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	_astar.default_compute_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	_astar.update()
	for cell: Variant in blocked_cells:
		var blocked := cell as Vector2i
		if in_bounds(blocked):
			_astar.set_point_solid(blocked, true)


func in_bounds(cell: Vector2i) -> bool:
	return cell.x >= 0 and cell.y >= 0 and cell.x < _size.x and cell.y < _size.y


func is_solid(cell: Vector2i) -> bool:
	if not in_bounds(cell):
		return true
	return _astar.is_point_solid(cell)


## 返回从 from 到 to 的格子路径（含起终点）。目标格不可通行时会寻找最近的可通行格。
func find_path(from: Vector2i, to: Vector2i) -> Array[Vector2i]:
	var empty: Array[Vector2i] = []
	if not in_bounds(from):
		return empty
	var goal := _nearest_open_cell(to)
	if goal.x < 0:
		return empty
	var raw := _astar.get_id_path(from, goal)
	var path: Array[Vector2i] = []
	for point: Vector2 in raw:
		path.append(Vector2i(roundi(point.x), roundi(point.y)))
	return path


func _nearest_open_cell(cell: Vector2i) -> Vector2i:
	if in_bounds(cell) and not _astar.is_point_solid(cell):
		return cell
	for radius in range(1, MAX_SPIRAL_RADIUS + 1):
		for dx in range(-radius, radius + 1):
			for dy in range(-radius, radius + 1):
				var candidate := cell + Vector2i(dx, dy)
				if in_bounds(candidate) and not _astar.is_point_solid(candidate):
					return candidate
	return Vector2i(-1, -1)
