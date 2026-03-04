-- PlayRU Premium — бонусы для подписчиков
local nk = require("nakama")

local PREMIUM_MULTIPLIER = 2.0   -- удвоение монет
local PREMIUM_DAILY_BONUS = 150  -- вместо 50

-- Проверить есть ли Premium
local function has_premium(user_id)
    local objects = nk.storage_read({
        {collection = "premium", key = "subscription", user_id = user_id}
    })
    if #objects == 0 then return false end
    -- objects[1].value уже таблица в Nakama
    local data = objects[1].value
    if not data or not data.expires_at then return false end
    return data.expires_at > nk.time()
end

-- RPC: Активировать Premium (вызывается после успешной оплаты)
local function activate_premium(context, payload)
    local data = {}
    if payload and payload ~= "" then
        local ok, decoded = pcall(nk.json_decode, payload)
        if ok then data = decoded end
    end
    if not data.days then error("Missing days") end

    local user_id = context.user_id
    local days = math.min(data.days or 30, 365)
    local expires_at = nk.time() + days * 86400 * 1000  -- миллисекунды

    -- value должен быть таблицей, НЕ json_encode
    nk.storage_write({
        {
            collection = "premium",
            key = "subscription",
            user_id = user_id,
            value = {
                activated_at = nk.time(),
                expires_at = expires_at,
                days = days
            },
            permission_read = 1,
            permission_write = 0
        }
    })

    -- Уведомление
    nk.notifications_send({
        {
            user_id = user_id,
            subject = "PlayRU Premium activated!",
            content = {
                message = "Premium active for " .. days .. " days. Coins x2!",
                expires_days = days
            },
            code = 10,
            sender_id = "00000000-0000-0000-0000-000000000000",
            persistent = true
        }
    })

    nk.logger_info("Premium activated: " .. user_id .. " for " .. days .. " days")

    return nk.json_encode({
        success = true,
        expires_at = expires_at,
        days = days,
        perks = {"2x coins", "Daily bonus x3", "Exclusive skins"}
    })
end

-- RPC: Статус Premium
local function premium_status(context, payload)
    local user_id = context.user_id
    local is_premium = has_premium(user_id)
    local expires_at = nil

    if is_premium then
        local objects = nk.storage_read({
            {collection = "premium", key = "subscription", user_id = user_id}
        })
        if #objects > 0 then
            expires_at = objects[1].value.expires_at
        end
    end

    return nk.json_encode({
        has_premium = is_premium,
        expires_at = expires_at,
        multiplier = is_premium and PREMIUM_MULTIPLIER or 1.0,
        daily_bonus = is_premium and PREMIUM_DAILY_BONUS or 50
    })
end

-- RPC: Начислить монеты с учётом Premium множителя
local function award_coins(context, payload)
    local data = {}
    if payload and payload ~= "" then
        local ok, decoded = pcall(nk.json_decode, payload)
        if ok then data = decoded end
    end
    if not data.amount then error("Missing amount") end

    local user_id = context.user_id
    local base_amount = math.min(data.amount, 500)
    local reason = data.reason or "game_reward"

    local multiplier = has_premium(user_id) and PREMIUM_MULTIPLIER or 1.0
    local final_amount = math.floor(base_amount * multiplier)

    nk.wallet_update(user_id, {playcoin = final_amount},
        {source = reason, base = base_amount, multiplier = multiplier}, true)

    return nk.json_encode({
        success = true,
        base_amount = base_amount,
        multiplier = multiplier,
        final_amount = final_amount,
        is_premium = multiplier > 1.0
    })
end

nk.register_rpc(activate_premium, "premium/activate")
nk.register_rpc(premium_status, "premium/status")
nk.register_rpc(award_coins, "economy/award_coins")

-- Экспортируем has_premium для других модулей
return {has_premium = has_premium, MULTIPLIER = PREMIUM_MULTIPLIER}
