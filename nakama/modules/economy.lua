-- PlayRU Economy Module — PlayCoin система
local nk = require("nakama")

-- Константы наград
local REWARDS = {
    daily_login = 50,        -- ежедневный вход
    first_game_complete = 25, -- первое завершение игры в день
    invite_friend = 100,     -- пригласить друга
    level_complete = 10,     -- завершить уровень
}

-- RPC: Получить баланс кошелька
local function get_wallet(context, payload)
    local user_id = context.user_id
    local account = nk.account_get_id(user_id)
    local wallet = account.wallet or {}

    return nk.json_encode({
        user_id = user_id,
        playcoin = wallet.playcoin or 0,
        display = tostring(wallet.playcoin or 0) .. " PlayCoin"
    })
end

-- RPC: Ежедневная награда
local function claim_daily_reward(context, payload)
    local user_id = context.user_id
    local today = os.date("%Y-%m-%d")
    local storage_key = "daily_reward_" .. today

    -- Проверяем, получал ли уже сегодня
    local objects = nk.storage_read({
        {collection = "economy", key = storage_key, user_id = user_id}
    })

    if #objects > 0 then
        return nk.json_encode({
            success = false,
            message = "Ежедневная награда уже получена сегодня",
            next_claim_in_hours = 24
        })
    end

    -- Записываем факт получения
    nk.storage_write({
        {
            collection = "economy",
            key = storage_key,
            user_id = user_id,
            value = {claimed_at = nk.time()},
            permission_read = 1,
            permission_write = 0
        }
    })

    -- Начисляем монеты (Premium = 150, обычный = 50)
    local prem = require("premium")
    local amount = prem.has_premium(user_id) and 150 or REWARDS.daily_login
    nk.wallet_update(user_id, {playcoin = amount},
        {source = "daily_reward", date = today}, true)

    nk.logger_info("Daily reward claimed: user=" .. user_id .. " amount=" .. amount)

    return nk.json_encode({
        success = true,
        coins_earned = amount,
        message = "+" .. amount .. " PlayCoin! Возвращайся завтра"
    })
end

-- RPC: История транзакций кошелька
local function get_wallet_history(context, payload)
    local data = {}
    if payload and payload ~= "" and payload ~= "{}" then
        local ok, decoded = pcall(nk.json_decode, payload)
        if ok then data = decoded end
    end
    local limit = (data and data.limit) or 20
    local user_id = context.user_id

    local ledger, cursor = nk.wallet_ledger_list(user_id, limit)

    local history = {}
    for _, entry in ipairs(ledger) do
        table.insert(history, {
            id = entry.id,
            changeset = entry.changeset,
            metadata = entry.metadata,
            create_time = entry.create_time,
            update_time = entry.update_time
        })
    end

    return nk.json_encode({
        history = history,
        count = #history
    })
end

-- Регистрируем RPC
nk.register_rpc(get_wallet, "economy/wallet")
nk.register_rpc(claim_daily_reward, "economy/daily_reward")
nk.register_rpc(get_wallet_history, "economy/wallet_history")

return {}
