-- PlayRU Platform - Room Manager
-- Система комнат с invite-кодами, поиск матчей, matchmaking

local nk = require("nakama")

-- Символы для invite-кодов (без 0/O/1/I/L для читаемости)
local CODE_CHARS   = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
local CODE_LENGTH  = 6
local CODE_COLLECTION = "room_codes"

-- Маппинг game_slug → специфичный match handler
-- Игры без записи используют generic "match_handler"
local MATCH_HANDLERS = {
    island_survival = "island_survival_match",
    -- future games:
    -- arena_shooter = "arena_match",
}

-- Генерация invite-кода
local function generate_invite_code()
    local code = {}
    for i = 1, CODE_LENGTH do
        local idx = math.random(1, #CODE_CHARS)
        code[i] = CODE_CHARS:sub(idx, idx)
    end
    return table.concat(code)
end

-- Генерация уникального кода (с проверкой коллизий)
local function generate_unique_code()
    for _ = 1, 10 do
        local code = generate_invite_code()
        local existing = nk.storage_read({
            { collection = CODE_COLLECTION, key = code, user_id = nil }
        })
        if not existing or #existing == 0 then
            return code
        end
    end
    -- Фоллбэк: добавить timestamp
    return generate_invite_code() .. tostring(nk.time()):sub(-2)
end

-- RPC: Создать комнату
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

    -- Создать матч (game-specific handler или generic)
    local handler = MATCH_HANDLERS[params.game_slug] or "match_handler"
    local match_id = nk.match_create(handler, params)

    -- Сгенерировать invite-код
    local invite_code = generate_unique_code()

    -- Сохранить маппинг code -> match_id
    nk.storage_write({
        {
            collection       = CODE_COLLECTION,
            key              = invite_code,
            user_id          = nil,
            value            = {
                match_id   = match_id,
                game_slug  = params.game_slug,
                created_by = context.user_id,
                created_at = nk.time()
            },
            permission_read  = 0,
            permission_write = 0
        }
    })

    nk.logger_info("Room created: " .. match_id .. " code: " .. invite_code)

    return nk.json_encode({
        match_id    = match_id,
        invite_code = invite_code
    })
end, "room/create")

-- RPC: Присоединиться по invite-коду
nk.register_rpc(function(context, payload)
    local ok, data = pcall(nk.json_decode, payload)
    if not ok or not data or not data.code then
        return nk.json_encode({ error = "Укажите код комнаты" })
    end

    local code = tostring(data.code):upper():gsub("%s", "")

    local objects = nk.storage_read({
        { collection = CODE_COLLECTION, key = code, user_id = nil }
    })

    if not objects or #objects == 0 then
        return nk.json_encode({ error = "Код не найден" })
    end

    local room_data = objects[1].value

    -- Проверить что матч ещё существует
    local matches = nk.match_list(1, nil, nil, nil, nil, '+label.open:true')
    local match_alive = false
    if matches then
        for _, m in ipairs(matches) do
            if m.match_id == room_data.match_id then
                match_alive = true
                break
            end
        end
    end

    -- Даже если матч не найден в listing, вернуть ID — клиент получит ошибку при join
    return nk.json_encode({
        match_id  = room_data.match_id,
        game_slug = room_data.game_slug
    })
end, "room/join_by_code")

-- RPC: Поиск открытых комнат по игре
nk.register_rpc(function(context, payload)
    local ok, data = pcall(nk.json_decode, payload)
    if not ok or not data then
        return nk.json_encode({ error = "Некорректный JSON" })
    end

    local game_slug = data.game_slug
    if not game_slug or game_slug == "" then
        return nk.json_encode({ error = "Укажите game_slug" })
    end

    local query = '+label.game:' .. game_slug .. ' +label.open:true'
    local limit = tonumber(data.limit) or 10
    if limit > 50 then limit = 50 end

    local matches = nk.match_list(limit, nil, nil, nil, nil, query)

    local rooms = {}
    if matches then
        for _, m in ipairs(matches) do
            local label_ok, label = pcall(nk.json_decode, m.label)
            if label_ok and label then
                rooms[#rooms + 1] = {
                    match_id    = m.match_id,
                    players     = label.players or 0,
                    max_players = label.max_players or 4,
                    day         = label.day or 1,
                    game        = label.game
                }
            end
        end
    end

    return nk.json_encode({ rooms = rooms })
end, "room/find")

-- Matchmaker callback: автоматическое создание матча при срабатывании
nk.register_matchmaker_matched(function(context, matched_users)
    -- Определить game_slug из properties первого пользователя
    local game_slug = "unknown"
    local max_players = #matched_users

    if matched_users[1] and matched_users[1].properties then
        local props = matched_users[1].properties
        if props.game_slug then
            game_slug = props.game_slug
        end
        if props.max_players then
            max_players = tonumber(props.max_players) or max_players
        end
    end

    if max_players > 6 then max_players = 6 end

    local params = {
        game_slug   = game_slug,
        max_players = max_players
    }

    local handler = MATCH_HANDLERS[game_slug] or "match_handler"
    local match_id = nk.match_create(handler, params)
    nk.logger_info("Matchmaker created match (" .. handler .. "): " .. match_id .. " for " .. #matched_users .. " players")

    return match_id
end)

-- RPC: Очистка устаревших invite-кодов (cron)
nk.register_rpc(function(context, payload)
    local cutoff = nk.time() - (24 * 60 * 60 * 1000)  -- 24 часа
    local cursor = nil
    local deleted = 0

    repeat
        local objects, new_cursor = nk.storage_list(nil, CODE_COLLECTION, nil, 100, cursor)
        if objects then
            local to_delete = {}
            for _, obj in ipairs(objects) do
                if obj.value and obj.value.created_at and obj.value.created_at < cutoff then
                    to_delete[#to_delete + 1] = {
                        collection = CODE_COLLECTION,
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
end, "room/cleanup_codes")

return {}
