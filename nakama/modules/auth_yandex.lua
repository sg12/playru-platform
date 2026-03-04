-- Yandex ID OAuth Custom Authentication for PlayRU
local nk = require("nakama")

-- Яндекс ID Custom Auth RPC
-- Клиент передаёт: { "yandex_token": "..." }
local function yandex_authenticate(context, payload)
    local data = nk.json_decode(payload)

    if not data or not data.yandex_token then
        error("Missing yandex_token in payload")
    end

    -- Запрос к Yandex API для получения данных пользователя
    local success, res_headers, res_body = pcall(function()
        return nk.http_request(
            "https://login.yandex.ru/info?format=json",
            "GET",
            {
                ["Authorization"] = "OAuth " .. data.yandex_token,
                ["Content-Type"] = "application/json"
            },
            nil
        )
    end)

    if not success then
        error("Yandex API request failed: " .. tostring(res_headers))
    end

    local ya_data = nk.json_decode(res_body)

    if not ya_data or not ya_data.id then
        error("Invalid Yandex token or empty response")
    end

    local ya_id = tostring(ya_data.id)
    local display_name = ya_data.display_name or ya_data.login or "Игрок"
    local avatar_url = ""
    if ya_data.default_avatar_id then
        avatar_url = "https://avatars.yandex.net/get-yapic/" .. ya_data.default_avatar_id .. "/islands-200"
    end

    -- Создаём или находим аккаунт по Яндекс ID
    local user_id, _, created = nk.authenticate_custom(ya_id, "ya_" .. ya_id, true)

    if created then
        nk.account_update_id(user_id, "ya_" .. ya_id, display_name, avatar_url, nil, nil, nil, nil)
        -- Стартовый бонус уже выдаётся через хук on_account_created в init.lua
        nk.logger_info("New Yandex user registered: " .. ya_id .. " / " .. display_name)
    end

    return nk.json_encode({
        user_id = user_id,
        display_name = display_name,
        avatar_url = avatar_url,
        is_new = created,
        provider = "yandex"
    })
end

nk.register_rpc(yandex_authenticate, "auth/yandex")

return {}
