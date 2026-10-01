# Changelog

All notable changes to ApexFury are documented here. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), version numbering follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.5] - 2026-10-01

### Added

- **A guide for new players.** The first time you log in with ApexFury, a short guide opens: what the alert does, the talents it needs, when the sound plays, picking your sound, the settings and the overlay. Open it any time with `/af guide` or the new Guide button in the settings window.
- **What's New window.** After an update it opens by itself with what changed since the version you last played. `/af changelog` opens it any time.
- ApexFury now has a page under the game's Options > AddOns, with a button that opens its settings.

### Changed

- The `/af` commands now match the other Coby addons (`/af guide` also answers to `/af tutorial`, `/af changelog` to `/af whatsnew` and `/af news`). Every command you already used still works.
- ApexFury's icon now shows on its settings and debug log windows.

### Fixed

- Dragging the settings window's corner now stops at the edge of the screen. Before, pulling it past the edge could make the window keep growing with its corner off screen.
- The overlay's Verdict line now checks the trigger duration before the Rising Fury linger, the same order the alert itself uses. With a threshold Dragonrage can't reach, it says "wait" only while a late Fire Breath or Eternity Surge could still extend Dragonrage, then "suppress: DR too short"; before, at Rising Fury rank 1 or 2, it blamed the linger for an alert that was really dropped as too short.
- The overlay's Status tooltip now covers every reason a PENDING alert waits (out of combat, in a vehicle, mounted, possessed, or crowd-controlled), and explains EXPIRED.

## [1.0.4] - 2026-09-29

### Changed

- **Windows no longer stay on top of the game's own windows.** ApexFury's windows now sit with the game's panels: clicking any window brings it to the front, and a window opens in front. Only questions that need an answer, such as confirmations, stay above everything.
- The settings window can now be made bigger by dragging its bottom-right corner, and it remembers its size.
- Settings sections sit closer together, so each group reads as one block.
- The command list in chat (`/af help`) is easier to read: commands in gold and their descriptions in white.

## [1.0.3] - 2026-09-21

### Changed

- Redesigned settings window (`/af`): Behavior, Trigger and Sound are categories on the left, and the sound browser now sits under the Sound settings.
- Changes take effect when you press Apply. Cancel, or closing the window, throws them away. Defaults (which replaces Reset Defaults) fills in every default for you to check, and nothing changes until you press Apply.
- Picking a sound in the browser, or with Grab Sound from Leatrix Sounds, works the same way: press Apply to keep it. The speaker button beside "Selected" plays the sound you picked on the audio channel you picked, before you apply.
- `/af channel` and `/af reset` update the settings window while it is open.
- The settings window can no longer be opened for the first time during combat (after logging in or a `/reload`). ApexFury tells you to try again after combat. Once it has been opened, `/af` works in combat as before.
- `/af help` is in color: the command, what you fill in and its description each stand out.

### Fixed

- A Fire Breath or Eternity Surge that registers a moment late, right at the 4th-stack moment, no longer loses the alert. ApexFury waits up to half a second for it and plays the sound once if it extended Dragonrage.
- An alert held until you could act (out of combat, in a vehicle, mounted, stunned) now plays after Dragonrage has ended only with Rising Fury rank 3, the only rank whose stacks outlast Dragonrage.
- Talent detection recovers on its own when your talents load late (login, loadout or spec swaps). ApexFury checks again after 1, 2 and 4 seconds and whenever your talents change, instead of treating Rising Fury or Animosity as untalented until a `/reload`.
- The overlay's stacks line shows the stacks you have now and, in brackets, the stacks you will have when Dragonrage ends.
- The overlay's "DR remain" line no longer shows another buff's duration. Out of combat it reads Dragonrage's own timer once after your cast and after each empower (marked "read"); otherwise it estimates.
- The "Alerting enabled" tooltip now says that turning it off stops tracking Dragonrage.
- With Rising Fury rank 1 or 2, a Dragonrage too short for your threshold is now reported as too short on the overlay and in the debug log. It used to be blamed on an expired linger.
- Clicking a sound in the browser previews it on the audio channel you picked, the way the alert itself will play. It used to preview on Master whatever you chose.
- `/af status` and the overlay say "Checking talents..." while your talent data is still loading after login; they used to show a blank reason.
- The number boxes in the settings refuse anything that is not a real number (such as `inf`), and a damaged saved setting goes back to its default at login.
- Running ApexFury beside other Coby addons from different releases no longer lets one addon's copy of the shared code break another's.

## [1.0.2] - 2026-09-08

- Updated for World of Warcraft patch 12.1 (Curse of Ula'tek).
- Rising Fury rank 3 was redesigned in 12.1: Risen Fury is gone, and Rising Fury itself now lingers for 4 seconds per stack after Dragonrage ends while Dragonrage becomes Unbound Flame. The linger timing ApexFury already used is unchanged. Chat messages, the overlay and the settings text now say "Rising Fury linger" instead of "Risen Fury", and Unbound Flame casts are never mistaken for a new Dragonrage.
- 12.1 hides all aura data from addons while you are in combat, in an encounter, inside a Mythic+ run, or in a PvP match. ApexFury already relied on cast timing instead of reading auras, so alert timing is unaffected. The overlay's out-of-combat "DR remaining" readout and the bookkeeping behind it now skip hidden aura data instead of erroring, and `/af scan` tells you when aura data is hidden instead of throwing an error.
- Spec detection now uses the current specialization API (the old one has been deprecated since 11.2).

## [1.0.1] - 2026-07-22

- Updated for World of Warcraft patch 12.0.7.

## [1.0.0] - 2026-05-14

Initial release of ApexFury.

[Unreleased]: https://github.com/HackyThings/CobySuite-ApexFury/compare/v1.0.5...HEAD
[1.0.5]: https://github.com/HackyThings/CobySuite-ApexFury/releases/tag/v1.0.5
[1.0.4]: https://github.com/HackyThings/CobySuite-ApexFury/releases/tag/v1.0.4
[1.0.3]: https://github.com/HackyThings/CobySuite-ApexFury/releases/tag/v1.0.3
[1.0.2]: https://github.com/HackyThings/CobySuite-ApexFury/releases/tag/v1.0.2
[1.0.1]: https://github.com/HackyThings/CobySuite-ApexFury/releases/tag/v1.0.1
[1.0.0]: https://github.com/HackyThings/CobySuite-ApexFury/releases/tag/v1.0.0
