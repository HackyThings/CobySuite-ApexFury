# Changelog

All notable changes to ApexFury are documented here. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), version numbering follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.4.0] - 2026-05-04

### Fixed

- **Group buffs and combat potions no longer get mistaken for Dragonrage.** Rising Fury is a hidden aura in Midnight 12.0 — its stack count, name, and duration are all secret values during combat. ApexFury can't read it directly, so it used to look at every buff that landed on you within a second of Dragonrage and try to pick out which one was Rising Fury. That worked on a target dummy. In a real M+ pull, your Augmentation's Prescience and Ebon Might land in the same instant, your Mistweaver's Renewing Mist lands, your combat potion lands, Tip the Scales lands — and any of those can win the guess. When the addon picked the wrong one, it thought Dragonrage ended whenever THAT buff expired. Prescience expires at 19s, most combat potions at 30s, real Dragonrage with 4 empowers at 31.7s — and the misidentification poisoned the Risen Fury linger window used by deferred alerts (the ones that re-fire after vehicle/CC/out-of-combat).
- The fix is to stop guessing. Rising Fury accumulates one stack every 6 seconds you're in Dragonrage, and Dragonrage's exact duration is a deterministic formula based on empower casts (Animosity adds 5 seconds per Fire Breath / Eternity Surge with diminishing returns). Empower casts come in over a public event channel that's not subject to the hidden-aura system, so the addon can count them precisely. ApexFury now drives every timing decision — when to fire, when to suppress as "trigger too short", how long the Risen Fury linger lasts — from that math instead of from an aura it can't reliably identify. There's no group-buff blacklist anymore because it doesn't need one; every buff other players cast on you is simply ignored.
- **What you'll notice:** the 4-stack alert at +18s already worked for almost everyone — the alert fired before the misidentified buff could matter. What was broken was deferred alerts that resolved later. Press Dragonrage in a vehicle phase and the alert holds, then fires when you exit at +25s. Before, a misidentified 19s buff made the addon think your Risen Fury linger had only seconds left when you actually had the full 20-second window. That's correct now. **Threshold ≥5 alerts** that previously suppressed on cycles where a short non-DR buff was being tracked will now fire correctly.
- **Without Animosity specced**, predicted Dragonrage duration is now correctly 18 seconds flat regardless of how many empowers you cast — Animosity is the only mechanic that extends it. Threshold ≥4 alerts still suppress automatically in this case (4 stacks of Rising Fury can't fit in 18 seconds), now via the predictive model rather than the previously-broken observed-aura path.
- The verbose debug log's `[CAPTURE]` lines still emit for diagnostic use, but the per-cycle "predicted vs observed" comparison line is gone — there's no observed end time anymore, only the predicted one. The "linger expired" suppression reason is now spelled `linger_expired` (was `buff_dropped`) for clarity in the overlay's verdict line.
- **High-latency M+ groups: empowers cast right at the end of Dragonrage no longer get silently dropped.** A Fire Breath or Eternity Surge release that the server applied while Dragonrage was still up can take 100-300ms (or rarely up to half a second) to make it back to your client as a cast-completion event. The previous build rejected anything past the predicted Dragonrage end with no slack, so a high-ping pull where you weave an Eternity Surge into the last second of Dragonrage could under-count empowers — the predictive model would then think your Dragonrage was shorter than it really was, and threshold ≥4 alerts on that cycle would suppress as "trigger too short" even though the buff actually ran long enough. ApexFury now allows a 0.5-second arrival grace, so empowers truly cast within Dragonrage but with their event landing client-side just after still get credited. The verbose debug log notes when the grace was used so you can see boundary cases.

## [0.3.0] - 2026-05-02

### Added

- **Audio channel selector.** Alerts now play on the **Dialog** audio channel by default. The Master channel — what most addons (including this one) used to play on — gets crowded in heavy combat: your spell sounds, boss telegraphs, weapon hits, DBM/BigWigs voice cues, and environmental audio all compete on the same mix bus, and a short alert sound can be technically playing yet inaudible against louder simultaneous sounds. The Dialog channel is reserved for NPC speech and cinematic dialogue, so it's nearly empty during M+ and raid pulls, giving your alert clean room to be heard. You can pick **Master**, **SFX**, or **Dialog** in the options window's Sound section, or change it on the fly with `/af channel [dialog|master|sfx]`. `/af status` now also reports the active channel. A one-time chat message on first login explains the new default, and tells you exactly what to check if you can't hear it (Audio > Dialog Volume in WoW's sound settings, or switch back to Master via the slash command).

### Fixed

- **Alerts now fire correctly when you have Font of Magic talented.** Font of Magic replaces Fire Breath and Eternity Surge with different spell IDs under the hood (382266 / 382411 instead of the base 357208 / 359073). ApexFury was only watching for the base IDs, so every empower you cast was invisible to the addon — every Dragonrage cycle counted zero empowers and got suppressed for "trigger too short", even though Dragonrage was running its full Animosity-extended duration. If you've ever seen "fired" on the overlay but heard nothing during M+, this was likely the cause. All four spell IDs are now tracked; you should see "Empower #1", "Empower #2", etc. in the debug log during Dragonrage.
- **Silent alerts now retry once.** WoW's audio mixer can drop short sounds when it's overwhelmed in heavy combat — successfully dispatched, but never audibly played. Since Dragonrage's trinket window is gated by a single alert per cycle, a dropped sound means a missed window. ApexFury now retries the alert once after a brief delay (which almost always succeeds once the mixer has freed up), and writes an "alert was inaudible" line to the debug log if both attempts fail. Combined with the new Dialog-channel default, this should resolve the intermittent "I didn't hear my alert" issue.

## [0.2.0] - 2026-05-01

### Added

- Talent gate. Detects class, spec, Rising Fury rank, and Animosity at login and on talent changes. Watcher events register only on Devastation Evoker with Rising Fury rank ≥1 — non-Devo characters and unspecced Devos pay zero per-event cost. Chat warns on transitions (specced/unspecced Animosity, dropped to non-Devo spec, etc.) and the overlay's new line 7 shows live gate status with reason detail.
- Math-aware Animosity warning. Without Animosity, Dragonrage caps at 18s and the 4th Rising Fury stack tick races the buff's expiration. The gate explicitly tells the user that thresholds ≥4 cannot fire without Animosity, instead of silently suppressing.
- Actionability gate (config-toggleable, default on). Defers the alert when the player is in a vehicle, mounted (incl. skyriding combat mounts on bosses like Dimensius P2 / Amirdrassil flying phase), possessed, or under loss-of-control (stun/fear/silence/etc.). The deferred alert re-fires the moment the player can act again, provided the Risen Fury linger phase still has time. Resolved via dedicated events (`UNIT_EXITED_VEHICLE`, `LOSS_OF_CONTROL_UPDATE`, `PLAYER_MOUNT_DISPLAY_CHANGED`) plus a 0.5s polling fallback for transitions without explicit events. Overlay line 1 shows the specific defer reason (waiting for combat / in vehicle / mounted / stunned / etc.).

### Fixed

- Wrong-aura tracking causing spurious alert suppressions. The whole identification path has been rebuilt around several layered strategies:
  - **Identify Dragonrage by spellId/name during capture** instead of trusting `addedAuras[1]`. Reads each added aura's `spellId` and `name` fields directly (with `pcall` + `issecretvalue` gating) and matches against the trigger spell. Falls back to a transient-buff exclusion list (Tip the Scales, etc.) when both fields are secret values during combat. Replaces the `+50ms GetPlayerAuraBySpellID` verification path which has been observed to consistently return `nil` for Dragonrage in 12.0 (the cast spell ID 375087 apparently doesn't match the buff in that lookup's filter logic).
  - **Don't let later UNIT_AURA events override a fallback-set `firstCapturedID`** with another fallback guess. Once we've picked DR via heuristic, only a *positive* spellId/name match can dethrone it. Without this guard, the previous code re-ran the whole identification logic on every UNIT_AURA event during the capture window — so a later 1-aura batch (50ms after the initial 2-aura batch) would pick its single non-transient member and clobber the correct early pick.
  - **Runtime "too-short-for-DR" adaptation.** When `firstCapturedID` drops within 13s of the cast (DR base is 18s, so a drop that early is definitively not Dragonrage), treat it as a transient consumption and switch to any other surviving captured aura. The next drop event will re-evaluate the new pick, cascading naturally — eventually landing on a long-lived aura that outlives the alert window. This catches cases where `addedAuras[1]` itself was a Tip-the-Scales-or-similar buff whose `spellId` field came back secret so the static transient list couldn't help.
  - **"Too-late-for-DR" predictive override.** When `firstCapturedID` drops more than 5s after the predictive Animosity model expects (with 0 empowers, predicted = 18s; with N empowers, predicted = 18 + Σ 5×0.75^i for i in 0..N-1), the tracked aura was probably a long-lived non-DR buff that survived the cascade. Trust the predictive end instead — set `triggerDropTime = expectedTriggerEnd`. This catches the case where Light's Potential or a similar ~30s trinket buff lands at `addedAuras[1]` and outlives the cascade window. Without it, the linger model would inflate stacks-at-drop and lingerDuration, causing deferred-then-fired alerts to play long after the trinket window has actually expired. Reproduced 2026-05-01: a no-empower DR cycle had Light's Potential tracked as DR, alert fired at +38s on combat re-entry when only 3 stacks ever existed.
  - **Verify-on-drop fallback** walks the remaining captured auras and identifies DR by `spellId`/`name` if the first-aura was wrong, replacing the broken `GetPlayerAuraBySpellID` verification.
  - Verbose mode now logs each aura's readable spell ID at capture time so future identification issues are diagnosable from logs alone.
  - **Match Rising Fury, not the cast ID, for the DR active-state proxy.** Training-dummy testing revealed that the aura with `spellId=375087` (Dragonrage's cast spell ID) only applies as a brief ~3s pulse — it's the *cast effect*, not the long-lived state buff. The actual buff representing "DR is active" is Rising Fury (`spellId=1271783` and related rank variants), which lasts the full Animosity-extended duration. The capture-phase identification now matches against `DR_STATE_AURA_IDS = {1271783, 1271687, 1271796}` and the name `"Rising Fury"` rather than the cast spell ID. The cast ID 375087 is also explicitly added to `TRANSIENT_AURA_SPELL_IDS` so the non-transient fallback skips it. Without this, our positive-ID match (Strategy A) was selecting the 3s pulse, and only the cascade-too-short heuristic (Strategy B) was rescuing each cycle by accident.

  Reproduced and stepwise-fixed across multiple real-pull cycles 2026-05-01.

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

[Unreleased]: https://github.com/HackyThings/CobySuite-ApexFury/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/HackyThings/CobySuite-ApexFury/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/HackyThings/CobySuite-ApexFury/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/HackyThings/CobySuite-ApexFury/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/HackyThings/CobySuite-ApexFury/releases/tag/v0.1.0
