<INSTRUCTIONS>
Always reply in Chinese.

If a plugin prints messages to the in-game chat area, the player-facing chat output must support multiple languages. Prefer SourceMod translations/phrases or the project's existing localization mechanism instead of hard-coding chat text in plugin source.

When updating `Update_log.md`, also update the localized update logs used by NewAnneWeb: `Update_log.en.md`, `Update_log.ja.md`, and `Update_log.ko.md`.

When syncing upstream changes from `SirPlease/L4D2-Competitive-Rework`, check whether upstream changed `cfg/stripper/zonemod`. If it added or updated Zonemod stripper entries, mirror the applicable additions/updates into the corresponding `cfg/stripper/zonemod_anne` stripper files as well.

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
- Formation breakup/spread/isolation must additionally persist for the spread confirmation (`inf_antibait_spread_confirm`, default 3 seconds) before the pressure state demotes. A survivor briefly stepping away and immediately regrouping must not clear the hold, and spreading is not progress (it must not reset the stall clock). A survivor flow-read failure (elevator, bad Nav) is not vulnerability; such members still count for formation, only their flow is excluded.
- Traitor (player-controlled SI) materialization is exempt from the live totalSI cap: a traitor in the SpawnAllowed state whose release wave has arrived may materialize even if leftover AI temporarily fills `l4d_infected_limit`, because the slot was already deducted from that wave's AI budget. AI-side spawning pauses on its own while the field is over cap.
- Once an Anti-Bait hold is cleared, start the next wave immediately. Do not append another base respawn countdown or compensate for time since the previous spawn.
- Preserve timing logs for countdown start, hold start, hold-clear candidate, hold release, kill-phase duration, base-countdown duration, and Anti-Bait extension duration whenever this state machine changes.

## Infected control version rollover

The active `infected_control.smx` release is 2026-08. The rollback release
`infected_control26-07.smx` must stay reproducible from commit
`82fb40a42a472debb220070956bc75ff5738e05e`.

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
</INSTRUCTIONS>
