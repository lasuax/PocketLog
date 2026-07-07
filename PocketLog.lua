local frame = CreateFrame("Frame")
frame:RegisterEvent("VARIABLES_LOADED")
frame:RegisterEvent("LOOT_OPENED")
frame:RegisterEvent("LOOT_SLOT_CLEARED")
frame:RegisterEvent("CHAT_MSG_SPELL_SELF_BUFF")

local sessionGold, sessionCount, sessionItems = 0, 0, {}
local sessionBoxGold, sessionBoxItems = 0, {}
local activeLootCache = {}
local slotClearedThisWindow = false
local sessionPaused = false
local pauseStarted = nil

-- Current loot source.
-- nil   = ordinary loot
-- "pick" = pickpocket
-- "box"  = junkbox
local lootMode = nil

local function FormatMoney(amt)
    local g, s, c = math.floor(amt / 10000), math.floor(math.mod(amt, 10000) / 100), math.mod(amt, 100)
    local str = ""
    if g > 0 then
        str = str .. g .. "g "
    end
    if s > 0 or g > 0 then
        str = str .. s .. "s "
    end
    return str .. c .. "c"
end

local function FormatElapsedTime(seconds)

    seconds = math.floor(seconds)

    local hours = math.floor(seconds / 3600)
    local minutes = math.floor(math.mod(seconds, 3600) / 60)
    local secs = math.mod(seconds, 60)

    if hours > 0 then
        return string.format("%02d:%02d:%02d", hours, minutes, secs)
    else
        return string.format("%02d:%02d", minutes, secs)
    end

end

local function CreateHUDRow(parent, anchor, labelText, spacing)

    spacing = spacing or -2

    -- Give extra space after the title.
    if anchor == hudTitle then
        spacing = -8
    end

    local label = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    label:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, spacing)
    label:SetWidth(90)
    label:SetJustifyH("LEFT")
    label:SetText("|cffFFD100"..labelText.."|r")

    local colon = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    colon:SetPoint("LEFT", label, "RIGHT", 0, 0)
    colon:SetText(":")

    local value = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    value:SetPoint("LEFT", colon, "RIGHT", 5, 0)

    return label, value
end

local hudFrame = CreateFrame("Frame", "PocketLogHUDFrame", UIParent)
hudFrame:SetWidth(170)
hudFrame:SetHeight(70)
hudFrame:SetPoint("CENTER", UIParent, "CENTER", 100, 100)
hudFrame:SetFrameStrata("HIGH")
hudFrame:SetFrameLevel(1)
hudFrame:SetClampedToScreen(true)
hudFrame:SetToplevel(true)
hudFrame:SetBackdrop({
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true,
    tileSize = 16,
    edgeSize = 16,
    insets = {
        left = 4,
        right = 4,
        top = 4,
        bottom = 4
    }
})
hudFrame:SetBackdropColor(0, 0, 0, 0.4)
hudFrame:SetBackdropBorderColor(0.3, 0.3, 0.3, 0.6)
hudFrame:SetMovable(true)
hudFrame:EnableMouse(true)
hudFrame:RegisterForDrag("LeftButton")
hudFrame:SetScript("OnDragStart", function()
    this:StartMoving()
end)
hudFrame:SetScript("OnDragStop", function()
    this:StopMovingOrSizing()
    if PocketLog_Data then
        local point, _, relativePoint, x, y = this:GetPoint()
        PocketLog_Data.HUD_Point = point
        PocketLog_Data.HUD_RelativePoint = relativePoint
        PocketLog_Data.HUD_X, PocketLog_Data.HUD_Y = x, y
    end
end)

local hudTitle = hudFrame:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
hudTitle:SetPoint("TOPLEFT", hudFrame, "TOPLEFT", 10, -8)
hudTitle:SetText("|cff00ff00PocketLog|r")
local hudLabelTargets, hudValueTargets = CreateHUDRow(hudFrame, hudTitle, "Pickpockets", -8)
local hudLabelGold, hudValueGold = CreateHUDRow(hudFrame, hudLabelTargets, "Gold")
local hudLabelAverage, hudValueAverage = CreateHUDRow(hudFrame, hudLabelGold, "Avg Value")

local function UpdateHUDText()

    local average = 0

    if sessionCount > 0 then
        average = math.floor(sessionGold / sessionCount)
    end

    hudValueTargets:SetText(sessionCount)
    hudValueGold:SetText(FormatMoney(sessionGold))
    hudValueAverage:SetText(FormatMoney(average))

    if sessionPaused then

        hudTitle:SetText("|cffff4040PocketLog (Paused)|r")

    elseif sessionStartTime then

        hudTitle:SetText(string.format("|cff00ff00PocketLog|r [%s]", FormatElapsedTime(GetTime() - sessionStartTime)))

    else

        hudTitle:SetText("|cff00ff00PocketLog|r")

    end

end

local hudRefreshTimer = nil
local hudUpdateTimer = 0

hudFrame:SetScript("OnUpdate", function()

    -- Delayed refresh after loot
    if hudRefreshTimer and GetTime() >= hudRefreshTimer then
        UpdateHUDText()
        hudRefreshTimer = nil
    end

    -- Live timer update once per second
    if sessionStartTime and not sessionPaused then

        hudUpdateTimer = hudUpdateTimer + arg1

        if hudUpdateTimer >= 1 then
            hudUpdateTimer = 0
            UpdateHUDText()
        end

    end

end)

-- Create a dedicated PocketLog window to display summaries (avoids chat spam)
local pocketWindow = CreateFrame("Frame", "PocketLogWindow", UIParent)
pocketWindow:SetWidth(380)
pocketWindow:SetHeight(380)
pocketWindow:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
pocketWindow:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true,
    tileSize = 32,
    edgeSize = 32,
    insets = {
        left = 8,
        right = 8,
        top = 8,
        bottom = 8
    }
})
pocketWindow:SetMovable(true)
pocketWindow:EnableMouse(true)
pocketWindow:RegisterForDrag("LeftButton")
pocketWindow:SetScript("OnDragStart", function()
    this:StartMoving()
end)
pocketWindow:SetScript("OnDragStop", function()
    this:StopMovingOrSizing()
end)
pocketWindow:Hide()

local pTitle = pocketWindow:CreateFontString(nil, "ARTWORK", "GameFontNormal")
pTitle:SetPoint("TOP", pocketWindow, "TOP", 0, -8)
pTitle:SetText("PocketLog Statistics")

-- Scroll area: use a ScrollFrame with a FontString child to display lines
local scrollFrame = CreateFrame("ScrollFrame", "PocketLogScrollFrame", pocketWindow, "UIPanelScrollFrameTemplate")
scrollFrame:SetPoint("TOPLEFT", pocketWindow, "TOPLEFT", 12, -32)
scrollFrame:SetPoint("BOTTOMRIGHT", pocketWindow, "BOTTOMRIGHT", -30, 140)
local scrollbar = getglobal(scrollFrame:GetName() .. "ScrollBar")

if scrollbar then
    scrollbar:SetScript("OnValueChanged", function()
        scrollFrame:SetVerticalScroll(arg1)
    end)
end

scrollFrame:EnableMouseWheel(true)

scrollFrame:SetScript("OnMouseWheel", function()

    local current = scrollFrame:GetVerticalScroll()
    local minv, maxv = scrollbar:GetMinMaxValues()

    local step = 20

    if arg1 > 0 then
        current = current - step
    else
        current = current + step
    end

    if current < minv then
        current = minv
    elseif current > maxv then
        current = maxv
    end

    scrollFrame:SetVerticalScroll(current)
    scrollbar:SetValue(current)

end)
local scrollChild = CreateFrame("Frame", "PocketLogScrollChild", scrollFrame)
scrollFrame:SetScrollChild(scrollChild)
local childWidth = 380 - 12 - 30 - 16 -- approximate inner width with padding
scrollChild:SetWidth(childWidth)
scrollChild:SetPoint("TOPLEFT", scrollFrame, "TOPLEFT", 0, 0)
local pScrollText = scrollChild:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
pScrollText:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 0, 0)
pScrollText:SetWidth(childWidth)
pScrollText:SetJustifyH("LEFT")

local pScroll = {
    lines = {}
}

function pScroll:Clear()

    self.lines = {}

end

function pScroll:AddMessage(text)

    table.insert(self.lines, text)

end

function pScroll:Refresh()

    local output = table.concat(self.lines, "\n")

    pScrollText:SetText(output)

    local h = pScrollText:GetHeight()

    if h < scrollFrame:GetHeight() then
        h = scrollFrame:GetHeight()
    end

    scrollChild:SetHeight(h)

    local maxScroll = math.max(0, h - scrollFrame:GetHeight())

    if scrollbar then
        scrollbar:SetMinMaxValues(0, maxScroll)
        scrollbar:SetValue(0)
    end

    scrollFrame:SetVerticalScroll(0)

end

local resetOptionRows = {{
    key = "StolenGold",
    label = "Stolen Gold"
}, {
    key = "StolenItems",
    label = "Stolen Items"
}, {
    key = "JunkboxGold",
    label = "Junkbox Gold"
}, {
    key = "JunkboxItems",
    label = "Junkbox Items"
}}
local resetCheckboxes = {}

local function ApplyResetSelectionsToUI()
    if not PocketLog_Data or not PocketLog_Data.ResetSelections then
        return
    end
    for _, row in ipairs(resetOptionRows) do
        local settings = PocketLog_Data.ResetSelections[row.key] or {
            Session = false,
            AllTime = false
        }
        if resetCheckboxes[row.key] then
            resetCheckboxes[row.key].Session:SetChecked(settings.Session and 1 or nil)
            resetCheckboxes[row.key].AllTime:SetChecked(settings.AllTime and 1 or nil)
        end
    end
end

local function SaveResetSelection(key, column, value)
    if not PocketLog_Data then
        return
    end
    if not PocketLog_Data.ResetSelections then
        PocketLog_Data.ResetSelections = {}
    end
    if not PocketLog_Data.ResetSelections[key] then
        PocketLog_Data.ResetSelections[key] = {
            Session = false,
            AllTime = false
        }
    end
    PocketLog_Data.ResetSelections[key][column] = value
end

local function CreateResetCheckbox(name, parent, x, y, key, column)
    local cb = CreateFrame("CheckButton", name, parent, "UICheckButtonTemplate")
    cb:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    cb:SetScript("OnClick", function()
        SaveResetSelection(key, column, this:GetChecked() == 1)
    end)
    return cb
end

-- bottom bar container for window controls (keeps buttons out of the scroll area)
local bottomBar = CreateFrame("Frame", "PocketLogBottomBar", pocketWindow)
bottomBar:SetPoint("BOTTOMLEFT", pocketWindow, "BOTTOMLEFT", 8, 10)
bottomBar:SetPoint("BOTTOMRIGHT", pocketWindow, "BOTTOMRIGHT", -8, 10)
bottomBar:SetHeight(110)

local function ApplyResetSelections()
    if not PocketLog_Data or not PocketLog_Data.ResetSelections then
        return
    end
    local selected = PocketLog_Data.ResetSelections
    local didReset = false

    if selected.StolenGold then
        if selected.StolenGold.Session then
            sessionGold = 0
            sessionCount = 0
            sessionStartTime = nil
            didReset = true
        end
        if selected.StolenGold.AllTime then
            PocketLog_Data.Gold = 0
            if PocketLog_Data then
                PocketLog_Data.Count = 0
            end
            didReset = true
        end
    end
    if selected.StolenItems then
        if selected.StolenItems.Session then
            sessionItems = {}
            sessionCount = 0
            sessionStartTime = nil
            didReset = true
        end
        if selected.StolenItems.AllTime then
            PocketLog_Data.Items = {}
            if PocketLog_Data then
                PocketLog_Data.Count = 0
            end
            didReset = true
        end
    end
    if selected.JunkboxGold then
        if selected.JunkboxGold.Session then
            sessionBoxGold = 0
            didReset = true
        end
        if selected.JunkboxGold.AllTime then
            if PocketLog_Data then
                PocketLog_Data.BoxData.Gold = 0
            end
            didReset = true
        end
    end
    if selected.JunkboxItems then
        if selected.JunkboxItems.Session then
            sessionBoxItems = {}
            didReset = true
        end
        if selected.JunkboxItems.AllTime then
            if PocketLog_Data then
                PocketLog_Data.BoxData.Items = {}
            end
            didReset = true
        end
    end

    if didReset then
        UpdateHUDText()
        pScroll:AddMessage("|cff00ff00[PocketLog]|r Selected reset options applied.")
    else
        pScroll:AddMessage("|cff00ff00[PocketLog]|r No reset options selected.")
    end
end

local btnRestoreHUD = CreateFrame("Button", "PL_RestoreHUDBtn", pocketWindow, "UIPanelButtonTemplate")
btnRestoreHUD:SetWidth(100)
btnRestoreHUD:SetHeight(20)
btnRestoreHUD:SetPoint("BOTTOMLEFT", bottomBar, "BOTTOMLEFT", 22, 35)
btnRestoreHUD:SetText("Restore HUD")
btnRestoreHUD:SetScript("OnClick", function()
    if PocketLog_Data then
        PocketLog_Data.ShowHUD = true
    end
    if hudFrame then
        -- reset to default visible position and save
        hudFrame:ClearAllPoints()
        hudFrame:SetPoint("CENTER", UIParent, "CENTER", 100, 100)
        hudFrame:Show()
        UpdateHUDText()
        if PocketLog_Data then
            PocketLog_Data.HUD_Point = "CENTER"
            PocketLog_Data.HUD_RelativePoint = "CENTER"
            PocketLog_Data.HUD_X, PocketLog_Data.HUD_Y = 100, 100
        end
    end
end)

local btnClose = CreateFrame("Button", "PL_WindowCloseBtn", pocketWindow, "UIPanelButtonTemplate")
btnClose:SetWidth(100)
btnClose:SetHeight(22)
btnClose:SetPoint("BOTTOMRIGHT", bottomBar, "BOTTOMRIGHT", -22, 10)
btnClose:SetText("Close")
btnClose:SetScript("OnClick", function()
    pocketWindow:Hide()
end)

-- separator texture between data and options
local separator = pocketWindow:CreateTexture(nil, "ARTWORK")
separator:SetPoint("BOTTOMLEFT", pocketWindow, "BOTTOMLEFT", 8, 140)
separator:SetPoint("BOTTOMRIGHT", pocketWindow, "BOTTOMRIGHT", -8, 140)
separator:SetHeight(2)
-- Use SetTexture with color args for 1.12 compatibility
separator:SetTexture(0.2, 0.2, 0.2, 0.9)

-- separate reset options window
local resetWindow = CreateFrame("Frame", "PocketLogResetWindow", UIParent)
resetWindow:SetWidth(340)
resetWindow:SetHeight(220)
resetWindow:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
resetWindow:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true,
    tileSize = 32,
    edgeSize = 32,
    insets = {
        left = 8,
        right = 8,
        top = 8,
        bottom = 8
    }
})
resetWindow:SetMovable(true)
resetWindow:EnableMouse(true)
resetWindow:RegisterForDrag("LeftButton")
resetWindow:SetScript("OnDragStart", function()
    this:StartMoving()
end)
resetWindow:SetScript("OnDragStop", function()
    this:StopMovingOrSizing()
end)
resetWindow:Hide()

local resetWindowTitle = resetWindow:CreateFontString(nil, "ARTWORK", "GameFontNormal")
resetWindowTitle:SetPoint("TOP", resetWindow, "TOP", 0, -10)
resetWindowTitle:SetText("PocketLog Reset Options")

local resetHeaderSession = resetWindow:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
resetHeaderSession:SetPoint("TOPLEFT", resetWindow, "TOPLEFT", 140, -30)
resetHeaderSession:SetText("Session")
local resetHeaderAllTime = resetWindow:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
resetHeaderAllTime:SetPoint("TOPLEFT", resetWindow, "TOPLEFT", 220, -30)
resetHeaderAllTime:SetText("All-Time")

for index, row in ipairs(resetOptionRows) do
    local yOffset = -50 - ((index - 1) * 30)
    local rowLabel = resetWindow:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    rowLabel:SetPoint("TOPLEFT", resetWindow, "TOPLEFT", 16, yOffset)
    rowLabel:SetText(row.label)

    resetCheckboxes[row.key] = {
        Session = CreateResetCheckbox("PocketLogResetWindow_" .. row.key .. "_Session", resetWindow, 140, yOffset,
            row.key, "Session"),
        AllTime = CreateResetCheckbox("PocketLogResetWindow_" .. row.key .. "_AllTime", resetWindow, 220, yOffset,
            row.key, "AllTime")
    }
end

local resetApplyBtn = CreateFrame("Button", "PL_ResetApplyBtn", resetWindow, "UIPanelButtonTemplate")
resetApplyBtn:SetWidth(100)
resetApplyBtn:SetHeight(22)
resetApplyBtn:SetPoint("BOTTOMLEFT", resetWindow, "BOTTOMLEFT", 30, 14)
resetApplyBtn:SetText("Reset Selected")
resetApplyBtn:SetScript("OnClick", function()
    ApplyResetSelections()
    if resetWindow then
        resetWindow:Hide()
    end
end)

local resetCloseBtn = CreateFrame("Button", "PL_ResetCloseBtn", resetWindow, "UIPanelButtonTemplate")
resetCloseBtn:SetWidth(100)
resetCloseBtn:SetHeight(22)
resetCloseBtn:SetPoint("BOTTOMRIGHT", resetWindow, "BOTTOMRIGHT", -30, 14)
resetCloseBtn:SetText("Close")
resetCloseBtn:SetScript("OnClick", function()
    resetWindow:Hide()
end)

local pauseButton

local function PauseSession()

    if sessionPaused then
        return
    end

    sessionPaused = true
    pauseStarted = GetTime()

    pauseButton:SetText("Resume Session")

    UpdateHUDText()

end

local function ResumeSession()

    if not sessionPaused then
        return
    end

    if sessionStartTime and pauseStarted then
        sessionStartTime = sessionStartTime + (GetTime() - pauseStarted)
    end

    pauseStarted = nil
    sessionPaused = false

    pauseButton:SetText("Pause Session")

    UpdateHUDText()

end

local function TogglePause()

    if sessionPaused then
        ResumeSession()
    else
        PauseSession()
    end

end

-- Options area inside the pocket window (dashboard)
local function CreateWindowButton(name, text, w, x, y, func)
    local btn = CreateFrame("Button", name, bottomBar, "UIPanelButtonTemplate")
    btn:SetWidth(w)
    btn:SetHeight(20)
    btn:SetPoint("BOTTOM", bottomBar, "BOTTOM", x, y)
    btn:SetText(text)
    btn:SetScript("OnClick", func)
    return btn
end

CreateWindowButton("PL_WinResetOptions", "Reset Options", 100, -110, 10, function()
    if resetWindow then
        ApplyResetSelectionsToUI()
        resetWindow:Show()
    end
end)

CreateWindowButton("PL_WinToggleHUD", "Toggle HUD", 100, 110, 35, function()
    if hudFrame:IsShown() then
        hudFrame:Hide()
        if PocketLog_Data then
            PocketLog_Data.ShowHUD = false
        end
    else
        hudFrame:Show()
        if PocketLog_Data then
            PocketLog_Data.ShowHUD = true
        end
    end
end)

CreateWindowButton("PL_WinWipeAll", "Wipe All", 100, 0, 10, function()
    sessionGold, sessionCount, sessionItems, sessionStartTime = 0, 0, {}, nil
    sessionBoxGold, sessionBoxItems = 0, {}
    PocketLog_Data = {
        Gold = 0,
        Count = 0,
        Items = {},
        ShowHUD = true,
        SilentMode = false,
        BoxData = {
            Gold = 0,
            Items = {}
        }
    }
    UpdateHUDText()
    pScroll:AddMessage("|cff00ff00[PocketLog]|r Absolutely all session and all-time records purged.")
end)

pauseButton = CreateWindowButton("PL_WinPause", "Pause Session", 100, 0, 35, TogglePause)

local copyrightText = bottomBar:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
copyrightText:SetPoint("BOTTOMRIGHT", bottomBar, "BOTTOMRIGHT", -12, 110)
copyrightText:SetJustifyH("RIGHT")
copyrightText:SetFont("Fonts\\FRIZQT__.TTF", 8)
copyrightText:SetText("Brought to you by your fellow rogue Critolis ^^,")
local silentCheckWindow =
    CreateFrame("CheckButton", "PocketLogSilentCheckboxWindow", bottomBar, "UICheckButtonTemplate")
silentCheckWindow:SetPoint("BOTTOMLEFT", bottomBar, "BOTTOMLEFT", 12, 74)
getglobal(silentCheckWindow:GetName() .. "Text"):SetText("Disable Live Chat Spams")
-- Initialize checkbox state from saved settings (default: enabled)
if PocketLog_Data == nil or PocketLog_Data.SilentMode then
    silentCheckWindow:SetChecked(1)
else
    silentCheckWindow:SetChecked(nil)
end
silentCheckWindow:SetScript("OnClick", function()
    if not PocketLog_Data then
        PocketLog_Data = {}
    end
    PocketLog_Data.SilentMode = (this:GetChecked() == 1)
end)

local function AddSortedItemList(title, itemTable, emptyText)

    pScroll:AddMessage(title)

    local items = {}

    for name, qty in pairs(itemTable) do
        if qty and qty > 0 then
            table.insert(items, {
                name = name,
                qty = qty
            })
        end
    end

    table.sort(items, function(a, b)

        if a.qty == b.qty then
            return a.name < b.name
        end

        return a.qty > b.qty

    end)

    if table.getn(items) == 0 then
        pScroll:AddMessage(emptyText)
        return
    end

    for _, item in ipairs(items) do

        pScroll:AddMessage(string.format("  %-28s x%d", item.name, item.qty))

    end

end

local function PopulatePocketWindow()
    pScroll:Clear()
    pScroll:AddMessage("|cff00ffff--- Session Gold & Items ---|r")
    pScroll:AddMessage("|cffffff00Gold:|r " .. FormatMoney(sessionGold))
    AddSortedItemList("|cff00ccccItems:|r", sessionItems, "  No items logged yet.")

    pScroll:AddMessage("")

    pScroll:AddMessage("|cff00ffff--- Session Junkbox Gains ---|r")
    pScroll:AddMessage("|cffffff00Gold:|r " .. FormatMoney(sessionBoxGold))
    AddSortedItemList("|cff00ccccItems:|r", sessionBoxItems, "  No junkbox items logged.")

    pScroll:AddMessage("")

    local lGold = (PocketLog_Data and PocketLog_Data.Gold) or 0
    local lItems = (PocketLog_Data and PocketLog_Data.Items) or {}
    pScroll:AddMessage("|cff00ffff--- All-Time ---|r")
    pScroll:AddMessage("|cffffff00Gold:|r " .. FormatMoney(lGold))
    AddSortedItemList("|cff00ccccItems:|r", lItems, "  No historical items logged.")

    pScroll:AddMessage("")

    if PocketLog_Data and PocketLog_Data.BoxData then
        pScroll:AddMessage("|cff00ffff--- Saved Junkbox Contents ---|r")
        pScroll:AddMessage("|cffffff00Gold:|r " .. FormatMoney(PocketLog_Data.BoxData.Gold))
        AddSortedItemList("|cff00ccccItems:|r", PocketLog_Data.BoxData.Items or {}, "  No box items logged.")
    end

    pScroll:Refresh()
end

local function RefreshPocketWindow()

    if pocketWindow and pocketWindow:IsShown() then
        PopulatePocketWindow()
    end

end

local hudOpenPanelButton = CreateFrame("Button", "PocketLogHUDBtn", hudFrame, "UIPanelButtonTemplate")
hudOpenPanelButton:SetWidth(20)
hudOpenPanelButton:SetHeight(18)
hudOpenPanelButton:SetPoint("TOPRIGHT", hudFrame, "TOPRIGHT", -8, -6)
hudOpenPanelButton:SetText("...")
hudOpenPanelButton:SetScript("OnClick", function()
    pocketWindow:Show()
    PopulatePocketWindow()

    scrollFrame:SetVerticalScroll(0)

    if scrollbar then
        scrollbar:SetValue(0)
    end
end)

SLASH_POCKETLOG1 = "/pocket"
SlashCmdList["POCKETLOG"] = function(msg)
    if pocketWindow:IsShown() then
        pocketWindow:Hide()
    else
        pocketWindow:Show()
        PopulatePocketWindow()

        scrollFrame:SetVerticalScroll(0)

        if scrollbar then
            scrollbar:SetValue(0)
        end
        if PocketLog_Data and PocketLog_Data.ShowHUD and hudFrame then
            hudFrame:Show()
            UpdateHUDText()
        end
    end
end

SLASH_POCKETRESET1 = "/pocketreset"
SlashCmdList["POCKETRESET"] = function(msg)
    if resetWindow:IsShown() then
        resetWindow:Hide()
    else
        ApplyResetSelectionsToUI()
        resetWindow:Show()
    end
end

local function GetCoinValue(slot)

    local _, text = GetLootSlotInfo(slot)

    if not text then
        return 0
    end

    text = string.lower(text)

    local value = 0

    local _, _, g = string.find(text, "(%d+) gold")
    local _, _, s = string.find(text, "(%d+) silver")
    local _, _, c = string.find(text, "(%d+) copper")

    if g then
        value = value + tonumber(g) * 10000
    end

    if s then
        value = value + tonumber(s) * 100
    end

    if c then
        value = value + tonumber(c)
    end

    return value

end

local function CacheLoot(source)

    activeLootCache = {}
    slotClearedThisWindow = false

    for slot = 1, GetNumLootItems() do

        local _, name, qty = GetLootSlotInfo(slot)

        if name then

            if LootSlotIsCoin(slot) then

                activeLootCache[slot] = {
                    source = source,
                    isCoin = true,
                    amount = GetCoinValue(slot)
                }

            else

                activeLootCache[slot] = {
                    source = source,
                    isCoin = false,
                    link = GetLootSlotLink(slot) or name,
                    count = qty or 1
                }

            end

        end

    end

end

frame:SetScript("OnEvent", function()
    if event == "VARIABLES_LOADED" then
        if not PocketLog_Data then
            PocketLog_Data = {}
        end
        if PocketLog_Data.Gold == nil then
            PocketLog_Data.Gold = 0
        end
        if PocketLog_Data.Count == nil then
            PocketLog_Data.Count = 0
        end
        if not PocketLog_Data.Items then
            PocketLog_Data.Items = {}
        end
        if PocketLog_Data.SilentMode == nil then
            PocketLog_Data.SilentMode = true
        end
        if PocketLog_Data.ShowHUD == nil then
            PocketLog_Data.ShowHUD = true
        end
        if PocketLog_Data.HUD_X and PocketLog_Data.HUD_Y then
            hudFrame:ClearAllPoints()
            if PocketLog_Data.HUD_Point and PocketLog_Data.HUD_RelativePoint then
                hudFrame:SetPoint(PocketLog_Data.HUD_Point, UIParent, PocketLog_Data.HUD_RelativePoint,
                    PocketLog_Data.HUD_X, PocketLog_Data.HUD_Y)
            else
                hudFrame:SetPoint("CENTER", UIParent, "CENTER", PocketLog_Data.HUD_X, PocketLog_Data.HUD_Y)
            end
        end
        if PocketLog_Data.ShowHUD then
            hudFrame:Show()
        else
            hudFrame:Hide()
        end
        hudFrame:SetClampedToScreen(true)
        if not PocketLog_Data.BoxData then
            PocketLog_Data.BoxData = {
                Gold = 0,
                Items = {}
            }
        end
        if not PocketLog_Data.ResetSelections then
            PocketLog_Data.ResetSelections = {
                StolenGold = {
                    Session = false,
                    AllTime = false
                },
                StolenItems = {
                    Session = false,
                    AllTime = false
                },
                JunkboxGold = {
                    Session = false,
                    AllTime = false
                },
                JunkboxItems = {
                    Session = false,
                    AllTime = false
                }
            }
        end

        ApplyResetSelectionsToUI()
        -- Sync silent checkbox state after saved-vars load (ensure UI reflects saved value)
        if silentCheckWindow then
            if PocketLog_Data.SilentMode then
                silentCheckWindow:SetChecked(1)
            else
                silentCheckWindow:SetChecked(nil)
            end
        end
        UpdateHUDText()
        return
    end
    if event == "CHAT_MSG_SPELL_SELF_BUFF" and arg1 then
        local castText = string.lower(arg1)
        if string.find(castText, "junkbox") then
            lootMode = "box"
            if string.find(castText, "heavy") then
                currentBoxName = "Heavy Junkbox"
            elseif string.find(castText, "sturdy") then
                currentBoxName = "Sturdy Junkbox"
            else
                currentBoxName = "Battered Junkbox"
            end
            return
        end
    end
    if event == "LOOT_OPENED" then
        activeLootCache = {}
        slotClearedThisWindow = false

        if lootMode == "box" then
            CacheLoot("box")
            lootMode = nil
        elseif UnitExists("target") and not UnitIsDead("target") and not UnitIsPlayer("target") then
            CacheLoot("pick")
        else
            lootMode = nil
            return
        end
    end

    if event == "LOOT_SLOT_CLEARED" and arg1 then
        if sessionPaused then
            return
        end
        local data = activeLootCache[tonumber(arg1)]
        if data then
            local silent = (PocketLog_Data and PocketLog_Data.SilentMode)

            -- PROCESS LOCKBOX EXTRACTIONS
            if data.source == "box" then
                -- PROCESS STANDARD PICKPOCKETING
                if not PocketLog_Data.BoxData then
                    PocketLog_Data.BoxData = {
                        Gold = 0,
                        Items = {}
                    }
                end

                if data.isCoin and data.amount > 0 then
                    PocketLog_Data.BoxData.Gold = PocketLog_Data.BoxData.Gold + data.amount
                    sessionBoxGold = sessionBoxGold + data.amount
                    RefreshPocketWindow()
                    if pocketWindow and pocketWindow:IsShown() and pScroll then
                        pScroll:AddMessage("|cff00ff00[PocketLog Box]|r Found Coin: " .. FormatMoney(data.amount))
                    end
                    if not silent then
                        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[PocketLog Box]|r Found Coin: " ..
                                                          FormatMoney(data.amount))
                    end
                elseif not data.isCoin and data.link then
                    PocketLog_Data.BoxData.Items[data.link] =
                        (PocketLog_Data.BoxData.Items[data.link] or 0) + data.count
                    sessionBoxItems[data.link] = (sessionBoxItems[data.link] or 0) + data.count
                    RefreshPocketWindow()
                    if pocketWindow and pocketWindow:IsShown() and pScroll then
                        pScroll:AddMessage("|cff00ff00[PocketLog Box]|r Found Item: " .. data.link .. " x" .. data.count)
                    end
                    if not silent then
                        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[PocketLog Box]|r Found Item: " .. data.link .. " x" ..
                                                          data.count)
                    end
                end
            elseif data.source == "pick" then
                if not sessionStartTime then
                    sessionStartTime = GetTime()
                end
                if not slotClearedThisWindow then
                    sessionCount = sessionCount + 1
                    if PocketLog_Data then
                        PocketLog_Data.Count = PocketLog_Data.Count + 1
                    end
                    slotClearedThisWindow = true
                end
                if data.isCoin and data.amount > 0 then
                    sessionGold = sessionGold + data.amount
                    RefreshPocketWindow()
                    if PocketLog_Data then
                        PocketLog_Data.Gold = PocketLog_Data.Gold + data.amount
                    end
                    if not silent then
                        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[PocketLog]|r Mugged: " .. FormatMoney(data.amount))
                    end
                elseif not data.isCoin and data.link then
                    sessionItems[data.link] = (sessionItems[data.link] or 0) + data.count
                    RefreshPocketWindow()
                    if PocketLog_Data then
                        PocketLog_Data.Items[data.link] = (PocketLog_Data.Items[data.link] or 0) + data.count
                    end
                    if not silent then
                        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[PocketLog]|r Stole: " .. data.link .. " x" ..
                                                          data.count)
                    end
                end
                hudRefreshTimer = GetTime() + 0.2
            end
            activeLootCache[tonumber(arg1)] = nil
        end
    end
end)
