extends StaticBody3D

# Ресурсный узел — дерево, камень, еда

enum ResourceType { WOOD, STONE, FOOD, FIBER }

@export var resource_type: ResourceType = ResourceType.WOOD
@export var max_resources: int = 5
@export var respawn_time: float = 60.0

var current_resources: int
var is_depleted: bool = false

signal resource_gathered(type: ResourceType, amount: int)
signal depleted()
signal respawned()

@onready var mesh: MeshInstance3D = $MeshInstance3D if has_node("MeshInstance3D") else null

func _ready() -> void:
	current_resources = max_resources

func gather(amount: int = 1) -> int:
	if is_depleted:
		return 0

	var gathered = min(amount, current_resources)
	current_resources -= gathered
	resource_gathered.emit(resource_type, gathered)

	if current_resources <= 0:
		_deplete()

	return gathered

func _deplete() -> void:
	is_depleted = true
	depleted.emit()
	if mesh:
		mesh.visible = false
	get_tree().create_timer(respawn_time).timeout.connect(_respawn)

func _respawn() -> void:
	is_depleted = false
	current_resources = max_resources
	if mesh:
		mesh.visible = true
	respawned.emit()

func get_resource_name() -> String:
	match resource_type:
		ResourceType.WOOD:  return "Дерево"
		ResourceType.STONE: return "Камень"
		ResourceType.FOOD:  return "Еда"
		ResourceType.FIBER: return "Волокно"
	return "Ресурс"
