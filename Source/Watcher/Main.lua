-------------------------------------------------------------------------------
-- ApexFury — Stack alert via cast-driven predictive timing
--
-- Background:
--   In Midnight 12.0, Rising Fury is flagged as a "private aura" — the
--   `applications`, `expirationTime`, `spellId`, and `name` fields all
--   return secret values during combat. We cannot read stack count or
--   identify the aura while the player is in combat.
--
--   We previously tried to identify the Rising Fury aura instance among
--   the auras the engine adds within ~1s of Dragonrage cast and observe
--   its drop time. That approach was unworkable: every other aura the
--   player happens to gain in that window — Augmentation Evoker buffs
--   (Prescience, Ebon Might), healer HoTs (Renewing Mist, Atonement),
--   the player's own combat potion buff, trinket procs, hero-talent
--   procs (Light's Potential), Tip the Scales, etc. — also lands in the
--   captured set with secret-value spellIds, and any of them can win
--   the fallback heuristic. We had a blacklist that grew without bound
--   and still couldn't cover every group composition or potion variant.
--
-- Design — predictive only:
--   1. Watch UNIT_SPELLCAST_SUCCEEDED for the configured TRIGGER spell.
--      Cast events are NOT subject to the private-aura system; spell IDs
--      and unit tokens are always public.
--   2. Schedule the alert at +(threshold - 1) * interval seconds.
--   3. Track empower casts via the EMPOWER_START → EMPOWER_STOP channel
--      lifecycle. EMPOWER_START sets an in-flight flag; the SUCCEEDED that
--      follows is recognized as part of the channel and ignored. STOP
--      complete=true counts the empower (channel landed during active DR —
--      Animosity extends per the formula +5s × 0.75^N) and clears the flag.
--      STOP complete=false just clears the flag (cancel — no extension,
--      not counted). Tip-the-Scales instants fire neither START nor STOP,
--      so their SUCCEEDED arrives with the flag clear and is the count
--      signal in that path. Cancels never count because the model never
--      speculatively increments on SUCCEEDED for channels — so there's
--      no retract logic.
--   4. Compute `expectedTriggerEnd = castTime + 18 + Σ 5 × 0.75^i` where
--      i ranges over empowers cast so far. This is empirically accurate
--      to ±0.05s on real-pull cycles. It's the source of truth for "when
--      does Dragonrage end" — we never observe the actual aura drop in
--      combat, but the deterministic Animosity formula matches reality.
--   5. At alert fire time:
--      - If combat_only and player not in combat → defer.
--      - If actionability_gate and player can't act (vehicle / mount /
--        CC / possession) → defer with reason.
--      - Otherwise fire sound (subject to predicted-duration and linger
--        gates inside FireAlert).
--   6. On combat re-entry / vehicle exit / CC end / mount change with a
--      pending alert, re-evaluate. The linger gate uses the predictive
--      end as the "drop time" — once `now > expectedTriggerEnd`, we're in
--      the Risen Fury linger phase, expiring at
--        expectedTriggerEnd + min(linger_max, stacks × linger_per_stack)
--      where stacks is computed by clamping elapsed to expectedTriggerEnd.
--
-- What we do NOT track:
--   - Aura identification (spellId or name match). All field reads are
--     secret values in combat for the auras we'd want to identify, so
--     this never produces useful data — confirmed across 3855 lines of
--     real-pull log with zero successful positive matches.
--   - Trigger drop observation. We don't know when Rising Fury actually
--     ends; the predictive Animosity model is our authority instead. Edge
--     cases where the user manually cancels Rising Fury or some unknown
--     mechanic ends DR early aren't caught — but they weren't caught
--     before either (we'd have observed the wrong aura). PLAYER_DEAD and
--     PLAYER_LEAVING_WORLD remain handled.
--
-- For the overlay's out-of-combat trigger-remaining display, we still
-- bookkeep a `capturedAuraIDs` set so the overlay can iterate it and
-- query `C_UnitAuras.GetAuraDataByAuraInstanceID` for whichever aura has
-- the longest remaining time. That's purely cosmetic — no in-combat
-- decisions read it.
-------------------------------------------------------------------------------

local Watcher = ApexFury.Watcher
local Config = ApexFury.Config
local Debug = ApexFury.Debug

-- Internal state ----------------------------------------------------------
local castTime              -- when trigger spell last cast (or nil)
local alertScheduledFor     -- absolute time the timer is set to elapse
local capturedAuraIDs       -- set: { [auraInstanceID] = true } — bookkeeping
                            -- for the overlay's OOC trigger-remaining read;
                            -- never used to identify Rising Fury.
local empowerCount          -- empower casts observed since trigger cast
local inFlightEmpower       -- spellID of an empower channel with EMPOWER_START
                            -- seen but no STOP yet (nil = no channel in flight).
                            -- Lets the SUCCEEDED handler distinguish "this is
                            -- a TtS instant, count now" from "this is part of
                            -- a channel, defer to STOP".
local expectedTriggerEnd    -- predicted absolute time the trigger buff will
                            -- end. Drives every in-combat timing decision.
local alertFired            -- bool: sound has been played
local alertPending          -- bool: timer elapsed but waiting for combat
local alertSuppressed       -- bool: alert was cancelled
local lastFiredTime         -- last time alert actually played sound
local lastFiredOffset       -- precise elapsed seconds from cast to fire
local lastSuppressOffset    -- precise elapsed seconds from cast to suppression
local lastSuppressReason    -- "linger_expired" / "rf_too_short" / "trigger_too_short" / "rf_expired" / "disabled" / "death" / "zone" / nil
local pendingTimer          -- C_Timer ticker handle (or nil)
local pendingDeferReason    -- "ooc" / "vehicle" / "vehicle_ui" / "mounted" / "possessed" / "loss_of_control"
local pendingPollTimer      -- C_Timer.NewTicker handle while alertPending; resolves the deferral
local watcherFrame
local active = false        -- cycle events registered? (TalentGate-controlled)

local CAPTURE_WINDOW = 1.0  -- seconds after cast to capture newly-added auras

-- Threshold safety buffer: built-in constant. For threshold N at interval I,
-- we need the trigger buff to actually run for at least (N-1)*I + buffer
-- seconds — otherwise the Nth stack tick races the buff's expiration and
-- loses (e.g. unextended Dragonrage at exactly 18s yields 3 stacks of
-- Rising Fury, not 4). 0.1s puts us firmly past the boundary.
local THRESHOLD_BUFFER = 0.1

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
-- in flight (Tip-the-Scales instant — fires neither START nor STOP).
-- Cancels (STOP with complete=false) never count — the conservative
-- model defers all counting until the channel resolves successfully,
-- so there's nothing to undo on cancel.
--
-- Both base AND Font-of-Magic variants must be listed. Font of Magic is a
-- Devastation talent (spell 411212) that overrides the action-bar spell IDs
-- via SPELL_AURA_OVERRIDE_ACTIONBAR_SPELL — the cast event then fires with
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

-- Exposed for the Overlay's verdict-line preview, which must mirror this
-- module's CheckTriggerRanLongEnough / PredictedTriggerEnd math. Keeping
-- the constants on the public module means a single edit here propagates
-- to the overlay without cross-file drift.
Watcher.THRESHOLD_BUFFER = THRESHOLD_BUFFER
Watcher.DR_BASE_DURATION = DR_BASE_DURATION

---------------------------------------------------------------------------
-- Tiny helper: cancel a C_Timer handle if non-nil, return nil for the
-- assign-back idiom. Usage: `pendingTimer = CancelTimer(pendingTimer)`.
---------------------------------------------------------------------------
local function CancelTimer(t)
  if t then t:Cancel() end
  return nil
end

---------------------------------------------------------------------------
-- Reset state
---------------------------------------------------------------------------
local function ResetState()
  castTime = nil
  alertScheduledFor = nil
  capturedAuraIDs = {}
  empowerCount = 0
  inFlightEmpower = nil
  expectedTriggerEnd = nil
  alertFired = false
  alertPending = false
  alertSuppressed = false
  lastSuppressReason = nil
  -- Per-cycle outcome offsets — reset so the next cycle's overlay
  -- "Fired after" line doesn't show stale data from the previous cycle.
  -- lastFiredTime is intentionally preserved across cycles for the
  -- separate "Last alert: Xs ago" display.
  lastFiredOffset = nil
  lastSuppressOffset = nil
  pendingTimer = CancelTimer(pendingTimer)
  pendingPollTimer = CancelTimer(pendingPollTimer)
  pendingDeferReason = nil
end

---------------------------------------------------------------------------
-- Compute the expected trigger buff end time based on empower casts so far.
-- Animosity formula: +5s per empower with 25% diminishing returns per cast.
--
-- Without Animosity, empowers don't extend Dragonrage at all — predicted
-- end stays at the 18s base. We consult TalentGate's `hasAnimosity` flag
-- to know which formula applies. TalentGate is started before the watcher
-- activates the trigger cycle in normal startup order, but defaults to
-- "with Animosity" if the gate isn't ready yet (the gate's own warning
-- chat message is the user's signal that threshold ≥4 won't fire).
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
-- The "predicted DR end" used everywhere downstream. Always returns a
-- valid number when castTime is set — falls back to base 18s if the
-- empower formula hasn't produced a value yet (shouldn't happen since
-- OnTriggerCast sets expectedTriggerEnd at cast time, but defend anyway).
---------------------------------------------------------------------------
local function PredictedTriggerEnd()
  if not castTime then return nil end
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

  local now = GetTime()
  local effectiveEnd = math.min(now, PredictedTriggerEnd())
  local elapsed = effectiveEnd - castTime - 0.05  -- boundary tick epsilon
  if elapsed < 0 then return 1 end

  return math.min(maxStacks, 1 + math.floor(elapsed / interval))
end

---------------------------------------------------------------------------
-- Will the trigger buff run long enough for the threshold-th stack tick to
-- definitively fire? Uses the predictive Animosity model — the only signal
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
-- Compute estimated linger remaining (seconds). Returns:
--   math.huge when DR is still predicted to be active (linger not started)
--   number when in linger window
--   0 when linger has fully expired
---------------------------------------------------------------------------
local function EstimateLingerRemaining()
  if not castTime then return 0 end
  local now = GetTime()
  local predictedEnd = PredictedTriggerEnd()
  if now < predictedEnd then return math.huge end

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
  local now = GetTime()
  if now < PredictedTriggerEnd() then return true end
  return EstimateLingerRemaining() > 0
end

---------------------------------------------------------------------------
-- Fire the alert (sound). Verifies the trigger context still holds and
-- that linger remaining meets the configured minimum.
---------------------------------------------------------------------------
local function FireAlert(reasonContext)
  if alertFired or alertSuppressed then return end

  -- Reaching FireAlert means this attempt resolves the cycle one way
  -- or another (fire OR suppress). Clear alertPending up front so the
  -- overlay's "PENDING — waiting for combat" status doesn't get stuck
  -- on after a suppress branch returns.
  alertPending = false

  if not Config.Get(Config.Options.ENABLED) then
    alertSuppressed = true
    lastSuppressReason = "disabled"
    if castTime then lastSuppressOffset = GetTime() - castTime end
    return
  end

  -- One-line dump of every gate input at the exact moment FireAlert was
  -- entered, BEFORE any gate runs. Useful for verifying deferred-alert
  -- resolution paths (TryFirePending → FireAlert) where the user wants
  -- to see whether the model thought DR was still active or in linger.
  if Config.Get(Config.Options.VERBOSE) then
    local _, actualDur, requiredDur = CheckTriggerRanLongEnough()
    local lingerRem = EstimateLingerRemaining()
    local elapsed = castTime and (GetTime() - castTime) or 0
    Debug.Log("WATCHER",
      "FireAlert(%s) @ +%.2fs — predDR=%.2fs req=%.2fs linger=%s empowers=%d",
      reasonContext, elapsed,
      actualDur or 0, requiredDur or 0,
      lingerRem == math.huge and "active" or string.format("%.2fs", lingerRem),
      empowerCount or 0)
  end

  -- RF / Risen Fury still presumed alive per the predictive linger model?
  -- (We never observe the actual drop in combat — Rising Fury's fields are
  -- secret values during combat — so the Animosity-extended predicted end
  -- is the source of truth. After predicted end, linger ticks down toward
  -- linger_max.)
  if not PresumablyHasStacks() then
    alertSuppressed = true
    lastSuppressReason = "linger_expired"
    if castTime then lastSuppressOffset = GetTime() - castTime end
    local predDur = (expectedTriggerEnd and castTime)
                    and (expectedTriggerEnd - castTime) or 0
    Debug.Log("WATCHER",
      "Alert suppressed @ %s — RF/Risen Fury linger expired (predDR=%.2fs, stacksAtDrop=%d, empowers=%d)",
      reasonContext, predDur, ComputeMaxStacksReached(), empowerCount or 0)
    return
  end

  -- Did the trigger buff run long enough to actually deliver the threshold
  -- stack? Linger auras can still be alive even when the threshold tick was
  -- lost to the trigger-end race (e.g. unextended DR at 18s yields 3 stacks
  -- of Rising Fury, not 4). Driven by the predictive Animosity model.
  local longEnough, actualDur, requiredDur = CheckTriggerRanLongEnough()
  if not longEnough then
    alertSuppressed = true
    lastSuppressReason = "trigger_too_short"
    if castTime then lastSuppressOffset = GetTime() - castTime end
    Debug.Log("WATCHER", "Alert suppressed @ %s — trigger duration %.2fs < required %.2fs (empowers=%d)",
      reasonContext, actualDur, requiredDur, empowerCount)
    return
  end

  -- Linger-remaining gate (only relevant after predicted DR end)
  local minRemaining = Config.Get(Config.Options.MIN_REMAINING) or 0
  local lingerRem = EstimateLingerRemaining()
  if lingerRem ~= math.huge and lingerRem < minRemaining then
    alertSuppressed = true
    lastSuppressReason = "rf_too_short"
    if castTime then lastSuppressOffset = GetTime() - castTime end
    Debug.Log("WATCHER", "Alert suppressed @ %s — linger %.2fs < min %.2fs",
      reasonContext, lingerRem, minRemaining)
    return
  end

  alertFired = true
  alertPending = false

  -- WoW's sound mixer can reject PlaySound/PlaySoundFile dispatches under
  -- heavy combat (channel saturation). On failure, surface it to the log
  -- and retry once after a short delay — by the next frame the mixer has
  -- typically freed a slot. Without this, an alert can silently go out
  -- while the overlay reports "fired".
  local soundValue   = Config.Get(Config.Options.SOUND_ID)
  local soundChannel = Config.Get(Config.Options.SOUND_CHANNEL)
  local handle, willPlay = ApexFury.Sound.Play(soundValue, soundChannel)
  if not (willPlay and handle) then
    Debug.Warn("WATCHER",
      "Sound dispatch returned willPlay=%s handle=%s — retrying in 50ms (mixer likely saturated)",
      tostring(willPlay), tostring(handle))
    C_Timer.After(0.05, function()
      local h2, wp2 = ApexFury.Sound.Play(soundValue, soundChannel)
      if wp2 and h2 then
        Debug.Log("WATCHER", "Sound retry succeeded")
      else
        Debug.Warn("WATCHER",
          "Sound retry also failed (willPlay=%s handle=%s) — alert was inaudible",
          tostring(wp2), tostring(h2))
      end
    end)
  end

  lastFiredTime = GetTime()
  if castTime then lastFiredOffset = lastFiredTime - castTime end

  -- Cycle resolution summary. One always-on line that captures every
  -- relevant number from the cycle so post-pull review can verify each
  -- decision without verbose mode. Suppress branches above also include
  -- their own structured summaries.
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

---------------------------------------------------------------------------
-- Actionability check — can the player meaningfully act on an alert RIGHT
-- NOW? Used by the timer-expiry path to defer alerts when the player is
-- in a vehicle, mounted (incl. skyriding combat mounts on bosses like
-- Dimensius P2 / Amirdrassil flying phase), possessed by a boss
-- mind-control mechanic, or affected by stuns/fear/silences/etc.
--
-- Returns (canAct, reason). reason is one of:
--   "vehicle" / "vehicle_ui" / "mounted" / "possessed" / "loss_of_control"
-- or nil when canAct=true.
---------------------------------------------------------------------------
local function CheckActionability()
  if UnitInVehicle("player") then return false, "vehicle" end
  if UnitHasVehicleUI("player") then return false, "vehicle_ui" end
  if IsMounted() then return false, "mounted" end

  local possessOk, possessed = pcall(UnitIsPossessed, "player")
  if possessOk and possessed then return false, "possessed" end

  -- C_LossOfControl exposes active CC effects (stun/fear/charm/disorient/
  -- incapacitate/silence/root). Wrap in pcall — older clients or some
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
-- cleanup only fires for THIS cycle — if the user casts again before
-- 45s elapses, ResetState will have nilled or replaced castTime and
-- we don't want to clobber the new cycle's pending state.
--
-- Worst-case linger end is castTime + max DR (with 4 empowers ≈ 31.67s)
-- + LINGER_MAX (default 20s) ≈ 52s after cast. Timer is already at +18s;
-- 45s from now safely covers the rest.
---------------------------------------------------------------------------
local function ScheduleStalePendingCleanup()
  local snapshotCastTime = castTime
  C_Timer.After(45, function()
    if castTime ~= snapshotCastTime then return end
    if alertPending and not alertFired and not alertSuppressed then
      alertPending = false
      alertSuppressed = true
      lastSuppressReason = "rf_expired"
      if castTime then lastSuppressOffset = GetTime() - castTime end
      pendingPollTimer = CancelTimer(pendingPollTimer)
      Debug.Log("WATCHER", "Pending alert cleared — linger expired without recovery (last reason: %s)",
        tostring(pendingDeferReason or "?"))
      pendingDeferReason = nil
    end
  end)
end

---------------------------------------------------------------------------
-- TryFirePending — unified resolution path for deferred alerts. Re-checks
-- BOTH gates (combat-only and actionability) and fires only when both
-- pass. Called from PLAYER_REGEN_DISABLED (existing OOC path) and from the
-- new actionability event handlers + polling fallback. FireAlert itself
-- still gates on linger remaining and trigger duration, so a recovery
-- past the linger window suppresses cleanly instead of firing late.
---------------------------------------------------------------------------
local function TryFirePending(reasonContext)
  if not (alertPending and not alertFired and not alertSuppressed) then return end

  if Config.Get(Config.Options.COMBAT_ONLY) and not UnitAffectingCombat("player") then
    return  -- still OOC, keep pending
  end

  if Config.Get(Config.Options.ACTIONABILITY_GATE) then
    local canAct, reason = CheckActionability()
    if not canAct then
      -- Update the displayed reason so overlay reflects the *current*
      -- blocker (e.g. exited vehicle into a stun).
      if reason ~= pendingDeferReason then
        Debug.Log("WATCHER", "Pending defer reason updated: %s -> %s",
          tostring(pendingDeferReason), tostring(reason))
        pendingDeferReason = reason
      end
      return
    end
  end

  -- Both gates pass — fire. FireAlert may still suppress on linger gate.
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

  -- Polling fallback — 0.5s ticker that re-evaluates gates. Cancels
  -- itself when alert fires, suppresses, or castTime changes (cycle
  -- replaced). Caps the implicit per-tick work at ~1 function call.
  pendingPollTimer = CancelTimer(pendingPollTimer)
  local snapshotCastTime = castTime
  pendingPollTimer = C_Timer.NewTicker(0.5, function()
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
-- Timer callback — alert moment arrived. Either fire or defer (via the
-- combat-only gate or the actionability gate, depending on user config).
---------------------------------------------------------------------------
local function OnAlertTimerExpired()
  if alertFired or alertSuppressed then return end

  -- Snapshot the predictive state at the exact moment the timer fires.
  -- This is the line that lets you verify, post-pull, "what did the model
  -- think when the alert was supposed to land?" — independent of which
  -- branch (defer / fire / suppress) the cycle takes after this point.
  if Config.Get(Config.Options.VERBOSE) then
    local elapsed = castTime and (GetTime() - castTime) or 0
    local predDur = (expectedTriggerEnd and castTime)
                    and (expectedTriggerEnd - castTime) or 0
    Debug.Log("WATCHER",
      "Alert timer expired @ +%.2fs — predDR=%.2fs empowers=%d combat=%s",
      elapsed, predDur, empowerCount or 0,
      tostring(UnitAffectingCombat("player")))
  end

  if Config.Get(Config.Options.COMBAT_ONLY) and not UnitAffectingCombat("player") then
    return DeferAlert("ooc")
  end

  if Config.Get(Config.Options.ACTIONABILITY_GATE) then
    local canAct, reason = CheckActionability()
    if not canAct then
      return DeferAlert(reason)
    end
  end

  FireAlert("timer")
end

---------------------------------------------------------------------------
-- Increment empower count and recompute the predicted DR end. Called from
-- two paths in the OnEvent handler:
--   1. UNIT_SPELLCAST_EMPOWER_STOP with complete=true (channeled release).
--   2. UNIT_SPELLCAST_SUCCEEDED for an empower spell when no channel is in
--      flight (Tip-the-Scales instant — START/STOP don't fire for these).
--
-- Only counts empowers cast while DR is predicted to still be active (plus
-- EMPOWER_LATENCY_GRACE for client-side event arrival lag). Empowers cast
-- after the predicted end don't extend an inactive DR — Animosity only
-- extends an ACTIVE DR — so they shouldn't inflate the model. Without aura
-- observation the predictive end is our best signal for "DR is still up."
---------------------------------------------------------------------------
local function CountEmpower(spellID)
  local predictedEnd = expectedTriggerEnd or (castTime + DR_BASE_DURATION)
  local now = GetTime()
  if now <= predictedEnd + EMPOWER_LATENCY_GRACE then
    local oldEnd = expectedTriggerEnd
    empowerCount = (empowerCount or 0) + 1
    expectedTriggerEnd = ComputeExpectedTriggerEnd()
    -- Show the per-empower extension delta. With Animosity, this is
    -- 5×0.75^(N-1) for the Nth empower. Without Animosity, the delta
    -- is 0.00s — making it visibly clear in the log that the empower
    -- registered but didn't extend DR (the talent gate suppressed the
    -- formula). This is the cleanest way to verify Animosity detection
    -- end-to-end at cycle time.
    local delta = expectedTriggerEnd - (oldEnd or expectedTriggerEnd)
    local lateBy = now - predictedEnd
    if lateBy > 0 and Config.Get(Config.Options.VERBOSE) then
      Debug.Log("WATCHER",
        "Empower #%d (%s, id=%d) — counted within %.2fs grace (%.2fs past predicted end). DR predicted to last %.2fs total (+%.2fs from this empower)",
        empowerCount, EMPOWER_SPELL_IDS[spellID], spellID,
        EMPOWER_LATENCY_GRACE, lateBy,
        expectedTriggerEnd - castTime, delta)
    else
      Debug.Log("WATCHER",
        "Empower #%d (%s, id=%d) — DR predicted to last %.2fs total (+%.2fs from this empower)",
        empowerCount, EMPOWER_SPELL_IDS[spellID], spellID,
        expectedTriggerEnd - castTime, delta)
    end
  elseif Config.Get(Config.Options.VERBOSE) then
    Debug.Log("WATCHER",
      "Empower id=%d cast %.2fs after predicted DR end — not counted (beyond %.2fs grace)",
      spellID, now - predictedEnd, EMPOWER_LATENCY_GRACE)
  end
end

---------------------------------------------------------------------------
-- Trigger spell was cast — start a new tracking cycle
---------------------------------------------------------------------------
local function OnTriggerCast()
  if not Config.Get(Config.Options.ENABLED) then return end

  ResetState()
  castTime = GetTime()
  expectedTriggerEnd = ComputeExpectedTriggerEnd()

  local threshold = Config.Get(Config.Options.THRESHOLD)
  local interval = Config.Get(Config.Options.STACK_INTERVAL)
  -- Fire at the exact stack-tick moment; the 0.1s safety buffer lives
  -- inside CheckTriggerRanLongEnough as a duration requirement.
  local delay = math.max(0, (threshold - 1) * interval)
  alertScheduledFor = castTime + delay

  -- Surface the TalentGate input that drove ComputeExpectedTriggerEnd's
  -- choice of formula. If hasAnimosity is unexpectedly false at cast time
  -- (e.g. TalentGate hasn't finished initial evaluation, or read failure),
  -- threshold ≥4 alerts will deterministically suppress as trigger_too_short
  -- and this is the line that explains why.
  local gate = ApexFury.GetTalentGate()
  local predDur = expectedTriggerEnd and (expectedTriggerEnd - castTime) or 0
  Debug.Log("WATCHER",
    "Trigger cast — timer at +%.2fs (suppress unless DR >= %.2fs, hasAnimosity=%s, base predDR=%.2fs)",
    delay, delay + THRESHOLD_BUFFER,
    tostring(gate and gate.hasAnimosity), predDur)

  pendingTimer = C_Timer.NewTimer(delay, OnAlertTimerExpired)

  -- All timing decisions downstream consult `expectedTriggerEnd`, which
  -- is updated by each counted empower (EMPOWER_STOP complete=true for
  -- channels, or SUCCEEDED for Tip-the-Scales instants). We never observe
  -- the actual Rising Fury aura drop — its fields are secret values in
  -- combat — and don't try to.
end

---------------------------------------------------------------------------
-- UNIT_AURA handler.
--
-- We do NOT identify Rising Fury here. The aura's spellId, name,
-- expirationTime, and applications fields are all secret values during
-- combat (private aura system), and even when the engine occasionally
-- puts them at addedAuras[1] without other auras around, the captured
-- set always also contains group buffs (Prescience, Ebon Might, HoTs from
-- healers), the player's potion buff, hero-talent procs, and Tip the
-- Scales — any of which can collide with the heuristic. Real-pull logs
-- show positive spellId/name matching never succeeded across thousands
-- of UNIT_AURA events in combat, so the entire identification path was
-- doing nothing useful and the fallback heuristic was producing the
-- wrong answer. The predictive Animosity model is now the single source
-- of truth for trigger duration; this handler just bookkeeps the
-- captured set so the overlay's out-of-combat trigger-remaining display
-- can iterate it and pick the longest-remaining aura.
---------------------------------------------------------------------------
local function HandleAuraUpdate(info)
  if not castTime then return end
  if not info then return end

  local now = GetTime()
  local sinceCast = now - castTime
  local verbose = Config.Get(Config.Options.VERBOSE)

  -- Add phase: track new aura instance IDs within the capture window.
  -- No identification, no scoring — this set is purely a list of
  -- observable aura instances on the player at cast time, used by the
  -- overlay's OOC trigger-remaining read.
  if sinceCast < CAPTURE_WINDOW and info.addedAuras then
    for idx, aura in ipairs(info.addedAuras) do
      local idOk, id = pcall(function() return aura.auraInstanceID end)
      if idOk and type(id) == "number" and not capturedAuraIDs[id] then
        capturedAuraIDs[id] = true
        if verbose then
          -- Read spellId for the diagnostic line only (secret-gated; never
          -- acted on). Format kept stable for cross-version log comparability.
          local sIDOk, sID = pcall(function()
            local s = aura.spellId
            if type(s) ~= "number" then return nil end
            if issecretvalue and issecretvalue(s) then return nil end
            return s
          end)
          local readableSID = sIDOk and type(sID) == "number" and sID or nil
          Debug.Log("CAPTURE", "  +%.3fs add[%d] instance=%d sID=%s",
            sinceCast, idx, id, tostring(readableSID))
        end
      end
    end
  end

  -- Remove phase: drop tracking. removedAuraInstanceIDs is a plain
  -- numeric array, always safe to read. We don't care which aura
  -- dropped — the predictive model decides when DR ended.
  if info.removedAuraInstanceIDs then
    for _, id in ipairs(info.removedAuraInstanceIDs) do
      if capturedAuraIDs[id] then
        capturedAuraIDs[id] = nil
        if verbose then
          Debug.Log("CAPTURE", "  +%.3fs drop instance=%d", sinceCast, id)
        end
      end
    end
  end
end

---------------------------------------------------------------------------
-- Combat boundary handlers
---------------------------------------------------------------------------
local function OnEnterCombat()
  if alertPending and not alertFired and not alertSuppressed then
    Debug.Log("WATCHER", "Combat entered — re-evaluating pending alert (current defer: %s)",
      tostring(pendingDeferReason or "?"))
    TryFirePending("combat_entry")
  end
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------
-- Config keys that, when changed, require the watcher to re-evaluate
-- its tracking state. Sound/UI options have no effect on the state
-- machine — ignoring them avoids resetting mid-cast and drops a flood
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

-- Reused by GetState — Overlay polls every 100ms, so we avoid the
-- ~20-field table allocation per call.
local stateView = {}

function Watcher.GetState()
  stateView.castTime           = castTime
  stateView.alertScheduledFor  = alertScheduledFor
  stateView.alertFired         = alertFired
  stateView.alertPending       = alertPending
  stateView.alertSuppressed    = alertSuppressed
  -- triggerDropTime: derived from the predictive Animosity model. Reads
  -- as nil while Dragonrage is predicted to still be active, and as the
  -- predicted end timestamp once `now` has passed it. The overlay treats
  -- non-nil triggerDropTime as "linger phase started," which lines up
  -- with the new predicted-only design (we never observe a real drop in
  -- combat — Rising Fury's fields are secret values).
  local now = GetTime()
  if castTime and expectedTriggerEnd and now >= expectedTriggerEnd then
    stateView.triggerDropTime = expectedTriggerEnd
  else
    stateView.triggerDropTime = nil
  end
  stateView.empowerCount       = empowerCount or 0
  stateView.expectedTriggerEnd = expectedTriggerEnd
  stateView.capturedIDs        = capturedAuraIDs
  stateView.lastFiredTime      = lastFiredTime
  stateView.lastFiredOffset    = lastFiredOffset
  stateView.lastSuppressOffset = lastSuppressOffset
  stateView.lastSuppressReason = lastSuppressReason
  stateView.estLingerRemaining = EstimateLingerRemaining()
  stateView.stacksAtDrop       = ComputeMaxStacksReached()
  stateView.pendingDeferReason = pendingDeferReason

  -- TalentGate status — surfaced here so the overlay can render a single
  -- combined view without coupling Overlay → TalentGate directly.
  local gate = ApexFury.GetTalentGate()
  if gate then
    stateView.gateUsable       = gate.usable
    stateView.gateReason       = gate.reason
    stateView.gateDetail       = gate.detail
    stateView.gateRisingFury   = gate.risingFuryRank
  else
    -- TalentGate not yet started — assume usable so the overlay shows
    -- normal state during the brief startup window.
    stateView.gateUsable       = true
    stateView.gateReason       = "ready"
    stateView.gateDetail       = "Initializing..."
    stateView.gateRisingFury   = nil
  end

  return stateView
end

---------------------------------------------------------------------------
-- Frame + event subscription
--
-- The frame is created at file load, but cycle events (UNIT_AURA, etc.) are
-- only registered while the TalentGate considers the player usable —
-- Devastation Evoker with at least Rising Fury rank 1. On non-Devo specs
-- the watcher is fully dormant: zero UNIT_AURA traffic, no per-event work.
-- See Source/TalentGate/Main.lua for the activation policy.
---------------------------------------------------------------------------
watcherFrame = CreateFrame("Frame")

watcherFrame:SetScript("OnEvent", function(_, event, ...)
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
      -- For channels, SUCCEEDED is an interim event — the count happens
      -- on STOP complete=true. Cancels (STOP complete=false) never count.
      if inFlightEmpower ~= spellID then
        CountEmpower(spellID)
      end
    end

  elseif event == "UNIT_SPELLCAST_EMPOWER_START" then
    -- A channel is starting. Mark in-flight so the SUCCEEDED that follows
    -- is recognized as part of this channel (and ignored). The flag is
    -- cleared at STOP regardless of complete value. Tip-the-Scales
    -- instants don't fire START — that's exactly the discriminator.
    local _, _, empSpellID = ...
    if EMPOWER_SPELL_IDS[empSpellID] and castTime then
      inFlightEmpower = empSpellID
      if Config.Get(Config.Options.VERBOSE) then
        Debug.Log("WATCHER",
          "EMPOWER_START fired @ +%.2fs — id=%d (%s) channel in flight",
          GetTime() - castTime, empSpellID, EMPOWER_SPELL_IDS[empSpellID])
      end
    end

  elseif event == "UNIT_SPELLCAST_EMPOWER_STOP" then
    -- args: unitTarget, castGUID, spellID, complete, interruptedBy, castBarID
    --
    -- Channel resolved. complete=true → count now (the empower landed
    -- during active DR — Animosity extends; CountEmpower applies its own
    -- latency-grace check to drop releases that arrived too late).
    -- complete=false → cancelled, no count. The conservative model never
    -- speculatively increments on SUCCEEDED, so cancels have nothing to
    -- retract. Always clear the in-flight flag.
    local _, _, empSpellID, complete = ...
    if not EMPOWER_SPELL_IDS[empSpellID] or not castTime then return end
    Debug.Log("WATCHER",
      "EMPOWER_STOP fired @ +%.2fs — id=%d (%s) complete=%s",
      GetTime() - castTime, empSpellID, EMPOWER_SPELL_IDS[empSpellID],
      tostring(complete))
    if inFlightEmpower == empSpellID then
      inFlightEmpower = nil
    end
    if complete then
      CountEmpower(empSpellID)
    end

  elseif event == "UNIT_AURA" then
    local _, info = ...
    HandleAuraUpdate(info)

  elseif event == "PLAYER_REGEN_DISABLED" then
    OnEnterCombat()

  elseif event == "UNIT_EXITED_VEHICLE" then
    -- Already filtered to player via RegisterUnitEvent.
    if alertPending then
      Debug.Log("WATCHER", "Vehicle exited — re-evaluating pending alert")
      TryFirePending("vehicle_exit")
    end

  elseif event == "LOSS_OF_CONTROL_UPDATE" then
    -- Stun/fear/silence/etc. just changed. Re-eval if pending.
    if alertPending then
      Debug.Log("WATCHER", "Loss-of-control state changed — re-evaluating pending alert")
      TryFirePending("loc_update")
    end

  elseif event == "PLAYER_MOUNT_DISPLAY_CHANGED" then
    -- Fires on mount/dismount. Re-eval if pending.
    if alertPending then
      Debug.Log("WATCHER", "Mount display changed — re-evaluating pending alert")
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
      lastSuppressOffset = GetTime() - castTime
      pendingTimer = CancelTimer(pendingTimer)
      pendingPollTimer = CancelTimer(pendingPollTimer)
    end

  elseif event == "PLAYER_LEAVING_WORLD" then
    if castTime and not alertFired and not alertSuppressed then
      Debug.Log("WATCHER", "Suppressing pending alert: PLAYER_LEAVING_WORLD")
      alertSuppressed = true
      alertPending = false
      lastSuppressReason = "zone"
      lastSuppressOffset = GetTime() - castTime
      pendingTimer = CancelTimer(pendingTimer)
      pendingPollTimer = CancelTimer(pendingPollTimer)
    end

  elseif event == "PLAYER_ENTERING_WORLD" then
    ResetState()
  end
end)

---------------------------------------------------------------------------
-- Activate / Deactivate — called from TalentGate based on usable state.
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
  watcherFrame:RegisterUnitEvent("UNIT_AURA", "player")
  watcherFrame:RegisterUnitEvent("UNIT_EXITED_VEHICLE", "player")
  watcherFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
  watcherFrame:RegisterEvent("PLAYER_DEAD")
  watcherFrame:RegisterEvent("PLAYER_LEAVING_WORLD")
  watcherFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
  watcherFrame:RegisterEvent("LOSS_OF_CONTROL_UPDATE")
  watcherFrame:RegisterEvent("PLAYER_MOUNT_DISPLAY_CHANGED")
  ResetState()
  active = true
  Debug.Log("WATCHER", "Activated — cycle events registered")
end

function Watcher.Deactivate()
  if not active then return end
  watcherFrame:UnregisterEvent("UNIT_SPELLCAST_SUCCEEDED")
  watcherFrame:UnregisterEvent("UNIT_SPELLCAST_EMPOWER_START")
  watcherFrame:UnregisterEvent("UNIT_SPELLCAST_EMPOWER_STOP")
  watcherFrame:UnregisterEvent("UNIT_AURA")
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
  Debug.Log("WATCHER", "Deactivated — cycle events unregistered%s",
    hadPending and " (pending alert cancelled)" or "")
end

function Watcher.IsActive()
  return active
end

---------------------------------------------------------------------------
-- Start — called from PLAYER_LOGIN. Only initializes; TalentGate decides
-- when to call Activate.
---------------------------------------------------------------------------
function Watcher.Start()
  Debug.Log("WATCHER", "Started — trigger=%s threshold=%s interval=%ss combat_only=%s min_rem=%ss",
    tostring(Config.Get(Config.Options.SPELL_ID)),
    tostring(Config.Get(Config.Options.THRESHOLD)),
    tostring(Config.Get(Config.Options.STACK_INTERVAL)),
    tostring(Config.Get(Config.Options.COMBAT_ONLY)),
    tostring(Config.Get(Config.Options.MIN_REMAINING)))
end
