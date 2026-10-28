class_name PropNode
extends StaticBody2D

## 场景实体占位实现：树 / 石头 / 建筑 / 围墙。
## 约定：节点 position 取占地范围“最下方顶点”（脚底），因此父级开启 y_sort 后
## 按 position.y 排序即可得到正确的等距遮挡关系。

enum Kind { TREE, ROCK, BUILDING, WALL }

const C_SHADOW := Color(0.0, 0.0, 0.0, 0.26)
const C_TRUNK := Color(0.298, 0.224, 0.161)
const C_CANOPY_BACK := Color(0.157, 0.322, 0.196)
const C_CANOPY_MID := Color(0.204, 0.396, 0.243)
const C_CANOPY_TOP := Color(0.251, 0.463, 0.290)
const C_ROCK := Color(0.404, 0.404, 0.427)
const C_ROCK_TOP := Color(0.510, 0.510, 0.529)
const C_OUTLINE := Color(0.0, 0.0, 0.0, 0.35)

var kind: int = Kind.TREE
var cell := Vector2i.ZERO
var footprint := Vector2i.ONE
var body_height := 44.0


func setup(p_kind: int, p_cell: Vector2i, p_footprint: Vector2i = Vector2i.ONE) -> void:
	kind = p_kind
	cell = p_cell
	footprint = p_footprint


func _ready() -> void:
	position = Iso.grid_to_world(cell + footprint - Vector2i.ONE) + Vector2(0.0, Iso.TILE_H * 0.5)
	if kind == Kind.BUILDING:
		body_height = 52.0 + float(maxi(footprint.x, footprint.y)) * 4.0
	_build_collider()
	queue_redraw()


func _build_collider() -> void:
	var quad := _base_quad()
	if kind == Kind.TREE:
		var shape := CircleShape2D.new()
		shape.radius = 9.0
		var collider := CollisionShape2D.new()
		collider.shape = shape
		collider.position = _center_of(quad)
		add_child(collider)
		return
	var polygon := CollisionPolygon2D.new()
	if kind == Kind.BUILDING:
		polygon.polygon = _scaled_quad(quad, 0.92)
	else:
		# 围墙/石头略微外扩，保证相邻格子的碰撞体之间没有缝隙。
		polygon.polygon = _scaled_quad(quad, 1.06)
	add_child(polygon)


func _draw() -> void:
	match kind:
		Kind.TREE:
			_draw_tree()
		Kind.ROCK:
			_draw_rock()
		Kind.BUILDING:
			_draw_box(
				Color(0.353, 0.302, 0.251),
				Color(0.451, 0.388, 0.322),
				Color(0.549, 0.475, 0.400),
				body_height,
				true
			)
		Kind.WALL:
			_draw_box(
				Color(0.267, 0.271, 0.290),
				Color(0.353, 0.357, 0.376),
				Color(0.451, 0.455, 0.475),
				body_height,
				false
			)


func _draw_tree() -> void:
	draw_colored_polygon(_ellipse(Vector2(0.0, -4.0), 16.0, 8.0), C_SHADOW)
	draw_colored_polygon(PackedVector2Array([
		Vector2(-4.0, -4.0), Vector2(4.0, -4.0), Vector2(3.0, -42.0), Vector2(-3.0, -42.0),
	]), C_TRUNK)
	draw_circle(Vector2(-11.0, -56.0), 17.0, C_CANOPY_BACK)
	draw_circle(Vector2(11.0, -56.0), 16.0, C_CANOPY_BACK)
	draw_circle(Vector2(0.0, -70.0), 19.0, C_CANOPY_MID)
	draw_circle(Vector2(-4.0, -74.0), 11.0, C_CANOPY_TOP)


func _draw_rock() -> void:
	draw_colored_polygon(_ellipse(Vector2(0.0, -4.0), 17.0, 8.0), C_SHADOW)
	var hull := PackedVector2Array([
		Vector2(-16.0, -4.0), Vector2(-11.0, -20.0), Vector2(-1.0, -26.0),
		Vector2(11.0, -21.0), Vector2(16.0, -5.0), Vector2(4.0, 0.0),
	])
	draw_colored_polygon(hull, C_ROCK)
	draw_colored_polygon(PackedVector2Array([
		Vector2(-11.0, -20.0), Vector2(-1.0, -26.0), Vector2(4.0, -17.0), Vector2(-5.0, -13.0),
	]), C_ROCK_TOP)
	draw_polyline(Iso.closed(hull), C_OUTLINE, 1.0)


func _draw_box(side_right: Color, side_left: Color, top: Color, height: float, with_door: bool) -> void:
	var quad := _base_quad()
	var p0 := quad[0]
	var p1 := quad[1]
	var p2 := quad[2]
	var p3 := quad[3]
	var up := Vector2(0.0, -height)

	draw_colored_polygon(_ellipse(Vector2(0.0, -2.0), 8.0, 4.0), C_SHADOW)

	draw_colored_polygon(PackedVector2Array([p1, p2, p2 + up, p1 + up]), side_right)
	draw_colored_polygon(PackedVector2Array([p3, p2, p2 + up, p3 + up]), side_left)
	draw_colored_polygon(PackedVector2Array([p0 + up, p1 + up, p2 + up, p3 + up]), top)

	if with_door:
		var a := p3.lerp(p2, 0.42)
		var b := p3.lerp(p2, 0.62)
		draw_colored_polygon(PackedVector2Array([a, b, b + up * 0.55, a + up * 0.55]), Color(0.157, 0.129, 0.110))

	draw_polyline(Iso.closed(PackedVector2Array([p0 + up, p1 + up, p2 + up, p3 + up])), C_OUTLINE, 1.0)
	draw_line(p3, p3 + up, C_OUTLINE, 1.0)
	draw_line(p2, p2 + up, C_OUTLINE, 1.0)
	draw_line(p1, p1 + up, C_OUTLINE, 1.0)


## 占地范围的底面四边形：p0 上、p1 右、p2 下（节点原点）、p3 左。
func _base_quad() -> PackedVector2Array:
	var w2 := Iso.TILE_W * 0.5
	var h2 := Iso.TILE_H * 0.5
	var fx := float(footprint.x)
	var fy := float(footprint.y)
	var p1 := Vector2(w2 * fy, -h2 * fy)
	var p0 := Vector2(w2 * fy - w2 * fx, -h2 * fy - h2 * fx)
	var p3 := Vector2(-w2 * fx, -h2 * fx)
	return PackedVector2Array([p0, p1, Vector2.ZERO, p3])


func _center_of(quad: PackedVector2Array) -> Vector2:
	return (quad[0] + quad[2]) * 0.5


func _scaled_quad(quad: PackedVector2Array, factor: float) -> PackedVector2Array:
	var center := _center_of(quad)
	var out := PackedVector2Array()
	for point in quad:
		out.append(center + (point - center) * factor)
	return out


func _ellipse(center: Vector2, rx: float, ry: float) -> PackedVector2Array:
	var points := PackedVector2Array()
	for i in 16:
		var angle := TAU * float(i) / 16.0
		points.append(center + Vector2(cos(angle) * rx, sin(angle) * ry))
	return points
