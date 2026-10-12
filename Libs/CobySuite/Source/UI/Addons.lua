---------------------------------------------------------------------------
-- CobySuite.UI.ToggleAddonsWindow / AddonsGuideSection: "/<cmd> addons",
-- the same list in every addon of every addon Cobanyte has released
--
-- One guide-style section per addon (UI.AddonCatalog, generated): its icon,
-- name and a line saying whether the player has it; open, its description,
-- its CurseForge link in a copy field (addons can't open a browser or write
-- the clipboard) and thumbnails of its CurseForge pictures (a small copy of
-- each, made for the tile: the full image drawn that small would alias). A thumbnail
-- shows the picture large inside the same window: the picture drawn in whole
-- screen pixels (fit to the window, or at Actual size with drag and wheel to
-- pan), its caption, a strip of the addon's other pictures to pick from with
-- arrows either side, and Back. The window is resizable in both views. Only
-- the open section holds its pictures, and the window lets go of all of them
-- when it closes.
--
--   local addons = { host = "Recollect", slash = "/recollect", icon = Recollect.ICON,
--                    message = function(text) Recollect.Message(text) end,
--                    state = function() return RECOLLECT_WINDOW_STATE end }  -- optional: the host's
--                    -- window-state SavedVariable; the list's place and size are kept in it under
--                    -- "addonsWindow" (opts.stateKey), so it opens where it was left
--   CobySuite.UI.ToggleAddonsWindow(addons)      -- the slash command (StandardCommands' addons)
--   sections[#sections + 1] = CobySuite.UI.AddonsGuideSection(addons)   -- the guide's last section
--
-- Nothing opens on its own: the window is built the first time it is asked
-- for, out of combat (asked for in combat, it opens when combat ends). Each
-- host addon gets its own window, <host>AddonsWindow.
---------------------------------------------------------------------------
local addonName = ...
local UI = CobySuite_ApexFury.UI
local U = CobySuite_ApexFury.Utilities

local THUMB_W, THUMB_H, THUMB_GAP = 128, 88, 8
local LINK_WIDTH = 330   -- at first; the field then fills the section's width
local VIEW_PAD = 12
local VIEW_BUTTON_W = 90
local BUTTON_H = U.ButtonSize.MEDIUM.height
local STRIP_BOX_W, STRIP_BOX_H, STRIP_GAP = 96, 66, 6   -- the large view's strip: one thumbnail's box, and the gap
local ARROW_W, ARROW_H = 26, 42   -- the strip's arrow buttons
local PAN_STEP = 80   -- units a wheel notch pans at Actual size
local windows = {}   -- host -> window
local actualSize = false   -- the large view's Actual size choice, kept for the session

-- Test seam (the offline tests and Verify's installed-on-and-off shots):
-- what counts as installed, defaulting to the client's own answer. Standing,
-- StatusText and SummaryText are shown here so a test can read them without a window.
local Seams = {}
UI.AddonsSeams = Seams
function Seams.IsLoaded(folder) return C_AddOns.IsAddOnLoaded(folder) end

-- Where the pictures are: the library's own folder in development, the
-- copy embedded in the host addon in a release (Build.lua names it)
local function MediaRoot()
  local info = CobySuite_ApexFury.BuildInfo
  if info and info.embedded and info.media then return info.media end
  return "Interface\\AddOns\\" .. addonName .. "\\Media\\"
end

-- Shows one catalog picture (the image itself, or its image.thumb, both
-- described the same way), cropped off its power-of-two canvas. Trilinear
-- filtering (Blizzard's own map tiles use it) smooths a picture drawn much
-- smaller than it is.
local function SetPicture(tex, entry, image)
  tex:SetTexture(MediaRoot() .. "Showcase\\" .. entry.folder .. "\\" .. image.file, nil, nil, "TRILINEAR")
  tex:SetTexCoord(0, image.w / image.cw, 0, image.h / image.ch)
end

-- w x h scaled to fit inside maxW x maxH, never larger than it is
local function Fit(w, h, maxW, maxH)
  local s = math.min(1, maxW / w, maxH / h)
  return math.max(1, w * s), math.max(1, h * s)
end

-- One screen pixel in the frame's units: Blizzard's pixel factor (PixelUtil,
-- 768 over the physical screen height) over the frame's effective scale. A
-- picture sized in these is drawn one source pixel to one screen pixel, which a
-- size in plain units is not once the UI scale isn't 1.
local function PixelUnit(frame)
  local factor = PixelUtil and PixelUtil.GetPixelToUIUnitFactor and PixelUtil.GetPixelToUIUnitFactor()
  if not factor and GetPhysicalScreenSize then
    local _, physicalHeight = GetPhysicalScreenSize()
    if type(physicalHeight) == "number" and physicalHeight > 0 then factor = 768 / physicalHeight end
  end
  local scale = frame:GetEffectiveScale()
  if type(factor) == "number" and type(scale) == "number" and scale > 0 then return factor / scale end
  return 1
end

local function SnapToPixel(value, unit) return math.floor(value / unit) * unit end

-- w x h pixels in whole screen pixels, in units: at its own size (actual), or
-- shrunk to fit inside maxW x maxH units, never above 1 source pixel per screen pixel
local function PictureSize(w, h, maxW, maxH, unit, actual)
  local scale = actual and 1 or math.min(1, maxW / unit / w, maxH / unit / h)
  return math.max(1, math.floor(w * scale + 0.5)) * unit, math.max(1, math.floor(h * scale + 0.5)) * unit
end

-- "host" for the addon showing the list, "installed" for another one the
-- player has loaded, else nil
local function Standing(entry, host)
  if entry.folder == host then return "host" end
  if Seams.IsLoaded(entry.folder) then return "installed" end
  return nil
end

---------------------------------------------------------------------------
-- A picture's thumbnail in a frame: a 1 screen pixel border around the
-- picture itself (not its box), light enough to show a dark window against the
-- dark background; gold while the mouse is over it, the selection color and
-- 2 pixels thick while it is the one shown large. The list's tiles and the
-- large view's strip are both made of these.
---------------------------------------------------------------------------
local function CreateFramedThumb(parent, boxW, boxH, pad)
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(boxW, boxH)
  b.Edge = b:CreateTexture(nil, "BACKGROUND")
  b.Picture = b:CreateTexture(nil, "ARTWORK")
  b.Picture:SetPoint("CENTER")

  function b:Paint()
    local c = U.Colors.LABEL_GRAY
    if self.hover then c = U.Colors.STATUS_GOLD elseif self.selected then c = U.Colors.INFO_BLUE end
    local grow = PixelUnit(self) * (self.selected and 2 or 1)
    self.Edge:ClearAllPoints()
    self.Edge:SetPoint("TOPLEFT", self.Picture, "TOPLEFT", -grow, grow)
    self.Edge:SetPoint("BOTTOMRIGHT", self.Picture, "BOTTOMRIGHT", grow, -grow)
    self.Edge:SetColorTexture(c[1], c[2], c[3], 1)
  end

  -- the thumbnail holds twice the pixels of its box, so it is drawn by its
  -- own size halved, which also fits the box (less the room for the frame)
  function b:Load(entry, image)
    self.Picture:SetSize(Fit(image.thumb.w / 2, image.thumb.h / 2, boxW - pad, boxH - pad))
    SetPicture(self.Picture, entry, image.thumb)
    self.loaded = true
    self:Paint()
  end

  function b:Release()
    if self.loaded then
      self.Picture:SetTexture(nil)
      self.loaded = nil
    end
  end

  function b:SetSelected(selected)
    self.selected = selected and true or nil
    self:Paint()
  end

  -- The tooltip and the hover frame share one pair of scripts (AddTooltip
  -- sets them, so the frame's change is wrapped around what it set)
  function b:SetTip(text)
    UI.AddTooltip(self, text, "ANCHOR_TOP")
    local enter, leave = self:GetScript("OnEnter"), self:GetScript("OnLeave")
    self:SetScript("OnEnter", function(frame) frame.hover = true frame:Paint() enter(frame) end)
    self:SetScript("OnLeave", function(frame) frame.hover = nil frame:Paint() leave(frame) end)
  end
  return b
end

---------------------------------------------------------------------------
-- The large view: covers the list until Back (or a click on the picture)
---------------------------------------------------------------------------
local ViewerMixin = {}

-- The picture in whole screen pixels in the pane: fit to it (never above 1
-- source pixel per screen pixel) or, at Actual size, 1:1 and as large as it is,
-- when the pane scrolls (drag, or the wheel). center puts a bigger picture's
-- middle in view, else the current position is kept inside the new range.
function ViewerMixin:Relayout(center)
  local image = self.entry and self.entry.images[self.index]
  if not image then return end
  local pane = self.Pane
  local paneW, paneH = pane:GetWidth(), pane:GetHeight()
  if not (paneW and paneH and paneW > 1 and paneH > 1) then return end
  local unit = PixelUnit(self)
  local w, h = PictureSize(image.w, image.h, paneW, paneH, unit, actualSize)
  local childW, childH = math.max(paneW, w), math.max(paneH, h)
  self.Picture:SetSize(w, h)
  self.PaneChild:SetSize(childW, childH)
  self.Picture:ClearAllPoints()
  self.Picture:SetPoint("TOPLEFT", self.PaneChild, "TOPLEFT",
    SnapToPixel((childW - w) / 2, unit), -SnapToPixel((childH - h) / 2, unit))
  self.Edge:ClearAllPoints()
  self.Edge:SetPoint("TOPLEFT", self.Picture, "TOPLEFT", -unit, unit)
  self.Edge:SetPoint("BOTTOMRIGHT", self.Picture, "BOTTOMRIGHT", unit, -unit)
  if center then
    self:PanTo((childW - paneW) / 2, (childH - paneH) / 2)
  else
    self:PanTo(pane:GetHorizontalScroll(), pane:GetVerticalScroll())
  end
end

-- Actual size on or off, kept for the session; the checkbox follows (a test
-- or Verify scene sets it this way)
function ViewerMixin:SetActualSize(on)
  actualSize = on and true or false
  self.Actual:SetChecked(actualSize)
  self:Relayout(true)
end

function ViewerMixin:GetActualSize() return actualSize end

-- Scrolls the pane to x, y units from the picture's top-left, inside the picture
function ViewerMixin:PanTo(x, y)
  local pane, child = self.Pane, self.PaneChild
  local maxX = math.max(0, child:GetWidth() - pane:GetWidth())
  local maxY = math.max(0, child:GetHeight() - pane:GetHeight())
  local unit = PixelUnit(self)
  pane:SetHorizontalScroll(SnapToPixel(math.min(math.max(x, 0), maxX), unit))
  pane:SetVerticalScroll(SnapToPixel(math.min(math.max(y, 0), maxY), unit))
end

-- Whether the picture is bigger than the pane, so there is something to pan
function ViewerMixin:CanPan()
  return self.PaneChild:GetWidth() > self.Pane:GetWidth() + 0.5
    or self.PaneChild:GetHeight() > self.Pane:GetHeight() + 0.5
end

-- The strip's thumbnails for this addon's pictures, made the first time and
-- when the addon changes; the one shown large is marked and kept in view
function ViewerMixin:LoadStrip()
  local entry = self.entry
  if self.stripEntry ~= entry then
    self:ReleaseStrip()
    for i, image in ipairs(entry.images) do
      local b = self.Thumbs[i]
      if not b then
        b = CreateFramedThumb(self.StripChild, STRIP_BOX_W, STRIP_BOX_H, 6)
        b:SetScript("OnClick", function()
          PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
          self:Open(self.entry, i)
        end)
        self.Thumbs[i] = b
      end
      b:SetTip(image.caption or "")
      b:Load(entry, image)
      b:Show()
    end
    for i = #entry.images + 1, #self.Thumbs do self.Thumbs[i]:Hide() end
    self.stripEntry = entry   -- set once the thumbnails exist, which LayoutStrip waits for
  end
  for i, b in ipairs(self.Thumbs) do b:SetSelected(i == self.index) end
  self:LayoutStrip()
end

function ViewerMixin:LayoutStrip()
  local entry = self.entry
  -- the strip's size handler can run as the view shows, before LoadStrip has
  -- made this addon's thumbnails (it lays them out itself when it has)
  if not entry or self.stripEntry ~= entry then return end
  local clipW = self.Strip:GetWidth()
  if not (clipW and clipW > 1) then return end
  local count = #entry.images
  local stride = STRIP_BOX_W + STRIP_GAP
  local contentW = count * stride - STRIP_GAP
  local childW = math.max(contentW, clipW)
  local first = (childW - contentW) / 2
  self.StripChild:SetSize(childW, STRIP_BOX_H)
  for i = 1, count do
    self.Thumbs[i]:ClearAllPoints()
    self.Thumbs[i]:SetPoint("LEFT", self.StripChild, "LEFT", first + (i - 1) * stride, 0)
  end
  -- the selected one in the middle of the strip when the strip scrolls
  local target = first + (self.index - 1) * stride - (clipW - STRIP_BOX_W) / 2
  self.Strip:SetHorizontalScroll(math.min(math.max(target, 0), childW - clipW))
end

function ViewerMixin:ReleaseStrip()
  for _, b in ipairs(self.Thumbs) do b:Release() end
  self.stripEntry = nil
end

function ViewerMixin:Open(entry, index)
  local count = #entry.images
  self.entry, self.index = entry, ((index - 1) % count) + 1
  local image = entry.images[self.index]
  SetPicture(self.Picture, entry, image)
  self.Caption:SetText(image.caption or "")
  self.Count:SetText(("%s  %d / %d"):format(entry.title, self.index, count))
  self.Prev:SetShown(count > 1)
  self.Next:SetShown(count > 1)
  self:Show()
  self:LoadStrip()
  self:Relayout(true)
end

function ViewerMixin:Close()
  self:Hide()
  self.drag = nil
  self.Pane:SetScript("OnUpdate", nil)
  self.Picture:SetTexture(nil)
  self:ReleaseStrip()
  self.entry = nil
end

-- Drag the picture to pan it; a plain click (nothing to pan) closes the view
local function WirePan(v)
  local pane = v.Pane
  pane:EnableMouse(true)
  pane:EnableMouseWheel(true)
  pane:SetScript("OnMouseDown", function(_, button)
    if button ~= "LeftButton" or not v.entry then return end
    local cx, cy = GetCursorPosition()
    v.drag = { cx = cx, cy = cy, x = pane:GetHorizontalScroll(), y = pane:GetVerticalScroll() }
    pane:SetScript("OnUpdate", function()
      local d = v.drag
      if not d then return end
      local nx, ny = GetCursorPosition()
      local scale = pane:GetEffectiveScale()
      if not (nx and ny and scale and scale > 0) then return end
      local dx, dy = (nx - d.cx) / scale, (ny - d.cy) / scale
      if math.abs(dx) + math.abs(dy) > 3 then d.moved = true end
      if d.moved then v:PanTo(d.x - dx, d.y + dy) end
    end)
  end)
  pane:SetScript("OnMouseUp", function(_, button)
    if button ~= "LeftButton" then return end
    local d = v.drag
    v.drag = nil
    pane:SetScript("OnUpdate", nil)
    if d and not d.moved and not v:CanPan() then v:Close() end
  end)
  pane:SetScript("OnMouseWheel", function(_, delta)
    if not v.entry then return end
    local x, y = pane:GetHorizontalScroll(), pane:GetVerticalScroll()
    local sideways = IsShiftKeyDown() or pane:GetHeight() >= v.PaneChild:GetHeight()
    if sideways then v:PanTo(x - delta * PAN_STEP, y) else v:PanTo(x, y - delta * PAN_STEP) end
  end)
end

local function BuildStrip(v)
  -- the strip fills the row between the two arrows (each about the shape of its atlas)
  local side = VIEW_PAD + ARROW_W + U.Spacing.BUTTON_GAP
  local rowY = VIEW_PAD + BUTTON_H + U.Spacing.GROUP_GAP
  v.Strip = CreateFrame("ScrollFrame", nil, v)
  v.Strip:SetPoint("BOTTOMLEFT", side, rowY)
  v.Strip:SetPoint("BOTTOMRIGHT", -side, rowY)
  local arrow = function(atlas, tip, point, step)
    return UI.CreateIconButton(v, { atlas = atlas, atlasInset = 2, width = ARROW_W, height = ARROW_H, point = point,
      highlightAtlas = atlas, highlightAlpha = 0.5, tooltip = tip,
      onClick = function() v:Open(v.entry, v.index + step) end })
  end
  v.Prev = arrow("common-icon-backarrow", "Previous picture", { "RIGHT", v.Strip, "LEFT", -U.Spacing.BUTTON_GAP, 0 }, -1)
  v.Next = arrow("common-icon-forwardarrow", "Next picture", { "LEFT", v.Strip, "RIGHT", U.Spacing.BUTTON_GAP, 0 }, 1)
  v.Strip:SetHeight(STRIP_BOX_H)
  v.StripChild = CreateFrame("Frame", nil, v.Strip)
  v.StripChild:SetSize(1, STRIP_BOX_H)
  v.Strip:SetScrollChild(v.StripChild)
  v.Strip:EnableMouseWheel(true)
  v.Strip:SetScript("OnMouseWheel", function(strip, delta)
    local range = math.max(0, v.StripChild:GetWidth() - strip:GetWidth())
    strip:SetHorizontalScroll(math.min(math.max(strip:GetHorizontalScroll() - delta * (STRIP_BOX_W + STRIP_GAP), 0), range))
  end)
  v.Strip:SetScript("OnSizeChanged", function() v:LayoutStrip() end)
  v.Thumbs = {}
end

local function BuildViewer(window)
  local v = Mixin(CreateFrame("Button", nil, window), ViewerMixin)
  v:SetPoint("TOPLEFT", 6, -24)
  v:SetPoint("BOTTOMRIGHT", -6, 6)
  v:SetFrameLevel(window:GetFrameLevel() + 50)
  local bg = v:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  local c = U.Colors.WINDOW_BG
  bg:SetColorTexture(c[1], c[2], c[3], 1)

  -- bottom up: the buttons row, the strip of pictures, the caption, then the
  -- pane the picture is drawn in takes the rest
  local gap = U.Spacing.GROUP_GAP
  v.Caption = v:CreateFontString(nil, "OVERLAY", U.Fonts.BODY)
  local captionY = VIEW_PAD + BUTTON_H + gap + STRIP_BOX_H + gap
  v.Caption:SetPoint("BOTTOMLEFT", VIEW_PAD, captionY)
  v.Caption:SetPoint("BOTTOMRIGHT", -VIEW_PAD, captionY)
  v.Caption:SetJustifyH("CENTER")
  v.Caption:SetSpacing(2)

  v.Pane = CreateFrame("ScrollFrame", nil, v)
  v.Pane:SetPoint("TOPLEFT", VIEW_PAD, -VIEW_PAD)
  v.Pane:SetPoint("BOTTOMRIGHT", v.Caption, "TOPRIGHT", 0, gap)
  v.PaneChild = CreateFrame("Frame", nil, v.Pane)
  v.PaneChild:SetSize(1, 1)
  v.Pane:SetScrollChild(v.PaneChild)
  v.Edge = v.PaneChild:CreateTexture(nil, "BACKGROUND")
  local edge = U.Colors.LABEL_GRAY
  v.Edge:SetColorTexture(edge[1], edge[2], edge[3], 1)
  v.Picture = v.PaneChild:CreateTexture(nil, "ARTWORK")
  v.Pane:SetScript("OnSizeChanged", function() v:Relayout() end)
  WirePan(v)

  BuildStrip(v)

  v.Back = UI.CreateButton(v, { text = "Back", size = { VIEW_BUTTON_W, BUTTON_H }, point = { "BOTTOMLEFT", VIEW_PAD, VIEW_PAD },
                                onClick = function() v:Close() end })
  v.Actual = UI.CreateCheckbox(v, { label = "Actual size", labelSide = "left", labelFont = U.Fonts.SMALL,
    point = { "BOTTOMRIGHT", -VIEW_PAD, VIEW_PAD - 2 }, initialValue = actualSize,
    tooltip = "Show the picture at its real size, one of its pixels to one pixel of your screen. "
      .. "Drag it or use the mouse wheel to look around (Shift scrolls sideways).",
    onChange = function(checked) v:SetActualSize(checked) end })
  v.Count = v:CreateFontString(nil, "OVERLAY", U.Fonts.SMALL)
  v.Count:SetWordWrap(false)
  v.Count:SetPoint("LEFT", v.Back, "RIGHT", 10, 0)
  v.Count:SetPoint("RIGHT", v.Actual.text, "LEFT", -10, 0)

  v:SetScript("OnShow", function(self) self.Actual:SetChecked(actualSize) end)
  v:Hide()
  return v
end

---------------------------------------------------------------------------
-- One addon's section: what it does, where to get it, its pictures
---------------------------------------------------------------------------
local function Green(text) return U.WrapColor(U.Colors.SUCCESS_GREEN, text) end

local function StatusText(entry, host)
  local standing = Standing(entry, host)
  if standing == "host" then
    return Green("You're using this one.") .. " Its pictures are below."
  elseif standing == "installed" then
    return Green("Installed.") .. " Type " .. UI.GuideText.Key(entry.slash) .. " to open it."
  end
  return "Free on CurseForge. Copy the link and paste it into your browser:"
end

local SUMMARY = { host = "You're using this one", installed = "Installed" }

local function SummaryText(entry, host)
  local standing = Standing(entry, host)
  return standing and Green(SUMMARY[standing]) or "On CurseForge"
end

Seams.Standing, Seams.StatusText, Seams.SummaryText = Standing, StatusText, SummaryText

local function CardContent(window, entry, host)
  local content = {}

  function content.build(body)
    local f = CreateFrame("Frame", nil, body)
    f.Status = f:CreateFontString(nil, "OVERLAY", U.Fonts.BODY)
    f.Status:SetPoint("TOPLEFT")
    f.Status:SetJustifyH("LEFT")
    f.Link = UI.CreateCopyField(f, { width = LINK_WIDTH, tooltip = "Select the link so Ctrl+C copies it" })
    f.Link:SetValue(entry.url)
    f.Thumbs = {}
    for i, image in ipairs(entry.images) do
      local b = CreateFramedThumb(f, THUMB_W, THUMB_H, 4)
      b:SetTip((image.caption or "") .. "\n" .. UI.GuideText.Note("Click to see it bigger."))
      b:SetScript("OnClick", function()
        PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
        window.OpenPicture(entry, i)
      end)
      f.Thumbs[i] = b
    end
    return f
  end

  function content.layout(f, width)
    f.Status:SetWidth(width)
    f.Status:SetText(StatusText(entry, host))
    local y = f.Status:GetStringHeight() + 6
    f.Link:ClearAllPoints()
    -- the edit box template's left edge art sits outside the frame
    f.Link:SetPoint("TOPLEFT", f, "TOPLEFT", 6, -y)
    -- the whole width (less the copy icon), so a long link isn't cut off
    f.Link:SetWidth(width - 36)
    y = y + f.Link:GetHeight() + 10
    local columns = math.max(1, math.floor((width + THUMB_GAP) / (THUMB_W + THUMB_GAP)))
    local total = #f.Thumbs
    for i, b in ipairs(f.Thumbs) do
      local col, row = (i - 1) % columns, math.floor((i - 1) / columns)
      -- each row centers on its own, so a short last row sits in the middle
      local inRow = math.min(columns, total - row * columns)
      local rowW = inRow * THUMB_W + (inRow - 1) * THUMB_GAP
      local left = math.max(0, (width - rowW) / 2)
      b:ClearAllPoints()
      b:SetPoint("TOPLEFT", f, "TOPLEFT", left + col * (THUMB_W + THUMB_GAP), -(y + row * (THUMB_H + THUMB_GAP)))
      if not b.loaded then b:Load(entry, entry.images[i]) end
    end
    local rows = math.ceil(#f.Thumbs / columns)
    if rows > 0 then y = y + rows * (THUMB_H + THUMB_GAP) - THUMB_GAP end
    return y
  end

  function content.release(f)
    for _, b in ipairs(f.Thumbs) do b:Release() end
  end

  return content
end

local function Sections(window, host)
  local sections = {}
  for _, entry in ipairs(UI.AddonCatalog or {}) do
    sections[#sections + 1] = {
      key = entry.folder, title = entry.title, icon = entry.icon, summary = SummaryText(entry, host),
      body = entry.blurb,
      content = CardContent(window, entry, host),
    }
  end
  return sections
end

local function Build(opts)
  local host = opts.host or "?"
  local window = {}
  local sections = Sections(window, host)
  local first
  for _, s in ipairs(sections) do
    if s.key ~= host then first = s.key break end
  end
  local guide = UI.CreateGuideWindow({
    name = host .. "AddonsWindow",
    title = "Cobanyte's addons",
    icon = opts.icon,
    -- Cobanyte's default (2026-10-06): half the width and two thirds the
    -- height of his 1920 x 1080 screen at his UI scale (one unit is one pixel
    -- there), fixed, never computed per player
    width = 960, height = 720,
    -- remembered between sessions in the host addon's own window state
    -- (Cobanyte, 2026-10-06: "the size should be remembered between sessions
    -- too"); the default is where a reset puts it back
    persist = opts.state and {
      svTable = opts.state, key = opts.stateKey or "addonsWindow",
      defaults = { point = "CENTER", relPoint = "CENTER", x = 0, y = 40 },
    } or nil,
    -- room to grow to the screen (the window keeps itself inside it), so a
    -- large picture can be drawn at its real size
    resizable = { minWidth = 480, minHeight = 460, maxWidth = 4000, maxHeight = 3000 },
    intro = "Every addon here is free. Copy a link into your browser to get one, "
      .. "or click a picture to see it bigger.",
    footer = opts.slash and ("Open this list any time with " .. UI.GuideText.Key(opts.slash .. " addons")) or nil,
    singleOpen = true,
    expanded = { first or (sections[1] and sections[1].key) },
    sections = sections,
  })
  -- Repaints every section's summary and the open sections' status line
  -- after what counts as installed changed (the seam above)
  function guide:RefreshStanding()
    for _, s in ipairs(self.sections) do
      for _, entry in ipairs(UI.AddonCatalog or {}) do
        if entry.folder == s.key then
          s.def.summary = SummaryText(entry, host)
          if s.summary then s.summary:SetText(s.def.summary) end
        end
      end
    end
    if self.Relayout then self:Relayout() end
  end
  -- The large view is built the first time a picture is opened (out of
  -- combat: a click in combat opens it when combat ends)
  function window.OpenPicture(entry, index)
    U.RunOutOfCombat(function()
      if not guide.Viewer then
        guide.Viewer = BuildViewer(guide)
        window.Viewer = guide.Viewer
        -- the large view covers the window, so the resize grip is raised above it
        if guide.ResizeGrip then guide.ResizeGrip:SetFrameLevel(guide.Viewer:GetFrameLevel() + 20) end
      end
      guide.Viewer:Open(entry, index)
    end, "addons-picture:" .. host)
  end
  guide.OpenPicture = window.OpenPicture
  guide:HookScript("OnHide", function()
    if guide.Viewer then guide.Viewer:Close() end
  end)
  return guide
end

-- Opens or closes the host addon's list; asked for in combat before it was
-- ever built, it opens once combat ends
function UI.ToggleAddonsWindow(opts)
  opts = opts or {}
  local host = opts.host or "?"
  local w = windows[host]
  if w then
    w:Toggle()
    return
  end
  if InCombatLockdown() and opts.message then
    opts.message("The addon list opens when combat ends.")
  end
  U.RunOutOfCombat(function()
    if windows[host] then return end
    windows[host] = Build(opts)
    windows[host]:Toggle()
  end, "addons:" .. host)
end

-- The guide's last section: what the list is and how to open it
function UI.AddonsGuideSection(opts)
  local T = UI.GuideText
  local slash = (opts.slash or "/?") .. " addons"
  return {
    key = "addons", title = "Want to check out my other addons?",
    icon = "Interface\\Icons\\INV_Misc_Gift_02",
    summary = "Every addon I've made, with pictures and links",
    body = {
      T.Bullets({
        "Type " .. T.Key(slash) .. " for a list of every addon I've released, what each one does and pictures of it.",
        "Each one has its CurseForge link, ready to copy into your browser.",
        "Addons you already have are marked " .. Green("Installed")
          .. ", with the command that opens them.",
      }),
      T.Note("The list only opens when you ask for it."),
    },
    try = { { slash, "Open the list of addons" } },
    buttons = { { text = "Show My Addons", width = 140, onClick = function() UI.ToggleAddonsWindow(opts) end } },
  }
end
