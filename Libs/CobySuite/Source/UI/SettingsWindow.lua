---------------------------------------------------------------------------
-- CobySuite.UI.CreateSettingsWindow: the suite's standard settings window
--
-- One window per addon, in the style CobySniper introduced: a sidebar of
-- categories (left out when there is only one), a scrolling panel per
-- category with gold section headers over thin dividers, labels on the left
-- and inputs aligned on the right, grey description lines, and a bottom bar
-- with Defaults on the left and Apply and Cancel on the right.
--
-- Edits are staged. Apply writes every staged value through Config.Set in
-- one go; Cancel, closing the window and opening it again all drop them.
-- Defaults stages every default, so the controls show them and Apply keeps
-- them. A staged value that is set back to the saved one stops being
-- staged. A setting changed from outside while the window is open (a slash
-- command, another window) repaints its control unless that control holds a
-- staged edit or is being typed in.
--
-- Apply saves key by key. A value Config.Set refuses is printed and
-- dropped. A Set that throws is printed too: when the saved value changed
-- anyway (a hook after the write failed) it counts as applied, otherwise
-- the edit stays staged in the window for another Apply. onApply runs under
-- pcall, and its error is printed.
--
-- The window is built when this is called, so call it at load (never in
-- combat); rows are declared, and the panel lays them out, so a row that
-- appears or disappears with another setting (visibleWhen) needs no
-- position bookkeeping.
--
--   local window = CobySuite.UI.CreateSettingsWindow({
--     name    = "MyAddonSettingsWindow",   -- global name: Escape closes it; the Defaults popup is <name>DefaultsPopup
--     title   = "My Addon - Settings",
--     config  = MyAddon.Config,            -- a CobySuite.Config.New instance (Get, Set, Defaults, CheckValue)
--     persist = { svTable = function() return MY_ADDON_WINDOW_STATE end, key = "settings" },
--     width   = 680, height = 480,         -- the defaults; the sidebar takes 140 of the width when shown
--     watch   = { bus = MyAddon.EventBus, event = MyAddon.Events.ConfigChanged },   -- optional
--     onApply = function(changes, window) end,   -- after Apply: changes[key] = { old = ..., new = ... }
--     message = MyAddon.Utilities.Message,       -- prints a value Config.Set refused (default print)
--     footerButtons = { { text = "Debug Log", width = 100, tooltip = "...", onClick = function(window) end } },
--     categories = {
--       { key = "general", label = "General", build = function(panel, window) ... end },
--       { key = "sound", label = "Sound", scroll = false, build = function(frame, window) ... end },
--     },
--   })
--
-- Rows (each returns its row frame). Every row takes visibleWhen =
-- function(get) and refresh = function(row, window) (run after every sync
-- and stage, for text beside a control that follows its value), and a row
-- with a control takes enabledWhen = function(get); get(key) is the staged
-- value, else the saved one. key rows bind to the config: a checkbox,
-- slider, dropdown, radio, keybind or multi-line box stages on every user
-- change; an Input stages when its text is committed (Enter, leaving the
-- field, or Apply, which commits the field being typed in first), and typing
-- in it lights Apply and Cancel as soon as its text differs from where the
-- edit started.
--   panel:Section(text)
--   panel:Description(text)
--   panel:Checkbox{ key, label, tooltip, indent }
--   panel:Input{ key, label, tooltip, width = 55, x, numeric, digits, maxLetters, format(value) -> text,
--                parse(text) -> value or nil, validate(value) -> bool }
--     x: the input's left edge (default right-aligned); digits: the box takes digits only. Text that
--     still reads format(current value) keeps that value exactly, so clicking through a field that
--     rounds its value (whole gold, a percent) stages nothing
--   panel:Slider{ key, label, tooltip, min, max, step, format(value) -> text }
--   panel:Dropdown{ key, label, tooltip, labels, values, tooltips, inline, width }   -- inline: label left, dropdown right
--   panel:Radio{ key, options = { { value =, label =, tooltip = } }, indent }
--   panel:Keybind{ key, label, tooltip }                  -- capture button and Clear (stages no value)
--   panel:MultiLine{ key, height, maxLetters, maxBytes, placeholder, fontScale, tooltip, validate(text) -> bool }
--   panel:Button{ text, width, tooltip, onClick(window) }
--   panel:Custom{ height, keys = { ... }, build(row, window, layout), refresh(row, window) }
--     keys: settings the row stages itself, so Defaults covers them; refresh runs after every sync and stage
--
--   window:Get(key)   window:Stage(key, value)   window:Apply()   window:Cancel()
--   window:HasEdits()  -- a staged value, or an Input being typed in
--   window:Toggle()   window:Open()   window:SelectCategory(key)
--   window:NotifyConfigChanged(key)   -- for an addon with no config event (nil: every setting)
--   window.panels[categoryKey]         -- .content, .layout (pad, rowHeight, contentWidth, inputX(width))
---------------------------------------------------------------------------
local UI = CobySuite_ApexFury.UI
local U = CobySuite_ApexFury.Utilities

local SIDEBAR_W = 140
local SIDEBAR_BUTTON_H = 28
local PAD = 16
local ROW_H = 26
local SECTION_H = 25
local SECTION_GAP = 22       -- above every section but a panel's first row
local INPUT_W = 55
local SCROLLBAR_ROOM = 20    -- the scroll indicator and a margin, right of every control
local CONTENT_TOP = 26       -- below the title bar
local FOOTER_H = 44          -- the bottom bar
local FOOTER_BUTTON_W, FOOTER_BUTTON_H = 120, 24
local CLEAR = {}             -- a staged "no value", which Apply stores as nil

local Settings = {}
local Panel = {}
Panel.__index = Panel

local function Color(region, c)
  region:SetTextColor(c[1], c[2], c[3])
end

---------------------------------------------------------------------------
-- Scroll indicator: a thin track and a draggable thumb beside a panel
---------------------------------------------------------------------------
local function AddScrollIndicator(scroll)
  local track = CreateFrame("Frame", nil, scroll)
  track:SetWidth(6)
  track:SetPoint("TOPRIGHT", 0, -2)
  track:SetPoint("BOTTOMRIGHT", 0, 2)
  track:SetFrameLevel(scroll:GetFrameLevel() + 10)

  local trackBg = track:CreateTexture(nil, "BACKGROUND")
  trackBg:SetAllPoints()
  local bar = U.Colors.BAR_BG
  trackBg:SetColorTexture(bar[1], bar[2], bar[3], 0.3)

  local thumb = CreateFrame("Button", nil, track)
  thumb:SetWidth(6)
  local thumbTex = thumb:CreateTexture(nil, "ARTWORK")
  thumbTex:SetAllPoints()
  local gray = U.Colors.DISABLED_GRAY
  thumbTex:SetColorTexture(gray[1], gray[2], gray[3], 0.6)
  local light = U.Colors.LIGHT_GRAY
  UI.AddHoverHighlight(thumb, { light[1], light[2], light[3], 0.3 })

  local function Update()
    local range = scroll:GetVerticalScrollRange()
    if range <= 0 then
      track:Hide()
      return
    end
    track:Show()
    local trackH = track:GetHeight()
    if trackH <= 0 then return end
    local ratio = scroll:GetHeight() / (scroll:GetHeight() + range)
    local thumbH = math.max(20, math.floor(trackH * ratio))
    thumb:SetHeight(thumbH)
    local travel = trackH - thumbH
    thumb:ClearAllPoints()
    thumb:SetPoint("TOPRIGHT", track, "TOPRIGHT", 0, -math.floor(scroll:GetVerticalScroll() / range * travel))
  end

  local function ScrollTo(offset)
    local range = scroll:GetVerticalScrollRange()
    scroll:SetVerticalScroll(math.max(0, math.min(range, offset)))
    Update()
  end

  scroll:EnableMouseWheel(true)
  scroll:SetScript("OnMouseWheel", function(self, delta)
    if self:GetVerticalScrollRange() <= 0 then return end
    ScrollTo(self:GetVerticalScroll() - delta * 30)
  end)

  local function CursorY()
    return select(2, GetCursorPosition()) / UIParent:GetEffectiveScale()
  end

  thumb:RegisterForDrag("LeftButton")
  thumb:SetScript("OnDragStart", function(self)
    self.dragging = true
    self.startY = CursorY()
    self.startScroll = scroll:GetVerticalScroll()
  end)
  thumb:SetScript("OnDragStop", function(self) self.dragging = false end)
  thumb:SetScript("OnHide", function(self) self.dragging = false end)
  thumb:SetScript("OnUpdate", function(self)
    if not self.dragging then return end
    local travel = track:GetHeight() - self:GetHeight()
    if travel <= 0 then return end
    ScrollTo(self.startScroll + (self.startY - CursorY()) / travel * scroll:GetVerticalScrollRange())
  end)

  track:EnableMouse(true)
  track:SetScript("OnMouseDown", function(self, button)
    if button ~= "LeftButton" then return end
    local height = self:GetHeight()
    if height <= 0 then return end
    ScrollTo((self:GetTop() - CursorY()) / height * scroll:GetVerticalScrollRange())
  end)

  scroll.UpdateScrollIndicator = Update
end

---------------------------------------------------------------------------
-- Staging
---------------------------------------------------------------------------

-- The staged value, else the saved one
function Settings:Get(key)
  local staged = self.pending[key]
  if staged == CLEAR then return nil end
  if staged ~= nil then return staged end
  return self.config.Get(key)
end

-- Records a value without refreshing anything
function Settings:StageValue(key, value)
  if value == self.config.Get(key) then
    self.pending[key] = nil
  elseif value == nil then
    self.pending[key] = CLEAR
  else
    self.pending[key] = value
  end
end

-- A user's change to a control. Ignored while the window paints its
-- controls, and while it is closed (a field losing focus as it hides).
function Settings:Stage(key, value)
  if self.syncing or not self:IsShown() then return end
  self:StageValue(key, value)
  self:RefreshState()
end

-- Drops a staged value (a field whose text is not a valid value)
function Settings:Unstage(key)
  if self.pending[key] == nil then return end
  self.pending[key] = nil
  self:RefreshState()
end

-- An Input whose text differs from where its edit started (nothing staged
-- yet). Ignored while the window paints its controls, and while it is closed.
function Settings:SetEditing(key, on)
  if self.syncing or not self:IsShown() then return end
  on = on and true or nil
  if self.editing[key] == on then return end
  self.editing[key] = on
  self:RefreshState()
end

function Settings:HasPending()
  return next(self.pending) ~= nil
end

-- Something for Apply or Cancel to act on: a staged value, or typing
function Settings:HasEdits()
  return self:HasPending() or next(self.editing) ~= nil
end

-- Paints the bound controls from resolver(key), without staging. With
-- skipStaged, a control holding a staged edit or being typed in keeps it.
function Settings:Populate(resolver, onlyKey, skipStaged)
  self.syncing = true
  for _, control in ipairs(self.controls) do
    local key = control.key
    local held = skipStaged and (self.pending[key] ~= nil or self.editing[key])
    if (onlyKey == nil or key == onlyKey) and not held then
      control.set(resolver(key))
    end
  end
  self.syncing = false
  self:RefreshState()
end

-- Stops keybind captures and anything else a control has in progress
function Settings:StopEditing()
  for _, control in ipairs(self.controls) do
    if control.stop then control.stop() end
  end
end

-- Drops every staged value and paints the saved ones
function Settings:Sync()
  self:StopEditing()
  wipe(self.pending)
  wipe(self.editing)
  self:Populate(self.getter)
end

function Settings:Cancel()
  self:Sync()
end

-- The saved value, or nil when reading it throws
local function SafeGet(config, key)
  local ok, value = pcall(config.Get, key)
  if ok then return value end
  return nil
end

function Settings:Apply()
  -- A field being typed in commits first, so its value is staged
  self:StopEditing()
  if not self:HasPending() then
    self:RefreshState()
    return
  end
  local staged = self.pending
  self.pending = {}
  self.applying = true

  local keys = {}
  for key in pairs(staged) do keys[#keys + 1] = key end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)

  local changes, kept, notes = {}, {}, {}
  for _, key in ipairs(keys) do
    local stagedValue = staged[key]
    local value = stagedValue
    if value == CLEAR then value = nil end
    local old = SafeGet(self.config, key)
    local ok, result, reason = pcall(self.config.Set, key, value)
    local name = tostring(key)
    if ok and result == false then
      notes[#notes + 1] = ("Setting %s was not applied: %s"):format(name, tostring(reason))
    elseif ok then
      changes[key] = { old = old, new = SafeGet(self.config, key) }
    else
      local now = SafeGet(self.config, key)
      if now ~= old then
        changes[key] = { old = old, new = now }
        notes[#notes + 1] = ("Setting %s was saved, but applying it failed: %s"):format(name, tostring(result))
      else
        kept[key] = stagedValue
        notes[#notes + 1] = ("Setting %s was not saved: %s. It is still in the window; press Apply to try again.")
          :format(name, tostring(result))
      end
    end
  end
  self.applying = false

  local print = self.opts.message or print
  for _, note in ipairs(notes) do
    print(note)
  end
  if next(changes) ~= nil and self.opts.onApply then
    local ok, err = pcall(self.opts.onApply, changes, self)
    if not ok then
      print(("Settings were saved, but applying them failed: %s"):format(tostring(err)))
    end
  end

  if next(kept) == nil then
    self:Sync()
  else
    self.pending = kept
    self:Populate(self.getter)
  end
end

-- Stages the default of every setting the window shows
function Settings:StageDefaults()
  local defaults = self.config.Defaults or {}
  for key in pairs(self.keys) do
    self:StageValue(key, defaults[key])
  end
  self:Populate(self.getter)
end

-- A setting changed outside the window: repaint it (every setting for a nil
-- key) unless its control holds a staged edit
function Settings:NotifyConfigChanged(key)
  if self.applying or not self:IsShown() then return end
  self:Populate(function(k) return self.config.Get(k) end, key, true)
end

-- Buttons, enabled states, visible rows and custom refreshers
function Settings:RefreshState()
  local edits = self:HasEdits()
  self.ApplyButton:SetEnabled(edits)
  self.CancelButton:SetEnabled(edits)
  for _, row in ipairs(self.dynamicRows) do
    if row.enabledWhen and row.SetRowEnabled then
      row.SetRowEnabled(row.enabledWhen(self.getter) and true or false)
    end
  end
  for _, panel in ipairs(self.panelList) do
    if panel.Layout then panel:Layout() end
  end
  for _, refresher in ipairs(self.refreshers) do
    refresher()
  end
end

---------------------------------------------------------------------------
-- Categories
---------------------------------------------------------------------------
function Settings:SelectCategory(key)
  if not self.panels[key] then return end
  for categoryKey, panel in pairs(self.panels) do
    local selected = categoryKey == key
    panel.frame:SetShown(selected)
    if selected and panel.scroll then
      panel.scroll:SetVerticalScroll(0)
      C_Timer.After(0, panel.scroll.UpdateScrollIndicator)
    end
  end
  for _, button in ipairs(self.sidebarButtons) do
    local selected = button.categoryKey == key
    button.Selected:SetShown(selected)
    button.Text:SetFontObject(selected and U.Fonts.BODY or U.Fonts.SMALL)
  end
  self.activeCategory = key
end

function Settings:Open()
  if not self:IsShown() then self:Toggle() end
end

---------------------------------------------------------------------------
-- Panel rows
---------------------------------------------------------------------------
function Panel:AddRow(height, opts, gap)
  local row = CreateFrame("Frame", nil, self.content)
  row:SetHeight(height)
  row.gap = gap or 0
  if opts then
    row.visibleWhen = opts.visibleWhen
    row.enabledWhen = opts.enabledWhen
    if opts.visibleWhen or opts.enabledWhen then
      table.insert(self.window.dynamicRows, row)
    end
    if opts.refresh then
      local window = self.window
      table.insert(window.refreshers, function() opts.refresh(row, window) end)
    end
  end
  self.rows[#self.rows + 1] = row
  return row
end

-- Stacks the visible rows from the top and sizes the scroll child
function Panel:Layout()
  local get = self.window.getter
  local y = -PAD
  local first = true
  for _, row in ipairs(self.rows) do
    local visible = true
    if row.visibleWhen then visible = row.visibleWhen(get) and true or false end
    row:SetShown(visible)
    if visible then
      if row.Measure then row.Measure() end
      if not first then y = y - row.gap end
      row:ClearAllPoints()
      row:SetPoint("TOPLEFT", self.content, "TOPLEFT", 0, y)
      row:SetPoint("TOPRIGHT", self.content, "TOPRIGHT", 0, y)
      y = y - row:GetHeight()
      first = false
    end
  end
  self.content:SetHeight(-y + PAD)
  if self.scroll and self.scroll.UpdateScrollIndicator then
    self.scroll.UpdateScrollIndicator()
  end
end

-- A label on a row, vertically centred on the first ROW_H of it
function Panel:Label(row, text, tooltip, x, maxWidth)
  local label = row:CreateFontString(nil, "OVERLAY", U.Fonts.DATA)
  label:SetPoint("LEFT", row, "TOPLEFT", x or PAD, -ROW_H / 2)
  label:SetJustifyH("LEFT")
  label:SetWordWrap(false)
  if maxWidth then label:SetWidth(maxWidth) end
  label:SetText(text or "")
  if tooltip then UI.AddTooltip(label, tooltip, "ANCHOR_RIGHT") end
  return label
end

-- A label's colour for the row's enabled state (its own colour, kept the
-- first time, or the disabled grey)
local function SetLabelEnabled(label, enabled)
  if not label then return end
  if not label.enabledColor then
    local r, g, b = label:GetTextColor()
    label.enabledColor = { r, g, b }
  end
  Color(label, enabled and label.enabledColor or U.Colors.DISABLED_GRAY)
end

function Panel:Bind(key, set, stop)
  local window = self.window
  window.keys[key] = true
  table.insert(window.controls, { key = key, set = set, stop = stop })
end

function Panel:Section(text, opts)
  local row = self:AddRow(SECTION_H, opts, SECTION_GAP)
  row.Header = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  row.Header:SetPoint("LEFT", row, "TOPLEFT", PAD, -8)
  row.Header:SetText(text or "")
  local c = U.Colors.DIVIDER_GRAY
  row.Divider = row:CreateTexture(nil, "ARTWORK")
  row.Divider:SetColorTexture(c[1], c[2], c[3], c[4])
  row.Divider:SetHeight(1)
  row.Divider:SetPoint("TOPLEFT", row, "TOPLEFT", PAD, -16)
  row.Divider:SetPoint("TOPRIGHT", row, "TOPRIGHT", -PAD, -16)
  return row
end

function Panel:Description(text, opts)
  local row = self:AddRow(ROW_H, opts)
  row.Text = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  row.Text:SetPoint("TOPLEFT", row, "TOPLEFT", PAD, -4)
  row.Text:SetWidth(self.layout.contentWidth - PAD * 2 - SCROLLBAR_ROOM)
  row.Text:SetJustifyH("LEFT")
  row.Text:SetWordWrap(true)
  row.Text:SetText(text or "")
  row.Measure = function()
    row:SetHeight(math.max(ROW_H - 6, math.ceil(row.Text:GetStringHeight()) + 10))
  end
  return row
end

function Panel:Checkbox(o)
  local window = self.window
  local row = self:AddRow(ROW_H, o)
  row.Checkbox = UI.CreateCheckbox(row, {
    size = 24,
    label = o.label,
    tooltip = o.tooltip,
    point = { "LEFT", row, "TOPLEFT", PAD + (o.indent or 0), -ROW_H / 2 },
    onChange = function(checked) window:Stage(o.key, checked) end,
  })
  row.SetRowEnabled = function(enabled) row.Checkbox:SetEnabled(enabled) end
  self:Bind(o.key, function(value) row.Checkbox:SetChecked(value and true or false) end)
  return row
end

function Panel:Input(o)
  local window = self.window
  local row = self:AddRow(ROW_H, o)
  local width = o.width or INPUT_W
  local x = o.x or self.layout.inputX(width)
  row.Label = self:Label(row, o.label, o.tooltip, PAD + (o.indent or 0), x - PAD - (o.indent or 0) - 8)

  local format = o.format or function(value)
    if value == nil then return "" end
    if type(value) == "number" then return ("%.14g"):format(value) end   -- 3, never 3.0
    return tostring(value)
  end
  -- A numeric field takes finite numbers only: "inf", "1e999" and (where the
  -- client parses it) "nan" are refused like any other text that is no number
  local parse = o.parse or (o.numeric and function(text)
    local n = tonumber(text)
    if U.IsFiniteNumber(n) then return n end
  end) or function(text) return text end

  -- The text when this edit began: typing lights Apply and Cancel while the
  -- text differs from it. Nothing is parsed or staged until the commit, so a
  -- field that rounds its value never stages a half-typed number.
  local editStart

  row.Input = UI.CreateTextInput(row, {
    width = width,
    maxLetters = o.maxLetters,
    tooltip = o.tooltip,
    point = { "LEFT", row, "TOPLEFT", x, -ROW_H / 2 },
    parse = function(text)
      text = strtrim(text)
      local current = window:Get(o.key)
      if current ~= nil and text == format(current) then return current end
      return parse(text)
    end,
    validate = function(value)
      if window.config.CheckValue and not window.config.CheckValue(o.key, value) then return false end
      if o.validate and not o.validate(value) then return false end
      return true
    end,
    format = format,
    onCommit = function(value) window:Stage(o.key, value) end,
    onChange = function(text) window:SetEditing(o.key, text ~= editStart) end,
  })
  row.Input:HookScript("OnEditFocusGained", function(box)
    editStart = box:GetText()
  end)
  -- After the commit (the factory's own focus-loss script runs first)
  row.Input:HookScript("OnEditFocusLost", function()
    window:SetEditing(o.key, false)
  end)
  if o.digits then row.Input:SetNumeric(true) end
  row.SetRowEnabled = function(enabled)
    row.Input:SetEnabled(enabled)
    SetLabelEnabled(row.Label, enabled)
  end
  self:Bind(o.key, function(value)
    row.Input:SetCommittedValue(value)
    row.Input:SetCursorPosition(0)
    -- A repaint replaces whatever was typed: the edit starts again from it
    editStart = row.Input:GetText()
    window.editing[o.key] = nil
  end, function()
    if row.Input:HasFocus() then row.Input:ClearFocus() end
  end)
  return row
end

function Panel:Slider(o)
  local window = self.window
  local row = self:AddRow(ROW_H + 18, o)
  row.Label = self:Label(row, o.label, o.tooltip)
  row.Value = row:CreateFontString(nil, "OVERLAY", U.Fonts.DATA)
  row.Value:SetPoint("RIGHT", row, "TOPRIGHT", -(PAD + SCROLLBAR_ROOM), -ROW_H / 2)
  row.Value:SetJustifyH("RIGHT")

  local format = o.format or function(value) return ("%g"):format(value) end
  local min = o.min or 0
  row.Slider = UI.CreateSlider(row, {
    template = "MinimalSliderTemplate",
    width = self.layout.contentWidth - PAD * 2 - SCROLLBAR_ROOM,
    height = 16,
    min = min,
    max = o.max or 100,
    step = o.step or 1,
    showValue = false,
    tooltip = o.tooltip,
    point = { "TOPLEFT", row, "TOPLEFT", PAD, -ROW_H + 2 },
    onChange = function(value)
      row.Value:SetText(format(value))
      window:Stage(o.key, value)
    end,
  })
  row.SetRowEnabled = function(enabled)
    row.Slider:SetEnabled(enabled)
    SetLabelEnabled(row.Label, enabled)
  end
  self:Bind(o.key, function(value)
    local v = value
    if type(v) ~= "number" then v = min end
    row.Slider:SetValue(v)
    row.Value:SetText(format(v))
  end)
  return row
end

function Panel:Dropdown(o)
  local window = self.window
  local row
  if o.inline then
    row = self:AddRow(ROW_H + 4, o)
    local width = o.width or 160
    row.Label = self:Label(row, o.label, o.tooltip, PAD, self.layout.inputX(width) - PAD - 8)
    row.Label:ClearAllPoints()
    row.Label:SetPoint("LEFT", row, "TOPLEFT", PAD, -(ROW_H + 4) / 2)
    row.Dropdown = UI.CreateDropDown(row, {
      label = false,
      width = width,
      point = { "LEFT", row, "TOPLEFT", self.layout.inputX(width), -(ROW_H + 4) / 2 },
      labels = o.labels, values = o.values, tooltips = o.tooltips,
      onValueChanged = function(value) window:Stage(o.key, value) end,
    })
  else
    row = self:AddRow(46, o)
    row.Dropdown = UI.CreateDropDown(row, {
      label = o.label or false,
      width = o.width or (self.layout.contentWidth - PAD * 2 - SCROLLBAR_ROOM),
      point = { "TOPLEFT", row, "TOPLEFT", PAD, -4 },
      labels = o.labels, values = o.values, tooltips = o.tooltips,
      onValueChanged = function(value) window:Stage(o.key, value) end,
    })
    row.Label = o.label and row.Dropdown.Label or nil
    if row.Label and o.tooltip then UI.AddTooltip(row.Label, o.tooltip, "ANCHOR_RIGHT") end
  end
  row.SetRowEnabled = function(enabled)
    row.Dropdown.DropDown:SetEnabled(enabled)
    SetLabelEnabled(row.Label, enabled)
  end
  self:Bind(o.key, function(value) row.Dropdown:SetValue(value) end)
  return row
end

function Panel:Radio(o)
  local window = self.window
  local options = o.options or {}
  local row = self:AddRow(ROW_H * math.max(1, #options), o)
  row.Buttons = {}
  local function Check(value)
    for _, entry in ipairs(row.Buttons) do
      entry.button:SetChecked(entry.value == value)
    end
  end
  for i, option in ipairs(options) do
    local button = UI.CreateRadioButton(row, {
      label = option.label,
      tooltip = option.tooltip or o.tooltip,
      point = { "LEFT", row, "TOPLEFT", PAD + (o.indent or 0), -(i - 0.5) * ROW_H },
      onChange = function()
        Check(option.value)
        window:Stage(o.key, option.value)
      end,
    })
    row.Buttons[i] = { value = option.value, button = button }
  end
  row.SetRowEnabled = function(enabled)
    for _, entry in ipairs(row.Buttons) do entry.button:SetEnabled(enabled) end
  end
  self:Bind(o.key, Check)
  return row
end

local MODIFIER_KEYS = { LSHIFT = true, RSHIFT = true, LCTRL = true, RCTRL = true, LALT = true, RALT = true }

function Panel:Keybind(o)
  local window = self.window
  local row = self:AddRow(ROW_H + 4, o)
  local clearX = self.layout.contentWidth - PAD - SCROLLBAR_ROOM - 60
  local captureX = clearX - 6 - 130
  row.Label = self:Label(row, o.label, o.tooltip, PAD, captureX - PAD - 8)
  row.Label:ClearAllPoints()
  row.Label:SetPoint("LEFT", row, "TOPLEFT", PAD, -(ROW_H + 4) / 2)

  local function Text(value)
    return value or "Not Set"
  end

  row.Capture = UI.CreateButton(row, {
    size = { 130, 24 }, text = "Not Set", tooltip = o.tooltip,
    point = { "LEFT", row, "TOPLEFT", captureX, -(ROW_H + 4) / 2 },
  })
  local capture = row.Capture

  local function StopCapture()
    if not capture.capturing then return end
    capture.capturing = false
    capture:SetScript("OnKeyDown", nil)
    capture:EnableKeyboard(false)
    capture:SetText(Text(window:Get(o.key)))
  end

  capture:SetScript("OnClick", function(self)
    if self.capturing or InCombatLockdown() then return end
    self.capturing = true
    self:SetText("Press a key...")
    self:EnableKeyboard(true)
    self:SetScript("OnKeyDown", function(button, key)
      button:SetPropagateKeyboardInput(false)
      if MODIFIER_KEYS[key] then return end   -- keep waiting for the real key
      if key == "ESCAPE" then
        StopCapture()
        return
      end
      local binding = (IsShiftKeyDown() and "SHIFT-" or "") .. (IsControlKeyDown() and "CTRL-" or "")
        .. (IsAltKeyDown() and "ALT-" or "") .. key
      StopCapture()
      window:Stage(o.key, binding)
      button:SetText(Text(binding))
    end)
  end)
  capture:SetScript("OnHide", StopCapture)

  row.Clear = UI.CreateButton(row, {
    size = { 60, 22 }, text = "Clear",
    point = { "LEFT", capture, "RIGHT", 6, 0 },
    onClick = function()
      StopCapture()
      window:Stage(o.key, nil)
      capture:SetText(Text(window:Get(o.key)))
    end,
  })

  row.SetRowEnabled = function(enabled)
    capture:SetEnabled(enabled)
    row.Clear:SetEnabled(enabled)
    SetLabelEnabled(row.Label, enabled)
  end
  self:Bind(o.key, function(value)
    if not capture.capturing then capture:SetText(Text(value)) end
  end, StopCapture)
  return row
end

-- Newlines fold into spaces, as the shared multi-line box does on commit
local function Fold(text)
  return strtrim((text:gsub("%s*\n%s*", " ")))
end

function Panel:MultiLine(o)
  local window = self.window
  local height = o.height or 60
  local row = self:AddRow(height + 12, o)
  local function Valid(text)
    return not o.validate or o.validate(text)
  end
  row.Box = UI.CreateMultiLineInput(row, {
    width = self.layout.contentWidth - PAD * 2 - SCROLLBAR_ROOM,
    height = height,
    maxLetters = o.maxLetters,
    maxBytes = o.maxBytes,
    placeholder = o.placeholder,
    fontScale = o.fontScale,
    tooltip = o.tooltip,
    point = { "TOPLEFT", row, "TOPLEFT", PAD + 4, -6 },
    validate = Valid,
    onCommit = function(text) window:Stage(o.key, text) end,
    -- Every keystroke stages, so Apply is ready without leaving the box; text
    -- that is not a valid value is simply not staged
    onChange = function(text)
      local folded = Fold(text)
      if Valid(folded) then
        window:Stage(o.key, folded)
      else
        window:Unstage(o.key)
      end
    end,
  })
  -- Escape, and leaving a box whose text is not valid, put the last text
  -- back without a user edit; stage what the box then shows, so Apply never
  -- saves text the box no longer holds
  local function StageShown()
    local folded = Fold(row.Box.EditBox:GetText())
    if Valid(folded) then
      window:Stage(o.key, folded)
    else
      window:Unstage(o.key)
    end
  end
  row.Box.EditBox:HookScript("OnEscapePressed", StageShown)
  row.Box.EditBox:HookScript("OnEditFocusLost", StageShown)
  self:Bind(o.key, function(value) row.Box:SetCommittedValue(value) end, function()
    if row.Box.EditBox:HasFocus() then row.Box.EditBox:ClearFocus() end
  end)
  return row
end

function Panel:Button(o)
  local window = self.window
  local row = self:AddRow(ROW_H + 4, o)
  row.Button = UI.CreateButton(row, {
    size = { o.width or 220, 22 }, text = o.text, tooltip = o.tooltip,
    point = { "LEFT", row, "TOPLEFT", PAD + (o.indent or 0), -(ROW_H + 4) / 2 },
    onClick = function() if o.onClick then o.onClick(window) end end,
  })
  row.SetRowEnabled = function(enabled) row.Button:SetEnabled(enabled) end
  return row
end

function Panel:Custom(o)
  local window = self.window
  local row = self:AddRow(o.height or ROW_H, o)
  if o.keys then
    for _, key in ipairs(o.keys) do window.keys[key] = true end
  end
  if o.build then o.build(row, window, self.layout) end
  return row
end

---------------------------------------------------------------------------
-- Construction
---------------------------------------------------------------------------
local function BuildSidebar(window, categories)
  local sidebar = CreateFrame("Frame", nil, window)
  sidebar:SetPoint("TOPLEFT", 8, -CONTENT_TOP)
  sidebar:SetPoint("BOTTOMLEFT", 8, FOOTER_H)
  sidebar:SetWidth(SIDEBAR_W)

  local bg = sidebar:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  local sb = U.Colors.SIDEBAR_BG
  bg:SetColorTexture(sb[1], sb[2], sb[3], sb[4])

  local divider = sidebar:CreateTexture(nil, "ARTWORK")
  local dg = U.Colors.DIVIDER_GRAY
  divider:SetColorTexture(dg[1], dg[2], dg[3], dg[4])
  divider:SetWidth(1)
  divider:SetPoint("TOPRIGHT")
  divider:SetPoint("BOTTOMRIGHT")

  local gold = U.Colors.STATUS_GOLD
  for i, category in ipairs(categories) do
    local button = CreateFrame("Button", nil, sidebar)
    button:SetSize(SIDEBAR_W - 10, SIDEBAR_BUTTON_H)
    button:SetPoint("TOPLEFT", 5, -(8 + (i - 1) * (SIDEBAR_BUTTON_H + 2)))
    button.categoryKey = category.key

    button.Text = button:CreateFontString(nil, "OVERLAY", U.Fonts.SMALL)
    button.Text:SetPoint("LEFT", 12, 0)
    button.Text:SetText(category.label or category.key)

    button.Selected = button:CreateTexture(nil, "BACKGROUND")
    button.Selected:SetAllPoints()
    button.Selected:SetColorTexture(gold[1], gold[2], gold[3], 0.15)
    button.Selected:Hide()

    UI.AddHoverHighlight(button, U.Colors.HOVER_HIGHLIGHT)
    button:SetScript("OnClick", function() window:SelectCategory(category.key) end)
    window.sidebarButtons[i] = button
  end
  return sidebar
end

function UI.CreateSettingsWindow(opts)
  assert(opts and opts.name and opts.config, "CreateSettingsWindow needs name and config")
  local categories = opts.categories or {}
  local withSidebar = #categories > 1
  local width = opts.width or 680
  local height = opts.height or 480

  local persist
  if opts.persist then
    persist = {
      svTable = opts.persist.svTable,
      key = opts.persist.key or "settings",
      defaults = opts.persist.defaults or { point = "CENTER", relPoint = "CENTER", x = 0, y = 0 },
      fixedSize = true,
    }
  end

  local window = UI.CreateWindow({
    name = opts.name,
    title = opts.title,
    width = width,
    height = height,
    escapeCloses = true,
    persist = persist,
    strata = opts.strata,
  })
  Mixin(window, Settings)
  window.opts = opts
  window.config = opts.config
  window.pending = {}
  window.editing = {}
  window.controls = {}
  window.keys = {}
  window.refreshers = {}
  window.dynamicRows = {}
  window.panels = {}
  window.panelList = {}
  window.sidebarButtons = {}
  window.getter = function(key) return window:Get(key) end

  local contentArea = CreateFrame("Frame", nil, window)
  if withSidebar then
    local sidebar = BuildSidebar(window, categories)
    contentArea:SetPoint("TOPLEFT", sidebar, "TOPRIGHT", 4, 0)
  else
    contentArea:SetPoint("TOPLEFT", 8, -CONTENT_TOP)
  end
  contentArea:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", -8, FOOTER_H)
  window.ContentArea = contentArea
  local contentWidth = width - 16 - (withSidebar and (SIDEBAR_W + 4) or 0)

  -- The bottom bar first: RefreshState reads its buttons
  window.DefaultsPopup = UI.CreateDialogPopup({
    name = opts.name .. "DefaultsPopup",
    title = "Reset to Defaults?",
    width = 340,
    height = 130,
    parent = window,
    point = { "CENTER", window, "CENTER", 0, 0 },
    body = "Every setting in this window goes back to its default. Press Apply to keep them.",
    confirmText = "Reset",
    hidden = true,
    onConfirm = function() window:StageDefaults() end,
  })
  window.DefaultsPopup:SetFrameStrata("FULLSCREEN_DIALOG")

  window.DefaultsButton = UI.CreateButton(window, {
    size = { FOOTER_BUTTON_W, FOOTER_BUTTON_H }, text = "Defaults",
    tooltip = "Stage the default of every setting in this window",
    point = { "BOTTOMLEFT", 12, 12 },
    onClick = function() window.DefaultsPopup:Show() end,
  })
  local previous = window.DefaultsButton
  for _, extra in ipairs(opts.footerButtons or {}) do
    previous = UI.CreateButton(window, {
      size = { extra.width or FOOTER_BUTTON_W, FOOTER_BUTTON_H }, text = extra.text, tooltip = extra.tooltip,
      point = { "LEFT", previous, "RIGHT", 6, 0 },
      onClick = function() if extra.onClick then extra.onClick(window) end end,
    })
  end
  window.CancelButton = UI.CreateButton(window, {
    size = { FOOTER_BUTTON_W, FOOTER_BUTTON_H }, text = "Cancel",
    point = { "BOTTOMRIGHT", -12, 12 },
    onClick = function() window:Cancel() end,
  })
  window.ApplyButton = UI.CreateButton(window, {
    size = { FOOTER_BUTTON_W, FOOTER_BUTTON_H }, text = "Apply",
    point = { "RIGHT", window.CancelButton, "LEFT", -8, 0 },
    onClick = function() window:Apply() end,
  })
  window.ApplyButton:Disable()
  window.CancelButton:Disable()

  -- Panels
  for _, category in ipairs(categories) do
    local panel
    if category.scroll == false then
      local frame = CreateFrame("Frame", nil, contentArea)
      frame:SetAllPoints(contentArea)
      frame:Hide()
      panel = { key = category.key, frame = frame }
      if category.build then category.build(frame, window) end
    else
      local scroll = CreateFrame("ScrollFrame", nil, contentArea)
      scroll:SetAllPoints(contentArea)
      scroll:Hide()
      local content = CreateFrame("Frame", nil, scroll)
      content:SetWidth(contentWidth)
      content:SetHeight(1)
      scroll:SetScrollChild(content)
      AddScrollIndicator(scroll)

      panel = setmetatable({
        key = category.key,
        frame = scroll,
        scroll = scroll,
        content = content,
        window = window,
        rows = {},
        layout = {
          pad = PAD,
          rowHeight = ROW_H,
          contentWidth = contentWidth,
          inputX = function(inputWidth)
            return contentWidth - (inputWidth or INPUT_W) - PAD - SCROLLBAR_ROOM
          end,
        },
      }, Panel)
      if category.build then category.build(panel, window) end
    end
    window.panels[category.key] = panel
    window.panelList[#window.panelList + 1] = panel
  end

  window:HookScript("OnShow", function(self)
    if not self.activeCategory and categories[1] then
      self:SelectCategory(categories[1].key)
    end
    self:Sync()
    local panel = self.panels[self.activeCategory]
    if panel and panel.scroll then
      C_Timer.After(0, panel.scroll.UpdateScrollIndicator)
    end
  end)
  window:HookScript("OnHide", function(self)
    self:StopEditing()
    wipe(self.pending)
    wipe(self.editing)
    self.DefaultsPopup:Hide()
  end)

  if opts.watch and opts.watch.bus and opts.watch.event then
    opts.watch.bus:Register({
      ReceiveEvent = function(_, _, key) window:NotifyConfigChanged(key) end,
    }, { opts.watch.event })
  end

  -- Controls are painted when the window shows: the SavedVariables may not
  -- be loaded yet while it is built
  if categories[1] then window:SelectCategory(categories[1].key) end
  return window
end
