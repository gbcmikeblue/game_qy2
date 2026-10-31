extends Node

## 存档服务（Autoload）：3 个槽位、JSON + CRC32 校验、原子写。
##
## 设计约束（doc/阶段C-数据契约-评审稿.md §7 / 决策 G-03、G-04）：
##   · 路径 user://save_1..3.json，一次只影响目标槽；
##   · 写入先落 .tmp 并回读校验，再 rename，半截写不会破坏旧档；
##   · crc 校验失败视为坏档：拒绝载入且不改动当前运行时状态；
##   · schema_version 每次结构变更 +1，旧档走 _migrate。
##
## 注意：CRC 只防误改（决策 N03 = A），不防逆工程。

const SAVE_VERSION := 1
const SLOT_COUNT := 3
## 自动存档固定写 1 号槽（手动槽留给玩家）。
const AUTOSAVE_SLOT := 1

## 自动存档开关：验收脚本会临时关掉，避免测试过程写用户的存档文件。
var autosave_enabled := true

## 主菜单选了「读取存档」时先把槽位号放在这里，等游戏场景把玩家建好后再消费。
## 直接在主菜单里 load 是不行的：那时 GameManager.player 还不存在。
var pending_slot := 0

## 当前所在地图 id：由 main 在启动与换图后写入，存档据此记录与还原。
var current_map_id := "test_map_01"
## 换图回调（main 注册）：读档时若存档在别的地图，先切图再恢复位置。
var map_switcher: Callable = Callable()


func _ready() -> void:
	# 自动存档时机（决策 D-01 的可落地部分）：升级与退出。
	# 「击杀精英」「切换地图」等时机依赖尚未实现的系统，等它们落地再接。
	EventBus.level_changed.connect(_on_level_changed)


func _exit_tree() -> void:
	if EventBus.level_changed.is_connected(_on_level_changed):
		EventBus.level_changed.disconnect(_on_level_changed)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST and autosave_enabled:
		save_slot(AUTOSAVE_SLOT)


func _on_level_changed(_level: int, _exp: int) -> void:
	if autosave_enabled:
		save_slot(AUTOSAVE_SLOT)


## 取出并清空「待读档槽位」；返回 0 表示没有待处理的读档请求。
func consume_pending_slot() -> int:
	var slot := pending_slot
	pending_slot = 0
	return slot


## 槽位路径（1..SLOT_COUNT）。
func slot_path(slot: int) -> String:
	return "user://save_%d.json" % slot


func has_save(slot: int) -> bool:
	return FileAccess.file_exists(slot_path(slot))


func delete_slot(slot: int) -> bool:
	if not has_save(slot):
		return false
	return DirAccess.remove_absolute(ProjectSettings.globalize_path(slot_path(slot))) == OK


## 存档：采集 → 序列化 → 写临时文件 → 回读校验 → rename。返回是否成功。
func save_slot(slot: int) -> bool:
	if slot < 1 or slot > SLOT_COUNT:
		return false
	var payload := snapshot()
	var text := _canonical(payload)
	var record := {"schema_version": SAVE_VERSION, "crc": crc32(text), "payload": payload}
	var body := JSON.stringify(record, "", false)

	var final_path := slot_path(slot)
	var tmp_path := final_path + ".tmp"
	if not _write_text(tmp_path, body):
		return false

	# 回读校验：确认写下去的字节能被解析且 CRC 对得上，再替换正式文件。
	var check := _read_record(tmp_path)
	if check.is_empty():
		DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp_path))
		return false

	var final_abs := ProjectSettings.globalize_path(final_path)
	var tmp_abs := ProjectSettings.globalize_path(tmp_path)
	if DirAccess.rename_absolute(tmp_abs, final_abs) != OK:
		# Windows 上 rename 覆盖已存在文件可能失败：先删旧档再改名。
		DirAccess.remove_absolute(final_abs)
		if DirAccess.rename_absolute(tmp_abs, final_abs) != OK:
			return false

	EventBus.save_written.emit(slot)
	return true


## 读档：校验通过才写入运行时；失败时状态完全不变。返回是否成功。
func load_slot(slot: int) -> bool:
	if slot < 1 or slot > SLOT_COUNT:
		return false
	var record := _read_record(slot_path(slot))
	if record.is_empty():
		return false

	var payload: Dictionary = _migrate(record["payload"], int(record["schema_version"]))
	# 先切到存档所在地图，再恢复背包与坐标：否则位置会被写进另一张图的坐标系里。
	var target_map := String(payload.get("map", ""))
	if not target_map.is_empty() and map_switcher.is_valid():
		map_switcher.call(target_map)
	# 存档里 player 是嵌套结构，restore_state 要吃扁平字段，这里做一次映射。
	var player_data: Dictionary = {}
	var raw_player: Variant = payload.get("player", {})
	if typeof(raw_player) == TYPE_DICTIONARY:
		player_data = raw_player as Dictionary
	QuestService.restore(payload.get("quests", {}))
	InventoryService.restore_state({
		"inventory": payload.get("inventory", []),
		"equipment": payload.get("equipment", {}),
		"gold": int(player_data.get("gold", 0)),
		"level": int(player_data.get("level", 1)),
		"exp": int(player_data.get("exp", 0)),
	})

	var player := GameManager.get_player()
	if player != null and is_instance_valid(player):
		if payload.has("position") and player is Node2D:
			var pos: Variant = payload["position"]
			if typeof(pos) == TYPE_ARRAY and (pos as Array).size() == 2:
				(player as Node2D).position = Vector2(float(pos[0]), float(pos[1]))
		var hp := int(player_data.get("hp", 0))
		if hp > 0 and player.has_method("set_hp"):
			player.set_hp(hp)
	return true


## 当前运行时快照（只放整数，保证序列化文本稳定、CRC 可复算）。
func snapshot() -> Dictionary:
	var player := GameManager.get_player()
	var position: Array = [0, 0]
	var hp := 0
	if player != null and is_instance_valid(player):
		if player is Node2D:
			var pos := (player as Node2D).global_position
			position = [int(round(pos.x)), int(round(pos.y))]
		if player.has_method("get_hp"):
			hp = int(player.get_hp())

	var inventory: Array = []
	for entry: Dictionary in InventoryService.items:
		inventory.append({"id": String(entry["id"]), "qty": int(entry["qty"])})

	var equipment: Dictionary = {}
	for slot: String in InventoryService.equipment:
		equipment[slot] = String(InventoryService.equipment[slot])

	return {
		"map": current_map_id,
		"player": {
			"level": InventoryService.level,
			"exp": InventoryService.exp,
			"gold": InventoryService.gold,
			"hp": hp,
		},
		"position": position,
		"inventory": inventory,
		"equipment": equipment,
		"quests": QuestService.snapshot(),
	}


## 槽位摘要（UI 用；坏档返回空字典）。
func slot_info(slot: int) -> Dictionary:
	var record := _read_record(slot_path(slot))
	if record.is_empty():
		return {}
	var payload: Dictionary = record["payload"]
	var player: Dictionary = payload.get("player", {})
	return {
		"level": int(player.get("level", 1)),
		"gold": int(player.get("gold", 0)),
		"inventory_size": (payload.get("inventory", []) as Array).size(),
	}


# ---------------- 内部 ----------------

## 递归按 key 排序，得到与插入顺序无关的稳定文本（CRC 才可复算）。
func _canonical(value: Variant) -> String:
	if typeof(value) == TYPE_DICTIONARY:
		var keys: Array = (value as Dictionary).keys()
		keys.sort()
		var parts: Array[String] = []
		for key: Variant in keys:
			parts.append("%s:%s" % [JSON.stringify(String(key)), _canonical((value as Dictionary)[key])])
		return "{" + ",".join(parts) + "}"
	if typeof(value) == TYPE_ARRAY:
		var parts: Array[String] = []
		for item: Variant in (value as Array):
			parts.append(_canonical(item))
		return "[" + ",".join(parts) + "]"
	# JSON 解析会把整数读成浮点：整数按整数格式化，保证「存」与「读回」得到同一段文本，
	# 否则 CRC 永远对不上（123 vs 123.0）。
	if typeof(value) == TYPE_FLOAT:
		var number := float(value)
		if is_equal_approx(number, roundf(number)):
			return str(int(roundf(number)))
		return str(number)
	if typeof(value) == TYPE_INT:
		return str(int(value))
	return JSON.stringify(value)


func _write_text(path: String, text: String) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("存档写入失败：%s" % path)
		return false
	file.store_string(text)
	file.flush()
	file.close()
	return true


## 读出并校验一条记录；任何异常都返回空字典（调用方据此拒绝载入）。
func _read_record(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var text := file.get_as_text()
	file.close()

	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("存档格式错误：%s" % path)
		return {}
	var record := parsed as Dictionary
	var payload: Variant = record.get("payload", {})
	if typeof(payload) != TYPE_DICTIONARY:
		return {}
	var expected := int(record.get("crc", -1))
	if crc32(_canonical(payload)) != expected:
		push_warning("存档校验失败（crc 不匹配）：%s" % path)
		return {}
	var version := int(record.get("schema_version", 0))
	if version <= 0 or version > SAVE_VERSION:
		push_warning("存档版本不支持：%s（v%d）" % [path, version])
		return {}
	return {"schema_version": version, "payload": payload}


## 结构迁移：本期只有 v1，留出接缝即可。
func _migrate(payload: Dictionary, from_version: int) -> Dictionary:
	var data := payload.duplicate(true)
	if from_version < SAVE_VERSION:
		# 未来：按版本逐级补字段。当前 v1 是首版，无历史档。
		pass
	return data


## CRC32（IEEE 802.3，与 zip/png 一致）。逐字节查表，避免引入额外依赖。
func crc32(text: String) -> int:
	var table := _crc_table()
	var value := 0xFFFFFFFF
	for byte: int in text.to_utf8_buffer():
		value = (value >> 8) ^ table[(value ^ byte) & 0xFF]
	return value ^ 0xFFFFFFFF


static var _crc_cache: Array[int] = []


func _crc_table() -> Array[int]:
	if not _crc_cache.is_empty():
		return _crc_cache
	var table: Array[int] = []
	table.resize(256)
	for i in 256:
		var c := i
		for bit in 8:
			c = (c >> 1) ^ (0xEDB88320 if (c & 1) != 0 else 0)
		table[i] = c
	_crc_cache = table
	return _crc_cache
