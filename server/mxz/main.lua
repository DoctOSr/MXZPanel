-- ============================================================
-- 冒险者控制面板 v1.1 — 服务端 (职业/传送/黑手/洪水)
-- ============================================================

local CONFIG = {
    keysFile    = "Resources/Server/keyAuth/keys.txt",
    pointsFile  = "Resources/Server/mxz/points.txt",
    stateFile   = "Resources/Server/mxz/state.json",
    criminalIndex = 10,
    heavyIndex    = 9,
    normalCount   = 8,
}

-- ============== State ==============

local groups = {}              -- {[groupName] = {x,y,z,yaw}[]}
local roleAssignments = {}     -- {[playerName] = {role="criminal"}}
local keyMap = {}              -- {[key] = codename}
local adminSet = {}            -- {[codename] = true}
local accountAuth
-- Compatibility view for existing gameplay; authoritative state belongs to account_runtime.
local playerIdentity = setmetatable({}, {
    __index=function(_, name) return accountAuth and accountAuth:by_name(name) end,
    __pairs=function() return next, accountAuth and accountAuth:view() or {}, nil end
})
-- Session lifecycle is owned by account_runtime.
local function authDenialMessage(pid)
    return accountAuth and accountAuth:denial_message(pid) or "正在初始化账号认证，请稍候"
end
local SERVER_NAME = "unknown" -- v4.6: 从工作目录初始化

-- JSON 字符串转义（写面板请求体用，避免卡密含引号/反斜杠破坏 JSON）
local function mxzJsonEsc(s)
    s = tostring(s or ""):gsub("\\", "\\\\"):gsub('"', '\\"')
    return s
end
local gkoCooldown = 6
local gkoLastTrigger = {} -- GForceKO 整合 (v4.7)
local playerNameByID = {} -- v4.8: playerID -> name 缓存（断线时 GetPlayerName 可能失效）

-- ====== v5 身份/预留位: DB 是唯一权威, keys.txt 仅作展示缓存 ======
local pendingActivation = {}      -- playerID -> os.time() 进服时间 (300s 未激活踢出)
local activationWarned = {}       -- playerID -> 已发宽限警告（防止重复刷屏）
local activatedPlayers = {}       -- playerID -> {name, key, tier} (预留位计数用)
local ACTIVATION_GRACE = 300   -- 进服未激活宽限 5 分钟
local ACTIVATION_WARN  = 270   -- 踢出前 30 秒警告
local serverSettings = { maxPlayers = 16, vipSlots = 0 }

-- ====== 黑手/Fuk 核心状态 ======
-- 必须提前声明: buildState() 在文件前部要读取它们 (local 作用域陷阱)
local STATE = { IDLE = 0, COUNTDOWN = 1, TRAITOR = 2 }
local gameState = STATE.IDLE
local gamePlayers = {}
local traitorID   = nil
local traitorName = nil
local countdown   = 0
local DEFAULT_CHASE_TIME = 300
local chaseTime = DEFAULT_CHASE_TIME

-- Flood state
local floodOptions = {
    oceanLevel = 0.0,
    floodSpeed = 0.001,
    limit = 0.0,
    limitEnabled = false,
    enabled = false,
    decrease = false,
}
local floodIsOceanValid = false
local floodInitialLevel = 0.0
local floodInvalidCount = 0

local function countKeys(t)
    local n = 0; for _ in pairs(t) do n = n + 1 end; return n
end

-- ============== Vehicle Spawn Guard ==============

function onVehicleSpawn(playerID, vehicleID, data)
    local name = MP.GetPlayerName(playerID)
    if not name or name == "" then return end
    if not playerIdentity[name] or not playerIdentity[name].loggedIn then
        MP.TriggerClientEventJson(playerID, "mxz_toast", {type="error", title="未激活", msg=authDenialMessage(playerID)})
        return 1
    end
end

-- ============== Persistence ==============

local function saveState()
    local s = {
        roleAssignments = roleAssignments,
        playerIdentity = accountAuth and accountAuth:snapshot() or {},
        savedAt = os.date("%Y-%m-%d %H:%M:%S"),
    }
    local f = io.open(CONFIG.stateFile, "w")
    if f then f:write(Util.JsonPrettify(Util.JsonEncode(s))); f:close() end
end

local function loadState()
    if not FS.Exists(CONFIG.stateFile) then return end
    local f = io.open(CONFIG.stateFile, "r")
    if not f then return end
    local data = Util.JsonDecode(f:read("*all"))
    f:close()
    if not data then return end
    if data.roleAssignments then roleAssignments = data.roleAssignments end
    -- Never restore authentication from a persisted display snapshot.
    print("[MXZ] State restored: " .. countKeys(roleAssignments) .. " roles, " .. countKeys(playerIdentity) .. " identities")
end

-- ============== Config Loading ==============

local function loadKeys()
    keyMap = {}
    adminSet = {}
    local f = io.open(CONFIG.keysFile, "r")
    if not f then print("[MXZ] keys.txt not found"); return end
    for line in f:lines() do
        line = line:gsub("^%s+", ""):gsub("%s+$", "")
        if line == "" or line:sub(1,1) == "#" then goto c end
        local parts = {}
        for part in line:gmatch("[^:]+") do parts[#parts+1] = part:gsub("^%s+", ""):gsub("%s+$", "") end
        if #parts >= 2 then
            local k = parts[1]
            local v = parts[2]
            if k ~= "" and v ~= "" then keyMap[k] = v end
        elseif #parts == 1 then
            keyMap[parts[1]] = parts[1]
        end
        ::c::
    end
    f:close()
    -- v5: 身份(管理员/vip)只以 DB 为准, keys.txt 的 :admin 后缀不再解析
    print("[MXZ] " .. countKeys(keyMap) .. " keys loaded (身份判定以 DB 为准)")
    for _, id in pairs(playerIdentity) do
        if id.loggedIn then id.isAdmin = (id.tier == 3) end
    end
end

local function loadGroups()
    local f = io.open(CONFIG.pointsFile, "r")
    if not f then print("[MXZ] points.txt not found"); return end
    groups = {}
    local cur = nil
    for line in f:lines() do
        line = line:gsub("^%s+", ""):gsub("%s+$", "")
        if line == "" or line:sub(1,1) == "#" then goto c end
        local g = line:match("^%[(.+)%]$")
        if g then cur = g; groups[cur] = {}; goto c end
        if cur then
            local p = {}
            for t in line:gmatch("%S+") do p[#p+1] = tonumber(t) end
            if #p >= 3 then groups[cur][#groups[cur]+1] = { x=p[1], y=p[2], z=p[3], yaw=p[4] or 0 } end
        end
        ::c::
    end
    f:close()
    print("[MXZ] " .. countKeys(groups) .. " groups loaded")
end

-- ============== Permission (v5: 四级身份, 最高等级者掌控) ==============
-- tier: 0普通 1众筹 2舰长 3管理员
local function onlineMaxTier()
    local maxT = 0
    for pid, pname in pairs(MP.GetPlayers()) do
        local id = playerIdentity[pname]
        if id and id.loggedIn and id.tier and id.tier > maxT then maxT = id.tier end
    end
    return maxT
end

local function canControl(playerName)
    local id = playerIdentity[playerName]
    if not id or not id.loggedIn then return false end
    local maxT = onlineMaxTier()
    if maxT <= 0 then return true end        -- 全部普通 → 所有人可控制
    return (id.tier or 0) == maxT            -- 否则仅最高等级者可控制
end

-- ============== State Broadcast ==============

local function buildGroupsInfo()
    local info = {}
    for gname, pts in pairs(groups) do info[gname] = #pts end
    return info
end

local function buildState()
    local allCodenames = {}
    for _, cn in pairs(keyMap) do allCodenames[cn] = true end
    local keyList = {}
    for cn, _ in pairs(allCodenames) do keyList[#keyList+1] = cn end
    table.sort(keyList)

    local adminList = {}
    for cn, _ in pairs(adminSet) do adminList[#adminList+1] = cn end
    table.sort(adminList)

    local maxTier = onlineMaxTier()
    local adminOnline = maxTier > 0

    local state = {
        players = {},
        roleCounts = { criminal = 0, police_normal = 0, police_heavy = 0 },
        groups = buildGroupsInfo(),
        hasAdminOnline = adminOnline,
        maxTier = maxTier,
        keyList = keyList,
        adminList = adminList,
        isLoggedIn = true,
        -- Fuk 状态
        fukState = gameState or 0,
        fukCountdown = countdown or 0,
        fukTraitor = traitorName or "",
        fukChaseTime = chaseTime or 300,
        -- 洪水
        floodEnabled = floodOptions.enabled,
        floodOceanLevel = floodOptions.oceanLevel,
        floodSpeed = floodOptions.floodSpeed,
        floodLimit = floodOptions.limit,
        floodLimitEnabled = floodOptions.limitEnabled,
        floodDecrease = floodOptions.decrease,
        floodIsOceanValid = floodIsOceanValid,
    }

    for pid, pname in pairs(MP.GetPlayers()) do
        local id = playerIdentity[pname]
        local assign = nil
        if id and id.loggedIn then assign = roleAssignments[id.codename] end
        local ptier = id and id.loggedIn and (id.tier or 0) or 0

        state.players[pname] = {
            name        = pname,
            displayName = (id and id.loggedIn and id.codename) or nil,
            isLoggedIn  = id and id.loggedIn or false,
            tier        = ptier,
            isAdmin     = (ptier == 3),
            isVip       = (ptier >= 1),
            role        = assign and assign.role or nil,
        }

        if assign and assign.role then
            state.roleCounts[assign.role] = (state.roleCounts[assign.role] or 0) + 1
        end
    end

    return state
end

local function broadcastState()
    MP.TriggerClientEventJson(-1, "tpg_stateUpdate", buildState())
end

local function sendStateToPlayer(playerID)
    local state = buildState()
    local name = MP.GetPlayerName(playerID)
    if state.players[name] then state.players[name].isYou = true end
    local myId = playerIdentity[name]
    state.myRole = (myId and myId.loggedIn and roleAssignments[myId.codename] and roleAssignments[myId.codename].role) or nil
    state.isAdmin   = state.players[name] and state.players[name].isAdmin
    state.isVip     = state.players[name] and state.players[name].isVip
    state.tier      = state.players[name] and state.players[name].tier or 0
    state.maxTier   = state.maxTier or onlineMaxTier()
    state.isLoggedIn = state.players[name] and state.players[name].isLoggedIn or false
    MP.TriggerClientEventJson(playerID, "tpg_stateUpdate", state)
end

-- ============== Role Management ==============

local ROLE_MAX = { criminal = 1, police_heavy = 1, police_normal = 8 }

local function assignRole(playerName, role)
    if not ROLE_MAX[role] then return false, "无效职业" end
    -- v5: 职业按卡密备注名(codename)键控, 随卡走而非 bmpID
    local cn = (playerIdentity[playerName] and playerIdentity[playerName].codename) or playerName
    local count = 0
    for rcn, a in pairs(roleAssignments) do
        if a.role == role then
            for pn2, id2 in pairs(playerIdentity) do
                if id2.loggedIn and id2.codename == rcn then count = count + 1 break end
            end
        end
    end
    if count >= ROLE_MAX[role] and (not roleAssignments[cn] or roleAssignments[cn].role ~= role) then
        return false, "该职业已满"
    end
    if roleAssignments[cn] and roleAssignments[cn].role == role then
        return true, "already"
    end
    roleAssignments[cn] = { role = role }
    saveState()
    return true, "ok"
end

local function removeRoleByCodename(targetCodename)
    if roleAssignments[targetCodename] then
        roleAssignments[targetCodename] = nil
        saveState()
        return true
    end
    return false
end

-- ============== Teleport ==============

local function shuffle(tbl)
    local t = {}
    for i = 1, #tbl do t[i] = tbl[i] end
    for i = #t, 2, -1 do
        local j = math.random(i)
        t[i], t[j] = t[j], t[i]
    end
    return t
end

local function playerIDByCodename(cn)
    for pn2, id2 in pairs(playerIdentity) do
        if id2.loggedIn and id2.codename == cn then
            return MP.GetPlayerIDByName(pn2)
        end
    end
    return -1
end

local function teleportGroup(groupName)
    local pts = groups[groupName]
    if not pts then return false, "编组不存在" end
    if #pts < CONFIG.criminalIndex then return false, "坐标不足" end

    local criminals, heavies, normals = {}, {}, {}
    -- v5: 职业按 codename 键控, 需反查在线玩家
    for cn, assign in pairs(roleAssignments) do
        local pid = playerIDByCodename(cn)
        if pid and pid ~= -1 then
            if assign.role == "criminal" then criminals[#criminals+1] = pid
            elseif assign.role == "police_heavy" then heavies[#heavies+1] = pid
            else normals[#normals+1] = pid end
        end
    end

    local normalPos = {}
    for i = 1, CONFIG.normalCount do
        if pts[i] then normalPos[#normalPos+1] = pts[i] end
    end
    normalPos = shuffle(normalPos)

    local count = 0
    for _, pid in ipairs(criminals) do
        MP.TriggerClientEventJson(pid, "tp_teleport", pts[CONFIG.criminalIndex]); count = count + 1 end
    for _, pid in ipairs(heavies) do
        MP.TriggerClientEventJson(pid, "tp_teleport", pts[CONFIG.heavyIndex]); count = count + 1 end
    for i, pid in ipairs(normals) do
        if i <= #normalPos then
            MP.TriggerClientEventJson(pid, "tp_teleport", normalPos[i]); count = count + 1
        end
    end

    local names = { criminal = "匪徒", police_normal = "普通警员", police_heavy = "重型单位" }
    for cn, assign in pairs(roleAssignments) do
        local pid = playerIDByCodename(cn)
        if pid and pid ~= -1 then
            MP.SendChatMessage(pid, "[MXZ] 已传送至 " .. groupName .. " — " .. (names[assign.role] or assign.role))
        end
    end
    MP.SendChatMessage(-1, "[MXZ] 传送 " .. groupName .. " 完成 — " .. count .. " 人")
    return true, "已传送 " .. count .. " 人"
end

-- ============== MXZ Events ==============

-- ============== v5 身份辅助 (DB 权威) ==============
-- 必须在 onActivate / onAdminAdd 之前定义 (作用域陷阱)

-- MXZ_ACTIVATION_LIMITS_V3: independent concurrent activation quotas.
local activationLimits = dofile("Resources/Server/mxz/lib/activation_limits.lua")
local quotaLastReport = 0
local function publishActivationUsage(force)
    local now = os.time()
    if not force and now - quotaLastReport < 5 then return end
    local report = activationLimits.counts(activatedPlayers, playerIdentity)
    report.version = activationLimits.version
    report.updatedAt = now
    report.activationGraceSeconds = ACTIVATION_GRACE
    report.normalActivationLimit = serverSettings.normalActivationLimit
    report.normalIncludesCrowdfund = true
    report.normalIncludesAdmin = true
    report.captainActivationLimit = serverSettings.captainActivationLimit
    report.configMaxPlayers = serverSettings.maxPlayers
    if type(MP.Get) == "function" and MP.Settings then
        local ok, value = pcall(MP.Get, MP.Settings.MaxPlayers)
        if ok then report.connectionMaxPlayers = value end
    end
    local path = "Resources/Server/mxz/settings/activation_usage.json"
    local f = io.open(path .. ".tmp", "w")
    if f then
        f:write(Util.JsonEncode(report)); f:close()
        if os.rename(path .. ".tmp", path) then quotaLastReport = now end
    end
end

local function loadServerSettings()
    local f, openError, openCode = io.open("Resources/Server/mxz/settings/server_settings.json", "r")
    if not f then
        if openCode == 2 then
            serverSettings = activationLimits.settings({})
        else
            serverSettings = activationLimits.settings({normalActivationLimit=0, captainActivationLimit=0})
            print("[MXZ] 无法读取激活限额设置，已暂停新增卡密激活: " .. tostring(openError))
        end
        return
    end
    local ok, data = pcall(Util.JsonDecode, f:read("*a"))
    f:close()
    if not ok or type(data) ~= "table" then
        serverSettings = activationLimits.settings({normalActivationLimit=0, captainActivationLimit=0})
        print("[MXZ] 激活限额设置文件无效，已暂停新增卡密激活")
        return
    end
    serverSettings = activationLimits.settings(data)
end

-- Game role writes use the authenticated account runtime, never the admin master token.

-- Injected after the existing quota/settings helpers, before onActivate.
local function ensureAccountAuth()
    if accountAuth then return accountAuth end
    local file = assert(io.open("Resources/Server/mxz/settings/account_auth.json", "r"), "缺少账号认证配置 account_auth.json")
    local raw = file:read("*a"); file:close()
    local config = assert(Util.JsonDecode(raw), "账号认证配置无效")
    local boot = tostring(os.time()) .. "_" .. tostring(Util.RandomIntRange(100000000,999999999))
    local transport = dofile("Resources/Server/mxz/lib/account_transport.lua").new({
        root="Resources/Server/mxz/settings/account_runtime", boot=boot,
        base_url=config.base_url, token=config.token, server=SERVER_NAME, Util=Util})
    local runtime = dofile("Resources/Server/mxz/lib/account_runtime.lua")
    local commands=dofile("Resources/Server/mxz/lib/account_commands.lua").new({MP=MP,transport=transport,
        identity=function(name)return accountAuth and accountAuth:by_name(name)end})
    accountAuth = runtime.new({MP=MP, transport=transport, commands=commands, nonce=function()
        return boot .. "_" .. tostring(Util.RandomIntRange(100000000,999999999))
    end, adapter={
        check_quota=function(pid, tier, reservations)
            loadServerSettings()
            local active={}
            for id, value in pairs(activatedPlayers) do active[id]=value end
            for id, value in pairs(reservations) do if id~=pid then active[id]=value end end
            return activationLimits.allow(serverSettings, active, playerIdentity, pid, tier)
        end,
        on_login=function(pid, name, identity, grant, refresh)
            local previous=activatedPlayers[pid]
            local changed=not previous or previous.tier~=identity.tier or previous.codename~=identity.codename
            activatedPlayers[pid] = {name=name, key_id=identity.key_id, tier=identity.tier, codename=identity.codename}
            playerNameByID[pid] = name
            pendingActivation[pid], activationWarned[pid] = nil, nil
            publishActivationUsage(true)
            saveState()
            if not refresh or changed then
                sendStateToPlayer(pid)
                broadcastState()
                MP.TriggerClientEvent(-1,"ka_nick",name.."|"..identity.codename.."|"..tostring(identity.tier))
            end
        end,
        on_logout=function(pid, name)
            activatedPlayers[pid] = nil
            publishActivationUsage(true)
            MP.TriggerClientEvent(-1,"ka_rmnick",name)
            saveState()
            broadcastState()
        end
    }})
    return accountAuth
end

function mxz_AccountPoll()
    if accountAuth then accountAuth:tick() end
end

function mxz_AccountShutdown()
    if accountAuth then accountAuth:shutdown() end
    MP.CancelEventTimer("mxz_AccountPoll")
end

function onActivate(playerID, key)
    return ensureAccountAuth():activate(playerID, key)
end



function onSelectRole(playerID, data)
    local name = MP.GetPlayerName(playerID)
    local d = Util.JsonDecode(data)
    if not d or not d.role then return end
    if not playerIdentity[name] or not playerIdentity[name].loggedIn then
        MP.TriggerClientEventJson(playerID, "mxz_toast", {type="error", title="未登录", msg=authDenialMessage(playerID)})
        return
    end
    local ok, msg = assignRole(name, d.role)
    if not ok then
        MP.TriggerClientEventJson(playerID, "mxz_toast", {type="error", title="操作失败", msg=msg})
    elseif msg ~= "already" then
        local names = { criminal = "匪徒", police_normal = "普通警员", police_heavy = "重型单位" }
        MP.TriggerClientEventJson(playerID, "mxz_toast", {type="info", title="职业已选择", msg=names[d.role] or d.role})
    end
    sendStateToPlayer(playerID)
    broadcastState()
end

function onTeleportAll(playerID, data)
    local name = MP.GetPlayerName(playerID)
    if not canControl(name) then
        MP.TriggerClientEventJson(playerID, "mxz_toast", {type="error", title="权限不足", msg="管理员在线，需要管理员身份"})
        return
    end
    local d = data and data ~= "" and Util.JsonDecode(data)
    local targetGroup = d and d.group
    if targetGroup and groups[targetGroup] then
        local ok, msg = teleportGroup(targetGroup)
        if not ok then MP.SendChatMessage(playerID, "[MXZ] " .. msg) end
    else
        local total = 0
        for gname, _ in pairs(groups) do
            local ok, msg = teleportGroup(gname)
            if ok then total = total + 1 end
        end
        MP.SendChatMessage(-1, "[MXZ] 传送了 " .. total .. " 个编组")
    end
end

function onRemoveRole(playerID, targetName)
    if not targetName or targetName == "" then return end
    local name = MP.GetPlayerName(playerID)
    local isSelf = (name == targetName)
    if not isSelf then
        if not canControl(name) then
            MP.TriggerClientEventJson(playerID, "mxz_toast", {type="error", title="权限不足", msg="当前有管理员在线"})
            return
        end
    end
    if removeRoleByCodename((playerIdentity[targetName] and playerIdentity[targetName].codename) or targetName) then
        if not isSelf then
            MP.TriggerClientEventJson(playerID, "mxz_toast", {type="info", title="已移除", msg=targetName .. " 的职业"})
        end
        local tid = MP.GetPlayerIDByName(targetName)
        if tid and tid ~= -1 then
            if isSelf then
                MP.TriggerClientEventJson(tid, "mxz_toast", {type="info", title="已辞职", msg="你的职业已释放"})
            else
                MP.TriggerClientEventJson(tid, "mxz_toast", {type="warning", title="职业被移除", msg="管理员已移除你的职业"})
            end
            sendStateToPlayer(tid)
        end
    else
        MP.TriggerClientEventJson(playerID, "mxz_toast", {type="error", title="操作失败", msg="该玩家无职业"})
    end
    broadcastState()
end

function onAdminTeleport(playerID, data)
    local d = Util.JsonDecode(data)
    if not d or not d.group then return end
    local pts = groups[d.group]
    if not pts then MP.SendChatMessage(playerID, "[MXZ] 编组不存在"); return end
    local idx = tonumber(d.index)
    if not idx or idx < 1 or idx > #pts then MP.SendChatMessage(playerID, "[MXZ] 坐标无效"); return end
    MP.TriggerClientEventJson(playerID, "tp_teleport", pts[idx])
    MP.SendChatMessage(playerID, "[MXZ] 已传送至 " .. d.group .. " #" .. idx)
end

-- ============== Admin Management ==============

local function allowQuotaRoleChange(playerID, codename, tier)
    loadServerSettings()
    local prospective = {}
    for name, id in pairs(playerIdentity) do prospective[name] = id end
    for pid, ap in pairs(activatedPlayers) do
        local id = prospective[ap.name]
        if id and id.loggedIn and id.codename == codename then
            local allowed, reason = activationLimits.allow(serverSettings, activatedPlayers, prospective, pid, tier)
            if not allowed then MP.SendChatMessage(playerID, "[MXZ] " .. reason); return false end
            local nextIdentity = {}
            for key, value in pairs(id) do nextIdentity[key] = value end
            nextIdentity.tier = tier
            prospective[ap.name] = nextIdentity
        end
    end
    return true
end

function onAdminAdd(playerID,codename)
    local auth=ensureAccountAuth()
    local actor=auth:get(playerID)
    if not actor or actor.tier~=3 then MP.SendChatMessage(playerID,"[MXZ] 此操作需要管理员权限"); return end
    if type(codename)~="string" then return end
    if not allowQuotaRoleChange(playerID,codename,3) then return end
    return auth:set_role(playerID,codename,3)
end



function onAdminRemove(playerID,codename)
    local auth=ensureAccountAuth()
    local actor=auth:get(playerID)
    if not actor or actor.tier~=3 then MP.SendChatMessage(playerID,"[MXZ] 此操作需要管理员权限"); return end
    if type(codename)~="string" then return end
    if not allowQuotaRoleChange(playerID,codename,0) then return end
    return auth:set_role(playerID,codename,0)
end



-- ============== 黑手: Config Lookup ==============

function LookupConfig(jbeam, trim)
    local key = jbeam .. "|" .. trim
    local map = {
        ["autobello|150 Corse Track (M)"] = "150_track",
        ["autobello|Baja Unlimited Class 5 (Sequential)"] = "autobuggy_baja_unlimited",
        ["autobello|Baja Extreme (Sequential)"] = "autobuggy_baja_extreme",
        ["autobello|130 (M)"] = "130_m",
        ["midtruck|525-C-2 Rally (M)"] = "6x6_rally_diesel",
        ["barstow|Kingsnake (M)"] = "kingsnake",
        ["barstow|Lancehead (M)"] = "lancehead",
        ["barstow|Police Interceptor (M)"] = "tracksport",
        ["barstow|The Appalling (M)"] = "awful",
        ["barstow|The Awful (M)"] = "awful",
        ["barstow|The Bandit (M)"] = "kingsnake",
        ["barstow|Track (Sequential)"] = "tracksport",
        ["barstow|TrackSport (M)"] = "tracksport",
        ["bastion|Battlehawk (A)"] = "battlehawk_A",
        ["bastion|Battlehawk (M)"] = "battlehawk_M",
        ["bastion|Hotlap Special (M)"] = "hotlap",
        ["bastion|Luxe 5.7 (A)"] = "luxe_v8_A",
        ["bastion|Luxe 5.7 AWD (A)"] = "luxe_v8_awd_A",
        ["bastion|Off-Road (A)"] = "offroad",
        ["bastion|Police 5.7 AWD (A)"] = "police_v8_awd_A",
        ["bastion|Redtail (A)"] = "redtail_A",
        ["bastion|Sport 5.7 (M)"] = "sport_M",
        ["bastion|Sport GT 6.5 (A)"] = "sport_gt_A",
        ["bastion|Sport GT 6.5 (M)"] = "sport_gt_M",
        ["bastion|封面"] = "sport_gt_A",
        ["bluebuck|Police Interceptor (A)"] = "interceptor",
        ["bluebuck|Stock Car (M)"] = "track",
        ["bluebuck|The Horrible (M)"] = "horrible",
        ["bluebuck|Blueshot RS (M)"] = "custom",
        ["bluebuck|Custom (M)"] = "custom",
        ["bluebuck|423 Detective Special (M)"] = "423m_detective_pbfmv",
        ["bluebuck|423 V8 Marshal 4-Door Hardtop (M)"] = "423m_4door_hardtop",
        ["bluebuck|423 V8 Marshal 4-Door Hardtop (A)"] = "423a_4door_hardtop",
        ["bluebuck|423 V8 Marshal 2-Door Hardtop (M)"] = "423m_2door_hardtop",
        ["bluebuck|423 V8 Marshal 2-Door Hardtop (A)"] = "423a_2door_hardtop",
        ["bluebuck|353 V8 Marshal 4-Door Hardtop (A)"] = "353a_4door_hardtop",
        ["bluebuck|353 V8 Marshal 4-Door Hardtop (M)"] = "353m_4door_hardtop",
        ["bluebuck|353 V8 Marshal 2-Door Hardtop (A)"] = "353a_2door_hardtop",
        ["bluebuck|353 V8 Marshal 2-Door Hardtop (M)"] = "353m_2door_hardtop",
        ["bluebuck|353 V8 Marshal 4-Door Sedan (A)"] = "353a_4door",
        ["bluebuck|353 V8 Marshal 4-Door Sedan (M)"] = "353m_4door",
        ["bluebuck|353 V8 Marshal 2-Door Sedan (A)"] = "353a_2door",
        ["bluebuck|353 V8 Marshal 2-Door Sedan (M)"] = "353m_2door",
        ["bluebuck|350 V8 Diesel 4-Door Sedan (M)"] = "353m_4door",
        ["bluebuck|350 V8 Diesel 4-Door Sedan (A)"] = "353a_4door",
        ["bluebuck|232 I6 2-Door Sedan (M)"] = "i6m_2door",
        -- sunburst2
        ["sunburst2|Gendarmerie (DCT)"] = "gendarmerie",
        ["sunburst2|Police Interceptor (DCT)"] = "interceptor",
        ["sunburst2|Itasha (DCT)"] = "itasha",
        ["sunburst2|Street Tuned (M)"] = "street_tuned",
        ["sunburst2|Trackday (M)"] = "trackday_M",
        ["sunburst2|NGRC1 - Asphalt Rally (M)"] = "rally_pro_asphalt",
        ["sunburst2|NGRC1 - Gravel Rally (M)"] = "rally_pro_gravel",
        ["sunburst2|NGRC2 - Asphalt Rally (M)"] = "rally_am_asphalt",
        ["sunburst2|NGRC2 - Gravel Rally (M)"] = "rally_am_gravel",
        ["sunburst2|Track Attack (Sequential)"] = "track_attack",
        ["sunburst2|Polizia (DCT)"] = "polizia",
        ["sunburst2|Sheriff (CVT)"] = "police",
        ["sunburst2|Off-Road (M)"] = "offroad",
        ["sunburst2|2.0 Comfort AWD (M)"] = "comfort_M",
        ["sunburst2|2.0 Comfort Wagon AWD (M)"] = "comfort_wagon_M",
        ["sunburst2|2.5 Comfort AWD (CVT)"] = "comfort_CVT",
        ["sunburst2|2.5 Comfor Wagon AWD (CVT)"] = "comfort_wagon_CVT",
        ["sunburst2|2.5 Sport RS AWD (M)"] = "sport_RS_M",
        ["sunburst2|2.5 Sport RS AWD (DCT)"] = "sport_RS_DCT",
        ["sunburst2|2.5 Sport RS Wagon AWD (M)"] = "sport_RS_wagon_M",
        ["sunburst2|2.5 Sport RS Wagon AWD (DCT)"] = "sport_RS_wagon_DCT",
        ["sunburst2|2.5 Sport RS-Aero AWD (DCT)"] = "sport_RS2_DCT",
        ["sunburst2|2.5 Sport RS-Aero Wagon AWD (DCT)"] = "sport_RS2_wagon_DCT",
        ["sunburst2|2.0 Base FWD (CVT)"] = "base_CVT",
        ["sunburst2|2.0 Base Wagon FWD (CVT)"] = "base_wagon_CVT",
        ["sunburst2|1.6 Sport FWD (M)"] = "sport_EU_M",
        ["sunburst2|1.6 Sport FWD (DCT)"] = "sport_EU_DCT",
        ["sunburst2|1.6 Sport Wagon FWD (M)"] = "sport_EU_wagon_M",
        ["sunburst2|1.6 Sport Wagon FWD (DCT)"] = "sport_EU_wagon_DCT",
        ["sunburst2|2.0 Sport S AWD (M)"] = "sport_S_M",
        ["sunburst2|2.0 Sport S AWD (DCT)"] = "sport_S_DCT",
        ["sunburst2|2.0 Sport S Wagon AWD (M)"] = "sport_S_wagon_M",
        ["sunburst2|2.0 Sport S Wagon AWD (DCT)"] = "sport_S_wagon_DCT",
        ["sunburst2|1.6 Base FWD (M)"] = "base_EU_M",
        ["sunburst2|1.6 Base FWD (CVT)"] = "base_EU_CVT",
        ["sunburst2|1.6 Base Wagon FWD (M)"] = "base_EU_wagon_M",
        ["sunburst2|1.6 Base Wagon FWD (CVT)"] = "base_EU_wagon_CVT",
        ["bolide|320 GT Group 4 - Asphalt (M)"] = "rally_asphalt",
        ["bolide|320 GT Group 4 - Gravel (M)"] = "rally_gravel",
        ["bolide|320 GTT Corse (M)"] = "320gtt",
        ["bolide|350 (M)"] = "350",
        ["bolide|350 Club Racer (M)"] = "clubracer",
        ["bolide|350 Polizia (M)"] = "polizia",
        ["bolide|350 Targa (M)"] = "350_targa",
        ["bolide|390 GT (M)"] = "390gt",
        ["bolide|390 GT Strada (M)"] = "390gt_strada",
        ["bolide|390 GT Targa - USDM (M)"] = "390gt_targa_us",
        ["bolide|Notte (M)"] = "notte",
        ["bolide|Police Cheetah"] = "race",
        ["burnside|Alpine Rally (M)"] = "stockcar",
        ["burnside|Custom (M)"] = "custom",
        ["burnside|Ratrod (M)"] = "ratrod",
        ["bx|'Mako' (M)"] = "vspecial_M",
        ["bx|240BX Coupe DX (Early-A)"] = "240bx_coupe_dx_A",
        ["bx|Diana GTz Turbo RZ (M)"] = "diana_gtz_M",
        ["bx|Diana Type-LS TECNICA (Early-M)"] = "diana_type_ls_M",
        ["bx|Gavril Huntsman Rally (SQ)"] = "240bx_coupe_rally_gravel",
        ["bx|Gavril Huntsman Street Tuned (M)"] = "street_tuned_M",
        ["bx|NGRC2 - Asphalt Rally (M)"] = "240bx_coupe_rally_asp",
        ["bx|NGRC2 - Gravel Rally (M)"] = "240bx_coupe_rally_gravel",
        ["bx|Runner (M)"] = "runner_M",
        ["bx|Street Tuned (Early-M)"] = "street_tuned_M",
        ["bx|Street Tuned (M)"] = "street_tuned_M",
        ["bx|Track (M)"] = "track_M",
        ["bx|240BX LXz SR-TEC Black-Series (M)"] = "240bx_hatch_lxz_srtec_black_M",
        ["bx|Diana Base (M)"] = "diana_base_M",
        ["bx|Diana Base (A)"] = "diana_base_A",
        ["bx|180BX Base (Early-M)"] = "diana_base_M",
        ["bx|200BX Base (M)"] = "200bx_base_M",
        ["bx|200BX Base (A)"] = "200bx_base_A",
        ["bx|Gavril Huntsman (A)"] = "200bx_base_A",
        ["bx|Gavril Huntsman (M)"] = "200bx_base_M",
        ["bx|240BX Coupe DX (M)"] = "240bx_coupe_dx_M",
        ["bx|240BX DX (M)"] = "240bx_hatch_dx_M",
        ["bx|200BX Type-L (A)"] = "200bx_type_l_A",
        ["bx|Diana Type-LS (M)"] = "diana_type_ls_M",
        ["bx|200BX Type-LS (M)"] = "200bx_type_ls_M",
        ["bx|240BX Coupe SE Turbo (M)"] = "240bx_coupe_lx_M",
        ["bx|240BX Coupe SE Turbo (A)"] = "240bx_coupe_lx_A",
        ["bx|240BXC Convertible SE Turbo (A)"] = "240bx_coupe_lx_A",
        ["bx|240BX LXz SR-TEC (M)"] = "240bx_hatch_lxz_M",
        ["bx|Diana Type-LS SR-TEC (M)"] = "diana_type_ls_srtec_M",
        ["bx|Diana Type-LS TECNICA (Early-M)"] = "diana_type_ls_srtecnica_M",
        ["bx|Gavril Huntsman V8 (M)"] = "vspecial_M",
        ["bx|Diana GTz Turbo 'Hearts' (Early-M)"] = "diana_gtz_M",
        ["bx|Diana Convertible GTz Turbo TECNICA Type-I (Early-M)"] = "diana_gtz_M",
        ["bx|Gavril Huntsman RoadSport (M)"] = "vspecial_M",
        ["bx|Diana TECNICA Z270 (M)"] = "diana_gtz_M",
        ["bx|Diana TECNICA Z270 (Early-M)"] = "diana_gtz_M",
        ["bx|240BX DX (Early-A)"] = "240bx_hatch_dx_A",
        ["bx|Diana Ute GTz Turbo (M)"] = "diana_gtz_M",
        ["bx|200BX Ute Base (M)"] = "200bx_base_M",
        ["bx|200BX Ute Base (A)"] = "200bx_base_A",
        ["etk800|854 250 (A)"] = "854x_250_A",
        ["hopper|LXT-4 (A)"] = "lxt4_A",
        ["hopper|XT-4 (A)"] = "xt4_A",
        ["hopper|XT-4 (M)"] = "xt4_M",
        ["legran|Sport SE V6 AWD (M)"] = "sport_se_v6_awd_facelift_M",
        ["pessima|1700 ETCC #58 GripAll (Sequential)"] = "race",
        ["pessima|1800 GL Diesel (M)"] = "DX_M",
        ["pessima|2000 Comfort Cab LX (A)"] = "LX_A",
        ["pigeon|base"] = "base",
        ["pigeon|base_4w"] = "base_4w",
        ["pigeon|cool_4w"] = "cool_4w",
        ["pigeon|drag"] = "drag",
        ["rockbouncer|ST2 Stadium (A)"] = "rock_racer",
        ["rockbouncer|TT1 Unlimited (A)"] = "rock_bouncer_n2o",
        ["vivace|Vivace 190Sd  (DCT)"] = "vivace_190Sd_DCT",
        ["wendover|Flik Appliances Ten Thousand (M)"] = "super",
        ["wigeon|base"] = "base",
        ["wigeon|base_4w"] = "base_4w",
        ["wigeon|drag"] = "drag",
        ["wigeon|lx"] = "lx",
        ["wigeon|lx_4w"] = "lx_4w",
        ["wigeon|pondskipper"] = "pondskipper",
        ["citybus|City (A)"] = "city",
        ["covet|2.0 Track (M)"] = "sport",
        ["covet|MR Turbo (M)"] = "turbo",
        ["covet|MR Turbo Evolution (M)"] = "turbo_evolution",
        ["covet|MR Turbo Race (Sequential)"] = "turbo_race",
        ["covet|MR Turbo Rally (M)"] = "turbo_rally",
        ["covet|Kanjozoku (M)"] = "15gtz_turbo_M",
        ["covet|Steet Tuned (M)"] = "sport",
        ["covet|16GTz SR-TECNICA (M)"] = "16gtz_srtecnica_M",
        ["covet|16GTz SR-TEC Black Series (M)"] = "16gtz_srtec_black_M",
        ["covet|16GTz SR-TEC EDX Black Series (Early-M)"] = "16gtz_srtec_pre_edx_black_M",
        ["covet|15GTz Turbo II (M)"] = "15gtz_turbo2_M",
        ["covet|2.0 GTz (M)"] = "gtz",
        ["covet|1.6 GTz SR-TEC EDX (Early-M)"] = "15gtz_turbo_M",
        ["covet|1.8 Street (M)"] = "sport",
        ["covet|Type-X (M)"] = "15zxi_M",
        ["covet|Type-LS Royale (M)"] = "type_LS_royale_M",
        ["covet|Type-LS Royale (A)"] = "type_LS_royale_A",
        ["covet|Type-LS Sedan (M)"] = "type_LS_M",
        ["covet|Type-LS (M)"] = "type_LS_M",
        ["covet|1.5 ZXi Special Edition (M)"] = "sport_alt",
        ["covet|Type-L (M)"] = "type_L_M",
        ["covet|The Pointless (M)"] = "pointless",
        ["covet|1.5 DXi (M)"] = "DXi_M",
        ["covet|1.5 DX Sedan (M)"] = "DX_pre_M",
        ["covet|1.5 DXi (A)"] = "DXi_A",
        ["covet|1.5 DXi EDX (Early-M)"] = "DXi_pre_edx_M",
        ["covet|1.5 DXi Sedan (A)"] = "DXi_pre_edx_A",
        ["covet|HXi Sedan (M)"] = "LXi_M",
        ["covet|NGRC2 - Asphalt Rally (M)"] = "rally_asphalt",
        ["covet|NGRC2 - Gravel Rally (M)"] = "rally_gravel",
        ["covet|Runner (M)"] = "runner",
        ["covet|Street Tuned (M)"] = "custom",
        ["covet|Student Driver (M)"] = "student_driver",
        ["covet|Track (M)"] = "race",
        ["etk800|844 150 (M)"] = "844_150_M",
        ["etk800|846tt 310d (A)"] = "846_310d_A",
        ["etk800|846tt Driving Expeirence (A)"] = "846x_driving_experience_A",
        ["etk800|854 150d (M)"] = "854_150d_M",
        ["etk800|854 190 (A)"] = "854_190_A",
        ["etk800|854 190d (A)"] = "854_190d_A",
        ["etk800|854 Polizei (A)"] = "854_police_A",
        ["etk800|854x 250 (A)"] = "854x_250_A",
        ["etk800|855 Police (A)"] = "854_police_A",
        ["etk800|856 ttSport (DCT)"] = "856_ttsport_DCT",
        ["etk800|856 ttSport Heritage Edition (M)"] = "846_ttsport_heritage_M",
        ["etk800|856tt 340 (A)"] = "856x_340_A",
        ["etk800|856ttx 310d (A)"] = "856x_310d_A",
        ["etk800|856ttx 340 (A)"] = "856x_340_A",
        ["etk800|856xc 260d (A)"] = "856xc_260d_A",
        ["etk800|856xc 300 (A)"] = "856xc_300_A",
        ["etk800|Knallhart (DCT)"] = "846_ttSport_custom_DCT",
        ["etk800|Rennspecht 8R (A)"] = "rennspecht_8r_A",
        ["etkc|1345 190 (A)"] = "kc4_250_A",
        ["etkc|1354 190d (A)"] = "kc4_250_A",
        ["etkc|1354x 190 (A)"] = "kc6x_360_A",
        ["etkc|1354x 230d (A)"] = "kc6x_310d_A",
        ["etkc|1354x 250 (A)"] = "kc6x_360_A",
        ["etkc|1354x 260d (A)"] = "kc6x_310d_A",
        ["etkc|1354x Off-Road (M)"] = "kc4_street_tuned_M",
        ["etkc|1356 The Perfecter (M)"] = "kc6_360_M",
        ["etkc|1356ttx 340 (A)"] = "kc6x_360_A",
        ["etkc|1356ttx 360 (A)"] = "kc6x_360_A",
        ["etkc|1356ttx 380d (A)"] = "kc6x_310d_A",
        ["etkc|1356x Taxi (A)"] = "kc6_360_A",
        ["etkc|1356x ttSport (DCT)"] = "kc6x_360_M",
        ["etkc|1356xc 260d (A)"] = "kc6x_310d_A",
        ["etkc|1358ttx 450 (A)"] = "kc8x_ttsport_plus_DCT",
        ["etkc|1358x 490 Exclusive (A)"] = "kc8_ttsport_DCT",
        ["etkc|1358x ttSport+ (DCT)"] = "kc8x_ttsport_plus_DCT",
        ["etkc|1358x ttSport+ Heritage Edition (DCT)"] = "kc8_ttsport_heritage_M",
        ["etkc|GT-IV (DCT)"] = "race_DCT",
        ["etkc|Rennspecht 13R (A)"] = "rennspecht_kr_A",
        ["etkc|kc4 250 (A)"] = "kc4_250_A",
        ["etkc|kc4 250 (M)"] = "kc4_250_M",
        ["etkc|kc4 Street Tuned (M)"] = "kc4_street_tuned_M",
        ["etkc|kc6 360 (A)"] = "kc6_360_A",
        ["etkc|kc6 360 (M)"] = "kc6_360_M",
        ["etkc|kc6x 310d (A)"] = "kc6x_310d_A",
        ["etkc|kc6x 310d Driving Experience (M)"] = "kc6x_310d_driving_experience_M",
        ["etkc|kc6x 340 Autobahn Polizei (A)"] = "kc6x_340_police_highway_A",
        ["etkc|kc6x 360 Police Interceptor"] = "kc6x_340_police_highway_A",
        ["etkc|kc6x Trackday (A)"] = "kc6x_trackday_A",
        ["etkc|kc8 ttSport (DCT)"] = "kc8_ttsport_DCT",
        ["etkc|kc8 ttSport Heritage Edition (M)"] = "kc8_ttsport_heritage_M",
        ["etkc|kc8x ttSport+ (DCT)"] = "kc8x_ttsport_plus_DCT",
        ["etki|2400ti TTSport (M)"] = "2400ti_sport_M_alt",
        ["etki|2400ti TTSport Evolution (M)"] = "2400ti_sport_evo_M",
        ["etki|2400tix TTSport (M)"] = "2400tix_sport_M_alt",
        ["etki|2400tix TTSport Evolution (M)"] = "2400tix_sport_evo_M",
        ["etki|3000i (A)"] = "3000i_A_alt",
        ["etki|3000i (M)"] = "3000i_M_alt",
        ["etki|3000ix (A)"] = "3000ix_A_alt",
        ["etki|3000ix (M)"] = "3000ix_M_alt",
        ["etki|3000ix Unmarked (A)"] = "3000ix_A",
        ["etki|Knallhart (M)"] = "cool",
        ["etki|NGRC2 - Asphalt Rally (M)"] = "rally_am_asphalt",
        ["etki|NGRC2 - Gravel Rally (M)"] = "rally_am_gravel",
        ["etki|Police Interceptor (M)"] = "offroad",
        ["etki|Rally - Gravel (M)"] = "rally",
        ["etki|Street Tuned (M)"] = "custom",
        ["etki|Track (M)"] = "race",
        ["etki|Gambler 500 (A)"] = "offroad",
        ["etki|2400 (M)"] = "2400_M_alt",
        ["etki|2400 (A)"] = "2400_A_alt",
        ["etki|2400i (A)"] = "2400i_A_alt",
        ["etki|2400ix (A)"] = "2400ix_A_alt",
        ["fullsize|LX Sport"] = "sport",
        ["fullsize|Police Interceptor"] = "interceptor",
        ["fullsize|Police Package"] = "police",
        ["fullsize|Unmarked"] = "unmarked",
        ["hopper|Classic (M)"] = "classic",
        ["hopper|Crawler (A)"] = "crawler",
        ["hopper|Custom (A)"] = "custom",
        ["hopper|Dune Edition (M)"] = "desert_M",
        ["hopper|LXT-4 (M)"] = "lxt4_M",
        ["hopper|LXT-6 (M)"] = "lxt6_M",
        ["hopper|Off-Road (M)"] = "offroad",
        ["hopper|Rock Racer (A)"] = "rock_racer",
        ["hopper|Sport Special (M)"] = "sport_M",
        ["hopper|Trackday (M)"] = "race",
        ["lansdale|2.5 Rally (M)"] = "25_rally_M",
        ["lansdale|3.8 SE AWD Overland (A)"] = "38_overland_AWD_A",
        ["lansdale|3.8 Sport SE AWD (A)"] = "38_SE_sport_AWD_late_A",
        ["lansdale|Super Tuner (M)"] = "38_tuner_late_M",
        ["lansdale|4.4 V8 Tuner Special Supercharged AWD (M)"] = "44_tuner_special_AWD_SC_M",
        ["lansdale|3.8 Race (M)"] = "38_race_late_M",
        ["lansdale|Turbo Tuner (M)"] = "25_tuner_M",
        ["lansdale|Unmarked Police Taxi (A)"] = "25_taxi_A",
        ["lansdale|3.3 S (M)"] = "33_S_late_A",
        ["lansdale|3.3 S Police (A)"] = "33_police_late_A",
        ["legran|Custom (M)"] = "custom",
        ["legran|Race (M)"] = "race",
        ["legran|Rally (M)"] = "rally",
        ["miramar|Mira-Mighty (M)"] = "miramighty",
        ["miramar|Safari Rally (M)"] = "safari_rally",
        ["miramar|Street Tuned (M)"] = "custom",
        ["miramar|Track (M)"] = "race",
        ["miramar|GTz Coupe (M)"] = "sport_coupe_facelift",
        ["miramar|Canyon King (M)"] = "drift",
        ["miramar|GTz (M)"] = "sport_facelift",
        ["miramar|Export Ute (M)"] = "ute_export_M_late",
        ["miramar|Export Base (M)"] = "base_export_M_late",
        ["miramar|Luxe Mira-Matic (A)"] = "luxe_facelift_A",
        ["miramar|Ute (M)"] = "base_ute_M",
        ["moonhawk|448 V8 Special (M)"] = "v8special",
        ["moonhawk|448 V8 Sport (M)"] = "v8m_sport_alt",
        ["moonhawk|488 Elite Custom (M)"] = "drive",
        ["moonhawk|Track"] = "race",
        ["nine|Bootlegger (M)"] = "nine_runner",
        ["nine|Hot Beams Custom (A)"] = "nine_hotbeams",
        ["nine|Phantom Sedan Restomod"] = "nine_restomod",
        ["nine|Sharp Dressed Speedster (A)"] = "nine_restomod_coupe",
        ["nine|Sundown Coupe"] = "nine_coupe",
        ["nine|Valley Speedster (M)"] = "nine_restomod_coupe",
        ["pessima|1300 Rally (Sequential)"] = "rally",
        ["pessima|Hillclimb - Asphalt (Sequential)"] = "hillclimb",
        ["pessima|JTCC (Sequential)"] = "race",
        ["pessima|Pro Tuned (M)"] = "custom2",
        ["pessima|Rally (Sequential)"] = "rally",
        ["pessima|Rally - Gravel (M)"] = "rally",
        ["pessima|Street Tuned (M)"] = "custom",
        ["pessima|Street Tuned Wagon (M)"] = "LX_M_kljpwagon",
        ["pessima|Touring Car (Sequential)"] = "race",
        ["pessima|Track (M)"] = "race",
        -- midsize (1996 Pessima)
        ["midsize|Touring Car (Sequential)"] = "race",
        ["midsize|Rally (Sequential)"] = "rally",
        ["midsize|Street Tuned (M)"] = "custom",
        ["midsize|The Unpalatable (M)"] = "derby",
        ["midsize|2.7 LX V6 Sport GTz (M)"] = "special",
        ["midsize|Unmarked Police Taxi (A)"] = "sg_A",
        ["midsize|2.7 LX V6 Sport (A)"] = "LX_V6_sport_A",
        ["midsize|2.7 LX V6 (A)"] = "LX_V6_A",
        ["midsize|2.7 LX V6 (M)"] = "LX_V6_M",
        ["midsize|2.0 LX Sport (A)"] = "LX_sport_A",
        ["midsize|2.0 LX Sport (M)"] = "LX_sport_M",
        ["midsize|1.8 DX TurboBurger (A)"] = "turboburger",
        ["midsize|1.8 DX (A)"] = "DX_A",
        ["midsize|1.8 DX (M)"] = "DX_M",
        ["pigeon|Race (M)"] = "race",
        ["roamer|Belasco Police (A)"] = "police",
        ["roamer|Off-Road (M)"] = "offroad",
        ["roamer|Street Tuned (M)"] = "street_tuned",
        ["rockbouncer|Rock Bouncer (A)"] = "rock_bouncer_n2o",
        ["rockbouncer|Rock Crawler (A)"] = "rock_crawler",
        ["rockbouncer|Rock Racer (A)"] = "rock_racer",
        ["rockbouncer|TT2 Spec (A)"] = "rock_crawler",
        ["scintilla|Amateur Rally - Asphalt (Sequential)"] = "rally",
        ["scintilla|Custom (DCT)"] = "custom",
        ["scintilla|Dark Owl - Movie Car (Sequential)"] = "dark_owl",
        ["scintilla|GT (DCT)"] = "gt",
        ["scintilla|GT Spyder (DCT)"] = "gt_spider",
        ["scintilla|GTs (DCT)"] = "gts",
        ["scintilla|GTs Corse (DCT)"] = "gts_corse",
        ["scintilla|GTs Corse Spyder (DCT)"] = "gts_corse_spider",
        ["scintilla|GTs Polizia (DCT)"] = "gts_polizia",
        ["scintilla|GTs Spyder (DCT)"] = "gts_spider",
        ["scintilla|GTx (DCT)"] = "gtx",
        ["scintilla|GTx Spyder (DCT)"] = "gtx_spider",
        ["scintilla|Off-Road (DCT)"] = "offroad",
        ["scintilla|Race (Sequential)"] = "race",
        ["signia|Race (M)"] = "race",
        ["signia|Rally (M)"] = "rally",
        ["signia|Street Tuned"] = "sport",
        ["vivace|Hillclimb (Sequential)"] = "hillclimb_SQ",
        ["vivace|Race (Sequential)"] = "race_SQ",
        ["vivace|Tograc 110 (M)"] = "tograc_110_M",
        ["vivace|Tograc 150dQX (DCT)"] = "tograc_150dqX_DCT",
        ["vivace|Tograc 190dQ (DCT)"] = "tograc_190dq_DCT",
        ["vivace|Tograc Amateur Rally - Gravel (DCT)"] = "tograc_amrally_DCT",
        ["vivace|Tograc Polizia (M)"] = "tograc_polizia",
        ["vivace|Tograc qE"] = "tograc_qE",
        ["vivace|Trackday (M)"] = "trackday_M",
        ["vivace|Vivace 100d (M)"] = "vivace_110d_M",
        ["vivace|Vivace 150d (M)"] = "vivace_150d_M",
        ["vivace|Vivace 160 (DCT)"] = "vivace_160_DCT",
        ["vivace|Vivace 190Sd (DCT)"] = "vivace_190Sd_DCT",
        ["vivace|Vivace 230S (DCT)"] = "vivace_230S_DCT",
        ["vivace|Vivace 410Q Arsenic (DCT)"] = "vivace_S_410q_DCT",
        ["vivace|Vivace 410q (M)"] = "vivace_S_410q_M",
        ["vivace|Vivace E"] = "vivace_E",
        ["vivace|Vivace NGRC1 - Asphalt Rally (Sequential)"] = "asphalt_SQ",
        ["vivace|Vivace NGRC1 - Gravel Rally (Sequential)"] = "gravel_SQ",
        ["vivace|Vivace Polizia"] = "vivace_polizia",
        ["vivace|Vivace S 270 (DCT)"] = "vivace_S_270_DCT",
        ["vivace|Vivace S 270 (M)"] = "vivace_S_270_M",
        ["vivace|Vivace S 310 (M)"] = "vivace_S_310_M",
        ["vivace|Vivace S 310 Arsenic (DCT)"] = "vivace_S_310_DCT",
        ["vivace|Vivace S 350 (DCT)"] = "vivace_S_350q_DCT",
        ["vivace|Vivace S 350q (M)"] = "vivace_S_350q_M",
        ["vivace|Vivace S Gendarmerie"] = "vivace_S_gendarmerie",
        ["wendover|Hillclimb (Sequential)"] = "hillclimb",
        ["wendover|Police Interceptor (A)"] = "interceptor",
        ["wendover|Race (M)"] = "race",
        ["wendover|Rally (M)"] = "rally",
        ["wendover|Safety Car (M)"] = "safetycar",
        ["wendover|Street Tuned (M)"] = "Street_tuned",
        ["wendover|Super"] = "super",
        ["wigeon|The Mantis (M)"] = "mantis",
        -- barstow missing
        ["barstow|Aero TrackSport (M)"] = "tracksport",
        ["barstow|Early TrackSport (M)"] = "tracksport",
        ["barstow|V8 RoadSport (M)"] = "tracksport",
        ["barstow|V8 RoadSport Convertible (M)"] = "tracksport",
        ["barstow|Night Snake (M)"] = "tracksport",
        ["barstow|SuperStock (M)"] = "423m",
        ["barstow|SuperSport (M)"] = "423m_sport",
        ["barstow|Javelin (M)"] = "lancehead",
        ["barstow|Early RoadSport Package (M)"] = "291a_sport",
        ["barstow|327 V8 Atom-Jet (M)"] = "353a_sport",
        ["barstow|423 V8 RoadSport Package (M)"] = "423m_sport",
        ["barstow|423 V8 RoadSport Package (A)"] = "423a_sport",
        ["barstow|Aero RoadSport (M)"] = "423a_sport",
        ["barstow|Early LuxeSport Package (A)"] = "423a",
        ["barstow|423 V8 (A)"] = "423a",
        ["barstow|423 V8 (M)"] = "423m",
        ["barstow|Police (A)"] = "423a",
        ["barstow|353 V8 RoadSport Package (M)"] = "353m_sport",
        ["barstow|353 V8 RoadSport Package (A)"] = "353a_sport",
        ["barstow|291 V8 RoadSport Package (M)"] = "291m_sport",
        ["barstow|291 V8 RoadSport Package (A)"] = "291a_sport",
        ["barstow|Early 353 V8 (M)"] = "353m",
        ["barstow|353 V8 (M)"] = "353m",
        ["barstow|353 V8 (A)"] = "353a",
        ["barstow|291 V8 (M)"] = "291m",
        ["barstow|291 V8 (A)"] = "291a",
        ["barstow|V8 RoadSport (A)"] = "tracksport",
        ["barstow|V8 Sport (M)"] = "423m_sport",
        ["barstow|V8 Sport (A)"] = "423a_sport",
        ["barstow|V8 Sport Convertible (M)"] = "423m_sport",
        ["barstow|V8 Sport Convertible (A)"] = "423a_sport",
        ["barstow|Police Package (A)"] = "423a",
        ["barstow|I6 (M)"] = "i6m",
        ["barstow|I6 (A)"] = "i6a",
        ["barstow|I6 Convertible (M)"] = "i6m",
        ["barstow|I6 Convertible (A)"] = "i6a",
        ["barstow|232 I6 (M)"] = "i6m",
        ["barstow|The Seroent (M-A)"] = "kingsnake",
        ["barstow|Disgustow (M-A)"] = "awful",
        ["barstow|Zootopia Police Department"] = "tracksport",
        ["barstow|Steet Tuned (M)"] = "custom",
        ["barstow|V8 (M)"] = "423m",
        ["barstow|V8 (A)"] = "423a",
        ["barstow|V8 Convertible (M)"] = "423m",
        ["barstow|V8 Convertible (A)"] = "423a",
        ["bastion|Taxi (A)"] = "taxi",
        ["bastion|Luxe 3.5 AWD (A)"] = "luxe_v6_awd_A",
        ["bastion|SE 3.5 (A)"] = "base_v6_A",
        ["bastion|SE AWD (A)"] = "base_v6_awd_A",
        -- bolide
        ["bolide|Gambler 500 - Iron Owl (A)"] = "gambler",
        -- burnside
        ["burnside|Bootlegger (M)"] = "bootlegger",
        ["burnside|Viceroy (A)"] = "4door_late_v8_3A_luxe",
        ["burnside|Stock Car (M)"] = "stockcar",
        ["burnside|347 V8 Luxe 4-Door Sedan (A)"] = "4door_late_v8_3A_luxe",
        ["burnside|423 V8 Police Interceptor (A)"] = "4door_late_v8_3A_police",
        ["burnside|banger"] = "banger",
        ["burnside|gasser_late"] = "gasser_late",
        ["burnside|leadsled"] = "leadsled",
        ["burnside|stunned"] = "stunned",
        -- fullsize
        ["fullsize|Marauder"] = "roadsport",
        ["fullsize|Fire, Belasco"] = "bcpd",
        ["fullsize|Rapid Taxi"] = "taxi",
        ["fullsize|LX"] = "luxe",
        ["fullsize|Base"] = "stock",
        ["fullsize|HPP"] = "fleet",
        ["fullsize|flyUS Airport"] = "fleet",
        -- Grand Marshal (fullsize)
        ["fullsize|Track (M)"] = "track",
        ["fullsize|V8 RoadSport (M)"] = "roadsport",
        ["fullsize|Street Tuned (M)"] = "sport",
        ["fullsize|Belasco Police (A)"] = "bcpd",
        ["fullsize|Unmarked Taxi Cab (A)"] = "unmarked",
        ["fullsize|Police Interceptor (A)"] = "interceptor",
        ["fullsize|V8 Sport (A)"] = "sport",
        ["fullsize|V8 (A)"] = "stock",
        ["fullsize|Taxi (A)"] = "taxi",
        ["fullsize|Fleet (A)"] = "fleet",
        ["fullsize|The Miserable (A)"] = "miserable",
        ["fullsize|V8 Luxe (A)"] = "luxe",
        -- legran
        ["legran|S V6 (A)"] = "s_v6_A",
        ["legran|SE V6 Wagon (Facelift) (A)"] = "se_v6_wagon_facelift_A",
        ["legran|SE (A)"] = "se_i4_A",
        ["legran|Sport SE (Facelift) (M)"] = "sport_se_i4_facelift_M",
        ["legran|Fire Cheif (Facelift) (A)"] = "firechief",
        ["legran|The Objectionable (M)"] = "derby_wagon",
        -- moonhawk
        ["moonhawk|448 V8 GH/S (M)"] = "v8m_sport",
        ["moonhawk|309 V8 (A)"] = "v8a_alt",
        ["moonhawk|448 V8 GH/S (M)"] = "448_ghs_early_m",
        ["moonhawk|309 V8 (A)"] = "v8a_alt",
        -- nine
        ["nine|nine_coupe_luxe"] = "nine_coupe_luxe",
        ["nine|nine_dragvan"] = "nine_dragvan",
        ["nine|nine_drift"] = "nine_drift",
        ["nine|nine_gasser"] = "nine_gasser",
        ["nine|nine_hotrod_60s"] = "nine_hotrod_60s",
        ["nine|nine_hotrod_vintage"] = "nine_hotrod_vintage",
        ["nine|nine_junkrod"] = "nine_junkrod",
        ["nine|nine_overlander"] = "nine_overlander",
        ["nine|nine_pickup"] = "nine_pickup",
        ["nine|nine_pickup_hotrod"] = "nine_pickup_hotrod",
        ["nine|nine_pickup_short"] = "nine_pickup_short",
        ["nine|nine_police"] = "nine_police",
        ["nine|nine_restomod_coupe"] = "nine_restomod_coupe",
        ["nine|nine_roadster_luxe"] = "nine_roadster_luxe",
        ["nine|nine_runner"] = "nine_runner",
        ["nine|nine_sedan"] = "nine_sedan",
        ["nine|nine_sedan_luxe"] = "nine_sedan_luxe",
        ["nine|nine_taxi"] = "nine_taxi",
        ["nine|nine_van_ext"] = "nine_van_ext",
        ["nine|nine_van_standard"] = "nine_van_standard",
        ["nine|Bullet Proof (M)"] = "nine_pickup_hotrod",
        -- roamer
        ["roamer|V8 RoadSport LXT (M)"] = "sport_ext_m",
        ["roamer|V8 RoadSport LXT (A)"] = "sport_ext",
        ["roamer|LXT35 Police Package (Unmarked) (A)"] = "unmarked",
        ["roamer|V8 RoadSport (A)"] = "sport",
        ["roamer|V8 RoadSport (M)"] = "sport_m",
        ["roamer|LXT (A) (Facelift)"] = "lxt_facelift",
        ["roamer|4WD LXT (A) (Facelift)"] = "4wd_lxt_facelift",
        ["roamer|Base (A) (Facelift)"] = "facelift",
        ["roamer|4WD Base (A) (Facelift)"] = "4wd_facelift",
        ["roamer|V8 LXT (A)"] = "v8_lxt",
        ["roamer|V8 4WD XT (A)"] = "v8_4wd_xt",
        ["roamer|V8 4WD (A)"] = "v8_4wd",
        ["roamer|V8 4WD (M)"] = "v8_4wd_m",
        ["roamer|V8 (A)"] = "v8",
        ["roamer|V8 (M)"] = "v8_m",
        ["roamer|I6 4WD (M)"] = "i6_4wd_m",
        ["roamer|I6 (M)"] = "i6_m",
        ["roamer|sheriff"] = "sheriff",
        ["roamer|adventure"] = "adventure",
        ["roamer|v8_xt"] = "v8_xt",
        ["roamer|v8_lxt_35"] = "v8_lxt_35",
        ["roamer|xt_facelift"] = "xt_facelift",
        -- lansdale
        ["lansdale|gambler500"] = "gambler500",
        -- wendover
        ["wendover|Sport SE 3800 (A)"] = "sport_se_v6_A",
        ["wendover|Sport SE 3800 (M)"] = "sport_se_v6_M",
        ["wendover|Sport SE 3800 (Facelift) (A)"] = "sport_se_v6_A_facelift",
        ["wendover|Sport SE 4400 V8 (Facelift) (A)"] = "sport_se_v8_A_facelift",
        ["wendover|SE 3800 (Facelift) (A)"] = "se_v6_A_facelift",
        ["wendover|SE 3800 (A)"] = "se_v6_A",
        ["wendover|Sport S 3800 (A)"] = "sport_s_v6_A",
        ["wendover|derby"] = "derby",
        ["wendover|gambler"] = "gambler",
        ["wendover|junkhana"] = "junkhana",
        ["wendover|base_v6_A"] = "base_v6_A",
        ["wendover|base_v6_A_facelift"] = "base_v6_A_facelift",
        ["wendover|se_v8_A"] = "se_v8_A",
        ["wendover|se_v8_A_facelift"] = "se_v8_A_facelift",
        ["wendover|sport_se_v8_A"] = "sport_se_v8_A",
        ["wendover|sport_se_v8_A_facelift"] = "sport_se_v8_A_facelift",
        -- SBR (Hirochi SBR4)
        ["sbr|Hillclimb - Asphalt (Sequential)"] = "hillclimb_SQ",
        ["sbr|Hillclimb - Asphalt (DCT)"] = "hillclimb",
        ["sbr|Track (Sequential)"] = "track",
        ["sbr|eSBR 800 Police Interceptor"] = "electric_800",
        ["sbr|eSBR 800"] = "electric_800",
        ["sbr|eSBR 500"] = "electric_500",
        ["sbr|eSBR 300"] = "electric_300",
        ["sbr|Street Tuned (M)"] = "custom",
        ["sbr|NGRC2 - Rally Gravel (M)"] = "rally_am_gravel",
        ["sbr|NGRC2 - Rally Asphalt (M)"] = "rally_am_asphalt",
        ["sbr|RWD GTs6-r Empyrean (DCT)"] = "custom",
        ["sbr|RWD GTs6 Elysian (DCT)"] = "custom",
        ["sbr|RWD GTs6 Elysian (M)"] = "custom",
        ["sbr|AMD TT S2 Olympian (DCT)"] = "TT_AWD_S2_DCT",
        ["sbr|AWD TT S2 Olympian (M)"] = "TT_AWD_S2_M",
        ["sbr|AMD TT S2 (DCT)"] = "TT_AWD_S_DCT",
        ["sbr|AWD TT S2 (M)"] = "TT_AWD_S2_M",
        ["sbr|AWD TT S Cyborg (DCT)"] = "TT_AWD_S_DCT",
        ["sbr|Police Interceptor (DCT)"] = "electric_800",
        ["sbr|AWD TT S (DCT)"] = "TT_AWD_S_DCT",
        ["sbr|AWD TT S (M)"] = "TT_AWD_S_M",
        ["sbr|AWD TT S Athlete (DCT)"] = "TT_AWD_S_DCT",
        ["sbr|AWD TT S Athlete (M)"] = "TT_AWD_S_M",
        ["sbr|RWD TT S (DCT)"] = "TT_RWD_S_DCT",
        ["sbr|RWD TT S (M)"] = "TT_RWD_S_M",
        ["sbr|AWD S Enthusiast (M)"] = "S_AWD_M",
        ["sbr|AWD S Enthusiast (DCT)"] = "S_AWD_fl_DCT",
        ["sbr|AWD S (DCT)"] = "S_AWD_DCT",
        ["sbr|AWD S (M)"] = "S_AWD_M",
        ["sbr|RWD S (DCT)"] = "S_RWD_DCT",
        ["sbr|RWD S (M)"] = "S_RWD_M",
        ["sbr|RWD Base (DCT)"] = "base_RWD_DCT",
        ["sbr|RWD Base (M)"] = "base_RWD_M",
        ["sbr|RWD Purist (DCT)"] = "S_RWD_DCT",
        ["sbr|RWD Pursit (M)"] = "S_RWD_M",
        -- ETK S-Series (etkss 模组)
        ["etkss|Ss12x Track (SQ)"] = "ss12x_track_SQ",
        ["etkss|Sl12x 580 Exclusive (A)"] = "sl12x_580_exclusive_A",
        ["etkss|Ss8 ttSport GT-S Heritage Edition (DCT)"] = "ss8x_ttsportgts_heritage_DCT",
        ["etkss|Ss12 ttSport GT-R (DCT)"] = "ss12x_ttsportgtr_DCT",
        ["etkss|Ss12 ttSport GT (DCT)"] = "ss12_ttsportgt_DCT",
        ["etkss|Rennspecht SR (A)"] = "rennspecht_sr_A",
        ["etkss|Ss8 ttSport+ (DCT)"] = "ss8x_ttsport_plus_DCT",
        ["etkss|Ss8 ttSport (DCT)"] = "ss8_ttsport_DCT",
        ["etkss|Sl12ttx 600 (A)"] = "sl12x_600_A",
        ["etkss|Ss12ttx 600 (A)"] = "ss12x_600_A",
        ["etkss|Sl8ttx 450 (A)"] = "sl8x_450_A",
        ["etkss|Ss6ttx 360 Dynamic+ (A)"] = "ss6x_360_dynamic_A",
        ["etkss|Sl6ttx Driving Experience (A)"] = "sl6x_driving_experience_A",
        ["etkss|Sl6ttx 380d (A)"] = "sl6x_380d_A",
        ["etkss|Sl6ttx 340 (A)"] = "sl6x_340_A",
        ["etkss|Ss8ttx 450 (A)"] = "ss8x_450_A",
        ["etkss|Ss6ttx 380d (A)"] = "ss6x_380d_A",
        ["etkss|Ss6ttx 340 (A)"] = "ss6x_340_A",
        ["etkss|Sl6ttx 310d (A)"] = "sl6x_310d_A",
        ["etkss|Ss6ttx 310d (A)"] = "ss6x_310d_A",
        ["etkss|Sl6x 300 (A)"] = "sl6x_300_A",
        ["etkss|Sl6x 260d (A)"] = "sl6x_260d_A",
        ["etkss|Sl4x 250 (A)"] = "sl4x_250_A",
        ["etkss|Ss6x Firwood Police (A)"] = "ss6x_firwood_A",
        ["etkss|Ss6x BCPD (A)"] = "ss6x_bcpd_A",
        ["etkss|Ss6x 300 (A)"] = "ss6x_300_A",
        ["etkss|Sl4x 230d (A)"] = "sl4x_230d_A",
        ["etkss|Ss6x 260d (A)"] = "ss6x_260d_A",
        ["etkss|Ss4x Polizei (A)"] = "ss4x_polizei_A",
        ["etkss|Ss4x 250 (A)"] = "ss4x_250_A",
        ["etkss|Ss4x 230d (A)"] = "ss4x_230d_A",
        ["etkss|Ss6 300 (A)"] = "ss6_300_A",
        ["etkss|Ss6 260d (A)"] = "ss6_260d_A",
        ["etkss|Ss4 Proto (A)"] = "ss4_proto_A",
        ["etkss|Ss4 250 (A)"] = "ss4_250_A",
        ["etkss|Ss4 Taxi (A)"] = "ss4_taxi_A",
        ["etkss|Ss4 230d (A)"] = "ss4_230d_A",
        -- ETK 1300-Series (etk1300 模组)
        ["etk1300|1356ttx 340 (A)"] = "1356x_340_A",
        ["etk1300|1356ttx 360 (A)"] = "1356x_360_A",
        ["etk1300|1356ttx 380d (A)"] = "1356x_380d_A",
        ["etk1300|1358ttx 450 (A)"] = "1358x_450_A",
        ["etk1300|1356x ttSport (DCT)"] = "1356x_ttsport_DCT",
        ["etk1300|1358x ttSport+ (DCT)"] = "1358x_ttsport_plus_DCT",
        ["etk1300|Rennspecht 13R (A)"] = "rennspecht_13r_A",
        ["etk1300|1358x ttSport+ Heritage Edition (DCT)"] = "1358x_ttsport_heritage_DCT",
        ["etk1300|1358x 490 Exclusive (A)"] = "1358x_490_exclusive_A",
        ["etk1300|1356 The Perfecter (M)"] = "1356_derby_M",
        ["etk1300|1354 190d (A)"] = "1354_190d_A",
        ["etk1300|1345 190 (A)"] = "1354_190_A",
        ["etk1300|1354x 190 (A)"] = "1354x_190_A",
        ["etk1300|1354x 250 (A)"] = "1354x_250_A",
        ["etk1300|1354x 230d (A)"] = "1354x_230d_A",
        ["etk1300|1354x 260d (A)"] = "1354x_190d_A",
        ["etk1300|1356x Taxi (A)"] = "1356x_300_A_taxi",
        ["etk1300|1356xc 260d (A)"] = "1356xc_260d_A",
        ["etk1300|1354x Off-Road (M)"] = "1356_offroad",
        -- Mistral (kajzercolt)
        ["kajzercolt|1.5 TSR ROBOT (M)"] = "facelift_tsr_robot",
        ["kajzercolt|Runner (M)"] = "runner",
        ["kajzercolt|Sleeper (M)"] = "sleeper",
        ["kajzercolt|Track V6 (M)"] = "race_v6",
        ["kajzercolt|Track I4 (SQ)"] = "race_i4",
        ["kajzercolt|S1600 Kit Car - Gravel (SQ)"] = "rally_gravel",
        ["kajzercolt|S1600 Kit Car - Asphalt (SQ)"] = "rally_asphalt",
        ["kajzercolt|1.6 GXL V6 (M)"] = "facelift_gxl_v6",
        ["kajzercolt|1.6 GXL V6 (A)"] = "facelift_gxl_v6_A",
        ["kajzercolt|1.5 SX Turbo (M)"] = "facelift_sx_turbo",
        ["kajzercolt|1.5 TSR (M)"] = "facelift_tsr",
        ["kajzercolt|Amateur Rally - Gravel (M)"] = "rally_amateur",
        ["kajzercolt|1.3 GX (M)"] = "facelift_poverty",
        ["kajzercolt|1.5 GXL (M)"] = "facelift_gxl",
        ["kajzercolt|1.3 Base (M)"] = "facelift_fx",
        -- D-Series (pickup)
        ["pickup|D15 Track"] = "d15_track_awd_M",
        ["pickup|D15 Pre-Runner (A)"] = "deserttruck_prerunner_short_A",
        ["pickup|D15 Pre-Runner  Extended Cab (A)"] = "d15_ext_4wd_A",
        ["pickup|D35 'SuperPig' (A)"] = "deserttruck_crawler_A",
        ["pickup|D15 V8 RoadSport (M)"] = "d15_roadsport_awd_M",
        ["pickup|D10 Zeta (A)"] = "d10_4wd_zeta_A",
        ["pickup|D15 Off-Road (M)"] = "d15_4wd_offroad_M",
        ["pickup|D15 423 Sport (A)"] = "d15_423sport_A",
        ["pickup|D10 Charro 423 Sport (A)"] = "d10_423sport_A",
        ["pickup|D35 'Pig' (M)"] = "d35_4wd_pig_M",
        ["pickup|D45 Ambulance (A)"] = "d45_ambulance_A",
        ["pickup|D15 Crawler Crew Cab (A)"] = "deserttruck_crew_crawler_A",
        ["pickup|D15 Fleet (M)"] = "d15_fleet_M_facelift",
        ["pickup|D16 Fleet Extended Cab (M)"] = "d15_fleet_ext_M",
        ["pickup|D15 Fleet Long Bed (M)"] = "d15_fleet_longbed_M",
        ["pickup|D15 Fleet Extended Cab (M)"] = "d15_fleet_ext_M_facelift",
        ["pickup|D15 Farmhand (M)"] = "d15_farmhand_M",
        ["pickup|D15 V8 (M)"] = "d15_M",
        ["pickup|D15 V8 Extended Cab (M)"] = "d15_ext_M",
        ["pickup|D15 V8 Extended Cab (A)"] = "d15_ext_A_facelift",
        ["pickup|D15 V8 Extended Cab Long Bed (M)"] = "d15_ext_longbed_M",
        ["pickup|D10 Charro V8 4WD (M)"] = "d10_4wd_A",
        ["pickup|P10 Park Ranger (M)"] = "d10_4wd_parkranger",
        ["pickup|Kentarch D30 V8 4WD (A)"] = "d30_ext_4wd_kentarch_A",
        -- Hirochi Ute (hute)
        ["hute|Hirochi 120 Speed (M)"] = "speed",
        ["hute|Hirochi RUSH Track (M)"] = "race_M",
        ["hute|Hirochi 120 Street Tuned (M)"] = "street_M",
        ["hute|Hirochi Rally (M)"] = "rally_M",
        ["hute|Hirochi RUSH Offroad (M)"] = "offroad",
        ["hute|Hirochi RUSH California Dream (M)"] = "rush_dream_M",
        ["hute|Hirochi RUSH XL Turbo HTI (M)"] = "rush_xl_turbo_hti_M",
        ["hute|Hirochi 120 GR (M)"] = "120_gr_M",
        ["hute|Hirochi RUSH ZSR Aero (M)"] = "rush_zsr_M",
        ["hute|Hirochi RUSH 'My Name Is Jeff' (M)"] = "rush_walt_M",
        -- Aurata (utv)
        ["utv|Custom - Asphalt (CVT)"] = "custom",
        ["utv|Race (CVT)"] = "race",
        ["utv|Wild (CVT)"] = "wild",
        ["utv|Junior (CVT)"] = "junior",
        ["utv|Sport Turbo (CVT)"] = "turbo",
        ["utv|Sport (CVT)"] = "plus",
        ["utv|Sheriff"] = "Sheriff",
        ["utv|Base (CVT)"] = "base",
        -- H-Series (van)
        ["van|H45 Cabster Chassie Cab (A)"] = "h45_chassiscab",
        ["van|H35 XT Passenger (A)"] = "h35_passenger_xt",
        ["van|H35 Vanster (A)"] = "h35_vanster",
        ["van|H15 Vanster Off-Road (M)"] = "offroad",
        ["van|Street Tuned"] = "street_tuned",
        ["van|H15 Vanster (A)"] = "h15_vanster",
        ["van|H15 Vanster Long Wheelbase (A)"] = "h15_ext_vanster",
        ["van|H15 Base Passenger (A)"] = "h15_passenger_i6",
        ["van|H15 Passenger (A)"] = "h15_passenger",
        ["van|H15 XT Passenger (A)"] = "h15_xt_passenger",
        ["van|H15 Police Transport Van (A)"] = "police_passenger",
        ["van|H25 Vanster (A)"] = "h25_vanster",
        ["van|H25 Passenger (A)"] = "h25_passenger",
        ["van|H25 4WD XT Passenger (A)"] = "h25_passenger_4wd_xt",
        ["van|H25 Belasco Police (A)"] = "police_passenger",
        ["van|H35 4WD XT Passenger (A)"] = "h35_passenger_4wd_xt",
        ["van|H45 Ambulance (A)"] = "ambulance",
        ["van|H45 Cabster Cargo Box Upfit (A)"] = "deliverytruck",
        ["van|H35 Vandel (M)"] = "h35_vanster",
        -- autobello (原 piccolina)
        ["autobello|150 Corse Track (M)"] = "150_track",
        ["autobello|Baja Unlimited Class 5 (Sequential)"] = "autobuggy_baja_unlimited",
        ["autobello|Baja Extreme (Sequential)"] = "autobuggy_baja_extreme",
        ["autobello|150 Corse"] = "150",
        ["autobello|150 Corse Rally - Gravel(M)"] = "150_rally",
        ["autobello|Baja (M)"] = "baja",
        ["autobello|Baja Spec Class 5 (M)"] = "autobuggy_baja_spec",
        -- scout (euvan)
        ["euvan|Cargo 330dX S35 (M)"] = "cargo_300dX_s35_AWD_M",
        ["euvan|Cargo 350RS (DCT)"] = "cargo_350RS_A",
        ["euvan|Cargo 350RS (M) (UKDM)"] = "cargo_350RS_M_rhd_thw",
        ["euvan|Tracer 330dX S25 AWD (M)"] = "tracer_330dX_s25_AWD_M",
        ["euvan|Multiway 300d S25 (M)"] = "multiway_300d_s25_M",
        ["euvan|Multiway Polizia (M)"] = "multiway_300d_polizia_M",
        ["euvan|Cargo 250d S10 Fleet (M)"] = "cargo_250d_s10_fleet_M",
        ["euvan|Cargo 250d S15 (M) (UKDM)"] = "cargo_250d_s15_M_rhd_thw",
        ["euvan|Cargo 250d S15 (A)"] = "cargo_250d_s15_A",
        ["euvan|Cargo Delivery (M)"] = "cargo_250d_delivery_M",
        ["euvan|Cargo Work Package (M)"] = "cargo_300d_workpackage_M",
        ["euvan|Cargo 220i S25 (M)"] = "cargo_220i_s25_M",
        ["euvan|Multiway 250d S15 (M)"] = "multiway_250d_s15_M",
        -- TPUSuperlite
        ["TPUSuperlite|1.8 GT RHD (M)"] = "150R_RHD",
        ["TPUSuperlite|1.6 GT LHD (M)"] = "150S_LHD",
        ["TPUSuperlite|125S LHD (M)"] = "Superlite1300SE",
        ["TPUSuperlite|Superlite 1500 (M)"] = "150S_LHD",
        ["TPUSuperlite|1.8 Sport RHD (M)"] = "150S_RHD",
        ["TPUSuperlite|150S LHD (M)"] = "150S_LHD",
        ["TPUSuperlite|1900 Twincam LHD (M)"] = "200S_LHD",
        ["TPUSuperlite|200S LHD (M)"] = "200S_LHD",
        ["TPUSuperlite|1900 Twincam Race (M)"] = "200_Race",
        ["TPUSuperlite|150 Cup (M)"] = "150_Race",
        ["TPUSuperlite|300S PHD (M)"] = "300S_LHD",
        ["TPUSuperlite|Street Tuned (M)"] = "StreetTuned",
        ["TPUSuperlite|Hillclimb (Sequential)"] = "Hillclimb",
        ["TPUSuperlite|300R RHD (Sequential)"] = "300R_RHD",
        ["TPUSuperlite|2.0R Race (M)"] = "200_Race",
        ["TPUSuperlite|Rally (Sequential)"] = "Rally",
        ["TPUSuperlite|200RR (Sequential)"] = "200RR",
        ["TPUSuperlite|Off-road (M)"] = "Off-road",
        ["TPUSuperlite|1600 GT LHD (M)"] = "150S_LHD",
        ["TPUSuperlite|80S (M)"] = "100S",
        ["TPUSuperlite|1.5 GT RHD (M)"] = "150R_RHD",
        ["TPUSuperlite|Superlite 600 (M)"] = "100R",
        -- etkk
        ["etkk|Kc6x 360 (A)"] = "kc6_a",
        ["etkk|Kc4 250 (M)"] = "kc4",
        ["etkk|Kc4 250 (A)"] = "kc4_a",
        ["etkk|Kc6x 310d (A)"] = "kc6_a",
        ["etkk|Kc6 360 (M)"] = "kc6",
        ["etkk|Kc6 360 (A)"] = "kc6_a",
        ["etkk|Kc4 250 Police (A)"] = "polizei",
        ["etkk|Kc4 Street Tuned (M)"] = "streettuned",
        ["etkk|Kc8 ttSport (DCT)"] = "kr6t",
        ["etkk|Rennspecht KR (A)"] = "kr6_a",
        ["etkk|Kc6x 310d Driving Experience (M)"] = "kc6",
        ["etkk|Kc6x Trackday (A)"] = "race",
        ["etkk|Kc8x ttSport+ (DCT)"] = "kr6t",
        ["etkk|Kc6x 360 Police Interceptor"] = "polizei",
        ["etkk|Kc6x 340 Autobahn Polizei (A)"] = "polizei",
        ["etkk|Kc8 ttSport Heritage Edition (M)"] = "kr6t",
        ["etkk|Kr4s Touring (M)"] = "kr4s",
        ["etkk|Kr6 (M)"] = "kr6",
        ["etkk|Beater (A)"] = "beater",
        ["etkk|Kc4 (A)"] = "kc4_a",
        ["etkk|Kr4 (M)"] = "kr4",
        ["etkk|Kr4 (A)"] = "kr4_a",
        ["etkk|GT-IV (DCT)"] = "race",
        -- K-Series(1994) trims
        ["etkk|Kr6t TTSport (M)"] = "kr6t",
        ["etkk|Kr6t TTSport (A)"] = "kr6_a",
        ["etkk|Kc6t TTSport Evolution (M)"] = "kc6t_evo",
        ["etkk|Off-Road (M)"] = "offroad",
        ["etkk|Race (M)"] = "race",
        ["etkk|Street Tuned (M)"] = "streettuned",
        -- Pessima Zenith(1984) (zenith 模组)
        ["zenith|1300 Rally (Sequential)"] = "rally_seq",
        ["zenith|1700 ETCC #58 GripAll (Sequential)"] = "touring2_seq",
        ["zenith|1800 Touring-Li-TURBO (M)"] = "touring_li_turbo_M",
        ["zenith|2000 Luminaire-Vi-TURBO 50th Anniversary Coupe (M)"] = "luminaire_viturbo_coupe_50th_A",
        ["zenith|1800 Touring-Li-TURBO Coupe (A)"] = "touring_li_turbo_coupe_A",
        ["zenith|1800 GL Diesel (M)"] = "gl_diesel_M",
        ["zenith|2000 Comfort Cab LX (A)"] = "lx_sedan_taxi_A",
        -- Pessima Zenith(1994) (zenith2 模组)
        ["zenith2|JTCC (Sequential)"] = "jtccbase",
        ["zenith2|1800 Touring (M)"] = "1800_touring_M",
        ["zenith2|1800 Touring (A)"] = "1800_touring_A",
        ["zenith2|1800 Touring V6 (M)"] = "1800_touring_v6_M",
        ["zenith2|1800 Touring V6 (A)"] = "1800_touring_v6_A",
        ["zenith2|2000 Touring (A)"] = "2000_touring_A",
        ["zenith2|2000 Touring (M)"] = "2000_touring_M",
        ["zenith2|2000 Touring-4 Fultrac (M)"] = "2000_touring4_M",
        ["zenith2|2000 Touring-4 Fultrac (A)"] = "2000_touring4_A",
        ["zenith2|2000 Touring-4 Fultrac Black Series (M)"] = "2000_touring4_black_A",
        ["zenith2|2000 Touring-R SR-TEC/VD Fultrac (M)"] = "2000_touringR_M",
        ["zenith2|2000 Touring-R Miami (A)"] = "2000_touringR_miami_A",
        ["zenith2|2000 Touring-R Rennspecht (A)"] = "rennspecht_A",
        ["etkk|Beater (A)"] = "beater",
        ["etkk|Kc4 (A)"] = "kc4_a",
        ["etkk|Kr4 (M)"] = "kr4",
        ["etkk|Kr4 (A)"] = "kr4_a",
        -- newsuper (mondello)
        ["newsuper|Strada (M)"] = "base_M",
        ["newsuper|Aperta (A)"] = "aperta_A",
        ["newsuper|Polizia (A)"] = "polizia",
        ["newsuper|Corse (A)"] = "corse_A",
        ["newsuper|45th Anniversary Edition (M)"] = "anniversary",
        ["newsuper|Widebody (M)"] = "turbo_rabbit",
        ["newsuper|Movitec SuperTurbo (SEQ)"] = "movitecsuper",
        ["newsuper|Civetta GT Cup Stradale (SEQ)"] = "cgtc_stradale",
        ["newsuper|Civetta GT Cup No.78 (SEQ)"] = "cgtc_no78",
        -- picnic
        ["picnic|2.0 Kit Car - Gravel (Sequential)"] = "2.0_kitcar_gravel_seq",
        ["picnic|2.0 Kit Car - Asphalt (Sequential)"] = "2.0_kitcar_seq",
        ["picnic|2.0 Race (Sequential)"] = "2.0_race_seq",
        ["picnic|2.0 Trackday (M)"] = "2.0_trackday_m",
        ["picnic|1.6 Group N - Gravel (Sequential)"] = "1.6_rally_gravel_seq",
        ["picnic|1.6 Group N - Asphalt (Sequential)"] = "1.6_rally_seq",
        ["picnic|1.6 Gti Turbo (M)"] = "1.6_gti_turbo_m",
        ["picnic|2.0 Git Rallye (M)"] = "2.0_rallye",
        ["picnic|1.6 Gti (M)"] = "1.6_gti_m",
        ["picnic|1.6 Dune (M)"] = "1.6_dune_m",
        ["picnic|1.6 Gendarmerie (M)"] = "1.6_gendarmerie_m",
        ["picnic|1.3 Dune (A)"] = "1.3_dune_a",
        ["picnic|1.1 Foxtrot (M)"] = "1.1_foxtrot_m",
        -- signia
        ["signia|GT-Z Runner (M)"] = "gtz2000r_late",
        ["signia|240BX L (1974-1975 - M)"] = "240bx_l_late",
        ["signia|Heritage Race (M)"] = "heritage_race",
        ["signia|240BX GT (1974-1975 - M)"] = "240bx_gt_late",
        ["signia|GT 2000 Patorl (1974-1975 - M)"] = "gt2000_late",
        ["signia|240BX SR (1975-1977 - M)"] = "240bx_sr_late",
        ["signia|GT-Z 2000R (1974-1975 - M)"] = "gtz2000r_late",
        ["signia|160BX SE (1973-1974 - M)"] = "160bx_se_early",
        ["signia|LX 2000 Brilliance (1974-1975 - A)"] = "lx2000_brilliance_late_A",
    }
    local pc = map[key]
    -- Pessima 年份特殊处理：1996 用 liftback 配置，1988 用原版
    if pc and trim and trim:find("1996") and jbeam == "pessima" then
        local liftMap = {
            ["LX_M"] = "lx_lift_M",
            ["GTz"] = "gtz_lift",
            ["race"] = "race",
            ["rally"] = "rally",
            ["hillclimb"] = "hillclimb",
        }
        return liftMap[pc] or pc
    end
    return pc
end


-- ============== 黑手: JBeam Map ==============

local JBEAM_MAP = {
    Autobello_Piccolina = "autobello", ["Autobello Stambecco"] = "midtruck",
    Blackpool_Superlite = "TPUSuperlite", ["Bruckell Bastion"] = "bastion",
    ["Bruckell LeGran"] = "legran", ["Bruckell Moonhawk"] = "moonhawk",
    ["Bruckell Nine"] = "nine", ["Bruckell Special"] = "burnside",
    ["Cherrier FCV"] = "vivace", ["Cherrier Picnic"] = "picnic",
    ["Civetta Bolide"] = "bolide", ["ETK 800-Series"] = "etk800",
    ["ETK I-Series"] = "etki", ["ETK K-Series(1994)"] = "etkk",
    ["ETK K-Series(2015)"] = "etkk", ["ETK S-Series"] = "etkss",
    ["ETK 1300-Series"] = "etk1300", ["Ford Crown Victoria"] = "fullsize",
    ["Gavril Barstow(1969)"] = "barstow", ["Gavril Barstow(1998)"] = "barstow",
    ["Gavril Bluebuck"] = "bluebuck", ["Gavril D-Serise"] = "pickup",
    ["Gavril Grand Marshal"] = "fullsize", ["Gavril H-Series"] = "van",
    ["Gavril Roamer"] = "roamer", ["Gavril Scout"] = "euvan",
    ["Hirochi Aurata"] = "utv", ["Hirochi SBR4"] = "sbr",
    ["Hirochi Sunburst"] = "sunburst2", ["Hirochi Mistral"] = "kajzercolt",
    ["Hirochi Ute"] = "hute", ["Ibishu BX-Series"] = "bx",
    ["Ibishu Covet"] = "covet", ["Ibishu Hopper"] = "hopper",
    ["Ibishu Miramar"] = "miramar", ["Ibishu Pessima Zenith(1984)"] = "zenith",
    ["Ibishu Pessima Zenith(1994)"] = "zenith2", ["Ibishu Pessima(1996)"] = "midsize",
    ["Ibishu Pessima(1998)"] = "midsize", ["Ibishu Pessima(1988)"] = "pessima",
    ["Ibishu Pessima (EUDM)"] = "pessima", ["Ibishu Pigeon"] = "pigeon",
    ["Ibishu Wigeon"] = "wigeon", ["Ibishu Signia"] = "signia",
    ["Soliad Lansdale"] = "lansdale", ["Soliad Wendover"] = "wendover",
    ["SP Dunekicker"] = "rockbouncer", ["SP Rockbasher"] = "rockbouncer",
    ["Senta 325"] = "ferax",
}

-- ============== 黑手: Car Pools (from B15 CarSelector) ==============

-- 高速组 (对应 Python 的 carlist + mainprogram)
local CARS_HIGH = {
    ["TPUSuperlite"] = {"125R_LHD", "125R_RHD", "125S_LHD", "125S_RHD", "125_Race", "150R_LHD", "150R_RHD", "150S_LHD", "150S_RHD", "150_Race", "1600GT_Late_LHD", "1600GT_Late_RHD", "1600Twincam_LHD", "1600Twincam_RHD", "1600Twincam_Race", "1900Twincam_LHD", "1900Twincam_RHD", "1900Twincam_Race", "200RR", "200R_LHD", "200R_RHD", "200S_LHD", "200S_RHD", "200_Race", "20GT_LHD", "20GT_RHD", "20R", "20R_Race", "20Track_LHD", "20Track_RHD", "300R_LHD", "300R_RHD", "300S_LHD", "300S_RHD", "Drift", "HP6", "Hillclimb", "Moto", "Off-road", "Rally", "StreetTuned", "Superlite1500", "Superlite2000", "Superlite600SE", "V8"},
    ["autobello"] = {"Drag", "autobuggy_baja_extreme", "autobuggy_baja_unlimited", "ecxy", "street"},
    ["barstow"] = {"custom", "drag", "drift", "kingsnake", "tracksport"},
    ["bastion"] = {"battlehawk_A", "battlehawk_M", "battlehawk_intrcptr_pbfmv", "bcpd2_v8_awd_pbfmv", "bcpdghost_pbfmv", "bngpolice_v8_awd_pbfmv", "bngsp_v8_awd_pbfmv", "drag", "drift", "hotlap", "luxe_v8_A", "luxe_v8_awd_A", "offroad", "police_unmarked_v8_awd_A", "police_v8_awd_A", "policetaxi_v8_awd_pbfmv", "redtail_A", "sheriff_v8_awd_pbfmv", "sport_A", "sport_M", "sport_gt_A", "sport_gt_M", "street_tuned", "swat_v8_awd_pbfmv"},
    ["bluebuck"] = {"215a_2door_turbo", "250m_2door_rs", "350a_4door_diesel", "350m_4door_diesel", "423m_detective_pbfmv", "423m_roadsport", "buckshot_rs", "custom", "dark_stag", "drag", "drift", "gasser", "intcptor2_pbfmv", "interceptor", "resourceful", "soot_sled", "track"},
    ["bolide"] = {"320gtt", "320gtt_targa", "320gtt_targa_us", "320gtt_us", "350", "350_targa", "350_targa_us", "350_us", "390gt", "390gt_strada", "390gt_targa", "390gt_targa_us", "390gt_us", "bspd", "carabinieri", "clubracer", "notte", "police cheetah", "police cheetah blue", "polizia", "race", "rally_asphalt", "rally_gravel", "scpd", "topspeed", "usaap"},
    ["burnside"] = {"custom", "drag", "gasser_late", "powerglow", "ratrod"},
    ["bx"] = {"240bx_hatch_lxz_srtecnica_M", "240bx_hatch_lxz_srtecnica_prefl_M", "240bx_hatch_rallycourse_prefl", "alexia_diesel_missile_vip", "alexia_drag_vip", "alexia_mako", "alexia_prodrift_vip", "alexia_v8_sc_vip", "bx_runner_vip", "diana_gtz_rz_A", "diana_gtz_rz_M", "diana_gtz_rz_prefl_A", "diana_gtz_rz_prefl_M", "diana_gtz_rz_vert_A", "diana_gtz_rz_vert_prefl_A", "diana_gtz_tec2_vert_M", "diana_gtz_tec_vert_M", "diana_type_ls_srtec_black_M", "diana_type_ls_srtec_black_prefl_M", "diana_type_ls_srtecnica_M", "diana_type_ls_srtecnica_prefl_M", "diana_z270_M", "diana_z270_prefl_M", "drag_A", "huntsman_custom", "huntsman_rally", "huntsman_sleigh", "powerglow", "pro_drift_M", "pro_drift_ute_lj_M", "runner_M", "street_drift_M", "street_tuned_M", "street_tuned_M_early", "track_M", "冒险者·警·羊·池谷", "冒险者·警·羊·深深武士", "冒险者·警·羊·澳警", "冒险者·警·羊·车手"},
    ["ccf"] = {"country_arctic_M", "country_arctic_M_rhd", "e_sport", "e_sport_rhd", "f4_base_miataowner", "f4_hti_M", "f4_rc", "f4_rc_lhd", "f4_sport_A", "f4_sport_DCT_BCPD", "f4_sport_DCT_cumbria", "f4_sport_M", "f4_sport_M_colourspecial", "f4_sport_M_colourspecial_rhd", "f4_sport_M_rhd", "f4_sport_turbo", "f6_5ae_M", "f6_base_A", "f6_base_M", "f6_base_M_camo", "f6_base_M_rhd", "f6_hti_M", "f6_offroadster_M", "f6_sport_A", "f6_sport_M", "f6_sport_M_rhd", "f6_tuned_M", "flesh", "v8"},
    ["covet"] = {"1.5_awd_dxi_vip", "1.5_lemons_vip", "1.5_offroad_vip", "2.0_drag_awd_vip", "2.0_homologation_vip", "2.0_ibishurally_vip", "2.0_ibishurallyt_vip", "2.0_stance_vip", "2.0_street_awd_vip", "2.0_street_vip", "2.0_track_vip", "custom", "drag", "mr_M", "mrv6", "race", "rally_asphalt", "rally_gravel", "runner", "turbo", "turbo_evolution", "turbo_race", "turbo_rally"},
    ["crownvic"] = {"35_V6", "60_Diesel_V8_Dually", "Drag", "Drift"},
    ["etk1300"] = {"1356_derby_M", "1356x_310d_A", "1356x_340_A", "1356x_360_A", "1356x_380d_A", "1356x_driving_experience_A", "1356x_ttsport_DCT", "1358x_450_A", "1358x_490_exclusive_A", "1358x_ttsport_heritage_DCT", "1358x_ttsport_plus_DCT", "rennspecht_13r_A"},
    ["etk800"] = {"844_250_A", "844_250_M", "844_bcpd_pbfmv", "844_police2_pbfmv", "844_police_A", "844_track_M", "846_310d_A", "846_340_A", "846_340_M", "846_ttSport_custom_DCT", "846_ttsport_heritage_M", "846_unmarked_pbfmv", "846x_driving_experience_A", "846x_ttsport_plus_DCT", "854_police_A", "854_police_A_alt", "854x_250_A", "856_police_xc_pbfmv", "856_sheriff_xc_pbfmv", "856_ttsport_DCT", "856x_310d_A", "856x_340_A", "856xc_260d_A", "856xc_300_A", "858_drift_M", "rennspecht_8r_A"},
    ["etkc"] = {"kc4_250_A", "kc4_250_M", "kc4_street_tuned_M", "kc4x_250_police_pbfmv", "kc6_360_A", "kc6_360_M", "kc6x_310d_A", "kc6x_310d_driving_experience_M", "kc6x_340_police_highway_A", "kc6x_360_A", "kc6x_360_M", "kc6x_360_intrcptr_pbfmv", "kc6x_360_unmarked_pbfmv", "kc6x_trackday_A", "kc8_drift_M", "kc8_ttsport_DCT", "kc8_ttsport_heritage_M", "kc8x_ttsport_plus_DCT", "onlinenew", "race_DCT", "rennspecht_kr_A"},
    ["etki"] = {"2400ti_sport_evo_M", "2400tix_sport_evo_M", "cool", "custom", "drift", "ger", "nbpd", "nbsd", "polizia", "race", "rally", "riksenergi", "shpd", "冒险者·警·羊·老爷警"},
    ["etkk"] = {"kc6t", "kc6t_evo", "kr6t", "offroad", "race", "streettuned"},
    ["etkss"] = {"rennspecht_sr_A", "sl12x_580_exclusive_A", "sl12x_600_A", "sl4x_250_A", "sl6x_260d_A", "sl6x_300_A", "sl6x_310d_A", "sl6x_340_A", "sl6x_380d_A", "sl6x_driving_experience_A", "sl8x_450_A", "ss12_ttsportgt_DCT", "ss12x_600_A", "ss12x_track_SQ", "ss12x_ttsportgtr_DCT", "ss4_250_A", "ss4_proto_A", "ss4x_250_A", "ss6_260d_A", "ss6_300_A", "ss6x_260d_A", "ss6x_300_A", "ss6x_310d_A", "ss6x_340_A", "ss6x_360_dynamic_A", "ss6x_380d_A", "ss6x_bcpd_A", "ss6x_firwood_A", "ss8_ttsport_DCT", "ss8x_450_A", "ss8x_ttsport_plus_DCT", "ss8x_ttsportgts_heritage_DCT"},
    ["ferax"] = {"Exion 1.7D 4x4"},
    ["fr04"] = {"F3_25CSS", "F3_25campus", "F3_25dead bull", "F3_25lotech", "F3_25rat", "F3_25torment", "F3_AXE", "F3_BAM", "F3_NBMotor", "F3_Pema", "F3_Vanta", "F3_mclamb", "F3_rokit", "F4_25CSS", "F4_25campus", "F4_25dead bull", "F4_25lotech", "F4_25rat", "F4_25torment", "F4_AXE", "F4_BAM", "F4_NBMotor", "F4_Pema", "F4_Vanta", "F4_mclamb", "F4_rokit", "FR_25CSS", "FR_25campus", "FR_25dead bull", "FR_25lotech", "FR_25rat", "FR_25torment", "FR_AXE", "FR_BAM", "FR_NBMotor", "FR_Pema", "FR_Vanta", "FR_mclamb", "FR_rokit", "GB3_25CSS", "GB3_25campus", "GB3_25dead bull", "GB3_25lotech", "GB3_25rat", "GB3_25torment", "GB3_AXE", "GB3_BAM", "GB3_NBMotor", "GB3_Pema", "GB3_Vanta", "GB3_mclamb", "GB3_rokit", "campus_aggressive", "campus_baseline", "campus_highdf", "campus_lowdf", "cpr_aggressive", "cpr_baseline", "cpr_highdf", "cpr_lowdf", "css_aggressive", "css_baseline", "css_highdf", "css_lowdf", "deadbull_aggressive", "deadbull_baseline", "deadbull_highdf", "deadbull_lowdf", "karlen_aggressive", "karlen_baseline", "karlen_highdf", "karlen_lowdf", "lotech_aggressive", "lotech_baseline", "lotech_highdf", "lotech_lowdf", "okudai_aggressive", "okudai_baseline", "okudai_highdf", "okudai_lowdf", "parma_aggressive", "parma_baseline", "parma_highdf", "parma_lowdf", "pu_aggressive", "pu_baseline", "pu_highdf", "pu_lowdf", "torment_aggressive", "torment_baseline", "torment_highdf", "torment_lowdf", "unpainted_aggressive", "unpainted_baseline", "unpainted_highdf", "unpainted_lowdf"},
    ["fullsize"] = {"Gavril Police Department (Interceptor)", "custom2", "drag", "drift", "onlinenew", "onlinenew-limopresident", "po1", "roadsport", "track"},
    ["gavril_vertex"] = {"belasco_lightning", "boomboom", "custom_sedan", "deo_volente_spec", "dorifto", "dorifto_pro", "drag", "drag_v12", "electricdrag", "extreme_timeattack", "failrace", "fire_chief", "fission", "fission_thunderbolt", "focusdreambuild", "furry", "fwd_drag", "gcg_edition", "general_yeet", "hillclimb", "hohoho_its_christmas_time", "innocentcustoms", "innocentcustoms_v600", "lotus", "murica", "muscle_v12", "neilogical", "offroader", "okudai", "powerdemonrwd", "powerglow", "powerglow_alt", "powolice_interceptor", "powolice_interceptor_alt", "racing", "racing_awd", "racing_electric", "rally", "rally_i5", "rally_tarmac", "rally_tarmac_i5", "rammer_jato", "rammer_jato_godmode", "roadsport", "roadsport_auto", "safetycar", "shadosfr", "shinyodd_edition", "sleeper", "speirs_drag", "street_tuned_awd", "street_tuned_fwd", "sus", "taxi_taxi_carrier", "thw_special", "top_speed_record", "tracksport", "ts_concept", "tunism", "vanilla", "vertexairways", "vertexsport", "withstiggy"},
    ["hopper"] = {"crawler", "drag", "rock_racer"},
    ["hute"] = {"drag_A", "drift_M", "race_M", "rally_M", "rascal_asr_M", "rush_xl_turbo_hti_M", "speed", "street_M", "tune"},
    ["kajzercolt"] = {"base_tsr", "facelift_gxl_v6_A", "facelift_monarch", "facelift_tsr", "facelift_tsr_robot", "race_i4", "race_v6", "rally_asphalt", "rally_gravel", "runner", "sleeper"},
    ["lansdale"] = {"25_rally_M", "25_tuner_M", "38_race_late_M", "38_tuner_late_M", "44_drag_late_M", "44_tuner_special_AWD_SC_M"},
    ["legran"] = {"custom", "race"},
    ["midsize"] = {"custom", "drag", "race", "rally", "冒险者·匪·羊·润人", "冒险者·匪·羊·路人甲"},
    ["miramar"] = {"custom", "miramighty", "race", "safari_rally"},
    ["moonhawk"] = {"drag", "drift", "drive", "powerglow", "race"},
    ["muscle"] = {"drag", "drift", "policeinterceptor", "race", "roadsport", "roadsport_convertible", "streettuned", "tracksport"},
    ["newsuper"] = {"anniversary", "anniversary_aperta", "aperta_A", "aperta_M", "base_A", "base_M", "cgtc_no50", "cgtc_no78", "cgtc_stradale", "corse_A", "corse_M", "corse_cup", "movitec", "movitecsuper", "polizia", "ta", "trackday", "turbo_rabbit"},
    ["nine"] = {"MZKZ_91-244", "MZKZ_91-244_taxi", "MZKZ_91-246", "MZKZ_91-246S", "MZKZ_91-246SC", "MZKZ_91-248_raven", "MZKZ_91-446", "MZKZ_91-446P", "MZKZ_Strelka", "classic_hotrod", "nine_dragvan", "nine_gasser", "nine_hotbeams", "nine_hotrod_60s", "nine_hotrod_vintage", "nine_restomod", "nine_restomod_coupe", "nine_tasti_hotrod", "powerglow", "rust_bucket", "stockcar", "winter_express"},
    ["pessima"] = {"EXiv6", "EXiv6_coupe", "EXiv6_pre", "EXiv6_pre_coupe", "EXv6", "EXv6_coupe", "EXv6_pre", "EXv6_pre_coupe", "GTz", "GTz_coupe", "GTz_coupe_rallycourse", "GTz_pre", "GTz_pre_coupe", "GTz_rallycourse_kljpwagon", "LX_pre_A", "LX_pre_M", "ZX_4ws_pre_M", "ZX_4ws_pre_coupe_M", "ZX_pre_M", "ZX_pre_coupe_M", "bhp", "brio", "bsd", "bsp", "carabinieri", "custom", "custom2", "custom_kljpwagon", "drift", "drift_kljpwagon", "fpd", "gendarmerie", "hillclimb", "hkp", "kuesowagon", "lspd", "nbcsd", "nbpd", "nbsp", "nnbsp", "personal", "polizia", "race", "rally", "rally_kljpwagon", "rz_coupe_pre", "rz_pre", "rz_turbo_coupe", "rz_turbo_pre_coupe"},
    ["pickup"] = {"d15_longbed_drag_A", "d15_streettuned_M", "d15_track_awd_M", "d25_longbed_dragDiesel_A", "deserttruck_prerunner_A", "deserttruck_prerunner_short_A"},
    ["picnic"] = {"1.6_gti_turbo_a", "1.6_gti_turbo_m", "2.0_kitcar_gravel_seq", "2.0_kitcar_seq", "2.0_race_seq", "2.0_rallye", "2.0_trackday_m"},
    ["pigeon"] = {"drag"},
    ["roamer"] = {"drag", "street_tuned"},
    ["sbr"] = {"GTs6_DCT", "GTs6_M", "GTs6r_DCT", "S_AWD_DCT", "S_AWD_M", "S_AWD_fl_DCT", "S_AWD_fl_M", "S_RWD_DCT", "S_RWD_M", "S_state_trooper_pbfmv", "TTS_intrcptr_pbfmv", "TT_AWD_S2_DCT", "TT_AWD_S2_M", "TT_AWD_S_DCT", "TT_AWD_S_M", "TT_AWD_fl_S2_DCT", "TT_AWD_fl_S2_M", "TT_AWD_fl_S_DCT", "TT_AWD_fl_S_M", "TT_AWD_fl_S_hybrid_DCT", "TT_RWD_S_DCT", "TT_RWD_S_M", "custom", "drift", "electric_300", "electric_500", "electric_800", "esbr500_state_trooper_pbfmv", "esbr800_intrcptr_pbfmv", "hillclimb", "hillclimb_SQ", "powerglow", "rally_am_asphalt", "rally_am_gravel", "track"},
    ["scintilla"] = {"SCPD", "custom", "dark_owl", "drag", "gt", "gt3_balanced", "gt3_endurance", "gt_spider", "gts", "gts_corse", "gts_corse_spider", "gts_polizia", "gts_spider", "gts_topspeed", "gtx", "gtx_intrcptr_pbfmv", "gtx_spider", "offroad", "race", "rally"},
    ["signia"] = {"drag", "drift", "pace", "race", "tuner"},
    ["sunburst2"] = {"The Tech-Verify Vehicle", "drift_pro", "firwood_police_RS", "fwpdSPU", "gendarmerie", "interceptor", "interceptor2_pbfmv", "itasha", "lcpd", "offroad", "police_firwood2_pbfmv", "polizia", "rally_pro_asphalt", "rally_pro_gravel", "scpd", "sport_RS2_DCT", "sport_RS2_wagon_DCT", "sport_RS_DCT", "sport_RS_M", "sport_RS_wagon_DCT", "sport_RS_wagon_M", "sport_S_DCT", "sport_S_M", "sport_S_wagon_DCT", "sport_S_wagon_M", "street_tuned", "track_attack", "trackday_M", "冒险者·匪·羊", "冒险者·警·羊"},
    ["utv"] = {"custom", "race", "turbo", "wild"},
    ["van"] = {"bhp", "bofd", "brd", "bsd", "bsp", "carabinieri", "carabinieri passenger", "drift", "fnyc", "fsb", "fwfd", "fwpd", "gpd", "lcpd", "lspdswat", "mmv", "nbsp", "noose", "nycpd", "pkr", "pnyct", "polizia", "polizia passenger", "riksenergi", "rusamb", "ruspd", "safd", "sfctos", "shpd", "shswat", "ssd", "stars", "tgpd", "usaap", "冒险者·匪·羊·商用底盘(自定义)"},
    ["vivace"] = {"ardente_230_DCT", "ardente_230_M", "ardente_S_310_DCT", "ardente_S_310_M", "ardente_S_410Q_DCT", "ardente_S_410Q_M", "ardente_carminsport", "ardente_ev", "ardente_ev_sport", "ardente_gendarmerie", "ardente_race", "ardente_rally", "ardente_rally_asphalt", "ardente_track", "ardente_tuned", "asphalt_SQ", "asphalt_SQ_emousse", "emousse_230S_DCT", "emousse_amateur_race", "emousse_arsenic", "emousse_s_gendarmerie", "gravel_SQ", "gravel_SQ_emousse_workpls", "hillclimb_SQ", "hillclimb_SQ_emousse", "race_SQ", "race_SQ_emousse_ht", "race_SQ_emousse_ht2", "safetycar_DCT", "trackday_M", "vivace_230S_DCT", "vivace_S350_intrcptr_pbfmv", "vivace_S_270_DCT", "vivace_S_270_M", "vivace_S_310_DCT", "vivace_S_310_M", "vivace_S_350q_DCT", "vivace_S_350q_M", "vivace_S_410q_DCT", "vivace_S_410q_M", "vivace_S_gendarmerie"},
    ["wendover"] = {"Street_tuned", "hillclimb", "onlinenew", "race", "super"},
    ["wigeon"] = {"drag", "mantis"},
}

local CARS_NORMAL = {
    ["TPUSuperlite"] = {"15GT_LHD", "15GT_RHD", "15Track_LHD", "15Track_RHD", "1600GT_Early_LHD", "1600GT_Early_RHD", "80R", "80S", "Superlite600"},
    ["autobello"] = {"150", "150_rally", "150_track", "autobuggy_baja_spec", "baja", "onlinenew"},
    ["barstow"] = {"188_eco_a", "188_eco_m", "291a", "291a_sport", "291m", "291m_sport", "327_RS_Atom-Jet", "327_super_sport", "353a", "353a_sport", "353m", "353m_sport", "392_javelin", "423a", "423a_sport", "423m", "423m_sport", "445_Super_Stock", "The_Appalling", "ZPD", "aero_road_sport", "aero_track_sport", "awful", "bcpd_old_pbfmv", "bspd", "early_Acapulco", "early_Atomjet", "early_disgustow", "early_i6", "early_kingsnake", "early_lancehead", "early_ls", "early_nightsnake", "early_rs", "early_ts", "early_v8", "fwpd", "i6a", "i6m", "lancehead", "police_import", "police_pbfmv", "sheriff_pbfmv", "the_serpent", "trainblower", "冒险者·警·羊·狂飙旧金山"},
    ["bastion"] = {"ZPD", "atspd", "bapdd", "base_v6_A", "base_v6_awd_A", "bcsd", "brio", "espd21", "espdn21", "fcpdd", "fvpd_nfs20", "fwpd1", "interceptor", "lspd_gta5", "luxe_v6_awd_A", "nbpd", "onlinenew", "scpd NFS14", "taxi", "冒险者·警·羊·高速截击机"},
    ["bluebuck"] = {"291a_2door", "291a_2door_mid", "291a_4door", "291a_4door_mid", "291m_2door", "291m_2door_mid", "291m_4door", "291m_4door_mid", "353a_2door", "353a_2door_hardtop", "353a_4door", "353a_4door_hardtop", "353m_2door", "353m_2door_hardtop", "353m_4door", "353m_4door_hardtop", "423a_2door_hardtop", "423a_4door_hardtop", "423m_2door_hardtop", "423m_4door_hardtop", "bsp", "bsphp", "ebpd", "horrible", "lowrider", "mcsd", "nbpd", "police", "police_bcpd_old_pbfmv", "sheriff_288_pbfmv", "ssd"},
    ["bolide"] = {"gambler"},
    ["burnside"] = {"15_bspecial_gravel", "233_i6_late_2door_sedan_m", "233_i6_late_sedan_a", "266_v8_lhead_viceroyspecial_a", "274_v8_late_sedan_utility_m", "274_v8_late_taxi_m", "29_bspecial_tarmac", "2doorSport_late_3A", "2door_late_v8_3A", "303_i6_lhead_a", "313_sheriff_pbfmv", "313_v8_late_2door_sedan_a", "313_v8_late_sedan_a", "347_v8_late_luxe_sedan_a", "347_v8_late_sport_coupe_a", "423_intrcptr_pbfmv", "423_v8_late_custom_a", "4door_late_v8_3A_luxe", "4door_late_v8_3A_police", "4door_late_v8_3M", "USP", "alpine_rally_late_m", "banger", "bigburns_gasser", "blown_ratrod", "bootlegger", "gramps_a", "leadsled", "state_sheriff", "stockcar", "stunned", "the_cuban", "冒险者·匪·羊·雷鸟", "冒险者·警·羊·哈德逊博士"},
    ["bx"] = {"200bx_base_A", "200bx_base_M", "200bx_base_prefl_A", "200bx_base_prefl_M", "200bx_base_ute_lj_A", "200bx_base_ute_lj_M", "200bx_gtz_M", "200bx_gtz_ute_lj_M", "200bx_ss_prefl_A", "200bx_ss_prefl_M", "200bx_ssr_prefl_M", "200bx_ssx_prefl_A", "200bx_ssx_prefl_M", "200bx_type_l_A", "200bx_type_l_M", "200bx_type_l_ute_lj_A", "200bx_type_l_ute_lj_M", "200bx_type_ls_A", "200bx_type_ls_M", "200bx_type_ls_ute_lj_A", "200bx_type_ls_ute_lj_M", "240bx_coupe_dx_A", "240bx_coupe_dx_M", "240bx_coupe_dx_prefl_A", "240bx_coupe_dx_prefl_M", "240bx_coupe_lx_A", "240bx_coupe_lx_M", "240bx_coupe_lx_early_A_vip", "240bx_coupe_lx_early_M_vip", "240bx_coupe_lx_prefl_A", "240bx_coupe_lx_prefl_M", "240bx_coupe_rally_asp", "240bx_coupe_rally_gravel", "240bx_coupe_se_A", "240bx_coupe_se_M", "240bx_coupe_se_prefl_A", "240bx_coupe_se_prefl_M", "240bx_hatch_dx_A", "240bx_hatch_dx_M", "240bx_hatch_dx_early_A_vip", "240bx_hatch_dx_early_M_vip", "240bx_hatch_dx_prefl_A", "240bx_hatch_dx_prefl_M", "240bx_hatch_lx_A", "240bx_hatch_lx_M", "240bx_hatch_lx_miami_A", "240bx_hatch_lx_miami_M", "240bx_hatch_lx_prefl_A", "240bx_hatch_lx_prefl_M", "240bx_hatch_lxz_M", "240bx_hatch_lxz_prefl_M", "240bx_hatch_lxz_srtec_M", "240bx_hatch_lxz_srtec_black_M", "240bx_hatch_lxz_srtec_black_prefl_M", "240bx_hatch_lxz_srtec_prefl_M", "240bx_intrcptr_pbfmv", "240bx_police_firwood_pbfmv", "240bx_ute_lj_dx_A", "240bx_ute_lj_dx_M", "240bx_ute_lj_lx_A", "240bx_ute_lj_lx_M", "240bx_ute_lj_lxz_M", "240bx_vert_lx_A", "240bx_vert_lx_M", "240bx_vert_lx_prefl_A", "240bx_vert_lx_prefl_M", "240bx_vert_se_A", "240bx_vert_se_prefl_A", "alexia_ace_vip", "alexia_canyon_vip", "alexia_itb_vip", "alexia_jack_a_vip", "alexia_jack_vip", "alexia_king_a_vip", "alexia_king_vip", "alexia_missile_vip", "alexia_offroad_vip", "alexia_queen_a_vip", "alexia_queen_vip", "alexia_stance_static_vip", "bx_itb_vip", "bx_stance_vip", "derby_M", "diana_base_A", "diana_base_M", "diana_base_prefl_A", "diana_base_prefl_M", "diana_base_ute_lj_A", "diana_base_ute_lj_M", "diana_diamonds_prefl_A", "diana_diamonds_prefl_M", "diana_gtz_M", "diana_gtz_tec2_vert_prefl_M", "diana_gtz_tec_vert_prefl_M", "diana_gtz_ute_lj_M", "diana_hearts_50_prefl_A", "diana_hearts_prefl_M", "diana_spades_prefl_A", "diana_spades_prefl_M", "diana_type_l_A", "diana_type_l_M", "diana_type_l_gusty_A", "diana_type_l_ute_lj_A", "diana_type_l_ute_lj_M", "diana_type_ls_A", "diana_type_ls_M", "diana_type_ls_signia_prefl_M", "diana_type_ls_srtec_M", "diana_type_ls_srtec_prefl_M", "diana_type_ls_ute_lj_A", "diana_type_ls_ute_lj_M", "fwpd", "huntsman_A", "huntsman_M", "huntsman_roadsport", "huntsman_utility", "huntsman_v8_A", "huntsman_v8_M", "nbsp", "police_A", "police_alt_A", "scpd", "usaap", "usaap1", "vspecial_M", "vspecial_ute_lj_M"},
    ["ccf"] = {"country_M", "country_M_rhd", "e_base", "e_base_rhd", "f4_base_A", "f4_base_A_bvtp", "f4_base_M", "f4_base_M_experience", "f4_base_M_rhd", "f4_cup_07", "f4_cup_17", "f4_cup_53", "f4_cup_press", "skull"},
    ["covet"] = {"1.0_hybrid_facelift_vip", "1.0_hybrid_manual_vip", "1.0_hybrid_stance_vip", "1.5_15ZXI_sedan_vip", "1.5_beater_vip", "1.5_dxi_sedan_M_vip", "1.5_hxi_sedan_vip", "1.5_lxi_sedan_A_vip", "1.5_lxi_sedan_M_vip", "1.5_roadtrip_vip", "1.5_sedan_police_vip", "1.5_stance_beater_vip", "1.5_type_LS_A_sedan_vip", "1.5_type_LS_M_sedan_vip", "1.8_kanjo_vip", "1.8_nomi_vip", "1.8_stance_bag_vip", "1.8_stance_beater_vip", "1.8_stance_vip", "1.8_street_vip", "1.8_types_2_vip", "1.8_types_beater_vip", "1.8_types_vip", "15ee_m", "15ee_pre_M", "15ee_pre_edx_M", "15gtz_turbo2_M", "15gtz_turbo2_fultrac_M", "15gtz_turbo_M", "15gtz_turbo_fultrac_pre_M", "15gtz_turbo_pre_M", "15le_A", "15le_M", "15le_fultrac_pre_A", "15le_fultrac_pre_M", "15le_pre_A", "15le_pre_M", "15se_M", "15se_pre_M", "15se_pre_edx_M", "15zxi_M", "15zxi_f1spec_pre_M", "15zxi_pre_M", "15zxi_pre_edx_M", "16gtz_srtec_M", "16gtz_srtec_black_M", "16gtz_srtec_black_fl_M", "16gtz_srtec_fl_M", "16gtz_srtec_pre_M", "16gtz_srtec_pre_black_M", "16gtz_srtec_pre_edx_M", "16gtz_srtec_pre_edx_black_M", "16gtz_srtecnica_M", "16gtz_srtecnica_fl_M", "16gtz_srtecnica_pre_M", "16le_royale_A", "16le_royale_M", "DXi_M", "DXi_pre_M", "DXi_pre_edx_M", "LXi_A", "LXi_M", "LXi_pre_A", "LXi_pre_M", "UNFINISHED", "carabinieri", "covet_career", "gamblertruck", "gendarmerie", "gtz", "gtz_pre", "gtz_srtec", "gtz_srtec_black", "gtz_srtec_pre", "gtz_srtec_pre_black", "gtz_srtec_pre_edx", "gtz_srtec_pre_edx_black", "gtz_srtecnica_M", "guineapig_covet", "hapd", "intrcptr_pbfmv", "onlinenew", "pointless", "police", "polizia", "sport", "sport_alt", "sport_elysian_pre", "sport_pre", "sport_pre_edx", "tgpd", "type_LS_A", "type_LS_M", "type_LS_royale_A", "type_LS_royale_M", "type_L_A", "type_L_M", "type_X_M", "冒险者·匪·羊·闪电"},
    ["crownvic"] = {"41_I6_CVT", "BCPD", "Beach_Boys_Shuttle", "Beater_Retiree", "Belasco_FD", "Dover_NH_PD", "FCPD", "Firwood", "Firwood_FD", "Firwood_Police_Colorable", "Firwood_Sheriff_Colorable", "Fleet", "Future_Police", "HPP", "LCPD", "LX", "LX_Sport", "Lansdale_Police", "Lansdale_Security", "MaineState", "Marauder", "MaxiesVic", "NH_State_Police", "Police", "PoliceNew", "Police_Interceptor", "Police_Wendover_Interceptor", "PreRelease_Model", "Rapid_Taxi", "Rochester_NHPD", "Sheriff", "StateTrooper", "Stock", "Taxi_493", "Taxi_7D36", "TrainingVic", "TwoTone", "Ukraine", "Umbrella", "Undercover", "Unmarked_SAP", "VIP", "Vinyl_Roof", "Weymouth", "flyUS_Airport", "冒险者·警·羊"},
    ["etk1300"] = {"1354_190_A", "1354_190_M", "1354_190d_A", "1354_190d_M", "1354x_190_A", "1354x_190d_A", "1354x_230d_A", "1354x_250_A", "1356_offroad", "1356x_260d_A", "1356x_260d_A_polizei", "1356x_300_A", "1356x_300_A_police", "1356x_300_A_policefir", "1356x_300_A_taxi", "1356xc_260d_A", "1356xc_300_A", "冒险者·警·羊·大只"},
    ["etk800"] = {"844_150_A", "844_150_M", "854_150d_A", "854_150d_M", "854_190_A", "854_190_M", "854_190d_A", "854_190d_M", "ZPD", "bhp", "bsd", "carabinieri", "crca", "crca2", "ddr", "flyus", "genadarmerie", "lcct", "nbpd", "nbsd", "olddrivingexperience", "olddrivingexperience2", "polizia", "polizia20", "scpd", "scpd2", "冒险者·匪·羊·逃", "冒险者·警·羊·全驱", "冒险者·警·羊·捕", "冒险者·警·羊·追"},
    ["etkc"] = {"aps", "carabinieri", "espd", "espdn", "fvpd_nfs20", "polizia", "polizia20", "scpd", "scpdfr", "scsd"},
    ["etki"] = {"2400_A", "2400_A_alt", "2400_M", "2400_M_alt", "2400i_A", "2400i_A_alt", "2400i_M", "2400i_M_alt", "2400ix_A", "2400ix_A_alt", "2400ix_M", "2400ix_M_alt", "2400ti_sport_M", "2400ti_sport_M_alt", "2400tix_intcptor_pbfmv", "2400tix_sport_M", "2400tix_sport_M_alt", "3000i_A", "3000i_A_alt", "3000i_M", "3000i_M_alt", "3000ix_A", "3000ix_A_alt", "3000ix_M", "3000ix_M_alt", "3000ix_unmarked_pbfmv", "etki_career", "offroad", "onlinenew", "onlinenewcr", "rally_am_asphalt", "rally_am_gravel"},
    ["etkk"] = {"beater", "kc4", "kc4_a", "kc6", "kc6_a", "kr4", "kr4_a", "kr4s", "kr6", "kr6_a", "polizei"},
    ["etkss"] = {"sl4x_230d_A", "ss4_230d_A", "ss4_taxi_A", "ss4x_230d_A", "ss4x_polizei_A"},
    ["eumidsize"] = {"bare_liftback", "bare_saloon", "bouncy", "china_fl_base", "china_fl_base_liftback", "china_fl_high", "china_fl_high_liftback", "china_fl_sport", "drag", "dx_diesel_m", "dx_liftback_m", "dx_m", "dx_rhd_m", "extreme_stance", "gtz", "gtz_police_uk", "gtz_raceschool", "gtz_special", "gtz_special01", "gtz_top", "monster_machine", "police_cn_2", "police_ge", "race", "taxi2", "taxi3", "used", "wagwam", "冒险者·匪·羊·爱快", "冒险者·警·羊·卧底"},
    ["euvan"] = {"cargo_220i_s25_A", "cargo_220i_s25_M", "cargo_220i_s25_M_rhd_thw", "cargo_250d_delivery_M", "cargo_250d_delivery_M_rhd_thw", "cargo_250d_roadassistance_M", "cargo_250d_s10_fleet_M", "cargo_250d_s10_fleet_M_rhd_thw", "cargo_250d_s15_A", "cargo_250d_s15_M", "cargo_250d_s15_M_rhd_thw", "cargo_300_hirochi_M", "cargo_300dX_s35_AWD_A", "cargo_300dX_s35_AWD_M", "cargo_300dX_s35_AWD_M_rhd_thw", "cargo_300d_s25_A", "cargo_300d_s25_M", "cargo_300d_s25_M_rhd_thw", "cargo_300d_workpackage_M", "cargo_300d_workpackage_M_rhd_thw", "cargo_350RS_A", "cargo_350RS_M", "cargo_350RS_M_rhd_thw", "multiway_220i_s25_A", "multiway_220i_s25_M", "multiway_220i_s25_M_rhd_thw", "multiway_250d_s15_A", "multiway_250d_s15_M", "multiway_250d_s15_M_rhd_thw", "multiway_300d_polizia_M", "multiway_300d_s25_A", "multiway_300d_s25_M", "multiway_300d_s25_M_rhd_thw", "simple_traffic_euvan_alt_parked", "simple_traffic_euvan_parked", "tracer_330dX_s25_AWD_A", "tracer_330dX_s25_AWD_M", "tracer_330dX_s25_AWD_M_rhd_thw", "冒险者·匪·羊·速递", "冒险者·警·羊·歼灭者"},
    ["ferax"] = {"1997 Excel 1.3", "Beach", "Beach UKDM", "Beach_mk2", "Chagggla_", "Excel-Up mk2 facelift", "Exion Van", "GANGSTA", "Henlein", "Summer", "UKDM", "VB", "colorline_blu_mk2", "colorline_gre_mk2", "colorline_yel_mk2", "excel_darkline", "excel_shine", "exion_darkline", "exion_mk2_family", "exion_perfekt", "exion_runner", "exion_shine", "exion_van_mk2", "ferax_darkline", "ferax_shine", "rallye car", "street_tuned_v6", "stripped mule"},
    ["fullsize"] = {"SCPD2", "apd_twd", "aps", "atspd", "bapd", "bbcpd", "bbinsp", "bbksp", "bblsp", "bbmsp", "bbscsd", "bcpd", "bcpd2_pbfmv", "bcpdghost_pbfmv", "bdr", "bfd", "bppd", "bppd2", "bripd", "brpd", "bsd", "bspd", "ccilsp", "codrus", "cps", "crca", "crca2", "custom", "detective", "detective 2", "detective 3", "dnypd", "epd", "epd_tbg", "espd", "espdn", "excop", "fcpd", "fcpd_fg", "firpd", "fleet", "flyus", "frepd", "fvpd_nfs20", "fwpd", "gambler", "gcpd", "gerpd", "gpd", "gpvs", "grpd", "interceptor", "jtf", "ksd", "lapd_tbg", "lapdr", "lbp", "lcct", "lcct2", "lcpd", "lcpd4", "limo_base", "limo_derby", "limo_luxe", "limo_official", "limo_special", "lowrider", "lpdf", "lsd", "lsd2", "lsdt", "lspd", "lssd", "luxe", "lvpd", "mcpd", "miserable", "mkpd", "nbpd22_pbfmv", "nbsd", "nbsp", "noose", "nypd", "obpd", "odc", "pdny", "pdny2", "pit_training_pbfmv", "pkr", "police", "police2_pbfmv", "policetaxi_pbfmv", "pota", "ppd", "ppd_nfs9", "psbp", "pvpd", "r6apd", "r6apd2", "raccoonpd", "rpd", "rpd_nfs9", "rrpd", "ruspd", "salspd", "salvpd", "sasfpd", "scpd", "spapd", "spd", "spd2", "sport", "ssd", "stock", "taxi", "unmarked", "unmarked2_pbfmv", "usaap", "vhp", "willamette", "wmp", "wmpd", "冒险者·匪·羊·的士高", "冒险者·警·羊", "冒险者·警·羊·伪装者"},
    ["gavril_vertex"] = {"3dcarbon", "3dcarbon_showcar", "basic_derby", "beamcraft", "bev_cup", "crashtest", "derby_beast", "donk", "driving_school_a", "driving_school_m", "ecobooscht", "gavril_vertex", "godmode", "hocus_pocus_theres_a_pizza_on_your_vertex", "hotwheels", "powolice_belasco", "powolice_firwood", "preproduction", "progresspride", "rally_amateur", "roadside_assistance", "s_auto", "s_manual", "se_appearance", "se_auto", "sel-6", "ses_auto", "ses_auto_sport", "ses_manual", "ses_manual_sport", "slalomyoungster", "sport", "stanced", "stripped", "taxi_dc_wo", "taxi_dc_yb", "taxi_yield", "undercover_cop", "冒险者·匪·羊·剃刀", "冒险者·警·羊·伪装者", "冒险者·警·羊·守卫"},
    ["hopper"] = {"carabinierio", "custom", "desert_A", "desert_M", "dprk", "jpaa", "jps", "lxt6_A", "lxt6_M", "offroad", "pkr", "race", "sheriff", "sport_A", "sport_M", "unmarked_pbfmv", "xt6_A", "xt6_M", "zxt6_A", "zxt6_M"},
    ["hute"] = {"120_adventure_M", "120_gr_M", "120_gs_A", "120_gs_M", "120_gs_travel_M", "120_gs_travel_extra_M", "120_lt_A", "120_s_M", "champion_campagne_M", "champion_de_M", "champion_de_extra_M", "champion_le_A", "champion_s_M", "champion_se_A", "champion_se_M", "fuk", "offroad", "police_aus_M", "police_fir_M", "police_nz_M", "rascal_cf_A", "rascal_cf_M", "rascal_cf_traveller_M", "rascal_cf_traveller_extra_M", "rascal_monarch_A", "rascal_sf_M", "rascal_sr_M", "rascal_sr_sportback_M", "rascal_sr_turbo_M", "rush_adventure_M", "rush_dream_M", "rush_gr_M", "rush_gs_A", "rush_gs_M", "rush_gs_travel_M", "rush_gs_travel_extra_M", "rush_hr_A", "rush_kiwi_A", "rush_l_M", "rush_lt_A", "rush_outback_M", "rush_s_M", "rush_sl_A", "rush_sl_M", "rush_sl_vacation_M", "rush_sl_vacation_extra_M", "rush_walt_M", "rush_work_M", "rush_xl_M", "rush_xl_turbo_M", "rush_zsr_M", "turboburger_M", "冒险者·匪·羊·烈马", "冒险者·警·羊·牧马人"},
    ["kajzercolt"] = {"base_fx", "base_gx", "base_gx_A", "base_gxl", "base_gxl_A", "base_poverty", "base_sx", "base_sx_turbo", "facelift_fx", "facelift_gx", "facelift_gx_A", "facelift_gxl", "facelift_gxl_A", "facelift_gxl_v6", "facelift_poverty", "facelift_sx", "facelift_sx_turbo", "rally_amateur"},
    ["lansdale"] = {"22_cargo_A", "22_cargo_late_A", "22_garage_M", "22_security_late_A", "25_S_M", "25_TD_S_M", "25_TD_S_late_A", "25_TD_late_M", "25_base_A", "25_base_late_A", "25_derby_M", "25_taxi_A", "33_S_A", "33_S_late_A", "33_S_sport_A", "33_S_sport_late_A", "33_derby_late_M", "33_police_late_A", "38_SE_AWD_A", "38_SE_AWD_late_A", "38_SE_sport_AWD_A", "38_SE_sport_AWD_late_A", "38_overland_AWD_A", "44_intrcptr_pbfmv", "FWPD", "bsp", "flyus", "gambler500", "lcct", "nbpd", "nbsd", "policetaxi_pbfmv", "冒险者·警·羊"},
    ["legran"] = {"acpd", "acpd2", "base_i4_M", "base_i4_facelift_M", "base_i4_wagon_facelift_M", "bbksp", "bbmsp", "bbscsd", "bfhp", "bhp", "bsp", "bspd", "ccpd", "derby", "derby_wagon", "detective", "firechief", "fwpd", "hpd", "luxe_v6_A", "luxe_v6_wagon_A", "nbpd", "nbsd", "nysp", "onlinenew", "onlinenewcr", "onlinenewspecial", "police", "police2_pbfmv", "policetaxi_pbfmv", "rally", "rally_asphalt", "rpd", "s_i4_A", "s_i4_wagon_A", "s_v6_A", "s_v6_facelift_A", "se_i4_A", "se_i4_wagon_facelift_A", "se_v6_A", "se_v6_towing_A", "se_v6_wagon_facelift_A", "se_v6_wagon_offroad_facelift_A", "sport_s_i4_A", "sport_s_i4_M", "sport_s_v6_A", "sport_s_v6_M", "sport_se_i4_facelift_A", "sport_se_i4_facelift_M", "sport_se_v6_awd_facelift_A", "sport_se_v6_awd_facelift_M", "taxi", "usaap", "vcpd", "冒险者·匪·羊·摧狼", "冒险者·警·羊·城市巡逻", "冒险者·警·羊·高速巡警"},
    ["midsize"] = {"DX_A", "DX_M", "EX_V6_A", "EX_V6_M", "EXi_V6_A", "LX_A", "LX_M", "LX_V6_A", "LX_V6_GXRV_A", "LX_V6_GXRV_M", "LX_V6_GXRV_redwood_A", "LX_V6_M", "LX_V6_sport_A", "LX_V6_sport_M", "LX_sport_A", "LX_sport_M", "army_pbfmv", "derby", "ex_v6_miami", "ex_v6_miami_M", "fire_chief_pbfmv", "gtturbo_A", "gtturbo_M", "mppo", "onlinenewtpb", "onlinenewtpd", "police", "police2_pbfmv", "police_cab_pbfmv", "policetaxi_pbfmv", "royale20_A", "sg_A", "sg_M", "sg_ab_A", "sg_ab_M", "sg_fleet_M", "sheriff_pbfmv", "special", "special_4wd", "sr_srtec_M", "sr_srtec_black_M", "stanced", "taxi", "tecnica", "touring18_A", "touring18_M", "touring18_ab_A", "touring18_ab_M", "touring20_4_A", "touring20_4_M", "touring20_4_ab_A", "touring20_4_ab_M", "touring20_A", "touring20_M", "touring20_R_A", "touring20_R_M", "touring20_S_A", "touring20_S_M", "touring20_ab_A", "touring20_ab_M", "touring20_gxrv_ab_A", "touring20_gxrv_boulevard_ab_A", "turboburger", "unmarked", "xg_A", "xg_M", "xg_ab_A", "xg_ab_M", "xg_fultrac_A", "xg_fultrac_M", "xg_fultrac_ab_A", "xg_fultrac_ab_M", "xgd_A", "xgd_M", "xgd_fultrac_A", "xgd_fultrac_M", "xgs_A", "xgs_M", "xgs_srtec_M", "xgs_srtec_black_M", "xgs_tecnica"},
    ["miramar"] = {"007r", "base_export_M_early", "base_export_M_late", "base_facelift_M", "bsp", "derby", "drift", "luxe_A", "luxe_coupe_A", "luxe_coupe_export_early_A", "luxe_coupe_export_late_A", "luxe_coupe_facelift_A", "luxe_facelift_A", "luxe_sedan_export_A_early", "luxe_sedan_export_A_late", "polizia", "sport", "sport_coupe", "sport_coupe_facelift", "sport_facelift", "uru", "ute_export_M_early", "ute_export_M_late"},
    ["moonhawk"] = {"264_ghx_late_m", "272_ghx_early_m", "305_d_v6_a", "305_d_v6_m", "350_d_v8_a", "350_d_v8_m", "448_ghs_early_m", "448_ghs_late_a", "500_elgalano_a", "ZPD", "alder_nascar", "bcpd_pbfmv", "bsp", "detective", "donk", "drag_mohawk", "fwpd", "ill_fated", "police_pbfmv", "sheriff_pbfmv", "terrible", "the_terrifying", "v8a", "v8a_alt", "v8a_luxe", "v8a_luxe_alt", "v8a_sport", "v8a_sport_alt", "v8m", "v8m_alt", "v8m_luxe", "v8m_luxe_alt", "v8m_sport", "v8m_sport_alt", "v8special", "冒险者·匪·羊·犯人", "冒险者·警·羊·Pimp My Ride", "冒险者·警·羊·猎人", "冒险者·警·羊·真探"},
    ["muscle"] = {"derby", "driftstow", "police", "v6", "v6_auto", "v6_convertible", "v6_convertible_auto", "v8", "v8_auto", "v8_convertible", "v8_convertible_auto", "v8_sport", "v8_sport_auto", "v8_sport_convertible", "v8_sport_convertible_auto"},
    ["nine"] = {"bsp", "fwpd", "guts", "hotroddie", "nine_drift", "nine_pickup_hotrod", "valley_speedster", "冒险者·匪·羊·私酒号"},
    ["pessima"] = {"18SE-i_A", "18SE-i_A_kljpwagon", "18SE-i_coupe_A", "DX_A", "DX_A_kljpwagon", "DX_M", "DX_M_kljpwagon", "DX_pre_A", "DX_pre_A_kljpwagon", "DX_pre_M", "DX_pre_M_kljpwagon", "GTz_kljpwagon", "GTz_pre_kljpwagon", "HX_M", "HX_M_kljpwagon", "HX_pre", "HX_pre_M_kljpwagon", "LX_A", "LX_A_kljpwagon", "LX_M", "LX_M_kljpwagon", "LX_pre_A_kljpwagon", "LX_pre_M_kljpwagon", "LX_srtec_M", "LX_srtec_coupe_M", "LX_srtec_pre_M", "LX_srtec_pre_coupe_M", "ZXR_M", "ZX_4ws_M", "ZX_4ws_M_kljpwagon", "ZX_4ws_coupe_M", "ZX_4ws_pre_M_kljpwagon", "ZX_M", "ZX_M_kljpwagon", "ZX_celeb_pre_M_kljpwagon", "ZX_coupe_M", "ZX_pre_M_kljpwagon", "debug_andy_v2", "derby", "derby_kljpwagon", "dx_lift_A", "dx_lift_M", "gtz_lift", "hx_lift_M", "lx_lift_A", "lx_lift_M", "police_pbfmv", "rz", "rz_coupe", "sheriff_pbfmv", "srtec_M", "srtec_coupe_M", "srtec_pre_M", "srtec_pre_coupe_M", "srtecblack_M", "srtecblack_coupe_M", "srtecnica", "srtecnica_sedan", "zx_4ws_lift", "zx_lift_M"},
    ["pickup"] = {"bdr", "beampo", "bhp", "bofd", "bsd", "bsp", "chief_stormchaser", "d10_423sport_A", "d10_4wd_A", "d10_4wd_parkranger", "d10_4wd_zeta_A", "d10_early_4wd_a_offroad", "d10_early_4wd_m", "d10_early_rwd_a", "d10_ext_4wd_A", "d10_ranger_pbfmv", "d15_423sport_A", "d15_4wd_A", "d15_4wd_A_facelift", "d15_4wd_M", "d15_4wd_offroad_M", "d15_A", "d15_M", "d15_crew_4wd_M", "d15_crew_A_facelift", "d15_crew_M", "d15_crew_shortbed_4wd_A", "d15_cypher_awd_m", "d15_drift_M", "d15_early_423_roadsport", "d15_early_4wd_a", "d15_early_farmhand_m", "d15_early_fleet_m", "d15_early_m", "d15_early_stepside_m", "d15_ext_4wd_A", "d15_ext_4wd_M", "d15_ext_A", "d15_ext_A_facelift", "d15_ext_M", "d15_ext_customclassic_M", "d15_ext_longbed_A", "d15_ext_longbed_M", "d15_fleet_M_facelift", "d15_fleet_ext_M", "d15_fleet_ext_M_facelift", "d15_longbed_4wd_A", "d15_longbed_4wd_M", "d15_nightshade_express_a", "d15_redsport_express_a", "d15_roadsport_awd_M", "d15_trailtop_special_a", "d25_crew_4wd_A", "d25_crew_4wd_A_facelift", "d25_crew_4wd_M", "d25_crew_A_facelift", "d25_crew_dually_A", "d25_crew_police_pbfmv", "d25_early_a_awd", "d25_early_ext_a_awd", "d25_early_fleet_m_d", "d25_early_longbed_dually_m_awd", "d25_ext_longbed_4wd_A", "d25_ext_longbed_4wd_A_facelift", "d25_ext_longbed_4wd_M", "d25_ext_longbed_A", "d25_ext_longbed_dually_A_facelift", "d25_longbed_4wd_A", "d25_longbed_4wd_M", "d25_longbed_4wd_lifted_A", "d25_longbed_A", "d25_longbed_M", "d30_early_4wd_kentarch_a", "d30_ext_4wd_kentarch_A", "d35_4WD_ext_longbed_A", "d35_4WD_longbed_A", "d35_crew_4wd_beast_A", "d35_crew_diesel_chiefrancher_A", "d35_crew_dually_A", "d35_disappointment_A", "d35_early_crew_a_awd_d", "d35_early_fleet_ext_dually_m_d", "d35_early_lucv", "d35_ext_chiefrancher_dually_A", "d35_longbed_dually_A", "d35_longbed_dually_M", "d45_early_cargobox_d_m", "deserttruck_crawler_A", "deserttruck_crew_crawler_A", "deserttruck_rockracer_A", "detective", "dprk", "drm", "ecx", "ecx2", "ecx3", "exc3", "fbi_ranger", "fwpd", "gdp", "heavy_foot", "hpd", "kra", "major_mayhem", "muscle_pickup", "nbpd", "nbsd", "nysp gta", "ol_rusty", "onlinenew", "outback_crawler", "ptmpd", "retro_custom", "sapd", "tasticola", "usaap", "冒险者·警·羊·拯救者", "冒险者·警·羊·警长座车", "冒险者·警·羊·费伍德警", "冒险者·警·羊·运动卡"},
    ["picnic"] = {"1.1_city_a", "1.1_city_m", "1.1_foxtrot_a", "1.1_foxtrot_m", "1.1_young_a", "1.1_young_m", "1.3_city_a", "1.3_city_m", "1.3_dune_a", "1.3_dune_m", "1.6_dune_a", "1.6_dune_m", "1.6_gendarmerie_m", "1.6_gti_a", "1.6_gti_m", "1.6_rally_gravel_seq", "1.6_rally_seq"},
    ["pigeon"] = {"race"},
    ["roamer"] = {"4wd_facelift", "4wd_lxt_facelift", "4wd_xt_facelift", "4wd_xt_unmarked_pbfmv", "adventure", "bcpd2_pbfmv", "bcpdghost_pbfmv", "derby", "detective", "detective 2", "ecx1", "facelift", "firechief", "gpdd", "i6_4wd_m", "i6_m", "lxt_facelift", "offroad", "onlinenew", "onlinenewcr", "police", "ptmpd", "sheriff", "sport", "sport_ext", "sport_ext_m", "sport_m", "unmarked", "v8", "v8_4wd", "v8_4wd_lxt", "v8_4wd_lxt_m", "v8_4wd_m", "v8_4wd_xt", "v8_4wd_xt_m", "v8_lxt", "v8_lxt_35", "v8_lxt_35_m", "v8_lxt_m", "v8_m", "v8_xt", "v8_xt_m", "xt_facelift"},
    ["sbr"] = {"bapd", "base_RWD_DCT", "base_RWD_M", "base_RWD_fl_DCT", "base_RWD_fl_M", "bpi", "carabinieri", "dsh", "fvpd_nfs20", "polizia", "polizia20", "scpd"},
    ["signia"] = {"120sr", "240bx_gt_late", "240bx_l_late", "240bx_l_towthing", "240bx_le_late_A", "240bx_le_late_M", "240bx_sr_late", "first_gtz", "gt2000_early", "gt2000_late", "gte2000_iefs_late", "gtz2000r_early", "gtz2000r_late", "heritage_race", "lowrider", "lx2000_brilliance_late_A", "lx2000_brilliance_late_M", "lxe2000_grande_iefs_late_A", "lxe2000_grande_iefs_late_M", "lxe2000_grande_iefs_late_M_options", "lxe2000_iefs_late_A", "lxe2000_iefs_late_M", "police", "rally", "rz1200_late", "rzz1200_late", "stanced", "street"},
    ["sunburst2"] = {"Polizia Sedan", "ZPD", "apmTutorial_sunburst", "base_CVT", "base_EU_CVT", "base_EU_M", "base_EU_wagon_CVT", "base_EU_wagon_M", "base_wagon_CVT", "bcpd_pbfmv", "bcsd", "bhp", "brio", "bsd", "carabinieri", "comfort_CVT", "comfort_M", "comfort_wagon_CVT", "comfort_wagon_M", "drift_street", "firwood_police", "fwpd", "nbpdold", "onlinenew", "onlinenewcr", "onlinenewcrtpb", "onlinenewtpb", "police", "police2_pbfmv", "police_firwood_pbfmv", "polizia20", "rally_am_asphalt", "rally_am_gravel", "sheriff_pbfmv", "shpd", "skpd", "sport_EU_DCT", "sport_EU_M", "sport_EU_wagon_DCT", "sport_EU_wagon_M", "冒险者·警·羊·截击机"},
    ["utv"] = {"base", "junior"},
    ["van"] = {"21", "bafd", "derby", "h15_ext_vanster", "h15_passenger", "h15_passenger_i6", "h15_vanster", "h15_xt_passenger", "h25_bcpd2_pbfmv", "h25_ext_passenger", "h25_ext_passenger_4wd", "h25_ext_passenger_4wd_xt", "h25_ext_passenger_xt", "h25_ext_vanster", "h25_ext_vanster_4wd", "h25_passenger", "h25_passenger_4wd", "h25_passenger_4wd_xt", "h25_passenger_xt", "h25_vanster", "h25_vanster_4wd", "h25_worker", "h35_bcpd3_pbfmv", "h35_ext_4wd_passenger", "h35_ext_passenger_xt", "h35_ext_vanster", "h35_ext_vanster_4wd", "h35_passenger_4wd_xt", "h35_passenger_xt", "h35_vanster", "h35_vanster_4wd", "h45_chassiscab", "lcfd", "lcmp", "lsfd", "lsmc", "mrsa", "offroad", "offroad_alt", "police", "police_passenger", "rfd", "street_tuned", "tacola2", "vcfd", "冒险者·匪·羊·叹息之墙", "冒险者·警·羊·一块巨石"},
    ["vivace"] = {"ZPD", "ardente_190d_DCT", "ardente_190d_DCT_comfort", "ardente_190d_M", "ardente_carabinieri", "carabinieri", "carabinieri2", "emousse_110_M", "emousse_150d_M", "emousse_160_M", "emousse_190Sd_DCT", "emousse_230S_DCT_vacation", "emousse_95d_M", "emousse_95d_M_work", "emousse_belasco", "emousse_crashtest", "emousse_east_M", "emousse_ev", "emousse_fire", "emousse_firwood", "emousse_fuoco", "emousse_gpolice", "emousse_mallsec", "emousse_medic", "emousse_polizei", "emousse_polizia", "emousse_st", "emousse_worn", "fwpd", "fwpd2", "mpd", "onlinenew", "onlinenewcr", "onlinenewcrtpb", "polizei", "polizei2", "polizia1", "polizia2", "tograc_110_M", "tograc_110d_M", "tograc_150dqX_DCT", "tograc_150dq_DCT", "tograc_150dq_M", "tograc_160q_DCT", "tograc_160q_M", "tograc_190dq_DCT", "tograc_270QX_intrcptr_pbfmv", "tograc_amrally_DCT", "tograc_polizia", "tograc_qE", "us_market_130", "us_market_130_drycabco", "us_market_130_turboburger", "us_market_130_yieldcabco", "us_market_230S", "us_market_base", "us_market_ev", "vivace_110_M", "vivace_110d_M", "vivace_150d_DCT", "vivace_150d_M", "vivace_160_DCT", "vivace_160_M", "vivace_160_unmarked_pbfmv", "vivace_190Sd_DCT", "vivace_E", "vivace_polizia", "冒险者·匪·羊·仙贝", "冒险者·匪·羊·跑路车", "冒险者·警·羊·无名小卒", "冒险者·警·羊·超体"},
    ["wendover"] = {"base_v6_A", "base_v6_A_facelift", "bsp", "derby", "fwpd", "gambler", "interceptor", "interceptor2_pbfmv", "junkhana", "nusap", "onlinenewcr", "rally", "s_v6_A", "s_v6_A_facelift", "safetycar", "se_v6_A", "se_v6_A_facelift", "se_v8_A", "se_v8_A_facelift", "sport_s_v6_A", "sport_s_v6_A_facelift", "sport_se_v6_A", "sport_se_v6_A_facelift", "sport_se_v6_M", "sport_se_v6_M_facelift", "sport_se_v8_A", "sport_se_v8_A_facelift", "冒险者·匪·羊·老爷爷", "冒险者·警·羊·战士"},
    ["zenith"] = {"contributor_M", "drivingschool_M", "gl_A", "gl_M", "gl_diesel_A", "gl_diesel_M", "gl_sedan_A", "gl_sedan_M", "gl_sedan_diesel_A", "gl_sedan_diesel_M", "gl_sedan_taxi_A", "gs_A", "gs_M", "gs_lucia_A", "gs_sedan_A", "gs_sedan_M", "gs_sedan_taxi_A", "gs_sedan_turbodiesel_A", "gs_sedan_turbodiesel_M", "gs_turbodiesel_A", "gs_turbodiesel_M", "guineapig_M", "haiso_A", "insanity", "luminaire_v_A", "luminaire_v_M", "luminaire_v_coupe_A", "luminaire_v_coupe_M", "luminaire_v_sedan_A", "luminaire_v_sedan_M", "luminaire_vi_aws_A", "luminaire_vi_aws_M", "luminaire_vi_aws_coupe_A", "luminaire_vi_aws_coupe_M", "luminaire_vi_aws_gf_A", "luminaire_vi_aws_sedan_A", "luminaire_vi_aws_sedan_M", "luminaire_viturbo_50th_A", "luminaire_viturbo_A", "luminaire_viturbo_coupe_50th_A", "luminaire_viturbo_coupe_A", "luminaire_viturbo_sedan_A", "lx_sedan_taxi_A", "mj2", "police_nz", "police_sedan_jp", "rally_seq", "stance_A", "touring2_seq", "touring_l_A", "touring_l_M", "touring_l_coupe_A", "touring_l_coupe_M", "touring_l_sedan_A", "touring_l_sedan_M", "touring_li_aws_A", "touring_li_aws_M", "touring_li_aws_coupe_A", "touring_li_aws_coupe_M", "touring_li_aws_sedan_A", "touring_li_aws_sedan_M", "touring_li_turbo_A", "touring_li_turbo_M", "touring_li_turbo_coupe_A", "touring_li_turbo_coupe_M", "touring_li_turbo_sedan_A", "touring_li_turbo_sedan_M", "touring_ri_turbo_M", "touring_ri_turbo_coupe_M", "touring_seq"},
    ["zenith2"] = {"1800_touring_A", "1800_touring_M", "1800_touring_v6_A", "1800_touring_v6_M", "2000_luminaire_A", "2000_luminaire_M", "2000_luminaire_gabester_A", "2000_touring4_A", "2000_touring4_M", "2000_touring4_black_A", "2000_touring4_black_M", "2000_touringR_A", "2000_touringR_M", "2000_touringR_miami_A", "2000_touring_A", "2000_touring_M", "2200_touringd_A", "2200_touringd_M", "2200_touringd_awd_A", "2200_touringd_awd_M", "MXZ-The Sword (Cop)", "MXZ-The Sword Diesel (Cop)", "dreid", "jtccbase", "oilex", "rennspecht_A", "rennspecht_M", "stance_A"},
}

local CARS_GRANDPA = {
    ["autobello"] = {"110_m", "110a_m", "110b_m", "130_m", "130a_m", "130b_m", "bsp", "carabinieri", "gambler", "polizia", "tricolore"},
    ["bastion"] = {"dnypd", "gcpd", "jtf", "nbsp", "冒险者·警·羊·州警·"},
    ["bluebuck"] = {"i6a_2door", "i6a_4door", "i6m_2door", "i6m_4door", "taxi"},
    ["burnside"] = {"2doorSport_early_3M", "2door_early_2A", "2door_late_i6_3M", "2door_utility_early_3M", "2door_utility_late_3M", "4door_early_3M", "4door_early_luxe_2A", "4door_early_v8_3M_taxi", "4door_late_i6_2A", "cspd", "ebpd", "fwpd", "nbpd", "nbt", "vckc"},
    ["covet"] = {"1.5_15S_sedan_vip", "1.5_dx_sedan_vip", "1.5_dxi_sedan_A_vip", "13s_M", "13s_pre_M", "15se_A", "15se_pre_A", "15se_pre_edx_A", "3wheel", "DX_M", "DX_pre_M", "DXi_A", "DXi_pre_A", "DXi_pre_edx_A", "covet_tutorial", "skidplate", "student_driver"},
    ["crownvic"] = {"冒险者·匪·羊·汉子", "冒险者·警·羊·一起抓人", "冒险者·警·羊·无间"},
    ["etki"] = {"bhp", "brpm", "bsd", "carabinieri", "lvpd", "msc", "ptmpd"},
    ["eumidsize"] = {"china_base", "china_fl_standard", "china_fl_standard_liftback", "china_prototype", "china_sport", "china_top", "derby", "dx_facelift_m", "dx_liftback_facelift_m", "general_walker", "gt_m", "lx_a", "lx_diesel_m", "lx_exclusive", "lx_facelift_a", "lx_facelift_m", "lx_liftback_a", "lx_liftback_facelift_a", "lx_liftback_facelift_m", "lx_liftback_m", "lx_m", "lx_rhd_a", "lx_rhd_m", "lx_turbodiesel_m", "police_bg", "police_cn", "police_ro", "police_ua_new", "police_ua_old", "police_uk_1", "police_uk_2", "police_uk_3", "police_uk_undercover", "prototype", "rally", "sx_a", "sx_facelift_a", "sx_facelift_m", "sx_liftback_a", "sx_liftback_facelift_a", "sx_liftback_facelift_m", "sx_liftback_m", "sx_m", "taxi", "trevor", "冒险者·警·羊·大英警"},
    ["euvan"] = {"cargo_140i_s10_fleet_M", "cargo_140i_s10_fleet_M_rhd_thw", "cargo_140i_s15_A", "cargo_140i_s15_M", "cargo_140i_s15_M_rhd_thw", "multiway_140i_s15_A", "multiway_140i_s15_M", "multiway_140i_s15_M_rhd_thw", "simple_traffic_euvan", "simple_traffic_euvan_alt"},
    ["ferax"] = {"1.7 Diesel", "1.7 Diesel MK2 Facelift", "Excel-Up Late", "exion_mk2_family_diesel", "exion_police_mk2", "outrider_4x4"},
    ["gavril_vertex"] = {"beater", "bev", "double_decker", "double_decker_pedals_top", "fidget_spinner"},
    ["hopper"] = {"bsp", "carabinieri", "classic", "gdp", "gecko", "guineapig_hopper", "kra", "lxt4_A", "lxt4_M", "nbpd", "parkranger", "polizia", "xt4_A", "xt4_M"},
    ["midsize"] = {"11", "ZPD", "adventurer_police_legal", "atspd", "bbinsp", "bbksp", "bbmsp", "bbscsd", "bfhp", "bhp", "brio", "brpm", "bsd", "bsp", "carabinieri", "crca", "crca2", "flyus", "fwpd", "lcct", "nbcsd", "nbpd", "opdw", "pdny", "sfpdw", "shhpd", "shpd", "sppd", "topd", "冒险者·警·羊·大隐隐于市", "冒险者·警·羊·柴州警", "冒险者·警·羊·装货"},
    ["miramar"] = {"base_M", "base_ute_M", "base_ute_facelift_M", "base_ute_plucky_M", "carabinieri"},
    ["moonhawk"] = {"i6a", "i6a_alt", "i6m", "i6m_alt"},
    ["nine"] = {"b", "nine_coupe", "nine_coupe_luxe", "nine_junkrod", "nine_overlander", "nine_pickup", "nine_pickup_short", "nine_police", "nine_roadster", "nine_roadster_luxe", "nine_runner", "nine_sedan", "nine_sedan_luxe", "nine_taxi", "nine_van_ext", "nine_van_standard"},
    ["pickup"] = {"bpd", "d10_diesel_4wd_marauder_M", "d15_farmhand_M", "d15_fleet_longbed_M", "d35_4wd_pig_M", "d35_ext_diesel_dually_M", "d45_ambulance_A", "d45_cargobox_A", "d45_diesel_4wd_ambulance_A", "d45_diesel_rollback_M", "nbsp"},
    ["picnic"] = {"1.4_city_a", "1.4_city_m", "1.4_foxtrot_a", "1.4_foxtrot_m"},
    ["pigeon"] = {"ZPD", "base", "base_4w", "bcpd_3w_pbfmv", "bcpd_4w_pbfmv", "bsp", "bsp1", "carabinieri", "cool_4w", "gambler", "jpaa", "offroad_4w", "spd", "stabilizer", "streetcleaning", "tasticola", "van", "van_4w"},
    ["roamer"] = {"atspd", "bbpd", "bfhp", "bfpd", "bhp", "bms", "bpd", "brpm", "bsd", "bwd", "carabinieri", "cps", "css", "epd_tbg", "epdc", "fnyc", "fvpd_nfs20", "fwfd", "gpd", "grpd", "lapd_tbg", "lslg", "lspr", "lssd", "nbsp", "nbsp2", "nycpd", "obsd", "obsp", "pkr", "polizia", "ppd_nfs9", "ppdk9_nfs9", "rpd_nfs9", "rpdk9_nfs9", "scpd", "sppd", "ssd", "usaap", "冒险者·匪·羊·天龙特攻队", "冒险者·警·羊·警长座车", "冒险者·警·羊·贝警版"},
    ["signia"] = {"1600_brilliance_early", "1600_early", "1600_grande_early_A", "1600_grande_early_M", "160bx_s_early", "160bx_s_late", "160bx_se_early", "160bx_se_late_A", "160bx_se_late_M", "beater", "sl1600_brilliance_late"},
    ["utv"] = {"Sheriff", "plus"},
    ["van"] = {"ZPD", "ambulance", "ambulance_eu", "cactos", "deliverytruck", "h45_rollback", "lspd", "nbpd", "nbsd", "nyac", "tacola1", "vantastic", "冒险者·警·羊·君王", "冒险者·警·羊·战锤"},
    ["wigeon"] = {"base", "base_4w", "bsp", "lx", "lx_4w", "pondskipper"},
}


function pickRandomCar(pool)
    pool = pool or "all"
    local merged = {}
    if pool == "all" or pool == "high" then
        for k, v in pairs(CARS_HIGH) do merged[k] = v end
    end
    if pool == "all" or pool == "normal" then
        for k, v in pairs(CARS_NORMAL) do merged[k] = v end
    end
    if pool == "all" or pool == "grandpa" then
        for k, v in pairs(CARS_GRANDPA) do merged[k] = v end
    end
    local models = {}
    for name, _ in pairs(merged) do table.insert(models, name) end
    if #models == 0 then return nil end
    local model = models[math.random(#models)]
    local trims = merged[model]
    local trim  = trims[math.random(#trims)]
    return model, trim
end

-- ====== 叛徒力场 (Fuk ForceField) ======
-- 循环: 追杀开始后先冷却 FUK_FF_CD 秒 → 激活 FUK_FF_ACTIVE 秒 → 冷却 → 激活 ...
local FUK_FF_CD     = 60        -- 冷却时长（秒）
local FUK_FF_ACTIVE = 30        -- 激活时长（秒）
local fukFFState  = "idle"     -- idle | cooldown | active
local fukFFRemain = 0          -- 当前相位剩余秒数
-- 叛徒追杀期间油门开度上限 (0~1, 1=不限制) —— 车辆 VM input.state.throttle.maxLimit
local FUK_TRAITOR_THROTTLE = 0.85

local BLACK = { r = 0.02, g = 0.02, b = 0.02, a = 1 }
local RED   = { r = 1.0,  g = 0.05, b = 0.05, a = 1 }

function startGame()
    gameState = STATE.COUNTDOWN
    countdown = 10
    for _, p in ipairs(gamePlayers) do
        MP.TriggerClientEventJson(-1, "Fuk_SetColor", {
            playerName = p.name, r = BLACK.r, g = BLACK.g, b = BLACK.b, a = BLACK.a,
        })
        MP.TriggerClientEventJson(p.id, "Fuk_Lock", { lock = true })
    end
    MP.SendChatMessage(-1, "[MXZ-黑手] 全部变黑锁定！" .. countdown .. "秒后揭晓叛徒...")
    broadcastState()
    MP.TriggerClientEventJson(-1, "Fuk_GameState", {state = gameState, countdown = countdown, traitor = "", chaseTime = chaseTime})
    MP.CreateEventTimer("Fuk_Tick", 1000)
end

function pickTraitor()
    if #gamePlayers == 0 then endGame(); return end
    if #gamePlayers < 2 then
        MP.SendChatMessage(-1, "[MXZ-黑手] 玩家人数不足 2 人，游戏自动结束")
        endGame(); return
    end
    local idx = math.random(1, #gamePlayers)
    traitorID = gamePlayers[idx].id
    traitorName = gamePlayers[idx].name
    MP.TriggerClientEventJson(-1, "Fuk_SetColor", {
        playerName = traitorName, r = RED.r, g = RED.g, b = RED.b, a = RED.a,
    })
    MP.TriggerClientEventJson(traitorID, "Fuk_Lock", { lock = false })
    MP.TriggerClientEventJson(-1, "Fuk_Traitor", { playerName = traitorName })
    MP.SendChatMessage(-1, "[MXZ-黑手] " .. traitorName .. " 叛变了！限时 " .. (chaseTime/60) .. " 分钟！")
    gameState = STATE.TRAITOR; countdown = chaseTime
    broadcastState()
    MP.TriggerClientEventJson(-1, "Fuk_GameState", {state = gameState, countdown = countdown, traitor = traitorName or "", chaseTime = chaseTime})
    -- 新叛徒同步当前力场状态（中途换叛徒时）
    if traitorID then
        MP.TriggerClientEventJson(traitorID, "Fuk_FFApply", {
            active = (fukFFState == "active"), remain = fukFFRemain, state = fukFFState,
        })
    end
    MP.TriggerClientEventJson(-1, "Fuk_FFStatus", {
        active = (fukFFState == "active"), remain = fukFFRemain, state = fukFFState, traitor = traitorName or "",
    })
    -- 新叛徒同步油门限制
    if traitorID then
        MP.TriggerClientEventJson(traitorID, "Fuk_ThrottleCap", { cap = FUK_TRAITOR_THROTTLE })
    end
end

function endGame()
    for _, p in ipairs(gamePlayers) do
        MP.TriggerClientEventJson(p.id, "Fuk_Lock", { lock = false })
    end
    MP.TriggerClientEventJson(-1, "Fuk_Traitor", { playerName = "" })
    MP.TriggerClientEventJson(-1, "Fuk_ResetColors", {})
    MP.TriggerClientEventJson(-1, "Fuk_GameState", {state = STATE.IDLE, countdown = 0, traitor = "", chaseTime = chaseTime})
    -- 叛徒力场关闭并复位
    if traitorID then
        MP.TriggerClientEventJson(traitorID, "Fuk_FFApply", { active = false, remain = 0, state = "idle" })
    end
    MP.TriggerClientEventJson(-1, "Fuk_FFStatus", { active = false, remain = 0, state = "idle", traitor = "" })
    fukFFState = "idle"; fukFFRemain = 0
    -- 叛徒油门限制恢复
    if traitorID then
        MP.TriggerClientEventJson(traitorID, "Fuk_ThrottleCap", { cap = 1 })
    end
    gameState = STATE.IDLE; gamePlayers = {}; traitorID = nil; traitorName = nil
    MP.CancelEventTimer("Fuk_Tick")
    broadcastState()
end

function Fuk_Tick()
    -- 玩家人数不足 2 人自动结束游戏
    if #gamePlayers < 2 then
        MP.SendChatMessage(-1, "[MXZ-黑手] 玩家人数不足 2 人，游戏自动结束")
        endGame()
        return
    end
    if gameState == STATE.COUNTDOWN then
        countdown = countdown - 1
        if countdown > 0 then MP.SendChatMessage(-1, "[MXZ-黑手] " .. countdown .. "...")
        else pickTraitor() end
    elseif gameState == STATE.TRAITOR then
        countdown = countdown - 1
        if countdown == chaseTime - 10 then
            for _, p in ipairs(gamePlayers) do
                if p.id ~= traitorID then MP.TriggerClientEventJson(p.id, "Fuk_Lock", { lock = false }) end
            end
            MP.SendChatMessage(-1, "[MXZ-黑手] 开始追杀！！")
            -- 叛徒力场循环启动: 先冷却 FUK_FF_CD 秒
            fukFFState = "cooldown"; fukFFRemain = FUK_FF_CD
            -- 叛徒油门限制: 追杀全程生效 (结束/换叛徒时恢复)
            if traitorID then
                MP.TriggerClientEventJson(traitorID, "Fuk_ThrottleCap", { cap = FUK_TRAITOR_THROTTLE })
            end
        end

        -- 叛徒力场相位推进 (cooldown <-> active)
        -- 注意: 追杀开始那一 tick 不推进（countdown == chaseTime-10 仅该 tick 成立）
        if fukFFState ~= "idle" and countdown ~= chaseTime - 10 then
            fukFFRemain = fukFFRemain - 1
            if fukFFRemain <= 0 then
                if fukFFState == "cooldown" then
                    fukFFState = "active"
                    MP.SendChatMessage(-1, "[MXZ-黑手] " .. tostring(traitorName) .. " 获得了力场能力！")
                    fukFFRemain = FUK_FF_ACTIVE
                else
                    fukFFState = "cooldown"
                    MP.SendChatMessage(-1, "[MXZ-黑手] " .. tostring(traitorName) .. " 的力场消失了！")
                    fukFFRemain = FUK_FF_CD
                end
            end
        end

        -- 叛徒力场同步: 每秒推送 叛徒本人(应用力场) + 全体玩家(状态面板)
        if traitorID then
            MP.TriggerClientEventJson(traitorID, "Fuk_FFApply", {
                active = (fukFFState == "active"), remain = fukFFRemain, state = fukFFState,
            })
        end
        MP.TriggerClientEventJson(-1, "Fuk_FFStatus", {
            active = (fukFFState == "active"), remain = fukFFRemain, state = fukFFState, traitor = traitorName or "",
        })

        if countdown % 60 == 0 and countdown > 0 then
            MP.SendChatMessage(-1, "[MXZ-黑手] 剩余时间: " .. math.floor(countdown/60) .. " 分钟")
        end
        if countdown <= 0 then
            MP.SendChatMessage(-1, "[MXZ-黑手] 时间到！叛徒 " .. traitorName .. " 逃脱成功！！")
            endGame()
        end
    end
end

-- ============== 洪水: Functions ==============

local function floodSetWaterLevel(level)
    if not floodIsOceanValid then return end
    MP.TriggerClientEvent(-1, "E_SetWaterLevel", tostring(level))
end

function ET_FloodUpdate()
    if not floodIsOceanValid or not floodOptions.enabled then return end
    local level = floodOptions.oceanLevel
    local speed = floodOptions.floodSpeed
    local limit = floodOptions.limit
    local limitEnabled = floodOptions.limitEnabled
    local decrease = floodOptions.decrease
    local canChange = true
    if limitEnabled then
        if decrease then
            if level - speed < limit then canChange = false end
        else
            if level + speed > limit then canChange = false end
        end
    end
    if canChange then
        if decrease then level = level - speed else level = level + speed end
    end
    floodOptions.oceanLevel = level
    floodSetWaterLevel(level)
end

function E_OnInitiliazeFlood(playerID, waterLevel)
    waterLevel = tonumber(waterLevel) or nil
    if not waterLevel and floodInvalidCount < 2 then
        floodInvalidCount = floodInvalidCount + 1
        return
    elseif not waterLevel and floodInvalidCount >= 2 then
        floodIsOceanValid = false
        return
    end
    floodIsOceanValid = true
    if floodInitialLevel == 0.0 then
        floodInitialLevel = waterLevel
    end
    -- 新玩家同步当前水位（无论洪水是否在运行）
    if floodOptions.oceanLevel ~= 0.0 and floodInitialLevel ~= 0.0 and math.abs(floodOptions.oceanLevel - floodInitialLevel) > 0.001 then
        MP.TriggerClientEvent(playerID, "E_SetWaterLevel", tostring(floodOptions.oceanLevel))
    end
end

-- ============== 洪水: UI Event Handlers ==============

function onFloodStart(playerID, data)
    local name = MP.GetPlayerName(playerID)
    if not canControl(name) then
        MP.TriggerClientEventJson(playerID, "mxz_toast", {type="error", title="权限不足", msg="管理员在线，需要管理员身份"})
        return
    end
    if not floodIsOceanValid then
        MP.TriggerClientEventJson(playerID, "mxz_toast", {type="error", title="洪水", msg="此地图无海洋，无法使用"})
        return
    end
    if floodOptions.enabled then
        MP.TriggerClientEventJson(playerID, "mxz_toast", {type="warning", title="洪水", msg="已经启动了"})
        return
    end
    floodOptions.enabled = true
    if floodOptions.oceanLevel == 0.0 then floodOptions.oceanLevel = floodInitialLevel end
    MP.SendChatMessage(-1, "[MXZ-洪水] 洪水开始了！")
    broadcastState()
end

function onFloodStop(playerID, data)
    local name = MP.GetPlayerName(playerID)
    if not canControl(name) then
        MP.TriggerClientEventJson(playerID, "mxz_toast", {type="error", title="权限不足", msg="管理员在线，需要管理员身份"})
        return
    end
    if not floodOptions.enabled then return end
    floodOptions.enabled = false
    MP.SendChatMessage(-1, "[MXZ-洪水] 洪水已停止")
    broadcastState()
end

function onFloodReset(playerID, data)
    local name = MP.GetPlayerName(playerID)
    if not canControl(name) then
        MP.TriggerClientEventJson(playerID, "mxz_toast", {type="error", title="权限不足", msg="管理员在线，需要管理员身份"})
        return
    end
    if not floodIsOceanValid then return end
    floodOptions.enabled = false
    floodOptions.oceanLevel = floodInitialLevel
    floodSetWaterLevel(floodInitialLevel)
    MP.SendChatMessage(-1, "[MXZ-洪水] 水位已重置")
    broadcastState()
end

function onFloodSetSpeed(playerID, data)
    local name = MP.GetPlayerName(playerID)
    if not canControl(name) then
        MP.TriggerClientEventJson(playerID, "mxz_toast", {type="error", title="权限不足", msg="管理员在线，需要管理员身份"})
        return
    end
    local speed = tonumber(data)
    if not speed or speed <= 0 then
        MP.TriggerClientEventJson(playerID, "mxz_toast", {type="error", title="洪水", msg="无效的速度值"})
        return
    end
    floodOptions.floodSpeed = speed
    MP.SendChatMessage(-1, "[MXZ-洪水] 速度设为 " .. speed)
    broadcastState()
end

function onFloodSetLimit(playerID, data)
    local name = MP.GetPlayerName(playerID)
    if not canControl(name) then
        MP.TriggerClientEventJson(playerID, "mxz_toast", {type="error", title="权限不足", msg="管理员在线，需要管理员身份"})
        return
    end
    local limit = tonumber(data)
    if not limit then
        MP.TriggerClientEventJson(playerID, "mxz_toast", {type="error", title="洪水", msg="无效的数值"})
        return
    end
    floodOptions.limit = limit
    MP.SendChatMessage(-1, "[MXZ-洪水] 水位上限设为 " .. limit)
    broadcastState()
end

function onFloodSetLimitEnabled(playerID, data)
    local name = MP.GetPlayerName(playerID)
    if not canControl(name) then
        MP.TriggerClientEventJson(playerID, "mxz_toast", {type="error", title="权限不足", msg="管理员在线，需要管理员身份"})
        return
    end
    floodOptions.limitEnabled = not floodOptions.limitEnabled
    MP.SendChatMessage(-1, "[MXZ-洪水] 水位上限" .. (floodOptions.limitEnabled and "已启用" or "已禁用"))
    broadcastState()
end

function onFloodSetDecrease(playerID, data)
    local name = MP.GetPlayerName(playerID)
    if not canControl(name) then
        MP.TriggerClientEventJson(playerID, "mxz_toast", {type="error", title="权限不足", msg="管理员在线，需要管理员身份"})
        return
    end
    floodOptions.decrease = not floodOptions.decrease
    MP.SendChatMessage(-1, "[MXZ-洪水] 模式切换为" .. (floodOptions.decrease and "退水" or "涨水"))
    broadcastState()
end


-- ============== Chat Commands ==============

-- ====== v7 面板命令轮询（kick/say/bc） ======
function mxz_CmdPoll()
    ensureAccountAuth():poll_commands()
end



-- ====== 里程上报 (v7) ======
-- 客户端 onUpdate 位置差分采样 → TriggerServerEvent("mxz_dist", 米) → 本函数 curl 面板
function onMxzDist(playerID, data)
    if accountAuth then accountAuth:event(playerID,"distance",tonumber(data)) end
    return 0
end



-- ====== GForceKO 整合 (v4.7) ======
function onGKOEvent(playerID, data)
    local eventType, posStr = data:match("^(%w+):(.+)$")
    if not eventType then eventType = data end
    local now = os.time()
    if eventType == "death" then
        gkoLastTrigger[playerID] = now
        if accountAuth then accountAuth:event(playerID,"death") end
    else
        if now - (gkoLastTrigger[playerID] or 0) < gkoCooldown then
            return 0
        end
        gkoLastTrigger[playerID] = now
    end

    local gname = MP.GetPlayerName(playerID) or "未知玩家"
    local gmsg
    if eventType == "death" then
        gmsg = gname .. " 由于强烈碰撞基米了！"
        if posStr then
            local players = MP.GetPlayers()
            for pid, _ in pairs(players) do
                if pid ~= playerID then
                    MP.TriggerClientEvent(pid, "GForceKO_death_sfx", posStr)
                end
            end
        end
    else
        gmsg = gname .. " 由于强烈碰撞昏迷了！"
    end
    MP.SendChatMessage(-1, gmsg)
    return 0
end

function onGKOReset(playerID, vehicleID)
    MP.TriggerClientEvent(playerID, "GForceKO_reset", "")
end

function onChatMessage(pid, name, msg)
    if msg == "/testko" then
        MP.SendChatMessage(-1, name .. " 由于强烈碰撞昏迷了！ (测试)")
        return 1
    end

    -- /activate <key>
    local key = msg:match("^/activate%s+(.+)$")
    if key then
        local okAct, err = pcall(onActivate, pid, key)
        if not okAct then print("[MXZ] onActivate error: " .. tostring(err)) end
        return 1
    end

    -- /tp x y z [yaw] (需要 canControl)
    local x, y, z, yaw = msg:match("^/tp%s+(-?%d+%.?%d*)%s+(-?%d+%.?%d*)%s+(-?%d+%.?%d*)%s*(-?%d*%.?%d*)")
    if x then
        if not canControl(name) then
            MP.SendChatMessage(pid, "[MXZ] 管理员在线，需要管理员权限")
            return 1
        end
        local payload = { x = tonumber(x), y = tonumber(y), z = tonumber(z) }
        local yy = tonumber(yaw)
        if yy and yy ~= 0 then payload.yaw = yy end
        MP.TriggerClientEventJson(pid, "tp_teleport", payload)
        return 1
    end

    -- ====== Fuk Commands ======

    -- /fukcar [normal|grandpa|all] — 全员统一刷车
    local fukcarArg = msg:match("^/fukcar%s*(.*)$")
    if fukcarArg ~= nil then
        if not canControl(name) then MP.SendChatMessage(pid, "[MXZ] 管理员在线，需要管理员权限"); return 1 end
        local pool = "all"
        if fukcarArg:find("high") then pool = "high"
        elseif fukcarArg:find("normal") then pool = "normal"
        elseif fukcarArg:find("grandpa") then pool = "grandpa" end
        local model, trim = pickRandomCar(pool)
        if not model then MP.SendChatMessage(pid, "[MXZ-黑手] 选车失败!"); return 1 end
        -- v6: 池的 key 就是 jbeam, 配置就是 .pc 文件名(去扩展名), 不再走 JBEAM_MAP/LookupConfig
        local jbeam = model
        local pcName = trim
        local spawnJson = Util.JsonEncode({ jbeam = jbeam, model = model, trim = pcName, pc = pcName })
        local players = MP.GetPlayers()
        local count = 0
        for pid2, pname in pairs(players) do
            if MP.GetPlayerVehicles(pid2) then
                MP.TriggerClientEvent(pid2, "Fuk_SpawnVehicle", spawnJson)
                count = count + 1
            end
        end
        MP.SendChatMessage(-1, "[MXZ-黑手] 全员刷车: " .. model .. " [" .. trim .. "]  -> " .. count .. " 名玩家")
        return 1
    end

    -- /fukt <minutes> — 设定追杀时长
    local fuktMin = msg:match("^/fukt%s+(%d+)$")
    if fuktMin then
        if not canControl(name) then MP.SendChatMessage(pid, "[MXZ] 管理员在线，需要管理员权限"); return 1 end
        if gameState ~= STATE.IDLE then MP.SendChatMessage(pid, "[MXZ-黑手] 游戏进行中无法修改时长"); return 1 end
        local mins = tonumber(fuktMin)
        if mins < 1 or mins > 60 then MP.SendChatMessage(pid, "[MXZ-黑手] 时间范围: 1-60 分钟"); return 1 end
        chaseTime = mins * 60
        MP.SendChatMessage(-1, "[MXZ-黑手] 追杀阶段时长已设为 " .. mins .. " 分钟")
        MP.TriggerClientEventJson(-1, "Fuk_GameState", {state = gameState, countdown = countdown, traitor = traitorName or "", chaseTime = chaseTime})
        broadcastState()
        return 1
    end

    -- /fukend — 手动结束游戏
    if msg == "/fukend" then
        if not canControl(name) then MP.SendChatMessage(pid, "[MXZ] 管理员在线，需要管理员权限"); return 1 end
        if gameState == STATE.IDLE then MP.SendChatMessage(pid, "[MXZ-黑手] 没有进行中的游戏"); return 1 end
        -- 统一走 endGame(): 完整清理力场/油门/状态
        MP.SendChatMessage(-1, "[MXZ-黑手] 游戏被手动终止")
        endGame()
        return 1
    end

    -- /fuk — 开始游戏
    if msg == "/fuk" then
        if not canControl(name) then MP.SendChatMessage(pid, "[MXZ] 管理员在线，需要管理员权限"); return 1 end
        if gameState ~= STATE.IDLE then MP.SendChatMessage(pid, "[MXZ-黑手] 游戏进行中!"); return 1 end
        gamePlayers = {}
        for id, pname in pairs(MP.GetPlayers()) do
            if MP.GetPlayerVehicles(id) then table.insert(gamePlayers, { id = id, name = pname }) end
        end
        if #gamePlayers < 2 then MP.SendChatMessage(pid, "[MXZ-黑手] 至少需要2名有车的玩家!"); return 1 end
        startGame()
        return 1
    end

    -- /tag — 切换悬浮标签
    if msg == "/tag" then
        MP.TriggerClientEvent(pid, "ka_tag", "1")
        return 1
    end

    -- /fuker — 流光灯彩蛋 (不限权限)
    if msg == "/fuker" then
        local pname = MP.GetPlayerName(pid)
        if rainbowPlayers[pname] then
            rainbowPlayers[pname] = nil
            MP.TriggerClientEventJson(-1, "Fuk_Rainbow", { playerName = pname, active = false })
        else
            rainbowPlayers[pname] = true
            MP.TriggerClientEventJson(-1, "Fuk_Rainbow", { playerName = pname, active = true })
        end
        return 1
    end

    return 0
end

-- ============== Lifecycle ==============

function onPlayerJoin(playerID)
    local name=MP.GetPlayerName(playerID)
    playerNameByID[playerID]=name
    local auth=ensureAccountAuth()
    for other, identity in pairs(auth:view()) do
        MP.TriggerClientEvent(playerID,"ka_nick",other.."|"..identity.codename.."|"..tostring(identity.tier))
    end
    auth:join(playerID)
    MP.TriggerClientEvent(playerID,"E_OnPlayerLoaded","")
    sendStateToPlayer(playerID)
    broadcastState()
end



function onPlayerDisconnect(playerID)
    local name=playerNameByID[playerID] or MP.GetPlayerName(playerID)
    if accountAuth then accountAuth:disconnect(playerID) end
    activatedPlayers[playerID],pendingActivation[playerID],activationWarned[playerID]=nil,nil,nil
    playerNameByID[playerID]=nil
    publishActivationUsage(true)
    if not name or name=="" then return end
    gkoLastTrigger[playerID]=nil
    -- 黑手: 处理游戏中掉线
    if gameState ~= STATE.IDLE then
        for i, p in ipairs(gamePlayers) do
            if p.id == playerID then table.remove(gamePlayers, i); break end
        end
        if playerID == traitorID then
            if #gamePlayers > 0 then pickTraitor() else endGame() end
        end
    end

    saveState()
    MP.TriggerClientEvent(-1,"ka_rmnick",name)
    broadcastState()
    MP.CancelEventTimer("mxz_DelayedBroadcast")
    MP.CreateEventTimer("mxz_DelayedBroadcast",300)
end



function mxz_ActivateKickTick()
    if os.time()-quotaLastReport>=5 then loadServerSettings() end
    publishActivationUsage(false)
    -- Grace period and reason-specific messages are owned by account_runtime.
end



function mxz_SessionHeartbeat()
    if accountAuth then accountAuth:tick() end
end



function mxz_DelayedBroadcast()
    MP.CancelEventTimer("mxz_DelayedBroadcast")
    broadcastState()
end

-- ============== Init ==============

local function resetOnlineActivation()
    local auth=ensureAccountAuth()
    for pid in pairs(MP.GetPlayers()) do auth:join(pid) end
end



function onInit()
    if accountAuth then accountAuth:shutdown(); accountAuth=nil end
    MP.CancelEventTimer("mxz_AccountPoll")
    MP.RegisterEvent("mxz_AccountPoll","mxz_AccountPoll")
    MP.RegisterEvent("onShutdown","mxz_AccountShutdown")
    MP.CreateEventTimer("mxz_AccountPoll",100)
    print("[MXZ] ===== v4.0 Init (MXZ + 黑手) =====")
    loadKeys()
    loadGroups()
    loadState()
    -- Account bindings persist in the DB; reconnect/reload reauthenticates online players.
    -- Authentication is reconstructed from official account identity.
    saveState()

    MP.RegisterEvent("onPlayerJoin", "onPlayerJoin")
    MP.RegisterEvent("onPlayerDisconnect", "onPlayerDisconnect")
    MP.RegisterEvent("onVehicleSpawn", "onVehicleSpawn")
    MP.RegisterEvent("onChatMessage", "onChatMessage")

    -- MXZ events
    MP.RegisterEvent("tpg_selectRole",    "onSelectRole")
    MP.RegisterEvent("tpg_teleportAll",   "onTeleportAll")
    MP.RegisterEvent("tpg_removeRole",    "onRemoveRole")
    MP.RegisterEvent("tpg_adminTeleport", "onAdminTeleport")
    MP.RegisterEvent("tpg_adminAdd",      "onAdminAdd")
    MP.RegisterEvent("tpg_adminRemove",   "onAdminRemove")
    MP.RegisterEvent("mxz_DelayedBroadcast", "mxz_DelayedBroadcast")
    MP.RegisterEvent("mxz:SessionHeartbeat", "mxz_SessionHeartbeat")
    MP.RegisterEvent("mxz:CmdPoll", "mxz_CmdPoll")
    MP.CreateEventTimer("mxz:CmdPoll", 5000)
    MP.RegisterEvent("gforce_knockout", "onGKOEvent")
    MP.RegisterEvent("mxz_dist", "onMxzDist")
    MP.RegisterEvent("onVehicleReset", "onGKOReset")
    MP.CreateEventTimer("mxz:SessionHeartbeat", 50000)
    -- v5: 激活超时踢出 + 服务器容量设置 + 面板 token
    MP.RegisterEvent("mxz_ActivateKickTick", "mxz_ActivateKickTick")
    MP.CreateEventTimer("mxz_ActivateKickTick", 1000)
    loadServerSettings()
    publishActivationUsage(true)
    print("[MXZ] 激活宽限 " .. ACTIVATION_GRACE .. "s, 普通位（含众筹、管理员）限额 " .. tostring(serverSettings.normalActivationLimit or "无限制") .. ", 舰长限额 " .. tostring(serverSettings.captainActivationLimit or "无限制"))
    -- v4.6: 从工作目录提取服名（如 BeamMP-Server-Test -> Test）
    SERVER_NAME = (os.getenv("PWD") or ""):gsub(".*/([^/]+)$", "%1"):gsub("^BeamMP%-Server%-", "")
    if SERVER_NAME == "" then SERVER_NAME = "unknown" end

    -- Fuk events
    MP.RegisterEvent("Fuk_Tick", "Fuk_Tick")
    MP.RegisterEvent("Fuk_SpawnVehicle_Cmd", "onFukSpawnVehicleCmd")
    MP.RegisterEvent("Fuk_Start_Cmd", "onFukStartCmd")
    MP.RegisterEvent("Fuk_End_Cmd", "onFukEndCmd")
    MP.RegisterEvent("Fuk_SetTime_Cmd", "onFukSetTimeCmd")

    -- Flood events
    MP.RegisterEvent("ET_FloodUpdate", "ET_FloodUpdate")
    MP.RegisterEvent("E_OnInitiliaze", "E_OnInitiliazeFlood")
    MP.RegisterEvent("Flood_Start", "onFloodStart")
    MP.RegisterEvent("Flood_Stop", "onFloodStop")
    MP.RegisterEvent("Flood_Reset", "onFloodReset")
    MP.RegisterEvent("Flood_SetSpeed", "onFloodSetSpeed")
    MP.RegisterEvent("Flood_SetLimit", "onFloodSetLimit")
    MP.RegisterEvent("Flood_SetLimitEnabled", "onFloodSetLimitEnabled")
    MP.RegisterEvent("Flood_SetDecrease", "onFloodSetDecrease")
    MP.CreateEventTimer("ET_FloodUpdate", 100)

    resetOnlineActivation()
    publishActivationUsage(true)
    broadcastState()
    print("[MXZ] Ready — " .. countKeys(groups) .. " groups, MySQL verification enabled")
end

-- ============== Fuk UI Event Handlers ==============

function onFukSpawnVehicleCmd(playerID, data)
    local name = MP.GetPlayerName(playerID)
    if not canControl(name) then
        MP.TriggerClientEventJson(playerID, "mxz_toast", {type="error", title="权限不足", msg="管理员在线，需要管理员身份"})
        return
    end
    local d = data and data ~= "" and Util.JsonDecode(data) or {}
    local pool = d.pool or "all"
    local model, trim = pickRandomCar(pool)
    if not model then return end
    -- v6: 池的 key 就是 jbeam, 配置就是 .pc 文件名(去扩展名)
    local jbeam = model
    local pcName = trim
    local spawnJson = Util.JsonEncode({ jbeam = jbeam, model = model, trim = pcName, pc = pcName })
    local players = MP.GetPlayers()
    local count = 0
    for pid2, pname in pairs(players) do
        if MP.GetPlayerVehicles(pid2) then
            MP.TriggerClientEvent(pid2, "Fuk_SpawnVehicle", spawnJson)
            count = count + 1
        end
    end
    local poolLabel = ({high="高速组", normal="正常组", grandpa="老爷爷组", all="所有组别"})[pool] or "所有组别"
    MP.SendChatMessage(-1, "[MXZ-黑手] 全员刷车(" .. poolLabel .. "): " .. model .. " [" .. trim .. "]  -> " .. count .. " 名玩家")
end

function onFukStartCmd(playerID, data)
    local name = MP.GetPlayerName(playerID)
    if not canControl(name) then
        MP.TriggerClientEventJson(playerID, "mxz_toast", {type="error", title="权限不足", msg="管理员在线，需要管理员身份"})
        return
    end
    if gameState ~= STATE.IDLE then
        MP.TriggerClientEventJson(playerID, "mxz_toast", {type="error", title="黑手", msg="游戏进行中"})
        return
    end
    gamePlayers = {}
    for id, pname in pairs(MP.GetPlayers()) do
        if MP.GetPlayerVehicles(id) then table.insert(gamePlayers, { id = id, name = pname }) end
    end
    if #gamePlayers < 2 then
        MP.TriggerClientEventJson(playerID, "mxz_toast", {type="error", title="黑手", msg="至少需要2名有车的玩家"})
        return
    end
    startGame()
end

function onFukEndCmd(playerID, data)
    local name = MP.GetPlayerName(playerID)
    if not canControl(name) then
        MP.TriggerClientEventJson(playerID, "mxz_toast", {type="error", title="权限不足", msg="管理员在线，需要管理员身份"})
        return
    end
    if gameState == STATE.IDLE then return end
    -- 统一走 endGame(): 完整清理力场/油门/状态 (勿再内联, 否则会漏清力场)
    MP.SendChatMessage(-1, "[MXZ-黑手] 游戏被手动终止")
    endGame()
end

function onFukSetTimeCmd(playerID, data)
    local name = MP.GetPlayerName(playerID)
    if not canControl(name) then
        MP.TriggerClientEventJson(playerID, "mxz_toast", {type="error", title="权限不足", msg="管理员在线，需要管理员身份"})
        return
    end
    if gameState ~= STATE.IDLE then
        MP.TriggerClientEventJson(playerID, "mxz_toast", {type="error", title="黑手", msg="游戏进行中无法修改时长"})
        return
    end
    local mins = tonumber(data)
    if not mins or mins < 1 or mins > 60 then return end
    chaseTime = mins * 60
    MP.SendChatMessage(-1, "[MXZ-黑手] 追杀阶段时长已设为 " .. mins .. " 分钟")
    MP.TriggerClientEventJson(-1, "Fuk_GameState", {state = gameState, countdown = countdown, traitor = traitorName or "", chaseTime = chaseTime})
    broadcastState()
end
