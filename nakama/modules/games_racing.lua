-- PlayRU: Racing Chaos — Server Logic
local nk = require("nakama")

nk.leaderboard_create("racing_leaderboard", true, "asc", "best", nil, nil, false)

local function racing_submit_result(context, payload)
    local data = {}
    if payload and payload ~= "" then
        local ok, decoded = pcall(nk.json_decode, payload)
        if ok and decoded then data = decoded end
    end
    if not data then error("Invalid payload") end

    local user_id = context.user_id
    local time_ms = data.time_ms or 0
    local position = data.position or 0
    local laps = data.laps or 0

    nk.leaderboard_record_write("racing_leaderboard", user_id, context.username or "", time_ms, laps, {
        position = position
    })

    local coins = 10
    if position == 1 then coins = 50
    elseif position == 2 then coins = 30
    elseif position == 3 then coins = 20 end

    nk.wallet_update(user_id, {playcoin = coins},
        {source = "racing", position = position}, true)

    nk.leaderboard_record_write("platform_total_score", user_id, context.username or "", 1000 - time_ms, 1, {})

    return nk.json_encode({
        success = true,
        time_ms = time_ms,
        position = position,
        coins_earned = coins
    })
end

local function racing_leaderboard(context, payload)
    local ok, records = pcall(function()
        local r, _, _, _ = nk.leaderboard_records_list("racing_leaderboard", nil, 10, nil, 0)
        return r
    end)
    if not ok then return nk.json_encode({records = {}}) end
    local result = {}
    for i, rec in ipairs(records) do
        table.insert(result, {
            rank = i,
            user_id = rec.owner_id,
            time_ms = rec.score,
            laps = rec.subscore
        })
    end
    return nk.json_encode({records = result})
end

nk.register_rpc(racing_submit_result, "games/racing/submit_result")
nk.register_rpc(racing_leaderboard, "games/racing/leaderboard")

return {}
