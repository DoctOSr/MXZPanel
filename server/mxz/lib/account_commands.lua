-- Existing admin command semantics with bounded async polling and duplicate suppression.
local M={}
function M.new(deps)
    local self={busy=false,seen={},serial=0}
    local MP,transport=deps.MP,deps.transport
    function self:poll()
        if self.busy then return end
        self.busy=true
        transport:request("/api/game/commands/pending",{},function(response)
            self.busy=false
            local commands=response.ok and response.data and response.data.commands
            if type(commands)~="table" then return end
            for index,command in ipairs(commands) do
                if index>20 then break end
                if type(command.id)=="number" and command.id%1==0 then
                    local cached=self.seen[command.id]
                    if not cached then
                        local result="ok"
                        if command.command=="kick" then
                            local matches={}
                            for pid,name in pairs(MP.GetPlayers()) do
                                local identity=deps.identity(name)
                                if name==command.payload or (identity and identity.codename==command.payload) then
                                    matches[#matches+1]=pid
                                end
                            end
                            if #matches==1 then MP.DropPlayer(matches[1],"已被管理员踢出")
                            elseif #matches>1 then result="ambiguous player; use BeamMP name"
                            else result="player not online" end
                        elseif command.command=="say" or command.command=="bc" then
                            MP.SendChatMessage(-1,(command.command=="say" and "[管理] " or "[广播] ")..tostring(command.payload or ""))
                        else result="unsupported command" end
                        self.serial=self.serial+1
                        cached={result=result,serial=self.serial};self.seen[command.id]=cached
                        if self.serial>256 then
                            for id,value in pairs(self.seen) do
                                if value.serial<=self.serial-256 then self.seen[id]=nil end
                            end
                        end
                    end
                    transport:request("/api/game/commands/ack",{command_id=command.id,result=cached.result},function()end)
                end
            end
        end)
    end
    return self
end
return M
