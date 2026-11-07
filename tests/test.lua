local H = dofile("harness.lua")
local function check(cond,msg) if not cond then error("FAIL: "..msg,2) end print("PASS: "..msg) end

-- Retail-style questline 900: quests 101 -> 102 -> 103 -> 104
local questline = {
  GetQuestLineInfo=function(id) if id>=101 and id<=104 then return {questLineID=900, questLineName="The Long Road"} end end,
  GetQuestLineQuests=function() return {101,102,103,104} end,
}
local titles={[101]="A Humble Start",[102]="Second Step",[103]="Third Step",[104]="The Finale",[555]="Lonely Quest"}

-- Alice: deep in the chain, plus a quest with no chain data, plus 40 filler quests to force chunking
local aliceLog={{104,"The Finale"},{555,"Lonely Quest"}}
for i=1,40 do table.insert(aliceLog,{2000+i,"Filler quest with a longer name ~^ number "..i}) end
local alice=H.makeClient("Alice",{log=aliceLog, done={[101]=true,[102]=true,[103]=true}, questline=questline, titles=titles})
-- Bob: fresh, nothing done
local bob=H.makeClient("Bob",{log={}, done={}, questline=questline, titles=titles})
-- Cara: did 101, has 102 in log
local cara=H.makeClient("Cara",{log={{102,"Second Step"}}, done={[101]=true}, questline=questline, titles=titles})

for _,c in ipairs(H.clients) do c.fire("ADDON_LOADED","CatchUp"); c.fire("PLAYER_LOGIN"); c.fire("PLAYER_ENTERING_WORLD") end
H.GROUP[1]="Alice"; H.GROUP[2]="Bob"; H.GROUP[3]="Cara"
for _,c in ipairs(H.clients) do c.fire("GROUP_ROSTER_UPDATE") end
H.advance(30)

check(bob.ns.party.Alice ~= nil, "Bob received Alice's snapshot")
local n=0 for _ in pairs(bob.ns.party.Alice.quests) do n=n+1 end
check(n==42, "all 42 of Alice's quests arrived across chunks (got "..n..")")
check(bob.ns.party.Alice.quests[2001]=="Filler quest with a longer name  number 1", "delimiters stripped from titles")
check(alice.sent < 15, "Alice sent a reasonable number of messages ("..alice.sent..")")

local r=bob.ns.Chains:Resolve(104)
check(r.status=="chain" and r.start==101 and r.behind==3, "Bob must start at 101, 3 behind")
r=cara.ns.Chains:Resolve(104)
check(r.status=="inprogress" and r.start==102, "Cara is in progress on 102")
r=bob.ns.Chains:Resolve(555)
check(r.status=="unknown", "quest without chain data is unknown")
r=alice.ns.Chains:Resolve(102)
check(r.status=="completed", "Alice already completed 102")
r=bob.ns.Chains:Resolve(101)
check(r.status=="available", "Bob can pick up 101 directly")

-- UI renders
bob.slash("")
local text=bob.ns.UI.text.text
check(text and text:find("Start with:") and text:find("A Humble Start"), "UI shows start-with line")
print((text:gsub("|c%x%x%x%x%x%x%x%x",""):gsub("|r","")))

-- Quest log change propagates: Alice abandons 555
table.remove(aliceLog,2)
alice.fire("QUEST_LOG_UPDATE")
H.advance(10)
check(bob.ns.party.Alice.quests[555]==nil, "Bob sees Alice's log update")

-- Group view: Alice sees what Bob and Cara are behind on
local ag=alice.ns.party.Bob and alice.ns.party.Bob.gaps
check(ag and ag[104] and ag[104].status=="chain" and ag[104].start==101 and ag[104].behind==3, "Alice received Bob's gap for 104 (start 101, 3 behind)")
local cg=alice.ns.party.Cara.gaps
check(cg[104] and cg[104].status=="inprogress" and cg[104].start==102, "Alice sees Cara is working on 102")
check(bob.ns.party.Cara.gaps[104] ~= nil, "Bob sees Cara's gaps too")
alice.slash("")
local at=alice.ns.UI.text.text:gsub("|c%x%x%x%x%x%x%x%x",""):gsub("|r","")
print(at)
check(at:find("WHO'S BEHIND") and at:find("Bob %- behind on") and at:find("Needs to start with: A Humble Start"), "Alice's window shows who's behind")
check(at:find("The Finale  %(you on it%)"), "shows that Alice has the target quest")
-- Bob catches up: completes 101..103 and picks up 104 -> gap disappears for Alice
bob.done[101]=true; bob.done[102]=true; bob.done[103]=true
table.insert(bob.log,{104,"The Finale"})
bob.fire("QUEST_LOG_UPDATE")
H.advance(15)
check(alice.ns.party.Bob.gaps[104]==nil, "Bob's gap clears for Alice after he catches up")

-- Someone leaves
H.GROUP[3]=nil
for _,c in ipairs(H.clients) do c.fire("GROUP_ROSTER_UPDATE") end
H.advance(5)
check(bob.ns.party.Cara==nil, "Cara pruned after leaving")

-- QuestieDB path (Classic/Forever): 301 needs ALL of {201,202}; 202 needs ANY of {150,151}
local SKY=4294967296  -- Skyborne race bit 32
local quests={[301]={name="Big Quest",preQuestGroup={201,202},startedBy={{77},{},{}},requiredLevel=0},
        [201]={name="Prep A",startedBy={{77},{},{}},requiredLevel=0},
        [202]={name="Prep B",preQuestSingle={150,151},startedBy={{77},{},{}},requiredLevel=0},
        [150]={name="Root One",startedBy={{88},{},{}},requiredLevel=10},
        [151]={name="Root Two",startedBy={{88},{},{}},requiredLevel=0},
        [400]={name="Warrior Only",requiredClasses=1,startedBy={},requiredLevel=0},
        [500]={name="Skyborne Only",requiredRaces=SKY,startedBy={},requiredLevel=0},
        [501]={name="Human or Skyborne",requiredRaces=SKY+1,startedBy={},requiredLevel=0}}
local npcs={[77]={name="Captain Foo",zoneID=0},[88]={name="Old Man Bar",zoneID=0}}
local function entity(t) return {Get=function(id,f) local e=t[id] return e and e[f] end, Exists=function(id) return t[id]~=nil end} end
local qdb={Quest=entity(quests),Npc=entity(npcs),Item=entity({}),Object=entity({}),
  RequireContract=function(v) return v<=4 end,
  Enum={classKeys={WARRIOR=1,MAGE=128},raceMaskById={[1]=1,[95]=SKY}}}
local dan=H.makeClient("Dan",{log={}, done={[201]=true}, qdb=qdb})
dan.fire("ADDON_LOADED","CatchUp")
r=dan.ns.Chains:Resolve(301)
check(r.status=="chain" and r.start==150 and r.giver=="Old Man Bar" and r.level==10, "QuestieDB: walks 301 -> 202 -> 150")
local eve=H.makeClient("Eve",{log={}, done={[201]=true,[151]=true}, qdb=qdb})
eve.fire("ADDON_LOADED","CatchUp")
r=eve.ns.Chains:Resolve(301)
check(r.status=="chain" and r.start==202, "QuestieDB: preQuestSingle satisfied by 151 -> start at 202")
check(dan.ns.Chains:Resolve(400).status=="ineligible", "class-restricted quest hidden for a mage")
check(dan.ns.Chains:Resolve(500).status=="ineligible", "Skyborne-only quest hidden for a human")
check(dan.ns.Chains:Resolve(501).status=="available", "Human-or-Skyborne quest shown for a human (>32-bit mask)")
local sky=H.makeClient("Sky",{log={}, done={}, qdb=qdb, race=95})
sky.fire("ADDON_LOADED","CatchUp")
check(sky.ns.Chains:Resolve(500).status=="available", "Skyborne-only quest shown for a Skyborne")
check(dan.ns.Chains:Describe("X",dan.ns.Chains:Resolve(301)):find("Root One"), "Describe uses QuestieDB name")
check(dan.ns.QuestLog:GetTitle(150)=="Root One", "titles fall back to QuestieDB")
-- No data source at all: hint printed once
H.advance(10)
local hinted=false for _,m in ipairs(alice.chat) do if m:find("QuestieDB") then hinted=true end end
check(hinted, "clients without QuestieDB get a one-time install hint")
local dh=false for _,m in ipairs(dan.chat) do if m:find("install") then dh=true end end
check(not dh, "no hint when QuestieDB is present")

-- UTF-8 truncation
local T=alice.ns.Comm.Utf8Truncate
check(T("ééé",3)=="é", "utf8 truncation does not split characters")
print("ALL TESTS PASSED")
