-- PlayRU Platform - Nakama Initialization Module
local nk = require("nakama")
require("auth_vk")
require("auth_yandex")
require("economy")
require("games_parkour")
require("games_clicker")
require("games_arena")
require("games_racing")
require("games_tower_defense")
require("games_island_survival")
require("games_island_survival_mp")
require("platform_leaderboard")
require("match_handler")
require("room_manager")
local achievements = require("achievements")
require("premium")
local notifications = require("notifications")

-- Регистрация RPC функций платформы
local function register_rpcs()
    -- Health check
    nk.register_rpc(function(context, payload)
        return nk.json_encode({
            status = "ok",
            platform = "PlayRU",
            version = "0.1.0",
            server_time = nk.time()
        })
    end, "platform/health")

    -- Получить список игр (заглушка — будет заменена на запрос к Django)
    nk.register_rpc(function(context, payload)
        return nk.json_encode({
            games = {},
            message = "Game catalog coming soon"
        })
    end, "platform/games/list")
end

-- Инициализация
register_rpcs()

-- Хук после аутентификации устройства — выдать стартовый баланс и уведомление новым пользователям
nk.register_req_after(function(context, payload)
    if payload.created then
        nk.logger_info("New account created: " .. context.user_id)

        local changeset = {
            playcoin = 100  -- 100 стартовых монет
        }
        local metadata = {source = "welcome_bonus"}

        nk.wallet_update(context.user_id, changeset, metadata, true)

        -- Welcome notification
        notifications.send(
            context.user_id,
            notifications.CODES.WELCOME,
            "Добро пожаловать в PlayRU!",
            {message = "Вам начислено 100 стартовых PlayCoin!", coins = 100},
            nil
        )

        nk.logger_info("New user setup complete: " .. context.user_id)
    end
end, "AuthenticateDevice")

nk.register_rt_before(function(context, logger, nk, envelope)
    logger:debug("RT message before: " .. tostring(envelope))
    return envelope
end, "ChannelJoin")

return {}
