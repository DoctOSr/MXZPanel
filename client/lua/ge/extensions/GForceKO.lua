-- GForceKO — 高G力昏迷/死亡系统 (GE 扩展)
-- G力来源: 每帧通过 queueLuaCommand 读取 Vehicle VM 中的 sensors.gx/gy/gz
local M = {}

-- 阈值: 10G 昏迷(1-10s) → ≥20G 死亡(30min)
local COMA_THRESHOLD  = 10
local DEATH_THRESHOLD = 20
local COMA_DUR_MIN    = 1
local COMA_DUR_MAX    = 10
local DEATH_DURATION  = 1800
local POST_COOLDOWN   = 1.5
local SUSTAIN_FRAMES  = 3

local isKnockedOut    = false
local isDead          = false
local pendingNotify   = nil  -- 延迟通知: {eventType, g} 或 nil
local knockoutTimer   = 0
local cooldownTimer   = 0
local sustainedFrames = 0
local sensorPending   = false
local lastVehicleId   = nil
local worldReady      = 0
local lastG           = 0   -- 最近一次计算的 G 值，供 UI 查询

local BLOCK_ACTIONS = {
    "accelerate", "brake", "accelerate_brake",
    "steer_left", "steer_right", "steering",
    "clutch", "parkingbrake",
    "shiftUp", "shiftDown",
    "gearR", "gear1", "gear2", "gear3", "gear4", "gear5", "gear6", "gear7", "gear8", "gearN",
    "toggleShifterMode", "activateStarterMotor",
}

-- ========== 输入屏蔽 ==========
local function setInputBlock(enable)
    if not extensions.core_input_actionFilter then return end
    pcall(function()
        extensions.core_input_actionFilter.setGroup("GForceKO", BLOCK_ACTIONS)
        extensions.core_input_actionFilter.addAction(0, "GForceKO", enable)
    end)
end

-- ========== 昏迷时长计算 ==========
local function comaDuration(g)
    if g >= DEATH_THRESHOLD then return DEATH_DURATION end
    local t = (g - COMA_THRESHOLD) / (DEATH_THRESHOLD - COMA_THRESHOLD)
    return COMA_DUR_MIN + t * (COMA_DUR_MAX - COMA_DUR_MIN)
end

-- ========== 服务端通知 ==========
-- 实际发送网络事件（仅在 onUpdate 主循环中调用）
local function doNotify(eventType)
    print("[GForceKO] doNotify: " .. eventType)
    if not TriggerServerEvent then
        print("[GForceKO] TriggerServerEvent is nil!")
        return
    end
    local data = eventType
    if eventType == "death" then
        local veh = be:getPlayerVehicle(0)
        if veh then
            local ok, p = pcall(veh.getPosition, veh)
            if ok and p then
                data = "death:" .. p.x .. "," .. p.y .. "," .. p.z
            end
        end
    end
    local ok, err = pcall(TriggerServerEvent, "gforce_knockout", data)
    if ok then
        print("[GForceKO] TriggerServerEvent OK: " .. data)
    else
        print("[GForceKO] TriggerServerEvent ERROR: " .. tostring(err))
    end
end

-- 从 _onSensors(VM回调) 中调用: 仅设标志, 由 onUpdate 延迟发送
-- 因为 VM 回调上下文中 TriggerServerEvent 不可靠
local function notifyServer(eventType)
    pendingNotify = eventType
end

-- ========== 死亡音效 ==========
local function createDeathSfx(pos)
    pcall(function()
        local obj = createObject("SFXEmitter")
        if not obj then return end
        obj.fileName = "art/sound/GForceKO/death_" .. math.random(0, 12) .. ".wav"
        obj.playOnAdd = true
        obj.isLooping = false
        obj.isStreaming = true
        obj.volume = 1.0  -- 音量倍率（音量由 wav 源文件控制；2026-08-01 曾降至12%，游戏修复 mod 音量 bug 后已还原为原始音量 wav）
        obj.is3D = true
        obj:setField("sourceGroup", 0, "AudioChannelOther")  -- 走"其他"通道，玩家可在设置里独立调节
        obj:setPosition(pos)
        obj:registerObject("GForceKO_death")
    end)
end

local function playDeathSound(veh)
    if not veh then return end
    createDeathSfx(veh:getPosition())
end

pcall(function()
    AddEventHandler("GForceKO_death_sfx", function(data)
        local x, y, z = data:match("([%d.-]+),([%d.-]+),([%d.-]+)")
        if x and y and z then
            createDeathSfx(vec3(tonumber(x), tonumber(y), tonumber(z)))
        end
    end)
end)

-- ========== 死亡时锁发动机 ==========
local function killEngine(v)
    if not v then return end
    pcall(function()
        local e = v:getElectrics()
        if e and e.values then e.values.ignition = 0 end
    end)
end

-- ========== 状态切换 ==========
local function startKnockout(g)
    local isDeath = g >= DEATH_THRESHOLD
    local dur = comaDuration(g)
    local veh = be:getPlayerVehicle(0)

    if isDeath then
        isDead = true
        killEngine(veh)
        playDeathSound(veh)
    else
        isKnockedOut = true
    end

    knockoutTimer   = dur
    sustainedFrames = 0
    setInputBlock(true)
    notifyServer(isDeath and "death" or "coma")

    local msg = isDeath
        and "你基米了！按 R 重置车辆"
        or string.format("你因强烈碰撞昏迷了！（%.0fG / %.0f秒）", g, dur)

    pcall(function()
        guihooks.trigger("toastrMsg", { type = "error", msg = msg, timeout = 4000 })
    end)
end

local function endKnockout()
    setInputBlock(false)
    isKnockedOut  = false
    cooldownTimer = POST_COOLDOWN
    sustainedFrames = 0
    pcall(function()
        guihooks.trigger("toastrMsg", { type = "info", msg = "你醒过来了！", timeout = 2000 })
    end)
end

local function endDeath()
    setInputBlock(false)
    isDead        = false
    cooldownTimer = POST_COOLDOWN
    sustainedFrames = 0
    pcall(function()
        guihooks.trigger("toastrMsg", { type = "info", msg = "车辆已重置", timeout = 2000 })
    end)
end

-- ========== 核心: 接收 Vehicle VM 回调的传感器原始值 ==========
-- 由 queueLuaCommand → obj:queueGameEngineLua 调用
function M._onSensors(gx, gy, gz)
    sensorPending = false

    -- 冷却/死亡期间忽略
    if cooldownTimer > 0 then return end
    if isDead then return end

    -- 合加速度 → G力 (m/s²)
    -- 注意: BeamNG sensors.gz 静止时为 -9.81 (负号), 所以要"加回"重力才是净冲击分量
    local gzAdj = gz + 9.81
    local g = math.sqrt(gx * gx + gy * gy + gzAdj * gzAdj) / 9.81
    lastG = g

    -- 昏迷中: 仅检测死亡升级
    if isKnockedOut then
        if g >= DEATH_THRESHOLD then
            isKnockedOut = false
            isDead = true
            knockoutTimer = DEATH_DURATION
            local v = be:getPlayerVehicle(0)
            killEngine(v)
            playDeathSound(v)
            notifyServer("death")
            pcall(function()
                guihooks.trigger("toastrMsg", { type = "error", msg = "你基米了！按 R 重置车辆", timeout = 4000 })
            end)
        end
        return
    end

    -- 正常状态: 持续帧数防抖
    if g >= COMA_THRESHOLD then
        sustainedFrames = sustainedFrames + 1
        if sustainedFrames >= SUSTAIN_FRAMES then
            startKnockout(g)
        end
    else
        sustainedFrames = 0
    end
end

-- ========== 服务端推送: 车辆重置解除昏迷/死亡 ==========
pcall(function()
    AddEventHandler("GForceKO_reset", function()
        sensorPending = false
        if isDead then endDeath() end
        if isKnockedOut then endKnockout() end
    end)
end)

-- ========== 生命周期 ==========
function M.onWorldReadyState(state)
    worldReady = state
end

-- 发送到 Vehicle VM 的传感器读取命令 (内联，无需外部文件)
local SENSOR_CMD = [[
    local s = sensors
    obj:queueGameEngineLua(string.format(
        "if GForceKO then GForceKO._onSensors(%f,%f,%f) end",
        s and s.gx or 0, s and s.gy or 0, s and s.gz or 0))
]]

function M.onUpdate(dt)
    if worldReady ~= 2 then return end

    local veh = be:getPlayerVehicle(0)
    -- 延迟通知: 即使无车辆也要处理(碰撞可能已销毁车辆)
    if pendingNotify then
        doNotify(pendingNotify)
        pendingNotify = nil
    end

    if not veh then
        if isKnockedOut then endKnockout() end
        if isDead then endDeath() end
        sustainedFrames = 0
        sensorPending = false
        return
    end

    -- 只检测自己拥有的车辆
    local isMine = true
    pcall(function()
        local id = veh:getID()
        if id then
            local mpveh = extensions and extensions.MPVehicleGE or MPVehicleGE
            if mpveh and mpveh.isOwn then isMine = mpveh.isOwn(id) end
        end
    end)
    if not isMine then return end

    -- 车辆变更 (刷新/重置) → 重置传感器管道, 防止旧车 VM 回调丢失导致死锁
    local vid = veh:getID()
    if vid ~= lastVehicleId then
        lastVehicleId = vid
        sensorPending = false
    end

    -- 死亡中: 倒计时 + 持续锁引擎 (不读传感器)
    if isDead then
        knockoutTimer = knockoutTimer - dt
        killEngine(veh)
        if knockoutTimer <= 0 then endDeath() end
        return
    end

    -- 昏迷中: 倒计时 (继续读传感器，用于死亡升级)
    if isKnockedOut then
        knockoutTimer = knockoutTimer - dt
        if knockoutTimer <= 0 then endKnockout() end
        -- 不 return, 继续走传感器读取
    end

    -- 冷却中: 跳过传感器读取
    if cooldownTimer > 0 then
        cooldownTimer = cooldownTimer - dt
        return
    end

    -- 每帧通过 queueLuaCommand 读取 Vehicle VM 中的 sensors 数据
    if not sensorPending then
        sensorPending = true
        local ok = pcall(function()
            veh:queueLuaCommand(SENSOR_CMD)
        end)
        if not ok then sensorPending = false end
    end
end

-- ========== 状态查询 (供 UI app 读取) ==========
function M.getState()
    return {
        isKnockedOut = isKnockedOut,
        isDead       = isDead,
        timer        = knockoutTimer,
        cooldown     = cooldownTimer,
        g            = lastG,
    }
end

-- ========== 测试接口 ==========
M.testComa = function()
    if isKnockedOut or isDead then return false end
    startKnockout(10)
    return true
end

M.testDeath = function()
    if isKnockedOut or isDead then return false end
    startKnockout(25)
    return true
end

_G.GForceKO = M
return M
