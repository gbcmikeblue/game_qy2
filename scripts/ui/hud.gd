extends CanvasLayer

## HUD：调试信息面板。文字使用 ASCII，等接入中文字体后再切换中文文案。

@onready var _debug_label: Label = $DebugLabel


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_debug_label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 0.92))
	_debug_label.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.85))
	_debug_label.add_theme_constant_override("outline_size", 4)


func _process(_delta: float) -> void:
	var lines: Array[String] = []
	lines.append("FPS %d" % Engine.get_frames_per_second())
	lines.append("STATE %s" % ("PAUSED" if GameManager.is_paused else "RUNNING"))

	var player := GameManager.player
	if is_instance_valid(player):
		var world: Vector2 = player.global_position
		var grid := Iso.world_to_grid(world)
		lines.append("WORLD %.1f, %.1f" % [world.x, world.y])
		lines.append("GRID %d, %d" % [grid.x, grid.y])
		lines.append("SPEED %.1f" % (player as CharacterBody2D).velocity.length())

	_debug_label.text = "\n".join(lines)
