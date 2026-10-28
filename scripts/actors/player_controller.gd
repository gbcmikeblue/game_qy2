extends CharacterBody2D

## 玩家：移动 + 锁定式攻击（屏幕内候选 + 自动接近） + 受击/死亡/复活。
##
## 目标选择交互（按住目标按钮 + 甩动摇杆）：
## 1. 按住按钮 -> 进入选择模式，摇杆不再驱动移动，改由甩动方向切换“预览目标”；
##    预览初始为当前锁定目标，没有锁定时取屏幕内最近目标。
## 2. 甩动方向与候选方位的夹角取最小者（<= select_max_angle_deg）；同一方向按住不会
##    重复切换（需回中位或换一个夹角 > select_sector_deg 的方向），并有 select_cooldown 间隔。
## 3. 松开按钮 -> 预览目标成为新的锁定目标；没有可切换目标时保持原选择不变。
## 4. 遮挡不作为筛选条件：只要目标在可见安全矩形内就可选中，被建筑挡住也允许。
## 5. 攻击（ATK 按钮 / 空格）保持独立，始终作用于已确认的锁定目标。
##
## 候选范围规则：可见安全矩形 = 视口矩形向内收缩 lock_screen_margin 像素，
## 世界坐标由相机 canvas_transform 反投影得到；该矩形每帧现算，相机滚动/缩放/窗口变化即时生效。

const HURT_INVULN := 0.3
const RESPAWN_DELAY := 2.0
const RESPAWN_INVULN := 1.0

## 自动接近：路径重算与卡住判定参数
const APPROACH_PATH_INTERVAL := 0.3
const APPROACH_PATH_DISTANCE := 32.0
const APPROACH_WAYPOINT_REACHED := 12.0
const APPROACH_STALL_TIME := 1.0
const APPROACH_STALL_PROGRESS := 10.0

@export var max_speed := 150.0
@export var acceleration := 1400.0
@export var deceleration := 1800.0

var spawn_point := Vector2.ZERO

var max_hp := 120
var attack := 20.0
var defense := 5.0
var crit_rate := 0.1
var crit_damage := 1.5

var attack_range := 72.0
var attack_cooldown := 0.45
var turn_rate := 12.0
var lock_screen_margin := 48.0
var lock_release_margin := 0.0
var auto_approach := true
var approach_stop_ratio := 0.85

var select_deadzone := 0.45
var select_max_angle_deg := 75.0
var select_sector_deg := 35.0
var select_cooldown := 0.18

var _health: HealthComponent
var _visual: Node2D
var _map
var _rng := RandomNumberGenerator.new()
var _facing := Vector2.DOWN
var _cooldown_left := 0.0
var _invuln_left := 0.0
var _respawn_left := 0.0
var _dead := false
var _locked: EnemyController = null

var _path: Array[Vector2i] = []
var _path_index := 0
var _path_timer := 0.0
var _path_anchor := Vector2.ZERO
var _approach_stalled := false
var _approach_time := 0.0
var _approach_best := INF

var _selecting := false
var _preview: EnemyController = null
var _select_direction := Vector2.ZERO
var _select_neutral := true
var _select_cooldown_left := 0.0


func _ready() -> void:
	motion_mode = CharacterBody2D.MOTION_MODE_FLOATING
	collision_layer = PhysLayers.PLAYER
	collision_mask = PhysLayers.WORLD | PhysLayers.ENEMY
	_rng.randomize()
	_apply_def()
	_health = get_node("Health") as HealthComponent
	_visual = get_node("Visual") as Node2D
	_health.setup(max_hp)
	_health.died.connect(_on_died)
	_health.hp_changed.connect(_on_hp_changed)
	EventBus.attack_requested.connect(_on_attack_requested)
	EventBus.target_select_pressed.connect(_on_target_select_pressed)
	EventBus.target_select_released.connect(_on_target_select_released)


func _exit_tree() -> void:
	if EventBus.attack_requested.is_connected(_on_attack_requested):
		EventBus.attack_requested.disconnect(_on_attack_requested)
	if EventBus.target_select_pressed.is_connected(_on_target_select_pressed):
		EventBus.target_select_pressed.disconnect(_on_target_select_pressed)
	if EventBus.target_select_released.is_connected(_on_target_select_released):
		EventBus.target_select_released.disconnect(_on_target_select_released)
	_cancel_selection()
	_set_locked_target(null)


## 由 main.gd 注入，用于锁定后的自动接近寻路。
func setup_navigation(map) -> void:
	_map = map


func is_alive() -> bool:
	return not _dead


func get_hp() -> int:
	return _health.hp if _health != null else 0


func get_max_hp() -> int:
	return _health.max_hp if _health != null else max_hp


func get_defense() -> float:
	return defense


func get_facing() -> Vector2:
	return _facing


func heal_to_full() -> void:
	if _health != null:
		_health.reset_full()


# ---------------- 可见范围 ----------------

## 锁定候选判定用的屏幕矩形（像素）：视口内部收缩 lock_screen_margin。
func get_lock_screen_rect() -> Rect2:
	return Rect2(Vector2.ZERO, get_viewport_rect().size).grow(-lock_screen_margin)


## 同一矩形反投影到世界坐标，便于调试与测试摆位。
func get_lock_view_rect() -> Rect2:
	var inverse := get_viewport().get_canvas_transform().affine_inverse()
	var top_left := inverse * Vector2.ZERO
	var bottom_right := inverse * get_viewport_rect().size
	return Rect2(top_left, bottom_right - top_left).abs()


## 遮挡不参与判定：只看是否落在屏幕安全矩形内。
func is_position_locked_view(world_position: Vector2, margin: float) -> bool:
	var screen := get_viewport().get_canvas_transform() * world_position
	return Rect2(Vector2.ZERO, get_viewport_rect().size).grow(-margin).has_point(screen)


# ---------------- 锁定目标 ----------------

func get_locked_target() -> EnemyController:
	if _has_valid_lock():
		return _locked
	return null


func get_preview_target() -> EnemyController:
	return _preview if is_instance_valid(_preview) else null


func is_selecting() -> bool:
	return _selecting


## 当前屏幕内所有可攻击目标，按距离由近到远。
func lock_targets() -> Array:
	var candidates: Array = []
	for node: Node in get_tree().get_nodes_in_group("enemies"):
		if not (node is EnemyController):
			continue
		var enemy := node as EnemyController
		if not enemy.is_alive():
			continue
		if not is_position_locked_view(enemy.global_position, lock_screen_margin):
			continue
		candidates.append(enemy)
	candidates.sort_custom(func(a: EnemyController, b: EnemyController) -> bool:
		return global_position.distance_to(a.global_position) < global_position.distance_to(b.global_position)
	)
	return candidates


func has_lock_targets() -> bool:
	return not lock_targets().is_empty()


## 顺序切换（脚本/测试用的程序接口；UI 走“按住 + 甩动”流程）。
func cycle_lock_target(targets: Array = []) -> bool:
	var candidates: Array = targets if not targets.is_empty() else lock_targets()
	if candidates.is_empty():
		_set_locked_target(null)
		return false
	var index := candidates.find(_locked)
	var next: EnemyController = candidates[0] if index < 0 else candidates[(index + 1) % candidates.size()]
	_set_locked_target(next)
	return true


## 供 HUD 展示锁定/选择状态。
func get_lock_summary() -> Dictionary:
	var candidates := lock_targets()
	var target := get_locked_target()
	var preview := get_preview_target()
	return {
		"count": candidates.size(),
		"index": candidates.find(_locked) + 1 if target != null else 0,
		"name": _display_name_of(target),
		"selecting": _selecting,
		"preview_index": candidates.find(_preview) + 1 if preview != null else 0,
		"preview_name": _display_name_of(preview),
	}


func face_direction(direction: Vector2) -> void:
	if direction.length() < 0.01:
		return
	_facing = direction.normalized()
	if _visual != null and _visual.has_method("set_facing"):
		_visual.set_facing(_facing)


## 挥击一次：返回命中数（0 或 1，锁定机制下每次只结算当前目标）。
## 选择目标期间（按住目标按钮）不响应任何攻击请求，保证按目标按钮绝不会打出伤害。
func try_attack() -> int:
	if _dead or _cooldown_left > 0.0 or _selecting:
		return 0
	_cooldown_left = attack_cooldown

	if not _has_valid_lock():
		_set_locked_target(_nearest_target())
	if not _has_valid_lock():
		return 0

	var target := _locked
	if global_position.distance_to(target.global_position) > attack_range:
		return 0

	var result := CombatMath.compute_damage(attack, 1.0, target.defense, crit_rate, crit_damage, _rng)
	var damage := int(result["damage"])
	if not target.take_damage(damage, self):
		return 0
	CombatFx.show_damage(target.global_position, damage, bool(result["is_crit"]))
	return 1


func take_damage(amount: int, _source: Node = null) -> void:
	if _dead or _invuln_left > 0.0:
		return
	var applied := _health.take_damage(amount)
	if applied <= 0:
		return
	_invuln_left = HURT_INVULN
	if _visual != null and _visual.has_method("flash"):
		_visual.flash()
	CombatFx.show_hurt(global_position, applied)


func _physics_process(delta: float) -> void:
	_cooldown_left = maxf(0.0, _cooldown_left - delta)
	_invuln_left = maxf(0.0, _invuln_left - delta)

	if _dead:
		_respawn_left -= delta
		velocity = Vector2.ZERO
		if _respawn_left <= 0.0:
			_respawn()
		return

	_drop_invalid_lock()

	# 选择模式下摇杆归选择流程，角色停下，不参与移动与自动接近。
	if _selecting:
		_tick_selection(delta)
		velocity = velocity.move_toward(Vector2.ZERO, deceleration * delta)
		move_and_slide()
		var focus := get_preview_target()
		_turn_towards(focus.global_position if focus != null else _facing_point(), delta)
		return

	var direction: Vector2 = InputManager.move_vector
	if direction.length() > 1.0:
		direction = direction.normalized()

	if direction.length() > 0.05:
		# 玩家主动操作优先：重置自动接近状态，让位给手动移动。
		_reset_approach_state()
	elif _should_auto_approach():
		direction = _approach_direction(delta)
		_update_approach_progress(delta)

	# 有锁定时朝向始终平滑跟随目标，攻击指向与锁定状态保持一致。
	if _has_valid_lock():
		_turn_towards(_locked.global_position, delta)
	elif direction.length() > 0.01:
		face_direction(direction)

	var target_speed := direction * max_speed
	var rate := acceleration if direction.length() > 0.01 else deceleration
	velocity = velocity.move_toward(target_speed, rate * delta)
	move_and_slide()


# ---------------- 目标选择（按住 + 甩动摇杆） ----------------

## 按住目标按钮：进入选择模式。返回是否找到可预览的目标。
func begin_target_selection() -> bool:
	if _dead:
		return false
	var candidates := lock_targets()
	if candidates.is_empty():
		# 没有可切换目标时不进入选择模式，当前选择与攻击行为都不受影响。
		_cancel_selection()
		return false
	_selecting = true
	_select_neutral = true
	_select_cooldown_left = 0.0
	_reset_approach_state()
	var initial: EnemyController = _locked if candidates.has(_locked) else candidates[0]
	_set_preview(initial)
	return true


## 松开目标按钮：确认预览目标。无可切换目标时保持原选择不变。
func end_target_selection() -> void:
	if not _selecting:
		return
	_selecting = false
	var confirmed := _preview
	_clear_preview()
	if is_instance_valid(confirmed) and confirmed.is_alive() and _is_candidate(confirmed):
		_set_locked_target(confirmed)


func _tick_selection(delta: float) -> void:
	_select_cooldown_left = maxf(0.0, _select_cooldown_left - delta)

	# 预览目标失效（死亡/离开屏幕）时清掉预览，避免指向无效对象。
	if _preview != null and not _is_candidate(_preview):
		_clear_preview()

	var direction: Vector2 = InputManager.move_vector
	if direction.length() < select_deadzone:
		_select_neutral = true
		return
	if _select_cooldown_left > 0.0:
		return
	if not _select_neutral and absf(_select_direction.angle_to(direction)) < deg_to_rad(select_sector_deg):
		# 同一方向持续按住不重复切换，避免目标一路乱跳。
		return

	_select_neutral = false
	_select_direction = direction.normalized()
	_select_cooldown_left = select_cooldown
	var next := _pick_candidate_in_direction(_select_direction)
	if next != null and next != _preview:
		_set_preview(next)


## 取与甩动方向夹角最小的候选；都超出角度窗口时返回 null（保持当前选择）。
func _pick_candidate_in_direction(direction: Vector2) -> EnemyController:
	var candidates := lock_targets()
	if candidates.is_empty():
		return null
	var best: EnemyController = null
	var best_dot := cos(deg_to_rad(select_max_angle_deg))
	for enemy: EnemyController in candidates:
		var offset := enemy.global_position - global_position
		if offset.length() < 0.01:
			continue
		var dot := offset.normalized().dot(direction)
		if dot > best_dot:
			best = enemy
			best_dot = dot
	return best


func _is_candidate(enemy: EnemyController) -> bool:
	if not is_instance_valid(enemy) or not enemy.is_alive():
		return false
	return is_position_locked_view(enemy.global_position, lock_screen_margin)


func _set_preview(enemy: EnemyController) -> void:
	if _preview == enemy:
		return
	if is_instance_valid(_preview) and _preview.has_method("set_preview"):
		_preview.set_preview(false)
	_preview = enemy
	if is_instance_valid(_preview) and _preview.has_method("set_preview"):
		_preview.set_preview(true)


func _clear_preview() -> void:
	_set_preview(null)


func _cancel_selection() -> void:
	_selecting = false
	_clear_preview()


func _facing_point() -> Vector2:
	return global_position + _facing * 32.0


# ---------------- 自动接近 ----------------

func _should_auto_approach() -> bool:
	if not auto_approach or _approach_stalled or not _has_valid_lock():
		return false
	return global_position.distance_to(_locked.global_position) > attack_range * approach_stop_ratio


func _approach_direction(delta: float) -> Vector2:
	var target_position := _locked.global_position
	if _map == null:
		var straight := target_position - global_position
		return straight.normalized() if straight.length() > 0.5 else Vector2.ZERO

	_path_timer -= delta
	if _path_timer <= 0.0 or _path.is_empty() or _path_anchor.distance_to(target_position) > APPROACH_PATH_DISTANCE:
		_path_timer = APPROACH_PATH_INTERVAL
		_path_anchor = target_position
		_path = _map.get_pathfinder().find_path(
			Iso.world_to_grid(global_position), Iso.world_to_grid(target_position)
		)
		_path_index = 1 if _path.size() > 1 else 0

	var goal := target_position
	if _path_index < _path.size():
		goal = Iso.grid_to_world(_path[_path_index])
		if global_position.distance_to(goal) < APPROACH_WAYPOINT_REACHED:
			_path_index += 1
			goal = target_position if _path_index >= _path.size() else Iso.grid_to_world(_path[_path_index])

	var direction := goal - global_position
	if direction.length() < 0.5:
		return Vector2.ZERO
	return direction.normalized()


func _update_approach_progress(delta: float) -> void:
	_approach_time += delta
	var distance := global_position.distance_to(_locked.global_position)
	if distance < _approach_best - APPROACH_STALL_PROGRESS:
		_approach_best = distance
		_approach_time = 0.0
	elif _approach_time > APPROACH_STALL_TIME:
		# 被墙或不可达地形卡住：停止自动接近，避免角色贴墙打转。
		_approach_stalled = true
		_reset_approach_path()


func _reset_approach_state() -> void:
	_approach_stalled = false
	_approach_time = 0.0
	_approach_best = INF


func _reset_approach_path() -> void:
	_path.clear()
	_path_index = 0
	_path_timer = 0.0


func _turn_towards(point: Vector2, delta: float) -> void:
	var offset := point - global_position
	if offset.length() < 0.01:
		return
	var next_angle := lerp_angle(_facing.angle(), offset.angle(), clampf(turn_rate * delta, 0.0, 1.0))
	_facing = Vector2.from_angle(next_angle)
	if _visual != null and _visual.has_method("set_facing"):
		_visual.set_facing(_facing)


func _nearest_target() -> EnemyController:
	var candidates := lock_targets()
	return candidates[0] if not candidates.is_empty() else null


func _has_valid_lock() -> bool:
	return is_instance_valid(_locked) and _locked.is_alive()


## 解锁条件：目标死亡，或目标离开视口边界（用更宽松的释放边距，避免贴边抖动）。
func _drop_invalid_lock() -> void:
	if _locked == null:
		return
	if not is_instance_valid(_locked) or not _locked.is_alive():
		_set_locked_target(null)
		return
	if not is_position_locked_view(_locked.global_position, lock_release_margin):
		_set_locked_target(null)


func _set_locked_target(enemy: EnemyController) -> void:
	if _locked == enemy:
		return
	if is_instance_valid(_locked) and _locked.has_method("set_locked"):
		_locked.set_locked(false)
	_locked = enemy
	if is_instance_valid(_locked) and _locked.has_method("set_locked"):
		_locked.set_locked(true)
	_reset_approach_state()
	_reset_approach_path()


func _display_name_of(enemy: EnemyController) -> String:
	if not is_instance_valid(enemy):
		return "-"
	if not enemy.def.is_empty():
		return String(enemy.def.get("display_name", enemy.enemy_id))
	return enemy.enemy_id


func _apply_def() -> void:
	var def := DataRegistry.get_player_def()
	max_hp = int(def.get("max_hp", max_hp))
	attack = float(def.get("attack", attack))
	defense = float(def.get("defense", defense))
	crit_rate = float(def.get("crit_rate", crit_rate))
	crit_damage = float(def.get("crit_damage", crit_damage))
	max_speed = float(def.get("move_speed", max_speed))
	attack_range = float(def.get("attack_range", attack_range))
	attack_cooldown = float(def.get("attack_cooldown", attack_cooldown))
	turn_rate = float(def.get("turn_rate", turn_rate))
	lock_screen_margin = float(def.get("lock_screen_margin", lock_screen_margin))
	lock_release_margin = float(def.get("lock_release_margin", lock_release_margin))
	auto_approach = bool(def.get("auto_approach", auto_approach))
	approach_stop_ratio = float(def.get("approach_stop_ratio", approach_stop_ratio))
	select_deadzone = float(def.get("select_deadzone", select_deadzone))
	select_max_angle_deg = float(def.get("select_max_angle_deg", select_max_angle_deg))
	select_sector_deg = float(def.get("select_sector_deg", select_sector_deg))
	select_cooldown = float(def.get("select_cooldown", select_cooldown))


func _on_attack_requested() -> void:
	try_attack()


func _on_target_select_pressed() -> void:
	begin_target_selection()


func _on_target_select_released() -> void:
	end_target_selection()


func _on_hp_changed(current: int, maximum: int) -> void:
	if _visual != null and _visual.has_method("set_health"):
		_visual.set_health(current, maximum)


func _on_died() -> void:
	_dead = true
	_respawn_left = RESPAWN_DELAY
	velocity = Vector2.ZERO
	_cancel_selection()
	_set_locked_target(null)
	set_deferred("collision_layer", 0)
	set_deferred("collision_mask", 0)
	if _visual != null and _visual.has_method("set_dead"):
		_visual.set_dead(true)
	EventBus.player_died.emit()


func _respawn() -> void:
	global_position = spawn_point
	_health.reset_full()
	_dead = false
	_invuln_left = RESPAWN_INVULN
	set_deferred("collision_layer", PhysLayers.PLAYER)
	set_deferred("collision_mask", PhysLayers.WORLD | PhysLayers.ENEMY)
	if _visual != null and _visual.has_method("set_dead"):
		_visual.set_dead(false)
	EventBus.player_respawned.emit()
