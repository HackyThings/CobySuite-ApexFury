# ApexFury

<p align="center">
  <img src="https://raw.githubusercontent.com/HackyThings/CobySuite-ApexFury/main/.publish-meta/icon/rising-fury-224.jpg" width="160" alt="ApexFury">
</p>

Sound alert at 4 stacks of Rising Fury for Devastation Evokers in WoW Midnight (12.1).

It plays a sound the instant your 4th stack lands, so the trinket window stops being a guess.

## The Problem

Blizzard hides Rising Fury from addons, and since 12.1 every aura during combat, encounters, Mythic+ and PvP. ApexFury never reads your stacks: it times your Dragonrage cast and your empowers, then plays the sound the moment your 4th stack would land.

## How It Works

1. **Dragonrage starts a timer** for your 4th stack: 18 seconds by default (a stack every 6s).
2. **Empowers inside Dragonrage** (Fire Breath, Eternity Surge) extend it through Animosity. They don't move the alert; they decide whether Dragonrage lasts long enough. With none, it ends too soon and ApexFury stays silent.
3. **At the 4th-stack moment, the sound plays.**
4. **Out of combat at that moment?** With Hold the alert until I'm in combat on (the default), it plays when you're back in combat. Once Dragonrage has ended, it plays only with Rising Fury rank 3 and at least your "Skip a held alert with less than" time left; otherwise it is dropped.

## Prerequisites

ApexFury checks your class, spec and talents at login and whenever they change. It switches off, and says so in chat, unless you're a Devastation Evoker with Rising Fury. Without Animosity it warns you and keeps running, since 3-stack alerts still work. Late-loading talents are checked again on their own; no `/reload` needed.

| What you need | Why |
|---|---|
| **Devastation Evoker** | Dragonrage exists only on Devastation. Other specs and classes switch the alert off; it comes back when you change spec. |
| **Rising Fury talent (rank 1+)** | Without it, the buff this addon tracks doesn't exist at all. The addon stays off. |
| **Animosity** | Without it Dragonrage stays at 18 seconds, so you only reach 3 stacks and a 4-stack alert can't play. Set the alert to 3 stacks. |
| **Rising Fury rank 3** (recommended) | Keeps your stacks 4 seconds each after Dragonrage ends. Without it, alerts play only during Dragonrage. |

Edge cases it handles:

- **Tip the Scales empowers** count toward Animosity too.
- **An empower right at the 4th-stack moment.** ApexFury waits up to half a second for a late one, and plays once if it extended Dragonrage.
- **Other buffs** (trinket procs, potions, group buffs) can't throw the timing off: it uses only your casts.
- **Rising Fury linger after Dragonrage ends.** Won't alert if your stacks have already faded below your "Skip a held alert with less than" setting.
- **Vehicles, mounts, possession, stuns and CC.** Hold the alert until I can act (on by default) holds the sound until you can act again, as long as Rising Fury is still up. Turn it off to hear it regardless.

## Install

**CurseForge:** https://www.curseforge.com/wow/addons/apexfury

**Manual:** Drop the `ApexFury` folder into your `Interface/AddOns/`. No dependencies.

## Slash Commands

```
/af settings - Open or close the settings window
/af guide - Open or close the feature guide
/af changelog - Open or close the changelog: what changed in each version
/af debug - Open or close the debug log window
/af status - Print the current settings and the talent check to chat
/af scan [name] - List active player buffs (find spell IDs)
/af overlay - Open or close the on-screen status overlay
/af channel [dialog|master|sfx] - Show or change the audio channel
/af reset - Restore every setting to its default
/af version - Print the addon version
/af help - Show this help
```

`/af` alone opens the settings. `/apex` and `/apexfury` work too.

## Guide and What's New

The first time you log in, the guide opens: a short tour in the order you'll need it. Click a heading to open or close it; `/af guide` or the Guide button in the settings reopens it.

After an update, a What's New window lists what changed since the version you last played. `/af changelog` opens it any time.

## Settings

Open with `/af`, Options > AddOns > ApexFury, or ApexFury in the addon list on the minimap (right-click there shows the overlay). Three pages: Alert, Sound and Advanced. Changes take effect when you press Apply; Cancel or closing the window drops them. Defaults asks first and still needs Apply. Drag the bottom-right corner to resize. After a login or `/reload`, open it out of combat the first time.

**Alert**
- A status card says whether ApexFury is ready on this character, with tiles for Devastation, Rising Fury and Animosity.
- Enable alerts (on by default)
- The stack to alert at, as tiles showing the time after your cast (default 4, +18s), with a timeline of the predicted alert and Play sample.
- Hold the alert until I'm in combat (on by default; an alert that comes out of combat waits for combat)
- Hold the alert until I can act (on by default; waits while you're in a vehicle, mounted, possessed, or stunned/CC'd; plays when you can act again)
- Skip a held alert with less than (default 2s of Rising Fury left)

**Sound**

Play sample plays your sound the way the alert will. "Play it on" picks the channel: Dialog (the default, nearly empty in combat), Master or Sound effects. The line under it says when a game setting mutes the alert.

Type to search the list. Filter by source. Click any row to hear it on your chosen channel and pick it, then press Apply.

**Advanced**
- The timing numbers ApexFury uses, locked until you press Edit timing overrides. Restore addon timing defaults puts them back.
- Show overlay, Open debug log, and Log every cast for bug reports (off by default; records every cast and empower to the debug window).

## Library Support

ApexFury picks up sounds from whatever you already have. No config required.

| Source | What you get |
|---|---|
| Built-in game sounds (always on) | Hundreds of in-game sounds, auto-categorized into UI / Combat / Voice / Item / Alert / Effect |
| Sound packs, through LibSharedMedia-3.0 (optional) | Every shared sound from your installed addons, filterable by pack. |
| Leatrix Sounds (optional) | About 275,000 sounds. Press *Open Leatrix*, click a row in its list, press *Use the sound I clicked*, then Apply. They don't show in ApexFury's search. |

The default sound is Blizzard's ready check.

## Overlay

`/af overlay` toggles a movable on-screen status window. Seven lines, each with a hover tooltip:

1. **Status.** Idle, counting down, fired, suppressed, or holding (for combat, a vehicle exit and so on, or half a second for a late empower).
2. **DR remaining.** Dragonrage time left, then the estimated Rising Fury linger. "read" is the game's own timer, taken out of combat after your cast and each empower; it stays until it runs out or you cast an empower. Otherwise it is an estimate.
3. **Empowers + stacks.** Empowers this Dragonrage, stacks so far, and in brackets the stacks you'll have when it ends if you cast nothing more. Also shows whether you're in combat.
4. **Fired after.** Exact seconds from your Dragonrage cast to the moment the sound played. Frozen once the cycle resolves.
5. **Last alert.** How long ago the last sound played. Blank after two minutes.
6. **Verdict.** Whether the alert's timing checks pass right now, or what would stop it. The combat and can-act holds are checked when the moment comes.
7. **Talent gate.** Whether your spec, Rising Fury rank, and Animosity are good. Tells you why the addon is inactive if it is.

## Troubleshooting

**No sound playing.**

- `/af status`. If `Alerts: no`, open `/af`, tick Enable alerts and press Apply.
- If `Hold until in combat: yes` and you're testing on a target dummy, make sure you actually pulled it (auto-attack on, or just hit it once).
- Open `/af` > Sound and press Play sample. The line under Play it on says if a game volume setting mutes it. Still silent? Your sound may be from a pack you uninstalled: pick another and press Apply.
- Still nothing? Try `/af channel master`. The default Dialog channel follows your Dialog Volume slider.

**Alert is firing too late or too early.**

- Open the overlay (`/af overlay`). The Verdict line shows whether the alert's timing checks pass right now, and why not.
- Verbose mode (`/af`, Advanced, tick Log every cast for bug reports, press Apply) writes every cast and empower to the debug window. `/af debug` opens it.

**It says my spell ID is unknown.**

- `/af scan` lists every active player buff with its spell ID, and `/af scan fury` filters by name. Run it out of combat and outside Mythic+ or PvP; while the game hides aura data it tells you so instead of listing.

## License

GPL-2.0. See [LICENSE](LICENSE).

## Issues / Feedback

Found a bug? Tick **Log every cast for bug reports** in `/af` > **Advanced**, reproduce it, then run `/af debug`, press **Copy Last 250** and send the text with a line about what you were doing. The log holds the addon version, your WoW build and your settings.

- **Email:** hackythings@gmail.com
- **BugSack errors:** whisper them to **Figment-Illidan** in game.
- **CurseForge:** comment on the [project page](https://www.curseforge.com/wow/addons/apexfury) for questions and feedback.
- **GitHub:** [open an issue](https://github.com/HackyThings/CobySuite-ApexFury/issues) for bugs you can reproduce.
