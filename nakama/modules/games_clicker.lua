-- PlayRU: Clicker World — Server Logic
-- Простой idle-кликер: тапаешь, копишь очки, покупаешь улучшения
local nk = require("nakama")

local UPGRADES = {
    auto_clicker    = {cost = 100,  cps = 1,   name = "Авто-кликер"},
    fast_fingers    = {cost = 500,  cps = 5,   name = "Быстрые пальцы"},
    click_machine   = {cost = 2000, cps = 20,  name = "Кликер-машина"},
    robot_army      = {cost = 10000,cps = 100, name = "Армия роботов"},
}

-- Лидерборд
nk.leaderboard_create("clicker_score", true, "desc", "set", nil, nil, false)

-- Загрузить состояние игры игрока
local function load_state(user_id)
    local objects = nk.storage_read({
        {collection = "clicker", key = "state", user_id = user_id}
    })
    if #objects > 0 then
        return objects[1].value
    end
    return {
        total_clicks = 0,
        score = 0,
        upgrades = {},
        last_save = nk.time()
    }
end

-- Сохранить состояние
local function save_state(user_id, state)
    state.last_save = nk.time()
    nk.storage_write({
        {
            collection = "clicker",
            key = "state",
            user_id = user_id,
            value = state,
            permission_read = 1,
            permission_write = 1
        }
    })
end

-- RPC: Синхронизация кликов (клиент отправляет пачку кликов)
local function clicker_sync(context, payload)
    local data = {}
    if payload and payload ~= "" then
        local ok, decoded = pcall(nk.json_decode, payload)
        if ok then data = decoded end
    end

    if not data or not data.clicks then
        error("Missing clicks in payload")
    end

    local user_id = context.user_id
    local clicks = math.min(data.clicks, 1000) -- максимум 1000 за раз (анти-чит)
    local state = load_state(user_id)

    -- Считаем CPS от улучшений
    local cps = 0
    for upgrade_id, level in pairs(state.upgrades) do
        if UPGRADES[upgrade_id] then
            cps = cps + UPGRADES[upgrade_id].cps * level
        end
    end

    -- Считаем оффлайн прогресс (максимум 4 часа)
    local elapsed = math.min((nk.time() - state.last_save) / 1000, 14400)
    local offline_score = math.floor(cps * elapsed)

    state.total_clicks = state.total_clicks + clicks
    state.score = state.score + clicks + offline_score

    save_state(user_id, state)

    -- Лидерборд по очкам
    nk.leaderboard_record_write("clicker_score", user_id, context.username or "", state.score, state.total_clicks, {})

    -- PlayCoin за каждые 100 кликов
    local coins = math.floor(clicks / 100)
    if coins > 0 then
        nk.wallet_update(user_id, {playcoin = coins},
            {source = "clicker_clicks", clicks = clicks}, true)
    end

    return nk.json_encode({
        score = state.score,
        total_clicks = state.total_clicks,
        offline_score = offline_score,
        cps = cps,
        coins_earned = coins
    })
end

-- RPC: Купить улучшение
local function clicker_buy_upgrade(context, payload)
    local data = {}
    if payload and payload ~= "" then
        local ok, decoded = pcall(nk.json_decode, payload)
        if ok then data = decoded end
    end

    if not data or not data.upgrade_id then
        error("Missing upgrade_id")
    end

    local upgrade_id = data.upgrade_id
    local upgrade = UPGRADES[upgrade_id]
    if not upgrade then
        error("Unknown upgrade: " .. upgrade_id)
    end

    local user_id = context.user_id
    local state = load_state(user_id)
    local level = (state.upgrades[upgrade_id] or 0)
    local cost = upgrade.cost * (level + 1)

    if state.score < cost then
        return nk.json_encode({
            success = false,
            message = "Недостаточно очков. Нужно: " .. cost,
            current_score = state.score
        })
    end

    state.score = state.score - cost
    state.upgrades[upgrade_id] = level + 1
    save_state(user_id, state)

    return nk.json_encode({
        success = true,
        upgrade_id = upgrade_id,
        new_level = level + 1,
        cost = cost,
        remaining_score = state.score,
        message = upgrade.name .. " улучшен до уровня " .. (level + 1)
    })
end

-- RPC: Получить состояние
local function clicker_get_state(context, payload)
    local state = load_state(context.user_id)
    local upgrades_info = {}
    for id, upgrade in pairs(UPGRADES) do
        local level = state.upgrades[id] or 0
        table.insert(upgrades_info, {
            id = id,
            name = upgrade.name,
            level = level,
            cps = upgrade.cps,
            cost = upgrade.cost * (level + 1)
        })
    end
    state.upgrades_info = upgrades_info
    return nk.json_encode(state)
end

nk.register_rpc(clicker_sync, "games/clicker/sync")
nk.register_rpc(clicker_buy_upgrade, "games/clicker/buy_upgrade")
nk.register_rpc(clicker_get_state, "games/clicker/state")

return {}
