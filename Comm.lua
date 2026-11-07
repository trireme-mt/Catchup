-- Comm: exchanges quest lists with group members via hidden addon messages.
-- You can't read another player's quest log directly, so every member needs
-- CatchUp installed; each one sends its own list to the group.
--
-- Protocol (prefix "CatchUp1", each message <= 255 bytes):
--   R                          "please send me your data"
--   D:<seq>:<id>~<title>^...   a chunk of MY QUEST LOG in snapshot <seq>
--   E:<seq>:<count>            end of quest snapshot; receiver checks the count
--   G:<seq>:<gap>^...          a chunk of quests I'M BEHIND ON, where each gap is
--                              target~status~start~behind~startTitle~giver
--   F:<seq>:<count>            end of gap snapshot
-- Both snapshot types use the same chunking code (SendSet / OnChunk / OnEnd).
local _, ns = ...
local Comm = {}
ns.Comm = Comm

local PREFIX = "CatchUp1"
local MAX_MSG = 250
local SEND_INTERVAL = 0.35   -- seconds between messages; stays under the server's throttle
local MAX_TRIES = 20

local seq = 0
local queue = {}       -- outgoing messages
local ticker
local incoming = {}    -- [sender] = { seq = "n", quests = {} } while a snapshot is arriving

C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)

local function Channel()
    if LE_PARTY_CATEGORY_INSTANCE and IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then
        return "INSTANCE_CHAT"   -- dungeon finder / battleground groups
    elseif IsInRaid() then
        return "RAID"
    elseif IsInGroup() then
        return "PARTY"
    end
end

-- Cut a string to at most maxBytes without splitting a UTF-8 character.
local function Utf8Truncate(s, maxBytes)
    if #s <= maxBytes then return s end
    local cut = maxBytes
    while cut > 0 do
        local b = s:byte(cut + 1)
        if b < 0x80 or b >= 0xC0 then break end  -- next byte starts a character
        cut = cut - 1
    end
    return s:sub(1, cut)
end
Comm.Utf8Truncate = Utf8Truncate

local function CleanTitle(title)
    return Utf8Truncate((title or ""):gsub("[%^~]", ""), 80)
end

-- Retail returns an enum (Success = 0), Classic returns a boolean, very old
-- clients return nothing.
local SUCCESS = Enum and Enum.SendAddonMessageResult and Enum.SendAddonMessageResult.Success
local function Sent(result)
    return result == nil or result == true or (SUCCESS ~= nil and result == SUCCESS)
end

local function Pump()
    local item = queue[1]
    if not item then
        if ticker then ticker:Cancel(); ticker = nil end
        return
    end
    local channel = Channel()
    if not channel then
        wipe(queue)
        return
    end
    if Sent(C_ChatInfo.SendAddonMessage(PREFIX, item.msg, channel)) then
        table.remove(queue, 1)
    else
        -- Throttled or blocked (e.g. some restricted content). Retry; if it
        -- keeps failing, drop this snapshot and try a fresh one later.
        item.tries = item.tries + 1
        if item.tries >= MAX_TRIES then
            ns:Debug("send keeps failing, retrying in 15s")
            wipe(queue)
            Comm:BroadcastSoon(15)
        end
    end
end

local function Send(msg)
    table.insert(queue, { msg = msg, tries = 0 })
    if not ticker then ticker = C_Timer.NewTicker(SEND_INTERVAL, Pump) end
end

-- Send a list of pre-encoded entries as chunks + an end marker with the count.
local function SendSet(dataKind, endKind, entries)
    seq = seq + 1
    local header = dataKind .. ":" .. seq .. ":"
    local budget = MAX_MSG - #header
    local parts, used = {}, 0
    local function Flush()
        if #parts > 0 then
            Send(header .. table.concat(parts, "^"))
            parts, used = {}, 0
        end
    end
    for _, entry in ipairs(entries) do
        if used + #entry + 1 > budget then Flush() end
        table.insert(parts, entry)
        used = used + #entry + 1
    end
    Flush()
    Send(endKind .. ":" .. seq .. ":" .. #entries)
end

local function Clean(text, maxBytes)
    return Utf8Truncate((tostring(text or "")):gsub("[%^~]", ""), maxBytes)
end

local function QuestEntries()
    local entries = {}
    for questID, title in pairs(ns.QuestLog.mine) do
        table.insert(entries, questID .. "~" .. CleanTitle(title))
    end
    return entries
end

local function GapEntries(gaps)
    local entries = {}
    for _, g in ipairs(gaps) do
        table.insert(entries, table.concat({
            g.target, g.status, g.start or 0, g.behind or 0,
            Clean(g.start and ns.QuestLog:GetTitle(g.start) or "", 60),
            Clean(g.giver or "", 60),
        }, "~"))
    end
    return entries
end

local lastGapSig
-- Send my quest log and the quests I'm behind on.
function Comm:Broadcast()
    if not Channel() then return end
    wipe(queue)   -- any half-sent older snapshot is stale now
    local quests = QuestEntries()
    SendSet("D", "E", quests)
    local gaps = ns.Chains:MyGaps()
    SendSet("G", "F", GapEntries(gaps))
    lastGapSig = ns.Chains:GapSignature(gaps)
    ns:Debug(("sent %d quests, %d gaps"):format(#quests, #gaps))
end

-- Called after every refresh: re-send gaps only if they changed (e.g. a party
-- member's quest list just arrived, or you finished a quest).
function Comm:SendGapsIfChanged()
    if not Channel() then return end
    local gaps = ns.Chains:MyGaps()
    local sig = ns.Chains:GapSignature(gaps)
    if sig == lastGapSig then return end
    ns:Debounce("gaps", 2, function()
        local current = ns.Chains:MyGaps()
        lastGapSig = ns.Chains:GapSignature(current)
        SendSet("G", "F", GapEntries(current))
    end)
end

-- Broadcast after a short delay; repeated calls collapse into one send.
-- Default delay has jitter so a whole group answering a request doesn't
-- send at the exact same moment.
function Comm:BroadcastSoon(delay)
    ns:Debounce("broadcast", delay or (0.5 + math.random() * 2), function() Comm:Broadcast() end)
end

function Comm:Request()
    if Channel() then Send("R") end
end

local PARSERS = {
    D = function(entry)
        local id, title = entry:match("^(%d+)~(.*)$")
        if not id then return end
        id = tonumber(id)
        if title ~= "" then ns.QuestLog.remoteTitles[id] = title end
        return id, title
    end,
    G = function(entry)
        local target, status, start, behind, startTitle, giver =
            strsplit("~", entry)
        target, start, behind = tonumber(target), tonumber(start), tonumber(behind)
        if not target then return end
        if start and start > 0 and startTitle and startTitle ~= "" then
            ns.QuestLog.remoteTitles[start] = startTitle
        end
        return target, {
            target = target, status = status,
            start = (start and start > 0) and start or nil,
            behind = (behind and behind > 0) and behind or nil,
            giver = (giver and giver ~= "") and giver or nil,
        }
    end,
}
local END_OF = { E = "D", F = "G" }

local function OnMessage(_, prefix, text, _, sender)
    if prefix ~= PREFIX then return end
    local name = ns:NormalizeName(sender)
    if not name or name == ns:NormalizeName(UnitName("player")) then return end

    local kind, snap, payload = strsplit(":", text, 3)
    if kind == "R" then
        Comm:BroadcastSoon()
    elseif PARSERS[kind] then
        local key = name .. ":" .. kind
        local inc = incoming[key]
        if not inc or inc.seq ~= snap then
            inc = { seq = snap, items = {} }
            incoming[key] = inc
        end
        for entry in (payload or ""):gmatch("[^%^]+") do
            local id, value = PARSERS[kind](entry)
            if id then inc.items[id] = value end
        end
    elseif END_OF[kind] then
        local key = name .. ":" .. END_OF[kind]
        local inc = incoming[key]
        incoming[key] = nil
        local expected = tonumber(payload) or -1
        local items = (inc and inc.seq == snap) and inc.items or {}
        local got = 0
        for _ in pairs(items) do got = got + 1 end
        if got ~= expected then
            ns:Debug(("incomplete %s snapshot from %s (%d/%d), ignored"):format(END_OF[kind], name, got, expected))
            return
        end
        local member = ns.party[name] or { quests = {}, gaps = {} }
        if kind == "E" then
            member.quests = items
            member.hasQuests = true
        else
            member.gaps = items
        end
        member.time = GetTime()
        ns.party[name] = member
        ns:Debug(("got %d %s from %s"):format(got, kind == "E" and "quests" or "gaps", name))
        ns:DataChanged()
    end
end

ns:On("CHAT_MSG_ADDON", OnMessage)
