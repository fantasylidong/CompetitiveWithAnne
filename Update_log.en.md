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

### August 13, 2026 Hit-Feedback Sound Set Customization
- `l4d2_hitsound.smx` sound sets gain two optional config keys to customize when they ring: `headshot_kill` assigns a dedicated sound for headshot kills (empty = fall back to the headshot sound, i.e. the old behavior), and `stack` controls whether the set plays every hit/kill event immediately and independently (same-frame stacking). `stack` defaults to 1 (stacking); only an explicit `stack 0` enables the one-sound-per-frame priority merge (kill > headshot > hit).
- Set 9 "original ding vote plugin" uses these to replicate the old killsound (Dingshot) feel: headshot hit = ding (littlereward), headshot kill = bell (bell_normal), non-headshot hits/kills stay silent; shotgun multi-kills ring once per kill again.
- The `!snd` main menu now offers two personal playback settings to all players (stored in the per-server KV file, not the database): "headshot-kill sound on/off" (off = headshot kills fall back to the normal headshot sound) and a three-state "sound playback mode" toggle (follow set / force stacking / force merging). The toggle replies use translation phrases (5 new phrases across zh-CN/zh-TW/en/ja/ko/vi) explaining what each mode does.
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
### August 13, 2026 text Plugin Status Translations
- `optional/AnneHappy/text.smx` now prints `!xx` / join / round-start status lines in the client's language, so English players no longer see hard-coded Chinese such as "特感", "连跳", "动态难度", or "回血".
- English no longer uses Chinese word-for-word phrasing such as "does not exceed 10 special". Japanese no longer mistranslates AnneHappy as "unhappy".
### August 13, 2026 Survivor MVP Translations
- Upgraded `survivor_mvp.smx` to 0.3.4. Round MVP/LVP lines, personal ranks, and bot prefixes no longer hard-code Chinese; they are printed in the client's language, so English players no longer see "特感/小僵尸/友伤/[机器人]".
- Japanese, Korean, and Vietnamese no longer mistranslate SI/FF/Anne compact stats as "special sense", "black gun", or "pharmacy". Spanish now includes the previously missing Tag and Anne compact-stat keys.
### August 13, 2026 l4d_stats Chat i18n
- Upgraded `l4d_stats.smx` to 1.5.6. Remaining hardcoded English chat fragments now use translation phrases; all 315 Simplified/Traditional Chinese, English, Japanese, Korean, and Vietnamese phrases are aligned, and the per-language files are no longer limited to the 13 map-record strings.
- Special Infected kill, Smoker/Hunter save, Charger rescue, and Tank rock announcements now show class names in the viewer's language. Human players still appear by nickname.
- Map-record team fallback names and the console `[RANK]` prefix are translated. Upgraded `global_chat.smx` to 1.1.1 so global map-record broadcasts use the same team-name phrases.
### August 13, 2026 Anne Tank Announce Translations
- Upgraded `optional/AnneHappy/l4d2_tank_announce.smx` to 1.0.1.1. Chat, hint, and center text now all use i18n phrases; Player/AI name prefixes are built in the client's language, so English players no longer see a hard-coded Chinese "(玩家)".
- English no longer uses Chinese word-for-word phrasing ("has been generated / controller"), and the hint line is translated. Spanish now includes the previously missing Anne-specific keys.
- Also aligned the versus `Spawned` phrases in Japanese, Korean, Vietnamese, and Traditional Chinese, keeping Tank as a proper noun.
### August 13, 2026 Water Slowdown Chat Translations
- Fixed `l4d2_slowdown_control` chat lines for water slowdown while Tank is in play and after Tank dies. English no longer uses Chinese word-for-word phrasing such as "tank generation", Vietnamese no longer mistranslates Tank as "xe tăng", and Japanese no longer uses two different plugin names.
- Simplified Chinese, Traditional Chinese, English, Japanese, Korean, and Vietnamese now match the upstream meaning: water slowdown is reduced while Tank is in play, then restored to normal.

### August 13, 2026 server_name leftover AI difficulty tag
- Upgraded `server_name.smx` to 1.4.8. Room-name tags such as `[AI:Expert]` are shown only while `annehappy_dynamic_ai_difficulty.smx` is actually loaded and a tier has been chosen.
- Unloading the dynamic-difficulty plugin leaves `ah_ai_dynamic_current_level` behind in SourceMod. The old hostname logic kept writing a leftover 1-6 value into `hostname` / `sn_main_name`. It now checks whether the plugin is running and strips any `[AI:...]` already baked into the room name.
- Upgraded `annehappy_dynamic_ai_difficulty.smx` to 2026.08.13.1. It registers the `annehappy_dynamic_ai_difficulty` library and resets `current_level` / `current_mode` / `current_ppm` / `current_locked` to 0 on unload, so HUD, `!xx`, and spawn strategy do not keep reading a stale tier.

### August 13, 2026 Scripted HUD custom slots and white-box hardening
- Upgraded `extend/l4d2_scripted_hud.smx` to 1.2.0. HUD 3 / HUD 4 now support player-selectable content: `!hudmenu` gains "HUD 3/4 content" submenus offering Server default / Survivor status / Special infected HP / Kill stats / Player ping. Choices persist in cookies and the `scripted_hud_prefs` database (old tables are ALTER-migrated automatically).
- The Special infected HP page shows the alive SI count vs the limit, each small SI's current HP (Smoker/Boomer/Hunter/Spitter/Jockey/Charger), Tank current/max HP, and the Witch count. Kill stats track per-survivor SI/common kills for the round; the ping page lists human players' latency (survivors first). All text uses translation phrases (Simplified/Traditional Chinese, English, Japanese, Korean, Vietnamese).
- Hardened the occasional "three empty white-outlined rectangles" seen around the hudmenu: those frames are EMS scripted HUD slots rendered in a transient "visible but neither NOBG nor TEXT" flag state. Per-client HUD flags are now rebuilt from the authoritative server flags so the ResetHUD refresh window can no longer send flags of 0, and unused EMS slots 4-7 are explicitly hidden on map start so stale slot data cannot draw empty background frames.
- Panel height is personalized per client from the actual line count (new m_fScriptedHUDHeight sendproxy), so multi-line custom content is no longer clipped. The `l4d2_scripted_hud_hud3_team` default changed from 2 (infected only) to 0 (everyone), so survivors can actually see their chosen HUD 3 content.
- HUD 2 gains a "Team wipe count" field: it reads `anne_round_wipe_count` published by `server.smx` (wipes on the current map, reset on transition), and shows `[Wipes xN]` at the end of HUD 2 once at least one wipe happened. HUD only - the room name is untouched. Toggle it under `!hudmenu` -> "Configure HUD 2 fields". Players with previously saved HUD 2 preferences start with the field off and need to enable it once; new players get it on by default.

### August 13, 2026 Scripted HUD extra content sources
- Upgraded `extend/l4d2_scripted_hud.smx` to 1.3.0. HUD 3 / HUD 4 content menus gain six extra sources, still chosen per slot and saved to cookies/database.
- Tank damage board: ranks survivors by damage this tank fight (top 4, with percent). The board stays after the Tank dies until the next Tank; "No Tank" when none is in play.
- Team items: one compact line per survivor for throwable / heal / temp (molotov/pipe/bile, kit/defib/incendiary/explosive, pills/adrenaline; empty is -).
- Next SI wave: reads `infected_control`'s `GetNextSpawnTime` native (shows -- if the plugin is not loaded) plus live small-SI count vs the limit.
- Speed / bhop: horizontal speed of yourself (or your spectated survivor) and the current bhop peak; the peak clears after about 0.25s of grounded walking.
- Round timer + horde: mm:ss from `round_start`; "ON" during the 60-second rolling `create_panic_event` window, otherwise the director horde countdown (`L4D2CT_MobSpawnTimer`).
- Witch distance warning: meters to the nearest Witch and state (calm / near / alert / enraged); "NEAR" inside 15 m. Extra Witches are counted separately. New phrases are translated in all six languages.

### August 13, 2026 Scripted HUD uses all 15 engine slots
- Upgraded `extend/l4d2_scripted_hud.smx` to 1.4.0. All 15 EMS HUD slots can be assigned a content source in `!hudmenu` → "All 15 HUD slots" (server default / unused / survivor status / SI HP / kills / ping / tank damage / team items / next wave / speed / round timer / Witch warning / progress-tank-witch / server status).
- HUD 1-4 keep their old defaults. Slots 5-8 (engine 4-7) stay hidden until a source is chosen, then they appear in a left column. Slots 9-15 (engine 8-14) keep passing through the engine kill list until you bind content to that slot, which then covers that kill line and moves it to the lower right so it does not sit on the crosshair.
- Preferences are stored in the cookie and `scripted_hud_prefs` (`hud_mask` widened to smallint, new `slot_sources` column; old 6-field cookies and hud3/hud4 columns still load). Slot names and menus are translated in all six languages.
- 1.4.1: Slot coordinates follow the screen aspect. `!hudmenu` → "Screen layout" offers 16:9 / 16:10 / 4:3 / 21:9. Extra slots sit in a left column (4-9) and a right column (10-14) with spacing that clears HUD 1-4, the kill feed, the crosshair, and the weapon tray. 4:3 narrows to avoid right-edge clipping; 21:9 pulls into a centered 16:9 safe area. Each player gets their own layout through SendProxy.
- 1.4.2: SI HP, next-wave countdown, the next-wave spawn queue, and HUD 2's "SI count / interval" are shown only to spectators and infected; survivors hide the whole slot. The menu marks those sources with " (spec/SI)". New "Next SI queue" source reads `InfectedControl_GetSpawnQueue` from `infected_control` (older plugins show --). Extra slots in the same column stack by their real line count; extra slots cap at 4 lines and HUD 3/4 at 6 so long text no longer overlaps.
### August 13, 2026 Spawn Dispersion and Class Variety
- Upgraded `infected_control.smx` to 2026-08-13.11 to push Hunter / Jockey / Charger even further off the survivor rear. Hard-reject **-5→-4** (`inf_score_behind_reject_gap_hjc`), behind-penalty scale **2.0→2.5**, flow back-anchors **-4/-3**. Hunter rear 0.15→0.05; Jockey no longer uses rear. Same-flow candidates still score. Smoker / Spitter / Boomer and wave timing are unchanged.
- Upgraded `infected_control.smx` to 2026-08-13.10 to further cut Hunter / Jockey / Charger spawns behind the survivor flow. Those three now hard-reject at **-5** (`inf_score_behind_reject_gap_hjc`) instead of the global -8, and their behind-flow penalty is multiplied by `inf_score_behind_hjc_scale` (default **2.0**). Their flow back-anchors move from -10/-9 to **-5/-4**; same-flow candidates still score. Hunter tactical quality leans flank/edge instead of rear; Jockey rear weight 0.15→0.05. Smoker / Spitter / Boomer keep the global behind rules. Wave timing is unchanged.
- Upgraded `infected_control.smx` to 2026-08-13.9 to ease hard separation another step. `inf_spawn_sep_radius` 150→**120**, `inf_spawn_sep_ttl` 2.5→**1.5**; same-Nav cooldown `NAV_CD_SECS` stays **1.0** s. Wave timing is unchanged.
- Upgraded `infected_control.smx` to 2026-08-13.8 so Hunters have a bit more pounce-setup distance. The preferred band moves from 350–750 to **350–850**, and the sweet spot from 38% (~500) to 48% (**~590**), still in the mid third rather than the old 950 far band. Charger / Jockey bands are unchanged. Wave timing is unchanged.
- Upgraded `infected_control.smx` to 2026-08-13.7 to pull Charger / Jockey / Hunter off overly far landings. Hunter’s preferred band shrinks from 350–950 to **350–750**, the distance sweet spot moves from 45% to 38% of the ring (~500), high-sort scale 0.90→0.95, and high-ground range compensation 800→450 so distant perches are no longer discounted into “mid” range. Jockey’s preferred band is **250–550**, Charger **250–600**, with slightly closer sweets; their dispersion weights drop from 1.15/1.00 to 0.75/0.65. Global hard-sep radius 180→150, kernel points 40→30, and the scoring budget changes from near/mid/far 6/4/2 to **6/5/1**. Wave timing is unchanged.
- Upgraded `infected_control.smx` to 2026-08-13.6. Distance bands go back from 10 to **6** (stage 0 is still the full preferred interval; stages 1–5 interpolate from the preferred max to the final max). Ten narrow rings left near/mid/far with only a couple hundred units to split; six wider rings make the tertiles meaningful. Near/mid/far are now thirds of the **current band’s search ring** (`scanMin..maxRange`), not the current page’s min/max, so a first page that only covers the near end of the ring is not re-split into a fake near/mid/far. Sector quota still constrains the first 2/3 of the bands (0–3) and exempts the last third (4–5). Wave timing is unchanged.
- Upgraded `infected_control.smx` to 2026-08-13.5. The scoring budget is no longer “the first 8 qualified points this tick”: each directed candidate page is split by path-distance tertiles and scored as **near 6 / mid 4 / far 2** (12 total). Consumption interleaves 3:2:1; a full tertile skips expensive visibility/path checks, and unused tertile slots overflow so an empty band does not stall the spawn. `inf_spawn_nav_expensive_per_slice` defaults to 24 (was 16). CVars: `inf_spawn_budget_near/mid/far` (all 0 disables tertiles). The ranked high-ground channel keeps in-group order and only interleaves tertiles. Wave timing is unchanged.
- Upgraded `infected_control.smx` to 2026-08-13.4. This release reworks spawn dispersion so a wave no longer lands in one small cluster, and adds controlled randomness to the class lineup. The wave timing contract (kill phase, independent 16-second base countdown, Anti-Bait) is unchanged.
- Distance bands are refined from 6 to 10 stages: each class keeps its full preferred band at stage 0 (e.g. Smoker 500–1200) so spawns do not get closer on average, while the failure-driven widening now interpolates linearly between the preferred and final maximum (Smoker +200 per stage up to 3000). Each escalation scans a smaller ring, distances ramp up more smoothly, and a ring is more likely to fit into one shuffled page. The sector quota accordingly constrains the first 2/3 of the bands and exempts the final third.
- Directed candidate pages are now shuffled after fetching (`inf_spawn_candidate_shuffle`, default on). The old flow consumed candidates in ascending path-distance order and accepted at most 8 qualified points per attempt, so scoring only ever saw the nearest little cluster; after shuffling, the scored set spans the whole distance band. The ranked high-ground channel keeps its ordering and is not shuffled.
- Hard separation is now configurable and stronger: `inf_spawn_sep_radius` (default 180, previously hard-coded 80) and `inf_spawn_sep_ttl` (default 2.5 s, previously 0.5 s), still scaled by the SI limit.
- The dispersion score gains a continuous kernel penalty: alive SI and recent spawn points subtract exp(-d/r)-weighted points (`inf_spawn_kernel_radius` default 280, `inf_spawn_kernel_points` default 40), complementing the coarse "last 3 sectors" memory, which is kept.
- New per-wave sector quota: spawns per sector per wave ≤ ceil(SI limit / sectors) + `inf_spawn_sector_quota_bonus` (default +1, -1 disables). Only the first four distance bands are constrained; far bands and the Director fallback are exempt so narrow maps cannot starve.
- High-ground priority now uses the extension's ranked directed candidates: `inf_nav_high_sort_scale` is re-enabled (new defaults Smoker 0.85 / Hunter 0.90). Candidates at least `inf_nav_high_sort_min_height` (64) above the target are front-loaded by discounted distance into the limited scoring budget, instead of relying on after-the-fact score bonuses inside the near-ground cluster.
- Class variety: class scarcity picks now apply a small random jitter of ±`inf_class_scarcity_jitter` (default 0.06) to break the fixed per-wave rotation among similarly occupied classes, and the support gate (Boomer/Spitter unlocking after pressure classes) is randomly waived per wave with probability `inf_support_gate_waive_prob` (default 0.15); breach waves never waive it.
- The `[SCORE-CHOSEN]` debug log and the `sm_navdebug` score breakdown now include the kernel term (kern).

### August 14, 2026 Network Quality Reports Prefer Loss
- Upgraded `network_quality_hint.smx` to 1.1.5. Website incidents now focus on packet loss: choke below `nqh_report_choke_limit` (default 20%) is no longer reported as an incident. Local chat warnings still use `nqh_choke_limit` (default 5%).
- Incident reason codes: timeouts stay `timing_out`; otherwise prefer `loss`, then `ping`, and `choke` only when above the report threshold.

### August 14, 2026 Player-facing text alignment
- The last `!xx` status field is now "Version", not a telecom-line label. English Tank stall / HP return and Japanese Expert / bunnyhop wording now match the source meaning.
- Traitor and Anti-Bait hints distinguish stalling, hold active, and wave released. Japanese, Korean, and Vietnamese fill in leftover English and use a single traitor name.
- Default Scripted HUD survivor status is built in the client's language. The header now says revive count instead of a current-downed label.
- Black-and-white hints use phrases and say the next down is death. The `!ht` menu adds Japanese, Korean, and Vietnamese. Chinese skill-detect class names now match traitor/stats wording.

### August 15, 2026 Actions crash fix
- Fixed `actions.ext` reinserting missing user-data keys while destroying Actions and never removing three Action-pointer caches. The Linux extension is now `3.7.6-anne.2` and erases user-data, identity-data, and actor cache entries on destruction.
- Fixed Actions method propagation creating empty pre/post listener hash entries for every Action even when no listener existed, then retaining the outer Action-pointer key after destruction. Candidate Action pending markers are now cleaned up as well.
- Updated `ai_charger3` to 1.0.1.7. `ChargerEvade` now defers `CommandABot(MOVE)` to the next frame instead of synchronously rebuilding the NextBot behavior tree inside an Actions `OnUpdate` callback.

### August 15, 2026 New-player traitor state cleanup
- Upgraded `infected_control.smx` to 2026-08-15.1. A player entering the server now explicitly clears traitor registration from the occupied client slot. Even if cleanup for the previous occupant did not finish, the new player starts as a non-traitor and `join.smx` can move an accidental infected-team assignment back to spectator. Registering as a traitor afterward is unaffected.

### August 15, 2026 Scripted HUD next-wave state fix
- Upgraded `infected_control.smx` to 2026-08-15.2 with a wave-status native that distinguishes the kill phase, independent base countdown, and Anti-Bait hold. The legacy ETA native remains compatible.
- Upgraded Scripted HUD to 1.4.4. Exact seconds are shown only during the base countdown; the kill phase and Anti-Bait hold use explicit localized states. Version 2026-07 and older providers show `--` because they lack the state API, instead of exposing an estimate that can be off by about eight seconds.

### August 15, 2026 Scripted HUD integrates the CS kill feed
- Upgraded Scripted HUD to 1.5.0. Removed the standalone `l4d2_cs_kill_hud.smx` and its old kill-feed votes; the CS-style feed is now built in. It is off for each player by default and can be toggled independently in `!hudmenu`, without a server-wide enable switch.
- For a player who enables it, SendProxy takes over engine slots 8-14 (shown as HUD 9-15 in menus) only for that recipient, and those slots disappear from that player's configurable-slot menu. Players who leave it off continue to receive the native kill list and keep their own slot preferences.
- Reworked `!hudmenu` into CS kill feed, Core HUD (1-4), Extra HUD (5-8), Extended HUD (9-15), screen layout, and HUD 2 field groups. Kill-feed and slot preferences are stored per player.

### August 15, 2026 Removed the corpse-dissolve vote
- Removed the "dissolve corpses" vote from every mode menu and deleted `cfg/vote/dissolve_on.cfg` and `cfg/vote/dissolve_off.cfg`.

### August 19, 2026 Anti-Bait pauses on low HP with no medkits
- Upgraded `infected_control.smx` to 2026-08-19.1. Anti-Bait now enters `Paused` when every standing survivor has permanent health below `inf_antibait_lowhp` (default 40) and no living survivor is carrying a first-aid kit, defibrillator, pain pills, or adrenaline. Incap health is not permanent health. Set the threshold to 0 to disable this gate.

### August 19, 2026 Scripted HUD restores survivor SI count/interval
- Upgraded Scripted HUD to 1.5.1. Version 1.4.2 hid HUD2's special-infected count/interval together with live SI HP, next-wave countdown, and the spawn queue. `[N SI / M sec]` is public room config (the same tag as the hostname), not live intel. Survivors see that field again, and it coexists with the built-in CS kill feed, which still uses only that player's engine slots 8-14.
- SI HP, next-wave countdown, and the next-wave queue remain spectator/infected only.

### August 20, 2026 Hit-feedback ding set closer to old killsound
- Upgraded `l4d2_hitsound.smx` to 2.6.0. Sound-set optional keys are down to three: `headshot_kill` (dedicated headshot-kill sound), `stack` (same-frame stack vs merge), and `apply_special_only` (write sound range on select). A kill plays one death-event sound only; no extra hurt ping for overkill. Playback is always `SNDCHAN_AUTO`. Fire, inferno, `DMG_DIRECT`, blast, and `weapon_id==0` filters are unchanged.
- A sound package now sets four items together: headshot, hit, kill, and headshot-kill. Players may independently choose headshot-kill set `0..N` (0 falls back to the regular headshot sound). That set ID and playback mode are stored in the RPG table and migrate once from the old `SoundSelect.txt`. The redundant overlay quick toggle and `sm_hitui` were removed; icon set 0 already disables icons.
- Set 9 "original ding vote plugin": ding on headshot hits, bell on headshot kills, silence otherwise; picking it sets the range to all infected.

### August 23, 2026 Per-sound hit-feedback refactor
- Upgraded `l4d2_hitsound.smx` to 2.7.0. Sound sets are now presets that apply only members with real samples; missing members are turned off. Set 9 therefore explicitly enables headshot and dedicated headshot-kill sounds while leaving hit/kill off.
- Players can independently choose the actual source for headshot, hit, kill, and headshot-kill sounds. Each picker lists only sources that provide that sound and previews it immediately. Headshot-kill value `0` still follows the regular headshot sound.
- Fixed the pre-damage `infected_hurt` fatal-shot check, the admin single-item close action clearing all three items, preference writes before initial DB load, authorization timing, out-of-order rapid saves, and the ineffective dynamic master switch. Existing DB/KV values are normalized on load. This refactor adds no columns; databases still missing `hitsound_stack_mode` / `hitsound_headkill` must run the existing idempotent `20260820_hitsound_personal_prefs.sql` migration once.

### August 23, 2026 Shared sound catalog and unrestricted per-event choices
- Upgraded `l4d2_hitsound.smx` to 2.8.0. The 25 non-empty preset references are deduplicated by path into 22 stable shared sounds `S01..S22`; the three duplicate samples in presets 1 and 3 are stored once. Downloads and precaching now also run once per unique sound.
- The headshot, hit, kill, and headshot-kill pickers all show the complete shared catalog, so any sound can be assigned to any event and previewed immediately. Preset labels expose their exact mapping; preset 9 is `[head:S21 hit:off kill:off head-kill:S22]`.
- Existing positive DB/KV preset-source values require no data migration. New shared choices use `-1..-127`, so the four sound columns must be signed integers. The repository schema already is signed; the idempotent `20260823_hitsound_sound_catalog.sql` fixes production tables that were created as `UNSIGNED`.

### August 23, 2026 Dual-layer hat preference persistence
- Upgraded `l4d_hats.smx` to 1.47.0. Hat type, wear toggle, first-person self view, third-person self view, and visibility of other players' hats are all stored in clientprefs cookies and load even when `l4d_hats_save` is `0`.
- Upgraded `rpg.smx` to 2.1.0. When the `rpg` MySQL entry exists in `databases.cfg`, the four toggles use the `RPG` table as primary storage; unavailable MySQL or failed column migration falls back to clientprefs SQLite. Existing accounts migrate `NULL` columns only after cookies are ready, preventing defaults from overwriting saved choices.
- Every rebuilt hat entity keeps its per-viewer `SetTransmit` filter, so hiding other players' hats remains effective across rounds. Added the idempotent `20260823_hat_preferences.sql` migration; the plugin can also add the same columns automatically.

### August 20, 2026 Tank ride detection for embedded riders
- Upgraded `ai_tank3` to 1.0.0.10. Riding still treats `m_hGroundEntity == Tank` as the first proof, so adjacent ledges and stairs are not counted as riding.
- If the ground entity is not the Tank, riding now requires overlapping XY hulls plus a downward hull trace from the survivor's feet that actually hits the Tank. That covers riders stuck in the Tank model whose ground entity is still the world, without using a center ray that merely misses world as proof.

### August 19, 2026 Tank head-ride and ladder drop
- Upgraded `ai_tank3` to 1.0.0.9. Head-block is now two cases: a survivor standing on the Tank hull, and an unreachable overhead stall.
- Riding no longer waits for a 2-second standstill and no longer blacklists the rider. A punch also `SweepFist`s upward at the rider; if they are still on the head after 3 seconds the Tank force-throws in place, without walking 250 units away. Close-range rocks aim straight at the target so the ballistic formula cannot divide by a near-zero horizontal distance. Jump-rocks are disabled while someone is riding.
- Overhead stalls still use the 2-second movement window. If another survivor exists, the Tank switches (standing first, then pinned, then downed). With no alternative it throws in place and no longer `CommandABot RESET`s the same unreachable target, which was restarting the climb-and-fall loop. RESET is also skipped on or near ladders.
- While on a ladder the Tank flattens pitch and locks yaw to `m_climbableNormal`, reducing the vanilla look-at-victim drop.

### August 29, 2026 Independent control-SI target cap
- Upgraded `SI_Target_limit.smx` to 1.7. Smoker / Hunter / Jockey / Charger now share one lock cap: control-SI budget / mobile survivors + 1. The budget is the sum of enabled control-class `z_*` / `inf_*` limits, clamped to `l4d_infected_limit`. Boomer / Spitter / Tank do not occupy this pool.
- Upgraded `l4d_target_override.smx` to 2.26 with `targeted_mask`, so only control SI count toward the cap. Flow-leader ×2 and rushman uncapping keep their previous meaning.
- Anne mode `shared_settings.cfg` files now pin `SI_enable_option 53`.
- Upgraded `l4d_target_override.smx` to 2.27: added `L4D_TargetOverride_SetLastVictim` so AI plugins that rewrite targets through the `L4D2_OnChooseVictim` channel register their choice in the same targeted ledger; also fixed the ledger not syncing when the `L4D_OnTargetOverride` forward rewrites the victim.
- Upgraded `SI_Target_limit.smx` to 1.8: added the `IsClassTargetLimited` native and the `sm_targetlimit_status` admin debug command; fixed a 1.7 changelog comment that terminated early and broke compilation.
- Unified the ledger across SI AI plugins: `ai_hunter_2` / `ai_jockey_2` / `ai_charger3` now respect the control-SI cap before retargeting (no switch when the new target is full), while `ai_spitter_3` / `ai_boomer_3` / `ai_tank3` register their rewrites; `ai_smoker3` never rewrites targets so it needs no hookup.
- Player-count adaptive: the formula scales across 4-player, 5-8 player multiplayer and solo endgames — total capacity is always "control-SI budget + mobile survivors", strictly greater than the control SI on the field; with one or few survivors the cap relaxes automatically, so SI never lack a legal target.
- Version rollback configs `Anne25-11` / `Anne25-10` / `Anne24-5` / `Anne23-1` now reload `SI_Target_limit.smx` (previously `unloadall.cfg` unloaded it and these versions silently lost the target cap).

### August 28, 2026 Per-team HUD slot visibility
- Upgraded Scripted HUD to 1.6.0. Every slot in `!hudmenu` gains a "show for team" submenu accepting any combination of survivor/spectator/infected (at least one must stay selected), so a slot can, for example, appear only while spectating. Choices persist to cookies and the database (new `slot_team_masks` column, migrated automatically); old preferences default to all teams.
- The team whitelist for sensitive content sources moved from hard-coded rules to the `l4d2_scripted_hud_source_teams` cvar (`source:teammask` pairs; bits 1=spectator, 2=survivor, 4=infected). The default `2:5,7:5,13:5` matches the old behavior—SI HP, next-wave countdown, and the spawn queue remain spectator/infected only—while `13:1` style entries narrow a source to spectators. Menu tags like "(spec/SI)" are now generated from the live configuration, with all six languages updated.
- Slots hidden by team gating no longer transmit their text to the client at all (previously the string still traveled over the network and was merely not rendered). Team changes refresh visibility immediately.

### August 29, 2026 AI Jockey post-shove suppression fix
- Upgraded `ai_jockey_2.smx` to 2026.08.29. Fixed the loophole where shoving the Jockey away was exactly what armed its punish branch: if the survivor's latest swing is the one that shoved the Jockey itself, the "instant leap during shove cooldown" punish no longer fires. The punish still applies to genuinely wasted shoves (whiffs or shoves spent on other SI).
- The post-shove suppression no longer reuses `z_jockey_leap_time` (0.4s in Anne configs). A new dedicated cvar `ai_JockeyShovedCooldown` (default 3.0s, matching the competitive-standard jumpcap block window for shoved Jockeys) governs it. During suppression the plugin applies no bhop/leap enhancements and strips the native AI's leap button, so the Jockey can no longer re-pounce mid-air the moment its 0.9s stagger ends; it can still move and retreat normally. The jumpcap patch's AI exemption and the stagger cvars are untouched.

### August 30, 2026 Jockey post-shove suppression scaled by AI difficulty
- `ai_JockeyShovedCooldown` is now driven by the dynamic AI difficulty system: the six tiers in `dynamic_ai_difficulty.cfg` use Easy `3.0`, Normal `2.5`, Hard `2.0`, Expert `1.5`, and Extreme/Neri `1.0` seconds. `annehappy_dynamic_ai_difficulty.smx` applies the value per tier and restores the baseline on tier changes, so nothing lingers.
- The plugin default of `3.0` equals the Easy tier, so modes that do not run the dynamic difficulty plugin automatically get the most lenient setting.

### August 29, 2026 AI SI path-bhop "sky-launch mega jump" fix
- Fixed path bhop occasionally producing a single absurdly long, flying-looking jump. Three root causes: `ai_spitter_3` / `ai_boomer_3` applied their hop impulse additively onto the current velocity with no cap at all, so on long open stretches the speed snowballed by +100/+150 every hop; the shared air correction kept the recorded hop speed as a floor for the entire airborne phase and even restored the spike after the engine slowed the SI on a wall clip; and the push vector carried a vertical component (Boomer toward elevated path goals, Spitter along its eye pitch), which stacked on top of the jump's own Z velocity into a literal sky launch.
- Upgraded `ai_spitter_3` to 3.0.6 with the new `ai_SpitterBhopMaxSpeed` and `ai_boomer_3` to 3.0.8 with the new `ai_BoomerBhopMaxSpeed`. The additive push is now clamped to that horizontal cap, the push vector keeps only its horizontal component (vertical height stays the jump's job), and the pre-jump safety check now traces with the same velocity that actually gets applied.
- Both new caps follow a "Charger cap +200" rule: the plugin default is 1000 (= `ai_charger3_bhop_max_speed` default 800 + 200), and the six dynamic AI difficulty tiers in `dynamic_ai_difficulty.cfg` are set to 600 / 600 / 700 / 800 / 1000 / 1000 (matching the Charger tiers 400 / 400 / 500 / 600 / 800 / 800).
- Shared module `ai_path_movement.inc`: `AIPathMovement_BeginPathHop` gained a max-speed argument, so the air correction never sustains more than each SI's own bhop cap and externally induced speed spikes are no longer preserved through the whole airborne phase.
- Upgraded `ai_smoker3` to 1.0.1.3 and `ai_tank3` to 1.0.0.11: the takeoff frame is now clamped by `ai_smoker3_bhop_max_speed` / `ai_tank3_bhop_max_speed` too (previously only airborne frames were clamped, so the takeoff instant could exceed the limit). Upgraded `ai_charger3` to 1.0.1.8; its ground/direct bhop already had a cap, and it now registers that cap with the shared air correction.
- Recompiled: `ai_smoker3.smx`, `ai_boomer_3.smx`, `ai_spitter_3.smx`, `ai_tank3.smx`, `ai_charger3.smx`. The Jockey already caps each hop at 400+80 and the Hunter has no bhop logic, so neither needed changes.

### August 30, 2026 Tank bhop cap lowered per difficulty
- Lowered `ai_tank3_bhop_max_speed` by 200 across the dynamic AI difficulty tiers with an 800 ceiling: Easy 500, Normal 600, Hard 700, Expert 800, Extreme 800 (850 hit the ceiling); the Neri tier stays at 1000. Config-only change (`dynamic_ai_difficulty.cfg`), no recompile needed; the plugin default (used without dynamic difficulty) remains 1000.

### August 30, 2026 Cancellable traitor registration; traitor Tank removed
- Upgraded `infected_control.smx` to 2026-08-30. Added `!itcancel` (alias of `!neiguicancel`): a traitor registration can be cancelled any time before its wave releases, and while a registration exists `!it` opens a menu with a single "cancel registration" entry; a cancelled slot is no longer immediately backfilled with an AI. Once the release window opens (SpawnAllowed), cancelling is refused with a "window closed" hint.
- Removed the Tank from traitor classes: selectable classes are now decided by the active spawn pool and the Tank can no longer be registered. The `inf_traitor_class_mask` default and ceiling stay at 127 (bit 64 is kept only for rollback compatibility and never takes effect), and `z_max_player_zombies` no longer reserves an extra slot for a traitor Tank.
- Selectable traitor classes now intersect with the active spawn pool: classes disabled via `inf_*_limit 0` cannot be queued, and the allcharger / allhunter modes only allow Charger / Hunter respectively.
- The effective `inf_traitor_max_slots` is clamped to `l4d_infected_limit - 1`, keeping at least one AI spawn budget per wave. Traitor auto-bhop moved to the OnPlayerRunCmd channel (internal refactor, same behavior). Usage and menu texts updated in all six languages.
- Version rollback configs `Anne26-07` / `Anne25-11` / `Anne25-10` now reload `smart_ai_rock.smx` (previously `unloadall.cfg` unloaded it and rollback versions silently lost smart Tank rock throws).

### August 30, 2026 Charger gun-range bait: two claws then charge
- Upgraded `ai_charger3` to 1.0.1.9. After hopping into `ai_charger3_bhop_min_dist` (default 100), a gun target is treated as a guaranteed hit: no more probabilistic waiting, and the charge window is no longer clamped to 36–95.
- If two claws can land before the target leaves claw range, the Charger punches twice then charges; if claws cannot connect, the target is backing out, or clawing takes more than 2.5 seconds, it charges immediately. Shotguns still charge as soon as they enter 100. Melee bait is unchanged.
- Recompiled: `ai_charger3.smx`.

### August 30, 2026 Loosen high-SI post-spawn repulsion
- Upgraded `infected_control.smx` to 2026-08-30.1. At high SI counts the back half of a wave was being pushed out of the near band by post-placement repulsion: the kernel treated SI already in the survivors' faces as occupancy and ignored the SI-limit scale, while hard separation scaled down with the cap and so tightened exactly when it should have loosened.
- Live SI closer than 400 to any survivor are no longer kernel sources. The SI-limit scale moved off the penalty value and onto the kernel radius (`inf_spawn_kernel_radius` × scale): at low SI it pushes candidates apart, at high SI it only prevents stacking, instead of flattening the whole curve and losing resolution. The `inf_spawn_kernel_points` default rose from 30 to 50.
- The sector dispersion axis was removed entirely (`recentSectors`, the per-wave sector quota, and `inf_spawn_sector_quota_bonus`); directional preference is now expressed solely by the continuous tactical-geometry score, leaving kernel density as the only dispersion term.
- Hard separation is now a fixed radius that no longer scales with the SI cap or with wave occupancy — it only answers "may we spawn here". The `inf_spawn_sep_radius` default dropped from 120 to 100. Wave timing is unchanged.

### 2026-08-30 Uniform AI reaction time across all tiers

- In `dynamic_ai_difficulty.cfg`, `z_acquire_far_time` / `z_acquire_near_time` changed from `5.0 / 0.5` to `0.0 / 0.0` for Easy through Expert, matching Extreme/Neri which were already `0.0 / 0.0`. Target-acquisition delay is no longer a difficulty axis; every tier difference now comes from per-class behaviour cvars.
- Config-only change, no recompile needed. The "reaction time" row in `docs/annehappy_dynamic_ai_difficulty.md` was updated to match.

### 2026-08-31 Pre-commit review fixes

- Rebuilt `ai_charger3.smx`. The shipped binary was still 1.0.1.8, so none of 1.0.1.9 made it in: the claw-combo-then-charge flow, the guaranteed-hit band in `resolveChargeCommitDist`, the control-SI target-cap gate, and the bhop speed cap registration. It was still running the probabilistic charge that the source had already deleted.
- Fixed a divide-by-zero in the `ai_boomer_3` / `ai_spitter_3` push normalisation. When the horizontal component is zero (target directly overhead or below, view pitch at ±90) normalising degenerates into a pure vertical vector, which launches the SI straight up — the very "flying" behaviour this batch set out to fix, reached by another path. Added a shared `AIPathMovement_NormalizeHorizontal()` that skips the push on a zero vector.
- `getChargerClawRange()` now invalidates its cache on map change and refuses to cache an out-of-range read. The previous function-local `static` cached forever, so a first call before the weapon scripts loaded would pin the 70.0 fallback for the life of the process.
- `spechud`'s `FillTankInfo` uses a fixed-size array, dropping the `new int[MaxClients]` heap allocation from every panel build on the HUD draw path.
- `sm_navtest` falls back to `GetTargetAnchorPos` when the target survivor is unusable, instead of comparing the candidate's height against itself (which always scored 0). Also fixes an uninitialised `targetEye`.
- Five SI AI plugins restore `#define REQUIRE_PLUGIN` after `#include <si_target_limit>`, matching `ai_tank3.sp`, so the optional dependency is scoped to that one include.
- `si_target_limit.inc` preserves the caller's `REQUIRE_PLUGIN` state when transitively including `l4d_target_override`, so third-party plugins are not silently given a hard dependency.
- Removed the five unreferenced macros left in `infected_control.sp` after the sector system was deleted, and corrected the `PEN_LIMIT_SCALE_LO` comment.
- Deduplicated `.gitignore` and dropped the nine explicit paths already covered by `/test_results`.
- Added the missing jp / ko / vi translations for `anne_server_redirect`, matching the six-language coverage of the other Anne plugins.
- Documentation corrections: the two dispersion bullets in `README_SPAWN_ARCHITECTURE.md`; the reaction-time row, Tank row and the two new bhop-cap cvars in `annehappy_dynamic_ai_difficulty.md`; and the four places in `ai_charger3/readme.md` still describing the probabilistic charge. Also corrected the Charger bhop speeds in the tier table (the doc said 45/60/75/90/150; the config is 40/50/60/70/100).
