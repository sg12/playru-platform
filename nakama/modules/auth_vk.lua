-- VK OAuth Custom Authentication for PlayRU
local nk = require("nakama")

-- VK Custom Auth RPC
-- Клиент передаёт: { "vk_token": "...", "device_id": "..." }
-- Сервер: верифицирует токен через VK API, создаёт/находит аккаунт
local function vk_authenticate(context, payload)
    local data = nk.json_decode(payload)

    if not data or not data.vk_token then
        error("Missing vk_token in payload")
    end

    -- Запрос к VK API для получения user_id
    local success, res_headers, res_body = pcall(function()
        return nk.http_request(
            "https://api.vk.com/method/users.get?access_token=" .. data.vk_token .. "&v=5.131&fields=photo_100",
            "GET",
            {["Content-Type"] = "application/json"},
            nil
        )
    end)

    if not success then
        error("VK API request failed: " .. tostring(res_headers))
    end

    local vk_data = nk.json_decode(res_body)

    if not vk_data or not vk_data.response or #vk_data.response == 0 then
        error("Invalid VK token or empty response")
    end

    local vk_user = vk_data.response[1]
    local vk_id = tostring(vk_user.id)
    local display_name = vk_user.first_name .. " " .. vk_user.last_name
    local avatar_url = vk_user.photo_100 or ""

    -- Создаём или находим аккаунт по VK ID
    local user_id, _, created = nk.authenticate_custom(vk_id, "vk_" .. vk_id, true)

    -- Обновляем профиль если новый пользователь
    if created then
        nk.account_update_id(user_id, "vk_" .. vk_id, display_name, avatar_url, nil, nil, nil, nil)
        nk.logger_info("New VK user registered: " .. vk_id .. " / " .. display_name)
    end

    -- Генерируем Nakama session token
    local token, _ = nk.authenticate_custom(vk_id, "vk_" .. vk_id, false)

    return nk.json_encode({
        user_id = user_id,
        display_name = display_name,
        avatar_url = avatar_url,
        is_new = created,
        nakama_token = token
    })
end

nk.register_rpc(vk_authenticate, "auth/vk")

return {}
