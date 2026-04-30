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
--   3. ~50ms after cast, look up the trigger's actual auraInstanceID via
--      C_UnitAuras.GetPlayerAuraBySpellID(triggerID). Dragonrage is a
--      public aura; reading its instance ID is taint-safe and
--      authoritative. We do NOT rely on UNIT_AURA's addedAuras[1] — that
--      ordering is engine-controlled and frequently puts a co-procced
--      Iridescence/trinket buff first (proven via debug instrumentation).
--   4. Track empower casts via UNIT_SPELLCAST_SUCCEEDED for known empower
--      spell IDs (Fire Breath, Eternity Surge). This catches both
--      normal channel-released empowers AND Tip-the-Scales instant ones,
--      which the older UNIT_SPELLCAST_EMPOWER_STOP path missed. Each
--      empower extends DR per the Animosity formula
--      (+5s × 0.75^N diminishing per cast).
--   5. When the trigger's auraInstanceID is removed (UNIT_AURA's
--      removedAuraInstanceIDs payload), mark triggerDropTime — the
--      Risen Fury linger phase begins.
--   6. At alert fire time:
--      - If combat_only and player not in combat → defer (alertPending=true)
--      - Otherwise fire sound immediately (subject to linger-remaining gate)
--   7. On PLAYER_REGEN_DISABLED with a pending alert, evaluate via the
--      linger-model gate. If presumed RF/Risen Fury time remaining is
--      below min_remaining, suppress; otherwise fire.
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
local watcherFrame

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
-- Timer callback — alert moment arrived. Either fire or defer.
---------------------------------------------------------------------------
local function OnAlertTimerExpired()
  if alertFired or alertSuppressed then return end

  local combatOnly = Config.Get(Config.Options.COMBAT_ONLY)
  if combatOnly and not UnitAffectingCombat("player") then
    -- Defer until combat starts
    alertPending = true
    Debug.Log("WATCHER", "Timer elapsed out of combat — alert deferred")

    -- Schedule a cleanup so the pending state doesn't stick around
    -- forever if the user never re-enters combat. Worst-case linger
    -- end is castTime + max DR (with 4 empowers ≈ 31.67s) + LINGER_MAX
    -- (default 20s) ≈ 52s after cast. We're already at +18s; 45s
    -- from now safely covers the rest.
    --
    -- Snapshot castTime so the cleanup only fires for THIS cycle —
    -- if the user casts again before 45s elapses, ResetState will
    -- have nilled or replaced castTime and we don't want to clobber
    -- the new cycle's pending state.
    local snapshotCastTime = castTime
    C_Timer.After(45, function()
      if castTime ~= snapshotCastTime then return end
      if alertPending and not alertFired and not alertSuppressed then
        alertPending = false
        alertSuppressed = true
        lastSuppressReason = "rf_expired"
        if castTime then lastSuppressOffset = GetTime() - castTime end
        Debug.Log("WATCHER", "Pending alert cleared — linger expired without combat re-entry")
      end
    end)
    return
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

  local triggerID = Config.Get(Config.Options.SPELL_ID)
  local threshold = Config.Get(Config.Options.THRESHOLD)
  local interval = Config.Get(Config.Options.STACK_INTERVAL)
  -- Fire at the exact stack-tick moment; the 0.1s safety buffer lives
  -- inside CheckTriggerRanLongEnough as a duration requirement.
  local delay = math.max(0, (threshold - 1) * interval)
  alertScheduledFor = castTime + delay

  Debug.Log("WATCHER", "Trigger cast — timer at +%.2fs (suppress unless DR >= %.2fs)",
    delay, delay + THRESHOLD_BUFFER)

  pendingTimer = C_Timer.NewTimer(delay, OnAlertTimerExpired)

  -- Targeted DR aura lookup at +50ms. The HandleAuraUpdate first-arrival
  -- heuristic picks whichever aura the engine puts at addedAuras[1] —
  -- often a co-procced trinket/Iridescence buff, NOT Dragonrage. That
  -- causes triggerDropTime to be set on the wrong aura's removal,
  -- silently suppressing alerts and ignoring later empower casts.
  -- Dragonrage is a public aura; reading its auraInstanceID via spell
  -- lookup is taint-safe and authoritative.
  local snapshotCastTime = castTime
  C_Timer.After(0.05, function()
    if castTime ~= snapshotCastTime then return end  -- cycle was reset/replaced
    -- C_UnitAuras.GetPlayerAuraBySpellID is the player-only variant; it
    -- takes only the spellID. Passing "player" as the first arg makes
    -- the literal string the spellID, defeats the lookup, and the pcall
    -- guard below trips on every cycle — leaving firstCapturedID
    -- pointing at whatever the engine put in addedAuras[1] (often a
    -- co-procced trinket/Iridescence buff, the original bug).
    local ok, aura = pcall(C_UnitAuras.GetPlayerAuraBySpellID, triggerID)
    if not (ok and aura) then return end
    local idOk, id = pcall(function() return aura.auraInstanceID end)
    if not (idOk and type(id) == "number") then return end
    local previousFirst = firstCapturedID
    firstCapturedID = id
    capturedAuraIDs[id] = true
    if previousFirst ~= id then
      Debug.Log("WATCHER", "DR aura ID = %d (via spell lookup; corrected from %s)",
        id, tostring(previousFirst))
    end
  end)
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
  -- aura's instance ID. The first one is the trigger parent
  -- (Dragonrage); subsequent ones are downstream procs (Rising Fury,
  -- Essence Burst, etc.). Reading auraInstanceID is documented-public
  -- on private auras.
  if sinceCast < CAPTURE_WINDOW and info.addedAuras then
    local verbose = Config.Get(Config.Options.VERBOSE)
    for idx, aura in ipairs(info.addedAuras) do
      local ok, id = pcall(function() return aura.auraInstanceID end)
      if ok and type(id) == "number" then
        local isNew = not capturedAuraIDs[id]
        capturedAuraIDs[id] = true
        if not firstCapturedID then
          firstCapturedID = id
          Debug.Log("WATCHER", "First-arrival aura ID = %d (initial capture, will verify via spell lookup)", id)
        end
        if verbose and isNew then
          Debug.Log("CAPTURE", "  +%.3fs add[%d] instance=%d", sinceCast, idx, id)
        end
      end
    end
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
          Debug.Log("CAPTURE", "  +%.3fs drop instance=%d%s", sinceCast, id,
            id == firstCapturedID and " [first]" or "")
        end
        if id == firstCapturedID and not triggerDropTime then
          triggerDropTime = now
          Debug.Log("WATCHER", "Trigger parent dropped after %.2fs (linger begins)", sinceCast)
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
    Debug.Log("WATCHER", "Combat entered — firing pending alert")
    FireAlert("combat_entry")
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
  spell_id         = true,
  threshold        = true,
  stack_interval   = true,
  linger_per_stack = true,
  linger_max       = true,
  max_stacks       = true,
  combat_only      = true,
  min_remaining    = true,
  enabled          = true,
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
  return stateView
end

---------------------------------------------------------------------------
-- Frame + event subscription
---------------------------------------------------------------------------
watcherFrame = CreateFrame("Frame")
watcherFrame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
watcherFrame:RegisterUnitEvent("UNIT_SPELLCAST_EMPOWER_STOP", "player")
watcherFrame:RegisterUnitEvent("UNIT_AURA", "player")
watcherFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
watcherFrame:RegisterEvent("PLAYER_DEAD")
watcherFrame:RegisterEvent("PLAYER_LEAVING_WORLD")
watcherFrame:RegisterEvent("PLAYER_ENTERING_WORLD")

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

  elseif event == "PLAYER_DEAD" then
    Debug.Log("WATCHER", "Suppressing pending alert: PLAYER_DEAD")
    alertSuppressed = true
    alertPending = false
    lastSuppressReason = "death"
    if castTime then lastSuppressOffset = GetTime() - castTime end
    if pendingTimer then
      pendingTimer:Cancel()
      pendingTimer = nil
    end

  elseif event == "PLAYER_LEAVING_WORLD" then
    Debug.Log("WATCHER", "Suppressing pending alert: PLAYER_LEAVING_WORLD")
    alertSuppressed = true
    alertPending = false
    lastSuppressReason = "zone"
    if castTime then lastSuppressOffset = GetTime() - castTime end
    if pendingTimer then
      pendingTimer:Cancel()
      pendingTimer = nil
    end

  elseif event == "PLAYER_ENTERING_WORLD" then
    ResetState()
  end
end)

---------------------------------------------------------------------------
-- Start — called from PLAYER_LOGIN
---------------------------------------------------------------------------
function Watcher.Start()
  Debug.Log("WATCHER", "Started — trigger=%s threshold=%s interval=%ss combat_only=%s min_rem=%ss",
    tostring(Config.Get(Config.Options.SPELL_ID)),
    tostring(Config.Get(Config.Options.THRESHOLD)),
    tostring(Config.Get(Config.Options.STACK_INTERVAL)),
    tostring(Config.Get(Config.Options.COMBAT_ONLY)),
    tostring(Config.Get(Config.Options.MIN_REMAINING)))
end
