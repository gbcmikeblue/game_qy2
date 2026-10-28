extends Node

## 全局事件总线：模块之间只通过信号通信，禁止跨层 get_node("../../..")。

signal attack_requested
signal game_paused(is_paused: bool)
