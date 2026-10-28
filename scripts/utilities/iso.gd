class_name Iso
extends RefCounted

## 等距坐标体系：全项目唯一的逻辑网格 <-> 世界坐标转换入口。
## 逻辑坐标 (u, v) 用于寻路、格子占用、地图数据；
## 世界坐标用于节点位置、碰撞、渲染。任何模块都不要再自己写一套公式。

const TILE_W := 64.0
const TILE_H := 32.0

static func grid_to_world(g: Vector2i) -> Vector2:
	return Vector2((g.x - g.y) * TILE_W * 0.5, (g.x + g.y) * TILE_H * 0.5)

static func world_to_grid(p: Vector2) -> Vector2i:
	var u := p.x / TILE_W + p.y / TILE_H
	var v := p.y / TILE_H - p.x / TILE_W
	return Vector2i(roundi(u), roundi(v))

## 单个格子的菱形四个顶点（顺序：上、右、下、左）。
static func diamond(center: Vector2) -> PackedVector2Array:
	var w := TILE_W * 0.5
	var h := TILE_H * 0.5
	return PackedVector2Array([
		center + Vector2(0.0, -h),
		center + Vector2(w, 0.0),
		center + Vector2(0.0, h),
		center + Vector2(-w, 0.0),
	])

## 闭合折线（用于描边），避免每次手动复制首顶点。
static func closed(points: PackedVector2Array) -> PackedVector2Array:
	var out := points.duplicate()
	if out.size() > 0:
		out.append(out[0])
	return out
