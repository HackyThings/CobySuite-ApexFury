-------------------------------------------------------------------------------
-- ApexFury Settings Window
--
-- The suite's standard settings window (CobySuite.UI.CreateSettingsWindow):
-- a sidebar with Behavior, Trigger and Sound, staged edits that Apply writes
-- through Config.Set, Cancel, and Defaults. The Sound category holds the
-- selected-sound display with its test button, the optional Leatrix Sounds
-- row, the audio channel and the library tip over an embedded
-- CobySuite.UI.SoundBrowser; a pick in the browser stages the sound like any
-- other control.
--
-- Built on the first open, not at load, because the sound catalog is
-- expensive; a first open in combat is refused (no CreateFrame in combat).
-- ApexFury has no config event bus, so Config/Main.lua calls
-- Config.NotifySettingsWindow from onSet and onReset, and slash commands that
-- change settings (/af channel, /af reset) repaint an open window.
--
-- We INTENTIONALLY do not register a StaticPopupDialogs entry. Adding to that
-- table from addon code taints it in Midnight 12.0; Blizzard's bag-use path
-- reads it and inherits the taint, producing ADDON_ACTION_FORBIDDEN cascades
-- on right-click. The replace-Leatrix confirmation is a
-- CobySuite.UI.CreateDialogPopup child of the window, built with it.
-------------------------------------------------------------------------------

local Config = ApexFury.Config
local Opt = Config.Options
local U = CobySuite_ApexFury.Utilities
local Fonts = U.Fonts
local UI = CobySuite_ApexFury.UI
local CSound = CobySuite_ApexFury.Sound

local WINDOW_W = 720
local WINDOW_H = 580

local INPUT_W = 80
local TRIGGER_INPUT_X = 200    -- every Trigger input starts here, so the spell name fits beside the first
local SOUND_VALUE_X = 140      -- the selected sound's name and the Leatrix buttons
local SELECTED_ROW_H = 34
local LEATRIX_ROW_H = 30
local TIP_ROW_H = 32
local BROWSER_MIN_H = 200      -- the row's own height; the browser itself reaches down to the panel's bottom
local BROWSER_INNER_PAD = 8    -- CobySuite.UI.SoundBrowser's own padding inside its frame

local window

-- Window position lives in APEX_FURY_UI_STATE.options
local function GetUIState()
  APEX_FURY_UI_STATE = APEX_FURY_UI_STATE or {}
  return APEX_FURY_UI_STATE
end

local function IsLeatrixValue(value)
  return type(value) == "string" and value:find("^fdid:") ~= nil
end

-------------------------------------------------------------------------------
-- Selected sound display
-------------------------------------------------------------------------------

-- A display entry for a sound value: the catalog entry (Blizzard SoundKit
-- and LibSharedMedia) when there is one, otherwise one built from the value.
-- A Leatrix fdid:N value is never in the catalog, so its label is the
-- SOUND_LABEL that goes with it (label; Grab Sound saves the file path).
local function SoundEntryFor(id, label)
  for _, e in ipairs(CSound.GetEntries()) do
    if e.value == id then return e end
  end
  local kind, _, fallbackLabel = CSound.Resolve(id)
  local source = "Custom"
  if kind == "soundkit"    then source = "Blizzard"       end
  if kind == "fdid"        then source = "Leatrix"        end
  if kind == "lsm"         then source = "LibSharedMedia" end
  if kind == "lsm_missing" then source = "LSM (missing)"  end
  return {
    label  = ApexFury.Sound.LookupLabel(id, label or "") or fallbackLabel,
    value  = id,
    source = source,
    kind   = kind == "soundkit"     and "SoundKit"
           or kind == "fdid"        and "FileDataID"
           or kind == "lsm"         and "LSM"
           or kind == "lsm_missing" and "LSM"
           or "Unknown",
  }
end

local function PaintSelectedSound(row, win)
  local entry = SoundEntryFor(win:Get(Opt.SOUND_ID), win:Get(Opt.SOUND_LABEL))
  row.SelectedLabel:SetText(entry.label or "|cFFAAAAAA(unknown)|r")
  row.SelectedSource:SetText(string.format("|cFF888888%s · %s|r", entry.pack or entry.source or "", entry.kind or ""))
end

-------------------------------------------------------------------------------
-- Trigger spell name and icon beside the spell ID input
-------------------------------------------------------------------------------
local function PaintSpell(row, spellID)
  local info
  if spellID then
    local ok, result = pcall(C_Spell.GetSpellInfo, spellID)
    if ok and type(result) == "table" then info = result end
  end
  if info and info.name then
    row.SpellName:SetText("|cFFFFD200" .. info.name .. "|r")
    if info.iconID then
      row.SpellIcon:SetTexture(info.iconID)
      row.SpellIcon:Show()
    else
      row.SpellIcon:Hide()
    end
  else
    row.SpellName:SetText("|cFFFF6644(unknown spell)|r")
    row.SpellIcon:Hide()
  end
end

-------------------------------------------------------------------------------
-- Categories
-------------------------------------------------------------------------------
local function BuildBehavior(panel)
  panel:Section("Behavior")
  panel:Checkbox{
    key = Opt.ENABLED, label = "Alerting enabled",
    tooltip = "Master switch. When off, Dragonrage isn't tracked and no sound plays.",
  }
  panel:Checkbox{
    key = Opt.COMBAT_ONLY, label = "Combat-only mode",
    tooltip = "When on: if the alert moment arrives out of combat, defer it. The sound plays the instant you re-enter combat (subject to the linger gate).",
  }
  panel:Checkbox{
    key = Opt.ACTIONABILITY_GATE, label = "Actionability gate",
    tooltip = "When on: if you're in a vehicle, mounted (incl. skyriding combat mounts on bosses like Dimensius P2 / Amirdrassil flying phase), possessed, stunned, feared, silenced, or otherwise unable to act, the alert defers and re-fires the moment you regain control, provided the Rising Fury linger still has time. When off, the sound plays regardless of player state. Recommended for high-end optimization.",
  }
  panel:Checkbox{
    key = Opt.VERBOSE, label = "Verbose debug logging",
    tooltip = "Logs every cast, empower, and lifecycle event to the debug window. Useful for diagnosis; off by default.",
  }
end

local function BuildTrigger(panel, win)
  panel:Section("Trigger")

  -- The spell's icon and name ride beside the input and follow the staged ID
  local spellRow = panel:Input{
    key = Opt.SPELL_ID, label = "Trigger spell ID",
    tooltip = "The cast event that starts a tracking cycle. Default 375087 = Dragonrage. Cast events are not subject to the private-aura system.",
    width = INPUT_W, x = TRIGGER_INPUT_X, numeric = true, maxLetters = 10,
    validate = function(v) return v > 0 and math.floor(v) == v end,
    refresh = function(row, w) PaintSpell(row, w:Get(Opt.SPELL_ID)) end,
  }
  do
    local layout = panel.layout
    local iconSize = U.EditBoxHeight.INPUT
    local nameX = TRIGGER_INPUT_X + INPUT_W + 8 + iconSize + 6
    local nameW = layout.inputX(0) - nameX

    local icon = spellRow:CreateTexture(nil, "ARTWORK")
    icon:SetSize(iconSize, iconSize)
    icon:SetPoint("LEFT", spellRow.Input, "RIGHT", 8, 0)
    -- Crop the border Blizzard icon textures carry so the icon sits flush
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    icon:Hide()
    spellRow.SpellIcon = icon

    local name = spellRow:CreateFontString(nil, "OVERLAY", Fonts.DATA)
    name:SetPoint("LEFT", icon, "RIGHT", 6, 0)
    name:SetWidth(nameW)
    name:SetJustifyH("LEFT")
    name:SetWordWrap(false)
    spellRow.SpellName = name

    -- The spell tooltip covers the icon and the name
    local hover = CreateFrame("Frame", nil, spellRow)
    hover:SetPoint("LEFT", spellRow.Input, "RIGHT", 8, 0)
    hover:SetSize(iconSize + 6 + nameW, iconSize + 4)
    hover:EnableMouse(true)
    UI.AddSpellTooltip(hover, function() return win:Get(Opt.SPELL_ID) end, "ANCHOR_RIGHT")
  end

  panel:Input{
    key = Opt.THRESHOLD, label = "Threshold (stacks)",
    tooltip = "Stack count at which to alert. Default 4 = Rising Fury at the trinket window.",
    width = INPUT_W, x = TRIGGER_INPUT_X, numeric = true,
    validate = function(v) return v >= 1 and v <= 99 and math.floor(v) == v end,
  }
  panel:Input{
    key = Opt.STACK_INTERVAL, label = "Stack interval (s)",
    tooltip = "Seconds between stack ticks while the trigger is active. Default 6 for Rising Fury.",
    width = INPUT_W, x = TRIGGER_INPUT_X, numeric = true,
    validate = function(v) return v > 0 and v <= 60 end,
  }
  panel:Input{
    key = Opt.MIN_REMAINING, label = "Min linger remaining (s)",
    tooltip = "If the alert was deferred (out of combat) and you re-enter combat with less than this much linger left, suppress it: the trinket window is too short to matter. Default 2.",
    width = INPUT_W, x = TRIGGER_INPUT_X, numeric = true,
    validate = function(v) return v >= 0 and v <= 60 end,
  }
end

local function BuildSound(panel, win)
  local layout = panel.layout
  local pad = layout.pad
  local rightEdge = layout.inputX(0)   -- where every right-aligned control ends
  local browser

  -- A pick stages the sound and its label together; Defaults covers both
  -- through the selected-sound row's keys
  local function StageSound(value, entry)
    win:Stage(Opt.SOUND_ID, value)
    win:Stage(Opt.SOUND_LABEL, entry and entry.label or "")
  end

  -- Going from a Leatrix sound to any other asks first
  local replacePopup = UI.CreateDialogPopup({
    name = "ApexFuryReplaceLeatrixPopup",
    title = "Replace Leatrix sound?",
    width = 380,
    height = 160,
    parent = win,
    point = { "CENTER", win, "CENTER", 0, 0 },
    confirmText = "Replace",
    hidden = true,
    onConfirm = function(popup) StageSound(popup.pickValue, popup.pickEntry) end,
  })
  replacePopup:SetFrameStrata("FULLSCREEN_DIALOG")
  win:HookScript("OnHide", function() replacePopup:Hide() end)

  local function PickSound(value, entry)
    if IsLeatrixValue(win:Get(Opt.SOUND_ID)) and not IsLeatrixValue(value) then
      replacePopup.pickValue, replacePopup.pickEntry = value, entry
      replacePopup:SetBody(string.format(
        "You're currently using a Leatrix Sounds selection.\n\nReplace it with: |cFFFFD200%s|r?",
        CSound.StripColors(entry and entry.label or "")))
      replacePopup:Show()
      return
    end
    StageSound(value, entry)
  end

  panel:Section("Sound")

  -- Selected sound: label, test button, name over its source
  panel:Custom{
    height = SELECTED_ROW_H,
    keys = { Opt.SOUND_ID, Opt.SOUND_LABEL },
    build = function(row)
      local mid = -SELECTED_ROW_H / 2
      local label = row:CreateFontString(nil, "OVERLAY", Fonts.DATA)
      label:SetPoint("LEFT", row, "TOPLEFT", pad, mid)
      label:SetText("Selected:")
      UI.AddTooltip(label,
        "The sound that will play when the threshold is reached. Pick a different one in the browser below.",
        "ANCHOR_RIGHT")

      row.TestButton = UI.CreateIconButton(row, {
        size        = 22,
        texture     = "Interface\\COMMON\\VoiceChat-Speaker",
        vertexColor = { 0.7, 0.9, 1.0 },
        tooltip     = "Play the selected sound",
        point       = { "LEFT", row, "TOPLEFT", SOUND_VALUE_X - 28, mid },
        onClick     = function()
          ApexFury.Sound.Play(win:Get(Opt.SOUND_ID), win:Get(Opt.SOUND_CHANNEL))
        end,
      })

      row.SelectedLabel = row:CreateFontString(nil, "OVERLAY", Fonts.BODY)
      row.SelectedLabel:SetPoint("LEFT", row, "TOPLEFT", SOUND_VALUE_X, mid + 7)
      row.SelectedLabel:SetWidth(rightEdge - SOUND_VALUE_X)
      row.SelectedLabel:SetJustifyH("LEFT")
      row.SelectedLabel:SetWordWrap(false)

      row.SelectedSource = row:CreateFontString(nil, "OVERLAY", Fonts.SMALL)
      row.SelectedSource:SetPoint("LEFT", row, "TOPLEFT", SOUND_VALUE_X, mid - 7)
      row.SelectedSource:SetWidth(rightEdge - SOUND_VALUE_X)
      row.SelectedSource:SetJustifyH("LEFT")
      row.SelectedSource:SetWordWrap(false)
    end,
    refresh = function(row, w)
      PaintSelectedSound(row, w)
      if browser then browser:RefreshSelection() end
    end,
  }

  -- Leatrix Sounds integration, when that addon is present
  local hasLTS = ApexFury.Leatrix and ApexFury.Leatrix.IsAvailable()
  if hasLTS then
    panel:Custom{
      height = LEATRIX_ROW_H,
      build = function(row)
        local mid = -LEATRIX_ROW_H / 2
        local label = row:CreateFontString(nil, "OVERLAY", Fonts.DATA)
        label:SetPoint("LEFT", row, "TOPLEFT", pad, mid)
        label:SetText("Leatrix Sounds:")
        UI.AddTooltip(label,
          "Open the Leatrix Sounds browser, click any sound row in there, press Grab Sound, then press Apply to keep it as your alert.",
          "ANCHOR_RIGHT")

        row.OpenButton = UI.CreateButton(row, {
          size  = { 96, 22 },
          text  = "Open Leatrix",
          point = { "LEFT", row, "TOPLEFT", SOUND_VALUE_X - 6, mid },
          tooltip = "Open the Leatrix Sounds browser. Click any row in its list to mark it as your selection, then return here and press Grab Sound.",
          onClick = function() ApexFury.Leatrix.OpenPanel() end,
        })

        row.GrabButton = UI.CreateButton(row, {
          size  = { 96, 22 },
          text  = "Grab Sound",
          point = { "LEFT", row.OpenButton, "RIGHT", 6, 0 },
          tooltip = "Pick the row you most recently clicked in the Leatrix Sounds browser as the ApexFury alert sound. Press Apply to keep it.",
          onClick = function()
            local path, fdid = ApexFury.Leatrix.GrabSelected()
            if not fdid then
              ApexFury.Message("|cFFFFAA00Click a sound in the Leatrix list first, then press Grab Sound.|r")
              return
            end
            -- Going INTO a Leatrix sound never needs the replace confirmation
            StageSound("fdid:" .. fdid, { label = path or "" })
            ApexFury.Message(string.format(
              "Sound picked from Leatrix: |cFFFFD200%s|r |cFF888888(FileDataID %d)|r. Press Apply to keep it.",
              path or "?", fdid))
          end,
        })
      end,
    }
  end

  panel:Dropdown{
    key = Opt.SOUND_CHANNEL, label = "Audio channel:", inline = true, width = 160,
    tooltip = "Which WoW audio channel the alert sound plays on.\n\n"
      .. "|cFFFFD200Dialog|r (default): nearly empty bus in combat, best isolation. "
      .. "If you can't hear it, raise Audio > Dialog Volume in WoW settings.\n\n"
      .. "|cFFFFD200Master|r: routes through the root mixer alongside DBM-style alerts. "
      .. "Can be drowned out by short samples competing with combat audio.\n\n"
      .. "|cFFFFD200SFX|r: shares the bus with all combat sound effects, so it is the most likely to be masked.",
    labels = ApexFury.SOUND_CHANNELS,
    values = ApexFury.SOUND_CHANNELS,
    tooltips = {
      "Recommended. Nearly empty bus during combat: best chance of being heard. Uses your Dialog Volume slider.",
      "Routes alongside DBM-style critical alerts. Can be masked by simultaneous combat sounds.",
      "Shares the bus with combat sound effects: most likely to be drowned out.",
    },
  }

  panel:Custom{
    height = TIP_ROW_H,
    build = function(row)
      local tip = row:CreateFontString(nil, "OVERLAY", Fonts.SMALL)
      tip:SetPoint("TOPLEFT", row, "TOPLEFT", pad, -4)
      tip:SetWidth(rightEdge - pad)
      tip:SetJustifyH("LEFT")
      tip:SetWordWrap(true)
      if hasLTS then
        tip:SetText("|cFF888888Tip: ApexFury also supports |cFFFFD200LibSharedMedia|r|cFF888888 packs (Astral, Causese, etc.); install more for additional sounds.|r")
      else
        tip:SetText("|cFF888888Tip: Install |cFFFFD200Leatrix Sounds|r|cFF888888 (~275k FileDataIDs) or a |cFFFFD200LibSharedMedia|r|cFF888888 pack (Astral, Causese, etc.) for thousands more sounds.|r")
      end
      row.Tip = tip
    end,
  }

  -- The browser is a full-width section: it starts at this row, reaches down
  -- to the bottom of the panel's view (taking whatever height the rows above
  -- leave) and spans the panel, its own padding lining its search bar and
  -- list up with the section heading and divider. The rows stay shorter than
  -- the view, so the panel never scrolls and needs no room for its bar.
  local edge = pad - BROWSER_INNER_PAD
  panel:Custom{
    height = BROWSER_MIN_H,
    build = function(row)
      browser = UI.SoundBrowser.Create(row, {
        width  = layout.contentWidth - 2 * edge,
        height = BROWSER_MIN_H,
        persistenceKey = "apexfury_sound_browser",
        persistence = { savedVariable = "APEX_FURY_UI_STATE", path = "soundBrowserCols" },
        getCurrentValue = function() return win:Get(Opt.SOUND_ID) end,
        -- A row's preview plays where the alert will: the staged audio channel
        onPreview = function(value) ApexFury.Sound.Play(value, win:Get(Opt.SOUND_CHANNEL)) end,
        onSelect = PickSound,
      })
      browser:SetPoint("TOPLEFT", row, "TOPLEFT", edge, 0)
      browser:SetPoint("BOTTOMRIGHT", panel.content:GetParent(), "BOTTOMRIGHT", -edge, edge)
      row.Browser = browser
    end,
  }
end

-------------------------------------------------------------------------------
-- Window
-------------------------------------------------------------------------------
local function BuildWindow()
  window = UI.CreateSettingsWindow({
    name    = "ApexFuryOptionsWindow",
    title   = ApexFury.WrapBrand("ApexFury") .. " - Settings",
    config  = Config,
    width   = WINDOW_W,
    height  = WINDOW_H,
    persist = { svTable = GetUIState, key = "options" },
    message = ApexFury.Message,
    footerButtons = {
      {
        text = "Debug Log", width = 120,
        onClick = function()
          if ApexFury.DebugWindow then ApexFury.DebugWindow:Toggle() end
        end,
      },
      {
        text = "Overlay", width = 120,
        onClick = function()
          if ApexFury.Overlay and ApexFury.Overlay.Toggle then ApexFury.Overlay.Toggle() end
        end,
      },
    },
    categories = {
      { key = "behavior", label = "Behavior", build = BuildBehavior },
      { key = "trigger",  label = "Trigger",  build = BuildTrigger },
      { key = "sound",    label = "Sound",    build = BuildSound },
    },
  })
  return window
end

-------------------------------------------------------------------------------
-- Public API
-------------------------------------------------------------------------------

-- Repaints an open window after a change made outside it (nil: every setting)
function Config.NotifySettingsWindow(key)
  if window then window:NotifyConfigChanged(key) end
end

function Config.ToggleSettings()
  if not window then
    if InCombatLockdown() then
      -- Root rule: no CreateFrame in combat. The window is built on the
      -- first open, so refuse that open; nothing reopens it later.
      ApexFury.Message("The settings window can't open for the first time in combat. Try again after combat.")
      return
    end
    BuildWindow()
  end
  window:Toggle()
end
