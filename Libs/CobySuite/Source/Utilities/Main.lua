---------------------------------------------------------------------------
-- CobySuite Shared Utilities: Constants + Utility Functions
-- All consumer addons import from here via CobySuite.Utilities
---------------------------------------------------------------------------
CobySuite_ApexFury.Utilities = CobySuite_ApexFury.Utilities or {}
local U = CobySuite_ApexFury.Utilities

---------------------------------------------------------------------------
-- Auction House
---------------------------------------------------------------------------
U.AH_CUT = 0.05

function U.NetProfit(marketValue, buyPrice)
  if not marketValue or marketValue <= 0 then return 0 end
  return math.floor(marketValue * (1 - U.AH_CUT)) - buyPrice
end

---------------------------------------------------------------------------
-- Numbers
---------------------------------------------------------------------------

-- Whether value is a number that is neither NaN nor infinite. The client's
-- Lua cannot tell NaN by comparing it: in 12.1, 0/0 == 0/0, 0/0 < math.huge
-- and 0/0 > -math.huge are all true, so value ~= value never catches it and
-- a range check lets it through. Printing compares nothing: a finite number
-- prints as digits, a point, a sign and an exponent, while NaN and the
-- infinities print letters or "#" ("-nan(ind)", "inf", "1.#INF").
function U.IsFiniteNumber(value)
  return type(value) == "number" and not string.find(tostring(value), "[^%d%.eE%+%-]")
end

---------------------------------------------------------------------------
-- Fonts
---------------------------------------------------------------------------
U.Fonts = {
  TITLE = "GameFontNormalLarge",
  HEADING = "GameFontNormalMed2",   -- gold, between TITLE and BODY (14 against 16 and 12)
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
-- Colors: shared semantic palette
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
  INFO_BLUE        = { 0.4, 0.8, 1 },       -- a positive but lesser state (Recollect's Useful)
  CAUTION_ORANGE   = { 1, 0.6, 0.2 },       -- worth a look, not an error (Recollect's Outdated)
  SAGE_GREEN       = { 0.6, 0.85, 0.6 },    -- settled, nothing left to do (Recollect's Purpose done)
  SAND_TAN         = { 0.85, 0.72, 0.55 },  -- a milder caution than orange (Recollect's Lower level)
  SLATE_GRAY       = { 0.62, 0.7, 0.86 },   -- not settled yet, told apart from plain text (Recollect's Can't tell)
  LINK_YELLOW      = { 1, 1, 0 },            -- the game's link color for quests and achievements
  LINK_BLUE        = { 0.443, 0.835, 1 },    -- the game's link color for spells (mounts, recipes, illusions)

  -- Inline text color codes (for WoW escape sequences)
  TEXT_GREEN  = "00FF00",
  TEXT_RED    = "FF0000",
  TEXT_YELLOW = "FFFF00",
  TEXT_ORANGE = "FF8800",
  TEXT_GOLD   = "FFD100",   -- the client's normal gold (NORMAL_FONT_COLOR)

  -- Slash command help and guide "Try it" lines (U.FormatCommandLine), so the
  -- command stands out from its description. Bright colors throughout: the
  -- chat frame's background is see-through, and gray or pure green text was
  -- hard to read over the game world (Cobanyte, 2026-09-27).
  HELP_HEADING  = "66CCFF",   -- the addon's name
  HELP_SECTION  = "66CCFF",   -- a group of commands
  HELP_COMMAND  = "FFD100",   -- what the player types as it is (the client's gold)
  HELP_ARGUMENT = "FFE680",   -- what the player fills in: <text>, [option]
  HELP_TEXT     = "FFFFFF",   -- the description
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
-- ColorToHex(color): "RRGGBB" for a hex string (as it is), an {r, g, b}
-- or { r =, g =, b = } table of 0 to 1 values (rounded), or a ColorMixin;
-- white for anything else
function U.ColorToHex(color)
  if type(color) == "string" then return color end
  if type(color) == "table" then
    local r = color.r or color[1] or 1
    local g = color.g or color[2] or 1
    local b = color.b or color[3] or 1
    return ("%02X%02X%02X"):format(math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5))
  end
  return "FFFFFF"
end

-- WrapColor(color, text): the text in a color, a hex string ("FFD100") or
-- anything ColorToHex takes ({1, 0.82, 0}, a ColorMixin)
function U.WrapColor(color, text)
  return "|cFF" .. U.ColorToHex(color) .. text .. "|r"
end

-- StripColors(text): the text without color codes: "|cFFxxxxxx", "|cFF 0FF 0"
-- (spaces for zeros), named "|cnHIGHLIGHT_FONT_COLOR:", and "|r" / "|R".
-- Anything but a string gives "".
function U.StripColors(text)
  if type(text) ~= "string" then return "" end
  if not text:find("|", 1, true) then return text end
  return (text:gsub("|cn[%w_]*:", ""):gsub("|c........", ""):gsub("|[rR]", ""))
end

---------------------------------------------------------------------------
-- Versions, key bindings and command lines as a player reads them
---------------------------------------------------------------------------
local BUTTON_WORDS = { BUTTON1 = "Left Click", BUTTON2 = "Right Click", BUTTON3 = "Middle Click" }

-- CompareVersions(a, b): -1, 0 or 1 as version a is older than, the same as
-- or newer than b; each run of digits is a number and missing parts count as
-- 0 ("1.10" is newer than "1.9"; "1.2" equals "1.2.0"); with the numbers
-- equal, letters right after the last number make a later build ("0.0.1a"
-- is newer than "0.0.1", "0.0.1b" than "0.0.1a")
function U.CompareVersions(a, b)
  local function Parts(v)
    local parts = {}
    for n in tostring(v or ""):gmatch("%d+") do parts[#parts + 1] = tonumber(n) end
    return parts
  end
  local function Suffix(v)
    return (tostring(v or ""):match("%d(%a*)%s*$") or ""):lower()
  end
  local pa, pb = Parts(a), Parts(b)
  for i = 1, math.max(#pa, #pb) do
    local x, y = pa[i] or 0, pb[i] or 0
    if x ~= y then return x < y and -1 or 1 end
  end
  local sa, sb = Suffix(a), Suffix(b)
  if sa ~= sb then return sa < sb and -1 or 1 end
  return 0
end

-- FormatKeyText(key): a binding string as the game saves it ("ALT-W",
-- "SHIFT-CTRL-X", "ALT-BUTTON1", "SHIFT-BUTTON4") the way a player reads
-- it ("Alt+W", "Shift+Ctrl+X", "Alt+Left Click", "Shift+Mouse 4"); nil
-- for anything but a string
function U.FormatKeyText(key)
  if type(key) ~= "string" then return nil end
  key = key:gsub("BUTTON(%d+)$", function(n) return BUTTON_WORDS["BUTTON" .. n] or ("Mouse " .. n) end)
  return (key:gsub("SHIFT%-", "Shift+"):gsub("CTRL%-", "Ctrl+"):gsub("ALT%-", "Alt+"))
end

-- A command and what it does in the help colours, as slash help and guide
-- windows show them: "/lp set <key> <value> - Change a setting". What the
-- player types as it is is HELP_COMMAND: everything before the first < or [
-- that follows a space, so a line that starts with a bracket ("[hearth")
-- stays literal. The rest of the usage is HELP_ARGUMENT and the description
-- HELP_TEXT; with no text, the command alone.
function U.FormatCommandLine(usage, text)
  local C = U.Colors
  local literal, args = usage:match("^(.-)%s+([<%[].*)$")
  if not literal then
    literal, args = usage, ""
  end
  local line = literal ~= "" and U.WrapColor(C.HELP_COMMAND, literal) or ""
  if args ~= "" then
    line = line .. (line ~= "" and " " or "") .. U.WrapColor(C.HELP_ARGUMENT, args)
  end
  if text and text ~= "" then
    line = line .. U.WrapColor(C.HELP_TEXT, " - " .. text)
  end
  return line
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
-- FormatKB: format kilobytes as "123.4 KB" or "1.23 MB"
---------------------------------------------------------------------------
function U.FormatKB(kb)
  if kb >= 1024 then
    return format("%.2f MB", kb / 1024)
  end
  return format("%.1f KB", kb)
end

---------------------------------------------------------------------------
-- FormatDuration: format seconds as "Xh Ym Zs", omitting zero parts
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
-- Timers: Debounce and Coalesce
--
-- Two ways to fold a burst of calls into one, both built on C_Timer:
--
--   local apply = U.Debounce(0.2, function(text) ... end)
--   apply:Call(text)    -- restarts the delay; fn runs once, with the LAST call's arguments
--
--   local refresh = U.Coalesce(0.2, function() ... end)
--   refresh:Call()      -- first call schedules; calls while pending are absorbed
--
-- Both handles have Cancel() (drop a pending run), IsPending(), Flush()
-- (run a pending call now) and SetDelay(seconds) for a delay that comes
-- from a setting. A delay of 0 runs on the next frame.
---------------------------------------------------------------------------
local function NewTimerHandle(delay, fn, restart)
  local h = { _timer = nil, _args = nil, _delay = delay }

  function h:SetDelay(seconds)
    self._delay = seconds
  end

  local function Fire()
    h._timer = nil
    local args = h._args
    h._args = nil
    if args then
      fn(unpack(args, 1, args.n))
    else
      fn()
    end
  end

  function h:Call(...)
    if self._timer then
      if not restart then return end
      self._timer:Cancel()
    end
    self._args = { n = select("#", ...), ... }
    self._timer = C_Timer.NewTimer(self._delay, Fire)
  end

  function h:Cancel()
    if self._timer then
      self._timer:Cancel()
      self._timer = nil
    end
    self._args = nil
  end

  function h:IsPending()
    return self._timer ~= nil
  end

  function h:Flush()
    if self._timer then
      self._timer:Cancel()
      Fire()
    end
  end

  return h
end

function U.Debounce(delay, fn)
  return NewTimerHandle(delay, fn, true)
end

function U.Coalesce(delay, fn)
  return NewTimerHandle(delay, fn, false)
end

---------------------------------------------------------------------------
-- Throttle: an OnUpdate handler that runs every `interval` seconds
--
--   local onUpdate, runSoon = U.Throttle(0.5, function(frame, elapsed) ... end)
--   frame:SetScript("OnUpdate", onUpdate)
--   frame:SetScript("OnShow", runSoon)   -- the next frame runs fn at once
--
-- fn(frame, elapsed) runs at most once per interval while the frame is
-- shown, with the time gathered since its last run; the excess over the
-- interval is dropped. The time is kept per frame, so one handler can serve
-- several frames. runSoon(frame) makes that frame's next OnUpdate run fn.
---------------------------------------------------------------------------
function U.Throttle(interval, fn)
  local gathered = setmetatable({}, { __mode = "k" })

  local function OnUpdate(frame, elapsed)
    local total = (gathered[frame] or 0) + (elapsed or 0)
    if total < interval then
      gathered[frame] = total
      return
    end
    gathered[frame] = 0
    fn(frame, total)
  end

  local function RunSoon(frame)
    gathered[frame] = interval
  end

  return OnUpdate, RunSoon
end

---------------------------------------------------------------------------
-- Secure command detection
---------------------------------------------------------------------------
-- The whole slash token, up to the first space, goes to IsSecureCmd, which
-- upper-cases it and knows every alias the client has. A capture of ASCII
-- letters only missed localized commands and cut names at punctuation.
function U.IsSecureCommand(text)
  if type(text) ~= "string" then return false end
  local cmd = text:match("^(/%S+)")
  if not cmd then return false end
  return (IsSecureCmd and IsSecureCmd(cmd)) and true or false
end

---------------------------------------------------------------------------
-- String helpers
---------------------------------------------------------------------------
-- Escape a literal string for use inside a Lua pattern.
function U.EscapePattern(text)
  return (text:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"))
end

-- A Lua pattern that matches `text` case-insensitively against a stored name:
-- each ASCII letter becomes a two-letter class ("s" -> "[sS]"), digits stay as
-- they are, and every other byte is escaped, so query text can never be read
-- as pattern syntax. Built once per query; matching then allocates nothing.
-- ASCII only: other bytes match exactly.
--   local pattern = U.CasePattern(query)
--   if name:find(pattern) then ... end
function U.CasePattern(text)
  return (string.gsub(text, ".", function(ch)
    local b = strbyte(ch)
    if b >= 97 and b <= 122 then           -- a-z
      return "[" .. ch .. string.char(b - 32) .. "]"
    elseif b >= 65 and b <= 90 then        -- A-Z
      return "[" .. string.char(b + 32) .. ch .. "]"
    elseif b >= 48 and b <= 57 then        -- 0-9
      return ch
    end
    return "%" .. ch                       -- literal for any other byte
  end))
end

-- Replace {key} placeholders in a template with values[key]. Keys are
-- matched lower-case; a placeholder with no value stays as typed. The
-- function replacement keeps hyperlink escape codes in the values out of
-- pattern interpretation.
--   U.ExpandPlaceholders("I can craft {item} for {name}", { item = link, name = "Bob" })
function U.ExpandPlaceholders(template, values)
  return (template:gsub("{(%a+)}", function(key)
    local value = values[key:lower()]
    if value == nil then return nil end
    return tostring(value)
  end))
end

-- The number of characters in UTF-8 text: every byte but a continuation
-- byte (128 to 191) starts one
function U.Utf8Length(text)
  local _, n = tostring(text):gsub("[^\128-\191]", "")
  return n
end

-- text cut to at most maxChars characters, ending in suffix ("..." by
-- default) when it was cut; a UTF-8 character is never split, so a cut
-- name in any language stays valid text
--   U.Truncate("Schwarzfelsspitze", 10)   -- "Schwarz..."
function U.Truncate(text, maxChars, suffix)
  text = tostring(text)
  suffix = suffix or "..."
  if U.Utf8Length(text) <= maxChars then return text end
  local keep = math.max(0, maxChars - U.Utf8Length(suffix))
  local count, cut = 0, 0
  for i = 1, #text do
    local b = string.byte(text, i)
    if b < 128 or b >= 192 then   -- the first byte of a character
      if count == keep then break end
      count = count + 1
    end
    cut = i
  end
  return text:sub(1, cut) .. suffix
end

-- Plain-text money for chat messages, where texture icons do not render:
-- "150g 25s", "25s", "40c". Gold values drop the copper.
function U.FormatMoneyText(copper)
  copper = math.floor(tonumber(copper) or 0)
  local gold = math.floor(copper / 10000)
  local silver = math.floor((copper % 10000) / 100)
  local cents = copper % 100
  if gold > 0 then
    if silver > 0 then return ("%dg %ds"):format(gold, silver) end
    return ("%dg"):format(gold)
  end
  if silver > 0 then
    if cents > 0 then return ("%ds %dc"):format(silver, cents) end
    return ("%ds"):format(silver)
  end
  return ("%dc"):format(cents)
end
