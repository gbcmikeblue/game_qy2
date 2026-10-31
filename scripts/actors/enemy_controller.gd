extends CharacterBody2D
class_name EnemyController

## 敌人：显式状态机 + 网格寻路。AI 不碰 UI、不改进背包等其它模块的数据。
## 排序保持阶段 A 的约定：节点 position 的 y 即脚底，父级 y_sort 处理遮挡。

enum State { IDLE, PATROL, CHASE, ATTACK, HURT, RETURN, DEAD }

const ATTACK_WINDUP := 0.22
const ATTACK_RECOVER := 0.18
const HURT_DURATION := 0.18
const PATH_REFRESH_INTERVAL := 0.25
const PATH_REFRESH_DISTANCE := 32.0
const WAYPOINT_REACHED := 10.0
const HOME_REACHED := 12.0
const DEATH_LINGER := 0.7
const ACCELERATION := 1200.0

var enemy_id := ""
var def: Dictionary = {}
var home_cell := Vector2i.ZERO
var state: int = State.IDLE

# 从配置展开的属性，避免每帧查字典。
var max_hp := 40.0
var attack := 10.0
var defense := 0.0
var move_speed := 90.0
var attack_range := 48.0
var attack_cooldown := 1.2
var aggro_radius := 220.0
var deaggro_radius := 360.0
var patrol_radius := 70.0

var _map
var _health: HealthComponent
var _visual: Node2D
var _rng := RandomNumberGenerator.new()

var _state_time := 0.0
var _hurt_left := 0.0
var _cooldown_left := 0.0
var _patrol_wait := 1.5
var _patrol_target := Vector2.ZERO
var _path: Array[Vector2i] = []
var _path_index := 0
var _path_timer := 0.0
var _path_anchor := Vector2.ZERO
var _attack_hit := false
var _dead_timer := 0.0
var _facing := Vector2.DOWN


func setup(p_id: String, p_cell: Vector2i, p_map) -> void:
	enemy_id = p_id
	home_cell = p_cell
	_map = p_map
	def = DataRegistry.get_enemy_def(p_id)
	if def.is_empty():
		push_error("未知敌人类型: %s" % p_id)


func _ready() -> void:
	add_to_group("enemies")
	_apply_def()
	position = Iso.grid_to_world(home_cell)
	_health = get_node("Health") as HealthComponent
	_visual = get_node("Visual") as Node2D
	_health.setup(int(max_hp))
	_health.died.connect(_on_died)
	_health.hp_changed.connect(_on_hp_changed)
	if _visual != null and _visual.has_method("configure"):
		_visual.configure(def)
	_apply_body_radius(float(def.get("body_radius", 11.0)))
	_on_hp_changed(int(max_hp), int(max_hp))
	_patrol_wait = randf_range(0.8, 2.2)


func is_alive() -> bool:
	return state != State.DEAD


func get_hp() -> int:
	return _health.hp if _health != null else 0


func get_max_hp() -> int:
	return _health.max_hp if _health != null else int(max_hp)


func get_state_name() -> String:
	return String(State.keys()[state])


## 目标类型（决定主操作按钮文案）：配置里没写就是怪物。
func get_target_kind() -> String:
	return String(def.get("kind", "monster"))


## 由玩家控制器调用：被选中时高亮，取消选中/死亡时取消高亮。
func set_locked(value: bool) -> void:
	if _visual != null and _visual.has_method("set_locked"):
		_visual.set_locked(value)


func take_damage(amount: int, _source: Node = null) -> bool:
	if state == State.DEAD:
		return false
	var applied := _health.take_damage(amount)
	if applied <= 0:
		return false
	if _visual != null and _visual.has_method("flash"):
		_visual.flash()
	if state != State.DEAD:
		_hurt_left = HURT_DURATION
		_set_state(State.HURT)
	return true


func _apply_def() -> void:
	max_hp = float(def.get("max_hp", 40))
	attack = float(def.get("attack", 10))
	defense = float(def.get("defense", 0))
	move_speed = float(def.get("move_speed", 90))
	attack_range = float(def.get("attack_range", 48))
	attack_cooldown = float(def.get("attack_cooldown", 1.2))
	aggro_radius = float(def.get("aggro_radius", 220))
	deaggro_radius = float(def.get("deaggro_radius", 360))
	patrol_radius = float(def.get("patrol_radius", 70))


func _apply_body_radius(radius: float) -> void:
	var collision := get_node_or_null("Collision") as CollisionShape2D
	if collision == null:
		return
	var circle := collision.shape as CircleShape2D
	if circle != null:
		circle.radius = radius


func _physics_process(delta: float) -> void:
	if state == State.DEAD:
		_dead_timer -= delta
		if _dead_timer <= 0.0:
			queue_free()
		return

	_state_time += delta
	_cooldown_left = maxf(0.0, _cooldown_left - delta)

	match state:
		State.IDLE:
			_tick_idle(delta)
		State.PATROL:
			_tick_patrol(delta)
		State.CHASE:
			_tick_chase(delta)
		State.ATTACK:
			_tick_attack(delta)
		State.HURT:
			_tick_hurt(delta)
		State.RETURN:
			_tick_return(delta)


func _tick_idle(delta: float) -> void:
	velocity = velocity.move_toward(Vector2.ZERO, ACCELERATION * delta)
	move_and_slide()
	if _find_target():
		return
	_patrol_wait -= delta
	if _patrol_wait <= 0.0:
		_set_state(State.PATROL)


func _tick_patrol(delta: float) -> void:
	if _find_target():
		return
	if global_position.distance_to(_patrol_target) < WAYPOINT_REACHED:
		_set_state(State.IDLE)
		return
	_move_towards(_patrol_target, move_speed * 0.6, delta)


func _tick_chase(delta: float) -> void:
	if not _is_target_valid() or _distance_to_target() > deaggro_radius:
		_set_state(State.RETURN)
		return
	if _distance_to_target() <= attack_range and _cooldown_left <= 0.0:
		_set_state(State.ATTACK)
		return
	_follow_target(delta)


func _tick_attack(delta: float) -> void:
	velocity = velocity.move_toward(Vector2.ZERO, ACCELERATION * delta)
	move_and_slide()
	if not _attack_hit and _state_time >= ATTACK_WINDUP:
		_attack_hit = true
		_deal_damage()
	if _state_time >= ATTACK_WINDUP + ATTACK_RECOVER:
		_cooldown_left = attack_cooldown
		_set_state(State.CHASE if _is_target_valid() else State.RETURN)


func _tick_hurt(delta: float) -> void:
	_hurt_left -= delta
	velocity = velocity.move_toward(Vector2.ZERO, ACCELERATION * delta)
	move_and_slide()
	if _hurt_left <= 0.0:
		_set_state(State.CHASE if _is_target_valid() else State.RETURN)


func _tick_return(delta: float) -> void:
	if _find_target():
		return
	var home := Iso.grid_to_world(home_cell)
	if global_position.distance_to(home) < HOME_REACHED:
		_set_state(State.IDLE)
		return
	_move_towards(home, move_speed * 0.8, delta)


func _set_state(next: int) -> void:
	if state == next:
		return
	state = next
	_state_time = 0.0
	match next:
		State.IDLE:
			velocity = Vector2.ZERO
			_patrol_wait = randf_range(0.8, 2.2)
		State.PATROL:
			_pick_patrol_point()
		State.CHASE:
			_path.clear()
			_path_index = 0
			_path_timer = 0.0
		State.ATTACK:
			_attack_hit = false
			velocity = Vector2.ZERO
		State.HURT:
			_hurt_left = HURT_DURATION
			velocity = Vector2.ZERO
		State.RETURN:
			_path.clear()
			_path_index = 0
			_path_timer = 0.0


func _pick_patrol_point() -> void:
	var angle := randf() * TAU
	var distance := randf_range(patrol_radius * 0.4, patrol_radius)
	var offset := Vector2(cos(angle), sin(angle)) * distance
	_patrol_target = Iso.grid_to_world(home_cell) + offset


func _follow_target(delta: float) -> void:
	var target := _get_target()
	if target == null:
		return
	_path_timer -= delta
	if _path_timer <= 0.0 or _path.is_empty() or _path_anchor.distance_to(target.global_position) > PATH_REFRESH_DISTANCE:
		_path_timer = PATH_REFRESH_INTERVAL
		_path_anchor = target.global_position
		_refresh_path(Iso.world_to_grid(target.global_position))

	var goal := target.global_position
	if not _path.is_empty() and _path_index < _path.size():
		goal = Iso.grid_to_world(_path[_path_index])
		if global_position.distance_to(goal) < WAYPOINT_REACHED:
			_path_index += 1
			goal = target.global_position if _path_index >= _path.size() else Iso.grid_to_world(_path[_path_index])

	_move_towards(goal, move_speed, delta)


func _refresh_path(goal_cell: Vector2i) -> void:
	var from := Iso.world_to_grid(global_position)
	_path = _map.get_pathfinder().find_path(from, goal_cell) if _map != null else ([] as Array[Vector2i])
	_path_index = 0
	# 路径首格是当前所在格，跳过避免原地打转。
	if _path.size() > 1:
		_path_index = 1


func _move_towards(goal: Vector2, speed: float, delta: float) -> void:
	var direction := goal - global_position
	if direction.length() > 2.0:
		direction = direction.normalized()
		_facing = direction
		velocity = velocity.move_toward(direction * speed, ACCELERATION * delta)
	else:
		velocity = velocity.move_toward(Vector2.ZERO, ACCELERATION * delta)
	move_and_slide()


func _deal_damage() -> void:
	var target := _get_target()
	if target == null:
		return
	# 命中/距离/暴击/被拒绝全部交给 CombatService，与玩家共用同一套规则。
	CombatService.strike(self, target, {
		"attack": attack,
		"max_range": attack_range,
		"range_tolerance": 1.25,
	})


func _find_target() -> bool:
	if not _is_target_valid():
		return false
	if _distance_to_target() > aggro_radius:
		return false
	_set_state(State.CHASE)
	return true


## 目标玩家统一从 GameManager 查询：联机时替换查询实现即可，AI 逻辑不用动。
func _get_target() -> Node2D:
	return GameManager.get_player()


func _is_target_valid() -> bool:
	var target := _get_target()
	if target == null or not is_instance_valid(target):
		return false
	return target.is_alive()


func _distance_to_target() -> float:
	var target := _get_target()
	if target == null or not is_instance_valid(target):
		return INF
	return global_position.distance_to(target.global_position)


func _on_hp_changed(current: int, maximum: int) -> void:
	if _visual != null and _visual.has_method("set_health"):
		_visual.set_health(current, maximum)


func _on_died() -> void:
	state = State.DEAD
	_state_time = 0.0
	_dead_timer = DEATH_LINGER
	velocity = Vector2.ZERO
	set_deferred("collision_layer", 0)
	set_deferred("collision_mask", 0)
	if _visual != null and _visual.has_method("set_dead"):
		_visual.set_dead(true)
	if _visual != null and _visual.has_method("set_locked"):
		_visual.set_locked(false)
	remove_from_group("enemies")
	EventBus.enemy_died.emit(enemy_id)
	# 掉落服务据此生成地面物并结算金币/经验（携带死亡坐标）。
	EventBus.enemy_defeated.emit(enemy_id, global_position)
