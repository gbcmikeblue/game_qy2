class_name HealthComponent
extends Node

## 生命值组件：玩家与敌人共用。死亡必须幂等——重复扣血不得重复触发 died，
## 否则掉落/经验会双倍结算（文档 4.6 的已知坑）。

signal hp_changed(current: int, maximum: int)
signal died

var max_hp := 100
var hp := 100
var is_dead := false


func setup(p_max_hp: int) -> void:
	max_hp = maxi(1, p_max_hp)
	hp = max_hp
	is_dead = false
	hp_changed.emit(hp, max_hp)


func take_damage(amount: int) -> int:
	if is_dead or amount <= 0:
		return 0
	var applied := mini(amount, hp)
	hp -= applied
	hp_changed.emit(hp, max_hp)
	if hp <= 0:
		is_dead = true
		died.emit()
	return applied


func heal(amount: int) -> void:
	if is_dead or amount <= 0:
		return
	hp = mini(max_hp, hp + amount)
	hp_changed.emit(hp, max_hp)


func reset_full() -> void:
	hp = max_hp
	is_dead = false
	hp_changed.emit(hp, max_hp)


## 上限变化（升级、装备 +HP 时调用）。
## 上限增加时把同样的增量补到当前血量，避免「升级后血条反而变短」；
## 上限减少（卸装）时只夹紧当前值，不额外扣血。
func set_max_hp(new_max: int) -> void:
	var clamped := maxi(1, new_max)
	var delta := clamped - max_hp
	max_hp = clamped
	hp = clampi(hp + maxi(0, delta), 0, max_hp)
	hp_changed.emit(hp, max_hp)
