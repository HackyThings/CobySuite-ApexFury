-------------------------------------------------------------------------------
-- Guide: the feature guide behind the settings window's Guide button and
-- /af guide (a new player's first session: start here, the talents it
-- needs, when the sound plays, then the sound, the settings and last the
-- optional overlay). A fresh install opens it at its first section
-- (UI/WhatsNew.lua). The suite's standard guide, as Recollect's. Built at
-- load, so opening it in combat creates nothing. Keep the text in step with
-- the README.
-------------------------------------------------------------------------------
local Guide = {}
ApexFury.Guide = Guide

local U = CobySuite_ApexFury.Utilities
local ICONS = "Interface\\Icons\\"

Guide.SECTIONS = {
    {
      key = "start", title = "Start here", icon = ApexFury.ICON,
      summary = "Cast Dragonrage; the sound tells you when to use your trinkets",
      body = {
        "- ApexFury is for Devastation Evokers with the Rising Fury talent. On any other class, spec or build it switches itself off.",
        "- Cast Dragonrage and play as usual. With the default settings the sound plays 18 seconds after the cast, when your 4th Rising Fury stack lands.",
        "- Nothing to set up: the default sound and settings work as they are.",
        "- Can't hear it? Alerts play on the Dialog audio channel. Raise Dialog Volume in the game's sound settings, or pick another channel.",
      },
      try = {
        { "/af", "Open the settings" },
        { "/af status", "Print your settings and the talent check to chat" },
      },
    },
    {
      key = "talents", title = "Talents it needs", icon = ICONS .. "INV_Misc_Book_09",
      summary = "Rising Fury to run, Animosity for 4 stacks, rank 3 for the linger",
      body = {
        "- Rising Fury, any rank: without it there is nothing to track, and ApexFury stays off.",
        "- Animosity: each Fire Breath or Eternity Surge in Dragonrage extends it. Without it there is no 4th stack, so set the alert to 3.",
        "- Rising Fury rank 3 keeps your stacks for a few seconds after Dragonrage ends. Only then can a held alert still play after Dragonrage.",
        "- Talents are checked at login and whenever you change them. A line in chat says what is missing.",
      },
    },
    {
      key = "timing", title = "When the sound plays", icon = ICONS .. "INV_Misc_PocketWatch_01",
      summary = "Timed from your casts, held while you can't act on it",
      body = {
        "- The timer runs from your Dragonrage cast, never from your buffs, so potions, procs and group buffs can't throw it off.",
        "- Your empowers only decide whether Dragonrage lasts long enough. If it ends too soon, no sound plays.",
        "- An empower that registers a moment late still counts: ApexFury waits up to half a second for it.",
        "- Out of combat at that moment? With |cFFFFD100Hold the alert until I'm in combat|r on, the sound waits and plays when you're back in combat.",
        "- In a vehicle, mounted, stunned or mind-controlled? |cFFFFD100Hold the alert until I can act|r holds the sound until you can.",
        "- After Dragonrage, a held sound plays only with rank 3 and at least |cFFFFD100Skip a held alert with less than|r of Rising Fury left.",
      },
    },
    {
      key = "sound", title = "Your sound", icon = ICONS .. "INV_Misc_Note_01",
      summary = "Pick any sound and the channel it plays on",
      body = {
        "- In the settings, open |cFFFFD100Sound|r. Search the list, click a row to hear it and pick it, then press |cFFFFD100Apply|r.",
        "- |cFFFFD100Play sample|r plays your pick the way the alert will.",
        "- |cFFFFD100Play it on|r: Dialog (the default) stands out most in combat; Master and Sound effects work too. The line under it warns when a game volume mutes the alert.",
        "- Sounds from LibSharedMedia packs show up by themselves. With Leatrix Sounds, use |cFFFFD100Open Leatrix|r, click a sound there, then |cFFFFD100Use the sound I clicked|r.",
      },
      try = { { "/af channel master", "Switch the audio channel from chat" } },
    },
    {
      key = "settings", title = "Settings", icon = ICONS .. "INV_Misc_Gear_01",
      summary = "Alert, Sound and Advanced, applied when you press Apply",
      body = {
        "- |cFFFFD100Alert|r: whether ApexFury is ready here, alerts on or off, the stack to alert at with a timeline, and the hold rules.",
        "- |cFFFFD100Sound|r: your sound, the channel it plays on and a check that it isn't muted.",
        "- |cFFFFD100Advanced|r: the timing numbers (locked until |cFFFFD100Edit timing overrides|r), the overlay, the debug log and verbose logging.",
        "- Changes wait for |cFFFFD100Apply|r. |cFFFFD100Cancel|r or closing the window drops them, and |cFFFFD100Defaults|r fills in every default for you to check.",
        "- After logging in, open the settings out of combat the first time.",
      },
      try = { { "/af reset", "Put every setting back to its default at once" } },
    },
    {
      key = "overlay", title = "Overlay and bug reports", icon = ICONS .. "INV_Misc_Spyglass_02",
      summary = "Watch what ApexFury is doing, live",
      body = {
        "- The overlay shows the timer, Dragonrage time left, your empowers and stacks, and why a sound played, waited or was dropped. Hover a line to see what it means.",
        "- Drag it anywhere. It stays up, even after a reload, until you close it.",
        "- For a bug report, tick |cFFFFD100Log every cast for bug reports|r under Advanced, play until it happens, then copy the debug log.",
      },
      try = {
        { "/af overlay", "Show or hide the overlay" },
        { "/af debug", "Open the debug log" },
        { "/af scan [name]", "List your buffs with their spell IDs (out of combat)" },
      },
    },
}

local guide = CobySuite_ApexFury.UI.CreateGuideWindow({
  name = "ApexFuryGuideWindow",
  title = "ApexFury Guide",
  icon = ApexFury.ICON,
  intro = "New here? Start with the first section. Click any heading to open or close it.",
  footer = "Open this guide any time with " .. U.WrapColor(U.Colors.HELP_COMMAND, "/af guide"),
  sections = Guide.SECTIONS,
  -- APEX_FURY_UI_STATE.guideWindow; nil at load (the saved variables come
  -- later), and the window restores its place again on every show
  persist = { svTable = function() return APEX_FURY_UI_STATE end, key = "guideWindow" },
})

-- The window, for the suites
Guide._test = { window = guide }

function Guide.Toggle() guide:Toggle() end

-- Shows the guide at its first section (a fresh install's first login)
function Guide.Show() guide:OpenSection(Guide.SECTIONS[1].key) end
