# Changelog

All notable changes to ApexFury are documented here. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), version numbering follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-04-30

Initial release.

### Added

- Cast-event-driven stack alert for Devastation Evoker (Dragonrage trigger, Rising Fury threshold). Works around the Midnight 12.0 private-aura constraint by never reading the stack count directly.
- Animosity-aware empower tracking. Counts Fire Breath and Eternity Surge casts off `UNIT_SPELLCAST_SUCCEEDED` so Tip-the-Scales instant releases register correctly.
- Combat-only mode. Deferred alerts fire on combat re-entry, gated by a configurable Risen Fury linger floor.
- Targeted aura lookup via `C_UnitAuras.GetPlayerAuraBySpellID` 50ms after cast. Corrects for trinket procs that land in `addedAuras[1]` ahead of Dragonrage.
- Searchable sound browser embedded in the options window. Sources: Blizzard SoundKit (~800 entries auto-categorized into UI / Combat / Voice / Item / Alert / Effect), every LibSharedMedia pack you have installed (auto-discovered by addon folder name), Leatrix Sounds bundled FileDataID catalog (~275k entries) when LTS is loaded.
- LibSharedMedia-3.0 and Leatrix Sounds integrations. Both optional. ApexFury reads from whatever you already have, no setup required.
- Movable overlay window with six tooltipped status lines for live verification (state, DR remaining, empowers, fired-after timer, last-alert-ago, live verdict).
- Configurable trigger spell, threshold, stack interval, min linger remaining.
- Custom replace-confirm dialog when switching away from a Leatrix sound (avoids `StaticPopupDialogs`, which is a confirmed taint vector in 12.0).
- Slash commands: `/af`, `/apex`, `/apexfury` with subcommands for status, scan, overlay, debug, reset, version, help.

### Known Issues

- The CurseForge thumbnail occasionally lags an icon refresh after big patches. Not unique to this addon.

[Unreleased]: https://github.com/HackyThings/CobySuite-ApexFury/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/HackyThings/CobySuite-ApexFury/releases/tag/v0.1.0
