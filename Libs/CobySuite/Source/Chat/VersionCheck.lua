---------------------------------------------------------------------------
-- CobySuite.VersionCheck: "a newer version is out", in every addon
--
-- The usual addon version check (Task #306, Cobanyte 2026-10-07): each copy
-- of an addon tells others which version it has over hidden addon messages,
-- and a copy that hears a higher released version of the same addon prints
-- one chat line, once per session:
--
--   CobySuite.VersionCheck.Register({
--     key     = "LP",                 -- the addon's short key in the message (letters and digits, unique in the suite)
--     addon   = "CobysLinkepedia",    -- the TOC folder: its Version is the version announced
--     title   = "Coby's Linkepedia",  -- the name in the chat line
--     color   = CobysLinkepedia.BRAND_COLOR,
--     enabled = function() return Config.Get(Opt.VERSION_CHECK) end,   -- read at every send and every notice
--     log     = function(fmt, ...) CobysLinkepedia.Debug.Log("INIT", fmt, ...) end,   -- optional
--   })
--   CobySuite.VersionCheck.AddSettingsRows(panel, Opt.VERSION_CHECK)   -- the section and checkbox, same in every addon
--
-- Call Register once from the addon's PLAYER_LOGIN callback. The option is
-- the addon's own (default true, validate boolean); off means the addon
-- neither sends, replies nor prints.
--
-- Only release builds send. A standalone build carries the library under its
-- own name with BuildInfo.embedded = true (build.py writes it into
-- Build.lua); the monorepo's copy has embedded = false, so a development
-- checkout, whose version may be newer than anything released, never
-- announces or replies. It still listens and prints.
--
-- The message: prefix VersionCheck.PREFIX, text "1:<key>:<version>". Sent:
--   - GUILD once per session, GUILD_DELAY seconds after login;
--   - to the group (INSTANCE_CHAT, RAID or PARTY) a few seconds after the
--     roster changes, at most once a GROUP_GAP on one channel;
--   - a reply, the same message, on the channel an older version came by,
--     once per sender per session, REPLY_DELAY seconds later, left out when
--     someone else announced our version or a newer one there meanwhile.
-- SAY and YELL are left out: Blizzard's generated docs (12.1.0) don't say
-- SendAddonMessage takes them. No custom channels and no whispers.
--
-- A send only happens out of combat and while the Chat restriction is off;
-- a send skipped or refused (throttled, AddOnMessageLockdown) is tried again
-- at the next trigger (leaving combat, the restriction lifting, a roster
-- change), never in a loop, and the guild at most GUILD_TRIES times.
--
-- Inbound messages are untrusted: a secret argument drops the message, the
-- text must decode exactly (Decode), our own echo is ignored, and only the
-- four channels above are read. Anyone can announce a made-up high version;
-- that is the risk every check of this kind takes, and the cost is one line.
--
-- Client calls go through VersionCheck.seams; VersionCheck.NewInstance(seams)
-- builds a separate checker for tests.
---------------------------------------------------------------------------
CobySuite_ApexFury.VersionCheck = CobySuite_ApexFury.VersionCheck or {}
local VC = CobySuite_ApexFury.VersionCheck
local U = CobySuite_ApexFury.Utilities

VC.PREFIX = "CobySuiteVer"
VC.PROTOCOL = "1"
VC.MAX_TEXT = 40            -- bytes; anything longer is dropped unread
VC.MAX_VERSION = 20         -- characters of a version
VC.MAX_KEY = 12
VC.GUILD_DELAY = { 20, 40 } -- seconds after Register, at random within
VC.GUILD_TRIES = 4
VC.GROUP_DELAY = { 3, 8 }
VC.GROUP_GAP = 60           -- seconds between two group announcements on one channel
VC.REPLY_DELAY = { 2, 6 }
VC.REPLY_GAP = 30           -- seconds between two of our messages on one channel before a reply
VC.RETRY_DELAY = { 2, 5 }   -- after leaving combat or the restriction lifting
VC.CHANNELS = { GUILD = true, PARTY = true, RAID = true, INSTANCE_CHAT = true }
VC.RESULT = { SUCCESS = 0, THROTTLE = 3, CHANNEL_THROTTLE = 8, LOCKDOWN = 11 }

VC.LABEL = "Tell me when a newer version is out"
VC.DESCRIPTION = "Shares the version you have with your guild and group in the background, and prints one line in chat when someone has a newer one. Off: nothing is sent and nothing is printed."
VC.SECTION_ICON = "Interface\\Icons\\INV_Misc_GroupNeedMore"

---------------------------------------------------------------------------
-- Versions and messages
---------------------------------------------------------------------------
-- ParseVersion(text): { parts = { n, ... }, suffix = "" or a letter, text }
-- for digits and dots with an optional lowercase letter after ("1.0.7",
-- "0.0.1c"), at most four numbers of at most six digits; nil for anything else
function VC.ParseVersion(text)
  if type(text) ~= "string" or U.IsSecret(text) then return nil end
  if #text == 0 or #text > VC.MAX_VERSION then return nil end
  local numbers, suffix = text:match("^([%d%.]+)([a-z]?)$")
  if not numbers then return nil end
  if numbers:sub(1, 1) == "." or numbers:sub(-1) == "." or numbers:find("..", 1, true) then return nil end
  local parts = {}
  for digits in numbers:gmatch("%d+") do
    if #digits > 6 or #parts >= 4 then return nil end
    parts[#parts + 1] = tonumber(digits)
  end
  return { parts = parts, suffix = suffix, text = text }
end

-- Compare(a, b): -1, 0 or 1 for two parsed versions; missing numbers count
-- as 0 (2.0 == 2.0.0), and a letter comes after none (0.0.1 < 0.0.1c)
function VC.Compare(a, b)
  for i = 1, 4 do
    local x, y = a.parts[i] or 0, b.parts[i] or 0
    if x ~= y then return x < y and -1 or 1 end
  end
  if a.suffix == b.suffix then return 0 end
  return a.suffix < b.suffix and -1 or 1
end

local function ValidKey(key)
  return type(key) == "string" and #key >= 1 and #key <= VC.MAX_KEY and key:find("^%w+$") ~= nil
end

function VC.Encode(key, version)
  return VC.PROTOCOL .. ":" .. key .. ":" .. version
end

-- Decode(text): key, parsed version; nil for anything but exactly "1:<key>:<version>"
function VC.Decode(text)
  if type(text) ~= "string" or U.IsSecret(text) or #text > VC.MAX_TEXT then return nil end
  local protocol, key, version = text:match("^(%d+):(%w+):([%w%.]+)$")
  if protocol ~= VC.PROTOCOL or not ValidKey(key) then return nil end
  local parsed = VC.ParseVersion(version)
  if not parsed then return nil end
  return key, parsed
end

---------------------------------------------------------------------------
-- Client calls
---------------------------------------------------------------------------
local function RandomBetween(range)
  return range[1] + math.random() * (range[2] - range[1])
end

VC.seams = {
  RegisterPrefix = function(prefix) return C_ChatInfo.RegisterAddonMessagePrefix(prefix) end,
  Send = function(prefix, text, chatType) return C_ChatInfo.SendAddonMessage(prefix, text, chatType) end,
  Version = function(addon) return C_AddOns.GetAddOnMetadata(addon, "Version") end,
  -- the release marker: build.py's Build.lua sets embedded = true
  Released = function()
    local info = CobySuite_ApexFury.BuildInfo
    return type(info) == "table" and info.embedded == true
  end,
  InCombat = function() return InCombatLockdown() end,
  ChatRestricted = function() return C_RestrictedActions.IsAddOnRestrictionActive(Enum.AddOnRestrictionType.Chat) end,
  InGuild = function() return IsInGuild() end,
  -- the group's addon channel, the way the chat box picks it; nil out of a group
  GroupChannel = function()
    if IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then return "INSTANCE_CHAT" end
    if IsInRaid() then return "RAID" end
    if IsInGroup() then return "PARTY" end
    return nil
  end,
  Self = function() return UnitFullName("player") end,
  Realm = function() return GetNormalizedRealmName() end,
  IsSecret = function(value) return U.IsSecret(value) end,
  After = function(delay, fn) C_Timer.After(delay, fn) end,
  Clock = function() return GetTime() end,
  Delay = RandomBetween,
  Print = function(text) print(text) end,
  -- Listen(handler): handler(event, ...) for every event the checker needs
  Listen = function(handler)
    local frame = CreateFrame("Frame")
    for _, event in ipairs({ "CHAT_MSG_ADDON", "GROUP_ROSTER_UPDATE", "PLAYER_REGEN_ENABLED", "ADDON_RESTRICTION_STATE_CHANGED" }) do
      frame:RegisterEvent(event)
    end
    frame:SetScript("OnEvent", function(_, event, ...) handler(event, ...) end)
    return frame
  end,
}

---------------------------------------------------------------------------
-- A checker: the registered addons of one copy of the library
---------------------------------------------------------------------------
local Checker = {}
Checker.__index = Checker

function VC.NewInstance(seams)
  return setmetatable({
    seams = seams or VC.seams,
    entries = {},      -- [key] = entry
    order = {},        -- keys in registration order
    listening = false,
    replied = {},      -- [key .. "@" .. sender] = true: answered this session
    lastSent = {},     -- [key .. "@" .. channel] = clock of our last message there
    lastStrong = {},   -- [key .. "@" .. channel] = clock someone else last said our version or newer there
    replies = {},      -- [key .. "@" .. channel] = true: a reply is scheduled
    group = {},        -- [key] = { scheduled, pending }
    retrying = false,
  }, Checker)
end

-- Seam(name, ...): a client call that never throws; a secret answer reads as nil
function Checker:Seam(name, ...)
  local ok, a, b = pcall(self.seams[name], ...)
  if not ok then return nil end
  local secret = self.seams.IsSecret
  if secret(a) or secret(b) then return nil end
  return a, b
end

function Checker:Log(entry, fmt, ...)
  if entry and entry.log then pcall(entry.log, "Version check: " .. fmt, ...) end
end

function Checker:Enabled(entry)
  local ok, on = pcall(entry.enabled)
  return ok and on and true or false
end

-- "Name-Realm", the form senders are compared in (U.CanonicalName); the
-- realm is read only for a name without one
function Checker:Canonical(name)
  if type(name) ~= "string" or self.seams.IsSecret(name) or name == "" then return nil end
  if name:find("-", 1, true) then return name end
  return U.CanonicalName(name, self:Seam("Realm"))
end

function Checker:SelfName()
  local name, realm = self:Seam("Self")
  if type(name) ~= "string" or name == "" then return nil end
  if type(realm) == "string" and realm ~= "" then return U.CanonicalName(name, realm) end
  return self:Canonical(name)
end

-- CanSend(entry): release build, the option on, out of combat, chat not restricted
function Checker:CanSend(entry)
  if self:Seam("Released") ~= true then return false, "development build" end
  if not self:Enabled(entry) then return false, "turned off" end
  if self:Seam("InCombat") ~= false then return false, "in combat" end
  if self:Seam("ChatRestricted") ~= false then return false, "addon chat is restricted" end
  return true
end

-- SendTo(entry, channel): true when the game took the message
function Checker:SendTo(entry, channel)
  local can, why = self:CanSend(entry)
  if not can then
    self:Log(entry, "%s not sent to %s (%s)", entry.key, channel, why)
    return false, why
  end
  local ok, result = pcall(self.seams.Send, VC.PREFIX, VC.Encode(entry.key, entry.version.text), channel)
  if not ok or self.seams.IsSecret(result) or result ~= VC.RESULT.SUCCESS then
    self:Log(entry, "%s to %s refused (%s); trying again at the next chance", entry.key, channel, ok and tostring(result) or "error")
    return false, "refused"
  end
  self.lastSent[entry.key .. "@" .. channel] = self:Seam("Clock") or 0
  self:Log(entry, "%s %s announced to %s", entry.key, entry.version.text, channel)
  return true
end

-- Register(opts): see the header. Returns the entry, or nil and why.
function Checker:Register(opts)
  opts = opts or {}
  if not ValidKey(opts.key) then return nil, "key must be letters and digits" end
  if self.entries[opts.key] then return self.entries[opts.key] end
  local text = self:Seam("Version", opts.addon)
  local version = VC.ParseVersion(text)
  local entry = {
    key = opts.key, addon = opts.addon, title = opts.title or opts.addon or opts.key, color = opts.color,
    enabled = type(opts.enabled) == "function" and opts.enabled or function() return true end,
    log = opts.log, version = version, noticed = false, guildTries = 0, guildDone = false,
  }
  if not version then
    self:Log(entry, "%s has no version to compare (%s); left out", opts.key, tostring(text))
    return nil, "no version"
  end
  self.entries[entry.key] = entry
  self.order[#self.order + 1] = entry.key
  self.group[entry.key] = { scheduled = false, pending = false }
  if not self.listening then
    self.listening = true
    self:Seam("RegisterPrefix", VC.PREFIX)
    self.frame = self:Seam("Listen", function(event, ...) self:OnEvent(event, ...) end)
  end
  self.seams.After(self.seams.Delay(VC.GUILD_DELAY), function() self:AnnounceGuild(entry) end)
  self:ScheduleGroup(entry)
  return entry
end

-- Quiet(entry): a development build or the option off, so nothing to schedule
function Checker:Quiet(entry)
  return self:Seam("Released") ~= true or not self:Enabled(entry)
end

function Checker:AnnounceGuild(entry)
  if entry.guildDone or entry.guildTries >= VC.GUILD_TRIES then return end
  if self:Quiet(entry) then entry.guildDone = true return end
  if self:Seam("InGuild") ~= true then return end
  entry.guildTries = entry.guildTries + 1
  if self:SendTo(entry, "GUILD") then entry.guildDone = true end
end

-- ScheduleGroup(entry): one group announcement a few seconds from now, or
-- once GROUP_GAP has passed since the last on that channel
function Checker:ScheduleGroup(entry)
  local state = self.group[entry.key]
  if state.scheduled then return end
  if self:Quiet(entry) then state.pending = false return end
  local channel = self:Seam("GroupChannel")
  if not VC.CHANNELS[channel] then return end
  local now = self:Seam("Clock") or 0
  local last = self.lastSent[entry.key .. "@" .. channel]
  local delay = self.seams.Delay(VC.GROUP_DELAY)
  if last and last + VC.GROUP_GAP > now + delay then delay = last + VC.GROUP_GAP - now end
  state.scheduled = true
  self.seams.After(delay, function()
    state.scheduled = false
    local current = self:Seam("GroupChannel")
    if not VC.CHANNELS[current] then state.pending = false return end
    state.pending = not self:SendTo(entry, current) and not self:Quiet(entry)
  end)
end

-- After combat or a lifted restriction: one more try for whatever was skipped
function Checker:Retry()
  if self.retrying then return end
  self.retrying = true
  self.seams.After(self.seams.Delay(VC.RETRY_DELAY), function()
    self.retrying = false
    for _, key in ipairs(self.order) do
      local entry = self.entries[key]
      if not entry.guildDone and entry.guildTries > 0 then self:AnnounceGuild(entry) end
      if self.group[key].pending then self:ScheduleGroup(entry) end
    end
  end)
end

-- Notice(entry, heard): the one chat line of the session
function Checker:Notice(entry, heard)
  if entry.noticed then return end
  entry.noticed = true
  entry.newest = heard.text
  local name = entry.color and U.WrapColor(U.ColorToHex(entry.color), entry.title) or entry.title
  self.seams.Print(("%s %s is available (you have %s)."):format(name, heard.text, entry.version.text))
end

-- Reply(entry, channel, heardAt): our version on that channel, unless
-- someone else said ours or newer there since heardAt
function Checker:Reply(entry, channel, heardAt)
  local slot = entry.key .. "@" .. channel
  if self.replies[slot] then return end
  local now = self:Seam("Clock") or 0
  local delay = self.seams.Delay(VC.REPLY_DELAY)
  local last = self.lastSent[slot]
  if last and last + VC.REPLY_GAP > now + delay then delay = last + VC.REPLY_GAP - now end
  self.replies[slot] = true
  self.seams.After(delay, function()
    self.replies[slot] = nil
    local strong = self.lastStrong[slot]
    if strong and strong >= heardAt then
      self:Log(entry, "%s reply on %s left out: someone else already said %s or newer", entry.key, channel, entry.version.text)
      return
    end
    self:SendTo(entry, channel)
  end)
end

-- Receive(prefix, text, channel, sender, ...): one CHAT_MSG_ADDON
function Checker:Receive(prefix, text, channel, sender, ...)
  local secret = self.seams.IsSecret
  if secret(prefix) or secret(text) or secret(channel) or secret(sender) then return false end
  for i = 1, select("#", ...) do
    if secret((select(i, ...))) then return false end
  end
  if prefix ~= VC.PREFIX or not VC.CHANNELS[channel] then return false end
  local key, heard = VC.Decode(text)
  local entry = key and self.entries[key]
  if not entry then return false end
  local from = self:Canonical(sender)
  if not from or from == self:SelfName() then return false end
  if not self:Enabled(entry) then return false end
  local now = self:Seam("Clock") or 0
  local order = VC.Compare(heard, entry.version)
  local slot = entry.key .. "@" .. channel
  if order >= 0 then self.lastStrong[slot] = now end
  if order > 0 then
    self:Log(entry, "%s %s heard from %s by %s (newer)", key, heard.text, from, channel)
    self:Notice(entry, heard)
  elseif order < 0 then
    local who = key .. "@" .. from
    if self.replied[who] or self:Seam("Released") ~= true then return true end
    self.replied[who] = true
    self:Log(entry, "%s %s heard from %s by %s (older); replying", key, heard.text, from, channel)
    self:Reply(entry, channel, now)
  end
  return true
end

function Checker:OnEvent(event, ...)
  if event == "CHAT_MSG_ADDON" then
    self:Receive(...)
  elseif event == "GROUP_ROSTER_UPDATE" then
    for _, key in ipairs(self.order) do self:ScheduleGroup(self.entries[key]) end
  elseif event == "PLAYER_REGEN_ENABLED" or event == "ADDON_RESTRICTION_STATE_CHANGED" then
    self:Retry()
  end
end

-- Status(): what each registered addon has and has heard (Verify, the debug log)
function Checker:Status()
  local out = { released = self:Seam("Released") == true, prefix = VC.PREFIX, entries = {} }
  for _, key in ipairs(self.order) do
    local entry = self.entries[key]
    out.entries[#out.entries + 1] = {
      key = key, addon = entry.addon, version = entry.version.text, enabled = self:Enabled(entry),
      noticed = entry.noticed, newest = entry.newest, guildDone = entry.guildDone, guildTries = entry.guildTries,
    }
  end
  return out
end

---------------------------------------------------------------------------
-- The library's own checker and the settings rows
---------------------------------------------------------------------------
local default
local function Default()
  default = default or VC.NewInstance(VC.seams)
  return default
end

function VC.Register(opts) return Default():Register(opts) end
function VC.Status() return Default():Status() end
function VC.Registered(key) return Default().entries[key] ~= nil end

-- AddSettingsRows(panel, key): the "Updates" section and its checkbox, worded
-- and placed the same in every addon (the end of the first category)
function VC.AddSettingsRows(panel, key)
  panel:Section("Updates", { icon = VC.SECTION_ICON })
  return panel:Checkbox{ key = key, label = VC.LABEL, description = VC.DESCRIPTION }
end
