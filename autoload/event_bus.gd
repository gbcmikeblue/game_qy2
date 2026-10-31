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

## ---------------- 阶段 C：物品与成长 ----------------
## 背包内容或容量变化（UI 全量刷新）。
signal inventory_changed
## 某个槽位的装备变化；item_id 为空表示卸下。
signal equipment_changed(slot: String, item_id: String)
signal gold_changed(gold: int)
signal level_changed(level: int, exp: int)
## 地面上拾取到物品（飘字与音效入口）。
signal item_picked_up(item_id: String, qty: int)
## 敌人被击杀（带世界坐标）：掉落服务据此生成地面物并结算金币/经验。
## 与 enemy_died 的分工：enemy_died 只给 id（统计/任务用），本信号带位置（掉落用）。
signal enemy_defeated(enemy_id: String, world_position: Vector2)
## 请求打开/关闭商店（UI 只发请求，交易结果走 gold/inventory 事件）。
signal shop_requested(open: bool)
signal save_written(slot: int)
