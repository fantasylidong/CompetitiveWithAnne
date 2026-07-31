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
