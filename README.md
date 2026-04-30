# ApexFury

<p align="center">
  <img src="https://raw.githubusercontent.com/HackyThings/CobySuite-ApexFury/main/.publish-meta/icon/rising-fury-224.jpg" width="160" alt="ApexFury">
</p>

Sound alert at 4 stacks of Rising Fury for Devastation Evokers in WoW Midnight 12.0.

If you've ever popped Dragonrage, mashed your trinkets early, then realized your stacks weren't actually at 4 yet... yeah. ApexFury plays a sound the instant you hit the threshold so the trinket window stops being a guessing game.

## The Problem

Midnight 12.0 made auras private. Stack counts on most class buffs come back as "secret values" during combat, and reading them can taint the entire UI execution context (PlayerFrame errors, ESC stops closing menus, etc.). On top of that, `COMBAT_LOG_EVENT_UNFILTERED` is no longer registerable by addons.

Rising Fury is a new talent in 12.0, so every stack tracker for it is starting from scratch. Most of the obvious approaches are off-limits before you even begin.

ApexFury never reads the stack count directly. It tracks what's still public (your Dragonrage cast, your empower casts, the Animosity formula) and fires at the exact moment the 4th stack tick lands.

## How It Works

1. Cast Dragonrage. Timer is set to fire at `(threshold - 1) × stack_interval` later. With the defaults, that's 18 seconds.
2. Each empower (Fire Breath, Eternity Surge) extends Dragonrage via the Animosity talent: `+5s × 0.75^N` per cast. ApexFury counts these and adjusts the model.
3. At t=18s exactly, the sound plays.
4. If Dragonrage finishes out of combat (e.g. mid-dungeon transition), the alert defers and fires the moment you re-enter combat. If the Risen Fury linger window has dropped below your `min_remaining` setting by then, it suppresses cleanly instead.

Edge cases it handles:

- **Tip the Scales empowers.** Instant-release empowers don't fire `UNIT_SPELLCAST_EMPOWER_STOP`. ApexFury counts them off `UNIT_SPELLCAST_SUCCEEDED` instead.
- **Trinket procs landing first in `addedAuras`.** A spell-ID lookup 50ms after cast confirms which `auraInstanceID` is actually Dragonrage, so a trinket dropping early doesn't trick the tracker into thinking your buff is gone.
- **Risen Fury linger after Dragonrage drops.** Won't alert if your stacks have already faded below the configured floor.

## Install

**CurseForge:** https://www.curseforge.com/wow/addons/apexfury

**Manual:** Drop the `ApexFury` folder into your `Interface/AddOns/`. No dependencies.

## Slash Commands

```
/af               Open settings window
/af help          Command list
/af status        Print current settings to chat
/af scan [name]   List active player buffs (find spell IDs)
/af overlay       Toggle on-screen status frame
/af debug         Toggle debug log window
/af reset         Restore defaults
/af version       Print version
```

`/apex` and `/apexfury` are aliases for `/af`.

## Settings

Open with `/af`. Two panes: form on the left, sound browser on the right.

**Behavior**
- Alerting enabled (master switch)
- Combat-only mode (defer alerts that would fire out of combat)
- Verbose debug logging (every cast / empower / aura event to the debug window)

**Trigger**
- Trigger spell ID (default 375087 = Dragonrage)
- Threshold (default 4 stacks)
- Stack interval (default 6s)
- Min linger remaining (default 2s, gates deferred alerts)

**Sound**

Type to search. Filter by source. Click any row to set it. Speaker icon next to "Selected" tests playback.

## Library Support

ApexFury picks up sounds from whatever you already have. No config required.

| Source | What you get |
|---|---|
| Blizzard SoundKit (always on) | ~800 in-game sounds, auto-categorized into UI / Combat / Voice / Item / Alert / Effect |
| LibSharedMedia-3.0 (optional) | Every LSM-registered sound from every addon you've installed. Astral, Causese, BugSack, WIM, ElvUI, etc. Pack names are auto-detected from the file paths. |
| Leatrix Sounds (optional) | ~275,000 FileDataIDs from the Leatrix bundled catalog. Searchable inline. Or hit *Open Leatrix* + click a row in their browser, then *Grab Sound* to import. |

The more libraries you have installed, the bigger the catalog. Default sound is Blizzard's READY_CHECK if you'd rather not pick anything.

## Overlay

`/af overlay` toggles a movable on-screen status frame. Six lines, each tooltipped:

1. **Status.** Idle / counting down / fired / suppressed / pending
2. **DR remaining.** Either read from the aura (out of combat) or estimated via the model (in combat)
3. **Empowers + projected stacks at DR drop + combat tag**
4. **Fired after.** Exact seconds from Dragonrage cast to alert fire, frozen at the moment of resolution
5. **Last alert.** How long ago the last sound played
6. **Verdict.** What `FireAlert` would do if the threshold moment hit right now (which gates pass, which would suppress)

Useful for sanity checks and bug reports. Hide it when you don't need it.

## Troubleshooting

**No sound playing.**

- `/af status`. If `Enabled: no`, flip it on in `/af`.
- If `Combat-only: yes` and you're testing on a target dummy, make sure you actually pulled it (auto-attack on, or just hit it once).
- Hit the speaker icon next to "Selected" in `/af`. If silent there too, your selected sound file is missing (probably an LSM pack you uninstalled, or a Leatrix sound after Leatrix went away). Pick a different one.

**Alert is firing too late or too early.**

- Open the overlay (`/af overlay`). The "Verdict" line tells you which gate fired or suppressed.
- Verbose mode (`/af` → Verbose debug logging) writes every cast and aura event to the debug window. `/af debug` opens it.

**It says my spell ID is unknown.**

- `/af scan` lists every active player buff with its spell ID. `/af scan fury` filters by name.

## License

GPL-2.0. See [LICENSE](LICENSE).

## Issues / Feedback

For bug reports, the cleanest path is the debug log. It's self-contained: it includes the addon version, your WoW build, a snapshot of every config setting, and a timestamped event timeline. No need to paste anything else.

**How to capture and send:**

1. In `/af`, under the **Behavior** section, tick **Verbose debug logging**. Verbose adds every cast, empower, and aura event to the log, which is what makes most bugs traceable.
2. Reproduce the issue.
3. Run `/af debug` to open the debug window. Copy the last ~250 entries.
4. Email them to **hackythings@gmail.com** with a sentence about what you were doing.

**Other channels:**

- **BugSack errors:** whisper the report straight to **Figment-Illidan** in-game; BugSack copies the stack trace for you. Mention how to reproduce if you can.
- **CurseForge comments:** drop a note on the [project page](https://www.curseforge.com/wow/addons/apexfury). Best for general feedback and quick questions.
- **GitHub issues:** [open one here](https://github.com/HackyThings/CobySuite-ApexFury/issues). Best for reproducible bugs and feature proposals where back-and-forth helps. Attach the debug-log paste here too if it's relevant.

If you don't see a `Verbose debug logging` checkbox: open `/af` and look at the **Behavior** section at the top of the form. Toggling it on takes effect immediately and persists across sessions. The debug window itself is `/af debug` from anywhere.
