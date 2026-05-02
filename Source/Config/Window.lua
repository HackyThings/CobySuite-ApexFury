-------------------------------------------------------------------------------
-- ApexFury Options Window
--
-- Two-pane layout:
--   - Left  (form):     Behavior + Trigger + slim Sound section + footer
--   - Right (browser):  CobySuite.UI.SoundBrowser — full searchable picker
--                       across Blizzard SoundKit, every LSM pack
--                       (Astral / Causese / Other), and Leatrix Sounds.
--
-- Form rows are built via CobySuite.UI.CreateFormLayout. Sound section
-- uses form:Custom for its bespoke layout (selected display + test button,
-- optional Leatrix grab buttons, library tip).
-------------------------------------------------------------------------------

local Config = ApexFury.Config
local U = CobySuite.Utilities
local TC = U.Colors
local Fonts = U.Fonts
local UI = CobySuite.UI
local CSound = CobySuite.Sound

-- Forward-declared so the confirm-dialog Accept callback can reach
-- the in-window commit logic defined inside BuildFrame.
local CommitSound

-- We INTENTIONALLY do not register a StaticPopupDialogs entry. Adding
-- to that table from addon code stains it in Midnight 12.0; Blizzard's
-- bag-use path (UseContainerItem → ContainerFrameItemButton_OnClick)
-- reads StaticPopupDialogs internally and inherits the taint, producing
-- ADDON_ACTION_FORBIDDEN cascades on right-click. We use our own custom
-- dialog frame (built lazily, see ConfirmReplaceLTS below).

-- Form (left pane) dimensions
local FORM_W   = 480
local PANEL_PAD = 16
local INPUT_W  = 80
local ROW_H    = 26
local SEC_GAP  = 14
local INPUT_X  = 220

-- Browser (right pane) dimensions
local BROWSER_W = 460

-- Window total
local GAP       = 6
local WINDOW_W  = FORM_W + GAP + BROWSER_W
local WINDOW_H  = 500

local frame
local widgets = {}
local browser

-- ═══════════════════════════════════════════════════════
-- Window state persistence
-- ═══════════════════════════════════════════════════════

local function SaveState()
  if not frame then return end
  APEX_FURY_UI_STATE = APEX_FURY_UI_STATE or {}
  UI.SaveWindowState(frame, APEX_FURY_UI_STATE, "options")
end

local function RestoreState()
  APEX_FURY_UI_STATE = APEX_FURY_UI_STATE or {}
  UI.RestoreWindowState(frame, APEX_FURY_UI_STATE, "options",
    { point = "CENTER", relPoint = "CENTER", x = 0, y = 0 })
  -- The layout is two-pane (form + browser) with fixed widths; ignore
  -- any width/height saved from older builds and pin to the current
  -- design size.
  frame:SetSize(WINDOW_W, WINDOW_H)
end

-- ═══════════════════════════════════════════════════════
-- Helpers — currently-selected sound display
-- ═══════════════════════════════════════════════════════

-- Synthesize a display entry for whatever the user currently has stored.
-- Skip the heavy Leatrix entry list — for fdid:N values, the resolved
-- label already comes from the Leatrix index, which is much cheaper.
local function GetCurrentSoundEntry()
  local id = Config.Get(Config.Options.SOUND_ID)
  for _, e in ipairs(CobySuite.Sound.GetEntries({ includeLeatrix = false })) do
    if e.value == id then return e end
  end
  local kind, _, fallbackLabel = CobySuite.Sound.Resolve(id)
  local source = "Custom"
  if kind == "soundkit"    then source = "Blizzard"       end
  if kind == "fdid"        then source = "Leatrix"        end
  if kind == "lsm"         then source = "LibSharedMedia" end
  if kind == "lsm_missing" then source = "LSM (missing)"  end
  return {
    label  = ApexFury.Sound.LookupLabel(id) or fallbackLabel,
    value  = id,
    source = source,
    kind   = kind == "soundkit"     and "SoundKit"
           or kind == "fdid"        and "FileDataID"
           or kind == "lsm"         and "LSM"
           or kind == "lsm_missing" and "LSM"
           or "Unknown",
  }
end

local function FormatSoundDisplay(entry)
  if not entry then return "|cFFAAAAAA(none)|r" end
  return entry.label or "|cFFAAAAAA(unknown)|r"
end

local function RefreshSelectedDisplay()
  if not widgets.selectedLabel then return end
  local entry = GetCurrentSoundEntry()
  widgets.selectedLabel:SetText(FormatSoundDisplay(entry))
  if widgets.selectedSourceLabel then
    local pack = entry.pack or entry.source or ""
    widgets.selectedSourceLabel:SetText(string.format(
      "|cFF888888%s · %s|r", pack, entry.kind or ""))
  end
end

-- ═══════════════════════════════════════════════════════
-- Refresh widgets from current Config
-- ═══════════════════════════════════════════════════════

local function Refresh()
  for _, w in pairs(widgets) do
    if w._optionKey then
      local val = Config.Get(Config.Options[w._optionKey])
      if w:GetObjectType() == "CheckButton" then
        w:SetChecked(val and true or false)
      elseif w:GetObjectType() == "EditBox" then
        if w.SetCommittedValue then
          w:SetCommittedValue(val)
        else
          w:SetText(tostring(val))
        end
        if w._refreshName then w._refreshName() end
      end
    end
  end
  RefreshSelectedDisplay()
  if browser and browser.RefreshSelection then browser:RefreshSelection() end
end

-- ═══════════════════════════════════════════════════════
-- Frame creation
-- ═══════════════════════════════════════════════════════

local function BuildFrame()
  if frame then return frame end

  local f = CreateFrame("Frame", "ApexFuryOptionsWindow", UIParent, "BasicFrameTemplateWithInset")
  f:SetSize(WINDOW_W, WINDOW_H)
  f:SetFrameStrata("HIGH")
  f:SetToplevel(true)
  f:SetClampedToScreen(true)
  f:EnableMouse(true)
  f:SetMovable(true)
  f:RegisterForDrag("LeftButton")
  f:Hide()

  -- Solid dark background behind the inset template
  local solidBg = f:CreateTexture(nil, "BACKGROUND", nil, -8)
  solidBg:SetAllPoints()
  local wbg = TC.WINDOW_BG
  solidBg:SetColorTexture(wbg[1], wbg[2], wbg[3], wbg[4])

  f.TitleText:SetText("|cFF" .. ApexFury.BRAND_COLOR .. "ApexFury|r — Settings")

  f:SetScript("OnDragStart", function(self) self:StartMoving() end)
  f:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    SaveState()
  end)
  f:SetScript("OnShow", Refresh)
  f:SetScript("OnKeyDown", function(self, key)
    if key == "ESCAPE" then
      self:SetPropagateKeyboardInput(false)
      self:Hide()
    else
      self:SetPropagateKeyboardInput(true)
    end
  end)

  -- ───────────────────────────────────────────────────
  -- Form (left pane) and Browser (right pane) frames
  -- ───────────────────────────────────────────────────
  local content = CreateFrame("Frame", nil, f)
  content:SetPoint("TOPLEFT", 8, -28)
  content:SetSize(FORM_W - 16, WINDOW_H - 28 - 44)

  -- Vertical divider between form and browser
  local divider = f:CreateTexture(nil, "ARTWORK")
  local dg = TC.DIVIDER_GRAY
  divider:SetColorTexture(dg[1], dg[2], dg[3], dg[4])
  divider:SetWidth(1)
  divider:SetPoint("TOPLEFT", content, "TOPRIGHT", 4, 0)
  divider:SetPoint("BOTTOMLEFT", content, "BOTTOMRIGHT", 4, 0)

  -- ───────────────────────────────────────────────────
  -- Form-builder
  -- ───────────────────────────────────────────────────
  local form = UI.CreateFormLayout(content, {
    labelX     = PANEL_PAD,
    controlX   = INPUT_X,
    rowHeight  = ROW_H,
    sectionGap = SEC_GAP,
    width      = FORM_W - 16,
    inputWidth = INPUT_W,
    startY     = -PANEL_PAD,
    dividerPadding = PANEL_PAD,
  })

  -- Section dividers stretch from PANEL_PAD to PANEL_PAD on the right.
  local sectionOpts = { dividerPadding = PANEL_PAD, dividerOffset = -4 }

  -- ───────────────────────────────────────────────────
  -- Behavior section
  -- ───────────────────────────────────────────────────
  form:Section("Behavior", sectionOpts)

  widgets.enabled = form:Checkbox{
    label        = "Alerting enabled",
    tooltip      = "Master enable. When off, the watcher still tracks state but never plays a sound.",
    optionKey    = "ENABLED",
    initialValue = Config.Get(Config.Options.ENABLED),
    onChange     = function(v) Config.Set(Config.Options.ENABLED, v) end,
  }

  widgets.combatOnly = form:Checkbox{
    label        = "Combat-only mode",
    tooltip      = "When on: if the alert moment arrives out of combat, defer it. The sound plays the instant you re-enter combat (subject to the linger gate).",
    optionKey    = "COMBAT_ONLY",
    initialValue = Config.Get(Config.Options.COMBAT_ONLY),
    onChange     = function(v) Config.Set(Config.Options.COMBAT_ONLY, v) end,
  }

  widgets.actionabilityGate = form:Checkbox{
    label        = "Actionability gate",
    tooltip      = "When on: if you're in a vehicle, mounted (incl. skyriding combat mounts on bosses like Dimensius P2 / Amirdrassil flying phase), possessed, stunned, feared, silenced, or otherwise unable to act, the alert defers and re-fires the moment you regain control — provided Risen Fury linger still has time. When off, the sound plays regardless of player state. Recommended for high-end optimization.",
    optionKey    = "ACTIONABILITY_GATE",
    initialValue = Config.Get(Config.Options.ACTIONABILITY_GATE),
    onChange     = function(v) Config.Set(Config.Options.ACTIONABILITY_GATE, v) end,
  }

  widgets.verbose = form:Checkbox{
    label        = "Verbose debug logging",
    tooltip      = "Logs every cast, empower, and lifecycle event to the debug window. Useful for diagnosis; off by default.",
    optionKey    = "VERBOSE",
    initialValue = Config.Get(Config.Options.VERBOSE),
    onChange     = function(v) Config.Set(Config.Options.VERBOSE, v) end,
  }

  -- ───────────────────────────────────────────────────
  -- Trigger section
  -- ───────────────────────────────────────────────────
  form:Section("Trigger", sectionOpts)

  -- Spell-ID input has a name label + hover frame to the right; build
  -- via NumberInput then anchor the auxiliaries off the editbox.
  widgets.spellId = form:NumberInput{
    label        = "Trigger spell ID",
    tooltip      = "The cast event that starts a tracking cycle. Default 375087 = Dragonrage. Cast events are not subject to the private-aura system.",
    optionKey    = "SPELL_ID",
    width        = INPUT_W,
    maxLetters   = 10,
    initialValue = Config.Get(Config.Options.SPELL_ID),
    validate     = function(v) return v > 0 and math.floor(v) == v end,
    onCommit     = function(v)
      Config.Set(Config.Options.SPELL_ID, v)
      if widgets.spellId._refreshName then widgets.spellId._refreshName() end
    end,
  }

  -- Spell icon + name display + hover-for-tooltip frame, anchored
  -- relative to the spell-id editbox so they ride along on the same row.
  -- Layout: [editbox] [icon] [name] — the hover frame spans icon+name so
  -- the spell tooltip shows for the whole visual cluster.
  do
    local eb = widgets.spellId
    local iconSize = U.EditBoxHeight.INPUT or 22

    local iconTex = content:CreateTexture(nil, "ARTWORK")
    iconTex:SetSize(iconSize, iconSize)
    iconTex:SetPoint("LEFT", eb, "RIGHT", 8, 0)
    -- Crop the default 5%-ish border that Blizzard icon textures have so
    -- the icon sits flush in the row without a chunky black frame.
    iconTex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    iconTex:Hide()

    local nameLabel = content:CreateFontString(nil, "OVERLAY", Fonts.DATA)
    nameLabel:SetPoint("LEFT", iconTex, "RIGHT", 6, 0)
    nameLabel:SetWidth(FORM_W - INPUT_X - INPUT_W - iconSize - 50)
    nameLabel:SetJustifyH("LEFT")
    nameLabel:SetWordWrap(false)

    local hover = CreateFrame("Frame", nil, content)
    hover:SetPoint("LEFT", eb, "RIGHT", 8, 0)
    hover:SetSize(FORM_W - INPUT_X - INPUT_W - 40, U.EditBoxHeight.INPUT + 4)
    hover:EnableMouse(true)

    UI.AddSpellTooltip(hover, function()
      return Config.Get(Config.Options.SPELL_ID)
    end, "ANCHOR_RIGHT")

    eb._refreshName = function()
      local id = Config.Get(Config.Options.SPELL_ID)
      local info
      if id then
        local ok, result = pcall(C_Spell.GetSpellInfo, id)
        if ok then info = result end
      end
      if info and type(info) == "table" and info.name then
        nameLabel:SetText("|cFFFFD200" .. info.name .. "|r")
        if info.iconID then
          iconTex:SetTexture(info.iconID)
          iconTex:Show()
        else
          iconTex:Hide()
        end
      else
        nameLabel:SetText("|cFFFF6644(unknown spell)|r")
        iconTex:Hide()
      end
    end
    eb._refreshName()
  end

  widgets.threshold = form:NumberInput{
    label        = "Threshold (stacks)",
    tooltip      = "Stack count at which to alert. Default 4 = Rising Fury at the trinket window.",
    optionKey    = "THRESHOLD",
    initialValue = Config.Get(Config.Options.THRESHOLD),
    validate     = function(v) return v >= 1 and v <= 99 and math.floor(v) == v end,
    onCommit     = function(v) Config.Set(Config.Options.THRESHOLD, v) end,
  }

  widgets.interval = form:NumberInput{
    label        = "Stack interval (s)",
    tooltip      = "Seconds between stack ticks while the trigger is active. Default 6 for Rising Fury.",
    optionKey    = "STACK_INTERVAL",
    initialValue = Config.Get(Config.Options.STACK_INTERVAL),
    validate     = function(v) return v > 0 and v <= 60 end,
    onCommit     = function(v) Config.Set(Config.Options.STACK_INTERVAL, v) end,
  }

  widgets.minRemain = form:NumberInput{
    label        = "Min linger remaining (s)",
    tooltip      = "If the alert was deferred (out of combat) and you re-enter combat with less than this much linger left, suppress it — the trinket window is too short to matter. Default 2.",
    optionKey    = "MIN_REMAINING",
    initialValue = Config.Get(Config.Options.MIN_REMAINING),
    validate     = function(v) return v >= 0 and v <= 60 end,
    onCommit     = function(v) Config.Set(Config.Options.MIN_REMAINING, v) end,
  }

  -- ───────────────────────────────────────────────────
  -- Sound section — bespoke layout (selected display + test button,
  -- optional Leatrix integration row, library tip)
  -- ───────────────────────────────────────────────────
  form:Section("Sound", sectionOpts)

  -- Row 1: "Selected:" label + speaker test button + two-line display
  form:Custom(function(parent, y)
    local label = parent:CreateFontString(nil, "OVERLAY", Fonts.DATA)
    label:SetPoint("LEFT", parent, "TOPLEFT", PANEL_PAD, y)
    label:SetText("Selected:")
    UI.AddTooltip(label,
      "The sound that will play when the threshold is reached. Pick a different one in the browser on the right.",
      "ANCHOR_RIGHT")

    local btnTest = UI.CreateIconButton(parent, {
      size        = 22,
      texture     = "Interface\\COMMON\\VoiceChat-Speaker",
      vertexColor = { 0.7, 0.9, 1.0 },
      tooltip     = "Play the selected sound",
      onClick     = function()
        ApexFury.Sound.Play(Config.Get(Config.Options.SOUND_ID))
      end,
      point       = { "LEFT", parent, "TOPLEFT", INPUT_X - 28, y },
    })

    local selectedLabel = parent:CreateFontString(nil, "OVERLAY", Fonts.BODY)
    selectedLabel:SetPoint("LEFT", parent, "TOPLEFT", INPUT_X, y + 6)
    selectedLabel:SetWidth(FORM_W - INPUT_X - 24)
    selectedLabel:SetJustifyH("LEFT")
    selectedLabel:SetWordWrap(false)
    widgets.selectedLabel = selectedLabel

    local selectedSourceLabel = parent:CreateFontString(nil, "OVERLAY", Fonts.SMALL)
    selectedSourceLabel:SetPoint("LEFT", parent, "TOPLEFT", INPUT_X, y - 8)
    selectedSourceLabel:SetWidth(FORM_W - INPUT_X - 24)
    selectedSourceLabel:SetJustifyH("LEFT")
    selectedSourceLabel:SetWordWrap(false)
    widgets.selectedSourceLabel = selectedSourceLabel

    return y - ROW_H
  end)

  -- Row 2 (conditional): Leatrix Sounds integration buttons
  local hasLTS = ApexFury.Leatrix and ApexFury.Leatrix.IsAvailable()
  if hasLTS then
    form:Custom(function(parent, y)
      local label = parent:CreateFontString(nil, "OVERLAY", Fonts.DATA)
      label:SetPoint("LEFT", parent, "TOPLEFT", PANEL_PAD, y)
      label:SetText("Leatrix Sounds:")
      UI.AddTooltip(label,
        "Open the Leatrix Sounds browser, click any sound row in there, then press Grab Sound to import it as your alert.",
        "ANCHOR_RIGHT")

      local btnOpenLTS = UI.CreateButton(parent, {
        size  = { 96, 22 },
        text  = "Open Leatrix",
        point = { "LEFT", parent, "TOPLEFT", INPUT_X - 6, y },
        tooltip = "Open the Leatrix Sounds browser. Click any row in its list to mark it as your selection, then return here and press Grab Sound.",
        onClick = function() ApexFury.Leatrix.OpenPanel() end,
      })

      UI.CreateButton(parent, {
        size  = { 96, 22 },
        text  = "Grab Sound",
        point = { "LEFT", btnOpenLTS, "RIGHT", 6, 0 },
        tooltip = "Import the row you most recently clicked in the Leatrix Sounds browser as the ApexFury alert sound.",
        onClick = function()
          local path, fdid = ApexFury.Leatrix.GrabSelected()
          if not fdid then
            ApexFury.Message("|cFFFFAA00Click a sound in the Leatrix list first, then press Grab Sound.|r")
            return
          end
          -- Grab path commits directly — going INTO an LTS sound never
          -- needs the replace-LTS confirmation.
          Config.Set(Config.Options.SOUND_ID, "fdid:" .. fdid)
          Config.Set(Config.Options.SOUND_LABEL, path or "")
          RefreshSelectedDisplay()
          if browser and browser.RefreshSelection then browser:RefreshSelection() end
          ApexFury.Message(string.format(
            "Sound set from Leatrix: |cFFFFD200%s|r |cFF888888(FileDataID %d)|r",
            path or "?", fdid))
        end,
      })

      return y - ROW_H
    end)
  end

  -- Row 3: Library support tip — always shown.
  form:Custom(function(parent, y)
    local libsTip = parent:CreateFontString(nil, "OVERLAY", Fonts.SMALL)
    libsTip:SetPoint("TOPLEFT",  parent, "TOPLEFT",  PANEL_PAD, y - 2)
    libsTip:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -PANEL_PAD, y - 2)
    libsTip:SetJustifyH("LEFT")
    libsTip:SetWordWrap(true)
    if hasLTS then
      libsTip:SetText("|cFF888888Tip: ApexFury also supports |cFFFFD200LibSharedMedia|r|cFF888888 packs (Astral, Causese, etc.) — install more for additional sounds.|r")
    else
      libsTip:SetText("|cFF888888Tip: Install |cFFFFD200Leatrix Sounds|r|cFF888888 (~275k FileDataIDs) or a |cFFFFD200LibSharedMedia|r|cFF888888 pack (Astral, Causese, etc.) for thousands more sounds.|r")
    end
    return y - ROW_H
  end)

  -- ───────────────────────────────────────────────────
  -- Sound Browser (right pane)
  -- ───────────────────────────────────────────────────
  -- Real commit (assigned to the file-scoped forward decl so the
  -- replace-LTS confirm-dialog Accept callback can reach it).
  CommitSound = function(value, entry)
    Config.Set(Config.Options.SOUND_ID, value)
    Config.Set(Config.Options.SOUND_LABEL, entry and entry.label or "")
    RefreshSelectedDisplay()
    if browser and browser.RefreshSelection then browser:RefreshSelection() end
  end

  -- Custom replace-LTS confirmation dialog, built lazily on first use.
  -- We avoid StaticPopupDialogs entirely — registering an entry stains
  -- that global table and cascades into UseContainerItem on bag clicks.
  local confirmDialog
  local function ShowReplaceLTSConfirm(value, entry)
    if not confirmDialog then
      local d = CreateFrame("Frame", nil, UIParent, "BasicFrameTemplateWithInset")
      d:SetSize(380, 150)
      d:SetFrameStrata("DIALOG")
      d:SetToplevel(true)
      d:SetClampedToScreen(true)
      d:EnableMouse(true)
      d:SetMovable(true)
      d:RegisterForDrag("LeftButton")
      d:SetScript("OnDragStart", function(self) self:StartMoving() end)
      d:SetScript("OnDragStop",  function(self) self:StopMovingOrSizing() end)
      d:Hide()

      local solid = d:CreateTexture(nil, "BACKGROUND", nil, -8)
      solid:SetAllPoints()
      local wbg = TC.WINDOW_BG
      solid:SetColorTexture(wbg[1], wbg[2], wbg[3], wbg[4])

      d.TitleText:SetText("Replace Leatrix sound?")

      local body = d:CreateFontString(nil, "OVERLAY", Fonts.BODY)
      body:SetPoint("TOPLEFT", 16, -34)
      body:SetPoint("TOPRIGHT", -16, -34)
      body:SetJustifyH("LEFT")
      body:SetJustifyV("TOP")
      body:SetWordWrap(true)
      body:SetHeight(60)
      d.body = body

      local btnYes = CreateFrame("Button", nil, d, "UIPanelButtonTemplate")
      btnYes:SetSize(110, 22)
      btnYes:SetPoint("BOTTOMLEFT", 16, 14)
      btnYes:SetText("Replace")
      d.btnYes = btnYes

      local btnNo = CreateFrame("Button", nil, d, "UIPanelButtonTemplate")
      btnNo:SetSize(110, 22)
      btnNo:SetPoint("BOTTOMRIGHT", -16, 14)
      btnNo:SetText("Cancel")
      btnNo:SetScript("OnClick", function() d:Hide() end)

      d:SetPoint("CENTER", UIParent, "CENTER", 0, 80)
      confirmDialog = d
    end

    local stripped = CSound.StripColors(entry and entry.label or "")
    confirmDialog.body:SetText(string.format(
      "You're currently using a Leatrix Sounds selection.\n\nReplace it with: |cFFFFD200%s|r?",
      stripped))
    confirmDialog.btnYes:SetScript("OnClick", function()
      confirmDialog:Hide()
      CommitSound(value, entry)
    end)
    confirmDialog:Show()
    confirmDialog:Raise()
  end

  -- Gated commit — show the replace-LTS confirm only when transitioning
  -- away from a Leatrix-sourced sound to a non-Leatrix one.
  local function MaybeCommit(value, entry)
    local current = Config.Get(Config.Options.SOUND_ID)
    local currentIsLTS = type(current) == "string" and current:find("^fdid:") ~= nil
    local newIsLTS     = type(value)   == "string" and value:find("^fdid:")   ~= nil
    if currentIsLTS and not newIsLTS then
      ShowReplaceLTSConfirm(value, entry)
      return
    end
    CommitSound(value, entry)
  end

  browser = CobySuite.UI.SoundBrowser.Create(f, {
    width  = BROWSER_W - 16,
    height = WINDOW_H - 28 - 44,
    persistenceKey = "apexfury_sound_browser",
    persistence = { savedVariable = "APEX_FURY_UI_STATE", path = "soundBrowserCols" },
    getCurrentValue = function()
      return Config.Get(Config.Options.SOUND_ID)
    end,
    onSelect = MaybeCommit,
  })
  browser:SetPoint("TOPLEFT", content, "TOPRIGHT", GAP + 4, 0)
  browser:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -8, 44)

  -- ───────────────────────────────────────────────────
  -- Footer action buttons
  -- ───────────────────────────────────────────────────
  local btnReset = UI.CreateButton(f, {
    size = { 120, 22 }, text = "Reset Defaults",
    point = { "BOTTOMLEFT", 12, 14 },
    onClick = function() Config.Reset(); Refresh() end,
  })

  local btnDebug = UI.CreateButton(f, {
    size = { 120, 22 }, text = "Debug Log",
    point = { "LEFT", btnReset, "RIGHT", 6, 0 },
    onClick = function()
      if ApexFuryDebugWindow then
        ApexFuryDebugWindow:SetShown(not ApexFuryDebugWindow:IsShown())
      end
    end,
  })

  UI.CreateButton(f, {
    size = { 120, 22 }, text = "Overlay",
    point = { "LEFT", btnDebug, "RIGHT", 6, 0 },
    onClick = function()
      if ApexFury.Overlay and ApexFury.Overlay.Toggle then
        ApexFury.Overlay.Toggle()
      end
    end,
  })

  frame = f
  return f
end

-- ═══════════════════════════════════════════════════════
-- Public API
-- ═══════════════════════════════════════════════════════

function Config.ToggleSettings()
  BuildFrame()
  if frame:IsShown() then
    frame:Hide()
  else
    RestoreState()
    frame:Show()
  end
end
