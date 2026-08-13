# L4D2 AnneHappy Rework Update Log

## Updates

### June 12-July 3, 2026 Update Log
#### Anne Modes And Spawn System
- Fixed third-person support in Anne versus-style modes. `!tp` and related third-person cvars are now applied through the Anne shared mode configs.
- Continued the `infected_control.smx` refactor and optimization work: added Left4DHooks PVS/visibility helpers, spawn-performance settings, queue tuning, and wave-decision cleanup to reduce abnormal spawns, double Smoker tongue cases, and overly fast refill waves.
- Added `anne_cvar_shield.smx` to protect key Anne cvars, preventing plugin or vote leftovers from leaking one mode's difficulty into another.
- Added the 26-7 test config `Anne25-11.cfg`, kept `infected_control25-11.smx` as a rollback build, and updated the dynamic difficulty notes.
- Fixed extreme-difficulty values affecting other difficulty levels; dynamic difficulty switches now reset Tank, Hunter, and related tier parameters more explicitly.
- Fixed cases where saferoom melee weapons might fail to appear, and cleaned up `MeleeInTheSafeRoom` logic.
- Reverted `spawn_vote_menu.smx` to the classic SourceMod menu and removed the external menu dependency. Anne and campaign spawn count, interval, auto mode, and teleport checks now start one vote per selected setting, while presets still vote on the full preset.
- Added and reorganized the not0721 coop/community/mutation modes, dirspawn presets, weapon configs, and SI limit configs.
- Added traitor-mode logic, spawn preset tables, and multilingual phrases to `infected_control` for future gameplay extensions.

#### Player Experience, Votes And Feedback
- Adjusted `l4d_stats.smx` custom-map scoring: ordinary custom maps award saferoom and strong-clear bonuses only after more than five minutes of actual map time, official maps retain their existing scoring, and custom finales do not receive team completion points while map timing, map records, and Special Infected statistics continue to be saved normally.
- Replaced the old `hextags` plugin with `hextags_lite.smx`, fixed title colors, hid admin commands, and moved the config to `hextags_lite.cfg`.
- Added more multilingual phrases for `global_chat.smx`, `join.smx`, and related messages, including global-chat status and LFG receive-state text.
- Fixed `l4d_stats.smx` quarterly ranking and persistence details, added more round-state tracking, and reduced some database/high-peak status write pressure.
- Merged the old `killsound` and ding sound voting behavior into `l4d2_hitsound.smx`; removed the old `sound_on/off` vote files and unified hit, kill, headshot sounds and icons under the feedback plugin.
- Updated `spechud.sp`: added ping display, adjusted bonus percentage breakdowns, and fixed spectator delay display.
- Disabled `basevotes.smx` and removed the no-charge Hunter direct vote entry to reduce conflicts with Anne dynamic difficulty and the new vote menu.
- `server_name.smx` no longer rewrites the SourceBans description directly; that display is now handled by the external proxy flow.
- Lowered high-peak unload and NPC-manager polling/prompt frequency to reduce extra load during busy periods.
- Hid some admin command output to reduce player-facing chat noise.

#### Upstream Sync, Maps And Core Dependencies
- Updated Left4DHooks, gamedata, includes, and test sources; added new natives/forwards and rebuilt the affected plugins.
- Updated `ai_tank3.smx`, fixed RPG score permission handling and extreme-difficulty callback/parameter issues, and adjusted Tank behavior configs.
- Synced upstream map and stripper fixes for Dead Center 2025, City 17, No Echo m3, Carried Off `cwm1_intro`, and more. Applicable zonemod changes were mirrored into `zonemod_anne`.
- Synced `cwm1_intro` hittable/clipwall fixes and updated `mapinfo.txt` for multiple modes.
- Removed the Rust server-browser tool and Docker deployment README from this repo; those workflows are now maintained through external tooling/web paths.
- Updated the `basevotes.smx` location, SourceMod configs, database fields, and several docs to keep the plugin pack structure cleaner.

### July 14, 2026 Dynamic Difficulty Hotfix
- Fixed the hard-coded `level0` profile overriding mode-specific values in 1vHunters, Alone, WitchParty, and other modes. The plugin now captures each mode's effective CVar baseline after configs execute and restores it before tier changes, map changes, and unloads.
- Removed invalid low-tier reset values such as `z_lunge_up 0`, `z_lunge_interval 0.08`, and `z_lunge_cooldown 0`, fixing Hunters repeatedly crouching or pouncing in place with the legacy `ai_hunter_2` plugin and preventing unintended Jockey, Tank, and Boomer overrides.
- Extreme and Neri retain their explicit overrides; leaving those tiers now restores the active mode's captured baseline.

### July 15, 2026 Dynamic Difficulty Fix
- Fixed controlled-CVar baseline discovery potentially missing later difficulty sections. The plugin now scans `level1` through `level6` explicitly, preventing Extreme- or Neri-only values from remaining after switching back to Expert or below.
- Fixed the legacy `ai_boomer_2` retaining a downward pitch after dynamic tiers enabled aim lift/turning, causing Boomers to vomit toward the ground. Initial aiming and multi-target turns now retain at least five degrees of upward pitch without changing bhop or jump-vomit parameters.
- Removed four obsolete CVars not registered by the active AI plugins. Three hidden/launcher CVars that SourceMod can resolve and modify remain configured.
- Fixed switching from a fixed tier back to automatic mode retaining Neri/high-tier CVars while PPM data was temporarily unavailable. The plugin now applies Easy as a safe baseline, then selects the automatic tier once statistics are ready.
- Fixed server-console/RCON `sm_aidiff` commands being deferred by the saferoom lock, which made operational tier changes appear not to apply. Console and RCON changes now apply immediately, while player-issued admin commands after leaving the saferoom still take effect next round.
- Added opt-in airborne ability switches for Boomer2 and Smoker3. Both default to off and are enabled only by Neri. Existing bhop behavior continues normally; the switches do not force an extra jump, and only let an AI that is already airborne use vomit or tongue. Ground attacks and activation distances remain unchanged.

### July 16, 2026 New-Player Download Optimization
- Reworked FastDL scheduling in `l4d2_blackscreen_fix.smx`. New players now download hit-feedback icons and non-built-in feedback sounds first, while dance assets are filled in during real map transitions.
- `restrict_strings.cfg` is now the first-connect priority list, containing 44 feedback material files and 17 deduplicated feedback sound files. Dance models are no longer downloaded on the initial connection.
- Added `deferred_strings.cfg` for the 60 dance songs, split into eight groups by default. Each actual `changelevel` offers one shuffled group; no group repeats until all eight have been offered, after which the order is shuffled again. `sm_fixscreen_deferred_group_count` controls the number of groups, and files already present in the client cache are skipped automatically.
- The three interdependent dance model files are downloaded together on the player's first map transition to prevent partial-model errors. The same transition also offers one random song group, and later transitions continue in shuffled, non-repeating order.
- All 124 feedback, model, and dance resources are now stored as path-preserving `.bz2` files in the NewAnneWeb file manager. FastDL now uses `http://anne.trygek.com/fastdl/left4dead2` with Cloudflare edge caching.

### July 22, 2026 Dynamic Difficulty PPM Fix
- Fixed automatic difficulty locking its team PPM snapshot too early at `round_start`, which could leave players who subsequently switched to spectator in the round's tier calculation.
- The round-start tier is now provisional. Survivor-roster changes inside the saferoom invalidate that PPM, and the plugin recalculates and locks from the real players still on the Survivor team when the first Survivor leaves. Spectators and bots are excluded.

### July 23, 2026 FastDL Map-Transition Stability Fix
- Removed the `l4d2_blackscreen_fix.smx` call to the private engine function `CNetworkStringTable::DeleteAllStrings()`, preventing the `downloadables` table from being cleared during map loading and potentially crashing or watchdog-restarting the server.
- Download scheduling is now append-only: each map adds the priority feedback files, while a real transition uses SourceMod's public `AddFileToDownloadsTable()` API to add the three dance model files and one shuffled song group. No string-table entries are deleted, overwritten, or restored.
- `fornite_l4d.smx` retains its original full dance-asset download registration behind the new default-off `sm_emotes_add_downloads` switch. This server uses the globally loaded `l4d2_blackscreen_fix.smx` for staged downloads, while other servers can enable the switch to restore one-shot downloads.

### July 26, 2026 Map Records v2
- `l4d_stats.smx` now records a general `ruleset_key`, ruleset version, record policy, and timing/difficulty profiles. Anne modes retain fastest-time leaderboards; co-op and survival rulesets are isolated; versus, realism versus, and scavenge use round history instead of misleading fastest-time comparisons.
- Added `map_runs`, `map_run_players`, and `legacy_map_bests`, plus repeatable migration and rollback scripts. Existing `timedmaps` and `timedmap_runs` stay intact, with legacy per-player bests kept distinct from real runs.
- NewAnneWeb now reads v2 records across the player profile, map list, and detail pages, with filters for ruleset, version, difficulty/AI level, team size, and Anne spawn settings. Deployment steps are documented in `docs/map_records_v2_migration.md`.

### August 10, 2026 Boomer/Spitter Path-Follow Bhop
- Upgraded the native `anne_nextbot` extension to 1.3.0. It remains the single `PathFollower::Update` detour and now copies bounded path-segment values in native code. Tank, Charger, Boomer, and Spitter read snapshots through natives; SourcePawn no longer receives or reads PathFollower/PathSegment pointers. Shared path signatures and vtable offsets now live only in `anne_nextbot.games.txt`.
- Upgraded Tank `ai_tank3` to 1.0.0.4 and Charger `ai_charger3` to 1.0.1.4, migrating their existing path-follow bhop logic to the same native snapshots. Their gamedata now retains only class-specific claw, charge, and locomotion calls instead of duplicating common PathFollower definitions.
- Upgraded Boomer to `ai_boomer_3.smx` 3.0.4 and Spitter to `ai_spitter_3.smx` 3.0.2. Their bhop movement now prefers a valid path look-ahead goal and falls back to native/direct behavior when the path is stale or blocked, or when a climb, gap jump, or other special traversal is ahead.
- All four AI plugins now share `ai_path_movement.inc` for airborne-time prediction, wall/landing/local-gap safety checks, and gradual airborne velocity correction. Charger-specific charge, repath, and lateral-duel decisions remain in its state machine.
- Boomer can keep approaching around corners while direct sight is temporarily lost when a valid PathFollower route remains available, while retaining the 26-07 AI2 vomit-pitch fix.
- The active 2026-08 AnneHappy, Hardcore, and Shotgun configs load AI3. `Anne26-07.cfg` continues to load the unchanged `ai_boomer_2.smx` and `ai_spitter_2.smx` as the 26-07 rollback build.

### August 13, 2026 infected_control Audit Fixes
- Upgraded `infected_control.smx` to 2026-08-13.2 with fixes from a full code audit. The wave-timing contract (kill phase, independent 16-second base countdown, unbounded Anti-Bait hold) is unchanged.
- Fixed double counting of alive specials: full-scan recounts such as `RecalcSiCapFromAlive` now skip clients already in the kick queue, so teleport kicks no longer prematurely fill class/total caps.
- Fixed a deadlock where a failed progress export after a dynamic Nav topology rebuild (elevators, etc.) kept spawn searches pending forever; the pending flag is now cleared and legacy flow buckets take over, restoring the Director fallback.
- Fixed cross-map cache pollution: the survivor-flow fallback value and the per-bucket alive-SI count cache are now reset on round/map cleanup, so a lower `GetGameTime` on the next map can no longer revive stale data; also freed two ArrayList handles leaked on every bucket build.
- Hardened the Nav bucket disk cache: a cache whose metadata matches but contains no usable areas is deleted and rebuilt, and a failed export now removes the partial file instead of leaving it for the next load.
- Fixed two teleport-supervision issues: an unknown spawn time is no longer treated as a permanent spawn grace (specials adopted after a watchdog hard recovery are re-stamped and can be teleported again), and Smokers now accumulate invisibility ticks while their ability is on cooldown instead of restarting the count once ready.
- Improved the `GetNextSpawnTime` native: during the kill phase it returns the upper-bound "remaining check window + full base countdown", and while paused it falls back to the frozen wave clock instead of conflating kill-phase time with the base countdown.
- Anti-Bait state machine redesign: clearing a hold by spreading now requires sustained confirmation — the new `inf_antibait_spread_confirm` (default 3 seconds) demands the formation stay spread continuously before Pressure demotes. Briefly stepping away and immediately regrouping no longer tricks the intensive hold, and spreading no longer resets the stall clock. A team that regroups while still stalled inside the arm window re-enters Pressure directly as a continuation of the same hold.
- Decoupled the Anti-Bait progress snapshot: a survivor flow-read failure (elevator, bad Nav) no longer counts as a "vulnerable" member that wrongly blocks or releases holds; such members still participate in formation statistics and are only excluded from flow statistics. Flow baselines rebuild when readings recover, also without resetting the stall clock.
- Traitor materialization is no longer capped by `totalSI`: a traitor in the SpawnAllowed state whose release wave has arrived (their slot was already deducted from that wave's AI budget) may materialize even when leftover AI temporarily fills the limit; AI backfilling pauses on its own while over cap.
- `create_panic_event` now uses a rolling 60-second window refreshed by every new panic event and cleared immediately by `panic_event_finished`; this prevents custom maps that never send the finish event from silently bypassing Anti-Bait for the whole round, while continuous/infinite horde scripts keep refreshing the window unaffected.
- `sm_wavestatus` and the Nav debug command replies now use translation phrases (12 new phrases across zh-CN/zh-TW/en/ja/ko/vi) instead of hard-coded Chinese.
- The "healthy survivors + no Tank" mercy gates on the early countdown trigger are confirmed as intentional design and are now documented in the AGENTS.md behavioral contract (together with the spread-confirmation and traitor-exemption semantics).

### August 13, 2026 AI3 Plugin Audit Fixes
- Upgraded `ai_tank3` to 1.0.0.8: `OnPlayerRunCmd` now aggregates sub-logic results before returning, fixing dropped button edits for the rock-throw distance limit, the anti-headblock forced rock, and the bhop jump keys. Punch vision lock now uses the GameTime clock consistently, rock release height is resolved via animation activity names instead of relying on sequence/enum value coincidence, and the `tank_swing_range` change hook is no longer re-added on every map change.
- Upgraded `ai_charger3` to 1.0.1.6: fixed the state machine `transitionTo` never running the old state's `OnExit` (the guard read the static struct before loading it), so air-brake, retreat-hop, and artificial charge-delay flags now reset correctly on state changes. The `player_spawn` event is now a Post hook, and clearing jump/duck input on ladders now correctly returns `Plugin_Changed`.
- Upgraded `ai_boomer_3` to 3.0.6: `L4D_OnVomitedUpon` now validates the attacker, fixing per-hit errors when the attacker is 0 (bile bombs etc.); the vomit-turn queue is no longer rebuilt while one already exists, preventing duplicate target growth from forced-bile recursion; fixed a trace handle leak on early return in victim selection and a wrong-index bile-state flag in the force-bile loop; the closest-survivor lookup is now cached for 0.2 seconds to cut per-frame sorting cost.
- Upgraded `ai_spitter_3` to 3.0.4: fixed the crowded-target policy copy-paste bug that used the pinned target's position (including a -1 index error), fixed `getTargetByPriority` leaking its ArrayList whenever someone was pinned or only one survivor remained, allowed a lone survivor to be selected by flow, zero-initialized the crowd-distance accumulator cell, and removed the always-false ray filter dead code.
- Trace-cost optimization: `ai_path_movement.inc` gains a jump-route failure throttle — safety checks that fail due to terrain (walls, gaps, dangerous landings) are not retried within a 0.1s cooldown. All four AI ground-hop attempts use it, cutting hull/ray trace cost while an SI is terrain-blocked to roughly 1/6 (at 60 tick), with the biggest win in multi-Charger lineups. `AIPathMovement_IsJumpRouteSafe` also moves the trace-free no-vision angle rejection ahead of the hull trace, so rejected attempts no longer emit any traces.

### August 13, 2026 Network Quality Reports
- Upgraded `network_quality_hint.smx` to 1.1.4. The plugin ConVar still defaults to `nqh_report_enable "0"`, so local ping/loss/choke checks do not depend on reporting. This repository now sets `nqh_report_enable "1"` in `cfg/sourcemod/network_quality_hint.cfg` for Anne game servers on the website whitelist.
- Reporting requires SteamWorks. Without SteamWorks the plugin still loads and shows local hints, but it will not POST to `nqh_report_url`.
- Community servers that are not on the website whitelist should keep or restore `nqh_report_enable "0"`.
### August 13, 2026 Hat/Skin Save Fixes
- Upgraded `l4d_hats.smx` to 1.46.1: added `Hats_SetClientHat` / `Hats_GetClientHat` natives so RPG can restore hats without going through the `sm_hatclient` console command.
- `L4D_OnHatLoadSave` now reports `-1` when a hat is removed, instead of colliding with the first hat's 0-based index. Cookie deletion and saved-hat restore now follow menu access (including top 100) and wait for rank data, so saved hats are no longer wiped.
- Upgraded `rpg.smx` to 2.0.1: hats, skins, and glows are reapplied after the database load finishes; hats/skins are no longer cleared to 0 while the scoreboard cache is still loading.
- The first hat is stored as `-2` so `HAT=0` no longer means both "no hat" and "first hat". Selecting a hat before the old row is read no longer overwrites the new choice.
- Skins had the same "not restored after async DB load / cleared before rank data is ready" hole and are fixed together. Titles, recoil, damage HUD, and hit sounds already restore from their own load callbacks or separate cookie/database paths.

### August 13, 2026 All-Newbie Team Bonus
- Upgraded `l4d_stats.smx` to 1.5.6. When every human survivor is a new player and there are at least four of them, the whole team earns a 1.5x newbie-team multiplier instead of nobody getting the mentoring bonus.
- One to three new players still use the old rule: only experienced survivors receive 1.1 / 1.3 / 1.5.
- Added `l4d_stats_newbie_bonus_all_newbie_multiplier` (default 1.5) and `l4d_stats_newbie_bonus_all_newbie_min` (default 4). Saferoom, finale, and round-start chat explain the team bonus in each language.
