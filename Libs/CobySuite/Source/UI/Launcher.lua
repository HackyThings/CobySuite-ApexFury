---------------------------------------------------------------------------
-- CobySuite.UI.CreateLauncher: the ways into an addon from outside its own
-- windows, all routed to the same actions and the same branded tooltip:
--
--   * a minimap button (the tracking-border ring with the addon's icon),
--     dragged around the minimap with its angle saved to the addon's table;
--   * a LibDataBroker launcher, when LibDataBroker-1.1 is loaded;
--   * handlers for the addon compartment, which the TOC's global
--     AddonCompartmentFunc / FuncOnEnter / FuncOnLeave functions call.
--
--   local launcher = CobySuite.UI.CreateLauncher({
--     name    = "MyAddon",                    -- LDB object name; the button is <name>MinimapButton unless buttonName is given
--     buttonName = "MyAddonMinimapButton",    -- optional global name for the minimap button
--     label   = "My Addon",                   -- LDB label (default name)
--     icon    = "Interface\\Icons\\INV_Misc_Book_09",
--     tooltip = { brandColor = "00CFD0", title = "My Addon", body = ..., keys = ... },
--                                             -- PopulateBrandedTooltip opts, or a function returning them
--     onLeftClick  = function(button) end,    -- also a compartment click with no button name
--     onRightClick = function(button) end,
--     persist = { svTable = function() return MY_ADDON_WINDOW_STATE end,   -- or the table
--                 key = "minimapAngle", defaultAngle = 220 },               -- degrees
--     isShown = function() return Config.Get("showMinimapButton") ~= false end,  -- default: always
--     minimapButton = true,                   -- false: no minimap button
--     broker        = true,                   -- false: no LibDataBroker object
--     radius        = 80,                     -- button centre from the minimap centre; default: just
--                                             -- outside the minimap's edge, whatever its size
--     buttonTooltipAnchor      = "ANCHOR_LEFT",
--     compartmentTooltipAnchor = "ANCHOR_RIGHT",
--   })
--
--   launcher:Initialize()          -- at PLAYER_LOGIN or later; safe to call again
--   launcher:RefreshShown()        -- re-reads isShown (after a settings change)
--   launcher:SetAngle(degrees)     -- moves the button and saves the angle
--   launcher:OnCompartmentClick(buttonName)
--   launcher:OnCompartmentEnter(menuItem)
--   launcher:OnCompartmentLeave()
--   launcher.Button                -- the minimap button, once initialised
--   launcher.DataObject            -- the LDB object, when registered
--
-- The TOC globals stay in the addon (their names are the addon's), each a
-- one-line call:
--   function MyAddon_OnAddonCompartmentClick(_, button) launcher:OnCompartmentClick(button) end
--   function MyAddon_OnAddonCompartmentEnter(_, menuItem) launcher:OnCompartmentEnter(menuItem) end
--   function MyAddon_OnAddonCompartmentLeave() launcher:OnCompartmentLeave() end
--
-- Nothing is created until Initialize, so building the launcher at file
-- load is free; Initialize is expected outside combat, like any frame
-- creation in the suite.
--
-- Every addon's launcher tooltip has one shape: the title with
-- the addon's icon, a status line when the addon has one, and one line for
-- each click. CobySuite.UI.LauncherTooltip builds it as tooltip opts:
--
--   tooltip = function()
--     return CobySuite.UI.LauncherTooltip({
--       title = "Coby's My Addon", brandColor = "00CFD0", icon = MyAddon.ICON,
--       status = MyAddon.StatusLine(),       -- optional: a string or a list, or nil for none
--       leftClick = "Open My Addon",         -- what a click does
--       rightClick = "Open settings",        -- optional; with none the key reads "Click"
--     })
--   end,
---------------------------------------------------------------------------
local UI = CobySuite_ApexFury.UI

function UI.LauncherTooltip(opts)
  local title = opts.title or ""
  if opts.icon then title = "|T" .. tostring(opts.icon) .. ":16:16:0:0:64:64:5:59:5:59|t " .. title end
  local status = opts.status
  if type(status) == "string" then status = status ~= "" and { status } or nil end
  local keys = {}
  if opts.leftClick then
    keys[#keys + 1] = { key = opts.rightClick and "Left-click" or "Click", desc = opts.leftClick }
  end
  if opts.rightClick then keys[#keys + 1] = { key = "Right-click", desc = opts.rightClick } end
  return { brandColor = opts.brandColor, title = title, body = status, keys = keys }
end

local BUTTON_SIZE = 32
-- The button's centre sits this far outside the minimap's edge (on the
-- classic 140-pixel minimap that is the old fixed 80). The radius is read
-- from the minimap each time, since the current minimap is larger and Edit
-- Mode can resize it; a fixed 80 put the button inside the map (a curator's
-- report, 2026-09-28)
local EDGE_OFFSET = 10
local FALLBACK_RADIUS = 80
local DEFAULT_ANGLE = 220
local BORDER_TEXTURE = "Interface\\Minimap\\MiniMap-TrackingBorder"
local HIGHLIGHT_TEXTURE = "Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight"

local LauncherMixin = {}

local function ResolveSV(persist)
  local sv = persist and persist.svTable
  if type(sv) == "function" then sv = sv() end
  return type(sv) == "table" and sv or nil
end

local IsFiniteNumber = CobySuite_ApexFury.Utilities.IsFiniteNumber

-- The branded tooltip opts for one showing, with an owner when given; a
-- copy, so the consumer's table never gains an owner
function LauncherMixin:TooltipOpts(owner, anchor)
  local source = self._opts.tooltip
  if type(source) == "function" then source = source() end
  local opts = {}
  if type(source) == "table" then
    for k, v in pairs(source) do opts[k] = v end
  end
  opts.owner = owner
  opts.anchor = anchor
  return opts
end

function LauncherMixin:Click(button)
  local opts = self._opts
  if button == "RightButton" then
    if opts.onRightClick then opts.onRightClick(button) end
  elseif button == "LeftButton" or button == nil then
    if opts.onLeftClick then opts.onLeftClick(button) end
  end
end

---------------------------------------------------------------------------
-- Minimap button
---------------------------------------------------------------------------
function LauncherMixin:GetAngle()
  local persist = self._opts.persist
  local sv = ResolveSV(persist)
  local saved = sv and sv[persist.key or "minimapAngle"]
  if IsFiniteNumber(saved) then return saved end
  local default = persist and persist.defaultAngle
  return IsFiniteNumber(default) and default or DEFAULT_ANGLE
end

function LauncherMixin:PositionButton(angle)
  local button = self.Button
  if not button then return end
  local radius = self._opts.radius
  if not radius then
    local ok, width = pcall(Minimap.GetWidth, Minimap)
    radius = (ok and IsFiniteNumber(width) and width > 0) and (width / 2 + EDGE_OFFSET) or FALLBACK_RADIUS
  end
  local rads = math.rad(angle)
  button:ClearAllPoints()
  button:SetPoint("CENTER", Minimap, "CENTER", math.cos(rads) * radius, math.sin(rads) * radius)
end

function LauncherMixin:SetAngle(angle)
  if not IsFiniteNumber(angle) then return end
  self:PositionButton(angle)
  local persist = self._opts.persist
  local sv = ResolveSV(persist)
  if sv then sv[persist.key or "minimapAngle"] = angle end
end

local function AngleFromCursor()
  local cx, cy = GetCursorPosition()
  local scale = Minimap:GetEffectiveScale()
  local mx, my = Minimap:GetCenter()
  return math.deg(math.atan2(cy - my * scale, cx - mx * scale))
end

function LauncherMixin:CreateButton()
  if self.Button then return self.Button end
  local launcher = self
  local opts = self._opts

  local btn = CreateFrame("Button", opts.buttonName or (opts.name .. "MinimapButton"), Minimap)
  btn:SetSize(BUTTON_SIZE, BUTTON_SIZE)
  btn:SetFrameStrata("MEDIUM")
  btn:SetFrameLevel(8)
  btn:SetClampedToScreen(true)

  local border = btn:CreateTexture(nil, "OVERLAY")
  border:SetSize(53, 53)
  border:SetTexture(BORDER_TEXTURE)
  border:SetPoint("TOPLEFT")

  local icon = btn:CreateTexture(nil, "BACKGROUND")
  icon:SetSize(20, 20)
  icon:SetTexture(opts.icon)
  icon:SetPoint("CENTER", -1, 1)
  btn.Icon = icon

  local highlight = btn:CreateTexture(nil, "HIGHLIGHT")
  highlight:SetSize(24, 24)
  highlight:SetTexture(HIGHLIGHT_TEXTURE)
  highlight:SetBlendMode("ADD")
  highlight:SetPoint("CENTER")

  btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  btn:SetScript("OnClick", function(_, button) launcher:Click(button) end)

  -- a dynamic tooltip whose builder fills only the tooltip it is handed, so
  -- the Verify tooltip grid can fill its own copy (opts.tooltip only reads)
  UI.AddDynamicTooltip(btn, function(tip) UI.PopulateBrandedTooltip(tip, launcher:TooltipOpts()) end,
    { anchor = opts.buttonTooltipAnchor or "ANCHOR_LEFT", fillable = true })

  -- Drag around the minimap; the angle is saved as it moves
  btn:RegisterForDrag("LeftButton")
  btn:SetScript("OnDragStart", function(frame)
    frame:SetScript("OnUpdate", function() launcher:SetAngle(AngleFromCursor()) end)
  end)
  btn:SetScript("OnDragStop", function(frame)
    frame:SetScript("OnUpdate", nil)
    launcher:SetAngle(AngleFromCursor())
  end)

  self.Button = btn
  return btn
end

function LauncherMixin:RefreshShown()
  if not self.Button then return end
  local isShown = self._opts.isShown
  self.Button:SetShown(isShown == nil or isShown() ~= false)
end

---------------------------------------------------------------------------
-- LibDataBroker
---------------------------------------------------------------------------
function LauncherMixin:RegisterBroker()
  if self.DataObject then return self.DataObject end
  local LDB = LibStub and LibStub("LibDataBroker-1.1", true)
  if not LDB then return nil end
  local launcher = self
  local opts = self._opts
  self.DataObject = LDB:NewDataObject(opts.name, {
    type = "launcher",
    label = opts.label or opts.name,
    icon = opts.icon,
    OnClick = function(_, button) launcher:Click(button) end,
    OnTooltipShow = function(tooltip)
      UI.PopulateBrandedTooltip(tooltip, launcher:TooltipOpts())
    end,
  })
  return self.DataObject
end

---------------------------------------------------------------------------
-- Lifecycle and the addon compartment
---------------------------------------------------------------------------
function LauncherMixin:Initialize()
  local opts = self._opts
  if opts.minimapButton ~= false then
    self:CreateButton()
    self:PositionButton(self:GetAngle())
    self:RefreshShown()
    -- Edit Mode can resize the minimap: the button follows its edge (a
    -- post-hook, which leaves the minimap's own script untouched)
    if not self._sizeHooked and not opts.radius then
      self._sizeHooked = pcall(Minimap.HookScript, Minimap, "OnSizeChanged", function()
        self:PositionButton(self:GetAngle())
      end)
    end
  end
  if opts.broker ~= false then
    self:RegisterBroker()
  end
end

function LauncherMixin:OnCompartmentClick(button)
  self:Click(button)
end

function LauncherMixin:OnCompartmentEnter(menuItem)
  local anchor = self._opts.compartmentTooltipAnchor or "ANCHOR_RIGHT"
  UI.PopulateBrandedTooltip(GameTooltip, self:TooltipOpts(menuItem, anchor))
end

function LauncherMixin:OnCompartmentLeave()
  GameTooltip:Hide()
end

function UI.CreateLauncher(opts)
  assert(opts and opts.name, "CreateLauncher needs opts.name")
  return Mixin({ _opts = opts }, LauncherMixin)
end
