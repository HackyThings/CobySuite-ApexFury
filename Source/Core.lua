ApexFury = {
  Debug = {},
  Config = {},
  Sound = {},
  Watcher = {},
  TalentGate = {},
  Overlay = {},
  Leatrix = {},
}

ApexFury.BRAND_COLOR = "FF8800"

local ADDON_NAME = "ApexFury"
local VERSION = C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version") or "0.1.0"

-------------------------------------------------------------------------------
-- Shared branding + namespace helpers
-------------------------------------------------------------------------------
local BRAND_OPEN = "|cFF" .. ApexFury.BRAND_COLOR
local BRAND_CLOSE = "|r"

-- Wrap text in the addon's brand color for chat output and window titles.
function ApexFury.WrapBrand(text)
  return BRAND_OPEN .. text .. BRAND_CLOSE
end

-- Defensive read of TalentGate state. Returns the current state table, or
-- nil if TalentGate hasn't loaded / been started yet (shouldn't happen
-- post-PLAYER_LOGIN given TOC order, but callers stay safe either way).
function ApexFury.GetTalentGate()
  return ApexFury.TalentGate
     and ApexFury.TalentGate.GetState
     and ApexFury.TalentGate.GetState()
      or nil
end

-- Audio channels accepted by ApexFury.Sound.Play. Listed in user-preference
-- order — "Dialog" is the default for in-combat audibility.
ApexFury.SOUND_CHANNELS = { "Dialog", "Master", "SFX" }
ApexFury.SOUND_CHANNEL_ALIASES = {
  dialog = "Dialog", master = "Master", sfx = "SFX",
}

-------------------------------------------------------------------------------
-- Chat output (branded prefix)
-------------------------------------------------------------------------------
local BRAND_CHAT_PREFIX = ApexFury.WrapBrand("[ApexFury]") .. " "
local function Message(text)
  print(BRAND_CHAT_PREFIX .. text)
end
ApexFury.Message = Message

-------------------------------------------------------------------------------
-- Slash command registration and routing
-------------------------------------------------------------------------------
SLASH_APEXFURY1 = "/apexfury"
SLASH_APEXFURY2 = "/apex"
SLASH_APEXFURY3 = "/af"

local function PrintHelp()
  Message("|cFFFFFFFFApexFury v" .. VERSION .. "|r — Slash commands:")
  Message("  /af — Open the settings window")
  Message("  /af help — Show this help")
  Message("  /af status — Print current settings to chat")
  Message("  /af scan [name] — List active player buffs (find spell IDs)")
  Message("  /af overlay — Toggle the on-screen status frame")
  Message("  /af debug — Toggle the debug log window")
  Message("  /af channel [dialog|master|sfx] — Show or change the audio channel")
  Message("  /af reset — Restore all settings to defaults")
  Message("  /af version — Print the addon version")
  Message("  |cFF888888(All other settings live in the GUI — open with /af)|r")
end

local function PrintStatus()
  local Config = ApexFury.Config
  local spellID = Config.Get(Config.Options.SPELL_ID)
  local threshold = Config.Get(Config.Options.THRESHOLD)
  local interval = Config.Get(Config.Options.STACK_INTERVAL)
  local soundID = Config.Get(Config.Options.SOUND_ID)
  local enabled = Config.Get(Config.Options.ENABLED)
  local fireDelay = math.max(0, (threshold - 1) * interval)
  local minDuration = fireDelay + ApexFury.Watcher.THRESHOLD_BUFFER

  local gate = ApexFury.GetTalentGate()

  Message("Status:")
  if gate then
    if gate.usable then
      if gate.hasAnimosity then
        Message("  Talent gate: |cFF00FF00ready|r |cFF888888(RF rank " ..
          tostring(gate.risingFuryRank) .. ", Animosity on)|r")
      else
        Message("  Talent gate: |cFFFFAA00active, max 3 stacks|r |cFF888888(no Animosity)|r")
      end
    else
      Message("  Talent gate: |cFFFF8800inactive|r — " .. (gate.detail or gate.reason or "?"))
    end
  end
  Message("  Enabled: " .. (enabled and "|cFF00FF00yes|r" or "|cFFFF4C4Cno|r"))
  Message("  Verbose: " .. (Config.Get(Config.Options.VERBOSE) and "|cFF00FF00on|r" or "|cFF888888off|r"))
  Message("  Trigger spell ID: |cFFFFFFFF" .. tostring(spellID) .. "|r (cast event)")
  Message("  Threshold: |cFFFFFFFF" .. tostring(threshold) .. " stacks|r")
  Message("  Stack interval: |cFFFFFFFF" .. tostring(interval) .. "s|r")
  Message(string.format("  → Timer fires at |cFF00FF00%.0fs|r |cFF888888(suppress unless trigger duration >= %.1fs)|r",
    fireDelay, minDuration))
  Message("  Combat-only: " .. (Config.Get(Config.Options.COMBAT_ONLY) and "|cFF00FF00yes|r (defer if not in combat)" or "|cFFFFFF00no|r (fire any time)"))
  Message("  Actionability gate: " .. (Config.Get(Config.Options.ACTIONABILITY_GATE) and "|cFF00FF00yes|r (defer in vehicle/mount/CC/possession)" or "|cFFFFFF00no|r (fire regardless of player state)"))
  Message("  Min linger remaining: |cFFFFFFFF" .. tostring(Config.Get(Config.Options.MIN_REMAINING)) .. "s|r")
  Message("  Linger model: |cFFFFFFFF" .. tostring(Config.Get(Config.Options.LINGER_PER_STACK)) .. "s/stack|r, max |cFFFFFFFF" .. tostring(Config.Get(Config.Options.LINGER_MAX)) .. "s|r, |cFFFFFFFF" .. tostring(Config.Get(Config.Options.MAX_STACKS)) .. "|r max stacks")
  Message("  Sound ID: |cFFFFFFFF" .. tostring(soundID) .. "|r")
  Message("  Audio channel: |cFFFFFFFF" .. tostring(Config.Get(Config.Options.SOUND_CHANNEL) or "Dialog") .. "|r")
end

local function HandleSlashCommand(input)
  local cmd, rest = input:match("^(%S+)%s*(.*)")
  if not cmd then cmd = input end
  cmd = cmd:lower():trim()

  local Config = ApexFury.Config

  -- Bare /af opens the settings window (most common entry point).
  if cmd == "" or cmd == "options" or cmd == "config" or cmd == "settings" then
    if ApexFury.Config.ToggleSettings then
      ApexFury.Config.ToggleSettings()
    end

  elseif cmd == "help" then
    PrintHelp()

  elseif cmd == "version" then
    Message("v" .. VERSION)

  elseif cmd == "status" then
    PrintStatus()

  elseif cmd == "scan" then
    local filter = rest and rest:lower():trim() or ""
    Message(filter == "" and "Active player buffs:" or ("Active player buffs matching '" .. filter .. "':"))
    local matched, hidden = 0, 0
    for i = 1, BUFF_MAX_DISPLAY do
      local a = C_UnitAuras.GetBuffDataByIndex("player", i)
      if a then
        local ok, isMatch = pcall(function()
          local name = a.name
          if type(name) ~= "string" then return false end
          local nameLower = name:lower()
          if filter ~= "" and not nameLower:find(filter, 1, true) then return false end
          local spellId = tonumber(a.spellId) or 0
          local stacks = tonumber(a.applications) or 0
          Message(string.format("  [%d] |cFFFFFFFF%s|r — id=|cFFFFFF00%d|r, stacks=|cFF00FF00%d|r",
            i, name, spellId, stacks))
          return true
        end)
        if ok and isMatch then
          matched = matched + 1
        elseif not ok then
          hidden = hidden + 1
        end
      end
    end
    if matched == 0 and hidden == 0 then
      Message("  (no matching buffs)")
    elseif hidden > 0 then
      Message(string.format("  |cFF888888(%d private aura(s) skipped)|r", hidden))
    end

  elseif cmd == "channel" then
    local arg = (rest or ""):lower():trim()
    if arg == "" then
      local cur = Config.Get(Config.Options.SOUND_CHANNEL) or "Dialog"
      Message(string.format("Audio channel: |cFFFFFFFF%s|r. Use |cFFFFFFFF/af channel dialog|master|sfx|r to change.", cur))
    elseif ApexFury.SOUND_CHANNEL_ALIASES[arg] then
      local channel = ApexFury.SOUND_CHANNEL_ALIASES[arg]
      Config.Set(Config.Options.SOUND_CHANNEL, channel)
      Message("Audio channel set to |cFFFFFFFF" .. channel .. "|r.")
    else
      Message("Unknown channel '" .. arg .. "'. Valid: |cFFFFFFFFdialog|master|sfx|r.")
    end

  elseif cmd == "reset" then
    Config.Reset()
    Message("All settings restored to defaults.")

  elseif cmd == "debug" then
    if ApexFuryDebugWindow then
      ApexFuryDebugWindow:SetShown(not ApexFuryDebugWindow:IsShown())
    else
      Message("Debug window not initialized.")
    end

  elseif cmd == "overlay" or cmd == "show" then
    if ApexFury.Overlay and ApexFury.Overlay.Toggle then
      ApexFury.Overlay.Toggle()
    end

  else
    Message("Unknown command: " .. cmd .. ". Type |cFFFFFFFF/af help|r for a list.")
  end
end

SlashCmdList["APEXFURY"] = HandleSlashCommand

-------------------------------------------------------------------------------
-- Startup sequence
-------------------------------------------------------------------------------
local startupFrame = CreateFrame("Frame")
startupFrame:RegisterEvent("ADDON_LOADED")
startupFrame:RegisterEvent("PLAYER_LOGIN")

startupFrame:SetScript("OnEvent", function(_, event, arg1)
  if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
    if ApexFury.Config.InitializeData then
      ApexFury.Config.InitializeData()
    end
    ApexFury.Debug.Log("INIT", "ApexFury v%s loaded", VERSION)

  elseif event == "PLAYER_LOGIN" then
    if ApexFury.Watcher.Start then
      ApexFury.Watcher.Start()
    end
    if ApexFury.TalentGate.Start then
      ApexFury.TalentGate.Start()
    end
    if ApexFury.Overlay.RestoreFromSavedVar then
      ApexFury.Overlay.RestoreFromSavedVar()
    end
    if ApexFury.Leatrix.TryHook then
      ApexFury.Leatrix.TryHook()
    end

    -- One-shot onboarding: surface the audio-channel default so users with
    -- their Dialog volume slider muted know why alerts are silent.
    APEX_FURY_UI_STATE = APEX_FURY_UI_STATE or {}
    if not APEX_FURY_UI_STATE.sawChannelHint then
      APEX_FURY_UI_STATE.sawChannelHint = true
      Message("Alerts play on the |cFFFFD200Dialog|r audio channel for best isolation in combat. "
        .. "If you can't hear them, raise |cFFFFFFFFAudio > Dialog Volume|r in WoW settings, "
        .. "or run |cFFFFFFFF/af channel master|r to switch.")
    end

    ApexFury.Debug.Log("INIT", "PLAYER_LOGIN — watcher started, talent gate armed")
  end
end)
