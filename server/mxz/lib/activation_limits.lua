-- MXZ independent concurrent activation quotas, v3. No player data is persisted.
local M = { version = 3 }
local function validLimit(value)
    if value == nil then return nil end -- absent / JSON null = unlimited
    if type(value) ~= "number" or value < 0 or value > 1000000 or value % 1 ~= 0 then
        return 0 -- malformed configured quota never silently opens admission
    end
    return value
end
function M.settings(data)
    data = data or {}
    return {
        maxPlayers = tonumber(data.maxPlayers) or 16,
        vipSlots = tonumber(data.vipSlots) or 0,
        normalActivationLimit = validLimit(data.normalActivationLimit),
        captainActivationLimit = validLimit(data.captainActivationLimit),
    }
end
function M.tier(ap, identities)
    local identity = ap and identities[ap.name]
    if identity and identity.loggedIn then return tonumber(identity.tier) or 0 end
    return ap and (tonumber(ap.tier) or 0)
end
function M.counts(active, identities, exclude)
    local counts = { normal = 0, crowdfund = 0, captain = 0, admin = 0 }
    local keys = {[0] = "normal", [1] = "crowdfund", [2] = "captain", [3] = "admin"}
    for pid, ap in pairs(active) do
        if pid ~= exclude then
            local key = keys[M.tier(ap, identities)]
            if key then counts[key] = counts[key] + 1 end
        end
    end
    counts.ordinary = counts.normal + counts.crowdfund + counts.admin
    return counts
end
function M.allow(settings, active, identities, pid, tier)
    if tier ~= 0 and tier ~= 1 and tier ~= 2 and tier ~= 3 then return false, "身份无效" end
    -- Renewing an occupied slot is allowed even after an administrator lowers the cap.
    local captain = tier == 2
    if active[pid] and (M.tier(active[pid], identities) == 2) == captain then return true end
    local counts = M.counts(active, identities, pid)
    local count, limit
    if captain then count, limit = counts.captain, settings.captainActivationLimit
    else count, limit = counts.ordinary, settings.normalActivationLimit end
    if limit ~= nil and count >= limit then
        local label = captain and "舰长位" or "普通位（含众筹、管理员）"
        return false, label .. "卡密激活名额已满（" .. count .. "/" .. limit .. "），请等待名额释放"
    end
    return true
end
return M
