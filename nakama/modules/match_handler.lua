-- PlayRU Platform - Authoritative Match Handler
-- Универсальный real-time мультиплеер для всех игр платформы
-- Тик-рейт: 10 Гц | Макс игроков: 6 | Delta-state broadcast

local nk = require("nakama")

-- Op-codes: Client -> Server
local OP_PLAYER_MOVE   = 1
local OP_PLAYER_ACTION = 2
local OP_CHAT_MESSAGE  = 3
local OP_PLAYER_READY  = 4

-- Op-codes: Server -> Client
local OP_WORLD_STATE   = 10
local OP_WORLD_DELTA   = 11
local OP_PLAYER_JOINED = 12
local OP_PLAYER_LEFT   = 13
local OP_GAME_EVENT    = 14
local OP_ERROR         = 15

-- Настройки
local AUTOSAVE_INTERVAL   = 300  -- тиков (30 сек при 10 Гц)
local DISCONNECT_TIMEOUT  = 600  -- тиков (60 сек)
local DAY_LENGTH          = 600  -- тиков
local NIGHT_LENGTH        = 400  -- тиков
local MAX_SPEED_SQ        = 25   -- max_speed² per tick
local ENTITY_UPDATE_RATE  = 5    -- каждые 5 тиков (2 раза/сек)
local HUNGER_UPDATE_RATE  = 10   -- каждые 10 тиков (1 раз/сек)
local COIN_BASE_PER_DAY   = 2
local COIN_CAP            = 100

local SAVE_COLLECTION = "match_saves"
local SAVE_PERM_READ  = 0
local SAVE_PERM_WRITE = 0

-- Утилиты

local function random_spawn()
    return math.random(50, 950), math.random(50, 950)
end

local function make_label(state)
    return nk.json_encode({
        game        = state.game_slug,
        players     = state.player_count,
        max_players = state.max_players,
        open        = state.player_count < state.max_players,
        day         = state.day_night_cycle.day_number
    })
end

local function mark_dirty(state, category, key)
    if not state.dirty[category] then
        state.dirty[category] = {}
    end
    state.dirty[category][key] = true
end

local function save_match_state(state, match_id)
    local save_data = {
        players        = state.players,
        world_objects   = state.world_objects,
        entities        = state.entities,
        day_night_cycle = state.day_night_cycle,
        saved_at        = nk.time()
    }
    local write_obj = {
        {
            collection      = SAVE_COLLECTION,
            key             = match_id,
            user_id         = nil,
            value           = save_data,
            permission_read = SAVE_PERM_READ,
            permission_write = SAVE_PERM_WRITE
        }
    }
    nk.storage_write(write_obj)
end

local function load_match_state(saved_match_id)
    local objects = nk.storage_read({
        { collection = SAVE_COLLECTION, key = saved_match_id, user_id = nil }
    })
    if objects and #objects > 0 then
        return objects[1].value
    end
    return nil
end

local function build_delta(state)
    local delta = {}
    local has_changes = false

    if state.dirty.players then
        delta.players = {}
        for uid, _ in pairs(state.dirty.players) do
            if state.players[uid] then
                delta.players[uid] = state.players[uid]
                has_changes = true
            end
        end
    end

    if state.dirty.world_objects then
        delta.world_objects = {}
        for oid, _ in pairs(state.dirty.world_objects) do
            delta.world_objects[oid] = state.world_objects[oid]
            has_changes = true
        end
    end

    if state.dirty.entities then
        delta.entities = {}
        for eid, _ in pairs(state.dirty.entities) do
            delta.entities[eid] = state.entities[eid]
            has_changes = true
        end
    end

    if state.dirty.day_night then
        delta.day_night_cycle = state.day_night_cycle
        has_changes = true
    end

    return has_changes, delta
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

local function all_disconnected(state)
    for _, p in pairs(state.players) do
        if not p.disconnected_at then
            return false
        end
    end
    return true
end

local function all_disconnected_timeout(state, tick)
    for _, p in pairs(state.players) do
        if not p.disconnected_at then
            return false
        end
        if (tick - p.disconnected_at) < DISCONNECT_TIMEOUT then
            return false
        end
    end
    return true
end

-- ============================================================
-- Match Callbacks
-- ============================================================

local M = {}

function M.match_init(context, params)
    local game_slug   = params.game_slug or "unknown"
    local max_players = tonumber(params.max_players) or 4
    local tick_rate    = tonumber(params.tick_rate) or 10

    if max_players > 6 then max_players = 6 end
    if max_players < 2 then max_players = 2 end

    local state = {
        game_slug    = game_slug,
        max_players  = max_players,
        player_count = 0,
        presences    = {},
        players      = {},
        world_objects = {},
        entities     = {},
        day_night_cycle = {
            is_night    = false,
            tick_in_phase = 0,
            day_number  = 1
        },
        input_buffer = {},
        dirty        = {},
        events_queue = {},
        last_action_tick = {}
    }

    -- Восстановление сохраненного матча
    if params.saved_match_id and params.saved_match_id ~= "" then
        local saved = load_match_state(params.saved_match_id)
        if saved then
            state.players        = saved.players or {}
            state.world_objects   = saved.world_objects or {}
            state.entities        = saved.entities or {}
            state.day_night_cycle = saved.day_night_cycle or state.day_night_cycle

            -- Пометить всех игроков как disconnected для reconnect
            for uid, p in pairs(state.players) do
                p.disconnected_at = 0
                p.session_id = nil
            end

            nk.logger_info("Match restored from save: " .. params.saved_match_id)
        end
    end

    local label = make_label(state)

    return state, tick_rate, label
end

function M.match_join_attempt(context, dispatcher, tick, state, presence, metadata)
    -- Проверка: reconnect разрешён всегда
    if state.players[presence.user_id] then
        return state, true
    end

    -- Проверка лимита игроков
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

            nk.logger_info("Player reconnected: " .. uid)
        else
            -- Новый игрок
            local sx, sy = random_spawn()
            state.players[uid] = {
                user_id    = uid,
                username   = presence.username,
                session_id = presence.session_id,
                x          = sx,
                y          = sy,
                health     = 100,
                hunger     = 100,
                inventory  = {},
                joined_at  = tick,
                disconnected_at = nil
            }
            state.player_count = state.player_count + 1

            nk.logger_info("Player joined: " .. uid .. " (" .. presence.username .. ")")
        end

        state.presences[uid] = presence
        mark_dirty(state, "players", uid)

        -- Отправить WORLD_STATE только новому игроку
        local world_state = nk.json_encode({
            players        = state.players,
            world_objects   = state.world_objects,
            entities        = state.entities,
            day_night_cycle = state.day_night_cycle
        })
        dispatcher.broadcast_message(OP_WORLD_STATE, world_state, { presence })

        -- Отправить PLAYER_JOINED всем остальным
        local join_msg = nk.json_encode({
            user_id  = uid,
            username = state.players[uid].username,
            x        = state.players[uid].x,
            y        = state.players[uid].y
        })

        local others = {}
        for other_uid, other_presence in pairs(state.presences) do
            if other_uid ~= uid then
                others[#others + 1] = other_presence
            end
        end
        if #others > 0 then
            dispatcher.broadcast_message(OP_PLAYER_JOINED, join_msg, others)
        end
    end

    -- Обновить label
    state.player_count = count_active_players(state)
    local label = make_label(state)
    dispatcher.match_label_update(label)

    return state
end

function M.match_loop(context, dispatcher, tick, state, messages)
    -- ============================================
    -- 1. Обработка входящих сообщений от клиентов
    -- ============================================
    for _, msg in ipairs(messages) do
        local uid = msg.sender.user_id
        local op  = msg.op_code
        local ok, data = pcall(nk.json_decode, msg.data)
        if not ok then
            data = {}
        end

        if op == OP_PLAYER_MOVE then
            -- Валидация скорости
            local player = state.players[uid]
            if player and not player.disconnected_at then
                local dx = tonumber(data.dx) or 0
                local dy = tonumber(data.dy) or 0
                local speed_sq = dx * dx + dy * dy

                if speed_sq <= MAX_SPEED_SQ then
                    player.x = player.x + dx
                    player.y = player.y + dy
                    mark_dirty(state, "players", uid)
                else
                    -- Античит: скорость превышена
                    local err_msg = nk.json_encode({ code = "SPEED_HACK", message = "Превышена максимальная скорость" })
                    dispatcher.broadcast_message(OP_ERROR, err_msg, { state.presences[uid] })
                end
            end

        elseif op == OP_PLAYER_ACTION then
            local player = state.players[uid]
            if player and not player.disconnected_at then
                -- Rate limit: 1 action per tick per player
                if state.last_action_tick[uid] and state.last_action_tick[uid] >= tick then
                    local err_msg = nk.json_encode({ code = "RATE_LIMIT", message = "Слишком частые действия" })
                    dispatcher.broadcast_message(OP_ERROR, err_msg, { state.presences[uid] })
                else
                    state.last_action_tick[uid] = tick
                    local action = data.action

                    if action == "chop" then
                        -- Рубка дерева: проверить наличие объекта
                        local target_id = data.target_id
                        if target_id and state.world_objects[target_id] then
                            local obj = state.world_objects[target_id]
                            if obj.type == "tree" and obj.health and obj.health > 0 then
                                obj.health = obj.health - 10
                                if obj.health <= 0 then
                                    obj.health = 0
                                    -- Добавить ресурс в инвентарь
                                    player.inventory.wood = (player.inventory.wood or 0) + 1
                                    mark_dirty(state, "players", uid)
                                    state.events_queue[#state.events_queue + 1] = {
                                        type = "object_destroyed", target_id = target_id
                                    }
                                end
                                mark_dirty(state, "world_objects", target_id)
                            end
                        end

                    elseif action == "build" then
                        -- Строительство: проверить ресурсы
                        local build_type = data.build_type or "wall"
                        local cost = { wall = 3, door = 2, campfire = 5 }
                        local required = cost[build_type] or 3
                        if (player.inventory.wood or 0) >= required then
                            player.inventory.wood = player.inventory.wood - required
                            local obj_id = "obj_" .. tostring(tick) .. "_" .. uid
                            state.world_objects[obj_id] = {
                                type    = build_type,
                                x       = data.x or player.x,
                                y       = data.y or player.y,
                                health  = 100,
                                builder = uid
                            }
                            mark_dirty(state, "players", uid)
                            mark_dirty(state, "world_objects", obj_id)
                        else
                            local err_msg = nk.json_encode({ code = "NO_RESOURCES", message = "Недостаточно ресурсов" })
                            dispatcher.broadcast_message(OP_ERROR, err_msg, { state.presences[uid] })
                        end

                    elseif action == "attack" then
                        -- Атака сущности
                        local target_id = data.target_id
                        if target_id and state.entities[target_id] then
                            local entity = state.entities[target_id]
                            if entity.health and entity.health > 0 then
                                entity.health = entity.health - (data.damage or 10)
                                if entity.health <= 0 then
                                    entity.health = 0
                                    state.events_queue[#state.events_queue + 1] = {
                                        type = "entity_killed", target_id = target_id, killer = uid
                                    }
                                end
                                mark_dirty(state, "entities", target_id)
                            end
                        end

                    elseif action == "craft" then
                        -- Крафт: проверить рецепт
                        local item = data.item
                        local recipes = {
                            torch    = { wood = 1 },
                            plank    = { wood = 2 },
                            barricade = { wood = 5 }
                        }
                        local recipe = recipes[item]
                        if recipe then
                            local can_craft = true
                            for res, amount in pairs(recipe) do
                                if (player.inventory[res] or 0) < amount then
                                    can_craft = false
                                    break
                                end
                            end
                            if can_craft then
                                for res, amount in pairs(recipe) do
                                    player.inventory[res] = player.inventory[res] - amount
                                end
                                player.inventory[item] = (player.inventory[item] or 0) + 1
                                mark_dirty(state, "players", uid)
                            else
                                local err_msg = nk.json_encode({ code = "NO_RESOURCES", message = "Недостаточно ресурсов для крафта" })
                                dispatcher.broadcast_message(OP_ERROR, err_msg, { state.presences[uid] })
                            end
                        end
                    end
                    -- Game-specific actions (op 50-99) можно обрабатывать здесь
                end
            end

        elseif op == OP_CHAT_MESSAGE then
            -- Ретранслировать чат всем
            local chat_data = nk.json_encode({
                user_id  = uid,
                username = state.players[uid] and state.players[uid].username or "???",
                text     = tostring(data.text or ""):sub(1, 200)  -- лимит длины
            })
            dispatcher.broadcast_message(OP_CHAT_MESSAGE, chat_data)

        elseif op == OP_PLAYER_READY then
            if state.players[uid] then
                state.players[uid].ready = true
                mark_dirty(state, "players", uid)
            end
        end
    end

    -- ============================================
    -- 2. День/ночь цикл
    -- ============================================
    local dnc = state.day_night_cycle
    dnc.tick_in_phase = dnc.tick_in_phase + 1

    if not dnc.is_night and dnc.tick_in_phase >= DAY_LENGTH then
        dnc.is_night = true
        dnc.tick_in_phase = 0
        mark_dirty(state, "day_night", "cycle")
        state.events_queue[#state.events_queue + 1] = {
            type = "night_start", day_number = dnc.day_number
        }
    elseif dnc.is_night and dnc.tick_in_phase >= NIGHT_LENGTH then
        dnc.is_night = false
        dnc.tick_in_phase = 0
        dnc.day_number = dnc.day_number + 1
        mark_dirty(state, "day_night", "cycle")
        state.events_queue[#state.events_queue + 1] = {
            type = "day_start", day_number = dnc.day_number
        }
    end

    -- ============================================
    -- 3. AI сущностей (заглушка, каждые 5 тиков)
    -- ============================================
    if tick % ENTITY_UPDATE_RATE == 0 then
        for eid, entity in pairs(state.entities) do
            if entity.health and entity.health > 0 then
                -- Заглушка: per-game логика подключается через game-specific модули
                -- Пример: случайное движение
                -- entity.x = entity.x + math.random(-1, 1)
                -- entity.y = entity.y + math.random(-1, 1)
                -- mark_dirty(state, "entities", eid)
            end
        end
    end

    -- ============================================
    -- 4. Голод и регенерация (каждые 10 тиков)
    -- ============================================
    if tick % HUNGER_UPDATE_RATE == 0 then
        for uid, player in pairs(state.players) do
            if not player.disconnected_at then
                -- Голод
                if player.hunger > 0 then
                    player.hunger = player.hunger - 1
                    mark_dirty(state, "players", uid)
                end

                -- Регенерация HP если голод > 50
                if player.hunger > 50 and player.health < 100 then
                    player.health = math.min(100, player.health + 1)
                    mark_dirty(state, "players", uid)
                end

                -- Урон от голода
                if player.hunger <= 0 and player.health > 0 then
                    player.health = player.health - 2
                    mark_dirty(state, "players", uid)

                    if player.health <= 0 then
                        player.health = 0
                        state.events_queue[#state.events_queue + 1] = {
                            type = "player_death", user_id = uid, cause = "starvation"
                        }
                    end
                end
            end
        end
    end

    -- ============================================
    -- 5. Delta-state broadcast
    -- ============================================
    local has_changes, delta = build_delta(state)
    if has_changes then
        local active = {}
        for uid, presence in pairs(state.presences) do
            if state.players[uid] and not state.players[uid].disconnected_at then
                active[#active + 1] = presence
            end
        end
        if #active > 0 then
            delta.tick = tick
            dispatcher.broadcast_message(OP_WORLD_DELTA, nk.json_encode(delta), active)
        end
    end

    -- ============================================
    -- 6. Game events broadcast
    -- ============================================
    if #state.events_queue > 0 then
        local active = {}
        for uid, presence in pairs(state.presences) do
            if state.players[uid] and not state.players[uid].disconnected_at then
                active[#active + 1] = presence
            end
        end
        if #active > 0 then
            for _, event in ipairs(state.events_queue) do
                dispatcher.broadcast_message(OP_GAME_EVENT, nk.json_encode(event), active)
            end
        end
        state.events_queue = {}
    end

    -- ============================================
    -- 7. Очистка dirty tracking
    -- ============================================
    state.dirty = {}

    -- ============================================
    -- 8. Автосохранение
    -- ============================================
    if tick % AUTOSAVE_INTERVAL == 0 and tick > 0 then
        local match_id = context.match_id
        save_match_state(state, match_id)
    end

    -- ============================================
    -- 9. Проверка disconnect timeout
    -- ============================================
    if next(state.players) and all_disconnected_timeout(state, tick) then
        -- Все отключены дольше таймаута — сохранить и завершить
        save_match_state(state, context.match_id)
        return nil
    end

    return state
end

function M.match_leave(context, dispatcher, tick, state, presences)
    for _, presence in ipairs(presences) do
        local uid = presence.user_id
        if state.players[uid] then
            -- НЕ удаляем — помечаем disconnected для reconnect
            state.players[uid].disconnected_at = tick
            state.players[uid].session_id = nil
        end
        state.presences[uid] = nil

        -- Broadcast PLAYER_LEFT
        local leave_msg = nk.json_encode({ user_id = uid })
        local active = {}
        for other_uid, other_presence in pairs(state.presences) do
            active[#active + 1] = other_presence
        end
        if #active > 0 then
            dispatcher.broadcast_message(OP_PLAYER_LEFT, leave_msg, active)
        end
    end

    state.player_count = count_active_players(state)
    local label = make_label(state)
    dispatcher.match_label_update(label)

    return state
end

function M.match_terminate(context, dispatcher, tick, state, grace_seconds)
    -- Сохранить финальное состояние
    save_match_state(state, context.match_id)

    -- Начислить монеты участникам
    local day_number = state.day_night_cycle.day_number or 1
    local reward = math.min(day_number * COIN_BASE_PER_DAY, COIN_CAP)

    for uid, player in pairs(state.players) do
        if reward > 0 then
            local changeset = { playcoin = reward }
            local metadata  = {
                source   = "multiplayer_match",
                game     = state.game_slug,
                match_id = context.match_id,
                days     = day_number
            }
            local ok, err = pcall(nk.wallet_update, uid, changeset, metadata, true)
            if not ok then
                nk.logger_warn("Failed to award coins to " .. uid .. ": " .. tostring(err))
            end
        end
    end

    nk.logger_info("Match terminated: " .. context.match_id .. " | Days: " .. day_number .. " | Reward: " .. reward)
    return nil
end

-- ============================================================
-- Регистрация match handler и RPC
-- ============================================================

nk.register_match(M)

-- RPC: создать матч
nk.register_rpc(function(context, payload)
    local ok, data = pcall(nk.json_decode, payload)
    if not ok or not data then
        return nk.json_encode({ error = "Некорректный JSON" })
    end

    local params = {
        game_slug      = data.game_slug or "unknown",
        max_players    = data.max_players or 4,
        tick_rate       = data.tick_rate or 10,
        saved_match_id = data.saved_match_id or ""
    }

    local match_id = nk.match_create("match_handler", params)
    return nk.json_encode({ match_id = match_id })
end, "match/create")

-- RPC: очистка старых сохранений (cron)
nk.register_rpc(function(context, payload)
    local cutoff = nk.time() - (7 * 24 * 60 * 60 * 1000)  -- 7 дней в миллисекундах
    local cursor = nil
    local deleted = 0

    repeat
        local objects, new_cursor = nk.storage_list(nil, SAVE_COLLECTION, nil, 100, cursor)
        if objects then
            local to_delete = {}
            for _, obj in ipairs(objects) do
                if obj.value and obj.value.saved_at and obj.value.saved_at < cutoff then
                    to_delete[#to_delete + 1] = {
                        collection = SAVE_COLLECTION,
                        key        = obj.key,
                        user_id    = nil
                    }
                end
            end
            if #to_delete > 0 then
                nk.storage_delete(to_delete)
                deleted = deleted + #to_delete
            end
        end
        cursor = new_cursor
    until not cursor or cursor == ""

    return nk.json_encode({ deleted = deleted })
end, "match/cleanup_saves")

return M
