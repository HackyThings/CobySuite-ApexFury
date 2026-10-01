-------------------------------------------------------------------------------
-- ApexFury Overlay: movable on-screen status frame
--
-- Seven tooltipped status lines for live verification of the watcher's
-- decision-making: status / DR remaining / empowers + stacks reached and
-- projected / fired-after offset / last-alert-ago / live verdict / talent
-- gate. See LINE_TOOLTIPS below for per-line descriptions.
--
-- Everything shown comes from Watcher.GetState(); the overlay makes no aura
-- API calls, so its 0.1s OnUpdate never touches aura data, which would taint
-- this addon's execution. The "DR remain (read)" value is the watcher's one-shot
-- out-of-combat read.
--
-- Position is persisted in APEX_FURY_UI_STATE.overlay.
-------------------------------------------------------------------------------

local Overlay = ApexFury.Overlay

local frame
local lines = {}
local U = CobySuite_ApexFury.Utilities
local UI = CobySuite_ApexFury.UI

local LINE_TOOLTIPS = {
  [1] = "Tracking state. Counts down to alert fire while DR is active. PENDING = the alert moment came while you couldn't act on it (out of combat, in a vehicle, mounted, possessed, or stunned or otherwise crowd-controlled); the line names which. When that clears, the alert is checked again and plays only if its other conditions still pass. EXPIRED = a pending alert whose Rising Fury ran out first. HOLD = at the alert moment Dragonrage looked too short, so the alert waits half a second for an empower that arrives late. fired/suppressed/idle resolve once the cycle completes.",
  [2] = "Time remaining for Dragonrage (or the Rising Fury linger after DR drops). (read) = Dragonrage's own timer, read once out of combat just after the cast and after each empower. Otherwise, and always in combat: estimated via the predictive model from cast time + Animosity empower extensions.",
  [3] = "Empower spells (Fire Breath / Eternity Surge) cast since this Dragonrage, the Rising Fury stacks reached so far, and in brackets the stacks projected for the moment DR drops (it grows as empowers extend DR). Each empower extends DR via Animosity (+5s, 25% diminishing per cast).",
  [4] = "Exact elapsed seconds from the Dragonrage cast to when the alert sound played (or was suppressed). Frozen at the moment of resolution.",
  [5] = "How long ago the most recent alert sound played. Useful for verifying the cadence between Dragonrages.",
  [6] = "Current verdict: what the watcher would do if the alert moment hit RIGHT NOW. Shows which gates would pass/fail (Rising Fury alive, DR duration ≥ threshold requirement, linger ≥ min_remaining). Helps explain unexpected suppressions.",
  [7] = "Talent gate: addon prerequisites. Requires Devastation Evoker spec + Rising Fury rank ≥1. Animosity needed for threshold ≥4 (unextended Dragonrage caps at 3 stacks). When inactive, the watcher unregisters its events entirely.",
}

local NUM_LINES = 7

-- Defer-reason → user-facing text for both the status line (line 1) and the
-- live verdict line (line 6). Single source so the two displays stay aligned.
local DEFER_REASON_DISPLAY = {
  ooc             = { status = "waiting for combat",  verdict = "awaiting combat re-entry" },
  vehicle         = { status = "in vehicle",          verdict = "awaiting vehicle exit" },
  vehicle_ui      = { status = "in vehicle",          verdict = "awaiting vehicle exit" },
  mounted         = { status = "mounted",             verdict = "awaiting dismount" },
  possessed       = { status = "possessed",           verdict = "awaiting possession end" },
  loss_of_control = { status = "stunned/CC'd",        verdict = "awaiting CC end" },
}
local DEFER_FALLBACK = { status = "waiting", verdict = "awaiting recovery" }

---------------------------------------------------------------------------
-- Render line 7: the talent gate status. Always shown.
---------------------------------------------------------------------------
local function RenderGateLine(state)
  local reason = state.gateReason or "unknown"
  local detail = state.gateDetail or ""
  if reason == "ready" then
    lines[7]:SetText(string.format(
      "|cFFCCCCCCGate:|r |cFF00FF00ready|r |cFF555555(RF rank %d, %s)|r",
      state.gateRisingFury or 0,
      state.gateAnimosity == nil and "Animosity assumed" or "Animosity on"))
  elseif reason == "no_animosity" then
    lines[7]:SetText(string.format(
      "|cFFCCCCCCGate:|r |cFFFFAA00active, max 3 stacks|r |cFF555555(no Animosity)|r"))
  elseif reason == "no_rising_fury" then
    lines[7]:SetText("|cFFCCCCCCGate:|r |cFFFF8800Rising Fury not specced|r")
  elseif reason == "wrong_spec" then
    lines[7]:SetText("|cFFCCCCCCGate:|r |cFFFF8800wrong spec|r |cFF555555(switch to Devastation)|r")
  elseif reason == "wrong_class" then
    lines[7]:SetText("|cFFCCCCCCGate:|r |cFFFF4C4Cwrong class|r")
  elseif reason == "api_unavailable" then
    lines[7]:SetText("|cFFCCCCCCGate:|r |cFFFF4C4Ctalents not loaded|r |cFF555555(change talents or /reload)|r")
  else
    lines[7]:SetText("|cFFCCCCCCGate:|r |cFF888888" .. tostring(detail) .. "|r")
  end
end

---------------------------------------------------------------------------
-- When the gate is closed (watcher inactive), lines 1-6 collapse to a
-- muted placeholder. The user still sees enough to know the addon is on
-- and why it's not doing anything.
---------------------------------------------------------------------------
local function RenderInactivePlaceholder(state)
  local detail = state.gateDetail or "Inactive"
  lines[1]:SetText("|cFFCCCCCCStatus:|r |cFF888888inactive|r")
  lines[2]:SetText("|cFF888888" .. detail .. "|r")
  lines[3]:SetText("|cFF888888--|r")
  lines[4]:SetText("|cFF888888--|r")
  lines[5]:SetText("|cFF888888--|r")
  lines[6]:SetText("|cFF888888--|r")
  RenderGateLine(state)
end

local function UpdateDisplay()
  if not frame or not frame:IsShown() then return end

  local state = ApexFury.Watcher.GetState and ApexFury.Watcher.GetState() or {}
  -- The watcher's clock, so the lines agree with its state (and its test clock)
  local now = state.now or GetTime()

  -- Gate-closed path: addon prerequisites not met. Skip cycle rendering
  -- entirely: the watcher isn't running, all the cycle fields are nil
  -- by design.
  if state.gateUsable == false then
    RenderInactivePlaceholder(state)
    return
  end

  -- Line 1: our timer / state
  if state.alertPending then
    local elapsed = state.castTime and (now - state.castTime) or 0
    -- Linger past its predicted end? The watcher's stale-pending cleanup
    -- only fires 45s after the alert was deferred, so between actual linger
    -- expiry and that cleanup the overlay would otherwise show a stale "PENDING."
    local lingerRem = state.estLingerRemaining
    if lingerRem ~= nil and lingerRem ~= math.huge and lingerRem <= 0 then
      lines[1]:SetText(string.format(
        "|cFFCCCCCCStatus:|r |cFF888888EXPIRED: Rising Fury ended|r |cFF555555(%.1fs since cast)|r",
        elapsed))
    else
      local reasonText = (DEFER_REASON_DISPLAY[state.pendingDeferReason] or DEFER_FALLBACK).status
      lines[1]:SetText(string.format(
        "|cFFCCCCCCStatus:|r |cFFFFAA00PENDING: %s|r |cFF555555(%.1fs since cast)|r",
        reasonText, elapsed))
    end
  elseif state.provisionalUntil and not state.alertFired and not state.alertSuppressed then
    lines[1]:SetText(string.format(
      "|cFFCCCCCCStatus:|r |cFFFFAA00HOLD, waiting for a late empower|r |cFF555555(%.1fs)|r",
      math.max(0, state.provisionalUntil - now)))
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

  -- Line 2: trigger remaining. The watcher's one-shot out-of-combat read
  -- while it is still running, then the predictive model, then the linger
  -- model. No aura API call here.
  local observedRem = state.observedTriggerEnd and (state.observedTriggerEnd - now) or nil
  local lingerRem = state.estLingerRemaining
  local inCombat = UnitAffectingCombat("player")
  local empowers = state.empowerCount or 0

  if observedRem and observedRem > 0 then
    lines[2]:SetText(string.format(
      "|cFFCCCCCCDR remain:|r |cFF00FFFF%.1fs|r |cFF555555(read, %d empowers)|r",
      observedRem, empowers))
  elseif state.triggerDropTime and lingerRem and lingerRem ~= math.huge then
    lines[2]:SetText(string.format(
      "|cFFCCCCCCRF linger:|r |cFFFFFF00~%.1fs|r |cFF555555(model)|r", lingerRem))
  elseif state.castTime and state.expectedTriggerEnd and not state.triggerDropTime then
    local predRem = math.max(0, state.expectedTriggerEnd - now)
    lines[2]:SetText(string.format(
      "|cFFCCCCCCDR pred:|r |cFFFFFF00~%.1fs|r |cFF555555(model, %d empowers)|r",
      predRem, empowers))
  else
    lines[2]:SetText("|cFFCCCCCCDR remain:|r |cFF888888--|r")
  end

  -- Line 3: empowers cast + stacks reached so far + stacks projected at the
  -- predicted DR end + combat status
  local combatTag = inCombat and "|cFFFF6644[COMBAT]|r" or "|cFF888888[idle]|r"
  if state.castTime then
    lines[3]:SetText(string.format(
      "|cFFCCCCCCEmpowers:|r |cFFFFFF00%d|r |cFFCCCCCC· stacks|r |cFFFFFF00~%d|r |cFF888888(~%d at DR end)|r %s",
      state.empowerCount or 0, state.stacksReached or 0, state.projectedStacksAtDrop or 0, combatTag))
  else
    lines[3]:SetText("|cFFCCCCCCEmpowers:|r |cFF888888--|r " .. combatTag)
  end

  -- Line 4: precise verifiable timer: exactly when the sound played
  -- relative to the trigger cast. Frozen at fire time, also shows
  -- suppression offset if alert was cancelled.
  if state.lastFiredOffset then
    lines[4]:SetText(string.format(
      "|cFFCCCCCCFired after:|r |cFF00FF00%.3fs|r",
      state.lastFiredOffset))
  elseif state.lastSuppressOffset then
    lines[4]:SetText(string.format(
      "|cFFCCCCCCFired after:|r |cFFFF8800suppressed @ %.3fs|r |cFF555555(%s)|r",
      state.lastSuppressOffset, tostring(state.lastSuppressReason or "?")))
  elseif state.castTime and not state.alertFired then
    -- Live elapsed since cast (counting up toward scheduled fire)
    local elapsed = now - state.castTime
    lines[4]:SetText(string.format(
      "|cFFCCCCCCFired after:|r |cFFAAAAAA%.2fs elapsed...|r", elapsed))
  else
    lines[4]:SetText("|cFFCCCCCCFired after:|r |cFF888888--|r")
  end

  -- Line 5: relative "ago" reading for context
  if state.lastFiredTime then
    local agoSec = now - state.lastFiredTime
    if agoSec < 120 then
      lines[5]:SetText(string.format(
        "|cFFCCCCCCLast alert:|r |cFFFF8800%.0fs ago|r", agoSec))
    else
      lines[5]:SetText("|cFFCCCCCCLast alert:|r |cFF888888--|r")
    end
  else
    lines[5]:SetText("|cFFCCCCCCLast alert:|r |cFF888888--|r")
  end

  -- Line 6: live verdict, a preview of FireAlert's gates in its order
  -- (duration, linger alive, min_remaining) without firing. A too-short
  -- duration waits while an empower can still extend the cycle (up to the
  -- predicted end plus the grace, unless Animosity is known missing), as
  -- FireAlert's hold does; after that it is a trigger_too_short suppress.
  if not state.castTime then
    lines[6]:SetText("|cFFCCCCCCVerdict:|r |cFF888888idle|r")
  elseif state.alertFired then
    lines[6]:SetText("|cFFCCCCCCVerdict:|r |cFF00FF00FIRED|r")
  elseif state.alertSuppressed then
    lines[6]:SetText(string.format(
      "|cFFCCCCCCVerdict:|r |cFFFF8800SUPPRESSED|r |cFF555555(%s)|r",
      tostring(state.lastSuppressReason or "?")))
  elseif state.provisionalUntil then
    lines[6]:SetText(
      "|cFFCCCCCCVerdict:|r |cFFFFAA00hold, waiting for a late empower|r")
  elseif state.alertPending then
    local lingerRem = state.estLingerRemaining
    if lingerRem ~= nil and lingerRem ~= math.huge and lingerRem <= 0 then
      lines[6]:SetText(
        "|cFFCCCCCCVerdict:|r |cFF888888expired: Rising Fury ended|r")
    else
      local detail = (DEFER_REASON_DISPLAY[state.pendingDeferReason] or DEFER_FALLBACK).verdict
      lines[6]:SetText(string.format(
        "|cFFCCCCCCVerdict:|r |cFFFFAA00deferred: %s|r", detail))
    end
  else
    local Config = ApexFury.Config
    local interval    = Config.Get(Config.Options.STACK_INTERVAL)
    local threshold   = Config.Get(Config.Options.THRESHOLD)
    local minRem      = Config.Get(Config.Options.MIN_REMAINING) or 0
    local requiredDur = (threshold - 1) * interval + ApexFury.Watcher.THRESHOLD_BUFFER
    local predictedEnd = state.expectedTriggerEnd or (state.castTime + ApexFury.Watcher.DR_BASE_DURATION)
    local actualDur   = state.triggerDropTime
                      and (state.triggerDropTime - state.castTime)
                       or (predictedEnd - state.castTime)
    local rem         = state.estLingerRemaining or math.huge
    local rfAlive     = (not state.triggerDropTime) or (rem > 0)
    local canExtend   = state.gateAnimosity ~= false
                        and now <= predictedEnd + ApexFury.Watcher.EMPOWER_LATENCY_GRACE

    if actualDur < requiredDur and canExtend then
      lines[6]:SetText(string.format(
        "|cFFCCCCCCVerdict:|r |cFFFFAA00wait: DR %.1fs / %.1fs needed|r",
        actualDur, requiredDur))
    elseif actualDur < requiredDur then
      lines[6]:SetText(string.format(
        "|cFFCCCCCCVerdict:|r |cFFFF8800suppress: DR %.1fs < %.1fs needed|r",
        actualDur, requiredDur))
    elseif not rfAlive then
      lines[6]:SetText("|cFFCCCCCCVerdict:|r |cFFFF8800suppress: linger expired|r")
    elseif rem ~= math.huge and rem < minRem then
      lines[6]:SetText(string.format(
        "|cFFCCCCCCVerdict:|r |cFFFF8800suppress: linger %.1fs < %.1fs|r",
        rem, minRem))
    else
      lines[6]:SetText("|cFFCCCCCCVerdict:|r |cFF00FF00WOULD FIRE|r |cFF555555(all gates pass)|r")
    end
  end

  -- Line 7: talent gate (always rendered when usable, since "ready" is
  -- the common case but "no_animosity" is the user's reminder that
  -- threshold ≥4 alerts can't fire).
  RenderGateLine(state)
end

---------------------------------------------------------------------------
-- The overlay's saved state, APEX_FURY_UI_STATE.overlay: its place (the
-- shell's persist writes point, relativePoint, x, y and the size into it
-- and leaves other keys alone) and the `shown` flag
---------------------------------------------------------------------------
local function GetUIState()
  APEX_FURY_UI_STATE = APEX_FURY_UI_STATE or {}
  return APEX_FURY_UI_STATE
end

local function GetOverlayState()
  local state = GetUIState()
  if type(state.overlay) ~= "table" then state.overlay = {} end
  return state.overlay
end

---------------------------------------------------------------------------
-- Frame creation: once, at load (the end of this file), so showing the
-- overlay for the first time in combat creates nothing
---------------------------------------------------------------------------
local function BuildFrame()
  if frame then return frame end

  -- Shared window shell (solid background, drag to move). The shell's
  -- persist saves the place on drag stop, and Overlay.Show restores it,
  -- checked field by field, before showing. A fixed size: the line count
  -- sets the height, never a saved one.
  local f = UI.CreateWindow({
    name       = "ApexFuryOverlay",
    title      = ApexFury.WrapBrand("ApexFury"),
    width      = 290,
    height     = 34 + NUM_LINES * 22 + 12,
    strata     = "MEDIUM",
    toplevel   = false,
    closeButtonInCombat = false,
    persist    = {
      svTable   = GetUIState,
      key       = "overlay",
      defaults  = { point = "CENTER", relPoint = "CENTER", x = 200, y = 0 },
      fixedSize = true,
    },
  })

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
    line:SetText("...")
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
  -- The saved place (right of center on the first show)
  frame:RestoreState()
  frame:Show()
  GetOverlayState().shown = true
end

function Overlay.Hide()
  if frame then frame:Hide() end
  GetOverlayState().shown = false
end

function Overlay.Toggle()
  if frame and frame:IsShown() then
    Overlay.Hide()
  else
    Overlay.Show()
  end
end

function Overlay.RestoreFromSavedVar()
  if GetOverlayState().shown == true then
    Overlay.Show()
  end
end

-- Built hidden now: the overlay is there to be watched in combat, and a
-- first /af overlay, the settings window's Overlay button or a restore after
-- a /reload can all come mid-fight. Its OnUpdate only runs while it shows.
BuildFrame()

-- For ApexFury's Watcher and Overlay suites: one display update and a line's text
Overlay._test = {
  Update = UpdateDisplay,
  GetLineText = function(i)
    return lines[i] and lines[i]:GetText() or nil
  end,
}
