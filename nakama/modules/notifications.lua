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
local function get_notifications(context, payload)
    local data = {}
    if payload and payload ~= "" then
        local ok, decoded = pcall(nk.json_decode, payload)
        if ok and decoded then data = decoded end
    end
    local limit = (data and data.limit) or 20

    local notifications, cursor = nk.notifications_list(context.user_id, limit, nil)

    local result = {}
    for _, n in ipairs(notifications) do
        table.insert(result, {
            id = n.id,
            subject = n.subject,
            content = n.content,
            code = n.code,
            create_time = n.create_time,
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

    nk.notifications_delete(context.user_id, data.ids)
    return nk.json_encode({success = true, deleted = #data.ids})
end

nk.register_rpc(get_notifications, "platform/notifications")
nk.register_rpc(mark_read, "platform/notifications/read")

-- Экспортируем функцию для использования в других модулях
return {
    send = send_notification,
    CODES = NOTIFICATION_CODES
}
