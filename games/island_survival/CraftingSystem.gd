extends Node

# Система крафта — создание предметов из ресурсов

const RECIPES = {
	"axe":      {"wood": 3, "stone": 2},
	"shelter":  {"wood": 10, "fiber": 5},
	"raft":     {"wood": 20, "fiber": 10},  # Победная цель
	"fire":     {"wood": 5, "stone": 3},
	"bandage":  {"fiber": 3},
}

const RECIPE_NAMES = {
	"axe":      "Топор (+50% сбор дерева)",
	"shelter":  "Укрытие (защита ночью)",
	"raft":     "Плот (ПОБЕДА!)",
	"fire":     "Костёр (еда не тратится ночью)",
	"bandage":  "Бинт (восстанавливает 30 HP)",
}

signal item_crafted(item_id: String)
signal craft_failed(item_id: String, reason: String)

var inventory: Dictionary = {
	"wood": 0, "stone": 0, "food": 10, "fiber": 0
}
var crafted_items: Dictionary = {}

func add_resource(resource_name: String, amount: int) -> void:
	inventory[resource_name] = inventory.get(resource_name, 0) + amount

func can_craft(item_id: String) -> bool:
	var recipe = RECIPES.get(item_id)
	if not recipe:
		return false
	for resource in recipe:
		if inventory.get(resource, 0) < recipe[resource]:
			return false
	return true

func craft(item_id: String) -> bool:
	if not can_craft(item_id):
		var recipe = RECIPES.get(item_id, {})
		var missing = []
		for resource in recipe:
			var have = inventory.get(resource, 0)
			var need = recipe[resource]
			if have < need:
				missing.append("%s: %d/%d" % [resource, have, need])
		craft_failed.emit(item_id, "Не хватает: " + ", ".join(missing))
		return false

	var recipe = RECIPES[item_id]
	for resource in recipe:
		inventory[resource] -= recipe[resource]

	crafted_items[item_id] = crafted_items.get(item_id, 0) + 1
	item_crafted.emit(item_id)
	return true

func get_inventory_display() -> String:
	var parts = []
	for k in inventory:
		if inventory[k] > 0:
			parts.append("%s: %d" % [k, inventory[k]])
	return ", ".join(parts)

func has_won() -> bool:
	return crafted_items.get("raft", 0) > 0
