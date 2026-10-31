extends Node

## 音效服务（Autoload）：全部音效在运行时合成，不引入任何音频素材。
##
## 为什么不用素材（Q16 = 只做 SFX，预算 0）：
##   · 零授权风险，不需要进《资产授权登记表》；
##   · 包体不增加；
##   · 垂直切片阶段"有反馈"比"好听"重要，正式音源接进来时替换 _build_streams 即可。
##
## 结构：N 个 AudioStreamPlayer 轮转复用，避免短促音效互相打断。

const SAMPLE_RATE := 22050
const POOL_SIZE := 6
## 默认音量（dB）。接设置面板后可做成可调项。
const DEFAULT_VOLUME_DB := -10.0

var enabled := true
var volume_db := DEFAULT_VOLUME_DB

var _players: Array[AudioStreamPlayer] = []
var _streams: Dictionary = {}
var _next := 0


func _ready() -> void:
	_build_players()
	_build_streams()
	_apply_audio_settings()
	_connect_events()
	GameSettings.audio_changed.connect(_apply_audio_settings)


## 把设置面板里的开关与音量同步到播放器。0 音量也当作静音处理。
func _apply_audio_settings() -> void:
	enabled = bool(GameSettings.audio_value("sfx_enabled"))
	var volume := float(GameSettings.audio_value("sfx_volume"))
	volume_db = linear_to_db(volume) if volume > 0.0 else -80.0
	for player in _players:
		player.volume_db = volume_db


func _exit_tree() -> void:
	if GameSettings.audio_changed.is_connected(_apply_audio_settings):
		GameSettings.audio_changed.disconnect(_apply_audio_settings)
	if EventBus.damage_dealt.is_connected(_on_damage_dealt):
		EventBus.damage_dealt.disconnect(_on_damage_dealt)
	if EventBus.item_picked_up.is_connected(_on_item_picked_up):
		EventBus.item_picked_up.disconnect(_on_item_picked_up)
	if EventBus.player_died.is_connected(_on_player_died):
		EventBus.player_died.disconnect(_on_player_died)
	if EventBus.enemy_died.is_connected(_on_enemy_died):
		EventBus.enemy_died.disconnect(_on_enemy_died)
	if EventBus.level_changed.is_connected(_on_level_changed):
		EventBus.level_changed.disconnect(_on_level_changed)
	if EventBus.quest_completed.is_connected(_on_quest_completed):
		EventBus.quest_completed.disconnect(_on_quest_completed)


func has_stream(name: String) -> bool:
	return _streams.has(name)


func stream_length(name: String) -> float:
	var stream := _streams.get(name, null) as AudioStreamWAV
	if stream == null or stream.data.is_empty():
		return 0.0
	return float(stream.data.size() / 2) / float(stream.mix_rate)


## 播放一个具名音效；返回是否真的播放了。
func play(name: String) -> bool:
	if not enabled or not _streams.has(name) or _players.is_empty():
		return false
	var player := _players[_next]
	_next = (_next + 1) % _players.size()
	player.stream = _streams[name]
	player.play()
	return true


# ---------------- 事件接线 ----------------

func _connect_events() -> void:
	EventBus.damage_dealt.connect(_on_damage_dealt)
	EventBus.item_picked_up.connect(_on_item_picked_up)
	EventBus.player_died.connect(_on_player_died)
	EventBus.enemy_died.connect(_on_enemy_died)
	EventBus.level_changed.connect(_on_level_changed)
	EventBus.quest_completed.connect(_on_quest_completed)


func _on_damage_dealt(_world_position: Vector2, _amount: int, is_crit: bool) -> void:
	play("crit" if is_crit else "hit")


func _on_item_picked_up(_item_id: String, _qty: int) -> void:
	play("pickup")


func _on_player_died() -> void:
	play("death")


func _on_enemy_died(_enemy_id: String) -> void:
	play("enemy_die")


func _on_level_changed(_level: int, _exp: int) -> void:
	play("level")


func _on_quest_completed(_quest_id: String) -> void:
	play("quest")


# ---------------- 合成 ----------------

func _build_players() -> void:
	for i in POOL_SIZE:
		var player := AudioStreamPlayer.new()
		player.bus = "Master"
		player.volume_db = volume_db
		add_child(player)
		_players.append(player)


func _build_streams() -> void:
	# 参数：起始频率、结束频率、时长、衰减指数、噪声比例。
	_streams["hit"] = _make_tone(320.0, 180.0, 0.07, 26.0, 0.35)
	_streams["crit"] = _make_tone(520.0, 260.0, 0.10, 20.0, 0.30)
	_streams["pickup"] = _make_tone(660.0, 990.0, 0.09, 22.0, 0.05)
	_streams["enemy_die"] = _make_tone(200.0, 90.0, 0.18, 16.0, 0.25)
	_streams["death"] = _make_tone(180.0, 60.0, 0.35, 9.0, 0.15)
	_streams["level"] = _make_tone(520.0, 780.0, 0.30, 7.0, 0.0)
	_streams["quest"] = _make_tone(440.0, 660.0, 0.28, 7.0, 0.0)


## 生成一段 16bit 单声道音：频率线性滑动 + 指数衰减 + 可选噪声。
func _make_tone(from_hz: float, to_hz: float, duration: float, decay: float,
		noise_mix: float) -> AudioStreamWAV:
	var count := maxi(1, int(SAMPLE_RATE * duration))
	var data := PackedByteArray()
	data.resize(count * 2)
	var phase := 0.0
	var rng := RandomNumberGenerator.new()
	rng.seed = 12345   # 固定种子：同一次运行内音色稳定，测试可复现
	for i in count:
		var t := float(i) / float(SAMPLE_RATE)
		var progress := t / duration
		var freq := lerpf(from_hz, to_hz, progress)
		phase += TAU * freq / float(SAMPLE_RATE)
		var envelope := exp(-t * decay)
		var value := sin(phase) * (1.0 - noise_mix) + rng.randf_range(-1.0, 1.0) * noise_mix
		var sample := int(clampf(value * envelope, -1.0, 1.0) * 32767.0)
		data.encode_s16(i * 2, sample)

	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = SAMPLE_RATE
	stream.stereo = false
	stream.data = data
	return stream
