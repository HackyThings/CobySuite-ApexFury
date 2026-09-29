---------------------------------------------------------------------------
-- CobySuite Shared UI Factories: tooltips, buttons, toolbars, dropdowns,
-- dialogs, clear buttons, hover highlights, copy fields, checkbox menus
---------------------------------------------------------------------------
local UI = CobySuite_ApexFury.UI
local U = CobySuite_ApexFury.Utilities

-- opts.point, a SetPoint argument list, for every factory that takes one
local function ApplyPoint(widget, point)
  if point then widget:SetPoint(unpack(point)) end
end

---------------------------------------------------------------------------
-- Tooltip helpers
--
-- Five flavors attach OnEnter/OnLeave scripts to `frame`, and
-- PopulateBrandedTooltip fills a tooltip it is handed:
--
--   AddTooltip(frame, text, anchor)
--     Plain wrapped text.
--
--   AddItemTooltip(frame, itemIDOrFunc, anchor, opts)
--     Blizzard item tooltip. itemIDOrFunc can be a number or a function
--     that returns one (called per-hover, useful for reusable rows).
--     opts.compareOnShift = true → calls GameTooltip_ShowCompareItem
--                                   while Shift is held (checked here;
--                                    Blizzard's function does not check it).
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
--   PopulateBrandedTooltip(tooltip, opts)
--     Fills a tooltip it is handed (it attaches no scripts) for "addon
--     entry" surfaces (minimap button, addon compartment menu, splash).
--     Provides a consistent look across CobySuite addons:
--       opts.brandColor  hex "FF8800" or {r,g,b} → title color
--       opts.title       string
--       opts.subtitle    string (smaller, gray)
--       opts.body        { "line", ... } or function returning that
--       opts.keys        { { key=, desc= }, ... } → keybind hints
--                         (gold key, gray colon, white desc)
--       opts.owner       a frame; given, it calls
--                         tooltip:SetOwner(opts.owner, opts.anchor) first
--       opts.anchor      "ANCHOR_RIGHT" (default), used with opts.owner
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

-- opts.compareOnShift (boolean or function(frame)) adds the equipped-item
-- comparison while Shift is held and the option is on. The shared
-- GameTooltip_ShowCompareItem does not check Shift itself, so it is checked
-- here, and the tooltip is rebuilt when Shift goes down or up while the
-- frame is hovered. opts.cleanShopping hides the comparison tooltips on
-- leave. Blizzard's own always-compare setting is untouched either way.
-- itemIDOrFunc may also give an item link (a string), for a specific variant.
function UI.AddItemTooltip(frame, itemIDOrFunc, anchor, opts)
  opts = opts or {}

  local function ShowFor(self)
    local item = ResolveID(itemIDOrFunc, self)
    if not item then return end
    GameTooltip:SetOwner(self, anchor or "ANCHOR_RIGHT")
    if type(item) == "string" then
      GameTooltip:SetHyperlink(item)
    else
      GameTooltip:SetItemByID(item)
    end
    local compare = opts.compareOnShift
    if type(compare) == "function" then compare = compare(self) end
    if compare and IsShiftKeyDown() and GameTooltip_ShowCompareItem then
      GameTooltip_ShowCompareItem(GameTooltip)
    end
    GameTooltip:Show()
  end

  local function HideComparison()
    if ShoppingTooltip1 then ShoppingTooltip1:Hide() end
    if ShoppingTooltip2 then ShoppingTooltip2:Hide() end
  end

  frame:SetScript("OnEnter", function(self)
    ShowFor(self)
    if opts.compareOnShift then
      self:RegisterEvent("MODIFIER_STATE_CHANGED")
    end
  end)
  frame:SetScript("OnLeave", function(self)
    if opts.compareOnShift then
      self:UnregisterEvent("MODIFIER_STATE_CHANGED")
    end
    GameTooltip:Hide()
    if opts.cleanShopping then HideComparison() end
  end)

  if opts.compareOnShift then
    frame:HookScript("OnEvent", function(self, event, key)
      if event ~= "MODIFIER_STATE_CHANGED" then return end
      if key ~= "LSHIFT" and key ~= "RSHIFT" then return end
      if not GameTooltip:IsOwned(self) then return end
      HideComparison()
      ShowFor(self)
    end)
  end
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
-- opts.owner (a frame) makes it call tooltip:SetOwner(opts.owner,
-- opts.anchor or "ANCHOR_RIGHT") first, for a caller that gets a frame but
-- no owned tooltip (the compartment's OnEnter hands over its menu button).
function UI.PopulateBrandedTooltip(tooltip, opts)
  opts = opts or {}
  if opts.owner then
    tooltip:SetOwner(opts.owner, opts.anchor or "ANCHOR_RIGHT")
  end

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
        string.format("|cFFFFD100%s|r|cFF888888:|r %s",
          kb.key or "", kb.desc or ""),
        1, 1, 1, true)
    end
  end

  tooltip:Show()
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

  return toolbar, btnRefs
end

---------------------------------------------------------------------------
-- CreateDropDown
--
-- A label over a WowStyle1DropdownTemplate dropdown with radio entries.
-- Without opts: a 200 by 40 frame, the label at its top-left (empty until
-- f.Label:SetText) and a 180 by 26 dropdown 14px below it.
--
--   local dd = CobySuite.UI.CreateDropDown(parent, {
--     label  = "Quality",           -- text; false hides the label and puts the dropdown at the top-left
--     width  = 140, height = 26,    -- of the dropdown (default 180 by 26); the frame follows
--     point  = { "TOPLEFT", 12, -40 },
--     labels = { ... }, values = { ... }, tooltips = { ... },   -- runs InitAgain
--     value  = "any",               -- initial selection (SetValue; onValueChanged is not called)
--     onValueChanged = function(value) end,   -- a user's pick
--     defaultText = "Choose...",     -- shown while nothing is selected
--   })
--   dd:InitAgain(labels, values, tooltips)   dd:SetValue(v)   dd:GetValue()
--   dd.Label   dd.DropDown   dd.onValueChanged
---------------------------------------------------------------------------
function UI.CreateDropDown(parent, opts)
  opts = opts or {}
  local ddWidth = opts.width or 180
  local ddHeight = opts.height or 26
  local showLabel = opts.label ~= false

  local f = CreateFrame("Frame", nil, parent)
  f.Label = f:CreateFontString(nil, "OVERLAY", U.Fonts.BODY)
  f.Label:SetPoint("TOPLEFT", 0, 0)
  f.DropDown = CreateFrame("DropdownButton", nil, f, "WowStyle1DropdownTemplate")
  f.DropDown:SetSize(ddWidth, ddHeight)
  if showLabel then
    f:SetSize(math.max(200, ddWidth), 14 + ddHeight)
    f.DropDown:SetPoint("TOPLEFT", 0, -14)
    if type(opts.label) == "string" then f.Label:SetText(opts.label) end
  else
    f:SetSize(ddWidth, ddHeight)
    f.DropDown:SetPoint("TOPLEFT", 0, 0)
    f.Label:Hide()
  end
  ApplyPoint(f, opts.point)
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

  if opts.defaultText then f.DropDown:SetDefaultText(opts.defaultText) end
  if opts.labels and opts.values then
    f:InitAgain(opts.labels, opts.values, opts.tooltips)
  end
  if opts.value ~= nil then f:SetValue(opts.value) end
  if opts.onValueChanged then f.onValueChanged = opts.onValueChanged end

  return f
end

---------------------------------------------------------------------------
-- CreateDialogPopup
---------------------------------------------------------------------------
-- opts.name gives the popup a global name and closes it with Escape through
-- UISpecialFrames, which works in combat. Without a name the older OnKeyDown
-- handler is kept for compatibility; it raises ADDON_ACTION_BLOCKED on
-- keystrokes while the popup is open in combat, so name new popups.
-- opts.parent (default UIParent) makes the popup follow that frame's
-- visibility; opts.point (default the parent's CENTER) places it;
-- opts.movable lets the user drag it anywhere on screen.
--
-- The popup is shown when created unless opts.hidden. Optional content and
-- actions, so a caller needs no follow-up wiring:
--   opts.body        text (or a list of paragraphs) in popup.Body, centred
--                    under the title; popup:SetBody(text) sets or replaces it
--   opts.confirmText the confirm label (default "OK")
--   opts.onConfirm   function(popup): the confirm click hides the popup, then
--                    calls it (without it, wire popup.ConfirmButton yourself)
--   opts.cancelText  the cancel label (default "Cancel")
--   opts.hideCancel  no cancel button; the confirm button is centred
--   opts.danger      the title in U.Colors.WARNING_RED, for destructive actions
local BODY_INSET = 24
local BODY_TOP = -50          -- below a title at -16
local BODY_TOP_UNTITLED = -24

function UI.CreateDialogPopup(opts)
  local popup = CreateFrame("Frame", opts.name, opts.parent or UIParent, "BackdropTemplate")
  popup:SetSize(opts.width or 320, opts.height or 120)
  if opts.point then
    popup:SetPoint(unpack(opts.point))
  else
    popup:SetPoint("CENTER")
  end
  popup:SetFrameStrata("DIALOG")
  popup:SetBackdrop(U.Backdrops.DIALOG)
  local dbg = U.Colors.DIALOG_BG
  popup:SetBackdropColor(dbg[1], dbg[2], dbg[3], dbg[4])
  popup:EnableMouse(true)
  popup:SetToplevel(true)

  if opts.movable then
    popup:SetMovable(true)
    popup:SetClampedToScreen(true)
    popup:RegisterForDrag("LeftButton")
    popup:SetScript("OnDragStart", popup.StartMoving)
    popup:SetScript("OnDragStop", popup.StopMovingOrSizing)
  end

  if opts.title then
    popup.Title = popup:CreateFontString(nil, "OVERLAY", U.Fonts.TITLE)
    popup.Title:SetPoint("TOP", 0, -16)
    popup.Title:SetText(opts.title)
    if opts.danger then
      local wr = U.Colors.WARNING_RED
      popup.Title:SetTextColor(wr[1], wr[2], wr[3])
    end
  end

  -- The body FontString is made on first use, so a popup without a body
  -- has no extra region
  function popup:SetBody(text)
    if type(text) == "table" then text = table.concat(text, "\n\n") end
    if not self.Body then
      local top = self.Title and BODY_TOP or BODY_TOP_UNTITLED
      self.Body = self:CreateFontString(nil, "OVERLAY", U.Fonts.BODY)
      self.Body:SetPoint("TOPLEFT", BODY_INSET, top)
      self.Body:SetPoint("TOPRIGHT", -BODY_INSET, top)
      self.Body:SetJustifyH("CENTER")
    end
    self.Body:SetText(text or "")
  end
  if opts.body ~= nil then popup:SetBody(opts.body) end

  popup.ConfirmButton = CreateFrame("Button", nil, popup, "UIPanelButtonTemplate")
  popup.ConfirmButton:SetSize(100, 24)
  popup.ConfirmButton:SetText(opts.confirmText or "OK")
  if opts.hideCancel then
    popup.ConfirmButton:SetPoint("BOTTOM", popup, "BOTTOM", 0, 12)
  else
    popup.ConfirmButton:SetPoint("BOTTOMRIGHT", popup, "BOTTOM", -4, 12)
  end
  if opts.onConfirm then
    popup.ConfirmButton:SetScript("OnClick", function()
      popup:Hide()
      opts.onConfirm(popup)
    end)
  end

  popup.CancelButton = CreateFrame("Button", nil, popup, "UIPanelButtonTemplate")
  popup.CancelButton:SetSize(100, 24)
  popup.CancelButton:SetPoint("BOTTOMLEFT", popup, "BOTTOM", 4, 12)
  popup.CancelButton:SetText(opts.cancelText or "Cancel")
  popup.CancelButton:SetScript("OnClick", function() popup:Hide() end)
  if opts.hideCancel then popup.CancelButton:Hide() end

  if opts.name then
    tinsert(UISpecialFrames, opts.name)
  else
    popup:SetScript("OnKeyDown", function(self, key)
      if key == "ESCAPE" then
        self:SetPropagateKeyboardInput(false)
        self:Hide()
      else
        self:SetPropagateKeyboardInput(true)
      end
    end)
  end

  if opts.hidden then popup:Hide() end
  return popup
end

---------------------------------------------------------------------------
-- AddHoverHighlight(frame, color)
--
-- The row hover wash: a HIGHLIGHT-layer texture filling the frame, which
-- the client shows while the mouse is over it (buttons, and any frame with
-- mouse enabled). color is {r, g, b, a}, default U.Colors.HOVER_HIGHLIGHT;
-- a missing alpha is 1. Returns the texture.
---------------------------------------------------------------------------
function UI.AddHoverHighlight(frame, color)
  local c = color or U.Colors.HOVER_HIGHLIGHT
  local tex = frame:CreateTexture(nil, "HIGHLIGHT")
  tex:SetAllPoints()
  tex:SetColorTexture(c[1], c[2], c[3], c[4] or 1)
  return tex
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
-- Writes position and size into svTable[key], keeping any other fields an
-- addon stores in the same sub-table (a visibility flag, for instance).
function UI.SaveWindowState(frame, svTable, key)
  if not frame or not svTable then return end
  local point, _, relativePoint, x, y = frame:GetPoint()
  local state = svTable[key]
  if type(state) ~= "table" then
    state = {}
    svTable[key] = state
  end
  state.point, state.relativePoint, state.x, state.y = point, relativePoint, x, y
  state.width, state.height = frame:GetWidth(), frame:GetHeight()
end

-- Saved geometry is checked field by field, since a SavedVariables file can
-- hold anything: the state must be a table, the anchor points anchor names,
-- x and y finite numbers, width and height finite positive numbers. A field
-- that fails falls back to defaults (point, relPoint, x, y, and optionally
-- width, height), then to CENTER / 0; a size with no usable value is left
-- as it is. Without a saved table the defaults apply; with neither, nothing
-- moves.
local ANCHOR_POINTS = {
  TOPLEFT = true, TOP = true, TOPRIGHT = true,
  LEFT = true, CENTER = true, RIGHT = true,
  BOTTOMLEFT = true, BOTTOM = true, BOTTOMRIGHT = true,
}

local function AnchorOr(value, fallback)
  if type(value) == "string" and ANCHOR_POINTS[value] then return value end
  return fallback
end

local IsFiniteNumber = U.IsFiniteNumber

local function OffsetOr(value, fallback)
  if IsFiniteNumber(value) then return value end
  return fallback
end

local function SizeOr(value, fallback)
  if IsFiniteNumber(value) and value > 0 then return value end
  return fallback
end

function UI.RestoreWindowState(frame, svTable, key, defaults)
  local state = type(svTable) == "table" and svTable[key] or nil
  if type(state) ~= "table" then state = nil end
  if type(defaults) ~= "table" then defaults = nil end
  if not state and not defaults then return end

  local d = defaults or {}
  local s = state or {}
  local point = AnchorOr(s.point, AnchorOr(d.point, "CENTER"))
  local relPoint = AnchorOr(s.relativePoint, AnchorOr(d.relPoint, "CENTER"))
  local x = OffsetOr(s.x, OffsetOr(d.x, 0))
  local y = OffsetOr(s.y, OffsetOr(d.y, 0))
  frame:ClearAllPoints()
  frame:SetPoint(point, UIParent, relPoint, x, y)

  local width = SizeOr(s.width, SizeOr(d.width, nil))
  local height = SizeOr(s.height, SizeOr(d.height, nil))
  if width then frame:SetWidth(width) end
  if height then frame:SetHeight(height) end
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
          -- MenuUtil.HideMenu has never existed in the 11.x/12.x menu system;
          -- the menu manager owns open menus.
          if Menu and Menu.GetManager then
            Menu.GetManager():CloseMenus()
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
-- Seven widgets, all (parent, opts) -> widget. Designed to be usable both
-- as freestanding controls (toolbars, in-row inputs, monitoring widgets)
-- and as the building blocks of CreateFormLayout below.
--
--   CreateCheckbox         UICheckButtonTemplate with optional label-on-right
--   CreateNumberInput      InputBoxTemplate with parse/validate/commit lifecycle
--   CreateTextInput        InputBoxTemplate for free-form text + select-on-focus
--   CreateMultiLineInput   InputScrollFrameTemplate, word-wrapping text with the same commit lifecycle
--   CreateIconButton       square texture button with optional tint + highlight
--   CreateSlider           slider with stepped values and live value-text
--   CreateSection          header FontString + horizontal divider line
--
-- Common conventions:
--   * opts.tooltip       attaches AddTooltip
--   * opts.point         passes through to SetPoint(unpack(point))
--   * opts.optionKey     stamped onto the widget as ._optionKey for any
--                        addon's existing Refresh-iterates-widgets pattern
---------------------------------------------------------------------------

---------------------------------------------------------------------------
-- Enabled-state wiring for labelled toggles (checkbox, radio)
--
-- Blizzard's check button templates only swap art for a checked disabled
-- box, and the label FontString and its mouse overlay are ours, so
-- SetEnabled / Enable / Disable are wrapped to grey the label and to stop
-- the label from clicking through while the widget is disabled.
---------------------------------------------------------------------------
local function ApplyEnabledLook(widget, enabled)
  if widget.text then
    if enabled then
      widget.text:SetTextColor(widget._labelR, widget._labelG, widget._labelB)
    else
      local c = U.Colors.DISABLED_GRAY
      widget.text:SetTextColor(c[1], c[2], c[3])
    end
  end
  if widget.labelHover then
    widget.labelHover:EnableMouse(enabled)
  end
end

local function WireEnabledState(widget)
  if widget.text then
    widget._labelR, widget._labelG, widget._labelB = widget.text:GetTextColor()
  end
  local SetEnabled, Enable, Disable = widget.SetEnabled, widget.Enable, widget.Disable
  widget.SetEnabled = function(self, enabled)
    SetEnabled(self, enabled)
    ApplyEnabledLook(self, enabled)
  end
  widget.Enable = function(self)
    Enable(self)
    ApplyEnabledLook(self, true)
  end
  widget.Disable = function(self)
    Disable(self)
    ApplyEnabledLook(self, false)
  end
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
      if button == "LeftButton" and cb:IsEnabled() then cb:Click() end
    end)
  end
  WireEnabledState(cb)

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
-- CreateRadioButton
--
-- Blizzard's UIRadioButtonTemplate (16px circle) with a label on the right,
-- styled like CreateCheckbox. Clicking a checked radio keeps it checked; the
-- group logic (one of N) lives in FormLayout:RadioGroup or the caller.
-- opts: name, label, labelFont, labelGap, tooltip, initialValue, optionKey,
-- point, onChange(checked, self).
---------------------------------------------------------------------------
function UI.CreateRadioButton(parent, opts)
  opts = opts or {}
  local rb = CreateFrame("CheckButton", opts.name, parent, "UIRadioButtonTemplate")
  ApplyPoint(rb, opts.point)
  if opts.optionKey then rb.optionKey = opts.optionKey end

  if opts.label then
    rb.text:SetFontObject(opts.labelFont or U.Fonts.DATA)
    rb.text:SetText(opts.label)
    rb.text:ClearAllPoints()
    rb.text:SetPoint("LEFT", rb, "RIGHT", opts.labelGap or 4, 0)
    -- The label toggles the radio and shares its tooltip (see CreateCheckbox).
    rb.labelHover = CreateFrame("Frame", nil, rb)
    rb.labelHover:SetAllPoints(rb.text)
    rb.labelHover:EnableMouse(true)
    rb.labelHover:SetScript("OnMouseUp", function(_, button)
      if button == "LeftButton" and rb:IsEnabled() then rb:Click() end
    end)
  end
  WireEnabledState(rb)

  rb:SetChecked(opts.initialValue == true)
  rb:SetScript("OnClick", function(self)
    self:SetChecked(true)   -- a radio never unchecks itself
    if opts.onChange then opts.onChange(true, self) end
  end)

  if opts.tooltip then
    UI.AddTooltip(rb, opts.tooltip, "ANCHOR_RIGHT")
    if rb.labelHover then UI.AddTooltip(rb.labelHover, opts.tooltip, "ANCHOR_RIGHT") end
  end
  return rb
end

---------------------------------------------------------------------------
-- CreateNumberInput
---------------------------------------------------------------------------
-- Commit lifecycle: Enter commits once, and so does clicking away (focus
-- loss); Escape restores the last valid value (or empties the box when there
-- is none) and commits nothing. Enter and Escape both end in ClearFocus,
-- whose focus loss would otherwise run the commit a second time or commit
-- the cancelled text, so each marks the edit settled first and the focus
-- loss of a settled edit does nothing. Gaining focus starts a new edit.
local function WireEditBoxCommit(eb, opts)
  -- Last-known-good value used to revert on invalid input or escape.
  -- We don't keep referring to opts.initialValue because validate may
  -- reject it later; we want the most recent successful commit.
  local lastValid = opts.initialValue
  if lastValid ~= nil then eb:SetText(tostring(lastValid)) end

  local settled = false

  local function Restore(self)
    if lastValid == nil then
      self:SetText("")
    elseif opts.format then
      self:SetText(opts.format(lastValid))
    else
      self:SetText(tostring(lastValid))
    end
  end

  local function Commit(self)
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
      Restore(self)
    end
  end

  eb:HookScript("OnEditFocusGained", function()
    settled = false
  end)
  eb:SetScript("OnEnterPressed", function(self)
    if not settled then
      settled = true
      Commit(self)
    end
    self:ClearFocus()
  end)
  eb:SetScript("OnEditFocusLost", function(self)
    if settled then return end
    settled = true
    Commit(self)
  end)
  eb:SetScript("OnEscapePressed", function(self)
    settled = true
    Restore(self)
    self:ClearFocus()
  end)

  -- Allow the form-builder / addon to push a new value programmatically
  -- (e.g. during a Refresh); it never calls onCommit.
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
-- Two icon sources: opts.texture (a file path, drawn on an ARTWORK texture)
-- or opts.atlas (drawn as the button's own normal texture). With an atlas,
-- opts.pushedAtlas (default: the same atlas) and opts.pushedShade (a grey
-- level applied to it, e.g. 0.75) give the pressed look, and
-- opts.highlightAtlas with opts.highlightBlend (default "ADD") and
-- opts.highlightAlpha replace the flat colour highlight. opts.width /
-- opts.height allow a non-square button (default opts.size, 22).
function UI.CreateIconButton(parent, opts)
  opts = opts or {}
  local size = opts.size or 22

  local btn = CreateFrame("Button", opts.name, parent)
  btn:SetSize(opts.width or size, opts.height or size)
  ApplyPoint(btn, opts.point)

  if opts.atlas then
    btn:SetNormalAtlas(opts.atlas)
    if opts.pushedAtlas or opts.pushedShade then
      btn:SetPushedAtlas(opts.pushedAtlas or opts.atlas)
    end
    -- opts.atlasInset shrinks (positive) or grows (negative) the glyph past
    -- the button's edges, for atlases with built-in padding; opts.vertexColor
    -- tints it (the pushed texture is tinted the same, then shaded).
    local inset = opts.atlasInset or 0
    local color = opts.vertexColor
    for _, tex in ipairs({ btn:GetNormalTexture(), btn:GetPushedTexture() }) do
      if tex then
        if inset ~= 0 then
          tex:ClearAllPoints()
          tex:SetPoint("TOPLEFT", inset, -inset)
          tex:SetPoint("BOTTOMRIGHT", -inset, inset)
        end
        if color then
          tex:SetVertexColor(color[1], color[2], color[3], color[4] or 1)
        end
      end
    end
    if opts.pushedShade then
      local s = opts.pushedShade
      local r, g, b = 1, 1, 1
      if color then r, g, b = color[1], color[2], color[3] end
      btn:GetPushedTexture():SetVertexColor(r * s, g * s, b * s)
    end
  end

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

  if opts.highlightAtlas then
    btn:SetHighlightAtlas(opts.highlightAtlas, opts.highlightBlend or "ADD")
    if opts.highlightAlpha then
      btn:GetHighlightTexture():SetAlpha(opts.highlightAlpha)
    end
  elseif opts.highlight ~= false then
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
-- HideOnClickOutside
--
-- Hides `frame` on a mouse press anywhere outside it (and outside any
-- `opts.owners`, typically the button that opened it), the way Blizzard's
-- menus close. A child listener frame carries the GLOBAL_MOUSE_DOWN
-- registration, so it follows the frame's visibility without touching the
-- frame's own OnShow / OnHide / OnEvent scripts. The owner's own click then
-- runs after the hide, so a toggle button still toggles.
---------------------------------------------------------------------------
function UI.HideOnClickOutside(frame, opts)
  local owners = opts and opts.owners or {}
  local listener = CreateFrame("Frame", nil, frame)
  listener:SetScript("OnShow", function(self) self:RegisterEvent("GLOBAL_MOUSE_DOWN") end)
  listener:SetScript("OnHide", function(self) self:UnregisterEvent("GLOBAL_MOUSE_DOWN") end)
  listener:SetScript("OnEvent", function()
    if frame:IsMouseOver() then return end
    for _, owner in ipairs(owners) do
      if owner:IsMouseOver() then return end
    end
    frame:Hide()
  end)
  if frame:IsVisible() then
    listener:RegisterEvent("GLOBAL_MOUSE_DOWN")
  end
  return listener
end

---------------------------------------------------------------------------
-- CreateSearchBox
--
-- Blizzard's SearchBoxTemplate (magnifier, "Search" placeholder, built-in
-- clear button) wired as a live filter: opts.onSearch(text, box) runs
-- opts.debounce seconds (default 0.2) after the last keystroke, and at once
-- when the box empties (opts.immediateOnEmpty, default true), so an empty
-- box always means "no search". It also runs for programmatic changes
-- (clear button, SetText), which is intended. Escape clears the box;
-- opts.onEscape replaces that. Not built on CreateTextInput on purpose: that
-- one's commit lifecycle makes Escape revert to the last committed value.
--
-- opts: name, width (150), height (U.EditBoxHeight.SEARCH), point,
-- maxLetters, placeholder (SEARCH), debounce, onSearch, onTextChanged(text,
-- userInput), immediateOnEmpty, onEscape, onEnter(box) (replaces the
-- template's Enter, which only clears focus), onKeyDown(box, key) (every key
-- while the box has focus, for list navigation). The box gains
-- :CancelPendingSearch(), :FlushSearch() (runs a pending search now, for an
-- Enter that must act on the current text), :IsSearchPending(),
-- :ClearSearch() and :SetSearchDelay(seconds). Setting OnEnterPressed or
-- OnKeyDown with SetScript after creation still works; it replaces the
-- option's handler.
---------------------------------------------------------------------------
function UI.CreateSearchBox(parent, opts)
  opts = opts or {}
  local box = CreateFrame("EditBox", opts.name, parent, "SearchBoxTemplate")
  box:SetSize(opts.width or 150, opts.height or U.EditBoxHeight.SEARCH)
  ApplyPoint(box, opts.point)
  box:SetAutoFocus(false)
  if opts.maxLetters then box:SetMaxLetters(opts.maxLetters) end
  -- The template reads self.instructionText in OnLoad, which is only set
  -- when the box comes from XML; set the placeholder ourselves.
  box.Instructions:SetText(opts.placeholder or SEARCH or "Search")

  local pending = U.Debounce(opts.debounce or 0.2, function()
    if opts.onSearch then opts.onSearch(box:GetText(), box) end
  end)

  box:SetScript("OnTextChanged", function(self, userInput)
    SearchBoxTemplate_OnTextChanged(self)   -- the template's icon / clear-button state
    local text = self:GetText()
    if opts.onTextChanged then opts.onTextChanged(text, userInput, self) end
    if opts.immediateOnEmpty ~= false and strtrim(text) == "" then
      pending:Cancel()
      if opts.onSearch then opts.onSearch(text, self) end
    else
      pending:Call()
    end
  end)
  box:SetScript("OnEscapePressed", opts.onEscape or function(self)
    SearchBoxTemplate_ClearText(self)
  end)
  -- Without opts.onEnter, OnEnterPressed keeps the template's EditBox_ClearFocus.
  if opts.onEnter then
    box:SetScript("OnEnterPressed", function(self) opts.onEnter(self) end)
  end
  if opts.onKeyDown then
    box:SetScript("OnKeyDown", function(self, key) opts.onKeyDown(self, key) end)
  end

  function box:CancelPendingSearch() pending:Cancel() end
  function box:FlushSearch() pending:Flush() end
  function box:IsSearchPending() return pending:IsPending() end
  function box:ClearSearch() SearchBoxTemplate_ClearText(self) end
  function box:SetSearchDelay(seconds) pending:SetDelay(seconds) end
  return box
end

---------------------------------------------------------------------------
-- CreateCopyField
--
-- A read-only text field with the copy icon at its right: an
-- InputBoxTemplate edit box that shows a value scrolled to its first
-- character. Addons cannot write to the clipboard, so the icon puts the
-- text to copy in the field, focused and fully selected, and Ctrl+C does the
-- rest. The shown text and the copied text may differ (an item link shown
-- with its escape codes doubled, copied raw).
--
--   local field = CobySuite.UI.CreateCopyField(parent, {
--     width = 240,                  -- or anchor both sides (point plus a SetPoint of your own)
--     height = U.EditBoxHeight.INLINE, point = { ... },
--     tooltip = "Select the link so Ctrl+C copies it",   -- on the icon
--     iconSize = 16,
--   })
--   field:SetValue(displayText, rawText)   -- rawText nil: copy displayText; false: nothing to copy
--   field:GetValue()                        -- displayText, rawText
--   field:SelectForCopy()                   -- what the icon does
--   field.CopyButton                        -- with :SetCopyEnabled(enabled)
--
-- Clicking into the field selects what it shows. Losing focus puts the
-- display text back and scrolls to the start; Escape and Enter clear focus.
-- Typing changes nothing but the box and never commits anything. The icon is
-- enabled only while there is something to copy. The icon is a child of the
-- field, so showing or hiding the field covers both.
---------------------------------------------------------------------------
local COPY_ICON_ATLAS = "friends-icon-battlenet-copy"   -- Blizzard's copy glyph (the friends list BattleTag)

-- The cursor to the first character, now and again next frame, since the
-- box scrolls to the end of a SetText only after layout
local function ScrollEditBoxToStart(box)
  if box:HasFocus() then return end
  box:SetCursorPosition(0)
  C_Timer.After(0, function()
    if not box:HasFocus() then box:SetCursorPosition(0) end
  end)
end

function UI.CreateCopyField(parent, opts)
  opts = opts or {}
  local field = CreateFrame("EditBox", opts.name, parent, "InputBoxTemplate")
  field:SetHeight(opts.height or U.EditBoxHeight.INLINE)
  if opts.width then field:SetWidth(opts.width) end
  ApplyPoint(field, opts.point)
  field:SetAutoFocus(false)

  local displayText, rawText = "", false
  local copying = false   -- the field holds the copy text, selected

  local function CopyText()
    if rawText == false then return nil end
    local text = rawText or displayText
    if text == "" then return nil end
    return text
  end

  field.CopyButton = UI.CreateIconButton(field, {
    atlas = COPY_ICON_ATLAS, size = opts.iconSize or 16,
    highlightAtlas = COPY_ICON_ATLAS, highlightAlpha = 0.5,
    point = { "LEFT", field, "RIGHT", 6, 0 },
    tooltip = opts.tooltip,
    onClick = function() field:SelectForCopy() end,
  })
  function field.CopyButton:SetCopyEnabled(enabled)
    self:SetEnabled(enabled)
    self:SetAlpha(enabled and 1 or 0.4)
  end
  field.CopyButton:SetCopyEnabled(false)

  function field:SelectForCopy()
    local text = CopyText()
    if not text then return end
    copying = true
    self:SetText(text)
    self:SetFocus()
    self:HighlightText()
  end

  function field:SetValue(newDisplay, newRaw)
    displayText = newDisplay or ""
    rawText = newRaw
    local copyText = CopyText()
    self.CopyButton:SetCopyEnabled(copyText ~= nil)
    if self:HasFocus() then
      -- Leave an edit in progress alone; keep a copy selection current
      if copying and copyText and self:GetText() ~= copyText then
        self:SetText(copyText)
        self:HighlightText()
      end
    else
      self:SetText(displayText)
      ScrollEditBoxToStart(self)
    end
  end

  function field:GetValue()
    return displayText, rawText
  end

  field:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
  field:SetScript("OnEditFocusLost", function(self)
    copying = false
    self:SetText(displayText)
    self:HighlightText(0, 0)
    ScrollEditBoxToStart(self)
  end)
  field:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  field:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)

  return field
end

---------------------------------------------------------------------------
-- CreateFavoriteStar
--
-- The auction house favorite star (filled when set, the dim empty star
-- otherwise, always visible, as on AH rows). opts.isFavorite() reports the
-- state, opts.onToggle(on) applies a click; the star refreshes itself after
-- the click and on :Refresh(). Width follows the atlas at opts.height
-- (default 16). opts.tooltipOn / opts.tooltipOff override the texts.
---------------------------------------------------------------------------
local STAR_ATLAS_ON = "auctionhouse-icon-favorite"
local STAR_ATLAS_OFF = "auctionhouse-icon-favorite-off"

local function StarSize(height)
  local info = C_Texture.GetAtlasInfo(STAR_ATLAS_ON)
  if info and info.width and info.height and info.height > 0 then
    return height * info.width / info.height, height
  end
  return height, height
end

function UI.CreateFavoriteStar(parent, opts)
  opts = opts or {}
  local star = CreateFrame("Button", opts.name, parent)
  star:SetSize(StarSize(opts.height or 16))
  ApplyPoint(star, opts.point)
  if opts.frameLevel then star:SetFrameLevel(opts.frameLevel) end

  local function IsFavorite()
    return opts.isFavorite ~= nil and opts.isFavorite() == true
  end

  function star:Refresh()
    local favorite = IsFavorite()
    local atlas = favorite and STAR_ATLAS_ON or STAR_ATLAS_OFF
    self:SetNormalAtlas(atlas)
    self:SetHighlightAtlas(atlas, "ADD")
    self:GetHighlightTexture():SetAlpha(favorite and 0.2 or 0.4)   -- as AuctionHouseFavoriteButtonBaseMixin
  end

  local function ShowTooltip(self)
    GameTooltip:SetOwner(self, opts.tooltipAnchor or "ANCHOR_RIGHT")
    GameTooltip:SetText(IsFavorite() and (opts.tooltipOn or "Remove from favorites")
      or (opts.tooltipOff or "Add to favorites"))
    GameTooltip:Show()
  end

  star:SetScript("OnClick", function(self)
    local on = not IsFavorite()
    if opts.onToggle then opts.onToggle(on) end
    PlaySound(on and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF)
    self:Refresh()
    ShowTooltip(self)
  end)
  star:SetScript("OnEnter", ShowTooltip)
  star:SetScript("OnLeave", GameTooltip_Hide)
  star:Refresh()
  return star
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
-- CreateSection: header FontString + thin horizontal divider
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

---------------------------------------------------------------------------
-- CreateMultiLineInput
--
-- Blizzard's InputScrollFrameTemplate (a bordered, word-wrapping edit box
-- with a scrollbar that appears when the text overflows and a small grey
-- "used/max" counter) wired with the same parse / validate / commit lifecycle
-- as CreateTextInput: Enter and losing focus commit, Escape reverts to the
-- last committed value. Newlines are folded into spaces before commit
-- unless opts.keepNewlines is set, since a whisper or a chat line has no
-- use for them.
--
--   local box = CobySuite.UI.CreateMultiLineInput(parent, {
--     width = 400, height = 60, point = { ... },
--     maxLetters = 255, placeholder = "Type a message", fontScale = 1.1,
--     maxBytes = 255,                       -- optional; a byte limit (eb:SetMaxBytes), and the counter
--                                           --   counts bytes (#text), so an accented letter counts two
--     showCharCount = true,                 -- default true when maxLetters or maxBytes is set; charCountFont overrides the font
--     initialValue = ..., validate = function(text) return text ~= "" end,
--     onCommit = function(text, editBox) end, onChange = function(text, editBox) end,
--     tooltip = "...", optionKey = "MESSAGE",
--   })
--   box.EditBox            box:GetText()            box:SetCommittedValue(v)
---------------------------------------------------------------------------
function UI.CreateMultiLineInput(parent, opts)
  opts = opts or {}
  local width = opts.width or 300
  local height = opts.height or 60

  local frame = CreateFrame("ScrollFrame", opts.name, parent, "InputScrollFrameTemplate")
  frame:SetSize(width, height)
  ApplyPoint(frame, opts.point)

  local eb = frame.EditBox
  eb:SetWidth(width - 18)   -- the template's OnLoad ran at width 0
  eb:SetMaxLetters(opts.maxLetters or 0)
  if opts.maxBytes then eb:SetMaxBytes(opts.maxBytes) end
  eb.Instructions:SetText(opts.placeholder or "")
  eb.Instructions:SetWidth(width - 18)

  -- opts.fontScale enlarges (or shrinks) the template's text, placeholder
  -- included; the counter keeps its own font.
  if opts.fontScale and opts.fontScale ~= 1 then
    for _, region in ipairs({ eb, eb.Instructions }) do
      local font, size, flags = region:GetFont()
      if font and size then region:SetFont(font, size * opts.fontScale, flags) end
    end
  end

  -- Counter: "used/max" in a small grey font (the template shows only the
  -- letters remaining, in its large font). Blizzard's OnTextChanged writes
  -- the remaining count first; the hook overwrites it. With maxBytes it
  -- counts bytes against that limit, otherwise letters against maxLetters.
  local maxBytes = opts.maxBytes or 0
  local maxLetters = opts.maxLetters or 0
  local limit = maxBytes > 0 and maxBytes or maxLetters
  local showCount = opts.showCharCount ~= false and limit > 0
  frame.CharCount:SetShown(showCount)
  if showCount then
    frame.CharCount:SetFontObject(opts.charCountFont or "GameFontDisableSmall")
    local function UpdateCount()
      local used = maxBytes > 0 and #eb:GetText() or eb:GetNumLetters()
      frame.CharCount:SetText(("%d/%d"):format(used, limit))
    end
    eb:HookScript("OnTextChanged", UpdateCount)
    frame.UpdateCharCount = UpdateCount
  end

  local function fold(text)
    if opts.keepNewlines then return text end
    return strtrim((text:gsub("%s*\n%s*", " ")))
  end

  WireEditBoxCommit(eb, {
    initialValue = opts.initialValue,
    numeric      = false,
    parse        = function(text) return fold(opts.parse and opts.parse(text) or text) end,
    validate     = opts.validate,
    format       = opts.format,
    onCommit     = opts.onCommit,
  })

  if opts.onChange then
    eb:HookScript("OnTextChanged", function(self, userInput)
      if userInput then opts.onChange(self:GetText(), self) end
    end)
  end

  if opts.tooltip then
    UI.AddTooltip(frame, opts.tooltip, opts.tooltipAnchor or "ANCHOR_RIGHT")
  end

  function frame:GetText() return eb:GetText() end
  function frame:SetCommittedValue(value) eb:SetCommittedValue(value) end
  function frame:SetFocus() eb:SetFocus() end

  frame._optionKey = opts.optionKey
  return frame
end

---------------------------------------------------------------------------
-- CreateMetricList(parent, metrics, opts): live label and value rows
--
-- One row per metric { label, getValue, tooltip }, each anchored across
-- parent, shaded every other row: the label in gray, the value (getValue()'s
-- text) beside it. Returns { rows, Refresh }: Refresh() reads every getter
-- again under pcall, and one that errors shows opts.errorText. When and how
-- often to refresh (a throttle, memory sampling) is the caller's.
--
--   opts.rowHeight   default 18
--   opts.labelWidth  default 140
--   opts.valueWidth  a fixed width; without it the value runs to the row's
--                    right edge
--   opts.padding     left and right inset, default 10
--   opts.top         the first row's offset from parent's top, default 0
--   opts.errorText   default "error" in U.Colors.TEXT_RED
---------------------------------------------------------------------------
function UI.CreateMetricList(parent, metrics, opts)
  opts = opts or {}
  local rowHeight, labelWidth = opts.rowHeight or 18, opts.labelWidth or 140
  local padding, top = opts.padding or 10, opts.top or 0
  local errorText = opts.errorText or U.WrapColor(U.Colors.TEXT_RED, "error")
  local list = { rows = {} }

  for i, metric in ipairs(metrics) do
    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(rowHeight)
    row:SetPoint("TOPLEFT", padding, -((i - 1) * rowHeight) - top)
    row:SetPoint("TOPRIGHT", -padding, -((i - 1) * rowHeight) - top)
    U.AddAlternatingRowBg(row, i)

    local label = row:CreateFontString(nil, "OVERLAY", U.Fonts.SMALL)
    label:SetPoint("LEFT", 0, 0)
    label:SetWidth(labelWidth)
    label:SetJustifyH("LEFT")
    label:SetText(metric.label)
    local lg = U.Colors.LABEL_GRAY
    label:SetTextColor(lg[1], lg[2], lg[3])

    local value = row:CreateFontString(nil, "OVERLAY", U.Fonts.DATA)
    value:SetPoint("LEFT", label, "RIGHT", 4, 0)
    if opts.valueWidth then
      value:SetWidth(opts.valueWidth)
    else
      value:SetPoint("RIGHT", -4, 0)
    end
    value:SetJustifyH("LEFT")
    value:SetText("--")

    row.Label = label
    row.Value = value
    if metric.tooltip then
      row:EnableMouse(true)
      UI.AddTooltip(row, metric.tooltip)
    end
    list.rows[i] = row
  end

  function list.Refresh()
    for i, metric in ipairs(metrics) do
      local row = list.rows[i]
      if row then
        local ok, val = pcall(metric.getValue)
        row.Value:SetText(ok and val or errorText)
      end
    end
  end
  return list
end
