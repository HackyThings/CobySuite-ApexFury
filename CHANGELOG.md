# Changelog

All notable changes to ApexFury are documented here. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), version numbering follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.2] - 2026-09-08

- Updated for World of Warcraft patch 12.1 (Curse of Ula'tek).
- Rising Fury rank 3 was redesigned in 12.1: Risen Fury is gone, and Rising Fury itself now lingers for 4 seconds per stack after Dragonrage ends while Dragonrage becomes Unbound Flame. The linger timing ApexFury already used is unchanged. Chat messages, the overlay and the settings text now say "Rising Fury linger" instead of "Risen Fury", and Unbound Flame casts are never mistaken for a new Dragonrage.
- 12.1 hides all aura data from addons while you are in combat, in an encounter, inside a Mythic+ run, or in a PvP match. ApexFury already relied on cast timing instead of reading auras, so alert timing is unaffected. The overlay's out-of-combat "DR remaining" readout and the bookkeeping behind it now skip hidden aura data instead of erroring, and `/af scan` tells you when aura data is hidden instead of throwing an error.
- Spec detection now uses the current specialization API (the old one has been deprecated since 11.2).

## [1.0.1] - 2026-07-22

- Updated for World of Warcraft patch 12.0.7.

## [1.0.0] - 2026-05-14

Initial release of ApexFury.

[Unreleased]: https://github.com/HackyThings/CobySuite-ApexFury/compare/v1.0.2...HEAD
[1.0.2]: https://github.com/HackyThings/CobySuite-ApexFury/releases/tag/v1.0.2
[1.0.1]: https://github.com/HackyThings/CobySuite-ApexFury/releases/tag/v1.0.1
[1.0.0]: https://github.com/HackyThings/CobySuite-ApexFury/releases/tag/v1.0.0
