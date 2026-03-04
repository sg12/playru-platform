extends Node3D

# Башня — стреляет по ближайшему врагу в радиусе

@export var damage: int = 25
@export var attack_speed: float = 1.5   # атак в секунду
@export var attack_range: float = 8.0
@export var cost: int = 50

var _attack_timer: float = 0.0
var _target: Node3D = null
var enemies_in_range: Array[Node3D] = []

@onready var range_area: Area3D = $RangeArea
@onready var muzzle: Marker3D = $Muzzle if has_node("Muzzle") else null

func _ready() -> void:
	if range_area:
		range_area.body_entered.connect(_on_enemy_enter)
		range_area.body_exited.connect(_on_enemy_exit)
		# Устанавливаем радиус через CollisionShape
		var shape = SphereShape3D.new()
		shape.radius = attack_range
		var col = CollisionShape3D.new()
		col.shape = shape
		range_area.add_child(col)

func _process(delta: float) -> void:
	_attack_timer += delta
	_clean_targets()

	if enemies_in_range.is_empty():
		_target = null
		return

	# Цель — ближайший к концу пути
	_target = enemies_in_range[0]

	if _attack_timer >= 1.0 / attack_speed:
		_attack_timer = 0.0
		_shoot()

func _shoot() -> void:
	if not _target or not is_instance_valid(_target):
		return
	if _target.has_method("take_damage"):
		_target.take_damage(damage)
	look_at(_target.global_position, Vector3.UP)

func _clean_targets() -> void:
	enemies_in_range = enemies_in_range.filter(
		func(e): return is_instance_valid(e) and e.is_alive if e.has_method("take_damage") else false
	)

func _on_enemy_enter(body: Node3D) -> void:
	if body.has_method("take_damage"):
		enemies_in_range.append(body)

func _on_enemy_exit(body: Node3D) -> void:
	enemies_in_range.erase(body)
