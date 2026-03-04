-- PlayRU: Achievement System
local nk = require("nakama")

local ACHIEVEMENTS = {
    first_game = {
        id = "first_game",
        name = "Первая игра",
        description = "Сыграй в первую игру",
        reward_coins = 50,
        icon = "trophy"
    },
    parkour_master = {
        id = "parkour_master",
        name = "Мастер паркура",
        description = "Пробеги паркур за менее чем 20 секунд",
        reward_coins = 100,
        icon = "runner"
    },
    arena_warrior = {
        id = "arena_warrior",
        name = "Воин арены",
        description = "Набери 10 убийств в одном матче",
        reward_coins = 100,
        icon = "sword"
    },
    clicker_addict = {
        id = "clicker_addict",
        name = "Кликер-маньяк",
        description = "Сделай 10,000 кликов",
        reward_coins = 75,
        icon = "finger"
    },
    survivor = {
        id = "survivor",
        name = "Выживший",
        description = "Продержись 10 дней на острове",
        reward_coins = 150,
        icon = "island"
    },
    defender = {
        id = "defender",
        name = "Защитник",
        description = "Пройди все 10 волн Tower Defense",
        reward_coins = 150,
        icon = "castle"
    },
    rich_player = {
        id = "rich_player",
        name = "Богатей",
        description = "Накопи 1000 PlayCoin",
        reward_coins = 0,
        icon = "money"
    },
}

-- Проверить и выдать достижение
local function unlock_achievement(user_id, achievement_id)
    local achievement = ACHIEVEMENTS[achievement_id]
    if not achievement then return false end

    -- Проверяем не выдано ли уже
    local objects = nk.storage_read({
        {collection = "achievements", key = achievement_id, user_id = user_id}
    })
    if #objects > 0 then return false end

    -- Записываем (value должен быть таблицей, НЕ json_encode)
    nk.storage_write({
        {
            collection = "achievements",
            key = achievement_id,
            user_id = user_id,
            value = {
                unlocked_at = nk.time(),
                achievement_id = achievement_id
            },
            permission_read = 1,
            permission_write = 0
        }
    })

    -- Награда
    if achievement.reward_coins > 0 then
        nk.wallet_update(user_id, {playcoin = achievement.reward_coins},
            {source = "achievement", id = achievement_id}, true)
    end

    -- Уведомление
    nk.notifications_send({
        {
            user_id = user_id,
            subject = "Achievement: " .. achievement.name,
            content = {
                description = achievement.description,
                coins = achievement.reward_coins,
                achievement_id = achievement_id
            },
            code = 3,
            sender_id = "00000000-0000-0000-0000-000000000000",
            persistent = true
        }
    })

    nk.logger_info("Achievement unlocked: " .. user_id .. " / " .. achievement_id)
    return true
end

-- RPC: Получить все достижения игрока
local function get_achievements(context, payload)
    local user_id = context.user_id
    local result = {}

    for id, achievement in pairs(ACHIEVEMENTS) do
        local objects = nk.storage_read({
            {collection = "achievements", key = id, user_id = user_id}
        })
        -- objects[1].value уже таблица, не нужен json_decode
        table.insert(result, {
            id = id,
            name = achievement.name,
            description = achievement.description,
            icon = achievement.icon,
            reward_coins = achievement.reward_coins,
            unlocked = #objects > 0,
            unlocked_at = #objects > 0 and objects[1].value.unlocked_at or nil
        })
    end

    local unlocked_count = 0
    for _, a in ipairs(result) do
        if a.unlocked then unlocked_count = unlocked_count + 1 end
    end

    return nk.json_encode({
        achievements = result,
        total = #result,
        unlocked = unlocked_count
    })
end

-- RPC: Разблокировать достижение (вызывается из игровой логики)
local function trigger_achievement(context, payload)
    local data = {}
    if payload and payload ~= "" then
        local ok, decoded = pcall(nk.json_decode, payload)
        if ok then data = decoded end
    end

    if not data.achievement_id then
        error("Missing achievement_id")
    end

    local unlocked = unlock_achievement(context.user_id, data.achievement_id)
    local achievement = ACHIEVEMENTS[data.achievement_id]

    return nk.json_encode({
        success = true,
        already_had = not unlocked,
        achievement = achievement,
        coins_earned = (unlocked and achievement and achievement.reward_coins) or 0
    })
end

nk.register_rpc(get_achievements, "platform/achievements")
nk.register_rpc(trigger_achievement, "platform/achievements/unlock")

-- Экспортируем для других модулей
return {unlock = unlock_achievement}
