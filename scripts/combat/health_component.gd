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
