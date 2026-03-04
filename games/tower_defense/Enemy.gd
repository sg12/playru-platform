extends CharacterBody3D

# Враг Tower Defense — идёт по пути, имеет здоровье

signal died(enemy: Node, reward: int)
signal reached_end(enemy: Node, damage: int)

@export var max_health: int = 100
@export var move_speed: float = 3.0
@export var coin_reward: int = 10
@export var damage_to_base: int = 1

var health: int
var path_points: PackedVector3Array = []
var current_point_index: int = 0
var is_alive: bool = true

@onready var health_bar: ProgressBar = $HealthBar3D if has_node("HealthBar3D") else null

func _ready() -> void:
	health = max_health

func setup(points: PackedVector3Array) -> void:
	path_points = points
	if path_points.size() > 0:
		global_position = path_points[0]

func _physics_process(delta: float) -> void:
	if not is_alive or path_points.is_empty():
		return
	if current_point_index >= path_points.size():
		reached_end.emit(self, damage_to_base)
		return

	var target = path_points[current_point_index]
	var direction = (target - global_position)

	if direction.length() < 0.3:
		current_point_index += 1
		return

	velocity = direction.normalized() * move_speed
	move_and_slide()
	look_at(target, Vector3.UP)

	if health_bar:
		health_bar.value = float(health) / max_health * 100

func take_damage(amount: int) -> void:
	if not is_alive:
		return
	health -= amount
	if health <= 0:
		die()

func die() -> void:
	is_alive = false
	died.emit(self, coin_reward)
	queue_free()
