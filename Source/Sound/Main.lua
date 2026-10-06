-------------------------------------------------------------------------------
-- ApexFury.Sound: thin wrapper over CobySuite.Sound
--
-- Sound resolution, catalog, and playback live in CobySuite so they can
-- be reused across addons. ApexFury keeps a small per-addon shim: it
-- injects its own SOUND_LABEL config value into LookupLabel so the
-- options window's "currently selected" display can survive Leatrix
-- being uninstalled (the persisted label is the path we saved at pick
-- time), and it plays the default sound for a saved sound whose pack is
-- no longer installed.
-------------------------------------------------------------------------------

local Sound = ApexFury.Sound
local CSound = CobySuite_ApexFury.Sound

-- The addon's default sound (Config loads after this file, so read at call time)
function Sound.DefaultValue()
  local Config = ApexFury.Config
  return Config.Defaults[Config.Options.SOUND_ID]
end

function Sound.DefaultLabel()
  return CSound.LookupLabel(Sound.DefaultValue()) or "the default sound"
end

-- Whether a saved sound's pack is gone: the shared player plays nothing for it
function Sound.IsMissing(value)
  return (CSound.Resolve(value)) == "lsm_missing"
end

-- A sound from a pack that is no longer installed would leave the alert
-- silent, so it plays the default sound until the pack is back. The saved
-- choice stays as it is.
function Sound.Play(value, channel)
  if Sound.IsMissing(value) then value = Sound.DefaultValue() end
  return CSound.Play(value, channel)
end

-- label: the SOUND_LABEL to fall back on; the settings window passes its
-- staged one, and nil reads the saved one
function Sound.LookupLabel(value, label)
  if label == nil and ApexFury.Config and ApexFury.Config.Get and ApexFury.Config.Options then
    label = ApexFury.Config.Get(ApexFury.Config.Options.SOUND_LABEL)
  end
  return CSound.LookupLabel(value, label)
end
