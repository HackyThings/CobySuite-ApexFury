-------------------------------------------------------------------------------
-- ApexFury — Stack alert via cast detection + targeted aura tracking
--
-- Background:
--   In Midnight 12.0, many class buffs (incl. Rising Fury) are flagged as
--   "private auras" — fields are secret values during combat. We cannot
--   directly observe stack counts, so we model them ourselves.
--
-- Design:
--   1. Watch UNIT_SPELLCAST_SUCCEEDED for the configured TRIGGER spell.
--      Cast events are NOT subject to the private-aura system.
--   2. Schedule the alert at +(threshold - 1) * interval seconds.
--   3. Identify Dragonrage's active state in UNIT_AURA's addedAuras
--      payload. The cast spell ID 375087 is NOT the long-lived state —
--      it applies as a brief ~3s pulse aura. The actual "DR is active"
--      buff is Rising Fury (DR_STATE_AURA_IDS, name "Rising Fury"),
--      which lasts the full Animosity-extended duration. We match by
--      spellId, then by name, with a transient-buff exclusion list and
--      cascade/predictive fallbacks for cases where field reads are
--      secret values during combat. See HandleAuraUpdate below for
--      the full identification flow (capture phase + verify-on-drop).
--   4. Track empower casts via UNIT_SPELLCAST_SUCCEEDED for known empower
--      spell IDs (Fire Breath, Eternity Surge). This catches both
--      normal channel-released empowers AND Tip-the-Scales instant ones,
--      which the older UNIT_SPELLCAST_EMPOWER_STOP path missed. Each
--      empower extends DR per the Animosity formula
--      (+5s × 0.75^N diminishing per cast).
--   5. When the tracked Rising Fury instance is removed (UNIT_AURA's
--      removedAuraInstanceIDs payload), mark triggerDropTime — the
--      Risen Fury linger phase begins.
--   6. At alert fire time:
--      - If combat_only and player not in combat → defer (alertPending=true)
--      - If actionability_gate and player can't act (vehicle/mount/CC/
--        possession) → defer with reason
--      - Otherwise fire sound immediately (subject to linger-remaining gate)
--   7. On combat re-entry / vehicle exit / CC end / mount change with a
--      pending alert, re-evaluate via the linger-model gate. A 0.5s
--      polling fallback resolves transitions that don't fire dedicated
--      events. If presumed RF/Risen Fury time remaining is below
--      min_remaining, suppress; otherwise fire.
--   8. Linger window for Rising Fury → Risen Fury after Dragonrage drops:
--        expires = triggerDropTime + min(linger_max, stacks_at_drop * linger_per_stack)
--      Stacks at drop are computed from elapsed time during DR.
-------------------------------------------------------------------------------

local Watcher = ApexFury.Watcher
local Config = ApexFury.Config
local Debug = ApexFury.Debug

-- Internal state ----------------------------------------------------------
local castTime              -- when trigger spell last cast (or nil)
local alertScheduledFor     -- absolute time the timer is set to elapse
local capturedAuraIDs       -- set: { [auraInstanceID] = true }
local capturedAuraMeta      -- per-aura diagnostic info: { [id] = { capturedAt, spellId } }
local firstCapturedID       -- presumed trigger parent (e.g. Dragonrage)
local triggerDropTime       -- when firstCapturedID was removed (parent buff ended)
local empowerCount          -- empower casts observed since trigger cast
local expectedTriggerEnd    -- predicted absolute time the trigger buff will end
local alertFired            -- bool: sound has been played
local alertPending          -- bool: timer elapsed but waiting for combat
local alertSuppressed       -- bool: alert was cancelled
local lastFiredTime         -- last time alert actually played sound
local lastFiredOffset       -- precise elapsed seconds from cast to fire
local lastSuppressOffset    -- precise elapsed seconds from cast to suppression
local lastSuppressReason    -- "buff_dropped" / "rf_too_short" / "trigger_too_short" / "rf_expired" / "death" / "zone" / nil
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

-- Empower spell IDs we track for Animosity duration extension. Counted
-- via UNIT_SPELLCAST_SUCCEEDED (not _EMPOWER_STOP) so Tip-the-Scales
-- instant releases register too — TtS-instant empowers don't fire
-- _EMPOWER_STOP with complete=true.
local EMPOWER_SPELL_IDS = {
  [357208] = "Fire Breath",
  [359073] = "Eternity Surge",
}

-- Known transient buffs the engine occasionally puts at addedAuras[1]
-- ahead of Dragonrage. When the trigger-spellId/name lookups all return
-- secret values during combat, we exclude these from being chosen as
-- firstCapturedID so a Tip-the-Scales consumption (~1-2s after DR cast)
-- doesn't get mistaken for DR ending. Add new entries here as we
-- identify them in real-pull bug reports.
local TRANSIENT_AURA_SPELL_IDS = {
  [370553] = "Tip the Scales",
  [375087] = "Dragonrage cast pulse",  -- the cast spell ID applies as a
                                       -- brief ~3s aura, not the long-
                                       -- lived state. Skip it from the
                                       -- non-transient fallback so we
                                       -- don't pick it.
}

-- Aura instance spell IDs that represent "Dragonrage is active" — the
-- long-lived state proxy we want to track for DR end timing. These are
-- Rising Fury variants (the talent that grants the haste-stacking buff
-- alongside DR). The cast spell ID 375087 is NOT here because it
-- applies as only a brief ~3s buff (the cast pulse), confirmed via
-- training-dummy testing 2026-05-01 — instance with sID=375087 lived
-- 3.26s while sID=1271783 (Rising Fury) lived 31.67s, matching the
-- predicted Animosity-extended DR end.
--
-- Different Rising Fury talent ranks appear to have different aura
-- IDs. We've observed 1271687 (TalentGate name match), 1271783
-- (training dummy at rank 4), and 1271796 (Wowhead's listed page).
-- All three are recognized as DR-state proxies. When new ranks or
-- variants surface in real-pull logs, add them here.
local DR_STATE_AURA_IDS = {
  [1271783] = true,  -- Rising Fury (rank 4 observed)
  [1271687] = true,  -- Rising Fury variant
  [1271796] = true,  -- Rising Fury variant
}
local DR_STATE_AURA_NAME = "Rising Fury"

-- The cast spell ID for Dragonrage. When the user has the default
-- trigger configured, we match DR-state aura IDs above. If they've
-- changed the trigger (testing/debugging), fall back to the configured
-- spell ID for direct matching.
local DRAGONRAGE_CAST_SPELL_ID = 375087

-- Trigger duration model (Devastation Evoker / Dragonrage defaults).
-- Used to PREDICT how long DR will run based on observed empower casts.
-- Each empower extends DR via the Animosity talent: +5s with 25%
-- diminishing returns per cast.
local DR_BASE_DURATION       = 18
local ANIMOSITY_EXTENSION    = 5
local ANIMOSITY_DIMINISHING  = 0.75

---------------------------------------------------------------------------
-- Reset state
---------------------------------------------------------------------------
local function ResetState()
  castTime = nil
  alertScheduledFor = nil
  capturedAuraIDs = {}
  capturedAuraMeta = {}
  firstCapturedID = nil
  triggerDropTime = nil
  empowerCount = 0
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
  if pendingTimer then
    pendingTimer:Cancel()
    pendingTimer = nil
  end
  if pendingPollTimer then
    pendingPollTimer:Cancel()
    pendingPollTimer = nil
  end
  pendingDeferReason = nil
end

---------------------------------------------------------------------------
-- Compute the expected trigger buff end time based on empower casts so far.
-- Animosity formula: +5s per empower with 25% diminishing returns per cast.
---------------------------------------------------------------------------
local function ComputeExpectedTriggerEnd()
  if not castTime then return nil end
  local totalExtension = 0
  for i = 0, empowerCount - 1 do
    totalExtension = totalExtension + ANIMOSITY_EXTENSION * (ANIMOSITY_DIMINISHING ^ i)
  end
  return castTime + DR_BASE_DURATION + totalExtension
end

---------------------------------------------------------------------------
-- Compute the maximum stack count delivered by the trigger.
--
-- Used for linger duration math. Stack ticks happen at t=interval,
-- 2*interval, ... while the trigger is active. A tick scheduled exactly
-- when the trigger ENDS doesn't fire (lost to the race), so we subtract a
-- tiny epsilon. The threshold-reached check itself uses the predictive
-- expectedTriggerEnd model (see CheckTriggerRanLongEnough).
---------------------------------------------------------------------------
local function ComputeMaxStacksReached()
  if not castTime then return 0 end
  local interval = Config.Get(Config.Options.STACK_INTERVAL)
  local maxStacks = Config.Get(Config.Options.MAX_STACKS)

  local effectiveEnd = triggerDropTime or GetTime()
  local elapsed = effectiveEnd - castTime - 0.05  -- boundary tick epsilon
  if elapsed < 0 then return 1 end

  return math.min(maxStacks, 1 + math.floor(elapsed / interval))
end

---------------------------------------------------------------------------
-- Will the trigger buff run long enough for the threshold-th stack tick to
-- definitively fire? Uses observed drop time when known, otherwise the
-- predictive expectedTriggerEnd from empower-cast tracking.
---------------------------------------------------------------------------
local function CheckTriggerRanLongEnough()
  if not castTime then return false end
  local interval = Config.Get(Config.Options.STACK_INTERVAL)
  local threshold = Config.Get(Config.Options.THRESHOLD)
  local requiredDuration = (threshold - 1) * interval + THRESHOLD_BUFFER

  local actualDuration
  if triggerDropTime then
    actualDuration = triggerDropTime - castTime
  else
    actualDuration = (expectedTriggerEnd or (castTime + DR_BASE_DURATION)) - castTime
  end

  return actualDuration >= requiredDuration, actualDuration, requiredDuration
end

---------------------------------------------------------------------------
-- Compute estimated linger remaining (seconds). Returns:
--   math.huge when trigger parent is still active (linger hasn't started yet)
--   number when in linger window
--   0 when linger has fully expired
---------------------------------------------------------------------------
local function EstimateLingerRemaining()
  if not castTime then return 0 end
  if not triggerDropTime then return math.huge end

  local lingerPer = Config.Get(Config.Options.LINGER_PER_STACK)
  local lingerMax = Config.Get(Config.Options.LINGER_MAX)

  local stacksAtDrop = ComputeMaxStacksReached()
  local lingerDuration = math.min(lingerMax, stacksAtDrop * lingerPer)
  local expiresAt = triggerDropTime + lingerDuration
  return math.max(0, expiresAt - GetTime())
end

---------------------------------------------------------------------------
-- Are stacks still available for the alert to be meaningful?
--
-- The capture set isn't a reliable proxy for "RF/Risen Fury still alive":
-- Rising Fury's first stack ticks at +6s (outside our 1s capture window),
-- so capturedAuraIDs typically only ever holds the trigger parent (DR).
-- When DR drops, captured becomes empty even though RF→Risen Fury can
-- linger for up to LINGER_MAX more seconds.
--
-- Use the time-based linger model instead:
--   - DR still active (no triggerDropTime): RF presumed accumulating.
--   - DR dropped: linger = stacksAtDrop × LINGER_PER_STACK (capped).
---------------------------------------------------------------------------
local function PresumablyHasStacks()
  if not castTime then return false end
  if not triggerDropTime then return true end
  return EstimateLingerRemaining() > 0
end

---------------------------------------------------------------------------
-- Fire the alert (sound + chat). Verifies the trigger context still holds
-- and that linger remaining meets the configured minimum.
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
    return
  end

  -- RF / Risen Fury still presumed alive per linger model? (Captured-set
  -- check would be unreliable since RF's first stack is outside our 1s
  -- capture window.)
  if not PresumablyHasStacks() then
    alertSuppressed = true
    lastSuppressReason = "buff_dropped"
    if castTime then lastSuppressOffset = GetTime() - castTime end
    Debug.Log("WATCHER", "Alert suppressed @ %s — RF/Risen Fury linger expired", reasonContext)
    return
  end

  -- Did the trigger buff run long enough to actually deliver the threshold
  -- stack? Linger auras can still be alive even when the threshold tick was
  -- lost to the trigger-end race (e.g. unextended DR at 18s yields 3 stacks
  -- of Rising Fury, not 4). Uses predictive duration when DR is still
  -- active, observed drop time when it has ended.
  local longEnough, actualDur, requiredDur = CheckTriggerRanLongEnough()
  if not longEnough then
    alertSuppressed = true
    lastSuppressReason = "trigger_too_short"
    if castTime then lastSuppressOffset = GetTime() - castTime end
    Debug.Log("WATCHER", "Alert suppressed @ %s — trigger duration %.2fs < required %.2fs (empowers=%d)",
      reasonContext, actualDur, requiredDur, empowerCount)
    return
  end

  -- Linger-remaining gate (only relevant after trigger parent dropped)
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

  ApexFury.Sound.Play(Config.Get(Config.Options.SOUND_ID))
  lastFiredTime = GetTime()
  if castTime then lastFiredOffset = lastFiredTime - castTime end

  -- Debug log only — sound itself is the user-facing alert; no chat spam.
  Debug.Event("WATCHER", "Alert fired @ %s (threshold=%d, offset=%.3fs)",
    reasonContext, Config.Get(Config.Options.THRESHOLD) or 0, lastFiredOffset or 0)
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
      if pendingPollTimer then
        pendingPollTimer:Cancel()
        pendingPollTimer = nil
      end
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
  if pendingPollTimer then
    pendingPollTimer:Cancel()
    pendingPollTimer = nil
  end
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
  if pendingPollTimer then pendingPollTimer:Cancel() end
  local snapshotCastTime = castTime
  pendingPollTimer = C_Timer.NewTicker(0.5, function()
    if castTime ~= snapshotCastTime
       or alertFired or alertSuppressed or not alertPending then
      if pendingPollTimer then pendingPollTimer:Cancel() end
      pendingPollTimer = nil
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

  Debug.Log("WATCHER", "Trigger cast — timer at +%.2fs (suppress unless DR >= %.2fs)",
    delay, delay + THRESHOLD_BUFFER)

  pendingTimer = C_Timer.NewTimer(delay, OnAlertTimerExpired)

  -- Note: an earlier `C_Timer.After(0.05)` GetPlayerAuraBySpellID
  -- verification step was removed once we identified that the cast
  -- spell ID 375087 isn't the long-lived state buff in 12.0 — it's a
  -- brief ~3s pulse, so the lookup was returning nil 100% of the time
  -- in real logs. Capture-phase Rising Fury matching (HandleAuraUpdate
  -- below) handles identification directly, with the cascade and
  -- predicted-vs-observed strategies as runtime safety nets.
end

---------------------------------------------------------------------------
-- UNIT_AURA handler
---------------------------------------------------------------------------
local function HandleAuraUpdate(info)
  if not castTime then return end
  if not info then return end

  local now = GetTime()
  local sinceCast = now - castTime

  -- Capture phase: within ~1s of cast, remember every newly-added
  -- aura's instance ID. Identify Dragonrage by its spellId or name
  -- inside the addedAuras struct directly — `GetPlayerAuraBySpellID`
  -- has been observed to return nil for DR in 12.0 (cast spellID
  -- apparently doesn't match the buff lookup), so we can't rely on
  -- a separate spell-lookup verification path.
  --
  -- Identification strategies, in order:
  --   1. aura.spellId == triggerID (positive match — most reliable)
  --   2. aura.name == triggerName (positive match — fallback if
  --      spellId is a secret value during combat)
  --   3. First non-transient aura (skip known short-lived buffs like
  --      Tip the Scales that get consumed seconds after DR cast)
  --   4. addedAuras[1] (last-resort first-arrival heuristic)
  --
  -- All field reads are pcall + issecretvalue gated.
  if sinceCast < CAPTURE_WINDOW and info.addedAuras then
    local verbose = Config.Get(Config.Options.VERBOSE)
    local triggerID = Config.Get(Config.Options.SPELL_ID)

    -- Determine which buff IDs/names mean "DR is active" for the
    -- current configuration. With default Dragonrage, match against
    -- Rising Fury (the long-lived state proxy). If the user has
    -- changed the trigger spell, match against that spell directly.
    local stateAuraIDs, stateAuraName
    if triggerID == DRAGONRAGE_CAST_SPELL_ID then
      stateAuraIDs = DR_STATE_AURA_IDS
      stateAuraName = DR_STATE_AURA_NAME
    else
      stateAuraIDs = { [triggerID] = true }
      local ok, n = pcall(function()
        return C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(triggerID) or nil
      end)
      if ok and type(n) == "string" then stateAuraName = n end
    end

    local matchedDR        -- positively identified via spellId or name
    local nonTransientGuess -- first aura in this batch whose spellId isn't a known transient
    local firstAuraInBatch  -- absolute first aura in this batch (last-resort fallback)

    for idx, aura in ipairs(info.addedAuras) do
      local idOk, id = pcall(function() return aura.auraInstanceID end)
      if idOk and type(id) == "number" then
        local isNew = not capturedAuraIDs[id]
        capturedAuraIDs[id] = true

        if not firstAuraInBatch then firstAuraInBatch = id end

        -- Read spellId with secret-value gating
        local sIDOk, sID = pcall(function()
          local s = aura.spellId
          if type(s) ~= "number" then return nil end
          if issecretvalue and issecretvalue(s) then return nil end
          return s
        end)
        local readableSID = sIDOk and type(sID) == "number" and sID or nil

        -- Diagnostic metadata. Lets the drop log emit a lifetime and
        -- the cycle-complete summary identify which sIDs were in the
        -- captured set without re-querying the API.
        if isNew then
          capturedAuraMeta[id] = { capturedAt = now, spellId = readableSID }
        end

        -- Strategy 1: spellId positive match (against DR state aura IDs,
        -- not the cast ID — see DR_STATE_AURA_IDS comment)
        if not matchedDR and readableSID and stateAuraIDs[readableSID] then
          matchedDR = id
        end

        -- Strategy 2: name positive match (only if spellId didn't match)
        if not matchedDR and stateAuraName then
          local nOk, name = pcall(function()
            local x = aura.name
            if type(x) ~= "string" then return nil end
            if issecretvalue and issecretvalue(x) then return nil end
            return x
          end)
          if nOk and name == stateAuraName then
            matchedDR = id
          end
        end

        -- Strategy 3: track first non-transient as a guess fallback.
        -- If spellId is readable AND it's a known transient → skip.
        -- If spellId is unreadable → can't tell, treat as candidate.
        if not nonTransientGuess then
          if not readableSID or not TRANSIENT_AURA_SPELL_IDS[readableSID] then
            nonTransientGuess = id
          end
        end

        if verbose and isNew then
          Debug.Log("CAPTURE", "  +%.3fs add[%d] instance=%d sID=%s",
            sinceCast, idx, id, tostring(readableSID))
        end
      end
    end

    -- Apply identification. Two precedence rules to prevent later UNIT_AURA
    -- events from clobbering a correct early pick:
    --   1. A positive spellId/name match ALWAYS wins. It can replace
    --      either a previous positive match (rare — would mean two auras
    --      claim the trigger spell) or a fallback guess.
    --   2. A fallback guess (non-transient or first-arrival) is ONLY
    --      used to set firstCapturedID for the first time. It never
    --      overrides an already-set firstCapturedID, even if that prior
    --      pick was itself a fallback guess. Otherwise event 2's single-
    --      aura batch would pick a different "non-transient" each time
    --      and the real DR (caught in event 1) would get displaced.
    if matchedDR then
      if matchedDR ~= firstCapturedID then
        Debug.Log("WATCHER",
          "DR positively identified: instance %d (spellId/name match; was %s)",
          matchedDR, tostring(firstCapturedID))
        firstCapturedID = matchedDR
      end
    elseif not firstCapturedID then
      -- First time setting — use best fallback in priority order.
      if nonTransientGuess then
        firstCapturedID = nonTransientGuess
        Debug.Log("WATCHER",
          "DR initial guess: instance %d (non-transient fallback)", firstCapturedID)
      elseif firstAuraInBatch then
        firstCapturedID = firstAuraInBatch
        Debug.Log("WATCHER",
          "DR initial guess: instance %d (first-arrival; all candidates were known transients)",
          firstCapturedID)
      end
    end
    -- Otherwise: firstCapturedID already set by a previous event. Don't
    -- override with another fallback guess.
  end

  -- Removal phase: removedAuraInstanceIDs is a plain numeric array,
  -- always safe to read. When the first captured ID drops, mark the
  -- linger window start. When all captured IDs are gone, the linger
  -- has fully expired.
  if info.removedAuraInstanceIDs then
    local sawCapturedRemoval = false
    local verbose = Config.Get(Config.Options.VERBOSE)
    for _, id in ipairs(info.removedAuraInstanceIDs) do
      if capturedAuraIDs[id] then
        capturedAuraIDs[id] = nil
        sawCapturedRemoval = true
        if verbose then
          local meta = capturedAuraMeta[id]
          local lifetime = meta and (now - meta.capturedAt) or nil
          local sIDStr = meta and tostring(meta.spellId) or "?"
          if lifetime then
            Debug.Log("CAPTURE",
              "  +%.3fs drop instance=%d (lived %.2fs sID=%s)%s",
              sinceCast, id, lifetime, sIDStr,
              id == firstCapturedID and " [first]" or "")
          else
            Debug.Log("CAPTURE", "  +%.3fs drop instance=%d%s", sinceCast, id,
              id == firstCapturedID and " [first]" or "")
          end
        end
        if id == firstCapturedID and not triggerDropTime then
          -- Verify the trigger spell is ACTUALLY gone before declaring
          -- it dropped. Two strategies, in order:
          --   A. Positive identification: walk the remaining captured
          --      auras, read each one's spellId/name (with secret-value
          --      gating), match against the trigger.
          --   B. Runtime adaptation (heuristic): if the drop happens
          --      too early to plausibly be Dragonrage (DR base is 18s,
          --      we use 13s threshold for safety margin), the
          --      just-dropped aura was a transient we couldn't identify
          --      because all its field reads were secret values during
          --      combat. Switch to ANY other surviving captured aura.
          --      If THAT one also drops short, the next drop event will
          --      cascade into another switch — eventually landing on a
          --      long-lived aura that outlives the alert window.
          --
          -- Cannot use GetPlayerAuraBySpellID — observed to consistently
          -- return nil for Dragonrage in 12.0.
          local TOO_SHORT_FOR_DR = 13

          local triggerID = Config.Get(Config.Options.SPELL_ID)

          -- Same DR-state aura ID/name logic as capture phase. Match
          -- the long-lived state buff (Rising Fury), not the brief
          -- cast pulse aura (Dragonrage cast spell ID).
          local stateAuraIDs, stateAuraName
          if triggerID == DRAGONRAGE_CAST_SPELL_ID then
            stateAuraIDs = DR_STATE_AURA_IDS
            stateAuraName = DR_STATE_AURA_NAME
          else
            stateAuraIDs = { [triggerID] = true }
            local ok, n = pcall(function()
              return C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(triggerID) or nil
            end)
            if ok and type(n) == "string" then stateAuraName = n end
          end

          -- Build set of IDs being dropped in THIS event so we don't
          -- pick a candidate that's about to vanish in this same loop.
          local thisEventDrops = {}
          for _, dID in ipairs(info.removedAuraInstanceIDs) do
            thisEventDrops[dID] = true
          end

          local realID, realIDSource

          -- Strategy A: positive match
          for candidateID in pairs(capturedAuraIDs) do
            if candidateID ~= id and not thisEventDrops[candidateID] then
              local aOk, aura = pcall(C_UnitAuras.GetAuraDataByAuraInstanceID, "player", candidateID)
              if aOk and aura then
                local sIDOk, sID = pcall(function()
                  local s = aura.spellId
                  if type(s) ~= "number" then return nil end
                  if issecretvalue and issecretvalue(s) then return nil end
                  return s
                end)
                if sIDOk and sID and stateAuraIDs[sID] then
                  realID, realIDSource = candidateID, "spellId match"
                  break
                end
                if stateAuraName then
                  local nOk, name = pcall(function()
                    local x = aura.name
                    if type(x) ~= "string" then return nil end
                    if issecretvalue and issecretvalue(x) then return nil end
                    return x
                  end)
                  if nOk and name == stateAuraName then
                    realID, realIDSource = candidateID, "name match"
                    break
                  end
                end
              end
            end
          end

          -- Strategy B: too-short-for-DR runtime fallback
          if not realID and sinceCast < TOO_SHORT_FOR_DR then
            for candidateID in pairs(capturedAuraIDs) do
              if candidateID ~= id and not thisEventDrops[candidateID] then
                realID = candidateID
                realIDSource = string.format(
                  "too-short-fallback (drop @ %.2fs < %ds)", sinceCast, TOO_SHORT_FOR_DR)
                break
              end
            end
          end

          if realID then
            Debug.Log("WATCHER",
              "First-aura drop @ %.2fs — correcting firstCapturedID from %d to %d (%s)",
              sinceCast, firstCapturedID, realID, realIDSource)
            firstCapturedID = realID
            -- Do NOT set triggerDropTime; trigger presumed still alive.
          else
            -- Strategy C: predicted-vs-observed sanity check.
            -- If the observed drop is significantly later than the
            -- predictive Animosity model expects, the tracked aura was
            -- probably not Dragonrage — it was a longer-lived non-DR
            -- buff (Light's Potential, trinket proc, etc.) that the
            -- engine put at addedAuras[1] and that we couldn't identify
            -- by spellId during combat. The cascade-too-short heuristic
            -- (Strategy B) doesn't catch these because they outlive the
            -- 13s window. Trust the predictive end instead.
            --
            -- Animosity is the only known DR extension mechanic in
            -- 12.0, so predicted is an upper bound on real DR duration.
            -- An observed > predicted + 5s means the tracked aura
            -- definitively outlived DR. Without this override, the
            -- linger model inflates stacks-at-drop and lingerDuration,
            -- causing late-fire false positives on deferred (OOC)
            -- alerts. Confirmed in a no-empower DR cycle 2026-05-01:
            -- DR ended at +18s but tracked aura (Light's Potential) at
            -- +30s, leading to alert firing at +38s on combat re-entry
            -- when only 3 stacks ever existed.
            local LATE_MARGIN = 5
            local sourceTag
            if expectedTriggerEnd
               and sinceCast > (expectedTriggerEnd - castTime) + LATE_MARGIN then
              triggerDropTime = expectedTriggerEnd
              sourceTag = "predicted-override"
              Debug.Log("WATCHER",
                "Observed drop @ %.2fs significantly later than predicted %.2fs (empowers=%d) — using predicted as trigger end (likely tracked non-DR aura)",
                sinceCast, expectedTriggerEnd - castTime, empowerCount)
            else
              triggerDropTime = now
              sourceTag = "observed"
              Debug.Log("WATCHER", "Trigger parent dropped after %.2fs (linger begins)", sinceCast)
            end

            -- Cycle-complete summary (always-on diagnostic). Compares
            -- the predictive Animosity model against the tracked aura's
            -- observed drop. Large deltas indicate either real DR was
            -- cancelled early, or our firstCapturedID wasn't actually
            -- DR (which would skew the linger model when deferred
            -- alerts later resolve). The instance + sID helps identify
            -- whether the tracked aura was DR or some longer/shorter
            -- non-DR buff that should be added to the transient list
            -- or otherwise filtered.
            if expectedTriggerEnd then
              local predictedSinceCast = expectedTriggerEnd - castTime
              local observedSinceCast = triggerDropTime - castTime
              local delta = observedSinceCast - predictedSinceCast
              local meta = capturedAuraMeta[id]
              local sIDStr = meta and tostring(meta.spellId) or "?"
              Debug.Log("WATCHER",
                "Cycle complete — predicted DR=%.2fs, observed=%.2fs (Δ=%+.2fs), empowers=%d, instance=%d sID=%s, source=%s",
                predictedSinceCast, observedSinceCast, delta,
                empowerCount, firstCapturedID, sIDStr, sourceTag)
            end
          end
        end
      end
    end

    if sawCapturedRemoval and next(capturedAuraIDs) == nil and sinceCast > 0.1 then
      -- Captured set typically only holds DR (RF first ticks at +6s,
      -- outside our 1s capture window), so this fires when DR drops —
      -- NOT when RF/Risen Fury actually expire. Don't auto-suppress
      -- here: let the timer / combat-entry path evaluate via FireAlert's
      -- linger-model gate, which knows about the Risen Fury phase.
      Debug.Log("WATCHER", "Trigger parent removed from capture set @ %.2fs (linger model takes over)", sinceCast)
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
  -- activeCount and capturedTotal both derive from capturedAuraIDs
  -- (maintained via UNIT_AURA's removedAuraInstanceIDs payload).
  local capturedTotal = 0
  for _ in pairs(capturedAuraIDs or {}) do capturedTotal = capturedTotal + 1 end

  stateView.castTime           = castTime
  stateView.alertScheduledFor  = alertScheduledFor
  stateView.alertFired         = alertFired
  stateView.alertPending       = alertPending
  stateView.alertSuppressed    = alertSuppressed
  stateView.triggerDropTime    = triggerDropTime
  stateView.empowerCount       = empowerCount or 0
  stateView.expectedTriggerEnd = expectedTriggerEnd
  stateView.capturedTotal      = capturedTotal
  stateView.activeCount        = capturedTotal
  stateView.capturedIDs        = capturedAuraIDs
  stateView.firstCapturedID    = firstCapturedID
  stateView.lastFiredTime      = lastFiredTime
  stateView.lastFiredOffset    = lastFiredOffset
  stateView.lastSuppressOffset = lastSuppressOffset
  stateView.lastSuppressReason = lastSuppressReason
  stateView.estLingerRemaining = EstimateLingerRemaining()
  stateView.stacksAtDrop       = ComputeMaxStacksReached()
  stateView.pendingDeferReason = pendingDeferReason

  -- TalentGate status — surfaced here so the overlay can render a single
  -- combined view without coupling Overlay → TalentGate directly.
  local gate = ApexFury.TalentGate and ApexFury.TalentGate.GetState
               and ApexFury.TalentGate.GetState() or nil
  if gate then
    stateView.gateUsable       = gate.usable
    stateView.gateReason       = gate.reason
    stateView.gateDetail       = gate.detail
    stateView.gateRisingFury   = gate.risingFuryRank
    stateView.gateAnimosity    = gate.hasAnimosity
    stateView.gateApiAvailable = gate.apiAvailable
    stateView.gateIsDevo       = gate.isDevastation
  else
    -- TalentGate not yet started — assume usable so the overlay shows
    -- normal state during the brief startup window.
    stateView.gateUsable       = true
    stateView.gateReason       = "ready"
    stateView.gateDetail       = "Initializing..."
  end
  stateView.watcherActive = active

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
    elseif EMPOWER_SPELL_IDS[spellID] and castTime and not triggerDropTime then
      -- Animosity extension. Counted on SUCCEEDED rather than _EMPOWER_STOP
      -- so Tip-the-Scales instant empowers register too.
      empowerCount = (empowerCount or 0) + 1
      expectedTriggerEnd = ComputeExpectedTriggerEnd()
      Debug.Log("WATCHER", "Empower #%d (%s, id=%d) — DR predicted to last %.2fs total",
        empowerCount, EMPOWER_SPELL_IDS[spellID], spellID, expectedTriggerEnd - castTime)
    end

  elseif event == "UNIT_SPELLCAST_EMPOWER_STOP" then
    -- We only care about cancellations here (informational log). The
    -- successful path is handled in UNIT_SPELLCAST_SUCCEEDED above.
    -- args: unitTarget, castGUID, spellID, complete, interruptedBy, castBarID
    local _, _, empSpellID, complete = ...
    if not complete and castTime and not triggerDropTime then
      Debug.Log("WATCHER", "Empower id=%s cancelled — no extension", tostring(empSpellID))
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
      if pendingTimer then
        pendingTimer:Cancel()
        pendingTimer = nil
      end
    end

  elseif event == "PLAYER_LEAVING_WORLD" then
    if castTime and not alertFired and not alertSuppressed then
      Debug.Log("WATCHER", "Suppressing pending alert: PLAYER_LEAVING_WORLD")
      alertSuppressed = true
      alertPending = false
      lastSuppressReason = "zone"
      lastSuppressOffset = GetTime() - castTime
      if pendingTimer then
        pendingTimer:Cancel()
        pendingTimer = nil
      end
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
