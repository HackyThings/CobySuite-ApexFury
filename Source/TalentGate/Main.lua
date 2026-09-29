-------------------------------------------------------------------------------
-- ApexFury TalentGate: class/spec/talent prerequisite detection
--
-- Why this exists:
--   ApexFury alerts on Rising Fury reaching N stacks during Dragonrage. The
--   underlying mechanic is exclusive to Devastation Evoker, and even on Devo
--   it requires specific talents to be useful:
--
--     * Class must be Evoker (Dragonrage doesn't exist on other classes)
--     * Spec must be Devastation (1467): Pres/Aug Evokers have no Dragonrage
--     * Rising Fury talent must be at rank ≥1: without it, the buff this
--       addon tracks doesn't exist at all
--     * Animosity is needed for threshold ≥4: unextended DR (18s) only
--       delivers 3 stacks before the buff expires
--
--   This module evaluates those conditions, activates/deactivates the
--   Watcher accordingly (so we don't waste UNIT_SPELLCAST events on a Pres
--   healer raid), and emits chat warnings on state transitions.
--
-- Design:
--   1. Always-registered events: PLAYER_LOGIN, PLAYER_ENTERING_WORLD,
--      PLAYER_SPECIALIZATION_CHANGED, ACTIVE_TALENT_GROUP_CHANGED,
--      TRAIT_CONFIG_UPDATED. Cheap, low-frequency.
--   2. PLAYER_LOGIN does the initial evaluation + emit (speaks once unless
--      the state is "ready", which is silent).
--      PLAYER_ENTERING_WORLD silently re-evaluates (zone changes shouldn't
--      spam chat) but emits on actual state transitions.
--   3. The three talent events are debounced 0.5s (TRAIT_CONFIG_UPDATED
--      fires repeatedly while the user drags talent points around); we
--      evaluate once after they settle. A spec or talent-group change
--      anywhere in the burst sets a sticky flag, and the burst's evaluation
--      wipes the node cache first, even when the burst's last event was a
--      TRAIT_CONFIG_UPDATED.
--   4. Node IDs are found by walking the active config's trees for entries
--      whose definition spellID (or English name) matches Rising Fury or
--      Animosity. A found node ID is cached under "specID:configID" and kept
--      until a spec or talent-group change wipes the cache. A target that
--      was not found is never cached: every evaluation walks the trees again
--      for whatever is still missing. The traits API may return nil at any
--      level while talent data loads (tree nodes, node, entry, definition);
--      the walk skips those and counts them per level in a verbose log.
--   5. Rising Fury not found, or no config yet, means talent data is still
--      loading (apiAvailable=false): the state is left as it was and the
--      evaluation is retried after 1, 2 and 4 seconds, then committed with
--      one chat message. A later talent event walks the trees again, so the
--      gate recovers without a spec change or /reload. Animosity not found
--      reads as unknown (hasAnimosity=nil): the state commits at once, the
--      duration model assumes Animosity, no "untalented" message is printed,
--      and the same retries keep looking. A node found at rank 0 is a real
--      negative and is never retried.
--   6. TalentGate._test gives the in-game suite fake traits (class, spec and
--      tree), fake timers, the walk counter, the event handler and a
--      debounce flush. Nothing there writes a Blizzard global.
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
-- only: we log loudly if we have to fall back to this.
local RISING_FURY_NAME_EN = "Rising Fury"
local ANIMOSITY_NAME_EN   = "Animosity"

local TRAIT_DEBOUNCE_SEC = 0.5
local RETRY_DELAYS       = { 1, 2, 4 }   -- seconds before each retry while talent data is incomplete

---------------------------------------------------------------------------
-- Internal state
---------------------------------------------------------------------------
local frame

local function NewState()
  return {
    classToken     = nil,
    specID         = nil,
    isEvoker       = false,
    isDevastation  = false,
    risingFuryRank = 0,
    hasAnimosity   = false,    -- nil = Animosity not found in the tree yet (unknown)
    apiAvailable   = true,     -- false = talent data still loading (Rising Fury not found)
    usable         = false,    -- isDevastation AND risingFuryRank>=1 AND apiAvailable
    reason         = "unknown",
    -- Shown by /af status and the overlay until the first evaluation commits
    -- (talent data can take a few seconds after login)
    detail         = "Checking talents...",
  }
end

local current = NewState()
local previousEmittedState  -- snapshot used to detect actual transitions
local nodeCache = {}        -- ["specID:configID"] = { animosity = nodeID, risingFury = nodeID }, found IDs only
local retryGeneration = 0   -- bumped by every fresh evaluation; older retry chains stop
local initialPending = false  -- a PLAYER_LOGIN evaluation has not committed yet
local invalidatePending = false  -- a spec or talent-group change is in the debounced burst
local scanCount = 0         -- tree walks started, for the suite

---------------------------------------------------------------------------
-- Game data and timers, swappable by the test suite (TalentGate._test).
-- RealTraits reads the client; a fake supplies the same functions for a
-- synthetic character and tree.
---------------------------------------------------------------------------
local RealTraits = {
  GetClassToken = function()
    local _, classToken = UnitClass("player")
    return classToken
  end,
  -- Returns nil for sub-spec-unlock characters. C_SpecializationInfo is the
  -- current API; the bare GetSpecialization / GetSpecializationInfo globals
  -- have been deprecated since 11.2.0 and only survive through Blizzard's
  -- compatibility shim.
  GetSpecID = function()
    local specIndex = C_SpecializationInfo.GetSpecialization()
    if not specIndex then return nil end
    return (C_SpecializationInfo.GetSpecializationInfo(specIndex))
  end,
  GetActiveConfigID = function()
    return C_ClassTalents and C_ClassTalents.GetActiveConfigID
           and C_ClassTalents.GetActiveConfigID() or nil
  end,
  GetConfigInfo = function(configID) return C_Traits.GetConfigInfo(configID) end,
  GetTreeNodes = function(treeID) return C_Traits.GetTreeNodes(treeID) end,
  GetNodeInfo = function(configID, nodeID) return C_Traits.GetNodeInfo(configID, nodeID) end,
  GetEntryInfo = function(configID, entryID) return C_Traits.GetEntryInfo(configID, entryID) end,
  GetDefinitionInfo = function(definitionID) return C_Traits.GetDefinitionInfo(definitionID) end,
  -- C_Spell.GetSpellName is the safe way to read names without taint
  GetSpellName = function(spellID)
    return C_Spell.GetSpellName and C_Spell.GetSpellName(spellID) or nil
  end,
}

local traits = RealTraits
local testTimers   -- { After } with C_Timer's signature, or nil

local function After(seconds, fn)
  if testTimers then return testTimers.After(seconds, fn) end
  return C_Timer.After(seconds, fn)
end

---------------------------------------------------------------------------
-- Chat messaging: uses the addon's branded prefix
---------------------------------------------------------------------------
local function Say(msg)
  if ApexFury.Message then ApexFury.Message(msg) end
end

---------------------------------------------------------------------------
-- Verbose log helper: only emits when Config.VERBOSE is on
---------------------------------------------------------------------------
local function LogVerbose(fmt, ...)
  if Config and Config.Get and Config.Options and Config.Options.VERBOSE
     and Config.Get(Config.Options.VERBOSE) then
    Debug.Log("TALENTGATE", fmt, ...)
  end
end

local function CacheKey(specID, configID)
  return tostring(specID) .. ":" .. tostring(configID)
end

---------------------------------------------------------------------------
-- Match one trait definition against the targets still missing from the
-- cache entry. A found node ID is never overwritten.
---------------------------------------------------------------------------
local function MatchDefinition(cache, nodeID, spellID)
  if not spellID then return end
  if not cache.animosity and spellID == ANIMOSITY_SPELL_ID then
    cache.animosity = nodeID
    return
  end
  if not cache.risingFury and spellID == RISING_FURY_AURA_ID then
    cache.risingFury = nodeID
    return
  end

  -- Localized name fallback, for a target the spellID match has not found
  local nameOk, name = pcall(traits.GetSpellName, spellID)
  if nameOk and type(name) == "string" then
    if not cache.animosity and name == ANIMOSITY_NAME_EN then
      cache.animosity = nodeID
      Debug.Log("TALENTGATE", "Animosity matched by name (spellID %s): talent ID may have changed",
        tostring(spellID))
    elseif not cache.risingFury and name == RISING_FURY_NAME_EN then
      cache.risingFury = nodeID
      Debug.Log("TALENTGATE", "Rising Fury matched by name (spellID %s): talent ID may have changed",
        tostring(spellID))
    end
  end
end

---------------------------------------------------------------------------
-- Find our target talent nodes in the active config's trees. The cache
-- entry for this spec and config holds only node IDs that were found; the
-- trees are walked again, for the missing targets only, until both are.
--
-- Returns the cache entry (either field may still be nil), or nil when the
-- config itself is not available yet.
---------------------------------------------------------------------------
local function ScanForNodes(configID, specID)
  if not configID or not specID then return nil end

  local key = CacheKey(specID, configID)
  local cache = nodeCache[key]
  if not cache then
    cache = {}
    nodeCache[key] = cache
  end
  if cache.animosity and cache.risingFury then return cache end

  scanCount = scanCount + 1
  local configInfo = traits.GetConfigInfo(configID)
  if not configInfo or not configInfo.treeIDs then
    LogVerbose("ScanForNodes: GetConfigInfo returned nil or no treeIDs (configID=%s)",
      tostring(configID))
    return nil
  end

  -- nil answers per level while talent data loads, for the verbose log
  local nilTrees, nilNodes, nilEntries, nilDefinitions = 0, 0, 0, 0

  for _, treeID in ipairs(configInfo.treeIDs) do
    if cache.animosity and cache.risingFury then break end
    local nodes = traits.GetTreeNodes(treeID)
    if not nodes then
      nilTrees = nilTrees + 1
    else
      for _, nodeID in ipairs(nodes) do
        if cache.animosity and cache.risingFury then break end
        local nodeInfo = traits.GetNodeInfo(configID, nodeID)
        if not (nodeInfo and nodeInfo.entryIDs) then
          nilNodes = nilNodes + 1
        else
          for _, entryID in ipairs(nodeInfo.entryIDs) do
            local entry = traits.GetEntryInfo(configID, entryID)
            if not (entry and entry.definitionID) then
              nilEntries = nilEntries + 1
            else
              local def = traits.GetDefinitionInfo(entry.definitionID)
              if not def then
                nilDefinitions = nilDefinitions + 1
              else
                MatchDefinition(cache, nodeID, def.spellID)
              end
            end
          end
        end
      end
    end
  end

  LogVerbose("ScanForNodes (%s): nil answers trees=%d nodes=%d entries=%d definitions=%d",
    key, nilTrees, nilNodes, nilEntries, nilDefinitions)
  Debug.Log("TALENTGATE", "Scan for specID=%s configID=%s: animosityNode=%s, risingFuryNode=%s",
    tostring(specID), tostring(configID), tostring(cache.animosity), tostring(cache.risingFury))

  return cache
end

---------------------------------------------------------------------------
-- Read activeRank for a cached node. Returns the rank, or nil when the API
-- has no node info right now (talent data loading).
---------------------------------------------------------------------------
local function ReadNodeRank(configID, nodeID)
  if not configID or not nodeID then return nil end
  local info = traits.GetNodeInfo(configID, nodeID)
  if not info then return nil end
  return info.activeRank or 0
end

---------------------------------------------------------------------------
-- Compute the human-readable reason + detail strings from the state.
---------------------------------------------------------------------------
local function ComputeReason(s)
  if not s.apiAvailable then
    return "api_unavailable",
      "Talent data still loading. Changing talents or /reload checks again."
  elseif not s.isEvoker then
    return "wrong_class",
      string.format("Class is %s: addon is Devastation-Evoker only.",
        tostring(s.classToken or "Unknown"))
  elseif not s.isDevastation then
    return "wrong_spec",
      "Wrong spec: switch to Devastation Evoker to enable."
  elseif s.risingFuryRank < 1 then
    return "no_rising_fury",
      "Rising Fury apex talent not specced: no buff to track."
  elseif s.hasAnimosity == false then
    return "no_animosity",
      "Animosity not specced: alerts at threshold ≥4 cannot fire (max 3 stacks)."
  elseif s.hasAnimosity == nil then
    return "ready",
      string.format("Ready: Rising Fury rank %d, Animosity not found yet (assumed).", s.risingFuryRank)
  else
    return "ready",
      string.format("Ready: Rising Fury rank %d, Animosity active.", s.risingFuryRank)
  end
end

---------------------------------------------------------------------------
-- Build a state snapshot. Read class, spec, then traits.
--
-- Returns the state and whether talent data was incomplete (a target node
-- not found, or no node info for it): apiAvailable=false when Rising Fury
-- is the missing one or there is no config yet, hasAnimosity=nil when only
-- Animosity is. Evaluate retries incomplete reads.
---------------------------------------------------------------------------
local function ReadState()
  local s = NewState()

  -- Class detection (always works, even before login finishes hydrating)
  s.classToken = traits.GetClassToken()
  s.isEvoker = (s.classToken == EVOKER_CLASS_TOKEN)

  -- Non-Evoker classes: skip all further evaluation. Talent API isn't
  -- relevant.
  if not s.isEvoker then
    s.reason, s.detail = ComputeReason(s)
    return s, false
  end

  -- Spec detection (nil for sub-spec-unlock characters)
  s.specID = traits.GetSpecID()
  s.isDevastation = (s.specID == DEVASTATION_SPEC_ID)

  -- Non-Devastation specs: also skip talent evaluation. The required
  -- nodes don't exist on Pres/Aug trees.
  if not s.isDevastation then
    s.reason, s.detail = ComputeReason(s)
    return s, false
  end

  -- Devastation: read traits API. This is the failure-prone path.
  local configID = traits.GetActiveConfigID()
  local cache = configID and ScanForNodes(configID, s.specID) or nil
  local rfRank = cache and ReadNodeRank(configID, cache.risingFury)
  if not rfRank then
    LogVerbose("ReadState: talent data incomplete (configID=%s, config=%s, risingFuryNode=%s)",
      tostring(configID), tostring(cache ~= nil), tostring(cache and cache.risingFury))
    s.apiAvailable = false
    s.hasAnimosity = nil
    s.reason, s.detail = ComputeReason(s)
    return s, true
  end

  s.risingFuryRank = rfRank
  local animosityRank = ReadNodeRank(configID, cache.animosity)
  if animosityRank then
    s.hasAnimosity = animosityRank > 0
  else
    s.hasAnimosity = nil   -- unknown: the duration model assumes Animosity
  end

  s.usable = (s.isDevastation and s.risingFuryRank >= 1 and s.apiAvailable)
  s.reason, s.detail = ComputeReason(s)

  LogVerbose("ReadState: class=%s, spec=%s, RF=%d, Anim=%s, usable=%s, reason=%s",
    tostring(s.classToken), tostring(s.specID), s.risingFuryRank,
    tostring(s.hasAnimosity), tostring(s.usable), s.reason)

  return s, s.hasAnimosity == nil
end

---------------------------------------------------------------------------
-- Compare two state snapshots. Returns true when anything user-visible
-- has changed (we suppress no-op transition emissions during a respec
-- session where TRAIT_CONFIG_UPDATED fires repeatedly with no net change).
---------------------------------------------------------------------------
local function StateDiffers(prev, next)
  if not prev then return true end
  if prev.classToken    ~= next.classToken
     or prev.specID        ~= next.specID
     or prev.isEvoker      ~= next.isEvoker
     or prev.isDevastation ~= next.isDevastation
     or prev.apiAvailable  ~= next.apiAvailable
     or prev.usable        ~= next.usable then
    return true
  end
  -- While talent data is loading the rank and Animosity readings are
  -- placeholders, not changes
  if not next.apiAvailable then return false end
  if prev.risingFuryRank ~= next.risingFuryRank then return true end
  -- Animosity becoming unknown is not a change; becoming known is
  return next.hasAnimosity ~= nil and prev.hasAnimosity ~= next.hasAnimosity
end

---------------------------------------------------------------------------
-- Activate or deactivate the watcher based on usable.
---------------------------------------------------------------------------
local function ApplyActivation()
  local W = ApexFury.Watcher
  if not (W and W.Activate and W.Deactivate) then
    Debug.Warn("TALENTGATE", "Watcher.Activate/Deactivate unavailable: skipping activation")
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
-- Plain ASCII only: WoW's chat font (Friz Quadrata) doesn't have most
-- unicode glyphs (⚠ ✓ ✗ render as boxes).
---------------------------------------------------------------------------
local C_CYAN  = "|cFF00CCFF"
local C_RED   = "|cFFFF4C4C"
local C_AMBER = "|cFFFFAA00"
local C_GREEN = "|cFF55FF55"
local C_END   = "|r"

---------------------------------------------------------------------------
-- Format helpers: keep call sites readable. Three severity levels:
--   * Bad  (red): addon won't work in this state
--   * Warn (amber): addon works but degraded (some feature lost)
--   * Good (green): positive transition
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
--
-- Unknown talent readings say nothing: no rank or Animosity message while
-- talent data is loading (apiAvailable=false), and no Animosity message
-- while its node has not been found (hasAnimosity=nil).
---------------------------------------------------------------------------
local TALENT_DATA_KEY  = "Talent data not loaded."
local TALENT_DATA_BODY = "ApexFury stays off until it loads. Changing talents or /reload checks again."

local EmitTransition
function EmitTransition(prev, next, isInitial)
  -- Initial login emit: speak once for any state but "ready" (the user may
  -- have switched characters or installed mid-session). After the first
  -- emit, subsequent calls only speak on actual transitions.
  if isInitial then
    if next.reason == "wrong_class" then
      Bad("Inactive:",
        string.format("class is %s, addon is Devastation Evoker only.",
          tostring(next.classToken or "Unknown")))
    elseif next.reason == "wrong_spec" then
      Bad("Inactive:",
        "wrong spec, switch to Devastation Evoker to enable.")
    elseif next.reason == "no_rising_fury" then
      Bad("Rising Fury not specced:",
        "no buff to track.")
    elseif next.reason == "no_animosity" then
      local threshold = Config.Get(Config.Options.THRESHOLD)
      if threshold and threshold >= 4 then
        Bad("Animosity not specced:",
          string.format("alerts at threshold %d cannot fire (max 3 stacks).", threshold))
      else
        Bad("Animosity not specced:",
          "alerts above 3 stacks impossible.")
      end
    elseif next.reason == "api_unavailable" then
      Bad(TALENT_DATA_KEY, TALENT_DATA_BODY)
    end
    -- "ready" is silent at login: happy path doesn't need announcing
    return
  end

  -- Transition emits: only when something user-visible flipped.
  if not prev then return end

  -- Spec change
  if prev.specID ~= next.specID then
    if next.isDevastation then
      Good("Devastation detected:", "re-evaluating talents...")
    elseif prev.isDevastation then
      Bad("Inactive:", "left Devastation spec.")
    end
  end

  -- Talent data availability change. Readings that come with recovered data
  -- are new rather than changed, so they are reported the way a login
  -- reports them.
  if prev.apiAvailable ~= next.apiAvailable then
    if not next.apiAvailable then
      Bad(TALENT_DATA_KEY, TALENT_DATA_BODY)
    elseif next.isDevastation then
      Good("Talent data loaded.", "")
      EmitTransition(nil, next, true)
    end
    return
  end

  -- Rising Fury rank changes (only meaningful on Devastation)
  if next.isDevastation and prev.risingFuryRank ~= next.risingFuryRank then
    if next.risingFuryRank == 0 and prev.risingFuryRank > 0 then
      Bad("Rising Fury untalented:", "no buff to track.")
    elseif next.risingFuryRank > 0 and prev.risingFuryRank == 0 then
      Good("Rising Fury detected",
        string.format("(rank %d).", next.risingFuryRank))
    elseif next.risingFuryRank < 3 and prev.risingFuryRank == 3 then
      Warn("Rising Fury rank reduced:",
        "alerts still fire during Dragonrage. The post-Dragonrage Rising Fury linger requires rank 3.")
    elseif next.risingFuryRank == 3 and prev.risingFuryRank < 3 then
      Good("Rising Fury at max rank:",
        "post-Dragonrage Rising Fury linger active (4s per stack).")
    end
  end

  -- Animosity changes (only meaningful on Devastation with Rising Fury).
  -- Found after being unknown: silent when talented (the model already
  -- assumed it), "not specced" when not.
  if next.isDevastation and next.risingFuryRank >= 1
     and next.hasAnimosity ~= nil and prev.hasAnimosity ~= next.hasAnimosity then
    if next.hasAnimosity then
      if prev.hasAnimosity == false then
        Good("Animosity detected.", "Full stack range available.")
      end
    else
      local key = prev.hasAnimosity == nil and "Animosity not specced" or "Animosity untalented"
      local threshold = Config.Get(Config.Options.THRESHOLD)
      if threshold and threshold >= 4 then
        Bad(key .. ":",
          string.format("alerts at threshold %d will be suppressed (max 3 stacks).",
            threshold))
      else
        Bad(key .. ":",
          "alerts above 3 stacks impossible.")
      end
    end
  end
end

---------------------------------------------------------------------------
-- Snapshot log line: emitted after every evaluation. Mirrors the Config
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
-- Run a full evaluation. Updates `current`, applies activation and emits
-- transition chat (unless silent=true).
--
-- Incomplete talent data (ReadState's second result) is retried after 1, 2
-- and 4 seconds. While Rising Fury is missing the state is not committed
-- until the last retry, which commits "talent data not loaded" and says so
-- once; with only Animosity missing the state commits at once and the
-- retries keep looking. A fresh evaluation (attempt 0) owns the retries from
-- then on, and a login evaluation that has not committed yet keeps its
-- first-login message through the evaluations that replace it.
---------------------------------------------------------------------------
local function Evaluate(opts)
  opts = opts or {}
  local attempt = opts.attempt or 0
  if attempt == 0 then
    retryGeneration = retryGeneration + 1
  end
  if opts.isInitial then initialPending = true end

  local prev = previousEmittedState
  local next, incomplete = ReadState()

  if incomplete then
    local missing = next.apiAvailable and "Animosity not found" or "Rising Fury not found"
    if attempt < #RETRY_DELAYS then
      local delay = RETRY_DELAYS[attempt + 1]
      local generation = retryGeneration
      LogVerbose("Talent data incomplete (%s): retry %d of %d in %ds",
        missing, attempt + 1, #RETRY_DELAYS, delay)
      After(delay, function()
        if generation ~= retryGeneration then return end   -- a newer evaluation owns the retries
        Evaluate({ attempt = attempt + 1 })
      end)
      -- Rising Fury missing: keep the current state until a retry finds it
      if not next.apiAvailable then return end
    else
      Debug.Log("TALENTGATE", "Talent data still incomplete after %d retries (%s); no more retries until a talent event",
        #RETRY_DELAYS, missing)
    end
  end

  -- Commit new state
  local isInitial = initialPending
  initialPending = false
  current = next
  ApplyActivation()
  LogSnapshot()

  -- Emission gating: initial login always speaks; subsequent calls only on
  -- actual differences (so respec-spam debounces don't print 12 lines).
  local shouldEmit = isInitial or StateDiffers(prev, next)
  if shouldEmit and not opts.silent then
    EmitTransition(prev, next, isInitial)
  end

  if shouldEmit then
    previousEmittedState = next
  end
end

---------------------------------------------------------------------------
-- Schedule a debounced re-evaluation. Multiple TRAIT_CONFIG_UPDATED events
-- during a respec coalesce into a single eval: CobySuite.Utilities.Debounce
-- restarts the delay on every call and fires once with the last reason.
---------------------------------------------------------------------------
local debouncedEval = CobySuite_ApexFury.Utilities.Debounce(TRAIT_DEBOUNCE_SEC, function(reason)
  LogVerbose("Debounced eval firing (%s)", tostring(reason))

  -- Spec changes and loadout swaps invalidate the node cache (different
  -- configID, possibly different node IDs). The flag is sticky for the whole
  -- burst, because its last event is often a TRAIT_CONFIG_UPDATED, which on
  -- its own keeps the cache (same configID, only ranks change).
  if invalidatePending then
    invalidatePending = false
    nodeCache = {}
    LogVerbose("Node cache wiped (spec or talent group changed in this burst)")
  end

  Evaluate({ silent = false })
end)

local function ScheduleDebouncedEval(reason)
  if reason == "PLAYER_SPECIALIZATION_CHANGED"
     or reason == "ACTIVE_TALENT_GROUP_CHANGED" then
    invalidatePending = true
  end
  if debouncedEval:IsPending() then
    LogVerbose("Debounced eval superseded by %s", tostring(reason))
  end
  LogVerbose("Debounced eval scheduled (%s, delay=%.2fs)",
    tostring(reason), TRAIT_DEBOUNCE_SEC)
  debouncedEval:Call(reason)
end

---------------------------------------------------------------------------
-- Event handler
---------------------------------------------------------------------------
local function OnEvent(_, event, ...)
  if event == "PLAYER_LOGIN" then
    Debug.Log("TALENTGATE", "PLAYER_LOGIN: initial evaluation")
    -- Slight delay: traits API isn't always hydrated immediately on LOGIN.
    -- ReadState handles the nil case via the retry path, but starting
    -- one tick later avoids a guaranteed-redundant first read.
    After(0.1, function()
      Evaluate({ isInitial = true })
    end)

  elseif event == "PLAYER_ENTERING_WORLD" then
    -- Zone change. State usually unchanged; silent re-eval but emit on
    -- actual transitions.
    LogVerbose("PLAYER_ENTERING_WORLD: silent re-evaluation")
    Evaluate({})

  elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
    Debug.Log("TALENTGATE", "PLAYER_SPECIALIZATION_CHANGED: debounced re-eval")
    ScheduleDebouncedEval(event)

  elseif event == "ACTIVE_TALENT_GROUP_CHANGED" then
    Debug.Log("TALENTGATE", "ACTIVE_TALENT_GROUP_CHANGED: debounced re-eval")
    ScheduleDebouncedEval(event)

  elseif event == "TRAIT_CONFIG_UPDATED" then
    LogVerbose("TRAIT_CONFIG_UPDATED: debounced re-eval")
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
    After(0.1, function()
      Evaluate({ isInitial = true })
    end)
  end
end

---------------------------------------------------------------------------
-- Test seams for ApexFury's TalentGateSuite (Source/Tests). The suite swaps
-- in fake traits and timers, drives events and the debounce by hand, and
-- puts the module's state back afterwards. Nothing here writes a Blizzard
-- global.
---------------------------------------------------------------------------
TalentGate._test = {
  -- fake: GetClassToken, GetSpecID, GetActiveConfigID, GetConfigInfo,
  -- GetTreeNodes, GetNodeInfo, GetEntryInfo, GetDefinitionInfo,
  -- GetSpellName (RealTraits' shape); nil for the client
  SetTraits = function(fake) traits = fake or RealTraits end,
  -- { After } with C_Timer's signature, or nil
  SetTimers = function(timers) testTimers = timers end,
  GetScanCount = function() return scanCount end,
  GetCacheEntry = function(specID, configID) return nodeCache[CacheKey(specID, configID)] end,
  HandleEvent = function(event, ...) OnEvent(nil, event, ...) end,
  FlushDebounce = function() debouncedEval:Flush() end,
  Evaluate = Evaluate,

  -- The module's state, to put back with Restore after the suite
  Save = function()
    return {
      current = current,
      previous = previousEmittedState,
      cache = nodeCache,
      initialPending = initialPending,
      invalidatePending = invalidatePending,
      debouncePending = debouncedEval:IsPending(),
      debounceReason = invalidatePending and "ACTIVE_TALENT_GROUP_CHANGED" or "TRAIT_CONFIG_UPDATED",
    }
  end,
  Restore = function(saved)
    debouncedEval:Cancel()
    retryGeneration = retryGeneration + 1
    current = saved.current
    previousEmittedState = saved.previous
    nodeCache = saved.cache
    initialPending = saved.initialPending
    invalidatePending = saved.invalidatePending
    if saved.debouncePending then debouncedEval:Call(saved.debounceReason) end
  end,
  -- A module that has never evaluated: no state, cache, retries or burst
  Reset = function()
    debouncedEval:Cancel()
    retryGeneration = retryGeneration + 1
    current = NewState()
    previousEmittedState = nil
    nodeCache = {}
    initialPending = false
    invalidatePending = false
    scanCount = 0
  end,
}
