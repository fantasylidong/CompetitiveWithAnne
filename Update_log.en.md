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
