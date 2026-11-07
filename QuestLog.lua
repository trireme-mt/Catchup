-- QuestLog: reads YOUR quest log and answers "have I done / do I have quest X".
-- Retail and Classic expose this through different APIs, so each call
-- feature-detects which one exists instead of checking the game version.
local _, ns = ...
local QL = {}
ns.QuestLog = QL

QL.mine = {}          -- [questID] = title, for quests currently in your log
QL.remoteTitles = {}  -- titles learned from party members' messages
local signature = ""

local function ScanLog()
    local quests = {}
    if C_QuestLog and C_QuestLog.GetInfo and C_QuestLog.GetNumQuestLogEntries then
        -- Modern API (Retail, newer Classic clients)
        for i = 1, C_QuestLog.GetNumQuestLogEntries() do
            local info = C_QuestLog.GetInfo(i)
            if info and not info.isHeader and not info.isHidden
               and not info.isTask and not info.isBounty  -- skip world quests/emissaries
               and info.questID and info.questID > 0 then
                local title = info.title
                quests[info.questID] = (title and not ns:IsSecret(title)) and title or ""
            end
        end
    else
        -- Old API (Classic Era). Note: quests under collapsed headers are not listed.
        for i = 1, GetNumQuestLogEntries() do
            local title, _, _, isHeader, _, _, _, questID = GetQuestLogTitle(i)
            if not isHeader and questID and questID > 0 then
                quests[questID] = title or ""
            end
        end
    end
    return quests
end

local function Signature(quests)
    local ids = {}
    for id in pairs(quests) do table.insert(ids, id) end
    table.sort(ids)
    return table.concat(ids, ",")
end

-- Rescan; returns true if the set of quests changed.
function QL:Refresh()
    local quests = ScanLog()
    self.mine = quests
    local sig = Signature(quests)
    if sig ~= signature then
        signature = sig
        return true
    end
    return false
end

function QL:Has(questID)
    return self.mine[questID] ~= nil
end

function QL:IsCompleted(questID)
    if C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted then
        return C_QuestLog.IsQuestFlaggedCompleted(questID) and true or false
    elseif IsQuestFlaggedCompleted then
        return IsQuestFlaggedCompleted(questID) and true or false
    end
    return false
end

function QL:GetTitle(questID)
    local title = self.mine[questID] or self.remoteTitles[questID]
    if title and title ~= "" then return title end
    if C_QuestLog then
        if C_QuestLog.GetTitleForQuestID then
            title = C_QuestLog.GetTitleForQuestID(questID)
        elseif C_QuestLog.GetQuestInfo then
            title = C_QuestLog.GetQuestInfo(questID)
        end
    end
    if (not title or title == "") and ns.Chains then
        title = ns.Chains:QuestField(questID, "name")
    end
    if title and title ~= "" then return title end
    -- Not cached by the client yet: ask the server; QUEST_DATA_LOAD_RESULT fires later.
    if C_QuestLog and C_QuestLog.RequestLoadQuestByID then
        C_QuestLog.RequestLoadQuestByID(questID)
    end
    return "Quest #" .. questID
end

ns:On("QUEST_LOG_UPDATE", function()
    ns:Debounce("questlog", 1, function()
        if QL:Refresh() then
            ns.Comm:BroadcastSoon(2)
        end
        ns:DataChanged()
    end)
end)
ns:On("QUEST_TURNED_IN", function() ns:DataChanged() end)
if C_QuestLog and C_QuestLog.RequestLoadQuestByID then
    ns:On("QUEST_DATA_LOAD_RESULT", function() ns:DataChanged() end)
end
ns:On("PLAYER_LOGIN", function() QL:Refresh() end)
