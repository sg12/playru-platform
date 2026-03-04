extends Node3D

# Остров Выживания — главная логика
# Цель: построить плот и спастись с острова

const DAY_DURATION = 120.0   # 2 минуты игрового дня
const HUNGER_RATE = 0.5      # голод в секунду

@onready var player: CharacterBody3D = $Player
@onready var crafting: Node = $CraftingSystem
@onready var resource_nodes: Node3D = $ResourceNodes
@onready var lbl_day: Label = $UI/LblDay
@onready var lbl_hunger: Label = $UI/LblHunger
@onready var lbl_inventory: Label = $UI/LblInventory
@onready var btn_craft_panel: Button = $UI/BtnCraft
@onready var craft_panel: Control = $UI/CraftPanel
@onready var btn_back: Button = $UI/BtnBack

var current_day: int = 1
var day_time: float = 0.0
var hunger: float = 100.0
var is_alive: bool = true
var days_survived: int = 0
var resources_gathered: int = 0

func _ready() -> void:
	btn_craft_panel.pressed.connect(_toggle_craft_panel)
	btn_back.pressed.connect(_on_back)

	crafting.item_crafted.connect(_on_item_crafted)
	crafting.craft_failed.connect(_on_craft_failed)

	_setup_resource_interactions()
	_build_craft_ui()

func _process(delta: float) -> void:
	if not is_alive:
		return

	# Дневной цикл
	day_time += delta
	if day_time >= DAY_DURATION:
		day_time = 0.0
		current_day += 1
		days_survived += 1
		Toast.show("День %d начался" % current_day)

	# Голод
	hunger -= HUNGER_RATE * delta
	hunger = max(hunger, 0.0)

	if hunger <= 0 and int(day_time * 2) % 60 == 0:
		# Урон от голода
		if player.has_method("take_damage"):
			player.take_damage(1)

	_update_ui()

func _update_ui() -> void:
	if lbl_day:
		var progress = int((day_time / DAY_DURATION) * 100)
		lbl_day.text = "День %d  [%d%%]" % [current_day, progress]
	if lbl_hunger:
		lbl_hunger.text = "🍖 %d%%" % int(hunger)
		lbl_hunger.modulate = Color.RED if hunger < 25 else Color.WHITE
	if lbl_inventory:
		lbl_inventory.text = crafting.get_inventory_display()

func _setup_resource_interactions() -> void:
	if not resource_nodes:
		return
	for node in resource_nodes.get_children():
		if node.has_signal("resource_gathered"):
			node.resource_gathered.connect(_on_resource_gathered)

func _on_resource_gathered(res_type, amount: int) -> void:
	resources_gathered += amount
	var name_map = {0: "wood", 1: "stone", 2: "food", 3: "fiber"}
	var type_int = res_type as int
	var res_name = name_map.get(type_int, "resource")
	crafting.add_resource(res_name, amount)

	if res_name == "food":
		hunger = min(hunger + amount * 20, 100.0)
		Toast.success("+%d еды" % amount)
	else:
		Toast.show("+%d %s" % [amount, res_name])

func _toggle_craft_panel() -> void:
	if craft_panel:
		craft_panel.visible = !craft_panel.visible

func _build_craft_ui() -> void:
	if not craft_panel:
		return
	for item_id in CraftingSystem.RECIPES:
		var btn = Button.new()
		btn.text = CraftingSystem.RECIPE_NAMES.get(item_id, item_id)
		btn.pressed.connect(_on_craft_pressed.bind(item_id))
		craft_panel.add_child(btn)

func _on_craft_pressed(item_id: String) -> void:
	crafting.craft(item_id)

func _on_item_crafted(item_id: String) -> void:
	Toast.success("Создан: " + CraftingSystem.RECIPE_NAMES.get(item_id, item_id))

	if item_id == "raft":
		_victory()

func _on_craft_failed(item_id: String, reason: String) -> void:
	Toast.error(reason)

func _victory() -> void:
	is_alive = false
	Toast.success("Победа! Ты построил плот и спасся! День %d" % current_day)
	_submit_result(true)

func _on_back() -> void:
	_submit_result(false)
	GameManager.end_game()

func _submit_result(victory: bool) -> void:
	if NakamaManager.is_connected_to_server():
		NakamaManager.call_rpc("games/island_survival/submit_result", {
			"days_survived": days_survived,
			"resources_gathered": resources_gathered,
			"victory": victory
		})
