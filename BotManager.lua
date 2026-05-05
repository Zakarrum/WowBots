-------------------------------------------------------------------------------
-- BotManager
-- Manages AzerothCore playerbots via a draggable panel + minimap button.
-------------------------------------------------------------------------------

local ADDON_NAME = "BotManager"

local DB_DEFAULTS = {
    minimapAngle = 225,
    knownBots = {},
}

-- Runtime state (not persisted)
local trackedBots   = {}
local selectedClass = "Warrior"
local selectedLevel = 60
local selectedRole  = "DPS"

local DEBUG = true
local debugLines = {}

-------------------------------------------------------------------------------
-- Debug window (toggle with /bmd — text is selectable/copyable)
-------------------------------------------------------------------------------

local debugFrame = CreateFrame("Frame", "BotManagerDebugFrame", UIParent)
debugFrame:SetWidth(500)
debugFrame:SetHeight(340)
debugFrame:SetPoint("CENTER", UIParent, "CENTER", 0, -120)
debugFrame:SetFrameStrata("DIALOG")
debugFrame:SetBackdrop({
    bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 },
})
debugFrame:SetMovable(true)
debugFrame:EnableMouse(true)
debugFrame:RegisterForDrag("LeftButton")
debugFrame:SetScript("OnDragStart", debugFrame.StartMoving)
debugFrame:SetScript("OnDragStop",  debugFrame.StopMovingOrSizing)
debugFrame:Hide()

local debugTitle = debugFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
debugTitle:SetPoint("TOP", debugFrame, "TOP", 0, -10)
debugTitle:SetText("BotManager Debug  (select + Ctrl-C to copy)")

local debugClose = CreateFrame("Button", nil, debugFrame, "UIPanelCloseButton")
debugClose:SetPoint("TOPRIGHT", debugFrame, "TOPRIGHT", -4, -4)

local debugClearBtn = CreateFrame("Button", nil, debugFrame, "UIPanelButtonTemplate")
debugClearBtn:SetWidth(60)
debugClearBtn:SetHeight(22)
debugClearBtn:SetPoint("BOTTOMLEFT", debugFrame, "BOTTOMLEFT", 12, 8)
debugClearBtn:SetText("Clear")

local debugSF = CreateFrame("ScrollFrame", "BotManagerDebugSF", debugFrame, "UIPanelScrollFrameTemplate")
debugSF:SetPoint("TOPLEFT",     debugFrame, "TOPLEFT",     10, -28)
debugSF:SetPoint("BOTTOMRIGHT", debugFrame, "BOTTOMRIGHT", -28, 38)

local debugEB = CreateFrame("EditBox", "BotManagerDebugEB", debugSF)
debugEB:SetMultiLine(true)
debugEB:SetMaxLetters(0)
debugEB:SetAutoFocus(false)
debugEB:SetFontObject(ChatFontNormal)
debugEB:SetWidth(440)
debugEB:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
debugEB:SetScript("OnChar", function(self, ch) end)
debugSF:SetScrollChild(debugEB)

local function RefreshDebugWindow()
    debugEB:SetText(table.concat(debugLines, "\n"))
    debugSF:SetVerticalScroll(debugSF:GetVerticalScrollRange())
end

debugClearBtn:SetScript("OnClick", function()
    debugLines = {}
    RefreshDebugWindow()
end)

debugFrame:SetScript("OnShow", RefreshDebugWindow)

local function dbg(msg)
    if not DEBUG then return end
    local line = tostring(msg)
    debugLines[#debugLines + 1] = line
    if #debugLines > 300 then table.remove(debugLines, 1) end
    if debugFrame:IsShown() then RefreshDebugWindow() end
end

local CLASSES = {
    "Warrior", "Paladin", "Hunter", "Rogue", "Priest",
    "Death Knight", "Shaman", "Mage", "Warlock", "Druid",
}
local ROLES     = { "DPS", "Tank", "Healer" }
local ROLE_CMDS = { DPS = "dps", Tank = "tank", Healer = "heal" }

-- Best default spec per class per role for WotLK 3.3.5
local ROLE_SPECS = {
    Warrior          = { DPS = "fury",         Tank = "protection",   Healer = nil },
    Paladin          = { DPS = "retribution",  Tank = "protection",   Healer = "holy" },
    Hunter           = { DPS = "marksmanship", Tank = nil,            Healer = nil },
    Rogue            = { DPS = "combat",       Tank = nil,            Healer = nil },
    Priest           = { DPS = "shadow",       Tank = nil,            Healer = "holy" },
    ["Death Knight"] = { DPS = "frost",        Tank = "blood",        Healer = nil },
    Shaman           = { DPS = "enhancement",  Tank = nil,            Healer = "restoration" },
    Mage             = { DPS = "frost",        Tank = nil,            Healer = nil },
    Warlock          = { DPS = "affliction",   Tank = nil,            Healer = nil },
    Druid            = { DPS = "balance",      Tank = "feral combat", Healer = "restoration" },
}

local ROW_HEIGHT   = 26
local PANEL_WIDTH  = 360
local PANEL_HEIGHT = 420

-- Column offsets for party rows
local COL_LABEL  = 128
local COL_MARK   = 182
local COL_REMOVE = 252

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

local function SendBot(cmd)
    SendChatMessage(cmd, "SAY")
end

local function SendParty(cmd)
    SendChatMessage(cmd, "PARTY")
end

local function SendWhisper(name, cmd)
    dbg("whisper " .. name .. ": " .. cmd)
    SendChatMessage(cmd, "WHISPER", nil, name)
end

local function SaveBots()
    BotManagerDB.knownBots = {}
    for name in pairs(trackedBots) do
        BotManagerDB.knownBots[name] = true
    end
end

local function AddTrackedBot(name)
    trackedBots[name] = true
    SaveBots()
end

local function RemoveTrackedBot(name)
    trackedBots[name] = nil
    SaveBots()
end

-- Shared anchor frame for EasyMenu
local menuAnchor = CreateFrame("Frame", "BotManagerMenuAnchor", UIParent, "UIDropDownMenuTemplate")

-------------------------------------------------------------------------------
-- Main panel
-------------------------------------------------------------------------------

local panel = CreateFrame("Frame", "BotManagerFrame", UIParent)
panel:SetWidth(PANEL_WIDTH)
panel:SetHeight(PANEL_HEIGHT)
panel:SetPoint("CENTER", UIParent, "CENTER")
panel:SetFrameStrata("DIALOG")
panel:SetBackdrop({
    bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile     = true, tileSize = 32, edgeSize = 32,
    insets   = { left = 11, right = 12, top = 12, bottom = 11 },
})
panel:SetMovable(true)
panel:EnableMouse(true)
panel:RegisterForDrag("LeftButton")
panel:SetScript("OnDragStart", panel.StartMoving)
panel:SetScript("OnDragStop",  panel.StopMovingOrSizing)
panel:Hide()

local titleText = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
titleText:SetPoint("TOP", panel, "TOP", 0, -16)
titleText:SetText("Bot Manager")

local closeBtn = CreateFrame("Button", nil, panel, "UIPanelCloseButton")
closeBtn:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -4, -4)

-------------------------------------------------------------------------------
-- Class selector
-------------------------------------------------------------------------------

local classLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
classLabel:SetPoint("TOPLEFT", panel, "TOPLEFT", 18, -48)
classLabel:SetText("Class:")

local classBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
classBtn:SetWidth(160)
classBtn:SetHeight(22)
classBtn:SetPoint("TOPLEFT", panel, "TOPLEFT", 62, -44)
classBtn:SetText(selectedClass .. " v")
classBtn:SetScript("OnClick", function()
    local menuList = {}
    for _, cls in ipairs(CLASSES) do
        local c = cls
        menuList[#menuList + 1] = {
            text         = cls,
            notCheckable = true,
            func         = function()
                selectedClass = c
                classBtn:SetText(c .. " v")
            end,
        }
    end
    EasyMenu(menuList, menuAnchor, "cursor", 0, 0, "MENU")
end)

-------------------------------------------------------------------------------
-- Level selector
-------------------------------------------------------------------------------

local levelLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
levelLabel:SetPoint("TOPLEFT", panel, "TOPLEFT", 18, -80)
levelLabel:SetText("Level:")

local levelBox = CreateFrame("EditBox", "BotManagerLevelBox", panel, "InputBoxTemplate")
levelBox:SetWidth(50)
levelBox:SetHeight(20)
levelBox:SetPoint("TOPLEFT", panel, "TOPLEFT", 62, -76)
levelBox:SetNumeric(true)
levelBox:SetMaxLetters(2)
levelBox:SetAutoFocus(false)
levelBox:SetText(tostring(selectedLevel))

local function CommitLevel(self)
    local val = tonumber(self:GetText())
    if val then
        selectedLevel = math.max(1, math.min(80, val))
    end
    self:SetText(tostring(selectedLevel))
    self:ClearFocus()
end
levelBox:SetScript("OnEnterPressed", CommitLevel)
levelBox:SetScript("OnEditFocusLost", CommitLevel)

-------------------------------------------------------------------------------
-- Role selector
-------------------------------------------------------------------------------

local roleLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
roleLabel:SetPoint("TOPLEFT", panel, "TOPLEFT", 18, -112)
roleLabel:SetText("Role:")

local roleButtons = {}
local ROLE_X = { 62, 110, 158 }

local function UpdateRoleButtons()
    for _, rb in ipairs(roleButtons) do
        if rb.role == selectedRole then
            rb:SetText("|cff00ff00" .. rb.role .. "|r")
        else
            rb:SetText(rb.role)
        end
    end
end

for i, role in ipairs(ROLES) do
    local rb = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    rb:SetWidth(44)
    rb:SetHeight(22)
    rb:SetPoint("TOPLEFT", panel, "TOPLEFT", ROLE_X[i], -106)
    rb.role = role
    rb:SetScript("OnClick", function()
        selectedRole = role
        UpdateRoleButtons()
    end)
    roleButtons[i] = rb
end
UpdateRoleButtons()

-------------------------------------------------------------------------------
-- Add Bot / Remove All Bots
-------------------------------------------------------------------------------

local addBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
addBtn:SetWidth(100)
addBtn:SetHeight(26)
addBtn:SetPoint("TOPLEFT", panel, "TOPLEFT", 18, -142)
addBtn:SetText("Add Bot")
addBtn:SetScript("OnClick", function()
    local cls = selectedClass:lower():gsub(" ", "")
    dbg("addclass " .. cls)
    SendBot(".playerbots bot addclass " .. cls)
end)

local removeAllBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
removeAllBtn:SetWidth(130)
removeAllBtn:SetHeight(26)
removeAllBtn:SetPoint("TOPLEFT", addBtn, "TOPRIGHT", 10, 0)
removeAllBtn:SetText("Remove All Bots")
removeAllBtn:SetScript("OnClick", function()
    local names = {}
    for name in pairs(trackedBots) do
        names[#names + 1] = name
    end
    if #names == 0 then return end
    SendBot(".playerbots bot remove " .. table.concat(names, ","))
    trackedBots = {}
    SaveBots()
end)

-------------------------------------------------------------------------------
-- Divider + party header
-------------------------------------------------------------------------------

local divider = panel:CreateTexture(nil, "ARTWORK")
divider:SetHeight(2)
divider:SetPoint("TOPLEFT",  panel, "TOPLEFT",  14, -178)
divider:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -14, -178)
divider:SetTexture("Interface\\Tooltips\\UI-Tooltip-Border")

local partyHeader = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
partyHeader:SetPoint("TOPLEFT", panel, "TOPLEFT", 18, -188)
partyHeader:SetText("Party Members")

-------------------------------------------------------------------------------
-- Scroll list for party members
-- Bug fix: use fixed pixel width instead of GetWidth() which returns 0 at load
-------------------------------------------------------------------------------

local scrollFrame = CreateFrame("ScrollFrame", "BotManagerScrollFrame", panel, "UIPanelScrollFrameTemplate")
scrollFrame:SetPoint("TOPLEFT",  panel, "TOPLEFT",  14, -208)
scrollFrame:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -30, 14)

local scrollChild = CreateFrame("Frame", "BotManagerScrollChild", scrollFrame)
scrollChild:SetWidth(PANEL_WIDTH - 44)
scrollChild:SetHeight(1)
scrollFrame:SetScrollChild(scrollChild)

local MAX_ROWS = 4
local rows = {}

for i = 1, MAX_ROWS do
    local row = CreateFrame("Frame", nil, scrollChild)
    row:SetHeight(ROW_HEIGHT)
    row:SetPoint("TOPLEFT",  scrollChild, "TOPLEFT",  0, -(i - 1) * ROW_HEIGHT)
    row:SetPoint("TOPRIGHT", scrollChild, "TOPRIGHT",  0, -(i - 1) * ROW_HEIGHT)

    row.nameText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.nameText:SetPoint("TOPLEFT",    row, "TOPLEFT",    4, 0)
    row.nameText:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 4, 0)
    row.nameText:SetWidth(120)
    row.nameText:SetJustifyH("LEFT")

    row.labelText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.labelText:SetPoint("TOPLEFT",    row, "TOPLEFT",    COL_LABEL, 0)
    row.labelText:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", COL_LABEL, 0)
    row.labelText:SetWidth(50)
    row.labelText:SetJustifyH("LEFT")

    row.markBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    row.markBtn:SetWidth(66)
    row.markBtn:SetHeight(20)
    row.markBtn:SetPoint("LEFT", row, "LEFT", COL_MARK, 0)

    row.removeBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    row.removeBtn:SetWidth(60)
    row.removeBtn:SetHeight(20)
    row.removeBtn:SetPoint("LEFT", row, "LEFT", COL_REMOVE, 0)
    row.removeBtn:SetText("Remove")

    row:Hide()
    rows[i] = row
end

local function RefreshPartyList()
    local count = GetNumPartyMembers()
    scrollChild:SetHeight(math.max(1, count * ROW_HEIGHT))

    for i = 1, MAX_ROWS do
        local row = rows[i]
        if i <= count then
            local name  = UnitName("party" .. i) or ("Party " .. i)
            local isBot = trackedBots[name] == true

            row.nameText:SetText(name)

            if isBot then
                row.labelText:SetText("|cffff9900Bot|r")
                row.markBtn:SetText("Unmark")
                row.removeBtn:Show()
            else
                row.labelText:SetText("|cff00ff00Player|r")
                row.markBtn:SetText("Mark Bot")
                row.removeBtn:Hide()
            end

            local capturedName = name
            row.markBtn:SetScript("OnClick", function()
                if trackedBots[capturedName] then
                    RemoveTrackedBot(capturedName)
                    RefreshPartyList()
                else
                    AddTrackedBot(capturedName)
                    RefreshPartyList()

                    local roleCmd  = ROLE_CMDS[selectedRole]
                    local specName = ROLE_SPECS[selectedClass] and ROLE_SPECS[selectedClass][selectedRole]
                    local lvl      = math.max(1, math.min(80, tonumber(levelBox:GetText()) or selectedLevel))
                    dbg("lvl=" .. lvl)

                    local lvlCmd = ".character level " .. capturedName .. " " .. lvl
                    dbg("level: " .. lvlCmd)
                    SendBot(lvlCmd)

                    -- Wave 1 (3s): maintenance + autogear — stabilize bot at new level
                    local e1 = 0
                    local t1 = CreateFrame("Frame")
                    t1:SetScript("OnUpdate", function(self, dt)
                        e1 = e1 + dt
                        if e1 < 3.0 then return end
                        self:SetScript("OnUpdate", nil)
                        SendWhisper(capturedName, "maintenance")
                        SendWhisper(capturedName, "autogear")
                    end)

                    -- Wave 2 (8s): talents + role — bot is stable, now spec it
                    local e2 = 0
                    local t2 = CreateFrame("Frame")
                    t2:SetScript("OnUpdate", function(self, dt)
                        e2 = e2 + dt
                        if e2 < 8.0 then return end
                        self:SetScript("OnUpdate", nil)

                        if specName then
                            SendWhisper(capturedName, "talents spec " .. specName)
                        else
                            dbg("no spec for " .. selectedClass .. "/" .. selectedRole)
                        end

                        SendWhisper(capturedName, "co -tank,-heal,-dps")
                        SendWhisper(capturedName, "co +" .. roleCmd)
                    end)
                end
            end)

            -- Bug fix: call RefreshPartyList after remove so the row updates immediately
            row.removeBtn:SetScript("OnClick", function()
                SendBot(".playerbots bot remove " .. capturedName)
                RemoveTrackedBot(capturedName)
                RefreshPartyList()
            end)

            row:Show()
        else
            row:Hide()
        end
    end
end

-------------------------------------------------------------------------------
-- Minimap button
-------------------------------------------------------------------------------

local minimapBtn

local function UpdateMinimapButtonPosition()
    local angle = math.rad(BotManagerDB.minimapAngle or 225)
    minimapBtn:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * 80, math.sin(angle) * 80)
end

local function CreateMinimapButton()
    minimapBtn = CreateFrame("Button", "BotManagerMinimapButton", Minimap)
    minimapBtn:SetWidth(31)
    minimapBtn:SetHeight(31)
    minimapBtn:SetFrameStrata("MEDIUM")
    minimapBtn:SetToplevel(true)
    minimapBtn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    local icon = minimapBtn:CreateTexture(nil, "BACKGROUND")
    icon:SetTexture("Interface\\Icons\\INV_Misc_Head_Orc_01")
    icon:SetWidth(20)
    icon:SetHeight(20)
    icon:SetPoint("TOPLEFT", minimapBtn, "TOPLEFT", 4, -3)

    local border = minimapBtn:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetWidth(53)
    border:SetHeight(53)
    border:SetPoint("TOPLEFT", minimapBtn, "TOPLEFT", -11, 11)

    minimapBtn:RegisterForClicks("LeftButtonUp")
    minimapBtn:RegisterForDrag("LeftButton")
    minimapBtn:SetMovable(true)

    minimapBtn:SetScript("OnClick", function(self, btn)
        if panel:IsShown() then
            panel:Hide()
        else
            panel:Show()
            RefreshPartyList()
        end
    end)

    minimapBtn:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", function(self)
            local mx, my = Minimap:GetCenter()
            local cx, cy = GetCursorPosition()
            local scale  = UIParent:GetEffectiveScale()
            local angle  = math.deg(math.atan2(cy / scale - my, cx / scale - mx))
            BotManagerDB.minimapAngle = angle
            UpdateMinimapButtonPosition()
        end)
    end)
    minimapBtn:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
    end)

    UpdateMinimapButtonPosition()
end

-------------------------------------------------------------------------------
-- Event frame
-------------------------------------------------------------------------------

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("PARTY_MEMBERS_CHANGED")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")

eventFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        BotManagerDB = BotManagerDB or {}
        if BotManagerDB.minimapAngle == nil then
            BotManagerDB.minimapAngle = DB_DEFAULTS.minimapAngle
        end
        BotManagerDB.knownBots = BotManagerDB.knownBots or {}
        for name in pairs(BotManagerDB.knownBots) do
            trackedBots[name] = true
        end

    elseif event == "PLAYER_LOGIN" then
        CreateMinimapButton()

    elseif event == "PARTY_MEMBERS_CHANGED" or event == "PLAYER_ENTERING_WORLD" then
        if panel:IsShown() then
            RefreshPartyList()
        end
    end
end)

-------------------------------------------------------------------------------
-- Slash commands
-------------------------------------------------------------------------------

SLASH_BOTMANAGER1 = "/bm"
SLASH_BOTMANAGER2 = "/botmanager"
SlashCmdList["BOTMANAGER"] = function()
    if panel:IsShown() then
        panel:Hide()
    else
        panel:Show()
        RefreshPartyList()
    end
end

SLASH_BMDEBUG1 = "/bmd"
SlashCmdList["BMDEBUG"] = function()
    if debugFrame:IsShown() then
        debugFrame:Hide()
    else
        debugFrame:Show()
    end
end
