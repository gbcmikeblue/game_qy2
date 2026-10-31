@tool
class_name ItemData
extends Resource

## 物品/装备定义：在编辑器里可视化配置，运行时只读（数值不写进脚本）。
## 文案一律走 i18n key，不在此存中文/英文原文。

enum Category { CONSUMABLE, EQUIPMENT, MATERIAL }
enum Rarity { COMMON, MAGIC, RARE, UNIQUE }

@export var id: StringName = &""
## 文案 key，形如 item.wep_rusty_sword.name（数据在 data/i18n/*.json）。
@export var name_key: String = ""
@export var desc_key: String = ""
@export var icon: Texture2D = null
@export var category: Category = Category.MATERIAL
## 装备槽：weapon / shield / armor / helmet / boots；非装备必须留空。
@export var slot: StringName = &""
@export var rarity: Rarity = Rarity.COMMON
@export var stackable: bool = false
@export var max_stack: int = 1
@export var attack_bonus: float = 0.0
@export var defense_bonus: float = 0.0
@export var max_hp_bonus: float = 0.0
@export var max_mp_bonus: float = 0.0
## 金币基准价：买入按此价，卖出按一半（向下取整）。
@export var value: int = 0
## 消耗品效果键：heal_hp / restore_mp；空表示不可使用。
@export var use_effect: StringName = &""


func is_equipment() -> bool:
	return category == Category.EQUIPMENT


## 不可堆叠的物品上限恒为 1，避免数据里写错 max_stack 造成误叠加。
func effective_max_stack() -> int:
	if not stackable:
		return 1
	return maxi(1, max_stack)


## 返回错误描述，空字符串表示通过。slots 为该职业允许的槽位集合。
func validate(slots: Array) -> String:
	if id == &"":
		return "缺少 id"
	if name_key.is_empty():
		return "缺少 name_key"
	if category == Category.EQUIPMENT:
		if slot == &"":
			return "装备缺少 slot"
		if not slots.has(String(slot)):
			return "slot '%s' 不在职业槽位集合内" % slot
	elif not slot.is_empty():
		return "非装备不应有 slot（%s）" % slot
	if max_stack < 1:
		return "max_stack 必须 ≥ 1"
	return ""
