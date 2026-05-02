---------------------------------------------------------------------------
-- CobySuite Shared UI Factories: tooltips, buttons, toolbars, dropdowns,
-- dialogs, clear buttons, checkbox menus
---------------------------------------------------------------------------
local UI = CobySuite.UI
local U = CobySuite.Utilities

---------------------------------------------------------------------------
-- Tooltip helpers
--
-- Five flavors, all attach OnEnter/OnLeave scripts to `frame`:
--
--   AddTooltip(frame, text, anchor)
--     Plain wrapped text.
--
--   AddItemTooltip(frame, itemIDOrFunc, anchor, opts)
--     Blizzard item tooltip. itemIDOrFunc can be a number or a function
--     that returns one (called per-hover, useful for reusable rows).
--     opts.compareOnShift = true → calls GameTooltip_ShowCompareItem
--                                   (Blizzard gates the visible compare
--                                    panes on shift internally).
--     opts.cleanShopping  = true → also hides ShoppingTooltip1/2 on leave.
--
--   AddSpellTooltip(frame, spellIDOrFunc, anchor)
--     Blizzard spell tooltip (SetSpellByID). Polymorphic ID like above.
--
--   AddRichTooltip(frame, header, lines, anchor)
--     Header + body lines. Each line may be:
--       "string"                              plain wrap-line, default white
--       { text, r, g, b }                     positional colored line (legacy)
--       { text="...", color={r,g,b} }         keyed colored line
--       { left="L", right="R",                double-line key/value
--         leftColor={r,g,b}, rightColor=… }
--
--   AddDynamicTooltip(frame, builder, opts)
--     builder(GameTooltip, frame) runs each OnEnter, building lines fresh.
--     opts.anchor       = "ANCHOR_RIGHT" (default)
--     opts.cursorFollow = true → SetOwner with ANCHOR_CURSOR and re-run
--                                builder every frame for cursor-tracking
--                                tooltips (e.g. chart hover read-outs).
--
--   AddBrandedTooltip(frame, opts)
--     Tooltip for "addon entry" surfaces (minimap button, addon
--     compartment menu, splash). Provides a consistent look across
--     CobySuite addons:
--       opts.brandColor  hex "FF8800" or {r,g,b} → title color
--       opts.title       string
--       opts.subtitle    string (smaller, gray)
--       opts.body        { "line", ... } or function returning that
--       opts.keys        { { key=, desc= }, ... } → keybind hints
--                         (gold key, gray em-dash, white desc)
--       opts.anchor      "ANCHOR_RIGHT" (default)
---------------------------------------------------------------------------
function UI.AddTooltip(frame, text, anchor)
  frame:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, anchor or "ANCHOR_RIGHT")
    GameTooltip:SetText(text, 1, 1, 1, 1, true)
    GameTooltip:Show()
  end)
  frame:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

local function ResolveID(idOrFunc, frame)
  if type(idOrFunc) == "function" then
    return idOrFunc(frame)
  end
  return idOrFunc
end

function UI.AddItemTooltip(frame, itemIDOrFunc, anchor, opts)
  opts = opts or {}
  frame:SetScript("OnEnter", function(self)
    local itemID = ResolveID(itemIDOrFunc, self)
    if not itemID then return end
    GameTooltip:SetOwner(self, anchor or "ANCHOR_RIGHT")
    GameTooltip:SetItemByID(itemID)
    local compare = opts.compareOnShift
    if type(compare) == "function" then compare = compare(self) end
    if compare and GameTooltip_ShowCompareItem then
      GameTooltip_ShowCompareItem(GameTooltip)
    end
    GameTooltip:Show()
  end)
  frame:SetScript("OnLeave", function()
    GameTooltip:Hide()
    if opts.cleanShopping then
      if ShoppingTooltip1 then ShoppingTooltip1:Hide() end
      if ShoppingTooltip2 then ShoppingTooltip2:Hide() end
    end
  end)
end

function UI.AddSpellTooltip(frame, spellIDOrFunc, anchor)
  frame:SetScript("OnEnter", function(self)
    local spellID = ResolveID(spellIDOrFunc, self)
    if not spellID then return end
    GameTooltip:SetOwner(self, anchor or "ANCHOR_RIGHT")
    GameTooltip:SetSpellByID(spellID)
    GameTooltip:Show()
  end)
  frame:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

local function AppendRichLine(line)
  if type(line) == "string" then
    GameTooltip:AddLine(line, nil, nil, nil, true)
  elseif type(line) == "table" then
    if line.left ~= nil or line.right ~= nil then
      local lc = line.leftColor  or { 1, 1, 1 }
      local rc = line.rightColor or { 1, 1, 1 }
      GameTooltip:AddDoubleLine(
        line.left or "", line.right or "",
        lc[1], lc[2], lc[3],
        rc[1], rc[2], rc[3])
    elseif line.text ~= nil then
      local c = line.color
      if c then
        GameTooltip:AddLine(line.text, c[1], c[2], c[3], true)
      else
        GameTooltip:AddLine(line.text, nil, nil, nil, true)
      end
    else
      -- Positional legacy form: { text, r, g, b }
      GameTooltip:AddLine(line[1], line[2], line[3], line[4], true)
    end
  end
end

function UI.AddRichTooltip(frame, header, lines, anchor)
  frame:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, anchor or "ANCHOR_RIGHT")
    GameTooltip:SetText(header, 1, 1, 1, 1, true)
    if lines then
      for _, line in ipairs(lines) do
        AppendRichLine(line)
      end
    end
    GameTooltip:Show()
  end)
  frame:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

function UI.AddDynamicTooltip(frame, builder, opts)
  opts = opts or {}
  local anchor = opts.anchor or "ANCHOR_RIGHT"
  local cursorFollow = opts.cursorFollow

  frame:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, anchor)
    builder(GameTooltip, self)
    GameTooltip:Show()
    if cursorFollow then
      self:SetScript("OnUpdate", function(s)
        GameTooltip:ClearLines()
        builder(GameTooltip, s)
        GameTooltip:Show()
      end)
    end
  end)
  frame:SetScript("OnLeave", function(self)
    if cursorFollow then self:SetScript("OnUpdate", nil) end
    GameTooltip:Hide()
  end)
end

local function ParseHexColor(hex)
  if type(hex) ~= "string" or #hex < 6 then return nil end
  local r = tonumber(hex:sub(1, 2), 16)
  local g = tonumber(hex:sub(3, 4), 16)
  local b = tonumber(hex:sub(5, 6), 16)
  if not (r and g and b) then return nil end
  return r / 255, g / 255, b / 255
end

-- Populate an arbitrary tooltip frame with branded content. Useful in
-- callbacks where Blizzard hands you the tooltip (LDB OnTooltipShow,
-- addon-compartment OnEnter, etc.) and you can't attach a hover script.
function UI.PopulateBrandedTooltip(tooltip, opts)
  opts = opts or {}

  local br, bg, bb = 1, 0.82, 0
  if opts.brandColor then
    if type(opts.brandColor) == "string" then
      local r, g, b = ParseHexColor(opts.brandColor)
      if r then br, bg, bb = r, g, b end
    elseif type(opts.brandColor) == "table" then
      br, bg, bb = opts.brandColor[1], opts.brandColor[2], opts.brandColor[3]
    end
  end

  if opts.title then
    tooltip:SetText(opts.title, br, bg, bb, 1, true)
  end
  if opts.subtitle then
    tooltip:AddLine(opts.subtitle, 0.7, 0.7, 0.7, true)
  end

  local body = opts.body
  if type(body) == "function" then body = body() end
  if type(body) == "table" then
    for _, line in ipairs(body) do
      if type(line) == "string" then
        tooltip:AddLine(line, 1, 1, 1, true)
      elseif type(line) == "table" then
        if line.left ~= nil or line.right ~= nil then
          local lc = line.leftColor  or { 1, 1, 1 }
          local rc = line.rightColor or { 1, 1, 1 }
          tooltip:AddDoubleLine(
            line.left or "", line.right or "",
            lc[1], lc[2], lc[3], rc[1], rc[2], rc[3])
        elseif line.text ~= nil then
          local c = line.color
          if c then
            tooltip:AddLine(line.text, c[1], c[2], c[3], true)
          else
            tooltip:AddLine(line.text, nil, nil, nil, true)
          end
        end
      end
    end
  end

  if opts.keys and #opts.keys > 0 then
    tooltip:AddLine(" ")
    for _, kb in ipairs(opts.keys) do
      tooltip:AddLine(
        string.format("|cFFFFD100%s|r |cFF888888—|r %s",
          kb.key or "", kb.desc or ""),
        1, 1, 1, true)
    end
  end

  tooltip:Show()
end

function UI.AddBrandedTooltip(frame, opts)
  opts = opts or {}
  local anchor = opts.anchor or "ANCHOR_RIGHT"
  frame:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, anchor)
    UI.PopulateBrandedTooltip(GameTooltip, opts)
  end)
  frame:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

---------------------------------------------------------------------------
-- CreateButton
---------------------------------------------------------------------------
function UI.CreateButton(parent, opts)
  local btn = CreateFrame("Button", opts.name, parent, opts.template or "UIPanelButtonTemplate")
  if opts.size then btn:SetSize(opts.size[1], opts.size[2]) end
  if opts.point then btn:SetPoint(unpack(opts.point)) end
  if opts.text then btn:SetText(opts.text) end
  if opts.fontSize then
    local font, _, flags = btn:GetFontString():GetFont()
    btn:GetFontString():SetFont(font, opts.fontSize, flags)
  end
  if opts.onClick then btn:SetScript("OnClick", opts.onClick) end
  if opts.tooltip then UI.AddTooltip(btn, opts.tooltip) end
  return btn
end

---------------------------------------------------------------------------
-- CreateToolbar
---------------------------------------------------------------------------
function UI.CreateToolbar(parent, buttons, opts)
  opts = opts or {}
  local gap = opts.gap or U.Spacing.BUTTON_GAP
  local groupGap = opts.groupGap or U.Spacing.GROUP_GAP
  local tierName = opts.buttonSize or "MEDIUM"
  local tier = U.ButtonSize[tierName]

  local toolbar = CreateFrame("Frame", nil, parent)
  toolbar:SetHeight(tier.height + 4)
  if opts.point then
    toolbar:SetPoint(unpack(opts.point))
  end
  if opts.width then
    toolbar:SetWidth(opts.width)
  else
    toolbar:SetPoint("RIGHT", parent, "RIGHT", 0, 0)
  end

  local btnRefs = {}
  local prevBtn = nil

  for _, def in ipairs(buttons) do
    local spacing = not prevBtn and 0 or (def.groupGap and groupGap or gap)
    local btnOpts = {
      size = { def.width, tier.height },
      text = def.text,
      fontSize = tier.fontSize,
      onClick = def.onClick,
      tooltip = def.tooltip,
    }
    if prevBtn then
      btnOpts.point = { "LEFT", prevBtn, "RIGHT", spacing, 0 }
    else
      btnOpts.point = { "LEFT", 0, 0 }
    end

    local btn = UI.CreateButton(toolbar, btnOpts)
    if def.key then btnRefs[def.key] = btn end
    prevBtn = btn
  end

  toolbar._buttons = btnRefs
  return toolbar, btnRefs
end

---------------------------------------------------------------------------
-- CreateDropDown
---------------------------------------------------------------------------
function UI.CreateDropDown(parent)
  local f = CreateFrame("Frame", nil, parent)
  f:SetSize(200, 40)
  f.Label = f:CreateFontString(nil, "OVERLAY", U.Fonts.BODY)
  f.Label:SetPoint("TOPLEFT", 0, 0)
  f.DropDown = CreateFrame("DropdownButton", nil, f, "WowStyle1DropdownTemplate")
  f.DropDown:SetPoint("TOPLEFT", 0, -14)
  f.DropDown:SetSize(180, 26)
  f.value = nil
  f.labels = {}
  f.values = {}

  function f:InitAgain(labels, values, tooltips)
    f.labels = labels
    f.values = values
    f.DropDown:SetupMenu(function(dd, rootDescription)
      for i, label in ipairs(labels) do
        local radio = rootDescription:CreateRadio(
          label,
          function() return f.value == values[i] end,
          function()
            f.value = values[i]
            f.DropDown:OverrideText(labels[i])
            if f.onValueChanged then f.onValueChanged(values[i]) end
          end
        )
        if tooltips and tooltips[i] then
          radio:SetTooltip(function(tooltip, elementDescription)
            GameTooltip_SetTitle(tooltip, label)
            GameTooltip_AddNormalLine(tooltip, tooltips[i])
          end)
        end
      end
    end)
  end

  function f:SetValue(v)
    f.value = v
    for i, val in ipairs(f.values) do
      if val == v then
        f.DropDown:OverrideText(f.labels[i])
        break
      end
    end
  end

  function f:GetValue()
    return f.value
  end

  return f
end

---------------------------------------------------------------------------
-- CreateDialogPopup
---------------------------------------------------------------------------
function UI.CreateDialogPopup(opts)
  local popup = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
  popup:SetSize(opts.width or 320, opts.height or 120)
  popup:SetPoint("CENTER")
  popup:SetFrameStrata("DIALOG")
  popup:SetBackdrop(U.Backdrops.DIALOG)
  local dbg = U.Colors.DIALOG_BG
  popup:SetBackdropColor(dbg[1], dbg[2], dbg[3], dbg[4])
  popup:EnableMouse(true)
  popup:SetToplevel(true)

  if opts.title then
    popup.Title = popup:CreateFontString(nil, "OVERLAY", U.Fonts.TITLE)
    popup.Title:SetPoint("TOP", 0, -16)
    popup.Title:SetText(opts.title)
  end

  popup.ConfirmButton = CreateFrame("Button", nil, popup, "UIPanelButtonTemplate")
  popup.ConfirmButton:SetSize(100, 24)
  popup.ConfirmButton:SetPoint("BOTTOMRIGHT", popup, "BOTTOM", -4, 12)
  popup.ConfirmButton:SetText(opts.confirmText or "OK")

  popup.CancelButton = CreateFrame("Button", nil, popup, "UIPanelButtonTemplate")
  popup.CancelButton:SetSize(100, 24)
  popup.CancelButton:SetPoint("BOTTOMLEFT", popup, "BOTTOM", 4, 12)
  popup.CancelButton:SetText("Cancel")
  popup.CancelButton:SetScript("OnClick", function() popup:Hide() end)

  popup:SetScript("OnKeyDown", function(self, key)
    if key == "ESCAPE" then
      self:SetPropagateKeyboardInput(false)
      self:Hide()
    else
      self:SetPropagateKeyboardInput(true)
    end
  end)

  return popup
end

---------------------------------------------------------------------------
-- CreateResizeGrip
---------------------------------------------------------------------------
function UI.CreateResizeGrip(frame)
  local grip = CreateFrame("Button", nil, frame)
  grip:SetSize(16, 16)
  grip:SetPoint("BOTTOMRIGHT", -2, 2)
  grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
  grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
  grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
  return grip
end

---------------------------------------------------------------------------
-- SaveWindowState / RestoreWindowState
---------------------------------------------------------------------------
function UI.SaveWindowState(frame, svTable, key)
  if not frame or not svTable then return end
  local point, _, relativePoint, x, y = frame:GetPoint()
  svTable[key] = {
    point = point, relativePoint = relativePoint, x = x, y = y,
    width = frame:GetWidth(), height = frame:GetHeight(),
  }
end

function UI.RestoreWindowState(frame, svTable, key, defaults)
  local state = svTable and svTable[key]
  if state then
    frame:ClearAllPoints()
    frame:SetPoint(state.point or "CENTER", UIParent, state.relativePoint or "CENTER", state.x or 0, state.y or 0)
    if state.width then frame:SetWidth(state.width) end
    if state.height then frame:SetHeight(state.height) end
  elseif defaults then
    frame:ClearAllPoints()
    frame:SetPoint(defaults.point or "CENTER", UIParent, defaults.relPoint or "CENTER", defaults.x or 0, defaults.y or 0)
  end
end

---------------------------------------------------------------------------
-- CreateClearButton
---------------------------------------------------------------------------
function UI.CreateClearButton(editBox, onClear)
  local btn = CreateFrame("Button", nil, editBox)
  btn:SetSize(14, 14)
  btn:SetPoint("RIGHT", -2, 0)
  btn:SetNormalTexture("Interface\\FriendsFrame\\ClearBroadcastIcon")
  btn:SetHighlightTexture("Interface\\FriendsFrame\\ClearBroadcastIcon")
  btn:GetHighlightTexture():SetAlpha(0.5)
  btn:SetScript("OnClick", function()
    editBox:SetText("")
    editBox:ClearFocus()
    if onClear then onClear() end
  end)
  btn:Hide()
  editBox:HookScript("OnTextChanged", function(s)
    btn:SetShown(s:GetText() ~= "")
  end)
  return btn
end

---------------------------------------------------------------------------
-- BuildCheckboxMenu
---------------------------------------------------------------------------
function UI.BuildCheckboxMenu(menuRoot, items, isChecked, setChecked, onChange)
  menuRoot:CreateButton("Check All", function()
    for _, item in ipairs(items) do
      setChecked(item.key, true)
    end
    if onChange then onChange() end
  end):SetResponse(MenuResponse.Refresh)

  menuRoot:CreateButton("Check None", function()
    for _, item in ipairs(items) do
      setChecked(item.key, false)
    end
    if onChange then onChange() end
  end):SetResponse(MenuResponse.Refresh)

  menuRoot:CreateDivider()

  for _, item in ipairs(items) do
    local cb = menuRoot:CreateCheckbox(item.label,
      function() return isChecked(item.key) end,
      function()
        setChecked(item.key, not isChecked(item.key))
        if onChange then onChange() end
      end
    )
    cb:SetResponse(MenuResponse.Refresh)

    cb:AddInitializer(function(button)
      button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
      local originalOnClick = button:GetScript("OnClick")
      button:SetScript("OnClick", function(btn, mouseButton, ...)
        if mouseButton == "RightButton" then
          for _, other in ipairs(items) do
            setChecked(other.key, other.key == item.key)
          end
          if onChange then onChange() end
          if MenuUtil and MenuUtil.HideMenu then
            MenuUtil.HideMenu()
          end
        elseif originalOnClick then
          originalOnClick(btn, mouseButton, ...)
        end
      end)
    end)
  end
end

---------------------------------------------------------------------------
-- Standalone widget factories
--
-- Six widgets, all (parent, opts) -> widget. Designed to be usable both
-- as freestanding controls (toolbars, in-row inputs, monitoring widgets)
-- and as the building blocks of CreateFormLayout below.
--
--   CreateCheckbox       — UICheckButtonTemplate with optional label-on-right
--   CreateNumberInput    — InputBoxTemplate with parse/validate/commit lifecycle
--   CreateTextInput      — InputBoxTemplate for free-form text + select-on-focus
--   CreateIconButton     — square texture button with optional tint + highlight
--   CreateSlider         — slider with stepped values and live value-text
--   CreateSection        — header FontString + horizontal divider line
--
-- Common conventions:
--   * opts.tooltip       attaches AddTooltip
--   * opts.point         passes through to SetPoint(unpack(point))
--   * opts.optionKey     stamped onto the widget as ._optionKey for any
--                        addon's existing Refresh-iterates-widgets pattern
---------------------------------------------------------------------------

local function ApplyPoint(widget, point)
  if point then widget:SetPoint(unpack(point)) end
end

---------------------------------------------------------------------------
-- CreateCheckbox
---------------------------------------------------------------------------
function UI.CreateCheckbox(parent, opts)
  opts = opts or {}
  local size = opts.size or 24

  local cb = CreateFrame("CheckButton", opts.name, parent, "UICheckButtonTemplate")
  cb:SetSize(size, size)
  ApplyPoint(cb, opts.point)

  if opts.label then
    cb.text = cb:CreateFontString(nil, "OVERLAY", opts.labelFont or U.Fonts.DATA)
    cb.text:SetText(opts.label)
    local gap = opts.labelGap or 4
    if opts.labelSide == "left" then
      cb.text:SetPoint("RIGHT", cb, "LEFT", -gap, 0)
    else
      cb.text:SetPoint("LEFT", cb, "RIGHT", gap, 0)
    end
    if opts.labelColor then
      cb.text:SetTextColor(opts.labelColor[1], opts.labelColor[2], opts.labelColor[3])
    end

    -- Mouse-target overlay so the label area triggers the same tooltip
    -- and toggles the checkbox when clicked. FontStrings can't receive
    -- mouse events directly, so we use a transparent Frame sized to the
    -- text. Setting frame strata above cb keeps it from being eaten by
    -- nearby widgets, and EnableMouse routes hover/click here.
    cb.labelHover = CreateFrame("Frame", nil, cb)
    cb.labelHover:SetAllPoints(cb.text)
    cb.labelHover:EnableMouse(true)
    cb.labelHover:SetScript("OnMouseUp", function(_, button)
      if button == "LeftButton" then cb:Click() end
    end)
  end

  if opts.initialValue then cb:SetChecked(true) end

  if opts.onChange then
    cb:SetScript("OnClick", function(self)
      opts.onChange(self:GetChecked() and true or false, self)
    end)
  end

  if opts.tooltip then
    UI.AddTooltip(cb, opts.tooltip, opts.tooltipAnchor or "ANCHOR_RIGHT")
    if cb.labelHover then
      UI.AddTooltip(cb.labelHover, opts.tooltip, opts.tooltipAnchor or "ANCHOR_RIGHT")
    end
  end

  cb._optionKey = opts.optionKey
  return cb
end

---------------------------------------------------------------------------
-- CreateNumberInput
---------------------------------------------------------------------------
local function WireEditBoxCommit(eb, opts)
  -- Last-known-good value used to revert on invalid input or escape.
  -- We don't keep referring to opts.initialValue because validate may
  -- reject it later; we want the most recent successful commit.
  local lastValid = opts.initialValue
  if lastValid ~= nil then eb:SetText(tostring(lastValid)) end

  local function commit(self)
    local text = self:GetText()
    local parsed
    if opts.parse then
      parsed = opts.parse(text)
    elseif opts.numeric ~= false then
      parsed = tonumber(text)
    else
      parsed = text
    end

    local ok = parsed ~= nil
    if ok and opts.validate then ok = opts.validate(parsed) end

    if ok then
      lastValid = parsed
      if opts.format then self:SetText(opts.format(parsed)) end
      if opts.onCommit then opts.onCommit(parsed, self) end
    else
      if lastValid ~= nil then self:SetText(tostring(lastValid)) end
    end
    self:ClearFocus()
  end

  eb:SetScript("OnEnterPressed", commit)
  eb:SetScript("OnEditFocusLost", commit)
  eb:SetScript("OnEscapePressed", function(self)
    if lastValid ~= nil then self:SetText(tostring(lastValid)) end
    self:ClearFocus()
  end)

  -- Allow the form-builder / addon to push a new value programmatically
  -- (e.g. during a Refresh) without re-firing the commit lifecycle.
  eb.SetCommittedValue = function(self, value)
    lastValid = value
    if value == nil then
      self:SetText("")
    elseif opts.format then
      self:SetText(opts.format(value))
    else
      self:SetText(tostring(value))
    end
  end
end

function UI.CreateNumberInput(parent, opts)
  opts = opts or {}
  local eb = CreateFrame("EditBox", opts.name, parent, opts.template or "InputBoxTemplate")
  eb:SetSize(opts.width or 80, opts.height or U.EditBoxHeight.INPUT)
  eb:SetAutoFocus(opts.autoFocus or false)
  if opts.maxLetters then eb:SetMaxLetters(opts.maxLetters) end
  if opts.numeric ~= false then eb:SetNumeric(opts.numericInput or false) end
  ApplyPoint(eb, opts.point)

  WireEditBoxCommit(eb, opts)

  if opts.tooltip then
    UI.AddTooltip(eb, opts.tooltip, opts.tooltipAnchor or "ANCHOR_RIGHT")
  end

  eb._optionKey = opts.optionKey
  return eb
end

---------------------------------------------------------------------------
-- CreateTextInput
---------------------------------------------------------------------------
function UI.CreateTextInput(parent, opts)
  opts = opts or {}
  local eb = CreateFrame("EditBox", opts.name, parent, opts.template or "InputBoxTemplate")
  eb:SetSize(opts.width or 200, opts.height or U.EditBoxHeight.INPUT)
  eb:SetAutoFocus(opts.autoFocus or false)
  if opts.maxLetters then eb:SetMaxLetters(opts.maxLetters) end
  ApplyPoint(eb, opts.point)

  if opts.initialValue then eb:SetText(opts.initialValue) end

  -- Reuse the commit lifecycle but force string mode (numeric=false)
  WireEditBoxCommit(eb, {
    initialValue = opts.initialValue,
    numeric      = false,
    parse        = opts.parse or function(t) return t end,
    validate     = opts.validate,
    format       = opts.format,
    onCommit     = opts.onCommit,
  })

  if opts.onChange then
    eb:HookScript("OnTextChanged", function(self, userInput)
      if userInput then opts.onChange(self:GetText(), self) end
    end)
  end

  if opts.highlightOnFocus then
    eb:HookScript("OnEditFocusGained", function(self) self:HighlightText() end)
    eb:HookScript("OnEditFocusLost",   function(self) self:HighlightText(0, 0) end)
  end

  if opts.tooltip then
    UI.AddTooltip(eb, opts.tooltip, opts.tooltipAnchor or "ANCHOR_RIGHT")
  end

  eb._optionKey = opts.optionKey
  return eb
end

---------------------------------------------------------------------------
-- CreateIconButton
---------------------------------------------------------------------------
function UI.CreateIconButton(parent, opts)
  opts = opts or {}
  local size = opts.size or 22

  local btn = CreateFrame("Button", opts.name, parent)
  btn:SetSize(size, size)
  ApplyPoint(btn, opts.point)

  if opts.texture then
    local tex = btn:CreateTexture(nil, "ARTWORK")
    tex:SetAllPoints()
    tex:SetTexture(opts.texture)
    if opts.texCoord then
      tex:SetTexCoord(opts.texCoord[1], opts.texCoord[2], opts.texCoord[3], opts.texCoord[4])
    end
    if opts.vertexColor then
      tex:SetVertexColor(opts.vertexColor[1], opts.vertexColor[2],
                         opts.vertexColor[3], opts.vertexColor[4])
    end
    btn._tex = tex
  end

  if opts.highlight ~= false then
    local hl = btn:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    local h = opts.highlight or { 1, 1, 1, 0.25 }
    hl:SetColorTexture(h[1], h[2], h[3], h[4] or 0.25)
  end

  if opts.onClick then btn:SetScript("OnClick", opts.onClick) end
  if opts.tooltip then
    UI.AddTooltip(btn, opts.tooltip, opts.tooltipAnchor or "ANCHOR_RIGHT")
  end

  return btn
end

---------------------------------------------------------------------------
-- CreateSlider
---------------------------------------------------------------------------
function UI.CreateSlider(parent, opts)
  opts = opts or {}
  local sl = CreateFrame("Slider", opts.name, parent, opts.template or "MinimalSliderTemplate")
  sl:SetWidth(opts.width or 280)
  if opts.height then sl:SetHeight(opts.height) end
  sl:SetMinMaxValues(opts.min or 0, opts.max or 100)
  sl:SetValueStep(opts.step or 1)
  if sl.SetObeyStepOnDrag and opts.obeyStepOnDrag ~= false then
    sl:SetObeyStepOnDrag(true)
  end
  ApplyPoint(sl, opts.point)

  -- Live value text to the right of the slider (optional).
  if opts.showValue ~= false then
    sl.ValueText = sl:CreateFontString(nil, "OVERLAY", opts.valueFont or U.Fonts.DATA)
    sl.ValueText:SetPoint("LEFT", sl, "RIGHT", opts.valueGap or 8, 0)
    sl.ValueText:SetWidth(opts.valueWidth or 60)
    sl.ValueText:SetJustifyH("LEFT")
  end

  -- Round to step when reporting back, but display via opts.format if given.
  local step = opts.step or 1
  local function snap(v)
    if step <= 0 then return v end
    return math.floor(v / step + 0.5) * step
  end
  local function displayValue(v)
    if opts.format then return opts.format(v) end
    return ("%g"):format(v)
  end

  sl:SetScript("OnValueChanged", function(self, raw, userInput)
    local v = snap(raw)
    if sl.ValueText then sl.ValueText:SetText(displayValue(v)) end
    if userInput and opts.onChange then opts.onChange(v, self) end
  end)

  if opts.initialValue ~= nil then sl:SetValue(opts.initialValue) end

  if opts.tooltip then
    UI.AddTooltip(sl, opts.tooltip, opts.tooltipAnchor or "ANCHOR_RIGHT")
  end

  sl._optionKey = opts.optionKey
  return sl
end

---------------------------------------------------------------------------
-- CreateSection — header FontString + thin horizontal divider
---------------------------------------------------------------------------
function UI.CreateSection(parent, opts)
  opts = opts or {}
  local header = parent:CreateFontString(nil, "OVERLAY", opts.font or "GameFontNormal")
  ApplyPoint(header, opts.point)
  if opts.text then header:SetText(opts.text) end

  local divider
  if opts.divider ~= false then
    divider = parent:CreateTexture(nil, "ARTWORK")
    local c = opts.dividerColor or U.Colors.DIVIDER_GRAY
    divider:SetColorTexture(c[1], c[2], c[3], c[4])
    divider:SetHeight(opts.dividerHeight or 1)
    if opts.width then
      divider:SetWidth(opts.width)
      divider:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, opts.dividerOffset or -2)
    else
      -- Stretch divider to parent's left/right padding when no explicit width.
      local pad = opts.dividerPadding or 0
      divider:SetPoint("TOPLEFT",  parent, "TOPLEFT",  pad, opts.dividerY or 0)
      divider:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -pad, opts.dividerY or 0)
    end
  end

  return header, divider
end
