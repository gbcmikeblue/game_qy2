extends Node

## 全局事件总线：模块之间只通过信号通信，禁止跨层 get_node("../../..")。

signal attack_requested
## 按住目标按钮进入选择模式，松开确认（按钮按下/抬起各发一次）。
signal target_select_pressed
signal target_select_released
signal game_paused(is_paused: bool)
signal player_died
signal player_respawned
signal enemy_died(enemy_id: String)
