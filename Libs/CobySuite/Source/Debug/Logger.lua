-------------------------------------------------------------------------------
-- CobySuite.Debug.NewLogger — shared ring-buffer debug logger constructor
--
-- Each consumer addon calls NewLogger(opts) to get its own independent instance
-- with its own buffer, categories, persistence, and session header.
-------------------------------------------------------------------------------

CobySuite.Debug = CobySuite.Debug or {}

-- Levels are shared across all logger instances
CobySuite.Debug.Levels = {
  INFO  = "INFO",
  WARN  = "WARN",
  STATE = "STATE",
  EVENT = "EVENT",
}

local Levels = CobySuite.Debug.Levels

-------------------------------------------------------------------------------
-- opts:
--   addonName       (string)   "CobySniper" or "Linkepedia"
--   categories      (table)    {"INIT", "CONFIG", ...}
--   savedVariable   (string)   "COBY_SNIPER_DEBUG_LOG" or "LinkepediaDebugLog"
--   bufferSize      (number?)  max entries, default 5000
--   sessionHeader   (function?) fn(lines) — appends extra lines to the header table
-------------------------------------------------------------------------------
function CobySuite.Debug.NewLogger(opts)
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
  local sessionStartTime = date("%Y-%m-%d %H:%M:%S")

  ---------------------------------------------------------------------------
  -- Timestamp from debugprofilestop() — millisecond precision
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

    buffer[writePos] = {
      timestamp = GetTimestamp(),
      level = level,
      category = category,
      message = message,
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

  function logger.Clear()
    wipe(buffer)
    writePos = 1
    bufferSize = 0
    totalAdded = 0
  end

  ---------------------------------------------------------------------------
  -- Formatting
  ---------------------------------------------------------------------------
  local function FormatEntry(entry)
    return string.format("[%s] [%s] [%s] %s",
      entry.timestamp, entry.level, entry.category, entry.message)
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
      maxCount = 250
      table.insert(lines, "Showing: Last 250 entries")
    end

    table.insert(lines, "")

    -- Iterate newest-first through ring buffer
    local count = 0
    for step = 0, bufferSize - 1 do
      local idx = (writePos - step - 1) % maxEntries + 1
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
