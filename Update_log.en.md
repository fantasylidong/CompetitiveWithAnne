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
