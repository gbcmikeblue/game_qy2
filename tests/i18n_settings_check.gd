extends Node

## 多语言 + 设置模块（按键绑定）验收：无头运行。
## 运行：godot --headless --path <项目> res://tests/i18n_settings_check.tscn

const MAIN_SCENE := preload("res://scenes/boot/main.tscn")

var _failures: Array[String] = []
var _main
var _hud


func _ready() -> void:
	_test_translation_table()
	_test_i18n_coverage()
	_test_font()
	_test_language_persistence()

	_main = MAIN_SCENE.instantiate()
	add_child(_main)
	await get_tree().physics_frame
	await get_tree().process_frame
	_hud = _main.get_node("HUD")

	await _test_hud_language_switch()
	await _test_action_label_by_kind()
	_test_bindings_defaults()
	_test_binding_conflict_and_reset()
	await _test_binding_effective()
	_test_binding_persistence()
	_test_combat_settings()
	await _test_settings_panel()

	# 收尾：恢复英文与默认键位，避免影响后续手动运行
	Locale.set_language("en")
	GameSettings.reset_defaults()
	_report()


func _test_translation_table() -> void:
	Locale.set_language("en")
	_check(Locale.t("hud.hp", [10, 20]) == "HP 10/20", "英文模板占位符替换正确")

	Locale.set_language("zh")
	_check(Locale.t("hud.hp", [10, 20]).contains("生命"), "中文文案生效（%s）" % Locale.t("hud.hp", [10, 20]))
	_check(Locale.t("settings.title") == "设置", "设置标题本地化")
	_check(Locale.t("no.such.key") == "no.such.key", "缺失键回退为 key 本身")
	_check(Locale.has_key("hud.hp") and not Locale.has_key("no.such.key"), "has_key 判定正确")
	_check(Locale.t("enemy.forest_wolf") == "森林狼", "敌人名称本地化")


## 覆盖度检查：中英词条数量一致；代码里用到的 key 在两种语言都存在。
func _test_i18n_coverage() -> void:
	var en := _read_translation("res://data/i18n/en.json")
	var zh := _read_translation("res://data/i18n/zh.json")
	_check(en.size() >= 30, "英文词条数量合理（%d）" % en.size())
	_check(zh.size() == en.size(), "中英词条数量一致（%d / %d）" % [en.size(), zh.size()])

	var missing: Array[String] = []
	for key: String in en.keys():
		if not zh.has(key):
			missing.append(key)
	_check(missing.is_empty(), "中文无缺失词条（缺 %s）" % str(missing))

	var used := _collect_used_keys()
	_check(used.size() >= 15, "扫描到代码中的文案 key（%d 个）" % used.size())
	var absent: Array[String] = []
	for key: String in used.keys():
		if not en.has(key) or not zh.has(key):
			absent.append(key)
	_check(absent.is_empty(), "代码引用的 key 都有中英词条（缺 %s）" % str(absent))

	# 动态拼接的 key（enemy.<id> / lang.<code> / action.<action> / 交互类型）单独校验
	for id: String in ["forest_wolf", "stone_boar", "cave_bat"]:
		_check(en.has("enemy." + id) and zh.has("enemy." + id), "敌人名有中英词条（%s）" % id)
	for code: String in Locale.SUPPORTED:
		_check(en.has("lang." + code) and zh.has("lang." + code), "语言名有中英词条（%s）" % code)
	for action: String in GameSettings.ACTIONS:
		_check(en.has("action." + action) and zh.has("action." + action), "按键名有中英词条（%s）" % action)
	for kind: String in DataRegistry.get_interaction_kinds():
		var key := DataRegistry.get_interaction_action(kind)
		_check(en.has(key) and zh.has(key), "交互文案有中英词条（%s -> %s）" % [kind, key])


func _read_translation(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	return parsed as Dictionary if typeof(parsed) == TYPE_DICTIONARY else {}


func _collect_used_keys() -> Dictionary:
	var keys := {}
	var regex := RegEx.new()
	regex.compile("Locale\\.(?:t|has_key)\\(\"([^\"]*)\"")
	for path: String in _script_files("res://scripts") + _script_files("res://autoload"):
		var file := FileAccess.open(path, FileAccess.READ)
		if file == null:
			continue
		var text := file.get_as_text()
		file.close()
		for result: RegExMatch in regex.search_all(text):
			var key := result.get_string(1)
			# 前缀拼接（action.<x> / enemy.<id> / lang.<code>）在下面单独校验
			if key.is_empty() or key.ends_with("."):
				continue
			keys[key] = true
	return keys


func _script_files(root: String) -> Array[String]:
	var result: Array[String] = []
	var dir := DirAccess.open(root)
	if dir == null:
		return result
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if not entry.begins_with("."):
			var path := root.path_join(entry)
			if dir.current_is_dir():
				result.append_array(_script_files(path))
			elif entry.ends_with(".gd"):
				result.append(path)
		entry = dir.get_next()
	dir.list_dir_end()
	return result


func _test_font() -> void:
	_check(Locale.font != null, "字体资源已加载")
	_check(ResourceLoader.exists(Locale.BUNDLED_FONT), "内置霞鹜文楷字体文件存在")
	_check(Locale.font is FontFile, "内置霞鹜文楷生效（FontFile）")
	_check(Locale.font.fallbacks.size() > 0, "霞鹜文楷配置了系统回退字体")
	_check(Locale.font.get_string_size("SETTINGS", HORIZONTAL_ALIGNMENT_LEFT, -1, 18).x > 30.0,
			"内置字体能测量拉丁字串")
	_check(Locale.font.get_string_size("设置", HORIZONTAL_ALIGNMENT_LEFT, -1, 18).x > 20.0,
			"内置字体能测量中文字串")
	_check(Locale.font.has_char("设".unicode_at(0)), "中文字形由内置字体直接提供（不依赖回退）")


func _test_language_persistence() -> void:
	Locale.set_language("zh")
	var config := ConfigFile.new()
	var loaded := config.load(Locale.SAVE_PATH) == OK
	_check(loaded and String(config.get_value("general", "language", "")) == "zh", "语言偏好已写入本地配置")


func _test_hud_language_switch() -> void:
	Locale.set_language("zh")
	for i in 4:
		await get_tree().process_frame
	_check(String(_hud.get_node("HpLabel").text).contains("生命"),
			"HUD 血量文本切为中文（%s）" % _hud.get_node("HpLabel").text)
	_check(String(_hud.get_node("HintLabel").text).contains("移动"),
			"HUD 按键提示切为中文（%s）" % _hud.get_node("HintLabel").text)
	_check(String(_hud.get_node("AttackButton").caption) == "攻击", "主操作按钮文案本地化")
	_check(String(_hud.get_node("SettingsButton").caption) == "设置", "设置按钮文案本地化")
	_check(not _hud.has_node("LangButton"), "语言切换按钮已从 HUD 移除（迁移到设置面板）")

	Locale.set_language("en")
	for i in 4:
		await get_tree().process_frame
	_check(String(_hud.get_node("HpLabel").text).begins_with("HP"), "切回英文后 HUD 立即恢复英文")
	_check(String(_hud.get_node("AttackButton").caption) == "ATTACK", "切回英文后按钮文案恢复")


func _test_action_label_by_kind() -> void:
	var button: Control = _hud.get_node("AttackButton")
	var player = GameManager.player
	Locale.set_language("zh")
	await get_tree().process_frame
	_check(String(button.caption) == "攻击", "未选中目标时按钮显示「攻击」")

	var enemy = _main.map.spawn_enemy("forest_wolf", Iso.world_to_grid(player.global_position))
	enemy.global_position = player.global_position + Vector2(0.0, 50.0)
	enemy.move_speed = 0.0
	await get_tree().physics_frame
	_check(player.select_target(enemy), "文案测试：选中目标")
	await get_tree().process_frame
	_check(String(button.caption) == "攻击", "选中怪物时按钮显示「攻击」")

	# 复制一份 def，避免污染 DataRegistry 里的共享配置
	enemy.def = (enemy.def as Dictionary).duplicate()
	var cases := {"npc": "交互", "plant": "采摘", "player": "观察", "monster_custom": "攻击"}
	for kind: String in cases.keys():
		enemy.def["kind"] = kind
		await get_tree().process_frame
		_check(String(button.caption) == String(cases[kind]),
				"类型 %s -> 按钮「%s」（实际 %s）" % [kind, cases[kind], button.caption])

	Locale.set_language("en")
	enemy.def["kind"] = "npc"
	await get_tree().process_frame
	_check(String(button.caption) == "INTERACT", "切语言后按钮文案实时更新（INTERACT）")
	Locale.set_language("zh")
	await get_tree().process_frame
	_check(String(button.caption) == "交互", "切回中文后按钮文案实时更新（交互）")

	_check(DataRegistry.get_interaction_action("npc") == "action.interact", "交互文案映射可查询")
	_check(DataRegistry.has_interaction_kind("plant") and not DataRegistry.has_interaction_kind("chest"),
			"交互类型表按 JSON 加载")

	player.clear_selection()
	enemy.queue_free()
	await get_tree().physics_frame


func _test_bindings_defaults() -> void:
	GameSettings.reset_defaults()
	_check(GameSettings.get_key("attack") == KEY_J, "攻击默认键为 J")
	_check(GameSettings.get_key("move_up") == KEY_W and GameSettings.get_key("move_left") == KEY_A,
			"移动默认键为 WASD")
	_check(_has_key_event("attack", KEY_J), "攻击动作已注册到 InputMap")
	_check(not InputMap.has_action("target_select"), "目标选择不再占用按键（选中由点击完成）")
	_check(String(_hud.get_node("HintLabel").text).contains("J"), "HUD 提示跟随当前键位")


func _test_binding_conflict_and_reset() -> void:
	var result := GameSettings.set_key("attack", KEY_W)
	_check(String(result.get("swapped", "")) == "move_up", "冲突时回报被交换的动作")
	_check(GameSettings.get_key("attack") == KEY_W, "攻击改为 W")
	_check(GameSettings.get_key("move_up") == KEY_J, "被占用的移动键被交换为 J")
	_check(_has_key_event("attack", KEY_W) and _has_key_event("move_up", KEY_J),
			"InputMap 随绑定同步更新")

	GameSettings.reset_defaults()
	_check(GameSettings.get_key("attack") == KEY_J and GameSettings.get_key("move_up") == KEY_W,
			"恢复默认键位生效")


func _test_binding_effective() -> void:
	var player = GameManager.player
	for enemy: Node in get_tree().get_nodes_in_group("enemies"):
		enemy.queue_free()
	await get_tree().physics_frame
	player.global_position = _main.map.spawn_world_position()
	player.velocity = Vector2.ZERO
	await get_tree().physics_frame

	var target = _main.map.spawn_enemy("forest_wolf", Iso.world_to_grid(player.global_position))
	target.global_position = player.global_position + Vector2(0.0, 40.0)
	target.move_speed = 0.0
	await get_tree().physics_frame
	_check(player.select_target(target), "改键测试：先选中近身目标")
	for i in 30:
		await get_tree().physics_frame

	GameSettings.set_key("attack", KEY_K)
	var hp_before: int = target.get_hp()
	_send_key(KEY_K, true)
	for i in 3:
		await get_tree().physics_frame
	_send_key(KEY_K, false)
	for i in 3:
		await get_tree().physics_frame
	_check(target.get_hp() < hp_before, "改键后新键 K 立即生效（%d -> %d）" % [hp_before, target.get_hp()])

	for i in 30:
		await get_tree().physics_frame
	var hp_after: int = target.get_hp()
	_send_key(KEY_J, true)
	for i in 3:
		await get_tree().physics_frame
	_send_key(KEY_J, false)
	for i in 3:
		await get_tree().physics_frame
	_check(target.get_hp() == hp_after, "旧键 J 不再触发攻击（%d）" % target.get_hp())

	GameSettings.reset_defaults()


func _test_binding_persistence() -> void:
	GameSettings.set_key("move_up", KEY_I)
	GameSettings.load_from_disk()
	_check(GameSettings.get_key("move_up") == KEY_I, "键位写入本地配置并可读回")

	GameSettings.reset_defaults()
	GameSettings.load_from_disk()
	_check(GameSettings.get_key("move_up") == KEY_W, "恢复默认后配置同步为默认值")


## 玩家战斗参数：默认值来自 player.json，可改、可落盘、可恢复默认。
func _test_combat_settings() -> void:
	var def := DataRegistry.get_player_def()
	var def_hold := float(def.get("auto_attack_hold_seconds", 0.8))
	var def_taps := float(def.get("auto_attack_tap_count", 5.0))

	_check(is_equal_approx(GameSettings.combat_value("auto_attack_hold_seconds", def_hold), def_hold),
			"长按阈值默认取自配置（%.1f s）" % def_hold)

	GameSettings.set_combat_value("auto_attack_hold_seconds", 0.4)
	_check(is_equal_approx(GameSettings.combat_value("auto_attack_hold_seconds", def_hold), 0.4),
			"长按阈值可修改并即时生效")

	GameSettings.adjust_combat("auto_attack_tap_count", -1, def_taps)
	_check(int(round(GameSettings.combat_value("auto_attack_tap_count", def_taps))) < int(def_taps),
			"连点次数可按步长调整（%d）" % int(round(GameSettings.combat_value("auto_attack_tap_count", def_taps))))

	# 越界会被夹紧
	GameSettings.set_combat_value("auto_attack_hold_seconds", 99.0)
	_check(GameSettings.combat_value("auto_attack_hold_seconds", def_hold) <= 2.5, "超出上限会被夹紧")

	var config := ConfigFile.new()
	var saved := config.load(GameSettings.SAVE_PATH) == OK
	_check(saved and float(config.get_value("combat", "auto_attack_hold_seconds", -1.0)) > 0.0,
			"战斗参数写入本地配置")

	GameSettings.reset_combat()
	_check(is_equal_approx(GameSettings.combat_value("auto_attack_hold_seconds", def_hold), def_hold),
			"恢复默认后回到配置值")


func _test_settings_panel() -> void:
	var panel = load("res://scenes/ui/settings_panel.tscn").instantiate()
	add_child(panel)
	await get_tree().process_frame
	_check(GameManager.is_paused, "打开设置面板会暂停游戏")

	Locale.set_language("zh")
	await get_tree().process_frame
	# 面板内容已放进 ScrollContainer，标签层级更深，这里改为递归查找。
	var title: Node = null
	var combat_title: Node = null
	for sub: Node in panel.find_children("*", "Label", true, false):
		var text := String((sub as Label).text)
		if text == "设置":
			title = sub
		elif text == "玩家战斗":
			combat_title = sub
	_check(title != null, "设置面板标题随语言切换为中文")
	_check(combat_title != null, "设置面板含「玩家战斗」区块")

	panel._close()
	await get_tree().process_frame
	await get_tree().process_frame
	_check(not GameManager.is_paused, "关闭设置面板后恢复运行")
	Locale.set_language("en")


func _has_key_event(action: String, keycode: int) -> bool:
	if not InputMap.has_action(action):
		return false
	for event: InputEvent in InputMap.action_get_events(action):
		if event is InputEventKey and (event as InputEventKey).physical_keycode == keycode:
			return true
	return false


func _send_key(keycode: int, pressed: bool) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = keycode
	event.pressed = pressed
	Input.parse_input_event(event)


func _check(condition: bool, message: String) -> void:
	if condition:
		print("[PASS] ", message)
	else:
		_failures.append(message)
		print("[FAIL] ", message)


func _report() -> void:
	print("---------- 多语言 / 设置验收 ----------")
	if _failures.is_empty():
		print("结果：全部通过")
		get_tree().quit(0)
	else:
		print("结果：%d 项失败" % _failures.size())
		get_tree().quit(1)
