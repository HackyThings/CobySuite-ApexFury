-------------------------------------------------------------------------------
-- ApexFury: Stack alert via cast-driven predictive timing
--
-- Background:
--   In Midnight 12.0, Rising Fury is flagged as a "private aura": the
--   `applications`, `expirationTime`, `spellId`, and `name` fields all
--   return secret values during combat. We cannot read stack count or
--   identify the aura while the player is in combat.
--
--   We previously tried to identify the Rising Fury aura instance among
--   the auras the engine adds within ~1s of Dragonrage cast and observe
--   its drop time. That approach was unworkable: every other aura the
--   player happens to gain in that window, Augmentation Evoker buffs
--   (Prescience, Ebon Might), healer HoTs (Renewing Mist, Atonement),
--   the player's own combat potion buff, trinket procs, hero-talent
--   procs (Light's Potential), Tip the Scales, etc., also lands in the
--   captured set with secret-value spellIds, and any of them can win
--   the fallback heuristic. We had a blacklist that grew without bound
--   and still couldn't cover every group composition or potion variant.
--
-- Design (predictive only):
--   1. Watch UNIT_SPELLCAST_SUCCEEDED for the configured TRIGGER spell.
--      Cast events are NOT subject to the private-aura system; spell IDs
--      and unit tokens are always public.
--   2. Schedule the alert at +(threshold - 1) * interval seconds.
--   3. Track empower casts via the EMPOWER_START → EMPOWER_STOP channel
--      lifecycle. EMPOWER_START sets an in-flight flag; the SUCCEEDED that
--      follows is recognized as part of the channel and ignored. STOP
--      complete=true counts the empower (channel landed during active DR: 
--      Animosity extends per the formula +5s × 0.75^N) and clears the flag.
--      STOP complete=false just clears the flag (cancel: no extension,
--      not counted). Tip-the-Scales instants fire neither START nor STOP,
--      so their SUCCEEDED arrives with the flag clear and is the count
--      signal in that path. Cancels never count because the model never
--      speculatively increments on SUCCEEDED for channels, so there's
--      no retract logic.
--   4. Compute `expectedTriggerEnd = castTime + 18 + Σ 5 × 0.75^i` where
--      i ranges over empowers cast so far. This is empirically accurate
--      to ±0.05s on real-pull cycles. It's the source of truth for "when
--      does Dragonrage end": we never observe the actual aura drop in
--      combat, but the deterministic Animosity formula matches reality.
--   5. At the alert moment (ResolveAlertMoment):
--      - If combat_only and player not in combat → defer.
--      - If actionability_gate and player can't act (vehicle / mount /
--        CC / possession) → defer with reason.
--      - Otherwise fire sound (subject to predicted-duration and linger
--        gates inside FireAlert).
--   6. On combat re-entry / vehicle exit / CC end / mount change with a
--      pending alert, re-evaluate. The linger gate uses the predictive
--      end as the "drop time": once `now > expectedTriggerEnd`, we're in
--      the post-Dragonrage Rising Fury linger phase, expiring at
--        expectedTriggerEnd + min(linger_max, stacks × linger_per_stack)
--      where stacks is computed by clamping elapsed to expectedTriggerEnd.
--      Only Rising Fury rank 3 has that linger: when the talent gate
--      reports a lower rank, nothing is left once the predicted end has
--      passed (LingerEligible). Unknown talent data keeps the linger.
--      A 0.5s polling ticker catches changes with no dedicated event, and
--      a pending alert still unresolved 45s after it was deferred is
--      suppressed as "rf_expired" (ScheduleStalePendingCleanup).
--   7. A "too short" verdict is provisional while a late empower could
--      still extend the cycle: when FireAlert finds the predicted duration
--      too short at or before expectedTriggerEnd + EMPOWER_LATENCY_GRACE
--      (and Animosity is not known to be missing), it holds until that
--      moment instead of suppressing. An empower counted during the hold
--      that extends the prediction runs the alert moment again
--      ("late_empower"); otherwise the hold settles into the suppression.
--      Death, a zone change and a config change end the hold for good.
--
-- What we do NOT track:
--   - Aura identification (spellId or name match). All field reads are
--     secret values in combat for the auras we'd want to identify, so
--     this never produces useful data, confirmed across 3855 lines of
--     real-pull log with zero successful positive matches.
--   - Trigger drop observation. We don't know when Rising Fury actually
--     ends; the predictive Animosity model is our authority instead. Edge
--     cases where the user manually cancels Rising Fury or some unknown
--     mechanic ends DR early aren't caught, but they weren't caught
--     before either (we'd have observed the wrong aura). PLAYER_DEAD and
--     PLAYER_LEAVING_WORLD remain handled.
--
-- For the overlay's "DR remain (read)" line, the watcher reads the trigger
-- aura once by spell ID, 0.1s after the cast and after each counted
-- empower, and only out of combat (ReadTriggerOnce, `observedTriggerEnd`).
-- It never watches UNIT_AURA and never reads an aura it cannot name, and no
-- alert decision reads that value. The overlay makes no aura calls of its
-- own; it shows the read while it is still running, otherwise the model.
--
-- Tests reach the file-local pieces through Watcher._test (fake clock,
-- timers, combat and actionability state, the aura reader). Every time
-- read and timer here goes through Now / After / NewTimer / NewTicker.
-------------------------------------------------------------------------------

local Watcher = ApexFury.Watcher
local Config = ApexFury.Config
local Debug = ApexFury.Debug

-- Internal state ----------------------------------------------------------
local castTime              -- when trigger spell last cast (or nil)
local alertScheduledFor     -- absolute time the timer is set to elapse
local observedTriggerEnd    -- the trigger aura's expiration from the one-shot
                            -- out-of-combat read (display only; nil when
                            -- there is no read for the current prediction)
local empowerCount          -- empower casts observed since trigger cast
local inFlightEmpower       -- spellID of an empower channel with EMPOWER_START
                            -- seen but no STOP yet (nil = no channel in flight).
                            -- Lets the SUCCEEDED handler distinguish "this is
                            -- a TtS instant, count now" from "this is part of
                            -- a channel, defer to STOP".
local expectedTriggerEnd    -- predicted absolute time the trigger buff will
                            -- end. Drives every in-combat timing decision.
local alertFired            -- bool: sound has been played
local soundFailed           -- bool: this cycle's sound and its retry both failed to play
local alertPending          -- bool: alert moment reached but deferred (out of combat or unable to act)
local alertSuppressed       -- bool: alert was cancelled
local lastFiredTime         -- last time alert actually played sound
local lastFiredOffset       -- precise elapsed seconds from cast to fire
local lastSuppressOffset    -- precise elapsed seconds from cast to suppression
local lastSuppressReason    -- "linger_expired" / "rf_too_short" / "trigger_too_short" / "rf_expired" / "disabled" / "death" / "zone" / nil
local pendingTimer          -- the alert moment's one-shot C_Timer handle (or nil)
local pendingDeferReason    -- "ooc" / "vehicle" / "vehicle_ui" / "mounted" / "possessed" / "loss_of_control"
local pendingPollTimer      -- C_Timer.NewTicker handle while alertPending; resolves the deferral
local provisionalUntil      -- while a too-short verdict waits for a late
                            -- empower: the moment it settles (nil = no hold)
local provisionalTimer      -- timer handle that settles the hold
local watcherFrame
local active = false        -- cycle events registered? (TalentGate-controlled)

-- Delay before the one-shot trigger aura read, so the aura the cast or
-- empower applied or extended is already there
local TRIGGER_READ_DELAY = 0.1

-- Threshold safety buffer: built-in constant. For threshold N at interval I,
-- we need the trigger buff to actually run for at least (N-1)*I + buffer
-- seconds; otherwise the Nth stack tick races the buff's expiration and
-- loses (e.g. unextended Dragonrage at exactly 18s yields 3 stacks of
-- Rising Fury, not 4). 0.1s puts us firmly past the boundary.
local THRESHOLD_BUFFER = 0.1

-- Secret-value gate (12.0 secret values, 12.1 fully secret aura data).
-- True for secret scalars and secret tables; false for nil and plain data.
local function IsSecret(v)
  if v == nil then return false end
  if issecretvalue and issecretvalue(v) then return true end
  if issecrettable and type(v) == "table" and issecrettable(v) then return true end
  return false
end

-- Empower arrival-latency grace. UNIT_SPELLCAST_SUCCEEDED arrives client-side
-- after the server has already resolved the cast and (if Animosity applied)
-- extended Dragonrage. Under typical M+ latency (~100-300ms) and rarely up
-- to ~500ms, an empower truly cast within DR can SUCCEED on the client up
-- to that long after our predicted DR end. Without a grace, those late-
-- arriving SUCCEEDED events get rejected and we under-count empowers,
-- false-suppressing high-threshold alerts on cycles that did extend.
-- 0.5s covers typical lag without letting truly post-DR empowers (cast
-- after server-side DR ended, no Animosity applied) inflate the model.
local EMPOWER_LATENCY_GRACE = 0.5

-- Empower spell IDs we track for Animosity duration extension. Counted
-- on UNIT_SPELLCAST_EMPOWER_STOP with complete=true (channeled release
-- landed during DR), or on UNIT_SPELLCAST_SUCCEEDED when no channel is
-- in flight (Tip-the-Scales instant: fires neither START nor STOP).
-- Cancels (STOP with complete=false) never count: the conservative
-- model defers all counting until the channel resolves successfully,
-- so there's nothing to undo on cancel.
--
-- Both base AND Font-of-Magic variants must be listed. Font of Magic is a
-- Devastation talent (spell 411212) that overrides the action-bar spell IDs
-- via SPELL_AURA_OVERRIDE_ACTIONBAR_SPELL; the cast event then fires with
-- the FoM variant ID (382266/382411) instead of the base (357208/359073).
-- Missing the FoM variants caused empowerCount=0 for every cycle on FoM-
-- talented users, suppressing every alert with "trigger duration < required"
-- (real-pull bug report 2026-05-02). FoM is a near-default high-end talent,
-- so this affected the addon's primary audience.
local EMPOWER_SPELL_IDS = {
  [357208] = "Fire Breath",            -- base
  [359073] = "Eternity Surge",         -- base
  [382266] = "Fire Breath (FoM)",      -- Font of Magic variant
  [382411] = "Eternity Surge (FoM)",   -- Font of Magic variant
}

-- Trigger duration model (Devastation Evoker / Dragonrage defaults).
-- Used to PREDICT how long DR will run based on observed empower casts.
-- Each empower extends DR via the Animosity talent: +5s with 25%
-- diminishing returns per cast.
local DR_BASE_DURATION       = 18
local ANIMOSITY_EXTENSION    = 5
local ANIMOSITY_DIMINISHING  = 0.75

-- Exposed for the Overlay's verdict-line preview and the settings window's
-- timeline, which must mirror this module's CheckTriggerRanLongEnough /
-- PredictedTriggerEnd / CanStillExtend math. Keeping the constants on the
-- public module means a single edit here propagates to both without
-- cross-file drift.
Watcher.THRESHOLD_BUFFER = THRESHOLD_BUFFER
Watcher.DR_BASE_DURATION = DR_BASE_DURATION
Watcher.ANIMOSITY_EXTENSION = ANIMOSITY_EXTENSION
Watcher.ANIMOSITY_DIMINISHING = ANIMOSITY_DIMINISHING
Watcher.EMPOWER_LATENCY_GRACE = EMPOWER_LATENCY_GRACE

-- The stacks every Dragonrage reaches without an extension (no Animosity):
-- 3 at the default 6s interval. interval: the seconds between stacks, or nil
-- for the saved one. For the chat lines, the overlay and the settings window.
function Watcher.StacksWithoutExtension(interval)
  interval = interval or Config.Get(Config.Options.STACK_INTERVAL)
  if type(interval) ~= "number" or interval <= 0 then return 1 end
  return math.floor((DR_BASE_DURATION - THRESHOLD_BUFFER) / interval) + 1
end

---------------------------------------------------------------------------
-- Clock, timers, combat and actionability state and the aura reader, each
-- swappable by the test suite through Watcher._test and resolved at call
-- time. nil overrides mean the real GetTime, C_Timer, unit state and
-- C_UnitAuras.
---------------------------------------------------------------------------
local testClock           -- function returning the current time
local testTimers          -- { After, NewTimer, NewTicker }
local testCombat          -- boolean
local testActionability   -- { canAct, reason }
local testAuraReader      -- function(spellID) returning aura data
local auraReads = 0       -- trigger aura reads attempted, for the suite

local function Now()
  if testClock then return testClock() end
  return GetTime()
end

local function After(seconds, fn)
  if testTimers then return testTimers.After(seconds, fn) end
  return C_Timer.After(seconds, fn)
end

local function NewTimer(seconds, fn)
  if testTimers then return testTimers.NewTimer(seconds, fn) end
  return C_Timer.NewTimer(seconds, fn)
end

local function NewTicker(seconds, fn)
  if testTimers then return testTimers.NewTicker(seconds, fn) end
  return C_Timer.NewTicker(seconds, fn)
end

local function InCombat()
  if testCombat ~= nil then return testCombat end
  return UnitAffectingCombat("player")
end

---------------------------------------------------------------------------
-- Tiny helper: cancel a C_Timer handle if non-nil, return nil for the
-- assign-back idiom. Usage: `pendingTimer = CancelTimer(pendingTimer)`.
---------------------------------------------------------------------------
local function CancelTimer(t)
  if t then t:Cancel() end
  return nil
end

-- Ends a provisional too-short hold without settling it
local function ClearProvisional()
  provisionalTimer = CancelTimer(provisionalTimer)
  provisionalUntil = nil
end

---------------------------------------------------------------------------
-- Reset state
---------------------------------------------------------------------------
local function ResetState()
  castTime = nil
  alertScheduledFor = nil
  observedTriggerEnd = nil
  empowerCount = 0
  inFlightEmpower = nil
  expectedTriggerEnd = nil
  alertFired = false
  soundFailed = false
  alertPending = false
  alertSuppressed = false
  lastSuppressReason = nil
  -- Per-cycle outcome offsets: reset so the next cycle's overlay
  -- "Fired after" line doesn't show stale data from the previous cycle.
  -- lastFiredTime is intentionally preserved across cycles for the
  -- separate "Last alert: Xs ago" display.
  lastFiredOffset = nil
  lastSuppressOffset = nil
  pendingTimer = CancelTimer(pendingTimer)
  pendingPollTimer = CancelTimer(pendingPollTimer)
  pendingDeferReason = nil
  ClearProvisional()
end

---------------------------------------------------------------------------
-- Compute the expected trigger buff end time based on empower casts so far.
-- Animosity formula: +5s per empower with 25% diminishing returns per cast.
--
-- Without Animosity, empowers don't extend Dragonrage at all: predicted
-- end stays at the 18s base. We consult TalentGate's `hasAnimosity` flag
-- to know which formula applies. Animosity is assumed unless the gate
-- reports hasAnimosity == false (found at rank 0): no gate, or a nil
-- reading (not found yet), keeps the formula. The gate's own warning chat
-- message is the user's signal that threshold ≥4 won't fire.
---------------------------------------------------------------------------
local function ComputeExpectedTriggerEnd()
  if not castTime then return nil end

  local hasAnimosity = true
  local gate = ApexFury.GetTalentGate()
  if gate and gate.hasAnimosity == false then hasAnimosity = false end

  if not hasAnimosity then
    return castTime + DR_BASE_DURATION
  end

  local totalExtension = 0
  for i = 0, empowerCount - 1 do
    totalExtension = totalExtension + ANIMOSITY_EXTENSION * (ANIMOSITY_DIMINISHING ^ i)
  end
  return castTime + DR_BASE_DURATION + totalExtension
end

---------------------------------------------------------------------------
-- Talent data that loads late can turn an unknown Animosity reading into a
-- known miss during a cycle: the extensions counted while it was assumed
-- never happened, so the prediction drops back to the 18s base. A reading
-- that turns up talented changes nothing.
local function DropAssumedExtensions()
  if not (castTime and expectedTriggerEnd) then return end
  if expectedTriggerEnd <= castTime + DR_BASE_DURATION then return end
  local gate = ApexFury.GetTalentGate()
  if gate and gate.hasAnimosity == false then
    expectedTriggerEnd = castTime + DR_BASE_DURATION
  end
end

---------------------------------------------------------------------------
-- The "predicted DR end" used everywhere downstream. Always returns a
-- valid number when castTime is set; falls back to base 18s if the
-- empower formula hasn't produced a value yet (shouldn't happen since
-- OnTriggerCast sets expectedTriggerEnd at cast time, but defend anyway).
---------------------------------------------------------------------------
local function PredictedTriggerEnd()
  if not castTime then return nil end
  DropAssumedExtensions()
  return expectedTriggerEnd or (castTime + DR_BASE_DURATION)
end

---------------------------------------------------------------------------
-- Compute the maximum stack count delivered by the trigger.
--
-- Stack ticks happen at t=interval, 2*interval, ... while the trigger is
-- active. A tick scheduled exactly when the trigger ENDS doesn't fire
-- (lost to the race), so we subtract a tiny epsilon.
--
-- The "effective end" for stack accumulation is min(now, predictedEnd):
-- during DR (now < predictedEnd) stacks grow with elapsed time; once DR
-- has predicted-ended (now >= predictedEnd), stacks freeze at whatever
-- they reached when DR ended. The deterministic Animosity formula is
-- the authority here; we never observe the actual aura drop in combat.
---------------------------------------------------------------------------
local function ComputeMaxStacksReached()
  if not castTime then return 0 end
  local interval = Config.Get(Config.Options.STACK_INTERVAL)
  local maxStacks = Config.Get(Config.Options.MAX_STACKS)

  local now = Now()
  local effectiveEnd = math.min(now, PredictedTriggerEnd())
  local elapsed = effectiveEnd - castTime - 0.05  -- boundary tick epsilon
  if elapsed < 0 then return 1 end

  return math.min(maxStacks, 1 + math.floor(elapsed / interval))
end

---------------------------------------------------------------------------
-- The stack count Rising Fury is projected to reach when Dragonrage ends,
-- from the predicted end as it stands (empowers counted so far). Unlike
-- ComputeMaxStacksReached it does not stop at `now`, so mid-cycle it is
-- the number the cycle is heading for, not the number reached. Same
-- boundary tick epsilon; 0 with no cycle or a non-positive interval.
---------------------------------------------------------------------------
local function ComputeProjectedStacksAtDrop()
  if not castTime then return 0 end
  local interval = Config.Get(Config.Options.STACK_INTERVAL)
  if type(interval) ~= "number" or interval <= 0 then return 0 end
  local maxStacks = Config.Get(Config.Options.MAX_STACKS)

  local elapsed = PredictedTriggerEnd() - castTime - 0.05
  if elapsed < 0 then return 1 end

  return math.min(maxStacks, 1 + math.floor(elapsed / interval))
end

---------------------------------------------------------------------------
-- Will the trigger buff run long enough for the threshold-th stack tick to
-- definitively fire? Uses the predictive Animosity model, the only signal
-- we have for DR duration in 12.0 (private aura, can't observe drop in
-- combat).
---------------------------------------------------------------------------
local function CheckTriggerRanLongEnough()
  if not castTime then return false end
  local interval = Config.Get(Config.Options.STACK_INTERVAL)
  local threshold = Config.Get(Config.Options.THRESHOLD)
  local requiredDuration = (threshold - 1) * interval + THRESHOLD_BUFFER
  local actualDuration = PredictedTriggerEnd() - castTime
  return actualDuration >= requiredDuration, actualDuration, requiredDuration
end

---------------------------------------------------------------------------
-- Does this character get the post-Dragonrage Rising Fury linger? Only
-- rank 3 has it. The talent gate's rank counts only while it reports talent
-- data available and a rank of at least 1 (the watcher is active only then
-- anyway); with no usable reading the linger model stays on, as it was
-- before the rank was known.
---------------------------------------------------------------------------
local function LingerEligible()
  local gate = ApexFury.GetTalentGate()
  if gate and gate.apiAvailable
     and type(gate.risingFuryRank) == "number" and gate.risingFuryRank >= 1 then
    return gate.risingFuryRank >= 3
  end
  return true
end

---------------------------------------------------------------------------
-- Compute estimated linger remaining (seconds). Returns:
--   math.huge when DR is still predicted to be active (linger not started)
--   number when in linger window
--   0 when linger has fully expired, or once DR has predicted-ended for a
--   character without the rank 3 linger
---------------------------------------------------------------------------
local function EstimateLingerRemaining()
  if not castTime then return 0 end
  local now = Now()
  local predictedEnd = PredictedTriggerEnd()
  if now < predictedEnd then return math.huge end
  if not LingerEligible() then return 0 end

  local lingerPer = Config.Get(Config.Options.LINGER_PER_STACK)
  local lingerMax = Config.Get(Config.Options.LINGER_MAX)
  local stacksAtDrop = ComputeMaxStacksReached()
  local lingerDuration = math.min(lingerMax, stacksAtDrop * lingerPer)
  local expiresAt = predictedEnd + lingerDuration
  return math.max(0, expiresAt - now)
end

---------------------------------------------------------------------------
-- Are stacks still available for the alert to be meaningful?
--
-- During predicted DR: stacks are accumulating, presumed available.
-- After predicted DR end: linger phase, available iff linger remaining > 0.
---------------------------------------------------------------------------
local function PresumablyHasStacks()
  if not castTime then return false end
  local now = Now()
  if now < PredictedTriggerEnd() then return true end
  return EstimateLingerRemaining() > 0
end

---------------------------------------------------------------------------
-- Can an empower still extend this cycle's predicted end? True up to the
-- predicted end plus the arrival-latency grace CountEmpower accepts, unless
-- the talent gate knows Animosity is missing (empowers then extend nothing).
---------------------------------------------------------------------------
local function CanStillExtend()
  if not castTime then return false end
  local gate = ApexFury.GetTalentGate()
  if gate and gate.hasAnimosity == false then return false end
  return Now() <= PredictedTriggerEnd() + EMPOWER_LATENCY_GRACE
end

local SettleProvisional   -- defined after FireAlert, which it calls

---------------------------------------------------------------------------
-- Fire the alert (sound). Verifies the trigger context still holds and
-- that linger remaining meets the configured minimum.
--
-- settling: true when a provisional hold settles, so a too-short verdict
-- becomes final instead of holding again.
---------------------------------------------------------------------------
local function FireAlert(reasonContext, settling)
  if alertFired or alertSuppressed then return end

  -- Reaching FireAlert means this attempt resolves the cycle one way
  -- or another (fire, suppress, or a provisional hold). Clear alertPending
  -- up front so the overlay's PENDING (waiting for combat) status doesn't
  -- get stuck on after a suppress branch returns.
  alertPending = false
  ClearProvisional()

  if not Config.Get(Config.Options.ENABLED) then
    alertSuppressed = true
    lastSuppressReason = "disabled"
    if castTime then lastSuppressOffset = Now() - castTime end
    return
  end

  -- One-line dump of every gate input at the exact moment FireAlert was
  -- entered, BEFORE any gate runs. Useful for verifying deferred-alert
  -- resolution paths (TryFirePending → FireAlert) where the user wants
  -- to see whether the model thought DR was still active or in linger.
  if Config.Get(Config.Options.VERBOSE) then
    local _, actualDur, requiredDur = CheckTriggerRanLongEnough()
    local lingerRem = EstimateLingerRemaining()
    local elapsed = castTime and (Now() - castTime) or 0
    Debug.Log("WATCHER",
      "FireAlert(%s) @ +%.2fs: predDR=%.2fs req=%.2fs linger=%s empowers=%d",
      reasonContext, elapsed,
      actualDur or 0, requiredDur or 0,
      lingerRem == math.huge and "active" or string.format("%.2fs", lingerRem),
      empowerCount or 0)
  end

  -- Did the trigger buff run long enough to actually deliver the threshold
  -- stack? Decided before the linger gate: a too-short verdict reached
  -- while an empower could still extend the cycle is provisional. It holds
  -- until the predicted end plus the grace; CountEmpower re-runs the alert
  -- moment if a late empower extends the prediction, and otherwise the
  -- hold settles here with settling=true.
  local longEnough, actualDur, requiredDur = CheckTriggerRanLongEnough()
  if not longEnough and not settling and CanStillExtend() then
    provisionalUntil = PredictedTriggerEnd() + EMPOWER_LATENCY_GRACE
    local holdUntil = provisionalUntil
    provisionalTimer = NewTimer(math.max(0, holdUntil - Now()), function()
      if provisionalUntil ~= holdUntil then return end   -- hold ended or replaced
      SettleProvisional()
    end)
    Debug.Log("WATCHER",
      "Alert held @ %s: trigger duration %.2fs < required %.2fs, waiting %.2fs for a late empower (empowers=%d)",
      reasonContext, actualDur, requiredDur, holdUntil - Now(), empowerCount or 0)
    return
  end

  -- Too short for good: the threshold tick was lost to the trigger-end race
  -- (e.g. unextended DR at 18s yields 3 stacks of Rising Fury, not 4), even
  -- if linger auras are still alive. Driven by the predictive Animosity
  -- model, and decided before the linger gate: below rank 3 there is no
  -- linger once the predicted end has passed, and a hold settles at or after
  -- that end, so the linger gate would claim every too-short cycle and the
  -- overlay would blame the linger for a Dragonrage no empower extended.
  if not longEnough then
    alertSuppressed = true
    lastSuppressReason = "trigger_too_short"
    if castTime then lastSuppressOffset = Now() - castTime end
    Debug.Log("WATCHER", "Alert suppressed @ %s: trigger duration %.2fs < required %.2fs (empowers=%d)",
      reasonContext, actualDur, requiredDur, empowerCount)
    return
  end

  -- Rising Fury still presumed alive per the predictive linger model?
  -- (We never observe the actual drop in combat, since Rising Fury's fields are
  -- secret values during combat, so the Animosity-extended predicted end
  -- is the source of truth. After predicted end, linger ticks down toward
  -- linger_max, for rank 3 only.)
  if not PresumablyHasStacks() then
    alertSuppressed = true
    lastSuppressReason = "linger_expired"
    if castTime then lastSuppressOffset = Now() - castTime end
    local predDur = (expectedTriggerEnd and castTime)
                    and (expectedTriggerEnd - castTime) or 0
    Debug.Log("WATCHER",
      "Alert suppressed @ %s: Rising Fury linger expired (predDR=%.2fs, stacksAtDrop=%d, empowers=%d)",
      reasonContext, predDur, ComputeMaxStacksReached(), empowerCount or 0)
    return
  end

  -- Linger-remaining gate (only relevant after predicted DR end)
  local minRemaining = Config.Get(Config.Options.MIN_REMAINING) or 0
  local lingerRem = EstimateLingerRemaining()
  if lingerRem ~= math.huge and lingerRem < minRemaining then
    alertSuppressed = true
    lastSuppressReason = "rf_too_short"
    if castTime then lastSuppressOffset = Now() - castTime end
    Debug.Log("WATCHER", "Alert suppressed @ %s: linger %.2fs < min %.2fs",
      reasonContext, lingerRem, minRemaining)
    return
  end

  alertFired = true

  -- WoW's sound mixer can reject PlaySound/PlaySoundFile dispatches under
  -- heavy combat (channel saturation). On failure, surface it to the log
  -- and retry once after a short delay: by the next frame the mixer has
  -- typically freed a slot. Without this, an alert can silently go out
  -- while the overlay reports "fired".
  local soundValue   = Config.Get(Config.Options.SOUND_ID)
  local soundChannel = Config.Get(Config.Options.SOUND_CHANNEL)
  local handle, willPlay = ApexFury.Sound.Play(soundValue, soundChannel)
  if not (willPlay and handle) then
    Debug.Warn("WATCHER",
      "Sound dispatch returned willPlay=%s handle=%s: retrying in 50ms (mixer likely saturated)",
      tostring(willPlay), tostring(handle))
    local cycleCast = castTime
    After(0.05, function()
      local h2, wp2 = ApexFury.Sound.Play(soundValue, soundChannel)
      if wp2 and h2 then
        Debug.Log("WATCHER", "Sound retry succeeded")
      else
        -- the overlay says so; a newer cycle keeps its own outcome
        if castTime == cycleCast then soundFailed = true end
        Debug.Warn("WATCHER",
          "Sound retry also failed (willPlay=%s handle=%s): alert was inaudible",
          tostring(wp2), tostring(h2))
      end
    end)
  end

  lastFiredTime = Now()
  if castTime then lastFiredOffset = lastFiredTime - castTime end

  -- Cycle resolution summary. One always-on line that captures every
  -- relevant number from the cycle so post-pull review can verify each
  -- decision without verbose mode. Every suppress branch above but
  -- "disabled" logs its own summary.
  local predDur = (expectedTriggerEnd and castTime)
                  and (expectedTriggerEnd - castTime) or 0
  local lingerRemFinal = EstimateLingerRemaining()
  Debug.Event("WATCHER",
    "Alert fired @ %s (threshold=%d, offset=%.3fs, predDR=%.2fs, empowers=%d, linger=%s)",
    reasonContext,
    Config.Get(Config.Options.THRESHOLD) or 0,
    lastFiredOffset or 0,
    predDur,
    empowerCount or 0,
    lingerRemFinal == math.huge and "active" or string.format("%.2fs", lingerRemFinal))
end

-- A provisional hold ran out with no late empower: the too-short verdict
-- becomes final (FireAlert with settling=true)
function SettleProvisional()
  provisionalTimer = nil
  if not provisionalUntil then return end
  provisionalUntil = nil
  FireAlert("provisional_settle", true)
end

---------------------------------------------------------------------------
-- Actionability check: can the player meaningfully act on an alert RIGHT
-- NOW? Used at the alert moment (timer or late empower) and by
-- TryFirePending to defer, or keep deferring, alerts when the player is
-- in a vehicle, mounted (incl. skyriding combat mounts on bosses like
-- Dimensius P2 / Amirdrassil flying phase), possessed by a boss
-- mind-control mechanic, or affected by stuns/fear/silences/etc.
--
-- Returns (canAct, reason). reason is one of:
--   "vehicle" / "vehicle_ui" / "mounted" / "possessed" / "loss_of_control"
-- or nil when canAct=true.
---------------------------------------------------------------------------
local function CheckActionability()
  if testActionability then
    return testActionability.canAct, testActionability.reason
  end
  if UnitInVehicle("player") then return false, "vehicle" end
  if UnitHasVehicleUI("player") then return false, "vehicle_ui" end
  if IsMounted() then return false, "mounted" end

  local possessOk, possessed = pcall(UnitIsPossessed, "player")
  if possessOk and possessed then return false, "possessed" end

  -- C_LossOfControl exposes active CC effects (stun/fear/charm/disorient/
  -- incapacitate/silence/root). Wrap in pcall: older clients or some
  -- WoW build niches have surfaced nil here.
  local locOk, locCount = pcall(function()
    if C_LossOfControl and C_LossOfControl.GetActiveLossOfControlDataCount then
      return C_LossOfControl.GetActiveLossOfControlDataCount()
    end
    return 0
  end)
  if locOk and type(locCount) == "number" and locCount > 0 then
    return false, "loss_of_control"
  end

  return true, nil
end

---------------------------------------------------------------------------
-- Schedule the 45s stale-pending cleanup. Snapshots castTime so the
-- cleanup only fires for THIS cycle: if the user casts again before
-- 45s elapses, ResetState will have nilled or replaced castTime and
-- we don't want to clobber the new cycle's pending state.
--
-- Worst-case linger end is castTime + max DR (18s plus at most 20s from
-- empowers, the Animosity series' limit) + LINGER_MAX (default 20s) ≈ 58s
-- after cast. The deferral happens at the alert moment (+18s at the
-- default threshold), so 45s from then covers it.
---------------------------------------------------------------------------
local function ScheduleStalePendingCleanup()
  local snapshotCastTime = castTime
  After(45, function()
    if castTime ~= snapshotCastTime then return end
    if alertPending and not alertFired and not alertSuppressed then
      alertPending = false
      alertSuppressed = true
      lastSuppressReason = "rf_expired"
      if castTime then lastSuppressOffset = Now() - castTime end
      pendingPollTimer = CancelTimer(pendingPollTimer)
      Debug.Log("WATCHER", "Pending alert cleared: linger expired without recovery (last reason: %s)",
        tostring(pendingDeferReason or "?"))
      pendingDeferReason = nil
    end
  end)
end

---------------------------------------------------------------------------
-- TryFirePending: unified resolution path for deferred alerts. Re-checks
-- BOTH gates (combat-only and actionability) and fires only when both
-- pass. Called from PLAYER_REGEN_DISABLED (existing OOC path) and from the
-- new actionability event handlers + polling fallback. FireAlert itself
-- still gates on linger remaining and trigger duration, so a recovery
-- past the linger window suppresses cleanly instead of firing late.
---------------------------------------------------------------------------
-- The displayed reason follows the *current* blocker, so the overlay never
-- names one that has cleared (exited a vehicle into a stun, or combat ended
-- while mounted)
local function UpdatePendingReason(reason)
  if reason ~= pendingDeferReason then
    Debug.Log("WATCHER", "Pending defer reason updated: %s -> %s",
      tostring(pendingDeferReason), tostring(reason))
    pendingDeferReason = reason
  end
end

local function TryFirePending(reasonContext)
  if not (alertPending and not alertFired and not alertSuppressed) then return end

  if Config.Get(Config.Options.COMBAT_ONLY) and not InCombat() then
    UpdatePendingReason("ooc")
    return  -- still OOC, keep pending
  end

  if Config.Get(Config.Options.ACTIONABILITY_GATE) then
    local canAct, reason = CheckActionability()
    if not canAct then
      UpdatePendingReason(reason)
      return
    end
  end

  -- Both gates pass: fire. FireAlert may still suppress on linger gate.
  pendingPollTimer = CancelTimer(pendingPollTimer)
  FireAlert(reasonContext)
end

---------------------------------------------------------------------------
-- Defer the alert with a tagged reason. Starts the polling fallback so
-- mount/CC transitions that don't fire dedicated events still resolve.
---------------------------------------------------------------------------
local function DeferAlert(reason)
  alertPending = true
  pendingDeferReason = reason
  Debug.Log("WATCHER", "Alert deferred (%s)", tostring(reason))

  -- Polling fallback: 0.5s ticker that re-evaluates gates. Cancels
  -- itself when alert fires, suppresses, or castTime changes (cycle
  -- replaced). Caps the implicit per-tick work at ~1 function call.
  pendingPollTimer = CancelTimer(pendingPollTimer)
  local snapshotCastTime = castTime
  pendingPollTimer = NewTicker(0.5, function()
    if castTime ~= snapshotCastTime
       or alertFired or alertSuppressed or not alertPending then
      pendingPollTimer = CancelTimer(pendingPollTimer)
      return
    end
    TryFirePending("polling")
  end)

  ScheduleStalePendingCleanup()
end

---------------------------------------------------------------------------
-- The alert moment: the timer ran out ("timer"), or a late empower extended
-- a cycle held as too short ("late_empower"). Either fire or defer (via the
-- combat-only gate or the actionability gate, depending on user config).
---------------------------------------------------------------------------
local function ResolveAlertMoment(reasonContext)
  if alertFired or alertSuppressed then return end

  -- Snapshot the predictive state at the exact moment of the decision.
  -- This is the line that lets you verify, post-pull, "what did the model
  -- think when the alert was supposed to land?", independent of which
  -- branch (defer / fire / suppress / hold) the cycle takes after this point.
  if Config.Get(Config.Options.VERBOSE) then
    local elapsed = castTime and (Now() - castTime) or 0
    local predDur = (expectedTriggerEnd and castTime)
                    and (expectedTriggerEnd - castTime) or 0
    Debug.Log("WATCHER",
      "Alert moment (%s) @ +%.2fs: predDR=%.2fs empowers=%d combat=%s",
      reasonContext, elapsed, predDur, empowerCount or 0,
      tostring(InCombat()))
  end

  if Config.Get(Config.Options.COMBAT_ONLY) and not InCombat() then
    return DeferAlert("ooc")
  end

  if Config.Get(Config.Options.ACTIONABILITY_GATE) then
    local canAct, reason = CheckActionability()
    if not canAct then
      return DeferAlert(reason)
    end
  end

  FireAlert(reasonContext)
end

-- Timer callback: the alert moment arrived
local function OnAlertTimerExpired()
  ResolveAlertMoment("timer")
end

---------------------------------------------------------------------------
-- One-shot read of the trigger aura's expiration, for the overlay's
-- "DR remain (read)" line and nothing else. Scheduled TRIGGER_READ_DELAY
-- after the cast and after each counted empower, and only out of combat:
-- one read of a non-private aura by spell ID at a known moment is safe,
-- while a read from per-frame code taints this addon's execution. Auras stay secret
-- between pulls inside Mythic+ even out of combat, so a secret table or
-- field ends the read with nothing stored; the pcall catches the rest.
---------------------------------------------------------------------------
local function ReadTriggerAura(spellID)
  if testAuraReader then return testAuraReader(spellID) end
  return C_UnitAuras.GetPlayerAuraBySpellID(spellID)
end

local function ReadTriggerOnce(cycleCastTime)
  if not castTime or castTime ~= cycleCastTime then return end   -- reset or a newer cycle
  if InCombat() then return end
  local spellID = Config.Get(Config.Options.SPELL_ID)
  if type(spellID) ~= "number" then return end

  auraReads = auraReads + 1
  local ok, expires = pcall(function()
    local aura = ReadTriggerAura(spellID)
    if aura == nil or IsSecret(aura) then return nil end
    local exp = aura.expirationTime
    if type(exp) ~= "number" or IsSecret(exp) then return nil end
    if exp <= 0 then return nil end   -- no duration
    return exp
  end)
  if ok and expires then
    observedTriggerEnd = expires
  end
end

local function ScheduleTriggerRead()
  if not castTime or InCombat() then return end
  local cycleCastTime = castTime
  After(TRIGGER_READ_DELAY, function() ReadTriggerOnce(cycleCastTime) end)
end

---------------------------------------------------------------------------
-- Increment empower count and recompute the predicted DR end. Called from
-- two paths in the OnEvent handler:
--   1. UNIT_SPELLCAST_EMPOWER_STOP with complete=true (channeled release).
--   2. UNIT_SPELLCAST_SUCCEEDED for an empower spell when no channel is in
--      flight (Tip-the-Scales instant: START/STOP don't fire for these).
--
-- Only counts empowers cast while DR is predicted to still be active (plus
-- EMPOWER_LATENCY_GRACE for client-side event arrival lag). Empowers cast
-- after the predicted end don't extend an inactive DR (Animosity only
-- extends an ACTIVE DR), so they shouldn't inflate the model. Without aura
-- observation the predictive end is our best signal for "DR is still up."
--
-- A counted empower that extends the prediction while a too-short verdict
-- is held (provisionalUntil) ends the hold and runs the alert moment again.
---------------------------------------------------------------------------
local function CountEmpower(spellID)
  if not castTime then return end
  local predictedEnd = PredictedTriggerEnd()
  local now = Now()
  if now <= predictedEnd + EMPOWER_LATENCY_GRACE then
    local oldEnd = expectedTriggerEnd
    empowerCount = (empowerCount or 0) + 1
    expectedTriggerEnd = ComputeExpectedTriggerEnd()
    -- Show the per-empower extension delta. With Animosity, this is
    -- 5×0.75^(N-1) for the Nth empower. Without Animosity, the delta
    -- is 0.00s, making it visibly clear in the log that the empower
    -- registered but didn't extend DR (the talent gate suppressed the
    -- formula). This is the cleanest way to verify Animosity detection
    -- end-to-end at cycle time.
    local delta = expectedTriggerEnd - (oldEnd or expectedTriggerEnd)
    local lateBy = now - predictedEnd
    if lateBy > 0 and Config.Get(Config.Options.VERBOSE) then
      Debug.Log("WATCHER",
        "Empower #%d (%s, id=%d): counted within %.2fs grace (%.2fs past predicted end). DR predicted to last %.2fs total (+%.2fs from this empower)",
        empowerCount, EMPOWER_SPELL_IDS[spellID], spellID,
        EMPOWER_LATENCY_GRACE, lateBy,
        expectedTriggerEnd - castTime, delta)
    else
      Debug.Log("WATCHER",
        "Empower #%d (%s, id=%d): DR predicted to last %.2fs total (+%.2fs from this empower)",
        empowerCount, EMPOWER_SPELL_IDS[spellID], spellID,
        expectedTriggerEnd - castTime, delta)
    end

    -- An earlier read no longer matches the extended prediction; read again
    -- if out of combat, otherwise the overlay shows the model
    observedTriggerEnd = nil
    ScheduleTriggerRead()

    if provisionalUntil and expectedTriggerEnd > predictedEnd then
      Debug.Log("WATCHER",
        "Late empower extended Dragonrage during the hold (%.2fs past predicted end); re-checking the alert",
        lateBy)
      ClearProvisional()
      ResolveAlertMoment("late_empower")
    end
  elseif Config.Get(Config.Options.VERBOSE) then
    Debug.Log("WATCHER",
      "Empower id=%d cast %.2fs after predicted DR end: not counted (beyond %.2fs grace)",
      spellID, now - predictedEnd, EMPOWER_LATENCY_GRACE)
  end
end

---------------------------------------------------------------------------
-- Trigger spell was cast: start a new tracking cycle
---------------------------------------------------------------------------
local function OnTriggerCast()
  if not Config.Get(Config.Options.ENABLED) then return end

  ResetState()
  castTime = Now()
  expectedTriggerEnd = ComputeExpectedTriggerEnd()

  local threshold = Config.Get(Config.Options.THRESHOLD)
  local interval = Config.Get(Config.Options.STACK_INTERVAL)
  -- Fire at the exact stack-tick moment; the 0.1s safety buffer lives
  -- inside CheckTriggerRanLongEnough as a duration requirement.
  local delay = math.max(0, (threshold - 1) * interval)
  alertScheduledFor = castTime + delay

  -- Surface the TalentGate input that drove ComputeExpectedTriggerEnd's
  -- choice of formula. If hasAnimosity is false at cast time (Animosity
  -- found at rank 0; a read failure gives nil, which keeps the formula),
  -- threshold ≥4 alerts will deterministically suppress as trigger_too_short
  -- and this is the line that explains why.
  local gate = ApexFury.GetTalentGate()
  local predDur = expectedTriggerEnd and (expectedTriggerEnd - castTime) or 0
  Debug.Log("WATCHER",
    "Trigger cast: timer at +%.2fs (suppress unless DR >= %.2fs, hasAnimosity=%s, base predDR=%.2fs)",
    delay, delay + THRESHOLD_BUFFER,
    tostring(gate and gate.hasAnimosity), predDur)

  pendingTimer = NewTimer(delay, OnAlertTimerExpired)

  -- All timing decisions downstream consult `expectedTriggerEnd`, which
  -- is updated by each counted empower (EMPOWER_STOP complete=true for
  -- channels, or SUCCEEDED for Tip-the-Scales instants). We never observe
  -- the actual Rising Fury aura drop (its fields are secret values in
  -- combat) and don't try to. The one-shot read below only feeds the
  -- overlay's display.
  ScheduleTriggerRead()
end

---------------------------------------------------------------------------
-- Combat boundary handlers
---------------------------------------------------------------------------
local function OnEnterCombat()
  if alertPending and not alertFired and not alertSuppressed then
    Debug.Log("WATCHER", "Combat entered: re-evaluating pending alert (current defer: %s)",
      tostring(pendingDeferReason or "?"))
    TryFirePending("combat_entry")
  end
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------
-- Config keys that, when changed, require the watcher to re-evaluate
-- its tracking state. Sound/UI options have no effect on the state
-- machine: ignoring them avoids resetting mid-cast and drops a flood
-- of "Config changed: sound_id ..." log noise when the user is browsing
-- the sound picker.
local WATCHER_RELEVANT_KEYS = {
  spell_id           = true,
  threshold          = true,
  stack_interval     = true,
  linger_per_stack   = true,
  linger_max         = true,
  max_stacks         = true,
  combat_only        = true,
  actionability_gate = true,
  min_remaining      = true,
  enabled            = true,
}

function Watcher.OnConfigChanged(name, old, value)
  if name and not WATCHER_RELEVANT_KEYS[name] then return end
  Debug.Log("WATCHER", "Config changed: %s %s -> %s",
    tostring(name), tostring(old), tostring(value))
  ResetState()
end

-- Reused by GetState: Overlay polls every 100ms, so we avoid the
-- ~20-field table allocation per call.
local stateView = {}

function Watcher.GetState()
  stateView.castTime           = castTime
  stateView.alertScheduledFor  = alertScheduledFor
  stateView.alertFired         = alertFired
  stateView.soundFailed        = soundFailed
  stateView.alertPending       = alertPending
  stateView.alertSuppressed    = alertSuppressed
  -- triggerDropTime: derived from the predictive Animosity model. Reads
  -- as nil while Dragonrage is predicted to still be active, and as the
  -- predicted end timestamp once `now` has passed it. The overlay treats
  -- non-nil triggerDropTime as "linger phase started," which lines up
  -- with the predicted-only design (we never observe a real drop in
  -- combat: Rising Fury's fields are secret values).
  local now = Now()
  stateView.now = now   -- the overlay renders against the same clock
  DropAssumedExtensions()
  if castTime and expectedTriggerEnd and now >= expectedTriggerEnd then
    stateView.triggerDropTime = expectedTriggerEnd
  else
    stateView.triggerDropTime = nil
  end
  stateView.empowerCount       = empowerCount or 0
  stateView.expectedTriggerEnd = expectedTriggerEnd
  -- The one-shot out-of-combat read of the trigger aura (display only)
  stateView.observedTriggerEnd = observedTriggerEnd
  stateView.provisionalUntil   = provisionalUntil
  stateView.lastFiredTime      = lastFiredTime
  stateView.lastFiredOffset    = lastFiredOffset
  stateView.lastSuppressOffset = lastSuppressOffset
  stateView.lastSuppressReason = lastSuppressReason
  stateView.estLingerRemaining = EstimateLingerRemaining()
  -- Stacks reached so far (frozen once DR predicted-ends), and the stacks
  -- the cycle is heading for when DR ends as predicted right now
  stateView.stacksReached         = ComputeMaxStacksReached()
  stateView.projectedStacksAtDrop = ComputeProjectedStacksAtDrop()
  stateView.pendingDeferReason = pendingDeferReason

  -- TalentGate status: surfaced here so the overlay can render a single
  -- combined view without coupling Overlay → TalentGate directly.
  local gate = ApexFury.GetTalentGate()
  if gate then
    stateView.gateUsable       = gate.usable
    stateView.gateReason       = gate.reason
    stateView.gateDetail       = gate.detail
    stateView.gateRisingFury   = gate.risingFuryRank
    stateView.gateAnimosity    = gate.hasAnimosity   -- nil = not found yet
  else
    -- TalentGate not yet started: assume usable so the overlay shows
    -- normal state during the brief startup window.
    stateView.gateUsable       = true
    stateView.gateReason       = "ready"
    stateView.gateDetail       = "Initializing..."
    stateView.gateRisingFury   = nil
    stateView.gateAnimosity    = nil
  end

  return stateView
end

---------------------------------------------------------------------------
-- Frame + event subscription
--
-- The frame is created at file load, but cycle events (UNIT_SPELLCAST_*,
-- etc.) are only registered while the TalentGate considers the player
-- usable: Devastation Evoker with at least Rising Fury rank 1. On non-Devo
-- specs the watcher is fully dormant, with no per-event work. UNIT_AURA is
-- never registered.
-- See Source/TalentGate/Main.lua for the activation policy.
---------------------------------------------------------------------------
watcherFrame = CreateFrame("Frame")

local function OnEvent(event, ...)
  if event == "UNIT_SPELLCAST_SUCCEEDED" then
    local unit, _, spellID = ...
    local triggerID = Config.Get(Config.Options.SPELL_ID)
    if Config.Get(Config.Options.VERBOSE) then
      local nameOk, name = pcall(function()
        local info = C_Spell.GetSpellInfo(spellID)
        return info and info.name
      end)
      Debug.Log("CAST", "unit=%s id=%s name=%s%s",
        tostring(unit), tostring(spellID),
        (nameOk and type(name) == "string") and name or "?",
        (spellID == triggerID) and " [MATCH]" or "")
    end
    if spellID == triggerID then
      OnTriggerCast()
    elseif EMPOWER_SPELL_IDS[spellID] and castTime then
      -- Conservative counting: a SUCCEEDED is a count signal only when no
      -- channel is in flight for this empower (Tip-the-Scales instant).
      -- For channels, SUCCEEDED is an interim event: the count happens
      -- on STOP complete=true. Cancels (STOP complete=false) never count.
      if inFlightEmpower ~= spellID then
        CountEmpower(spellID)
      end
    end

  elseif event == "UNIT_SPELLCAST_EMPOWER_START" then
    -- A channel is starting. Mark in-flight so the SUCCEEDED that follows
    -- is recognized as part of this channel (and ignored). The flag is
    -- cleared at STOP regardless of complete value. Tip-the-Scales
    -- instants don't fire START: that's exactly the discriminator.
    local _, _, empSpellID = ...
    if EMPOWER_SPELL_IDS[empSpellID] and castTime then
      inFlightEmpower = empSpellID
      if Config.Get(Config.Options.VERBOSE) then
        Debug.Log("WATCHER",
          "EMPOWER_START fired @ +%.2fs: id=%d (%s) channel in flight",
          Now() - castTime, empSpellID, EMPOWER_SPELL_IDS[empSpellID])
      end
    end

  elseif event == "UNIT_SPELLCAST_EMPOWER_STOP" then
    -- args: unitTarget, castGUID, spellID, complete, interruptedBy, castBarID
    --
    -- Channel resolved. complete=true → count now (the empower landed
    -- during active DR: Animosity extends; CountEmpower applies its own
    -- latency-grace check to drop releases that arrived too late).
    -- complete=false → cancelled, no count. The conservative model never
    -- speculatively increments on SUCCEEDED, so cancels have nothing to
    -- retract. Always clear the in-flight flag.
    local _, _, empSpellID, complete = ...
    if not EMPOWER_SPELL_IDS[empSpellID] or not castTime then return end
    Debug.Log("WATCHER",
      "EMPOWER_STOP fired @ +%.2fs: id=%d (%s) complete=%s",
      Now() - castTime, empSpellID, EMPOWER_SPELL_IDS[empSpellID],
      tostring(complete))
    if inFlightEmpower == empSpellID then
      inFlightEmpower = nil
    end
    if complete then
      CountEmpower(empSpellID)
    end

  elseif event == "PLAYER_REGEN_DISABLED" then
    OnEnterCombat()

  elseif event == "UNIT_EXITED_VEHICLE" then
    -- Already filtered to player via RegisterUnitEvent.
    if alertPending then
      Debug.Log("WATCHER", "Vehicle exited: re-evaluating pending alert")
      TryFirePending("vehicle_exit")
    end

  elseif event == "LOSS_OF_CONTROL_UPDATE" then
    -- Stun/fear/silence/etc. just changed. Re-eval if pending.
    if alertPending then
      Debug.Log("WATCHER", "Loss-of-control state changed: re-evaluating pending alert")
      TryFirePending("loc_update")
    end

  elseif event == "PLAYER_MOUNT_DISPLAY_CHANGED" then
    -- Fires on mount/dismount. Re-eval if pending.
    if alertPending then
      Debug.Log("WATCHER", "Mount display changed: re-evaluating pending alert")
      TryFirePending("mount_change")
    end

  elseif event == "PLAYER_DEAD" then
    -- Only suppress (and log) when there's actually an unresolved cycle.
    -- Without this guard, every death after a clean alert resolution
    -- emits a misleading "Suppressing pending alert" line.
    if castTime and not alertFired and not alertSuppressed then
      Debug.Log("WATCHER", "Suppressing pending alert: PLAYER_DEAD")
      alertSuppressed = true
      alertPending = false
      lastSuppressReason = "death"
      lastSuppressOffset = Now() - castTime
      pendingTimer = CancelTimer(pendingTimer)
      pendingPollTimer = CancelTimer(pendingPollTimer)
      ClearProvisional()
    end

  elseif event == "PLAYER_LEAVING_WORLD" then
    if castTime and not alertFired and not alertSuppressed then
      Debug.Log("WATCHER", "Suppressing pending alert: PLAYER_LEAVING_WORLD")
      alertSuppressed = true
      alertPending = false
      lastSuppressReason = "zone"
      lastSuppressOffset = Now() - castTime
      pendingTimer = CancelTimer(pendingTimer)
      pendingPollTimer = CancelTimer(pendingPollTimer)
      ClearProvisional()
    end

  elseif event == "PLAYER_ENTERING_WORLD" then
    ResetState()
  end
end

watcherFrame:SetScript("OnEvent", function(_, event, ...)
  OnEvent(event, ...)
end)

---------------------------------------------------------------------------
-- Activate / Deactivate: called from TalentGate based on usable state.
--
-- Activate registers all cycle events; Deactivate unregisters them and
-- resets state so a stale castTime / pending timer can't leak across a
-- spec swap. Both are idempotent.
---------------------------------------------------------------------------
function Watcher.Activate()
  if active then return end
  watcherFrame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
  watcherFrame:RegisterUnitEvent("UNIT_SPELLCAST_EMPOWER_START", "player")
  watcherFrame:RegisterUnitEvent("UNIT_SPELLCAST_EMPOWER_STOP", "player")
  watcherFrame:RegisterUnitEvent("UNIT_EXITED_VEHICLE", "player")
  watcherFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
  watcherFrame:RegisterEvent("PLAYER_DEAD")
  watcherFrame:RegisterEvent("PLAYER_LEAVING_WORLD")
  watcherFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
  watcherFrame:RegisterEvent("LOSS_OF_CONTROL_UPDATE")
  watcherFrame:RegisterEvent("PLAYER_MOUNT_DISPLAY_CHANGED")
  ResetState()
  active = true
  Debug.Log("WATCHER", "Activated: cycle events registered")
end

function Watcher.Deactivate()
  if not active then return end
  watcherFrame:UnregisterEvent("UNIT_SPELLCAST_SUCCEEDED")
  watcherFrame:UnregisterEvent("UNIT_SPELLCAST_EMPOWER_START")
  watcherFrame:UnregisterEvent("UNIT_SPELLCAST_EMPOWER_STOP")
  watcherFrame:UnregisterEvent("UNIT_EXITED_VEHICLE")
  watcherFrame:UnregisterEvent("PLAYER_REGEN_DISABLED")
  watcherFrame:UnregisterEvent("PLAYER_DEAD")
  watcherFrame:UnregisterEvent("PLAYER_LEAVING_WORLD")
  watcherFrame:UnregisterEvent("PLAYER_ENTERING_WORLD")
  watcherFrame:UnregisterEvent("LOSS_OF_CONTROL_UPDATE")
  watcherFrame:UnregisterEvent("PLAYER_MOUNT_DISPLAY_CHANGED")
  local hadPending = (alertScheduledFor and not alertFired and not alertSuppressed) or alertPending
  ResetState()
  active = false
  Debug.Log("WATCHER", "Deactivated: cycle events unregistered%s",
    hadPending and " (pending alert cancelled)" or "")
end

function Watcher.IsActive()
  return active
end

---------------------------------------------------------------------------
-- Start: called from PLAYER_LOGIN. Only initializes; TalentGate decides
-- when to call Activate.
---------------------------------------------------------------------------
function Watcher.Start()
  Debug.Log("WATCHER", "Started: trigger=%s threshold=%s interval=%ss combat_only=%s min_rem=%ss",
    tostring(Config.Get(Config.Options.SPELL_ID)),
    tostring(Config.Get(Config.Options.THRESHOLD)),
    tostring(Config.Get(Config.Options.STACK_INTERVAL)),
    tostring(Config.Get(Config.Options.COMBAT_ONLY)),
    tostring(Config.Get(Config.Options.MIN_REMAINING)))
end

---------------------------------------------------------------------------
-- Test seams for ApexFury's suites (Source/Tests). The Watcher and Overlay
-- suites drive the state machine on a fake clock and timer queue, with
-- combat, actionability and the aura reader under their control, and the
-- Config suite saves and restores the player's cycle; every setter takes
-- nil to go back to the real game state. Nothing here writes a Blizzard
-- global.
---------------------------------------------------------------------------
Watcher._test = {
  Reset                        = ResetState,
  OnTriggerCast                = OnTriggerCast,
  CountEmpower                 = CountEmpower,
  EstimateLingerRemaining      = EstimateLingerRemaining,
  ComputeMaxStacksReached      = ComputeMaxStacksReached,
  ComputeProjectedStacksAtDrop = ComputeProjectedStacksAtDrop,
  HandleEvent                  = OnEvent,

  -- fn() returning the time, or nil for GetTime
  SetClock = function(fn) testClock = fn end,
  -- { After, NewTimer, NewTicker } with C_Timer's signatures, or nil
  SetTimers = function(timers) testTimers = timers end,
  -- true / false, or nil for UnitAffectingCombat
  SetCombat = function(inCombat) testCombat = inCombat end,
  -- canAct true / false with an optional reason, or nil for the real checks
  SetActionability = function(canAct, reason)
    if canAct == nil then
      testActionability = nil
    else
      testActionability = { canAct = canAct, reason = reason }
    end
  end,
  -- fn(spellID) returning aura data, or nil for C_UnitAuras
  SetAuraReader = function(fn) testAuraReader = fn end,
  -- Trigger aura reads attempted since load (the one-shot read is the only one)
  GetAuraReadCount = function() return auraReads end,
  IsEventRegistered = function(event) return watcherFrame:IsEventRegistered(event) end,

  -- The cycle's outcome and the last alert time, to put back with Restore
  -- after a suite. Timer handles are not kept: the suites run only while no
  -- cycle is waiting on one (Setup.lua's watcher_idle prerequisite).
  Save = function()
    return {
      castTime = castTime, alertScheduledFor = alertScheduledFor,
      observedTriggerEnd = observedTriggerEnd, empowerCount = empowerCount,
      expectedTriggerEnd = expectedTriggerEnd, alertFired = alertFired,
      alertSuppressed = alertSuppressed, lastFiredTime = lastFiredTime,
      lastFiredOffset = lastFiredOffset, lastSuppressOffset = lastSuppressOffset,
      lastSuppressReason = lastSuppressReason,
    }
  end,
  Restore = function(saved)
    ResetState()
    castTime = saved.castTime
    alertScheduledFor = saved.alertScheduledFor
    observedTriggerEnd = saved.observedTriggerEnd
    empowerCount = saved.empowerCount or 0
    expectedTriggerEnd = saved.expectedTriggerEnd
    alertFired = saved.alertFired or false
    alertSuppressed = saved.alertSuppressed or false
    lastFiredTime = saved.lastFiredTime
    lastFiredOffset = saved.lastFiredOffset
    lastSuppressOffset = saved.lastSuppressOffset
    lastSuppressReason = saved.lastSuppressReason
  end,
}
