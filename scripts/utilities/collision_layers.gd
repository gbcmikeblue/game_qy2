class_name PhysLayers
extends RefCounted

## 物理层约定：世界=1，玩家=2，敌人=4。
## 新增层时只改这里，避免各处硬编码位掩码。

const WORLD := 1
const PLAYER := 2
const ENEMY := 4
