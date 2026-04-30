-------------------------------------------------------------------------------
-- ApexFury × Leatrix Sounds integration
--
-- Leatrix Sounds publishes its main panel as the global LeaSoundsGlobalPanel
-- but exposes no API for "what's currently selected." Workaround: hook every
-- row button's OnClick and remember the last entry the user clicked. Our
-- options window then has Open + Grab buttons that drive this — the LTS
-- panel itself stays unmodified (no injected button, no taint surface).
--
-- Selection format: each row's text is "path/file.ogg#FileDataID". We parse
-- the FileDataID and store the sound as "fdid:NNN" so Sound.Play routes to
-- PlaySoundFile, plus persist the path as SOUND_LABEL for display.
-------------------------------------------------------------------------------

local Leatrix = ApexFury.Leatrix

local lastSelected   -- last-clicked row entry ("path#fdid")
local hookedButtons  -- weak set of row buttons we've already hooked

local function CaptureFromText(text)
  if type(text) ~= "string" then return end
  if not text:find("#") then return end          -- skip headings/separators
  if text:find("|c", 1, true) then return end    -- skip color-coded headers
  lastSelected = text
end

-- Walk a frame tree and attach an OnClick hook to anything that looks
-- like a Leatrix row button. Filter to Button/CheckButton — EditBox /
-- ScrollFrame / etc. don't have an OnClick script and HookScript raises
-- a Lua error if the named script doesn't exist on the frame type.
local function HookRowButtons(frame)
  if not frame or not frame.GetChildren then return end
  for _, child in ipairs({ frame:GetChildren() }) do
    if child.GetObjectType
       and (child:GetObjectType() == "Button" or child:GetObjectType() == "CheckButton")
       and child.GetText
       and not hookedButtons[child] then
      hookedButtons[child] = true
      child:HookScript("OnClick", function(self)
        CaptureFromText(self:GetText())
      end)
    end
    HookRowButtons(child)
  end
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

-- IsAvailable: true if Leatrix Sounds is loaded (or loadable) right now.
-- Covers three cases: (1) panel already created, (2) addon loaded but
-- panel not yet built, (3) addon enabled-but-on-demand.
function Leatrix.IsAvailable()
  if _G["LeaSoundsGlobalPanel"] or _G.Leatrix_Sounds then return true end
  if SlashCmdList and SlashCmdList["Leatrix_Sounds"] then return true end
  if C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("Leatrix_Sounds") then
    return true
  end
  return false
end

-- OpenPanel: best-effort load + open. Force-loads on-demand addons via
-- LoadAddOn, then invokes the slash command which both creates and shows
-- the panel. Re-arms our row-button hook polling so a freshly loaded
-- panel still gets our click capture wired up.
function Leatrix.OpenPanel()
  if C_AddOns and C_AddOns.LoadAddOn then
    pcall(C_AddOns.LoadAddOn, "Leatrix_Sounds")
  end
  if SlashCmdList and SlashCmdList["Leatrix_Sounds"] then
    SlashCmdList["Leatrix_Sounds"]("")
    Leatrix._attached = false
    Leatrix._pollAttempts = 0
    Leatrix.TryHook()
    return true
  end
  return false
end

-- GrabSelected: returns (path, fdid) for the most recent row click, or
-- (nil, nil) if nothing has been captured. Caller is responsible for
-- writing these into config.
function Leatrix.GrabSelected()
  if type(lastSelected) ~= "string" then return nil, nil end
  local path, idStr = lastSelected:match("^(.+)#(%d+)$")
  if not path or not idStr then return nil, nil end
  local fdid = tonumber(idStr)
  if not fdid then return nil, nil end
  return path, fdid
end

---------------------------------------------------------------------------
-- TryHook: idempotent. Looks for _G["LeaSoundsGlobalPanel"]; if absent,
-- polls every 1s for up to 30s to handle PLAYER_LOGIN load-order
-- variability (Leatrix creates the panel inside its own PLAYER_LOGIN
-- handler, which may fire after ours). Once attached, additionally hooks
-- SlashCmdList["Leatrix_Sounds"] as a redundant trigger for panel events.
---------------------------------------------------------------------------
local POLL_INTERVAL = 1
local POLL_MAX_ATTEMPTS = 30
Leatrix._pollAttempts = 0

function Leatrix.TryHook()
  if Leatrix._attached then return true end

  local panel = _G["LeaSoundsGlobalPanel"]
  if not panel then
    Leatrix._pollAttempts = Leatrix._pollAttempts + 1
    if Leatrix._pollAttempts < POLL_MAX_ATTEMPTS then
      C_Timer.After(POLL_INTERVAL, Leatrix.TryHook)
    else
      ApexFury.Debug.Log("INIT", "Leatrix integration: timeout — panel never appeared")
    end
    return false
  end

  hookedButtons = hookedButtons or setmetatable({}, { __mode = "k" })

  if not panel.ApexFuryHookedShow then
    panel.ApexFuryHookedShow = true
    panel:HookScript("OnShow", function(self)
      HookRowButtons(self)
    end)
  end

  -- Redundant slash-command hook so we re-attach if the panel is rebuilt.
  if SlashCmdList and SlashCmdList["Leatrix_Sounds"] and not Leatrix._slashHooked then
    Leatrix._slashHooked = true
    hooksecurefunc(SlashCmdList, "Leatrix_Sounds", function()
      local p = _G["LeaSoundsGlobalPanel"]
      if p and p ~= panel then
        Leatrix._attached = false
        Leatrix.TryHook()
      end
    end)
  end

  HookRowButtons(panel)

  Leatrix._attached = true
  ApexFury.Debug.Log("INIT", "Leatrix Sounds integration attached (panel:IsShown=%s)",
    tostring(panel:IsShown()))
  return true
end
