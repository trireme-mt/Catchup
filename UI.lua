-- UI: a movable window listing, per group member, the quests they're on that
-- you're missing and where to start. Toggle with /catchup; Esc closes it.
local _, ns = ...
local UI = {}
ns.UI = UI

local WIDTH, HEIGHT = 460, 380

function UI:Create()
    if self.frame then return end

    -- BasicFrameTemplateWithInset is a Blizzard template: border, background, close button.
    local f = CreateFrame("Frame", "CatchUpFrame", UIParent, "BasicFrameTemplateWithInset")
    f:SetSize(WIDTH, HEIGHT)
    f:SetFrameStrata("MEDIUM")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint()
        ns.db.ui.point = { point, relPoint, x, y }
    end)
    local saved = ns.db.ui.point
    if saved then
        f:SetPoint(saved[1], UIParent, saved[2], saved[3], saved[4])
    else
        f:SetPoint("CENTER")
    end
    f:SetScript("OnShow", function() UI:Refresh() end)
    f:Hide()
    table.insert(UISpecialFrames, "CatchUpFrame")  -- Esc closes it

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    title:SetPoint("TOP", 0, -5)
    title:SetText("CatchUp - Party Quests")

    local sync = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    sync:SetSize(80, 22)
    sync:SetPoint("BOTTOMRIGHT", -10, 8)
    sync:SetText("Sync")
    sync:SetScript("OnClick", function()
        ns.Comm:Request()
        ns.Comm:BroadcastSoon()
    end)

    local footer = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    footer:SetPoint("BOTTOMLEFT", 14, 14)
    footer:SetText("/catchup help for commands")

    -- Scrollable text area: one multi-line FontString in a scroll child.
    local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 12, -30)
    scroll:SetPoint("BOTTOMRIGHT", -32, 38)
    local child = CreateFrame("Frame", nil, scroll)
    local textWidth = WIDTH - 12 - 32 - 6
    child:SetSize(textWidth, 1)
    scroll:SetScrollChild(child)

    local text = child:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    text:SetPoint("TOPLEFT", 4, -4)
    text:SetWidth(textWidth - 4)
    text:SetJustifyH("LEFT")
    text:SetJustifyV("TOP")
    text:SetSpacing(3)

    self.frame, self.child, self.text = f, child, text
end

function UI:Toggle()
    self:Create()
    self.frame:SetShown(not self.frame:IsShown())
end

local GREY, GREEN, ORANGE, WHITE = "|cff888888", "|cff40ff40", "|cffff9933", "|cffffffff"

local function Q(id)
    return "|cffffd100" .. ns.QuestLog:GetTitle(id) .. "|r"
end

local function GapLines(gap, member, lines)
    table.insert(lines, "   " .. Q(gap.target) .. (gap.line and (GREY .. "  (" .. gap.line .. ")|r") or ""))
    local behind = gap.behind and (" - %d step%s behind"):format(gap.behind, gap.behind == 1 and "" or "s") or ""
    if gap.status == "chain" then
        local where = gap.giver and (" from " .. gap.giver) or ""
        local lvl = (gap.level and gap.level > 0) and (" (level " .. gap.level .. ")") or ""
        table.insert(lines, "      " .. ORANGE .. "Start with:|r " .. Q(gap.start) .. where .. lvl .. GREY .. behind .. "|r")
    elseif gap.status == "inprogress" then
        table.insert(lines, "      " .. ORANGE .. "Finish:|r " .. Q(gap.start) .. GREY .. " (in your log)" .. behind .. "|r")
    elseif gap.status == "available" then
        table.insert(lines, "      " .. GREEN .. "You can do this now - ask " .. member .. " to share it|r")
    elseif gap.status == "unknown" then
        table.insert(lines, "      " .. GREY .. "No chain data for this quest|r")
    end
end

function UI:Refresh()
    if not (self.frame and self.frame:IsShown()) then return end
    local lines = {}
    local members = ns.Chains:AnalyzeParty()

    if #members == 0 then
        table.insert(lines, GREY .. "You're not in a group. Join a party with people who also have CatchUp installed.|r")
    end

    if #members > 0 then table.insert(lines, "|cffffd100WHAT YOU'RE MISSING|r") end
    for _, m in ipairs(members) do
        if not m.hasAddon then
            table.insert(lines, WHITE .. m.name .. "|r" .. GREY .. " - no data (CatchUp not installed, or still syncing)|r")
        else
            local shown, hidden = {}, 0
            for _, gap in ipairs(m.gaps) do
                if gap.status ~= "unknown" or ns.db.showUnknown then
                    table.insert(shown, gap)
                else
                    hidden = hidden + 1
                end
            end
            table.insert(lines, ("%s%s|r %s- %d quest%s, %d you're missing|r")
                :format(WHITE, m.name, GREY, m.total, m.total == 1 and "" or "s", #m.gaps))
            for _, gap in ipairs(shown) do GapLines(gap, m.name, lines) end
            if hidden > 0 then
                table.insert(lines, ("   %s+%d with no chain data (/catchup unknown to show)|r"):format(GREY, hidden))
            end
            if #m.gaps == 0 then
                table.insert(lines, "   " .. GREEN .. "You're caught up with " .. m.name .. ".|r")
            end
        end
        table.insert(lines, " ")
    end

    -- Second section: what other people are behind on (reported by their CatchUp).
    local behind = ns.Chains:AnalyzeGroupGaps()
    if #behind > 0 then
        table.insert(lines, "|cffffd100WHO'S BEHIND|r")
        for _, m in ipairs(behind) do
            table.insert(lines, ("%s%s|r %s- behind on %d quest%s|r")
                :format(WHITE, m.name, GREY, #m.gaps, #m.gaps == 1 and "" or "s"))
            for _, gap in ipairs(m.gaps) do
                local who = #gap.haveIt > 0 and (GREY .. "  (" .. table.concat(gap.haveIt, ", ") .. " on it)|r") or ""
                table.insert(lines, "   " .. Q(gap.target) .. who)
                local steps = gap.behind and (" - %d step%s behind"):format(gap.behind, gap.behind == 1 and "" or "s") or ""
                if gap.status == "chain" then
                    local where = gap.giver and (" from " .. gap.giver) or ""
                    table.insert(lines, "      " .. ORANGE .. "Needs to start with:|r " .. Q(gap.start) .. where .. GREY .. steps .. "|r")
                elseif gap.status == "inprogress" then
                    table.insert(lines, "      " .. ORANGE .. "Working on:|r " .. Q(gap.start) .. GREY .. steps .. "|r")
                elseif gap.status == "available" then
                    table.insert(lines, "      " .. GREEN .. "Can take it now - share it with " .. m.name .. "|r")
                end
            end
        end
        table.insert(lines, " ")
    end

    self.text:SetText(table.concat(lines, "\n"))
    self.child:SetHeight(self.text:GetStringHeight() + 10)
end
