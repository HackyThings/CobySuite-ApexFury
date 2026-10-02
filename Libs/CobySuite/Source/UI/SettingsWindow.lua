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
-- Size: size = "compact" (640 x 460), "standard" (680 x 480, the default)
-- or "browser" (720 x 580), the suite's shared presets (UI.SettingsSizes);
-- width or height, when given, wins over the preset. Every size uses the
-- same spacing and controls: rows wrap, tile grids drop columns and a long
-- page scrolls; text never shrinks. The window grows from its bottom-right
-- corner (CreateWindow's resize grip), and the declared size is the
-- smallest it gets, by choice (Task #50, 2026-10-01): the rows are laid out
-- for it (a panel that fills its view, as ApexFury's sound browser does,
-- never has to scroll), so a saved window smaller than a new, larger preset
-- grows to it on the next open, and a saved larger window is kept. It grows
-- by up to MAX_GROWTH in each direction unless resizable gives other bounds.
-- The size is saved and restored with the position under persist. A panel's
-- rows follow its width: text wraps to it, sliders, multi-line boxes and
-- full-width dropdowns stretch, and inputs, inline dropdowns and keybind
-- buttons stay right-aligned. layout.contentWidth and layout.inputX give
-- the width at build, so a Custom row sized from them keeps that size, and
-- a category taller than the window scrolls.
--
--   local window = CobySuite.UI.CreateSettingsWindow({
--     name    = "MyAddonSettingsWindow",   -- global name: Escape closes it; the Defaults popup is <name>DefaultsPopup
--     title   = "My Addon - Settings",
--     icon    = "Interface\\Icons\\INV_Misc_Book_09",  -- optional, left of the title (CreateWindow)
--     config  = MyAddon.Config,            -- a CobySuite.Config.New instance (Get, Set, Defaults, CheckValue)
--     persist = { svTable = function() return MY_ADDON_WINDOW_STATE end, key = "settings" },
--     size    = "standard",                -- or "compact", "browser"; the sidebar and its gap take 144 of the width
--     width   = 680, height = 480,         -- optional, over the preset
--     resizable = { maxWidth = 1180, maxHeight = 980 },  -- optional bounds; false keeps the size fixed
--     strata  = "MEDIUM",                  -- optional; CreateWindow's default MEDIUM
--     watch   = { bus = MyAddon.EventBus, event = MyAddon.Events.ConfigChanged },   -- optional
--     onApply = function(changes, window) end,   -- after Apply: changes[key] = { old = ..., new = ... }
--     message = MyAddon.Utilities.Message,       -- prints Apply's notes: a refused or failed Set, an onApply error (default print)
--     footerButtons = { { text = "Debug Log", width = 100, tooltip = "...", onClick = function(window) end } },
--     categories = {
--       { key = "general", label = "General", build = function(panel, window) ... end },
--       { key = "sound", label = "Sound", scroll = false, build = function(frame, window) ... end },
--       { key = "extra", label = "Extra", config = function() return Other.Config end, build = ... },
--     },
--   })
--
-- A category's optional config (a config, or a function returning one or
-- nil) owns the settings its rows bind; the window's config owns the rest.
-- A function is called on every read and write, so it can name a config
-- that exists only later (a part of the addon that loads after the window
-- is built, or may not load at all). While it returns nil, that category's
-- controls are not painted, Defaults and Apply leave its keys alone, and
-- rows meant only for then are gated with visibleWhen. Keys are staged by
-- name alone, so keys of two configs in one window must not share a name.
-- A scroll = false category binds no rows, so it always uses the window's
-- config.
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
--   panel:Section(text, opts)       -- opts: visibleWhen, refresh
--   panel:Description(text, opts)
--   panel:Checkbox{ key, label, tooltip, indent }
--   panel:Input{ key, label, tooltip, indent, width = 55, x, numeric, digits, maxLetters, format(value) -> text,
--                parse(text) -> value or nil, validate(value) -> bool }
--     x: the input's left edge (default right-aligned); digits: the box takes digits only. Text that
--     still reads format(current value) keeps that value exactly, so clicking through a field that
--     rounds its value (whole gold, a percent) stages nothing
--   panel:Slider{ key, label, tooltip, min, max, step, format(value) -> text }
--   panel:Dropdown{ key, label, tooltip, labels, values, tooltips, inline, width }   -- inline: label left, dropdown right
--   panel:Radio{ key, options = { { value =, label =, tooltip = } }, tooltip, indent }   -- tooltip: for an option without one
--   panel:Keybind{ key, label, tooltip, mouse, indent }   -- capture button and Clear (stages no value); mouse
--                                                          --   also takes a click on the button: any of Middle, Mouse 4
--                                                          --   and 5, and Left or Right with a modifier ("ALT-BUTTON1")
--   panel:MultiLine{ key, height, maxLetters, maxBytes, placeholder, fontScale, tooltip, validate(text) -> bool }
--   panel:Button{ text, width, tooltip, indent, onClick(window) }
--   panel:Custom{ height, keys = { ... }, build(row, window, layout), refresh(row, window) }
--     keys: settings the row stages itself, so Defaults covers them; refresh runs after every sync and stage
--
-- The styled rows (Task #29, 2026-10-01). An icon is icon = file ID or path,
-- or atlas = name. A field marked live may be a function(window), read again
-- on every repaint and staged change (window:Get(key) then gives the staged
-- value). Every
-- row with a control takes description (live): a readable grey line under
-- it that wraps. enabledWhen disables a row whose staying in view explains
-- the feature; visibleWhen hides one that applies to one mode only; a hidden
-- or disabled row keeps its value, staged or saved.
--   panel:Section(text, { icon/atlas, subtitle, count(window), switchKey, switchTooltip })
--     count: "(12)" after the title; switchKey: an on/off box at the header's right end
--   panel:Radio{ ..., options = { { value, label, tooltip, description } }, inline, label, labelWidth }
--     inline: the options side by side on one line after the label. One option lit for a saved
--     value; values may be strings, numbers or booleans (false too)
--   panel:Slider{ ..., minLabel, maxLabel, customText(value) }   panel:Input{ ..., unit = "gold", icon/atlas, labelColor }
--     a saved value off the bar (out of range, between steps) reads "Custom: " .. format(value)
--   panel:Dropdown{ ..., extraLabel(value) }   -- a saved value off the list is its own entry ("Custom: 5")
--   panel:Button{ ..., text (live), enabled (live), immediate, icon/atlas }
--     immediate: an action outside Apply; "Takes effect immediately." joins its description
--   panel:MultiLine{ ..., description, tokens = { { text, label, tooltip } } }   row.GetDraft(): the box's text
--   panel:Tiles{ key or get(window)/onSelect(value, window), options, columns, minTileWidth (100), height,
--                maxTiles, indent }
--     choose one (a radio mark); options is a list or function(get, window) (then maxTiles tiles are
--     made at build). Fewer columns when a tile would be narrower than minTileWidth.
--     An option: { value (any type), title, description, icon/atlas or face (a keycap word), count,
--     badge, dot (a color), dim, warn, tooltip (all live), preview(frame, layout), previewHeight,
--     previewPaint(frame, selected, window) }
--   panel:ToggleTiles{ options = { { key, locked, ...a tile's fields } } }   -- each its own on/off setting
--     a square check; locked: a lock, "Always included" and no hover
--   panel:StatusTiles{ options = { { state, stateText (live), ...a tile's fields } } }   -- read only, no hover
--     state (live): "ok", "off", "warn" or "unknown"; stateText: the word beside its mark
--   panel:ActionTiles{ options = { { onClick(window), ...a tile's fields } } }   -- an arrow; acts at once
--   panel:StatusCard{ icon/atlas, state, stateText, title, description (all live), ticker,
--                     actions = { { text (live), onClick(window), enabled (live), tooltip (live), width } }, gap }
--     what is happening now; read only; row.Refresh() repaints it
--   panel:BeginCard{ title (live), description (live), icon/atlas, dot, switchKey, switchTooltip, visibleWhen } ... panel:EndCard()
--     the rows between sit in one bordered card and show only while it does
--   panel:Note{ text (live), icon/atlas, color }   -- with a color, a callout strip; empty text takes no room
--   panel:Notice{ kind (live: "info", "warn", "error"), text (live), recovery (live) }
--   panel:EmptyState{ state (live: "empty", "nomatch", "loading", "unavailable"), title, text (live),
--                     icon/atlas, action = { text, onClick(window) } }
--   panel:Bullets{ items = { { title, lines = { ... }, icon/atlas } } or function(window), maxItems }
--   panel:Preview{ caption (live), text (live) and color (live), or height, build(frame, window) and
--                  refresh(frame, window); ticker (seconds), dimWhen(get), action = { text, onClick(window) } }
--     caption = "Example" for a passive example; action for "Play sample", "Send test to myself"
--   panel:Value{ label, value (live), events = { ... } }   -- read-only label and value
--   panel:Meter{ label, value (live), max (live), warnAt (0.75), format(used, max) }
--   panel:Legend{ items = { { icon/atlas, color, label } } }
--   panel:DropdownAction{ label, options(window) -> labels, values, detail(value, window), buttonText,
--                         buttonTooltip, onClick(value, window), emptyText, width, buttonWidth }
--   panel:List{ rows(window) -> entries, onRemove(entry, window), onUndo(entry, window), removeTooltip,
--               empty = { state, title, text, icon/atlas, action } or function(window), searchAt }
--     an entry: { itemID (icon, quality color, tooltip), text, tag, icon/atlas, tooltip, removed }
--     (removed: struck through with Undo). The search stays while it holds a query, with "Matches:
--     N of M"; a search that hides everything shows No matches and Clear the search. Its frames
--     are made out of combat; entries past them wait for combat to end.
-- A category with defaults = false keeps its settings out of the Defaults button.
--
--   window:Get(key)   window:Stage(key, value)   window:Apply()   window:Cancel()
--                     -- Stage repaints the key's controls; a Custom control whose
--                     -- repaint would disturb the player (typing, a drag) stages
--                     -- its own change with window:StageEdit (no repaint)
--   window:StageValue(key, value) ... window:Populate(window.getter)
--                                      -- stages several keys, then repaints once (a "restore these" button)
--   window:HasEdits()  -- a staged value, or an Input being typed in
--   window:Toggle()   window:Open()   window:SelectCategory(key)
--   window:NotifyConfigChanged(key)   -- for an addon with no config event (nil: every setting)
--   window:Refresh()                   -- something shown changed outside the config (a count, a status);
--                                      --   nothing while the window is closed
--   window:Relayout()                  -- lays the panels out again at the window's size (a resize does it)
--   window.FooterButtons               -- the footerButtons' buttons, in order
--   window.panels[categoryKey]         -- .content, .layout (pad, rowHeight, contentWidth, inputX(width)), :Width()
---------------------------------------------------------------------------
local UI = CobySuite_ApexFury.UI
local U = CobySuite_ApexFury.Utilities

local SIDEBAR_W = 140
local SIDEBAR_BUTTON_H = 28
local PAD = 16
local ROW_H = 26
local RADIO_H = 22           -- one radio button's line: its circle is 16 high, a checkbox 24
local RADIO_NOTE_H = 14      -- a radio option's grey description line
-- A section's header and divider sit close over its rows and further from
-- the rows above, so each section reads as one group
local SECTION_H = 22         -- the header's line and the divider under it
local SECTION_GAP = 14       -- above every section but a panel's first row
local MAX_GROWTH = 500       -- how far the window grows past its declared size, each way
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
-- The styled rows' look (Cobanyte, 2026-10-01: "icons, tiles, etc. ...
-- They should look fancy!"). Every atlas and texture below is one Blizzard's own UI
-- uses (12.1.0, build 69933), named with the Blizzard file that uses it.
---------------------------------------------------------------------------
local SECTION_ICON = 16
local TILE_H, TILE_GAP, TILE_ICON = 58, 8, 32
local TILE_MIN_W = 100     -- a tile narrower than this wraps its grid to fewer columns
local LIST_ROW_H, LIST_ICON = 24, 18
local EMPTY_H = 58
local STYLE = {
  -- the friends list's card, stretched to its button (FriendsListTemplates.xml)
  tileAtlas = "friends-card-default",
  tileHoverAtlas = "friends-card-selected",
  -- the round option and the check of the role poll and the 12.x Settings
  -- checkbox (RolePoll.xml, Blizzard_SettingControls.xml)
  radioAtlas = "common-radiobutton-circle",
  radioDotAtlas = "common-radiobutton-dot",
  checkboxAtlas = "checkbox-minimal",
  checkAtlas = "checkmark-minimal",
  -- the auction house filter's red x (UIResetButtonTemplate)
  removeAtlas = "auctionhouse-ui-filter-redx",
  -- the Settings category list's hover (Blizzard_CategoryList.lua)
  rowHoverAtlas = "Options_List_Hover",
  -- the cooldown viewer settings' empty category (CooldownViewerSettings.lua)
  emptyAtlas = "cdm-empty",
  -- the money frame's gold coin (MoneyFrame)
  goldAtlas = "coin-gold",
  -- Task #50's states (Gethe wow-ui-source live, 2026-10-01): the group
  -- finder's lock (LFGList.xml), the transmog warning
  -- (Blizzard_TransmogTemplates.xml), the quest log's question mark
  -- (QuestMapFrame.xml), the guild rename's red x (Blizzard_GuildRename.lua),
  -- the auction house's "i" (Blizzard_AuctionHouseBuyDialog.xml) and the
  -- friends list's category arrow (FriendsFrame.xml)
  lockAtlas = "groupfinder-icon-lock",
  warnAtlas = "transmog-icon-warning-small",
  unknownAtlas = "questlog-waypoint-finaldestination-questionmark",
  errorAtlas = "common-icon-redx",
  infoIcon = "Interface\\common\\help-i",
  actionAtlas = "friendslist-categorybutton-arrow-right",
}

-- Secondary text (descriptions, captions, subtitles, counts): a readable
-- gray, never the disabled 0.5 (about 9:1 on the window's background)
local function DescText(parent, layer)
  local text = parent:CreateFontString(nil, layer or "OVERLAY", U.Fonts.DATA)
  Color(text, U.Colors.LABEL_GRAY)
  return text
end

-- What a live field gives now: a function's answer (nil when it throws), or
-- the field itself
local function Live(field, window)
  if type(field) ~= "function" then return field end
  local ok, value = pcall(field, window)
  if ok then return value end
end

-- A state's mark, color and default word (StatusTiles, StatusCard)
local STATES = {
  ok      = { atlas = STYLE.checkAtlas, color = U.Colors.SUCCESS_GREEN, word = "On" },
  off     = { atlas = STYLE.removeAtlas, color = U.Colors.WARNING_RED, word = "Off" },
  warn    = { atlas = STYLE.warnAtlas, color = U.Colors.CAUTION_ORANGE, word = "Limited" },
  unknown = { atlas = STYLE.unknownAtlas, color = U.Colors.LABEL_GRAY, word = "Unknown" },
}

local IMMEDIATE_TEXT = "Takes effect immediately."
local ALWAYS_INCLUDED_TEXT = "Always included"

-- The shared window sizes. Each size is also the window's minimum (see the
-- header)
UI.SettingsSizes = {
  compact  = { width = 640, height = 460 },
  standard = { width = 680, height = 480 },
  browser  = { width = 720, height = 580 },
}

-- spec.atlas, else spec.icon (a file ID or path, trimmed like an action icon)
local function SetIcon(texture, spec)
  if spec.atlas then
    texture:SetAtlas(spec.atlas)
  elseif spec.icon then
    texture:SetTexture(spec.icon)
    texture:SetTexCoord(0.07, 0.93, 0.07, 0.93)
  end
end

-- A 1px border of four textures; frame:SetEdgeColor(c, alpha) paints it
local function AddEdges(frame, layer)
  local edges = {}
  for i, def in ipairs({ { "TOPLEFT", "TOPRIGHT" }, { "BOTTOMLEFT", "BOTTOMRIGHT" },
                         { "TOPLEFT", "BOTTOMLEFT" }, { "TOPRIGHT", "BOTTOMRIGHT" } }) do
    local edge = frame:CreateTexture(nil, layer or "BORDER")
    edge:SetPoint(def[1])
    edge:SetPoint(def[2])
    if i <= 2 then edge:SetHeight(1) else edge:SetWidth(1) end
    edges[i] = edge
  end
  frame.SetEdgeColor = function(_, c, alpha)
    for _, edge in ipairs(edges) do edge:SetColorTexture(c[1], c[2], c[3], alpha or c[4] or 1) end
  end
end

-- A list's identity, so a refresh rebuilds a dropdown only when it changed
local function Signature(labels, values)
  local parts = {}
  for i = 1, #values do parts[i] = tostring(values[i]) .. "\31" .. tostring(labels[i]) end
  return table.concat(parts, "\30")
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

  -- A range that shrinks (the window grew, a row hid) brings the offset
  -- back inside it, so no blank band shows above the first row
  scroll:SetScript("OnScrollRangeChanged", function(self)
    local range = math.max(0, self:GetVerticalScrollRange())
    if self:GetVerticalScroll() > range then self:SetVerticalScroll(range) end
    Update()
  end)

  scroll.UpdateScrollIndicator = Update
end

---------------------------------------------------------------------------
-- Staging
---------------------------------------------------------------------------

-- A config, or what a config function returns now (possibly nil)
local function Resolve(config)
  if type(config) == "function" then return config() end
  return config
end

-- The config that owns a key: its category's (resolved now, possibly nil)
-- or the window's
function Settings:ConfigFor(key)
  local owner = self.keyConfig[key]
  if owner ~= nil then return Resolve(owner) end
  return self.config
end

-- The staged value, else the saved one (nil while the key's config is absent)
function Settings:Get(key)
  local staged = self.pending[key]
  if staged == CLEAR then return nil end
  if staged ~= nil then return staged end
  local config = self:ConfigFor(key)
  if not config then return nil end
  return config.Get(key)
end

-- Records a value without refreshing anything (nothing while the key's
-- config is absent)
function Settings:StageValue(key, value)
  local config = self:ConfigFor(key)
  if not config then
    self.pending[key] = nil
    return
  end
  if value == config.Get(key) then
    self.pending[key] = nil
  elseif value == nil then
    self.pending[key] = CLEAR
  else
    self.pending[key] = value
  end
end

-- A control's own change (the kit's controls call it): staged, the rows
-- refreshed, the control left as it is, since it already shows the value
-- and may be mid-edit (a box stages every keystroke, a slider every step
-- of a drag). Ignored while the window paints its controls, and while it
-- is closed (a field losing focus as it hides).
function Settings:StageEdit(key, value)
  if self.syncing or not self:IsShown() then return end
  self:StageValue(key, value)
  self:RefreshState()
end

-- A change from code (an addon's own button, a Verify scene): staged, and
-- the key's controls repainted to show it (four addons' scenes staged a
-- value while its checkbox or slider kept showing the saved one, run 2).
-- Ignored while the window paints its controls, and while it is closed.
function Settings:Stage(key, value)
  if self.syncing or not self:IsShown() then return end
  self:StageValue(key, value)
  self:Populate(self.getter, key)
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
-- skipStaged, a control holding a staged edit or being typed in keeps it. A
-- control whose config is absent is left as it is.
function Settings:Populate(resolver, onlyKey, skipStaged)
  self.syncing = true
  for _, control in ipairs(self.controls) do
    local key = control.key
    local held = skipStaged and (self.pending[key] ~= nil or self.editing[key])
    if (onlyKey == nil or key == onlyKey) and not held and self:ConfigFor(key) then
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

-- The saved value, or nil when reading it throws or there is no config
local function SafeGet(config, key)
  if not config then return nil end
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
    local config = self:ConfigFor(key)
    local old = SafeGet(config, key)
    local ok, result, reason
    if config then
      ok, result, reason = pcall(config.Set, key, value)
    else
      ok, result, reason = true, false, "its settings are not available now"
    end
    local name = tostring(key)
    if ok and result == false then
      notes[#notes + 1] = ("Setting %s was not applied: %s"):format(name, tostring(reason))
    elseif ok then
      changes[key] = { old = old, new = SafeGet(config, key) }
    else
      local now = SafeGet(config, key)
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

-- Stages the default of every setting the window shows whose config is there
function Settings:StageDefaults()
  for key in pairs(self.keys) do
    local config = self:ConfigFor(key)
    if config and not self.noDefaults[key] then self:StageValue(key, (config.Defaults or {})[key]) end
  end
  self:Populate(self.getter)
end

-- A setting changed outside the window: repaint it (every setting for a nil
-- key) unless its control holds a staged edit or is being typed in
function Settings:NotifyConfigChanged(key)
  if self.applying or not self:IsShown() then return end
  self:Populate(function(k)
    local config = self:ConfigFor(k)
    return config and config.Get(k)
  end, key, true)
end

-- Buttons, enabled states, custom refreshers and visible rows. The
-- refreshers run before the layout: a refresher may set a row's text
-- (a Description filled in refresh), and the layout measures each row's
-- height from the text it has then.
function Settings:RefreshState()
  local edits = self:HasEdits()
  self.ApplyButton:SetEnabled(edits)
  self.CancelButton:SetEnabled(edits)
  for _, row in ipairs(self.dynamicRows) do
    if row.enabledWhen and row.SetRowEnabled then
      row.SetRowEnabled(row.enabledWhen(self.getter) and true or false)
    end
  end
  for _, refresher in ipairs(self.refreshers) do
    refresher()
  end
  self:Relayout()
end

-- Something the window shows changed outside the config (a count, a status):
-- reads enabledWhen, every live field and the layout again. Nothing while
-- the window is closed (it reads them all when it opens).
function Settings:Refresh()
  if self:IsShown() then self:RefreshState() end
end

-- Lays every panel out at its width now (a scroll = false panel lays
-- itself out)
function Settings:Relayout()
  for _, panel in ipairs(self.panelList) do
    if panel.Layout then panel:Layout() end
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
      -- A panel hidden while the window was resized has not followed it yet
      if self:IsShown() then panel:Layout() end
      panel.scroll:SetVerticalScroll(0)
      C_Timer.After(0, panel.scroll.UpdateScrollIndicator)
    end
  end
  for _, button in ipairs(self.sidebarButtons) do
    local selected = button.categoryKey == key
    button.Selected:SetShown(selected)
    -- the selected label is larger, unless that runs past its highlight
    -- ("Keys and waypoints", Recollect, 2026-10-01): then the small white one
    button.Text:SetFontObject(selected and U.Fonts.BODY or U.Fonts.SMALL)
    if selected and button.Text:GetUnboundedStringWidth() > button:GetWidth() - 18 then
      button.Text:SetFontObject(U.Fonts.DATA)
    end
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
  -- a row inside an open card shows only while the card does
  local cardVisible = self.card and self.card.visibleWhen
  if opts or cardVisible then
    local visibleWhen = opts and opts.visibleWhen
    if cardVisible and visibleWhen and visibleWhen ~= cardVisible then
      local own = visibleWhen
      visibleWhen = function(get) return cardVisible(get) and own(get) end
    elseif cardVisible then
      visibleWhen = cardVisible
    end
    opts = opts or {}
    row.visibleWhen = visibleWhen
    row.enabledWhen = opts.enabledWhen
    if visibleWhen or opts.enabledWhen then
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

-- The panel's width now: its scroll frame's, which follows the window's
-- size; the width at build while the frame has none yet
function Panel:Width()
  local width = self.scroll:GetWidth()
  if type(width) ~= "number" or width <= 0 then return self.layout.contentWidth end
  return width
end

-- Stacks the visible rows from the top and sizes the scroll child. A new
-- width first goes to every row that follows it (row.Reflow), hidden ones
-- too, so a row that shows later is already at the width.
function Panel:Layout()
  local width = self:Width()
  if width ~= self.width then
    self.width = width
    self.content:SetWidth(width)
    for _, row in ipairs(self.rows) do
      if row.Reflow then row.Reflow(width) end
    end
  end
  local get = self.window.getter
  local y = -PAD
  local first = true
  for _, row in ipairs(self.rows) do
    local visible = true
    if row.visibleWhen then visible = row.visibleWhen(get) and true or false end
    -- a row with nothing to say now (a Note whose live text is empty) takes no room
    if visible and row.Collapsed and row.Collapsed() then visible = false end
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
  if self.config ~= nil then window.keyConfig[key] = self.config end
  if self.noDefaults then window.noDefaults[key] = true end
  table.insert(window.controls, { key = key, set = set, stop = stop })
end

-- Describe(row, o, x): o.description as a grey line under the row's control,
-- from x, wrapping to the panel's width; the row grows to fit it. A function
-- description (function(window) -> text) is read again on every repaint.
function Panel:Describe(row, o, x)
  if not (o and o.description) then return end
  local window = self.window
  local fixedBase = row:GetHeight()
  local note = DescText(row)
  note:SetPoint("TOPLEFT", row, "TOPLEFT", x, -(fixedBase - 2))
  note:SetJustifyH("LEFT")
  note:SetWordWrap(true)
  if type(o.description) == "function" then
    table.insert(window.refreshers, function()
      local ok, text = pcall(o.description, window)
      note:SetText(ok and text or "")
    end)
  else
    note:SetText(o.description)
  end
  row.Note = note
  local reflow = row.Reflow
  row.Reflow = function(width)
    if reflow then reflow(width) end
    note:SetWidth(width - x - PAD - SCROLLBAR_ROOM)
  end
  note:SetWidth(self.layout.contentWidth - x - PAD - SCROLLBAR_ROOM)
  local measure = row.Measure
  -- under the row's own content, which may change height (a radio's wrapped
  -- lines, a tile grid that wraps or shows fewer tiles)
  row.Measure = function()
    local base = fixedBase
    if measure then
      measure()
      base = row:GetHeight()
      note:ClearAllPoints()
      note:SetPoint("TOPLEFT", row, "TOPLEFT", x, -(base - 2))
    end
    row:SetHeight(base + math.ceil(note:GetStringHeight()) + 4)
  end
  local setEnabled = row.SetRowEnabled
  row.SetRowEnabled = function(enabled)
    if setEnabled then setEnabled(enabled) end
    note:SetAlpha(enabled and 1 or 0.5)
  end
end

function Panel:Section(text, opts)
  opts = opts or {}
  local window = self.window
  local row = self:AddRow(SECTION_H, opts, SECTION_GAP)
  local x = PAD
  if opts.icon or opts.atlas then
    row.Icon = row:CreateTexture(nil, "ARTWORK")
    row.Icon:SetSize(SECTION_ICON, SECTION_ICON)
    row.Icon:SetPoint("LEFT", row, "TOPLEFT", PAD, -8)
    SetIcon(row.Icon, opts)
    x = PAD + SECTION_ICON + 5
  end
  row.Header = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  row.Header:SetPoint("LEFT", row, "TOPLEFT", x, -8)
  row.Header:SetText(text or "")
  -- count: a grey number after the title, read on every refresh ("Kept items (12)")
  if opts.count then
    row.Count = DescText(row)
    row.Count:SetPoint("LEFT", row.Header, "RIGHT", 6, 0)
    table.insert(window.refreshers, function()
      local ok, n = pcall(opts.count, window)
      row.Count:SetText((ok and type(n) == "number") and ("(" .. n .. ")") or "")
    end)
  end
  local c = U.Colors.DIVIDER_GRAY
  row.Divider = row:CreateTexture(nil, "ARTWORK")
  row.Divider:SetColorTexture(c[1], c[2], c[3], c[4])
  row.Divider:SetHeight(1)
  row.Divider:SetPoint("TOPLEFT", row, "TOPLEFT", PAD, -16)
  row.Divider:SetPoint("TOPRIGHT", row, "TOPRIGHT", -PAD, -16)
  -- switchKey: an on/off box at the header's right end, bound to that
  -- setting (the rows under it can follow it with enabledWhen)
  if opts.switchKey then self:Switch(row, opts.switchKey, opts.switchTooltip, -8) end
  -- subtitle: a grey line under the divider that wraps to the panel's width
  if opts.subtitle then self:Describe(row, { description = opts.subtitle }, PAD) end
  return row
end

-- Switch(row, key, tooltip, y): a checkbox at the row's right end, y below
-- its top, staging key
function Panel:Switch(row, key, tooltip, y)
  local window = self.window
  row.Switch = UI.CreateCheckbox(row, {
    size = 24, tooltip = tooltip,
    point = { "RIGHT", row, "TOPRIGHT", -(PAD + SCROLLBAR_ROOM) + 4, y },
    onChange = function(checked) window:StageEdit(key, checked) end,
  })
  self:Bind(key, function(value) row.Switch:SetChecked(value and true or false) end)
  return row.Switch
end

function Panel:Description(text, opts)
  local row = self:AddRow(ROW_H, opts)
  row.Text = DescText(row)
  row.Text:SetPoint("TOPLEFT", row, "TOPLEFT", PAD, -4)
  row.Reflow = function(width) row.Text:SetWidth(width - PAD * 2 - SCROLLBAR_ROOM) end
  row.Reflow(self.layout.contentWidth)
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
    onChange = function(checked) window:StageEdit(o.key, checked) end,
  })
  row.SetRowEnabled = function(enabled) row.Checkbox:SetEnabled(enabled) end
  self:Bind(o.key, function(value) row.Checkbox:SetChecked(value and true or false) end)
  self:Describe(row, o, PAD + (o.indent or 0) + 28)
  return row
end

function Panel:Input(o)
  local window = self.window
  local row = self:AddRow(ROW_H, o)
  local width = o.width or INPUT_W
  local indent = o.indent or 0
  -- unit = "gold": the gold coin after the box
  local unitRoom = o.unit == "gold" and 18 or 0
  local x = o.x or (self.layout.inputX(width) - unitRoom)
  -- icon / atlas: an icon before the label (a currency, an item)
  if o.icon or o.atlas then
    row.Icon = row:CreateTexture(nil, "ARTWORK")
    row.Icon:SetSize(18, 18)
    row.Icon:SetPoint("LEFT", row, "TOPLEFT", PAD + indent, -ROW_H / 2)
    SetIcon(row.Icon, o)
    indent = indent + 24
  end
  row.Label = self:Label(row, o.label, o.tooltip, PAD + indent, x - PAD - indent - 8)
  if o.labelColor then Color(row.Label, o.labelColor) end
  -- Without an x the input stays at the row's right edge, and its label
  -- takes the room left of it
  local point = { "LEFT", row, "TOPLEFT", x, -ROW_H / 2 }
  if not o.x then
    point = { "RIGHT", row, "TOPRIGHT", -(PAD + SCROLLBAR_ROOM + unitRoom), -ROW_H / 2 }
    row.Reflow = function(rowWidth)
      row.Label:SetWidth(rowWidth - width - unitRoom - PAD - SCROLLBAR_ROOM - PAD - indent - 8)
    end
  end

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
    point = point,
    parse = function(text)
      text = strtrim(text)
      local current = window:Get(o.key)
      if current ~= nil and text == format(current) then return current end
      return parse(text)
    end,
    validate = function(value)
      local config = window:ConfigFor(o.key)
      if config and config.CheckValue and not config.CheckValue(o.key, value) then return false end
      if o.validate and not o.validate(value) then return false end
      return true
    end,
    format = format,
    onCommit = function(value) window:StageEdit(o.key, value) end,
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
  if unitRoom > 0 then
    row.Unit = row:CreateTexture(nil, "ARTWORK")
    row.Unit:SetSize(14, 14)
    row.Unit:SetPoint("LEFT", row.Input, "RIGHT", 4, 0)
    row.Unit:SetAtlas(STYLE.goldAtlas)
  end
  row.SetRowEnabled = function(enabled)
    row.Input:SetEnabled(enabled)
    SetLabelEnabled(row.Label, enabled)
    -- a disabled box keeps its text color: a locked value greys with its label
    SetLabelEnabled(row.Input, enabled)
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
  self:Describe(row, o, PAD + indent)
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
      window:StageEdit(o.key, value)
    end,
  })
  row.Reflow = function(width) row.Slider:SetWidth(width - PAD * 2 - SCROLLBAR_ROOM) end
  row.SetRowEnabled = function(enabled)
    row.Slider:SetEnabled(enabled)
    SetLabelEnabled(row.Label, enabled)
  end
  -- A saved value off the bar (outside min..max, or between its steps) shows
  -- as it is, "Custom: 25s", with the thumb at the nearest end; painting it
  -- stages nothing, so it stays saved until the player moves the bar
  local max, step = o.max or 100, o.step or 1
  local function OffBar(v)
    if v < min or v > max then return true end
    local steps = (v - min) / step
    return math.abs(steps - math.floor(steps + 0.5)) > 1e-6
  end
  self:Bind(o.key, function(value)
    local v = value
    if not U.IsFiniteNumber(v) then v = min end
    row.Slider:SetValue(v)
    if v == value and OffBar(v) then
      row.Value:SetText(o.customText and o.customText(v) or ("Custom: " .. format(v)))
    else
      row.Value:SetText(format(v))
    end
  end)
  -- minLabel / maxLabel: grey words under the bar's two ends ("Instant", "Slow")
  if o.minLabel or o.maxLabel then
    row:SetHeight(row:GetHeight() + 12)
    row.MinLabel = DescText(row)
    row.MinLabel:SetPoint("TOPLEFT", row.Slider, "BOTTOMLEFT", 0, -1)
    row.MinLabel:SetText(o.minLabel or "")
    row.MaxLabel = DescText(row)
    row.MaxLabel:SetPoint("TOPRIGHT", row.Slider, "BOTTOMRIGHT", 0, -1)
    row.MaxLabel:SetText(o.maxLabel or "")
  end
  self:Describe(row, o, PAD)
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
      point = { "RIGHT", row, "TOPRIGHT", -(PAD + SCROLLBAR_ROOM), -(ROW_H + 4) / 2 },
      labels = o.labels, values = o.values, tooltips = o.tooltips,
      onValueChanged = function(value) window:StageEdit(o.key, value) end,
    })
    row.Reflow = function(rowWidth)
      row.Label:SetWidth(rowWidth - width - PAD - SCROLLBAR_ROOM - PAD - 8)
    end
  else
    row = self:AddRow(46, o)
    row.Dropdown = UI.CreateDropDown(row, {
      label = o.label or false,
      width = o.width or (self.layout.contentWidth - PAD * 2 - SCROLLBAR_ROOM),
      point = { "TOPLEFT", row, "TOPLEFT", PAD, -4 },
      labels = o.labels, values = o.values, tooltips = o.tooltips,
      onValueChanged = function(value) window:StageEdit(o.key, value) end,
    })
    row.Label = o.label and row.Dropdown.Label or nil
    if row.Label and o.tooltip then UI.AddTooltip(row.Label, o.tooltip, "ANCHOR_RIGHT") end
    -- A dropdown with no width of its own spans the row
    if not o.width then
      row.Reflow = function(rowWidth)
        local ddWidth = rowWidth - PAD * 2 - SCROLLBAR_ROOM
        row.Dropdown.DropDown:SetWidth(ddWidth)
        row.Dropdown:SetWidth(o.label and math.max(200, ddWidth) or ddWidth)
      end
    end
  end
  row.SetRowEnabled = function(enabled)
    row.Dropdown.DropDown:SetEnabled(enabled)
    SetLabelEnabled(row.Label, enabled)
  end
  -- A saved value that isn't on the list shows as an extra entry,
  -- "Custom: 5", or extraLabel(value)'s words ("5 days (your setting)"),
  -- never as a blank or the last label shown
  local extraLabel = o.extraLabel or function(value) return "Custom: " .. tostring(value) end
  local extended = false
  self:Bind(o.key, function(value)
    local onList = false
    for _, v in ipairs(o.values or {}) do
      if v == value then onList = true end
    end
    if not onList and value ~= nil then
      local labels, values = { unpack(o.labels or {}) }, { unpack(o.values or {}) }
      labels[#labels + 1] = extraLabel(value)
      values[#values + 1] = value
      row.Dropdown:InitAgain(labels, values, o.tooltips)
      extended = true
    elseif extended then
      row.Dropdown:InitAgain(o.labels, o.values, o.tooltips)
      extended = false
    end
    row.Dropdown:SetValue(value)
  end)
  self:Describe(row, o, PAD)
  return row
end

-- Radio{ inline = true, label, labelWidth (140) }: the options side by side
-- on one line after the label
local function InlineRadio(panel, o)
  local window = panel.window
  local row = panel:AddRow(ROW_H + 4, o)
  local indent = o.indent or 0
  local y = -(ROW_H + 4) / 2
  local x = PAD + indent
  if o.label then
    row.Label = panel:Label(row, o.label, o.tooltip, x, (o.labelWidth or 140) - 8)
    row.Label:ClearAllPoints()
    row.Label:SetPoint("LEFT", row, "TOPLEFT", x, y)
    x = x + (o.labelWidth or 140)
  end
  row.Buttons = {}
  local function Check(value)
    for _, entry in ipairs(row.Buttons) do entry.button:SetChecked(entry.value == value) end
  end
  for i, option in ipairs(o.options or {}) do
    local button = UI.CreateRadioButton(row, {
      label = option.label, tooltip = option.tooltip or o.tooltip,
      point = { "LEFT", row, "TOPLEFT", x, y },
      onChange = function()
        Check(option.value)
        window:StageEdit(o.key, option.value)
      end,
    })
    row.Buttons[i] = { value = option.value, button = button }
    x = x + 20 + math.ceil(button.text:GetStringWidth()) + 16
  end
  row.SetRowEnabled = function(enabled)
    for _, entry in ipairs(row.Buttons) do entry.button:SetEnabled(enabled) end
    SetLabelEnabled(row.Label, enabled)
  end
  panel:Bind(o.key, Check)
  panel:Describe(row, o, PAD + indent)
  return row
end

function Panel:Radio(o)
  if o.inline then return InlineRadio(self, o) end
  local window = self.window
  local options = o.options or {}
  -- an option with a description takes a second, grey line under its label
  local height = 0
  for _, option in ipairs(options) do
    height = height + RADIO_H + (option.description and RADIO_NOTE_H or 0)
  end
  local row = self:AddRow(math.max(RADIO_H, height), o)
  row.Buttons = {}
  local function Check(value)
    for _, entry in ipairs(row.Buttons) do
      entry.button:SetChecked(entry.value == value)
    end
  end
  local x = PAD + (o.indent or 0)
  for i, option in ipairs(options) do
    local button = UI.CreateRadioButton(row, {
      label = option.label,
      tooltip = option.tooltip or o.tooltip,
      onChange = function()
        Check(option.value)
        window:StageEdit(o.key, option.value)
      end,
    })
    row.Buttons[i] = { value = option.value, button = button }
    if option.description then
      local note = DescText(row)
      note:SetJustifyH("LEFT")
      note:SetWordWrap(true)
      note:SetText(option.description)
      row.Buttons[i].note = note
    end
  end
  -- Each option's line, then its description wrapped under it
  local function Place()
    local y = 0
    for _, entry in ipairs(row.Buttons) do
      entry.button:ClearAllPoints()
      entry.button:SetPoint("LEFT", row, "TOPLEFT", x, -(y + RADIO_H / 2))
      y = y + RADIO_H
      if entry.note then
        entry.note:ClearAllPoints()
        entry.note:SetPoint("TOPLEFT", row, "TOPLEFT", x + 20, -(y - 2))
        y = y + math.max(RADIO_NOTE_H, math.ceil(entry.note:GetStringHeight()) + 2)
      end
    end
    return math.max(RADIO_H, y)
  end
  row.Reflow = function(width)
    for _, entry in ipairs(row.Buttons) do
      if entry.note then entry.note:SetWidth(width - x - 20 - PAD - SCROLLBAR_ROOM) end
    end
  end
  row.Reflow(self.layout.contentWidth)
  row:SetHeight(Place())
  row.Measure = function() row:SetHeight(Place()) end
  row.SetRowEnabled = function(enabled)
    for _, entry in ipairs(row.Buttons) do
      entry.button:SetEnabled(enabled)
      if entry.note then entry.note:SetAlpha(enabled and 1 or 0.5) end
    end
  end
  self:Bind(o.key, Check)
  self:Describe(row, o, x)
  return row
end

local MODIFIER_KEYS = { LSHIFT = true, RSHIFT = true, LCTRL = true, RCTRL = true, LALT = true, RALT = true }
-- A click's binding names, as the game's binding code converts them
-- (BindingUtil's GetConvertedKeyOrButton)
local MOUSE_BUTTONS = { LeftButton = "BUTTON1", RightButton = "BUTTON2", MiddleButton = "BUTTON3",
  Button4 = "BUTTON4", Button5 = "BUTTON5" }

-- The key with the modifiers held now, in the order this row has always saved
local function Chord(key)
  return (IsShiftKeyDown() and "SHIFT-" or "") .. (IsControlKeyDown() and "CTRL-" or "")
    .. (IsAltKeyDown() and "ALT-" or "") .. key
end

-- Keyboard capture and combat (the taint rules, "Keyboard capture is fixed
-- for the rest of combat"): EnableKeyboard is protected, so every
-- capture ends as combat starts (PLAYER_REGEN_DISABLED runs before the
-- lockdown), and a button whose keyboard could not be let go in combat lets
-- it go when combat ends. Made at load.
local captures, heldKeyboards = {}, {}
local captureCombatFrame = CreateFrame("Frame")
captureCombatFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
captureCombatFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
captureCombatFrame:SetScript("OnEvent", function(_, event)
  if event == "PLAYER_REGEN_DISABLED" then
    for stop in pairs(captures) do stop() end
  else
    for button in pairs(heldKeyboards) do
      button:SetPropagateKeyboardInput(true)
      button:EnableKeyboard(false)
    end
    wipe(heldKeyboards)
  end
end)

-- Lets go of a capture button's keyboard, now or after combat
local function ReleaseKeyboard(button)
  if InCombatLockdown() then
    heldKeyboards[button] = true
  else
    button:EnableKeyboard(false)
  end
end

function Panel:Keybind(o)
  local window = self.window
  local row = self:AddRow(ROW_H + 4, o)
  local indent = o.indent or 0
  -- Clear sits at the row's right edge and the capture button left of it;
  -- the label takes the room left of both
  local function CaptureX(rowWidth)
    return rowWidth - PAD - SCROLLBAR_ROOM - 60 - 6 - 130
  end
  row.Label = self:Label(row, o.label, o.tooltip, PAD + indent, CaptureX(self.layout.contentWidth) - PAD - indent - 8)
  row.Label:ClearAllPoints()
  row.Label:SetPoint("LEFT", row, "TOPLEFT", PAD + indent, -(ROW_H + 4) / 2)
  row.Reflow = function(rowWidth)
    row.Label:SetWidth(CaptureX(rowWidth) - PAD - indent - 8)
  end

  -- "Alt+W", "Alt+Left Click": as the addons word keys elsewhere (U.FormatKeyText)
  local function Text(value)
    if not value then return "Not Set" end
    return U.FormatKeyText(value)
  end

  row.Clear = UI.CreateButton(row, {
    size = { 60, 22 }, text = "Clear",
    point = { "RIGHT", row, "TOPRIGHT", -(PAD + SCROLLBAR_ROOM), -(ROW_H + 4) / 2 },
  })
  row.Capture = UI.CreateButton(row, {
    size = { 130, 24 }, text = "Not Set", tooltip = o.tooltip,
    point = { "RIGHT", row.Clear, "LEFT", -6, 0 },
  })
  local capture = row.Capture

  local StopCapture
  StopCapture = function()
    if not capture.capturing then return end
    capture.capturing = false
    captures[StopCapture] = nil
    capture:SetScript("OnKeyDown", nil)
    ReleaseKeyboard(capture)
    capture:SetText(Text(window:Get(o.key)))
  end

  local function Captured(binding)
    StopCapture()
    window:StageEdit(o.key, binding)
    capture:SetText(Text(binding))
  end

  capture:SetScript("OnClick", function(self)
    -- the release of the Left click just captured is not a new capture
    if self.swallowClick then
      self.swallowClick = nil
      return
    end
    if self.capturing or InCombatLockdown() then return end
    self.capturing = true
    captures[StopCapture] = true
    heldKeyboards[self] = nil
    self:SetText(o.mouse and "Press a key or click" or "Press a key...")
    self:EnableKeyboard(true)
    self:SetScript("OnKeyDown", function(button, key)
      if not InCombatLockdown() then button:SetPropagateKeyboardInput(false) end
      if MODIFIER_KEYS[key] then return end   -- keep waiting for the real key
      if key == "ESCAPE" then
        StopCapture()
        return
      end
      Captured(Chord(key))
    end)
  end)
  capture:SetScript("OnHide", StopCapture)
  -- A click while capturing (hooked: the template's own OnMouseDown draws the
  -- pressed look). A plain Left or Right click is every click, so those need
  -- a modifier.
  if o.mouse then
    capture:HookScript("OnMouseDown", function(button, mouseButton)
      if not button.capturing then return end
      local key = MOUSE_BUTTONS[mouseButton]
      if not key then return end
      if (key == "BUTTON1" or key == "BUTTON2") and not IsModifierKeyDown() then return end
      if mouseButton == "LeftButton" then button.swallowClick = true end
      Captured(Chord(key))
    end)
  end

  row.Clear:SetScript("OnClick", function()
    StopCapture()
    window:StageEdit(o.key, nil)
    capture:SetText(Text(window:Get(o.key)))
  end)

  row.SetRowEnabled = function(enabled)
    capture:SetEnabled(enabled)
    row.Clear:SetEnabled(enabled)
    SetLabelEnabled(row.Label, enabled)
  end
  self:Bind(o.key, function(value)
    if not capture.capturing then capture:SetText(Text(value)) end
  end, StopCapture)
  self:Describe(row, o, PAD + indent)
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
  -- The box's text, staged when it is a valid value, and the rows repainted
  local function StageDraft(text)
    local folded = Fold(text or "")
    if Valid(folded) then
      window:StageEdit(o.key, folded)
    elseif window.pending[o.key] ~= nil then
      window:Unstage(o.key)
    elseif not window.syncing then
      window:Refresh()
    end
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
    onCommit = function(text) window:StageEdit(o.key, text) end,
    -- Every keystroke stages, so Apply is ready without leaving the box; text
    -- that is not a valid value is simply not staged. The rows repaint on
    -- every keystroke either way, so a preview or a note reading the draft
    -- (row:GetDraft()) follows it.
    onChange = function(text) StageDraft(text) end,
  })
  -- The box's text now, folded as staging folds it (valid or not)
  row.GetDraft = function() return Fold(row.Box.EditBox:GetText() or "") end
  -- Escape, and leaving a box whose text is not valid, put the last text
  -- back without a user edit; stage what the box then shows, so Apply never
  -- saves text the box no longer holds
  local function StageShown()
    local folded = Fold(row.Box.EditBox:GetText())
    if Valid(folded) then
      window:StageEdit(o.key, folded)
    else
      window:Unstage(o.key)
    end
  end
  -- The box spans the row; its text area is 18 narrower, as the factory
  -- builds it
  row.Reflow = function(width)
    local boxWidth = width - PAD * 2 - SCROLLBAR_ROOM
    row.Box:SetWidth(boxWidth)
    row.Box.EditBox:SetWidth(boxWidth - 18)
    if row.Box.EditBox.Instructions then row.Box.EditBox.Instructions:SetWidth(boxWidth - 18) end
  end
  row.Box.EditBox:HookScript("OnEscapePressed", StageShown)
  row.Box.EditBox:HookScript("OnEditFocusLost", StageShown)
  -- tokens = { { text, label, tooltip } }: chips under the box that put
  -- their text in at the cursor, while it fits in maxBytes
  if o.tokens then
    row:SetHeight(row:GetHeight() + 26)
    row.Tokens = {}
    local previous
    for i, token in ipairs(o.tokens) do
      local label = token.label or token.text
      local chip = UI.CreateButton(row, { text = label, size = { 20, 20 }, fontSize = 10, tooltip = token.tooltip,
        point = previous and { "LEFT", previous, "RIGHT", 6, 0 } or { "TOPLEFT", row.Box, "BOTTOMLEFT", 0, -4 },
        onClick = function()
          local box = row.Box.EditBox
          local text = box:GetText() or ""
          if o.maxBytes and #text + #token.text > o.maxBytes then return end
          box:SetFocus()
          box:Insert(token.text)
          -- text put in from code is no user change to the box: stage it here
          StageDraft(box:GetText())
        end })
      chip:SetWidth(math.ceil(chip:GetFontString():GetStringWidth()) + 18)
      -- a click area larger than the chip: halfway into the gaps around it
      chip:SetHitRectInsets(-3, -3, -4, -4)
      row.Tokens[i] = chip
      previous = chip
    end
  end
  self:Bind(o.key, function(value) row.Box:SetCommittedValue(value) end, function()
    if row.Box.EditBox:HasFocus() then row.Box.EditBox:ClearFocus() end
  end)
  self:Describe(row, o, PAD + 4)
  return row
end

function Panel:Button(o)
  local window = self.window
  local row = self:AddRow(ROW_H + 4, o)
  row.Button = UI.CreateButton(row, {
    size = { o.width or 220, 22 }, text = type(o.text) == "function" and "" or o.text, tooltip = o.tooltip,
    point = { "LEFT", row, "TOPLEFT", PAD + (o.indent or 0), -(ROW_H + 4) / 2 },
    onClick = function()
      if o.onClick then o.onClick(window) end
      -- an action changes what the page shows (a count, a status)
      window:Refresh()
    end,
  })
  -- text and enabled (live): read on every repaint; enabled and enabledWhen
  -- must both allow a click
  local rowEnabled = true
  local function PaintButton()
    if type(o.text) == "function" then row.Button:SetText(Live(o.text, window) or "") end
    local on = rowEnabled
    if o.enabled ~= nil and not Live(o.enabled, window) then on = false end
    row.Button:SetEnabled(on)
    if row.Icon then row.Icon:SetDesaturated(not on) end
  end
  if type(o.text) == "function" or o.enabled ~= nil then table.insert(window.refreshers, PaintButton) end
  -- immediate: the action is not staged, and the line under it says so
  if o.immediate then
    local own = o.description
    o = setmetatable({ description = function(w)
      local text = Live(own, w)
      if text and text ~= "" then return text .. " " .. IMMEDIATE_TEXT end
      return IMMEDIATE_TEXT
    end }, { __index = o })
  end
  -- icon / atlas: a small icon before the label
  if o.icon or o.atlas then
    row.Icon = row.Button:CreateTexture(nil, "OVERLAY")
    row.Icon:SetSize(14, 14)
    row.Icon:SetPoint("LEFT", row.Button, "LEFT", 8, 0)
    SetIcon(row.Icon, o)
    local text = row.Button:GetFontString()
    text:ClearAllPoints()
    text:SetPoint("CENTER", row.Button, "CENTER", 9, 0)
  end
  row.SetRowEnabled = function(enabled)
    rowEnabled = enabled
    PaintButton()
  end
  self:Describe(row, o, PAD + (o.indent or 0))
  return row
end

function Panel:Custom(o)
  local window = self.window
  local row = self:AddRow(o.height or ROW_H, o)
  if o.keys then
    for _, key in ipairs(o.keys) do
      window.keys[key] = true
      if self.config ~= nil then window.keyConfig[key] = self.config end
      if self.noDefaults then window.noDefaults[key] = true end
    end
  end
  if o.build then o.build(row, window, self.layout) end
  return row
end

---------------------------------------------------------------------------
-- Tiles: cards in a grid, each with an icon (or a keycap word), a title, a
-- line and a mark in its top-right corner. Four kinds share the look:
-- Tiles (choose one), ToggleTiles (each its own on/off setting),
-- StatusTiles (read only: found or not) and ActionTiles (each runs an action).
---------------------------------------------------------------------------

-- A hover tooltip the Verify tooltip grid can fill too (UI.FillTooltipFor,
-- Cobanyte: every tooltip covered): fill(tip, frame) writes only to tip and
-- returns false when there is nothing to show, and then a hover shows none
local function FillableHover(frame, fill)
  UI.AddDynamicTooltip(frame, fill, { fillable = true })
  frame:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    if fill(GameTooltip, self) == false then
      GameTooltip:Hide()
      return
    end
    GameTooltip:Show()
  end)
end

-- A tile's tooltip: its option's text (live)
local function TileTipFill(tip, tile)
  local text = tile.option and Live(tile.option.tooltip, tile.window)
  if text == nil or text == "" then return false end
  tip:SetText(text, 1, 1, 1, 1, true)
end

-- One tile's frames, made once; FillTile puts an option's content in them
local function CreateTile(parent, height, kind)
  local tile = CreateFrame("Button", nil, parent)
  tile:SetHeight(height)
  tile.kind = kind
  tile.Card = tile:CreateTexture(nil, "BACKGROUND")
  tile.Card:SetAllPoints()
  tile.Card:SetAtlas(STYLE.tileAtlas)
  local gold = U.Colors.STATUS_GOLD
  tile.Tint = tile:CreateTexture(nil, "BORDER")
  tile.Tint:SetAllPoints()
  tile.Tint:SetColorTexture(gold[1], gold[2], gold[3], 0.12)
  tile.Tint:Hide()
  AddEdges(tile, "ARTWORK")
  tile:SetEdgeColor(U.Colors.DIVIDER_GRAY)
  -- a read-only tile has no hover: nothing about it can be clicked
  if kind ~= "status" then
    tile.Hover = tile:CreateTexture(nil, "HIGHLIGHT")
    tile.Hover:SetAllPoints()
    tile.Hover:SetAtlas(STYLE.tileHoverAtlas)
    tile.Hover:SetBlendMode("ADD")
    tile.Hover:SetAlpha(0.5)
  end

  -- a keycap: a word on a small dark key with a light edge
  local face = CreateFrame("Frame", nil, tile)
  face:SetSize(44, 26)
  local bg = face:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  local c = U.Colors.DIALOG_BG
  bg:SetColorTexture(c[1], c[2], c[3], 1)
  AddEdges(face, "BORDER")
  face:SetEdgeColor(U.Colors.LABEL_GRAY, 0.8)
  face.Text = face:CreateFontString(nil, "OVERLAY", U.Fonts.BODY)
  face.Text:SetPoint("CENTER")
  tile.Face = face
  -- an icon, with a count on it like a buff's stacks
  tile.Icon = tile:CreateTexture(nil, "ARTWORK")
  tile.Icon:SetSize(TILE_ICON, TILE_ICON)
  tile.Count = tile:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
  tile.Count:SetPoint("BOTTOMRIGHT", tile.Icon, "BOTTOMRIGHT", 1, 0)

  tile.Title = tile:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  tile.Title:SetPoint("RIGHT", tile, "RIGHT", -28, 0)
  tile.Title:SetJustifyH("LEFT")
  tile.Title:SetWordWrap(false)
  tile.Text = tile:CreateFontString(nil, "OVERLAY", U.Fonts.DATA)
  tile.Text:SetPoint("TOPLEFT", tile.Title, "BOTTOMLEFT", 0, -3)
  tile.Text:SetPoint("RIGHT", tile, "RIGHT", -10, 0)
  tile.Text:SetJustifyH("LEFT")
  tile.Text:SetJustifyV("TOP")
  tile.Text:SetWordWrap(true)
  tile.Badge = DescText(tile)
  tile.Badge:SetPoint("BOTTOMRIGHT", -8, 6)

  -- the corner mark: a radio circle and dot, a checkbox and check (a lock
  -- on a locked toggle), a status mark, or an action's arrow
  tile.Mark = tile:CreateTexture(nil, "OVERLAY")
  tile.Mark:SetSize(16, 16)
  tile.Mark:SetPoint("TOPRIGHT", -7, -7)
  tile.Check = tile:CreateTexture(nil, "OVERLAY", nil, 1)
  tile.Check:SetPoint("CENTER", tile.Mark)
  tile.Check:SetSize(16, 16)
  if kind == "radio" then
    tile.Mark:SetAtlas(STYLE.radioAtlas)
    tile.Check:SetAtlas(STYLE.radioDotAtlas)
  elseif kind == "check" then
    tile.Mark:SetAtlas(STYLE.checkboxAtlas)
    tile.Check:SetSize(18, 18)
    tile.Check:SetAtlas(STYLE.checkAtlas)
  elseif kind == "action" then
    -- an action goes somewhere: an arrow, never a selection mark
    tile.Mark:SetAtlas(STYLE.actionAtlas)
  else
    tile.Mark:Hide()
  end
  -- a status tile's state word, left of its mark ("Talented", "Missing")
  if kind == "status" then
    tile.State = tile:CreateFontString(nil, "OVERLAY", U.Fonts.DATA)
    tile.State:SetPoint("RIGHT", tile.Mark, "LEFT", -4, 0)
    tile.State:SetJustifyH("RIGHT")
  end
  tile.Check:Hide()
  -- a status dot, colored by the option's dot
  tile.Dot = tile:CreateTexture(nil, "OVERLAY")
  tile.Dot:SetSize(10, 10)
  tile.Dot:SetAtlas(STYLE.radioDotAtlas)
  tile.Dot:Hide()
  -- the preview's frame, made here: the first paint may come in combat
  tile.Preview = CreateFrame("Frame", nil, tile)
  tile.Preview:SetPoint("BOTTOMLEFT", 10, 8)
  tile.Preview:SetPoint("BOTTOMRIGHT", -10, 8)
  tile.Preview:Hide()

  FillableHover(tile, TileTipFill)
  return tile
end

-- FillTile(tile, opt, window): the option's face or icon, title, line,
-- count, badge, dot and dim or warning state, read now (every field may be a
-- function of the window); the preview is drawn the first time
local function FillTile(tile, opt, window)
  tile.option, tile.window = opt, window
  local face, icon = Live(opt.face, window), nil
  if not face then
    local iconValue, atlas = Live(opt.icon, window), Live(opt.atlas, window)
    if iconValue or atlas then icon = { icon = iconValue, atlas = atlas } end
  end
  local top = opt.preview ~= nil
  tile.Face:SetShown(face ~= nil)
  tile.Icon:SetShown(icon ~= nil)
  local textX = 12
  if face then
    tile.Face.Text:SetText(face)
    tile.Face:ClearAllPoints()
    tile.Face:SetPoint(top and "TOPLEFT" or "LEFT", 10, top and -10 or 0)
    textX = 10 + 44 + 10
  elseif icon then
    SetIcon(tile.Icon, icon)
    tile.Icon:ClearAllPoints()
    tile.Icon:SetPoint(top and "TOPLEFT" or "LEFT", 10, top and -10 or 0)
    textX = 10 + TILE_ICON + 10
  end
  tile.Count:SetShown(icon ~= nil)
  tile.Count:SetText(icon and Live(opt.count, window) or "")
  tile.Title:ClearAllPoints()
  tile.Title:SetPoint("TOPLEFT", tile, "TOPLEFT", textX, -9)
  tile.Title:SetPoint("RIGHT", tile, "RIGHT", -28, 0)
  tile.Title:SetText(Live(opt.title, window) or "")
  tile.Text:SetText(Live(opt.description, window) or "")
  tile.Badge:SetText(Live(opt.badge, window) or "")

  local dot = Live(opt.dot, window)
  tile.Dot:SetShown(type(dot) == "table")
  if type(dot) == "table" then
    tile.Dot:ClearAllPoints()
    tile.Dot:SetPoint("RIGHT", tile.Mark, tile.Mark:IsShown() and "LEFT" or "RIGHT", tile.Mark:IsShown() and -4 or 0, 0)
    tile.Dot:SetVertexColor(dot[1], dot[2], dot[3])
  end

  -- a preview the addon draws once per tile with its own textures under the
  -- text (its first option's); previewPaint(frame, selected, window) runs on
  -- every repaint
  tile.Preview:SetShown(opt.preview ~= nil)
  if opt.preview and not tile.previewDrawn then
    tile.previewDrawn = true
    tile.Preview:SetHeight(opt.previewHeight or 24)
    opt.preview(tile.Preview, { height = opt.previewHeight or 24 })
  end
  -- the text keeps its natural height, and the grid makes the tile tall
  -- enough for it (TileHeight): a line is never cut off
  tile.textX = textX
  tile.Text:ClearAllPoints()
  tile.Text:SetPoint("TOPLEFT", tile.Title, "BOTTOMLEFT", 0, -3)
  local width = tile:GetWidth()
  if type(width) == "number" and width > 0 then tile.Text:SetWidth(width - textX - 10) end

  local warn = Live(opt.warn, window)
  local title = warn and U.Colors.WARNING_RED or U.Colors.STATUS_GOLD
  tile.Title:SetTextColor(title[1], title[2], title[3])
  local light = U.Colors.LIGHT_GRAY
  tile.Text:SetTextColor(light[1], light[2], light[3])
  tile.dim = Live(opt.dim, window) and true or false
  tile.warn = warn and true or false
  tile.Icon:SetDesaturated(tile.dim)
end

-- The height tile needs for its title, its wrapped text, its preview and
-- its badge, and at least the grid's own tile height
local function TileHeight(tile, minimum)
  local text = tile.Text:GetText()
  local need = 9 + math.ceil(tile.Title:GetStringHeight())
  if text and text ~= "" then need = need + 3 + math.ceil(tile.Text:GetStringHeight()) end
  if tile.Preview:IsShown() then need = need + 4 + (tile.Preview:GetHeight() or 0) + 8 end
  local badge = tile.Badge:GetText()
  need = need + ((badge and badge ~= "") and 18 or 8)
  return math.max(minimum, need)
end

-- on: the tile's chosen or checked look (a warning keeps its red edge)
local function PaintTile(tile, on)
  tile.on = on
  tile.Tint:SetShown(on)
  if tile.warn then
    tile:SetEdgeColor(U.Colors.WARNING_RED, 0.8)
  else
    tile:SetEdgeColor(on and U.Colors.STATUS_GOLD or U.Colors.DIVIDER_GRAY, on and 0.9 or nil)
  end
  tile.Check:SetShown(on)
  if tile.Preview:IsShown() and tile.option and tile.option.previewPaint then
    tile.option.previewPaint(tile.Preview, on, tile.window)
  end
end

-- A disabled row fades every tile; a dim tile is half faded on its own
local function SetTileEnabled(tile, enabled)
  tile:SetEnabled(enabled and not (tile.option and tile.option.locked))
  tile:SetAlpha(enabled and (tile.dim and 0.6 or 1) or 0.4)
end

-- The columns that fit width: o.columns while each tile keeps minWidth,
-- else fewer, as evenly filled as the same number of lines allows (four
-- tiles that can't sit four across go two by two, not three and one)
local function FitColumns(columns, count, room, minWidth)
  local fit = math.max(1, math.floor((room + TILE_GAP) / (minWidth + TILE_GAP)))
  if fit >= columns then return columns end
  local lines = math.ceil(math.max(count, 1) / fit)
  local c = fit
  while c > 1 and math.ceil(count / (c - 1)) == lines do c = c - 1 end
  return c
end

-- The grid every tile row is: o.columns (default 2, or fewer options) tiles
-- across the panel's width, o.height (TILE_H) at least, each line of tiles as
-- tall as its tallest (a long description makes its tile grow; text is
-- never cut off), wrapping to fewer
-- columns when a tile would be narrower than o.minTileWidth (TILE_MIN_W).
-- o.options is a list, or a function(get, window) giving it on every repaint
-- (then o.maxTiles tiles are made at build, never later, since a repaint may
-- come in combat; the row is as tall as the tiles it shows).
local function TileGrid(panel, o, kind, paint)
  local window = panel.window
  local live = type(o.options) == "function"
  local count = live and (o.maxTiles or 6) or #(o.options or {})
  local wanted = math.max(1, o.columns or math.min(math.max(count, 1), 2))
  local columns = wanted
  local height = o.height or TILE_H
  local function RowHeight(n)
    local lines = math.max(1, math.ceil(n / columns))
    return lines * (height + TILE_GAP) - TILE_GAP + 4
  end
  local row = panel:AddRow(RowHeight(count), o)
  local x = PAD + (o.indent or 0)
  row.Tiles = {}
  for i = 1, count do row.Tiles[i] = CreateTile(row, height, kind) end
  row.Reflow = function(width)
    local room = width - x - PAD - SCROLLBAR_ROOM
    columns = FitColumns(wanted, count, room, o.minTileWidth or TILE_MIN_W)
    row.columns = columns
    local tileWidth = (room - (columns - 1) * TILE_GAP) / columns
    for i, tile in ipairs(row.Tiles) do
      local column, line = (i - 1) % columns, math.floor((i - 1) / columns)
      tile:ClearAllPoints()
      tile:SetPoint("TOPLEFT", row, "TOPLEFT", x + column * (tileWidth + TILE_GAP), -2 - line * (height + TILE_GAP))
      tile:SetWidth(tileWidth)
      tile.Text:SetWidth(tileWidth - (tile.textX or 12) - 10)
    end
  end
  row.Reflow(panel.layout.contentWidth)
  local shown = count
  local enabled = true
  -- every repaint and staged change: the options, then the row's own paint
  table.insert(window.refreshers, function()
    local options = o.options
    if live then
      local ok, list = pcall(o.options, window.getter, window)
      options = (ok and type(list) == "table") and list or {}
    end
    shown = 0
    for i, tile in ipairs(row.Tiles) do
      local opt = options[i]
      tile:SetShown(opt ~= nil)
      if opt then
        FillTile(tile, opt, window)
        SetTileEnabled(tile, enabled)
        shown = i
      end
    end
    paint(row)
  end)
  -- each line as tall as its tallest tile, the lines stacked from the top
  row.Measure = function()
    local width = row.Tiles[1] and row.Tiles[1]:GetWidth() or 0
    local y = 2
    for first = 1, math.max(shown, 1), columns do
      local lineH = height
      for i = first, math.min(first + columns - 1, shown) do
        lineH = math.max(lineH, TileHeight(row.Tiles[i], height))
      end
      for i = first, math.min(first + columns - 1, #row.Tiles) do
        local tile = row.Tiles[i]
        local column = (i - 1) % columns
        tile:ClearAllPoints()
        tile:SetPoint("TOPLEFT", row, "TOPLEFT", x + column * (width + TILE_GAP), -y)
        tile:SetHeight(lineH)
      end
      y = y + lineH + TILE_GAP
    end
    row:SetHeight(y - TILE_GAP + 4)
  end
  row.SetRowEnabled = function(on)
    enabled = on
    for _, tile in ipairs(row.Tiles) do SetTileEnabled(tile, on) end
  end
  return row
end

-- Tiles{ key or get/onSelect, options, columns, height, maxTiles, indent }:
-- choose one. An option: { value, title, description, icon/atlas or face,
-- count, badge, dot, dim, warn, tooltip, preview(frame, layout), previewHeight,
-- previewPaint(frame, selected, window) }; a value may be any type, booleans
-- included
function Panel:Tiles(o)
  local window = self.window
  local function Current()
    if o.key then return window:Get(o.key) end
    return Live(o.get, window)
  end
  local row
  local function Paint(value)
    for _, tile in ipairs(row.Tiles) do
      PaintTile(tile, tile:IsShown() and value ~= nil and tile.option ~= nil and tile.option.value == value)
    end
  end
  row = TileGrid(self, o, "radio", function() Paint(Current()) end)
  for _, tile in ipairs(row.Tiles) do
    tile:SetScript("OnClick", function()
      local value = tile.option and tile.option.value
      if value == nil then return end
      if o.key then
        Paint(value)
        window:StageEdit(o.key, value)
      elseif o.onSelect and Current() ~= value then
        o.onSelect(value, window)
        Paint(Current())
      end
    end)
  end
  if o.key then self:Bind(o.key, Paint) end
  self:Describe(row, o, PAD + (o.indent or 0))
  return row
end

-- ToggleTiles{ options, columns, height, indent }: each tile its own on/off
-- setting. An option: { key, locked (always on), and a Tiles option's fields }
function Panel:ToggleTiles(o)
  local window = self.window
  -- every key the tiles bind, so Defaults, Cancel and outside changes reach
  -- them; a live list binds the keys it gives at build and any it adds later
  local panel, bound = self, {}
  local function BindOptions(list)
    for _, opt in ipairs(list) do
      if opt.key and not opt.locked and not bound[opt.key] then
        bound[opt.key] = true
        panel:Bind(opt.key, function() end)
      end
    end
  end
  local row = TileGrid(self, o, "check", function(grid)
    for _, tile in ipairs(grid.Tiles) do
      local opt = tile.option
      if opt then
        BindOptions({ opt })
        -- locked: always on, a lock in place of the check, "Always included"
        -- and no hover, so nothing suggests it could change
        local locked = opt.locked and true or false
        tile.Mark:SetAtlas(locked and STYLE.lockAtlas or STYLE.checkboxAtlas)
        tile.Hover:SetShown(not locked)
        PaintTile(tile, locked or (window:Get(opt.key) and true or false))
        if locked then
          tile.Check:Hide()
          if (tile.Badge:GetText() or "") == "" then tile.Badge:SetText(ALWAYS_INCLUDED_TEXT) end
        end
      end
    end
  end)
  for _, tile in ipairs(row.Tiles) do
    tile:SetScript("OnClick", function()
      local opt = tile.option
      if not opt or opt.locked then return end
      local on = not tile.on
      PaintTile(tile, on)
      window:StageEdit(opt.key, on)
    end)
  end
  if type(o.options) == "function" then
    local ok, list = pcall(o.options, window.getter, window)
    if ok and type(list) == "table" then BindOptions(list) end
  elseif type(o.options) == "table" then
    BindOptions(o.options)
  end
  self:Describe(row, o, PAD + (o.indent or 0))
  return row
end

-- Paints a state's mark (a texture) and word (a font string), both hidden
-- for no state; returns the state's look
local function PaintState(mark, word, state, text)
  local look = STATES[state]
  mark:SetShown(look ~= nil)
  word:SetShown(look ~= nil)
  if not look then return nil end
  mark:SetAtlas(look.atlas)
  -- the green check is tinted; the other marks keep their own colors
  local tint = state == "ok" and look.color or U.Colors.HIGHLIGHT_WHITE
  mark:SetVertexColor(tint[1], tint[2], tint[3])
  word:SetText(text or look.word)
  Color(word, look.color)
  return look
end

-- StatusTiles{ options, columns, height }: read only, no hover and no
-- selection look. An option: { state (live): "ok" (a green check), "off" (a
-- red cross and a grey title), "warn" (an amber warning), "unknown" (a grey
-- question mark: not loaded, not found); stateText (live): the word beside
-- the mark ("Talented", "Missing", "Checking"), since color only reinforces
-- it; and a Tiles option's fields }
function Panel:StatusTiles(o)
  local window = self.window
  local gray = U.Colors.DISABLED_GRAY
  local row = TileGrid(self, o, "status", function(grid)
    for _, tile in ipairs(grid.Tiles) do
      local opt = tile.option
      if opt then
        local state = Live(opt.state, window)
        PaintState(tile.Check, tile.State, state, Live(opt.stateText, window))
        tile.Title:SetPoint("RIGHT", tile.State, "LEFT", -6, 0)
        if state == "off" then tile.Title:SetTextColor(gray[1], gray[2], gray[3]) end
      end
    end
  end)
  self:Describe(row, o, PAD + (o.indent or 0))
  return row
end

-- ActionTiles{ options, columns, height }: each tile runs an action at once
-- (nothing staged). An option: { onClick(window), and a Tiles option's fields }
function Panel:ActionTiles(o)
  local window = self.window
  local row = TileGrid(self, o, "action", function(grid)
    for _, tile in ipairs(grid.Tiles) do PaintTile(tile, false) end
  end)
  for _, tile in ipairs(row.Tiles) do
    tile:SetScript("OnClick", function()
      local opt = tile.option
      if opt and opt.onClick then
        opt.onClick(window)
        window:RefreshState()
      end
    end)
  end
  self:Describe(row, o, PAD + (o.indent or 0))
  return row
end

---------------------------------------------------------------------------
-- Cards: BeginCard{ title, description, icon/atlas, dot, switchKey, switchTooltip, visibleWhen } then
-- any rows, then EndCard(); the rows sit in one bordered card under its
-- header and show only while the card does
---------------------------------------------------------------------------
local CARD_HEAD_H = 40

function Panel:BeginCard(o)
  assert(not self.card, "BeginCard: a card is already open")
  local window = self.window
  local head = self:AddRow(CARD_HEAD_H, o, SECTION_GAP)
  self.card = { visibleWhen = o.visibleWhen, head = head }
  local bg = CreateFrame("Frame", nil, self.content)
  bg:SetFrameLevel(self.content:GetFrameLevel())
  bg.Card = bg:CreateTexture(nil, "BACKGROUND")
  bg.Card:SetAllPoints()
  bg.Card:SetAtlas(STYLE.tileAtlas)
  AddEdges(bg, "BORDER")
  bg:SetEdgeColor(U.Colors.DIVIDER_GRAY)
  head.CardBg = bg
  head:HookScript("OnShow", function() bg:Show() end)
  head:HookScript("OnHide", function() bg:Hide() end)

  local x = PAD
  if o.icon or o.atlas then
    head.Icon = head:CreateTexture(nil, "ARTWORK")
    head.Icon:SetSize(24, 24)
    head.Icon:SetPoint("TOPLEFT", head, "TOPLEFT", PAD, -(CARD_HEAD_H - 24) / 2)
    SetIcon(head.Icon, o)
    x = PAD + 24 + 8
  end
  head.Title = head:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  head.Title:SetPoint("TOPLEFT", head, "TOPLEFT", x, -7)
  head.Title:SetJustifyH("LEFT")
  head.Title:SetWordWrap(false)
  -- the description wraps; the header grows to fit it
  head.Text = DescText(head)
  head.Text:SetPoint("TOPLEFT", head.Title, "BOTTOMLEFT", 0, -3)
  head.Text:SetJustifyH("LEFT")
  head.Text:SetWordWrap(true)
  local right = o.switchKey and 40 or 16
  head.Reflow = function(width)
    head.Text:SetWidth(width - x - PAD - SCROLLBAR_ROOM - right)
  end
  head.Reflow(self.layout.contentWidth)
  head.Measure = function()
    local text = head.Text:GetText()
    local textH = (text and text ~= "") and (3 + math.ceil(head.Text:GetStringHeight())) or 0
    head:SetHeight(math.max(CARD_HEAD_H, 7 + math.ceil(head.Title:GetStringHeight()) + textH + 8))
  end
  if o.dot then
    head.Dot = head:CreateTexture(nil, "OVERLAY")
    head.Dot:SetSize(10, 10)
    head.Dot:SetPoint("LEFT", head.Title, "RIGHT", 6, 0)
    head.Dot:SetAtlas(STYLE.radioDotAtlas)
  end
  if o.switchKey then self:Switch(head, o.switchKey, o.switchTooltip, -CARD_HEAD_H / 2) end
  table.insert(window.refreshers, function()
    head.Title:SetText(Live(o.title, window) or "")
    head.Text:SetText(Live(o.description, window) or "")
    if head.Dot then
      local c = Live(o.dot, window)
      head.Dot:SetShown(type(c) == "table")
      if type(c) == "table" then head.Dot:SetVertexColor(c[1], c[2], c[3]) end
    end
  end)
  return head
end

function Panel:EndCard()
  local card = assert(self.card, "EndCard: no card is open")
  local foot = self:AddRow(8)
  self.card = nil
  local bg = card.head.CardBg
  bg:SetPoint("TOPLEFT", card.head, "TOPLEFT", PAD - 8, 0)
  bg:SetPoint("BOTTOMRIGHT", foot, "BOTTOMRIGHT", -(PAD + SCROLLBAR_ROOM) + 8, 0)
  return foot
end

---------------------------------------------------------------------------
-- Note{ text (live), icon/atlas, color, indent }: a line with an icon; with
-- a color it is a callout (a tinted strip and an edge in it). A Note whose
-- text is empty takes no room.
-- Notice{ kind (live): "info" (neutral), "warn" (amber: a limitation) or
-- "error" (red: invalid input, a failure), text (live), recovery (live: the
-- step that fixes it, on a line of its own), icon/atlas, indent }: the same
-- callout with the kind's icon and color, beside the control it is about
---------------------------------------------------------------------------
local NOTICE_KINDS = {
  info  = { color = U.Colors.INFO_BLUE, text = U.Colors.LIGHT_GRAY, icon = STYLE.infoIcon },
  warn  = { color = U.Colors.CAUTION_ORANGE, atlas = STYLE.warnAtlas },
  error = { color = U.Colors.WARNING_RED, atlas = STYLE.errorAtlas },
}

local function Callout(panel, o, kinded)
  local window = panel.window
  local row = panel:AddRow(ROW_H, o)
  local x = PAD + (o.indent or 0)
  local strip = o.color or kinded
  local textX = x + (strip and 8 or 0)
  if strip then
    row.Strip = row:CreateTexture(nil, "BACKGROUND")
    row.Strip:SetPoint("TOPLEFT", row, "TOPLEFT", x, -2)
    row.Strip:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -(PAD + SCROLLBAR_ROOM), 2)
    row.Edge = row:CreateTexture(nil, "BORDER")
    row.Edge:SetPoint("TOPLEFT", row.Strip, "TOPLEFT")
    row.Edge:SetPoint("BOTTOMLEFT", row.Strip, "BOTTOMLEFT")
    row.Edge:SetWidth(2)
  end
  if o.icon or o.atlas or kinded then
    row.Icon = row:CreateTexture(nil, "ARTWORK")
    row.Icon:SetSize(16, 16)
    row.Icon:SetPoint("TOPLEFT", row, "TOPLEFT", textX, -5)
    if o.icon or o.atlas then SetIcon(row.Icon, o) end
    textX = textX + 22
  end
  row.Text = row:CreateFontString(nil, "OVERLAY", U.Fonts.DATA)
  row.Text:SetPoint("TOPLEFT", row, "TOPLEFT", textX, -7)
  row.Text:SetJustifyH("LEFT")
  row.Text:SetWordWrap(true)
  local function Paint(c, textColor)
    if row.Strip then
      row.Strip:SetColorTexture(c[1], c[2], c[3], 0.08)
      row.Edge:SetColorTexture(c[1], c[2], c[3], 0.9)
    end
    local t = textColor or c
    row.Text:SetTextColor(t[1], t[2], t[3])
  end
  if o.color then Paint(o.color) end
  row.Reflow = function(width) row.Text:SetWidth(width - textX - PAD - SCROLLBAR_ROOM - 8) end
  row.Reflow(panel.layout.contentWidth)
  row.Measure = function()
    row:SetHeight(math.max(ROW_H, math.ceil(row.Text:GetStringHeight()) + 14))
  end
  row.Collapsed = function() return (row.Text:GetText() or "") == "" end
  table.insert(window.refreshers, function()
    local text = Live(o.text, window) or ""
    if kinded then
      local recovery = Live(o.recovery, window)
      if text ~= "" and recovery and recovery ~= "" then text = text .. "\n" .. recovery end
      local kind = NOTICE_KINDS[Live(o.kind, window) or "info"] or NOTICE_KINDS.info
      Paint(kind.color, kind.text)
      if not (o.icon or o.atlas) then
        if kind.atlas then row.Icon:SetAtlas(kind.atlas) else row.Icon:SetTexture(kind.icon) end
        row.Icon:SetTexCoord(0, 1, 0, 1)
      end
    end
    row.Text:SetText(text)
  end)
  return row
end

function Panel:Note(o)
  return Callout(self, o, false)
end

function Panel:Notice(o)
  return Callout(self, o, true)
end

---------------------------------------------------------------------------
-- Bullets{ items, maxItems, indent }: an icon per item, a gold heading and
-- white lines under it. items is a list of { title, lines = { ... },
-- icon/atlas } (title and lines live), or a function(window) giving it on
-- every repaint (then maxItems, default 6, are made at build: text a
-- provider registers after the window is built).
---------------------------------------------------------------------------
function Panel:Bullets(o)
  local window = self.window
  local row = self:AddRow(ROW_H, o)
  local x = PAD + (o.indent or 0)
  local live = type(o.items) == "function"
  local count = live and (o.maxItems or 6) or #(o.items or {})
  row.Items = {}
  for i = 1, count do
    local item = {}
    item.Icon = row:CreateTexture(nil, "ARTWORK")
    item.Icon:SetSize(20, 20)
    item.Title = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    item.Title:SetJustifyH("LEFT")
    item.Text = row:CreateFontString(nil, "OVERLAY", U.Fonts.DATA)
    item.Text:SetJustifyH("LEFT")
    item.Text:SetWordWrap(true)
    row.Items[i] = item
  end
  local shown = 0
  local function Fill()
    local defs = o.items
    if live then
      local ok, list = pcall(o.items, window)
      defs = (ok and type(list) == "table") and list or {}
    end
    shown = 0
    for i, item in ipairs(row.Items) do
      local def = defs[i]
      item.Icon:SetShown(def ~= nil and (def.icon or def.atlas) ~= nil)
      item.Title:SetShown(def ~= nil)
      item.Text:SetShown(def ~= nil)
      if def then
        if def.icon or def.atlas then SetIcon(item.Icon, def) end
        item.Title:SetText(Live(def.title, window) or "")
        local lines = Live(def.lines, window)
        item.Text:SetText(type(lines) == "table" and table.concat(lines, "\n") or (lines or ""))
        shown = i
      end
    end
  end
  Fill()
  table.insert(window.refreshers, Fill)
  row.Reflow = function(width)
    for _, item in ipairs(row.Items) do
      item.Title:SetWidth(width - x - 28 - PAD - SCROLLBAR_ROOM)
      item.Text:SetWidth(width - x - 28 - PAD - SCROLLBAR_ROOM)
    end
  end
  row.Reflow(self.layout.contentWidth)
  row.Measure = function()
    local y = 4
    for i = 1, shown do
      local item = row.Items[i]
      item.Icon:ClearAllPoints()
      item.Icon:SetPoint("TOPLEFT", row, "TOPLEFT", x, -y)
      item.Title:ClearAllPoints()
      item.Title:SetPoint("TOPLEFT", row, "TOPLEFT", x + 28, -(y + 3))
      item.Text:ClearAllPoints()
      item.Text:SetPoint("TOPLEFT", item.Title, "BOTTOMLEFT", 0, -3)
      y = y + 3 + math.ceil(item.Title:GetStringHeight()) + 3 + math.ceil(item.Text:GetStringHeight()) + 10
    end
    row:SetHeight(math.max(ROW_H, y))
  end
  row.Collapsed = function() return shown == 0 end
  return row
end

-- Runs paint every seconds seconds while frame shows, on a timer that runs
-- only then (never a per-frame script)
local function TickWhileShown(frame, seconds, paint)
  local ticker
  frame:HookScript("OnShow", function()
    if ticker then ticker:Cancel() end
    ticker = C_Timer.NewTicker(seconds, paint)
  end)
  frame:HookScript("OnHide", function()
    if ticker then ticker:Cancel() end
    ticker = nil
  end)
end

---------------------------------------------------------------------------
-- Preview{ caption (live), text (live) and color (live), or height,
--   build(frame, window) and refresh(frame, window); ticker (seconds),
--   dimWhen(get), action = { text, onClick(window), tooltip, width } }: a
-- framed, inset example that follows the staged values (it repaints on every
-- stage, never per frame). Label a passive example caption = "Example": it
-- shows the staged choices and changes nothing live. With text it is a
-- wrapped line in color (a chat line in its chat type's color) sized to the
-- text; otherwise the addon draws into the frame (build runs once, at
-- build). action puts a button at the caption line's right end for
-- something that happens only on that click ("Play sample", "Send test to
-- myself"). ticker repaints it every that many seconds while it shows (a
-- status that changes with no setting); dimWhen fades it (its feature is off).
---------------------------------------------------------------------------
function Panel:Preview(o)
  local window = self.window
  local x = PAD + (o.indent or 0)
  local captionH = o.action and 24 or (o.caption and 16 or 0)
  -- A Preview's refresh paints its box (Paint below), never the row: AddRow
  -- gets the options without it, or it would run refresh(row) as well
  -- (Task #70: Recollect's refresh errored on the row, 2026-10-01)
  local row = self:AddRow((o.height or ROW_H) + captionH + 8, setmetatable({ refresh = false }, { __index = o }))
  if o.caption then
    row.Caption = DescText(row)
    row.Caption:SetPoint("LEFT", row, "TOPLEFT", x, -captionH / 2)
    if type(o.caption) ~= "function" then row.Caption:SetText(o.caption) end
  end
  if o.action then
    local action = o.action
    row.Action = UI.CreateButton(row, {
      size = { action.width or 140, 20 }, text = action.text, tooltip = action.tooltip,
      point = { "TOPRIGHT", row, "TOPRIGHT", -(PAD + SCROLLBAR_ROOM), -1 },
      onClick = function() if action.onClick then action.onClick(window) end end,
    })
  end
  -- The box takes its own height from the row's top: a description under it
  -- grows the row, never the box (it drew the note inside the box, 2026-10-01)
  local box = CreateFrame("Frame", nil, row)
  box:SetPoint("TOPLEFT", row, "TOPLEFT", x, -(captionH + 2))
  box:SetPoint("TOPRIGHT", row, "TOPRIGHT", -(PAD + SCROLLBAR_ROOM), -(captionH + 2))
  box:SetHeight((o.height or ROW_H) + 2)
  box.Bg = box:CreateTexture(nil, "BACKGROUND")
  box.Bg:SetAllPoints()
  local c = U.Colors.CONTENT_BG
  box.Bg:SetColorTexture(c[1], c[2], c[3], 0.55)
  AddEdges(box, "BORDER")
  box:SetEdgeColor(U.Colors.CONTENT_BORDER, 0.6)
  row.Box = box
  if o.text then
    box.Text = box:CreateFontString(nil, "OVERLAY", "ChatFontNormal")
    box.Text:SetPoint("TOPLEFT", 8, -6)
    box.Text:SetJustifyH("LEFT")
    box.Text:SetWordWrap(true)
    row.Reflow = function(width) box.Text:SetWidth(width - x - PAD - SCROLLBAR_ROOM - 16) end
    row.Reflow(self.layout.contentWidth)
    row.Measure = function()
      local h = math.max(ROW_H, math.ceil(box.Text:GetStringHeight()) + 12)
      box:SetHeight(h + 2)
      row:SetHeight(h + captionH + 8)
    end
  elseif o.build then
    o.build(box, window)
  end
  local function Paint()
    if type(o.caption) == "function" then row.Caption:SetText(Live(o.caption, window) or "") end
    if box.Text then
      box.Text:SetText(Live(o.text, window) or "")
      local color = Live(o.color, window)
      if type(color) == "table" then box.Text:SetTextColor(color[1], color[2], color[3]) end
    end
    if o.refresh then pcall(o.refresh, box, window) end
    if o.dimWhen then box:SetAlpha(o.dimWhen(window.getter) and 0.4 or 1) end
  end
  table.insert(window.refreshers, Paint)
  if o.ticker then TickWhileShown(box, o.ticker, Paint) end
  row.SetRowEnabled = function(enabled)
    if row.Action then row.Action:SetEnabled(enabled) end
  end
  self:Describe(row, o, x)
  return row
end

---------------------------------------------------------------------------
-- StatusCard{ icon/atlas (live), state (live), stateText (live), title
--   (live), description (live), actions = { { text (live), onClick(window),
--   enabled (live), tooltip (live), width } }, ticker (seconds), indent }: what is
-- happening now, read only. A card with an icon, a gold title, a state mark
-- and word at its top right ("ok", "off", "warn", "unknown" as StatusTiles;
-- color only reinforces the word), a wrapped explanation and a line of
-- buttons (the first the main one). It has no hover and no selection look,
-- so it never reads as a setting; an enable checkbox goes in its own row
-- outside it. Its buttons act at once and stage nothing. ticker repaints it
-- every that many seconds while it shows; row.Refresh() repaints it now.
-- Built on UI.CreateStatusCard (below), the same card outside a settings
-- window.
---------------------------------------------------------------------------
local CARD_ICON, CARD_PAD = 32, 10

-- UI.CreateStatusCard(parent, o): the StatusCard for any frame (Task #114).
-- o: the StatusCard fields above, and context (what live fields and an
-- action's onClick receive), afterAction() (after an action ran; default:
-- the card repaints), onHeight(height) (when the card's height changed) and
-- deferPaint (no paint at build, show or resize: the caller calls Refresh; the settings kit's, whose
-- SavedVariables may not be loaded at build). Anchor it with a width (two
-- points or SetWidth); it sets its own height. card:Refresh() repaints and
-- measures; card:Paint(), card:Measure() -> height, card:Reflow(width) and
-- card:SetCardEnabled(on) are the parts. card.Icon, Mark, State, Title,
-- Text and Buttons are its regions.
function UI.CreateStatusCard(parent, o)
  local ctx = o.context
  local textX = CARD_PAD + CARD_ICON + CARD_PAD
  local card = CreateFrame("Frame", nil, parent)
  card:SetHeight(CARD_ICON + CARD_PAD * 2)
  card.Bg = card:CreateTexture(nil, "BACKGROUND")
  card.Bg:SetAllPoints()
  card.Bg:SetAtlas(STYLE.tileAtlas)
  AddEdges(card, "BORDER")
  card:SetEdgeColor(U.Colors.DIVIDER_GRAY)

  card.Icon = card:CreateTexture(nil, "ARTWORK")
  card.Icon:SetSize(CARD_ICON, CARD_ICON)
  card.Icon:SetPoint("TOPLEFT", CARD_PAD, -CARD_PAD)
  card.Mark = card:CreateTexture(nil, "OVERLAY")
  card.Mark:SetSize(16, 16)
  card.Mark:SetPoint("TOPRIGHT", -CARD_PAD, -CARD_PAD + 1)
  card.State = card:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  card.State:SetPoint("RIGHT", card.Mark, "LEFT", -4, 0)
  card.State:SetJustifyH("RIGHT")
  card.Title = card:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  card.Title:SetPoint("TOPLEFT", textX, -CARD_PAD - 2)
  card.Title:SetPoint("RIGHT", card.State, "LEFT", -8, 0)
  card.Title:SetJustifyH("LEFT")
  card.Title:SetWordWrap(false)
  card.Text = DescText(card)
  card.Text:SetPoint("TOPLEFT", card.Title, "BOTTOMLEFT", 0, -4)
  card.Text:SetJustifyH("LEFT")
  card.Text:SetWordWrap(true)

  card.Buttons = {}
  for i, action in ipairs(o.actions or {}) do
    card.Buttons[i] = UI.CreateButton(card, {
      size = { action.width or 120, 22 }, text = type(action.text) == "function" and "" or action.text,
      tooltip = type(action.tooltip) ~= "function" and action.tooltip or nil,
      onClick = function()
        if action.onClick then action.onClick(ctx) end
        if o.afterAction then o.afterAction() else card:Refresh() end
      end,
    })
    -- a live tooltip, read at each hover, for a button whose text changes
    if type(action.tooltip) == "function" then
      UI.AddDynamicTooltip(card.Buttons[i], function(tip)
        tip:SetText(Live(action.tooltip, ctx) or "", 1, 1, 1, 1, true)
      end, { fillable = true })
    end
  end

  local enabled = true
  function card:Paint()
    local iconValue, atlas = Live(o.icon, ctx), Live(o.atlas, ctx)
    self.Icon:SetShown(iconValue ~= nil or atlas ~= nil)
    if iconValue or atlas then SetIcon(self.Icon, { icon = iconValue, atlas = atlas }) end
    PaintState(self.Mark, self.State, Live(o.state, ctx), Live(o.stateText, ctx))
    self.Title:SetText(Live(o.title, ctx) or "")
    self.Text:SetText(Live(o.description, ctx) or "")
    for i, action in ipairs(o.actions or {}) do
      local button = self.Buttons[i]
      if type(action.text) == "function" then button:SetText(Live(action.text, ctx) or "") end
      if not action.width then
        button:SetWidth(math.max(90, math.ceil(button:GetFontString():GetStringWidth()) + 28))
      end
      local on = enabled
      if action.enabled ~= nil and not Live(action.enabled, ctx) then on = false end
      button:SetEnabled(on)
    end
  end

  -- The height its title, wrapped text and buttons need; it takes it
  function card:Measure()
    local text = self.Text:GetText()
    local y = CARD_PAD + 2 + math.ceil(self.Title:GetStringHeight())
    if text and text ~= "" then y = y + 4 + math.ceil(self.Text:GetStringHeight()) end
    y = math.max(y, CARD_PAD + CARD_ICON)
    local bx = textX
    for _, button in ipairs(self.Buttons) do
      button:ClearAllPoints()
      button:SetPoint("TOPLEFT", self, "TOPLEFT", bx, -(y + 8))
      bx = bx + button:GetWidth() + 8
    end
    if #self.Buttons > 0 then y = y + 8 + 22 end
    local height = y + CARD_PAD
    if height ~= self:GetHeight() then
      self:SetHeight(height)
      if o.onHeight then o.onHeight(height) end
    end
    return height
  end

  function card:Reflow(width)
    self.Text:SetWidth(width - textX - CARD_PAD)
  end

  function card:Refresh()
    self:Paint()
    self:Measure()
  end

  function card:SetCardEnabled(on)
    enabled = on and true or false
    self:Paint()
  end

  if not o.deferPaint then
    card:SetScript("OnSizeChanged", function(self, width)
      if width and width > 0 then
        self:Reflow(width)
        self:Measure()
      end
    end)
    card:HookScript("OnShow", function(self) self:Refresh() end)
    if o.ticker then TickWhileShown(card, o.ticker, function() card:Refresh() end) end
    card:Refresh()
  end
  return card
end

function Panel:StatusCard(o)
  local window = self.window
  local panel = self
  local x = PAD + (o.indent or 0)
  local row = self:AddRow(CARD_ICON + CARD_PAD * 2 + 4, o, o.gap)
  local spec = {}
  for k, v in pairs(o) do spec[k] = v end
  spec.context, spec.deferPaint, spec.ticker, spec.onHeight = window, true, nil, nil
  spec.afterAction = function() window:Refresh() end
  local card = UI.CreateStatusCard(row, spec)
  card:SetPoint("TOPLEFT", row, "TOPLEFT", x, -2)
  card:SetPoint("TOPRIGHT", row, "TOPRIGHT", -(PAD + SCROLLBAR_ROOM), -2)
  row.Card = card
  row.Buttons = card.Buttons

  row.Reflow = function(width)
    card:Reflow(width - x - PAD - SCROLLBAR_ROOM)
  end
  row.Reflow(self.layout.contentWidth)
  table.insert(window.refreshers, function() card:Paint() end)
  row.Measure = function()
    row:SetHeight(card:Measure() + 4)
  end
  row.SetRowEnabled = function(enabled)
    card:SetCardEnabled(enabled)
  end

  -- A repaint outside the window's own (a timer, the addon's event): the
  -- panel lays out again only when the card's height changed
  row.Refresh = function()
    if not window:IsShown() then return end
    local before = row:GetHeight()
    card:Paint()
    row.Measure()
    if row:GetHeight() ~= before then panel:Layout() end
  end
  if o.ticker then TickWhileShown(card, o.ticker, row.Refresh) end
  return row
end

---------------------------------------------------------------------------
-- UI.CreateStatTiles(parent, o): a grid of read-only stat tiles for any
-- frame (Task #114), in the settings kit's tile look: the kit's card, edge,
-- icon and fonts, a number first. Replaces the hand-made tiles of Verify's
-- banner, Loot Sweeper's overview and Recollect's curator dashboard.
--
--   local grid = CobySuite.UI.CreateStatTiles(parent, {
--     tiles = { tile, ... } or function(context) return { tile, ... } end,
--     maxTiles = 8,          -- tiles made at build when tiles is a function (never later: a repaint may come in combat)
--     columns = 3,           -- wanted; fewer when a tile would be narrower than minTileWidth
--     minTileWidth = 100, height = 50,   -- each line is as tall as its tallest tile, at least height
--     context = anything,    -- what every live field receives
--     selected = key or function(context),  -- the tile drawn chosen (a gold tint and edge)
--     onClick = function(key, context) end, -- tiles become buttons with a hover; the grid repaints after
--     onHeight = function(height) end,      -- when the grid's height changed
--   })
--   A tile: { key, icon or atlas (live), value (live: the number or word, in
--   the large font, the body font when the large one doesn't fit), label
--   (live: the line under it, wrapping), labelShort (live: used instead when
--   the label doesn't fit one line), labelColor (live; default gray), color
--   (live: the value's color table; default gold), accent (live: the tile's
--   own color, for its picked tint and edge and a line along its bottom,
--   faint until picked; default gold, no line), tooltip (live text) or
--   tooltipFill(tip, context) (writes only to tip; return false for none),
--   bar (live: 0 to 1, a thin share bar under the label), barColor, dim
--   (live: faded), state and stateText (live: a mark and word at the top
--   right, as StatusTiles) }
--
-- Anchor it with a width; it sets its own height and lays itself out again
-- when its width changes. grid:Refresh() repaints every live field;
-- grid.Tiles holds the tile frames. Tile tooltips are fillable, so the
-- Verify tooltip grid can show them.
---------------------------------------------------------------------------
local STAT_H, STAT_BAR = 50, 4

local function StatTipFill(tip, tile, ctx)
  local t = tile.stat
  if not t then return false end
  if t.tooltipFill then return t.tooltipFill(tip, ctx) end
  local text = Live(t.tooltip, ctx)
  if text == nil or text == "" then return false end
  tip:SetText(text, 1, 1, 1, 1, true)
end

local function CreateStatTile(grid, height, clickable, ctx)
  local tile = CreateTile(grid, height, clickable and "stat" or "status")
  tile.Title:SetFontObject(U.Fonts.TITLE)
  if not tile.State then
    tile.State = tile:CreateFontString(nil, "OVERLAY", U.Fonts.DATA)
    tile.State:SetPoint("RIGHT", tile.Mark, "LEFT", -4, 0)
    tile.State:SetJustifyH("RIGHT")
  end
  tile.BarTrack = tile:CreateTexture(nil, "ARTWORK")
  tile.BarTrack:SetHeight(STAT_BAR)
  local track = U.Colors.BAR_BG
  tile.BarTrack:SetColorTexture(track[1], track[2], track[3], track[4] or 0.8)
  tile.BarFill = tile:CreateTexture(nil, "OVERLAY")
  tile.BarFill:SetHeight(STAT_BAR)
  tile.BarFill:SetPoint("TOPLEFT", tile.BarTrack, "TOPLEFT")
  tile.BarTrack:Hide()
  tile.BarFill:Hide()
  tile.Accent = tile:CreateTexture(nil, "OVERLAY")
  tile.Accent:SetPoint("BOTTOMLEFT", 1, 1)
  tile.Accent:SetPoint("BOTTOMRIGHT", -1, 1)
  tile.Accent:SetHeight(2)
  tile.Accent:Hide()
  FillableHover(tile, function(tip, owner) return StatTipFill(tip, owner or tile, ctx) end)
  return tile
end

function UI.CreateStatTiles(parent, o)
  local ctx = o.context
  local live = type(o.tiles) == "function"
  local count = live and (o.maxTiles or 8) or #(o.tiles or {})
  local wanted = math.max(1, o.columns or 3)
  local height = o.height or STAT_H
  local grid = CreateFrame("Frame", nil, parent)
  grid:SetHeight(height)
  grid.Tiles = {}
  for i = 1, count do
    local tile = CreateStatTile(grid, height, o.onClick ~= nil, ctx)
    if o.onClick then
      tile:SetScript("OnClick", function(self)
        if self.stat and self.stat.key ~= nil then o.onClick(self.stat.key, ctx) end
        grid:Refresh()
      end)
    end
    grid.Tiles[i] = tile
  end
  local shown = 0

  -- columns, widths, each line as tall as its tallest tile (a bar adds room)
  function grid:Layout(width)
    width = width or self:GetWidth() or 0
    if width <= 0 then return end
    local columns = FitColumns(wanted, math.max(shown, 1), width, o.minTileWidth or TILE_MIN_W)
    self.columns = columns
    local tileWidth = (width - (columns - 1) * TILE_GAP) / columns
    local y = 0
    for first = 1, math.max(shown, 1), columns do
      local lineH = height
      for i = first, math.min(first + columns - 1, shown) do
        local tile = self.Tiles[i]
        tile:SetWidth(tileWidth)
        local textRoom = tileWidth - (tile.textX or 12) - 10
        tile.Text:SetWidth(textRoom)
        -- the value in the large font when it fits, else the body font; the
        -- label's short form when the full one would wrap (Loot Sweeper's five tiles)
        local titleRoom = tileWidth - (tile.textX or 12) - (tile.hasState and (28 + tile.State:GetStringWidth() + 6) or 10)
        tile.Title:SetFontObject(U.Fonts.TITLE)
        if tile.Title:GetUnboundedStringWidth() > titleRoom then tile.Title:SetFontObject(U.Fonts.BODY) end
        Color(tile.Title, tile.titleColor)
        tile.Text:SetText(tile.labelFull or "")
        if tile.labelShort and tile.Text:GetUnboundedStringWidth() > textRoom then tile.Text:SetText(tile.labelShort) end
        lineH = math.max(lineH, TileHeight(tile, height) + (tile.BarTrack:IsShown() and STAT_BAR + 4 or 0))
      end
      for i = first, math.min(first + columns - 1, shown) do
        local tile = self.Tiles[i]
        tile:ClearAllPoints()
        tile:SetPoint("TOPLEFT", self, "TOPLEFT", ((i - first) % columns) * (tileWidth + TILE_GAP), -y)
        tile:SetHeight(lineH)
        if tile.BarTrack:IsShown() then
          tile.BarTrack:ClearAllPoints()
          tile.BarTrack:SetPoint("BOTTOMLEFT", tile, "BOTTOMLEFT", tile.textX or 12, 7)
          tile.BarTrack:SetPoint("BOTTOMRIGHT", tile, "BOTTOMRIGHT", -10, 7)
          local room = tileWidth - (tile.textX or 12) - 10
          tile.BarFill:SetWidth(math.max(0.01, room * (tile.fraction or 0)))
        end
      end
      y = y + lineH + TILE_GAP
    end
    local total = math.max(height, y - TILE_GAP)
    if total ~= self:GetHeight() then
      self:SetHeight(total)
      if o.onHeight then o.onHeight(total) end
    end
  end

  function grid:Refresh()
    local list = o.tiles
    if live then
      local ok, value = pcall(o.tiles, ctx)
      list = (ok and type(value) == "table") and value or {}
    end
    local chosen = Live(o.selected, ctx)
    local gold, light = U.Colors.STATUS_GOLD, U.Colors.LABEL_GRAY
    shown = 0
    for i, tile in ipairs(self.Tiles) do
      local t = list and list[i]
      tile:SetShown(t ~= nil)
      if t then
        shown = i
        tile.stat = t
        FillTile(tile, { icon = t.icon, atlas = t.atlas, title = t.value, description = t.label, dim = t.dim }, ctx)
        local color = Live(t.color, ctx)
        tile.titleColor = type(color) == "table" and color or gold
        Color(tile.Title, tile.titleColor)
        local labelColor = Live(t.labelColor, ctx)
        Color(tile.Text, type(labelColor) == "table" and labelColor or light)
        tile.labelFull, tile.labelShort = tile.Text:GetText(), Live(t.labelShort, ctx)
        local state = Live(t.state, ctx)
        PaintState(tile.Check, tile.State, state, Live(t.stateText, ctx))
        tile.hasState = state ~= nil
        if state then
          tile.Title:SetPoint("RIGHT", tile.State, "LEFT", -6, 0)
        else
          tile.Title:SetPoint("RIGHT", tile, "RIGHT", -10, 0)
        end
        local fraction = tonumber((Live(t.bar, ctx)))
        tile.fraction = fraction and math.max(0, math.min(1, fraction)) or nil
        tile.BarTrack:SetShown(tile.fraction ~= nil)
        tile.BarFill:SetShown(tile.fraction ~= nil)
        local bar = t.barColor or gold
        tile.BarFill:SetColorTexture(bar[1], bar[2], bar[3], 1)
        local on = chosen ~= nil and t.key == chosen
        local accent = Live(t.accent, ctx)
        local mark = type(accent) == "table" and accent or gold
        tile.Tint:SetColorTexture(mark[1], mark[2], mark[3], 0.12)
        tile.Tint:SetShown(on)
        tile:SetEdgeColor(on and mark or U.Colors.DIVIDER_GRAY, on and 0.9 or nil)
        tile.Accent:SetShown(type(accent) == "table")
        if type(accent) == "table" then tile.Accent:SetColorTexture(accent[1], accent[2], accent[3], on and 1 or 0.25) end
        tile:SetAlpha(tile.dim and 0.6 or 1)
      end
    end
    self:Layout()
  end

  grid:SetScript("OnSizeChanged", function(self, width) self:Layout(width) end)
  grid:HookScript("OnShow", function(self) self:Refresh() end)
  grid:Refresh()
  return grid
end

---------------------------------------------------------------------------
-- EmptyState{ state (live): "empty" (Nothing saved), "nomatch" (No
--   matches), "loading" (Still loading) or "unavailable" (Unavailable);
--   title (live), text (live), icon/atlas, action = { text, onClick(window) },
--   indent }: what is empty, why it matters and one next step, in a soft
-- card. The title defaults to the state's words; say why in text. A List
-- shows the same card when it is empty or its search matches nothing.
---------------------------------------------------------------------------
local EMPTY_STATES = {
  empty       = { title = "Nothing saved", atlas = STYLE.emptyAtlas },
  nomatch     = { title = "No matches", atlas = STYLE.emptyAtlas },
  loading     = { title = "Still loading", atlas = STYLE.unknownAtlas },
  unavailable = { title = "Unavailable", atlas = STYLE.warnAtlas },
}

-- One empty-state card's frames (made at build)
local function CreateEmptyCard(parent, window)
  local empty = CreateFrame("Frame", nil, parent)
  empty:SetHeight(EMPTY_H - 6)
  empty.Bg = empty:CreateTexture(nil, "BACKGROUND")
  empty.Bg:SetAllPoints()
  local c = U.Colors.CONTENT_BG
  empty.Bg:SetColorTexture(c[1], c[2], c[3], c[4])
  AddEdges(empty, "BORDER")
  empty:SetEdgeColor(U.Colors.DIVIDER_GRAY, 0.4)
  empty.Icon = empty:CreateTexture(nil, "ARTWORK")
  empty.Icon:SetSize(28, 28)
  empty.Icon:SetPoint("TOPLEFT", 12, -12)
  empty.Title = empty:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  empty.Title:SetPoint("TOPLEFT", 50, -10)
  empty.Text = DescText(empty)
  empty.Text:SetPoint("TOPLEFT", empty.Title, "BOTTOMLEFT", 0, -3)
  empty.Text:SetPoint("RIGHT", empty, "RIGHT", -10, 0)
  empty.Text:SetJustifyH("LEFT")
  empty.Text:SetWordWrap(true)
  empty.Button = UI.CreateButton(empty, { size = { 130, 20 }, text = "",
    onClick = function()
      if empty.onAction then empty.onAction(window) end
      window:Refresh()
    end })
  empty.Button:SetPoint("TOPLEFT", empty.Text, "BOTTOMLEFT", 0, -6)
  return empty
end

-- Fills the card from def ({ state, title, text, icon/atlas, action }, its
-- fields live) and returns its height
local function FillEmptyCard(empty, def, window)
  local look = EMPTY_STATES[Live(def.state, window) or "empty"] or EMPTY_STATES.empty
  SetIcon(empty.Icon, (def.icon or def.atlas) and def or look)
  empty.Title:SetText(Live(def.title, window) or look.title)
  empty.Text:SetText(Live(def.text, window) or "")
  local action = def.action
  empty.Button:SetShown(action ~= nil)
  empty.onAction = action and action.onClick
  local height = 10 + math.ceil(empty.Title:GetStringHeight()) + 3 + math.ceil(empty.Text:GetStringHeight()) + 10
  if action then
    empty.Button:SetText(Live(action.text, window) or "")
    empty.Button:SetWidth(math.max(90, math.ceil(empty.Button:GetFontString():GetStringWidth()) + 28))
    height = height + 6 + 20
  end
  height = math.max(EMPTY_H - 6, height)
  empty:SetHeight(height)
  return height
end

function Panel:EmptyState(o)
  local window = self.window
  local x = PAD + (o.indent or 0)
  local row = self:AddRow(EMPTY_H, o)
  local empty = CreateEmptyCard(row, window)
  empty:SetPoint("TOPLEFT", row, "TOPLEFT", x, -2)
  empty:SetPoint("RIGHT", row, "RIGHT", -(PAD + SCROLLBAR_ROOM), 0)
  row.EmptyState = empty
  local height = EMPTY_H - 6
  table.insert(window.refreshers, function() height = FillEmptyCard(empty, o, window) end)
  row.Measure = function() row:SetHeight(height + 6) end
  return row
end

---------------------------------------------------------------------------
-- Value{ label, value(window), events = { ... } }: a label on the left and a
-- value on the right, read on every repaint and when one of the events fires
-- while the window shows (UPDATE_BINDINGS for a key binding)
---------------------------------------------------------------------------
function Panel:Value(o)
  local window = self.window
  local indent = o.indent or 0
  local row = self:AddRow(ROW_H, o)
  row.Label = self:Label(row, o.label, o.tooltip, PAD + indent)
  row.Value = row:CreateFontString(nil, "OVERLAY", U.Fonts.BODY)
  row.Value:SetPoint("RIGHT", row, "TOPRIGHT", -(PAD + SCROLLBAR_ROOM), -ROW_H / 2)
  row.Value:SetJustifyH("RIGHT")
  local function Paint() row.Value:SetText(Live(o.value, window) or "") end
  table.insert(window.refreshers, Paint)
  if o.events then
    for _, event in ipairs(o.events) do row:RegisterEvent(event) end
    row:SetScript("OnEvent", function() if window:IsShown() then Paint() end end)
  end
  row.SetRowEnabled = function(enabled) SetLabelEnabled(row.Label, enabled) end
  self:Describe(row, o, PAD + indent)
  return row
end

---------------------------------------------------------------------------
-- Meter{ label, value(window) -> used, max(window) or max, warnAt (0.75),
--   format(used, max) }: a thin bar with "N of M", green, then amber from
--   warnAt, then red when full or over
---------------------------------------------------------------------------
function Panel:Meter(o)
  local window = self.window
  local indent = o.indent or 0
  local row = self:AddRow(ROW_H + 10, o)
  row.Label = self:Label(row, o.label, o.tooltip, PAD + indent)
  row.Count = row:CreateFontString(nil, "OVERLAY", U.Fonts.DATA)
  row.Count:SetPoint("RIGHT", row, "TOPRIGHT", -(PAD + SCROLLBAR_ROOM), -ROW_H / 2)
  row.Track = row:CreateTexture(nil, "BACKGROUND")
  row.Track:SetPoint("TOPLEFT", row, "TOPLEFT", PAD + indent, -(ROW_H + 1))
  row.Track:SetPoint("TOPRIGHT", row, "TOPRIGHT", -(PAD + SCROLLBAR_ROOM), -(ROW_H + 1))
  row.Track:SetHeight(6)
  local bar = U.Colors.BAR_BG
  row.Track:SetColorTexture(bar[1], bar[2], bar[3], bar[4])
  row.Fill = row:CreateTexture(nil, "ARTWORK")
  row.Fill:SetPoint("TOPLEFT", row.Track, "TOPLEFT")
  row.Fill:SetHeight(6)
  local function Paint()
    local used = tonumber(Live(o.value, window)) or 0
    local max = tonumber(Live(o.max, window)) or 0
    local share = max > 0 and math.min(1, used / max) or 0
    local width = row.Track:GetWidth()
    if not width or width <= 0 then width = self.layout.contentWidth - PAD * 2 - SCROLLBAR_ROOM - indent end
    row.Fill:SetWidth(math.max(1, width * share))
    local c = (max > 0 and used >= max) and U.Colors.WARNING_RED
      or (max > 0 and used / max >= (o.warnAt or 0.75)) and U.Colors.CAUTION_ORANGE or U.Colors.SUCCESS_GREEN
    row.Fill:SetColorTexture(c[1], c[2], c[3], 0.9)
    row.Count:SetText(o.format and o.format(used, max) or ("%d of %d"):format(used, max))
  end
  table.insert(window.refreshers, Paint)
  self:Describe(row, o, PAD + indent)
  return row
end

---------------------------------------------------------------------------
-- Legend{ items = { { icon/atlas, color, label } } }: small swatches with a
-- short word each, side by side
---------------------------------------------------------------------------
function Panel:Legend(o)
  local row = self:AddRow(ROW_H, o)
  local x = PAD + (o.indent or 0)
  row.Items = {}
  for i, def in ipairs(o.items or {}) do
    local swatch = row:CreateTexture(nil, "ARTWORK")
    swatch:SetSize(14, 14)
    swatch:SetPoint("LEFT", row, "TOPLEFT", x, -ROW_H / 2)
    if def.icon or def.atlas then
      SetIcon(swatch, def)
      if def.color then swatch:SetVertexColor(def.color[1], def.color[2], def.color[3]) end
    elseif def.color then
      swatch:SetColorTexture(def.color[1], def.color[2], def.color[3], 1)
    end
    local label = row:CreateFontString(nil, "OVERLAY", U.Fonts.DATA)
    label:SetPoint("LEFT", swatch, "RIGHT", 5, 0)
    label:SetText(def.label or "")
    row.Items[i] = { swatch = swatch, label = label }
    x = x + 14 + 5 + math.ceil(label:GetStringWidth()) + 16
  end
  self:Describe(row, o, PAD + (o.indent or 0))
  return row
end

---------------------------------------------------------------------------
-- DropdownAction{ label, options(window) -> labels, values, detail(value, window),
--   buttonText, buttonTooltip, onClick(value, window), emptyText, width, buttonWidth }:
-- pick from a list the addon gives on every refresh, then act on it
---------------------------------------------------------------------------
function Panel:DropdownAction(o)
  local window = self.window
  local indent = o.indent or 0
  local lineH = ROW_H + 6
  local row = self:AddRow(lineH + (o.detail and 16 or 0), o)
  local ddWidth, buttonWidth = o.width or 200, o.buttonWidth or 140
  local y = -lineH / 2
  row.Button = UI.CreateButton(row, { size = { buttonWidth, 22 }, text = o.buttonText, tooltip = o.buttonTooltip,
    point = { "RIGHT", row, "TOPRIGHT", -(PAD + SCROLLBAR_ROOM), y } })
  local Detail
  row.Dropdown = UI.CreateDropDown(row, { label = false, width = ddWidth,
    point = { "RIGHT", row.Button, "LEFT", -8, 0 }, onValueChanged = function() Detail() end })
  row.Label = self:Label(row, o.label, o.tooltip, PAD + indent)
  row.Label:ClearAllPoints()
  row.Label:SetPoint("LEFT", row, "TOPLEFT", PAD + indent, y)
  row.Reflow = function(width)
    row.Label:SetWidth(width - buttonWidth - 8 - ddWidth - PAD - SCROLLBAR_ROOM - PAD - indent - 8)
  end
  row.Reflow(self.layout.contentWidth)
  if o.detail then
    row.Detail = DescText(row)
    row.Detail:SetPoint("TOPLEFT", row.Dropdown, "BOTTOMLEFT", 2, -3)
    row.Detail:SetJustifyH("LEFT")
  end
  row.Empty = DescText(row)
  row.Empty:SetPoint("RIGHT", row, "TOPRIGHT", -(PAD + SCROLLBAR_ROOM), y)
  row.Empty:SetJustifyH("RIGHT")
  row.Empty:SetText(o.emptyText or "")

  Detail = function()
    if not row.Detail then return end
    local value = row.Dropdown:GetValue()
    row.Detail:SetText(value ~= nil and (Live(function() return o.detail(value, window) end) or "") or "")
  end
  local signature
  table.insert(window.refreshers, function()
    local ok, labels, values = pcall(o.options, window)
    if not ok or type(labels) ~= "table" or type(values) ~= "table" then labels, values = {}, {} end
    local sig = Signature(labels, values)
    if sig ~= signature then
      signature = sig
      local current, keep = row.Dropdown:GetValue(), nil
      for _, v in ipairs(values) do
        if v == current then keep = v end
      end
      row.Dropdown:InitAgain(labels, values)
      row.Dropdown:SetValue(keep ~= nil and keep or values[1])
    end
    local any = #values > 0
    row.Dropdown:SetShown(any)
    row.Button:SetShown(any)
    if row.Detail then row.Detail:SetShown(any) end
    row.Empty:SetShown(not any)
    Detail()
  end)
  row.Button:SetScript("OnClick", function()
    local value = row.Dropdown:GetValue()
    if value ~= nil and o.onClick then o.onClick(value, window) end
  end)
  row.SetRowEnabled = function(enabled)
    row.Dropdown.DropDown:SetEnabled(enabled)
    row.Button:SetEnabled(enabled)
    SetLabelEnabled(row.Label, enabled)
  end
  self:Describe(row, o, PAD + indent)
  return row
end

---------------------------------------------------------------------------
-- List{ rows(window) -> entries, onRemove(entry, window), onUndo(entry, window),
--   removeTooltip, empty = { state, title, text, icon/atlas, action } or function(window), searchAt, indent }
-- An entry: { itemID (its icon, quality color and tooltip), text, tag, icon/atlas,
--   tooltip, removed (a staged removal: struck through, with Undo) }.
-- The list is as tall as its entries (the panel scrolls); its row frames are
-- made out of combat only, and entries past them wait for combat to end.
---------------------------------------------------------------------------
local waitingLists = {}
-- made at load: the lists wait on it in combat, when no frame may be made
local listCombatFrame = CreateFrame("Frame")
listCombatFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
listCombatFrame:SetScript("OnEvent", function()
  for w in pairs(waitingLists) do
    if w:IsShown() then w:RefreshState() end
  end
  wipe(waitingLists)
end)

local function ListAfterCombat(window)
  waitingLists[window] = true
end

local function QualityOf(entry)
  if not entry.itemID then return nil end
  -- GetItemIconByID returns only the icon; quality comes from its own call
  local ok, quality = pcall(C_Item.GetItemQualityByID, entry.itemID)
  if ok and type(quality) == "number" then return quality end
end

local function CreateListItem(row, o, window, x)
  local item = CreateFrame("Button", nil, row)
  item:SetHeight(LIST_ROW_H)
  item:SetPoint("LEFT", row, "LEFT", x, 0)
  item:SetPoint("RIGHT", row, "RIGHT", -(PAD + SCROLLBAR_ROOM), 0)
  local hover = item:CreateTexture(nil, "HIGHLIGHT")
  hover:SetAllPoints()
  hover:SetAtlas(STYLE.rowHoverAtlas)
  hover:SetBlendMode("ADD")
  item.Icon = item:CreateTexture(nil, "ARTWORK")
  item.Icon:SetSize(LIST_ICON, LIST_ICON)
  item.Icon:SetPoint("LEFT", 4, 0)
  item.Border = CreateFrame("Frame", nil, item)
  item.Border:SetPoint("TOPLEFT", item.Icon, "TOPLEFT", -1, 1)
  item.Border:SetPoint("BOTTOMRIGHT", item.Icon, "BOTTOMRIGHT", 1, -1)
  AddEdges(item.Border, "OVERLAY")
  item.Remove = UI.CreateIconButton(item, { size = 16, atlas = STYLE.removeAtlas, highlightAtlas = STYLE.removeAtlas,
    highlightAlpha = 0.4, point = { "RIGHT", item, "RIGHT", -4, 0 }, tooltip = o.removeTooltip or "Remove",
    onClick = function() if item.entry and o.onRemove then o.onRemove(item.entry, window) end end })
  -- a click area wider than the small x: the gap around it counts too
  item.Remove:SetHitRectInsets(-6, -6, -4, -4)
  item.Undo = UI.CreateButton(item, { text = "Undo", size = { 54, 18 }, fontSize = 10,
    point = { "RIGHT", item, "RIGHT", -4, 0 },
    onClick = function() if item.entry and o.onUndo then o.onUndo(item.entry, window) end end })
  item.Tag = DescText(item)
  item.Tag:SetPoint("RIGHT", item.Remove, "LEFT", -8, 0)
  item.Tag:SetJustifyH("RIGHT")
  item.Text = item:CreateFontString(nil, "OVERLAY", U.Fonts.BODY)
  item.Text:SetPoint("LEFT", item.Icon, "RIGHT", 8, 0)
  item.Text:SetPoint("RIGHT", item.Tag, "LEFT", -8, 0)
  item.Text:SetJustifyH("LEFT")
  item.Text:SetWordWrap(false)
  item.Strike = item:CreateTexture(nil, "OVERLAY")
  item.Strike:SetHeight(1)
  item.Strike:SetPoint("LEFT", item.Text, "LEFT", 0, 0)
  local gray = U.Colors.LABEL_GRAY
  item.Strike:SetColorTexture(gray[1], gray[2], gray[3], 0.9)
  FillableHover(item, function(tip, owner)
    local entry = (owner or item).entry
    if entry and entry.itemID then
      tip:SetItemByID(entry.itemID)
    elseif entry and entry.tooltip then
      tip:SetText(entry.tooltip, 1, 1, 1, 1, true)
    else
      return false
    end
  end)
  return item
end

local function FillListItem(item, entry, index, o)
  item.entry = entry
  U.AddAlternatingRowBg(item, index)
  if entry.atlas or entry.icon then
    SetIcon(item.Icon, entry)
  elseif entry.itemID then
    local ok, icon = pcall(C_Item.GetItemIconByID, entry.itemID)
    item.Icon:SetTexture(ok and icon or 134400)   -- the question mark icon while it loads
    item.Icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
  else
    item.Icon:SetTexture(nil)
  end
  local quality = QualityOf(entry)
  local text = entry.text
  if text == nil and entry.itemID then
    text = C_Item.GetItemNameByID(entry.itemID) or ("Item " .. entry.itemID)
  end
  item.Text:SetText(text or "")
  local white, gray = U.Colors.HIGHLIGHT_WHITE, U.Colors.DISABLED_GRAY
  local r, g, b = white[1], white[2], white[3]
  if quality then r, g, b = C_Item.GetItemQualityColor(quality) end
  if entry.removed then r, g, b = gray[1], gray[2], gray[3] end
  item.Text:SetTextColor(r, g, b)
  item.Border:SetShown(quality ~= nil)
  if quality then item.Border:SetEdgeColor({ r, g, b }, 0.9) end
  item.Tag:SetText(entry.tag or "")
  item.Strike:SetShown(entry.removed == true)
  item.Strike:SetWidth(math.min(item.Text:GetStringWidth(), math.max(1, item.Text:GetWidth())))
  item.Icon:SetDesaturated(entry.removed == true)
  item.Remove:SetShown(not entry.removed and o.onRemove ~= nil)
  item.Undo:SetShown(entry.removed == true and o.onUndo ~= nil)
  item.Tag:ClearAllPoints()
  item.Tag:SetPoint("RIGHT", entry.removed and item.Undo or item.Remove, "LEFT", -8, 0)
end

function Panel:List(o)
  local window = self.window
  local x = PAD + (o.indent or 0)
  local row = self:AddRow(EMPTY_H, o)
  row.Items = {}
  local entries, shown, query, emptyH = {}, 0, "", EMPTY_H - 6

  -- the empty state (EmptyState's card): the list's own when it has no
  -- entries, "No matches" with a way back when the search hides them all
  local empty = CreateEmptyCard(row, window)
  empty:SetPoint("RIGHT", row, "RIGHT", -(PAD + SCROLLBAR_ROOM), 0)
  row.EmptyState = empty
  local clearSearch = { text = "Clear the search", onClick = function()
    query = ""
    if row.Search then row.Search:SetText("") end
  end }

  -- a search box once the list is long; it stays while it holds a query,
  -- even when removals take the list under searchAt
  local top = 0
  if o.searchAt then
    row.Search = UI.CreateSearchBox(row, { width = 200, point = { "TOPLEFT", row, "TOPLEFT", x + 4, -2 },
      onSearch = function(text)
        query = strlower(strtrim(text or ""))
        window:RefreshState()
      end })
    -- "Matches: 3 of 41" beside it while a query is set
    row.Matches = DescText(row)
    row.Matches:SetPoint("LEFT", row.Search, "RIGHT", 10, 0)
  end

  row.More = DescText(row)
  row.More:SetJustifyH("LEFT")

  local function Matches(entry)
    if query == "" then return true end
    local text = entry.text or (entry.itemID and C_Item.GetItemNameByID(entry.itemID)) or ""
    text = strlower(text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
    return text:find(query, 1, true) ~= nil or strlower(entry.tag or ""):find(query, 1, true) ~= nil
  end

  local function Paint()
    local ok, all = pcall(o.rows, window)
    if not ok or type(all) ~= "table" then all = {} end
    local searching = row.Search ~= nil and (#all > o.searchAt or query ~= "")
    if row.Search then
      row.Search:SetShown(searching)
      row.Matches:SetShown(searching and query ~= "")
    end
    top = searching and 28 or 0
    entries = {}
    for _, entry in ipairs(all) do
      if Matches(entry) then entries[#entries + 1] = entry end
    end
    if row.Matches then row.Matches:SetText(("Matches: %d of %d"):format(#entries, #all)) end
    shown = 0
    for i, entry in ipairs(entries) do
      local item = row.Items[i]
      if not item then
        if InCombatLockdown() then
          ListAfterCombat(window)
          break
        end
        item = CreateListItem(row, o, window, x)
        row.Items[i] = item
      end
      item:ClearAllPoints()
      item:SetPoint("TOPLEFT", row, "TOPLEFT", x, -(top + (i - 1) * LIST_ROW_H))
      item:SetPoint("RIGHT", row, "RIGHT", -(PAD + SCROLLBAR_ROOM), 0)
      FillListItem(item, entry, i, o)
      item:Show()
      shown = i
    end
    for i = shown + 1, #row.Items do row.Items[i]:Hide() end
    local more = #entries - shown
    row.More:SetShown(more > 0)
    if more > 0 then
      row.More:ClearAllPoints()
      row.More:SetPoint("TOPLEFT", row, "TOPLEFT", x + 4, -(top + shown * LIST_ROW_H + 4))
      row.More:SetText(("%d more after combat."):format(more))
    end
    -- empty: the list's own card (o.empty, a table or function(window));
    -- nothing matching: No matches and a way to clear the search
    local noMatch = #all > 0 and #entries == 0
    empty:SetShown(#all == 0 or noMatch)
    if noMatch then
      emptyH = FillEmptyCard(empty, { state = "nomatch",
        text = ("Nothing on this list matches \"%s\"."):format(query), action = clearSearch }, window)
    elseif #all == 0 then
      local def = Live(o.empty, window)
      emptyH = FillEmptyCard(empty, type(def) == "table" and def or {}, window)
    end
    empty:ClearAllPoints()
    empty:SetPoint("TOPLEFT", row, "TOPLEFT", x, -(top + 2))
    empty:SetPoint("RIGHT", row, "RIGHT", -(PAD + SCROLLBAR_ROOM), 0)
  end
  row.Measure = function()
    if empty:IsShown() then
      row:SetHeight(top + emptyH + 6)
    else
      local extra = row.More:IsShown() and 22 or 4
      row:SetHeight(top + shown * LIST_ROW_H + extra)
    end
  end
  table.insert(window.refreshers, Paint)
  self:Describe(row, o, x)
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
    button.Text:SetPoint("RIGHT", -6, 0)
    button.Text:SetJustifyH("LEFT")
    button.Text:SetWordWrap(false)
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
  -- size: one of the shared presets; an explicit width or height wins
  local preset = UI.SettingsSizes[opts.size or "standard"]
  assert(preset, "CreateSettingsWindow: size is compact, standard or browser")
  local width = opts.width or preset.width
  local height = opts.height or preset.height

  local persist
  if opts.persist then
    persist = {
      svTable = opts.persist.svTable,
      key = opts.persist.key or "settings",
      defaults = opts.persist.defaults or { point = "CENTER", relPoint = "CENTER", x = 0, y = 0 },
    }
  end

  -- Grows from the declared size, never below it (see the header)
  local resizable
  if opts.resizable ~= false then
    local r = type(opts.resizable) == "table" and opts.resizable or {}
    resizable = {
      minWidth = r.minWidth or width, minHeight = r.minHeight or height,
      maxWidth = r.maxWidth or width + MAX_GROWTH, maxHeight = r.maxHeight or height + MAX_GROWTH,
    }
  end

  local window = UI.CreateWindow({
    name = opts.name,
    title = opts.title,
    icon = opts.icon,
    width = width,
    height = height,
    escapeCloses = true,
    persist = persist,
    resizable = resizable,
    strata = opts.strata,
  })
  Mixin(window, Settings)
  window.opts = opts
  window.config = opts.config
  window.pending = {}
  window.editing = {}
  window.controls = {}
  window.keys = {}
  window.keyConfig = {}      -- [key] = the category config that owns it (a config or a function)
  window.noDefaults = {}     -- [key] = true: its category opted out of Defaults (defaults = false)
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
  local contentWidth = width - 16 - (withSidebar and (SIDEBAR_W + 4) or 0)

  -- The bottom bar first: RefreshState reads its buttons
  window.DefaultsPopup = UI.CreateDialogPopup({
    name = opts.name .. "DefaultsPopup",
    icon = opts.icon,
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
    tooltip = "Put every setting in this window back to its default. Press Apply to keep them.",
    point = { "BOTTOMLEFT", 12, 12 },
    onClick = function() window.DefaultsPopup:Show() end,
  })
  local previous = window.DefaultsButton
  window.FooterButtons = {}   -- opts.footerButtons' buttons, in order (a Verify scene finds them here)
  for i, extra in ipairs(opts.footerButtons or {}) do
    previous = UI.CreateButton(window, {
      size = { extra.width or FOOTER_BUTTON_W, FOOTER_BUTTON_H }, text = extra.text, tooltip = extra.tooltip,
      point = { "LEFT", previous, "RIGHT", 6, 0 },
      onClick = function() if extra.onClick then extra.onClick(window) end end,
    })
    window.FooterButtons[i] = previous
  end
  -- Clear of the resize grip in the corner
  window.CancelButton = UI.CreateButton(window, {
    size = { FOOTER_BUTTON_W, FOOTER_BUTTON_H }, text = "Cancel",
    tooltip = "Undo the changes you haven't applied yet. The window stays open.",
    point = { "BOTTOMRIGHT", window.ResizeGrip and -22 or -12, 12 },
    onClick = function() window:Cancel() end,
  })
  window.ApplyButton = UI.CreateButton(window, {
    size = { FOOTER_BUTTON_W, FOOTER_BUTTON_H }, text = "Apply",
    tooltip = "Save your changes in every category of this window.",
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
      -- The window's size changed: rows follow the new width (while it
      -- shows: the rows read the settings, which may not be loaded before)
      scroll:SetScript("OnSizeChanged", function()
        if panel and window:IsShown() then panel:Layout() end
      end)

      panel = setmetatable({
        key = category.key,
        frame = scroll,
        scroll = scroll,
        content = content,
        window = window,
        config = category.config,
        noDefaults = category.defaults == false,
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
