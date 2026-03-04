-- PlayRU: Tower Defense — Server Logic
local nk = require("nakama")

nk.leaderboard_create("td_leaderboard", true, "desc", "set", nil, nil, false)

local function td_submit_result(context, payload)
    local data = {}
    if payload and payload ~= "" then
        local ok, decoded = pcall(nk.json_decode, payload)
        if ok and decoded then data = decoded end
    end
    if not data then error("Invalid payload") end

    local user_id = context.user_id
    local waves = data.waves_survived or 0
    local kills = data.enemies_killed or 0
    local victory = data.victory or false

    nk.leaderboard_record_write("td_leaderboard", user_id, context.username or "", waves, kills, {
        victory = victory
    })

    local coins = waves * 5
    if victory then coins = coins + 50 end

    nk.wallet_update(user_id, {playcoin = coins},
        {source = "tower_defense", waves = waves, victory = tostring(victory)}, true)

    nk.leaderboard_record_write("platform_total_score", user_id, context.username or "", waves * 100, 1, {})

    return nk.json_encode({
        success = true,
        waves_survived = waves,
        enemies_killed = kills,
        victory = victory,
        coins_earned = coins
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

nk.register_rpc(td_submit_result, "games/tower_defense/submit_result")
nk.register_rpc(td_leaderboard, "games/tower_defense/leaderboard")

return {}
