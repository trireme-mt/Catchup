local H=dofile("harness.lua")
local a=H.makeClient("Ann",{log={{1,"x"}}}); local b=H.makeClient("Ben",{log={}})
local SECRET={}
for _,c in ipairs(H.clients) do c.env.issecretvalue=function(v) return v==SECRET end; c.fire("ADDON_LOADED","CatchUp") end
H.GROUP[1]="Ann"; H.GROUP[2]="Ben"
b.env.UnitName=function(u) if u=="player" then return "Ben" end return SECRET end
for _,c in ipairs(H.clients) do c.fire("PLAYER_LOGIN"); c.fire("GROUP_ROSTER_UPDATE") end
H.advance(20)
assert(#b.ns:GetGroupMembers()==0); print("PASS: secret unit names are skipped without errors")
