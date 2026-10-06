-------------------------------------------------------------------------------
-- CobySuite.Sound: unified sound catalog, resolution, and playback.
--
-- Consolidates the Blizzard SoundKit catalog and the LibSharedMedia (LSM)
-- registry into a single namespace consumer addons can browse, resolve,
-- and play against.
--
-- Storage formats (what consumers persist into their config):
--   number 8960              → Blizzard SoundKit ID  (PlaySound)
--   string "8960"            → SoundKit ID as string (PlaySound)
--   string "fdid:538903"     → Blizzard FileDataID   (PlaySoundFile); not in
--                              the catalog: a consumer picks it elsewhere and
--                              keeps its own label for LookupLabel
--   string "lsm:Glass Break" → LibSharedMedia entry  (PlaySoundFile via path)
--
-- Each entry exposed via Sound.GetEntries returns:
--   { label, value, source, pack, kind, raw, path,
--     _sortName, _sortSource, _sortKind }   ← pre-computed for fast sort
--
-- where:
--   label   string  display name (may contain |c color codes from LSM)
--   value   any     storage form for Config.Set (a SoundKit ID or "lsm:Name")
--   source  string  top-level source ("Blizzard"/"LibSharedMedia")
--   pack    string  sub-source: for Blizzard "UI"/"Voice"/"Combat"/"Item"/
--                   "Alert"/"Effect"; for LSM auto-derived from the addon
--                   folder name in the file path (e.g. "Astral", "Causese",
--                   "ElvUI"; "Other LSM" if path has no AddOns segment)
--   kind    string  "SoundKit"/"LSM"
--   raw     any     numeric ID or file path (whatever Play needs)
--   path    string  filesystem path when known (LSM), for tooltips
--
-- Source names (GetSourceList, GetSourceCount, GetSourceCounts) are
-- "Blizzard: <pack>" for each Blizzard pack with sounds, then the LSM pack
-- names, sorted, with "Other LSM" last. Their counts come from one snapshot
-- per catalog generation (one SOUNDKIT pass and one LSM pass), so a menu
-- that asks for every count on every open repeats no scan.
-------------------------------------------------------------------------------

CobySuite_ApexFury = CobySuite_ApexFury or {}
CobySuite_ApexFury.Sound = CobySuite_ApexFury.Sound or {}
local Sound = CobySuite_ApexFury.Sound

---------------------------------------------------------------------------
-- Source colors, used by the sound browser to color-code source pills,
-- keyed by an entry's source (an LSM entry by its pack). Hex color codes
-- (no |c prefix). Consumers that need decimal values can divide by 255.
---------------------------------------------------------------------------
Sound.SourceColors = {
  Blizzard          = "FFD200",
  LibSharedMedia    = "8AD4FF",
  Astral            = "A335EE",   -- matches Astral's own |c prefix
  Causese           = "FF7777",
  Other             = "AAAAAA",
}

---------------------------------------------------------------------------
-- SOUNDKIT exclusion: entries we never expose because they aren't
-- useful as alert sounds (music tracks, ambient soundscapes). Voice
-- clips ARE included as a separate pack so they can be browsed.
---------------------------------------------------------------------------
local NON_EFFECT_PREFIXES = {
  "MUSIC_", "MUS_", "ZONEMUSIC_", "BGM_",
  "AMB_", "AMBIENCE_", "AMBIENT_",
  "TIMEWALKING_BG_",
}

local NON_EFFECT_SUBSTRINGS = {
  "_MUSIC_", "_MUSIC", "MUSIC_",
  "_AMBIENCE", "_AMBIENT",
  "_BGSND",
  "ZONEMUSIC", "WALKMUSIC",
  "STINGER",                      -- musical stingers (long, dramatic)
}

local function IsExcluded(name)
  if type(name) ~= "string" then return true end
  for _, prefix in ipairs(NON_EFFECT_PREFIXES) do
    if name:sub(1, #prefix) == prefix then return true end
  end
  for _, sub in ipairs(NON_EFFECT_SUBSTRINGS) do
    if name:find(sub, 1, true) then return true end
  end
  return false
end

---------------------------------------------------------------------------
-- Blizzard sub-pack classification by name pattern
--
-- ~800 SOUNDKIT entries split into ~6 buckets so users don't drown in
-- one mega-list. Order matters: most specific category first; first
-- match wins.
---------------------------------------------------------------------------
local function ClassifyBlizzardName(name)
  if type(name) ~= "string" then return "Effect" end

  -- Voice (most specific). SOUNDKIT genuinely has very little voice
  -- content: boss/NPC speech is FileDataID-based, outside SOUNDKIT.
  -- VO_, VOX_ and NPC_ are anchored prefixes to avoid false positives;
  -- VOICEOVER, _SPEECH and _DIALOGUE match anywhere.
  if name:find("VOICEOVER", 1, true)
     or name:sub(1, 3) == "VO_"
     or name:sub(1, 4) == "VOX_"
     or name:find("_SPEECH", 1, true)
     or name:find("_DIALOGUE", 1, true)
     or name:sub(1, 4) == "NPC_"
  then
    return "Voice"
  end

  -- Item / economy: checked before UI so an item sound that also carries a
  -- UI marker (an IG_ or UI_ prefix, _CLICK, _POPUP) goes to Item.
  if name:find("AUCTION", 1, true)
     or name:find("ITEM_", 1, true)
     or name:find("_ITEM", 1, true)
     or name:find("BAG", 1, true)
     or name:find("LOOT", 1, true)
     or name:find("MAIL", 1, true)
     or name:find("VENDOR", 1, true)
     or name:find("PUTDOWN", 1, true)
     or name:find("PICKUP", 1, true)
     or name:find("INVENTORY", 1, true)
     or name:find("EQUIP", 1, true)
  then
    return "Item"
  end

  -- Combat: spells, abilities, casts, impacts, weapon hits
  if name:find("SPELL", 1, true)
     or name:find("ABILITY", 1, true)
     or name:find("ATTACK", 1, true)
     or name:find("COMBAT", 1, true)
     or name:find("_CAST_", 1, true)
     or name:find("_IMPACT", 1, true)
     or name:find("PARRY", 1, true)
     or name:find("DODGE", 1, true)
     or name:find("BLOCK_", 1, true)
     or name:find("CRITICAL", 1, true)
     or name:find("WEAPON", 1, true)
     or name:find("DAMAGE", 1, true)
     or name:find("BATTLE", 1, true)
     or name:find("DUEL", 1, true)
  then
    return "Combat"
  end

  -- System alerts: also before UI, so an alert name with an IG_ or UI_ prefix goes to Alert
  if name:find("ALARM", 1, true)
     or name:find("READY_CHECK", 1, true)
     or name:find("RAID_", 1, true)
     or name:find("LFG_", 1, true)
     or name:find("PVP_", 1, true)
     or name:find("MAP_", 1, true)
     or name:find("LEVELUP", 1, true)
     or name:find("ZONE", 1, true)
     or name:find("REWARD", 1, true)
     or name:find("ACHIEVEMENT", 1, true)
     or name:find("QUEST", 1, true)
  then
    return "Alert"
  end

  -- UI: interface clicks/popups/menus. Generic _OPEN/_CLOSE are not a marker:
  -- they overlap heavily with item/quest/auction sounds.
  if name:sub(1, 3) == "UI_"
     or name:sub(1, 3) == "IG_"
     or name:sub(1, 10) == "INTERFACE_"
     or name:sub(1, 5) == "MENU_"
     or name:sub(1, 9) == "TUTORIAL_"
     or name:find("_CLICK", 1, true)
     or name:find("_POPUP", 1, true)
  then
    return "UI"
  end

  return "Effect"
end

-- Iconic sounds not in SOUNDKIT global: explicit IDs needed.
local EXTRA_BLIZZARD_SOUNDS = {
  { id = 12889, label = "Raid Warning Horn",     pack = "Alert"  },
  { id = 12867, label = "LFG Reward",            pack = "Alert"  },
  { id = 17316, label = "Auto Quest Complete",   pack = "Alert"  },
  { id = 18019, label = "Loot Received (Personal)", pack = "Item" },
  { id = 1186,  label = "Loot Coin (Large)",     pack = "Item"   },
  { id = 1316,  label = "Loot Coin (Small)",     pack = "Item"   },
  { id = 7355,  label = "Put Down Ring",         pack = "Item"   },
  { id = 11466, label = "Bell Toll (Horde)",     pack = "Alert"  },
  { id = 11467, label = "Bell Toll (Alliance)",  pack = "Alert"  },
  { id = 8454,  label = "PvP Flag Capture",      pack = "Alert"  },
  { id = 8455,  label = "PvP Flag Pickup",       pack = "Alert"  },
  { id = 8458,  label = "PvP Flag Return",       pack = "Alert"  },
  { id = 3093,  label = "Click Chime",           pack = "UI"     },
  { id = 3175,  label = "Mail Sound",            pack = "Item"   },
  { id = 3408,  label = "Slot Click",            pack = "UI"     },
  { id = 3837,  label = "Cloth Item Pickup",     pack = "Item"   },
  { id = 3355,  label = "Fishing Hooked",        pack = "Effect" },
}

---------------------------------------------------------------------------
-- LSM pack classification
--
-- LSM doesn't expose which addon registered which sound, only the
-- (name, path) pair. So we parse the addon folder name out of the
-- path (every well-formed LSM sound path is under
-- Interface\AddOns\<FolderName>\...). Universal coverage: any pack
-- the user installs auto-categorizes by its folder name.
---------------------------------------------------------------------------
local function PrettifyPackName(folderName)
  if type(folderName) ~= "string" or folderName == "" then return "Other LSM" end
  local s = folderName
  -- Strip the conventional SharedMedia prefixes/suffixes so packs like
  -- SharedMedia_Causese show as "Causese" and AstralSharedMedia as "Astral".
  s = s:gsub("^SharedMedia[_%-]?", "")
  s = s:gsub("[_%-]?SharedMedia$", "")
  s = s:gsub("^[_%-]+", ""):gsub("[_%-]+$", "")
  if s == "" then return folderName end
  return s
end

local function ExtractPackFromPath(path)
  if type(path) ~= "string" then return nil end
  -- Match Interface\AddOns\<Folder>\... in any case / slash style
  return path:match("[Ii]nterface[\\/][Aa]dd[Oo]ns[\\/]([^\\/]+)")
end

local function ClassifyLSMPath(path)
  if type(path) ~= "string" then return "Other LSM" end
  local folder = ExtractPackFromPath(path)
  if folder then return PrettifyPackName(folder) end
  -- Default LSM sounds (e.g. the library's built-in "None") have paths
  -- like "Interface\Quiet.ogg" with no AddOns segment.
  return "Other LSM"
end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local function GetLSM()
  if not LibStub then return nil end
  return LibStub("LibSharedMedia-3.0", true)
end

local function PrettifyName(name)
  -- "FISHING_HOOKED" → "Fishing Hooked"
  -- "IG_QUEST_LIST_OPEN" → "Ig Quest List Open"
  local s = name:gsub("_", " ")
  return (s:gsub("(%a)(%w*)", function(first, rest)
    return first:upper() .. rest:lower()
  end))
end

-- Reverse lookup of Blizzard's SOUNDKIT global (ID → named constant).
-- Built lazily, then cached.
local soundKitNamesById
local function GetSoundKitNamesById()
  if soundKitNamesById then return soundKitNamesById end
  soundKitNamesById = {}
  if type(SOUNDKIT) == "table" then
    for name, id in pairs(SOUNDKIT) do
      if type(id) == "number" and type(name) == "string" then
        soundKitNamesById[id] = name
      end
    end
  end
  return soundKitNamesById
end

---------------------------------------------------------------------------
-- Entry construction helpers: pre-compute sort keys so subsequent
-- sort/filter passes don't re-do StripColors/lower per comparison.
---------------------------------------------------------------------------
local function MakeEntry(label, value, source, pack, kind, raw, path)
  local sortName = label or ""
  sortName = CobySuite_ApexFury.Utilities.StripColors(sortName):lower()

  local sortSource = source or ""
  if pack and source == "LibSharedMedia" then sortSource = pack end
  if pack and source == "Blizzard"       then sortSource = "Blizzard: " .. pack end
  sortSource = sortSource:lower()

  return {
    label  = label,
    value  = value,
    source = source,
    pack   = pack,
    kind   = kind,
    raw    = raw,
    path   = path,
    _sortName   = sortName,
    _sortSource = sortSource,
    _sortKind   = (kind or ""):lower(),
  }
end

---------------------------------------------------------------------------
-- Catalog builders
---------------------------------------------------------------------------

local function BuildBlizzardEntries()
  local entries, seen = {}, {}

  if type(SOUNDKIT) == "table" then
    for name, id in pairs(SOUNDKIT) do
      if type(id) == "number"
         and type(name) == "string"
         and not seen[id]
         and not IsExcluded(name)
      then
        seen[id] = true
        local pack = ClassifyBlizzardName(name)
        table.insert(entries,
          MakeEntry(PrettifyName(name), id, "Blizzard", pack, "SoundKit", id, nil))
      end
    end
  end

  for _, s in ipairs(EXTRA_BLIZZARD_SOUNDS) do
    if not seen[s.id] then
      seen[s.id] = true
      table.insert(entries,
        MakeEntry(s.label, s.id, "Blizzard", s.pack or "Effect", "SoundKit", s.id, nil))
    end
  end

  return entries
end

local function BuildLSMEntries()
  local entries = {}
  local LSM = GetLSM()
  if not LSM then return entries end

  -- LSM:HashTable returns the internal name→path map directly: one
  -- table reference instead of N Fetch calls.
  local hash = LSM:HashTable("sound") or {}
  for name, path in pairs(hash) do
    table.insert(entries,
      MakeEntry(name, "lsm:" .. name, "LibSharedMedia",
                ClassifyLSMPath(path), "LSM", path, path))
  end

  return entries
end

---------------------------------------------------------------------------
-- Module-level caches
--
-- Building 800+ Blizzard + 400+ LSM entries takes work; caching the
-- result avoids redoing it on every browser:Refresh(). The per-source
-- counts are a snapshot of their own, so a source menu never builds
-- entries. A pack can register sounds after the catalog was built, so a
-- registration empties both and bumps the catalog generation (see the
-- watcher at the end of this file); browsers compare the generation on
-- Refresh.
---------------------------------------------------------------------------
local cachedEntries
local countSnapshot       -- { generation, sources, counts, total, blizzardTotal }
local countBuilds = 0
local catalogGeneration = 0

-- Empties every catalog cache, so the next lookup rebuilds from the
-- sources as they are now
local function InvalidateCatalog()
  catalogGeneration = catalogGeneration + 1
  cachedEntries = nil
  countSnapshot = nil
end

Sound.InvalidateCatalog = InvalidateCatalog

-- Changes whenever the catalog is invalidated; compare, never interpret
function Sound.GetCatalogGeneration()
  return catalogGeneration
end

---------------------------------------------------------------------------
-- Public catalog API
---------------------------------------------------------------------------

-- Every catalog entry, Blizzard then LSM
function Sound.GetEntries()
  if not cachedEntries then
    local out = {}
    for _, e in ipairs(BuildBlizzardEntries()) do table.insert(out, e) end
    for _, e in ipairs(BuildLSMEntries())      do table.insert(out, e) end
    cachedEntries = out
  end
  return cachedEntries
end

-- Per-pack counts of the Blizzard catalog, without building entries (the
-- same seen/exclusion rules as BuildBlizzardEntries)
local function ListBlizzardPacks()
  local counts = { UI = 0, Voice = 0, Combat = 0, Item = 0, Alert = 0, Effect = 0 }
  local seen = {}

  if type(SOUNDKIT) == "table" then
    for name, id in pairs(SOUNDKIT) do
      if type(id) == "number"
         and type(name) == "string"
         and not seen[id]
         and not IsExcluded(name)
      then
        seen[id] = true
        local pack = ClassifyBlizzardName(name)
        counts[pack] = (counts[pack] or 0) + 1
      end
    end
  end
  for _, s in ipairs(EXTRA_BLIZZARD_SOUNDS) do
    if not seen[s.id] then
      seen[s.id] = true
      counts[s.pack or "Effect"] = (counts[s.pack or "Effect"] or 0) + 1
    end
  end
  return counts
end

-- Per-pack counts of LSM:HashTable, without building entries
local function ListLSMPacks()
  local counts = {}
  local LSM = GetLSM()
  if not LSM then return counts end
  local hash = LSM:HashTable("sound") or {}
  for _, path in pairs(hash) do
    local pack = ClassifyLSMPath(path)
    counts[pack] = (counts[pack] or 0) + 1
  end
  return counts
end

local BLIZZARD_PACK_ORDER = { "UI", "Combat", "Voice", "Item", "Alert", "Effect" }

-- The source names and their counts for this catalog generation: built on
-- first use after an invalidation, from one pass over each catalog
local function GetCountSnapshot()
  if countSnapshot and countSnapshot.generation == catalogGeneration then
    return countSnapshot
  end
  countBuilds = countBuilds + 1

  local sources, counts, total, blizzardTotal = {}, {}, 0, 0

  local blizCounts = ListBlizzardPacks()
  for _, pack in ipairs(BLIZZARD_PACK_ORDER) do
    local n = blizCounts[pack] or 0
    if n > 0 then
      local name = "Blizzard: " .. pack
      sources[#sources + 1] = name
      counts[name] = n
      total = total + n
      blizzardTotal = blizzardTotal + n
    end
  end

  local lsmCounts = ListLSMPacks()
  local lsmNames = {}
  for name in pairs(lsmCounts) do
    if name ~= "Other LSM" then lsmNames[#lsmNames + 1] = name end
  end
  table.sort(lsmNames, function(a, b) return a:lower() < b:lower() end)
  if lsmCounts["Other LSM"] then lsmNames[#lsmNames + 1] = "Other LSM" end
  for _, name in ipairs(lsmNames) do
    sources[#sources + 1] = name
    counts[name] = lsmCounts[name]
    total = total + lsmCounts[name]
  end

  countSnapshot = {
    generation = catalogGeneration,
    sources = sources,
    counts = counts,
    total = total,
    blizzardTotal = blizzardTotal,
  }
  return countSnapshot
end

-- GetSourceList: names of sources/packs available right now, ordered for
-- menu rendering (a copy; each name works with GetSourceCount)
function Sound.GetSourceList()
  local snapshot = GetCountSnapshot()
  local out = {}
  for i, name in ipairs(snapshot.sources) do out[i] = name end
  return out
end

-- GetSourceCount: one source's count ("Blizzard" sums its packs), from the
-- snapshot
function Sound.GetSourceCount(name)
  if not name then return 0 end
  local snapshot = GetCountSnapshot()
  if name == "Blizzard" then return snapshot.blizzardTotal end
  return snapshot.counts[name] or 0
end

-- GetSourceCounts: sources (ordered), counts[name] and the total of every
-- source, all copies, from one snapshot
function Sound.GetSourceCounts()
  local snapshot = GetCountSnapshot()
  local sources, counts = {}, {}
  for i, name in ipairs(snapshot.sources) do
    sources[i] = name
    counts[name] = snapshot.counts[name]
  end
  return sources, counts, snapshot.total
end

-- For tests: how many times the count snapshot was built this session
function Sound.GetCatalogStats()
  return { countBuilds = countBuilds }
end

---------------------------------------------------------------------------
-- Resolve / Play / LookupLabel
---------------------------------------------------------------------------

function Sound.Resolve(value)
  if type(value) == "number" then
    return "soundkit", value, ("SoundKit %d"):format(value)
  end
  if type(value) ~= "string" then
    return nil, nil, "(invalid)"
  end

  local fdid = value:match("^fdid:(%d+)$")
  if fdid then
    local id = tonumber(fdid)
    return "fdid", id, ("FileDataID %d"):format(id)
  end

  local lsmName = value:match("^lsm:(.+)$")
  if lsmName then
    local LSM = GetLSM()
    if not LSM then return "lsm_missing", lsmName, ("Shared media (not loaded): %s"):format(lsmName) end
    -- noDefault: without it LSM hands back its default sound for a name it
    -- does not have, and a removed pack would look like a valid choice
    local path = LSM:Fetch("sound", lsmName, true)
    if not path then return "lsm_missing", lsmName, ("Shared media: %s"):format(lsmName) end
    return "lsm", path, lsmName
  end

  local id = tonumber(value)
  if id then return "soundkit", id, ("SoundKit %d"):format(id) end

  return nil, nil, "(invalid)"
end

local MAX_PLAYBACK_SECONDS = 10
local FADEOUT_MS = 400

-- Returns (handle, willPlay). willPlay is the boolean PlaySound/PlaySoundFile
-- returns first; false means the WoW mixer rejected the dispatch (channel
-- saturation under heavy combat is the typical cause). Callers that need
-- to know whether audio actually went out should treat
-- (willPlay and handle) as the success signal; handle alone can be valid
-- even when willPlay is false in some edge cases.
function Sound.Play(value, channel)
  channel = channel or "Master"
  local kind, payload = Sound.Resolve(value)
  local willPlay, handle
  if kind == "soundkit" then
    willPlay, handle = PlaySound(payload, channel)
  elseif kind == "lsm" then
    willPlay, handle = PlaySoundFile(payload, channel)
  elseif kind == "fdid" then
    willPlay, handle = PlaySoundFile(payload, channel)
  end

  if handle then
    C_Timer.After(MAX_PLAYBACK_SECONDS, function()
      StopSound(handle, FADEOUT_MS)
    end)
  end
  return handle, willPlay
end

-- Built lazily once: value → label map for the curated Blizzard catalog
-- (SOUNDKIT entries + EXTRA_BLIZZARD_SOUNDS). Avoids re-scanning ~800
-- entries on every LookupLabel call from the options window's Refresh.
local blizzardLabelByValue
local function GetBlizzardLabelByValue()
  if blizzardLabelByValue then return blizzardLabelByValue end
  blizzardLabelByValue = {}
  for _, e in ipairs(BuildBlizzardEntries()) do
    blizzardLabelByValue[e.value] = e.label
  end
  return blizzardLabelByValue
end

-- The Blizzard catalog label, else a SOUNDKIT name, else savedLabel (the
-- label a consumer kept for a value outside that catalog, such as
-- "fdid:N"), else Resolve's description (an LSM value's name)
function Sound.LookupLabel(value, savedLabel)
  local label = GetBlizzardLabelByValue()[value]
  if label then return label end

  -- SOUNDKIT reverse lookup for arbitrary numeric IDs
  if type(value) == "number" then
    local skName = GetSoundKitNamesById()[value]
    if skName then return PrettifyName(skName) end
  end

  if savedLabel and savedLabel ~= "" then return savedLabel end

  local _, _, fallback = Sound.Resolve(value)
  return fallback
end

---------------------------------------------------------------------------
-- Catalog freshness. LibSharedMedia announces every registration through
-- its LibSharedMedia_Registered callback, hooked as soon as the library is
-- present (which may be after this file loads); each sound registration
-- invalidates the catalog. Once hooked, ADDON_LOADED is no longer needed.
---------------------------------------------------------------------------
local lsmHooked = false
local watchFrame = CreateFrame("Frame")

local function WatchSources()
  if lsmHooked then return end
  local LSM = GetLSM()
  if LSM and LSM.RegisterCallback then
    LSM.RegisterCallback(Sound, "LibSharedMedia_Registered", function(_, mediaType)
      if mediaType == "sound" then InvalidateCatalog() end
    end)
    lsmHooked = true
    watchFrame:UnregisterEvent("ADDON_LOADED")
    InvalidateCatalog()   -- sounds registered before the hook existed
  end
end

watchFrame:RegisterEvent("ADDON_LOADED")
watchFrame:SetScript("OnEvent", WatchSources)
WatchSources()
