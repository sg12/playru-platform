-- PlayRU: Notifications — внутренние уведомления игрокам
local nk = require("nakama")

local NOTIFICATION_CODES = {
    WELCOME         = 1,
    DAILY_REWARD    = 2,
    ACHIEVEMENT     = 3,
    FRIEND_JOINED   = 4,
    LEADERBOARD_TOP = 5,
    COINS_RECEIVED  = 6,
}

-- Отправить уведомление игроку
local function send_notification(user_id, code, subject, content, sender_id)
    sender_id = sender_id or "00000000-0000-0000-0000-000000000000"
    nk.notifications_send({
        {
            user_id = user_id,
            subject = subject,
            content = content,
            code = code,
            sender_id = sender_id,
            persistent = true
        }
    })
end

-- RPC: Получить непрочитанные уведомления
-- nk.notifications_list недоступна в Nakama 3.22, используем SQL
local function get_notifications(context, payload)
    local data = {}
    if payload and payload ~= "" then
        local ok, decoded = pcall(nk.json_decode, payload)
        if ok and decoded then data = decoded end
    end
    local limit = (data and data.limit) or 20

    local query = [[
        SELECT id, subject, content, code, create_time
        FROM notification
        WHERE user_id = $1::UUID
        ORDER BY create_time DESC
        LIMIT $2::INT
    ]]
    local rows = nk.sql_query(query, {context.user_id, limit})

    local result = {}
    for _, row in ipairs(rows) do
        local content = row.content
        if type(content) == "string" then
            local ok, decoded = pcall(nk.json_decode, content)
            if ok then content = decoded end
        end
        table.insert(result, {
            id = row.id,
            subject = row.subject,
            content = content,
            code = row.code,
            create_time = row.create_time,
        })
    end

    return nk.json_encode({
        notifications = result,
        count = #result
    })
end

-- RPC: Отметить уведомления прочитанными
local function mark_read(context, payload)
    local data = {}
    if payload and payload ~= "" then
        local ok, decoded = pcall(nk.json_decode, payload)
        if ok and decoded then data = decoded end
    end

    if not data or not data.ids then
        return nk.json_encode({success = true, deleted = 0})
    end

    -- Гарантируем, что ids — таблица
    local ids = data.ids
    if type(ids) == "string" then
        ids = {ids}
    end

    -- nk.notifications_delete принимает таблицу {user_id=, notification_id=}
    local deletes = {}
    for _, id in ipairs(ids) do
        table.insert(deletes, {
            user_id = context.user_id,
            notification_id = id,
        })
    end

    nk.notifications_delete(deletes)
    return nk.json_encode({success = true, deleted = #ids})
end

nk.register_rpc(get_notifications, "platform/notifications")
nk.register_rpc(mark_read, "platform/notifications/read")

-- Экспортируем функцию для использования в других модулях
return {
    send = send_notification,
    CODES = NOTIFICATION_CODES
}
