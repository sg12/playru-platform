-- PlayRU: Island Survival — Multiplayer Match Handler
-- Кооперативный survival, 2–6 игроков, shared world, крафт, AI-мобы, день/ночь
-- Ориентир: «99 Nights in the Forest» (Roblox), масштабировано до 30 дней

local nk = require("nakama")

-- ============================================================
-- Constants
-- ============================================================

local SAVE_COLLECTION = "match_saves"
local WORLD_WIDTH     = 2000
local WORLD_HEIGHT    = 2000
local MAX_INVENTORY   = 20
local RESPAWN_TICKS   = 50     -- 5 сек
local RESOURCE_RESPAWN = 300   -- 30 сек
local AUTOSAVE_INTERVAL = 300  -- 30 сек
local DISCONNECT_TIMEOUT = 600 -- 60 сек
local CAMPFIRE_X = 1000
local CAMPFIRE_Y = 1000
local MAX_SPEED_SQ = 25        -- 5.0² per tick

-- Op-codes: Client -> Server (base)
local OP_PLAYER_MOVE = 1

-- Op-codes: Server -> Client (base)
local OP_WORLD_STATE   = 10
local OP_WORLD_DELTA   = 11
local OP_PLAYER_JOINED = 12
local OP_PLAYER_LEFT   = 13
local OP_GAME_EVENT    = 14
local OP_ERROR         = 15

-- Op-codes: Game-specific Client -> Server
local OP_GATHER      = 50
local OP_CRAFT       = 51
local OP_BUILD       = 52
local OP_EQUIP       = 53
local OP_USE_ITEM    = 54
local OP_ATTACK      = 55
local OP_ADD_FUEL    = 56
local OP_DROP_ITEM   = 57
local OP_PICKUP_ITEM = 58

-- Op-codes: Game-specific Server -> Client
local OP_RESOURCE_UPDATE  = 100
local OP_STRUCTURE_UPDATE = 101
local OP_ENEMY_UPDATE     = 102
local OP_ENEMY_REMOVED    = 103
local OP_INVENTORY_UPDATE = 104
local OP_PLAYER_DIED      = 105
local OP_PLAYER_RESPAWNED = 106
local OP_CAMPFIRE_UPDATE  = 107
local OP_LOOT_SPAWN       = 108
local OP_LOOT_REMOVED     = 109
local OP_GAME_OVER        = 110

-- Рецепты крафта
local RECIPES = {
    axe         = { wood = 3, stone = 2 },
    pickaxe     = { wood = 2, stone = 3 },
    sword       = { wood = 2, iron = 3 },
    spear       = { wood = 4, stone = 1 },
    torch       = { wood = 2, fiber = 1 },
    wall_kit    = { wood = 5, stone = 3 },
    trap_kit    = { wood = 3, iron = 2 },
    bandage     = { fiber = 3, berries = 1 },
    cooked_meat = { raw_meat = 1, wood = 1 },
}

-- Урон по типу оружия
local WEAPON_DAMAGE = {
    sword   = 25,
    spear   = 20,
    axe     = 15,
    pickaxe = 10,
}

-- Необходимые инструменты для ресурсов
local GATHER_TOOL = {
    tree     = "axe",
    rock     = "pickaxe",
    iron_ore = "pickaxe",
    bush     = nil,        -- руками
}

-- Дроп с ресурсов
local GATHER_DROP = {
    tree     = "wood",
    rock     = "stone",
    iron_ore = "iron",
    bush     = "berries",
}

-- Дроп с врагов
local ENEMY_DROP = {
    wolf         = "raw_meat",
    cultist      = "iron",
    deer_monster = "raw_meat",
}

-- Параметры врагов
local ENEMY_STATS = {
    wolf         = { health = 40,  damage = 10, speed = 3.0, detect_range = 300, attack_range = 50 },
    cultist      = { health = 60,  damage = 15, speed = 3.5, detect_range = 300, attack_range = 50 },
    deer_monster = { health = 200, damage = 30, speed = 2.5, detect_range = 400, attack_range = 60 },
}

-- ============================================================
-- Utility functions
-- ============================================================

local function distance(x1, y1, x2, y2)
    local dx = x1 - x2
    local dy = y1 - y2
    return math.sqrt(dx * dx + dy * dy)
end

local function clamp(val, min_val, max_val)
    if val < min_val then return min_val end
    if val > max_val then return max_val end
    return val
end

local function random_pos_range(min_v, max_v)
    return math.random(min_v, max_v)
end

local function inventory_count(inventory)
    local count = 0
    for _, slot in ipairs(inventory) do
        if slot then count = count + 1 end
    end
    return count
end

local function inventory_has(inventory, item_type, amount)
    local total = 0
    for _, slot in ipairs(inventory) do
        if slot and slot.type == item_type then
            total = total + slot.amount
        end
    end
    return total >= amount
end

local function inventory_remove(inventory, item_type, amount)
    local remaining = amount
    for i, slot in ipairs(inventory) do
        if slot and slot.type == item_type and remaining > 0 then
            if slot.amount <= remaining then
                remaining = remaining - slot.amount
                inventory[i] = nil
            else
                slot.amount = slot.amount - remaining
                remaining = 0
            end
        end
    end
    return remaining == 0
end

local function inventory_add(inventory, item_type, amount)
    -- Попробовать стакнуть
    for _, slot in ipairs(inventory) do
        if slot and slot.type == item_type then
            slot.amount = slot.amount + amount
            return true
        end
    end
    -- Новый слот
    if inventory_count(inventory) >= MAX_INVENTORY then
        return false
    end
    inventory[#inventory + 1] = { type = item_type, amount = amount }
    return true
end

local function inventory_has_item(inventory, item_type)
    for _, slot in ipairs(inventory) do
        if slot and slot.type == item_type then
            return true
        end
    end
    return false
end

local function make_label(state)
    return nk.json_encode({
        game        = "island_survival",
        players     = state.player_count,
        max_players = state.max_players,
        open        = state.player_count < state.max_players,
        day         = state.day_night.day_number
    })
end

local function count_active_players(state)
    local count = 0
    for _, p in pairs(state.players) do
        if not p.disconnected_at then
            count = count + 1
        end
    end
    return count
end

local function save_match_state(state, match_id)
    local save_data = {
        players        = state.players,
        resources      = state.resources,
        structures     = state.structures,
        enemies        = state.enemies,
        ground_items   = state.ground_items,
        campfire       = state.campfire,
        day_night      = state.day_night,
        next_enemy_id  = state.next_enemy_id,
        next_resource_id = state.next_resource_id,
        next_structure_id = state.next_structure_id,
        next_ground_id = state.next_ground_id,
        saved_at       = nk.time()
    }
    nk.storage_write({
        {
            collection       = SAVE_COLLECTION,
            key              = match_id,
            user_id          = nil,
            value            = save_data,
            permission_read  = 0,
            permission_write = 0
        }
    })
end

-- ============================================================
-- World Generation
-- ============================================================

local function generate_world(state)
    math.randomseed(os.time())

    -- Костёр в центре
    state.campfire = {
        x = CAMPFIRE_X, y = CAMPFIRE_Y,
        fuel = 100, light_radius = 200, is_lit = true
    }

    local resources = {}
    local id = 1
    local placed = {}

    local function try_place(rtype, health, zone_min, zone_max)
        for _ = 1, 50 do  -- макс попыток
            local x = random_pos_range(zone_min, zone_max)
            local y = random_pos_range(zone_min, zone_max)

            -- Не ближе 150 к костру
            if distance(x, y, CAMPFIRE_X, CAMPFIRE_Y) < 150 then
                -- skip
            else
                -- Минимум 100 px между ресурсами
                local too_close = false
                for _, p in ipairs(placed) do
                    if distance(x, y, p.x, p.y) < 100 then
                        too_close = true
                        break
                    end
                end
                if not too_close then
                    local rid = tostring(id)
                    resources[rid] = {
                        type = rtype, x = x, y = y,
                        health = health, max_health = health,
                        respawn_at = nil
                    }
                    placed[#placed + 1] = { x = x, y = y }
                    id = id + 1
                    return true
                end
            end
        end
        return false
    end

    -- 40 деревьев (в основном лесная зона)
    for _ = 1, 40 do try_place("tree", 3, 100, 1900) end
    -- 20 камней
    for _ = 1, 20 do try_place("rock", 5, 100, 1900) end
    -- 15 кустов
    for _ = 1, 15 do try_place("bush", 1, 100, 1900) end
    -- 10 iron_ore (дальше от центра)
    for _ = 1, 10 do try_place("iron_ore", 7, 1400, 1900) end
    -- Вторая зона iron_ore
    for _ = 1, 5 do try_place("iron_ore", 7, 100, 600) end

    state.resources = resources
    state.next_resource_id = id

    -- Начальный верстак рядом с костром
    state.structures = {
        ["1"] = {
            type = "workbench", x = CAMPFIRE_X + 50, y = CAMPFIRE_Y,
            health = 100, owner_id = nil, data = {}
        }
    }
    state.next_structure_id = 2

    -- Немного fiber рядом со стартом
    state.ground_items = {}
    local gid = 1
    for _ = 1, 5 do
        local fx = CAMPFIRE_X + random_pos_range(-200, 200)
        local fy = CAMPFIRE_Y + random_pos_range(-200, 200)
        state.ground_items[tostring(gid)] = {
            type = "fiber", x = fx, y = fy, amount = 2,
            despawn_tick = nil
        }
        gid = gid + 1
    end
    state.next_ground_id = gid
end

-- ============================================================
-- Match Callbacks
-- ============================================================

local M = {}

function M.match_init(context, params)
    local max_players = tonumber(params.max_players) or 4
    if max_players > 6 then max_players = 6 end
    if max_players < 2 then max_players = 2 end

    local state = {
        game_slug    = "island_survival",
        max_players  = max_players,
        player_count = 0,
        tick_count   = 0,
        presences    = {},
        players      = {},
        dirty        = {},

        day_night = {
            current_tick     = 0,
            day_length       = 600,
            night_length     = 400,
            is_night         = false,
            day_number       = 1,
            total_days_target = 30,
        },

        campfire = {},
        resources = {},
        structures = {},
        enemies = {},
        ground_items = {},

        next_enemy_id     = 1,
        next_resource_id  = 1,
        next_structure_id = 1,
        next_ground_id    = 1,

        last_action_tick = {},
        pending_respawns = {},  -- {uid -> respawn_tick}
    }

    -- Восстановление или генерация мира
    if params.saved_match_id and params.saved_match_id ~= "" then
        local objects = nk.storage_read({
            { collection = SAVE_COLLECTION, key = params.saved_match_id, user_id = nil }
        })
        if objects and #objects > 0 then
            local saved = objects[1].value
            state.players          = saved.players or {}
            state.resources        = saved.resources or {}
            state.structures       = saved.structures or {}
            state.enemies          = saved.enemies or {}
            state.ground_items     = saved.ground_items or {}
            state.campfire         = saved.campfire or state.campfire
            state.day_night        = saved.day_night or state.day_night
            state.next_enemy_id    = saved.next_enemy_id or 1
            state.next_resource_id = saved.next_resource_id or 1
            state.next_structure_id = saved.next_structure_id or 1
            state.next_ground_id   = saved.next_ground_id or 1

            for uid, p in pairs(state.players) do
                p.disconnected_at = 0
                p.session_id = nil
            end
            nk.logger_info("Island Survival match restored: " .. params.saved_match_id)
        else
            generate_world(state)
        end
    else
        generate_world(state)
    end

    local tick_rate = 10
    local label = make_label(state)
    return state, tick_rate, label
end

function M.match_join_attempt(context, dispatcher, tick, state, presence, metadata)
    if state.players[presence.user_id] then
        return state, true  -- reconnect
    end
    if state.player_count >= state.max_players then
        return state, false, "Комната заполнена"
    end
    return state, true
end

function M.match_join(context, dispatcher, tick, state, presences)
    for _, presence in ipairs(presences) do
        local uid = presence.user_id

        if state.players[uid] then
            -- Reconnect
            state.players[uid].session_id = presence.session_id
            state.players[uid].disconnected_at = nil
            nk.logger_info("Island Survival reconnect: " .. uid)
        else
            -- Новый игрок — спавн у костра
            local sx = CAMPFIRE_X + random_pos_range(-100, 100)
            local sy = CAMPFIRE_Y + random_pos_range(-100, 100)
            state.players[uid] = {
                username  = presence.username,
                x = sx, y = sy,
                health = 100,
                hunger = 100,
                inventory = {},
                equipped  = nil,
                is_alive  = true,
                deaths    = 0,
                kills     = 0,
                resources_gathered = 0,
                session_id = presence.session_id,
                disconnected_at = nil,
            }
            state.player_count = state.player_count + 1
            nk.logger_info("Island Survival player joined: " .. uid)
        end

        state.presences[uid] = presence

        -- Full world state только новому игроку
        local world = nk.json_encode({
            players      = state.players,
            resources    = state.resources,
            structures   = state.structures,
            enemies      = state.enemies,
            ground_items = state.ground_items,
            campfire     = state.campfire,
            day_night    = state.day_night,
        })
        dispatcher.broadcast_message(OP_WORLD_STATE, world, { presence })

        -- PLAYER_JOINED всем остальным
        local join_msg = nk.json_encode({
            user_id  = uid,
            username = state.players[uid].username,
            x = state.players[uid].x,
            y = state.players[uid].y,
        })
        local others = {}
        for other_uid, other_pres in pairs(state.presences) do
            if other_uid ~= uid then
                others[#others + 1] = other_pres
            end
        end
        if #others > 0 then
            dispatcher.broadcast_message(OP_PLAYER_JOINED, join_msg, others)
        end
    end

    state.player_count = count_active_players(state)
    dispatcher.match_label_update(make_label(state))
    return state
end

function M.match_loop(context, dispatcher, tick, state, messages)
    state.tick_count = tick

    -- Собираем active presences один раз
    local function get_active()
        local active = {}
        for uid, pres in pairs(state.presences) do
            if state.players[uid] and not state.players[uid].disconnected_at then
                active[#active + 1] = pres
            end
        end
        return active
    end

    local function send_to_player(uid, op, data)
        if state.presences[uid] then
            dispatcher.broadcast_message(op, nk.json_encode(data), { state.presences[uid] })
        end
    end

    local function broadcast_all(op, data)
        local active = get_active()
        if #active > 0 then
            dispatcher.broadcast_message(op, nk.json_encode(data), active)
        end
    end

    -- ============================================
    -- 1. Обработка входящих сообщений
    -- ============================================
    for _, msg in ipairs(messages) do
        local uid = msg.sender.user_id
        local op  = msg.op_code
        local player = state.players[uid]

        if not player or player.disconnected_at or not player.is_alive then
            goto continue_msg
        end

        local ok, data = pcall(nk.json_decode, msg.data)
        if not ok then data = {} end

        if op == OP_PLAYER_MOVE then
            local dx = tonumber(data.dx) or 0
            local dy = tonumber(data.dy) or 0
            if dx * dx + dy * dy <= MAX_SPEED_SQ then
                player.x = clamp(player.x + dx, 0, WORLD_WIDTH)
                player.y = clamp(player.y + dy, 0, WORLD_HEIGHT)
                state.dirty["player_" .. uid] = true
            else
                send_to_player(uid, OP_ERROR, { code = "SPEED_HACK", message = "Превышена скорость" })
            end

        elseif op == OP_GATHER then
            local rid = data.resource_id
            local res = rid and state.resources[tostring(rid)]
            if not res or (res.health and res.health <= 0) then
                goto continue_msg
            end

            if distance(player.x, player.y, res.x, res.y) > 80 then
                send_to_player(uid, OP_ERROR, { code = "TOO_FAR", message = "Слишком далеко" })
                goto continue_msg
            end

            local required_tool = GATHER_TOOL[res.type]
            if required_tool and player.equipped ~= required_tool then
                send_to_player(uid, OP_ERROR, { code = "WRONG_TOOL", message = "Нужен: " .. required_tool })
                goto continue_msg
            end

            res.health = res.health - 1
            state.dirty["res_" .. tostring(rid)] = true

            if res.health <= 0 then
                local drop = GATHER_DROP[res.type]
                if drop then
                    if inventory_add(player.inventory, drop, 1) then
                        player.resources_gathered = player.resources_gathered + 1
                        send_to_player(uid, OP_INVENTORY_UPDATE, { inventory = player.inventory })
                    end
                end
                res.respawn_at = tick + RESOURCE_RESPAWN
                broadcast_all(OP_RESOURCE_UPDATE, { id = tostring(rid), removed = true })
            else
                broadcast_all(OP_RESOURCE_UPDATE, { id = tostring(rid), health = res.health })
            end

        elseif op == OP_CRAFT then
            -- Rate limit
            if state.last_action_tick[uid] and state.last_action_tick[uid] >= tick then
                send_to_player(uid, OP_ERROR, { code = "RATE_LIMIT", message = "Подождите" })
                goto continue_msg
            end
            state.last_action_tick[uid] = tick

            local recipe_name = data.recipe
            local recipe = recipe_name and RECIPES[recipe_name]
            if not recipe then
                send_to_player(uid, OP_ERROR, { code = "BAD_RECIPE", message = "Неизвестный рецепт" })
                goto continue_msg
            end

            -- cooked_meat требует близости к костру
            if recipe_name == "cooked_meat" then
                if distance(player.x, player.y, state.campfire.x, state.campfire.y) > 150 then
                    send_to_player(uid, OP_ERROR, { code = "TOO_FAR", message = "Нужен костёр рядом" })
                    goto continue_msg
                end
                if not state.campfire.is_lit then
                    send_to_player(uid, OP_ERROR, { code = "NO_FIRE", message = "Костёр не горит" })
                    goto continue_msg
                end
            end

            -- Проверить ресурсы
            for res_type, amount in pairs(recipe) do
                if not inventory_has(player.inventory, res_type, amount) then
                    send_to_player(uid, OP_ERROR, { code = "NO_RESOURCES", message = "Не хватает: " .. res_type })
                    goto continue_msg
                end
            end

            -- Проверить место в инвентаре
            if not inventory_has_item(player.inventory, recipe_name) and inventory_count(player.inventory) >= MAX_INVENTORY then
                send_to_player(uid, OP_ERROR, { code = "INVENTORY_FULL", message = "Инвентарь полон" })
                goto continue_msg
            end

            -- Забрать ресурсы и дать предмет
            for res_type, amount in pairs(recipe) do
                inventory_remove(player.inventory, res_type, amount)
            end
            inventory_add(player.inventory, recipe_name, 1)
            send_to_player(uid, OP_INVENTORY_UPDATE, { inventory = player.inventory })

        elseif op == OP_BUILD then
            if state.last_action_tick[uid] and state.last_action_tick[uid] >= tick then
                goto continue_msg
            end
            state.last_action_tick[uid] = tick

            local stype = data.structure_type
            local kit_map = { wall = "wall_kit", trap = "trap_kit" }
            local kit_needed = kit_map[stype]

            if not kit_needed then
                send_to_player(uid, OP_ERROR, { code = "BAD_TYPE", message = "Нельзя построить" })
                goto continue_msg
            end

            if not inventory_has(player.inventory, kit_needed, 1) then
                send_to_player(uid, OP_ERROR, { code = "NO_KIT", message = "Нет " .. kit_needed })
                goto continue_msg
            end

            local bx = tonumber(data.x) or player.x
            local by = tonumber(data.y) or player.y
            bx = clamp(bx, 0, WORLD_WIDTH)
            by = clamp(by, 0, WORLD_HEIGHT)

            -- Проверка расстояния
            if distance(player.x, player.y, bx, by) > 100 then
                send_to_player(uid, OP_ERROR, { code = "TOO_FAR", message = "Слишком далеко" })
                goto continue_msg
            end

            -- Проверка коллизий со структурами
            local collision = false
            for _, s in pairs(state.structures) do
                if distance(bx, by, s.x, s.y) < 40 then
                    collision = true
                    break
                end
            end
            if collision then
                send_to_player(uid, OP_ERROR, { code = "COLLISION", message = "Место занято" })
                goto continue_msg
            end

            inventory_remove(player.inventory, kit_needed, 1)
            local sid = tostring(state.next_structure_id)
            state.next_structure_id = state.next_structure_id + 1

            local struct_health = 100
            if stype == "trap" then struct_health = 50 end

            state.structures[sid] = {
                type = stype, x = bx, y = by,
                health = struct_health, owner_id = uid, data = {}
            }

            send_to_player(uid, OP_INVENTORY_UPDATE, { inventory = player.inventory })
            broadcast_all(OP_STRUCTURE_UPDATE, {
                id = sid, type = stype, x = bx, y = by, health = struct_health
            })

        elseif op == OP_EQUIP then
            local item_type = data.item_type
            if item_type == nil or item_type == "" then
                player.equipped = nil  -- снять
            else
                if inventory_has_item(player.inventory, item_type) then
                    player.equipped = item_type
                else
                    send_to_player(uid, OP_ERROR, { code = "NO_ITEM", message = "Нет в инвентаре" })
                end
            end
            state.dirty["player_" .. uid] = true

        elseif op == OP_USE_ITEM then
            local item_type = data.item_type
            if not item_type or not inventory_has(player.inventory, item_type, 1) then
                send_to_player(uid, OP_ERROR, { code = "NO_ITEM", message = "Нет предмета" })
                goto continue_msg
            end

            if item_type == "bandage" then
                player.health = clamp(player.health + 30, 0, 100)
                inventory_remove(player.inventory, "bandage", 1)
            elseif item_type == "berries" then
                player.hunger = clamp(player.hunger + 15, 0, 100)
                inventory_remove(player.inventory, "berries", 1)
            elseif item_type == "cooked_meat" then
                player.hunger = clamp(player.hunger + 40, 0, 100)
                player.health = clamp(player.health + 10, 0, 100)
                inventory_remove(player.inventory, "cooked_meat", 1)
            else
                send_to_player(uid, OP_ERROR, { code = "CANT_USE", message = "Нельзя использовать" })
                goto continue_msg
            end

            state.dirty["player_" .. uid] = true
            send_to_player(uid, OP_INVENTORY_UPDATE, { inventory = player.inventory })

        elseif op == OP_ATTACK then
            if state.last_action_tick[uid] and state.last_action_tick[uid] >= tick then
                goto continue_msg
            end
            state.last_action_tick[uid] = tick

            local eid = data.enemy_id and tostring(data.enemy_id)
            local enemy = eid and state.enemies[eid]
            if not enemy or enemy.health <= 0 then
                goto continue_msg
            end

            if distance(player.x, player.y, enemy.x, enemy.y) > 60 then
                send_to_player(uid, OP_ERROR, { code = "TOO_FAR", message = "Слишком далеко" })
                goto continue_msg
            end

            local dmg = WEAPON_DAMAGE[player.equipped] or 5
            enemy.health = enemy.health - dmg

            if enemy.health <= 0 then
                enemy.health = 0
                player.kills = player.kills + 1

                -- Дроп
                local drop_type = ENEMY_DROP[enemy.type]
                if drop_type then
                    local gid = tostring(state.next_ground_id)
                    state.next_ground_id = state.next_ground_id + 1
                    state.ground_items[gid] = {
                        type = drop_type, x = enemy.x, y = enemy.y,
                        amount = 1, despawn_tick = tick + 600
                    }
                    broadcast_all(OP_LOOT_SPAWN, {
                        id = gid, type = drop_type, x = enemy.x, y = enemy.y, amount = 1
                    })
                end

                broadcast_all(OP_ENEMY_REMOVED, { id = eid, reason = "killed" })
                state.enemies[eid] = nil
                state.dirty["player_" .. uid] = true
            else
                broadcast_all(OP_ENEMY_UPDATE, {
                    id = eid, type = enemy.type,
                    x = enemy.x, y = enemy.y,
                    health = enemy.health, ai_state = enemy.ai_state
                })
            end

        elseif op == OP_ADD_FUEL then
            if distance(player.x, player.y, state.campfire.x, state.campfire.y) > 100 then
                send_to_player(uid, OP_ERROR, { code = "TOO_FAR", message = "Подойдите к костру" })
                goto continue_msg
            end
            if not inventory_has(player.inventory, "wood", 1) then
                send_to_player(uid, OP_ERROR, { code = "NO_WOOD", message = "Нет дров" })
                goto continue_msg
            end
            inventory_remove(player.inventory, "wood", 1)
            state.campfire.fuel = clamp(state.campfire.fuel + 20, 0, 100)
            if not state.campfire.is_lit then
                state.campfire.is_lit = true
                state.campfire.light_radius = 200
            end
            send_to_player(uid, OP_INVENTORY_UPDATE, { inventory = player.inventory })
            broadcast_all(OP_CAMPFIRE_UPDATE, {
                fuel = state.campfire.fuel,
                is_lit = state.campfire.is_lit,
                light_radius = state.campfire.light_radius
            })

        elseif op == OP_DROP_ITEM then
            local item_type = data.item_type
            local amount = tonumber(data.amount) or 1
            if not item_type or not inventory_has(player.inventory, item_type, amount) then
                send_to_player(uid, OP_ERROR, { code = "NO_ITEM", message = "Нет предмета" })
                goto continue_msg
            end
            inventory_remove(player.inventory, item_type, amount)
            if player.equipped == item_type and not inventory_has_item(player.inventory, item_type) then
                player.equipped = nil
            end
            local gid = tostring(state.next_ground_id)
            state.next_ground_id = state.next_ground_id + 1
            state.ground_items[gid] = {
                type = item_type, x = player.x, y = player.y,
                amount = amount, despawn_tick = tick + 600
            }
            send_to_player(uid, OP_INVENTORY_UPDATE, { inventory = player.inventory })
            broadcast_all(OP_LOOT_SPAWN, {
                id = gid, type = item_type, x = player.x, y = player.y, amount = amount
            })

        elseif op == OP_PICKUP_ITEM then
            local gid = data.ground_item_id and tostring(data.ground_item_id)
            local item = gid and state.ground_items[gid]
            if not item then
                goto continue_msg
            end
            if distance(player.x, player.y, item.x, item.y) > 60 then
                send_to_player(uid, OP_ERROR, { code = "TOO_FAR", message = "Слишком далеко" })
                goto continue_msg
            end
            if not inventory_add(player.inventory, item.type, item.amount) then
                send_to_player(uid, OP_ERROR, { code = "INVENTORY_FULL", message = "Инвентарь полон" })
                goto continue_msg
            end
            state.ground_items[gid] = nil
            send_to_player(uid, OP_INVENTORY_UPDATE, { inventory = player.inventory })
            broadcast_all(OP_LOOT_REMOVED, { id = gid })
        end

        ::continue_msg::
    end

    -- ============================================
    -- 2. День/ночь цикл
    -- ============================================
    local dn = state.day_night
    dn.current_tick = dn.current_tick + 1

    if not dn.is_night and dn.current_tick >= dn.day_length then
        dn.is_night = true
        dn.current_tick = 0
        broadcast_all(OP_GAME_EVENT, { type = "night_start", day = dn.day_number })
    elseif dn.is_night and dn.current_tick >= dn.night_length then
        dn.is_night = false
        dn.current_tick = 0
        dn.day_number = dn.day_number + 1

        -- Удалить оставшихся врагов на рассвете
        for eid, _ in pairs(state.enemies) do
            broadcast_all(OP_ENEMY_REMOVED, { id = eid, reason = "despawned" })
        end
        state.enemies = {}

        broadcast_all(OP_GAME_EVENT, { type = "day_start", day = dn.day_number })

        -- Победа?
        if dn.day_number > dn.total_days_target then
            local stats = {}
            for uid, p in pairs(state.players) do
                stats[uid] = {
                    username = p.username,
                    kills = p.kills,
                    deaths = p.deaths,
                    resources = p.resources_gathered
                }
            end
            broadcast_all(OP_GAME_OVER, { reason = "survived", stats = stats })
            -- match_terminate будет вызван Nakama
            return nil
        end
    end

    -- ============================================
    -- 3. AI врагов (каждые 5 тиков = 2 раза/сек)
    -- ============================================
    if tick % 5 == 0 then
        -- Спавн врагов ночью
        if dn.is_night then
            local night_tick = dn.current_tick

            -- Волки: каждые 100 тиков ночи
            if night_tick > 0 and night_tick % 100 == 0 then
                local eid = tostring(state.next_enemy_id)
                state.next_enemy_id = state.next_enemy_id + 1
                local sx = random_pos_range(100, 300)
                local sy = random_pos_range(100, 300)
                -- Спавн от краёв
                if math.random() > 0.5 then sx = WORLD_WIDTH - sx end
                if math.random() > 0.5 then sy = WORLD_HEIGHT - sy end
                local stats = ENEMY_STATS.wolf
                state.enemies[eid] = {
                    type = "wolf", x = sx, y = sy,
                    health = stats.health, max_health = stats.health,
                    damage = stats.damage, speed = stats.speed,
                    ai_state = "idle", target_uid = nil, spawn_tick = tick,
                    last_attack_tick = 0,
                }
                broadcast_all(OP_ENEMY_UPDATE, {
                    id = eid, type = "wolf", x = sx, y = sy,
                    health = stats.health, ai_state = "idle"
                })
            end

            -- Cultist: каждые 200 тиков, начиная с day 5
            if dn.day_number >= 5 and night_tick > 0 and night_tick % 200 == 0 then
                local eid = tostring(state.next_enemy_id)
                state.next_enemy_id = state.next_enemy_id + 1
                local sx = random_pos_range(50, 200)
                local sy = random_pos_range(50, 200)
                if math.random() > 0.5 then sx = WORLD_WIDTH - sx end
                if math.random() > 0.5 then sy = WORLD_HEIGHT - sy end
                local stats = ENEMY_STATS.cultist
                state.enemies[eid] = {
                    type = "cultist", x = sx, y = sy,
                    health = stats.health, max_health = stats.health,
                    damage = stats.damage, speed = stats.speed,
                    ai_state = "idle", target_uid = nil, spawn_tick = tick,
                    last_attack_tick = 0,
                }
                broadcast_all(OP_ENEMY_UPDATE, {
                    id = eid, type = "cultist", x = sx, y = sy,
                    health = stats.health, ai_state = "idle"
                })
            end

            -- Deer Monster: дни 10, 20, 30, один раз в начале ночи
            if (dn.day_number == 10 or dn.day_number == 20 or dn.day_number == 30) and night_tick == 5 then
                local eid = tostring(state.next_enemy_id)
                state.next_enemy_id = state.next_enemy_id + 1
                local stats = ENEMY_STATS.deer_monster
                state.enemies[eid] = {
                    type = "deer_monster", x = 100, y = 100,
                    health = stats.health, max_health = stats.health,
                    damage = stats.damage, speed = stats.speed,
                    ai_state = "idle", target_uid = nil, spawn_tick = tick,
                    last_attack_tick = 0,
                }
                broadcast_all(OP_GAME_EVENT, { type = "boss_spawn", enemy_type = "deer_monster" })
                broadcast_all(OP_ENEMY_UPDATE, {
                    id = eid, type = "deer_monster", x = 100, y = 100,
                    health = stats.health, ai_state = "idle"
                })
            end
        end

        -- AI поведение для всех врагов
        local enemies_to_remove = {}
        for eid, enemy in pairs(state.enemies) do
            if enemy.health <= 0 then
                goto continue_ai
            end

            local stats = ENEMY_STATS[enemy.type]
            if not stats then goto continue_ai end

            -- Найти ближайшего живого игрока
            local nearest_uid = nil
            local nearest_dist = 99999

            for uid, p in pairs(state.players) do
                if p.is_alive and not p.disconnected_at then
                    local d = distance(enemy.x, enemy.y, p.x, p.y)
                    if d < nearest_dist then
                        nearest_dist = d
                        nearest_uid = uid
                    end
                end
            end

            -- Deer monster боится света костра
            if enemy.type == "deer_monster" and state.campfire.is_lit then
                local campfire_dist = distance(enemy.x, enemy.y, state.campfire.x, state.campfire.y)
                if campfire_dist < state.campfire.light_radius then
                    -- Отступить от костра
                    local dx = enemy.x - state.campfire.x
                    local dy = enemy.y - state.campfire.y
                    local len = math.sqrt(dx * dx + dy * dy)
                    if len > 0 then
                        enemy.x = enemy.x + (dx / len) * stats.speed
                        enemy.y = enemy.y + (dy / len) * stats.speed
                    end
                    enemy.ai_state = "fleeing"
                    broadcast_all(OP_ENEMY_UPDATE, {
                        id = eid, type = enemy.type,
                        x = enemy.x, y = enemy.y,
                        health = enemy.health, ai_state = enemy.ai_state
                    })
                    goto continue_ai
                end
            end

            if nearest_uid and nearest_dist < stats.detect_range then
                local target = state.players[nearest_uid]
                enemy.target_uid = nearest_uid
                enemy.ai_state = "chase"

                if nearest_dist <= stats.attack_range then
                    -- Атака (каждые 10 тиков = 1 раз/сек)
                    enemy.ai_state = "attack"
                    if tick - enemy.last_attack_tick >= 10 then
                        enemy.last_attack_tick = tick
                        target.health = target.health - enemy.damage
                        state.dirty["player_" .. nearest_uid] = true

                        if target.health <= 0 then
                            target.health = 0
                            target.is_alive = false
                            target.deaths = target.deaths + 1

                            broadcast_all(OP_PLAYER_DIED, {
                                user_id = nearest_uid, killer_type = enemy.type
                            })

                            -- Дроп половины инвентаря
                            local drop_count = 0
                            for i, slot in ipairs(target.inventory) do
                                if slot and drop_count < 5 then
                                    local gid = tostring(state.next_ground_id)
                                    state.next_ground_id = state.next_ground_id + 1
                                    local half = math.ceil(slot.amount / 2)
                                    state.ground_items[gid] = {
                                        type = slot.type, x = target.x, y = target.y,
                                        amount = half, despawn_tick = tick + 600
                                    }
                                    broadcast_all(OP_LOOT_SPAWN, {
                                        id = gid, type = slot.type,
                                        x = target.x, y = target.y, amount = half
                                    })
                                    slot.amount = slot.amount - half
                                    if slot.amount <= 0 then
                                        target.inventory[i] = nil
                                    end
                                    drop_count = drop_count + 1
                                end
                            end
                            target.equipped = nil
                            send_to_player(nearest_uid, OP_INVENTORY_UPDATE, { inventory = target.inventory })

                            -- Респавн через 5 сек
                            state.pending_respawns[nearest_uid] = tick + RESPAWN_TICKS
                        end
                    end
                else
                    -- Преследование
                    local dx = target.x - enemy.x
                    local dy = target.y - enemy.y
                    local len = math.sqrt(dx * dx + dy * dy)
                    if len > 0 then
                        enemy.x = enemy.x + (dx / len) * stats.speed
                        enemy.y = enemy.y + (dy / len) * stats.speed
                    end
                end

                -- Cultist атакует структуры по пути
                if enemy.type == "cultist" and enemy.ai_state == "chase" then
                    for sid, struct in pairs(state.structures) do
                        if struct.type ~= "workbench" and distance(enemy.x, enemy.y, struct.x, struct.y) < 40 then
                            struct.health = struct.health - 5
                            if struct.health <= 0 then
                                broadcast_all(OP_STRUCTURE_UPDATE, { id = sid, removed = true })
                                state.structures[sid] = nil
                            else
                                broadcast_all(OP_STRUCTURE_UPDATE, {
                                    id = sid, type = struct.type,
                                    x = struct.x, y = struct.y, health = struct.health
                                })
                            end
                            break
                        end
                    end
                end

                broadcast_all(OP_ENEMY_UPDATE, {
                    id = eid, type = enemy.type,
                    x = enemy.x, y = enemy.y,
                    health = enemy.health, ai_state = enemy.ai_state
                })
            else
                -- Idle — медленное случайное движение
                if enemy.ai_state ~= "idle" then
                    enemy.ai_state = "idle"
                    enemy.target_uid = nil
                end
                enemy.x = clamp(enemy.x + (math.random() - 0.5) * 2, 50, WORLD_WIDTH - 50)
                enemy.y = clamp(enemy.y + (math.random() - 0.5) * 2, 50, WORLD_HEIGHT - 50)
            end

            -- Trap проверка
            for sid, struct in pairs(state.structures) do
                if struct.type == "trap" and distance(enemy.x, enemy.y, struct.x, struct.y) < 30 then
                    enemy.health = enemy.health - 50
                    broadcast_all(OP_STRUCTURE_UPDATE, { id = sid, removed = true })
                    state.structures[sid] = nil

                    if enemy.health <= 0 then
                        enemy.health = 0
                        local drop_type = ENEMY_DROP[enemy.type]
                        if drop_type then
                            local gid = tostring(state.next_ground_id)
                            state.next_ground_id = state.next_ground_id + 1
                            state.ground_items[gid] = {
                                type = drop_type, x = enemy.x, y = enemy.y,
                                amount = 1, despawn_tick = tick + 600
                            }
                            broadcast_all(OP_LOOT_SPAWN, {
                                id = gid, type = drop_type,
                                x = enemy.x, y = enemy.y, amount = 1
                            })
                        end
                        broadcast_all(OP_ENEMY_REMOVED, { id = eid, reason = "killed" })
                        enemies_to_remove[#enemies_to_remove + 1] = eid
                    else
                        broadcast_all(OP_ENEMY_UPDATE, {
                            id = eid, type = enemy.type,
                            x = enemy.x, y = enemy.y,
                            health = enemy.health, ai_state = "chase"
                        })
                    end
                    break
                end
            end

            ::continue_ai::
        end

        for _, eid in ipairs(enemies_to_remove) do
            state.enemies[eid] = nil
        end
    end

    -- ============================================
    -- 4. Голод, здоровье, костёр (каждые 10 тиков)
    -- ============================================
    if tick % 10 == 0 then
        for uid, player in pairs(state.players) do
            if not player.disconnected_at and player.is_alive then
                -- Голод
                player.hunger = player.hunger - 1
                if player.hunger < 0 then player.hunger = 0 end

                -- Урон от голода
                if player.hunger <= 0 then
                    player.health = player.health - 2
                end

                -- Урон от тьмы ночью без костра
                if dn.is_night and not state.campfire.is_lit then
                    player.health = player.health - 1
                end

                -- Регенерация если сытый
                if player.hunger > 50 and player.health < 100 then
                    player.health = player.health + 1
                end

                player.health = clamp(player.health, 0, 100)
                state.dirty["player_" .. uid] = true

                -- Смерть от голода/тьмы
                if player.health <= 0 and player.is_alive then
                    player.is_alive = false
                    player.deaths = player.deaths + 1
                    broadcast_all(OP_PLAYER_DIED, { user_id = uid, killer_type = "environment" })
                    state.pending_respawns[uid] = tick + RESPAWN_TICKS
                end
            end
        end

        -- Костёр
        if dn.is_night then
            state.campfire.fuel = state.campfire.fuel - 0.5
            if state.campfire.fuel <= 0 then
                state.campfire.fuel = 0
                state.campfire.is_lit = false
                state.campfire.light_radius = 0
            end
            broadcast_all(OP_CAMPFIRE_UPDATE, {
                fuel = state.campfire.fuel,
                is_lit = state.campfire.is_lit,
                light_radius = state.campfire.light_radius
            })
        elseif state.campfire.fuel > 0 and not state.campfire.is_lit then
            state.campfire.is_lit = true
            state.campfire.light_radius = 200
            broadcast_all(OP_CAMPFIRE_UPDATE, {
                fuel = state.campfire.fuel,
                is_lit = state.campfire.is_lit,
                light_radius = state.campfire.light_radius
            })
        end

        -- Resource respawn
        for rid, res in pairs(state.resources) do
            if res.respawn_at and tick >= res.respawn_at then
                res.health = res.max_health
                res.respawn_at = nil
                broadcast_all(OP_RESOURCE_UPDATE, {
                    id = rid, type = res.type,
                    x = res.x, y = res.y,
                    health = res.health, respawned = true
                })
            end
        end

        -- Ground items despawn
        local items_to_remove = {}
        for gid, item in pairs(state.ground_items) do
            if item.despawn_tick and tick >= item.despawn_tick then
                items_to_remove[#items_to_remove + 1] = gid
            end
        end
        for _, gid in ipairs(items_to_remove) do
            state.ground_items[gid] = nil
            broadcast_all(OP_LOOT_REMOVED, { id = gid })
        end
    end

    -- ============================================
    -- 5. Респавн мёртвых игроков
    -- ============================================
    local respawned = {}
    for uid, respawn_tick in pairs(state.pending_respawns) do
        if tick >= respawn_tick then
            local player = state.players[uid]
            if player then
                player.is_alive = true
                player.health = 50
                player.hunger = 50
                player.x = CAMPFIRE_X + random_pos_range(-50, 50)
                player.y = CAMPFIRE_Y + random_pos_range(-50, 50)
                player.equipped = nil
                state.dirty["player_" .. uid] = true

                broadcast_all(OP_PLAYER_RESPAWNED, {
                    user_id = uid, x = player.x, y = player.y
                })
            end
            respawned[#respawned + 1] = uid
        end
    end
    for _, uid in ipairs(respawned) do
        state.pending_respawns[uid] = nil
    end

    -- Проверка: все мертвы одновременно?
    if next(state.players) then
        local all_dead = true
        for uid, p in pairs(state.players) do
            if not p.disconnected_at then
                if p.is_alive or state.pending_respawns[uid] then
                    all_dead = false
                    break
                end
            end
        end
        if all_dead and count_active_players(state) > 0 then
            local stats = {}
            for uid, p in pairs(state.players) do
                stats[uid] = {
                    username = p.username,
                    kills = p.kills, deaths = p.deaths,
                    resources = p.resources_gathered
                }
            end
            broadcast_all(OP_GAME_OVER, { reason = "all_dead", stats = stats })
            return nil
        end
    end

    -- ============================================
    -- 6. Delta-state broadcast
    -- ============================================
    if next(state.dirty) then
        local delta = { tick = tick, players = {} }
        for key, _ in pairs(state.dirty) do
            local uid = key:match("^player_(.+)$")
            if uid and state.players[uid] then
                delta.players[uid] = {
                    x = state.players[uid].x,
                    y = state.players[uid].y,
                    health = state.players[uid].health,
                    hunger = state.players[uid].hunger,
                    equipped = state.players[uid].equipped,
                    is_alive = state.players[uid].is_alive,
                }
            end
        end
        if next(delta.players) then
            broadcast_all(OP_WORLD_DELTA, delta)
        end
        state.dirty = {}
    end

    -- ============================================
    -- 7. Автосохранение
    -- ============================================
    if tick % AUTOSAVE_INTERVAL == 0 and tick > 0 then
        save_match_state(state, context.match_id)
    end

    -- ============================================
    -- 8. Disconnect timeout
    -- ============================================
    if next(state.players) then
        local all_gone = true
        for _, p in pairs(state.players) do
            if not p.disconnected_at then
                all_gone = false
                break
            end
            if (tick - p.disconnected_at) < DISCONNECT_TIMEOUT then
                all_gone = false
                break
            end
        end
        if all_gone then
            save_match_state(state, context.match_id)
            return nil
        end
    end

    return state
end

function M.match_leave(context, dispatcher, tick, state, presences)
    for _, presence in ipairs(presences) do
        local uid = presence.user_id
        if state.players[uid] then
            state.players[uid].disconnected_at = tick
            state.players[uid].session_id = nil
        end
        state.presences[uid] = nil

        local leave_msg = nk.json_encode({ user_id = uid })
        local active = {}
        for other_uid, other_pres in pairs(state.presences) do
            active[#active + 1] = other_pres
        end
        if #active > 0 then
            dispatcher.broadcast_message(OP_PLAYER_LEFT, leave_msg, active)
        end
    end

    state.player_count = count_active_players(state)
    dispatcher.match_label_update(make_label(state))
    return state
end

function M.match_terminate(context, dispatcher, tick, state, grace_seconds)
    save_match_state(state, context.match_id)

    local day_number = state.day_night.day_number or 1
    local survived = day_number > state.day_night.total_days_target

    for uid, player in pairs(state.players) do
        -- Награда: day*2 + kills*3 + resources*0.5, cap 200, x2 если выжил
        local coins = math.floor(day_number * 2 + player.kills * 3 + player.resources_gathered * 0.5)
        if survived then coins = coins * 2 end
        if coins > 200 then coins = 200 end
        if coins < 0 then coins = 0 end

        if coins > 0 then
            local ok, err = pcall(nk.wallet_update, uid, { playcoin = coins }, {
                source = "island_survival_mp",
                match_id = context.match_id,
                days = day_number,
                kills = player.kills
            }, true)
            if not ok then
                nk.logger_warn("Wallet update failed for " .. uid .. ": " .. tostring(err))
            end
        end

        -- Лидерборд
        local score = day_number * 50 + player.kills * 10
        pcall(nk.leaderboard_record_write, "survival_leaderboard", uid, player.username or "", score, day_number, {
            multiplayer = true,
            kills = player.kills,
            survived = survived
        })

        -- Platform total score
        pcall(nk.leaderboard_record_write, "platform_total_score", uid, player.username or "", score, 1, {})
    end

    nk.logger_info("Island Survival match ended: " .. context.match_id ..
        " | Day " .. day_number .. " | Survived: " .. tostring(survived))
    return nil
end

-- ============================================================
-- Registration
-- ============================================================

nk.register_match(M, "island_survival_match")

-- RPC для создания Island Survival матча
nk.register_rpc(function(context, payload)
    local ok, data = pcall(nk.json_decode, payload)
    if not ok or not data then
        data = {}
    end

    local params = {
        game_slug      = "island_survival",
        max_players    = data.max_players or 6,
        saved_match_id = data.saved_match_id or ""
    }

    local match_id = nk.match_create("island_survival_match", params)
    return nk.json_encode({ match_id = match_id })
end, "games/island_survival/create_match")

return {}
