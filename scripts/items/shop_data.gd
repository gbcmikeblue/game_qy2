@tool
class_name ShopData
extends Resource

## 商店库存：一份 Resource 就是一家店的货架。
## 后续接 NPC 时按 npc.shop 字段引用 id 即可，不需要改 UI。

@export var id: StringName = &""
## 货架上的商品（按此顺序展示）。数量无限，价格取 ItemData.value。
@export var stock: Array[ItemData] = []


func items() -> Array[ItemData]:
	return stock


func contains(item_id: StringName) -> bool:
	for item: ItemData in stock:
		if item != null and item.id == item_id:
			return true
	return false
