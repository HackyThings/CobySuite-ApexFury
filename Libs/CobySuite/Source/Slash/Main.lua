---------------------------------------------------------------------------
-- CobySuite.Slash: slash command registrar
--
-- Registers an addon's slash aliases and routes "/cmd <name> <rest>" to a
-- command table, generating the help and version commands from it:
--
--   CobySuite.Slash.Register({
--     key      = "COBYSCURRENCYSEARCHER",          -- SlashCmdList key
--     slashes  = { "/ccs", "/cobyscurrencysearcher" },
--     title    = "Coby's Currency Searcher",
--     version  = "1.0.0",
--     message  = Message,                          -- the addon's chat printer
--     commands = {
--       { name = "settings", aliases = { "config" }, help = "Open the settings window",
--         run = function(rest, input) ... end },
--       { name = "test", usage = "test [suite]", help = "Open the test window", run = function(rest) ... end,
--         available = function() return MyAddon.Tests ~= nil end },   -- optional
--       { usage = "<text>", help = "Search for <text>" },   -- help line only
--       { section = "Windows" },                            -- help heading only
--     },
--     fallback = function(input, cmd, rest) ... end,   -- unknown command; default prints a hint
--     onEmpty  = function() ... end,                   -- bare "/ccs"; default prints the help
--     footer   = { "(Everything else lives in the settings window.)" },  -- extra help lines, optional
--     help     = function() ... end,                   -- replaces the generated help entirely
--   })
--
-- "/ccs help" prints the help (bare "/ccs" too, unless onEmpty is given);
-- "/ccs version" prints the version. Command names and aliases are matched
-- case-insensitively; `rest` is the trimmed text after the command, `input`
-- the whole trimmed line. `available`, when given, is asked on every use: a
-- command it returns false for is left out of the help and handled as an
-- unknown command (the fallback, else the hint), so a build without that
-- feature never advertises it. Register returns the handler so an addon can
-- call it directly (tests, keybinds). `message` is captured at registration:
-- when the addon's printer is defined in a later file, pass a wrapper that
-- resolves it per call.
--
-- The help is one block in the chat frame, without the addon's chat prefix on
-- every line: the addon's name, then a line per command and help-only entry
-- in table order, a blank line and a heading for each `section`, then the
-- version and help lines and the footer. On each line the command the player
-- types is gold, what they fill in (the part of `usage` from its first < or
-- [ after a space) a paler gold, and the description white (U.Colors.HELP_*).
-- Slash.HelpLines(opts) returns that block without printing it.
---------------------------------------------------------------------------
CobySuite_ApexFury.Slash = CobySuite_ApexFury.Slash or {}
local Slash = CobySuite_ApexFury.Slash
local U = CobySuite_ApexFury.Utilities

-- A command whose available() says false does not exist for now
local function IsAvailable(def)
  return def.available == nil or def.available() and true or false
end

-- "  /lp set <key> <value> - Change a setting" (U.FormatCommandLine): the
-- literal command in one colour, what the player fills in in another, the
-- description in a third
local function HelpLine(primary, usage, text)
  return "  " .. U.FormatCommandLine(primary .. " " .. usage, text)
end

function Slash.HelpLines(opts)
  local C = U.Colors
  local primary = opts.slashes[1]
  local heading = U.WrapColor(C.HELP_HEADING, opts.title or opts.key)
  if opts.version then
    heading = heading .. U.WrapColor(C.HELP_TEXT, " v" .. opts.version)
  end
  local lines = { heading .. U.WrapColor(C.HELP_TEXT, " commands") }
  for _, def in ipairs(opts.commands or {}) do
    if def.section then
      lines[#lines + 1] = " "
      lines[#lines + 1] = U.WrapColor(C.HELP_SECTION, def.section)
    else
      local usage = def.usage or def.name
      if usage and def.help and IsAvailable(def) then
        lines[#lines + 1] = HelpLine(primary, usage, def.help)
      end
    end
  end
  if opts.version then
    lines[#lines + 1] = HelpLine(primary, "version", "Print the addon version")
  end
  lines[#lines + 1] = HelpLine(primary, "help", "Show this help")
  for _, line in ipairs(opts.footer or {}) do
    lines[#lines + 1] = line
  end
  return lines
end

function Slash.Register(opts)
  assert(opts and opts.key, "Slash.Register needs opts.key")
  assert(opts.slashes and opts.slashes[1], "Slash.Register needs at least one slash alias")
  local message = opts.message or print
  local commands = opts.commands or {}
  local primary = opts.slashes[1]

  local byName = {}
  for _, def in ipairs(commands) do
    if def.name and def.run then
      byName[strlower(def.name)] = def
      for _, alias in ipairs(def.aliases or {}) do
        byName[strlower(alias)] = def
      end
    end
  end

  local function PrintHelp()
    if opts.help then
      opts.help()
      return
    end
    for _, line in ipairs(Slash.HelpLines(opts)) do
      print(line)
    end
  end

  local function Handle(input)
    input = strtrim(input or "")
    local cmd, rest = input:match("^(%S+)%s*(.-)$")
    cmd = strlower(cmd or "")
    rest = rest or ""

    if cmd == "" then
      if opts.onEmpty then opts.onEmpty() else PrintHelp() end
      return
    end
    if cmd == "help" then
      PrintHelp()
      return
    end
    if cmd == "version" and opts.version then
      message("v" .. opts.version)
      return
    end
    local def = byName[cmd]
    if def and IsAvailable(def) then
      def.run(rest, input)
      return
    end
    if opts.fallback then
      opts.fallback(input, cmd, rest)
    else
      message(("Unknown command '%s'. Type %s for the list."):format(cmd,
        U.WrapColor(U.Colors.HELP_COMMAND, primary .. " help")))
    end
  end

  for i, slash in ipairs(opts.slashes) do
    _G["SLASH_" .. opts.key .. i] = slash
  end
  SlashCmdList[opts.key] = Handle
  return Handle
end

-------------------------------------------------------------------------------
-- StandardCommands(opts): the commands every suite addon has, with the same
-- names, aliases and help in each (Cobanyte, 2026-09-30: "the same command
-- system from core"; Recollect's set). Pass the result as Register's
-- commands. Each handler is a function called per use, so it may name a
-- module that loads after Core.lua. An entry whose handler is nil is left
-- out, so an addon without a main window passes no show.
--
--   opts.show       open or close the main window (also pass it as onEmpty)
--   opts.showHelp   show's help text ("Open or close the main window")
--   opts.settings   open or close the settings window
--   opts.guide      open or close the feature guide
--   opts.changelog  open or close the What's New changelog
--   opts.debug      open or close the debug log window
--   opts.tests      function returning the addon's test runner, nil in a
--                   release build: "test [suite]" exists only while it
--                   returns one
--   opts.extra      the addon's own commands, placed before test
-------------------------------------------------------------------------------
function Slash.StandardCommands(opts)
  local list = {}
  local function Add(def) list[#list + 1] = def end
  if opts.show then
    Add({ name = "show", help = opts.showHelp or "Open or close the main window", run = function() opts.show() end })
  end
  if opts.settings then
    Add({ name = "settings", aliases = { "config", "options" }, help = "Open the settings window",
          run = function() opts.settings() end })
  end
  if opts.guide then
    Add({ name = "guide", aliases = { "tutorial" }, help = "Open or close the feature guide",
          run = function() opts.guide() end })
  end
  if opts.changelog then
    Add({ name = "changelog", aliases = { "change", "whatsnew", "news" },
          help = "Open or close the changelog: what changed in each version",
          run = function() opts.changelog() end })
  end
  if opts.debug then
    Add({ name = "debug", help = "Open or close the debug log window", run = function() opts.debug() end })
  end
  for _, def in ipairs(opts.extra or {}) do Add(def) end
  if opts.tests then
    Add({
      name = "test", usage = "test [suite]", help = "Open the in-game test window, optionally running one suite",
      available = function() return opts.tests() ~= nil end,
      run = function(rest)
        local tests = opts.tests()
        if not tests then return end
        tests.Window:Show()
        local suite = rest and rest:match("^%s*(%S+)")
        if suite then tests.RunSuite(suite) end
      end,
    })
  end
  return list
end
