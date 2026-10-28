extends Node

## 阶段 A 自动验收：无头模式运行，检查等距坐标往返、围墙围合、斜向速度一致。
## 运行：godot --headless --path <项目> res://tests/stage_a_check.tscn

const MAIN_SCENE := preload("res://scenes/boot/main.tscn")

var _failures: Array[String] = []
var _main


func _ready() -> void:
	_main = MAIN_SCENE.instantiate()
	add_child(_main)
	await get_tree().physics_frame
	await get_tree().physics_frame

	_test_grid_roundtrip()
	await _test_wall_containment()
	await _test_diagonal_speed()
	_report()


func _test_grid_roundtrip() -> void:
	var bad := 0
	for u in 64:
		for v in 64:
			var cell := Vector2i(u, v)
			if Iso.world_to_grid(Iso.grid_to_world(cell)) != cell:
				bad += 1
	_check(bad == 0, "Iso 坐标往返：64x64 网格全部可逆（失败 %d 个）" % bad)


func _test_wall_containment() -> void:
	var player := GameManager.player as CharacterBody2D
	if player == null:
		_check(false, "玩家节点未创建")
		return

	var directions: Array[Vector2] = [
		Vector2.RIGHT, Vector2.LEFT, Vector2.UP, Vector2.DOWN,
		Vector2(1.0, 1.0).normalized(), Vector2(-1.0, -1.0).normalized(),
	]
	for direction in directions:
		InputManager.touch_vector = direction
		for i in 240:
			await get_tree().physics_frame
		var frac := _fractional_grid(player.global_position)
		var inside := frac.x > 0.25 and frac.y > 0.25 and frac.x < 22.75 and frac.y < 22.75
		_check(inside, "朝 %s 冲撞 4 秒后仍在围墙内：grid(%.2f, %.2f)" % [str(direction.round()), frac.x, frac.y])
	InputManager.touch_vector = Vector2.ZERO

	# 玩家不应该卡在墙里：恢复输入后应能继续移动。
	var before := player.global_position
	InputManager.touch_vector = Vector2.DOWN
	for i in 30:
		await get_tree().physics_frame
	InputManager.touch_vector = Vector2.ZERO
	_check(player.global_position.distance_to(before) > 1.0, "撞墙后没有卡死，仍可移动（位移 %.2f）" % player.global_position.distance_to(before))


func _test_diagonal_speed() -> void:
	var player := GameManager.player as CharacterBody2D
	var spawn: Vector2 = _main.map.spawn_world_position()

	player.global_position = spawn
	player.velocity = Vector2.ZERO
	InputManager.touch_vector = Vector2.RIGHT
	var start := player.global_position
	for i in 40:
		await get_tree().physics_frame
	var straight := player.global_position.distance_to(start)

	player.global_position = spawn
	player.velocity = Vector2.ZERO
	InputManager.touch_vector = Vector2(1.0, 1.0).normalized()
	start = player.global_position
	for i in 40:
		await get_tree().physics_frame
	var diagonal := player.global_position.distance_to(start)
	InputManager.touch_vector = Vector2.ZERO

	var ratio := diagonal / maxf(straight, 0.001)
	_check(ratio > 0.85 and ratio < 1.15, "斜向速度与直线一致：%.2f vs %.2f（比值 %.3f）" % [straight, diagonal, ratio])


func _fractional_grid(world: Vector2) -> Vector2:
	return Vector2(world.x / Iso.TILE_W + world.y / Iso.TILE_H, world.y / Iso.TILE_H - world.x / Iso.TILE_W)


func _check(condition: bool, message: String) -> void:
	if condition:
		print("[PASS] ", message)
	else:
		_failures.append(message)
		print("[FAIL] ", message)


func _report() -> void:
	print("---------- 阶段 A 验收 ----------")
	if _failures.is_empty():
		print("结果：全部通过")
		get_tree().quit(0)
	else:
		print("结果：%d 项失败" % _failures.size())
		get_tree().quit(1)
