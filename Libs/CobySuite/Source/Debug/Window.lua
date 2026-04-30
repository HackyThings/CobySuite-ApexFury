-------------------------------------------------------------------------------
-- CobySuite.Debug.NewWindow — shared debug window constructor
--
-- Each consumer addon calls NewWindow(opts) to get its own independent window
-- with its own filters, state, and customizations. The core UI layout, filter
-- system, copy box, auto-scroll, and live log display are all shared.
--
-- Consumer addons can add tabs, extra toolbar buttons, and custom methods
-- (e.g., ResetAllData, WipeAllData) after construction.
-------------------------------------------------------------------------------

local LEVEL_COLORS = {
  INFO  = {r = 0.8, g = 0.8, b = 0.8},
  WARN  = {r = 1.0, g = 0.8, b = 0.0},
  STATE = {r = 0.4, g = 0.8, b = 1.0},
  EVENT = {r = 0.6, g = 1.0, b = 0.6},
}

local DEFAULT_CATEGORY_BACKDROP = {
  bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
  edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
  tile = true, tileSize = 16, edgeSize = 16,
  insets = { left = 4, right = 4, top = 4, bottom = 4 },
}

-------------------------------------------------------------------------------
-- Shared mixin — all methods reference self._logger for the addon's logger
-------------------------------------------------------------------------------
local DebugWindowMixin = {}

function DebugWindowMixin:OnLoad()
  self.TitleText:SetText(self._title)

  -- Configure log display
  self.LogDisplay:SetMaxLines(5000)
  self.LogDisplay:SetFading(false)
  self.LogDisplay:SetFontObject("GameFontHighlightSmall")
  self.LogDisplay:SetHyperlinksEnabled(false)
  self.LogDisplay:SetJustifyH("LEFT")
  self.LogDisplay:SetInsertMode("BOTTOM")

  -- Configure copy box
  local copyBox = self.CopyScrollFrame.CopyBox
  copyBox:SetFontObject(ChatFontSmall)
  copyBox:SetScript("OnEscapePressed", function()
    self:HideCopyBox()
  end)

  -- State
  self.autoScroll = true
  self.lastEntryCount = 0
  self.levelFilters = {}
  self.categoryFilters = {}
  self.filterButtons = {}

  -- Enable all levels by default
  for _, level in pairs(self._logger.Levels) do
    self.levelFilters[level] = true
  end

  -- Enable all categories by default
  for _, cat in ipairs(self._logger.Categories) do
    self.categoryFilters[cat] = true
  end

  -- Auto-scroll checkbox
  self.AutoScrollToggle:SetChecked(true)
  self.AutoScrollLabel = self.AutoScrollLabel or self:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  self.AutoScrollLabel:SetPoint("RIGHT", self.AutoScrollToggle, "LEFT", -2, 0)
  self.AutoScrollLabel:SetText("Auto-scroll")

  -- Mouse wheel scrolling on log display
  -- ScrollingMessageFrame: offset 0 = bottom (newest), higher = scrolled up (older)
  self.LogDisplay:SetScript("OnMouseWheel", function(_, delta)
    local current = self.LogDisplay:GetScrollOffset()
    local maxScroll = self.LogDisplay:GetMaxScrollRange()
    local newValue = math.max(0, math.min(maxScroll, current + delta * 3))
    self.LogDisplay:SetScrollOffset(newValue)
    if newValue == 0 then
      self.autoScroll = true
      self.AutoScrollToggle:SetChecked(true)
    elseif delta > 0 then
      self.autoScroll = false
      self.AutoScrollToggle:SetChecked(false)
    end
  end)

  self:RegisterForDrag("LeftButton")
  self:CreateFilterButtons()
  self:SetClampedToScreen(true)

  self._activeTab = "log"

  if self._tabs and #self._tabs > 0 then
    PanelTemplates_SetTab(self, 1)
  end

  self:RefreshDisplay()
end

-- === Filter Buttons ===

function DebugWindowMixin:CreateFilterButtons()
  local row = self.FilterRow
  local logger = self._logger
  local xOffset = 0

  -- Level filter buttons
  for _, level in ipairs({"INFO", "WARN", "STATE", "EVENT"}) do
    local btn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    btn:SetSize(50, 18)
    btn:SetPoint("LEFT", xOffset, 0)
    btn:SetText(level)
    btn:GetFontString():SetFont(btn:GetFontString():GetFont(), 9)

    btn.active = true

    btn:SetScript("OnClick", function()
      btn.active = not btn.active
      self.levelFilters[level] = btn.active
      if btn.active then
        btn:GetFontString():SetTextColor(1, 1, 1)
      else
        btn:GetFontString():SetTextColor(0.4, 0.4, 0.4)
      end
      self:RefreshDisplay()
    end)

    table.insert(self.filterButtons, btn)
    xOffset = xOffset + 52
  end

  xOffset = xOffset + 10

  -- Separator
  local sep = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  sep:SetPoint("LEFT", xOffset, 0)
  sep:SetText("|")
  xOffset = xOffset + 10

  -- Category filter button
  local catBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
  catBtn:SetSize(80, 18)
  catBtn:SetPoint("LEFT", xOffset, 0)
  catBtn:SetText("Categories")
  catBtn:GetFontString():SetFont(catBtn:GetFontString():GetFont(), 9)
  catBtn:SetScript("OnClick", function()
    self:ToggleCategoryMenu(catBtn)
  end)
  xOffset = xOffset + 84

  -- DIAG quick-filter button (toggles between DIAG-only and all categories)
  local diagBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
  diagBtn:SetSize(50, 18)
  diagBtn:SetPoint("LEFT", xOffset, 0)
  diagBtn:SetText("DIAG")
  diagBtn:GetFontString():SetFont(diagBtn:GetFontString():GetFont(), 9)
  diagBtn:GetFontString():SetTextColor(1, 0.5, 0)
  diagBtn.diagOnly = false

  local diagActiveColor = self._diagActiveColor
  diagBtn:SetScript("OnClick", function()
    diagBtn.diagOnly = not diagBtn.diagOnly
    if diagBtn.diagOnly then
      -- Save current filters, switch to DIAG-only
      diagBtn.savedCategoryFilters = {}
      for _, cat in ipairs(logger.Categories) do
        diagBtn.savedCategoryFilters[cat] = self.categoryFilters[cat]
        self.categoryFilters[cat] = (cat == "DIAG")
      end
      -- Resolve color (supports function form for lazy Utilities access)
      local color = type(diagActiveColor) == "function" and diagActiveColor() or diagActiveColor
      diagBtn:GetFontString():SetTextColor(color[1], color[2], color[3])
    else
      -- Restore saved filters
      if diagBtn.savedCategoryFilters then
        for cat, val in pairs(diagBtn.savedCategoryFilters) do
          self.categoryFilters[cat] = val
        end
      end
      diagBtn:GetFontString():SetTextColor(1, 0.5, 0)
    end
    self:RefreshDisplay()
  end)
end

function DebugWindowMixin:ToggleCategoryMenu(anchor)
  if self.categoryMenu and self.categoryMenu:IsShown() then
    self.categoryMenu:Hide()
    return
  end

  if not self.categoryMenu then
    local logger = self._logger
    local window = self

    self.categoryMenu = CreateFrame("Frame", nil, self, "BackdropTemplate")
    -- Resolve backdrop (supports function form for lazy Utilities access)
    local backdrop = self._categoryMenuBackdrop
    if type(backdrop) == "function" then backdrop = backdrop() end
    self.categoryMenu:SetBackdrop(backdrop)
    self.categoryMenu:SetFrameStrata("DIALOG")
    self.categoryMenu:SetClampedToScreen(true)

    local yOff = -8
    local checkboxes = {}
    for _, cat in ipairs(logger.Categories) do
      local cb = CreateFrame("CheckButton", nil, self.categoryMenu, "UICheckButtonTemplate")
      cb:SetSize(20, 20)
      cb:SetPoint("TOPLEFT", 8, yOff)
      cb:SetChecked(self.categoryFilters[cat] ~= false)
      cb.text = cb.text or cb:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
      cb.text:SetPoint("LEFT", cb, "RIGHT", 2, 0)
      cb.text:SetText(cat)

      local capturedCat = cat
      cb:SetScript("OnClick", function(cbSelf)
        window.categoryFilters[capturedCat] = cbSelf:GetChecked()
        window:RefreshDisplay()
      end)

      table.insert(checkboxes, cb)
      yOff = yOff - 20
    end

    -- All / None buttons
    local allBtn = CreateFrame("Button", nil, self.categoryMenu, "UIPanelButtonTemplate")
    allBtn:SetSize(50, 18)
    allBtn:SetPoint("TOPLEFT", 8, yOff - 4)
    allBtn:SetText("All")
    allBtn:GetFontString():SetFont(allBtn:GetFontString():GetFont(), 9)
    allBtn:SetScript("OnClick", function()
      for _, cat in ipairs(logger.Categories) do
        window.categoryFilters[cat] = true
      end
      for _, cb in ipairs(checkboxes) do
        cb:SetChecked(true)
      end
      window:RefreshDisplay()
    end)

    local noneBtn = CreateFrame("Button", nil, self.categoryMenu, "UIPanelButtonTemplate")
    noneBtn:SetSize(50, 18)
    noneBtn:SetPoint("LEFT", allBtn, "RIGHT", 4, 0)
    noneBtn:SetText("None")
    noneBtn:GetFontString():SetFont(noneBtn:GetFontString():GetFont(), 9)
    noneBtn:SetScript("OnClick", function()
      for _, cat in ipairs(logger.Categories) do
        window.categoryFilters[cat] = false
      end
      for _, cb in ipairs(checkboxes) do
        cb:SetChecked(false)
      end
      window:RefreshDisplay()
    end)

    self.categoryMenu:SetSize(130, math.abs(yOff) + 32)
  end

  self.categoryMenu:ClearAllPoints()
  self.categoryMenu:SetPoint("BOTTOMLEFT", anchor, "TOPLEFT", 0, 2)
  self.categoryMenu:Show()
end

-- === Tab Switching ===

function DebugWindowMixin:SetTab(tabName)
  self._activeTab = tabName
  local isLog = (tabName == "log")

  -- Log tab elements
  local copyShown = self.CopyScrollFrame:IsShown()
  self.LogDisplay:SetShown(isLog and not copyShown)
  self.CopyScrollFrame:SetShown(isLog and copyShown)
  self.BackToLiveButton:SetShown(isLog and copyShown)
  self.FilterRow:SetShown(isLog)
  self.ActionToolbar:SetShown(isLog)
  self.EntryCount:SetShown(isLog)
  if self.AutoScrollLabel then self.AutoScrollLabel:SetShown(isLog) end

  -- Toggle non-log tab content frames
  if self._tabContents then
    for name, content in pairs(self._tabContents) do
      local show = (name == tabName)
      content:SetShown(show)
      if show and content.Refresh then content:Refresh() end
    end
  end

  -- Update tab visual
  if self._tabs then
    for i, tab in ipairs(self._tabs) do
      if tab.name == tabName then
        PanelTemplates_SetTab(self, i)
        break
      end
    end
  end
end

-- === Log Display ===

function DebugWindowMixin:RefreshDisplay()
  self.LogDisplay:Clear()
  self.lastEntryCount = 0

  local logger = self._logger
  local entries = logger.GetFilteredEntries(self.levelFilters, self.categoryFilters)
  for _, entry in ipairs(entries) do
    local c = LEVEL_COLORS[entry.level] or LEVEL_COLORS.INFO
    self.LogDisplay:AddMessage(logger.FormatEntry(entry), c.r, c.g, c.b)
  end

  self.lastEntryCount = logger.GetEntryCount()

  if self.autoScroll then
    self.LogDisplay:SetScrollOffset(0)
  end
end

function DebugWindowMixin:OnUpdate()
  if self._activeTab ~= "log" then return end

  local logger = self._logger
  local currentCount = logger.GetEntryCount()
  if currentCount > self.lastEntryCount then
    local buf = logger.GetBuffer()
    local bufLen = #buf
    -- totalAdded maps to buf[bufLen], so buf index = bufLen - (currentCount - seqNum)
    local newCount = currentCount - self.lastEntryCount
    local startBufIdx = bufLen - newCount + 1
    for i = math.max(1, startBufIdx), bufLen do
      local entry = buf[i]
      if entry then
        local levelOk = self.levelFilters[entry.level]
        local catOk = self.categoryFilters[entry.category]
        if levelOk and catOk then
          local c = LEVEL_COLORS[entry.level] or LEVEL_COLORS.INFO
          self.LogDisplay:AddMessage(logger.FormatEntry(entry), c.r, c.g, c.b)
        end
      end
    end
    self.lastEntryCount = currentCount

    if self.autoScroll then
      self.LogDisplay:SetScrollOffset(0)
    end
  end

  self.EntryCount:SetText(logger.GetBufferSize() .. " entries")
end

-- === Copy Box ===

function DebugWindowMixin:CopyAll()
  self:ShowCopyBox(self._logger.GetFormattedLog(false, self.levelFilters, self.categoryFilters))
end

function DebugWindowMixin:CopyRecent()
  self:ShowCopyBox(self._logger.GetFormattedLog(true, self.levelFilters, self.categoryFilters))
end

function DebugWindowMixin:ShowCopyBox(text)
  -- Switch to log tab if on another tab
  if self._activeTab ~= "log" then
    self:SetTab("log")
  end

  self.LogDisplay:Hide()
  self.CopyAllButton:Hide()
  self.CopyRecentButton:Hide()
  self.ClearButton:Hide()
  self.BackToLiveButton:Show()

  self.CopyScrollFrame:Show()
  local editBox = self.CopyScrollFrame.CopyBox
  editBox:SetWidth(self.CopyScrollFrame:GetWidth() - 18)
  editBox:SetText(text)
  local numLines = select(2, text:gsub("\n", "\n")) + 1
  local _, fontHeight = editBox:GetFont()
  editBox:SetHeight(numLines * (fontHeight + 2) + 20)
  editBox:HighlightText()
  editBox:SetFocus()
end

function DebugWindowMixin:HideCopyBox()
  self.CopyScrollFrame:Hide()
  self.CopyScrollFrame.CopyBox:ClearFocus()
  self.CopyScrollFrame.CopyBox:SetText("")
  self.BackToLiveButton:Hide()

  self.CopyAllButton:Show()
  self.CopyRecentButton:Show()
  self.ClearButton:Show()
  self.LogDisplay:Show()
  self:RefreshDisplay()
end

-- === Data Management ===

function DebugWindowMixin:ClearLog()
  self._logger.Clear()
  self.LogDisplay:Clear()
  self.lastEntryCount = 0
end

-------------------------------------------------------------------------------
-- Constructor
-------------------------------------------------------------------------------
-- opts:
--   windowName             (string)   global frame name, e.g., "CobySniperDebugWindow"
--   title                  (string)   window title text
--   logger                 (table)    logger instance from NewLogger
--   tabs                   (table?)   array of {name, label, contentKey?}
--                                     first entry should be {name="log", label="Log"}
--                                     non-log tabs get content frames created automatically
--                                     contentKey stores the content frame as frame[contentKey]
--   extraToolbarButtons    (table?)   array of {key?, text, width?, textColor?, side, onClick}
--                                     side = "left" (after Clear) or "right" (before AutoScroll)
--                                     onClick receives the window frame
--   diagActiveColor        (table|fn?) {R, G, B} array or function returning same, default {0,1,0}
--   categoryMenuBackdrop   (table|fn?) backdrop table or function returning one
-------------------------------------------------------------------------------
function CobySuite.Debug.NewWindow(opts)
  local windowName = opts.windowName
  local title = opts.title
  local logger = opts.logger
  local tabs = opts.tabs
  local extraButtons = opts.extraToolbarButtons or {}
  local diagActiveColor = opts.diagActiveColor or {0, 1, 0}
  local categoryMenuBackdrop = opts.categoryMenuBackdrop or DEFAULT_CATEGORY_BACKDROP

  -- Create main frame
  local f = CreateFrame("Frame", windowName, UIParent, "BasicFrameTemplateWithInset")
  Mixin(f, DebugWindowMixin)

  -- Store instance config
  f._title = title
  f._logger = logger
  f._diagActiveColor = diagActiveColor
  f._categoryMenuBackdrop = categoryMenuBackdrop
  f._tabs = tabs
  f._tabContents = {}

  -- Frame properties
  f:SetSize(800, 550)
  f:SetPoint("CENTER")
  f:SetFrameStrata("HIGH")
  f:EnableMouse(true)
  f:SetMovable(true)
  f:SetToplevel(true)
  f:SetResizable(true)
  f:SetResizeBounds(600, 400, 1200, 800)
  f:Hide()

  -- EntryCount label
  f.EntryCount = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  f.EntryCount:SetJustifyH("LEFT")
  f.EntryCount:SetPoint("TOPLEFT", 70, -28)

  -- Scrolling log display
  f.LogDisplay = CreateFrame("ScrollingMessageFrame", nil, f)
  f.LogDisplay:SetPoint("TOPLEFT", 12, -44)
  f.LogDisplay:SetPoint("BOTTOMRIGHT", -12, 70)
  f.LogDisplay:EnableMouse(true)

  -- Copy overlay scroll frame
  f.CopyScrollFrame = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
  f.CopyScrollFrame:SetPoint("TOPLEFT", 12, -44)
  f.CopyScrollFrame:SetPoint("BOTTOMRIGHT", -30, 70)
  f.CopyScrollFrame:Hide()

  local copyBox = CreateFrame("EditBox", nil, f.CopyScrollFrame)
  copyBox:SetMultiLine(true)
  copyBox:SetAutoFocus(false)
  copyBox:EnableMouse(true)
  copyBox:SetSize(740, 1)
  f.CopyScrollFrame.CopyBox = copyBox
  f.CopyScrollFrame:SetScrollChild(copyBox)

  -- === Action toolbar ===

  f.ActionToolbar = CreateFrame("Frame", nil, f)
  f.ActionToolbar:SetHeight(22)
  f.ActionToolbar:SetPoint("BOTTOMLEFT", 12, 42)
  f.ActionToolbar:SetPoint("BOTTOMRIGHT", -12, 42)

  -- Left side: Copy All, Copy Last 250, Clear, Back to Live
  f.CopyAllButton = CreateFrame("Button", nil, f.ActionToolbar, "UIPanelButtonTemplate")
  f.CopyAllButton:SetSize(90, 22)
  f.CopyAllButton:SetPoint("LEFT", 0, 0)
  f.CopyAllButton:SetText("Copy All")
  f.CopyAllButton:SetScript("OnClick", function() f:CopyAll() end)

  f.CopyRecentButton = CreateFrame("Button", nil, f.ActionToolbar, "UIPanelButtonTemplate")
  f.CopyRecentButton:SetSize(120, 22)
  f.CopyRecentButton:SetPoint("LEFT", f.CopyAllButton, "RIGHT", 4, 0)
  f.CopyRecentButton:SetText("Copy Last 250")
  f.CopyRecentButton:SetScript("OnClick", function() f:CopyRecent() end)

  f.BackToLiveButton = CreateFrame("Button", nil, f.ActionToolbar, "UIPanelButtonTemplate")
  f.BackToLiveButton:SetSize(100, 22)
  f.BackToLiveButton:SetPoint("LEFT", f.CopyRecentButton, "RIGHT", 4, 0)
  f.BackToLiveButton:SetText("Back to Live")
  f.BackToLiveButton:SetScript("OnClick", function() f:HideCopyBox() end)
  f.BackToLiveButton:Hide()

  f.ClearButton = CreateFrame("Button", nil, f.ActionToolbar, "UIPanelButtonTemplate")
  f.ClearButton:SetSize(70, 22)
  f.ClearButton:SetPoint("LEFT", f.CopyRecentButton, "RIGHT", 4, 0)
  f.ClearButton:SetText("Clear")
  f.ClearButton:SetScript("OnClick", function() f:ClearLog() end)

  -- Extra left-side toolbar buttons (after Clear)
  local lastLeftButton = f.ClearButton
  for _, btnOpts in ipairs(extraButtons) do
    if btnOpts.side == "left" then
      local btn = CreateFrame("Button", nil, f.ActionToolbar, "UIPanelButtonTemplate")
      btn:SetSize(btnOpts.width or 100, 22)
      btn:SetPoint("LEFT", lastLeftButton, "RIGHT", 4, 0)
      btn:SetText(btnOpts.text)
      if btnOpts.textColor then
        btn:GetFontString():SetTextColor(btnOpts.textColor[1], btnOpts.textColor[2], btnOpts.textColor[3])
      end
      btn:SetScript("OnClick", function() btnOpts.onClick(f) end)
      if btnOpts.key then f[btnOpts.key] = btn end
      lastLeftButton = btn
    end
  end

  -- Right side: build from rightmost inward, then place AutoScroll
  local rightAnchor = nil
  local rightButtons = {}
  for _, btnOpts in ipairs(extraButtons) do
    if btnOpts.side == "right" then
      table.insert(rightButtons, btnOpts)
    end
  end

  for i = #rightButtons, 1, -1 do
    local btnOpts = rightButtons[i]
    local btn = CreateFrame("Button", nil, f.ActionToolbar, "UIPanelButtonTemplate")
    btn:SetSize(btnOpts.width or 100, 22)
    if rightAnchor then
      btn:SetPoint("RIGHT", rightAnchor, "LEFT", -4, 0)
    else
      btn:SetPoint("RIGHT", 0, 0)
    end
    btn:SetText(btnOpts.text)
    if btnOpts.textColor then
      btn:GetFontString():SetTextColor(btnOpts.textColor[1], btnOpts.textColor[2], btnOpts.textColor[3])
    end
    btn:SetScript("OnClick", function() btnOpts.onClick(f) end)
    if btnOpts.key then f[btnOpts.key] = btn end
    rightAnchor = btn
  end

  -- Auto-scroll: anchor left of rightmost right button, or at right edge
  f.AutoScrollToggle = CreateFrame("CheckButton", nil, f.ActionToolbar, "UICheckButtonTemplate")
  f.AutoScrollToggle:SetSize(24, 24)
  if rightAnchor then
    f.AutoScrollToggle:SetPoint("RIGHT", rightAnchor, "LEFT", -8, 0)
  else
    f.AutoScrollToggle:SetPoint("RIGHT", 0, 0)
  end
  f.AutoScrollToggle:SetScript("OnClick", function(self) f.autoScroll = self:GetChecked() end)

  -- Filter row
  f.FilterRow = CreateFrame("Frame", nil, f)
  f.FilterRow:SetHeight(20)
  f.FilterRow:SetPoint("BOTTOMLEFT", 12, 16)
  f.FilterRow:SetPoint("BOTTOMRIGHT", -12, 16)

  -- === Tabs (optional) ===

  if tabs and #tabs > 0 then
    f.numTabs = #tabs
    local prevTab = nil
    for i, tabDef in ipairs(tabs) do
      local tab = CreateFrame("Button", windowName .. "Tab" .. i, f, "PanelTabButtonTemplate")
      if prevTab then
        tab:SetPoint("LEFT", prevTab, "RIGHT", 0, 0)
      else
        tab:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 15, -30)
      end
      tab:SetText(tabDef.label)
      tab:SetID(i)

      local tabName = tabDef.name
      tab:SetScript("OnClick", function() f:SetTab(tabName) end)
      PanelTemplates_TabResize(tab, 0)
      prevTab = tab

      -- Create content frame for non-log tabs
      if tabDef.name ~= "log" then
        local content = CreateFrame("Frame", nil, f)
        content:SetPoint("TOPLEFT", 12, -44)
        content:SetPoint("BOTTOMRIGHT", -12, 5)
        content:Hide()
        f._tabContents[tabDef.name] = content
        if tabDef.contentKey then
          f[tabDef.contentKey] = content
        end
      end
    end
  end

  -- Resize grip
  f.ResizeGrip = CobySuite.UI.CreateResizeGrip(f)
  f.ResizeGrip:SetScript("OnMouseDown", function() f:StartSizing("BOTTOMRIGHT") end)
  f.ResizeGrip:SetScript("OnMouseUp", function() f:StopMovingOrSizing() end)

  -- Scripts
  f:SetScript("OnUpdate", f.OnUpdate)
  f:SetScript("OnDragStart", function(self) self:StartMoving() end)
  f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)

  f:OnLoad()

  return f
end
