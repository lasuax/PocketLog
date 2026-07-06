local frame = CreateFrame("Frame")
frame:RegisterEvent("VARIABLES_LOADED")
frame:RegisterEvent("LOOT_OPENED")
frame:RegisterEvent("LOOT_SLOT_CLEARED")
frame:RegisterEvent("CHAT_MSG_SPELL_SELF_BUFF")

local sessionGold, sessionCount, sessionItems = 0, 0, {}
local sessionBoxGold, sessionBoxItems = 0, {}
local activeLootCache, isPickpocketActive, slotClearedThisWindow = {}, false, false
local sessionStartTime = nil
local isOpeningJunkbox = false
local currentBoxName = ""

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

local function PrintCollection(title, dataset)
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00" .. title .. ":|r")
    local empty = true
    for name, qty in pairs(dataset) do
        if qty > 0 then
            DEFAULT_CHAT_FRAME:AddMessage("  - " .. name .. " x" .. qty)
            empty = false
        end
    end
    if empty then
        DEFAULT_CHAT_FRAME:AddMessage("  - No items logged yet.")
    end
end

local hudFrame = CreateFrame("Frame", "PocketLogHUDFrame", UIParent)
hudFrame:SetWidth(180)
hudFrame:SetHeight(75)
hudFrame:SetPoint("CENTER", UIParent, "CENTER", 100, 100)
hudFrame:SetFrameStrata("HIGH")
hudFrame:SetFrameLevel(1)
hudFrame:SetClampedToScreen(true)
hudFrame:SetToplevel(true)
hudFrame:SetBackdrop(
    {
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 16,
        insets = {left = 4, right = 4, top = 4, bottom = 4}
    }
)
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
hudTitle:SetText("|cff00ff00PocketLog Session|r")
local hudTargets = hudFrame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
hudTargets:SetPoint("TOPLEFT", hudTitle, "BOTTOMLEFT", 0, -4)
local hudMoney = hudFrame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
hudMoney:SetPoint("TOPLEFT", hudTargets, "BOTTOMLEFT", 0, -4)
local hudValue = hudFrame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
hudValue:SetPoint("TOPLEFT", hudMoney, "BOTTOMLEFT", 0, -4)

local function UpdateHUDText()
    local gHrSpeed = 0
    if sessionStartTime and sessionGold > 0 then
        local elapsed = GetTime() - sessionStartTime
        if elapsed > 1 then
            gHrSpeed = math.floor((sessionGold / elapsed) * 3600)
        end
    end

    hudTargets:SetText("Mobs Mugged: " .. sessionCount)
    hudMoney:SetText("Liberated Coins: " .. FormatMoney(sessionGold))
    hudValue:SetText("Gold/Hr: |cffffffff" .. FormatMoney(gHrSpeed) .. "|r")
end


-- Create a dedicated PocketLog window to display summaries (avoids chat spam)
local pocketWindow = CreateFrame("Frame", "PocketLogWindow", UIParent)
pocketWindow:SetWidth(380)
pocketWindow:SetHeight(380)
pocketWindow:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
pocketWindow:SetBackdrop(
    {
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true,
        tileSize = 32,
        edgeSize = 32,
        insets = {left = 8, right = 8, top = 8, bottom = 8}
    }
)
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
pTitle:SetText("PocketLog - Detailed View")

-- Scroll area: use a ScrollFrame with a FontString child to display lines
local scrollFrame = CreateFrame("ScrollFrame", "PocketLogScrollFrame", pocketWindow, "UIPanelScrollFrameTemplate")
scrollFrame:SetPoint("TOPLEFT", pocketWindow, "TOPLEFT", 12, -32)
scrollFrame:SetPoint("BOTTOMRIGHT", pocketWindow, "BOTTOMRIGHT", -30, 140)
local scrollChild = CreateFrame("Frame", "PocketLogScrollChild", scrollFrame)
scrollFrame:SetScrollChild(scrollChild)
local childWidth = 380 - 12 - 30 - 16 -- approximate inner width with padding
scrollChild:SetWidth(childWidth)
scrollChild:SetPoint("TOPLEFT", scrollFrame, "TOPLEFT", 0, 0)
local pScrollText = scrollChild:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
pScrollText:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 0, 0)
pScrollText:SetWidth(childWidth)
pScrollText:SetJustifyH("LEFT")

local pScrollBuffer = {}
local pScroll = {}
-- Try to find a scrollbar child without using _G (some environments may not expose _G)
local scrollbar = nil
local targetName = scrollFrame:GetName() .. "ScrollBar"
if scrollFrame and scrollFrame.GetChildren then
    local children = {scrollFrame:GetChildren()}
    for i = 1, (children and table.getn(children) or 0) do
        local child = children[i]
        if child and child.GetName and child:GetName() == targetName then
            scrollbar = child
            break
        end
    end
end
-- If not found, attempt to get global or create a scrollbar for 1.12 compatibility
if not scrollbar then
    if type(getglobal) == 'function' then
        scrollbar = getglobal(targetName)
    end
end
if not scrollbar then
    scrollbar = CreateFrame("Slider", targetName, scrollFrame, "UIPanelScrollBarTemplate")
    scrollbar:SetPoint("TOPLEFT", scrollFrame, "TOPRIGHT", 4, -16)
    scrollbar:SetPoint("BOTTOMLEFT", scrollFrame, "BOTTOMRIGHT", 4, 16)
end
if scrollbar then
    scrollbar:SetMinMaxValues(0, 0)
    scrollbar:SetValue(0)
    if scrollbar.SetOrientation then
        scrollbar:SetOrientation("VERTICAL")
    end
    scrollbar:SetScript("OnValueChanged", function(self, value)
        local v = tonumber(value)
        if scrollFrame and scrollFrame.SetVerticalScroll and v then
            scrollFrame:SetVerticalScroll(v)
        end
    end)
end
scrollFrame:EnableMouseWheel(true)
scrollFrame:SetScript("OnMouseWheel", function()
    if not scrollFrame then
        return
    end
    local delta = arg1
    if not delta or type(delta) ~= "number" then
        return
    end
    local current = scrollFrame:GetVerticalScroll() or 0
    local val = current - (delta * 20)
    local minv, maxv = 0, 0
    if scrollbar then
        minv, maxv = scrollbar:GetMinMaxValues()
    end
    if val < minv then val = minv end
    if val > maxv then val = maxv end
    scrollFrame:SetVerticalScroll(val)
    if scrollbar then
        scrollbar:SetValue(val)
    end
end)
function pScroll:Clear()
    pScrollBuffer = {}
    pScrollText:SetText("")
    scrollChild:SetHeight(scrollFrame:GetHeight())
    if scrollFrame and scrollFrame.SetVerticalScroll then
        scrollFrame:SetVerticalScroll(0)
    end
    if scrollbar then
        scrollbar:SetMinMaxValues(0, 0)
        scrollbar:SetValue(0)
    end
end
function pScroll:AddMessage(msg)
    tinsert(pScrollBuffer, msg)
    pScrollText:SetText(table.concat(pScrollBuffer, "\n"))
    local h = pScrollText:GetHeight() or 0
    if h < scrollFrame:GetHeight() then
        h = scrollFrame:GetHeight()
    end
    scrollChild:SetHeight(h)
    if scrollFrame and scrollFrame.SetVerticalScroll then
        local maxv = math.max(0, h - scrollFrame:GetHeight())
        scrollFrame:SetVerticalScroll(maxv)
        if scrollbar then
            scrollbar:SetMinMaxValues(0, maxv)
            scrollbar:SetValue(maxv)
        end
    end
end

local resetOptionRows = {
    {key = "StolenGold", label = "Stolen Gold"},
    {key = "StolenItems", label = "Stolen Items"},
    {key = "JunkboxGold", label = "Junkbox Gold"},
    {key = "JunkboxItems", label = "Junkbox Items"}
}
local resetCheckboxes = {}

local function ApplyResetSelectionsToUI()
    if not PocketLog_Data or not PocketLog_Data.ResetSelections then
        return
    end
    for _, row in ipairs(resetOptionRows) do
        local settings = PocketLog_Data.ResetSelections[row.key] or {Session = false, AllTime = false}
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
        PocketLog_Data.ResetSelections[key] = {Session = false, AllTime = false}
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
            didReset = true
        end
        if selected.StolenGold.AllTime then
            PocketLog_Data.Gold = 0
            didReset = true
        end
    end
    if selected.StolenItems then
        if selected.StolenItems.Session then
            sessionItems = {}
            didReset = true
        end
        if selected.StolenItems.AllTime then
            PocketLog_Data.Items = {}
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
btnRestoreHUD:SetPoint("BOTTOMLEFT", bottomBar, "BOTTOMLEFT", 12, 44)
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
btnClose:SetWidth(80)
btnClose:SetHeight(22)
btnClose:SetPoint("BOTTOMRIGHT", bottomBar, "BOTTOMRIGHT", -12, 44)
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
    insets = {left = 8, right = 8, top = 8, bottom = 8}
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
        Session = CreateResetCheckbox("PocketLogResetWindow_" .. row.key .. "_Session", resetWindow, 140, yOffset, row.key, "Session"),
        AllTime = CreateResetCheckbox("PocketLogResetWindow_" .. row.key .. "_AllTime", resetWindow, 220, yOffset, row.key, "AllTime")
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

CreateWindowButton("PL_WinToggleHUD", "Toggle HUD", 100, 0, 10, function()
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

CreateWindowButton("PL_WinWipeAll", "Wipe Everything", 100, 110, 10, function()
    sessionGold, sessionCount, sessionItems, sessionStartTime = 0, 0, {}, nil
    sessionBoxGold, sessionBoxItems = 0, {}
    PocketLog_Data = {Gold = 0, Count = 0, Items = {}, ShowHUD = true, SilentMode = false, BoxData = {Gold = 0, Items = {}}}
    UpdateHUDText()
    pScroll:AddMessage("|cff00ff00[PocketLog]|r Absolutely all session and all-time records purged.")
end)

local copyrightText = bottomBar:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
copyrightText:SetPoint("BOTTOMRIGHT", bottomBar, "BOTTOMRIGHT", -12, 110)
copyrightText:SetJustifyH("RIGHT")
copyrightText:SetFont("Fonts\\FRIZQT__.TTF", 8)
copyrightText:SetText("Brought to you by your fellow rogue Critolis ^^,")
local silentCheckWindow = CreateFrame("CheckButton", "PocketLogSilentCheckboxWindow", bottomBar, "UICheckButtonTemplate")
silentCheckWindow:SetPoint("BOTTOMLEFT", bottomBar, "BOTTOMLEFT", 12, 74)
getglobal(silentCheckWindow:GetName() .. "Text"):SetText("Disable Live Chat Spams")
silentCheckWindow:SetScript("OnClick", function()
    if PocketLog_Data then
        if this:GetChecked() == 1 then
            PocketLog_Data.SilentMode = true
        else
            PocketLog_Data.SilentMode = false
        end
    end
end)

local function PopulatePocketWindow()
    pScroll:Clear()
    pScroll:AddMessage("|cffffff00=== PocketLog Detailed Summary ===|r")
    pScroll:AddMessage("|cff00ffff--- Session Gold & Items ---|r")
    pScroll:AddMessage("Session Gold: " .. FormatMoney(sessionGold))
    local empty = true
    for name, qty in pairs(sessionItems) do
        if qty > 0 then
            pScroll:AddMessage(name .. " x" .. qty)
            empty = false
        end
    end
    if empty then
        pScroll:AddMessage("No items logged yet.")
    end

    pScroll:AddMessage("|cff00ffff--- Session Junkbox Gains ---|r")
    pScroll:AddMessage("Session Junkbox Gold: " .. FormatMoney(sessionBoxGold))
    local emptySessionBox = true
    for name, qty in pairs(sessionBoxItems) do
        if qty > 0 then
            pScroll:AddMessage(name .. " x" .. qty)
            emptySessionBox = false
        end
    end
    if emptySessionBox then
        pScroll:AddMessage("No junkbox items logged in this session.")
    end

    local lGold = (PocketLog_Data and PocketLog_Data.Gold) or 0
    local lItems = (PocketLog_Data and PocketLog_Data.Items) or {}
    pScroll:AddMessage("|cff00ffff--- All-Time ---|r")
    pScroll:AddMessage("All-Time Gold: " .. FormatMoney(lGold))
    empty = true
    for name, qty in pairs(lItems) do
        if qty > 0 then
            pScroll:AddMessage(name .. " x" .. qty)
            empty = false
        end
    end
    if empty then
        pScroll:AddMessage("No historical items logged.")
    end

    if PocketLog_Data and PocketLog_Data.BoxData then
        pScroll:AddMessage("|cff00ffff--- Saved Junkbox Contents ---|r")
        pScroll:AddMessage("Total Box Gold: " .. FormatMoney(PocketLog_Data.BoxData.Gold))
        local emptybox = true
        for name, qty in pairs(PocketLog_Data.BoxData.Items or {}) do
            if qty > 0 then
                pScroll:AddMessage(name .. " x" .. qty)
                emptybox = false
            end
        end
        if emptybox then
            pScroll:AddMessage("No box items logged.")
        end
    end
end

local hudOpenPanelButton = CreateFrame("Button", "PocketLogHUDBtn", hudFrame, "UIPanelButtonTemplate")
hudOpenPanelButton:SetWidth(20)
hudOpenPanelButton:SetHeight(18)
hudOpenPanelButton:SetPoint("TOPRIGHT", hudFrame, "TOPRIGHT", -8, -6)
hudOpenPanelButton:SetText("...")
hudOpenPanelButton:SetScript("OnClick", function()
    PopulatePocketWindow()
    pocketWindow:Show()
end)

SLASH_POCKETLOG1 = "/pocket"
SlashCmdList["POCKETLOG"] = function(msg)
    if pocketWindow:IsShown() then
        pocketWindow:Hide()
    else
        PopulatePocketWindow()
        pocketWindow:Show()
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

local hudRefreshTimer = nil
hudFrame:SetScript(
    "OnUpdate",
    function()
        if hudRefreshTimer and GetTime() >= hudRefreshTimer then
            UpdateHUDText()
            hudRefreshTimer = nil
        end
    end
)

frame:SetScript(
    "OnEvent",
    function()
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
                PocketLog_Data.SilentMode = false
            end
            if PocketLog_Data.ShowHUD == nil then
                PocketLog_Data.ShowHUD = true
            end
            if PocketLog_Data.HUD_X and PocketLog_Data.HUD_Y then
                hudFrame:ClearAllPoints()
                if PocketLog_Data.HUD_Point and PocketLog_Data.HUD_RelativePoint then
                    hudFrame:SetPoint(PocketLog_Data.HUD_Point, UIParent, PocketLog_Data.HUD_RelativePoint, PocketLog_Data.HUD_X, PocketLog_Data.HUD_Y)
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
                PocketLog_Data.BoxData = {Gold = 0, Items = {}}
            end
            if not PocketLog_Data.ResetSelections then
                PocketLog_Data.ResetSelections = {
                    StolenGold = {Session = false, AllTime = false},
                    StolenItems = {Session = false, AllTime = false},
                    JunkboxGold = {Session = false, AllTime = false},
                    JunkboxItems = {Session = false, AllTime = false}
                }
            end

            ApplyResetSelectionsToUI()
            UpdateHUDText()
            return
        end
        if event == "CHAT_MSG_SPELL_SELF_BUFF" and arg1 then
            local castText = string.lower(arg1)
            if string.find(castText, "junkbox") then
                isOpeningJunkbox = true
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
            activeLootCache, slotClearedThisWindow = {}, false

            if isOpeningJunkbox then
                isPickpocketActive = false
                for slot = 1, GetNumLootItems() do
                    local _, name, qty = GetLootSlotInfo(slot)
                    if name then
                        if LootSlotIsCoin(slot) then
                            -- Process coins found inside the lockbox
                            local text, ext = string.lower(name), 0
                            local _, _, g = string.find(text, "(%d+) gold")
                            local _, _, s = string.find(text, "(%d+) silver")
                            local _, _, c = string.find(text, "(%d+) copper")
                            if g then
                                ext = ext + (tonumber(g) * 10000)
                            end
                            if s then
                                ext = ext + (tonumber(s) * 100)
                            end
                            if c then
                                ext = ext + tonumber(c)
                            end
                            activeLootCache[slot] = {isCoin = true, isFromBox = true, amount = ext}
                        else
                            -- Process items (gems, potions, cloth) found inside the lockbox
                            activeLootCache[slot] = {
                                isCoin = false,
                                isFromBox = true,
                                link = GetLootSlotLink(slot) or name,
                                count = qty or 1
                            }
                        end
                    end
                end
            elseif UnitExists("target") and not UnitIsDead("target") and not UnitIsPlayer("target") then
                isPickpocketActive = true
                for slot = 1, GetNumLootItems() do
                    local _, name, qty = GetLootSlotInfo(slot)
                    if name then
                        if LootSlotIsCoin(slot) then
                            local text, ext = string.lower(name), 0
                            local _, _, g = string.find(text, "(%d+) gold")
                            local _, _, s = string.find(text, "(%d+) silver")
                            local _, _, c = string.find(text, "(%d+) copper")
                            if g then
                                ext = ext + (tonumber(g) * 10000)
                            end
                            if s then
                                ext = ext + (tonumber(s) * 100)
                            end
                            if c then
                                ext = ext + tonumber(c)
                            end
                            activeLootCache[slot] = {isCoin = true, amount = ext}
                        else
                            activeLootCache[slot] = {
                                isCoin = false,
                                link = GetLootSlotLink(slot) or name,
                                count = qty or 1
                            }
                        end
                    end
                end
            else
                isPickpocketActive = false
                isOpeningJunkbox = false
                return
            end
        end

        if event == "LOOT_SLOT_CLEARED" and arg1 then
            local data = activeLootCache[tonumber(arg1)]
            if data then
                local silent = (PocketLog_Data and PocketLog_Data.SilentMode)

                -- PROCESS LOCKBOX EXTRACTIONS
                if data.isFromBox then
                    -- PROCESS STANDARD PICKPOCKETING
                    if not PocketLog_Data.BoxData then
                        PocketLog_Data.BoxData = {Gold = 0, Items = {}}
                    end

                    if data.isCoin and data.amount > 0 then
                        PocketLog_Data.BoxData.Gold = PocketLog_Data.BoxData.Gold + data.amount
                        sessionBoxGold = sessionBoxGold + data.amount
                        if pocketWindow and pocketWindow:IsShown() and pScroll then
                            pScroll:AddMessage("|cff00ff00[PocketLog Box]|r Found Coin: " .. FormatMoney(data.amount))
                        end
                        if not silent then
                            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[PocketLog Box]|r Found Coin: " .. FormatMoney(data.amount))
                        end
                    elseif not data.isCoin and data.link then
                        PocketLog_Data.BoxData.Items[data.link] =
                            (PocketLog_Data.BoxData.Items[data.link] or 0) + data.count
                        sessionBoxItems[data.link] = (sessionBoxItems[data.link] or 0) + data.count
                        if pocketWindow and pocketWindow:IsShown() and pScroll then
                            pScroll:AddMessage("|cff00ff00[PocketLog Box]|r Found Item: " .. data.link .. " x" .. data.count)
                        end
                        if not silent then
                            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[PocketLog Box]|r Found Item: " .. data.link .. " x" .. data.count)
                        end
                    end
                elseif isPickpocketActive then
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
                        if PocketLog_Data then
                            PocketLog_Data.Gold = PocketLog_Data.Gold + data.amount
                        end
                        if not silent then
                            DEFAULT_CHAT_FRAME:AddMessage(
                                "|cff00ff00[PocketLog]|r Mugged: " .. FormatMoney(data.amount)
                            )
                        end
                    elseif not data.isCoin and data.link then
                        sessionItems[data.link] = (sessionItems[data.link] or 0) + data.count
                        if PocketLog_Data then
                            PocketLog_Data.Items[data.link] = (PocketLog_Data.Items[data.link] or 0) + data.count
                        end
                        if not silent then
                            DEFAULT_CHAT_FRAME:AddMessage(
                                "|cff00ff00[PocketLog]|r Stole: " .. data.link .. " x" .. data.count
                            )
                        end
                    end
                    hudRefreshTimer = GetTime() + 0.2
                end
                activeLootCache[tonumber(arg1)] = nil
            end
        end
    end
)
