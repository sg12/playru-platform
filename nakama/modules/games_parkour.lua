-- PlayRU Parkour Game Module
local nk = require("nakama")

local LEADERBOARD_ID = "parkour_leaderboard"

-- Создаём лидерборд при загрузке модуля
nk.leaderboard_create(LEADERBOARD_ID, false, "desc", "set", nil, nil, false)

-- RPC: Сохранить результат паркура и начислить монеты
local function submit_score(context, payload)
    local data = {}
    if payload and payload ~= "" then
        local ok, decoded = pcall(nk.json_decode, payload)
        if ok then data = decoded end
    end

    local user_id = context.user_id
    local time_val = data.time or 0
    local deaths = data.deaths or 0
    local level = data.level or "unknown"

    -- Считаем очки: чем быстрее и меньше смертей, тем лучше
    local score = math.max(1, math.floor(1000 - time_val * 10 - deaths * 50))

    -- Записываем в лидерборд
    nk.leaderboard_record_write(LEADERBOARD_ID, user_id, context.username or "", score, 0, {
        time = time_val,
        deaths = deaths,
        level = level
    })

    -- Начисляем монеты за прохождение
    local coins_earned = 10
    nk.wallet_update(user_id, {playcoin = coins_earned},
        {source = "parkour_score", level = level, score = score}, true)

    -- Обновить суммарный счёт платформы
    nk.leaderboard_record_write("platform_total_score", user_id, context.username or "", score, 1, {})

    -- Проверяем достижения
    local ach = require("achievements")
    ach.unlock(user_id, "first_game")
    if time_val > 0 and time_val < 20 then
        ach.unlock(user_id, "parkour_master")
    end

    nk.logger_info("Parkour score: user=" .. user_id .. " score=" .. score .. " coins=" .. coins_earned)

    return nk.json_encode({
        success = true,
        score = score,
        coins_earned = coins_earned,
        level = level
    })
end

-- RPC: Получить лидерборд паркура
local function get_leaderboard(context, payload)
    local data = {}
    if payload and payload ~= "" then
        local ok, decoded = pcall(nk.json_decode, payload)
        if ok then data = decoded end
    end

    local limit = data.limit or 10
    local records, owner_records, next_cursor, prev_cursor = nk.leaderboard_records_list(
        LEADERBOARD_ID, nil, limit
    )

    local result = {}
    for _, record in ipairs(records) do
        table.insert(result, {
            user_id = record.owner_id,
            username = record.username,
            score = record.score,
            metadata = record.metadata
        })
    end

    return nk.json_encode({
        records = result,
        count = #result
    })
end

-- Регистрируем RPC
nk.register_rpc(submit_score, "games/parkour/submit_score")
nk.register_rpc(get_leaderboard, "games/parkour/leaderboard")

return {}
