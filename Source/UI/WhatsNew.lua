-------------------------------------------------------------------------------
-- WhatsNew: the changelog window and what its login shows, on the shared
-- CobySuite.UI.CreateWhatsNewWindow (the suite's standard, as Recollect's):
-- one collapsible section per version of Data/Changelog.lua, /af changelog
-- any time. At login APEX_FURY_UI_STATE.lastVersion says what the player
-- last ran: none (a fresh install) opens the feature guide, an older
-- version this window with every version since then open, else nothing;
-- either waits for combat to end. Core.lua's PLAYER_LOGIN calls OnLogin.
--
-- ApexFury was released before this window existed, so a player upgrading
-- from 1.0.4 or older has no lastVersion either. The channel hint's flag
-- (APEX_FURY_UI_STATE.sawChannelHint, set at every login since before
-- 1.0.0) tells them apart: such a player is recorded as coming from
-- LAST_VERSION_WITHOUT_CHANGELOG, so the update shows what is new rather
-- than the guide.
-------------------------------------------------------------------------------
local U = CobySuite_ApexFury.Utilities

local WhatsNew = {}
ApexFury.WhatsNew = WhatsNew

local LAST_VERSION_WITHOUT_CHANGELOG = "1.0.4"

-- The saved table holding lastVersion and the window's place; read at
-- login and later, once the saved variables have loaded
local function GetUIState()
  APEX_FURY_UI_STATE = APEX_FURY_UI_STATE or {}
  return APEX_FURY_UI_STATE
end

local changelog = CobySuite_ApexFury.UI.CreateWhatsNewWindow({
  name = "ApexFuryChangelogWindow",
  title = "ApexFury: What's New",
  icon = ApexFury.ICON,
  intro = "What changed in each version of ApexFury, newest first. Click a version to open or close it.",
  footer = "Open this window any time with " .. U.WrapColor(U.Colors.HELP_COMMAND, "/af changelog"),
  entries = ApexFury.Data.Changelog,
  version = ApexFury.VERSION,
  state = GetUIState,
  onFirstRun = function() if ApexFury.Guide then ApexFury.Guide.Show() end end,
  combatMessage = function(text) ApexFury.Message(text) end,
  onShow = function(what) ApexFury.Debug.Log("INIT", "Login shows the %s", what) end,
})

-- A player who ran ApexFury before this window existed: recorded as coming
-- from the last version without it (see the header)
local function SeedEarlierPlayer(state)
  if state.lastVersion == nil and state.sawChannelHint then
    state.lastVersion = LAST_VERSION_WITHOUT_CHANGELOG
  end
end

-- The window's instance and the seeding step, for the suites
WhatsNew._test = {
  instance = changelog,
  SeedEarlierPlayer = SeedEarlierPlayer,
  LAST_VERSION_WITHOUT_CHANGELOG = LAST_VERSION_WITHOUT_CHANGELOG,
}

function WhatsNew.Toggle() changelog:Toggle() end

function WhatsNew.OnLogin()
  SeedEarlierPlayer(GetUIState())
  changelog:OnLogin()
end
