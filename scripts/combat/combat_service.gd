class_name CombatService
extends RefCounted

## 战斗结算唯一入口：能不能打、打多少、是否飘字，全部在这里决定。
## 玩家与敌人共用同一套规则；数值公式仍留在 CombatMath（纯函数、可单测）。
##
## 收口的目的：后续接权威服务器时，只需要把本文件的结算替换成服务端下发的
## 结果（或把 strike 搬到服务端），控制器不必再各写一份。

## 一次攻击结算。params 支持：
##   attack: float            攻击方攻击力（必填）
##   crit_rate / crit_damage  暴击参数，敌人传 0 / 1.0（默认 0 / 1.0）
##   rng: RandomNumberGenerator  为空则不判暴击
##   max_range: float         超出即不结算（默认 INF，表示由调用方判定）
##   range_tolerance: float   距离容差系数（敌人用 1.25，默认 1.0）
##   defense: float           显式指定防御（缺省时向目标查询，见 _defense_of）
##   show_damage_fx: bool     命中后是否飘伤害数字（默认 false）
## 返回 {hit, damage, is_crit, reason}；reason 仅用于调试与测试诊断。
static func strike(attacker: Node2D, target: Node, params: Dictionary = {}) -> Dictionary:
	var out := {"hit": false, "damage": 0, "is_crit": false, "reason": ""}

	if attacker == null or not is_instance_valid(attacker):
		out["reason"] = "no_attacker"
		return out
	if target == null or not is_instance_valid(target):
		out["reason"] = "no_target"
		return out
	if not target.has_method("take_damage"):
		out["reason"] = "target_not_damageable"
		return out
	if target.has_method("is_alive") and not target.is_alive():
		out["reason"] = "target_dead"
		return out

	var max_range := float(params.get("max_range", INF))
	var tolerance := float(params.get("range_tolerance", 1.0))
	if is_finite(max_range):
		if attacker.global_position.distance_to(target.global_position) > max_range * tolerance:
			out["reason"] = "out_of_range"
			return out

	var result := CombatMath.compute_damage(
		float(params.get("attack", 0.0)),
		1.0,
		float(params.get("defense", _defense_of(target))),
		float(params.get("crit_rate", 0.0)),
		float(params.get("crit_damage", 1.0)),
		params.get("rng", null)
	)
	var damage := int(result["damage"])

	# 目标可能因为无敌帧/已死亡拒绝这次伤害，此时不计命中也不飘字。
	if not target.take_damage(damage, attacker):
		out["reason"] = "rejected"
		return out

	if bool(params.get("show_damage_fx", false)):
		CombatFx.show_damage(target.global_position, damage, bool(result["is_crit"]))

	EventBus.damage_dealt.emit(target.global_position, damage, bool(result["is_crit"]))
	out["hit"] = true
	out["damage"] = damage
	out["is_crit"] = bool(result["is_crit"])
	return out


## 目标防御力：优先 get_defense()（玩家），否则读 defense 字段（敌人）。
static func _defense_of(target: Node) -> float:
	if target.has_method("get_defense"):
		return float(target.get_defense())
	if "defense" in target:
		return float(target.defense)
	return 0.0
