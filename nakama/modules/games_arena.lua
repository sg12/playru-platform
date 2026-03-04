-- PlayRU: Arena — PvP battle game server logic
local nk = require("nakama")

local LEADERBOARD_ID = "arena_leaderboard"

-- Создаём лидерборд при загрузке модуля
nk.leaderboard_create(LEADERBOARD_ID, false, "desc", "set", nil, nil, false)

-- RPC: Сохранить результат арены и начислить монеты
local function submit_result(context, payload)
    local data = {}
    if payload and payload ~= "" then
        local ok, decoded = pcall(nk.json_decode, payload)
        if ok then data = decoded end
    end

    local user_id = context.user_id
    local kills = data.kills or 0
    local deaths = data.deaths or 0
    local won = data.won or false

    -- Считаем очки: убийства +100, смерти -30, победа +500
    local score = kills * 100 - deaths * 30
    if won then
        score = score + 500
    end
    score = math.max(1, score)

    -- Записываем в лидерборд
    nk.leaderboard_record_write(LEADERBOARD_ID, user_id, context.username or "", score, kills, {
        kills = kills,
        deaths = deaths,
        won = won
    })

    -- Начисляем монеты
    local coins_earned = 5 + kills * 2
    if won then coins_earned = coins_earned + 20 end

    nk.wallet_update(user_id, {playcoin = coins_earned},
        {source = "arena_result", kills = kills, won = tostring(won)}, true)

    -- Обновить суммарный счёт платформы
    nk.leaderboard_record_write("platform_total_score", user_id, context.username or "", score, 1, {})

    nk.logger_info("Arena result: user=" .. user_id .. " score=" .. score .. " coins=" .. coins_earned)

    return nk.json_encode({
        success = true,
        score = score,
        coins_earned = coins_earned,
        kills = kills,
        deaths = deaths,
        won = won
    })
end

-- RPC: Получить лидерборд арены
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
nk.register_rpc(submit_result, "games/arena/submit_result")
nk.register_rpc(get_leaderboard, "games/arena/leaderboard")

return {}
