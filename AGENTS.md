<INSTRUCTIONS>
Always reply in Chinese.

If a plugin prints messages to the in-game chat area, the player-facing chat output must support multiple languages. Prefer SourceMod translations/phrases or the project's existing localization mechanism instead of hard-coding chat text in plugin source.

When updating `Update_log.md`, also update the localized update logs used by NewAnneWeb: `Update_log.en.md`, `Update_log.ja.md`, and `Update_log.ko.md`.

When syncing upstream changes from `SirPlease/L4D2-Competitive-Rework`, check whether upstream changed `cfg/stripper/zonemod`. If it added or updated Zonemod stripper entries, mirror the applicable additions/updates into the corresponding `cfg/stripper/zonemod_anne` stripper files as well.

Official Valve campaigns (`c1`–`c14`) already have matching anne nav: copy their zonemod geometry `add:` (clips, blockers, ladders, solid props) as usual.

For custom / third-party maps, do not copy `add:` of ladders, solid props, clips that are not player blockers, or nav-blocker entities into `zonemod_anne` unless the matching anne nav (or a `nav_fixes` script that covers that geometry) is updated at the same time. `env_physics_blocker` and `env_player_blocker` may be copied if `BlockType` is set to survivors only (`1`). Still mirror `filter:` / `modify:` and non-geometry `add:` (items, `nav_fixes` logic_auto).

## Infected wave timing semantics

Treat the following as a behavioral contract when changing `infected_control`:

- A wave starts with a kill phase. The kill-phase timeout is difficulty-dependent; Expert defaults to 8 seconds.
- If survivors reduce the active special infected to the configured low-pressure threshold before the kill-phase timeout, and all normal/asynchronous spawn queues for that wave are empty, start the base respawn countdown early.
- The early start additionally requires the survivor team to be broadly healthy (at least half of the living survivors are not incapacitated, not black-and-white, have 30+ health, and are not pinned) and no active Tank / less than half the team down. These mercy gates are intentional design, not a bug; when they fail, the wave simply waits out the kill-phase timeout.
- The base respawn countdown is a complete independent countdown (`versus_special_respawn_interval`, normally 16 seconds) starting when the kill phase ends. It must not be shortened.
- The 16-second value is not the time from the previous wave's last successful spawn to the next wave's first successful spawn. Do not add or restore a last-spawn-time gap gate.
- Anti-Bait observes progress and formation throughout the wave but may arm only near the base countdown deadline (default: the final 4 seconds).
- At the base countdown deadline, a healthy, stalled, tightly grouped formation that has remained stable for the configured confirmation time (default: 2 seconds) enters the Anti-Bait intensive hold.
- The Anti-Bait intensive hold has no maximum duration. As long as the advantageous grouped/stalled condition remains true, the next wave remains delayed indefinitely.
- Progress, formation breakup, isolation, excessive team spread, Tank pressure, or a survivor becoming dead, incapacitated, ledged, pinned, or otherwise vulnerable clears the hold candidate. Release the next wave only after the clear condition remains stable for the configured release confirmation (default: 2 seconds).
- In addition to the existing pause reasons (Tank pressure, half the team down/dead, everyone pinned), Anti-Bait also pauses when every standing survivor has permanent health below `inf_antibait_lowhp` (default 40) and no living survivor is carrying a first-aid kit, defibrillator, pain pills, or adrenaline. This extra gate does not replace the other pause or hold-clear conditions.
- Formation breakup/spread/isolation must additionally persist for the spread confirmation (`inf_antibait_spread_confirm`, default 3 seconds) before the pressure state demotes. A survivor briefly stepping away and immediately regrouping must not clear the hold, and spreading is not progress (it must not reset the stall clock). A survivor flow-read failure (elevator, bad Nav) is not vulnerability; such members still count for formation, only their flow is excluded.
- Traitor (player-controlled SI) materialization is exempt from the live totalSI cap: a traitor in the SpawnAllowed state whose release wave has arrived may materialize even if leftover AI temporarily fills `l4d_infected_limit`, because the slot was already deducted from that wave's AI budget. AI-side spawning pauses on its own while the field is over cap.
- Once an Anti-Bait hold is cleared, start the next wave immediately. Do not append another base respawn countdown or compensate for time since the previous spawn.
- Preserve timing logs for countdown start, hold start, hold-clear candidate, hold release, kill-phase duration, base-countdown duration, and Anti-Bait extension duration whenever this state machine changes.

## Infected control version rollover

The active `infected_control.smx` release is 2026-08. The rollback release
`infected_control26-07.smx` preserves the 2026-07 spawning behavior. Its
database quota integration may use the current optional `anne_traitor_quota`
provider as long as the archived spawning modules remain unchanged.

When rolling the active infected-control version forward:

- Update the active plugin `myinfo.version` and `BUCKET_CACHE_VER` together.
- Update `AnnePluginVersion` in every Anne mode `confogl_plugins.cfg` and update
  the latest-version labels in `addons/sourcemod/configs/annehappy*.txt` and
  `multiplayermode.txt`.
- Preserve the previous source as an isolated `infected_controlYY-MM.sp` plus
  a matching `infected_controlYY-MM/` include directory. Do not compile an old
  entry point against the active `infected_control/` includes.
- Compile the archived source to
  `addons/sourcemod/plugins/optional/AnneHappy/infected_controlYY-MM.smx`.
- Add its `cfg/vote/Anne/AnneYY-MM.cfg` version-switch configuration, expose it
  in every Anne version-vote menu, and add the SMX to
  `cfg/vote/Anne/unloadall.cfg`.
- Gate version-specific UI and votes by `AnnePluginVersion`, not by lingering
  ConVars. Traitor-mode voting and status are available only for 2026-07 and
  newer releases.
- Recompile the active `infected_control.smx`, the archived rollback SMX, and
  any changed extension before publishing.

## MySQL / database plugins

Every MySQL connection costs a server-side thread, and every game server runs
many database plugins. All MySQL access goes through the `anne_db` connection
hub (`extend/anne_db.sp`, `include/anne_db.inc`), which keeps one shared
connection per physical database and hands out `CloneHandle` copies.
SourceMod runs all threaded queries on a single worker thread, so sharing a
connection costs no throughput.

- Connect with `AnneDB_ConnectCompat` / `AnneDB_TConnectCompat` /
  `AnneDB_ConnectSyncCompat` instead of `Database.Connect` / `SQL_TConnect` /
  `SQL_Connect`. They fall back to the native call when `anne_db` is not loaded
  or the config is not MySQL, so plugins keep working without the hub. Do not
  open a second connection to a database a plugin is already connected to.
- If a plugin calls an `AnneDB_*` native directly instead of through a stock,
  guard that call with `AnneDB_NativeReady("<that native>")`.
  `GetFeatureStatus` only reports natives the calling plugin itself references,
  so testing a different native always says "unavailable" and silently falls
  back to a private connection.
- Request the first connection in `OnAllPluginsLoaded`, `OnConfigsExecuted`,
  or later, never in `OnPluginStart`: `extend/` autoloads at boot in arbitrary
  order. `extend/anne_db.smx` is the first line of `cfg/generalfixes.cfg`;
  keep it there.
- Prefer threaded queries. Every synchronous query (`SQL_Query`,
  `SQL_FastQuery`) must go through `AnneDB_LockedQuery` /
  `AnneDB_LockedFastQuery`, which hold `SQL_LockDatabase` and capture the
  error, affected rows, and insert id inside the lock. Never read
  `SQL_GetAffectedRows` / `SQL_GetInsertId` / `SQL_GetError` from a database
  handle outside the lock; use the query or result handle instead.
- Code on a gameplay path that must query synchronously uses
  `AnneDBLane_Sync` and `allowBlock=false`. Block on a connect only at load
  time. Never retry a synchronous connect on a timer.
- Never change session state on a shared connection. That means no
  `SetCharset`, `SET NAMES`, `SET @var`, `SET time_zone`, temporary tables, or
  `START TRANSACTION`/`COMMIT` through `SQL_FastQuery`. Use
  `AnneDB_SetCharsetIfOwned`. For atomic multi-statement writes use a
  SourceMod `Transaction` with `SQL_ExecuteTransaction`. The hub sets the
  charset (`anne_db_charset`, default `utf8mb4`).
- Do not add private `SELECT 1` keepalive timers, and do not close and reopen
  a connection on every map. The hub pings every `anne_db_keepalive` seconds
  (keep this below MySQL `wait_timeout`, currently 600), and the MySQL driver
  reconnects automatically. After a lost-connection error it is fine to
  `delete` the handle and request it again, because that returns a cheap
  clone.
- Guard reconnect callbacks with a generation counter and `delete` the old
  handle. A plugin must never have more than one connect in flight for the
  same config.
- Reuse the existing `databases.cfg` sections: `l4dstats`/`rpg` for
  `l4d2stats`, `chatlog`/`globalchat` for `chat`, and `sourcebans`. A new MySQL
  section must use the same host/user/pass so it shares the connection, and
  must set `"timeout" "15"`. Keep the `home.trygek.com`, `12345`, `morzlee`,
  and `anne123` placeholders; l4d2-docker substitutes them at deploy time.
- One-shot checks (for example a license check at plugin start) may connect
  directly but must `delete` the handle right after use. Local SQLite
  (`storage-local`, clientprefs) is not managed and may be used directly.
- Verify with `sm_annedb_status` (console only) and by counting connections
  per game-server IP in `information_schema.PROCESSLIST`. The target is 3
  connections per server, or 5 in Anne modes (the extra `Sync` lanes).
</INSTRUCTIONS>
