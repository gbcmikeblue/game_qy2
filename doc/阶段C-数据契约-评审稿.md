# 阶段 C 数据契约（评审稿）

> 日期：2026-10-31　状态：**待评审，通过后才写实现**
> 依据：`doc/决策记录.md` 的 P-01 / G-01～G-07 / A-07 / A-10 / N04(A) / N05(A)
> 目标：把「掉落 → 拾取 → 列表背包 → 5 槽装备 → 属性重算 → 3 槽存档 → 等级 → 菜单式商店」拆成可独立验收的数据与接口。

---

## 1. 格式落地（对应 N04=A）

| 数据 | 格式 | 位置 | 理由 |
|---|---|---|---|
| 物品定义 | **`.tres`**（`ItemData`） | `data/items/items/*.tres` | 需要在编辑器里配图标与数值，且带类型检查 |
| 装备定义 | **`.tres`**（继承 `ItemData`，`slot` 非空即装备） | 同上 | 复用同一份资源与图标管线 |
| 掉落表 | **`.tres`**（`LootTable`） | `data/items/loot/*.tres` | 引用 `ItemData`，编辑器里可视化调权重 |
| 职业与槽位 | **JSON** | `data/actors/classes.json` | 与 actors 同族，`DataRegistry` 已能读 |
| 数值/敌人/地图/文案 | **JSON**（不变） | `data/**` | 不迁，避免重写 `DataRegistry` |

**双通道边界（写死，避免日后腐化）**
- `DataRegistry` 继续只读 JSON：`player`、`enemies`、`maps`、`i18n`、`interactions`、`classes`。
- 物品相关**统一走 `ItemRegistry`**（新 autoload，扫描 `data/items/` 下的 `.tres` 建 id→资源索引），不读 JSON。
- 二者互不引用；UI 与业务只查 `ItemRegistry`，不再自己 `load()`。

---

## 2. 目录与文件

```text
scripts/items/
  item_data.gd          class_name ItemData  extends Resource
  loot_table.gd         class_name LootTable extends Resource
  loot_entry.gd         class_name LootEntry extends Resource
  item_registry.gd      Autoload「ItemRegistry」：扫描 .tres、id 索引、按 id 取定义
  inventory_service.gd  Autoload「InventoryService」：运行时背包/装备/金币/等级 + 存档
data/items/
  items/*.tres          物品与装备（垂直切片起步：3 消耗品 + 7 装备）
  loot/*.tres           每个敌人一份掉落表
scenes/ui/inventory/
  inventory_panel.tscn  列表背包 + 5 槽装备 + 角色属性
  shop_panel.tscn       菜单式商店（买/卖）
```

---

## 3. ItemData 字段

| 字段 | 类型 | 说明 |
|---|---|---|
| `id` | `StringName` | 唯一键，与文件名一致（如 `wep_rusty_sword`） |
| `name_key` / `desc_key` | `String` | i18n key，形如 `item.wep_rusty_sword.name`（文案进 `data/i18n/*.json`） |
| `icon` | `Texture2D` | 64×64；阶段 C 期间允许为 `null`，UI 用占位绘制（A-10） |
| `category` | `int` 枚举 | `CONSUMABLE / EQUIPMENT / MATERIAL` |
| `slot` | `StringName` | 装备槽：`weapon/shield/armor/helmet/boots`；非装备为空 |
| `rarity` | `int` 枚举 | `COMMON / MAGIC / RARE / UNIQUE`，本期只影响图标底色与掉落权重 |
| `stackable` / `max_stack` | `bool` / `int` | 默认 1 / 1；材料与消耗品 `99` |
| `attack_bonus` `defense_bonus` `max_hp_bonus` `max_mp_bonus` | `float` | 装备加成，进 `stats()` |
| `value` | `int` | 金币基准价（买入 = value，卖出 = value/2 向下取整） |
| `use_effect` | `StringName` | 消耗品效果键：`heal_hp / restore_mp`，空表示不可用 |

**校验规则**（`ItemRegistry` 启动时执行，失败即 `push_error` 并跳过）：`id` 非空且唯一；`category==EQUIPMENT` 时 `slot` 必须属于 `classes.json` 的槽位集合；`stackable=false` 时 `max_stack` 强制 1。

---

## 4. 槽位与职业（对应 P01=C）

`data/actors/classes.json`：

```json
{
  "classes": [
    {
      "id": "warrior",
      "display_name_key": "class.warrior.name",
      "slots": ["weapon", "shield", "armor", "helmet", "boots"]
    }
  ]
}
```

- 本期只有 `warrior`，但代码**从 `slots` 数组读取**，不写死 5 个常量。
- UI 按 `slots` 渲染装备格（当前 5 格）；加职业只加数据。
- 存档里的 `equipment` 按槽位名存 key，与槽位顺序无关。

---

## 5. 掉落表（LootTable / LootEntry）

| 字段 | 说明 |
|---|---|
| `rolls` | 独立抽取次数（默认 1） |
| `entries: Array[LootEntry]` | 每项：`item`、`weight`、`min_qty`、`max_qty`、`chance`（0–1，先过 chance 再按 weight 抽） |
| `guaranteed: Array[LootEntry]` | 必掉项（首杀、任务物品） |
| `gold_min` / `gold_max` | 金币掉落范围，不单独建表 |

- 敌人通过 `enemies.json` 的 `"loot": "wolf_basic"` 引用掉落表；缺省用 `default_basic`。
- 抽取用 `RandomNumberGenerator`（可 seed，便于测试复现）。

---

## 6. 运行时服务：InventoryService

| 状态 | 类型 | 说明 |
|---|---|---|
| `items` | `Array[Dictionary]` | `{id, qty}` 列表（G-01 列表背包，无占格） |
| `equipment` | `Dictionary` | `slot → id`，空槽不存键 |
| `gold` / `level` / `exp` | `int` | 等级自动成长（D-02） |
| `capacity` | `int` | 物品种类上限，默认 24 |

| 方法 | 语义 |
|---|---|
| `add_item(id, qty) -> int` | 返回**实际入包数量**（0 表示满）；先补已有堆叠，再占新格 |
| `remove_item(id, qty) -> bool` | 不足则不改动并返回 false（事务性） |
| `equip(id) -> bool` | 校验槽位；旧件自动回包（包满则拒绝装备，保持原状） |
| `unequip(slot) -> bool` | 回包失败则拒绝 |
| `stats() -> Dictionary` | 基础值 + 装备加成，供玩家控制器读取 |
| `gain_exp(amount)` | 触发升级，返回升级次数 |
| `buy(id)` / `sell(id)` | 商店交易，校验金币与容量 |

**事务性要求**：任何一步失败都必须回滚到调用前状态（测试覆盖「包满时装备」「金币不足」）。

---

## 7. 存档格式（对应 G-03 / G-04）

```json
{
  "schema_version": 1,
  "crc": "8f2c...",
  "saved_at": 1793491200,
  "player": { "level": 3, "exp": 120, "hp": 140, "mp": 30, "gold": 250 },
  "inventory": [ { "id": "mat_wolf_fang", "qty": 4 } ],
  "equipment": { "weapon": "wep_rusty_sword", "armor": "arm_basic" },
  "position": [ 16, 16 ]
}
```

- 路径：`user://save_1.json` / `save_2.json` / `save_3.json`（3 槽，G-03）。
- `crc` = 对去掉 `crc` 字段后的紧凑 JSON 文本算 CRC32；不匹配则拒绝载入并提示「存档损坏」。
- `schema_version` 每次结构变更 +1；载入旧档走 `_migrate(data, from_version)`，本期只有 1 版，函数留空壳。
- 自动存档时机（D-01）：击杀精英、切换地图、退出游戏；手动存档由面板按钮触发。
- 写入用「写临时文件 → 校验 → rename」，避免半截文件（原子写）。

---

## 8. 事件契约（EventBus 新增）

```gdscript
signal inventory_changed
signal equipment_changed(slot: String, item_id: String)
signal gold_changed(gold: int)
signal level_changed(level: int, exp: int)
signal item_picked_up(item_id: String, qty: int)
signal shop_requested(open: bool)
signal save_written(slot: int)
```

规则：UI 只发「请求」事件（`shop_requested`、`save_requested`），业务结果由服务层广播状态事件；UI 不直接改 `InventoryService` 的字段。

---

## 9. `tests/stage_c_check` 断言清单

| 组 | # | 断言 |
|---|---|---|
| 数据 | 1 | `ItemRegistry` 载入的物品种类数 = 文件数，id 无重复 |
| 数据 | 2 | 装备的 `slot` 全部属于 `classes.json` 的槽位集合 |
| 数据 | 3 | `stackable=false` 的物品 `max_stack` 被强制为 1 |
| 背包 | 4 | 已有 3 个、加 2 个 → 仍是 1 格、qty=5（先补堆叠） |
| 背包 | 5 | 堆叠到上限后开新格；满包时返回实际入包数量（可小于请求数） |
| 背包 | 6 | `remove_item` 数量不足时不做任何改动 |
| 装备 | 7 | 装备后 `stats()` 的 attack 增加对应 `attack_bonus` |
| 装备 | 8 | 换装时旧件回包；包满则拒绝换装且原装备不变 |
| 装备 | 9 | `unequip` 包满时拒绝，槽位保持原值 |
| 属性 | 10 | 升级后 `max_hp/max_mp` 按曲线增长，当前值不超上限 |
| 掉落 | 11 | 固定 seed 下掉落结果可复现 |
| 掉落 | 12 | `chance=0` 的条目永不出、`chance=1` 必出 |
| 掉落 | 13 | `guaranteed` 条目每次必出且数量在 `[min_qty, max_qty]` |
| 存档 | 14 | 存 → 读往返后背包/装备/等级/金币/位置完全一致 |
| 存档 | 15 | 3 个槽位互不覆盖（写 2 号槽不影响 1 号） |
| 存档 | 16 | 篡改 `crc` 后被拒绝载入，且不改动当前运行时状态 |
| 存档 | 17 | 写临时文件后不 rename 不会破坏原有存档 |
| 商店 | 18 | 买入扣金币且入包；金币不足时两者都不变 |
| 商店 | 19 | 卖出移除物品并加金币（value/2 向下取整）；包满时买入失败 |
| 集成 | 20 | 击杀敌人 → 掉落进包 → `inventory_changed` 触发次数正确 |
| 集成 | 21 | 装备武器后攻击伤害按新 `attack` 计算（接 `CombatService`） |
| 集成 | 22 | 读档后玩家血量/位置恢复，且不触发死亡判定 |
| 回归 | 23 | 现有 7 套验收全绿 |

---

## 10. 实施顺序（每步一个 commit）

| # | 内容 | 产出 | 估时 |
|---|---|---|---|
| 1 | `ItemData` / `LootTable` / `LootEntry` + `ItemRegistry` | 能加载 `.tres` 并在测试里查表 | 0.5 d |
| 2 | `InventoryService`（增删/堆叠/装备/属性/金币/等级） | 断言 1–10 | 1 d |
| 3 | 掉落与拾取（地面 `LootDrop` + 自动拾取范围） | 断言 11–13、20 | 1 d |
| 4 | 存档（3 槽 / CRC / 原子写 / 迁移壳） | 断言 14–17、22 | 1 d |
| 5 | 列表背包 + 5 槽装备面板（占位图标） | 人工可操作 | 1.5 d |
| 6 | 菜单式商店（买/卖） | 断言 18–19 | 1 d |
| 7 | 接线 `CombatService` 与玩家属性、经验入账 | 断言 21 | 0.5 d |
| 8 | `stage_c_check` 全量 + CI 接第 8 套 | 断言 23 | 0.5 d |

合计约 **7 人日**（`data/items/*.tres` 内容填充不含在内）。

---

## 11. 需要你点头的 5 个细节（评审点）

| 编号 | 细节 | 建议 |
|---|---|---|
| R1 | 物品种类上限 `capacity` 默认 24 | 24 够垂直切片，后续进设置面板 |
| R2 | 堆叠上限：材料/消耗品 99，装备不可堆叠 | 按此 |
| R3 | 卖出价 = `value / 2` 向下取整 | 与常见 RPG 一致；要更严可改 1/3 |
| R4 | 存档 `user://save_1..3.json`，明文 JSON + CRC | 本地开发够用，加密留到上架前 |
| R5 | 等级曲线：`exp_to_next = 50 × level^1.5`（取整），每级 `max_hp +8 / max_mp +4 / attack +2 / defense +1` | 先给能玩的曲线，数值后续调 `player.json` |

**评审通过方式**：回「契约通过」或指出要改的编号；通过后按 §10 顺序实现，每步保持全部验收全绿。
