---------------------------------------------------------------------------
-- CobySuite Shared Config Constructor
--
-- Usage:
--   local config = CobySuite.Config.New({
--     savedVariable = "COBY_SNIPER_CONFIG",
--     options    = { USE_BLEEP = "use_bleep_2", ... },
--     defaults   = { ["use_bleep_2"] = true, ... },
--     debug      = CobySniper.Debug,       -- optional: for Log/Warn calls
--     onSet      = function(name, old, new) end,  -- optional: hook after Set
--     onReset    = function() end,          -- optional: hook after Reset
--     migrations = function(sv) end,        -- optional: runs during InitializeData
--     quietKeys  = { "sound_id", ... },     -- optional: keys to skip from CONFIG.Set log
--     validate   = {                        -- optional: per-key value rules
--       ["use_bleep_2"] = { type = "boolean" },
--       ["max_rows"]    = { type = "number", min = 1, max = 10, integer = true },
--       ["speed"]       = { type = "string", values = { "Slow", "Fast" } },
--     },
--   })
--
-- Returns: { Options, Defaults, IsValidOption, CheckValue, Get, Set, Reset, InitializeData }
--
-- Validation: a key with a rule only ever holds a value that passes it.
-- Set refuses a failing value (returns false and the reason, logs a CONFIG
-- warning, does not call onSet); InitializeData replaces a failing saved
-- value with its default. Numbers must also be finite. Set(key, nil) clears
-- a key back to its default and is always allowed. Set returns true when it
-- stores. Keys without a rule, and addons that pass no validate table, keep
-- the old unchecked behaviour. Table-valued defaults are shared by reference
-- with the SavedVariable; copy them before mutating.
---------------------------------------------------------------------------

function CobySuite_ApexFury.Config.New(opts)
  local config = {}
  config.Options = opts.options
  config.Defaults = opts.defaults

  local svName = opts.savedVariable
  local debug = opts.debug

  -- Build reverse lookup set for O(1) validation
  local validOptions = {}
  for _, option in pairs(opts.options) do
    validOptions[option] = true
  end

  -- Optional set of "quiet" keys whose Set calls should NOT be logged.
  -- Useful for high-traffic keys (e.g. sound picks while a user browses
  -- a 1000-entry sound library) where every change would flood the
  -- debug log with noise the user didn't ask for.
  local quietKeys = {}
  if type(opts.quietKeys) == "table" then
    for _, k in ipairs(opts.quietKeys) do quietKeys[k] = true end
  end

  function config.IsValidOption(name)
    return validOptions[name] == true
  end

  local rules = opts.validate or {}

  -- true, or false and a reason, for a value against the key's rule
  function config.CheckValue(name, value)
    local rule = rules[name]
    if not rule then return true end
    if rule.type == "number" then
      if type(value) ~= "number" then return false, "expects a number" end
      if not CobySuite_ApexFury.Utilities.IsFiniteNumber(value) then
        return false, "expects a finite number"
      end
      if rule.integer and value ~= math.floor(value) then return false, "expects a whole number" end
      if rule.min and value < rule.min then return false, "must be at least " .. rule.min end
      if rule.max and value > rule.max then return false, "must be at most " .. rule.max end
    elseif rule.type == "boolean" then
      if type(value) ~= "boolean" then return false, "expects true or false" end
    elseif rule.type == "string" then
      if type(value) ~= "string" then return false, "expects text" end
      if rule.values then
        for _, allowed in ipairs(rule.values) do
          if value == allowed then return true end
        end
        return false, "must be one of " .. table.concat(rule.values, ", ")
      end
    end
    return true
  end

  function config.Get(name)
    local sv = _G[svName]
    if type(sv) ~= "table" then
      if debug then debug.Warn("CONFIG", "Get(%s): %s nil, using default", tostring(name), svName) end
      return config.Defaults[name]
    end
    local val = sv[name]
    if val == nil then return config.Defaults[name] end
    return val
  end

  function config.Set(name, value)
    local sv = _G[svName]
    if sv == nil then
      error(svName .. " not initialized")
    elseif not config.IsValidOption(name) then
      error("Invalid option '" .. tostring(name) .. "'")
    end
    if value ~= nil then
      local ok, reason = config.CheckValue(name, value)
      if not ok then
        if debug then
          debug.Warn("CONFIG", "Set %s refused (%s): %s", tostring(name), tostring(value), reason)
        end
        return false, reason
      end
    end
    local old = sv[name]
    sv[name] = value
    if debug and not quietKeys[name] then
      debug.Log("CONFIG", "Set %s: %s -> %s", tostring(name), tostring(old), tostring(value))
    end
    if opts.onSet then opts.onSet(name, old, value) end
    return true
  end

  function config.Reset()
    local sv = {}
    for option, value in pairs(config.Defaults) do
      sv[option] = value
    end
    _G[svName] = sv
    if debug then debug.Log("CONFIG", "Reset: all options restored to defaults") end
    if opts.onReset then opts.onReset() end
  end

  function config.InitializeData()
    local sv = _G[svName]
    if type(sv) ~= "table" then
      if sv ~= nil and debug then
        debug.Warn("CONFIG", "InitializeData: %s held a %s, starting from defaults", svName, type(sv))
      end
      config.Reset()
      if debug then debug.Log("CONFIG", "InitializeData: created fresh config with defaults") end
    else
      local filled = 0
      for option, value in pairs(config.Defaults) do
        if sv[option] == nil then
          sv[option] = value
          filled = filled + 1
        end
      end
      if filled > 0 and debug then
        debug.Log("CONFIG", "InitializeData: filled %d missing defaults", filled)
      end
    end

    -- Addon-specific migrations (before stale key cleanup)
    if opts.migrations then opts.migrations(_G[svName]) end

    -- Clean up stale keys not in current options
    sv = _G[svName]
    for key in pairs(sv) do
      if not validOptions[key] then
        sv[key] = nil
        if debug then debug.Log("CONFIG", "InitializeData: removed stale key '%s'", key) end
      end
    end

    -- Replace saved values that fail their rule with the default
    for key in pairs(rules) do
      local value = sv[key]
      if value ~= nil then
        local ok, reason = config.CheckValue(key, value)
        if not ok then
          sv[key] = config.Defaults[key]
          if debug then
            debug.Warn("CONFIG", "InitializeData: %s held %s (%s), reset to default", tostring(key), tostring(value), reason)
          end
        end
      end
    end

    -- Log non-default values
    local nonDefaults = {}
    for option, default in pairs(config.Defaults) do
      local current = sv[option]
      if type(current) ~= "table" and current ~= default then
        table.insert(nonDefaults, tostring(option) .. "=" .. tostring(current))
      end
    end
    if #nonDefaults > 0 then
      table.sort(nonDefaults)
      if debug then debug.Log("CONFIG", "Non-default values: %s", table.concat(nonDefaults, ", ")) end
    end
  end

  return config
end
