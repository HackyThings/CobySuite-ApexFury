-------------------------------------------------------------------------------
-- ApexFury.Sound — thin wrapper over CobySuite.Sound
--
-- Sound resolution, catalog, and playback now live in CobySuite so they
-- can be reused across addons. ApexFury keeps a small per-addon shim
-- that injects its own SOUND_LABEL config value into LookupLabel so the
-- options window's "currently selected" display can survive Leatrix
-- being uninstalled (the persisted label is the path we saved at pick
-- time).
-------------------------------------------------------------------------------

local Sound = ApexFury.Sound
local CSound = CobySuite.Sound

Sound.Play = CSound.Play

function Sound.LookupLabel(value)
  local saved
  if ApexFury.Config and ApexFury.Config.Get and ApexFury.Config.Options then
    saved = ApexFury.Config.Get(ApexFury.Config.Options.SOUND_LABEL)
  end
  return CSound.LookupLabel(value, saved)
end
