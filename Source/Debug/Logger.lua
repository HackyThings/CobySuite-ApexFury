-------------------------------------------------------------------------------
-- ApexFury Debug Logger — thin wrapper around CobySuite.Debug.NewLogger
-------------------------------------------------------------------------------

ApexFury.Debug = CobySuite.Debug.NewLogger({
  addonName = "ApexFury",
  categories = {
    "INIT", "CONFIG", "WATCHER", "CAST", "CAPTURE",
  },
  savedVariable = "APEX_FURY_DEBUG_LOG",
  sessionHeader = function(lines)
    table.insert(lines, "Config Snapshot:")
    if APEX_FURY_CONFIG then
      local parts = {}
      for key, val in pairs(APEX_FURY_CONFIG) do
        if type(val) ~= "table" then
          table.insert(parts, "  " .. tostring(key) .. "=" .. tostring(val))
        end
      end
      table.sort(parts)
      for _, p in ipairs(parts) do
        table.insert(lines, p)
      end
    else
      table.insert(lines, "  (not loaded)")
    end
  end,
})
