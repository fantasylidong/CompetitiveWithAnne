# Anne NextBot extension

This SourceMod extension keeps the hot `NextBotManager::ShouldUpdate` scheduler and the shared
`PathFollower::Update` router in native code. SourcePawn remains responsible for configuration and
Tank/Charger behavior.

The extension is intentionally loaded only at server startup. Install the platform binary together
with `anne_nextbot.autoload`, `anne_nextbot.games.txt`, and `anne_nextbot.inc`, then restart the server.
It creates Detour handles during startup but leaves every Detour disabled until an Anne plugin requests
the scheduler or PathFollower broker. When the last consumer unloads, the corresponding Detours are
disabled again, so non-Anne modes do not pass through extension callbacks.

GitHub Actions builds optimized x86 Linux and Windows artifacts. The Linux artifact is the normal
Left 4 Dead 2 dedicated-server target.

Run `sm_anne_nextbot_status` in the server console to inspect scheduler activity and PathFollower
routing. Tank and Charger are reported separately with their consumer request, SourcePawn listener
count, matched/forwarded/error counters, and the last forwarded client and age. `waiting` means no
matching PathFollower update has occurred since the extension loaded; `idle` means forwarding worked
previously but no matching update occurred during the last 10 seconds.
