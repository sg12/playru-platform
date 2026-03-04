-- PlayRU: Island Survival — Server Logic
local nk = require("nakama")

local function survival_submit_result(context, payload)
    local data = nk.json_decode(payload)
    if not data then error("Invalid payload") end

    local user_id = context.user_id
    local days = data.days_survived or 0
    local resources = data.resources_gathered or 0
    local victory = data.victory or false

    nk.leaderboard_records_write("survival_leaderboard", {
        {owner_id = user_id, score = days, subscore = resources,
         metadata = {victory = victory}}
    })

    local coins = days * 8
    if victory then coins = coins + 75 end
    if resources > 50 then coins = coins + 20 end

    nk.wallet_update(user_id, {playcoin = coins},
        {source = "island_survival", days = days, victory = victory}, true)

    nk.logger_info(string.format("Survival: user=%s days=%d resources=%d victory=%s",
        user_id, days, resources, tostring(victory)))

    return nk.json_encode({
        success = true,
        days_survived = days,
        victory = victory,
        coins_earned = coins,
        message = victory and "Спасся с острова! +" .. coins .. " PlayCoin"
                  or "Выжил " .. days .. " дней. +" .. coins .. " PlayCoin"
    })
end

local function survival_leaderboard(context, payload)
    local ok, records = pcall(function()
        local r, _, _, _ = nk.leaderboard_records_list("survival_leaderboard", nil, 10, nil, 0)
        return r
    end)
    if not ok then return nk.json_encode({records = {}}) end
    local result = {}
    for i, rec in ipairs(records) do
        table.insert(result, {
            rank = i,
            user_id = rec.owner_id,
            days = rec.score,
            resources = rec.subscore
        })
    end
    return nk.json_encode({records = result})
end

pcall(function()
    nk.leaderboard_create("survival_leaderboard", true, "SCORE_DESC", "SCORE_DESC", false, {})
end)

nk.register_rpc(survival_submit_result, "games/island_survival/submit_result")
nk.register_rpc(survival_leaderboard, "games/island_survival/leaderboard")

return {}
