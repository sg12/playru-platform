-- PlayRU: Сводный лидерборд платформы
-- Агрегирует результаты по всем играм в единый рейтинг
local nk = require("nakama")

-- Лидерборд суммарных очков
nk.leaderboard_create("platform_total_score", true, "desc", "set", nil, nil, false)

-- RPC: Топ игроков по суммарным PlayCoin
local function platform_top_players(context, payload)
    local data = {}
    if payload and payload ~= "" then
        local ok, decoded = pcall(nk.json_decode, payload)
        if ok then data = decoded end
    end
    local limit = math.min((data and data.limit) or 10, 50)

    local ok, records = pcall(function()
        local r, _, _, _ = nk.leaderboard_records_list(
            "platform_total_score", nil, limit, nil, 0)
        return r
    end)

    if not ok or not records then
        return nk.json_encode({
            players = {},
            message = "Leaderboard building..."
        })
    end

    local players = {}
    for i, record in ipairs(records) do
        table.insert(players, {
            rank = i,
            user_id = record.owner_id,
            total_score = record.score,
            games_played = record.subscore or 0
        })
    end

    return nk.json_encode({players = players, count = #players})
end

-- RPC: Обновить суммарный счёт игрока (вызывается после каждой игры)
local function platform_update_score(context, payload)
    local data = {}
    if payload and payload ~= "" then
        local ok, decoded = pcall(nk.json_decode, payload)
        if ok then data = decoded end
    end

    if not data or not data.score then
        error("Missing score")
    end

    local user_id = context.user_id

    -- Читаем текущий суммарный счёт
    local objects = nk.storage_read({
        {collection = "platform", key = "total_score", user_id = user_id}
    })

    local current = {total_score = 0, games_played = 0}
    if #objects > 0 then
        current = objects[1].value
    end

    current.total_score = current.total_score + data.score
    current.games_played = current.games_played + 1

    nk.storage_write({
        {
            collection = "platform",
            key = "total_score",
            user_id = user_id,
            value = current,
            permission_read = 2,
            permission_write = 1
        }
    })

    -- Обновляем суммарный лидерборд
    nk.leaderboard_record_write("platform_total_score", user_id, context.username or "", current.total_score, current.games_played, {})

    return nk.json_encode({
        total_score = current.total_score,
        games_played = current.games_played
    })
end

-- RPC: Статистика конкретного игрока
local function platform_player_stats(context, payload)
    local data = {}
    if payload and payload ~= "" then
        local ok, decoded = pcall(nk.json_decode, payload)
        if ok then data = decoded end
    end
    local target_id = (data and data.user_id) or context.user_id

    local objects = nk.storage_read({
        {collection = "platform", key = "total_score", user_id = target_id}
    })

    if #objects == 0 then
        return nk.json_encode({
            user_id = target_id,
            total_score = 0,
            games_played = 0,
            message = "Нет данных"
        })
    end

    local stats = objects[1].value
    stats.user_id = target_id
    return nk.json_encode(stats)
end

nk.register_rpc(platform_top_players, "platform/leaderboard")
nk.register_rpc(platform_update_score, "platform/update_score")
nk.register_rpc(platform_player_stats, "platform/player_stats")

return {}
