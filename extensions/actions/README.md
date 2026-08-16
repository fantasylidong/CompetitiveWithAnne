# Actions extension Anne patch

The deployed Linux binary is based on
[`Vinillia/actions.ext@ab6f84b`](https://github.com/Vinillia/actions.ext/commit/ab6f84b95b440c4b93e82e94779c438143736f02)
(Actions 3.7.6) plus `actions-3.7.6-anne.2.patch`.

The patch fixes action-destruction cleanup in `ActionsManager::ClearUserData`.
Upstream used `m_actionsUserData[action].clear()`, which inserts an empty outer-map
entry when the action has no user data and never removes entries from the user-data,
identity-data, or actor caches. Anne's build erases the destroyed action from all
three caches.

The patch also fixes Action listener-map growth. Upstream used `operator[]` for
listener lookups, so every intercepted method created empty pre/post entries even
when no plugin listened to it. Action destruction then cleared only the inner map
and retained the outer Action-pointer key. Anne uses non-inserting lookups, erases
the complete listener entry on destruction, defers cleanup safely across nested
callbacks, prunes empty listener maps, and removes pending markers before directly
deleting candidate Actions. The extension identifies itself as `3.7.6-anne.2`.

The Linux artifact is built as optimized i386 on Ubuntu 18.04 with Clang 6 and
static libstdc++. It has a SHA-1 Build-ID and requires at most `GLIBC_2.27`.
The SourceMod, Metamod:Source, and HL2SDK inputs used for the current artifact are:

- SourceMod `f53cb134ef83b580c83e1f4bf35f60d11c4571dd`
- Metamod:Source `7ff2d97bdad1493b809c5ec91bbfc7abc6ae5445`
- HL2SDK L4D2 `2a31cd007b2d7d2f964dc093eedcf7a812cf9dd6`

Actions does not support late loading. Replace the binary while the server is
stopped and restart SRCDS. The Windows DLL remains the upstream 3.7.6 build and
does not contain this Linux crash fix.
