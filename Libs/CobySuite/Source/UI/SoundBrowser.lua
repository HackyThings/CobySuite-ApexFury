-------------------------------------------------------------------------------
-- CobySuite.UI.SoundBrowser: embeddable sound-picker widget
--
-- Reusable across consumer addons. Aggregates Blizzard SoundKit and every
-- LibSharedMedia pack (Astral / Causese / Other) into one searchable,
-- sortable, virtualized table.
--
-- Build it once, embed it inside an options window, and let the user
-- pick. Selection is reported back via the onSelect callback; current
-- value is queried via getCurrentValue so the highlighted row tracks
-- whatever the consumer's config currently has stored.
--
-- Usage:
--   local browser = CobySuite.UI.SoundBrowser.Create(parent, {
--     width  = 440,
--     height = 400,
--     onSelect = function(value, entry) ... end,
--     onPreview = function(value, entry) ... end,    -- optional
--     getCurrentValue = function() return ... end,   -- for highlighting
--     persistenceKey  = "apexfury_sounds",           -- for column widths
--     persistence     = { savedVariable = "...", path = "..." },
--   })
--   browser:SetPoint("TOPLEFT", parent, "TOPRIGHT", 8, 0)
--   browser:Refresh()
--
-- Public methods on the returned frame:
--   browser:Refresh()              re-pull entries (e.g. after addon load)
--   browser:RefreshSelection()     re-read getCurrentValue + recolor rows
-------------------------------------------------------------------------------

CobySuite_ApexFury.UI = CobySuite_ApexFury.UI or {}
CobySuite_ApexFury.UI.SoundBrowser = {}
local SoundBrowser = CobySuite_ApexFury.UI.SoundBrowser

local Sound = CobySuite_ApexFury.Sound
local U     = CobySuite_ApexFury.Utilities
local TC    = U.Colors
local Fonts = U.Fonts
local SortDir = CobySuite_ApexFury.SortDir

local ROW_HEIGHT  = 22
local HEADER_H    = 20
local TOP_BAR_H   = 56
local PAD         = 8
local SCROLLBAR_W = 16
local PREVIEW_SZ  = 14

---------------------------------------------------------------------------
-- Column layout shared by header + rows
---------------------------------------------------------------------------
local DEFAULT_COLUMNS = {
  { key = "name",   label = "Name",   width = 240, sortable = true,  justify = "LEFT",
    tooltip = "Sound name. Click to preview and select." },
  { key = "source", label = "Source", width = 90,  sortable = true,  justify = "LEFT",
    tooltip = "Where the sound comes from: a Blizzard pack or the addon that registered it." },
  { key = "kind",   label = "Type",   width = 70,  sortable = true,  justify = "LEFT", stretch = true,
    tooltip = "Audio type: SoundKit (built-in IDs) or LSM (LibSharedMedia)." },
}

---------------------------------------------------------------------------
-- Source pill colors (uses CobySuite.Sound.SourceColors as default; falls
-- back per-pack for LSM since multiple packs share source="LibSharedMedia")
---------------------------------------------------------------------------
local function PillColorForEntry(entry)
  local SC = Sound.SourceColors or {}
  if entry.source == "LibSharedMedia" then
    return SC[entry.pack] or SC.Other or "AAAAAA"
  end
  return SC[entry.source] or "FFFFFF"
end

local function SourceDisplayName(entry)
  if entry.source == "LibSharedMedia" then
    return entry.pack or "LSM"
  end
  return entry.source or ""
end

---------------------------------------------------------------------------
-- Sort: read pre-computed sort keys from the entry (set at creation
-- time by MakeEntry in Sound/Main.lua). Avoids per-comparison string
-- stripping / lowering.
---------------------------------------------------------------------------
local SORT_KEY_FIELDS = {
  name   = "_sortName",
  source = "_sortSource",
  kind   = "_sortKind",
}

local function SortEntries(entries, key, ascending)
  local field = SORT_KEY_FIELDS[key] or "_sortName"
  if ascending then
    table.sort(entries, function(a, b) return (a[field] or "") < (b[field] or "") end)
  else
    table.sort(entries, function(a, b) return (a[field] or "") > (b[field] or "") end)
  end
end

---------------------------------------------------------------------------
-- Per-row construction (called once per visible row by ScrollView)
---------------------------------------------------------------------------
local function EnsureRowStructure(row, columns)
  if row._initialized then return end
  row._initialized = true

  -- Hover highlight + selection background
  row.Highlight = CobySuite_ApexFury.UI.AddHoverHighlight(row)

  row.SelectedBg = row:CreateTexture(nil, "BACKGROUND")
  row.SelectedBg:SetAllPoints()
  row.SelectedBg:SetColorTexture(0.3, 0.5, 0.9, 0.25)
  row.SelectedBg:Hide()

  row.AltBg = row:CreateTexture(nil, "BACKGROUND", nil, -1)
  row.AltBg:SetAllPoints()
  local ar = TC.ALT_ROW_BG
  row.AltBg:SetColorTexture(ar[1], ar[2], ar[3], ar[4])
  row.AltBg:Hide()

  row:RegisterForClicks("LeftButtonUp")

  -- Preview button: small speaker on the far left of the name column
  local play = CreateFrame("Button", nil, row)
  play:SetSize(PREVIEW_SZ, PREVIEW_SZ)
  local tex = play:CreateTexture(nil, "ARTWORK")
  tex:SetAllPoints()
  tex:SetTexture("Interface\\COMMON\\VoiceChat-Speaker")
  tex:SetVertexColor(0.7, 0.9, 1.0)
  local hl = play:CreateTexture(nil, "HIGHLIGHT")
  hl:SetAllPoints()
  hl:SetColorTexture(1, 1, 1, 0.3)
  row.Preview = play

  -- Cells per column (text only; the name cell hosts the play icon to the left)
  row._cells = {}
  for i = 1, #columns do
    local cell = {}
    cell.text = row:CreateFontString(nil, "OVERLAY", Fonts.DATA)
    cell.text:SetJustifyH(columns[i].justify or "LEFT")
    cell.text:SetWordWrap(false)
    row._cells[i] = cell
  end
end

local function RepositionRow(row, columns)
  local x = 0
  for i, colDef in ipairs(columns) do
    local cell = row._cells[i]
    if not cell then break end
    local w = colDef.width

    if colDef.key == "name" then
      -- Preview icon at left, text follows
      row.Preview:ClearAllPoints()
      row.Preview:SetPoint("LEFT", row, "LEFT", x + 4, 0)
      cell.text:ClearAllPoints()
      cell.text:SetPoint("LEFT", row, "LEFT", x + PREVIEW_SZ + 8, 0)
      cell.text:SetWidth(math.max(w - PREVIEW_SZ - 12, 10))
    else
      cell.text:ClearAllPoints()
      cell.text:SetPoint("LEFT", row, "LEFT", x + 4, 0)
      cell.text:SetWidth(math.max(w - 8, 10))
    end
    x = x + w
  end
end

local function PopulateRow(row, entry, columns, currentValue, rowIndex)
  EnsureRowStructure(row, columns)
  RepositionRow(row, columns)
  row._entry = entry

  for i, colDef in ipairs(columns) do
    local cell = row._cells[i]
    if not cell then break end
    if colDef.key == "name" then
      cell.text:SetText(entry.label or "")
      cell.text:SetTextColor(1, 1, 1)
    elseif colDef.key == "source" then
      local color = PillColorForEntry(entry)
      cell.text:SetText("|cFF" .. color .. SourceDisplayName(entry) .. "|r")
    elseif colDef.key == "kind" then
      local lg = TC.LIGHT_GRAY
      cell.text:SetText(entry.kind or "")
      cell.text:SetTextColor(lg[1], lg[2], lg[3])
    end
  end

  -- Selection + alternating background
  row.SelectedBg:SetShown(currentValue ~= nil and entry.value == currentValue)
  row.AltBg:SetShown((rowIndex or 0) % 2 == 0)
end

---------------------------------------------------------------------------
-- Public: Create
---------------------------------------------------------------------------
function SoundBrowser.Create(parent, opts)
  opts = opts or {}
  local width  = opts.width  or 440
  local height = opts.height or 400

  local frame = CreateFrame("Frame", nil, parent)
  frame:SetSize(width, height)

  -- Internal state
  local allEntries          = {}
  local filteredEntries     = {}
  -- Row index per entry for the alternating background. Kept here rather
  -- than stamped on the entries: those are the catalog's shared objects, and
  -- two browsers with different filters would overwrite each other's stamps.
  local rowIndexOf          = setmetatable({}, { __mode = "k" })
  local searchText          = ""
  local activeSource        = "All"
  local sortKey             = "name"
  local sortDir             = SortDir.ASC
  local onSelect            = opts.onSelect
  local onPreview           = opts.onPreview or function(v) Sound.Play(v) end
  local getCurrentValue     = opts.getCurrentValue or function() return nil end

  ---------------------------------------------------------------------------
  -- Background card
  ---------------------------------------------------------------------------
  local bg = frame:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  local cb = TC.CONTENT_BG
  bg:SetColorTexture(cb[1], cb[2], cb[3], cb[4])

  ---------------------------------------------------------------------------
  -- Top bar: source filter + search + count
  ---------------------------------------------------------------------------
  local topBar = CreateFrame("Frame", nil, frame)
  topBar:SetPoint("TOPLEFT", PAD, -PAD)
  topBar:SetPoint("TOPRIGHT", -PAD, -PAD)
  topBar:SetHeight(TOP_BAR_H)

  -- Source filter
  local sourceLabel = topBar:CreateFontString(nil, "OVERLAY", Fonts.DATA)
  sourceLabel:SetPoint("TOPLEFT", topBar, "TOPLEFT", 0, -2)
  sourceLabel:SetText("Source:")

  local sourceDD = CreateFrame("DropdownButton", nil, topBar, "WowStyle1DropdownTemplate")
  sourceDD:SetSize(130, 22)
  sourceDD:SetPoint("LEFT", sourceLabel, "RIGHT", 6, 0)

  -- Search
  local searchLabel = topBar:CreateFontString(nil, "OVERLAY", Fonts.DATA)
  searchLabel:SetPoint("LEFT", sourceDD, "RIGHT", 14, 0)
  searchLabel:SetText("Search:")

  local searchEB = CreateFrame("EditBox", nil, topBar, "InputBoxTemplate")
  searchEB:SetSize(180, U.EditBoxHeight.INPUT)
  searchEB:SetAutoFocus(false)
  searchEB:SetPoint("LEFT", searchLabel, "RIGHT", 6, 0)

  -- Count text (bottom-left of top bar)
  local countText = topBar:CreateFontString(nil, "OVERLAY", Fonts.DATA)
  countText:SetPoint("BOTTOMLEFT", topBar, "BOTTOMLEFT", 0, 4)
  countText:SetText("")

  ---------------------------------------------------------------------------
  -- TableHeader: anchored below top bar
  ---------------------------------------------------------------------------
  local header = CreateFrame("Frame", nil, frame)
  Mixin(header, CobySuite_ApexFury.UI.TableHeaderMixin)
  header:SetPoint("TOPLEFT", topBar, "BOTTOMLEFT", 0, -4)
  header:SetPoint("TOPRIGHT", topBar, "BOTTOMRIGHT", -SCROLLBAR_W - 4, -4)
  header:SetHeight(HEADER_H)

  -- Forward declarations so onSort can call refresh
  local Refresh
  local scrollBox, dataProvider

  -- TableHeader expects utilities.AddTooltip; CobySuite splits it across
  -- Utilities (constants) and UI (AddTooltip), so merge for the mixin.
  local utilsForHeader = setmetatable(
    { AddTooltip = CobySuite_ApexFury.UI.AddTooltip },
    { __index = U }
  )

  header:Init({
    columns        = DEFAULT_COLUMNS,
    persistenceKey = opts.persistenceKey,
    persistence    = opts.persistence,
    utilities      = utilsForHeader,
    headerHeight   = HEADER_H,
    onSort = function(key, dir)
      sortKey = key
      sortDir = dir
      -- Re-sort the master list so subsequent filter passes inherit
      -- order without re-sorting per keystroke.
      SortEntries(allEntries, sortKey, sortDir == SortDir.ASC)
      Refresh()
    end,
    onColumnResize = function()
      if not scrollBox then return end
      scrollBox:ForEachFrame(function(row)
        if row._cells and row._entry then
          RepositionRow(row, header:GetColumns())
        end
      end)
    end,
  })
  header:SetSort(sortKey, sortDir)

  ---------------------------------------------------------------------------
  -- ScrollBox + scrollbar (modern virtualized list)
  ---------------------------------------------------------------------------
  scrollBox = CreateFrame("Frame", nil, frame, "WowScrollBoxList")
  scrollBox:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -2)
  scrollBox:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -SCROLLBAR_W - PAD - 4, PAD)

  local scrollBar = CreateFrame("EventFrame", nil, frame, "MinimalScrollBar")
  scrollBar:SetPoint("TOPLEFT", scrollBox, "TOPRIGHT", 4, 0)
  scrollBar:SetPoint("BOTTOMLEFT", scrollBox, "BOTTOMRIGHT", 4, 0)

  dataProvider = CreateDataProvider()

  local scrollView = CreateScrollBoxListLinearView()
  scrollView:SetElementExtent(ROW_HEIGHT)
  scrollView:SetElementInitializer("Button", function(row, data)
    EnsureRowStructure(row, header:GetColumns())

    -- Reset and bind handlers (clean per virtualization cycle).
    -- Selection repaint is the consumer's job: call frame:RefreshSelection()
    -- after committing so a cancelled commit doesn't leave a stale highlight.
    row:SetScript("OnClick", function(self)
      if not self._entry then return end
      onPreview(self._entry.value, self._entry)
      if onSelect then onSelect(self._entry.value, self._entry) end
    end)
    row.Preview:SetScript("OnClick", function()
      if not row._entry then return end
      onPreview(row._entry.value, row._entry)
    end)

    -- Tooltip with technical detail
    row:SetScript("OnEnter", function(self)
      if not self._entry then return end
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetText(Sound.StripColors(self._entry.label or ""), 1, 1, 1)
      local color = PillColorForEntry(self._entry)
      GameTooltip:AddLine("Source: |cFF" .. color .. SourceDisplayName(self._entry) .. "|r", 1, 1, 1)
      GameTooltip:AddLine("Type: |cFF888888" .. (self._entry.kind or "") .. "|r", 1, 1, 1)
      if self._entry.path then
        GameTooltip:AddLine(" ", 1, 1, 1)
        GameTooltip:AddLine("|cFF666666" .. self._entry.path .. "|r", 1, 1, 1, true)
      elseif type(self._entry.raw) == "number" then
        GameTooltip:AddLine("|cFF666666ID: " .. self._entry.raw .. "|r", 1, 1, 1)
      end
      GameTooltip:AddLine(" ", 1, 1, 1)
      GameTooltip:AddLine("|cFFAAAAAAClick to use this sound|r", 1, 1, 1)
      GameTooltip:Show()
    end)
    row:SetScript("OnLeave", GameTooltip_Hide)

    PopulateRow(row, data, header:GetColumns(), getCurrentValue(), rowIndexOf[data])
  end)

  ScrollUtil.InitScrollBoxListWithScrollBar(scrollBox, scrollBar, scrollView)
  scrollBox:SetDataProvider(dataProvider)

  ---------------------------------------------------------------------------
  -- Filtering + refresh
  ---------------------------------------------------------------------------
  local function MatchesSource(e, src)
    if src == "All"      then return true end
    if src == "Blizzard" then return e.source == "Blizzard" end
    if src:sub(1, 10) == "Blizzard: " then
      return e.source == "Blizzard" and e.pack == src:sub(11)
    end
    -- Anything else is an LSM pack name (auto-derived from the addon
    -- folder, e.g. "Astral", "Causese", "ElvUI", "Other LSM").
    return e.source == "LibSharedMedia" and e.pack == src
  end

  local function ComputeFiltered()
    filteredEntries = {}
    local lower = searchText:lower()
    local hasSearch = lower ~= ""

    for i = 1, #allEntries do
      local e = allEntries[i]
      if MatchesSource(e, activeSource) then
        if not hasSearch then
          filteredEntries[#filteredEntries + 1] = e
        elseif (e._sortName or ""):find(lower, 1, true) then
          -- _sortName is already color-stripped + lowercased at creation
          filteredEntries[#filteredEntries + 1] = e
        end
      end
    end

    -- allEntries is pre-sorted; filteredEntries inherits the order.
    wipe(rowIndexOf)
    for i = 1, #filteredEntries do
      rowIndexOf[filteredEntries[i]] = i
    end
  end

  Refresh = function()
    ComputeFiltered()
    dataProvider:Flush()
    -- Bulk insert with a single OnInsert event: replaces N per-element
    -- Insert calls each of which would notify the scroll box. With ~800
    -- Blizzard entries this turns ~800ms of layout thrash into ~10ms.
    if dataProvider.InsertTable then
      dataProvider:InsertTable(filteredEntries)
    else
      -- Fallback for older clients without InsertTable
      for i = 1, #filteredEntries do
        dataProvider:Insert(filteredEntries[i])
      end
    end
    countText:SetText(string.format(
      "|cFF888888%d %s|r",
      #filteredEntries,
      #filteredEntries == 1 and "sound" or "sounds"
    ))
  end

  ---------------------------------------------------------------------------
  -- Build entries. CobySuite.Sound.GetEntries is module-level cached, so
  -- this is O(1) after first call; we sort a local copy so a re-sort here
  -- doesn't disturb the cache shared with other consumers. The copy is kept
  -- until the catalog generation moves.
  ---------------------------------------------------------------------------
  local lastGeneration
  local function RebuildAllEntries()
    local generation = Sound.GetCatalogGeneration()
    if lastGeneration == generation then
      -- Current allEntries is still valid. A sort change re-sorts it
      -- separately (onSort).
      return
    end
    local source = Sound.GetEntries()
    -- Shallow copy so our sort doesn't mutate the cached order shared
    -- with other browser instances.
    allEntries = {}
    for i = 1, #source do allEntries[i] = source[i] end
    SortEntries(allEntries, sortKey, sortDir == SortDir.ASC)
    lastGeneration = generation
  end

  ---------------------------------------------------------------------------
  -- Source filter dropdown wiring
  ---------------------------------------------------------------------------
  -- Blizzard runs this builder whenever the menu is set up, shown or
  -- opened; the names and counts come from the catalog's count snapshot, so
  -- no build repeats a scan
  sourceDD:SetupMenu(function(_, root)
    local sources, counts, total = Sound.GetSourceCounts()

    root:CreateRadio(string.format("All (%d)", total or 0),
      function() return activeSource == "All" end,
      function()
        activeSource = "All"
        sourceDD:OverrideText("All")
        RebuildAllEntries()
        Refresh()
      end)
    for _, src in ipairs(sources) do
      local capt = src
      root:CreateRadio(string.format("%s (%d)", src, counts[src] or 0),
        function() return activeSource == capt end,
        function()
          activeSource = capt
          sourceDD:OverrideText(capt)
          RebuildAllEntries()
          Refresh()
        end)
    end
  end)
  sourceDD:OverrideText(activeSource)

  ---------------------------------------------------------------------------
  -- Search wiring
  ---------------------------------------------------------------------------
  searchEB:SetScript("OnTextChanged", function(self)
    searchText = self:GetText() or ""
    Refresh()
  end)
  searchEB:SetScript("OnEscapePressed", function(self)
    self:SetText("")
    self:ClearFocus()
  end)
  searchEB:SetScript("OnEnterPressed", function(self)
    self:ClearFocus()
  end)

  ---------------------------------------------------------------------------
  -- Public methods
  ---------------------------------------------------------------------------
  function frame:Refresh()
    RebuildAllEntries()
    Refresh()
  end

  function frame:RefreshSelection()
    if not scrollBox then return end
    local cur = getCurrentValue()
    scrollBox:ForEachFrame(function(row)
      if row._entry then
        row.SelectedBg:SetShown(row._entry.value == cur)
      end
    end)
  end

  -- Initial fill (deferred one frame so PLAYER_LOGIN-time addons that
  -- register LSM sounds late still get picked up)
  C_Timer.After(0, function()
    if frame:IsObjectType("Frame") then
      frame:Refresh()
    end
  end)

  return frame
end
