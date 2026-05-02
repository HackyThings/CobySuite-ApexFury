# ApexFury

<p align="center">
  <img src="https://raw.githubusercontent.com/HackyThings/CobySuite-ApexFury/main/.publish-meta/icon/rising-fury-224.jpg" width="160" alt="ApexFury">
</p>

Sound alert at 4 stacks of Rising Fury for Devastation Evokers in WoW Midnight 12.0.

If you've ever popped Dragonrage, mashed your trinkets early, then realized your stacks weren't actually at 4 yet... yeah. ApexFury plays a sound the instant you hit the threshold so the trinket window stops being a guessing game.

## The Problem

In Midnight 12.0, Blizzard hid most class buffs from addons during combat — including Rising Fury. The stack count comes back as a "secret value" that addons can't safely read; touching it triggers UI errors (PlayerFrame breaks, the Escape key stops closing menus). The old fallback — watching the combat log — was also disabled for addons in 12.0.

Rising Fury is brand new in 12.0, so every stack tracker is starting from scratch under these rules.

ApexFury sidesteps the problem. It never reads your stack count. Instead it watches the things Blizzard still lets addons see — your Dragonrage cast, your Fire Breath / Eternity Surge casts, and the Animosity timing — and plays the sound the exact moment your 4th stack lands.

## How It Works

1. **You cast Dragonrage.** ApexFury starts a timer for when the 4th stack will land. With default settings (Rising Fury ticks every 6s, threshold 4), that's 18 seconds from your cast.
2. **You cast empowers (Fire Breath / Eternity Surge) inside Dragonrage.** Each one extends Dragonrage via Animosity. The first cast adds the full 5 seconds; each later cast contributes 25% less than the one before (5s, 3.75s, 2.81s, 2.11s, 1.58s for casts 1 through 5). ApexFury tracks your empowers and updates the timer to match.
3. **At the 4th-stack moment, the sound plays.**
4. **If Dragonrage finishes while you're out of combat** (e.g. between dungeon pulls), the alert holds. It plays the instant you re-enter combat — as long as your Risen Fury linger window is still alive. If the linger has already dropped below your minimum-remaining setting, it cancels cleanly instead of firing late.

## Prerequisites

ApexFury checks your class, spec, and talents at login and any time you change them. If anything's missing it tells you in chat and stops working in the background until you fix it. No `/reload` ever needed.

| What you need | Why |
|---|---|
| **Devastation Evoker** | Dragonrage only exists on Devastation. On other specs/classes the addon shuts off completely — no background work, no cost. |
| **Rising Fury talent (rank 1+)** | Without it, the buff this addon tracks doesn't exist at all. The addon stays off. |
| **Animosity** | Without Animosity, Dragonrage stays at 18 seconds and you only ever get 3 stacks. The 4-stack alert is mathematically impossible. Drop your threshold to 3 if you don't run Animosity. |
| **Rising Fury rank 3** (recommended) | Rank 3 unlocks Risen Fury, the linger phase that keeps your stacks alive after Dragonrage drops. Without rank 3, alerts only fire during Dragonrage itself, not in the post-DR window. |

Edge cases it handles:

- **Tip the Scales empowers.** Instant-release empowers go through a different game event than channeled ones. ApexFury watches the right event so they all count toward Animosity.
- **Trinket procs that land alongside Dragonrage.** ApexFury verifies which buff is actually Dragonrage so a trinket dropping early doesn't make the tracker think your DR ended.
- **Risen Fury linger after Dragonrage ends.** Won't alert if your stacks have already faded below your minimum-remaining setting.
- **Vehicles, mounts, possession, stuns/CC.** The optional actionability gate (on by default) holds the alert when you can't act on it, then plays it the instant you regain control — as long as your Risen Fury linger window is still alive. Covers raid vehicle mechanics, skyriding combat mounts (Dimensius P2, Amirdrassil flying phase), boss mind-control, and stun/fear/silence/etc. Toggle off in the options if you want the sound regardless of player state.

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
- Actionability gate (defer alerts while in vehicle / mounted / possessed / CC'd; re-fires on recovery)
- Verbose debug logging (records every cast, empower, and buff change to the debug window — useful for bug reports)

**Trigger**
- Trigger spell ID (default 375087 = Dragonrage)
- Threshold (default 4 stacks)
- Stack interval (default 6s — how often Rising Fury ticks during Dragonrage)
- Min linger remaining (default 2s — held alerts cancel if your Risen Fury linger drops below this)

**Sound**

Type to search. Filter by source. Click any row to set it. Speaker icon next to "Selected" tests playback.

## Library Support

ApexFury picks up sounds from whatever you already have. No config required.

| Source | What you get |
|---|---|
| Blizzard SoundKit (always on) | ~800 in-game sounds, auto-categorized into UI / Combat / Voice / Item / Alert / Effect |
| LibSharedMedia-3.0 (optional) | Every shared sound from every addon you've installed. Astral, Causese, BugSack, WIM, ElvUI, etc. Pack names are auto-detected, so you can filter by addon. |
| Leatrix Sounds (optional) | ~275,000 sounds from Leatrix's bundled catalog. Searchable inline. Or hit *Open Leatrix* + click any row in their browser, then *Grab Sound* to import. |

The more libraries you have installed, the bigger the catalog. Default sound is Blizzard's READY_CHECK if you'd rather not pick anything.

## Overlay

`/af overlay` toggles a movable on-screen status window. Seven lines, each with a hover tooltip:

1. **Status.** What the addon is doing right now: idle, counting down, fired, suppressed, or holding (waiting for combat / vehicle exit / etc).
2. **DR remaining.** Time left on Dragonrage. Read directly from your buff out of combat, estimated from your cast + empower count in combat (Blizzard hides the buff timer in combat).
3. **Empowers cast + projected stacks at DR drop.** How many empowers you've used this Dragonrage and how many Rising Fury stacks you'll end up with. Also shows whether you're in combat.
4. **Fired after.** Exact seconds from your Dragonrage cast to the moment the sound played. Frozen once the cycle resolves.
5. **Last alert.** How long ago the last sound played.
6. **Verdict.** What ApexFury would do if your 4th stack landed RIGHT NOW — fire, hold, or cancel. Useful for understanding why an alert didn't go off.
7. **Talent gate.** Whether your spec, Rising Fury rank, and Animosity are good. Tells you why the addon is inactive if it is.

Useful for sanity checks and bug reports. Hide it when you don't need it.

## Troubleshooting

**No sound playing.**

- `/af status`. If `Enabled: no`, flip it on in `/af`.
- If `Combat-only: yes` and you're testing on a target dummy, make sure you actually pulled it (auto-attack on, or just hit it once).
- Hit the speaker icon next to "Selected" in `/af`. If silent there too, your selected sound file is missing (probably an LSM pack you uninstalled, or a Leatrix sound after Leatrix went away). Pick a different one.

**Alert is firing too late or too early.**

- Open the overlay (`/af overlay`). The "Verdict" line tells you what ApexFury would do right now and why — useful for spotting which condition is misbehaving.
- Verbose mode (`/af` → Verbose debug logging) writes every cast and buff event to the debug window. `/af debug` opens it.

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
