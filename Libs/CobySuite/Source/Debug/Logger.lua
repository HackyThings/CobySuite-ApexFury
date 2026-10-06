-------------------------------------------------------------------------------
-- CobySuite.Debug.NewLogger: shared ring-buffer debug logger constructor
--
-- Each consumer addon calls NewLogger(opts) to get its own independent instance
-- with its own buffer, categories, persistence, and session header.
-------------------------------------------------------------------------------

CobySuite_ApexFury.Debug = CobySuite_ApexFury.Debug or {}

-- Levels are shared across all logger instances
CobySuite_ApexFury.Debug.Levels = {
  INFO  = "INFO",
  WARN  = "WARN",
  STATE = "STATE",
  EVENT = "EVENT",
}

local Levels = CobySuite_ApexFury.Debug.Levels

-- CobySuite.Debug.SetLineTag(fn): fn() gives a tag ("[test]") or nil; every
-- logger keeps the tag with each line written while it gives one (entry.tag,
-- shown before the message). The test framework sets it in development
-- builds, so lines a suite or a Verify scene writes never pass for the
-- player's own in their debug log (ApexFury's run 2 review); nothing in a
-- release sets it.
local lineTag = nil
local RECENT_COUNT = 250   -- the debug window's "Copy Last 250"
function CobySuite_ApexFury.Debug.SetLineTag(fn)
  lineTag = fn
end

-------------------------------------------------------------------------------
-- AppendConfigSnapshot: emits "Config Snapshot:" + sorted key=value pairs
-- for every non-table entry in the named SavedVariable. Used by consumer
-- addons' sessionHeader callbacks; consumers append their own extras after.
-------------------------------------------------------------------------------
function CobySuite_ApexFury.Debug.AppendConfigSnapshot(lines, svName)
  table.insert(lines, "Config Snapshot:")
  local sv = _G[svName]
  if sv then
    local parts = {}
    for key, val in pairs(sv) do
      if type(val) ~= "table" then
        table.insert(parts, "  " .. tostring(key) .. "=" .. tostring(val))
      end
    end
    table.sort(parts)
    for _, p in ipairs(parts) do
      table.insert(lines, p)
    end
  else
    table.insert(lines, "  (not loaded)")
  end
end

-------------------------------------------------------------------------------
-- opts:
--   addonName       (string)   "Recollect" or "CobysLinkepedia"
--   categories      (table)    {"INIT", "CONFIG", ...}
--   savedVariable   (string)   "MYADDON_DEBUG_LOG" or "COBYS_LINKEPEDIA_DEBUG_LOG"
--   bufferSize      (number?)  max entries, default 5000
--   sessionHeader   (function?) fn(lines): appends extra lines to the header table
-------------------------------------------------------------------------------
function CobySuite_ApexFury.Debug.NewLogger(opts)
  local addonName     = opts.addonName
  local categories    = opts.categories
  local savedVariable = opts.savedVariable
  local maxEntries    = opts.bufferSize or 5000
  local sessionHeader = opts.sessionHeader

  local logger = {}
  logger.Categories = categories
  logger.Levels = Levels

  -- Ring buffer state (private to this instance)
  local buffer = {}
  local writePos = 1
  local bufferSize = 0
  local totalAdded = 0
  local resetCount = 0   -- bumped whenever the buffer is replaced (Clear, the load-time restore)
  local sessionStartTime = date("%Y-%m-%d %H:%M:%S")

  ---------------------------------------------------------------------------
  -- Timestamp from debugprofilestop(), millisecond precision
  ---------------------------------------------------------------------------
  local function GetTimestamp()
    local ms = debugprofilestop()
    local totalSeconds = ms / 1000
    local hours = math.floor(totalSeconds / 3600) % 24
    local minutes = math.floor(totalSeconds / 60) % 60
    local seconds = math.floor(totalSeconds) % 60
    local millis = math.floor(ms) % 1000
    return string.format("%02d:%02d:%02d.%03d", hours, minutes, seconds, millis)
  end

  ---------------------------------------------------------------------------
  -- Ring buffer core
  ---------------------------------------------------------------------------
  local function AddEntry(level, category, message, ...)
    if select("#", ...) > 0 then
      message = string.format(message, ...)
    end
    local tag
    if lineTag then
      local ok, value = pcall(lineTag)
      if ok and type(value) == "string" and value ~= "" then tag = value end
    end

    buffer[writePos] = {
      timestamp = GetTimestamp(),
      level = level,
      category = category,
      message = message,
      tag = tag,
    }

    writePos = writePos % maxEntries + 1
    if bufferSize < maxEntries then bufferSize = bufferSize + 1 end
    totalAdded = totalAdded + 1
  end

  ---------------------------------------------------------------------------
  -- Public logging API
  ---------------------------------------------------------------------------
  function logger.Log(category, message, ...)
    AddEntry(Levels.INFO, category, message, ...)
  end

  function logger.Warn(category, message, ...)
    AddEntry(Levels.WARN, category, message, ...)
  end

  function logger.State(category, message, ...)
    AddEntry(Levels.STATE, category, message, ...)
  end

  function logger.Event(category, message, ...)
    AddEntry(Levels.EVENT, category, message, ...)
  end

  ---------------------------------------------------------------------------
  -- Buffer access
  ---------------------------------------------------------------------------

  -- Return entries in chronological order (oldest first)
  function logger.GetBuffer()
    local ordered = {}
    if bufferSize < maxEntries then
      for i = 1, bufferSize do ordered[i] = buffer[i] end
    else
      -- Ring wrapped: oldest is at writePos, newest is at writePos - 1
      local idx = 1
      for i = writePos, maxEntries do ordered[idx] = buffer[i]; idx = idx + 1 end
      for i = 1, writePos - 1 do ordered[idx] = buffer[i]; idx = idx + 1 end
    end
    return ordered
  end

  function logger.GetBufferSize()
    return bufferSize
  end

  function logger.GetEntryCount()
    return totalAdded
  end

  -- The entries added since seq (an earlier GetEntryCount()), oldest first,
  -- and whether the ring had already overwritten some of them (the caller
  -- fell more than a whole buffer behind). Only the new entries are copied;
  -- the live debug view uses this instead of GetBuffer.
  function logger.GetEntriesSince(seq)
    local newCount = totalAdded - (seq or 0)
    if newCount <= 0 then return {}, false end
    local overrun = newCount > bufferSize
    if overrun then newCount = bufferSize end
    local out = {}
    for k = newCount, 1, -1 do
      -- The newest entry sits just before writePos
      out[newCount - k + 1] = buffer[(writePos - k - 1) % maxEntries + 1]
    end
    return out, overrun
  end

  -- How many times the buffer has been replaced: Clear and the restore of
  -- the saved log at ADDON_LOADED. The entry count alone cannot show a
  -- restore, which can leave it higher than before, so a view that keeps a
  -- position (GetEntriesSince) rebuilds when this changes.
  function logger.GetResetCount()
    return resetCount
  end

  function logger.Clear()
    wipe(buffer)
    writePos = 1
    bufferSize = 0
    totalAdded = 0
    resetCount = resetCount + 1
  end

  ---------------------------------------------------------------------------
  -- Formatting
  ---------------------------------------------------------------------------
  local function FormatEntry(entry)
    return string.format("[%s] [%s] [%s] %s%s",
      entry.timestamp, entry.level, entry.category, entry.tag and (entry.tag .. " ") or "", entry.message)
  end

  function logger.FormatEntry(entry)
    return FormatEntry(entry)
  end

  function logger.GetSessionHeader()
    local lines = {}
    table.insert(lines, "=== " .. string.upper(addonName) .. " DEBUG LOG ===")

    local version = C_AddOns.GetAddOnMetadata(addonName, "Version") or "?"
    table.insert(lines, "Addon Version: " .. version)

    local build, _, _, tocVersion = GetBuildInfo()
    table.insert(lines, "WoW Build: " .. build .. " (TOC " .. tocVersion .. ")")
    table.insert(lines, "Session Start: " .. sessionStartTime)
    table.insert(lines, "Time Now: " .. date("%Y-%m-%d %H:%M:%S"))

    -- Consumer-provided extra header lines
    if sessionHeader then
      sessionHeader(lines)
    end

    table.insert(lines, "=== LOG ENTRIES (newest first) ===")
    return table.concat(lines, "\n")
  end

  function logger.GetFormattedLog(recentOnly, levelFilters, categoryFilters)
    local lines = {}
    table.insert(lines, logger.GetSessionHeader())

    -- Note active filters in output
    if levelFilters then
      local active = {}
      for _, level in ipairs({"INFO", "WARN", "STATE", "EVENT"}) do
        if levelFilters[level] then table.insert(active, level) end
      end
      if #active < 4 then
        table.insert(lines, "Active Level Filters: " .. table.concat(active, ", "))
      end
    end
    if categoryFilters then
      local active = {}
      for _, cat in ipairs(categories) do
        if categoryFilters[cat] then table.insert(active, cat) end
      end
      if #active < #categories then
        table.insert(lines, "Active Category Filters: " .. table.concat(active, ", "))
      end
    end

    local maxCount = nil
    if recentOnly then
      maxCount = RECENT_COUNT
      table.insert(lines, "Showing: Last " .. RECENT_COUNT .. " entries")
    end

    table.insert(lines, "")

    -- Iterate newest-first through ring buffer.
    -- writePos points to the slot AFTER the newest entry (the next slot to
    -- write into), so the newest entry sits at writePos-1 in 1-indexed
    -- terms, which is `(writePos - 0 - 2) % maxEntries + 1`. Subtracting
    -- only -1 would land on writePos itself, which is the OLDEST slot in a
    -- wrapped buffer (or a nil slot in a partial buffer, dropping the
    -- oldest entry).
    local count = 0
    for step = 0, bufferSize - 1 do
      local idx = (writePos - step - 2) % maxEntries + 1
      local entry = buffer[idx]
      if entry then
        local levelOk = not levelFilters or levelFilters[entry.level]
        local catOk = not categoryFilters or categoryFilters[entry.category]
        if levelOk and catOk then
          table.insert(lines, FormatEntry(entry))
          count = count + 1
          if maxCount and count >= maxCount then break end
        end
      end
    end

    table.insert(lines, "")
    table.insert(lines, "(" .. count .. " entries)")

    return table.concat(lines, "\n")
  end

  function logger.GetFilteredEntries(levelFilters, categoryFilters)
    local result = {}
    local startIdx = bufferSize < maxEntries and 1 or writePos
    for step = 0, bufferSize - 1 do
      local idx = (startIdx + step - 1) % maxEntries + 1
      local entry = buffer[idx]
      if entry then
        local levelOk = not levelFilters or levelFilters[entry.level]
        local catOk = not categoryFilters or categoryFilters[entry.category]
        if levelOk and catOk then
          result[#result + 1] = entry
        end
      end
    end
    return result
  end

  ---------------------------------------------------------------------------
  -- Persistence: save buffer to SavedVariable on logout, restore on load
  ---------------------------------------------------------------------------
  local persistFrame = CreateFrame("Frame")
  persistFrame:RegisterEvent("ADDON_LOADED")
  persistFrame:RegisterEvent("PLAYER_LOGOUT")
  persistFrame:SetScript("OnEvent", function(_, event, addon)
    if event == "ADDON_LOADED" and addon == addonName then
      local saved = _G[savedVariable]
      if saved and #saved > 0 then
        -- Capture any init entries logged before ADDON_LOADED
        local initEntries = logger.GetBuffer()

        -- Rebuild buffer: saved entries first, then separator, then init entries
        wipe(buffer)
        writePos = 1
        bufferSize = 0
        totalAdded = 0
        resetCount = resetCount + 1

        for _, entry in ipairs(saved) do
          buffer[writePos] = entry
          writePos = writePos % maxEntries + 1
          if bufferSize < maxEntries then bufferSize = bufferSize + 1 end
          totalAdded = totalAdded + 1
        end

        -- Session boundary marker
        AddEntry(Levels.INFO, "INIT", "=== New session ===")

        for _, entry in ipairs(initEntries) do
          buffer[writePos] = entry
          writePos = writePos % maxEntries + 1
          if bufferSize < maxEntries then bufferSize = bufferSize + 1 end
          totalAdded = totalAdded + 1
        end
      end
      _G[savedVariable] = nil  -- free memory until next save
    elseif event == "PLAYER_LOGOUT" then
      _G[savedVariable] = logger.GetBuffer()
    end
  end)

  logger.Log("INIT", "Debug logger initialized")

  return logger
end
