-- Chains: given a quest a party member has, figure out where YOU need to start.
--
-- The game has no "prerequisites of quest X" API, so we use two data sources:
--   1. QuestieDB (Classic, Forever): a data-only library addon, separate from
--      Questie itself. No map pins, no tracker - just quest/NPC facts with a
--      documented public API (global LibQuestieDB). It has exact prerequisite
--      lists plus who starts each quest.
--   2. C_QuestLine (Retail). Blizzard groups story quests into ordered
--      questlines; we take the first quest before the target you haven't done.
-- If neither knows the quest, its status is "unknown".
local _, ns = ...
local C = {}
ns.Chains = C
local QL = ns.QuestLog

-- Status meanings:
--   completed  you already finished it              (hidden)
--   active     it's in your log too                 (hidden)
--   ineligible wrong class/race for you             (hidden)
--   available  prereqs done, you can pick it up now
--   inprogress you're mid-chain (a prereq is in your log)
--   chain      start the chain at `start`
--   unknown    no prerequisite data for this quest
local ORDER = { chain = 1, inprogress = 2, available = 3, unknown = 4 }

---------------------------------------------------------------------------
-- QuestieDB. Reads go through pcall so a bad/unexpected provider can never
-- break CatchUp; the worst case is quests showing as "unknown".
---------------------------------------------------------------------------
local contractOK
local function Lib()
    local lib = LibQuestieDB
    if type(lib) ~= "table" or type(lib.Quest) ~= "table" then return nil end
    if contractOK == nil then
        -- We only use the basic read API, available since contract 1.
        contractOK = not lib.RequireContract or (lib.RequireContract(1) and true or false)
    end
    if contractOK then return lib end
end

function C:HasQuestDB()
    return Lib() ~= nil
end

local function Read(entity, id, field)
    local lib = Lib()
    if not lib or not lib[entity] then return nil end
    local ok, value = pcall(lib[entity].Get, id, field)
    if ok then return value end
end

function C:QuestField(questID, field)
    return Read("Quest", questID, field)
end

-- Masks can exceed 32 bits (Forever's Skyborne races), so test bits with
-- arithmetic instead of bit.band, which is 32-bit only.
local function HasBit(mask, bitValue)
    if type(mask) ~= "number" or mask == 0 or type(bitValue) ~= "number" or bitValue <= 0 then
        return true   -- no restriction, or we can't tell: don't hide the quest
    end
    return math.floor(mask / bitValue) % 2 == 1
end

local function EligibleForMe(questID)
    local enum = Lib().Enum or {}
    local _, classToken = UnitClass("player")
    local _, _, raceID = UnitRace("player")
    local classBit = enum.classKeys and enum.classKeys[classToken]
    local raceBit = enum.raceMaskById and enum.raceMaskById[raceID]
    return HasBit(C:QuestField(questID, "requiredClasses"), classBit)
       and HasBit(C:QuestField(questID, "requiredRaces"), raceBit)
end

-- Walk prerequisites backwards until we hit a quest whose own prereqs are met.
--   preQuestGroup  = ALL of these must be completed
--   preQuestSingle = ANY ONE of these must be completed
local function FindRoot(questID, visited, depth)
    visited[questID] = true
    local group = C:QuestField(questID, "preQuestGroup")
    if type(group) == "table" then
        for _, pre in ipairs(group) do
            if pre > 0 and not visited[pre] and not QL:IsCompleted(pre) then
                return FindRoot(pre, visited, depth + 1)
            end
        end
    end
    local single = C:QuestField(questID, "preQuestSingle")
    if type(single) == "table" and #single > 0 then
        for _, pre in ipairs(single) do
            if QL:IsCompleted(pre) then return questID, depth end
        end
        for _, pre in ipairs(single) do
            if pre > 0 and not visited[pre] then return FindRoot(pre, visited, depth + 1) end
        end
    end
    return questID, depth
end

local function Giver(questID)
    local startedBy = C:QuestField(questID, "startedBy")   -- { npcIDs, objectIDs, itemIDs }
    if type(startedBy) ~= "table" then return nil end
    local npcs = startedBy[1]
    if type(npcs) == "table" and npcs[1] then
        local name = Read("Npc", npcs[1], "name")
        local zoneID = Read("Npc", npcs[1], "zoneID")
        local zone = zoneID and zoneID ~= 0 and C_Map and C_Map.GetAreaInfo and C_Map.GetAreaInfo(zoneID)
        if name then return zone and (name .. ", " .. zone) or name end
    end
    if type(startedBy[3]) == "table" and startedBy[3][1] then
        local item = Read("Item", startedBy[3][1], "name")
        return item and ("the item " .. item) or "an item"
    end
    if type(startedBy[2]) == "table" and startedBy[2][1] then
        local obj = Read("Object", startedBy[2][1], "name")
        return obj or "an object"
    end
end

function C:ResolveQuestDB(questID)
    local lib = Lib()
    if not lib or not (lib.Quest.Exists and lib.Quest.Exists(questID)) then return nil end
    if not EligibleForMe(questID) then
        return { status = "ineligible", target = questID }
    end
    local root, depth = FindRoot(questID, {}, 0)
    local r = { target = questID, start = root, behind = depth, giver = Giver(root),
                level = self:QuestField(root, "requiredLevel") }
    if root == questID then
        r.status = "available"
    elseif QL:Has(root) then
        r.status = "inprogress"
    else
        r.status = "chain"
    end
    return r
end

---------------------------------------------------------------------------
-- Retail questlines
---------------------------------------------------------------------------
local function QuestLineInfo(questID)
    local ok, info = pcall(C_QuestLine.GetQuestLineInfo, questID)
    if ok and info and info.questLineID then return info end
    -- Some versions need a map ID: try the player's current map.
    local mapID = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
    if mapID then
        ok, info = pcall(C_QuestLine.GetQuestLineInfo, questID, mapID)
        if ok and info and info.questLineID then return info end
    end
end

function C:ResolveQuestLine(questID)
    if not (C_QuestLine and C_QuestLine.GetQuestLineInfo and C_QuestLine.GetQuestLineQuests) then
        return nil
    end
    local info = QuestLineInfo(questID)
    if not info then return nil end
    local ok, quests = pcall(C_QuestLine.GetQuestLineQuests, info.questLineID)
    if not (ok and type(quests) == "table") then return nil end

    local index
    for i, id in ipairs(quests) do
        if id == questID then index = i break end
    end
    if not index then return nil end

    local r = { target = questID, line = info.questLineName, total = #quests, step = index }
    for i = 1, index - 1 do
        local id = quests[i]
        if not QL:IsCompleted(id) then
            r.start, r.startStep, r.behind = id, i, index - i
            r.status = QL:Has(id) and "inprogress" or "chain"
            return r
        end
    end
    r.status = "available"
    r.start = questID
    return r
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------
function C:Resolve(questID)
    if QL:IsCompleted(questID) then return { status = "completed", target = questID } end
    if QL:Has(questID) then return { status = "active", target = questID } end
    local r = self:ResolveQuestDB(questID) or self:ResolveQuestLine(questID)
             or { status = "unknown", target = questID }
    r.actionable = (r.status == "chain" or r.status == "available")
    return r
end

-- One line of text describing what to do about a gap.
function C:Describe(member, r)
    local function Q(id) return "|cffffd100[" .. QL:GetTitle(id) .. "]|r" end
    local s = ("%s is on %s"):format(member, Q(r.target))
    if r.status == "chain" then
        s = s .. (" - start with %s"):format(Q(r.start))
        if r.giver then s = s .. " from " .. r.giver end
        if r.behind then s = s .. (" (%d step%s behind)"):format(r.behind, r.behind == 1 and "" or "s") end
    elseif r.status == "inprogress" then
        s = s .. (" - you're on the way: finish %s"):format(Q(r.start))
        if r.behind then s = s .. (" (%d step%s behind)"):format(r.behind, r.behind == 1 and "" or "s") end
    elseif r.status == "available" then
        s = s .. " - you can pick this up now (ask them to share it)"
    elseif r.status == "unknown" then
        s = s .. " |cff888888- no chain data|r"
    else
        s = s .. " (" .. r.status .. ")"
    end
    return s
end

-- For each group member: which of their quests you're missing, and how to get there.
function C:AnalyzeParty()
    local out = {}
    for _, name in ipairs(ns:GetGroupMembers()) do
        local data = ns.party[name]
        local entry = { name = name, hasAddon = data ~= nil and data.hasQuests, gaps = {}, total = 0 }
        if entry.hasAddon then
            for questID in pairs(data.quests) do
                entry.total = entry.total + 1
                local r = self:Resolve(questID)
                if ORDER[r.status] then table.insert(entry.gaps, r) end
            end
            table.sort(entry.gaps, function(a, b)
                if a.status ~= b.status then return ORDER[a.status] < ORDER[b.status] end
                return a.target < b.target
            end)
        end
        table.insert(out, entry)
    end
    return out
end

-- The quests I'M behind on, across the whole group, each target listed once.
-- This is what gets sent to the group so others can see who's behind.
function C:MyGaps()
    local seen, list = {}, {}
    for _, member in ipairs(self:AnalyzeParty()) do
        for _, gap in ipairs(member.gaps) do
            if gap.status ~= "unknown" and not seen[gap.target] then
                seen[gap.target] = true
                table.insert(list, gap)
            end
        end
    end
    table.sort(list, function(a, b) return a.target < b.target end)
    while #list > 30 do table.remove(list) end   -- keep messages bounded
    return list
end

function C:GapSignature(gaps)
    local parts = {}
    for _, g in ipairs(gaps) do
        parts[#parts + 1] = g.target .. g.status .. (g.start or 0)
    end
    return table.concat(parts, ",")
end

-- Everyone else's gaps, as reported by their own CatchUp.
-- haveIt lists who in the group (including you) has the target quest.
function C:AnalyzeGroupGaps()
    local out = {}
    local myName = UnitName("player")
    for _, name in ipairs(ns:GetGroupMembers()) do
        local data = ns.party[name]
        if data and data.gaps and next(data.gaps) then
            local entry = { name = name, gaps = {} }
            for _, gap in pairs(data.gaps) do
                if ORDER[gap.status] then
                    local haveIt = {}
                    if QL:Has(gap.target) then table.insert(haveIt, "you") end
                    for _, other in ipairs(ns:GetGroupMembers()) do
                        local od = ns.party[other]
                        if other ~= name and od and od.quests and od.quests[gap.target] ~= nil then
                            table.insert(haveIt, other)
                        end
                    end
                    gap.haveIt = haveIt
                    table.insert(entry.gaps, gap)
                end
            end
            table.sort(entry.gaps, function(a, b)
                if a.status ~= b.status then return ORDER[a.status] < ORDER[b.status] end
                return a.target < b.target
            end)
            table.insert(out, entry)
        end
    end
    return out
end
