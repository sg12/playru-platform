-- PlayRU: Tower Defense — Server Logic
local nk = require("nakama")

local function td_submit_result(context, payload)
    local data = nk.json_decode(payload)
    if not data then error("Invalid payload") end

    local user_id = context.user_id
    local waves = data.waves_survived or 0
    local kills = data.enemies_killed or 0
    local victory = data.victory or false

    -- Лидерборд по волнам
    nk.leaderboard_records_write("td_leaderboard", {
        {owner_id = user_id, score = waves, subscore = kills,
         metadata = {victory = victory}}
    })

    -- Монеты: 5 за волну + 50 бонус за победу
    local coins = waves * 5
    if victory then coins = coins + 50 end

    nk.wallet_update(user_id, {playcoin = coins},
        {source = "tower_defense", waves = waves, victory = victory}, true)

    nk.logger_info(string.format("TD: user=%s waves=%d kills=%d victory=%s coins=%d",
        user_id, waves, kills, tostring(victory), coins))

    return nk.json_encode({
        success = true,
        waves_survived = waves,
        enemies_killed = kills,
        victory = victory,
        coins_earned = coins,
        message = victory and "Победа! +" .. coins .. " PlayCoin"
                  or "Выжил " .. waves .. " волн. +" .. coins .. " PlayCoin"
    })
end

local function td_leaderboard(context, payload)
    local ok, records = pcall(function()
        local r, _, _, _ = nk.leaderboard_records_list("td_leaderboard", nil, 10, nil, 0)
        return r
    end)
    if not ok then return nk.json_encode({records = {}}) end
    local result = {}
    for i, rec in ipairs(records) do
        table.insert(result, {
            rank = i,
            user_id = rec.owner_id,
            waves = rec.score,
            kills = rec.subscore
        })
    end
    return nk.json_encode({records = result})
end

pcall(function()
    nk.leaderboard_create("td_leaderboard", true, "SCORE_DESC", "SCORE_DESC", false, {})
end)

nk.register_rpc(td_submit_result, "games/tower_defense/submit_result")
nk.register_rpc(td_leaderboard, "games/tower_defense/leaderboard")

return {}
