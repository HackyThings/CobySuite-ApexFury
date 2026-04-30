-------------------------------------------------------------------------------
-- CobySuite.Sound — unified sound catalog, resolution, and playback.
--
-- Consolidates the Blizzard SoundKit catalog, LibSharedMedia (LSM)
-- registry, and Leatrix Sounds' bundled FileDataID database into a
-- single namespace consumer addons can browse, resolve, and play
-- against.
--
-- Storage formats (what consumers persist into their config):
--   number 8960              → Blizzard SoundKit ID  (PlaySound)
--   string "8960"            → SoundKit ID as string (PlaySound)
--   string "fdid:538903"     → Blizzard FileDataID   (PlaySoundFile)
--   string "lsm:Glass Break" → LibSharedMedia entry  (PlaySoundFile via path)
--
-- Each entry exposed via Sound.GetEntries returns:
--   { label, value, source, pack, kind, raw, path,
--     _sortName, _sortSource, _sortKind }   ← pre-computed for fast sort
--
-- where:
--   label   string  display name (may contain |c color codes from LSM)
--   value   any     storage form for Config.Set (one of the 4 above)
--   source  string  top-level source ("Blizzard"/"LibSharedMedia"/"Leatrix")
--   pack    string  sub-source — for Blizzard: "UI"/"Voice"/"Combat"/"Item"/
--                   "Alert"/"Effect"; for LSM: auto-derived from the addon
--                   folder name in the file path (e.g. "Astral", "Causese",
--                   "ElvUI"; "Other LSM" if path has no AddOns segment);
--                   nil otherwise
--   kind    string  "SoundKit"/"FileDataID"/"LSM"
--   raw     any     numeric ID, file path, or LSM name (whatever Play needs)
--   path    string  filesystem path when known (LSM/Leatrix) — for tooltips
-------------------------------------------------------------------------------

CobySuite = CobySuite or {}
CobySuite.Sound = CobySuite.Sound or {}
local Sound = CobySuite.Sound

---------------------------------------------------------------------------
-- Source colors — used by browsers/UI to color-code source pills. Hex
-- color codes (no |c prefix). Consumers that need decimal values can
-- divide by 255.
---------------------------------------------------------------------------
Sound.SourceColors = {
  Blizzard          = "FFD200",
  ["Blizzard: UI"]      = "FFE07A",
  ["Blizzard: Voice"]   = "9FC2E0",
  ["Blizzard: Combat"]  = "F09898",
  ["Blizzard: Item"]    = "8AE07A",
  ["Blizzard: Alert"]   = "FFAA40",
  ["Blizzard: Effect"]  = "FFD200",
  LibSharedMedia    = "8AD4FF",
  Leatrix           = "B58AFF",
  Astral            = "A335EE",   -- matches Astral's own |c prefix
  Causese           = "FF7777",
  Other             = "AAAAAA",
}

---------------------------------------------------------------------------
-- SOUNDKIT exclusion — entries we never expose because they aren't
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
-- one mega-list. Order matters — most specific category first; first
-- match wins.
---------------------------------------------------------------------------
local function ClassifyBlizzardName(name)
  if type(name) ~= "string" then return "Effect" end

  -- Voice (most specific). SOUNDKIT genuinely has very little voice
  -- content — boss/NPC speech is FileDataID-based (Leatrix's territory).
  -- Anchored prefixes only to avoid false positives.
  if name:find("VOICEOVER", 1, true)
     or name:sub(1, 3) == "VO_"
     or name:sub(1, 4) == "VOX_"
     or name:find("_SPEECH", 1, true)
     or name:find("_DIALOGUE", 1, true)
     or name:sub(1, 4) == "NPC_"
  then
    return "Voice"
  end

  -- Item / economy — check BEFORE UI so things like LOOT_OPEN, BAG_CLOSE,
  -- AUCTION_WINDOW_OPEN go to Item rather than getting swallowed by UI's
  -- generic _OPEN/_CLOSE patterns.
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

  -- System alerts — also before UI so READY_CHECK_*_OPEN doesn't end up UI
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

  -- UI: interface clicks/popups/menus. Removed generic _OPEN/_CLOSE
  -- since those overlapped heavily with item/quest/auction sounds.
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

-- Iconic sounds not in SOUNDKIT global — explicit IDs needed.
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
-- LSM doesn't expose which addon registered which sound — only the
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

-- Strip WoW |cAARRGGBB...|r color codes. Fast-path skips work when
-- there's no color code — which is true for all Blizzard SoundKit names
-- and most Leatrix paths.
function Sound.StripColors(s)
  if type(s) ~= "string" then return "" end
  if not s:find("|c", 1, true) then return s end
  return (s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
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
-- Leatrix Sounds index (FileDataID → path)
---------------------------------------------------------------------------
local leatrixIndex
local leatrixEntriesRaw  -- list of {fdid, path, kind}

local function BuildLeatrixIndex()
  leatrixIndex = {}
  leatrixEntriesRaw = {}
  local lx = _G.Leatrix_Sounds
  if type(lx) ~= "table" then return end

  for _, listKey in ipairs({ "OGG", "MP3", "EXT" }) do
    local list = lx[listKey]
    if type(list) == "table" then
      for _, entry in ipairs(list) do
        if type(entry) == "string" then
          local path, idStr = entry:match("^(.+)#(%d+)$")
          if path and idStr then
            local fdid = tonumber(idStr)
            if fdid and not leatrixIndex[fdid] then
              leatrixIndex[fdid] = path
              table.insert(leatrixEntriesRaw, { fdid = fdid, path = path, kind = listKey })
            end
          end
        end
      end
    end
  end
end

local function GetLeatrixIndex()
  if not leatrixIndex then BuildLeatrixIndex() end
  return leatrixIndex
end

local function GetLeatrixEntriesRaw()
  if not leatrixEntriesRaw then BuildLeatrixIndex() end
  return leatrixEntriesRaw
end

function Sound.IsLeatrixAvailable()
  return type(_G.Leatrix_Sounds) == "table"
end

function Sound.IsLSMAvailable()
  return GetLSM() ~= nil
end

---------------------------------------------------------------------------
-- Entry construction helpers — pre-compute sort keys so subsequent
-- sort/filter passes don't re-do StripColors/lower per comparison.
---------------------------------------------------------------------------
local function MakeEntry(label, value, source, pack, kind, raw, path)
  local sortName = label or ""
  if sortName ~= "" and sortName:find("|c", 1, true) then
    sortName = (sortName:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
  end
  sortName = sortName:lower()

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

  -- LSM:HashTable returns the internal name→path map directly — one
  -- table reference instead of N Fetch calls.
  local hash = LSM:HashTable("sound") or {}
  for name, path in pairs(hash) do
    table.insert(entries,
      MakeEntry(name, "lsm:" .. name, "LibSharedMedia",
                ClassifyLSMPath(path), "LSM", path, path))
  end

  return entries
end

local function BuildLeatrixEntriesUnified()
  local entries = {}
  local list = GetLeatrixEntriesRaw() or {}
  for i = 1, #list do
    local e = list[i]
    table.insert(entries,
      MakeEntry(e.path, "fdid:" .. e.fdid, "Leatrix", e.kind, "FileDataID", e.fdid, e.path))
  end
  return entries
end

---------------------------------------------------------------------------
-- Module-level entry cache
--
-- Building 800+ Blizzard + 400+ LSM entries takes work; caching the
-- result avoids redoing it on every browser:Refresh(). Two cache slots
-- (with/without Leatrix) since Leatrix is opt-in. The cache lives for
-- the session — LSM packs and Leatrix register at addon load and don't
-- change at runtime.
---------------------------------------------------------------------------
local cachedNoLeatrix
local cachedWithLeatrix

local function BuildAll(includeLeatrix)
  local out = {}
  for _, e in ipairs(BuildBlizzardEntries()) do table.insert(out, e) end
  for _, e in ipairs(BuildLSMEntries())      do table.insert(out, e) end
  if includeLeatrix then
    for _, e in ipairs(BuildLeatrixEntriesUnified()) do table.insert(out, e) end
  end
  return out
end

---------------------------------------------------------------------------
-- Public catalog API
---------------------------------------------------------------------------

function Sound.GetEntries(opts)
  opts = opts or {}
  if opts.includeLeatrix then
    if not cachedWithLeatrix then cachedWithLeatrix = BuildAll(true) end
    return cachedWithLeatrix
  end
  if not cachedNoLeatrix then cachedNoLeatrix = BuildAll(false) end
  return cachedNoLeatrix
end

-- Sub-pack list helpers — used by browser source-filter dropdowns
-- to enumerate visible packs without materializing the full entry list.

local function ListBlizzardPacks()
  -- Probe via a fast iteration of SOUNDKIT names so we know which
  -- Blizzard packs actually have content (also includes counts from
  -- EXTRA_BLIZZARD_SOUNDS).
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

-- ListLSMPacks — fast scan of LSM:HashTable to count entries per pack.
-- Used by GetSourceList / GetSourceCount without materializing entries.
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

-- GetSourceList — names of sources/packs available right now, ordered
-- for menu rendering. Each entry is the canonical name a consumer can
-- pass to GetEntriesBySource / GetSourceCount.
function Sound.GetSourceList()
  local out = {}

  -- Blizzard sub-packs (only show ones with entries)
  local blizCounts = ListBlizzardPacks()
  local PACK_ORDER = { "UI", "Combat", "Voice", "Item", "Alert", "Effect" }
  for _, pack in ipairs(PACK_ORDER) do
    if (blizCounts[pack] or 0) > 0 then
      table.insert(out, "Blizzard: " .. pack)
    end
  end

  -- LSM packs auto-discovered from paths
  local lsmCounts = ListLSMPacks()
  local lsmNames = {}
  for name in pairs(lsmCounts) do
    if name ~= "Other LSM" then table.insert(lsmNames, name) end
  end
  table.sort(lsmNames, function(a, b) return a:lower() < b:lower() end)
  for _, n in ipairs(lsmNames) do table.insert(out, n) end
  if lsmCounts["Other LSM"] then table.insert(out, "Other LSM") end

  if Sound.IsLeatrixAvailable() then
    table.insert(out, "Leatrix")
  end

  return out
end

-- GetSourceCount — fast count without materializing the entry list.
function Sound.GetSourceCount(name)
  if not name then return 0 end

  if name:sub(1, 10) == "Blizzard: " then
    local pack = name:sub(11)
    local counts = ListBlizzardPacks()
    return counts[pack] or 0
  elseif name == "Blizzard" then
    local total, counts = 0, ListBlizzardPacks()
    for _, n in pairs(counts) do total = total + n end
    return total
  elseif name == "Leatrix" then
    local list = GetLeatrixEntriesRaw()
    return list and #list or 0
  end
  -- Treat as LSM pack name
  local counts = ListLSMPacks()
  return counts[name] or 0
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
    if not LSM then return "lsm_missing", lsmName, ("LSM (unavailable): %s"):format(lsmName) end
    local path = LSM:Fetch("sound", lsmName)
    if not path then return "lsm_missing", lsmName, ("LSM (unknown): %s"):format(lsmName) end
    return "lsm", path, lsmName
  end

  local id = tonumber(value)
  if id then return "soundkit", id, ("SoundKit %d"):format(id) end

  return nil, nil, "(invalid)"
end

local MAX_PLAYBACK_SECONDS = 10
local FADEOUT_MS = 400

function Sound.Play(value, channel)
  channel = channel or "Master"
  local kind, payload = Sound.Resolve(value)
  local handle
  if kind == "soundkit" then
    local _
    _, handle = PlaySound(payload, channel)
  elseif kind == "lsm" then
    local _
    _, handle = PlaySoundFile(payload, channel)
  elseif kind == "fdid" then
    local _
    _, handle = PlaySoundFile(payload, channel)
  end

  if handle then
    C_Timer.After(MAX_PLAYBACK_SECONDS, function()
      StopSound(handle, FADEOUT_MS)
    end)
  end
  return handle
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

function Sound.LookupLabel(value, savedLabel)
  local label = GetBlizzardLabelByValue()[value]
  if label then return label end

  -- SOUNDKIT reverse lookup for arbitrary numeric IDs
  if type(value) == "number" then
    local skName = GetSoundKitNamesById()[value]
    if skName then return PrettifyName(skName) end
  end

  -- Leatrix path lookup for "fdid:N"
  if type(value) == "string" then
    local fdid = value:match("^fdid:(%d+)$")
    if fdid then
      local path = GetLeatrixIndex()[tonumber(fdid)]
      if path then return path end
    end
  end

  if savedLabel and savedLabel ~= "" then return savedLabel end

  local _, _, fallback = Sound.Resolve(value)
  return fallback
end

