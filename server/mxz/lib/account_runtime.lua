-- Authoritative per-connection authentication state; no nickname or state.json credentials.
local M = {}
local permanent = {GUEST_NOT_ALLOWED=true, INVALID_ACCOUNT=true, ACCOUNT_DISABLED=true,
    KEY_BANNED=true, KEY_REVOKED=true, BINDING_CHANGED=true, BINDING_LOCKED=true,
    SESSION_CLOSED=true, SESSION_EXPIRED=true, KEY_BOUND_TO_OTHER_ACCOUNT=true,
    INSUFFICIENT_SERVER_PERMISSION=true, IDENTITY_MISMATCH=true}

function M.new(deps)
    local self = {connections={}, reservations={}, serial=0, stopped=false}
    local MP, transport, adapter = deps.MP, deps.transport, deps.adapter
    local clock = deps.clock or os.time
    local nonce = assert(deps.nonce, "connection nonce factory required")
    local function tell(pid, message) MP.SendChatMessage(pid, "[MXZ] " .. message) end

    local function official(pid)
        if type(MP.IsPlayerGuest) ~= "function" or type(MP.GetPlayerIdentifiers) ~= "function" then
            return nil, "INVALID_ACCOUNT", "无法验证正式 BeamMP 账号"
        end
        local ok, guest = pcall(MP.IsPlayerGuest, pid)
        if not ok or guest ~= false then
            return nil, "GUEST_NOT_ALLOWED", "请先登录正式 BeamMP 账号后重新进服激活"
        end
        local good, ids = pcall(MP.GetPlayerIdentifiers, pid)
        local id = good and type(ids) == "table" and ids.beammp or nil
        if type(id) ~= "string" or #id > 32 or not id:match("^[1-9]%d*$") then
            return nil, "INVALID_ACCOUNT", "无法验证正式 BeamMP 账号"
        end
        return id
    end

    local function same(pid, connection)
        return not self.stopped and self.connections[pid] == connection and
            MP.IsPlayerConnected(pid) and official(pid) == connection.beammp_id
    end

    local function body(connection)
        return {beammp_id=connection.beammp_id, is_guest=false,
            connection_id=connection.connection_id, name=connection.name}
    end

    local function end_grant(connection, grant)
        if not grant then return end
        local data = body(connection); data.session_token = grant.session_token
        transport:request("/api/game/session/end", data, function() end)
    end

    local function clear(pid, connection, reason)
        self.reservations[pid] = nil
        if connection.grant then
            end_grant(connection, connection.grant)
            connection.grant, connection.identity = nil, nil
            adapter.on_logout(pid, connection.name, reason)
        end
    end

    local function failure(pid, connection, result)
        self.reservations[pid] = nil
        connection.inflight = false
        connection.reason = result.code or "AUTH_SERVICE_UNAVAILABLE"
        connection.message = result.error or "认证服务暂时不可用，请稍后重试"
        tell(pid, connection.message)
    end

    function self:get(pid)
        local connection = self.connections[pid]
        if connection and connection.grant and same(pid, connection) and
                clock() - connection.verified_at < 90 then return connection.identity end
    end

    function self:denial_message(pid)
        local connection=self.connections[pid]
        if not connection then return "请先使用 /activate <卡密> 完成首次激活" end
        if connection.message then return connection.message end
        if connection.inflight then return "正在验证账号，请稍候" end
        if connection.grant then return "会话已过期，请重新进服认证" end
        return "请先使用 /activate <卡密> 完成首次激活"
    end

    function self:poll_commands()
        if deps.commands and not self.stopped then deps.commands:poll() end
    end

    function self:by_name(name)
        local found
        for pid, connection in pairs(self.connections) do
            if connection.name == name then
                local identity = self:get(pid)
                if identity then
                    if found then return nil end -- duplicate display names never select an owner
                    found = identity
                end
            end
        end
        return found
    end

    function self:snapshot()
        local result = {}
        for pid, connection in pairs(self.connections) do
            local id = self:get(pid)
            if id then
                result[connection.name] = {codename=id.codename, tier=id.tier, isAdmin=id.isAdmin,
                    isVip=id.isVip, loggedIn=true}
            end
        end
        return result
    end

    function self:view()
        local result = {}
        for pid, connection in pairs(self.connections) do
            local identity = self:get(pid)
            if identity then result[connection.name] = self:by_name(connection.name) end
        end
        return result
    end

    function self:authenticate(pid, key)
        local connection = self.connections[pid]
        if not connection or connection.inflight or self.stopped then return false end
        local id, code, message = official(pid)
        if not id or id ~= connection.beammp_id then
            failure(pid, connection, {code=code or "IDENTITY_MISMATCH", error=message or "账号身份已变化，请重新进服"})
            return false
        end
        connection.inflight = true
        self.serial = self.serial + 1
        local request_id = connection.connection_id .. "_" .. self.serial
        local data = body(connection)
        if key ~= nil then data.key = key end
        transport:request("/api/game/auth/prepare", data, function(result)
            if not same(pid, connection) then return end
            if not result.ok then failure(pid, connection, result); return end
            local info = result.data
            if type(info)~="table" or type(info.ticket)~="string" or
                    type(info.key_id)~="number" or type(info.tier)~="number" or
                    info.tier < 0 or info.tier > 3 or info.tier%1~=0 then
                failure(pid, connection, {code="AUTH_SERVICE_UNAVAILABLE",error="认证服务返回无效结果"}); return
            end
            local allowed, why = adapter.check_quota(pid, info.tier, self.reservations)
            if not allowed then
                failure(pid, connection, {code="SERVER_QUOTA_FULL", error=why}); return
            end
            self.reservations[pid] = {name="@reservation_"..pid, tier=info.tier}
            local commit = body(connection)
            commit.ticket, commit.request_id = info.ticket, request_id
            transport:request("/api/game/auth/finalize", commit, function(final)
                if not same(pid, connection) then
                    if final.ok then end_grant(connection, final.data) end
                    return
                end
                self.reservations[pid] = nil
                if not final.ok then
                    -- A timeout after commit is ambiguous. Suspend any previous grant;
                    -- a new attempt can recover the connection's idempotent server-side lease.
                    if final.code=="AUTH_SERVICE_UNAVAILABLE" then clear(pid,connection,final.code) end
                    failure(pid, connection, final); return
                end
                local grant = final.data
                if type(grant)~="table" or type(grant.session_token)~="string" or
                        type(grant.session_id)~="number" or type(grant.player_id)~="number" or
                        grant.beammp_id ~= connection.beammp_id or grant.tier ~= info.tier or grant.key_id~=info.key_id then
                    if type(grant)=="table" and type(grant.session_token)=="string" then end_grant(connection, grant) end
                    failure(pid, connection, {code="IDENTITY_MISMATCH", error="认证状态已变化，请重试"})
                    return
                end
                connection.grant = grant
                connection.identity = {codename=grant.codename, tier=grant.tier,
                    isAdmin=grant.tier==3, isVip=grant.tier>=1, loggedIn=true,
                    key_id=grant.key_id, player_id=grant.player_id, beammp_id=grant.beammp_id}
                connection.verified_at, connection.last_heartbeat = clock(), clock()
                connection.inflight, connection.reason, connection.message = false, nil, nil
                adapter.on_login(pid, connection.name, connection.identity, grant)
                tell(pid, grant.newly_bound and "激活成功，已绑定当前 BeamMP 账号，以后进服自动登录" or
                    (key and "激活成功 — " or "自动登录成功 — ") .. grant.codename)
            end)
        end)
        return true
    end

    function self:join(pid)
        if self.connections[pid] then self:disconnect(pid) end
        local id, code, message = official(pid)
        local connection = {name=MP.GetPlayerName(pid) or "", beammp_id=id,
            connection_id=nonce(), joined_at=clock(), reason=code, message=message,
            last_heartbeat=clock(), verified_at=0, event_serial=0}
        self.connections[pid] = connection
        if not id then tell(pid, message); return end
        self:authenticate(pid)
    end

    function self:activate(pid, key)
        if type(key) ~= "string" then return false end
        key = key:match("^%s*(.-)%s*$")
        if #key == 0 or #key > 128 then tell(pid, "用法: /activate <卡密>"); return false end
        if not self.connections[pid] then self:join(pid) end
        local connection = self.connections[pid]
        if connection.inflight then tell(pid, "正在验证，请稍后重试"); return false end
        return self:authenticate(pid, key)
    end

    function self:disconnect(pid)
        local connection = self.connections[pid]
        if not connection then return end
        clear(pid, connection, "disconnect")
        self.connections[pid], self.reservations[pid] = nil, nil
    end

    function self:set_role(pid, codename, tier)
        local identity = self:get(pid)
        if not identity or identity.tier~=3 then tell(pid,"此操作需要管理员权限"); return false end
        if type(codename)~="string" then return false end
        codename = codename:match("^%s*(.-)%s*$")
        local length = utf8 and utf8.len and utf8.len(codename) or #codename
        if not length or length==0 or length>128 or #codename>512 or (tier~=0 and tier~=1 and tier~=2 and tier~=3) then return false end
        local connection=self.connections[pid]
        if connection.role_inflight then tell(pid,"身份修改正在处理，请稍后重试"); return false end
        local data=body(connection)
        data.session_token, data.codename, data.tier=connection.grant.session_token,codename,tier
        connection.role_inflight=true
        transport:request("/api/game/keys/role",data,function(result)
            if not same(pid,connection) then return end
            connection.role_inflight=false
            if not result.ok then tell(pid,result.error or "身份修改失败"); return end
            for other, target in pairs(self.connections) do
                if target.identity and target.identity.codename==codename then target.last_heartbeat=clock()-30 end
            end
            tell(pid,"身份已更新 — "..codename)
        end)
        return true
    end

    function self:event(pid, kind, value)
        local connection = self.connections[pid]
        if not self:get(pid) then return false end
        if kind == "distance" and (type(value) ~= "number" or value ~= value or value <= 0 or value > 5000) then return false end
        connection.event_serial = connection.event_serial + 1
        local data = body(connection)
        data.session_token = connection.grant.session_token
        data.event_id = connection.connection_id .. "_event_" .. connection.event_serial
        if kind == "distance" then data.dist_m = value end
        transport:request("/api/game/stats/" .. kind, data, function(result)
            if same(pid, connection) and not result.ok and permanent[result.code] then
                clear(pid, connection, result.code)
                failure(pid, connection, result)
            end
        end)
        return true
    end

    function self:tick()
        transport:poll()
        local now = clock()
        for pid, connection in pairs(self.connections) do
            if connection.grant then
                if not same(pid, connection) or now - connection.verified_at >= 90 then
                    clear(pid, connection, "SESSION_EXPIRED")
                    connection.reason, connection.message = "SESSION_EXPIRED", "会话已过期，请重新进服认证"
                elseif not connection.inflight and now - connection.last_heartbeat >= 30 then
                    connection.last_heartbeat, connection.inflight = now, true
                    local data = body(connection); data.session_token = connection.grant.session_token
                    transport:request("/api/game/session/heartbeat", data, function(result)
                        if not same(pid, connection) then return end
                        connection.inflight = false
                        if result.ok and type(result.data)=="table" and type(result.data.tier)=="number" and
                                result.data.beammp_id==connection.beammp_id and result.data.session_id==connection.grant.session_id then
                            local info = result.data
                            local allowed, why = adapter.check_quota(pid, info.tier, self.reservations)
                            if not allowed then
                                clear(pid, connection, "SERVER_QUOTA_FULL")
                                failure(pid, connection, {code="SERVER_QUOTA_FULL", error=why})
                                return
                            end
                            local id = connection.identity
                            id.tier, id.isAdmin, id.isVip, id.codename = info.tier, info.tier==3, info.tier>=1, info.codename
                            connection.verified_at = clock()
                            adapter.on_login(pid, connection.name, id, info, true)
                        elseif permanent[result.code] then
                            clear(pid, connection, result.code)
                            failure(pid, connection, result)
                        end
                    end)
                end
            elseif now - connection.joined_at >= 300 then
                MP.DropPlayer(pid, connection.message or "未在时限内激活卡密")
                self:disconnect(pid)
            elseif not connection.warned and now - connection.joined_at >= 270 then
                connection.warned = true
                tell(pid, connection.reason == "ACCOUNT_UNBOUND" and "还剩 30 秒，请用 /activate <卡密> 完成首次激活" or
                    ((connection.message or "尚未通过账号认证") .. "，30 秒后将断开连接"))
            end
        end
    end

    function self:shutdown()
        -- End requests are submitted before stopping response processing.
        for pid in pairs(self.connections) do self:disconnect(pid) end
        self.stopped = true
    end
    return self
end
return M
