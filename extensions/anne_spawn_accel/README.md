# Anne Spawn Accel extension

This SourceMod extension accelerates the expensive, stable primitives used by `infected_control`:

- spawn hull and survivor-visibility traces with native trace filters;
- candidate geometry batches and stable top-k selection;
- two-dimensional NavArea nearest-neighbor mapping during bucket construction;
- a bounded two-thread work queue for graph I/O, graph assembly, and distance fields;
- a versioned, checksummed binary Nav graph cache in `data/anne_spawn_accel/navgraph`;
- asynchronous, target-specific directed candidate snapshots and integer-keyed path fallback caching.

On every graph start, the main thread snapshots engine-owned Nav pointers and every live directed
floor/ladder edge in bounded batches. Canonically sorted live edges, topology issue bits, and the stable dynamic
state are part of the v7 cache fingerprint, so a stale cache cannot survive a Nav Variant or Stripper
topology change merely because area IDs and centers stayed the same. Each state is stored as a separate
`<map>.<fingerprint>.anvg` file; returning to an already observed mechanism state loads that variant instead
of overwriting or rebuilding it. Workers never dereference engine objects: they consume
copied IDs, centers, flow distances, edges, and packed blocker bits. The live blocker snapshot is
validated before it reaches a worker; an implausible all-blocked map disables the directed snapshot
for that query and leaves the Director API fallback available; SourcePawn does not scan all NavAreas. Invalid
flow values inherit the nearest valid progress over the Nav graph on a worker. Ordinary floor paths use a
reverse distance field shared by every candidate for the same survivor NavArea. Candidate snapshots
exclude Nav centers within 250 world units (3D straight-line distance) of any live survivor. The default
snapshot sorts by raw directed `candidate -> target` path distance. Ranked snapshots retain that raw
distance but assign Nav centers at least 64 units above the target eye a configurable rank multiplier;
Smoker and Hunter default to `0.50`, so high ground is visited earlier without falsifying the path range.
Ties use raw path distance and then area index. The plugin refreshes snapshots every 1.0 second while
idle and every 0.1 second during the final second before a wave or while spawn work is pending; consumers
accept results for at most 0.2 seconds. `NavAreaBuildPath` remains a final precision check for directed
candidates. An unavailable or incomplete graph goes to the Director API rather than an unordered all-Nav scan. The main
thread monitors the `TheNavAreas` identity and all live floor connections and ladder endpoints; resolved
`func_elevator` origin, velocity, and toggle state additionally prevent capture and live-edge traversal
while a lift is moving. Edge polling resumes after the mechanism stops.
This result-based topology watch also covers ferries, platforms, scripted relays, custom-map mechanisms,
or any other entity that actually rewires `CNavArea`, without maintaining a fragile classname list.
Polling is throttled to 1.0 second while idle and 0.1 second near spawn work. Each poll checks at most
1,024 areas and advances a persistent cursor, so successive polls cover the whole map without putting a
full-map topology scan into one frame. Elevator entities that can be resolved are checked on every poll. A directed-edge change immediately increments
the graph generation, discards pending graph/candidate/path results, and waits for 0.2 seconds of stable,
non-moving state before a bounded recapture. The capture hashes the complete topology both before and after
the bounded copy, so a mechanism that changes mid-capture cannot publish a mixed graph. Spawn searches stay pending during recapture instead
of switching to an all-Nav scan. Graph generation invalidation clears all distance fields and path results
before another state can publish; returning to any known topology loads its matching variant. A stable
state remains usable when an optional elevator entity cannot be resolved, provided the live directed
connections are readable and no unknown/invalid Nav storage is found. Ordinary Nav
blockers use the existing packed blocker snapshot/epoch and do not force a topology rebuild.
Mapped bad-flow areas remain recallable, but the mapping is only progress metadata: the current tick still
checks directed `candidate -> target` reachability against the profession's maximum and, when direct
distance cannot prove the minimum, its minimum too. Complete static and stable dynamic maps use the
directed graph; engine `BuildPath` only validates candidates returned by that graph. Flow buckets are not
used as a candidate source or as proof of path connectivity.

Team snapshots (`AnneSpawn_NavCandidatesPrepareTeam`) are built for the whole eligible survivor set as one
reverse multi-source field (distance = shortest directed path to any survivor, owner = the survivor realizing it)
and, since 1.5.0, also keep one bounded single-source distance layer per survivor. `AnneSpawn_NavCandidatesCollectTeamEx`
takes an exclusion list (survivors that already carry their maximum number of Special Infected) and re-resolves every
row against the remaining survivors from those layers at collect time, so "skip the full survivor and measure from
the next nearest one" costs a page read instead of a snapshot rebuild; the cached snapshot key does not include the
exclusion set. Excluding every survivor degenerates to no exclusion so the caller still receives candidates.

The binary payload stores one ID per area plus forward CSR offsets and packed edges. Flow is read fresh
from the engine on each graph capture, so it does not enlarge or invalidate the topology cache. A synthetic graph
with 10,000 areas and 60,000 directed edges occupies 320,060 bytes (about 312.6 KiB). The standalone
round-trip test is `tests/nav_graph_test.cpp`.

Only copied graph, blocker, and survivor-eye data is processed on workers. Spawn rules, random Nav points,
flags, cooldowns, stuck/visibility traces, final path validation, and score tuning remain in SourcePawn on
the game thread. A candidate snapshot is therefore an ordered coarse filter, never permission to spawn.
When this extension is unavailable, the plugin retains SourcePawn safety and scoring code but skips the
unordered all-Nav candidate source and uses the Director API fallback for position selection.

Install the platform binary with `anne_spawn_accel.autoload`, `anne_spawn_accel.games.txt`, and
`anne_spawn_accel.inc`. Autoloading at server startup is recommended, but late loading is supported;
`infected_control` detects the library dynamically and switches directed Nav selection off when it unloads.
The worker pool is created lazily by `AnneSpawn_NavGraphStart` and destroyed by
`AnneSpawn_NavGraphStop`, so merely autoloading the extension does not create background threads.
