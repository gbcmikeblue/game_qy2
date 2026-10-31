extends CharacterBody2D

## 玩家：移动 + 点选目标 + 锁定式攻击 + 受击/死亡/复活。
##
## 选中与攻击完全分离（本文件是这两条链路的唯一边界）：
## 1. 选中：外部（点击/点触的世界拾取器）调用 select_target()/clear_selection()，
##    这里只维护"当前选中目标"与它的高亮，不产生任何伤害、不触发任何攻击。
## 2. 攻击：只由 attack_requested（ATK 按钮 / 攻击键）触发，作用于当前选中目标；
##    没有选中目标时攻击不会自动选目标，只空挥。
## 3. 自动接近：只有"按攻击键且选中目标在攻击距离外"才开启；摇杆、技能、暂停、
##    目标失效都会立刻关闭，且不会自行恢复。
##
## 候选范围：目标脚底落在"视口矩形向内收缩 lock_screen_margin"的区域（每帧实时计算）。

## 受击/复活时序：数值在 data/actors/player.json，测试可注入更短的值来加速验收。
var hurt_invuln := 0.3
var respawn_delay := 2.0
var respawn_invuln := 1.0
## NPC 交互半径（与 NpcNode.INTERACT_RADIUS 保持一致）。
const INTERACT_RADIUS := 56.0
## 摇杆幅值超过该值即视为玩家主动操作，会打断自动接近。
const STICK_CANCEL_THRESHOLD := 0.2
## 非战斗交互（交互/采摘/观察）的飘字颜色。
const INTERACT_COLOR := Color(0.62, 0.9, 1.0)

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
## 魔法上限：阶段 C 只做属性预留，技能系统落地后才消耗（决策 N05）。
var max_mp := 30
## 当前魔法值与技能参数（数值在 player.json）。技能是 Q12 的 B 阶段首个主动技能。
var mp := 30
var mp_regen := 2.0
var skill_mp_cost := 10
var skill_cooldown := 3.0
var skill_multiplier := 2.2
var _skill_cd_left := 0.0
var _mp_frac := 0.0
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

## 持续攻击：长按秒数 / 连点次数（可在"设置 → 玩家战斗"里改，运行时实时生效）。
var auto_attack_hold_seconds := 0.8
var auto_attack_tap_count := 5
## 连点计数的滚动窗口（设计值，不进设置面板）。
var auto_attack_tap_window := 1.0
## 仇恨接管锁的保持时间：这段时间内该怪不再攻击就释放锁。
var aggro_latch_timeout := 4.0

var _health: HealthComponent
var _visual: Node2D
var _map
var _rng := RandomNumberGenerator.new()
var _facing := Vector2.DOWN
var _cooldown_left := 0.0
var _invuln_left := 0.0
var _respawn_left := 0.0
var _dead := false

## 当前选中的目标（等价于旧版本的"锁定目标"）。
var _locked: EnemyController = null

var _path: Array[Vector2i] = []
var _path_index := 0
var _path_timer := 0.0
var _path_anchor := Vector2.ZERO
var _approach_stalled := false
var _approach_time := 0.0
var _approach_best := INF

## 自动接近开关：只有「按攻击键且目标在攻击距离外」才会打开；
## 摇杆、技能键、暂停、目标失效或切换都会立刻关闭。
var _approach_enabled := false

## ---- 持续攻击状态 ----
var _auto_attack := false
var _hold_time := 0.0
var _ui_attack_held := false
var _tap_times: Array[float] = []
var _clock := 0.0

## ---- 仇恨接管：第一只攻击玩家的怪 ----
var _aggro_latch: EnemyController = null
var _aggro_latch_left := 0.0


func _ready() -> void:
	motion_mode = CharacterBody2D.MOTION_MODE_FLOATING
	collision_layer = PhysLayers.PLAYER
	collision_mask = PhysLayers.WORLD | PhysLayers.ENEMY
	_rng.randomize()
	_apply_def()
	_health = get_node("Health") as HealthComponent
	_visual = get_node("Visual") as Node2D
	# 属性以 InventoryService.stats() 为准（基础值 + 等级成长 + 装备加成）。
	_sync_stats_from_inventory()
	_health.setup(int(max_hp))
	_health.died.connect(_on_died)
	_health.hp_changed.connect(_on_hp_changed)
	_apply_combat_settings()


## 信号在 enter_tree 里接、exit_tree 里断：
## 换图会把玩家从旧地图摘下再挂到新地图，这会触发 exit/enter tree，
## 而 _ready 只跑一次——如果只在 _ready 接线，换图后攻击按钮就再也没反应了。
func _enter_tree() -> void:
	_connect_events()


func _connect_events() -> void:
	if not EventBus.attack_requested.is_connected(_on_attack_requested):
		EventBus.attack_requested.connect(_on_attack_requested)
	if not EventBus.attack_pressed.is_connected(_on_attack_pressed):
		EventBus.attack_pressed.connect(_on_attack_pressed)
	if not EventBus.skill_requested.is_connected(_on_skill_requested):
		EventBus.skill_requested.connect(_on_skill_requested)
	if not EventBus.game_paused.is_connected(_on_game_paused):
		EventBus.game_paused.connect(_on_game_paused)
	if not EventBus.equipment_changed.is_connected(_on_stats_changed):
		EventBus.equipment_changed.connect(_on_stats_changed)
	if not EventBus.level_changed.is_connected(_on_stats_changed):
		EventBus.level_changed.connect(_on_stats_changed)
	if not GameSettings.combat_changed.is_connected(_apply_combat_settings):
		GameSettings.combat_changed.connect(_apply_combat_settings)


func _exit_tree() -> void:
	if EventBus.attack_requested.is_connected(_on_attack_requested):
		EventBus.attack_requested.disconnect(_on_attack_requested)
	if EventBus.attack_pressed.is_connected(_on_attack_pressed):
		EventBus.attack_pressed.disconnect(_on_attack_pressed)
	if GameSettings.combat_changed.is_connected(_apply_combat_settings):
		GameSettings.combat_changed.disconnect(_apply_combat_settings)
	if EventBus.skill_requested.is_connected(_on_skill_requested):
		EventBus.skill_requested.disconnect(_on_skill_requested)
	if EventBus.game_paused.is_connected(_on_game_paused):
		EventBus.game_paused.disconnect(_on_game_paused)
	if EventBus.equipment_changed.is_connected(_on_stats_changed):
		EventBus.equipment_changed.disconnect(_on_stats_changed)
	if EventBus.level_changed.is_connected(_on_stats_changed):
		EventBus.level_changed.disconnect(_on_stats_changed)
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


## 消耗品回血入口：由 UI 调用，扣物品在服务层完成。
func heal(amount: int) -> void:
	if _health != null and not _dead:
		_health.heal(amount)


## 读档恢复血量：不触发死亡判定，也不进入无敌帧。
func set_hp(value: int) -> void:
	if _health != null:
		_health.set_hp(value)


## 换图前清空锁定/仇恨残留：旧图的敌人马上要被释放，不能留下悬空引用。
func clear_targets() -> void:
	_set_locked_target(null)
	_aggro_latch = null
	_aggro_latch_left = 0.0
	cancel_auto_attack()
	cancel_auto_approach()


func get_mp() -> int:
	return mp


func get_skill_cooldown_left() -> float:
	return _skill_cd_left


## 主动技能：重击。消耗 MP、有冷却，伤害为普攻的 skill_multiplier 倍。
## 冷却与 MP 的判定放在真正结算之前，失败不扣蓝也不进冷却。
func try_skill() -> int:
	if _dead or not _has_valid_lock():
		return 0
	var target := _locked
	if not is_instance_valid(target) or not target.is_alive():
		return 0
	if _skill_cd_left > 0.0:
		CombatFx.show_text(global_position + Vector2(0.0, -44.0), Locale.t("skill.cooling"),
				Color(0.75, 0.75, 0.85))
		return 0
	if mp < skill_mp_cost:
		CombatFx.show_text(global_position + Vector2(0.0, -44.0), Locale.t("skill.no_mp"),
				Color(0.55, 0.65, 0.95))
		return 0
	if global_position.distance_to(target.global_position) > attack_range * 1.25:
		return 0

	var result := CombatService.strike(self, target, {
		"attack": attack * skill_multiplier,
		"crit_rate": crit_rate,
		"crit_damage": crit_damage,
		"rng": _rng,
		"max_range": attack_range * 1.25,
		"show_damage_fx": true,
	})
	if not bool(result["hit"]):
		return 0
	mp -= skill_mp_cost
	_skill_cd_left = skill_cooldown
	return 1


## 魔法回复：死亡时不回；累计小数部分，够 1 点才进位（避免每帧截断导致永远回不满）。
func _tick_mp(delta: float) -> void:
	_skill_cd_left = maxf(0.0, _skill_cd_left - delta)
	if _dead or mp >= max_mp:
		return
	_mp_frac += mp_regen * delta
	if _mp_frac < 1.0:
		return
	var gain := int(_mp_frac)
	_mp_frac -= float(gain)
	mp = mini(max_mp, mp + gain)


func get_max_mp() -> int:
	return max_mp


# ---------------- 可见范围 ----------------

## 候选判定用的屏幕矩形（像素）：视口内部收缩 lock_screen_margin。
func get_lock_screen_rect() -> Rect2:
	return Rect2(Vector2.ZERO, get_viewport_rect().size).grow(-lock_screen_margin)


## 同一矩形反投影到世界坐标，便于调试、测试摆位与点击拾取。
func get_lock_view_rect() -> Rect2:
	var inverse := get_viewport().get_canvas_transform().affine_inverse()
	var top_left := inverse * Vector2.ZERO
	var bottom_right := inverse * get_viewport_rect().size
	return Rect2(top_left, bottom_right - top_left).abs()


## 遮挡不参与判定：只看是否落在屏幕安全矩形内。
func is_position_locked_view(world_position: Vector2, margin: float) -> bool:
	var screen := get_viewport().get_canvas_transform() * world_position
	return Rect2(Vector2.ZERO, get_viewport_rect().size).grow(-margin).has_point(screen)


# ---------------- 选中目标 ----------------

## 当前选中的目标（无效时返回 null）。
func get_selected_target() -> EnemyController:
	if _has_valid_lock():
		return _locked
	return null


## 旧名保留，便于既有调用点与工具脚本平滑迁移。
func get_locked_target() -> EnemyController:
	return get_selected_target()


## 点击/点触选中：只改选中状态与高亮，绝不触发攻击。
## 目标必须存活且脚底在当前可见安全矩形内，否则返回 false。
## from_aggro=true 表示由"被攻击接管"驱动，此时不清除仇恨锁。
func select_target(enemy: EnemyController, from_aggro := false) -> bool:
	if _dead or not is_instance_valid(enemy) or not enemy.is_alive():
		return false
	if not is_position_locked_view(enemy.global_position, lock_screen_margin):
		return false
	if not from_aggro:
		clear_aggro_latch()
	_set_locked_target(enemy)
	return true


## 点击空白处 / 取消选中。
func clear_selection() -> void:
	_set_locked_target(null)


## 当前屏幕内所有可点选的目标，按距离由近到远。
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


## 主操作按钮的文案 key：由"选中目标的类型"决定（怪物=攻击 / NPC=交互 / 植物=采摘 / 玩家=观察）。
## 没有选中目标时回退到攻击，新增类型只需要改 data/targets/interactions.json。
func get_selected_action_key() -> String:
	var kind := "monster"
	if _has_valid_lock() and _locked.has_method("get_target_kind"):
		kind = _locked.get_target_kind()
	elif nearest_npc() != null:
		# 没锁定但站在 NPC 旁边：主操作按钮显示「交互」，与实际行为一致。
		kind = "npc"
	return DataRegistry.get_interaction_action(kind)


## 交互半径内最近的 NPC；没有则返回 null。
func nearest_npc() -> Node2D:
	var best: Node2D = null
	var best_distance := INTERACT_RADIUS
	for node: Node in get_tree().get_nodes_in_group("npcs"):
		if not (node is Node2D):
			continue
		var npc := node as Node2D
		var distance := global_position.distance_to(npc.global_position)
		if distance <= best_distance:
			best_distance = distance
			best = npc
	return best


## 供 HUD 展示选中状态。
func get_lock_summary() -> Dictionary:
	var candidates := lock_targets()
	var target := get_selected_target()
	return {
		"count": candidates.size(),
		"index": candidates.find(_locked) + 1 if target != null else 0,
		"name": _display_name_of(target),
	}


func face_direction(direction: Vector2) -> void:
	if direction.length() < 0.01:
		return
	_facing = direction.normalized()
	if _visual != null and _visual.has_method("set_facing"):
		_visual.set_facing(_facing)


## 主操作（ATK 按钮 / 攻击键）：统一入口，按"选中目标的类型"分发。
## - 目标超距：先自动接近（不消耗冷却，也不产生动作）
## - 归类为 action.attack（怪物，或未知类型回退）：走战斗结算
## - 其它类型（NPC/植物/玩家）：只广播 target_action_requested 并飘字，绝不造成伤害
## 返回 0 = 未执行，1 = 已执行。
func perform_action() -> int:
	if _dead:
		return 0

	if not _has_valid_lock():
		_set_locked_target(null)
		# 没有战斗目标时：靠近 NPC 按主操作即交互（NPC 不进锁定系统）。
		var npc := nearest_npc()
		if npc != null:
			cancel_auto_approach()
			EventBus.target_action_requested.emit(npc.get_target_kind(), npc)
			CombatFx.show_text(npc.global_position, Locale.t("action.interact"), INTERACT_COLOR)
			return 1
		return 0

	var target := _locked
	if global_position.distance_to(target.global_position) > attack_range:
		# 目标在攻击距离外：这次按键表示"走过去"，开启自动接近、不消耗冷却。
		_approach_enabled = true
		_reset_approach_state()
		return 0

	if _cooldown_left > 0.0:
		return 0

	_cooldown_left = attack_cooldown
	var kind := "monster"
	if target.has_method("get_target_kind"):
		kind = target.get_target_kind()
	var action_key := DataRegistry.get_interaction_action(kind)
	if action_key == "action.attack":
		return _resolve_attack(target)

	EventBus.target_action_requested.emit(kind, target)
	CombatFx.show_text(target.global_position, Locale.t(action_key), INTERACT_COLOR)
	return 1


## 兼容旧调用名（测试与工具脚本使用）。
func try_attack() -> int:
	return perform_action()


func _resolve_attack(target: EnemyController) -> int:
	# 控制器只负责「发起」；命中、暴击、伤害与飘字统一由 CombatService 结算。
	var result := CombatService.strike(self, target, {
		"attack": attack,
		"crit_rate": crit_rate,
		"crit_damage": crit_damage,
		"rng": _rng,
		"max_range": attack_range,
		"show_damage_fx": true,
	})
	return 1 if bool(result["hit"]) else 0


func take_damage(amount: int, source: Node = null) -> void:
	# 先记录"谁在攻击我"，再判断能不能真正扣血：
	# 复活无敌帧、受击保护期内攻击虽然不生效，但目标接管必须照常进行，
	# 否则复活后立刻挨打时会没有选中目标。
	_latch_attacker(source)
	if _dead or _invuln_left > 0.0:
		return
	var applied := _health.take_damage(amount)
	if applied <= 0:
		return
	_invuln_left = hurt_invuln
	if _visual != null and _visual.has_method("flash"):
		_visual.flash()
	CombatFx.show_hurt(global_position, applied)


func _physics_process(delta: float) -> void:
	_clock += delta
	_cooldown_left = maxf(0.0, _cooldown_left - delta)
	_invuln_left = maxf(0.0, _invuln_left - delta)
	_tick_mp(delta)

	if _dead:
		_respawn_left -= delta
		velocity = Vector2.ZERO
		if _respawn_left <= 0.0:
			_respawn()
		return

	_drop_invalid_lock()
	_tick_aggro_latch(delta)

	var direction: Vector2 = InputManager.move_vector
	if direction.length() > 1.0:
		direction = direction.normalized()

	if direction.length() > STICK_CANCEL_THRESHOLD:
		# 摇杆一动就打断自动接近与持续攻击，松手后不会自己恢复。
		cancel_auto_approach()
		cancel_auto_attack()
	elif _should_auto_approach():
		direction = _approach_direction(delta)
		_update_approach_progress(delta)

	# 有选中目标时朝向始终平滑跟随，攻击指向与选中状态保持一致。
	if _has_valid_lock():
		_turn_towards(_locked.global_position, delta)
	elif direction.length() > 0.01:
		face_direction(direction)

	var target_speed := direction * max_speed
	var rate := acceleration if direction.length() > 0.01 else deceleration
	velocity = velocity.move_toward(target_speed, rate * delta)
	move_and_slide()

	# 移动输入已在上面取消持续攻击，这里只处理"触发/维持"。
	_tick_auto_attack(delta)


# ---------------- 持续攻击 ----------------

## 持续攻击是否处于激活状态。
func is_auto_attack_active() -> bool:
	return _auto_attack


## 触发阈值说明：按住主操作 ≥ auto_attack_hold_seconds，或在 auto_attack_tap_window 内
## 连点 ≥ auto_attack_tap_count 次。两个阈值都可在"设置 → 玩家战斗"里调整。
func _tick_auto_attack(delta: float) -> void:
	var holding := Input.is_action_pressed("attack") or _ui_attack_held
	if holding:
		_hold_time += delta
		if not _auto_attack and auto_attack_hold_seconds > 0.0 and _hold_time >= auto_attack_hold_seconds:
			_start_auto_attack()
	else:
		_hold_time = 0.0

	if not _auto_attack:
		return
	# 目标失效（死亡/离开屏幕/被清空）自动结束
	if not _has_valid_lock():
		cancel_auto_attack()
		return
	perform_action()


func _start_auto_attack() -> void:
	if _auto_attack or _dead:
		return
	if not _has_valid_lock():
		return
	_auto_attack = true
	_tap_times.clear()
	EventBus.auto_attack_changed.emit(true)


## 主动中断持续攻击（移动 / 点空白 / 点其他目标 / 技能 / 暂停 / 目标失效都会调用）。
func cancel_auto_attack() -> void:
	_hold_time = 0.0
	_tap_times.clear()
	if not _auto_attack:
		return
	_auto_attack = false
	EventBus.auto_attack_changed.emit(false)


func _register_tap() -> void:
	_tap_times.append(_clock)
	while not _tap_times.is_empty() and _clock - _tap_times[0] > auto_attack_tap_window:
		_tap_times.pop_front()
	if not _auto_attack and auto_attack_tap_count > 0 and _tap_times.size() >= auto_attack_tap_count:
		_start_auto_attack()


# ---------------- 仇恨接管 ----------------

## 目标切换优先级（自上而下）：
## 1. 玩家手动点选：立即生效，并清空仇恨锁（下一次被攻击会重新建立锁）。
## 2. 首只攻击者优先：已有有效仇恨锁时，后续怪物的攻击不会切换目标。
## 3. 锁失效（死亡 / 离开视口 / 超过 aggro_latch_timeout 未再攻击玩家）后，
##    下一只攻击玩家的怪重新成为锁并接管目标。
func _latch_attacker(source: Node) -> void:
	# 死亡期间不接管目标（复活时会统一清空锁，复活后的下一次攻击重新建立）。
	if _dead:
		return
	if not (source is EnemyController):
		return
	var enemy := source as EnemyController
	if not enemy.is_alive():
		return
	if _has_active_latch():
		# 已有首攻怪：只有它自己再攻击才续期，其它怪的攻击不改变目标。
		if _aggro_latch == enemy:
			_aggro_latch_left = aggro_latch_timeout
		return
	_aggro_latch = enemy
	_aggro_latch_left = aggro_latch_timeout
	select_target(enemy, true)


func _has_active_latch() -> bool:
	if _aggro_latch == null or _aggro_latch_left <= 0.0:
		return false
	if not is_instance_valid(_aggro_latch) or not _aggro_latch.is_alive():
		return false
	return is_position_locked_view(_aggro_latch.global_position, lock_release_margin)


func _tick_aggro_latch(delta: float) -> void:
	if _aggro_latch == null:
		return
	# 允许运行时调小超时（设置/测试），立即按新上限收缩剩余时间。
	_aggro_latch_left = minf(_aggro_latch_left, aggro_latch_timeout)
	_aggro_latch_left = maxf(0.0, _aggro_latch_left - delta)
	if _aggro_latch_left <= 0.0 or not _has_active_latch():
		_aggro_latch = null
		_aggro_latch_left = 0.0


## 玩家手动选目标时调用：释放仇恨锁，玩家意志优先。
func clear_aggro_latch() -> void:
	_aggro_latch = null
	_aggro_latch_left = 0.0


func get_aggro_latch() -> EnemyController:
	return _aggro_latch if _aggro_latch_left > 0.0 else null


# ---------------- 自动接近 ----------------

func _should_auto_approach() -> bool:
	if not auto_approach or _approach_stalled or not _approach_enabled:
		return false
	if not _has_valid_lock():
		return false
	return global_position.distance_to(_locked.global_position) > attack_range * approach_stop_ratio


## 当前是否正在自动接近（HUD / 测试用）。
func is_auto_approaching() -> bool:
	return _should_auto_approach()


## 自动接近是否处于"已开启"状态（即使当前已在攻击距离内、暂时不需要移动）。
func is_approach_enabled() -> bool:
	return _approach_enabled


## 关闭自动接近并清空路径：任何玩家主动操作都会调用它，关闭后不会自行恢复。
func cancel_auto_approach() -> void:
	_approach_enabled = false
	_reset_approach_state()
	_reset_approach_path()


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


func _has_valid_lock() -> bool:
	return is_instance_valid(_locked) and _locked.is_alive()


## 取消选中条件：目标死亡，或目标移出视口（用更宽松的释放边距，避免贴边抖动）。
func _drop_invalid_lock() -> void:
	if _locked == null:
		return
	if not is_instance_valid(_locked) or not _locked.is_alive():
		_set_locked_target(null)
		return
	if not is_position_locked_view(_locked.global_position, lock_release_margin):
		_set_locked_target(null)


## 设置选中目标（只处理状态与高亮，不涉及任何攻击逻辑）。
func _set_locked_target(enemy: EnemyController) -> void:
	if _locked != enemy:
		cancel_auto_approach()
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
	if enemy.def.is_empty():
		return enemy.enemy_id
	# 怪物名优先跟随语言表，没有条目时回退到配置里的 display_name。
	var id := String(enemy.def.get("id", enemy.enemy_id))
	var key := "enemy." + id
	if not id.is_empty() and Locale.has_key(key):
		return Locale.t(key)
	return String(enemy.def.get("display_name", enemy.enemy_id))


## 属性同步：基础值来自 player.json，等级成长与装备加成来自 InventoryService。
## 生命上限变化交给 HealthComponent.set_max_hp（增量同时补当前血量）。
func _sync_stats_from_inventory() -> void:
	var s := InventoryService.stats()
	attack = float(s.get("attack", attack))
	defense = float(s.get("defense", defense))
	crit_rate = float(s.get("crit_rate", crit_rate))
	crit_damage = float(s.get("crit_damage", crit_damage))
	max_hp = int(s.get("max_hp", max_hp))
	max_mp = int(s.get("max_mp", max_mp))
	mp = clampi(mp, 0, max_mp)
	if _health != null:
		_health.set_max_hp(max_hp)


## 装备或等级变化后重算属性；默认参数让两个信号（2 参数）都能直接连过来。
func _on_stats_changed(_arg1: Variant = null, _arg2: Variant = null) -> void:
	_sync_stats_from_inventory()


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
	hurt_invuln = float(def.get("hurt_invuln", hurt_invuln))
	respawn_delay = float(def.get("respawn_delay", respawn_delay))
	respawn_invuln = float(def.get("respawn_invuln", respawn_invuln))
	mp_regen = float(def.get("mp_regen", mp_regen))
	skill_mp_cost = int(def.get("skill_mp_cost", skill_mp_cost))
	skill_cooldown = float(def.get("skill_cooldown", skill_cooldown))
	skill_multiplier = float(def.get("skill_multiplier", skill_multiplier))
	auto_approach = bool(def.get("auto_approach", auto_approach))
	approach_stop_ratio = float(def.get("approach_stop_ratio", approach_stop_ratio))
	# 持续攻击与仇恨锁的设计默认值（用户可在设置里覆盖前两项）。
	auto_attack_hold_seconds = float(def.get("auto_attack_hold_seconds", auto_attack_hold_seconds))
	auto_attack_tap_count = int(def.get("auto_attack_tap_count", auto_attack_tap_count))
	auto_attack_tap_window = float(def.get("auto_attack_tap_window", auto_attack_tap_window))
	aggro_latch_timeout = float(def.get("aggro_latch_timeout", aggro_latch_timeout))


## 用户在"设置 → 玩家战斗"里改的阈值实时生效。
func _apply_combat_settings() -> void:
	auto_attack_hold_seconds = GameSettings.combat_value("auto_attack_hold_seconds", auto_attack_hold_seconds)
	auto_attack_tap_count = int(GameSettings.combat_value("auto_attack_tap_count", float(auto_attack_tap_count)))


## 主操作按钮是自动接近的唯一开启来源：目标在距离外 -> 走过去；在距离内 -> 执行动作。
func _on_attack_requested() -> void:
	_ui_attack_held = false
	_register_tap()
	perform_action()


func _on_attack_pressed() -> void:
	_ui_attack_held = true


func _on_skill_requested(_skill_id: String) -> void:
	# 技能按钮同样打断自动接近与持续攻击，然后尝试施放。
	cancel_auto_approach()
	cancel_auto_attack()
	try_skill()


func _on_game_paused(is_paused: bool) -> void:
	# 打开设置面板/暂停时立刻结束寻路与持续攻击，避免恢复后角色继续行动。
	if is_paused:
		cancel_auto_approach()
		cancel_auto_attack()


func _on_hp_changed(current: int, maximum: int) -> void:
	if _visual != null and _visual.has_method("set_health"):
		_visual.set_health(current, maximum)


## 死亡：立即停手、清空选中与仇恨锁、取消碰撞，2 秒后自动复活。
func _on_died() -> void:
	_dead = true
	_respawn_left = respawn_delay
	velocity = Vector2.ZERO
	_ui_attack_held = false
	cancel_auto_attack()
	cancel_auto_approach()
	clear_aggro_latch()
	_set_locked_target(null)
	set_deferred("collision_layer", 0)
	set_deferred("collision_mask", 0)
	if _visual != null and _visual.has_method("set_dead"):
		_visual.set_dead(true)
	EventBus.player_died.emit()


## 复活（触发条件：`HealthComponent.died` 后经过 respawn_delay 秒）。
## 状态重置清单（顺序重要：先恢复存活标记，再清理战斗状态）：
## 1. 位置回到出生点、满血、无敌 respawn_invuln 秒；
## 2. 清空选中目标与仇恨锁——复活后的第一次被攻击可以重新接管目标；
## 3. 取消持续攻击 / 自动接近，并清掉按钮按住状态与攻击冷却；
## 4. 恢复碰撞层，恢复视觉。
func _respawn() -> void:
	global_position = spawn_point
	velocity = Vector2.ZERO
	_health.reset_full()
	_dead = false
	_invuln_left = respawn_invuln
	_cooldown_left = 0.0
	_ui_attack_held = false
	_hold_time = 0.0
	_tap_times.clear()
	cancel_auto_attack()
	cancel_auto_approach()
	clear_aggro_latch()
	_set_locked_target(null)
	set_deferred("collision_layer", PhysLayers.PLAYER)
	set_deferred("collision_mask", PhysLayers.WORLD | PhysLayers.ENEMY)
	if _visual != null and _visual.has_method("set_dead"):
		_visual.set_dead(false)
	EventBus.player_respawned.emit()
