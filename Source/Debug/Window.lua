-------------------------------------------------------------------------------
-- ApexFury Debug Window — thin wrapper around CobySuite.Debug.NewWindow
-------------------------------------------------------------------------------

CobySuite.Debug.NewWindow({
  windowName = "ApexFuryDebugWindow",
  title = "ApexFury Debug Log",
  logger = ApexFury.Debug,
})
