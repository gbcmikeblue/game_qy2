extends Node

## 全局事件总线：模块之间只通过信号通信，禁止跨层 get_node("../../..")。

signal attack_requested
## 技能按钮预留通道：目前只用于打断自动接近，后续接技能系统。
signal skill_requested(skill_id: String)
## 非战斗目标的“主操作”请求：NPC 对话 / 植物采集 / 观察玩家，由玩法层后续接入。
signal target_action_requested(kind: String, target: Node)
## 主操作按钮按下（用于“长按触发持续攻击”的计时，抬起走 attack_requested）。
signal attack_pressed
## 持续攻击状态变化（HUD 指示用）。
signal auto_attack_changed(active: bool)
signal game_paused(is_paused: bool)
signal player_died
signal player_respawned
signal enemy_died(enemy_id: String)
