---------------------------------------------------------------------------
-- CobySuite.UI.CreateGuideWindow / CreateHelpButton: an addon's feature guide
--
-- A guide is a window of sections, one per part of the addon. Each section
-- is a header (icon, title, a one-line summary, and at its right edge the
-- plus and minus buttons of Blizzard's objective tracker, which its housing
-- dashboard also uses for collapsible lists) that opens and closes a body:
-- paragraphs of text, then "Try it" lines in the slash help colours
-- (U.FormatCommandLine). It is not a walkthrough: the player opens whatever
-- they are curious about.
--
--   local guide = CobySuite.UI.CreateGuideWindow({
--     name       = "MyAddonGuideWindow",   -- optional global name; Escape closes a named guide
--     title      = "My Addon Guide",
--     icon       = "Interface\\Icons\\INV_Misc_Book_09",  -- optional, left of the title (CreateWindow)
--     intro      = "A line above the sections.",           -- optional
--     footer     = "Open this guide any time with /ma guide",   -- optional: a strip along the
--                                                        -- bottom that doesn't scroll (color codes welcome)
--     width = 580, height = 620,                           -- the defaults
--     persist    = { svTable = function() return MY_STATE end, key = "guide" },  -- optional
--     singleOpen = false,                  -- true: opening a section closes the others
--     expanded   = { "search" },           -- keys open at first; default the first section
--     sections   = {
--       { key = "search", title = "Searching",
--         icon    = "Interface\\Icons\\INV_Misc_Spyglass_03",   -- a texture path or file ID,
--         atlas   = "common-search-magnifyingglass",            -- or an atlas
--         summary = "One line, shown open or closed",
--         body    = { "A paragraph.", "Another." },             -- a string, a list, or a function
--                                                               -- returning either, read again each
--                                                               -- time the guide shows (text another
--                                                               -- part of the addon supplies later)
--         try     = { { "/ma show", "Open the search window" }, { "Shift-click", "Link it" } },
--         buttons = { { text = "Build Database", width = 140, tooltip = "...",   -- optional, under the
--                       onClick = function(button) end,                         -- text: an action the
--                       enabled = function() return true end,                   -- section talks about;
--                       label = function() return "Building..." end } },        -- enabled and label are
--                                                               -- read again on show and after a click
--       },
--     },
--   })
--   guide:Toggle()                 -- the CreateWindow shell's own
--   guide:OpenSection("search")    -- shows the guide with that section open, scrolled to it
--   guide:SetExpanded("search", true)   guide:IsExpanded("search")   guide:GetContentHeight()
--
-- Everything is built at once, so create a guide out of combat (at load or
-- login); showing and hiding it later is safe in combat. It is a CreateWindow
-- shell in the MEDIUM layer, like every window, that the player can move and
-- resize; the text reflows with the width.
--
--   local help = CobySuite.UI.CreateHelpButton(window, {
--     onClick = function() guide:Toggle() end,
--     tooltip = "My Addon guide",         -- default "Guide"
--     tooltipAnchor = "ANCHOR_TOP",       -- the default
--     name    = "MyAddonHelpButton",      -- optional
--     size    = 24,                       -- the default, to match the close button
--     point   = { "TOPRIGHT", -30, -2 },   -- default: left of window.CloseButton
--   })
--
-- The help button is a gold question mark in the title font, 24 px square by
-- default to match the close button beside it, white under the mouse.
---------------------------------------------------------------------------
local UI = CobySuite_ApexFury.UI
local U = CobySuite_ApexFury.Utilities

local HEADER_HEIGHT = 46
local ICON_SIZE = 32
local PAD = 10                             -- inside a section
local GAP = 4                              -- between sections
local BODY_LEFT = PAD + ICON_SIZE + PAD    -- body text lines up with the title
local INSET_LEFT, INSET_RIGHT = 12, 32     -- the scroll area inside the window (its bar on the right)
local TOP = 30                             -- below the title bar
local BOTTOM = 12                          -- the scroll area's gap above the bottom edge
local FOOTER_HEIGHT = 24                   -- the footer strip (opts.footer)
local FOOTER_RIGHT = 26                    -- leaves the resize grip its corner
-- Self-contained square buttons. The Options list's arrow is the right cap
-- of a three-part bar and has no left border of its own.
local ARROW_CLOSED = "ui-questtrackerbutton-expand-all"
local ARROW_OPEN = "ui-questtrackerbutton-collapse-all"

-- The objective tracker's plus (a closed section) and minus (an open one)
UI.FOLD_ATLAS = { closed = ARROW_CLOSED, open = ARROW_OPEN }

---------------------------------------------------------------------------
-- CreateCollapsibleHeader(parent, opts): a section header as the guide's:
-- a shaded button with an icon, a title, a one-line summary under it, and
-- at its right edge the plus or minus, which brightens with the header
-- under the mouse. The caller sets the texts, the icon (a texture, cropped
-- by the caller, or an atlas) and its OnClick.
--
--   local h = CobySuite.UI.CreateCollapsibleHeader(parent, {
--     height = 46, iconSize = 32, pad = 10,   -- the guide's (the defaults)
--     titleFont = U.Fonts.TITLE,              -- the default
--     titleY = -1, summaryGap = 3,            -- the title's offset from the icon's top; the gap under it
--   })
--   h.Icon, h.Title, h.Summary, h.Arrow, h.ArrowGlow
--   h:SetOpen(open)                          -- the minus when open, else the plus
---------------------------------------------------------------------------
function UI.CreateCollapsibleHeader(parent, opts)
  opts = opts or {}
  local pad = opts.pad or PAD
  local h = CreateFrame("Button", nil, parent)
  h:SetHeight(opts.height or HEADER_HEIGHT)
  local bg = h:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  local c = U.Colors.CONTENT_BG
  bg:SetColorTexture(c[1], c[2], c[3], c[4])
  UI.AddHoverHighlight(h)

  local size = opts.iconSize or ICON_SIZE
  h.Icon = h:CreateTexture(nil, "ARTWORK")
  h.Icon:SetSize(size, size)
  h.Icon:SetPoint("LEFT", pad, 0)

  h.Arrow = h:CreateTexture(nil, "ARTWORK")
  h.Arrow:SetPoint("RIGHT", -pad, 0)
  h.Arrow:SetAtlas(ARROW_CLOSED, true)
  -- Brightens with the header under the mouse, as the housing dashboard's does
  h.ArrowGlow = h:CreateTexture(nil, "HIGHLIGHT")
  h.ArrowGlow:SetAllPoints(h.Arrow)
  h.ArrowGlow:SetBlendMode("ADD")
  h.ArrowGlow:SetAlpha(0.3)
  h.ArrowGlow:SetAtlas(ARROW_CLOSED)

  h.Title = h:CreateFontString(nil, "OVERLAY", opts.titleFont or U.Fonts.TITLE)
  h.Title:SetPoint("TOPLEFT", h.Icon, "TOPRIGHT", pad, opts.titleY or -1)
  h.Title:SetPoint("RIGHT", h.Arrow, "LEFT", -pad, 0)
  h.Title:SetJustifyH("LEFT")
  h.Title:SetWordWrap(false)

  h.Summary = h:CreateFontString(nil, "OVERLAY", U.Fonts.DATA)
  h.Summary:SetPoint("TOPLEFT", h.Title, "BOTTOMLEFT", 0, -(opts.summaryGap or 3))
  h.Summary:SetPoint("RIGHT", h.Arrow, "LEFT", -pad, 0)
  h.Summary:SetJustifyH("LEFT")
  h.Summary:SetWordWrap(false)
  local gray = U.Colors.LABEL_GRAY
  h.Summary:SetTextColor(gray[1], gray[2], gray[3])

  function h:SetOpen(open)
    local atlas = open and ARROW_OPEN or ARROW_CLOSED
    self.Arrow:SetAtlas(atlas, true)
    self.ArrowGlow:SetAtlas(atlas)
  end
  return h
end

---------------------------------------------------------------------------
-- CreateHelpButton
---------------------------------------------------------------------------
function UI.CreateHelpButton(parent, opts)
  opts = opts or {}
  local size = opts.size or 24
  local btn = CreateFrame("Button", opts.name, parent)
  btn:SetSize(size, size)
  if opts.point then
    btn:SetPoint(unpack(opts.point))
  elseif parent.CloseButton then
    btn:SetPoint("RIGHT", parent.CloseButton, "LEFT", 0, 0)
  else
    btn:SetPoint("TOPRIGHT", -4, -2)
  end

  local glyph = btn:CreateFontString(nil, "OVERLAY", U.Fonts.TITLE)
  glyph:SetPoint("CENTER")
  glyph:SetText("?")
  btn.Glyph = glyph

  local function Paint(over)
    local c = over and U.Colors.HIGHLIGHT_WHITE or U.Colors.STATUS_GOLD
    glyph:SetTextColor(c[1], c[2], c[3])
  end
  Paint(false)

  UI.AddTooltip(btn, opts.tooltip or "Guide", opts.tooltipAnchor or "ANCHOR_TOP")
  btn:HookScript("OnEnter", function() Paint(true) end)
  btn:HookScript("OnLeave", function() Paint(false) end)
  btn:SetScript("OnMouseDown", function() glyph:SetPoint("CENTER", 1, -1) end)
  btn:SetScript("OnMouseUp", function() glyph:SetPoint("CENTER", 0, 0) end)
  btn:SetScript("OnClick", function(self, button)
    PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
    if opts.onClick then opts.onClick(self, button) end
  end)
  return btn
end

---------------------------------------------------------------------------
-- CreateGuideWindow
---------------------------------------------------------------------------
local GuideMixin = {}

local function Paragraphs(body)
  if type(body) == "function" then
    local ok, value = pcall(body)
    body = ok and value or ""
  end
  if type(body) == "table" then return table.concat(body, "\n\n") end
  return body or ""
end

-- A section button's label and state, read from its definition
local function PaintButton(button)
  local def = button.def
  if def.label then
    local ok, text = pcall(def.label)
    button:SetText(ok and text or def.text or "")
  end
  if def.enabled then
    local ok, on = pcall(def.enabled)
    button:SetEnabled(ok and on == true)
  end
end

-- Reads every function body and button label again, then lays the guide out
-- again while it is shown, so a body whose text changed length gets its new
-- height (on show, after a button click, or from an outside call)
function GuideMixin:RefreshBodies()
  for _, s in ipairs(self.sections) do
    if type(s.def.body) == "function" then s.text:SetText(Paragraphs(s.def.body)) end
    for _, button in ipairs(s.buttons or {}) do PaintButton(button) end
  end
  if self:IsShown() then self:Relayout() end
end

-- A row of buttons under the section's text: things the section talks about
local function BuildButtons(guide, s, body, defs)
  s.buttons = {}
  local previous
  for i, def in ipairs(defs) do
    local button = UI.CreateButton(body, {
      text = def.text or "", size = { def.width or 140, 22 }, tooltip = def.tooltip,
      onClick = function(self)
        if def.onClick then def.onClick(self) end
        guide:RefreshBodies()
      end,
    })
    button.def = def
    if previous then
      button:SetPoint("LEFT", previous, "RIGHT", 8, 0)
    end
    previous = button
    s.buttons[i] = button
  end
end

local function BuildSection(guide, def)
  local child = guide.Child
  local s = { key = def.key, def = def, expanded = false }

  local header = UI.CreateCollapsibleHeader(child)
  local icon, arrow, title, summary = header.Icon, header.Arrow, header.Title, header.Summary
  if def.atlas then
    icon:SetAtlas(def.atlas)
  else
    icon:SetTexture(def.icon)
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)   -- the icon border
  end
  s.arrowGlow = header.ArrowGlow
  title:SetText(def.title or def.key)
  summary:SetText(def.summary or "")

  header:SetScript("OnClick", function()
    local open = not s.expanded
    PlaySound(open and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF)
    guide:SetExpanded(s.key, open)
  end)

  local body = CreateFrame("Frame", nil, child)
  local bodyBg = body:CreateTexture(nil, "BACKGROUND")
  bodyBg:SetAllPoints()
  local a = U.Colors.ALT_ROW_BG
  bodyBg:SetColorTexture(a[1], a[2], a[3], a[4])

  local text = body:CreateFontString(nil, "OVERLAY", U.Fonts.BODY)
  text:SetPoint("TOPLEFT", BODY_LEFT, -PAD)
  text:SetJustifyH("LEFT")
  text:SetJustifyV("TOP")
  text:SetSpacing(2)
  text:SetText(Paragraphs(def.body))

  if def.try and #def.try > 0 then
    local label = body:CreateFontString(nil, "OVERLAY", U.Fonts.SMALL)
    label:SetPoint("TOPLEFT", text, "BOTTOMLEFT", 0, -10)
    label:SetText("Try it")
    local lines = {}
    for _, entry in ipairs(def.try) do
      lines[#lines + 1] = U.FormatCommandLine(entry[1], entry[2])
    end
    local try = body:CreateFontString(nil, "OVERLAY", U.Fonts.BODY)
    try:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 0, -4)
    try:SetJustifyH("LEFT")
    try:SetJustifyV("TOP")
    try:SetSpacing(4)
    try:SetText(table.concat(lines, "\n"))
    s.tryLabel, s.try = label, try
  end
  if def.buttons and #def.buttons > 0 then BuildButtons(guide, s, body, def.buttons) end
  body:Hide()

  s.header, s.icon, s.arrow, s.title, s.summary = header, icon, arrow, title, summary
  s.body, s.text = body, text
  return s
end

-- The body's height for a content width
local function MeasureBody(s, width)
  local textWidth = width - BODY_LEFT - PAD
  s.text:SetWidth(textWidth)
  local h = PAD + s.text:GetStringHeight()
  if s.try then
    s.try:SetWidth(textWidth)
    h = h + 10 + s.tryLabel:GetStringHeight() + 4 + s.try:GetStringHeight()
  end
  if s.buttons and s.buttons[1] then
    h = h + 10
    s.buttons[1]:ClearAllPoints()
    s.buttons[1]:SetPoint("TOPLEFT", s.body, "TOPLEFT", BODY_LEFT, -h)
    h = h + 22
  end
  return math.ceil(h + PAD)
end

function GuideMixin:Relayout()
  local width = self:GetWidth() - INSET_LEFT - INSET_RIGHT
  if width <= 0 then return end

  local top = TOP
  if self.Intro then
    self.Intro:SetWidth(width)
    top = top + self.Intro:GetStringHeight() + 8
  end
  self.Scroll:ClearAllPoints()
  self.Scroll:SetPoint("TOPLEFT", INSET_LEFT, -top)
  local bottom = BOTTOM
  if self.Footer then
    self.Footer.Text:SetWidth(self:GetWidth() - INSET_LEFT - FOOTER_RIGHT - 2 * PAD)
    bottom = BOTTOM + FOOTER_HEIGHT + 6
  end
  self.Scroll:SetPoint("BOTTOMRIGHT", -INSET_RIGHT, bottom)
  self.Child:SetWidth(width)

  local y = 0
  for _, s in ipairs(self.sections) do
    s.top = y
    s.header:ClearAllPoints()
    s.header:SetPoint("TOPLEFT", self.Child, "TOPLEFT", 0, -y)
    s.header:SetPoint("RIGHT", self.Child, "RIGHT", 0, 0)
    s.arrow:SetAtlas(s.expanded and ARROW_OPEN or ARROW_CLOSED, true)
    s.arrowGlow:SetAtlas(s.expanded and ARROW_OPEN or ARROW_CLOSED)
    y = y + HEADER_HEIGHT
    if s.expanded then
      local h = MeasureBody(s, width)
      s.body:ClearAllPoints()
      s.body:SetPoint("TOPLEFT", self.Child, "TOPLEFT", 0, -y)
      s.body:SetPoint("RIGHT", self.Child, "RIGHT", 0, 0)
      s.body:SetHeight(h)
      s.body:Show()
      y = y + h
    else
      s.body:Hide()
    end
    y = y + GAP
  end
  self.contentHeight = y
  self.Child:SetHeight(math.max(1, y))
  self.Scroll:UpdateScrollChildRect()
end

function GuideMixin:IsExpanded(key)
  local s = self.byKey[key]
  return s ~= nil and s.expanded
end

function GuideMixin:SetExpanded(key, expanded)
  local s = self.byKey[key]
  if not s then return end
  if expanded and self.singleOpen then
    for _, other in ipairs(self.sections) do other.expanded = false end
  end
  s.expanded = expanded and true or false
  self:Relayout()
end

function GuideMixin:GetContentHeight()
  return self.contentHeight or 0
end

function GuideMixin:OpenSection(key)
  if not self:IsShown() then
    self:RestoreState()
    self:Show()
  end
  local s = self.byKey[key]
  if not s then return end
  self:SetExpanded(key, true)
  local range = self.Scroll:GetVerticalScrollRange()
  self.Scroll:SetVerticalScroll(math.max(0, math.min(s.top or 0, range)))
end

function UI.CreateGuideWindow(opts)
  opts = opts or {}
  local f = UI.CreateWindow({
    name         = opts.name,
    title        = opts.title,
    icon         = opts.icon,
    width        = opts.width or 580,
    height       = opts.height or 620,
    resizable    = { minWidth = 440, minHeight = 320, maxWidth = 1000, maxHeight = 1100 },
    escapeCloses = opts.name ~= nil,
    persist      = opts.persist,
    point        = not opts.persist and { "CENTER", UIParent, "CENTER", 0, 40 } or nil,
    mixin        = GuideMixin,
  })
  f.singleOpen = opts.singleOpen and true or false

  if opts.intro then
    local intro = f:CreateFontString(nil, "OVERLAY", U.Fonts.BODY)
    intro:SetPoint("TOPLEFT", INSET_LEFT + 2, -TOP)
    intro:SetJustifyH("LEFT")
    intro:SetSpacing(2)
    intro:SetText(opts.intro)
    f.Intro = intro
  end

  if opts.footer then
    local footer = CreateFrame("Frame", nil, f)
    footer:SetPoint("BOTTOMLEFT", INSET_LEFT, BOTTOM - 4)
    footer:SetPoint("BOTTOMRIGHT", -FOOTER_RIGHT, BOTTOM - 4)
    footer:SetHeight(FOOTER_HEIGHT)
    local bg = footer:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    local c = U.Colors.CONTENT_BG
    bg:SetColorTexture(c[1], c[2], c[3], c[4])
    local text = footer:CreateFontString(nil, "OVERLAY", U.Fonts.SMALL)
    text:SetPoint("CENTER")
    text:SetJustifyH("CENTER")
    text:SetWordWrap(false)
    local gray = U.Colors.LABEL_GRAY
    text:SetTextColor(gray[1], gray[2], gray[3])
    text:SetText(opts.footer)
    footer.Text = text
    f.Footer = footer
  end

  local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
  -- The template's bar is the old slider, without ScrollBarMixin's
  -- SetHideIfUnscrollable. scrollBarHideable makes the template's range
  -- handler (ScrollFrame_OnScrollRangeChanged) hide the bar while there is
  -- nothing to scroll and show it again when there is. The template's OnLoad
  -- ran before the flag was set, so the bar starts hidden here.
  scroll.scrollBarHideable = true
  if scroll.ScrollBar then scroll.ScrollBar:Hide() end
  local child = CreateFrame("Frame", nil, scroll)
  child:SetSize(1, 1)
  scroll:SetScrollChild(child)
  f.Scroll, f.Child = scroll, child

  f.sections, f.byKey = {}, {}
  for _, def in ipairs(opts.sections or {}) do
    local s = BuildSection(f, def)
    f.sections[#f.sections + 1] = s
    f.byKey[def.key] = s
  end

  local open = opts.expanded or (f.sections[1] and { f.sections[1].key } or {})
  for _, key in ipairs(open) do
    if f.byKey[key] then f.byKey[key].expanded = true end
  end

  f:RestoreState()
  f:SetScript("OnSizeChanged", function(self) self:Relayout() end)
  f:HookScript("OnShow", function(self) self:RefreshBodies() end)
  f:Relayout()
  return f
end

---------------------------------------------------------------------------
-- CobySuite.UI.WhatsNew / CreateWhatsNewWindow: an addon's changelog in the
-- guide's window, one collapsible section per version, and what its login
-- shows: a fresh install opens the addon's guide (onFirstRun), an update
-- opens this window with every version since the last one run, and anything
-- else shows nothing. Both wait for combat to end.
--
--   local whatsNew = CobySuite.UI.CreateWhatsNewWindow({
--     name    = "MyAddonChangelogWindow",
--     title   = "My Addon: What's New",
--     icon    = "Interface\\Icons\\INV_Misc_Book_09",   -- the window's and each version's default icon
--     intro   = "What changed in each version, newest first.",
--     footer  = "Open this window any time with /ma changelog",   -- optional
--     entries = MyAddon.Data.Changelog,   -- newest first: { version, title, date, icon, new, changed, fixed }
--     version = MyAddon.VERSION,          -- the TOC's
--     state   = function() return MY_ADDON_WINDOW_STATE end,   -- saved table: holds lastVersion and the window's place
--     persistKey = "changelogWindow",     -- optional: the key under state() for the window's place (the default)
--     onFirstRun = function() MyAddon.Guide.Show() end,          -- optional: a fresh install
--     existingInstall = function() return MyAddon.hadSavedConfig end, -- optional: true when the player
--                                         -- ran the addon before it had this window (its settings
--                                         -- were saved before this login): no guide, the version is
--                                         -- only recorded, and the next update shows What's New
--     combatMessage = function(text) MyAddon.Message(text) end, -- optional: when asked for in combat before it is built
--     onShow = function(what) end,        -- optional: "guide" or "changelog", at login
--   })
--   whatsNew:OnLogin()        -- at PLAYER_LOGIN
--   whatsNew:Toggle()         -- a slash command
--   whatsNew:ShowVersions({ "v1.2.0" })
--
-- An entry's lines are strings a player reads: "Feature: what it does", the
-- part before the first ": " in the help blue, and {Alt+D} or {/cmd} for a
-- key or command in the help gold. A date shows "Released <date>", none
-- "Beta". The window is built at login, out of combat.
---------------------------------------------------------------------------
UI.WhatsNew = {}
local WhatsNew = UI.WhatsNew
local SHOW_DELAY = 3   -- seconds after login, so the window opens over a settled screen
local BULLET = "\226\128\162 "
local KINDS = {
  { key = "new", label = "New" },
  { key = "changed", label = "Changed" },
  { key = "fixed", label = "Fixed" },
}

function WhatsNew.SectionKey(entry)
  return "v" .. tostring(entry.version)
end

-- One line as shown: a bullet, the lead before ": " in blue, {keys} in gold
function WhatsNew.Line(text)
  local lead, rest = tostring(text):match("^([^:{]+): (.*)$")
  local function Keys(s)
    return (s:gsub("{(.-)}", function(key) return U.WrapColor(U.Colors.HELP_COMMAND, key) end))
  end
  if lead then return BULLET .. U.WrapColor(U.Colors.HELP_SECTION, lead) .. ": " .. Keys(rest) end
  return BULLET .. Keys(tostring(text))
end

-- Decide(state, version, entries, existing): what login shows, recording
-- version as state.lastVersion. "guide" on a fresh install (no lastVersion,
-- and existing not true); nothing when there is no lastVersion but the
-- player ran the addon before (existing: a release from before this window);
-- "changelog" and the section keys of every entry newer than the last
-- version run and not newer than this one (in the entries' order) after an
-- update; else nil.
function WhatsNew.Decide(state, version, entries, existing)
  if type(state) ~= "table" or type(version) ~= "string" then return nil end
  local last = state.lastVersion
  state.lastVersion = version
  if type(last) ~= "string" then
    if existing then return nil end
    return "guide"
  end
  if U.CompareVersions(version, last) <= 0 then return nil end
  local keys = {}
  for _, entry in ipairs(entries or {}) do
    if U.CompareVersions(entry.version, last) > 0 and U.CompareVersions(entry.version, version) <= 0 then
      keys[#keys + 1] = WhatsNew.SectionKey(entry)
    end
  end
  if #keys == 0 then return nil end
  return "changelog", keys
end

-- The guide window's sections for the entries: a header per version (its
-- title, the release date or "Beta") and a paragraph per kind of change, a
-- gold heading over its bulleted lines; icon is the default section icon
function WhatsNew.Sections(entries, icon)
  local sections = {}
  for _, entry in ipairs(entries or {}) do
    local body = {}
    for _, kind in ipairs(KINDS) do
      local lines = entry[kind.key]
      if type(lines) == "table" and #lines > 0 then
        local text = { U.WrapColor(U.Colors.TEXT_GOLD, kind.label) }
        for _, line in ipairs(lines) do text[#text + 1] = WhatsNew.Line(line) end
        body[#body + 1] = table.concat(text, "\n")
      end
    end
    local title = "Version " .. tostring(entry.version)
    if entry.title then title = title .. ": " .. entry.title end
    sections[#sections + 1] = {
      key = WhatsNew.SectionKey(entry),
      title = title,
      icon = entry.icon or icon,
      summary = entry.date and ("Released " .. entry.date) or "Beta",
      body = body,
    }
  end
  return sections
end

-- The client calls login makes, as seams a test can script
WhatsNew.seams = {
  After = function(delay, fn) C_Timer.After(delay, fn) end,
  InCombat = function() return InCombatLockdown() end,
  OnceEvent = function(event, fn) EventUtil.RegisterOnceFrameEventAndCallback(event, fn) end,
}

local WhatsNewMixin = {}

-- The window, built once and out of combat; nil when it can't be built yet
function WhatsNewMixin:Build()
  if self.window then return self.window end
  if InCombatLockdown() then return nil end
  local opts = self.opts
  self.window = UI.CreateGuideWindow({
    name = opts.name, title = opts.title, icon = opts.icon, intro = opts.intro, footer = opts.footer,
    sections = WhatsNew.Sections(opts.entries, opts.icon),
    persist = opts.state and { svTable = opts.state, key = opts.persistKey or "changelogWindow" } or nil,
  })
  return self.window
end

function WhatsNewMixin:Toggle()
  local w = self:Build()
  if w then
    w:Toggle()
  elseif self.opts.combatMessage then
    self.opts.combatMessage("The changelog opens when combat ends.")
  end
end

-- Opens the window with exactly these versions open, scrolled to the first
function WhatsNewMixin:ShowVersions(keys)
  local w = self:Build()
  if not w or not keys or not keys[1] then return end
  for _, section in ipairs(w.sections) do w:SetExpanded(section.key, false) end
  for _, key in ipairs(keys) do w:SetExpanded(key, true) end
  w:OpenSection(keys[1])
end

function WhatsNewMixin:OnLogin()
  self:Build()
  local opts = self.opts
  local existing = opts.existingInstall and opts.existingInstall() == true
  local what, keys = WhatsNew.Decide(opts.state and opts.state(), opts.version, opts.entries, existing)
  if not what then return end
  if opts.onShow then opts.onShow(what) end
  local function Show()
    if what == "guide" then
      if opts.onFirstRun then opts.onFirstRun() end
    else
      self:ShowVersions(keys)
    end
  end
  local seams = WhatsNew.seams
  seams.After(SHOW_DELAY, function()
    if seams.InCombat() then
      seams.OnceEvent("PLAYER_REGEN_ENABLED", Show)
    else
      Show()
    end
  end)
end

function UI.CreateWhatsNewWindow(opts)
  return setmetatable({ opts = opts or {} }, { __index = WhatsNewMixin })
end
