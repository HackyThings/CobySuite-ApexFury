-------------------------------------------------------------------------------
-- ApexFury Debug Logger: thin wrapper around CobySuite.Debug.NewLogger
-------------------------------------------------------------------------------

ApexFury.Debug = CobySuite_ApexFury.Debug.NewLogger({
  addonName = "ApexFury",
  categories = {
    "INIT", "CONFIG", "WATCHER", "CAST", "TALENTGATE",
  },
  savedVariable = "APEX_FURY_DEBUG_LOG",
  sessionHeader = function(lines)
    CobySuite_ApexFury.Debug.AppendConfigSnapshot(lines, "APEX_FURY_CONFIG")
  end,
})
