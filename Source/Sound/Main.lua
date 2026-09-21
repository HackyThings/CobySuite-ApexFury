-------------------------------------------------------------------------------
-- ApexFury.Sound: thin wrapper over CobySuite.Sound
--
-- Sound resolution, catalog, and playback now live in CobySuite so they
-- can be reused across addons. ApexFury keeps a small per-addon shim
-- that injects its own SOUND_LABEL config value into LookupLabel so the
-- options window's "currently selected" display can survive Leatrix
-- being uninstalled (the persisted label is the path we saved at pick
-- time).
-------------------------------------------------------------------------------

local Sound = ApexFury.Sound
local CSound = CobySuite_ApexFury.Sound

Sound.Play = CSound.Play

-- label: the SOUND_LABEL to fall back on; the settings window passes its
-- staged one, and nil reads the saved one
function Sound.LookupLabel(value, label)
  if label == nil and ApexFury.Config and ApexFury.Config.Get and ApexFury.Config.Options then
    label = ApexFury.Config.Get(ApexFury.Config.Options.SOUND_LABEL)
  end
  return CSound.LookupLabel(value, label)
end
