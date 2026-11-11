-- Statistics only: do not replace gameplay, login, or online-time handlers.
local VERSION='round-only-20261104'
local old=rawget(_G,'mxzRoundStatsPolicy')
local policy={version=VERSION,distanceDropped=0,deathDropped=0,firstPackets={},active=false,epoch=0}
local function accessor(fn,key,seen,depth)
 if type(fn)~='function'or depth>5 or seen[fn]then return end;seen[fn]=true
 for i=1,100 do local name,value=debug.getupvalue(fn,i);if not name then break end
  if name==key then return function()local _,v=debug.getupvalue(fn,i);return v end end
 end
 for i=1,100 do local name,value=debug.getupvalue(fn,i);if not name then break end
  if type(value)=='function'then local found=accessor(value,key,seen,depth+1);if found then return found end end
 end
end
local function getAccess(key,...)
 for _,fn in ipairs({...})do local get=accessor(fn,key,{},0);if get then return get end end
end
local function active()
 local round=policy.round and policy.round()
 if type(round)=='table'then return round.phase=='running',tostring(round.id or '')end
 local game=policy.game and policy.game()
 local water=policy.water and policy.water()
 return game==2 or type(water)=='table'and water.enabled==true,'legacy'
end
local function refresh()
 local enabled,roundId=active()
 if enabled~=policy.active or roundId~=policy.roundId then
  policy.active=enabled;policy.roundId=roundId;policy.epoch=policy.epoch+1;policy.firstPackets={}
 end
end
function mxz_round_stats_tick()
 local fn=rawget(_G,'onMxzDist')
 if fn~=policy.handler then
  policy.handler=fn
  policy.auth=getAccess('accountAuth',fn)
  policy.round=getAccess('round',rawget(_G,'onMxzRoundStart'),rawget(_G,'onMxzRoundGo'))
  policy.game=getAccess('gameState',rawget(_G,'Fuk_Tick'))
  policy.water=getAccess('floodOptions',rawget(_G,'onFloodStart'))
 end
 local auth=policy.auth and policy.auth()
 if auth and type(auth.event)=='function'and auth.event~=policy.wrapper then
  local original=old and old.authInstance==auth and old.original or auth.event
  policy.original=original;policy.authInstance=auth
  policy.wrapper=function(self,pid,kind,...)
   if kind=='distance'or kind=='death'then
    refresh()
    if not policy.active then
     if kind=='distance'then policy.firstPackets[pid]=nil;policy.distanceDropped=policy.distanceDropped+1 else policy.deathDropped=policy.deathDropped+1 end
     return false,'outside_round'
    end
    if kind=='distance'and not policy.firstPackets[pid]then
     -- Legacy clients batch distance across match boundaries. Discard that
     -- first ambiguous batch instead of attributing pre-match driving to a match.
     policy.firstPackets[pid]=true;policy.distanceDropped=policy.distanceDropped+1
     return false,'cross_boundary_batch'
    end
   end
   return original(self,pid,kind,...)
  end
  auth.event=policy.wrapper
 end
 refresh()
 local now=os.time()
 if now~=(policy.lastWrite or 0)and now%5==0 then
  policy.lastWrite=now
  local f=io.open('Resources/Server/mxz/round_stats_status.json','w')
  if f then f:write(Util.JsonEncode({version=VERSION,at=now,installed=policy.wrapper~=nil,active=policy.active,source=policy.round and 'round.phase'or 'legacy_mafia_flood',distanceDropped=policy.distanceDropped,deathDropped=policy.deathDropped}));f:close()end
 end
end
_G.mxzRoundStatsPolicy=policy
MP.CancelEventTimer('mxz:round-stats')
MP.RegisterEvent('mxz:round-stats','mxz_round_stats_tick')
MP.CreateEventTimer('mxz:round-stats',1000)
mxz_round_stats_tick()
-- The native script watcher calls onInit after a changed file. If the account
-- runtime already exists, shield just that call to preserve the live session.
if policy.authInstance then
 local originalInit=rawget(_G,'onInit')
 if type(originalInit)=='function'then _G.onInit=function(...)_G.onInit=originalInit end end
end
print('[MXZ-STATS] '..VERSION..' installed; online-time unchanged')
