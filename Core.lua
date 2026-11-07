-- Core: shared namespace, event dispatch, timers, group roster, slash commands.
-- Every file in an addon receives the same two varargs: the addon's folder name
-- and a private table (`ns`) shared by all files of this addon only.
local ADDON, ns = ...
ns.version = "0.1.0"
ns.party = {}      -- [memberKey] = { quests = { [questID] = title }, time = GetTime() }
ns.notified = {}   -- "member:questID" -> true, so chat notifications fire once

---------------------------------------------------------------------------
-- Event dispatch: one hidden frame, many listeners per event.
---------------------------------------------------------------------------
local frame = CreateFrame("Frame")
local handlers = {}

function ns:On(event, fn)
    if not handlers[event] then
        handlers[event] = {}
        frame:RegisterEvent(event)
    end
    table.insert(handlers[event], fn)
end

frame:SetScript("OnEvent", function(_, event, ...)
    for _, fn in ipairs(handlers[event]) do
        fn(event, ...)
    end
end)

---------------------------------------------------------------------------
-- Debounce: run fn once, `delay` seconds after the LAST call with this key.
-- Quest/group events fire in bursts; this collapses them into one update.
---------------------------------------------------------------------------
local timers = {}
function ns:Debounce(key, delay, fn)
    if timers[key] then timers[key]:Cancel() end
    timers[key] = C_Timer.NewTimer(delay, function()
        timers[key] = nil
        fn()
    end)
end

function ns:Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99CatchUp|r: " .. tostring(msg))
end

function ns:Debug(msg)
    if ns.db and ns.db.debug then
        DEFAULT_CHAT_FRAME:AddMessage("|cff888888CatchUp debug|r: " .. tostring(msg))
    end
end

---------------------------------------------------------------------------
-- Group roster. Names are normalized so "Bob", "Bob-Realm" from the roster
-- and "Bob-Realm" from addon messages map to the same key.
---------------------------------------------------------------------------
-- Midnight-era clients (Retail, Forever) can hand addons "secret values" that
-- can't be compared or concatenated. Older clients don't have issecretvalue.
function ns:IsSecret(v)
    return issecretvalue ~= nil and issecretvalue(v) or false
end

function ns:NormalizeName(name)
    if not name or ns:IsSecret(name) then return nil end
    return (Ambiguate(name, "none"):gsub("%s", ""))
end

local function UnitKey(unit)
    local name, realm = UnitName(unit)
    if not name or ns:IsSecret(name) or name == UNKNOWNOBJECT then return nil end
    if realm and not ns:IsSecret(realm) and realm ~= "" then name = name .. "-" .. realm end
    return ns:NormalizeName(name)
end

function ns:GetGroupMembers()
    local list = {}
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            local unit = "raid" .. i
            if not UnitIsUnit(unit, "player") then
                local key = UnitKey(unit)
                if key then table.insert(list, key) end
            end
        end
    else
        for i = 1, GetNumSubgroupMembers() do
            local key = UnitKey("party" .. i)
            if key then table.insert(list, key) end
        end
    end
    return list
end

local known = {}
local function OnRosterChanged()
    local current, anyNew = {}, false
    for _, key in ipairs(ns:GetGroupMembers()) do
        current[key] = true
        if not known[key] then anyNew = true end
    end
    for key in pairs(ns.party) do
        if not current[key] then ns.party[key] = nil end
    end
    known = current
    if anyNew then
        -- Ask everyone for their quests; our own snapshot goes out too
        -- (same debounce key as replies to requests, so it's sent once).
        ns.Comm:Request()
        ns.Comm:BroadcastSoon()
    end
    ns:DataChanged()
end

ns:On("GROUP_ROSTER_UPDATE", function() ns:Debounce("roster", 1.5, OnRosterChanged) end)
ns:On("PLAYER_ENTERING_WORLD", function() ns:Debounce("roster", 3, OnRosterChanged) end)

---------------------------------------------------------------------------
-- Something changed (our log, a member's log, quest data loaded): refresh.
---------------------------------------------------------------------------
function ns:DataChanged()
    ns:Debounce("refresh", 0.3, function()
        ns.UI:Refresh()
        ns:NotifyNewGaps()
        ns.Comm:SendGapsIfChanged()
    end)
end

function ns:NotifyNewGaps()
    if not ns.db.notify then return end
    for _, member in ipairs(ns.Chains:AnalyzeParty()) do
        local fresh = {}
        for _, gap in ipairs(member.gaps) do
            local key = member.name .. ":" .. gap.target
            if gap.actionable and not ns.notified[key] then
                ns.notified[key] = true
                table.insert(fresh, gap)
            end
        end
        if #fresh > 3 then
            ns:Print(("%s is on %d quests you could catch up on. Type /catchup to see them."):format(member.name, #fresh))
        else
            for _, gap in ipairs(fresh) do
                ns:Print(ns.Chains:Describe(member.name, gap))
            end
        end
    end
end

---------------------------------------------------------------------------
-- Saved variables become available on ADDON_LOADED for this addon.
---------------------------------------------------------------------------
ns:On("ADDON_LOADED", function(_, name)
    if name ~= ADDON then return end
    CatchUpDB = CatchUpDB or {}
    local db = CatchUpDB
    if db.notify == nil then db.notify = true end
    if db.showUnknown == nil then db.showUnknown = false end
    db.ui = db.ui or {}
    ns.db = db
end)

-- One-time hint if there's no prerequisite data for this client.
ns:On("PLAYER_LOGIN", function()
    C_Timer.After(5, function()
        if not ns.Chains:HasQuestDB() and not ns.db.hintShown then
            ns.db.hintShown = true
            ns:Print("For quest chain data on Classic/Forever, install the QuestieDB addon "
                .. "(data only - you don't need Questie itself).")
        end
    end)
end)

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------
local function Toggle(key, label)
    ns.db[key] = not ns.db[key]
    ns:Print(label .. ": " .. (ns.db[key] and "on" or "off"))
end

SLASH_CATCHUP1 = "/catchup"
SlashCmdList.CATCHUP = function(input)
    local cmd, arg = strsplit(" ", strtrim(input or ""), 2)
    cmd = (cmd or ""):lower()
    if cmd == "" then
        ns.UI:Toggle()
    elseif cmd == "sync" then
        ns.Comm:Request()
        ns.Comm:BroadcastSoon()
        ns:Print("Requested quest lists from the group.")
    elseif cmd == "notify" then
        Toggle("notify", "Chat notifications")
    elseif cmd == "unknown" then
        Toggle("showUnknown", "Show quests with unknown chains")
        ns.UI:Refresh()
    elseif cmd == "debug" then
        Toggle("debug", "Debug output")
    elseif cmd == "chain" and tonumber(arg) then
        -- Developer helper: test chain lookup on any quest ID while solo.
        local r = ns.Chains:Resolve(tonumber(arg))
        ns:Print(("status=%s  %s"):format(r.status, ns.Chains:Describe("(test)", r)))
    else
        ns:Print("/catchup - toggle window")
        ns:Print("/catchup sync - re-request quest lists")
        ns:Print("/catchup notify - toggle chat notifications")
        ns:Print("/catchup unknown - toggle quests with no chain data")
        ns:Print("/catchup chain <questID> - test chain lookup")
        ns:Print("/catchup debug - toggle debug output")
    end
end
