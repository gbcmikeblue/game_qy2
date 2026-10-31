extends Node

## 阶段 B 验收：战斗闭环 + 点选目标（选中与攻击完全分离）+ 自动接近。
## 运行：godot --headless --path <项目> res://tests/stage_b_check.tscn

const MAIN_SCENE := preload("res://scenes/boot/main.tscn")


## 结算测试用的哑实体：只需要位置、生命与防御，不依赖场景树里的真实角色。
class DummyActor extends Node2D:
	var hp := 100
	var defense := 5.0
	## 模拟无敌帧/已死亡：拒绝这次伤害。
	var reject := false

	func take_damage(amount: int, _source: Node = null) -> bool:
		if reject or hp <= 0:
			return false
		hp = maxi(0, hp - amount)
		return true

	func is_alive() -> bool:
		return hp > 0

	func get_defense() -> float:
		return defense

var _failures: Array[String] = []
var _main
var _map
var _player


func _ready() -> void:
	_main = MAIN_SCENE.instantiate()
	add_child(_main)
	await get_tree().physics_frame
	await get_tree().physics_frame

	_map = _main.map
	_player = GameManager.player
	EventBus.enemy_died.connect(_on_enemy_died)

	# 刷怪布局必须在清场之前验证。
	await _test_spawn_layout()
	_clear_enemies()
	await get_tree().physics_frame

	_test_combat_math()
	_test_combat_service()
	_test_health_component()
	_test_pathfinding()
	await _test_fsm()
	await _test_hysteresis_and_return()
	await _test_click_select()
	await _test_selection_never_attacks()
	await _test_attack_requires_selection()
	await _test_deselect_edges()
	await _test_auto_approach()
	await _test_approach_cancel()
	await _test_keyboard_attack()
	await _test_action_dispatch_by_kind()
	await _test_aggro_targeting()
	await _test_auto_attack()
	await _test_death_and_respawn()
	await _test_respawn_aggro_recovery()
	_report()


# ---------------- 数据与数值 ----------------

func _test_spawn_layout() -> void:
	var enemies := get_tree().get_nodes_in_group("enemies")
	_check(enemies.size() == 12, "初始刷怪 12 只（4 个方向各 3 只），实际 %d" % enemies.size())

	var north := 0
	var east := 0
	var south := 0
	var west := 0
	var too_close := 0
	for node: Node in enemies:
		var offset: Vector2 = node.global_position - _player.global_position
		var safe_distance: float = float(node.def.get("aggro_radius", 0.0)) + float(node.def.get("patrol_radius", 0.0))
		if offset.length() <= safe_distance:
			too_close += 1
		if absf(offset.x) > absf(offset.y):
			if offset.x > 0.0:
				east += 1
			else:
				west += 1
		else:
			if offset.y > 0.0:
				south += 1
			else:
				north += 1

	_check(too_close == 0, "开局所有怪物都在「仇恨+巡逻」半径之外（越界 %d 只）" % too_close)
	_check(north == 3 and east == 3 and south == 3 and west == 3,
			"四个方向各 3 只（上 %d / 右 %d / 下 %d / 左 %d）" % [north, east, south, west])

	var hp_before: int = _player.get_hp()
	var combat_states: Array[String] = []
	for i in 180:
		await get_tree().physics_frame
		for node: Node in get_tree().get_nodes_in_group("enemies"):
			var current: String = node.get_state_name()
			if (current == "CHASE" or current == "ATTACK") and not combat_states.has(current):
				combat_states.append(current)
	_check(combat_states.is_empty(), "开局 3 秒内没有怪物进入战斗状态（观测到 %s）" % str(combat_states))
	_check(_player.get_hp() == hp_before, "开局 3 秒内玩家未受伤（%d/%d）" % [_player.get_hp(), _player.get_max_hp()])


func _test_combat_math() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 12345

	var normal := CombatMath.compute_damage(20.0, 1.0, 5.0, 0.0, 1.5, rng)
	_check(int(normal["damage"]) == 15 and not bool(normal["is_crit"]), "伤害公式 20 攻击 - 5 防御 = 15")

	var floored := CombatMath.compute_damage(3.0, 1.0, 99.0, 0.0, 1.5, rng)
	_check(int(floored["damage"]) == 1, "防御高于伤害时保底 1 点（实际 %d）" % int(floored["damage"]))

	var crit := CombatMath.compute_damage(20.0, 1.0, 5.0, 1.0, 2.0, rng)
	_check(bool(crit["is_crit"]) and int(crit["damage"]) == 30,
			"必暴击时按 crit_damage 放大（实际 %d）" % int(crit["damage"]))


## CombatService 是玩家与敌人共用的结算入口：这里只验「拒绝路径」与「正常路径」。
func _test_combat_service() -> void:
	var attacker := DummyActor.new()
	var target := DummyActor.new()
	add_child(attacker)
	add_child(target)
	attacker.global_position = Vector2.ZERO
	target.global_position = Vector2(200.0, 0.0)

	var far := CombatService.strike(attacker, target, {"attack": 20.0, "max_range": 50.0})
	_check(not bool(far["hit"]) and String(far["reason"]) == "out_of_range",
			"CombatService：超出射程不结算（%s）" % String(far["reason"]))

	var no_target := CombatService.strike(attacker, null, {"attack": 20.0})
	_check(not bool(no_target["hit"]) and String(no_target["reason"]) == "no_target",
			"CombatService：无目标不结算（%s）" % String(no_target["reason"]))

	var hit := CombatService.strike(attacker, target, {"attack": 20.0, "max_range": 300.0})
	_check(bool(hit["hit"]) and int(hit["damage"]) == 15 and target.hp == 85,
			"CombatService：20 攻 - 5 防 = 15，目标 100→85（实际伤害 %d、血量 %d）"
					% [int(hit["damage"]), target.hp])

	var blocked := DummyActor.new()
	add_child(blocked)
	blocked.global_position = Vector2.ZERO
	blocked.reject = true
	var rejected := CombatService.strike(attacker, blocked, {"attack": 20.0})
	_check(not bool(rejected["hit"]) and String(rejected["reason"]) == "rejected",
			"CombatService：目标拒绝（无敌帧）时不计命中（%s）" % String(rejected["reason"]))

	blocked.hp = 0
	var dead := CombatService.strike(attacker, blocked, {"attack": 20.0})
	_check(not bool(dead["hit"]) and String(dead["reason"]) == "target_dead",
			"CombatService：目标已死亡不结算（%s）" % String(dead["reason"]))

	attacker.queue_free()
	target.queue_free()
	blocked.queue_free()


func _test_health_component() -> void:
	var health := HealthComponent.new()
	add_child(health)
	var died_count := [0]
	health.died.connect(func() -> void: died_count[0] += 1)

	health.setup(30)
	var applied := health.take_damage(20)
	_check(applied == 20 and health.hp == 10, "扣血正确 30-20=10（实际 %d）" % health.hp)

	health.take_damage(50)
	_check(health.hp == 0 and health.is_dead, "溢出伤害不会让生命变负（实际 %d）" % health.hp)
	_check(died_count[0] == 1, "死亡幂等：重复扣血不再触发 died（died 次数 %d）" % died_count[0])

	health.take_damage(10)
	_check(died_count[0] == 1 and health.hp == 0, "死亡后再次扣血不再触发死亡事件")

	health.reset_full()
	_check(health.hp == 30 and not health.is_dead, "reset_full 后满血且脱离死亡")
	health.queue_free()


func _test_pathfinding() -> void:
	var pathfinder: GridPathfinder = _map.get_pathfinder()
	var from := Vector2i(16, 16)
	var goal := Vector2i(6, 10)
	var path := pathfinder.find_path(from, goal)
	_check(path.size() > 11, "寻路绕开建筑（%d 格，直线约 10 格）" % path.size())
	if path.is_empty():
		return
	_check(path[0] == from, "路径首格等于起点")
	_check(path[path.size() - 1] == goal, "路径末格等于终点")

	var blocked_hits := 0
	for cell in path:
		if _map.is_blocked(cell):
			blocked_hits += 1
	_check(blocked_hits == 0, "路径不穿过阻挡格（违例 %d 个）" % blocked_hits)

	var detour := pathfinder.find_path(from, Vector2i(11, 11))
	_check(detour.size() > 0, "目标位于建筑内时仍能找到替代路径（%d 格）" % detour.size())
	if detour.size() > 0:
		_check(not _map.is_blocked(detour[detour.size() - 1]), "目标被占时终点退到最近可走格")


# ---------------- 敌人状态机 ----------------

func _test_fsm() -> void:
	_clear_enemies()
	await get_tree().physics_frame
	await _ensure_player_alive()
	_player.global_position = _map.spawn_world_position()
	_player.velocity = Vector2.ZERO
	await get_tree().physics_frame

	var wolf = _map.spawn_enemy("forest_wolf", Vector2i(16, 12))
	_check(wolf.get_state_name() == "IDLE", "敌人生成后处于 IDLE")
	await get_tree().physics_frame

	for i in 120:
		await get_tree().physics_frame
		if wolf.get_state_name() == "CHASE":
			break
	_check(wolf.get_state_name() == "CHASE", "IDLE -> CHASE：进入仇恨范围后开始追击")

	var hp_before: int = _player.get_hp()
	for i in 240:
		await get_tree().physics_frame
		if _player.get_hp() < hp_before:
			break
	_check(_player.get_hp() < hp_before, "CHASE -> ATTACK：进入攻击距离后发动攻击")
	_check(wolf.get_state_name() == "ATTACK" or wolf.get_state_name() == "CHASE",
			"攻击后敌人停留在战斗状态（当前 %s）" % wolf.get_state_name())

	wolf.take_damage(1)
	await get_tree().physics_frame
	_check(wolf.get_state_name() == "HURT", "受击进入 HURT 状态")

	wolf.take_damage(9999)
	await get_tree().physics_frame
	_check(wolf.get_state_name() == "DEAD", "生命归零进入 DEAD 状态")


func _test_hysteresis_and_return() -> void:
	_clear_enemies()
	await get_tree().physics_frame
	await _ensure_player_alive()
	_player.global_position = _map.spawn_world_position()
	_player.velocity = Vector2.ZERO
	await get_tree().physics_frame

	var wolf = _map.spawn_enemy("forest_wolf", Vector2i(16, 12))
	await get_tree().physics_frame
	for i in 120:
		await get_tree().physics_frame
		if wolf.get_state_name() == "CHASE":
			break
	_check(wolf.get_state_name() == "CHASE", "滞回测试前提：已进入战斗（CHASE）")

	var aggro := float(wolf.def.get("aggro_radius", 220.0))
	var deaggro := float(wolf.def.get("deaggro_radius", 380.0))
	var middle := (aggro + deaggro) * 0.5
	# 用固定方向，避免随机方位把怪丢进墙里导致路径不可达（测试抖动）。
	var direction := Vector2.RIGHT
	wolf.global_position = _player.global_position + direction * middle
	wolf.velocity = Vector2.ZERO
	await get_tree().physics_frame
	_check(middle > aggro and middle < deaggro, "测试布置：玩家位于 aggro 与 deaggro 之间（%.0f px）" % middle)

	var return_count := 0
	var last_state: String = wolf.get_state_name()
	for i in 240:
		await get_tree().physics_frame
		var current: String = wolf.get_state_name()
		if current == "RETURN" and last_state != "RETURN":
			return_count += 1
		last_state = current
		wolf.global_position = _player.global_position + direction * middle
		wolf.velocity = Vector2.ZERO
	_check(return_count == 0, "目标处于 aggro 与 deaggro 之间时不脱战（RETURN 出现 %d 次，末态 %s）" % [return_count, last_state])

	var far := middle + deaggro
	wolf.global_position = _player.global_position + direction * far
	wolf.velocity = Vector2.ZERO
	await get_tree().physics_frame
	_check(far > deaggro, "测试布置：目标已超出 deaggro 半径（%.0f px）" % far)

	for i in 120:
		await get_tree().physics_frame
		if wolf.get_state_name() == "RETURN":
			break
	_check(wolf.get_state_name() == "RETURN", "目标超出 deaggro 后进入 RETURN")

	for i in 900:
		await get_tree().physics_frame
		if wolf.get_state_name() != "RETURN":
			break
	# 回到出生点后会重新进入 IDLE；若玩家仍在仇恨范围内则可能立刻转为 CHASE。
	_check(wolf.get_state_name() != "RETURN", "返回出生点后脱离 RETURN（末态 %s）" % wolf.get_state_name())


# ---------------- 点选目标（只选中，不攻击） ----------------

func _test_click_select() -> void:
	_clear_enemies()
	await get_tree().physics_frame
	await _ensure_player_alive()
	_player.global_position = _map.spawn_world_position()
	_player.velocity = Vector2.ZERO
	_player.crit_rate = 0.0
	InputManager.touch_vector = Vector2.ZERO
	await get_tree().physics_frame

	var near = _spawn_static_enemy(Vector2(70.0, 40.0))
	var far = _spawn_static_enemy(Vector2(-90.0, 60.0))
	await get_tree().physics_frame
	await get_tree().process_frame

	_check(_player.get_selected_target() == null, "初始没有选中目标")
	_check(_player.get_lock_summary().get("count", 0) == 2, "屏幕内可点选目标 2 个")

	var hp_near: int = near.get_hp()
	await _click_enemy(near)
	_check(_player.get_selected_target() == near, "点击敌人只选中该目标")
	_check(near.get_hp() == hp_near, "点击选中不产生任何伤害（%d）" % near.get_hp())
	_check(_player.get_lock_summary().get("name", "") != "-", "HUD 能拿到选中目标名字")

	await _click_enemy(far)
	_check(_player.get_selected_target() == far, "点击另一个敌人切换选中")

	await _click_world(_player.global_position + Vector2(60.0, 140.0))
	_check(_player.get_selected_target() == null, "点击空白处取消选中")


func _test_selection_never_attacks() -> void:
	_clear_enemies()
	await get_tree().physics_frame
	await _ensure_player_alive()
	_player.global_position = _map.spawn_world_position()
	_player.velocity = Vector2.ZERO
	_player.crit_rate = 0.0
	InputManager.touch_vector = Vector2.ZERO
	await get_tree().physics_frame

	var target = _spawn_static_enemy(Vector2(0.0, 30.0))
	await get_tree().physics_frame
	var hp_before: int = target.get_hp()

	# 连续点选 5 次：一次伤害都不能有
	for i in 5:
		await _click_enemy(target)
		await get_tree().physics_frame
	_check(target.get_hp() == hp_before, "反复点选敌人不产生伤害（%d）" % target.get_hp())

	# 攻击键仍然可用，并且只作用于选中目标
	EventBus.attack_requested.emit()
	await get_tree().physics_frame
	_check(target.get_hp() < hp_before, "ATK 触发后才造成伤害（%d -> %d）" % [hp_before, target.get_hp()])


func _test_attack_requires_selection() -> void:
	_clear_enemies()
	await get_tree().physics_frame
	await _ensure_player_alive()
	_player.global_position = _map.spawn_world_position()
	_player.velocity = Vector2.ZERO
	_player.crit_rate = 0.0
	InputManager.touch_vector = Vector2.ZERO
	await get_tree().physics_frame

	var target = _spawn_static_enemy(Vector2(0.0, 40.0))
	await get_tree().physics_frame
	for i in 30:
		await get_tree().physics_frame

	var hp_before: int = target.get_hp()
	_player.clear_selection()
	var hits: int = _player.try_attack()
	_check(hits == 0 and target.get_hp() == hp_before, "没有选中目标时攻击不造成伤害")
	_check(_player.get_selected_target() == null, "攻击不会自动选中目标（选中只能由点击产生）")

	await _click_enemy(target)
	_check(_player.get_selected_target() == target, "点击后选中目标")
	for i in 30:
		await get_tree().physics_frame
	var hits2: int = _player.try_attack()
	_check(hits2 == 1 and target.get_hp() < hp_before,
			"选中后攻击命中该目标（%d -> %d）" % [hp_before, target.get_hp()])


func _test_deselect_edges() -> void:
	_clear_enemies()
	await get_tree().physics_frame
	await _ensure_player_alive()
	_player.global_position = _map.spawn_world_position()
	_player.velocity = Vector2.ZERO
	InputManager.touch_vector = Vector2.ZERO
	await get_tree().physics_frame

	var target = _spawn_static_enemy(Vector2(0.0, 60.0))
	await get_tree().physics_frame
	await _click_enemy(target)
	_check(_player.get_selected_target() == target, "边界测试：选中成功")

	target.take_damage(9999)
	for i in 4:
		await get_tree().physics_frame
	_check(_player.get_selected_target() == null, "目标死亡后自动取消选中")

	var moved = _spawn_static_enemy(Vector2(0.0, 60.0))
	await get_tree().physics_frame
	await _click_enemy(moved)
	_check(_player.get_selected_target() == moved, "边界测试：重新选中")

	# 移出可见安全矩形 -> 取消选中
	var view: Rect2 = _player.get_lock_view_rect()
	moved.global_position = Vector2(view.end.x + 120.0, _player.global_position.y)
	for i in 4:
		await get_tree().physics_frame
	_check(_player.get_selected_target() == null, "目标移出屏幕后自动取消选中")

	# 屏幕外的目标不能被点选
	_check(not _player.select_target(moved), "屏幕外目标无法被选中")
	_check(not _player.has_lock_targets(), "屏幕内没有目标时 has_lock_targets 为 false")


# ---------------- 自动接近（攻击驱动） ----------------

func _test_auto_approach() -> void:
	_clear_enemies()
	await get_tree().physics_frame
	await _ensure_player_alive()
	_player.global_position = _map.spawn_world_position()
	_player.velocity = Vector2.ZERO
	InputManager.touch_vector = Vector2.ZERO
	await get_tree().physics_frame

	var target = _spawn_static_enemy(Vector2(-170.0, 0.0))
	await get_tree().physics_frame
	_check(_player.select_target(target), "自动接近前提：选中屏幕内目标")

	var start_distance: float = _player.global_position.distance_to(target.global_position)
	_check(start_distance > _player.attack_range, "初始距离超出攻击范围（%.0f px）" % start_distance)

	for i in 20:
		await get_tree().physics_frame
	_check(not _player.is_approach_enabled(), "只选中目标不会自动接近（需要按攻击键）")

	# 走真实按钮路径：按钮抬起 -> attack_requested -> 目标超距 -> 开启自动接近
	var button = _main.get_node_or_null("HUD/AttackButton")
	_check(button != null, "HUD 存在主操作按钮")
	button._press()
	button._release()
	await get_tree().physics_frame
	await get_tree().physics_frame
	_check(_player.is_auto_approaching(), "点击主操作按钮后开始自动接近")

	for i in 240:
		await get_tree().physics_frame
	var end_distance: float = _player.global_position.distance_to(target.global_position)
	_check(end_distance <= _player.attack_range, "接近到攻击距离内后停下（%.0f px）" % end_distance)
	_check(not _player.is_auto_approaching(), "进入攻击距离后不再移动")


func _test_approach_cancel() -> void:
	_clear_enemies()
	await get_tree().physics_frame
	await _ensure_player_alive()
	_player.global_position = _map.spawn_world_position()
	_player.velocity = Vector2.ZERO
	InputManager.touch_vector = Vector2.ZERO
	await get_tree().physics_frame

	var target = _spawn_static_enemy(Vector2(-190.0, 0.0))
	await get_tree().physics_frame
	_player.select_target(target)

	# 1) 点击选中不开启寻路
	await get_tree().physics_frame
	_check(not _player.is_auto_approaching(), "点击选中不会开始寻路")

	# 2) 攻击开启，摇杆立即停止且不自行恢复
	EventBus.attack_requested.emit()
	await get_tree().physics_frame
	await get_tree().physics_frame
	_check(_player.is_auto_approaching(), "按攻击键开启寻路")
	InputManager.touch_vector = Vector2.RIGHT
	await get_tree().physics_frame
	_check(not _player.is_auto_approaching(), "摇杆一动立即停止寻路")
	for i in 6:
		await get_tree().physics_frame
	InputManager.touch_vector = Vector2.ZERO
	for i in 10:
		await get_tree().physics_frame
	var paused_at: Vector2 = _player.global_position
	for i in 60:
		await get_tree().physics_frame
	_check(not _player.is_approach_enabled(), "摇杆松手后寻路保持关闭")
	_check(_player.global_position.distance_to(paused_at) < 2.0,
			"摇杆松手后角色静止（位移 %.2f）" % _player.global_position.distance_to(paused_at))

	# 3) 技能键停止
	EventBus.attack_requested.emit()
	await get_tree().physics_frame
	await get_tree().physics_frame
	_check(_player.is_auto_approaching(), "技能测试前处于寻路状态")
	EventBus.skill_requested.emit("test_skill")
	await get_tree().physics_frame
	_check(not _player.is_auto_approaching(), "技能键停止寻路")

	# 4) 目标失效停止
	EventBus.attack_requested.emit()
	await get_tree().physics_frame
	await get_tree().physics_frame
	target.take_damage(9999)
	for i in 4:
		await get_tree().physics_frame
	_check(not _player.is_auto_approaching(), "目标死亡后寻路停止")
	_check(_player.get_selected_target() == null, "目标死亡后选中状态清空")

	# 5) 暂停停止
	var extra = _spawn_static_enemy(Vector2(-190.0, 0.0))
	await get_tree().physics_frame
	_player.select_target(extra)
	EventBus.attack_requested.emit()
	await get_tree().physics_frame
	await get_tree().physics_frame
	_check(_player.is_auto_approaching(), "暂停测试前处于寻路状态")
	GameManager.set_paused(true)
	await get_tree().physics_frame
	_check(not _player.is_auto_approaching(), "暂停时寻路状态被清除")
	GameManager.set_paused(false)
	for i in 20:
		await get_tree().physics_frame
	_check(not _player.is_auto_approaching(), "恢复运行后不会自动继续寻路")
	InputManager.touch_vector = Vector2.ZERO


# ---------------- 输入与生死 ----------------

func _test_keyboard_attack() -> void:
	_clear_enemies()
	await get_tree().physics_frame
	await _ensure_player_alive()
	_player.global_position = _map.spawn_world_position()
	_player.velocity = Vector2.ZERO
	_player.crit_rate = 0.0
	InputManager.touch_vector = Vector2.ZERO
	await get_tree().physics_frame

	var target = _spawn_static_enemy(Vector2(0.0, 40.0))
	await get_tree().physics_frame
	_player.select_target(target)
	for i in 30:
		await get_tree().physics_frame

	var hp_before: int = target.get_hp()
	_send_key(KEY_J, true)
	for i in 3:
		await get_tree().physics_frame
	_send_key(KEY_J, false)
	for i in 3:
		await get_tree().physics_frame
	_check(target.get_hp() < hp_before, "J 键攻击选中目标（%d -> %d）" % [hp_before, target.get_hp()])
	_check(_player.get_selected_target() == target, "攻击不改变选中状态")


func _test_action_dispatch_by_kind() -> void:
	_clear_enemies()
	await get_tree().physics_frame
	await _ensure_player_alive()
	_player.global_position = _map.spawn_world_position()
	_player.velocity = Vector2.ZERO
	_player.crit_rate = 0.0
	InputManager.touch_vector = Vector2.ZERO
	await get_tree().physics_frame

	var received: Array[String] = []
	var handler := func(kind: String, _target: Node) -> void:
		received.append(kind)
	EventBus.target_action_requested.connect(handler)

	var target = _spawn_static_enemy(Vector2(0.0, 40.0))
	await get_tree().physics_frame
	_check(_player.select_target(target), "分发测试：选中目标")
	target.def = (target.def as Dictionary).duplicate()

	# 1) 怪物 -> 造成伤害
	for i in 30:
		await get_tree().physics_frame
	var hp_monster: int = target.get_hp()
	_check(_player.perform_action() == 1 and target.get_hp() < hp_monster,
			"怪物：主操作造成伤害（%d -> %d）" % [hp_monster, target.get_hp()])
	_check(received.is_empty(), "怪物：不广播交互事件")

	# 2) NPC -> 不造成伤害，广播一次交互
	target.def["kind"] = "npc"
	var hp_npc: int = target.get_hp()
	for i in 30:
		await get_tree().physics_frame
	_check(_player.perform_action() == 1 and target.get_hp() == hp_npc,
			"NPC：主操作不造成伤害（%d）" % target.get_hp())
	_check(received.size() == 1 and received[0] == "npc", "NPC：广播 target_action_requested(npc)")

	# 3) 植物 -> 同样只交互
	target.def["kind"] = "plant"
	received.clear()
	for i in 30:
		await get_tree().physics_frame
	_check(_player.perform_action() == 1, "植物：主操作被执行")
	_check(received.size() == 1 and received[0] == "plant", "植物：广播 target_action_requested(plant)")
	_check(target.get_hp() == hp_npc, "植物：不造成伤害")

	# 4) 未知类型 -> 文案回退攻击，行为也按攻击处理
	target.def["kind"] = "chest"
	received.clear()
	for i in 30:
		await get_tree().physics_frame
	var hp_unknown: int = target.get_hp()
	_check(_player.perform_action() == 1 and target.get_hp() < hp_unknown,
			"未知类型回退为攻击（%d -> %d）" % [hp_unknown, target.get_hp()])
	_check(received.is_empty(), "未知类型不广播交互事件")

	EventBus.target_action_requested.disconnect(handler)
	target.queue_free()
	await get_tree().physics_frame


## 复活后自动选中恢复：立即受击（无敌期）、延迟受击、真实怪物攻击都要求接管目标。
func _test_respawn_aggro_recovery() -> void:
	_clear_enemies()
	await get_tree().physics_frame
	await _ensure_player_alive()
	_player.global_position = _map.spawn_world_position()
	_player.velocity = Vector2.ZERO
	_player.crit_rate = 0.0
	InputManager.touch_vector = Vector2.ZERO
	await get_tree().physics_frame

	var a = _spawn_static_enemy(Vector2(-110.0, 0.0))
	var b = _spawn_static_enemy(Vector2(110.0, 0.0))
	await get_tree().physics_frame

	_player.take_damage(5, a)
	await get_tree().physics_frame
	_check(_player.get_selected_target() == a, "复活测试前提：死亡前已被 A 接管")

	var health: HealthComponent = _player.get_node("Health")
	health.take_damage(9999)
	await get_tree().physics_frame
	_check(not _player.is_alive(), "致死伤害后进入死亡")
	_check(_player.get_selected_target() == null and _player.get_aggro_latch() == null,
			"死亡时清空选中与仇恨锁")

	for i in 200:
		await get_tree().physics_frame
		if _player.is_alive():
			break
	_check(_player.is_alive(), "2 秒后复活")
	_check(_player.get_selected_target() == null, "复活后选中为空（需要重新接管）")
	_check(_player.get_aggro_latch() == null, "复活后仇恨锁为空")

	# 场景 1：复活后立即受击（仍在无敌期）——目标必须接管，但不掉血
	var hp_before: int = _player.get_hp()
	_player.take_damage(5, b)
	await get_tree().physics_frame
	_check(_player.get_selected_target() == b, "复活后立即受击：自动选中攻击者 B")
	_check(_player.get_aggro_latch() == b, "复活后立即受击：B 成为仇恨锁")
	_check(_player.get_hp() == hp_before, "无敌期内不掉血（%d）" % _player.get_hp())

	# 场景 2：复活后首攻优先依然成立
	for i in 24:
		await get_tree().physics_frame
	_player.take_damage(5, a)
	await get_tree().physics_frame
	_check(_player.get_selected_target() == b, "复活后首攻优先仍生效（保持 B）")

	# 场景 3：延迟受击（无敌结束后）——接管且正常掉血
	var c = _spawn_static_enemy(Vector2(0.0, 120.0))
	await get_tree().physics_frame
	_player.clear_aggro_latch()
	_player.clear_selection()
	for i in 90:
		await get_tree().physics_frame
	var hp_delay: int = _player.get_hp()
	_player.take_damage(6, c)
	await get_tree().physics_frame
	_check(_player.get_selected_target() == c, "复活后延迟受击：自动选中 C")
	_check(_player.get_hp() < hp_delay, "无敌结束后正常掉血（%d -> %d）" % [hp_delay, _player.get_hp()])

	# 场景 4：真实怪物攻击（走物理与攻击流程，不是手工调 take_damage）
	_clear_enemies()
	await get_tree().physics_frame
	_player.clear_selection()
	_player.clear_aggro_latch()
	_player.global_position = _map.spawn_world_position()
	await get_tree().physics_frame

	var wolf = _map.spawn_enemy("forest_wolf", Iso.world_to_grid(_player.global_position))
	wolf.global_position = _player.global_position + Vector2(34.0, 0.0)
	await get_tree().physics_frame

	var health2: HealthComponent = _player.get_node("Health")
	health2.take_damage(9999)
	for i in 200:
		await get_tree().physics_frame
		if _player.is_alive():
			break
	_check(_player.is_alive(), "真实场景：复活成功")
	for i in 400:
		await get_tree().physics_frame
		if _player.get_selected_target() != null:
			break
	_check(_player.get_selected_target() == wolf, "复活后被真实怪物攻击也会自动选中")


func _test_death_and_respawn() -> void:
	await _ensure_player_alive()
	_player.global_position = _map.spawn_world_position()
	var spawn: Vector2 = _map.spawn_world_position()
	var health: HealthComponent = _player.get_node("Health")
	health.take_damage(9999)
	await get_tree().physics_frame
	_check(not _player.is_alive(), "致死伤害后玩家进入死亡状态")
	_check(_player.get_selected_target() == null, "玩家死亡时取消选中")

	for i in 150:
		await get_tree().physics_frame
		if _player.is_alive():
			break
	_check(_player.is_alive(), "2 秒后自动复活")
	_check(_player.global_position.distance_to(spawn) < 1.0,
			"复活位置回到出生点（偏差 %.2f）" % _player.global_position.distance_to(spawn))
	_check(_player.get_hp() == _player.get_max_hp(), "复活后满血（%d/%d）" % [_player.get_hp(), _player.get_max_hp()])


# ---------------- 工具 ----------------

## 造一只“站桩”怪：位置固定、不参与 AI 物理，保证点击几何关系稳定。
func _spawn_static_enemy(offset: Vector2, type := "forest_wolf"):
	var enemy = _map.spawn_enemy(type, Vector2i(12, 14))
	enemy.global_position = _player.global_position + offset
	enemy.move_speed = 0.0
	enemy.set_physics_process(false)
	return enemy


## 仇恨接管：首只攻击者优先；锁释放（超时 / 手选 / 死亡）后新的攻击者接管。
func _test_aggro_targeting() -> void:
	_clear_enemies()
	await get_tree().physics_frame
	await _ensure_player_alive()
	_player.global_position = _map.spawn_world_position()
	_player.velocity = Vector2.ZERO
	_player.crit_rate = 0.0
	InputManager.touch_vector = Vector2.ZERO
	await get_tree().physics_frame

	var a = _spawn_static_enemy(Vector2(-120.0, 0.0))
	var b = _spawn_static_enemy(Vector2(120.0, 0.0))
	await get_tree().physics_frame
	_player.clear_selection()
	_player.clear_aggro_latch()
	_check(_player.get_selected_target() == null, "仇恨测试：初始无选中目标")

	_player.take_damage(5, a)
	await get_tree().physics_frame
	_check(_player.get_selected_target() == a, "被 A 攻击后自动选中 A")
	_check(_player.get_aggro_latch() == a, "A 成为仇恨锁（第一只攻击者）")

	for i in 24:
		await get_tree().physics_frame
	_player.take_damage(5, b)
	await get_tree().physics_frame
	_check(_player.get_selected_target() == a, "B 随后攻击不切换目标（先到先得）")

	# 长按秒数内的“同一只怪继续攻击”只续期，不换目标
	for i in 24:
		await get_tree().physics_frame
	_player.take_damage(5, a)
	await get_tree().physics_frame
	_check(_player.get_selected_target() == a and _player.get_aggro_latch() == a, "A 继续攻击只续期锁")

	# 超时释放：把锁的保持时间调小，等它过期后 B 可以接管
	var previous_timeout: float = _player.aggro_latch_timeout
	_player.aggro_latch_timeout = 0.3
	for i in 24:
		await get_tree().physics_frame
	_check(_player.get_aggro_latch() == null, "超时未再被攻击时仇恨锁释放")
	for i in 24:
		await get_tree().physics_frame
	_player.take_damage(5, b)
	await get_tree().physics_frame
	_check(_player.get_selected_target() == b, "锁释放后 B 攻击接管目标")
	_player.aggro_latch_timeout = previous_timeout

	# 玩家手动点选优先，并清空仇恨锁
	await _click_enemy(a)
	_check(_player.get_selected_target() == a, "手动点选 A 生效")
	_check(_player.get_aggro_latch() == null, "手动点选会清空仇恨锁")
	for i in 24:
		await get_tree().physics_frame
	_player.take_damage(5, b)
	await get_tree().physics_frame
	_check(_player.get_selected_target() == b, "清锁后新的攻击者重新接管")

	# 锁过期后，第三只攻击者接管
	_player.aggro_latch_timeout = 0.3
	for i in 24:
		await get_tree().physics_frame
	_check(_player.get_aggro_latch() == null, "B 停止攻击后锁过期")
	var c = _spawn_static_enemy(Vector2(-120.0, 0.0))
	await get_tree().physics_frame
	_player.take_damage(5, c)
	await get_tree().physics_frame
	_check(_player.get_selected_target() == c, "锁过期后第三只攻击者接管目标")
	_player.aggro_latch_timeout = previous_timeout

	# 非当前目标死亡不影响选中
	b.take_damage(9999)
	for i in 4:
		await get_tree().physics_frame
	_check(_player.get_selected_target() == c, "非当前目标的死亡不影响选中")


## 持续攻击：长按 / 连点触发，反复攻击直到目标死亡或主动中断。
func _test_auto_attack() -> void:
	_clear_enemies()
	await get_tree().physics_frame
	await _ensure_player_alive()
	_player.global_position = _map.spawn_world_position()
	_player.velocity = Vector2.ZERO
	_player.crit_rate = 0.0
	InputManager.touch_vector = Vector2.ZERO
	await get_tree().physics_frame

	var target = _spawn_static_enemy(Vector2(0.0, 34.0), "stone_boar")
	await get_tree().physics_frame
	_check(_player.select_target(target), "持续攻击：选中目标")
	_player.clear_aggro_latch()
	_check(not _player.is_auto_attack_active(), "默认未开启持续攻击")

	# 1) 长按触发
	_send_key(KEY_J, true)
	for i in 60:
		await get_tree().physics_frame
	_check(_player.is_auto_attack_active(), "按住攻击键超过 %.1f 秒后开启持续攻击" % _player.auto_attack_hold_seconds)
	_send_key(KEY_J, false)
	for i in 6:
		await get_tree().physics_frame
	_check(_player.is_auto_attack_active(), "松开按键后持续攻击继续（直到目标死亡/中断）")

	var hp_after_hold: int = target.get_hp()
	for i in 70:
		await get_tree().physics_frame
	_check(target.get_hp() < hp_after_hold, "持续攻击自动反复造成伤害（%d -> %d）" % [hp_after_hold, target.get_hp()])

	# 2) 移动中断
	InputManager.touch_vector = Vector2.RIGHT
	await get_tree().physics_frame
	_check(not _player.is_auto_attack_active(), "移动中断持续攻击")
	InputManager.touch_vector = Vector2.ZERO
	for i in 6:
		await get_tree().physics_frame

	# 3) 连点触发
	_player.cancel_auto_attack()
	await get_tree().physics_frame
	var taps: int = _player.auto_attack_tap_count
	for i in taps:
		_send_key(KEY_J, true)
		await get_tree().physics_frame
		_send_key(KEY_J, false)
		await get_tree().physics_frame
	await get_tree().physics_frame
	_check(_player.is_auto_attack_active(), "连点 %d 次触发持续攻击" % taps)

	# 4) 点空白中断
	await _click_world(_player.global_position + Vector2(95.0, 165.0))
	_check(not _player.is_auto_attack_active(), "点击空白处中断持续攻击")

	# 5) 点其他目标中断（点空白已清空选中，这里重新选中目标）
	_player.cancel_auto_attack()
	_player.select_target(target)
	await get_tree().physics_frame
	for i in taps:
		_send_key(KEY_J, true)
		await get_tree().physics_frame
		_send_key(KEY_J, false)
		await get_tree().physics_frame
	await get_tree().physics_frame
	_check(_player.is_auto_attack_active(), "连点再次开启持续攻击")
	var other = _spawn_static_enemy(Vector2(120.0, 10.0), "stone_boar")
	await get_tree().physics_frame
	await _click_enemy(other)
	_check(not _player.is_auto_attack_active(), "点击其他交互对象中断持续攻击")

	# 6) 技能键中断
	_player.select_target(target)
	for i in taps:
		_send_key(KEY_J, true)
		await get_tree().physics_frame
		_send_key(KEY_J, false)
		await get_tree().physics_frame
	await get_tree().physics_frame
	_check(_player.is_auto_attack_active(), "持续攻击重新开启")
	EventBus.skill_requested.emit("test_skill")
	await get_tree().physics_frame
	_check(not _player.is_auto_attack_active(), "技能键中断持续攻击")

	# 7) 目标死亡中断
	_player.select_target(target)
	for i in taps:
		_send_key(KEY_J, true)
		await get_tree().physics_frame
		_send_key(KEY_J, false)
		await get_tree().physics_frame
	await get_tree().physics_frame
	_check(_player.is_auto_attack_active(), "持续攻击再次开启")
	target.take_damage(9999)
	for i in 6:
		await get_tree().physics_frame
	_check(not _player.is_auto_attack_active(), "目标死亡后持续攻击结束")

	other.queue_free()
	await get_tree().physics_frame


## 模拟真实点击：直接调用拾取器逻辑。
## 世界层在独立 SubViewport 内渲染后，屏幕坐标换算由 WorldView 负责（main 已注入），
## 因此这里走世界坐标入口 pick_at_world，验证的命中/选中语义与真实点击一致。
func _click_enemy(enemy: Node) -> void:
	await _click_world(enemy.global_position - Vector2(0.0, 26.0))


func _click_world(world_position: Vector2) -> void:
	var picker = _main.get_node_or_null("TargetPicker")
	if picker == null:
		_check(false, "场景里缺少 TargetPicker")
		return
	picker.pick_at_world(world_position)
	await get_tree().process_frame


func _send_key(keycode: int, pressed: bool) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = keycode
	event.pressed = pressed
	Input.parse_input_event(event)


func _clear_enemies() -> void:
	for node: Node in get_tree().get_nodes_in_group("enemies"):
		node.queue_free()


func _ensure_player_alive() -> void:
	if not is_instance_valid(_player):
		return
	_player.clear_selection()
	if not _player.is_alive():
		var health: HealthComponent = _player.get_node("Health")
		health.reset_full()
		_player.global_position = _map.spawn_world_position()


func _on_enemy_died(_enemy_id: String) -> void:
	pass


func _check(condition: bool, message: String) -> void:
	if condition:
		print("[PASS] ", message)
	else:
		_failures.append(message)
		print("[FAIL] ", message)


func _report() -> void:
	print("---------- 阶段 B1 验收 ----------")
	if _failures.is_empty():
		print("结果：全部通过")
		get_tree().quit(0)
	else:
		print("结果：%d 项失败" % _failures.size())
		get_tree().quit(1)
