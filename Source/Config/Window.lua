-------------------------------------------------------------------------------
-- ApexFury Settings Window
--
-- The suite's standard settings window (CobySuite.UI.CreateSettingsWindow):
-- a sidebar with Alert, Sound and Advanced, staged edits that Apply writes
-- through Config.Set, Undo edits, Defaults and the Guide button (the standard
-- footer). The addon is also listed under Options > AddOns with a button
-- that opens this window (CobySuite.UI.RegisterSettingsCategory).
--
-- Alert: a read-only status card (the talent gate's reading, in words and
-- tiles), Enable alerts, the stack tiles with a predicted timeline, and the
-- hold rules. Sound: the selected sound with Play sample, the audio channel
-- with an audibility check (the game's sound CVars), the optional Leatrix
-- Sounds row and an embedded CobySuite.UI.SoundBrowser. Advanced: the timing
-- model's numbers, read only until "Edit timing overrides", and the overlay,
-- debug log and verbose logging.
--
-- Every preview reads the staged values (window:Get) and never calls
-- Config.Set: a config change resets the watcher's cycle. The timeline
-- reads the settings and TalentGate.GetState() only, never an aura.
--
-- Built on the first open, not at load, because the sound catalog is
-- expensive; a first open in combat is refused (no CreateFrame in combat).
-- ApexFury has no config event bus, so Config/Main.lua calls
-- Config.NotifySettingsWindow from onSet and onReset, and TalentGate calls it
-- after every evaluation, so slash commands and talent changes repaint an
-- open window.
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

local ICONS = "Interface\\Icons\\"
local SPEAKER_TEXTURE = "Interface\\COMMON\\VoiceChat-Speaker"
local DRAGONRAGE_SPELL_ID = 375087
local RISING_FURY_SPELL_ID = 1271796
local ANIMOSITY_SPELL_ID = 375797

local MAX_STACKS_SHOWN = 10    -- the window's cap on Most stacks: one tile each
local MIN_REMAINING_MAX = 20   -- the slider's top: the default linger cap
local TIMING_KEYS = { Opt.SPELL_ID, Opt.STACK_INTERVAL, Opt.MAX_STACKS, Opt.LINGER_PER_STACK, Opt.LINGER_MAX }

local INPUT_W = 80
local TIMING_INPUT_X = 230     -- every Advanced input starts here, so the spell name fits beside the first
local SOUND_CARD_H = 52
local LEATRIX_ROW_H = 30
local LEATRIX_X = 140
local TIMELINE_H = 58
local BROWSER_MIN_H = 200      -- the row's own height; the browser itself reaches down to the panel's bottom
local BROWSER_INNER_PAD = 8    -- CobySuite.UI.SoundBrowser's own padding inside its frame

local AMBER = U.Colors.CAUTION_ORANGE
local RED = U.Colors.WARNING_RED
local GREEN = U.Colors.SUCCESS_GREEN
local GRAY = U.Colors.DISABLED_GRAY

local window
-- The Advanced page's timing values take edits only after "Edit timing
-- overrides"; closing the window locks them again
local editTiming = false

-- Window position lives in APEX_FURY_UI_STATE.options
local function GetUIState()
  APEX_FURY_UI_STATE = APEX_FURY_UI_STATE or {}
  return APEX_FURY_UI_STATE
end

local function IsLeatrixValue(value)
  return type(value) == "string" and value:find("^fdid:") ~= nil
end

-- A live field's body, its error logged: the kit runs live fields under
-- pcall and shows nothing when one throws, which would hide a bug
local function Safe(what, fn)
  return function(...)
    local ok, result = pcall(fn, ...)
    if ok then return result end
    ApexFury.Debug.Warn("CONFIG", "Settings window: %s failed: %s", what, tostring(result))
  end
end

local function SpellTexture(spellID)
  local ok, texture = pcall(C_Spell.GetSpellTexture, spellID)
  if ok and texture then return texture end
  return ApexFury.ICON
end

-- 18, 2.5, 0.1: whole seconds without a decimal point
local function Seconds(value)
  local text = string.format("%.1f", value or 0)
  return (text:gsub("%.0$", ""))
end

local function Gate()
  return ApexFury.GetTalentGate()
end

-- Whether the gate has read this character's talents (it starts at "unknown")
local function GateRead(gate)
  return gate ~= nil and gate.reason ~= "unknown" and gate.apiAvailable ~= false
end

-- Animosity known to be missing: only from a reading of a Devastation
-- character. The gate starts at hasAnimosity = false before it has read
-- anything, and leaves it false off Devastation.
local function AnimosityMissing(gate)
  return GateRead(gate) and gate.isDevastation and gate.hasAnimosity == false
end

-------------------------------------------------------------------------------
-- The timing model, from the staged values (window:Get)
-------------------------------------------------------------------------------

local function StagedNumber(win, key)
  local value = win:Get(key)
  if type(value) == "number" then return value end
  return Config.Defaults[key]
end

-- Seconds after the Dragonrage cast that the alert is timed for
local function AlertDelay(win, threshold)
  return math.max(0, ((threshold or StagedNumber(win, Opt.THRESHOLD)) - 1) * StagedNumber(win, Opt.STACK_INTERVAL))
end

-- How long Dragonrage must last for that alert (the watcher's check)
local function RequiredDuration(win, threshold)
  return AlertDelay(win, threshold) + ApexFury.Watcher.THRESHOLD_BUFFER
end

-- The longest Dragonrage can last: 18s without Animosity, and with it the
-- limit of 18 + 5 x 0.75^i over every empower
local function LongestDragonrage(gate)
  local base = ApexFury.Watcher.DR_BASE_DURATION
  if AnimosityMissing(gate) then return base end
  return base + ApexFury.Watcher.ANIMOSITY_EXTENSION / (1 - ApexFury.Watcher.ANIMOSITY_DIMINISHING)
end

-- Most stacks as configured (Advanced); the saved value may pass the tiles' 10
local function StackCap(win)
  return math.max(1, math.floor(StagedNumber(win, Opt.MAX_STACKS)))
end

-- How many stack tiles the Alert page shows
local function MaxStacks(win)
  return math.min(MAX_STACKS_SHOWN, StackCap(win))
end

-- Rising Fury rank 1 or 2, read on Devastation: the buff ends with Dragonrage
local function LowRank(gate)
  return GateRead(gate) and gate.isDevastation
    and type(gate.risingFuryRank) == "number" and gate.risingFuryRank >= 1 and gate.risingFuryRank < 3
end

-- The longest Rising Fury lasts after Dragonrage in the staged model
local function LongestLinger(get)
  local function n(key)
    local v = get(key)
    if type(v) == "number" then return v end
    return Config.Defaults[key]
  end
  return math.min(n(Opt.LINGER_MAX), n(Opt.MAX_STACKS) * n(Opt.LINGER_PER_STACK))
end

-- The most stacks every Dragonrage reaches without an extension
local function StacksWithoutExtension(win)
  return ApexFury.Watcher.StacksWithoutExtension(StagedNumber(win, Opt.STACK_INTERVAL))
end

-------------------------------------------------------------------------------
-- Alert: the status card
-------------------------------------------------------------------------------

-- The card's state: its words, the dot's color and the line under it
local function StatusOf(win)
  local gate = Gate()
  if not win:Get(Opt.ENABLED) then
    return "Alerts are off", GRAY, "Tick Enable alerts below to turn them back on."
  end
  if not GateRead(gate) then
    return "Talent check incomplete", AMBER,
      "Your talents haven't loaded yet. ApexFury checks again when you change talents or zones."
  end
  if gate.reason == "wrong_class" then
    return "Off on this character", GRAY, "ApexFury works for Devastation Evokers with the Rising Fury talent."
  elseif gate.reason == "wrong_spec" then
    return "Off on this character", GRAY, "Switch to Devastation to turn it on."
  elseif gate.reason == "no_rising_fury" then
    return "Off on this character", GRAY, "Take the Rising Fury talent to turn it on."
  end
  local threshold = StagedNumber(win, Opt.THRESHOLD)
  if gate.hasAnimosity == false then
    if RequiredDuration(win) > ApexFury.Watcher.DR_BASE_DURATION then
      return "Ready, but this alert can't play", AMBER, string.format(
        "Without Animosity, Dragonrage ends before stack %d. Pick %d stacks or fewer below.",
        threshold, StacksWithoutExtension(win))
    end
    return "Ready", GREEN, "Without Animosity, Dragonrage lasts 18 seconds."
  end
  if RequiredDuration(win) > LongestDragonrage(gate) then
    return "Ready, but this alert can't play", AMBER, string.format(
      "Dragonrage can't last until stack %d. Pick an earlier stack below.", threshold)
  end
  if threshold > StackCap(win) then
    return "Ready, past the stack cap", AMBER, string.format(
      "Timed for stack %d at +%ss, past the %d stacks Rising Fury reaches. It still plays if Dragonrage lasts that long.",
      threshold, Seconds(AlertDelay(win)), StackCap(win))
  end
  if gate.hasAnimosity == nil then
    return "Talent check incomplete", AMBER,
      "Animosity not found yet, so timings assume you have it until the check finishes."
  end
  return "Ready", GREEN, string.format("The alert is timed for stack %d of Rising Fury.", threshold)
end

-- The three talent tiles: state, the word on the tile, and its line
local function SpecTile(field)
  local gate = Gate()
  if not GateRead(gate) then
    return ({ state = "unknown", word = "Checking", text = "Not loaded yet" })[field]
  end
  if gate.isDevastation then
    return ({ state = "ok", word = "Active", text = "Your current spec" })[field]
  end
  if gate.isEvoker == false then
    return ({ state = "off", word = "Not active", text = "An Evoker spec" })[field]
  end
  return ({ state = "off", word = "Not active", text = "Switch to it to use ApexFury" })[field]
end

local function RisingFuryTile(field)
  local gate = Gate()
  if not GateRead(gate) then
    return ({ state = "unknown", word = "Checking", text = "Not loaded yet" })[field]
  end
  -- off Devastation the gate doesn't read the talents: say so, not "Checking"
  if not gate.isDevastation then
    return ({ state = "unknown", word = "Not checked", text = "Read on Devastation only" })[field]
  end
  local rank = gate.risingFuryRank or 0
  if rank >= 1 then
    local text = rank >= 3 and "Stacks stay after Dragonrage" or "Stacks end with Dragonrage"
    if field == "tip" then
      local of = type(gate.risingFuryMaxRank) == "number" and gate.risingFuryMaxRank >= rank
        and (" of " .. gate.risingFuryMaxRank) or ""
      return "Rising Fury: rank " .. rank .. of .. ". " .. text .. "."
    end
    return ({ state = "ok", word = "Rank " .. rank, text = text })[field]
  end
  return ({ state = "off", word = "Not taken", text = "Needed: it is the buff ApexFury times" })[field]
end

local function AnimosityTile(field)
  local gate = Gate()
  if GateRead(gate) and not gate.isDevastation then
    return ({ state = "unknown", word = "Not checked", text = "Read on Devastation only" })[field]
  end
  if not GateRead(gate) or gate.hasAnimosity == nil then
    return ({ state = "unknown", word = "Not found yet", text = "Assumed until the check finishes" })[field]
  end
  if gate.hasAnimosity then
    return ({ state = "ok", word = "Talented", text = "Your empowers make Dragonrage last longer" })[field]
  end
  return ({ state = "warn", word = "Not taken", text = string.format("Dragonrage stops at %d stacks", StacksWithoutExtension(window)) })[field]
end

local function TalentTile(title, iconID, read)
  return {
    title = title,
    icon = function() return SpellTexture(iconID) end,
    state = Safe("talent tile", function() return read("state") end),
    stateText = Safe("talent tile", function() return read("word") end),
    description = Safe("talent tile", function() return read("text") end),
    tooltip = Safe("talent tile", function()
      return read("tip") or (title .. ": " .. read("word") .. ". " .. read("text") .. ".")
    end),
  }
end

local function BuildStatus(panel, win)
  panel:BeginCard{
    title = "This character",
    icon = ApexFury.ICON,
    description = Safe("status", function() local words = StatusOf(win); return words end),
    dot = Safe("status dot", function() local _, color = StatusOf(win); return color end),
  }
  panel:Note{ text = Safe("status line", function() local _, _, line = StatusOf(win); return line end) }
  panel:StatusTiles{
    -- two across: at three, the state word leaves the title too little room
    columns = 2,
    options = {
      TalentTile("Devastation", DRAGONRAGE_SPELL_ID, SpecTile),
      TalentTile("Rising Fury", RISING_FURY_SPELL_ID, RisingFuryTile),
      TalentTile("Animosity", ANIMOSITY_SPELL_ID, AnimosityTile),
    },
  }
  panel:EndCard()

  panel:Checkbox{
    key = Opt.ENABLED, label = "Enable alerts",
    tooltip = "Turn the alert on or off for every character.",
    description = "Off: ApexFury ignores Dragonrage and plays nothing.",
  }
end

-------------------------------------------------------------------------------
-- Alert: the stack tiles and the predicted timeline
-------------------------------------------------------------------------------

local function StackTile(win, n, default, gate)
  local delay = AlertDelay(win, n)
  local needsAnimosity = AnimosityMissing(gate)
    and RequiredDuration(win, n) > ApexFury.Watcher.DR_BASE_DURATION
  local text = "+" .. Seconds(delay) .. "s"
  local tooltip = delay > 0
    and string.format("Play the alert when Rising Fury's stack %d lands, %s seconds after you cast Dragonrage.", n, Seconds(delay))
    or string.format("Play the alert when Rising Fury's stack %d lands, as you cast Dragonrage.", n)
  if needsAnimosity then
    text = text .. ", needs Animosity"
    tooltip = tooltip .. " Without Animosity, Dragonrage ends first, so this alert can't play."
  end
  return {
    value = n,
    icon = ApexFury.ICON,
    count = tostring(n),
    title = n == 1 and "1 stack" or (n .. " stacks"),
    description = text,
    badge = n == default and "Default" or nil,
    dim = needsAnimosity,
    tooltip = tooltip,
  }
end

-- A saved threshold past the tiles: still timed (the watcher checks only
-- Dragonrage's length). Past Most stacks it is past Rising Fury's last
-- stack; within it (a saved Most stacks above the 10 tiles) it is only
-- past the tiles.
local function CustomStackTile(win, threshold)
  local delay = AlertDelay(win, threshold)
  local cap = StackCap(win)
  local tile = {
    value = threshold,
    icon = ApexFury.ICON,
    count = tostring(threshold),
    title = "Custom: " .. threshold,
  }
  if threshold > cap then
    tile.description = string.format("+%ss, past the cap of %d", Seconds(delay), cap)
    tile.warn = true
    tile.tooltip = string.format("Your saved stack, past the %d stacks Rising Fury reaches: the alert comes %s seconds after the cast if Dragonrage lasts that long. Click another tile to replace it.",
      cap, Seconds(delay))
  else
    tile.description = string.format("+%ss, your saved stack", Seconds(delay))
    tile.tooltip = string.format("Your saved stack: the alert comes %s seconds after the cast. Click another tile to replace it.",
      Seconds(delay))
  end
  return tile
end

local function StackTiles(_, win)
  local maxStacks = MaxStacks(win)
  local default = Config.Defaults[Opt.THRESHOLD]
  local gate = Gate()
  local list = {}
  for n = 1, maxStacks do list[n] = StackTile(win, n, default, gate) end
  local threshold = win:Get(Opt.THRESHOLD)
  if type(threshold) == "number" and threshold > maxStacks then
    list[#list + 1] = CustomStackTile(win, threshold)
  end
  return list
end

-- The timeline's frames, made once with the window
local function BuildTimeline(box)
  local light = U.Colors.LIGHT_GRAY
  box.Track = box:CreateTexture(nil, "BACKGROUND", nil, 1)
  local bg = U.Colors.BAR_BG
  box.Track:SetColorTexture(bg[1], bg[2], bg[3], bg[4])
  box.Base = box:CreateTexture(nil, "ARTWORK")
  box.Extension = box:CreateTexture(nil, "ARTWORK")
  box.BaseText = box:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  box.Ticks, box.TickText = {}, {}
  for i = 1, MAX_STACKS_SHOWN do
    local tick = box:CreateTexture(nil, "OVERLAY")
    tick:SetColorTexture(light[1], light[2], light[3], 0.8)
    tick:SetSize(1, 16)
    box.Ticks[i] = tick
    local label = box:CreateFontString(nil, "OVERLAY", Fonts.DATA)
    box.TickText[i] = label
  end
  box.Marker = box:CreateTexture(nil, "OVERLAY", nil, 2)
  box.Marker:SetSize(2, 38)
  box.Speaker = box:CreateTexture(nil, "OVERLAY")
  box.Speaker:SetSize(14, 14)
  box.Speaker:SetTexture(SPEAKER_TEXTURE)
  box.MarkerText = box:CreateFontString(nil, "OVERLAY", Fonts.SMALL)

  box.Play = UI.CreateButton(box, {
    size = { 100, 22 }, text = "Play sample",
    point = { "RIGHT", box, "RIGHT", -8, 0 },
    tooltip = "Play your alert sound on the audio channel you picked under Sound.",
    onClick = function()
      ApexFury.Sound.Play(window:Get(Opt.SOUND_ID), window:Get(Opt.SOUND_CHANNEL))
    end,
  })
end

-- From the top: the marker's speaker and time, the stack numbers, the bar,
-- then the Dragonrage caption under it
local TRACK_Y, TRACK_H = -28, 10

-- One segment of the bar, from t0 to t1 seconds
local function PlaceSegment(texture, box, x, scale, t0, t1)
  local width = math.max(0, (t1 - t0) * scale)
  texture:SetShown(width >= 1)
  texture:ClearAllPoints()
  texture:SetPoint("TOPLEFT", box, "TOPLEFT", x + t0 * scale, TRACK_Y)
  texture:SetSize(math.max(1, width), TRACK_H)
end

local function PaintTimeline(box, win)
  local barW = box:GetWidth() - 8 - 120
  if barW <= 20 then return end
  local gate = Gate()
  local base = ApexFury.Watcher.DR_BASE_DURATION
  local longest = LongestDragonrage(gate)
  local delay = AlertDelay(win)
  local span = math.min(120, math.max(longest, delay + 3))
  local scale, x = barW / span, 8

  PlaceSegment(box.Track, box, x, scale, 0, span)
  local c = U.Colors.CAUTION_ORANGE
  box.Base:SetColorTexture(c[1], c[2], c[3], 0.9)
  PlaceSegment(box.Base, box, x, scale, 0, base)
  box.Extension:SetColorTexture(c[1], c[2], c[3], 0.3)
  PlaceSegment(box.Extension, box, x, scale, base, longest)
  box.BaseText:ClearAllPoints()
  box.BaseText:SetPoint("TOPLEFT", box, "TOPLEFT", x, TRACK_Y - TRACK_H - 2)
  box.BaseText:SetText(longest > base and "Dragonrage 18s, longer with Animosity" or "Dragonrage 18s")

  local interval = StagedNumber(win, Opt.STACK_INTERVAL)
  for i, tick in ipairs(box.Ticks) do
    local t = (i - 1) * interval
    local shown = i <= MaxStacks(win) and t <= span
    tick:SetShown(shown)
    -- the alert's own stack is named by the marker above it
    box.TickText[i]:SetShown(shown and i ~= StagedNumber(win, Opt.THRESHOLD))
    if shown then
      tick:ClearAllPoints()
      tick:SetPoint("TOP", box, "TOPLEFT", x + t * scale, TRACK_Y + 3)
      box.TickText[i]:ClearAllPoints()
      box.TickText[i]:SetPoint("BOTTOM", tick, "TOP", 0, 1)
      box.TickText[i]:SetText(tostring(i))
    end
  end

  local reachable = RequiredDuration(win) <= longest
  local color = reachable and U.Colors.STATUS_GOLD or RED
  box.Marker:SetColorTexture(color[1], color[2], color[3], 1)
  box.Marker:ClearAllPoints()
  box.Marker:SetPoint("TOP", box, "TOPLEFT", x + math.min(delay, span) * scale, -2)
  box.Speaker:ClearAllPoints()
  box.Speaker:SetPoint("TOPLEFT", box.Marker, "TOPRIGHT", 3, 0)
  box.MarkerText:ClearAllPoints()
  box.MarkerText:SetPoint("LEFT", box.Speaker, "RIGHT", 2, 0)
  box.MarkerText:SetText(U.WrapColor(color, "+" .. Seconds(delay) .. "s"))
end

-- The line under the timeline: what the alert needs from Dragonrage
local function TimelineNote(win)
  local gate = Gate()
  local need = RequiredDuration(win)
  local base = ApexFury.Watcher.DR_BASE_DURATION
  if need <= base then
    return "Every Dragonrage reaches this stack. The hold rules below still apply."
  end
  if AnimosityMissing(gate) then
    return U.WrapColor(AMBER, string.format(
      "Without Animosity, Dragonrage ends at %ss, so this alert can't play. Pick %d stacks or fewer.",
      Seconds(base), StacksWithoutExtension(win)))
  end
  local longest = LongestDragonrage(gate)
  if need > longest then
    return U.WrapColor(RED, string.format("Dragonrage can't last until +%ss, so this alert can't play. Pick an earlier stack.",
      Seconds(AlertDelay(win))))
  end
  return string.format(
    "Plays only if Dragonrage lasts longer than %ss. Each Fire Breath or Eternity Surge you finish during it adds time (Animosity).",
    Seconds(AlertDelay(win)))
end

local function BuildStacks(panel, win)
  panel:Section("When the alert plays", { icon = ApexFury.ICON })
  panel:Tiles{
    key = Opt.THRESHOLD,
    columns = 3,
    maxTiles = MAX_STACKS_SHOWN + 1,
    options = Safe("stack tiles", StackTiles),
    description = Safe("stack tiles", function(w)
      local default = Config.Defaults[Opt.THRESHOLD]
      local picked = StagedNumber(w, Opt.THRESHOLD)
      local delay = AlertDelay(w, picked)
      local when = delay > 0 and (Seconds(delay) .. " seconds after you cast Dragonrage") or "as you cast Dragonrage"
      if picked == default then
        return string.format("Picked: stack %d, %s (the default).", picked, when)
      end
      return string.format("Picked: stack %d, %s. %d is the default.", picked, when, default)
    end),
  }
  panel:Preview{
    caption = "Example: predicted alert time",
    height = TIMELINE_H,
    build = function(box)
      BuildTimeline(box)
      -- The box has no width until the panel lays it out: paint again then
      local paint = Safe("timeline", PaintTimeline)
      box:SetScript("OnSizeChanged", function(b) paint(b, win) end)
    end,
    refresh = Safe("timeline", PaintTimeline),
  }
  panel:Note{ text = Safe("timeline note", TimelineNote) }
end

-------------------------------------------------------------------------------
-- Alert: holding the alert
-------------------------------------------------------------------------------

local function EitherHold(get)
  return get(Opt.COMBAT_ONLY) or get(Opt.ACTIONABILITY_GATE)
end

local function BuildHold(panel)
  panel:Section("If you can't act on it right away", {
    icon = ICONS .. "INV_Misc_PocketWatch_01",
    subtitle = "If the stack lands when you can't act on it, ApexFury can hold the alert.",
  })
  panel:Checkbox{
    key = Opt.COMBAT_ONLY, label = "Hold the alert until I'm in combat",
    tooltip = "An alert that comes while you're out of combat waits for combat.",
    description = "Out of combat when the stack lands? It plays as you enter combat. Off: it plays right away.",
  }
  panel:Checkbox{
    key = Opt.ACTIONABILITY_GATE, label = "Hold the alert until I can act",
    tooltip = "An alert that comes while you can't act waits until you can.",
    description = "In a vehicle, mounted, stunned, feared or mind-controlled? It plays once you're back in control. Off: it plays right away.",
  }
  panel:Slider{
    key = Opt.MIN_REMAINING, label = "Skip a held alert with less than",
    tooltip = "A held alert that comes after Dragonrage ends needs this much Rising Fury left, or it is skipped. An alert never plays once Rising Fury has ended.",
    min = 0, max = MIN_REMAINING_MAX, step = 0.5,
    format = function(v) return Seconds(v) .. "s of Rising Fury left" end,
    customText = function(v) return "Custom: " .. Seconds(v) .. "s of Rising Fury left" end,
    minLabel = "0s: no minimum", maxLabel = Seconds(MIN_REMAINING_MAX) .. "s",
    description = "A held alert that comes after Dragonrage ends plays only while at least this much Rising Fury is left.",
    -- at rank 1 or 2 nothing is left after Dragonrage, so it never applies
    enabledWhen = function(get) return EitherHold(get) and not LowRank(Gate()) end,
  }
  panel:Note{
    text = "Your Rising Fury rank ends the buff with Dragonrage, so a held alert never plays after it. Rank 3 or higher keeps it a few seconds longer.",
    visibleWhen = function() return LowRank(Gate()) end,
  }
  panel:Note{
    text = Safe("linger note", function(win)
      return U.WrapColor(AMBER, string.format(
        "Rising Fury lasts at most %ss after Dragonrage, so a held alert can only play during Dragonrage.",
        Seconds(LongestLinger(function(key) return win:Get(key) end))))
    end),
    visibleWhen = function(get)
      return EitherHold(get) and not LowRank(Gate())
        and (get(Opt.MIN_REMAINING) or 0) > LongestLinger(get)
    end,
  }
end

local function BuildAlert(panel, win)
  BuildStatus(panel, win)
  BuildStacks(panel, win)
  BuildHold(panel)
end

-------------------------------------------------------------------------------
-- Sound: the selected sound
-------------------------------------------------------------------------------

-- A display entry for a sound value: the catalog entry (Blizzard SoundKit
-- and LibSharedMedia) when there is one, otherwise one built from the value.
-- A Leatrix fdid:N value is never in the catalog, so its label is the
-- SOUND_LABEL that goes with it (label; the Leatrix row saves the file path).
local function SoundEntryFor(id, label)
  for _, e in ipairs(CSound.GetEntries()) do
    if e.value == id then return e end
  end
  local kind, _, fallbackLabel = CSound.Resolve(id)
  local source = "Custom"
  if kind == "soundkit"    then source = "Blizzard"       end
  if kind == "fdid"        then source = "Leatrix"        end
  if kind == "lsm"         then source = "LibSharedMedia" end
  if kind == "lsm_missing" then source = "Pack not installed" end
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

-- The line under the selected sound uses the shared sound browser's words
-- for the catalog's data names; the Leatrix and source-only ones are ours
local function SelectedSourceText(source)
  if source == "LibSharedMedia" then return "Sound pack" end
  if source == "Leatrix" then return "From Leatrix Sounds" end
  return UI.SoundBrowser.PackLabel(source)
end

local function SelectedKindText(kind)
  if kind == "FileDataID" then return "Game sound file" end
  return UI.SoundBrowser.KindLabel(kind)
end

-- A Leatrix pick's label is the sound file's path: its name without the
-- folders and extension reads better ("sound/interface/readycheck.ogg" ->
-- "readycheck"); the path stays saved and shows in the label's tooltip
local function FileName(path)
  local name = path:match("([^/\\]+)$") or path
  return (name:gsub("%.%w+$", ""))
end

local function PaintSelectedSound(row, win)
  local entry = SoundEntryFor(win:Get(Opt.SOUND_ID), win:Get(Opt.SOUND_LABEL))
  local label = entry.label
  local path = entry.kind == "FileDataID" and type(label) == "string" and label:find("[/\\]") and label or nil
  row.SelectedLabel:SetText(path and FileName(path) or label or "|cFFAAAAAA(unknown)|r")
  if path and row.PathHover.path ~= path then
    UI.AddTooltip(row.PathHover, "Sound file: " .. path, "ANCHOR_RIGHT")
  end
  row.PathHover.path = path
  row.PathHover:EnableMouse(path ~= nil)
  local source = entry.pack or entry.source or ""
  if source == "Pack not installed" then
    -- the alert falls back to the default sound (ApexFury.Sound.Play)
    row.SelectedSource:SetText(U.WrapColor(AMBER, string.format(
      "Pack not installed: the alert plays %s until it's back", U.StripColors(ApexFury.Sound.DefaultLabel()))))
  else
    local line = SelectedSourceText(source) .. " · " .. SelectedKindText(entry.kind or "")
    row.SelectedSource:SetText("|cFF888888" .. line .. "|r")
  end
end

local function BuildSoundCard(panel, win, getBrowser)
  local pad = panel.layout.pad
  local rightEdge = panel.layout.inputX(0)
  panel:Custom{
    height = SOUND_CARD_H,
    keys = { Opt.SOUND_ID, Opt.SOUND_LABEL },
    build = function(row)
      local mid = -SOUND_CARD_H / 2
      row.Play = UI.CreateButton(row, {
        size = { 120, 26 }, text = "Play sample",
        point = { "LEFT", row, "TOPLEFT", pad, mid },
        tooltip = "Play this sound on the audio channel picked below, the way the alert plays it.",
        onClick = function()
          ApexFury.Sound.Play(win:Get(Opt.SOUND_ID), win:Get(Opt.SOUND_CHANNEL))
        end,
      })
      local speaker = row.Play:CreateTexture(nil, "OVERLAY")
      speaker:SetSize(16, 16)
      speaker:SetPoint("LEFT", row.Play, "LEFT", 8, 0)
      speaker:SetTexture(SPEAKER_TEXTURE)
      local text = row.Play:GetFontString()
      text:ClearAllPoints()
      text:SetPoint("CENTER", row.Play, "CENTER", 9, 0)

      local valueX = pad + 120 + 14
      row.SelectedLabel = row:CreateFontString(nil, "OVERLAY", Fonts.TITLE)
      row.SelectedLabel:SetPoint("LEFT", row, "TOPLEFT", valueX, mid + 8)
      row.SelectedLabel:SetWidth(rightEdge - valueX)
      row.SelectedLabel:SetJustifyH("LEFT")
      row.SelectedLabel:SetWordWrap(false)

      -- A Leatrix pick's full file path, on hover over its name
      local hover = CreateFrame("Frame", nil, row)
      hover:SetAllPoints(row.SelectedLabel)
      hover:EnableMouse(false)
      row.PathHover = hover

      row.SelectedSource = row:CreateFontString(nil, "OVERLAY", Fonts.DATA)
      row.SelectedSource:SetPoint("LEFT", row, "TOPLEFT", valueX, mid - 10)
      row.SelectedSource:SetWidth(rightEdge - valueX)
      row.SelectedSource:SetJustifyH("LEFT")
      row.SelectedSource:SetWordWrap(false)
    end,
    refresh = function(row, w)
      PaintSelectedSound(row, w)
      local browser = getBrowser()
      if browser then browser:RefreshSelection() end
    end,
  }
end

-------------------------------------------------------------------------------
-- Sound: the audio channel and whether it can be heard
-------------------------------------------------------------------------------

local CHANNEL_CVARS = {
  Dialog = { name = "Dialog", enable = "Sound_EnableDialog", volume = "Sound_DialogVolume" },
  SFX    = { name = "Sound effects", enable = "Sound_EnableSFX", volume = "Sound_SFXVolume" },
}

local function CVarOn(name)
  if not C_CVar then return nil end
  local ok, value = pcall(C_CVar.GetCVarBool, name)
  if ok then return value end
end

local function CVarVolume(name)
  if not C_CVar then return nil end
  local ok, value = pcall(C_CVar.GetCVar, name)
  value = ok and tonumber(value)
  if U.IsFiniteNumber(value) then return value end
end

local function Percent(volume)
  return string.format("%d%%", math.floor(volume * 100 + 0.5))
end

-- The first thing that keeps the alert silent on this channel, in the order
-- the game's mixer applies them; otherwise the volumes and "play a sample"
local function Audibility(win)
  local fix = " Change it in the game's Sound settings."
  if CVarOn("Sound_EnableAllSound") == false then
    return U.WrapColor(AMBER, "All game sound is off, so the alert is silent." .. fix)
  end
  local master = CVarVolume("Sound_MasterVolume")
  if master and master <= 0 then
    return U.WrapColor(AMBER, "Master volume is 0%, so the alert is silent." .. fix)
  end
  local channel = CHANNEL_CVARS[win:Get(Opt.SOUND_CHANNEL)]
  local parts = { master and ("Master " .. Percent(master)) or nil }
  if channel then
    if CVarOn(channel.enable) == false then
      return U.WrapColor(AMBER, channel.name .. " sound is off, so the alert is silent." .. fix)
    end
    local volume = CVarVolume(channel.volume)
    if volume and volume <= 0 then
      return U.WrapColor(AMBER, channel.name .. " volume is 0%, so the alert is silent." .. fix)
    end
    if volume then parts[#parts + 1] = channel.name .. " " .. Percent(volume) end
  end
  local volumes = table.concat(parts, ", ")
  if volumes ~= "" then volumes = volumes .. ": nothing is muted. " end
  return volumes .. "Play a sample to check you can hear it."
end

local function BuildChannel(panel, win)
  local row = panel:Radio{
    key = Opt.SOUND_CHANNEL, inline = true, label = "Play it on", labelWidth = 90,
    tooltip = "The game volume channel the alert plays on.",
    options = {
      { value = "Dialog", label = "Dialog",
        tooltip = "The default. Little else plays on it in combat, so the alert stands out. Follows your Dialog volume." },
      { value = "Master", label = "Master",
        tooltip = "Plays with every other game sound; busy fights can cover it. Follows your Master volume only." },
      { value = "SFX", label = "Sound effects",
        tooltip = "Shares the channel with spell and combat effects, so it is the easiest to miss. Follows your Effects volume." },
    },
    description = Safe("audibility", Audibility),
  }
  -- A volume changed in the game's Sound settings while this window is open
  row:RegisterEvent("CVAR_UPDATE")
  row:SetScript("OnEvent", function()
    if win:IsShown() then win:RefreshState() end
  end)
end

-------------------------------------------------------------------------------
-- Sound: Leatrix Sounds, the tip and the browser
-------------------------------------------------------------------------------

local function BuildLeatrix(panel, stageSound)
  local pad = panel.layout.pad
  panel:Custom{
    height = LEATRIX_ROW_H,
    build = function(row)
      local mid = -LEATRIX_ROW_H / 2
      local label = row:CreateFontString(nil, "OVERLAY", Fonts.DATA)
      label:SetPoint("LEFT", row, "TOPLEFT", pad, mid)
      label:SetText("Leatrix Sounds:")
      row.Label = label
      UI.AddTooltip(label,
        "Open Leatrix Sounds, click any sound in its list, then come back and press Use the sound I clicked.",
        "ANCHOR_RIGHT")

      row.OpenButton = UI.CreateButton(row, {
        size  = { 110, 22 },
        text  = "Open Leatrix",
        point = { "LEFT", row, "TOPLEFT", LEATRIX_X, mid },
        tooltip = "Open Leatrix Sounds and click any sound in its list.",
        onClick = function() ApexFury.Leatrix.OpenPanel() end,
      })

      row.GrabButton = UI.CreateButton(row, {
        size  = { 170, 22 },
        text  = "Use the sound I clicked",
        point = { "LEFT", row.OpenButton, "RIGHT", 6, 0 },
        tooltip = "Use the sound you last clicked in Leatrix Sounds. Press Apply to keep it.",
        onClick = function()
          local path, fdid = ApexFury.Leatrix.GrabSelected()
          if not fdid then
            ApexFury.Message("|cFFFFAA00Click a sound in the Leatrix list first, then press Use the sound I clicked.|r")
            return
          end
          -- Going INTO a Leatrix sound never needs the replace confirmation
          stageSound("fdid:" .. fdid, { label = path or "" })
          ApexFury.Message(string.format(
            "Sound picked from Leatrix: |cFFFFD200%s|r |cFF888888(FileDataID %d)|r. Press Apply to keep it.",
            path or "?", fdid))
        end,
      })
    end,
  }
end

-- Sound packs found: every catalog sound that isn't one of the game's own
local function HasSoundPacks()
  local ok, _, _, total = pcall(CSound.GetSourceCounts)
  if not ok or type(total) ~= "number" then return true end
  return total > (CSound.GetSourceCount("Blizzard") or 0)
end

local function BuildBrowser(panel, win, pickSound, setBrowser)
  local layout = panel.layout
  -- The browser is a full-width section: it starts at this row, reaches down
  -- to the bottom of the panel's view (taking whatever height the rows above
  -- leave) and spans the panel, its own padding lining its search bar and
  -- list up with the section heading and divider. The rows stay shorter than
  -- the view, so the panel never scrolls and needs no room for its bar.
  local edge = layout.pad - BROWSER_INNER_PAD
  panel:Custom{
    height = BROWSER_MIN_H,
    build = function(row)
      local browser = UI.SoundBrowser.Create(row, {
        width  = layout.contentWidth - 2 * edge,
        height = BROWSER_MIN_H,
        persistenceKey = "apexfury_sound_browser",
        persistence = { savedVariable = "APEX_FURY_UI_STATE", path = "soundBrowserCols" },
        getCurrentValue = function() return win:Get(Opt.SOUND_ID) end,
        -- A row's preview plays where the alert will: the staged audio channel
        onPreview = function(value) ApexFury.Sound.Play(value, win:Get(Opt.SOUND_CHANNEL)) end,
        onSelect = pickSound,
      })
      browser:SetPoint("TOPLEFT", row, "TOPLEFT", edge, 0)
      browser:SetPoint("BOTTOMRIGHT", panel.content:GetParent(), "BOTTOMRIGHT", -edge, edge)
      setBrowser(browser)
    end,
  }
end

local function BuildSound(panel, win)
  local browser

  -- A pick stages the sound and its label together; Defaults covers both
  -- through the sound card's keys
  local function StageSound(value, entry)
    win:Stage(Opt.SOUND_ID, value)
    win:Stage(Opt.SOUND_LABEL, entry and entry.label or "")
  end

  -- Going from a Leatrix sound to any other asks first
  local replacePopup = UI.CreateDialogPopup({
    name = "ApexFuryReplaceLeatrixPopup",
    icon = ApexFury.ICON,
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
        U.StripColors(entry and entry.label or "")))
      replacePopup:Show()
      return
    end
    StageSound(value, entry)
  end

  panel:Section("Your alert sound", { icon = ICONS .. "INV_Misc_Note_01" })
  BuildSoundCard(panel, win, function() return browser end)
  BuildChannel(panel, win)

  local hasLTS = ApexFury.Leatrix and ApexFury.Leatrix.IsAvailable()
  if hasLTS then BuildLeatrix(panel, StageSound) end
  panel:Note{
    text = hasLTS and "Want more sounds? Install a LibSharedMedia sound pack."
      or "Want more sounds? Install a LibSharedMedia sound pack or Leatrix Sounds.",
    visibleWhen = function() return not HasSoundPacks() end,
  }

  BuildBrowser(panel, win, PickSound, function(b) browser = b end)
end

-------------------------------------------------------------------------------
-- Advanced: the timing model
-------------------------------------------------------------------------------

local function TimingEditable() return editTiming end

-- The spell's icon and name beside the spell ID input, with its tooltip
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

local function AddSpellDisplay(panel, spellRow, win)
  local iconSize = U.EditBoxHeight.INPUT
  local nameX = TIMING_INPUT_X + INPUT_W + 8 + iconSize + 6
  local nameW = panel.layout.inputX(0) - nameX

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
  spellRow.SpellHover = hover
end

local function TimingInput(panel, key, label, tooltip, validate)
  return panel:Input{
    key = key, label = label, tooltip = tooltip,
    width = INPUT_W, x = TIMING_INPUT_X, numeric = true,
    validate = validate,
    enabledWhen = TimingEditable,
  }
end

local function AnyTimingChanged(get)
  for _, key in ipairs(TIMING_KEYS) do
    if get(key) ~= Config.Defaults[key] then return true end
  end
  return false
end

local function RestoreTimingDefaults(win)
  for _, key in ipairs(TIMING_KEYS) do
    win:StageValue(key, Config.Defaults[key])
  end
  win:Populate(win.getter)
end

local function BuildTimingLock(panel, win)
  panel:Button{
    text = "Edit timing overrides", width = 200,
    tooltip = "Unlock the numbers below. They lock again when the window closes.",
    onClick = function()
      editTiming = not editTiming
    end,
    refresh = function(row)
      row.Button:SetText(editTiming and "Lock timing overrides" or "Edit timing overrides")
    end,
  }
  win:HookScript("OnHide", function() editTiming = false end)
  panel:Note{
    text = "Change these only if a patch changed Rising Fury before ApexFury caught up. Wrong numbers mean wrong alert times.",
    color = AMBER,
    visibleWhen = TimingEditable,
  }
end

local function BuildTiming(panel, win)
  panel:Section("Timing model", {
    icon = ICONS .. "INV_Misc_Gear_01",
    subtitle = "The numbers ApexFury times Rising Fury with. They match the game as ApexFury knows it.",
  })
  BuildTimingLock(panel, win)

  local spellRow = panel:Input{
    key = Opt.SPELL_ID, label = "Starts the timer",
    tooltip = "The cast that starts the timer: Dragonrage. ApexFury's timing is built around it.",
    width = INPUT_W, x = TIMING_INPUT_X, numeric = true, maxLetters = 10,
    validate = function(v) return v > 0 and math.floor(v) == v end,
    enabledWhen = TimingEditable,
    refresh = function(row, w) PaintSpell(row, w:Get(Opt.SPELL_ID)) end,
  }
  AddSpellDisplay(panel, spellRow, win)
  panel:Note{
    text = "Not Dragonrage: ApexFury's timing is built for Dragonrage, so alerts will come at the wrong time.",
    color = RED,
    visibleWhen = function(get) return get(Opt.SPELL_ID) ~= DRAGONRAGE_SPELL_ID end,
  }

  TimingInput(panel, Opt.STACK_INTERVAL, "Seconds between stacks",
    "How often Rising Fury gains a stack while Dragonrage is up.",
    function(v) return v > 0 and v <= 60 end)
  TimingInput(panel, Opt.MAX_STACKS, "Most stacks",
    "The most Rising Fury stacks you can have. Also how many stack tiles the Alert page shows (10 at most).",
    function(v) return v >= 1 and v <= MAX_STACKS_SHOWN and math.floor(v) == v end)
  TimingInput(panel, Opt.LINGER_PER_STACK, "Seconds kept per stack",
    "With Rising Fury rank 3 or higher, how long the buff stays after Dragonrage ends, for each stack.",
    function(v) return v >= 0 and v <= 60 end)
  TimingInput(panel, Opt.LINGER_MAX, "Most seconds kept",
    "The cap on how long Rising Fury stays after Dragonrage ends.",
    function(v) return v >= 0 and v <= 60 end)

  panel:Button{
    text = "Restore addon timing defaults", width = 220,
    tooltip = "Put these five numbers back to ApexFury's own values. Press Apply to keep them.",
    onClick = RestoreTimingDefaults,
    enabledWhen = AnyTimingChanged,
  }
end

-------------------------------------------------------------------------------
-- Advanced: troubleshooting
-------------------------------------------------------------------------------

local function OverlayShown()
  local state = APEX_FURY_UI_STATE and APEX_FURY_UI_STATE.overlay
  return type(state) == "table" and state.shown == true
end

local function DebugLogShown()
  local log = ApexFury.DebugWindow
  return log ~= nil and log.IsShown ~= nil and log:IsShown()
end

local function BuildTroubleshooting(panel)
  panel:Section("Troubleshooting", { icon = ICONS .. "INV_Misc_Spyglass_02" })
  panel:Button{
    text = "Show overlay", width = 200, icon = ICONS .. "INV_Misc_Spyglass_02",
    tooltip = "Show or hide the overlay. Takes effect at once, outside Apply.",
    description = "A small live readout: the timer, Dragonrage time left, your empowers, and why the alert played, waited or was skipped.",
    onClick = function()
      if ApexFury.Overlay and ApexFury.Overlay.Toggle then ApexFury.Overlay.Toggle() end
    end,
    refresh = function(row)
      row.Button:SetText(OverlayShown() and "Hide overlay" or "Show overlay")
    end,
  }
  panel:Button{
    text = "Open debug log", width = 200, icon = ICONS .. "INV_Misc_Note_01",
    tooltip = "Open or close the debug log.",
    description = "The log to copy into a bug report.",
    onClick = function()
      if ApexFury.DebugWindow then ApexFury.DebugWindow:Toggle() end
    end,
    refresh = function(row)
      row.Button:SetText(DebugLogShown() and "Close debug log" or "Open debug log")
    end,
  }
  panel:Checkbox{
    key = Opt.VERBOSE, label = "Log every cast for bug reports",
    tooltip = "Writes every cast, empower and timing step to the debug log.",
    description = "Turn it on, play until the problem happens, then copy the debug log.",
  }
end

local function BuildAdvanced(panel, win)
  BuildTiming(panel, win)
  BuildTroubleshooting(panel)
end

-------------------------------------------------------------------------------
-- Window
-------------------------------------------------------------------------------
local function BuildWindow()
  window = UI.CreateSettingsWindow({
    name    = "ApexFuryOptionsWindow",
    title   = ApexFury.WrapBrand("ApexFury") .. " Settings",
    icon    = ApexFury.ICON,
    config  = Config,
    size    = "browser",          -- 720 x 580: room for the sound browser
    persist = { svTable = GetUIState, key = "options" },
    message = ApexFury.Message,
    footerButtons = {
      {
        text = "Guide", width = 80,
        tooltip = "Open the feature guide: what the alert does and how to set it up.",
        onClick = function() if ApexFury.Guide then ApexFury.Guide.Toggle() end end,
      },
    },
    categories = {
      { key = "alert",    label = "Alert",    build = BuildAlert },
      { key = "sound",    label = "Sound",    build = BuildSound },
      { key = "advanced", label = "Advanced", build = BuildAdvanced },
    },
  })
  return window
end

-------------------------------------------------------------------------------
-- Public API
-------------------------------------------------------------------------------

-- Repaints an open window after a change made outside it (nil: every setting
-- and every live line, as after a talent change)
function Config.NotifySettingsWindow(key)
  if window then window:NotifyConfigChanged(key) end
end

-- The window, built on the first open; nil when that first open comes in
-- combat. Root rule: no CreateFrame in combat, so that open is refused with
-- a chat line and nothing reopens it later.
local function EnsureWindow()
  if window then return window end
  if InCombatLockdown() then
    ApexFury.Message("The settings window can't open for the first time in combat. Try again after combat.")
    return nil
  end
  return BuildWindow()
end

function Config.ToggleSettings()
  if EnsureWindow() then window:Toggle() end
end

function Config.OpenSettings()
  if EnsureWindow() then window:Open() end
end

-- For the suites: the window once built
function Config.GetSettingsWindow()
  return window
end

-------------------------------------------------------------------------------
-- Options > AddOns entry (registered once this addon has finished loading)
-------------------------------------------------------------------------------
EventUtil.ContinueOnAddOnLoaded("ApexFury", function()
  UI.RegisterSettingsCategory({
    name        = "ApexFury",
    brandColor  = ApexFury.BRAND_COLOR,
    version     = ApexFury.VERSION,
    description = {
      "Plays a sound the moment a Devastation Evoker's Rising Fury reaches your chosen stack (4 by default), timed from Dragonrage and your empowers.",
      "The settings live in the addon's own settings window.",
    },
    slash       = "/af settings",
    onOpen      = Config.OpenSettings,
  })
end)
