extends Node

## 多语言支持：语言表 + 可含中日韩字形的字体 + 语言偏好持久化。
## 文本统一走 Locale.t(key, args)，缺失键回退到英文表，再回退到 key 本身。
## 语言切换通过 language_changed 信号通知所有 UI，立即生效。

signal language_changed(code: String)

const SUPPORTED := ["en", "zh"]
const DEFAULT_LANGUAGE := "en"
const SAVE_PATH := "user://locale.cfg"
const I18N_DIR := "res://data/i18n/"
## 内置正文/标题字体：霞鹜文楷 Lite（SIL OFL 1.1，中文全覆盖）。
## 保留系统字体回退，兜住字形表外的冷僻字与特殊符号。
const BUNDLED_FONT := "res://fonts/LXGWWenKaiLite-Regular.ttf"
const FONT_NAMES := [
	"Microsoft YaHei UI",
	"Microsoft YaHei",
	"Noto Sans CJK SC",
	"Source Han Sans SC",
	"PingFang SC",
	"WenQuanYi Micro Hei",
	"sans-serif",
]

var current := DEFAULT_LANGUAGE
## 全局字体：所有 UI 与自定义绘制都用这个（霞鹜文楷 + 系统回退链）。
var font: Font

var _tables: Dictionary = {}


func _ready() -> void:
	_build_font()
	_load_tables()
	_load_preference()
	language_changed.emit(current)


## 取翻译文本；args 非空时按 printf 规则填充。
func t(key: String, args: Array = []) -> String:
	var text := _lookup(key)
	if args.is_empty():
		return text
	return text % args


func has_key(key: String) -> bool:
	return not String((_tables.get(current, {}) as Dictionary).get(key, "")).is_empty()


func set_language(code: String) -> void:
	if not SUPPORTED.has(code):
		return
	if code == current:
		language_changed.emit(current)
		return
	current = code
	_save_preference()
	language_changed.emit(current)


func next_language() -> void:
	var index := SUPPORTED.find(current)
	set_language(SUPPORTED[(index + 1) % SUPPORTED.size()])


func language_label(code: String) -> String:
	return t("lang." + code)


func _lookup(key: String) -> String:
	var table: Dictionary = _tables.get(current, {})
	if table.has(key):
		return String(table[key])
	var fallback: Dictionary = _tables.get(DEFAULT_LANGUAGE, {})
	if fallback.has(key):
		return String(fallback[key])
	return key


func _build_font() -> void:
	var system := SystemFont.new()
	system.font_names = PackedStringArray(FONT_NAMES)
	system.antialiasing = TextServer.FONT_ANTIALIASING_GRAY

	# 优先使用内置霞鹜文楷（中文 + 拉丁），字形表外的字符走系统字体回退。
	if ResourceLoader.exists(BUNDLED_FONT):
		var bundled := load(BUNDLED_FONT) as Font
		if bundled != null:
			var fallbacks: Array[Font] = [system]
			bundled.fallbacks = fallbacks
			font = bundled
			return

	font = system


func _load_tables() -> void:
	for code: String in SUPPORTED:
		_tables[code] = _read_json(I18N_DIR + code + ".json")


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_error("语言表缺失: %s" % path)
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("语言表不是合法 JSON 对象: %s" % path)
		return {}
	return parsed as Dictionary


func _load_preference() -> void:
	var config := ConfigFile.new()
	if config.load(SAVE_PATH) != OK:
		return
	var code := String(config.get_value("general", "language", DEFAULT_LANGUAGE))
	current = code if SUPPORTED.has(code) else DEFAULT_LANGUAGE


func _save_preference() -> void:
	var config := ConfigFile.new()
	config.set_value("general", "language", current)
	config.save(SAVE_PATH)
