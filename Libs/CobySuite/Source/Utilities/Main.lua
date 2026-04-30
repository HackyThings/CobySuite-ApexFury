---------------------------------------------------------------------------
-- CobySuite Shared Utilities: Constants + Utility Functions
-- All consumer addons import from here via CobySuite.Utilities
---------------------------------------------------------------------------
CobySuite.Utilities = CobySuite.Utilities or {}
local U = CobySuite.Utilities

---------------------------------------------------------------------------
-- Auction House
---------------------------------------------------------------------------
U.AH_CUT = 0.05

function U.NetProfit(marketValue, buyPrice)
  if not marketValue or marketValue <= 0 then return 0 end
  return math.floor(marketValue * (1 - U.AH_CUT)) - buyPrice
end

---------------------------------------------------------------------------
-- Fonts
---------------------------------------------------------------------------
U.Fonts = {
  TITLE = "GameFontNormalLarge",
  BODY  = "GameFontHighlight",
  SMALL = "GameFontNormalSmall",
  DATA  = "GameFontHighlightSmall",
}

---------------------------------------------------------------------------
-- Button sizes
---------------------------------------------------------------------------
U.ButtonSize = {
  SMALL  = { height = 20, fontSize = 9 },
  MEDIUM = { height = 22, fontSize = 10 },
  LARGE  = { height = 24, fontSize = nil },
}

---------------------------------------------------------------------------
-- Spacing
---------------------------------------------------------------------------
U.Spacing = {
  BUTTON_GAP = 4,
  GROUP_GAP  = 8,
}

---------------------------------------------------------------------------
-- Header background
---------------------------------------------------------------------------
U.HeaderBg = {
  color = { 0.1, 0.1, 0.1, 0.5 },
}

---------------------------------------------------------------------------
-- Edit box heights
---------------------------------------------------------------------------
U.EditBoxHeight = {
  INLINE = 18,
  INPUT  = 20,
  SEARCH = 22,
}

---------------------------------------------------------------------------
-- Colors — shared semantic palette
---------------------------------------------------------------------------
U.Colors = {
  WARNING_RED      = { 1, 0.3, 0.3 },
  SUCCESS_GREEN    = { 0, 1, 0 },
  DISABLED_GRAY    = { 0.5, 0.5, 0.5 },
  STATUS_GOLD      = { 1, 0.82, 0 },
  CONTENT_BG       = { 0, 0, 0, 0.4 },
  TOAST_BG         = { 0, 0, 0, 0.9 },
  CONTENT_BORDER   = { 0.4, 0.4, 0.4, 0.8 },
  DIALOG_BG        = { 0.1, 0.1, 0.1, 1 },
  DIVIDER_GRAY     = { 0.4, 0.4, 0.4, 0.6 },
  RESIZE_HIGHLIGHT = { 0.6, 0.8, 1.0, 0.6 },
  BAR_BG           = { 0.1, 0.1, 0.1, 0.8 },
  HIGHLIGHT_WHITE  = { 1, 1, 1 },
  WINDOW_BG        = { 0.05, 0.05, 0.05, 0.95 },
  HOVER_HIGHLIGHT  = { 1, 1, 1, 0.05 },
  SIDEBAR_BG       = { 0.08, 0.08, 0.08, 0.9 },
  ALT_ROW_BG       = { 1, 1, 1, 0.03 },
  LIGHT_GRAY       = { 0.8, 0.8, 0.8 },
  LABEL_GRAY       = { 0.7, 0.7, 0.7 },

  -- Inline text color codes (for WoW escape sequences)
  TEXT_GREEN  = "00FF00",
  TEXT_RED    = "FF0000",
  TEXT_YELLOW = "FFFF00",
  TEXT_ORANGE = "FF8800",
}

---------------------------------------------------------------------------
-- Backdrops
---------------------------------------------------------------------------
U.Backdrops = {
  MENU = {
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 16, edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
  },
  DIALOG = {
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 8, right = 8, top = 8, bottom = 8 },
  },
  CONTENT = {
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 14,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
  },
  BUY_FRAME = {
    bgFile = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Buttons\\WHITE8x8",
    edgeSize = 1,
  },
}

---------------------------------------------------------------------------
-- Color helper
---------------------------------------------------------------------------
function U.WrapColor(hexColor, text)
  return "|cFF" .. hexColor .. text .. "|r"
end

---------------------------------------------------------------------------
-- Table utilities
---------------------------------------------------------------------------
function U.TableCount(t)
  local count = 0
  for _ in pairs(t) do count = count + 1 end
  return count
end

function U.SortByColumn(data, columnKey, ascending)
  table.sort(data, function(a, b)
    local va, vb = a[columnKey], b[columnKey]
    if va == nil and vb == nil then return false end
    if va == nil then return false end
    if vb == nil then return true end
    if type(va) == "string" then
      va = string.lower(va)
      vb = type(vb) == "string" and string.lower(vb) or vb
    end
    if ascending then
      return va < vb
    else
      return va > vb
    end
  end)
end

function U.SortByQualityThenName(a, b)
  if a.quality ~= b.quality then
    return a.quality > b.quality
  end
  return a.name < b.name
end

function U.NumberComparator(sortDir, field)
  if sortDir == 1 then
    return function(left, right) return (left[field] or 0) < (right[field] or 0) end
  else
    return function(left, right) return (left[field] or 0) > (right[field] or 0) end
  end
end

function U.StringComparator(sortDir, field)
  if sortDir == 1 then
    return function(left, right) return (left[field] or "") < (right[field] or "") end
  else
    return function(left, right) return (left[field] or "") > (right[field] or "") end
  end
end

---------------------------------------------------------------------------
-- Gold formatting
---------------------------------------------------------------------------
local GOLD_ICON = "|TInterface\\MoneyFrame\\UI-GoldIcon:0|t"
local SILVER_ICON = "|TInterface\\MoneyFrame\\UI-SilverIcon:0|t"

function U.FormatGoldValue(copper)
  if not copper or copper <= 0 then return "" end
  return math.floor(copper / 10000)
end

function U.FormatGoldPrecise(copper)
  if not copper or copper == 0 then return "0.00" .. GOLD_ICON end
  local negative = copper < 0
  copper = math.abs(copper)
  local prefix = negative and "-" or ""
  local gold = copper / 10000
  if gold >= 1000000 then
    return prefix .. string.format("%.2fm", gold / 1000000) .. GOLD_ICON
  elseif gold >= 1000 then
    return prefix .. string.format("%.2fk", gold / 1000) .. GOLD_ICON
  elseif gold >= 1 then
    return prefix .. string.format("%.2f", gold) .. GOLD_ICON
  end
  local silver = copper / 100
  if silver >= 1 then return prefix .. string.format("%.1f", silver) .. SILVER_ICON end
  return prefix .. tostring(copper) .. "c"
end

---------------------------------------------------------------------------
-- Row styling
---------------------------------------------------------------------------
function U.AddAlternatingRowBg(row, index)
  if index % 2 == 0 then
    if not row._altRowBg then
      local c = U.Colors.ALT_ROW_BG
      local bg = row:CreateTexture(nil, "BACKGROUND")
      bg:SetAllPoints()
      bg:SetColorTexture(c[1], c[2], c[3], c[4])
      row._altRowBg = bg
    end
    row._altRowBg:Show()
  elseif row._altRowBg then
    row._altRowBg:Hide()
  end
end

---------------------------------------------------------------------------
-- Item key utilities
---------------------------------------------------------------------------
function U.ItemKeyString(itemKey)
  local suffix = itemKey.itemSuffix or 0
  local level = itemKey.itemLevel or 0
  local pet = itemKey.battlePetSpeciesID or 0
  if suffix == 0 and level == 0 and pet == 0 then
    return itemKey.itemID .. "_0_0_0"
  end
  return itemKey.itemID .. "_" .. suffix .. "_" .. level .. "_" .. pet
end

---------------------------------------------------------------------------
-- FormatKB — format kilobytes as "123.4 KB" or "1.23 MB"
---------------------------------------------------------------------------
function U.FormatKB(kb)
  if kb >= 1024 then
    return format("%.2f MB", kb / 1024)
  end
  return format("%.1f KB", kb)
end

---------------------------------------------------------------------------
-- FormatDuration — format seconds as "Xh Ym Zs", omitting zero parts
---------------------------------------------------------------------------
function U.FormatDuration(seconds)
  seconds = math.floor(seconds)
  local h = math.floor(seconds / 3600)
  local m = math.floor((seconds % 3600) / 60)
  local s = seconds % 60
  if h > 0 then return format("%dh %dm %ds", h, m, s) end
  if m > 0 then return format("%dm %ds", m, s) end
  return format("%ds", s)
end

---------------------------------------------------------------------------
-- Secure command detection
---------------------------------------------------------------------------
function U.IsSecureCommand(text)
  if not text then return false end
  local cmd = text:match("^(/[%a]+)")
  if not cmd then return false end
  return IsSecureCmd and IsSecureCmd(cmd) or false
end
