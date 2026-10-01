local Config = ApexFury.Config

-- Keys whose Set / change events shouldn't spam the debug log. Used both
-- for the underlying CONFIG.Set log line and for the post-change snapshot
-- emitted from onSet below; declared once so the two stay in sync.
local QUIET_KEYS = { "sound_id", "sound_label" }
local QUIET_LOOKUP = {}
for _, k in ipairs(QUIET_KEYS) do QUIET_LOOKUP[k] = true end

-- Emit a single-line snapshot of the entire saved-variable to the debug
-- log. Called after every non-quiet Set so users sharing the log after
-- tweaking settings see the current full state, not just whatever the
-- session-header snapshot captured at initial load.
local function LogConfigSnapshot()
  if not (ApexFury.Debug and ApexFury.Debug.Log and APEX_FURY_CONFIG) then
    return
  end
  local parts = {}
  for k, v in pairs(APEX_FURY_CONFIG) do
    if type(v) ~= "table" then
      table.insert(parts, k .. "=" .. tostring(v))
    end
  end
  table.sort(parts)
  ApexFury.Debug.Log("CONFIG", "Snapshot: %s", table.concat(parts, ", "))
end

---------------------------------------------------------------------------
-- Shared config base via CobySuite.Config.New
---------------------------------------------------------------------------
local base = CobySuite_ApexFury.Config.New({
  savedVariable = "APEX_FURY_CONFIG",
  -- Kept out of the CONFIG.Set log line. They were quiet when every pick
  -- in the sound browser wrote them; a pick now only stages in the
  -- settings window, and Apply writes them once.
  quietKeys = QUIET_KEYS,
  options = {
    SPELL_ID         = "spell_id",         -- TRIGGER cast spell (not the stacking aura)
    THRESHOLD        = "threshold",        -- target stack count
    STACK_INTERVAL   = "stack_interval",   -- seconds between stack ticks
    LINGER_PER_STACK = "linger_per_stack", -- seconds of post-trigger linger per stack (Rising Fury = 4)
    LINGER_MAX       = "linger_max",       -- maximum total linger duration (Rising Fury cap = 20)
    MAX_STACKS       = "max_stacks",       -- maximum stacks the buff can reach (Rising Fury = 5)
    COMBAT_ONLY      = "combat_only",      -- only fire alert while in combat; defer otherwise
    ACTIONABILITY_GATE = "actionability_gate", -- defer alert while vehicled/mounted/CC'd/possessed
    MIN_REMAINING    = "min_remaining",    -- min seconds of linger remaining required to fire deferred alert
    SOUND_ID         = "sound_id",
    SOUND_LABEL      = "sound_label",      -- persisted friendly label (e.g. Leatrix path) for sounds outside our catalog
    SOUND_CHANNEL    = "sound_channel",    -- WoW audio channel: "Dialog" (default), "Master" or "SFX" (ApexFury.SOUND_CHANNELS)
    ENABLED          = "enabled",
    VERBOSE          = "verbose",
  },
  defaults = {
    ["spell_id"]         = 375087, -- Dragonrage (Devastation Evoker trigger)
    ["threshold"]        = 4,      -- 4 stacks of Rising Fury
    ["stack_interval"]   = 6,      -- Rising Fury ticks every 6s while Dragonrage is up
    ["linger_per_stack"] = 4,      -- Rising Fury lingers 4s/stack after Dragonrage drops
    ["linger_max"]       = 20,     -- max 20s of lingering total
    ["max_stacks"]       = 5,      -- Rising Fury caps at 5 stacks
    ["combat_only"]      = true,   -- only play sound while in combat (defer pending if not)
    ["actionability_gate"] = true, -- defer alert while in vehicle/mount/CC/possession (re-fires on recovery if linger remains)
    ["min_remaining"]    = 2,      -- need >=2s of linger remaining to fire deferred alert
    ["sound_id"]         = 8960,   -- READY_CHECK
    ["sound_label"]      = "",     -- empty = use catalog/SOUNDKIT/Leatrix lookup
    -- Dialog default: the game's default Dialog volume is 1.0 (full) and
    -- the channel carries near-zero traffic in combat (NPC speech / cinematics
    -- only). Master is the root mixer but suffers perceptual masking against
    -- short LSM samples; SFX shares a bus with combat sound effects. Dialog
    -- gives the alert an effectively empty bus while still respecting the
    -- user's Master volume gate.
    ["sound_channel"]    = "Dialog",
    ["enabled"]          = true,
    ["verbose"]          = false,
  },
  -- Set refuses a failing value and InitializeData puts the default back for
  -- a failing saved one (a hand-edited or damaged file). The ranges are the
  -- widest the settings window has ever allowed, 1.0.2 included, so nothing a
  -- player saved through the UI is reset; the window's own checks stay
  -- stricter (an interval above 0). sound_id has no rule: it is a number or
  -- a string, by source.
  validate = {
    ["spell_id"]           = { type = "number", min = 1, integer = true },
    ["threshold"]          = { type = "number", min = 1, max = 99, integer = true },
    ["stack_interval"]     = { type = "number", min = 0.001, max = 60 },
    ["linger_per_stack"]   = { type = "number", min = 0, max = 600 },
    ["linger_max"]         = { type = "number", min = 0, max = 600 },
    ["max_stacks"]         = { type = "number", min = 1, max = 99, integer = true },
    ["combat_only"]        = { type = "boolean" },
    ["actionability_gate"] = { type = "boolean" },
    ["min_remaining"]      = { type = "number", min = 0, max = 60 },
    ["sound_label"]        = { type = "string" },
    ["sound_channel"]      = { type = "string", values = ApexFury.SOUND_CHANNELS },
    ["enabled"]            = { type = "boolean" },
    ["verbose"]            = { type = "boolean" },
  },
  debug = ApexFury.Debug,
  onSet = function(name, old, value)
    if ApexFury.Watcher and ApexFury.Watcher.OnConfigChanged then
      ApexFury.Watcher.OnConfigChanged(name, old, value)
    end
    -- An open settings window repaints the setting (/af channel); defined
    -- by Config/Window.lua, since this addon has no config event bus
    if Config.NotifySettingsWindow then Config.NotifySettingsWindow(name) end
    if name and not QUIET_LOOKUP[name] then
      LogConfigSnapshot()
    end
  end,
  onReset = function()
    if ApexFury.Watcher and ApexFury.Watcher.OnConfigChanged then
      ApexFury.Watcher.OnConfigChanged()
    end
    if Config.NotifySettingsWindow then Config.NotifySettingsWindow() end
    LogConfigSnapshot()
  end,
})

Config.Options       = base.Options
Config.Defaults      = base.Defaults     -- the settings window's Defaults button stages these
Config.CheckValue    = base.CheckValue
Config.Get           = base.Get
Config.Set           = base.Set
Config.Reset         = base.Reset

function Config.InitializeData()
  base.InitializeData()
  ApexFury.Debug.Log("CONFIG", "Config initialized")
  LogConfigSnapshot()
end
