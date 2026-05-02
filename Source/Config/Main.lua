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
local base = CobySuite.Config.New({
  savedVariable = "APEX_FURY_CONFIG",
  -- High-traffic UI-driven keys — exclude from CONFIG.Set logging so
  -- browsing the 1000-entry sound picker doesn't flood the debug log.
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
    ["enabled"]          = true,
    ["verbose"]          = false,
  },
  debug = ApexFury.Debug,
  onSet = function(name, old, value)
    if ApexFury.Watcher and ApexFury.Watcher.OnConfigChanged then
      ApexFury.Watcher.OnConfigChanged(name, old, value)
    end
    if name and not QUIET_LOOKUP[name] then
      LogConfigSnapshot()
    end
  end,
  onReset = function()
    if ApexFury.Watcher and ApexFury.Watcher.OnConfigChanged then
      ApexFury.Watcher.OnConfigChanged()
    end
    LogConfigSnapshot()
  end,
})

Config.Options       = base.Options
Config.Get           = base.Get
Config.Set           = base.Set
Config.Reset         = base.Reset

function Config.InitializeData()
  base.InitializeData()
  ApexFury.Debug.Log("CONFIG", "Config initialized")
  LogConfigSnapshot()
end
