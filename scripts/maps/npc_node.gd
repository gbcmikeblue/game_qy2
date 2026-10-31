class_name NpcNode
extends Node2D

## 静态 NPC：目前只有商人一种，靠「靠近 + 主操作按钮」交互。
##
## 刻意不进玩家的锁定系统（锁定只认 EnemyController）：NPC 不是战斗目标，
## 混进去会让自动接近、攻击冷却这些逻辑都要额外分支。交互走距离判定即可。

const INTERACT_RADIUS := 56.0

const BODY_COLOR := Color(0.55, 0.42, 0.30)
const HEAD_COLOR := Color(0.88, 0.74, 0.58)
const PAD_COLOR := Color(0.20, 0.30, 0.26, 0.75)
const NAME_COLOR := Color(0.92, 0.92, 0.86, 0.9)

var kind := "npc"
## 交互时打开的商店 id（对应 data/items/shop/*.tres）。
var shop_id: StringName = &"basic"
var display_name_key := "npc.merchant.name"
## 对话台词 key（对话框正文）；空则用通用台词。
var dialogue_key := ""
## 是否发布任务（对话框据此显示「接取 / 交付」）。
var quest_giver := false


func setup(p_shop_id: StringName, p_name_key: String, p_dialogue_key := "", p_quest_giver := false) -> void:
	shop_id = p_shop_id
	if not p_name_key.is_empty():
		display_name_key = p_name_key
	dialogue_key = p_dialogue_key
	quest_giver = p_quest_giver
	queue_redraw()


func _ready() -> void:
	add_to_group("npcs")


func get_target_kind() -> String:
	return kind


func is_player_near() -> bool:
	var player := GameManager.get_player()
	if player == null or not is_instance_valid(player):
		return false
	return global_position.distance_to(player.global_position) <= INTERACT_RADIUS


func _draw() -> void:
	# 地台 + 身体 + 头 + 名字：全部程序化，接入正式美术时只换这个函数。
	draw_circle(Vector2(0.0, 0.0), 20.0, PAD_COLOR)
	draw_rect(Rect2(-8.0, -28.0, 16.0, 22.0), BODY_COLOR, true)
	draw_circle(Vector2(0.0, -34.0), 8.0, HEAD_COLOR)
	if not is_player_near():
		return
	var font := Locale.font
	if font == null:
		return
	var text := Locale.t(display_name_key)
	var width := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x
	draw_string(font, Vector2(-width * 0.5, -50.0), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 13,
			NAME_COLOR)
