extends Node3D

# Tower Defense — главная логика
# Волны врагов, строительство башен, защита базы

const WAVE_INTERVAL = 8.0
const BASE_HEALTH = 20
const STARTING_COINS = 150

@export var tower_scene: PackedScene
@export var enemy_scene: PackedScene

@onready var path_node: Path3D = $EnemyPath
@onready var build_grid: Node3D = $BuildGrid
@onready var ui: Control = $UI
@onready var lbl_wave: Label = $UI/LblWave
@onready var lbl_coins: Label = $UI/LblCoins
@onready var lbl_base_hp: Label = $UI/LblBaseHP
@onready var lbl_enemies: Label = $UI/LblEnemies
@onready var btn_next_wave: Button = $UI/BtnNextWave
@onready var btn_build: Button = $UI/BtnBuildTower
@onready var btn_back: Button = $UI/BtnBack

var current_wave: int = 0
var max_waves: int = 10
var coins: int = STARTING_COINS
var base_health: int = BASE_HEALTH
var enemies_alive: int = 0
var enemies_killed: int = 0
var is_wave_active: bool = false
var path_points: PackedVector3Array = []

signal wave_started(wave: int)
signal wave_completed(wave: int, enemies_killed: int)
signal game_over(survived_waves: int, total_kills: int)

func _ready() -> void:
	btn_next_wave.pressed.connect(_start_next_wave)
	btn_build.pressed.connect(_build_tower_at_cursor)
	btn_back.pressed.connect(_on_back)

	# Извлекаем точки пути
	if path_node and path_node.curve:
		for i in range(path_node.curve.get_point_count()):
			path_points.append(path_node.curve.get_point_position(i))

	_update_ui()

func _start_next_wave() -> void:
	if is_wave_active:
		return
	current_wave += 1
	is_wave_active = true
	btn_next_wave.disabled = true
	wave_started.emit(current_wave)

	var enemy_count = 3 + current_wave * 2
	Toast.show("Волна %d! %d врагов" % [current_wave, enemy_count])

	await _spawn_wave(enemy_count)

func _spawn_wave(count: int) -> void:
	enemies_alive = count
	for i in range(count):
		var enemy = enemy_scene.instantiate() as CharacterBody3D
		add_child(enemy)
		enemy.setup(path_points)
		# Масштабируем сложность с волнами
		enemy.max_health = 100 + current_wave * 30
		enemy.health = enemy.max_health
		enemy.move_speed = 2.5 + current_wave * 0.1
		enemy.coin_reward = 10 + current_wave * 2
		enemy.died.connect(_on_enemy_died)
		enemy.reached_end.connect(_on_enemy_reached_end)
		await get_tree().create_timer(1.0).timeout

func _on_enemy_died(enemy: Node, reward: int) -> void:
	enemies_alive -= 1
	enemies_killed += 1
	coins += reward
	_update_ui()

	if enemies_alive <= 0:
		_complete_wave()

func _on_enemy_reached_end(enemy: Node, damage: int) -> void:
	enemies_alive -= 1
	base_health -= damage
	_update_ui()

	if base_health <= 0:
		_game_over()
	elif enemies_alive <= 0:
		_complete_wave()

func _complete_wave() -> void:
	is_wave_active = false
	var bonus = current_wave * 25
	coins += bonus
	wave_completed.emit(current_wave, enemies_killed)
	Toast.success("Волна %d пройдена! +%d монет" % [current_wave, bonus])

	if current_wave >= max_waves:
		_victory()
	else:
		btn_next_wave.disabled = false
	_update_ui()

func _build_tower_at_cursor() -> void:
	if coins < 50 or not tower_scene:
		Toast.error("Недостаточно монет (нужно 50)")
		return
	# Простое размещение — в реальной игре через raycast на grid
	var tower = tower_scene.instantiate()
	build_grid.add_child(tower)
	tower.global_position = Vector3(randf_range(-5, 5), 0, randf_range(-5, 5))
	coins -= 50
	_update_ui()

func _update_ui() -> void:
	if lbl_wave: lbl_wave.text = "Волна: %d/%d" % [current_wave, max_waves]
	if lbl_coins: lbl_coins.text = "🪙 %d" % coins
	if lbl_base_hp: lbl_base_hp.text = "🏰 %d" % base_health
	if lbl_enemies: lbl_enemies.text = "👾 %d" % enemies_alive

func _game_over() -> void:
	is_wave_active = false
	Toast.error("База уничтожена! Волн пройдено: %d" % (current_wave - 1))
	game_over.emit(current_wave - 1, enemies_killed)
	await _submit_result(false)
	await get_tree().create_timer(3.0).timeout
	GameManager.end_game()

func _victory() -> void:
	Toast.success("Победа! Все %d волн отражены!" % max_waves)
	game_over.emit(max_waves, enemies_killed)
	await _submit_result(true)
	await get_tree().create_timer(3.0).timeout
	GameManager.end_game()

func _submit_result(victory: bool) -> void:
	if NakamaManager.is_connected_to_server():
		await NakamaManager.call_rpc("games/tower_defense/submit_result", {
			"waves_survived": current_wave,
			"enemies_killed": enemies_killed,
			"victory": victory,
			"base_health_remaining": base_health
		})

func _on_back() -> void:
	GameManager.end_game()
