-------------------------------------------------------------------------------
-- CobySuite.UI.TableHeaderMixin: shared sortable, resizable column headers
--
-- Provides column headers with drag-to-resize, click-to-sort, double-click
-- auto-fit, right-click reset, and persistent column widths. Each consumer
-- passes its own column definitions, persistence config, and callbacks.
-------------------------------------------------------------------------------

CobySuite_ApexFury.UI = CobySuite_ApexFury.UI or {}

local MIN_COL_WIDTH = 25
local DEFAULT_COL_WIDTH = 150   -- a column declared without a width
local SortDir = CobySuite_ApexFury.SortDir
local IsFiniteNumber = CobySuite_ApexFury.Utilities.IsFiniteNumber

-- A usable column width: a finite number, never below the minimum, and no
-- wider than room when room is given. Room below the minimum still yields
-- the minimum; the header clips what does not fit.
local function ClampWidth(width, room)
  width = tonumber(width)
  if not IsFiniteNumber(width) then
    return MIN_COL_WIDTH
  end
  if room and width > room then width = room end
  return math.max(width, MIN_COL_WIDTH)
end

-- Fallbacks when no utilities table, or not that field, is provided
local DEFAULT_HEADER_BG    = {0.1, 0.1, 0.1, 0.5}
local DEFAULT_DIVIDER      = {0.3, 0.3, 0.3, 0.8}
local DEFAULT_RESIZE_HL    = {0.5, 0.5, 1.0, 0.5}
local DEFAULT_HEADER_FONT  = CobySuite_ApexFury.Utilities.Fonts.SMALL

CobySuite_ApexFury.UI.TableHeaderMixin = {}
local Mixin = CobySuite_ApexFury.UI.TableHeaderMixin

-------------------------------------------------------------------------------
-- Init
-------------------------------------------------------------------------------
-- opts:
--   columns         (table)    array of {key, label, width (default 150), sortable?, stretch?, tooltip?, justify?}
--                              At most one column stretches, to fill what the
--                              others leave. It may sit anywhere: the last
--                              column runs to the header's right edge, and one
--                              before others takes the room left over (never
--                              less than its minimum), the columns after it
--                              moving with it; each of those is resized from
--                              its left edge, the one that moves. Call
--                              GetColumnBounds() for where each column sits,
--                              so rows can follow.
--   persistenceKey  (string?)  unique key for saving column widths
--   persistence     (table?)   { savedVariable = "NAME", path = "key" } for width storage;
--                              only the columns a player resized are saved
--   widthsVersion   (number?)  saved widths of another version are ignored, so
--                              new default widths reach players who saved the
--                              old ones (the sound browser's Source column)
--   utilities       (table?)   addon's Utilities table (Colors, HeaderBg, Fonts, AddTooltip; AddTooltip defaults to CobySuite.UI.AddTooltip)
--   onSort          (fn?)      callback(key, dir) fired on column click
--   onColumnResize  (fn?)      callback() fired whenever column widths change:
--                              each step of a drag, an auto-fit, a reset, a fit
--   measureColumn   (fn?)      callback(colIndex, key) -> width for auto-fit
--   onUserResize    (fn?)      callback(colIndex, how) when the user sizes a
--                              column: how is "drag" (a drag that changed its
--                              width), "fit" (a divider's double-click) or
--                              "reset" (Reset Column Widths; colIndex nil).
--                              For a table that sizes columns itself until
--                              the user does (AutoFitColumns).
--   headerHeight    (number?)  default 20
--   headerFont      (string?)  font object name, default from utilities or GameFontNormalSmall
--   leftPadding     (number?)  default 0
--   minStretch      (number?)  the stretch column's own minimum width: a drag
--                              or auto-fit never leaves it less, and
--                              fitToWidth keeps it that much room. Default:
--                              the stretch column may shrink to MIN_COL_WIDTH.
--   fitToWidth      (bool?)    default false. When the columns are wider than
--                              the header, shrink the width above each
--                              column's minimum, in proportion, so every
--                              column stays in view; the wanted widths are
--                              kept (and saved), so a wider header gives the
--                              room back. Call :FitColumns() after changes.
--                              Pressing a divider (a click, the start of a
--                              drag, or the auto-fit double-click) makes every
--                              column's current fitted width its wanted
--                              width, which the release saves: once the user
--                              touches a divider, the layout on screen is
--                              the one kept.
--
-- Every width dragged or auto-fitted is at least MIN_COL_WIDTH; a declared
-- width is used as given. A saved width that is not a finite number of at
-- least MIN_COL_WIDTH keeps the declared width.
-------------------------------------------------------------------------------
function Mixin:Init(opts)
  -- Init again on the same header (a table that switches its column set):
  -- the old buttons and handles go, or they stay on screen and clickable
  -- beside the new ones
  for _, btn in ipairs(self._headerButtons or {}) do btn:Hide() end
  for _, handle in pairs(self._resizeHandles or {}) do handle:Hide() end
  self._columns = {}
  self._headerButtons = {}
  self._resizeHandles = {}
  self._persistenceKey = opts.persistenceKey
  self._persistence = opts.persistence
  self._widthsVersion = opts.widthsVersion
  self._utilities = opts.utilities
  self._onSort = opts.onSort
  self._onColumnResize = opts.onColumnResize
  self._measureColumn = opts.measureColumn
  self._onUserResize = opts.onUserResize
  self._headerHeight = opts.headerHeight or 20
  self._leftPadding = opts.leftPadding or 0
  self._minStretch = opts.minStretch
  self._fitToWidth = opts.fitToWidth or false
  self._sortKey = nil
  self._sortDir = nil

  -- Resolve header font
  local utils = opts.utilities
  self._headerFont = opts.headerFont
    or (utils and utils.Fonts and utils.Fonts.SMALL)
    or DEFAULT_HEADER_FONT

  -- Copy column definitions (don't mutate caller's table)
  for _, col in ipairs(opts.columns) do
    table.insert(self._columns, {
      key = col.key,
      label = col.label,
      width = col.width,
      want = col.width,
      _defaultWidth = col.width,
      sortable = col.sortable ~= false,
      stretch = col.stretch or false,
      tooltip = col.tooltip,
      justify = col.justify or "LEFT",
    })
  end

  self:_RestoreWidths()
  self:_BuildHeaders()
  self:_SetupDragTracking()

  -- hooked once, however often Init runs; each hook reads the current setup
  if self._fitToWidth and not self._fitHooked then
    self._fitHooked = true
    self:HookScript("OnSizeChanged", function(header) if header._fitToWidth then header:FitColumns() end end)
  end
  if self:_MidStretch() then
    -- the columns after the stretch column follow the header's width
    if not self._midHooked then
      self._midHooked = true
      self:HookScript("OnSizeChanged", function(header) if header:_MidStretch() then header:RepositionHeaders() end end)
    end
    self:RepositionHeaders()
  end
end

-- The index of a stretch column with columns after it, or nil
function Mixin:_MidStretch()
  for i, col in ipairs(self._columns) do
    if col.stretch then return i < #self._columns and i or nil end
  end
  return nil
end

-- 1 when a column's resize handle is its right edge, -1 when it is its left
-- edge (a column after a mid stretch column: its left edge is the one that
-- moves when it grows)
function Mixin:_HandleSide(index)
  local mid = self:_MidStretch()
  return (mid and index > mid) and -1 or 1
end

-- The room a drag, an auto-fit or fitToWidth must leave the stretch
-- column; none when no column stretches (a table whose columns all keep
-- their widths, like a spreadsheet's)
function Mixin:_StretchRoom()
  for _, col in ipairs(self._columns) do
    if col.stretch then return math.max(MIN_COL_WIDTH, self._minStretch or 0) end
  end
  return 0
end

-- The width the columns other than index take, for how wide index may
-- grow: their widths, or with fitToWidth their minimums, since fitting
-- gives the grown column's room from theirs (FitColumns)
function Mixin:_OthersWidth(index)
  local total = 0
  for j, c in ipairs(self._columns) do
    if j ~= index and not c.stretch then
      total = total + (self._fitToWidth and MIN_COL_WIDTH or (c.width or DEFAULT_COL_WIDTH))
    end
  end
  return total
end

-------------------------------------------------------------------------------
-- Persistence
-------------------------------------------------------------------------------
function Mixin:_SaveWidths()
  if not self._persistence or not self._persistenceKey then return end
  local sv = _G[self._persistence.savedVariable]
  if not sv then return end
  local path = self._persistence.path
  if not sv[path] then sv[path] = {} end
  -- only the columns a player resized (dragged or fitted), so a later
  -- default reaches every column they left alone
  local saved = { _v = self._widthsVersion }
  for _, col in ipairs(self._columns) do
    if col.key and col.width and not col.stretch and col.userSet then
      saved[col.key] = col.want or col.width
    end
  end
  sv[path][self._persistenceKey] = saved
end

function Mixin:_RestoreWidths()
  if not self._persistence or not self._persistenceKey then return end
  local sv = _G[self._persistence.savedVariable]
  if not sv then return end
  local saved = sv[self._persistence.path]
    and sv[self._persistence.path][self._persistenceKey]
  if type(saved) ~= "table" then return end
  if self._widthsVersion and saved._v ~= self._widthsVersion then return end
  for _, col in ipairs(self._columns) do
    if col.key and not col.stretch and saved[col.key] ~= nil then
      -- Earlier builds could save negative widths from a narrow window;
      -- anything that is not a usable width keeps the default
      local w = tonumber(saved[col.key])
      if IsFiniteNumber(w) and w >= MIN_COL_WIDTH then
        col.width, col.want, col.userSet = w, w, true
      end
    end
  end
end

-------------------------------------------------------------------------------
-- Build header buttons and resize handles
-------------------------------------------------------------------------------
function Mixin:_BuildHeaders()
  local h = self._headerHeight
  self:SetHeight(h)

  -- Columns sit at fixed x offsets, so whenever the header is narrower than the
  -- sum of its column widths (a shrunk window, or defaults that never fitted in
  -- the first place) the right-hand columns would draw straight over whatever
  -- sits beside the table: the scrollbar, a detail pane, the window edge. Clip
  -- to the header's own bounds so they are occluded instead.
  self:SetClipsChildren(true)

  -- Resolve colors from utilities or use defaults
  local utils = self._utilities
  local bgColor      = (utils and utils.HeaderBg and utils.HeaderBg.color) or DEFAULT_HEADER_BG
  local dividerColor = (utils and utils.Colors and utils.Colors.DIVIDER_GRAY) or DEFAULT_DIVIDER
  local resizeColor  = (utils and utils.Colors and utils.Colors.RESIZE_HIGHLIGHT) or DEFAULT_RESIZE_HL
  local addTooltipFn = (utils and utils.AddTooltip) or CobySuite_ApexFury.UI.AddTooltip
  local x = self._leftPadding

  for i, col in ipairs(self._columns) do
    local btn = CreateFrame("Button", nil, self)

    if col.stretch then
      btn:SetPoint("TOPLEFT", x, 0)
      btn:SetPoint("TOPRIGHT", self, "TOPRIGHT", 0, 0)
      btn:SetHeight(h)
    else
      btn:SetSize(col.width or DEFAULT_COL_WIDTH, h)
      btn:SetPoint("TOPLEFT", x, 0)
    end

    local text = btn:CreateFontString(nil, "OVERLAY", self._headerFont)
    text:SetPoint("CENTER")
    text:SetText(col.label or "")
    btn._headerText = text

    local sortArrow = btn:CreateFontString(nil, "OVERLAY", self._headerFont)
    sortArrow:SetPoint("LEFT", text, "RIGHT", 2, 0)
    btn._sortArrow = sortArrow

    local bg = btn:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(bgColor[1], bgColor[2], bgColor[3], bgColor[4] or 0.5)

    local header = self
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    btn:SetScript("OnClick", function(_, mouseButton)
      if mouseButton == "RightButton" then
        header:_ShowContextMenu(btn)
      elseif col.sortable then
        header:_HandleSortClick(i)
      end
    end)

    if col.tooltip and addTooltipFn then
      addTooltipFn(btn, col.tooltip)
    end

    -- Divider line on right edge (not on a last stretch column)
    if not col.stretch or i < #self._columns then
      local divider = btn:CreateTexture(nil, "ARTWORK")
      divider:SetSize(1, h - 6)
      divider:SetPoint("RIGHT", 0, 0)
      divider:SetColorTexture(dividerColor[1], dividerColor[2], dividerColor[3], dividerColor[4] or 1)
    end

    self._headerButtons[i] = btn

    -- Resize handle (not on stretch column)
    if not col.stretch then
      local handle = CreateFrame("Button", nil, self)
      handle:SetSize(6, h)
      handle:SetPoint("TOPLEFT", x + (col.width or DEFAULT_COL_WIDTH) - 3, 0)
      handle:SetFrameLevel(self:GetFrameLevel() + 2)

      local highlight = handle:CreateTexture(nil, "OVERLAY")
      highlight:SetSize(2, h)
      highlight:SetPoint("CENTER")
      highlight:SetColorTexture(resizeColor[1], resizeColor[2], resizeColor[3], resizeColor[4] or 1)
      highlight:Hide()

      handle:EnableMouse(true)
      local capturedIndex = i
      handle:SetScript("OnMouseDown", function()
        if header._fitToWidth then
          -- The layout on screen becomes the wanted one, so the drag moves
          -- only the column being dragged
          for _, c in ipairs(header._columns) do
            if not c.stretch then c.want = c.width end
          end
        end
        header._dragIndex = capturedIndex
        header._dragHighlight = highlight
        header._dragStartX = GetCursorPosition() / (header:GetEffectiveScale() or 1)
        header._dragStartWidth = header._columns[capturedIndex].width or DEFAULT_COL_WIDTH
      end)

      -- the drag ends on the release too, not only when OnUpdate next sees
      -- the button up: a release it missed let the next left press anywhere
      -- (the window's resize grip) carry on the old drag
      handle:SetScript("OnMouseUp", function()
        if header._dragIndex then header:_StopDrag() end
      end)

      handle:RegisterForClicks("LeftButtonUp")
      handle:SetScript("OnDoubleClick", function()
        header:AutoFitColumn(capturedIndex)
        if header._onUserResize then header._onUserResize(capturedIndex, "fit") end
      end)

      handle:SetScript("OnEnter", function() highlight:Show() end)
      handle:SetScript("OnLeave", function()
        if not header._dragIndex then highlight:Hide() end
      end)

      self._resizeHandles[i] = handle
      x = x + (col.width or DEFAULT_COL_WIDTH)
    end
  end
end

-------------------------------------------------------------------------------
-- Drag tracking via OnUpdate
-------------------------------------------------------------------------------
function Mixin:_SetupDragTracking()
  local header = self
  -- hidden mid-drag (a tab switch, the window closing): the drag ends there
  if not self._hideHooked then
    self._hideHooked = true
    self:HookScript("OnHide", function(h) if h._dragIndex then h:_StopDrag() end end)
  end
  self:SetScript("OnUpdate", function()
    if not header._dragIndex then return end

    if not IsMouseButtonDown("LeftButton") then
      header:_StopDrag()
      return
    end

    local cursorX = GetCursorPosition() / (header:GetEffectiveScale() or 1)
    local delta = (cursorX - header._dragStartX) * header:_HandleSide(header._dragIndex)

    -- The room the other columns leave (with fitToWidth, all but their
    -- minimums: they give way as it grows); the result never drops below
    -- the minimum, even when there is less room than that
    local cols = header._columns
    local room = header:GetWidth() - header._leftPadding - header:_OthersWidth(header._dragIndex) - header:_StretchRoom()
    local newWidth = ClampWidth(header._dragStartWidth + delta, room)

    if cols[header._dragIndex].width ~= newWidth then
      cols[header._dragIndex].width = newWidth
      cols[header._dragIndex].want = newWidth
      if header._fitToWidth then header:FitColumns() end
      header:RepositionHeaders()
      if header._onColumnResize then
        header._onColumnResize()
      end
    end
  end)
end

function Mixin:_StopDrag()
  if self._dragHighlight then
    self._dragHighlight:Hide()
  end
  local index = self._dragIndex
  local moved = index and self._columns[index] and self._columns[index].width ~= self._dragStartWidth
  if moved then self._columns[index].userSet = true end
  if self._fitToWidth then
    -- the columns that gave way keep the widths on screen
    for _, c in ipairs(self._columns) do
      if not c.stretch then c.want = c.width end
    end
  end
  self._dragIndex = nil
  self._dragHighlight = nil
  self:_SaveWidths()
  if moved and self._onUserResize then self._onUserResize(index, "drag") end
end

-------------------------------------------------------------------------------
-- Sort handling
-------------------------------------------------------------------------------
function Mixin:_HandleSortClick(colIndex)
  local col = self._columns[colIndex]
  if not col or not col.sortable then return end

  -- Clear arrows on other headers
  for j, btn in ipairs(self._headerButtons) do
    if j ~= colIndex and btn._sortArrow then
      btn._sortArrow:SetText("")
    end
  end

  -- The same column flips direction; a new column starts ascending
  local btn = self._headerButtons[colIndex]
  if self._sortKey == col.key then
    self._sortDir = self._sortDir == SortDir.ASC and SortDir.DESC or SortDir.ASC
  else
    self._sortKey = col.key
    self._sortDir = SortDir.ASC
  end

  btn._sortArrow:SetText(self._sortDir == SortDir.ASC and " ^" or " v")

  if self._onSort then
    self._onSort(self._sortKey, self._sortDir)
  end
end

-------------------------------------------------------------------------------
-- Right-click context menu
-------------------------------------------------------------------------------
function Mixin:_ShowContextMenu(anchorFrame)
  MenuUtil.CreateContextMenu(anchorFrame, function(_, rootDescription)
    rootDescription:CreateButton("Reset Column Widths", function()
      self:ResetColumnWidths()
      if self._onUserResize then self._onUserResize(nil, "reset") end
    end)
  end)
end

-------------------------------------------------------------------------------
-- Public API
-------------------------------------------------------------------------------
function Mixin:GetColumns()
  return self._columns
end

-- GetColumnBounds(): { { key, left, width } } per column, left from the
-- header's left edge (leftPadding included); the stretch column's width is
-- the room the others leave, never below its minimum
function Mixin:GetColumnBounds()
  local fixed = 0
  for _, col in ipairs(self._columns) do
    if not col.stretch then fixed = fixed + (col.width or DEFAULT_COL_WIDTH) end
  end
  local stretch = math.max((self:GetWidth() or 0) - self._leftPadding - fixed, self:_StretchRoom())
  local bounds, x = {}, self._leftPadding
  for i, col in ipairs(self._columns) do
    local width = col.stretch and stretch or (col.width or DEFAULT_COL_WIDTH)
    bounds[i] = { key = col.key, left = x, width = width }
    x = x + width
  end
  return bounds
end

function Mixin:RepositionHeaders()
  local x = self._leftPadding
  local mid = self:_MidStretch()
  local bounds = mid and self:GetColumnBounds()

  for i, col in ipairs(self._columns) do
    local btn = self._headerButtons[i]
    btn:ClearAllPoints()

    if col.stretch and i == mid then
      btn:SetSize(bounds[i].width, self._headerHeight)
      btn:SetPoint("TOPLEFT", x, 0)
      x = x + bounds[i].width
    elseif col.stretch then
      btn:SetPoint("TOPLEFT", x, 0)
      btn:SetPoint("TOPRIGHT", self, "TOPRIGHT", 0, 0)
      btn:SetHeight(self._headerHeight)
    else
      btn:SetSize(col.width or DEFAULT_COL_WIDTH, self._headerHeight)
      btn:SetPoint("TOPLEFT", x, 0)
    end

    local handle = self._resizeHandles[i]
    if handle then
      handle:ClearAllPoints()
      local edge = self:_HandleSide(i) < 0 and x or x + (col.width or DEFAULT_COL_WIDTH)
      handle:SetPoint("TOPLEFT", edge - 3, 0)
    end

    if not col.stretch then
      x = x + (col.width or DEFAULT_COL_WIDTH)
    end
  end
end

function Mixin:SetSort(key, dir)
  self._sortKey = key
  self._sortDir = dir

  for i, col in ipairs(self._columns) do
    local btn = self._headerButtons[i]
    if col.key == key then
      btn._sortArrow:SetText(dir == SortDir.ASC and " ^" or " v")
    else
      btn._sortArrow:SetText("")
    end
  end
end

function Mixin:GetSort()
  return self._sortKey, self._sortDir
end

-- The width a column needs: its title (and sort arrow) and, through
-- measureColumn, its content
function Mixin:_ContentWidth(colIndex)
  local col = self._columns[colIndex]
  local PADDING = 16

  -- Measure header text width
  local headerBtn = self._headerButtons[colIndex]
  local maxWidth = (headerBtn._headerText:GetUnboundedStringWidth() or 0) + PADDING

  local arrowWidth = headerBtn._sortArrow:GetUnboundedStringWidth() or 0
  if arrowWidth > 0 then
    maxWidth = maxWidth + arrowWidth + 4
  end

  -- Delegate content measurement to consumer
  if self._measureColumn then
    local contentWidth = self._measureColumn(colIndex, col.key)
    if contentWidth and contentWidth > maxWidth then
      maxWidth = contentWidth
    end
  end
  return maxWidth
end

-- AutoFitColumns(keep): every column but a stretch one and those keep names
-- ({ [key] = true }) sized to its title and content, as a double-click
-- would, without saving; fitToWidth then shrinks them into the header when
-- they don't fit. For a table that sizes itself to what it shows until the
-- user sizes a column (onUserResize).
function Mixin:AutoFitColumns(keep)
  -- the kept columns stay as the user sized them when fitting, too
  self._pinned = keep
  for i, col in ipairs(self._columns) do
    if not col.stretch and not (keep and keep[col.key]) then
      local width = ClampWidth(self:_ContentWidth(i))
      col.width, col.want = width, width
    end
  end
  self:RepositionHeaders()
  if self._fitToWidth then self:FitColumns() end
  if self._onColumnResize then
    self._onColumnResize()
  end
end

function Mixin:AutoFitColumn(colIndex)
  local col = self._columns[colIndex]
  if not col or col.stretch then return end

  local maxWidth = self:_ContentWidth(colIndex)

  -- Clamp to the room the other columns leave (with fitToWidth, all but
  -- their minimums, which give way), never below the minimum
  local room = self:GetWidth() - self._leftPadding - self:_OthersWidth(colIndex) - self:_StretchRoom()
  col.width = ClampWidth(maxWidth, room)
  col.want = col.width
  col.userSet = true
  if self._fitToWidth then
    self._holdIndex = colIndex
    self:FitColumns()
    self._holdIndex = nil
    for _, c in ipairs(self._columns) do
      if not c.stretch then c.want = c.width end
    end
  end
  self:RepositionHeaders()
  if self._onColumnResize then
    self._onColumnResize()
  end
  self:_SaveWidths()
end

function Mixin:ResetColumnWidths()
  for _, col in ipairs(self._columns) do
    if col._defaultWidth then
      col.width = col._defaultWidth
      col.want = col._defaultWidth
    end
    col.userSet = nil
  end
  self:RepositionHeaders()
  if self._onColumnResize then
    self._onColumnResize()
  end
  self:_SaveWidths()
  if self._fitToWidth then self:FitColumns() end
end

-- Fits the columns into the header's width (opts.fitToWidth). Every column
-- takes its wanted width when they all fit. Otherwise only the width above
-- each column's minimum shrinks, by one shared factor, so no column goes
-- below its floor; when even the minimums do not fit, all sit at the
-- minimum and the header clips the rest. The column being dragged or
-- fitted, and the columns the user sized (AutoFitColumns' keep), hold their
-- widths while the others give way; only when the others' minimums leave
-- them no room does every column shrink alike.
function Mixin:FitColumns()
  local room = self:GetWidth() - self._leftPadding - self:_StretchRoom()
  if room <= 0 then return end

  local pinned = self._pinned
  local function Holds(i, col)
    return i == self._dragIndex or i == self._holdIndex or (pinned ~= nil and col.key ~= nil and pinned[col.key] == true)
  end
  local function Tally(holding)
    local held, total, spare, loose = 0, 0, 0, 0
    for i, col in ipairs(self._columns) do
      if not col.stretch then
        local want = ClampWidth(col.want or col.width)
        if holding and Holds(i, col) then
          held = held + want
        else
          total, spare, loose = total + want, spare + (want - MIN_COL_WIDTH), loose + 1
        end
      end
    end
    return held, total, spare, loose
  end
  local holding = true
  local held, total, spare, loose = Tally(true)
  if held > 0 and held + loose * MIN_COL_WIDTH > room then
    holding = false
    held, total, spare = Tally(false)
  end

  local excess = total - (room - held)
  local keep = 1
  if excess > 0 then
    keep = spare > 0 and math.max(0, 1 - excess / spare) or 0
  end

  local changed = false
  for i, col in ipairs(self._columns) do
    if not col.stretch then
      local want = ClampWidth(col.want or col.width)
      local width = want
      if excess > 0 and not (holding and Holds(i, col)) then
        width = math.floor(MIN_COL_WIDTH + (want - MIN_COL_WIDTH) * keep)
      end
      if col.width ~= width then
        col.width = width
        changed = true
      end
    end
  end

  if changed then
    self:RepositionHeaders()
    if self._onColumnResize then
      self._onColumnResize()
    end
  end
end
