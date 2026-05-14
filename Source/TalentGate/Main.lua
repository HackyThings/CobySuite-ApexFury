-------------------------------------------------------------------------------
-- ApexFury TalentGate — class/spec/talent prerequisite detection
--
-- Why this exists:
--   ApexFury alerts on Rising Fury reaching N stacks during Dragonrage. The
--   underlying mechanic is exclusive to Devastation Evoker, and even on Devo
--   it requires specific talents to be useful:
--
--     * Class must be Evoker (Dragonrage doesn't exist on other classes)
--     * Spec must be Devastation (1467) — Pres/Aug Evokers have no Dragonrage
--     * Rising Fury talent must be at rank ≥1 — without it, the buff this
--       addon tracks doesn't exist at all
--     * Animosity is needed for threshold ≥4 — unextended DR (18s) only
--       delivers 3 stacks before the buff expires
--
--   This module evaluates those conditions, activates/deactivates the
--   Watcher accordingly (so we don't waste UNIT_AURA / UNIT_SPELLCAST events
--   on a Pres healer raid), and emits chat warnings on state transitions.
--
-- Design:
--   1. Always-registered events: PLAYER_LOGIN, PLAYER_ENTERING_WORLD,
--      PLAYER_SPECIALIZATION_CHANGED, ACTIVE_TALENT_GROUP_CHANGED,
--      TRAIT_CONFIG_UPDATED. Cheap, low-frequency.
--   2. PLAYER_LOGIN does the initial evaluation + emit (always speaks once).
--      PLAYER_ENTERING_WORLD silently re-evaluates (zone changes shouldn't
--      spam chat) but emits on actual state transitions.
--   3. TRAIT_CONFIG_UPDATED is debounced 0.5s — fires repeatedly while the
--      user drags talent points around. We evaluate once after they settle.
--   4. Traits API can return nil at PLAYER_LOGIN before the config is
--      hydrated. Retry once at +1s, fail closed (apiAvailable=false) if
--      still nil. Distinct chat message so users can tell "API broken"
--      apart from "you didn't spec the talent".
--   5. Node IDs are resolved by scanning the trait tree once per spec for
--      entries whose definition spellID matches our targets. Cached.
-------------------------------------------------------------------------------

ApexFury.TalentGate = ApexFury.TalentGate or {}
local TalentGate = ApexFury.TalentGate

local Config = ApexFury.Config
local Debug  = ApexFury.Debug

---------------------------------------------------------------------------
-- Constants
---------------------------------------------------------------------------
local DEVASTATION_SPEC_ID = 1467
local EVOKER_CLASS_TOKEN  = "EVOKER"

-- Spell IDs we identify in the trait tree. These match against the spellID
-- exposed by C_Traits.GetDefinitionInfo for each ranked entry.
local ANIMOSITY_SPELL_ID  = 375797   -- passive, single-rank
local RISING_FURY_AURA_ID = 1271796  -- the buff aura the apex talent grants

-- Localized name fallback when spellID matching fails (e.g. talent
-- definition references a different ID than the buff). English client
-- only — we log loudly if we have to fall back to this.
local RISING_FURY_NAME_EN = "Rising Fury"
local ANIMOSITY_NAME_EN   = "Animosity"

local TRAIT_DEBOUNCE_SEC = 0.5
local API_RETRY_SEC      = 1.0

---------------------------------------------------------------------------
-- Internal state
---------------------------------------------------------------------------
local frame
local current = {
  classToken     = nil,
  specID         = nil,
  isEvoker       = false,
  isDevastation  = false,
  risingFuryRank = 0,
  hasAnimosity   = false,
  apiAvailable   = true,
  usable         = false,    -- isDevastation AND risingFuryRank>=1 AND apiAvailable
  reason         = "unknown",
  detail         = "",
}
local previousEmittedState  -- snapshot used to detect actual transitions
local nodeCache = {}        -- per-specID: { animosity = nodeID, risingFury = nodeID, scanned = true }
local pendingDebounceID = 0 -- generation counter for debounce coalescing
local pendingApiRetryID = 0 -- ditto for API retry

---------------------------------------------------------------------------
-- Chat messaging — uses the addon's branded prefix
---------------------------------------------------------------------------
local function Say(msg)
  if ApexFury.Message then ApexFury.Message(msg) end
end

---------------------------------------------------------------------------
-- Verbose log helper — only emits when Config.VERBOSE is on
---------------------------------------------------------------------------
local function LogVerbose(fmt, ...)
  if Config and Config.Get and Config.Options and Config.Options.VERBOSE
     and Config.Get(Config.Options.VERBOSE) then
    Debug.Log("TALENTGATE", fmt, ...)
  end
end

---------------------------------------------------------------------------
-- Scan the active trait tree for our target talent nodes. Caches the
-- nodeIDs per-spec so we only walk the tree once per spec change.
--
-- Returns true if the API returned a usable config; false if anything
-- nil-ed out (retry path will be triggered by caller).
---------------------------------------------------------------------------
local function ScanForNodes(configID, specID)
  if not configID or not specID then return false end

  -- Already scanned this spec? Use cache.
  if nodeCache[specID] and nodeCache[specID].scanned then
    return true
  end

  local configInfo = C_Traits.GetConfigInfo(configID)
  if not configInfo or not configInfo.treeIDs then
    LogVerbose("ScanForNodes: GetConfigInfo returned nil or no treeIDs (configID=%s)",
      tostring(configID))
    return false
  end

  local cache = { animosity = nil, risingFury = nil, scanned = false }

  for _, treeID in ipairs(configInfo.treeIDs) do
    local nodes = C_Traits.GetTreeNodes(treeID)
    if nodes then
      for _, nodeID in ipairs(nodes) do
        local nodeInfo = C_Traits.GetNodeInfo(configID, nodeID)
        if nodeInfo and nodeInfo.entryIDs then
          for _, entryID in ipairs(nodeInfo.entryIDs) do
            local entry = C_Traits.GetEntryInfo(configID, entryID)
            if entry and entry.definitionID then
              local def = C_Traits.GetDefinitionInfo(entry.definitionID)
              if def then
                local spellID = def.spellID
                if spellID == ANIMOSITY_SPELL_ID then
                  cache.animosity = nodeID
                elseif spellID == RISING_FURY_AURA_ID then
                  cache.risingFury = nodeID
                end

                -- Localized name fallback: only check if spellID match
                -- didn't already identify this node. C_Spell.GetSpellName
                -- is the safe way to read names without taint.
                if not cache.animosity or not cache.risingFury then
                  local nameOk, name = pcall(function()
                    return spellID and C_Spell.GetSpellName and C_Spell.GetSpellName(spellID) or nil
                  end)
                  if nameOk and type(name) == "string" then
                    if not cache.animosity and name == ANIMOSITY_NAME_EN then
                      cache.animosity = nodeID
                      Debug.Log("TALENTGATE", "Animosity matched by name (spellID %s) — talent ID may have changed",
                        tostring(spellID))
                    elseif not cache.risingFury and name == RISING_FURY_NAME_EN then
                      cache.risingFury = nodeID
                      Debug.Log("TALENTGATE", "Rising Fury matched by name (spellID %s) — talent ID may have changed",
                        tostring(spellID))
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
  end

  cache.scanned = true
  nodeCache[specID] = cache

  Debug.Log("TALENTGATE", "Scan complete for specID=%d: animosityNode=%s, risingFuryNode=%s",
    specID, tostring(cache.animosity), tostring(cache.risingFury))

  return true
end

---------------------------------------------------------------------------
-- Read activeRank for a cached node. Returns rank or 0 if node not found
-- or API returned nil.
---------------------------------------------------------------------------
local function ReadNodeRank(configID, nodeID)
  if not configID or not nodeID then return 0 end
  local info = C_Traits.GetNodeInfo(configID, nodeID)
  if not info then return 0 end
  return info.activeRank or 0
end

---------------------------------------------------------------------------
-- Compute the human-readable reason + detail strings from the state.
---------------------------------------------------------------------------
local function ComputeReason(s)
  if not s.apiAvailable then
    return "api_unavailable",
      "Talent API unavailable. /reload to retry."
  elseif not s.isEvoker then
    return "wrong_class",
      string.format("Class is %s — addon is Devastation-Evoker only.",
        tostring(s.classToken or "Unknown"))
  elseif not s.isDevastation then
    return "wrong_spec",
      "Wrong spec — switch to Devastation Evoker to enable."
  elseif s.risingFuryRank < 1 then
    return "no_rising_fury",
      "Rising Fury apex talent not specced — no buff to track."
  elseif not s.hasAnimosity then
    return "no_animosity",
      "Animosity not specced — alerts at threshold ≥4 cannot fire (max 3 stacks)."
  else
    return "ready",
      string.format("Ready — Rising Fury rank %d, Animosity active.", s.risingFuryRank)
  end
end

---------------------------------------------------------------------------
-- Build a state snapshot. Read class, spec, then traits. Sets apiAvailable
-- based on whether traits API returned usable data.
---------------------------------------------------------------------------
local function ReadState()
  local s = {
    classToken     = nil,
    specID         = nil,
    isEvoker       = false,
    isDevastation  = false,
    risingFuryRank = 0,
    hasAnimosity   = false,
    apiAvailable   = true,
    usable         = false,
    reason         = "unknown",
    detail         = "",
  }

  -- Class detection (always works, even before login finishes hydrating)
  local _, classToken = UnitClass("player")
  s.classToken = classToken
  s.isEvoker = (classToken == EVOKER_CLASS_TOKEN)

  -- Non-Evoker classes: skip all further evaluation. Talent API isn't
  -- relevant.
  if not s.isEvoker then
    s.reason, s.detail = ComputeReason(s)
    return s
  end

  -- Spec detection. Returns nil for sub-spec-unlock characters.
  local specIndex = GetSpecialization()
  if specIndex then
    local specID = GetSpecializationInfo(specIndex)
    s.specID = specID
    s.isDevastation = (specID == DEVASTATION_SPEC_ID)
  end

  -- Non-Devastation specs: also skip talent evaluation. The required
  -- nodes don't exist on Pres/Aug trees.
  if not s.isDevastation then
    s.reason, s.detail = ComputeReason(s)
    return s
  end

  -- Devastation: read traits API. This is the failure-prone path.
  local configID = C_ClassTalents and C_ClassTalents.GetActiveConfigID
                   and C_ClassTalents.GetActiveConfigID() or nil
  if not configID then
    LogVerbose("ReadState: GetActiveConfigID returned nil")
    s.apiAvailable = false
    s.reason, s.detail = ComputeReason(s)
    return s
  end

  local scanned = ScanForNodes(configID, s.specID)
  if not scanned then
    s.apiAvailable = false
    s.reason, s.detail = ComputeReason(s)
    return s
  end

  local cache = nodeCache[s.specID]
  s.risingFuryRank = ReadNodeRank(configID, cache.risingFury)
  s.hasAnimosity   = ReadNodeRank(configID, cache.animosity) > 0

  s.usable = (s.isDevastation and s.risingFuryRank >= 1 and s.apiAvailable)
  s.reason, s.detail = ComputeReason(s)

  LogVerbose("ReadState: class=%s, spec=%s, RF=%d, Anim=%s, usable=%s, reason=%s",
    tostring(s.classToken), tostring(s.specID), s.risingFuryRank,
    tostring(s.hasAnimosity), tostring(s.usable), s.reason)

  return s
end

---------------------------------------------------------------------------
-- Compare two state snapshots. Returns true when anything user-visible
-- has changed (we suppress no-op transition emissions during a respec
-- session where TRAIT_CONFIG_UPDATED fires repeatedly with no net change).
---------------------------------------------------------------------------
local function StateDiffers(prev, next)
  if not prev then return true end
  return prev.classToken     ~= next.classToken
      or prev.specID         ~= next.specID
      or prev.isEvoker       ~= next.isEvoker
      or prev.isDevastation  ~= next.isDevastation
      or prev.risingFuryRank ~= next.risingFuryRank
      or prev.hasAnimosity   ~= next.hasAnimosity
      or prev.apiAvailable   ~= next.apiAvailable
      or prev.usable         ~= next.usable
end

---------------------------------------------------------------------------
-- Activate or deactivate the watcher based on usable.
---------------------------------------------------------------------------
local function ApplyActivation()
  local W = ApexFury.Watcher
  if not (W and W.Activate and W.Deactivate) then
    Debug.Warn("TALENTGATE", "Watcher.Activate/Deactivate unavailable — skipping activation")
    return
  end

  if current.usable then
    if not (W.IsActive and W.IsActive()) then
      Debug.Log("TALENTGATE", "Activating watcher (usable=true, reason=%s)", current.reason)
      W.Activate()
    end
  else
    if W.IsActive and W.IsActive() then
      Debug.Log("TALENTGATE", "Deactivating watcher (usable=false, reason=%s)", current.reason)
      W.Deactivate()
    end
  end
end

---------------------------------------------------------------------------
-- Color codes used in chat output. Two patterns:
--   * Negative state: red key phrase + cyan explanation
--   * Positive state: green key phrase + cyan explanation
-- Plain ASCII only — WoW's chat font (Friz Quadrata) doesn't have most
-- unicode glyphs (⚠ ✓ ✗ render as boxes).
---------------------------------------------------------------------------
local C_CYAN  = "|cFF00CCFF"
local C_RED   = "|cFFFF4C4C"
local C_AMBER = "|cFFFFAA00"
local C_GREEN = "|cFF55FF55"
local C_END   = "|r"

---------------------------------------------------------------------------
-- Format helpers — keep call sites readable. Three severity levels:
--   * Bad  (red)   — addon won't work in this state
--   * Warn (amber) — addon works but degraded (some feature lost)
--   * Good (green) — positive transition
---------------------------------------------------------------------------
local function Bad(key, body)
  Say(C_RED .. key .. C_END .. " " .. C_CYAN .. body .. C_END)
end

local function Warn(key, body)
  Say(C_AMBER .. key .. C_END .. " " .. C_CYAN .. body .. C_END)
end

local function Good(key, body)
  if body and body ~= "" then
    Say(C_GREEN .. key .. C_END .. " " .. C_CYAN .. body .. C_END)
  else
    Say(C_GREEN .. key .. C_END)
  end
end

---------------------------------------------------------------------------
-- Emit chat messages based on the state transition. Returns nothing.
---------------------------------------------------------------------------
local function EmitTransition(prev, next, isInitial)
  -- Initial login emit: speak once, regardless of state — the user may have
  -- switched characters or installed mid-session. After the first emit,
  -- subsequent calls only speak on actual transitions.
  if isInitial then
    if next.reason == "wrong_class" then
      Bad("Inactive",
        string.format("— class is %s, addon is Devastation Evoker only.",
          tostring(next.classToken or "Unknown")))
    elseif next.reason == "wrong_spec" then
      Bad("Inactive",
        "— wrong spec, switch to Devastation Evoker to enable.")
    elseif next.reason == "no_rising_fury" then
      Bad("Rising Fury not specced",
        "— no buff to track.")
    elseif next.reason == "no_animosity" then
      local threshold = Config.Get(Config.Options.THRESHOLD)
      if threshold and threshold >= 4 then
        Bad("Animosity not specced",
          string.format("— alerts at threshold %d cannot fire (max 3 stacks).", threshold))
      else
        Bad("Animosity not specced",
          "— alerts above 3 stacks impossible.")
      end
    elseif next.reason == "api_unavailable" then
      Bad("Talent API unavailable",
        "— addon disabled. /reload to retry.")
    end
    -- "ready" is silent at login — happy path doesn't need announcing
    return
  end

  -- Transition emits — only when something user-visible flipped.
  if not prev then return end

  -- Spec change
  if prev.specID ~= next.specID then
    if next.isDevastation then
      Good("Devastation detected", "— re-evaluating talents...")
    elseif prev.isDevastation then
      Bad("Inactive", "— left Devastation spec.")
    end
  end

  -- API availability change
  if prev.apiAvailable ~= next.apiAvailable then
    if next.apiAvailable then
      Good("Talent API recovered.", "")
    else
      Bad("Talent API unavailable", "— addon disabled.")
    end
  end

  -- Rising Fury rank changes (only meaningful on Devastation)
  if next.isDevastation and prev.risingFuryRank ~= next.risingFuryRank then
    if next.risingFuryRank == 0 and prev.risingFuryRank > 0 then
      Bad("Rising Fury untalented", "— no buff to track.")
    elseif next.risingFuryRank > 0 and prev.risingFuryRank == 0 then
      Good("Rising Fury detected",
        string.format("(rank %d).", next.risingFuryRank))
    elseif next.risingFuryRank < 3 and prev.risingFuryRank == 3 then
      Warn("Rising Fury rank reduced",
        "— alerts still fire during Dragonrage. Risen Fury post-DR linger phase requires rank 3.")
    elseif next.risingFuryRank == 3 and prev.risingFuryRank < 3 then
      Good("Rising Fury at max rank",
        "— Risen Fury post-DR linger phase active.")
    end
  end

  -- Animosity changes (only meaningful on Devastation with Rising Fury)
  if next.isDevastation and next.risingFuryRank >= 1
     and prev.hasAnimosity ~= next.hasAnimosity then
    if next.hasAnimosity then
      Good("Animosity detected", "— full stack range available.")
    else
      local threshold = Config.Get(Config.Options.THRESHOLD)
      if threshold and threshold >= 4 then
        Bad("Animosity untalented",
          string.format("— alerts at threshold %d will be suppressed (max 3 stacks).",
            threshold))
      else
        Bad("Animosity untalented",
          "— alerts above 3 stacks impossible.")
      end
    end
  end
end

---------------------------------------------------------------------------
-- Snapshot log line — emitted after every evaluation. Mirrors the Config
-- snapshot pattern so log dumps always show current talent state.
---------------------------------------------------------------------------
local function LogSnapshot()
  Debug.Log("TALENTGATE",
    "Snapshot: class=%s, spec=%s(%s), RF=rank%d, Animosity=%s, apiAvailable=%s, usable=%s, reason=%s",
    tostring(current.classToken),
    tostring(current.specID),
    current.isDevastation and "Devastation" or "other",
    current.risingFuryRank,
    tostring(current.hasAnimosity),
    tostring(current.apiAvailable),
    tostring(current.usable),
    current.reason)
end

---------------------------------------------------------------------------
-- Run a full evaluation. Updates `current`, applies activation, emits
-- transition chat (unless silent=true), schedules an API retry if needed.
---------------------------------------------------------------------------
local function Evaluate(opts)
  opts = opts or {}
  local prev = previousEmittedState
  local next = ReadState()

  -- API unavailable during traits read? Schedule a single retry.
  if next.isEvoker and next.isDevastation and not next.apiAvailable
     and not opts.isRetry then
    LogVerbose("API unavailable on first read — scheduling retry in %.1fs", API_RETRY_SEC)
    pendingApiRetryID = pendingApiRetryID + 1
    local retryGen = pendingApiRetryID
    C_Timer.After(API_RETRY_SEC, function()
      if retryGen ~= pendingApiRetryID then return end  -- superseded
      LogVerbose("API retry firing")
      Evaluate({ isRetry = true, isInitial = opts.isInitial })
    end)
    -- Don't update current/emit yet — wait for retry. Falls through if
    -- retry also fails: the retry will set apiAvailable=false and emit.
    return
  end

  -- Commit new state
  current = next
  ApplyActivation()
  LogSnapshot()

  -- Emission gating: initial login always speaks; subsequent calls only on
  -- actual differences (so respec-spam debounces don't print 12 lines).
  local shouldEmit = opts.isInitial or StateDiffers(prev, next)
  if shouldEmit and not opts.silent then
    EmitTransition(prev, next, opts.isInitial)
  end

  if shouldEmit then
    previousEmittedState = next
  end
end

---------------------------------------------------------------------------
-- Schedule a debounced re-evaluation. Multiple TRAIT_CONFIG_UPDATED events
-- during a respec coalesce into a single eval.
---------------------------------------------------------------------------
local function ScheduleDebouncedEval(reason)
  pendingDebounceID = pendingDebounceID + 1
  local gen = pendingDebounceID
  LogVerbose("Debounced eval scheduled (%s, gen=%d, delay=%.2fs)",
    tostring(reason), gen, TRAIT_DEBOUNCE_SEC)
  C_Timer.After(TRAIT_DEBOUNCE_SEC, function()
    if gen ~= pendingDebounceID then
      LogVerbose("Debounced eval gen=%d superseded — skipping", gen)
      return
    end
    LogVerbose("Debounced eval gen=%d firing", gen)

    -- Spec changes and loadout swaps invalidate the node cache (different
    -- configID, possibly different node IDs). Trait-config updates within
    -- the same spec re-use the cache (same configID, only rank changes).
    if reason == "PLAYER_SPECIALIZATION_CHANGED"
       or reason == "ACTIVE_TALENT_GROUP_CHANGED" then
      nodeCache = {}
    end

    Evaluate({ silent = false })
  end)
end

---------------------------------------------------------------------------
-- Event handler
---------------------------------------------------------------------------
local function OnEvent(_, event, ...)
  if event == "PLAYER_LOGIN" then
    Debug.Log("TALENTGATE", "PLAYER_LOGIN — initial evaluation")
    -- Slight delay: traits API isn't always hydrated immediately on LOGIN.
    -- ReadState handles the nil case via the retry path, but starting
    -- one tick later avoids a guaranteed-redundant first read.
    C_Timer.After(0.1, function()
      Evaluate({ isInitial = true })
    end)

  elseif event == "PLAYER_ENTERING_WORLD" then
    -- Zone change. State usually unchanged; silent re-eval but emit on
    -- actual transitions.
    LogVerbose("PLAYER_ENTERING_WORLD — silent re-evaluation")
    Evaluate({})

  elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
    Debug.Log("TALENTGATE", "PLAYER_SPECIALIZATION_CHANGED — debounced re-eval")
    ScheduleDebouncedEval(event)

  elseif event == "ACTIVE_TALENT_GROUP_CHANGED" then
    Debug.Log("TALENTGATE", "ACTIVE_TALENT_GROUP_CHANGED — debounced re-eval")
    ScheduleDebouncedEval(event)

  elseif event == "TRAIT_CONFIG_UPDATED" then
    LogVerbose("TRAIT_CONFIG_UPDATED — debounced re-eval")
    ScheduleDebouncedEval(event)
  end
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------
function TalentGate.GetState()
  return current
end

function TalentGate.Start()
  if frame then return end  -- idempotent
  frame = CreateFrame("Frame")
  frame:RegisterEvent("PLAYER_LOGIN")
  frame:RegisterEvent("PLAYER_ENTERING_WORLD")
  frame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
  frame:RegisterEvent("ACTIVE_TALENT_GROUP_CHANGED")
  frame:RegisterEvent("TRAIT_CONFIG_UPDATED")
  frame:SetScript("OnEvent", OnEvent)
  Debug.Log("TALENTGATE", "Started")

  -- If we're being started AFTER PLAYER_LOGIN already fired (e.g. addon
  -- reloaded), evaluate immediately so the watcher activates without
  -- waiting for the next zone change.
  if IsLoggedIn and IsLoggedIn() then
    C_Timer.After(0.1, function()
      Evaluate({ isInitial = true })
    end)
  end
end
