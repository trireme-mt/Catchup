-- Minimal WoW API mock: runs N clients of the addon in separate global envs.
local ADDON_DIR = arg[1]
local FILES = {"Core.lua","QuestLog.lua","Chains.lua","Comm.lua","UI.lua"}
local now = 0
local timers = {}
local clients = {}
local GROUP = {}

local function band(a,b) local r,bit=0,1 while a>0 and b>0 do if a%2==1 and b%2==1 then r=r+bit end a=math.floor(a/2) b=math.floor(b/2) bit=bit*2 end return r end

local function newFrame()
  local f = {scripts={}, events={}, shown=false}
  local mt = {__index=function(t,k) return function() end end}
  setmetatable(f, mt)
  f.SetScript=function(self,k,fn) self.scripts[k]=fn end
  f.RegisterEvent=function(self,e) self.events[e]=true end
  f.CreateFontString=function() local s=newFrame(); s.SetText=function(self,t) self.text=t end; s.GetStringHeight=function() return 100 end; return s end
  f.IsShown=function(self) return self.shown end
  f.SetShown=function(self,v) self.shown=v; if v and self.scripts.OnShow then self.scripts.OnShow(self) end end
  f.Hide=function(self) self.shown=false end
  f.GetPoint=function() return "CENTER",nil,"CENTER",0,0 end
  return f
end

local function makeClient(name, opts)
  local env = setmetatable({}, {__index=_G})
  local c = {name=name, env=env, frames={}, log=opts.log or {}, done=opts.done or {}, chat={}}
  env.CreateFrame=function() local f=newFrame(); table.insert(c.frames,f); return f end
  env.UIParent=newFrame(); env.UISpecialFrames={}
  env.DEFAULT_CHAT_FRAME={AddMessage=function(_,m) table.insert(c.chat,m); print("  ["..name.." chat] "..m:gsub("|c%x%x%x%x%x%x%x%x",""):gsub("|r","")) end}
  env.C_Timer={After=function(d,fn) table.insert(timers,{at=now+d,fn=fn,Cancel=function() end}) end, NewTimer=function(d,fn) local t={at=now+d,fn=fn}; t.Cancel=function() t.dead=true end; table.insert(timers,t); return t end,
               NewTicker=function(d,fn) local t={at=now+d,fn=fn,every=d}; t.Cancel=function() t.dead=true end; table.insert(timers,t); return t end}
  env.strsplit=function(d,s,n) local out={} local start=1 while true do if n and #out==n-1 then table.insert(out,s:sub(start)) break end local i=s:find(d,start,true) if not i then table.insert(out,s:sub(start)) break end table.insert(out,s:sub(start,i-1)) start=i+1 end return unpack(out) end
  env.strtrim=function(s) return (s:gsub("^%s+",""):gsub("%s+$","")) end
  env.wipe=function(t) for k in pairs(t) do t[k]=nil end return t end
  env.tinsert=table.insert
  env.bit={band=band}
  env.Ambiguate=function(n) return (n:gsub("%-MyRealm$","")) end
  env.UnitName=function(u) if u=="player" then return name end local i=tonumber(u:match("party(%d)")) local others={} for _,m in ipairs(GROUP) do if m~=name then table.insert(others,m) end end return others[i] end
  env.UnitClass=function() return "Mage",opts.class or "MAGE",8 end
  env.UnitRace=function() return "Race","Race",opts.race or 1 end
  env.IsInRaid=function() return false end
  env.IsInGroup=function(cat) if cat then return false end return #GROUP>1 end
  env.LE_PARTY_CATEGORY_INSTANCE=2
  env.GetNumSubgroupMembers=function() return #GROUP-1 end
  env.UnitIsUnit=function() return false end
  env.GetTime=function() return now end
  env.Enum={SendAddonMessageResult={Success=0}}
  env.C_ChatInfo={RegisterAddonMessagePrefix=function() end,
    SendAddonMessage=function(p,msg,ch)
      assert(#msg<=255,"message too long "..#msg)
      c.sent=(c.sent or 0)+1
      for _,o in ipairs(clients) do o.fire("CHAT_MSG_ADDON",p,msg,ch,name.."-MyRealm") end
      return 0 end}
  env.C_QuestLog={
    GetNumQuestLogEntries=function() return #c.log end,
    GetInfo=function(i) local q=c.log[i]; return {questID=q[1], title=q[2]} end,
    IsQuestFlaggedCompleted=function(id) return c.done[id]==true end,
    GetTitleForQuestID=function(id) return opts.titles and opts.titles[id] end,
  }
  env.C_QuestLine=opts.questline
  env.LibQuestieDB=opts.qdb
  env.SLASH_CATCHUP1=nil; env.SlashCmdList={}
  local ns={}
  for _,f in ipairs(FILES) do
    local chunk=assert(loadfile(ADDON_DIR.."/"..f)); setfenv(chunk,env); chunk("CatchUp",ns)
  end
  c.ns=ns
  c.fire=function(ev,...) for _,f in ipairs(c.frames) do if f.events[ev] and f.scripts.OnEvent then f.scripts.OnEvent(f,ev,...) end end end
  c.slash=function(s) env.SlashCmdList.CATCHUP(s) end
  table.insert(clients,c)
  return c
end

local function advance(sec)
  local target=now+sec
  while true do
    table.sort(timers,function(a,b) return a.at<b.at end)
    local t
    for _,x in ipairs(timers) do if not x.dead and x.at<=target then t=x break end end
    if not t then break end
    now=t.at
    if t.every then t.at=now+t.every else t.dead=true end
    t.fn()
    for i=#timers,1,-1 do if timers[i].dead then table.remove(timers,i) end end
  end
  now=target
end

return {makeClient=makeClient, advance=advance, GROUP=GROUP, clients=clients}
