-------------------------------------------------------------------------------
-- ApexFury Debug Window: thin wrapper around CobySuite.Debug.NewWindow
--
-- The frame is kept as ApexFury.DebugWindow; callers use its :Toggle().
-------------------------------------------------------------------------------

ApexFury.DebugWindow = CobySuite_ApexFury.Debug.NewWindow({
  windowName = "ApexFuryDebugWindow",
  title = "ApexFury Debug Log",
  logger = ApexFury.Debug,
})
