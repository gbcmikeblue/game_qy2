extends CanvasLayer

## HUD：玩家血条 + 锁定状态 + 调试信息。文字使用 ASCII，等接入中文字体后再切换中文文案。

const HP_FILL_MAX := 276.0

@onready var _debug_label: Label = $DebugLabel
@onready var _hp_fill: ColorRect = $HpFill
@onready var _hp_label: Label = $HpLabel
@onready var _switch_button = $SwitchButton
@onready var _hint_label: Label = $HintLabel

var _lock_line := "LOCK -"


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	for label: Label in [_debug_label, _hp_label]:
		label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 0.92))
		label.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.85))
		label.add_theme_constant_override("outline_size", 4)

	# 桌面测试按键提示：与 ATK / TGT 按钮一一对应。
	_hint_label.text = "WASD MOVE   SPACE ATK   F HOLD TGT"
	_hint_label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 0.55))
	_hint_label.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.7))
	_hint_label.add_theme_constant_override("outline_size", 3)


func _process(_delta: float) -> void:
	_update_health()
	_update_lock()
	_update_debug()


func _update_health() -> void:
	var player := GameManager.player
	if not is_instance_valid(player) or not player.has_method("get_hp"):
		return
	var current: int = player.get_hp()
	var maximum: int = player.get_max_hp()
	var ratio := clampf(float(current) / float(maxi(1, maximum)), 0.0, 1.0)
	_hp_fill.size = Vector2(HP_FILL_MAX * ratio, _hp_fill.size.y)
	_hp_label.text = "HP %d/%d" % [current, maximum]


## 无任何可选目标时目标按钮置灰且不响应按住；按住选择期间显示 SELECT 预览信息。
func _update_lock() -> void:
	var player := GameManager.player
	if not is_instance_valid(player) or not player.has_method("get_lock_summary"):
		_switch_button.set_disabled(true)
		_lock_line = "LOCK -"
		return

	var summary: Dictionary = player.get_lock_summary()
	var count := int(summary.get("count", 0))
	var selecting := bool(summary.get("selecting", false))
	_switch_button.set_disabled(count == 0)

	if count == 0:
		_lock_line = "SELECT -" if selecting else "LOCK -"
	elif selecting:
		_lock_line = "SELECT %d/%d %s" % [
			int(summary.get("preview_index", 0)), count, String(summary.get("preview_name", "-"))
		]
	elif int(summary.get("index", 0)) == 0:
		_lock_line = "LOCK -  %d TARGETS" % count
	else:
		_lock_line = "LOCK %d/%d %s" % [
			int(summary.get("index", 0)), count, String(summary.get("name", "-"))
		]


func _update_debug() -> void:
	var lines: Array[String] = []
	lines.append("FPS %d" % Engine.get_frames_per_second())
	lines.append("STATE %s" % ("PAUSED" if GameManager.is_paused else "RUNNING"))
	lines.append("ENEMIES %d" % get_tree().get_node_count_in_group("enemies"))
	lines.append(_lock_line)

	var player := GameManager.player
	if is_instance_valid(player):
		var world: Vector2 = player.global_position
		var grid := Iso.world_to_grid(world)
		lines.append("WORLD %.1f, %.1f" % [world.x, world.y])
		lines.append("GRID %d, %d" % [grid.x, grid.y])
		lines.append("SPEED %.1f" % (player as CharacterBody2D).velocity.length())
		if not player.is_alive():
			lines.append("DEAD - RESPAWNING")

	_debug_label.text = "\n".join(lines)
