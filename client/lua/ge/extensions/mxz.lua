-- ============================================================
-- MXZ v4.0 — 冒险者服务器控制面板 (集成黑手游戏模式)
-- ============================================================

local M = {}
local im = ui_imgui
local ffi = require('ffi')

local roleCounts = {criminal=0, police_normal=0, police_heavy=0}
local myRole = nil
local players = {}
local groups = {}
local keyList = {}
local adminList = {}
local hasAdminOnline = false
local maxTier = 0
local myTier = 0
local isAdmin = false
local isVip = false
local myCodename = ""
local isLoggedIn = false
local myName = nil

-- Fuk state
local fukState = 0       -- 0=IDLE, 1=COUNTDOWN, 2=TRAITOR
local fukCountdown = 0
local fukTraitor = ""
local fukChaseTime = 300
local localTimer = 0

-- 洪水 state
local floodEnabled = false
local floodOceanLevel = 0
local floodSpeed = 0.001
local floodLimit = 0
local floodLimitEnabled = false
local floodDecrease = false
local floodIsOceanValid = true
local floodSpeedStr = "0.001"
local floodLimitStr = "0"

-- 传送后位置重置
local tpResetTimer = 0
local tpResetActive = false
local tpLastX, tpLastY, tpLastZ, tpLastH = 0, 0, 0, 0

local tp = {group="", idx=1}

local ROLE = {
    criminal      = {n="匪徒", c={0.9,0.2,0.2}},
    police_normal = {n="警员", c={0.2,0.5,1.0}},
    police_heavy  = {n="重型", c={0.2,0.85,0.3}},
}

-- ============== Events ==============

if MPGameNetwork then
    AddEventHandler("mxz_toast", function(data)
        local d = jsonDecode(data)
        if not d then return end
        guihooks.trigger("toastrMsg", {
            type = d.type or "info",
            title = d.title or "MXZ",
            msg = d.msg or "",
            config = { timeOut = tonumber(d.timeOut) or 4000 }
        })
    end)
    AddEventHandler("tp_teleport", function(data)
        local d = jsonDecode(data)
        if not d then return end
        local v = be:getPlayerVehicle(0)
        if not v then return end
        local y = tonumber(d.yaw) or 0; local h = math.rad(y)/2
        local x, yv, z = tonumber(d.x), tonumber(d.y), tonumber(d.z)
        v:setPositionRotation(x, yv, z, 0,0,-math.sin(h),math.cos(h))
        -- 300ms 后重设位置，防止重叠损伤
        tpLastX, tpLastY, tpLastZ = x, yv, z
        tpLastH = h
        tpResetTimer = 0.3
        tpResetActive = true
    end)
    AddEventHandler("tpg_stateUpdate", function(data)
        local s = jsonDecode(data)
        if not s then return end
        if s.roleCounts    then roleCounts    = s.roleCounts    end
        if s.myRole ~= nil then myRole        = s.myRole        end
        if s.players       then
            for _, info in pairs(s.players) do
                if info.isYou then myName = info.name; myCodename = info.displayName end
            end
            players = s.players
        end
        if s.groups         then groups         = s.groups         end
        if s.keyList        then keyList        = s.keyList        end
        if s.adminList      then adminList      = s.adminList      end
        if s.isAdmin ~= nil then isAdmin        = s.isAdmin        end
        if s.isVip   ~= nil then isVip          = s.isVip          end
        if s.tier    ~= nil then myTier         = s.tier           end
        if s.maxTier ~= nil then maxTier        = s.maxTier        end
        if s.isLoggedIn ~= nil then isLoggedIn  = s.isLoggedIn     end
        if s.hasAdminOnline ~= nil then hasAdminOnline = s.hasAdminOnline end
        if s.fukState ~= nil    then fukState    = s.fukState    end
        -- 力场清理由 onUpdate 统一处理 (fukState==0 时自动清), 此处不调用避免作用域问题
        -- Fuk倒计时优先本地计时器，只在非活跃时同步服务端值
        if s.fukCountdown ~= nil and fukState == 0 then fukCountdown = s.fukCountdown end
        if s.fukTraitor ~= nil and fukState == 0 then fukTraitor = s.fukTraitor end
        if s.fukChaseTime ~= nil then fukChaseTime = s.fukChaseTime end
        if s.floodEnabled ~= nil then floodEnabled = s.floodEnabled end
        if s.floodOceanLevel ~= nil then floodOceanLevel = s.floodOceanLevel end
        if s.floodSpeed ~= nil then floodSpeed = s.floodSpeed; floodSpeedStr = tostring(s.floodSpeed) end
        if s.floodLimit ~= nil then floodLimit = s.floodLimit; floodLimitStr = tostring(s.floodLimit) end
        if s.floodLimitEnabled ~= nil then floodLimitEnabled = s.floodLimitEnabled end
        if s.floodDecrease ~= nil then floodDecrease = s.floodDecrease end
        if s.floodIsOceanValid ~= nil then floodIsOceanValid = s.floodIsOceanValid end
    end)
end

-- ============== 3D Nametag ==============
local showTags = true
local playerTags = {}
local drawText = ffi and ffi.C and ffi.C.BNG_DBG_DRAW_TextAdvanced or nil
local TAG_FG_N   = color(100, 180, 255, 255)
local TAG_BG_N   = color(10, 50, 120, 220)
local TAG_FG_ADM = color(255, 140, 0, 255)      -- 管理员 橙
local TAG_BG_ADM = color(90, 50, 0, 220)
local TAG_FG_VIP = color(255, 215, 0, 255)      -- 舰长 金
local TAG_BG_VIP = color(90, 70, 0, 220)
local TAG_FG_T1  = color(167, 139, 250, 255)   -- 众筹 紫
local TAG_BG_T1  = color(50, 40, 90, 220)
local tagPos = vec3()

AddEventHandler("ka_nick", function(data)
    local p1 = (data or ""):find("|")
    if not p1 then return end
    local name = data:sub(1, p1 - 1)
    local rest = data:sub(p1 + 1)
    local p2 = rest:find("|")
    local codename, tier
    if p2 then
        codename = rest:sub(1, p2 - 1)
        tier = tonumber(rest:sub(p2 + 1)) or 0
    else
        codename = rest
        tier = 0
    end
    -- tier: 0=普通 1=管理员 2=VIP
    playerTags[name] = {codename = codename, tier = tier}
    if extensions and extensions.MPVehicleGE then
        extensions.MPVehicleGE.setPlayerNickPrefix(name, "mxz", "")
    end
end)

AddEventHandler("ka_rmnick", function(data)
    if data and data ~= "" then
        playerTags[data] = nil
        if extensions and extensions.MPVehicleGE then
            extensions.MPVehicleGE.setPlayerNickPrefix(data, "mxz", "")
        end
    end
end)

AddEventHandler("ka_tag", function()
    showTags = not showTags
    guihooks.trigger("toastrMsg", {
        type = "info", title = "悬浮标签: " .. (showTags and "ON" or "OFF"),
        msg = showTags and "标签已显示" or "标签已隐藏",
        config = { tapToDismiss = true, timeOut = 3000 }
    })
end)

-- ============== 洪水: Client Events ==============
local floodOcean = nil
local floodAllWater = {}

local function floodFindObject(objectName, className)
    local obj = scenetree.findObject(objectName)
    if obj then return obj end
    if not className then return nil end
    local objects = scenetree.findClassObjects(className)
    for _, name in pairs(objects) do
        if string.find(name, objectName) then return scenetree.findObject(name) end
    end
    return nil
end

local function floodGetWaterLevel()
    if not floodOcean then return nil end
    return floodOcean.position:getColumn(3).z
end

local floodCalledInit = false

local function floodTableToMatrix(tbl)
    local mat = MatrixF(true)
    mat:setColumn(0, tbl.c0)
    mat:setColumn(1, tbl.c1)
    mat:setColumn(2, tbl.c2)
    mat:setColumn(3, tbl.c3)
    return mat
end

AddEventHandler("E_OnPlayerLoaded", function()
    floodOcean = floodFindObject("Ocean", "WaterPlane")
    floodAllWater = {}
    local toSearch = {"River", "WaterBlock"}
    for _, cls in ipairs(toSearch) do
        local objects = scenetree.findClassObjects(cls)
        for _, id in pairs(objects) do
            local src = scenetree.findObject(id)
            if src then table.insert(floodAllWater, src) end
        end
    end
    local level = floodGetWaterLevel()
    if not floodCalledInit and level then
        floodCalledInit = true
        TriggerServerEvent("E_OnInitiliaze", tostring(level))
    end
end)

AddEventHandler("E_SetWaterLevel", function(level)
    level = tonumber(level) or nil
    if not level or not floodOcean then return end
    local c3 = floodOcean.position:getColumn(3)
    floodOcean.position = floodTableToMatrix({
        c0 = floodOcean.position:getColumn(0),
        c1 = floodOcean.position:getColumn(1),
        c2 = floodOcean.position:getColumn(2),
        c3 = vec3(c3.x, c3.y, level)
    })
end)


-- ============== Fuk: Client Events ==============
local playerColors = {}
local fukTraitorName = ""
-- 叛徒力场状态（同步自服务端）
local fukFF = { active = false, state = "idle", remain = 0 }
local fukFFTraitor = ""
local fukFFTimer = 0
local fukFFPrevActive = false
local FF_RADIUS = 5
local FF_MASS = -60000000000000
-- 质量点去重: 只有中心移动>0.5m 或车辆集合变化才重刷 setPlanets。
-- 否则每 0.05s 无条件替换 planet 会引发 UI 闪烁（与质量点刷新同步）。
local fukFFLastX, fukFFLastY, fukFFLastZ = nil, nil, nil
local fukFFLastSig, fukFFLastN = nil, 0
-- 叛徒油门上限 (追杀期间 0.85, 结束/换叛徒恢复 1)
local fukThrottleCap = nil
local throttleCapTimer = 0
local fukUITimer = 0

-- ============== Fuk UI App (fukStatus) 数据推送 ==============
-- 必须在事件处理器之前定义 (处理器里引用)
local function fukPushUI()
    if not guihooks then return end
    guihooks.trigger("fukStatus", {
        gameState = fukState,
        countdown = fukCountdown,
        ffState = fukFF.state,
        ffRemain = fukFF.remain,
    })
end

function M.getFukAppState()
    return {
        gameState = fukState,
        countdown = fukCountdown,
        ffState = fukFF.state,
        ffRemain = fukFF.remain,
    }
end
local isLocked = false
local spawnCooldown = 0
local MIN_SPAWN_INTERVAL = 3
local rainbowPlayers = {}
local rainbowTimer = 0
local TAG_FG_TR = color(255, 30, 30, 255)
local TAG_BG_TR = color(90, 0, 0, 220)

if MPGameNetwork then
    AddEventHandler("Fuk_SpawnVehicle", function(jsonStr)
        if not jsonStr or jsonStr == "" then return end
        local ok, data = pcall(jsonDecode, jsonStr)
        if not ok or not data then return end
        if not data.jbeam or data.jbeam == "" then return end
        local now = os.time()
        if now - spawnCooldown < MIN_SPAWN_INTERVAL then return end
        spawnCooldown = now
        local opts = { autoEnterVehicle = true }
        if data.pc then opts.config = data.pc end
        local veh = be:getPlayerVehicle(0)
        local fn = veh and core_vehicles.replaceVehicle or core_vehicles.spawnNewVehicle
        local ok2, err2 = pcall(fn, data.jbeam, opts)
        if not ok2 and data.pc and not data.pc:find("/") then
            opts.config = "vehicles/" .. data.jbeam .. "/" .. data.pc .. ".pc"
            ok2, err2 = pcall(fn, data.jbeam, opts)
        end
    end)

    AddEventHandler("Fuk_SetColor", function(data)
        local decoded = jsonDecode(data)
        if not decoded then return end
        local name = decoded.playerName
        if not name then return end
        playerColors[name] = { r=tonumber(decoded.r) or 0, g=tonumber(decoded.g) or 0, b=tonumber(decoded.b) or 0, a=tonumber(decoded.a) or 1 }
    end)

    AddEventHandler("Fuk_Lock", function(data)
        local decoded = jsonDecode(data)
        if not decoded then return end
        local newLocked = decoded.lock == true
        if newLocked == isLocked then return end
        isLocked = newLocked
        if isLocked then
            local veh = be:getPlayerVehicle(0)
            if veh then veh:queueLuaCommand("controller.setFreeze(1)"); veh:queueLuaCommand("electrics.setIgnitionLevel(0)"); veh:queueLuaCommand('input.event("parkingbrake", 1)') end
            core_input_actionFilter.addAction(0, "mxz_lockAll", true)
        else
            local veh = be:getPlayerVehicle(0)
            if veh then veh:queueLuaCommand("controller.setFreeze(0)") end
            core_input_actionFilter.addAction(0, "mxz_lockAll", false)
        end
    end)

    AddEventHandler("Fuk_Traitor", function(data)
        local decoded = jsonDecode(data)
        if not decoded then return end
        fukTraitorName = decoded.playerName or ""
    end)

    AddEventHandler("Fuk_ResetColors", function()
        playerColors = {}
    end)

    AddEventHandler("Fuk_Rainbow", function(data)
        local decoded = jsonDecode(data)
        if not decoded then return end
        if decoded.active then rainbowPlayers[decoded.playerName] = true
        else rainbowPlayers[decoded.playerName] = nil end
    end)

    AddEventHandler("Fuk_GameState", function(data)
        local d = jsonDecode(data)
        if not d then return end
        if d.state ~= nil then fukState = d.state end
        fukCountdown = tonumber(d.countdown) or fukCountdown
        if d.traitor then fukTraitor = d.traitor end
        if d.chaseTime then fukChaseTime = tonumber(d.chaseTime) or fukChaseTime end
        -- 重置本地计时器
        localTimer = fukCountdown
        fukPushUI()
    end)

    -- 叛徒力场: 状态仅由服务端每秒推送驱动，物理由 fukFFApply 在全员客户端执行
    AddEventHandler("Fuk_FFApply", function(data)
        local decoded = jsonDecode(data)
        if not decoded then return end
        fukFF.active = (decoded.active == true)
        fukFF.state = decoded.state or fukFF.state
        fukFF.remain = tonumber(decoded.remain) or fukFF.remain
        fukPushUI()
    end)

    -- 叛徒力场: 全体玩家收到，面板显示
    AddEventHandler("Fuk_FFStatus", function(data)
        local decoded = jsonDecode(data)
        if not decoded then return end
        fukFF.active = (decoded.active == true)
        fukFF.state = decoded.state or "idle"
        fukFF.remain = tonumber(decoded.remain) or 0
        if decoded.traitor then fukFFTraitor = decoded.traitor end
        fukPushUI()
    end)

    -- 叛徒油门限制: 仅叛徒收到, 钳制油门开度 (input.state.throttle.maxLimit)
    AddEventHandler("Fuk_ThrottleCap", function(data)
        local decoded = jsonDecode(data)
        if not decoded then return end
        fukThrottleCap = tonumber(decoded.cap) or 1
        local capVeh = be:getPlayerVehicle(0)
        if capVeh then capVeh:queueLuaCommand("input.state.throttle.maxLimit = " .. tostring(fukThrottleCap)) end
    end)
end

-- Fuk: 锁车输入过滤
core_input_actionFilter.setGroup("mxz_lockAll", {
    "recover_vehicle", "recover_vehicle_alt", "recover_to_last_road",
    "reset_physics", "reset_all_physics", "reload_vehicle", "reload_all_vehicles",
    "funBreak", "funHinges", "funTires", "funRandomTire",
    "funFire", "funExtinguish", "funBoom",
    "funFling", "funFlingDownward", "funBoost", "funBoostBackwards",
    "funSetFuelLevelFull", "SetFuelLevelFull",
    "funSetFuelLevelEmpty", "SetFuelLevelEmpty",
    "forceField", "editorToggle", "editorSafeModeToggle",
    "aiControls", "funStuff",
    "pause", "toggle_slow_motion", "slower_motion", "faster_motion",
    "latchesOpen", "latchesClose", "loadHome", "saveHome",
    "dropPlayerAtCamera", "dropPlayerAtCameraNoReset",
    "toggleCamera", "nodegrabberAction", "nodegrabberGrab", "nodegrabberRender",
})
core_input_actionFilter.addAction(0, "mxz_lockAll", false)

-- ============== Helpers ==============

local function roleBtn(label, role, cur, max, clr)
    local disabled = not isLoggedIn or (cur >= max and myRole ~= role)
    if disabled then im.BeginDisabled(true) end
    im.PushStyleColor2(im.Col_Button,       im.ImVec4(clr[1]*0.4,clr[2]*0.4,clr[3]*0.4,0.8))
    im.PushStyleColor2(im.Col_ButtonHovered,im.ImVec4(clr[1]*0.6,clr[2]*0.6,clr[3]*0.6,1.0))
    im.PushStyleColor2(im.Col_ButtonActive, im.ImVec4(clr[1]*0.7,clr[2]*0.7,clr[3]*0.7,1.0))
    if im.Button(label.." ("..cur.."/"..max..")", im.ImVec2(115,32)) then
        TriggerServerEvent("tpg_selectRole", jsonEncode({role=role}))
    end
    im.PopStyleColor(3)
    if disabled then im.EndDisabled() end
end

local function canControl()
    -- v5: 最高等级者掌控 (全普通时所有人)
    if maxTier <= 0 then return true end
    return myTier == maxTier
end

-- ============== 叛徒力场: 全员客户端统一应用 ==============
-- 内置 gameplay_forceField 只在本地模拟生效，别人看不到；这里让每个客户端都对
-- 自己的模拟施加同一力场（以叛徒车为中心推所有其他车），所有玩家看到的效果一致。
-- 参数照抄内置 forceField.lua: 半径5, 质量 -6e13 * 叛徒车尺寸系数
local function fukFFFindTraitorVehicle()
    if not MPVehicleGE then return nil end
    local vehicles = MPVehicleGE.getVehicles()
    if not vehicles then return nil end
    for _, v in pairs(vehicles) do
        if v.ownerName == fukFFTraitor and v.gameVehicleID then
            return v.gameVehicleID
        end
    end
    return nil
end

local function fukFFVehSignature()
    local sig, n = 0, 0
    if MPVehicleGE then
        local vs = MPVehicleGE.getVehicles()
        if vs then
            for _, v in pairs(vs) do
                sig = sig + (v.gameVehicleID or 0)
                n = n + 1
            end
        end
    end
    return sig, n
end

local function fukFFApply()
    local vid = fukFFFindTraitorVehicle()
    if not vid then
        -- 叛徒车消失(掉线/销毁): 清除残留质量点, 防止幽灵力场继续推人
        if fukFFPrevActive then fukFFClear() end
        return
    end
    -- getObjectOOBBCenterXYZ 返回三个 number (x,y,z)，不是 Point3F
    local okC, cx, cy, cz = pcall(function() return be:getObjectOOBBCenterXYZ(vid) end)
    if not okC or not cx or not cy or not cz then return end
    -- 去重: 质量点没动(>0.5m)且车辆集合没变 → 不重刷（planet 已生效, 无需替换）
    local sig, n = fukFFVehSignature()
    if fukFFLastX ~= nil then
        local dx, dy, dz = cx - fukFFLastX, cy - fukFFLastY, cz - fukFFLastZ
        if dx*dx + dy*dy + dz*dz <= 0.25 and sig == fukFFLastSig and n == fukFFLastN then
            fukFFPrevActive = true
            return
        end
    end
    fukFFLastX, fukFFLastY, fukFFLastZ = cx, cy, cz
    fukFFLastSig, fukFFLastN = sig, n
    -- 尺寸系数: 叛徒车 OOBB 最长半轴/3（与内置一致），失败则用 1
    local sizeFactor = 1
    local veh = getObjectByID(vid)
    if veh and veh.getSpawnWorldOOBB then
        local okB, bb = pcall(function() return veh:getSpawnWorldOOBB() end)
        if okB and bb and bb.getHalfExtents then
            local h = bb:getHalfExtents()
            sizeFactor = math.max(math.max(h.x, h.y), h.z) / 3
        end
    end
    local cmd = string.format('obj:setPlanets({%f, %f, %f, %d, %f})', cx, cy, cz, FF_RADIUS, FF_MASS * sizeFactor)
    for i = 0, be:getObjectCount() - 1 do
        local obj = be:getObject(i)
        if obj and obj.getId and obj:getId() ~= vid then
            obj:queueLuaCommand(cmd)
        end
    end
    fukFFPrevActive = true
end

local function fukFFClear()
    for i = 0, be:getObjectCount() - 1 do
        local obj = be:getObject(i)
        if obj and obj.queueLuaCommand then obj:queueLuaCommand("obj:setPlanets({})") end
    end
    fukFFLastX, fukFFLastY, fukFFLastZ = nil, nil, nil
    fukFFLastSig, fukFFLastN = nil, 0
    fukFFPrevActive = false
end

-- ============== Draw ==============

local worldReady = 0
M.onWorldReadyState = function(s) worldReady = s end

-- ===== 里程统计 (v7)：位置差分采样，≥500m 或 60s 兜底上报服务端 =====
local odoTimer, odoReport = 0, 0
local odoPending = 0        -- 未上报里程（米）
local odoLastPos = nil
local odoLastVeh = -1

function M.onUpdate(dt)
    -- 里程采样：0.25s 位置差分；跳变 >60m 视为传送/重置，不计
    odoTimer = odoTimer + dt
    if odoTimer >= 0.25 then
        odoTimer = 0
        local veh = be:getPlayerVehicle(0)
        if veh then
            local okP, pos = pcall(veh.getPosition, veh)
            local vid = veh:getId()
            if okP and pos then
                if odoLastPos and odoLastVeh == vid then
                    local d = (pos - odoLastPos):length()
                    if d < 60 then odoPending = odoPending + d end
                end
                odoLastPos = pos
                odoLastVeh = vid
            end
        else
            odoLastPos = nil
        end
        odoReport = odoReport + 0.25
        if odoPending >= 500 or (odoPending >= 20 and odoReport >= 60) then
            if TriggerServerEvent then
                pcall(TriggerServerEvent, "mxz_dist", string.format("%.1f", odoPending))
            end
            odoPending = 0
            odoReport = 0
        end
    end

    -- 叛徒力场: 全员客户端统一应用（以叛徒车为中心推所有其他车，0.05s 一次）
    -- 门控: 仅追杀阶段(fukState==2)且力场激活时施加; 任何其他状态(含漏收 idle 事件)
    -- 都会触发 fukFFClear 清空质量点 —— 兜住所有结束路径
    if fukFF.state == "active" and fukState == 2 then
        fukFFTimer = fukFFTimer + dt
        if fukFFTimer >= 0.05 then
            fukFFTimer = 0
            pcall(fukFFApply)
        end
    elseif fukFFPrevActive then
        fukFFClear()
    end

    -- 叛徒油门上限自愈 (切车/重置后 0.5s 内重设)
    if fukThrottleCap and fukThrottleCap < 1 then
        throttleCapTimer = throttleCapTimer + dt
        if throttleCapTimer >= 0.5 then
            throttleCapTimer = 0
            local capVeh = be:getPlayerVehicle(0)
            if capVeh then capVeh:queueLuaCommand("input.state.throttle.maxLimit = " .. tostring(fukThrottleCap)) end
        end
    end

    -- Fuk UI App 推送 (0.5s 节流, 覆盖本地倒计时跳动)
    fukUITimer = fukUITimer + dt
    if fukUITimer >= 0.5 then
        fukUITimer = 0
        fukPushUI()
    end

    -- 本地 Fuk 倒计时
    if fukState ~= 0 and localTimer > 0 then
        localTimer = localTimer - dt
        fukCountdown = math.max(0, math.floor(localTimer + 0.5))
    end

    -- 传送后位置重置 (300ms 延迟)
    if tpResetActive then
        tpResetTimer = tpResetTimer - dt
        if tpResetTimer <= 0 then
            tpResetActive = false
            local v = be:getPlayerVehicle(0)
            if v then v:setPositionRotation(tpLastX, tpLastY, tpLastZ, 0,0,-math.sin(tpLastH),math.cos(tpLastH)) end
        end
    end

    im.SetNextWindowSize(im.ImVec2(460, 620), im.Cond_FirstUseEver)
    im.SetNextWindowPos(im.ImVec2(50, 50), im.Cond_FirstUseEver)

    -- v5: 窗口按身份着色 — 管理员橙/舰长金/众筹紫/普通白
    local TIER_NAME = { "【普通】", "【众筹】", "【舰长】", "【管理员】" }
    local TIER_COL  = {
        im.ImVec4(0.9, 0.9, 0.95, 1.0),  -- 普通 白
        im.ImVec4(0.77, 0.55, 0.98, 1.0), -- 众筹 紫
        im.ImVec4(1.0, 0.84, 0.0, 1.0),   -- 舰长 金
        im.ImVec4(1.0, 0.55, 0.05, 1.0),  -- 管理员 橙
    }
    local TIER_BG  = {
        im.ImVec4(0.15, 0.15, 0.75, 0.5),
        im.ImVec4(0.35, 0.2, 0.6, 0.6),
        im.ImVec4(0.45, 0.35, 0.05, 0.6),
        im.ImVec4(0.45, 0.22, 0.05, 0.6),
    }
    local myTierC = (myTier >= 0 and myTier <= 3) and myTier or 0
    local selfColor = TIER_COL[myTierC + 1]
    local titleBg   = TIER_BG[myTierC + 1]

    im.PushStyleColor2(im.Col_TitleBg,       titleBg)
    im.PushStyleColor2(im.Col_TitleBgActive, titleBg)
    im.PushStyleColor2(im.Col_Button,        im.ImVec4(0.15,0.15,0.75,0.333))
    im.PushStyleColor2(im.Col_ButtonHovered, im.ImVec4(0.1,0.1,0.69,0.5))
    im.PushStyleColor2(im.Col_ButtonActive,  im.ImVec4(0.05,0.05,0.55,0.999))
    im.PushStyleColor2(im.Col_FrameBg,       im.ImVec4(0,0,0.33,0.5))
    im.PushStyleColor2(im.Col_Tab,           im.ImVec4(0.33,0.33,1,0.5))
    im.PushStyleColor2(im.Col_TabActive,     im.ImVec4(0.125,0.125,1,0.5))
    im.PushStyleColor2(im.Col_Header,        im.ImVec4(0.25,0.25,0.5,0.5))
    im.PushStyleColor2(im.Col_Separator,     im.ImVec4(0.66,0.66,0.95,0.75))
    im.SetNextWindowBgAlpha(0.75)

    -- 标题文字颜色跟随身份 (Begin 前 push, Begin 后立即 pop, 只影响标题栏)
    if myTierC > 0 then
        im.PushStyleColor2(im.Col_Text, selfColor)
    end

    if not im.Begin("mxz_Server control_v1.0") then im.End(); im.PopStyleColor(10); if myTierC > 0 then im.PopStyleColor(1) end; return end

    if myTierC > 0 then
        im.PopStyleColor(1)
    end

    -- 顶部身份行 (自身 名字/备注 + 身份标签)
    im.TextColored(selfColor, TIER_NAME[myTierC + 1] .. " " .. (myCodename ~= "" and myCodename or myName or ""))
    im.Separator()

    local a = (roleCounts.criminal or 0)+(roleCounts.police_normal or 0)+(roleCounts.police_heavy or 0)
    local pc = 0; for _ in pairs(players) do pc = pc+1 end
    im.Text("在线:"..pc.." 已分配:"..a)

    if im.BeginTabBar("tabs") then

        -- ====== Tab 1: 职业 ======
        if im.BeginTabItem("职业") then
            im.Spacing()
            if not isLoggedIn then
                im.TextColored(im.ImVec4(1.0,0.85,0.3,1.0), "请先在聊天输入 /activate <卡密> 登录")
                im.Spacing()
            end

            roleBtn("匪徒","criminal",roleCounts.criminal or 0,1,ROLE.criminal.c); im.SameLine()
            roleBtn("警员","police_normal",roleCounts.police_normal or 0,8,ROLE.police_normal.c); im.SameLine()
            roleBtn("重型","police_heavy",roleCounts.police_heavy or 0,1,ROLE.police_heavy.c)

            if myRole then
                im.SameLine()
                im.PushStyleColor2(im.Col_Button, im.ImVec4(0.6,0.3,0.1,0.7))
                if im.SmallButton("辞职") then
                    if myName then TriggerServerEvent("tpg_removeRole", myName) end
                end
                im.PopStyleColor(1)
            end

            im.Separator()
            im.Text("玩家列表:")

            local arr = {}
            for k, info in pairs(players) do arr[info.name or k] = info end
            local pa = {}; for _, v in pairs(arr) do pa[#pa+1]=v end
            table.sort(pa, function(a,b)
                if (a.role or "z") ~= (b.role or "z") then return (a.role or "z") < (b.role or "z") end
                if a.isLoggedIn ~= b.isLoggedIn then return a.isLoggedIn end
                return (a.displayName or a.name or "") < (b.displayName or b.name or "")
            end)

            if #pa == 0 then
                im.TextColored(im.ImVec4(0.5,0.5,0.5,1.0), "  (暂无)")
            else
                im.BeginChild1("pl", im.ImVec2(0,220), true)
                for _,info in ipairs(pa) do
                    if info.isLoggedIn and info.displayName then
                        local itier = info.tier or 0
                        if itier == 3 then
                            im.TextColored(im.ImVec4(1.0,0.55,0.05,1.0), info.displayName)  -- 管理员 橙
                        elseif itier == 2 then
                            im.TextColored(im.ImVec4(1.0,0.84,0.0,1.0), info.displayName)    -- 舰长 金
                        elseif itier == 1 then
                            im.TextColored(im.ImVec4(0.77,0.55,0.98,1.0), info.displayName)  -- 众筹 紫
                        else
                            im.TextColored(im.ImVec4(0.55,0.75,0.98,1.0), info.displayName)  -- 普通 蓝
                        end
                        im.SameLine()
                        im.TextColored(im.ImVec4(0.4,0.4,0.4,1.0), " ("..(info.name or "?")..")")
                    else
                        im.Text(info.name or "?")
                        im.SameLine()
                        im.TextColored(im.ImVec4(0.5,0.3,0.3,1.0), " (未激活)")
                    end
                    if info.isYou then im.SameLine(); im.TextColored(im.ImVec4(0.4,0.7,1.0,1.0), " (你)") end

                    im.SameLine(290)
                    if info.role then
                        local m = ROLE[info.role]
                        if m then im.TextColored(im.ImVec4(m.c[1],m.c[2],m.c[3],1.0), m.n) end
                    else im.TextColored(im.ImVec4(0.4,0.4,0.4,1.0), "-") end

                    if info.role and not info.isYou and isAdmin then
                        im.SameLine(360)
                        im.PushStyleColor2(im.Col_Button, im.ImVec4(0.8,0.2,0.1,0.5))
                        if im.SmallButton("移除##rm_"..(info.name or "")) then
                            TriggerServerEvent("tpg_removeRole", info.name)
                        end
                        im.PopStyleColor(1)
                    end
                end
                im.EndChild()
            end
            im.EndTabItem()
        end

        -- ====== Tab 2: 传送 ======
        if im.BeginTabItem("传送") then
            im.Spacing()

            if not isLoggedIn then
                im.TextColored(im.ImVec4(1.0,0.85,0.3,1.0), "请先用 /activate <卡密> 登录")
            else
                local gn = {}; for gname,_ in pairs(groups) do gn[#gn+1]=gname end
                table.sort(gn)

                if #gn == 0 then
                    im.TextColored(im.ImVec4(0.5,0.5,0.5,1.0), "暂无编组数据")
                else
                    if tp.group=="" or not groups[tp.group] then tp.group=gn[1]; tp.idx=1 end

                im.Text("编组:")
                im.BeginChild1("grp", im.ImVec2(0, 80), true)
                for _,gname in ipairs(gn) do
                    local sel = (tp.group == gname)
                    if sel then im.PushStyleColor2(im.Col_Button, im.ImVec4(0.2,0.55,0.2,0.7)) end
                    if im.SmallButton(gname) then tp.group = gname; tp.idx = 1 end
                    if sel then im.PopStyleColor(1) end
                end
                im.EndChild()
                im.Spacing()

                if canControl() then
                    im.PushStyleColor2(im.Col_Button,       im.ImVec4(0.15,0.55,0.15,0.7))
                    im.PushStyleColor2(im.Col_ButtonHovered,im.ImVec4(0.2,0.65,0.2,0.85))
                    im.PushStyleColor2(im.Col_ButtonActive, im.ImVec4(0.1,0.5,0.1,0.95))
                    if im.Button("传送 "..tp.group.." 所有人", im.ImVec2(400,40)) then
                        TriggerServerEvent("tpg_teleportAll", jsonEncode({group=tp.group}))
                    end
                    im.PopStyleColor(3)
                else
                    im.TextColored(im.ImVec4(0.6,0.4,0.1,1.0), "管理员在线，传送所有人需要管理员权限")
                end

                im.Separator()

                if canControl() then
                    im.Text("自传坐标:")
                    local mp = groups[tp.group] or 10
                    for i=1,mp do
                        if i==1 then im.SameLine() end
                        local ksel = (tp.idx == i)
                        if ksel then im.PushStyleColor2(im.Col_Button, im.ImVec4(0.2,0.6,0.2,0.7)) end
                        if im.SmallButton(tostring(i).."##tpself"..i) then tp.idx = i end
                        if ksel then im.PopStyleColor(1) end
                        im.SameLine()
                    end
                    im.Spacing()
                    if im.Button("传至 "..tp.group.." #"..tp.idx, im.ImVec2(400,28)) then
                        TriggerServerEvent("tpg_adminTeleport", jsonEncode({group=tp.group, index=tp.idx}))
                    end
                else
                    im.TextColored(im.ImVec4(0.6,0.4,0.1,1.0), "管理员在线，自传需要管理员权限")
                end
                im.TextColored(im.ImVec4(0.4,0.4,0.5,1.0), "1-8:警员  9:重型  10:匪徒")
                end
            end
            im.EndTabItem()
        end

        -- ====== Tab 3: 黑手 ======
        if im.BeginTabItem("黑手") then
            im.Spacing()

            -- 状态显示
            local statusText = "空闲"
            local statusColor = im.ImVec4(0.4,0.8,0.4,1.0)
            if fukState == 1 then
                statusText = "倒计时: " .. math.floor(fukCountdown) .. "s"
                statusColor = im.ImVec4(1.0,0.85,0.2,1.0)
            elseif fukState == 2 then
                local min = math.floor(fukCountdown / 60)
                local sec = fukCountdown % 60
                statusText = "追杀中: " .. min .. ":" .. string.format("%02d", sec)
                statusColor = im.ImVec4(1.0,0.2,0.2,1.0)
                if fukTraitor ~= "" then
                    im.SameLine()
                    im.Text("叛徒: " .. fukTraitor)
                end
            end
            im.Text("状态: "); im.SameLine()
            im.TextColored(statusColor, statusText)
            -- 叛徒力场状态 (同步自服务端)
            im.Text("力场: "); im.SameLine()
            if fukState == 2 and fukFF.state == "active" then
                im.TextColored(im.ImVec4(1.0,0.3,0.2,1.0), "激活中 (剩 " .. fukFF.remain .. "s)")
            elseif fukState == 2 and fukFF.state == "cooldown" then
                im.TextColored(im.ImVec4(0.6,0.6,0.6,1.0), "冷却中 (还需 " .. fukFF.remain .. "s)")
            elseif fukState == 2 then
                im.TextColored(im.ImVec4(0.4,0.4,0.4,1.0), "未开启")
            else
                im.TextColored(im.ImVec4(0.4,0.4,0.4,1.0), "—")
            end
            im.Spacing()

            local isInGame = (fukState ~= 0)
            local noPerm = not canControl()

            -- 刷车按钮 (按组别)
            im.Text("全员刷车:")
            local spawnBtns = {
                {label="高速组", pool="high", r=0.15, g=0.55, b=0.35},
                {label="正常组", pool="normal", r=0.15, g=0.6, b=0.5},
                {label="老爷爷组", pool="grandpa", r=0.6, g=0.4, b=0.15},
                {label="所有组别", pool="all", r=0.15, g=0.4, b=0.6},
            }
            for i, btn in ipairs(spawnBtns) do
                if noPerm then im.BeginDisabled(true) end
                im.PushStyleColor2(im.Col_Button, im.ImVec4(btn.r, btn.g, btn.b, 0.7))
                im.PushStyleColor2(im.Col_ButtonHovered, im.ImVec4(btn.r+0.05, btn.g+0.1, btn.b+0.1, 0.85))
                if im.Button(btn.label, im.ImVec2(195, 30)) then
                    TriggerServerEvent("Fuk_SpawnVehicle_Cmd", jsonEncode({pool = btn.pool}))
                end
                im.PopStyleColor(2)
                if noPerm then im.EndDisabled() end
                if i % 2 == 1 then im.SameLine() end
            end
            im.Spacing()

            -- 开始/结束游戏
            if noPerm then im.BeginDisabled(true) end
            if isInGame then
                im.PushStyleColor2(im.Col_Button, im.ImVec4(0.65,0.15,0.15,0.7))
                im.PushStyleColor2(im.Col_ButtonHovered, im.ImVec4(0.75,0.2,0.2,0.85))
                if im.Button("结束游戏", im.ImVec2(400,40)) then
                    TriggerServerEvent("Fuk_End_Cmd", "")
                end
                im.PopStyleColor(2)
            else
                im.PushStyleColor2(im.Col_Button, im.ImVec4(0.15,0.55,0.15,0.7))
                im.PushStyleColor2(im.Col_ButtonHovered, im.ImVec4(0.2,0.65,0.2,0.85))
                im.PushStyleColor2(im.Col_ButtonActive, im.ImVec4(0.1,0.5,0.1,0.95))
                if im.Button("开始黑手", im.ImVec2(400,40)) then
                    TriggerServerEvent("Fuk_Start_Cmd", "")
                end
                im.PopStyleColor(3)
            end
            if noPerm then im.EndDisabled() end
            im.Spacing()

            im.Separator()
            im.Text("追杀时长 (分钟):")
            local presets = {1, 3, 5, 10, 15, 30}
            local chaseMins = math.floor((fukChaseTime or 300) / 60 + 0.5)
            if chaseMins < 1 then chaseMins = 1 elseif chaseMins > 60 then chaseMins = 60 end
            for _, p in ipairs(presets) do
                local isActive = (chaseMins == p)
                if noPerm or isInGame then im.BeginDisabled(true) end
                if isActive then
                    im.PushStyleColor2(im.Col_Button, im.ImVec4(0.2, 0.6, 0.2, 0.7))
                else
                    im.PushStyleColor2(im.Col_Button, im.ImVec4(0.15, 0.35, 0.55, 0.5))
                end
                if im.SmallButton(tostring(p)) then
                    fukChaseTime = p * 60
                    chaseMins = p
                    TriggerServerEvent("Fuk_SetTime_Cmd", tostring(p))
                end
                im.PopStyleColor(1)
                if noPerm or isInGame then im.EndDisabled() end
                im.SameLine()
            end
            im.Text("")  -- 换行

            im.EndTabItem()
        end

        -- ====== Tab 4: 洪水 ======
        if im.BeginTabItem("洪水") then
            im.Spacing()

            -- Re-scan ocean on tab open
            if not floodOcean then
                floodOcean = floodFindObject("Ocean", "WaterPlane")
                if floodOcean and not floodCalledInit then
                    floodCalledInit = true
                    TriggerServerEvent("E_OnInitiliaze", tostring(floodGetWaterLevel()))
                end
            end

            local noPerm = not canControl()
            local noOcean = not floodIsOceanValid

            -- 状态
            if noOcean then
                im.TextColored(im.ImVec4(1.0,0.4,0.2,1.0), "此地图无海洋，洪水不可用")
            else
                local statusText = floodEnabled and "运行中" or "已停止"
                local statusColor = floodEnabled and im.ImVec4(1.0,0.3,0.2,1.0) or im.ImVec4(0.4,0.8,0.4,1.0)
                im.Text("状态: "); im.SameLine()
                im.TextColored(statusColor, statusText)
                im.SameLine(200)
                im.Text("水位: " .. string.format("%.2f", floodOceanLevel))
            end
            im.Spacing()

            -- 开始/停止/重置
            if noPerm or noOcean then im.BeginDisabled(true) end
            im.PushStyleColor2(im.Col_Button, im.ImVec4(0.15,0.55,0.15,0.7))
            im.PushStyleColor2(im.Col_ButtonHovered, im.ImVec4(0.2,0.65,0.2,0.85))
            if im.Button("开始涨水", im.ImVec2(128, 30)) then
                TriggerServerEvent("Flood_Start", "")
            end
            im.PopStyleColor(2)
            im.SameLine()
            im.PushStyleColor2(im.Col_Button, im.ImVec4(0.65,0.15,0.15,0.7))
            im.PushStyleColor2(im.Col_ButtonHovered, im.ImVec4(0.75,0.2,0.2,0.85))
            if im.Button("停止", im.ImVec2(128, 30)) then
                TriggerServerEvent("Flood_Stop", "")
            end
            im.PopStyleColor(2)
            im.SameLine()
            im.PushStyleColor2(im.Col_Button, im.ImVec4(0.6,0.4,0.15,0.7))
            im.PushStyleColor2(im.Col_ButtonHovered, im.ImVec4(0.7,0.5,0.2,0.85))
            if im.Button("重置", im.ImVec2(128, 30)) then
                TriggerServerEvent("Flood_Reset", "")
            end
            im.PopStyleColor(2)
            if noPerm or noOcean then im.EndDisabled() end
            im.Spacing()

            -- 速度
            im.Text("速度 (x0.001):")
            if noPerm or noOcean then im.BeginDisabled(true) end
            im.SetNextItemWidth(120)
            local speedBuf = ffi.new("char[32]", floodSpeedStr)
            if im.InputText("##floodSpeed", speedBuf, 32) then
                floodSpeedStr = ffi.string(speedBuf)
            end
            im.SameLine()
            if im.SmallButton("确定##spd") then
                local v = tonumber(floodSpeedStr)
                if v and v > 0 then TriggerServerEvent("Flood_SetSpeed", floodSpeedStr) end
            end
            if noPerm or noOcean then im.EndDisabled() end
            im.Spacing()

            -- 水位上限
            im.Text("水位上限:")
            if noPerm or noOcean then im.BeginDisabled(true) end
            im.SetNextItemWidth(120)
            local limitBuf = ffi.new("char[32]", floodLimitStr)
            if im.InputText("##floodLimit", limitBuf, 32) then
                floodLimitStr = ffi.string(limitBuf)
            end
            im.SameLine()
            if im.SmallButton("确定##lim") then
                local v = tonumber(floodLimitStr)
                if v then TriggerServerEvent("Flood_SetLimit", floodLimitStr) end
            end
            im.SameLine()
            local limitLabel = floodLimitEnabled and "上限:开" or "上限:关"
            if im.SmallButton(limitLabel .. "##togLim") then
                TriggerServerEvent("Flood_SetLimitEnabled", "")
            end
            if noPerm or noOcean then im.EndDisabled() end
            im.Spacing()

            -- 退水模式
            im.Text("模式: " .. (floodDecrease and "退水" or "涨水"))
            im.SameLine()
            if noPerm or noOcean then im.BeginDisabled(true) end
            if im.SmallButton(floodDecrease and "切为涨水" or "切为退水") then
                TriggerServerEvent("Flood_SetDecrease", "")
            end
            if noPerm or noOcean then im.EndDisabled() end

            im.EndTabItem()
        end

        im.EndTabBar()
    end

    im.End()
    im.PopStyleColor(10)
end

-- ============== 3D Nametag (MXZ + 黑手 traitor) ==============
local _lastLockedVehID = nil

M.onPreRender = function(dt)
    if not drawText then return end
    local vehicles = MPVehicleGE and MPVehicleGE.getVehicles()
    if not vehicles then return end
    for _, v in pairs(vehicles) do
        local vid = v.gameVehicleID
        if not vid then goto c end
        local veh = getObjectByID(vid)
        if not veh then goto c end

        -- Fuk 上色
        local color = playerColors[v.ownerName]
        if color then
            local cc = Point4F(color.r, color.g, color.b, color.a)
            veh.color = cc; veh.colorPalette0 = cc; veh.colorPalette1 = cc
        end

        -- 流光灯
        if rainbowPlayers[v.ownerName] then
            local t = rainbowTimer * 4
            local r = (math.sin(t) + 1) / 2
            local g = (math.sin(t + 2.094) + 1) / 2
            local b = (math.sin(t + 4.189) + 1) / 2
            local rc = Point4F(r, g, b, 1)
            veh.color = rc; veh.colorPalette0 = rc; veh.colorPalette1 = rc
        end

        -- 叛徒标签
        if fukTraitorName ~= "" and v.ownerName == fukTraitorName then
            tagPos:set(be:getObjectOOBBCenterXYZ(vid))
            local h = v.vehicleHeight
            if not h or h == 0 then
                if veh.getInitialHeight then h = veh:getInitialHeight(); v.vehicleHeight = h end
            end
            tagPos.z = tagPos.z + 6
            drawText(tagPos.x, tagPos.y, tagPos.z, String(" 叛徒 "), TAG_FG_TR, true, false, TAG_BG_TR, false, false)
        end

        -- MXZ nametag
        if not showTags then goto c end
        -- tier 优先 ka_nick, 兜底用 tpg_stateUpdate 的 players 状态表 (每次进出服/激活全量刷新, 不会漏)
        local t = playerTags[v.ownerName]
        local nmCodename = t and t.codename
        local nmTier = t and t.tier
        local pi = players and players[v.ownerName]
        if nmTier == nil and pi and pi.isLoggedIn then
            nmTier = pi.tier or 0
            nmCodename = nmCodename or pi.displayName
        end
        if nmCodename then
            tagPos:set(be:getObjectOOBBCenterXYZ(vid))
            local h = v.vehicleHeight
            if not h or h == 0 then
                if veh.getInitialHeight then h = veh:getInitialHeight(); v.vehicleHeight = h end
            end
            tagPos.z = tagPos.z + 6
            -- v5: tier 0=普通(蓝) 1=众筹(紫) 2=舰长(金) 3=管理员(橙)
            local fg, bg = TAG_FG_N, TAG_BG_N
            if nmTier == 1 then fg, bg = TAG_FG_T1, TAG_BG_T1          -- 众筹 紫
            elseif nmTier == 2 then fg, bg = TAG_FG_VIP, TAG_BG_VIP    -- 舰长 金
            elseif nmTier == 3 then fg, bg = TAG_FG_ADM, TAG_BG_ADM    -- 管理员 橙
            end
            drawText(tagPos.x, tagPos.y, tagPos.z, String(" [" .. nmCodename .. "] "), fg, true, false, bg, false, false)
        end
        ::c::
    end

    -- 驱动流光计时器
    if next(rainbowPlayers) ~= nil then rainbowTimer = rainbowTimer + dt end

    -- 锁车
    if isLocked then
        local veh = be:getPlayerVehicle(0)
        if veh then
            local vid = veh:getID()
            if vid ~= _lastLockedVehID then
                veh:queueLuaCommand("controller.setFreeze(1)")
                veh:queueLuaCommand("electrics.setIgnitionLevel(0)")
                veh:queueLuaCommand('input.event("parkingbrake", 1)')
                _lastLockedVehID = vid
            end
        end
    elseif _lastLockedVehID then
        _lastLockedVehID = nil
    end
end

-- ============== Fuk UI App 布局注入 (fukStatus) ==============
local FUK_UI_APP = "fukStatus"
local FUK_UI_LAYOUTS = {
    "settings/ui_apps/layouts/default/multiplayer.uilayout.json",
    "settings/ui_apps/layouts/default/beammp.uilayout.json",
}
local fukUILayoutOriginals = {}   -- [layoutPath] = 注入前的文件内容

local function ensureFukAppInLayout()
    for _, layoutPath in ipairs(FUK_UI_LAYOUTS) do
        local content = jsonReadFile(layoutPath)
        if type(content) ~= "table" then
            log("W", "mxz", "无法读取布局文件: " .. tostring(layoutPath))
        else
            if fukUILayoutOriginals[layoutPath] == nil then
                -- 深拷贝（jsonEncode/jsonDecode），避免后续 table.insert 就地改同一引用导致还原无效
                fukUILayoutOriginals[layoutPath] = jsonDecode(jsonEncode(content))
            end
            content.apps = content.apps or {}
            local found = false
            for _, app in ipairs(content.apps) do
                if app.appName == FUK_UI_APP then found = true break end
            end
            if not found then
                table.insert(content.apps, {
                    appName = FUK_UI_APP,
                    placement = {
                        top = "12%", left = 0, right = 0,
                        width = "420px", height = "90px",
                        margin = "auto", position = "absolute"
                    }
                })
                jsonWriteFile(layoutPath, content, 1)
                log("I", "mxz", "已将 fukStatus App 注入布局: " .. layoutPath)
            end
        end
    end
end

local function restoreFukLayouts()
    for layoutPath, content in pairs(fukUILayoutOriginals) do
        jsonWriteFile(layoutPath, content, 1)
        log("I", "mxz", "已还原布局: " .. layoutPath)
    end
    fukUILayoutOriginals = {}
end

function M.onExtensionLoaded()
    log("W","mxz","v4.0 loaded (MXZ + 黑手)")
    ensureFukAppInLayout()
    guihooks.trigger("toastrMsg", {
        type = "info", title = "控制面板已就绪",
        msg = "mxz_Server control v1.0 已自动打开 (v4.0)",
        config = { timeOut = 4000 }
    })
end
function M.onExtensionUnloaded()
    fukFFClear()
    restoreFukLayouts()
end

return M
