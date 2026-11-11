-- Bounded asynchronous localhost transport. Only fixed, internally generated paths enter a shell.
local M = {}
local function quote(value) return "'" .. value:gsub("'", "'\\''") .. "'" end

function M.new(options)
    local io_, os_, Util = options.io or io, options.os or os, options.Util
    local self = {jobs={}, serial=0}
    local root = assert(options.root)
    assert(root:match("^[%w_./-]+$"), "unsafe transport directory")
    assert(options.base_url:match("^http://127%.0%.0%.1:%d+$"), "only localhost auth service is supported")
    assert(options.server:match("^[%w_-]+$"), "invalid server name")
    assert(type(options.token)=="string" and #options.token>=32 and options.token:match("^[%w_-]+$"), "missing per-server credential")
    assert(options.boot:match("^[%w_-]+$"), "invalid transport nonce")
    os_.execute("mkdir -p "..quote(root).." && chmod 700 "..quote(root))
    -- Recover files abandoned by an earlier reload/crash. Active requests are
    -- bounded to seconds; only our exact artifact names older than 10 minutes
    -- are eligible, and find does not follow symlinks.
    os_.execute("find "..quote(root).." -maxdepth 1 -regextype posix-extended -type f -mmin +10 -regex "..
        quote('.*/[A-Za-z0-9_-]+_[0-9]+[.](request|config|response|done|status)').." -delete >/dev/null 2>&1 &")
    local function write(path, text)
        local file = io_.open(path, "w")
        if not file then return false end
        file:write(text); file:close(); return true
    end
    local function read(path)
        local file = io_.open(path, "r")
        if not file then return nil end
        local text = file:read("*a"); file:close(); return text
    end
    local function clean(base)
        for _, ext in ipairs({".request", ".config", ".response", ".done", ".status"}) do os_.remove(base..ext) end
    end
    local function launch(base,job)
        for _,ext in ipairs({".response",".done",".status"})do os_.remove(base..ext)end
        job.started,job.retry_at=os_.time(),nil
        local command = "umask 077; curl --config "..quote(base..".config").." --data-binary "..quote("@"..base..".request")..
            " --output "..quote(base..".response").." --write-out '%{http_code}' > "..quote(base..".status")..
            " 2>/dev/null; mv "..quote(base..".status").." "..quote(base..".done")
        os_.execute("sh -c "..quote(command).." >/dev/null 2>&1 &")
    end
    function self:request(endpoint, data, callback)
        local count=0; for _ in pairs(self.jobs) do count=count+1 end
        if count >= 32 then callback({ok=false,code="AUTH_SERVICE_UNAVAILABLE",error="认证请求繁忙，请稍后重试"}); return false end
        assert(endpoint:match("^/api/game/[%w_/-]+$"), "invalid game endpoint")
        self.serial = self.serial + 1
        local base = root .. "/" .. options.boot .. "_" .. self.serial
        -- Tokens stay in protected config files, never curl process arguments or game state.
        local config = 'silent\nshow-error\nconnect-timeout = 1\nmax-time = 3\nrequest = "POST"\n' ..
            'url = "'..options.base_url..endpoint..'"\nheader = "Content-Type: application/json"\n' ..
            'header = "Authorization: Bearer '..options.token..'"\nheader = "X-MXZ-Server: '..options.server..'"\n'
        if not write(base..".request", Util.JsonEncode(data)) or not write(base..".config", config) then
            clean(base); callback({ok=false,code="AUTH_SERVICE_UNAVAILABLE",error="无法写入认证请求"}); return false
        end
        self.jobs[base] = {callback=callback, attempts=0}
        launch(base,self.jobs[base])
        return true
    end
    function self:poll()
        local completed = {}
        for base, job in pairs(self.jobs) do
            if job.retry_at then
                if os_.time()>=job.retry_at then launch(base,job)end
            else
            local status = read(base..".done")
            if status or os_.time()-job.started > 5 then
                local raw = status and read(base..".response")
                local success, result = pcall(Util.JsonDecode, raw or "")
                local code = tonumber(status)
                if not success or type(result)~="table" or type(result.ok)~="boolean" or
                        (result.ok and type(result.data)~="table") or not code or code < 200 or code >= 500 then
                    result = {ok=false,code="AUTH_SERVICE_UNAVAILABLE",error="认证服务暂时不可用，请稍后重试"}
                end
                if result.code=="AUTH_SERVICE_UNAVAILABLE" and job.attempts<2 then
                    job.attempts=job.attempts+1
                    job.retry_at=os_.time()+2^job.attempts
                else
                    completed[#completed+1] = {base=base, callback=job.callback, result=result}
                end
            end
            end
        end
        for _, job in ipairs(completed) do
            self.jobs[job.base] = nil; clean(job.base)
            job.callback(job.result)
        end
    end
    return self
end
return M
