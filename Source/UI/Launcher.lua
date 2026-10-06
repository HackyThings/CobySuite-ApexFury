-------------------------------------------------------------------------------
-- Launcher: ApexFury's entry in the addon compartment (the addon list on the
-- minimap), on the shared CobySuite.UI.CreateLauncher with no minimap button
-- and no broker object. A left click opens or closes the settings, a right
-- click the overlay. The tooltip is the shared LauncherTooltip shape with a
-- status line for this character, read when the tooltip opens.
-------------------------------------------------------------------------------
-- What ApexFury is doing on this character, in a few words
local function StatusLine()
  local Config = ApexFury.Config
  if not Config.Get(Config.Options.ENABLED) then return "Alerts are off" end
  local gate = ApexFury.TalentGate and ApexFury.TalentGate.GetState()
  local reason = gate and gate.reason
  if reason == "ready" then
    if gate.hasAnimosity == nil then return "Ready (Animosity not found yet)" end
    return "Ready"
  elseif reason == "no_animosity" then
    return string.format("Ready, up to %d stacks without Animosity", ApexFury.Watcher.StacksWithoutExtension())
  elseif reason == "wrong_class" or reason == "wrong_spec" or reason == "no_rising_fury" then
    return "Off on this character"
  end
  return "Checking talents"
end

local function TooltipOpts()
  return CobySuite_ApexFury.UI.LauncherTooltip({
    title = "ApexFury",
    brandColor = ApexFury.BRAND_COLOR,
    icon = ApexFury.ICON,
    status = StatusLine(),
    leftClick = "Open settings",
    rightClick = "Show or hide the overlay",
  })
end

local launcher = CobySuite_ApexFury.UI.CreateLauncher({
  name = "ApexFury",
  minimapButton = false,
  broker = false,
  onLeftClick = function() ApexFury.Config.ToggleSettings() end,
  onRightClick = function() ApexFury.Overlay.Toggle() end,
  compartmentTooltipAnchor = "ANCHOR_LEFT",
  tooltip = TooltipOpts,
})

function ApexFury_OnAddonCompartmentClick(_, button) launcher:OnCompartmentClick(button) end
function ApexFury_OnAddonCompartmentEnter(_, menuItem) launcher:OnCompartmentEnter(menuItem) end
function ApexFury_OnAddonCompartmentLeave() launcher:OnCompartmentLeave() end
