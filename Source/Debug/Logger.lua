-------------------------------------------------------------------------------
-- ApexFury Debug Logger — thin wrapper around CobySuite.Debug.NewLogger
-------------------------------------------------------------------------------

ApexFury.Debug = CobySuite.Debug.NewLogger({
  addonName = "ApexFury",
  categories = {
    "INIT", "CONFIG", "WATCHER", "CAST", "CAPTURE", "TALENTGATE",
  },
  savedVariable = "APEX_FURY_DEBUG_LOG",
  sessionHeader = function(lines)
    CobySuite.Debug.AppendConfigSnapshot(lines, "APEX_FURY_CONFIG")
  end,
})
