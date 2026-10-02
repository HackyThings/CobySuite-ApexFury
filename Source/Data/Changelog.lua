-------------------------------------------------------------------------------
-- Data.Changelog: the in-game changelog (UI/WhatsNew.lua, /af changelog),
-- one entry per version, newest first. Shown after an update with every
-- version newer than the one the player last ran opened.
--
-- An entry: version (the TOC's), title (a few words), date ("2026-10-02"
-- once released; nil shows "Beta"), and the lists new, changed and fixed,
-- each a line a player reads (the CHANGELOG.md style: what changed for
-- them, no internals), short enough to fit on one line: "Feature: what it
-- does", the part before the first ": " shown in blue, and {/af} for a
-- command in gold. Keep it in step with CHANGELOG.md: /release adds the
-- entry.
-------------------------------------------------------------------------------
ApexFury.Data = ApexFury.Data or {}

ApexFury.Data.Changelog = {
  {
    version = "1.0.6",
    title = "New settings and a minimap entry",
    date = "2026-10-01",
    new = {
      "Minimap: ApexFury in the addon list; click it for settings",
    },
    changed = {
      "Settings: Alert, Sound and Advanced; your choices are kept",
      "Alert: a card shows whether ApexFury is ready on this character",
      "Threshold: pick a stack from tiles, with a timeline preview",
      "Plainer names for the hold, skip and logging options",
      "Sound: Play sample, and a warning when a game setting mutes it",
      "Advanced: timing numbers locked until you choose to edit them",
      "Tooltips: shorter and plainer in settings and on the overlay",
      "Sound browser: plain words; hold Shift for a sound's path or ID",
      "Overlay: says in words why an alert was dropped",
      "Late talent data: checked again on its own, no reload needed",
    },
    fixed = {
      "Overlay: wider, so long lines stay inside it",
      "Late talents mid-Dragonrage: an alert that can't land stays silent",
      "Held alerts: the overlay says it waits for combat once combat ends",
    },
  },
  {
    version = "1.0.5",
    title = "Guide and What's New",
    date = "2026-10-01",
    new = {
      "Guide: a short guide for new players, {/af guide}",
      "What's New: opens after an update, {/af changelog}",
      "Options > AddOns: ApexFury has its own page",
    },
    changed = {
      "Commands: match the other Coby addons",
      "Icons: ApexFury's icon on its windows",
    },
    fixed = {
      "Settings window: resizing stops at the screen edge",
      "Overlay: the Verdict line checks Dragonrage's length first",
      "Overlay: the Status tooltip lists every reason an alert waits",
    },
  },
  {
    version = "1.0.4",
    title = "Windows like the game's",
    date = "2026-09-29",
    changed = {
      "Windows: sit with the game's own, and a click brings one to the front",
      "Settings window: drag its corner to resize it; it keeps the size",
      "Settings: each group of options sits closer together",
      "Command list: {/af help} shows commands in gold",
    },
  },
  {
    version = "1.0.3",
    title = "New settings window",
    date = "2026-09-21",
    changed = {
      "Settings: Behavior, Trigger and Sound down the left side",
      "Apply, Cancel and Defaults: nothing changes until you press Apply",
      "Sound picks: the speaker plays yours first, Apply keeps it",
      "{/af channel} and {/af reset} update an open settings window",
      "Settings window: can't open for the first time in combat",
    },
    fixed = {
      "Late empowers: one right at the 4th stack no longer loses the alert",
      "Held alerts: play after Dragonrage only with Rising Fury rank 3",
      "Talents: checked again when they load late, no reload needed",
      "Overlay: your stacks now, and at the end of Dragonrage",
      "Overlay: Dragonrage time left never shows another buff's",
      "Rank 1 or 2: a short Dragonrage is reported as too short",
      "Sound previews: play on the audio channel you chose",
      "Checking talents: shown while talent data is still loading",
      "Number boxes: refuse anything that isn't a real number",
      "Coby addons from different releases no longer break each other",
    },
  },
  {
    version = "1.0.2",
    title = "Patch 12.1",
    date = "2026-09-08",
    changed = {
      "Updated for patch 12.1",
      "Rising Fury rank 3: its linger after Dragonrage replaces Risen Fury",
      "Unbound Flame: never taken for a new Dragonrage",
      "Hidden auras in combat: alert timing is unaffected",
      "{/af scan} says when the game is hiding aura data",
      "Spec check: uses the game's current way of reading your spec",
    },
  },
  {
    version = "1.0.1",
    title = "Patch 12.0.7",
    date = "2026-07-22",
    changed = {
      "Updated for patch 12.0.7",
    },
  },
  {
    version = "1.0.0",
    title = "First release",
    date = "2026-05-14",
    new = {
      "Rising Fury alert: a sound when your 4th stack lands",
      "Timed from your casts: Dragonrage, your empowers and Animosity",
      "Held alerts: wait for combat, or until you can act again",
      "Sound browser: game sounds, LibSharedMedia packs and Leatrix Sounds",
      "Overlay: {/af overlay} shows what the alert is doing",
      "Talent check: says in chat when something is missing",
    },
  },
}
