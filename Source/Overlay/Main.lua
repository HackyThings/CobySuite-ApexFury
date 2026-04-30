-------------------------------------------------------------------------------
-- ApexFury Overlay — movable on-screen status frame
--
-- Shows live timer + watcher state for at-a-glance verification:
--   - Time until our scheduled alert fires
--   - How many captured auras are still alive
--   - Trigger buff's actual remaining time (when readable; private in combat)
--   - Last alert outcome (fired / suppressed / —)
--
-- Position is persisted in APEX_FURY_UI_STATE.overlay.
-------------------------------------------------------------------------------

local Overlay = ApexFury.Overlay

local frame
local lines = {}
local U = CobySuite.Utilities
local UI = CobySuite.UI
local TC = U.Colors

local LINE_TOOLTIPS = {
  [1] = "Tracking state. Counts down to alert fire while DR is active. PENDING = timer fired out of combat and is waiting for combat re-entry. fired/suppressed/idle resolve once the cycle completes.",
  [2] = "Time remaining for Dragonrage (or Risen Fury linger after DR drops). Out of combat: read directly from the aura. In combat: estimated via the predictive model from cast time + Animosity empower extensions.",
  [3] = "Empower spells (Fire Breath / Eternity Surge) cast since this Dragonrage, plus the projected Rising Fury stack count at the moment DR drops. Each empower extends DR via Animosity (+5s, 25% diminishing per cast).",
  [4] = "Exact elapsed seconds from the Dragonrage cast to when the alert sound played (or was suppressed). Frozen at the moment of resolution.",
  [5] = "How long ago the most recent alert sound played. Useful for verifying the cadence between Dragonrages.",
  [6] = "Current verdict — what the watcher would do if the alert moment hit RIGHT NOW. Shows which gates would pass/fail (RF/Risen Fury alive, DR duration ≥ threshold requirement, linger ≥ min_remaining). Helps explain unexpected suppressions.",
}

local NUM_LINES = 6

---------------------------------------------------------------------------
-- Best-effort read of an aura's remaining duration. expirationTime is
-- a secret value on private auras during combat — wrap in pcall and
-- gate on issecretvalue() before any comparison.
---------------------------------------------------------------------------
local function SafeReadRemaining(a)
  if not a then return nil end
  local ok, remaining = pcall(function()
    local exp = a.expirationTime
    if type(exp) ~= "number" then return nil end
    if issecretvalue and issecretvalue(exp) then return nil end
    if exp <= 0 then return nil end
    return exp - GetTime()
  end)
  if ok and type(remaining) == "number" and remaining > 0 then
    return remaining
  end
  return nil
end

---------------------------------------------------------------------------
-- ReadTriggerRemaining: gated on out-of-combat. In-combat reads of
-- private aura fields can leave taint markers; the predictive model
-- handles the in-combat display.
---------------------------------------------------------------------------
local function ReadTriggerRemaining()
  if UnitAffectingCombat("player") then return nil, nil end

  local trackedID = ApexFury.Config.Get(ApexFury.Config.Options.SPELL_ID)
  if not trackedID then return nil, nil end

  local aura = C_UnitAuras.GetPlayerAuraBySpellID(trackedID)
  local rem = SafeReadRemaining(aura)
  if rem then return rem, "direct" end

  local state = ApexFury.Watcher.GetState and ApexFury.Watcher.GetState() or nil
  if state and state.capturedIDs then
    local longest, source = nil, nil
    for id in pairs(state.capturedIDs) do
      local ok, a = pcall(C_UnitAuras.GetAuraDataByAuraInstanceID, "player", id)
      if ok and a then
        local r = SafeReadRemaining(a)
        if r and (not longest or r > longest) then
          longest = r
          source = "inst:" .. tostring(id)
        end
      end
    end
    if longest then return longest, source end
  end

  return nil, nil
end

---------------------------------------------------------------------------
-- Update display — called from OnUpdate
---------------------------------------------------------------------------
local function UpdateDisplay()
  if not frame or not frame:IsShown() then return end

  local state = ApexFury.Watcher.GetState and ApexFury.Watcher.GetState() or {}
  local now = GetTime()

  -- Line 1: our timer / state
  if state.alertPending then
    local elapsed = state.castTime and (now - state.castTime) or 0
    lines[1]:SetText(string.format(
      "|cFFCCCCCCStatus:|r |cFFFFAA00PENDING — waiting for combat|r |cFF555555(%.1fs since cast)|r",
      elapsed))
  elseif state.castTime and state.alertScheduledFor and not state.alertFired and not state.alertSuppressed then
    local remaining = math.max(0, state.alertScheduledFor - now)
    lines[1]:SetText(string.format(
      "|cFFCCCCCCOur timer:|r |cFF00FF00%.1fs|r", remaining))
  elseif state.alertSuppressed and state.lastSuppressReason then
    lines[1]:SetText(string.format(
      "|cFFCCCCCCStatus:|r |cFFFF8800suppressed (%s)|r",
      state.lastSuppressReason))
  elseif state.alertFired and state.castTime and (now - state.castTime) < 30 then
    lines[1]:SetText("|cFFCCCCCCStatus:|r |cFF00FF00fired|r")
  else
    lines[1]:SetText("|cFFCCCCCCStatus:|r |cFF888888idle|r")
  end

  -- Line 2: trigger remaining — API-read first (out of combat only),
  -- then predictive model, then linger model.
  local apiRem, source = ReadTriggerRemaining()
  local lingerRem = state.estLingerRemaining
  local inCombat = UnitAffectingCombat("player")
  local empowers = state.empowerCount or 0

  if apiRem then
    lines[2]:SetText(string.format(
      "|cFFCCCCCCDR remain:|r |cFF00FFFF%.1fs|r |cFF555555(%s, %d empowers)|r",
      apiRem, source or "", empowers))
  elseif state.triggerDropTime and lingerRem and lingerRem ~= math.huge then
    lines[2]:SetText(string.format(
      "|cFFCCCCCCRF linger:|r |cFFFFFF00~%.1fs|r |cFF555555(model)|r", lingerRem))
  elseif state.castTime and state.expectedTriggerEnd and not state.triggerDropTime then
    local predRem = math.max(0, state.expectedTriggerEnd - now)
    lines[2]:SetText(string.format(
      "|cFFCCCCCCDR pred:|r |cFFFFFF00~%.1fs|r |cFF555555(model, %d empowers)|r",
      predRem, empowers))
  else
    lines[2]:SetText("|cFFCCCCCCDR remain:|r |cFF888888—|r")
  end

  -- Line 3: empowers cast + projected stacks at DR drop + combat status
  local combatTag = inCombat and "|cFFFF6644[COMBAT]|r" or "|cFF888888[idle]|r"
  if state.castTime then
    lines[3]:SetText(string.format(
      "|cFFCCCCCCEmpowers:|r |cFFFFFF00%d|r |cFFCCCCCC· stacks:|r |cFFFFFF00~%d|r %s",
      state.empowerCount or 0, state.stacksAtDrop or 0, combatTag))
  else
    lines[3]:SetText("|cFFCCCCCCEmpowers:|r |cFF888888—|r " .. combatTag)
  end

  -- Line 4: precise verifiable timer — exactly when the sound played
  -- relative to the trigger cast. Frozen at fire time, also shows
  -- suppression offset if alert was cancelled.
  if state.lastFiredOffset then
    lines[4]:SetText(string.format(
      "|cFFCCCCCCFired after:|r |cFF00FF00%.3fs|r |cFF555555✓|r",
      state.lastFiredOffset))
  elseif state.lastSuppressOffset then
    lines[4]:SetText(string.format(
      "|cFFCCCCCCFired after:|r |cFFFF8800suppressed @ %.3fs|r |cFF555555(%s)|r",
      state.lastSuppressOffset, tostring(state.lastSuppressReason or "?")))
  elseif state.castTime and not state.alertFired then
    -- Live elapsed since cast (counting up toward scheduled fire)
    local elapsed = now - state.castTime
    lines[4]:SetText(string.format(
      "|cFFCCCCCCFired after:|r |cFFAAAAAA%.2fs elapsed…|r", elapsed))
  else
    lines[4]:SetText("|cFFCCCCCCFired after:|r |cFF888888—|r")
  end

  -- Line 5: relative "ago" reading for context
  if state.lastFiredTime then
    local agoSec = now - state.lastFiredTime
    if agoSec < 120 then
      lines[5]:SetText(string.format(
        "|cFFCCCCCCLast alert:|r |cFFFF8800%.0fs ago|r", agoSec))
    else
      lines[5]:SetText("|cFFCCCCCCLast alert:|r |cFF888888—|r")
    end
  else
    lines[5]:SetText("|cFFCCCCCCLast alert:|r |cFF888888—|r")
  end

  -- Line 6: live verdict — what FireAlert would do if it ran right now.
  -- Mirrors FireAlert's gate logic without actually firing.
  if not state.castTime then
    lines[6]:SetText("|cFFCCCCCCVerdict:|r |cFF888888idle|r")
  elseif state.alertFired then
    lines[6]:SetText("|cFFCCCCCCVerdict:|r |cFF00FF00FIRED|r")
  elseif state.alertSuppressed then
    lines[6]:SetText(string.format(
      "|cFFCCCCCCVerdict:|r |cFFFF8800SUPPRESSED|r |cFF555555(%s)|r",
      tostring(state.lastSuppressReason or "?")))
  elseif state.alertPending then
    lines[6]:SetText("|cFFCCCCCCVerdict:|r |cFFFFAA00deferred — awaiting combat re-entry|r")
  else
    local Config = ApexFury.Config
    local interval    = Config.Get(Config.Options.STACK_INTERVAL)
    local threshold   = Config.Get(Config.Options.THRESHOLD)
    local minRem      = Config.Get(Config.Options.MIN_REMAINING) or 0
    local requiredDur = (threshold - 1) * interval + 0.1
    local actualDur   = state.triggerDropTime
                      and (state.triggerDropTime - state.castTime)
                       or ((state.expectedTriggerEnd or (state.castTime + 18)) - state.castTime)
    local rem         = state.estLingerRemaining or math.huge
    local rfAlive     = (not state.triggerDropTime) or (rem > 0)

    if not rfAlive then
      lines[6]:SetText("|cFFCCCCCCVerdict:|r |cFFFF8800suppress — linger expired|r")
    elseif actualDur < requiredDur then
      lines[6]:SetText(string.format(
        "|cFFCCCCCCVerdict:|r |cFFFFAA00wait — DR %.1fs / %.1fs needed|r",
        actualDur, requiredDur))
    elseif rem ~= math.huge and rem < minRem then
      lines[6]:SetText(string.format(
        "|cFFCCCCCCVerdict:|r |cFFFF8800suppress — linger %.1fs < %.1fs|r",
        rem, minRem))
    else
      lines[6]:SetText("|cFFCCCCCCVerdict:|r |cFF00FF00WOULD FIRE|r |cFF555555(all gates pass)|r")
    end
  end
end

---------------------------------------------------------------------------
-- Persist position to SavedVariable
---------------------------------------------------------------------------
local function SavePosition()
  if not frame then return end
  local point, _, relPoint, x, y = frame:GetPoint(1)
  if not point then return end
  APEX_FURY_UI_STATE = APEX_FURY_UI_STATE or {}
  APEX_FURY_UI_STATE.overlay = APEX_FURY_UI_STATE.overlay or {}
  APEX_FURY_UI_STATE.overlay.point = point
  APEX_FURY_UI_STATE.overlay.relativePoint = relPoint
  APEX_FURY_UI_STATE.overlay.x = x
  APEX_FURY_UI_STATE.overlay.y = y
end

---------------------------------------------------------------------------
-- Frame creation (lazy — only when first shown)
---------------------------------------------------------------------------
local function BuildFrame()
  if frame then return frame end

  local f = CreateFrame("Frame", "ApexFuryOverlay", UIParent, "BasicFrameTemplateWithInset")
  f:SetSize(290, 34 + NUM_LINES * 22 + 12)
  f:SetFrameStrata("MEDIUM")
  f:EnableMouse(true)
  f:SetMovable(true)
  f:SetClampedToScreen(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", function(self) self:StartMoving() end)
  f:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    SavePosition()
  end)

  -- Solid dark background behind the inset, matching the settings window
  local solidBg = f:CreateTexture(nil, "BACKGROUND", nil, -8)
  solidBg:SetAllPoints()
  local wbg = TC.WINDOW_BG
  solidBg:SetColorTexture(wbg[1], wbg[2], wbg[3], wbg[4])

  f.TitleText:SetText("|cFF" .. ApexFury.BRAND_COLOR .. "ApexFury|r")

  -- BasicFrameTemplate exposes its close button as f.CloseButton; route it
  -- through Overlay.Hide so the SavedVariable visibility flag stays in sync.
  if f.CloseButton then
    f.CloseButton:SetScript("OnClick", function() Overlay.Hide() end)
  end

  -- Status lines, anchored within the inset content area. Each line is
  -- a FontString with a UI.AddTooltip describing what it shows.
  for i = 1, NUM_LINES do
    local line = f:CreateFontString(nil, "OVERLAY", U.Fonts.DATA)
    line:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -34 - (i - 1) * 22)
    line:SetJustifyH("LEFT")
    line:SetText("…")
    if LINE_TOOLTIPS[i] then
      UI.AddTooltip(line, LINE_TOOLTIPS[i], "ANCHOR_RIGHT")
    end
    lines[i] = line
  end

  local accum = 0
  f:SetScript("OnUpdate", function(_, elapsed)
    accum = accum + elapsed
    if accum >= 0.1 then
      UpdateDisplay()
      accum = 0
    end
  end)

  frame = f
  return f
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------
function Overlay.Show()
  BuildFrame()

  -- Restore saved position (or center on first show)
  local s = APEX_FURY_UI_STATE and APEX_FURY_UI_STATE.overlay
  frame:ClearAllPoints()
  if s and s.point then
    frame:SetPoint(s.point, UIParent, s.relativePoint or s.point, s.x or 0, s.y or 0)
  else
    frame:SetPoint("CENTER", UIParent, "CENTER", 200, 0)
  end

  frame:Show()
  APEX_FURY_UI_STATE = APEX_FURY_UI_STATE or {}
  APEX_FURY_UI_STATE.overlay = APEX_FURY_UI_STATE.overlay or {}
  APEX_FURY_UI_STATE.overlay.shown = true
end

function Overlay.Hide()
  if frame then frame:Hide() end
  APEX_FURY_UI_STATE = APEX_FURY_UI_STATE or {}
  APEX_FURY_UI_STATE.overlay = APEX_FURY_UI_STATE.overlay or {}
  APEX_FURY_UI_STATE.overlay.shown = false
end

function Overlay.Toggle()
  if frame and frame:IsShown() then
    Overlay.Hide()
  else
    Overlay.Show()
  end
end

function Overlay.RestoreFromSavedVar()
  if APEX_FURY_UI_STATE
     and APEX_FURY_UI_STATE.overlay
     and APEX_FURY_UI_STATE.overlay.shown then
    Overlay.Show()
  end
end
