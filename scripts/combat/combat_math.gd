class_name CombatMath
extends RefCounted

## 伤害计算：纯函数，不依赖任何节点或动画，便于单元测试。
## 公式：max(1, attack * multiplier - defense)，暴击再乘 crit_damage。

static func compute_damage(
	attack: float,
	multiplier: float,
	defense: float,
	crit_rate: float,
	crit_damage: float,
	rng: RandomNumberGenerator = null
) -> Dictionary:
	var mitigated := maxf(1.0, attack * multiplier - defense)
	var is_crit := rng != null and rng.randf() < crit_rate
	var final := mitigated * (crit_damage if is_crit else 1.0)
	return {
		"damage": maxi(1, int(round(final))),
		"is_crit": is_crit,
	}
