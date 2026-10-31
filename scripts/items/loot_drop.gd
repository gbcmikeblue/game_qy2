class_name LootDrop
extends Node2D

## 地面掉落物：靠近自动拾取，背包放不下时留在原地并给出提示。
## 纯占位视觉（按稀有度着色的菱形 + 数量），接入正式美术时只换 _draw。

const PICKUP_RADIUS := 48.0
const LIFETIME := 60.0
const FADE_TIME := 5.0
const HINT_COOLDOWN := 1.5

const C_COMMON := Color(0.78, 0.78, 0.80)
const C_MAGIC := Color(0.44, 0.62, 1.00)
const C_RARE := Color(1.00, 0.84, 0.35)
const C_UNIQUE := Color(1.00, 0.52, 0.30)
const C_OUTLINE := Color(0.0, 0.0, 0.0, 0.45)
const C_HINT_FULL := Color(1.0, 0.45, 0.40)
const C_HINT_PICK := Color(0.85, 1.0, 0.85)

var item_id: StringName = &""
var qty := 1

var _life := LIFETIME
var _hint_left := 0.0


## 由掉落服务调用；位置由调用方设置。
func setup(p_item_id: StringName, p_qty: int) -> void:
	item_id = p_item_id
	qty = maxi(1, p_qty)
	queue_redraw()


func _ready() -> void:
	add_to_group("loot_drops")


func _process(delta: float) -> void:
	_life -= delta
	_hint_left = maxf(0.0, _hint_left - delta)
	if _life <= 0.0:
		queue_free()
		return
	if _life < FADE_TIME:
		modulate.a = clampf(_life / FADE_TIME, 0.0, 1.0)

	var player := GameManager.get_player()
	if player == null or not is_instance_valid(player):
		return
	if global_position.distance_to(player.global_position) > PICKUP_RADIUS:
		return
	try_pickup()


## 尝试拾取，返回是否成功（成功也包含「部分入包」）。
func try_pickup() -> bool:
	var def := ItemRegistry.get_item(item_id)
	if def == null:
		queue_free()
		return false

	var added := InventoryService.add_item(item_id, qty)
	if added <= 0:
		if _hint_left <= 0.0:
			_hint_left = HINT_COOLDOWN
			CombatFx.show_text(global_position, Locale.t("inventory.full"), C_HINT_FULL)
		return false

	qty -= added
	EventBus.item_picked_up.emit(String(item_id), added)
	CombatFx.show_text(global_position, "+%d %s" % [added, Locale.t(def.name_key)], C_HINT_PICK)
	if qty <= 0:
		queue_free()
	return true


func color_for_rarity() -> Color:
	var def := ItemRegistry.get_item(item_id)
	if def == null:
		return C_COMMON
	match def.rarity:
		ItemData.Rarity.MAGIC:
			return C_MAGIC
		ItemData.Rarity.RARE:
			return C_RARE
		ItemData.Rarity.UNIQUE:
			return C_UNIQUE
		_:
			return C_COMMON


func _draw() -> void:
	var color := color_for_rarity()
	var points := PackedVector2Array([
		Vector2(0.0, -9.0), Vector2(9.0, 0.0), Vector2(0.0, 9.0), Vector2(-9.0, 0.0),
	])
	draw_colored_polygon(points, color)
	var closed := points.duplicate()
	closed.append(points[0])
	draw_polyline(closed, C_OUTLINE, 1.0)
	if qty > 1:
		var font := ThemeDB.fallback_font
		draw_string(font, Vector2(6.0, 14.0), str(qty), HORIZONTAL_ALIGNMENT_LEFT, -1, 11,
				Color(1.0, 1.0, 1.0, 0.9))
