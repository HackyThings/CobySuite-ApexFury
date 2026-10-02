---------------------------------------------------------------------------
-- CobySuite.UI.CreateWindow: the standard window shell
--
-- Every addon window in the suite is a BasicFrameTemplateWithInset frame
-- with the same trimmings: a solid dark background behind the inset art,
-- drag to move, an optional resize grip, a saved position (and size), an
-- Escape key that closes it, and a close button that also works in combat.
-- This builds that shell once so windows only add their content.
--
--   local f = CobySuite.UI.CreateWindow({
--     name          = "MyAddonOptionsWindow",  -- global name; needed for escapeCloses
--     title         = "My Addon Settings",     -- TitleText
--     parent        = UIParent,                -- default UIParent
--     template      = "BasicFrameTemplateWithInset",  -- default BasicFrameTemplateWithInset
--     icon          = "Interface\\Icons\\INV_Misc_Book_09",  -- optional, 16px left of the title
--     width = 400, height = 190,
--     strata        = "MEDIUM",                -- default MEDIUM: the layer of Blizzard's own
--                                              -- panels, so a click brings either forward;
--                                              -- only a dialog that asks something passes
--                                              -- "DIALOG" (Cobanyte, 2026-09-28)
--     toplevel      = true,                    -- default true
--     clampToScreen = true,                    -- default true
--     movable       = true,                    -- default true
--     resizable     = { minWidth = 600, minHeight = 400, maxWidth = 1200, maxHeight = 800 },  -- optional
--     solidBackground = true,                  -- default true (U.Colors.WINDOW_BG)
--     backgroundColor = { r, g, b, a },        -- default U.Colors.WINDOW_BG
--     escapeCloses  = true,                    -- UISpecialFrames insert; default false
--     closeButtonInCombat = true,              -- close button calls Hide(); default true
--     persist = {                              -- optional saved position / size
--       svTable   = MY_ADDON_WINDOW_STATE,     -- table, or function returning it
--       key       = "options",
--       defaults  = { point = "CENTER", relPoint = "CENTER", x = 0, y = 0 },
--       fixedSize = true,                      -- ignore a saved size
--     },
--     point = { "CENTER", UIParent, "CENTER", 0, 80 },   -- initial anchor for a window without persist
--     mixin = MyWindowMixin,                   -- optional, applied before anything else
--     onDragStop = function(f) end,            -- optional, after the state is saved
--     onResizeStop = function(f) end,          -- optional, likewise after a resize
--     shown = false,                           -- default false: the window starts hidden
--   })
--   Moving and sizing start on the left button and also end (state saved,
--   callback run) when the window hides mid-drag. A resizable window is
--   brought inside its bounds each time it shows and after RestoreState: a
--   size saved before the bounds grew (by persist, or by the client's own
--   layout cache for a named window the player moved) never hides content.
--   Neither can the screen: a window never fits wider or taller than the
--   screen, and a drag of its corner stops at the screen's edges. A window
--   clamped to the screen and sized past an edge is pushed back by the
--   client while the drag keeps growing it, so it ran away to its largest
--   size with its grip off the screen (the curator console, 2026-09-30).
--   f:SaveState()      f:RestoreState()      f:FitToBounds()      f:Toggle()
--
-- Escape: UISpecialFrames is the standard path (CloseSpecialWindows calls
-- Hide() directly, so it works in combat). The OnKeyDown +
-- SetPropagateKeyboardInput handler is deliberately not offered: it raises
-- ADDON_ACTION_BLOCKED on every keystroke while the window is open in
-- combat (ApexFury, 2026-04). UISpecialFrames itself is still on watch as a
-- possible taint vector, so it stays opt-in.
--
-- Close button: BasicFrameTemplate's default routes through HideUIPanel,
-- which silently no-ops in combat; the override is a plain Hide().
---------------------------------------------------------------------------
local UI = CobySuite_ApexFury.UI
local U = CobySuite_ApexFury.Utilities

local WindowMixin = {}

local function ResolveSV(persist)
  local sv = persist.svTable
  if type(sv) == "function" then sv = sv() end
  return sv
end

function WindowMixin:SaveState()
  local persist = self._persist
  if not persist then return end
  UI.SaveWindowState(self, ResolveSV(persist), persist.key)
end

function WindowMixin:RestoreState()
  local persist = self._persist
  if not persist then return end
  UI.RestoreWindowState(self, ResolveSV(persist), persist.key, persist.defaults)
  if persist.fixedSize then
    self:SetSize(self._width, self._height)
  end
  self:FitToBounds()
end

-- ScreenSize(f): the screen's width and height in f's own units, or nil
-- when they can't be read
local function ScreenSize(f)
  local ok, w, h, parentScale, ownScale = pcall(function()
    return UIParent:GetWidth(), UIParent:GetHeight(), UIParent:GetEffectiveScale(), f:GetEffectiveScale()
  end)
  if not ok or type(w) ~= "number" or type(h) ~= "number" or type(parentScale) ~= "number"
    or type(ownScale) ~= "number" or ownScale <= 0 or w <= 0 or h <= 0 then
    return nil
  end
  return w * parentScale / ownScale, h * parentScale / ownScale
end

-- Brings the size inside the resize bounds and the screen (a resizable
-- window only)
function WindowMixin:FitToBounds()
  local b = self._bounds
  if not b then return end
  local w, h = self:GetSize()
  local fitW = math.min(math.max(w, b.minWidth), b.maxWidth)
  local fitH = math.min(math.max(h, b.minHeight), b.maxHeight)
  local screenW, screenH = ScreenSize(self)
  if screenW then
    fitW, fitH = math.min(fitW, screenW), math.min(fitH, screenH)
  end
  if fitW ~= w or fitH ~= h then
    self:SetSize(fitW, fitH)
  end
end

function WindowMixin:Toggle()
  if self:IsShown() then
    self:Hide()
  else
    self:RestoreState()
    self:Show()
  end
end

function UI.CreateWindow(opts)
  opts = opts or {}
  local f = CreateFrame("Frame", opts.name, opts.parent or UIParent, opts.template or "BasicFrameTemplateWithInset")
  if opts.mixin then Mixin(f, opts.mixin) end
  Mixin(f, WindowMixin)

  f._width = opts.width or 400
  f._height = opts.height or 300
  f._persist = opts.persist
  f:SetSize(f._width, f._height)
  -- Initial anchor: opts.point (a SetPoint argument list) for a window that
  -- does not persist, otherwise the persist defaults, otherwise CENTER.
  if opts.point then
    f:SetPoint(unpack(opts.point))
  else
    local d = opts.persist and opts.persist.defaults or {}
    f:SetPoint(d.point or "CENTER", UIParent, d.relPoint or "CENTER", d.x or 0, d.y or 0)
  end
  -- MEDIUM with Blizzard's panels (the achievement and character windows
  -- are MEDIUM and toplevel): a click raises whichever window it lands on,
  -- and a window coming up is raised over the others (Cobanyte, 2026-09-28:
  -- the item details window, in DIALOG, stayed over the achievement window
  -- it had opened)
  f:SetFrameStrata(opts.strata or "MEDIUM")
  if opts.toplevel ~= false then
    f:SetToplevel(true)
    f:HookScript("OnShow", function(self) self:Raise() end)
  end
  if opts.clampToScreen ~= false then f:SetClampedToScreen(true) end
  f:EnableMouse(true)

  if opts.solidBackground ~= false then
    local solidBg = f:CreateTexture(nil, "BACKGROUND", nil, -8)
    solidBg:SetAllPoints()
    local c = opts.backgroundColor or U.Colors.WINDOW_BG
    solidBg:SetColorTexture(c[1], c[2], c[3], c[4])
  end

  if opts.title and f.TitleText then
    f.TitleText:SetText(opts.title)
  end

  -- The addon's icon just left of the title. TitleText is anchored by its
  -- TOP only, so it is as wide as its text and the icon follows it when the
  -- title changes.
  if opts.icon and f.TitleText then
    local icon = f:CreateTexture(nil, "OVERLAY")
    icon:SetSize(16, 16)
    icon:SetPoint("RIGHT", f.TitleText, "LEFT", -4, 0)
    icon:SetTexture(opts.icon)
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    f.TitleIcon = icon
  end

  -- Moving and sizing start on the left button only (RegisterForDrag covers
  -- the drag) and end the normal way, saving the state, on release or when
  -- the window hides mid-drag (Escape, a close from code), so a drag that
  -- loses its release still stops and saves. A child frame carries the
  -- OnHide, so a window's own OnHide script cannot replace it.
  local function StopMoving(self)
    if not self._moving then return end
    self._moving = false
    self:StopMovingOrSizing()
    self:SaveState()
    if opts.onDragStop then opts.onDragStop(self) end
  end

  local function StopSizing(self)
    if not self._sizing then return end
    self._sizing = false
    if self.ResizeGrip then self.ResizeGrip:SetScript("OnUpdate", nil) end
    self:StopMovingOrSizing()
    -- the drag's screen-edge limits end with it
    local b = self._bounds
    if b then self:SetResizeBounds(b.minWidth, b.minHeight, b.maxWidth, b.maxHeight) end
    self:SaveState()
    if opts.onResizeStop then opts.onResizeStop(self) end
  end

  if opts.movable ~= false then
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self)
      self._moving = true
      self:StartMoving()
    end)
    f:SetScript("OnDragStop", StopMoving)
  end

  if opts.resizable then
    local r = opts.resizable
    f._bounds = {
      minWidth = r.minWidth or 200, minHeight = r.minHeight or 150,
      maxWidth = r.maxWidth or 1600, maxHeight = r.maxHeight or 1000,
    }
    f:SetResizable(true)
    f:SetResizeBounds(f._bounds.minWidth, f._bounds.minHeight, f._bounds.maxWidth, f._bounds.maxHeight)
    f.ResizeGrip = UI.CreateResizeGrip(f)
    f.ResizeGrip:SetScript("OnMouseDown", function(_, button)
      if button ~= "LeftButton" then return end
      -- Anchored by its top-left corner where it stands, so sizing from the
      -- bottom-right moves only that corner: a window anchored at its
      -- center could jump past the cursor when sizing began. Both are in the
      -- window's own units, measured from the screen's bottom-left.
      local left, top = f:GetLeft(), f:GetTop()
      if left and top then
        f:ClearAllPoints()
        f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
        -- the corner stops at the screen's right and bottom edges: past them
        -- the clamp pushes the window back and the drag runs away
        local b = f._bounds
        local maxW, maxH = b.maxWidth, b.maxHeight
        local screenW = ScreenSize(f)
        if screenW then
          maxW = math.max(b.minWidth, math.min(b.maxWidth, screenW - left))
          maxH = math.max(b.minHeight, math.min(b.maxHeight, top))
          f:SetResizeBounds(b.minWidth, b.minHeight, maxW, maxH)
        end
        -- the size follows the cursor's position, not its movement: StartSizing
        -- kept moving the corner after the window stopped at its minimum, so
        -- coming back grew it while the cursor was still inside (Verify q48-33)
        f._sizing = true
        f.ResizeGrip:SetScript("OnUpdate", function()
          local cx, cy = GetCursorPosition()
          local scale = f:GetEffectiveScale()
          if not (cx and cy and scale and scale > 0) then return end
          local w = math.max(b.minWidth, math.min(maxW, cx / scale - left))
          local h = math.max(b.minHeight, math.min(maxH, top - cy / scale))
          f:SetSize(w, h)
        end)
      end
    end)
    f.ResizeGrip:SetScript("OnMouseUp", function(_, button)
      if button ~= "LeftButton" then return end
      StopSizing(f)
    end)
  end

  if opts.movable ~= false or opts.resizable then
    local hideWatcher = CreateFrame("Frame", nil, f)
    hideWatcher:SetScript("OnHide", function()
      StopMoving(f)
      StopSizing(f)
    end)
    -- The child shows with the window, and a window's own OnShow script
    -- cannot replace this one
    hideWatcher:SetScript("OnShow", function()
      f:FitToBounds()
    end)
  end

  if opts.escapeCloses then
    assert(opts.name, "CreateWindow: escapeCloses needs a global name")
    tinsert(UISpecialFrames, opts.name)
  end

  if opts.closeButtonInCombat ~= false and f.CloseButton then
    f.CloseButton:SetScript("OnClick", function() f:Hide() end)
  end

  if not opts.shown then f:Hide() end
  return f
end

---------------------------------------------------------------------------
-- UI.RegisterSettingsCategory: an entry under Options > AddOns
--
-- Suite addons keep their settings in their own window
-- (CreateSettingsWindow). This registers a small canvas page in Blizzard's
-- Options > AddOns list so the addon is found where players look first:
-- the name in the brand colour, the version, a description and a button
-- that hides the options panel (left open while it holds unapplied changes)
-- and opens the addon's window. Returns the
-- Settings category (category:GetID() for Settings.OpenToCategory) and
-- the canvas frame, which is also kept in UI.SettingsPages[name] with its
-- button as canvas.OpenButton, for the taint suites.
--
--   CobySuite.UI.RegisterSettingsCategory({
--     name        = "Public Order Whisper",   -- list entry and page title
--     brandColor  = "00CED1",                  -- optional hex
--     version     = "1.0.0",                   -- optional
--     description = { "para", "para" },        -- string or list of paragraphs
--     buttonText  = "Open Settings",           -- default
--     slash       = "/pow settings",           -- optional hint beside the button
--     onOpen      = function() Config.ToggleSettings() end,
--   })
---------------------------------------------------------------------------
function UI.RegisterSettingsCategory(opts)
  assert(opts and opts.name and opts.onOpen, "RegisterSettingsCategory needs name and onOpen")
  local canvas = CreateFrame("Frame")
  canvas:Hide()   -- the options panel shows and sizes it

  local title = canvas:CreateFontString(nil, "OVERLAY", U.Fonts.TITLE)
  title:SetPoint("TOPLEFT", 16, -16)
  title:SetText(opts.brandColor and U.WrapColor(opts.brandColor, opts.name) or opts.name)
  local last = title

  local gray = U.Colors.LABEL_GRAY
  if opts.version then
    local version = canvas:CreateFontString(nil, "OVERLAY", U.Fonts.DATA)
    version:SetPoint("LEFT", title, "RIGHT", 8, 0)
    version:SetText("v" .. opts.version)
    version:SetTextColor(gray[1], gray[2], gray[3])
  end

  local description = opts.description
  if type(description) == "table" then description = table.concat(description, "\n\n") end
  if description then
    local body = canvas:CreateFontString(nil, "OVERLAY", U.Fonts.BODY)
    body:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -12)
    body:SetPoint("RIGHT", canvas, "RIGHT", -16, 0)
    body:SetJustifyH("LEFT")
    body:SetJustifyV("TOP")
    body:SetSpacing(2)
    body:SetText(description)
    last = body
  end

  local button = UI.CreateButton(canvas, {
    size  = { 140, 24 },
    text  = opts.buttonText or "Open Settings",
    point = { "TOPLEFT", last, "BOTTOMLEFT", 0, -16 },
    onClick = function()
      -- Never SettingsPanel:Close() from addon code: it goes back to the
      -- game menu through ToggleGameMenu, which then runs the Escape chain
      -- with this addon's taint (SpellStopCasting, SpellStopTargeting and
      -- ClearTarget forbidden, 12.1; Recollect 0.0.1c curators' reports,
      -- 2026-09-28), and with Blizzard settings changed but not applied it
      -- shows a StaticPopup. HideUIPanel hides it through the panel
      -- manager's secure delegate; with unapplied changes the panel stays
      -- open under the addon's window.
      if SettingsPanel and SettingsPanel:IsShown() and not SettingsPanel:HasUnappliedSettings() then
        HideUIPanel(SettingsPanel)
      end
      opts.onOpen()
    end,
  })
  canvas.OpenButton = button   -- the taint suites click the real button
  UI.SettingsPages = UI.SettingsPages or {}
  UI.SettingsPages[opts.name] = canvas

  if opts.slash then
    local hint = canvas:CreateFontString(nil, "OVERLAY", U.Fonts.DATA)
    hint:SetPoint("LEFT", button, "RIGHT", 10, 0)
    hint:SetText("or type " .. opts.slash)
    hint:SetTextColor(gray[1], gray[2], gray[3])
  end

  local category = Settings.RegisterCanvasLayoutCategory(canvas, opts.name)
  Settings.RegisterAddOnCategory(category)
  return category, canvas
end
