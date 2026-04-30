-------------------------------------------------------------------------------
-- CobySuite.UI.TableHeaderMixin — shared sortable, resizable column headers
--
-- Provides column headers with drag-to-resize, click-to-sort, double-click
-- auto-fit, right-click reset, and persistent column widths. Each consumer
-- passes its own column definitions, persistence config, and callbacks.
-------------------------------------------------------------------------------

CobySuite.UI = CobySuite.UI or {}

local MIN_COL_WIDTH = 25
local SortDir = CobySuite.SortDir

-- Defaults when no utilities table is provided
local DEFAULT_HEADER_BG    = {0.1, 0.1, 0.1, 0.5}
local DEFAULT_DIVIDER      = {0.3, 0.3, 0.3, 0.8}
local DEFAULT_RESIZE_HL    = {0.5, 0.5, 1.0, 0.5}
local DEFAULT_HEADER_FONT  = "GameFontNormalSmall"

CobySuite.UI.TableHeaderMixin = {}
local Mixin = CobySuite.UI.TableHeaderMixin

-------------------------------------------------------------------------------
-- Init
-------------------------------------------------------------------------------
-- opts:
--   columns         (table)    array of {key, label, width, sortable?, stretch?, tooltip?, justify?}
--   persistenceKey  (string?)  unique key for saving column widths
--   persistence     (table?)   { savedVariable = "NAME", path = "key" } for width storage
--   utilities       (table?)   addon's Utilities table (Colors, HeaderBg, Fonts, AddTooltip)
--   onSort          (fn?)      callback(key, dir) fired on column click
--   onColumnResize  (fn?)      callback() fired after drag release
--   measureColumn   (fn?)      callback(colIndex, key) -> width for auto-fit
--   headerHeight    (number?)  default 20
--   headerFont      (string?)  font object name, default from utilities or GameFontNormalSmall
--   leftPadding     (number?)  default 0
-------------------------------------------------------------------------------
function Mixin:Init(opts)
  self._columns = {}
  self._headerButtons = {}
  self._resizeHandles = {}
  self._persistenceKey = opts.persistenceKey
  self._persistence = opts.persistence
  self._utilities = opts.utilities
  self._onSort = opts.onSort
  self._onColumnResize = opts.onColumnResize
  self._measureColumn = opts.measureColumn
  self._headerHeight = opts.headerHeight or 20
  self._leftPadding = opts.leftPadding or 0
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
  local saved = {}
  for _, col in ipairs(self._columns) do
    if col.key and col.width then
      saved[col.key] = col.width
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
  if not saved then return end
  for _, col in ipairs(self._columns) do
    if col.key and saved[col.key] then
      col.width = saved[col.key]
    end
  end
end

-------------------------------------------------------------------------------
-- Build header buttons and resize handles
-------------------------------------------------------------------------------
function Mixin:_BuildHeaders()
  local h = self._headerHeight
  self:SetHeight(h)

  -- Resolve colors from utilities or use defaults
  local utils = self._utilities
  local bgColor      = (utils and utils.HeaderBg and utils.HeaderBg.color) or DEFAULT_HEADER_BG
  local dividerColor = (utils and utils.Colors and utils.Colors.DIVIDER_GRAY) or DEFAULT_DIVIDER
  local resizeColor  = (utils and utils.Colors and utils.Colors.RESIZE_HIGHLIGHT) or DEFAULT_RESIZE_HL
  local addTooltipFn = utils and utils.AddTooltip
  local x = self._leftPadding

  for i, col in ipairs(self._columns) do
    local btn = CreateFrame("Button", nil, self)

    if col.stretch then
      btn:SetPoint("TOPLEFT", x, 0)
      btn:SetPoint("TOPRIGHT", self, "TOPRIGHT", 0, 0)
      btn:SetHeight(h)
    else
      btn:SetSize(col.width or 150, h)
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

    -- Divider line on right edge (not on stretch column)
    if not col.stretch then
      local divider = btn:CreateTexture(nil, "ARTWORK")
      divider:SetSize(1, h - 6)
      divider:SetPoint("RIGHT", 0, 0)
      divider:SetColorTexture(dividerColor[1], dividerColor[2], dividerColor[3], dividerColor[4] or 1)
      btn._divider = divider
    end

    self._headerButtons[i] = btn

    -- Resize handle (not on stretch column)
    if not col.stretch then
      local handle = CreateFrame("Button", nil, self)
      handle:SetSize(6, h)
      handle:SetPoint("TOPLEFT", x + (col.width or 150) - 3, 0)
      handle:SetFrameLevel(self:GetFrameLevel() + 2)

      local highlight = handle:CreateTexture(nil, "OVERLAY")
      highlight:SetSize(2, h)
      highlight:SetPoint("CENTER")
      highlight:SetColorTexture(resizeColor[1], resizeColor[2], resizeColor[3], resizeColor[4] or 1)
      highlight:Hide()

      handle:EnableMouse(true)
      local capturedIndex = i
      handle:SetScript("OnMouseDown", function()
        header._dragIndex = capturedIndex
        header._dragHighlight = highlight
        header._dragStartX = GetCursorPosition() / (header:GetEffectiveScale() or 1)
        header._dragStartWidth = header._columns[capturedIndex].width or 150
      end)

      handle:RegisterForClicks("LeftButtonUp")
      handle:SetScript("OnDoubleClick", function()
        header:AutoFitColumn(capturedIndex)
      end)

      handle:SetScript("OnEnter", function() highlight:Show() end)
      handle:SetScript("OnLeave", function()
        if not header._dragIndex then highlight:Hide() end
      end)

      self._resizeHandles[i] = handle
      x = x + (col.width or 150)
    end
  end
end

-------------------------------------------------------------------------------
-- Drag tracking via OnUpdate
-------------------------------------------------------------------------------
function Mixin:_SetupDragTracking()
  local header = self
  self:SetScript("OnUpdate", function()
    if not header._dragIndex then return end

    if not IsMouseButtonDown("LeftButton") then
      header:_StopDrag()
      return
    end

    local cursorX = GetCursorPosition() / (header:GetEffectiveScale() or 1)
    local delta = cursorX - header._dragStartX
    local newWidth = math.max(header._dragStartWidth + delta, MIN_COL_WIDTH)

    -- Clamp: don't let this column push others below minimum
    local cols = header._columns
    local totalOther = 0
    for j, c in ipairs(cols) do
      if j ~= header._dragIndex and not c.stretch then
        totalOther = totalOther + (c.width or 150)
      end
    end
    local containerWidth = header:GetWidth()
    local maxWidth = containerWidth - totalOther - MIN_COL_WIDTH
    newWidth = math.min(newWidth, maxWidth)

    if cols[header._dragIndex].width ~= newWidth then
      cols[header._dragIndex].width = newWidth
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
  self._dragIndex = nil
  self._dragHighlight = nil
  self:_SaveWidths()
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

  -- Toggle direction
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
    end)
  end)
end

-------------------------------------------------------------------------------
-- Public API
-------------------------------------------------------------------------------
function Mixin:GetColumns()
  return self._columns
end

function Mixin:GetColumnWidth(index)
  local col = self._columns[index]
  return col and col.width
end

function Mixin:RepositionHeaders()
  local x = self._leftPadding

  for i, col in ipairs(self._columns) do
    local btn = self._headerButtons[i]
    btn:ClearAllPoints()

    if col.stretch then
      btn:SetPoint("TOPLEFT", x, 0)
      btn:SetPoint("TOPRIGHT", self, "TOPRIGHT", 0, 0)
      btn:SetHeight(self._headerHeight)
    else
      btn:SetSize(col.width or 150, self._headerHeight)
      btn:SetPoint("TOPLEFT", x, 0)
    end

    local handle = self._resizeHandles[i]
    if handle then
      handle:ClearAllPoints()
      handle:SetPoint("TOPLEFT", x + (col.width or 150) - 3, 0)
    end

    if not col.stretch then
      x = x + (col.width or 150)
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

function Mixin:ClearSort()
  self._sortKey = nil
  self._sortDir = nil
  for _, btn in ipairs(self._headerButtons) do
    if btn._sortArrow then
      btn._sortArrow:SetText("")
    end
  end
end

function Mixin:AutoFitColumn(colIndex)
  local col = self._columns[colIndex]
  if not col or col.stretch then return end

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

  -- Clamp to min and max
  maxWidth = math.max(maxWidth, MIN_COL_WIDTH)
  local totalOther = 0
  for j, c in ipairs(self._columns) do
    if j ~= colIndex and not c.stretch then
      totalOther = totalOther + (c.width or 150)
    end
  end
  local containerWidth = self:GetWidth()
  maxWidth = math.min(maxWidth, containerWidth - totalOther - MIN_COL_WIDTH)

  col.width = maxWidth
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
    end
  end
  self:RepositionHeaders()
  if self._onColumnResize then
    self._onColumnResize()
  end
  self:_SaveWidths()
end
