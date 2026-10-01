# ApexFury

<p align="center">
  <img src="https://raw.githubusercontent.com/HackyThings/CobySuite-ApexFury/main/.publish-meta/icon/rising-fury-224.jpg" width="160" alt="ApexFury">
</p>

Sound alert at 4 stacks of Rising Fury for Devastation Evokers in WoW Midnight (12.1).

If you've ever popped Dragonrage, mashed your trinkets early, then realized your stacks weren't actually at 4 yet... yeah. ApexFury plays a sound the instant you hit the threshold so the trinket window stops being a guessing game.

## The Problem

In Midnight, Blizzard hid Rising Fury from addons, and since 12.1 every aura is hidden from addons during combat, encounters, Mythic+ and PvP. Reading the stack count directly causes UI errors, and the usual combat-log workaround was also disabled.

ApexFury never tries to read your stacks. It tracks your Dragonrage cast, your empowers, and the Animosity timing, then plays the sound the exact moment your 4th stack would land.

## How It Works

1. **You cast Dragonrage.** ApexFury starts a timer for when the 4th stack will land. With default settings (Rising Fury ticks every 6s, threshold 4), that's 18 seconds from your cast.
2. **You cast empowers (Fire Breath / Eternity Surge) inside Dragonrage.** Each one extends Dragonrage via Animosity. ApexFury counts them to know whether Dragonrage will last long enough for your 4th stack; the alert time itself stays at 18 seconds, and with no empower at all Dragonrage ends too soon and ApexFury stays silent.
3. **At the 4th-stack moment, the sound plays.**
4. **With Combat-only mode on (the default), if the 4th-stack moment arrives while you're out of combat** (between pulls in a dungeon, for instance), the alert holds and plays the instant you re-enter combat. If Dragonrage has already ended by then, it plays only with Rising Fury rank 3 and only while the linger has at least your minimum-remaining setting left; otherwise it cancels cleanly instead of firing late.

## Prerequisites

ApexFury checks your class, spec, and talents at login and any time you change them. It switches itself off, and tells you in chat, if you are not a Devastation Evoker or have not taken Rising Fury. Without Animosity it warns you and keeps running, since alerts at 3 stacks still work. A `/reload` is almost never needed: if your talents load late, ApexFury checks again on its own, and again whenever you change talents or zone.

| What you need | Why |
|---|---|
| **Devastation Evoker** | Dragonrage only exists on Devastation. On other specs and classes the addon shuts off completely. No background work, no cost. |
| **Rising Fury talent (rank 1+)** | Without it, the buff this addon tracks doesn't exist at all. The addon stays off. |
| **Animosity** | Without Animosity, Dragonrage stays at 18 seconds and you only ever get 3 stacks. The 4-stack alert is mathematically impossible. Drop your threshold to 3 if you don't run Animosity. |
| **Rising Fury rank 3** (recommended) | Rank 3 keeps your Rising Fury stacks alive after Dragonrage drops (4 seconds per stack) and turns Dragonrage into Unbound Flame. Without rank 3, alerts only fire during Dragonrage itself, not in the post-DR window. |

Edge cases it handles:

- **Tip the Scales empowers.** Instant-release empowers go through a different game event than channeled ones. ApexFury watches the right event so they all count toward Animosity.
- **An empower that lands right at the 4th-stack moment.** If Dragonrage looks too short at that moment, ApexFury waits up to half a second for an empower whose cast arrives late (lag), and plays the sound once if it extended Dragonrage.
- **Other buffs gained alongside Dragonrage** (trinket procs, potions, group buffs). The alert timing never reads your buffs, only your casts, so nothing you gain or lose during Dragonrage can throw off the tracker.
- **Rising Fury linger after Dragonrage ends.** Won't alert if your stacks have already faded below your minimum-remaining setting.
- **Vehicles, mounts, possession, stuns and CC.** The optional actionability gate (on by default) holds the alert when you can't act on it, then plays it the instant you regain control, as long as your Rising Fury linger is still alive. Covers raid vehicle mechanics, skyriding combat mounts (Dimensius P2, Amirdrassil flying phase), boss mind-control, and stun, fear, silence, etc. Toggle off in the options if you want the sound regardless of player state.

## Install

**CurseForge:** https://www.curseforge.com/wow/addons/apexfury

**Manual:** Drop the `ApexFury` folder into your `Interface/AddOns/`. No dependencies.

## Slash Commands

```
/af                                Open settings window (also /af settings, /af config, /af options)
/af guide                          Open or close the feature guide (also /af tutorial)
/af changelog                      Open or close What's New: what changed in each version (also /af whatsnew, /af news)
/af debug                          Toggle debug log window
/af status                         Print current settings and the talent check to chat
/af scan [name]                    List active player buffs (find spell IDs)
/af overlay                        Toggle on-screen status frame (also /af show)
/af channel [dialog|master|sfx]    Show or change the audio channel
/af reset                          Restore every setting to its default at once (no Apply needed)
/af version                        Print version
/af help                           Command list
```

`/apex` and `/apexfury` are aliases for `/af`.

## Guide and What's New

The first time you log in with ApexFury, its guide opens: a short tour in the order you'll need it (start here, the talents it needs, when the sound plays, your sound, the settings, the overlay). Click a heading to open or close it. Open it again any time with `/af guide` or the Guide button in the settings window.

After an update, a What's New window lists what changed since the version you last played. `/af changelog` opens it any time.

## Settings

Open with `/af`, or from the game's Options > AddOns > ApexFury page. The settings are grouped into three categories on the left: Behavior, Trigger and Sound. Changes take effect when you press Apply; Cancel or closing the window throws them away. Defaults asks first, then fills in every default, and nothing changes until you press Apply. Drag the window's bottom-right corner to make it bigger; it keeps that size. The first time after logging in or a `/reload`, open it out of combat; ApexFury will not build the window during combat.

**Behavior**
- Alerting enabled (master switch, on by default)
- Combat-only mode (on by default; defer alerts that would fire out of combat)
- Actionability gate (on by default; defer alerts while in vehicle, mounted, possessed, or stunned/CC'd; re-fires on recovery)
- Verbose debug logging (off by default; records every cast and empower to the debug window. Useful for bug reports.)

**Trigger**
- Trigger spell ID (default 375087 = Dragonrage)
- Threshold (default 4 stacks)
- Stack interval (default 6s. How often Rising Fury ticks during Dragonrage.)
- Min linger remaining (default 2s. Held alerts cancel if your Rising Fury linger drops below this.)

**Sound**

Type to search. Filter by source. Click any row to hear it on your chosen channel and pick it, then press Apply. The speaker icon next to "Selected" plays the sound you picked on the channel you picked.

The audio channel dropdown picks which WoW mix bus the alert plays on. Dialog is the default (nearly empty in combat, best chance to be heard). Master and SFX are also available if you'd rather route through those.

The Guide, Debug Log and Overlay buttons at the bottom of the window open the same windows as `/af guide`, `/af debug` and `/af overlay`.

## Library Support

ApexFury picks up sounds from whatever you already have. No config required.

| Source | What you get |
|---|---|
| Blizzard SoundKit (always on) | Hundreds of in-game sounds, auto-categorized into UI / Combat / Voice / Item / Alert / Effect |
| LibSharedMedia-3.0 (optional) | Every shared sound from every addon you've installed. Astral, Causese, BugSack, WIM, ElvUI, etc. Pack names are auto-detected, so you can filter by addon. |
| Leatrix Sounds (optional) | ~275,000 sounds from Leatrix's bundled catalog. Hit *Open Leatrix*, click any row in their browser, press *Grab Sound*, then press Apply to keep it. (Leatrix keeps its catalog to itself, so those sounds don't show up in ApexFury's search.) |

The more libraries you have installed, the bigger the catalog. Default sound is Blizzard's READY_CHECK if you'd rather not pick anything.

## Overlay

`/af overlay` toggles a movable on-screen status window. Seven lines, each with a hover tooltip:

1. **Status.** What the addon is doing right now: idle, counting down, fired, suppressed, or holding (waiting for combat, vehicle exit, etc., or for half a second at the 4th-stack moment in case an empower arrives late).
2. **DR remaining.** Time left on Dragonrage. Out of combat it is read once from the buff right after your cast and after each empower (marked "read"); otherwise, and always in combat (Blizzard hides the buff timer there), it is estimated. After Dragonrage ends it shows the estimated Rising Fury linger instead.
3. **Empowers cast + stacks.** How many empowers you've used this Dragonrage, how many Rising Fury stacks you have so far, and in brackets how many you'll end up with when Dragonrage ends if you cast nothing more. Also shows whether you're in combat.
4. **Fired after.** Exact seconds from your Dragonrage cast to the moment the sound played. Frozen once the cycle resolves.
5. **Last alert.** How long ago the last sound played. Blank after two minutes.
6. **Verdict.** What ApexFury would do if your 4th stack landed right now: fire, hold, or cancel. Useful for understanding why an alert didn't go off.
7. **Talent gate.** Whether your spec, Rising Fury rank, and Animosity are good. Tells you why the addon is inactive if it is.

Useful for sanity checks and bug reports. Hide it when you don't need it.

## Troubleshooting

**No sound playing.**

- `/af status`. If `Enabled: no`, open `/af`, tick Alerting enabled and press Apply.
- If `Combat-only: yes` and you're testing on a target dummy, make sure you actually pulled it (auto-attack on, or just hit it once).
- Open `/af`, go to Sound, and hit the speaker icon next to "Selected". If silent there too, your selected sound is missing (probably a LibSharedMedia pack you uninstalled). Pick a different one and press Apply.
- Still nothing? Try `/af channel master`. The default Dialog channel uses your Dialog Volume slider in WoW's audio settings, so if that's down to zero you won't hear alerts.

**Alert is firing too late or too early.**

- Open the overlay (`/af overlay`). The "Verdict" line tells you what ApexFury would do right now and why. Useful for spotting which condition is misbehaving.
- Verbose mode (`/af`, tick Verbose debug logging, press Apply) writes every cast and empower to the debug window. `/af debug` opens it.

**It says my spell ID is unknown.**

- `/af scan` lists every active player buff with its spell ID, and `/af scan fury` filters by name. Run it out of combat and outside Mythic+ or PvP; while the game hides aura data it tells you so instead of listing.

## License

GPL-2.0. See [LICENSE](LICENSE).

## Issues / Feedback

For bug reports, the cleanest path is the debug log. It's self-contained: it includes the addon version, your WoW build, a snapshot of every config setting, and a timestamped event timeline. No need to paste anything else.

**How to capture and send:**

1. In `/af`, under **Behavior**, tick **Verbose debug logging** and press **Apply**. Verbose adds every cast and empower to the log, which is what makes most bugs traceable.
2. Reproduce the issue.
3. Run `/af debug` to open the debug window, press **Copy Last 250**, and copy the text.
4. Email them to **hackythings@gmail.com** with a sentence about what you were doing.

**Other channels:**

- **BugSack errors:** whisper the report straight to **Figment-Illidan** in-game. BugSack copies the stack trace for you. Mention how to reproduce if you can.
- **CurseForge comments:** drop a note on the [project page](https://www.curseforge.com/wow/addons/apexfury). Best for general feedback and quick questions.
- **GitHub issues:** [open one here](https://github.com/HackyThings/CobySuite-ApexFury/issues). Best for reproducible bugs and feature proposals where back-and-forth helps. Attach the debug-log paste here too if it's relevant.
