extends Node

## 阶段 B1 自动验收：无头运行，覆盖数值公式、生命值幂等、寻路、状态机、单次命中、死亡复活。
## 运行：godot --headless --path <项目> res://tests/stage_b_check.tscn

const MAIN_SCENE := preload("res://scenes/boot/main.tscn")

var _failures: Array[String] = []
var _main
var _map
var _player
var _enemy_deaths: Array[String] = []


func _ready() -> void:
	_test_damage_formula()
	_test_health_component()

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

	_test_pathfinding()
	await _test_fsm()
	await _test_hysteresis_and_return()
	await _test_lock_targeting()
	await _test_screen_scope()
	await _test_hold_selection()
	await _test_auto_approach()
	await _test_keyboard_bindings()
	await _test_death_and_respawn()
	_report()


func _test_damage_formula() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 12345

	var plain := CombatMath.compute_damage(20.0, 1.0, 5.0, 0.0, 1.5, rng)
	_check(int(plain["damage"]) == 15 and not bool(plain["is_crit"]), "伤害公式 20 攻击 - 5 防御 = 15")

	var floored := CombatMath.compute_damage(5.0, 1.0, 100.0, 0.0, 1.5, rng)
	_check(int(floored["damage"]) == 1, "防御高于伤害时保底 1 点（实际 %d）" % int(floored["damage"]))

	var crit := CombatMath.compute_damage(20.0, 1.0, 5.0, 1.0, 2.0, rng)
	_check(int(crit["damage"]) == 30 and bool(crit["is_crit"]), "必暴击时按 crit_damage 放大（实际 %d）" % int(crit["damage"]))


func _test_health_component() -> void:
	var health := HealthComponent.new()
	add_child(health)
	var deaths := [0]
	health.died.connect(func() -> void: deaths[0] += 1)

	health.setup(30)
	health.take_damage(20)
	_check(health.hp == 10, "扣血正确 30-20=10（实际 %d）" % health.hp)

	health.take_damage(100)
	_check(health.hp == 0 and health.is_dead, "溢出伤害不会让生命变负（实际 %d）" % health.hp)

	var again := health.take_damage(50)
	_check(again == 0 and deaths[0] == 1, "死亡幂等：重复扣血不再触发 died（died 次数 %d）" % deaths[0])

	health.reset_full()
	_check(health.hp == 30 and not health.is_dead, "reset_full 后满血且脱离死亡")
	health.queue_free()


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


func _test_fsm() -> void:
	_clear_enemies()
	await get_tree().physics_frame
	await _ensure_player_alive()
	_player.global_position = _map.spawn_world_position()
	_player.velocity = Vector2.ZERO
	await get_tree().physics_frame

	var wolf = _map.spawn_enemy("forest_wolf", Vector2i(16, 12))
	await get_tree().physics_frame

	var saw_chase := false
	var saw_attack := false
	var hp_before: int = _player.get_hp()
	for i in 360:
		await get_tree().physics_frame
		if not is_instance_valid(wolf) or not wolf.is_alive():
			break
		var current: String = wolf.get_state_name()
		if current == "CHASE":
			saw_chase = true
		if current == "ATTACK":
			saw_attack = true
		if saw_attack and _player.get_hp() < hp_before:
			break

	_check(saw_chase, "IDLE -> CHASE：进入仇恨范围后开始追击")
	_check(saw_attack, "CHASE -> ATTACK：进入攻击距离后发动攻击")
	_check(_player.get_hp() < hp_before, "敌人攻击对玩家造成伤害（%d -> %d）" % [hp_before, _player.get_hp()])

	if not is_instance_valid(wolf) or not wolf.is_alive():
		return

	var states: Array[String] = []
	wolf.take_damage(1)
	for i in 30:
		await get_tree().physics_frame
		states.append(wolf.get_state_name())
	_check(states.has("HURT"), "受击进入 HURT 状态")

	var deaths_before := _enemy_deaths.size()
	wolf.take_damage(9999)
	await get_tree().physics_frame
	_check(wolf.get_state_name() == "DEAD", "生命归零进入 DEAD 状态")
	await get_tree().process_frame
	_check(_enemy_deaths.size() == deaths_before + 1, "死亡事件只触发一次（%d 次）" % (_enemy_deaths.size() - deaths_before))

	wolf.take_damage(9999)
	await get_tree().process_frame
	_check(_enemy_deaths.size() == deaths_before + 1, "死亡后再次扣血不再触发死亡事件")


func _test_hysteresis_and_return() -> void:
	_clear_enemies()
	await get_tree().physics_frame
	await _ensure_player_alive()
	_player.global_position = _map.spawn_world_position()
	_player.velocity = Vector2.ZERO
	await get_tree().physics_frame

	var wolf = _map.spawn_enemy("forest_wolf", Vector2i(16, 12))
	await get_tree().physics_frame

	for i in 90:
		await get_tree().physics_frame
	_check(wolf.get_state_name() in ["CHASE", "ATTACK"], "滞回测试前提：已进入战斗（%s）" % wolf.get_state_name())

	# 以敌人当前位置为基准，把玩家放到 aggro(220) 与 deaggro(380) 之间的 300px 处。
	var away: Vector2 = _player.global_position - wolf.global_position
	var direction := away.normalized() if away.length() > 0.01 else Vector2.DOWN
	_player.global_position = wolf.global_position + direction * 300.0
	var separation: float = _player.global_position.distance_to(wolf.global_position)
	_check(separation > 220.0 and separation < 380.0, "测试布置：玩家位于 aggro 与 deaggro 之间（%.0f px）" % separation)

	var return_count := 0
	var last_state: String = wolf.get_state_name()
	for i in 240:
		await get_tree().physics_frame
		if not is_instance_valid(wolf):
			break
		last_state = wolf.get_state_name()
		if last_state == "RETURN":
			return_count += 1
	_check(return_count == 0, "目标处于 aggro 与 deaggro 之间时不脱战（RETURN 出现 %d 次，末态 %s）" % [return_count, last_state])

	# 直接把敌人挪到超出 deaggro 的位置，应立刻脱战并走回出生点。
	await _ensure_player_alive()
	var far_cell := Vector2i(21, 8)
	wolf.global_position = Iso.grid_to_world(far_cell)
	await get_tree().physics_frame
	var distance: float = _player.global_position.distance_to(wolf.global_position)
	_check(distance > 380.0, "测试布置：目标已超出 deaggro 半径（%.0f px）" % distance)

	var saw_return := false
	for i in 240:
		await get_tree().physics_frame
		if not is_instance_valid(wolf):
			break
		if wolf.get_state_name() == "RETURN":
			saw_return = true
			break
	_check(saw_return, "目标超出 deaggro 后进入 RETURN")

	var saw_idle := false
	for i in 900:
		await get_tree().physics_frame
		if not is_instance_valid(wolf):
			break
		if wolf.get_state_name() == "IDLE":
			saw_idle = true
			break
	if is_instance_valid(wolf):
		_check(saw_idle, "返回出生点后回到 IDLE（末态 %s）" % wolf.get_state_name())


func _test_lock_targeting() -> void:
	_clear_enemies()
	await get_tree().physics_frame
	await _ensure_player_alive()
	_player.global_position = _map.spawn_world_position()
	_player.velocity = Vector2.ZERO
	_player.crit_rate = 0.0
	_player.face_direction(Vector2.DOWN)

	var switch_button = _main.get_node_or_null("HUD/SwitchButton")
	_check(switch_button != null, "HUD 存在切换锁定按钮")
	_check(_player.has_lock_targets() == false, "无怪时 has_lock_targets 为 false")

	var near = _map.spawn_enemy("forest_wolf", Vector2i(12, 14))
	var far = _map.spawn_enemy("forest_wolf", Vector2i(12, 14))
	near.global_position = _player.global_position + Vector2(0.0, 30.0)
	far.global_position = _player.global_position + Vector2(0.0, 60.0)
	await get_tree().physics_frame
	await get_tree().process_frame

	var summary: Dictionary = _player.get_lock_summary()
	_check(int(summary.get("count", 0)) == 2, "锁定候选按距离收集（%d 个）" % int(summary.get("count", 0)))
	_check(not switch_button.is_disabled(), "有可选目标时切换按钮可用")

	var hp_near: int = near.get_hp()
	var hp_far: int = far.get_hp()
	var hits: int = _player.try_attack()
	_check(hits == 1, "锁定攻击每次只结算一个目标（命中 %d）" % hits)
	_check(_player.get_locked_target() == near, "攻击时自动锁定最近目标")
	_check(near.get_hp() == hp_near - 18 and far.get_hp() == hp_far,
			"只有被锁定目标掉血（%d->%d, %d->%d）" % [hp_near, near.get_hp(), hp_far, far.get_hp()])

	var blocked: int = _player.try_attack()
	_check(blocked == 0 and near.get_hp() == hp_near - 18, "冷却期间再次挥击不重复扣血")

	_check(_player.cycle_lock_target(), "切换锁定返回成功")
	_check(_player.get_locked_target() == far, "切换后锁定对象变为第二个目标")

	for i in 30:
		await get_tree().physics_frame

	var to_far: Vector2 = (far.global_position - _player.global_position).normalized()
	_check(_player.get_facing().dot(to_far) > 0.9, "攻击指向平滑追踪锁定目标（朝向点积 %.2f）" % _player.get_facing().dot(to_far))

	var hp_near_locked: int = near.get_hp()
	var hp_far_locked: int = far.get_hp()
	var hits2: int = _player.try_attack()
	_check(hits2 == 1 and near.get_hp() == hp_near_locked and far.get_hp() == hp_far_locked - 18,
			"切换后攻击指向新目标（near %d, far %d->%d）" % [near.get_hp(), hp_far_locked, far.get_hp()])

	_check(_player.cycle_lock_target(), "连续切换返回成功")
	_check(_player.get_locked_target() == near, "选中最后一个后循环回到第一个目标")

	near.take_damage(9999)
	far.take_damage(9999)
	for i in 4:
		await get_tree().physics_frame
	await get_tree().process_frame

	_check(not _player.has_lock_targets(), "目标全部死亡后无可选目标")
	_check(not _player.cycle_lock_target(), "无目标时切换返回 false")
	_check(_player.get_locked_target() == null, "无目标时锁定被清空")
	_check(_player.try_attack() == 0, "无目标时攻击不产生伤害")
	_check(switch_button.is_disabled(), "无目标时切换按钮置灰不可用")


func _test_screen_scope() -> void:
	_clear_enemies()
	await get_tree().physics_frame
	await _ensure_player_alive()
	_player.global_position = _map.spawn_world_position()
	_player.velocity = Vector2.ZERO
	await get_tree().physics_frame
	await get_tree().process_frame

	var switch_button = _main.get_node_or_null("HUD/SwitchButton")
	var view: Rect2 = _player.get_lock_view_rect()
	_check(view.size.x > 0.0 and view.size.y > 0.0,
			"可见范围矩形有效 %.0f x %.0f 世界像素" % [view.size.x, view.size.y])

	var inside = _map.spawn_enemy("forest_wolf", Vector2i(12, 14))
	inside.global_position = _player.global_position + Vector2(0.0, 36.0)
	inside.move_speed = 0.0

	var outside = _map.spawn_enemy("forest_wolf", Vector2i(12, 14))
	outside.global_position = Vector2(view.end.x + 80.0, _player.global_position.y)
	outside.move_speed = 0.0
	await get_tree().physics_frame
	await get_tree().process_frame

	var summary: Dictionary = _player.get_lock_summary()
	_check(int(summary.get("count", 0)) == 1, "候选只统计屏幕内目标（%d 个）" % int(summary.get("count", 0)))
	_check(not _player.is_position_locked_view(outside.global_position, _player.lock_screen_margin),
			"屏幕外目标不满足可见安全矩形")

	_check(_player.cycle_lock_target(), "屏幕内有目标时可切换")
	_check(_player.get_locked_target() == inside, "只会锁定屏幕内目标")

	_player.cycle_lock_target()
	_check(_player.get_locked_target() == inside, "屏幕外目标不参与循环切换")

	inside.global_position = Vector2(view.end.x + 120.0, _player.global_position.y)
	for i in 4:
		await get_tree().physics_frame
	_check(_player.get_locked_target() == null, "锁定目标离开屏幕后自动解锁")

	await get_tree().process_frame
	_check(switch_button.is_disabled(), "屏幕内无目标时切换按钮置灰")

	inside.global_position = _player.global_position + Vector2(0.0, 36.0)
	outside.global_position = _player.global_position + Vector2(40.0, 36.0)
	await get_tree().process_frame
	_check(not switch_button.is_disabled(), "屏幕内重新出现目标后按钮恢复可用")


func _test_hold_selection() -> void:
	_clear_enemies()
	await get_tree().physics_frame
	await _ensure_player_alive()
	_player.global_position = _map.spawn_world_position()
	_player.velocity = Vector2.ZERO
	_player.crit_rate = 0.0
	InputManager.touch_vector = Vector2.ZERO
	await get_tree().physics_frame

	var left = _spawn_static_enemy(Vector2(-160.0, 0.0))
	var right = _spawn_static_enemy(Vector2(160.0, 0.0))
	var down = _spawn_static_enemy(Vector2(0.0, 150.0))
	await get_tree().physics_frame

	# 1) 按住 -> 进入选择模式，预览默认取最近目标
	EventBus.target_select_pressed.emit()
	await get_tree().physics_frame
	_check(_player.is_selecting(), "按住目标按钮进入选择模式")
	_check(_player.get_preview_target() == down, "初始预览为屏幕内最近目标")

	# 选择模式下摇杆只用于选目标，不再驱动移动
	var before: Vector2 = _player.global_position
	InputManager.touch_vector = Vector2.LEFT
	for i in 20:
		await get_tree().physics_frame
	_check(_player.global_position.distance_to(before) < 2.0,
			"选择模式下角色不移动（位移 %.2f）" % _player.global_position.distance_to(before))
	_check(_player.get_preview_target() == left, "向左甩动摇杆把预览切到左侧目标")
	_check(_player.get_locked_target() == null, "未松开前不改变已锁定的目标")

	# 2) 松开 -> 确认选择
	InputManager.touch_vector = Vector2.ZERO
	for i in 3:
		await get_tree().physics_frame
	EventBus.target_select_released.emit()
	await get_tree().physics_frame
	_check(not _player.is_selecting(), "松开目标按钮退出选择模式")
	_check(_player.get_locked_target() == left, "松开后预览目标成为锁定目标")

	# 3) 朝没有目标的方向甩动 -> 保持当前选择不变
	EventBus.target_select_pressed.emit()
	for i in 2:
		await get_tree().physics_frame
	InputManager.touch_vector = Vector2.UP
	for i in 8:
		await get_tree().physics_frame
	_check(_player.get_preview_target() == left, "朝空方向甩动时预览保持为当前目标")
	EventBus.target_select_released.emit()
	InputManager.touch_vector = Vector2.ZERO
	await get_tree().physics_frame
	_check(_player.get_locked_target() == left, "无可切换目标时松开保持原选择")

	# 4) 被建筑遮挡的目标同样可选（不做遮挡判定）
	var occluded = _map.spawn_enemy("forest_wolf", Vector2i(10, 8))
	occluded.move_speed = 0.0
	await get_tree().physics_frame
	_check(_player.lock_targets().has(occluded), "被遮挡目标仍进入候选列表")
	EventBus.target_select_pressed.emit()
	await get_tree().physics_frame
	var toward: Vector2 = (occluded.global_position - _player.global_position).normalized()
	InputManager.touch_vector = toward
	for i in 10:
		await get_tree().physics_frame
	_check(_player.get_preview_target() == occluded, "被遮挡目标可以被选中")
	EventBus.target_select_released.emit()
	InputManager.touch_vector = Vector2.ZERO
	await get_tree().physics_frame
	_check(_player.get_locked_target() == occluded, "松开后被遮挡目标成为锁定目标")

	# 5) 回归：按住目标按钮期间不会触发攻击
	_player.global_position = occluded.global_position + Vector2(0.0, 40.0)
	_player.velocity = Vector2.ZERO
	await get_tree().physics_frame
	EventBus.target_select_pressed.emit()
	await get_tree().physics_frame
	var hp_before: int = occluded.get_hp()
	EventBus.attack_requested.emit()
	var hits: int = _player.try_attack()
	for i in 3:
		await get_tree().physics_frame
	_check(hits == 0 and occluded.get_hp() == hp_before,
			"按住目标按钮期间攻击被抑制（目标血量 %d -> %d）" % [hp_before, occluded.get_hp()])

	EventBus.target_select_released.emit()
	await get_tree().physics_frame
	var hits_after: int = _player.try_attack()
	_check(hits_after == 1 and occluded.get_hp() < hp_before, "松开后攻击恢复正常（命中 %d）" % hits_after)

	# 6) 完全没有目标时按住/松开不改变任何状态
	_clear_enemies()
	for i in 4:
		await get_tree().physics_frame
	EventBus.target_select_pressed.emit()
	await get_tree().physics_frame
	_check(_player.get_preview_target() == null, "无目标时按住在没有预览对象")
	EventBus.target_select_released.emit()
	await get_tree().physics_frame
	_check(_player.get_locked_target() == null, "无目标时松开不产生锁定")
	InputManager.touch_vector = Vector2.ZERO


func _spawn_static_enemy(offset: Vector2):
	var enemy = _map.spawn_enemy("forest_wolf", Vector2i(12, 14))
	enemy.global_position = _player.global_position + offset
	enemy.move_speed = 0.0
	return enemy


func _test_auto_approach() -> void:
	_clear_enemies()
	await get_tree().physics_frame
	await _ensure_player_alive()
	_player.global_position = _map.spawn_world_position()
	_player.velocity = Vector2.ZERO
	InputManager.touch_vector = Vector2.ZERO
	await get_tree().physics_frame

	var target = _map.spawn_enemy("forest_wolf", Vector2i(12, 14))
	target.global_position = _player.global_position + Vector2(-150.0, 0.0)
	target.move_speed = 0.0
	await get_tree().physics_frame

	_check(_player.cycle_lock_target(), "自动接近前提：锁定屏幕内目标")
	var start_distance: float = _player.global_position.distance_to(target.global_position)
	_check(start_distance > _player.attack_range, "初始距离超出攻击范围（%.0f px）" % start_distance)

	for i in 240:
		await get_tree().physics_frame
	var end_distance: float = _player.global_position.distance_to(target.global_position)
	_check(end_distance < start_distance - 30.0, "锁定后自动接近（%.0f -> %.0f px）" % [start_distance, end_distance])
	_check(end_distance <= _player.attack_range, "接近到攻击距离内后停下（%.0f px）" % end_distance)

	# 摇杆输入优先于自动接近：把角色挪远后向右推摇杆，应该向右走而不是朝目标走。
	_player.global_position = target.global_position + Vector2(0.0, 200.0)
	_player.velocity = Vector2.ZERO
	await get_tree().physics_frame
	var before: Vector2 = _player.global_position
	InputManager.touch_vector = Vector2.RIGHT
	for i in 30:
		await get_tree().physics_frame
	InputManager.touch_vector = Vector2.ZERO
	var moved: Vector2 = _player.global_position - before
	_check(moved.x > 10.0 and absf(moved.y) < absf(moved.x),
			"有摇杆输入时自动接近让位（位移 %.0f, %.0f）" % [moved.x, moved.y])


func _test_keyboard_bindings() -> void:
	_clear_enemies()
	await get_tree().physics_frame
	await _ensure_player_alive()
	_player.global_position = _map.spawn_world_position()
	_player.velocity = Vector2.ZERO
	InputManager.touch_vector = Vector2.ZERO
	await get_tree().physics_frame

	var target = _spawn_static_enemy(Vector2(0.0, 40.0))
	await get_tree().physics_frame
	_check(_player.cycle_lock_target(), "键盘测试：先锁定近身目标")

	# SPACE -> 攻击（与 ATK 按钮完全等价）
	var hp_before: int = target.get_hp()
	_send_key(KEY_SPACE, true)
	for i in 3:
		await get_tree().physics_frame
	_send_key(KEY_SPACE, false)
	for i in 3:
		await get_tree().physics_frame
	_check(target.get_hp() < hp_before, "SPACE 键触发攻击（%d -> %d）" % [hp_before, target.get_hp()])

	# F 按住 -> 进入选择模式；松开 -> 退出并确认
	_send_key(KEY_F, true)
	for i in 4:
		await get_tree().physics_frame
	_check(_player.is_selecting(), "F 键按住进入目标选择模式")
	_send_key(KEY_F, false)
	for i in 4:
		await get_tree().physics_frame
	_check(not _player.is_selecting(), "F 键松开退出目标选择模式")
	_check(_player.get_locked_target() == target, "F 键松开后保持原锁定目标")


func _send_key(keycode: int, pressed: bool) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = keycode
	event.pressed = pressed
	Input.parse_input_event(event)


func _test_death_and_respawn() -> void:
	_clear_enemies()
	await get_tree().physics_frame
	await _ensure_player_alive()
	var spawn: Vector2 = _map.spawn_world_position()
	_player.global_position = spawn
	for i in 30:
		await get_tree().physics_frame

	_player.take_damage(9999)
	await get_tree().physics_frame
	_check(not _player.is_alive(), "致死伤害后玩家进入死亡状态")

	var respawned := false
	for i in 180:
		await get_tree().physics_frame
		if _player.is_alive():
			respawned = true
			break
	_check(respawned, "2 秒后自动复活")
	_check(_player.global_position.distance_to(spawn) < 2.0,
			"复活位置回到出生点（偏差 %.2f）" % _player.global_position.distance_to(spawn))
	_check(_player.get_hp() == _player.get_max_hp(),
			"复活后满血（%d/%d）" % [_player.get_hp(), _player.get_max_hp()])


func _clear_enemies() -> void:
	for enemy: Node in get_tree().get_nodes_in_group("enemies"):
		enemy.queue_free()


func _ensure_player_alive() -> void:
	var guard := 0
	while not _player.is_alive() and guard < 300:
		await get_tree().physics_frame
		guard += 1
	_player.heal_to_full()
	await get_tree().physics_frame


func _on_enemy_died(enemy_id: String) -> void:
	_enemy_deaths.append(enemy_id)


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
