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
--   })
--
-- Returns: { Options, Defaults, IsValidOption, Get, Set, Reset, InitializeData }
---------------------------------------------------------------------------

function CobySuite.Config.New(opts)
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

  function config.Get(name)
    local sv = _G[svName]
    if sv == nil then
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
    else
      local old = sv[name]
      sv[name] = value
      if debug and not quietKeys[name] then
        debug.Log("CONFIG", "Set %s: %s -> %s", tostring(name), tostring(old), tostring(value))
      end
      if opts.onSet then opts.onSet(name, old, value) end
    end
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
    if sv == nil then
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
