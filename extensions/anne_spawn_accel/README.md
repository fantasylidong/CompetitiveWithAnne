# Anne Spawn Accel extension

This SourceMod extension accelerates the expensive, stable primitives used by `infected_control`:

- spawn hull and survivor-visibility traces with native trace filters;
- candidate geometry batches and stable top-k selection;
- two-dimensional NavArea nearest-neighbor mapping during bucket construction;
- a bounded two-thread work queue for graph I/O, graph assembly, and distance fields;
- a versioned, checksummed binary Nav graph cache in `data/anne_spawn_accel/navgraph`;
- asynchronous, target-specific directed candidate snapshots and integer-keyed path fallback caching.

The main thread only snapshots engine-owned Nav pointers in bounded batches. Workers never dereference
engine objects: they consume copied IDs, centers, flow distances, edges, and blocker bytes. Invalid
flow values inherit the nearest valid progress over the Nav graph on a worker. Ordinary floor paths use a
reverse distance field shared by every candidate for the same survivor NavArea. Candidate snapshots
exclude Nav centers within 250 world units (3D straight-line distance) of any live survivor, then sort the
remaining reachable areas by directed `candidate -> target` Nav path distance, using the area index only
as a deterministic tie-break. The plugin refreshes these snapshots every 1.0 second while
idle and every 0.1 second during the final second before a wave or while spawn work is pending; consumers
accept results for at most 0.2 seconds. `NavAreaBuildPath`
remains the conservative fallback while the cache is unavailable and for ladder/elevator paths or
queries close to the maximum-distance boundary. Dynamic elevator membership marks the captured graph
incomplete: target-specific graph candidate snapshots are then disabled and SourcePawn scans all NavAreas
before applying the current-tick path check. This deliberately favors completeness over a false graph
negative; Flow buckets are not used as a candidate source.

The binary payload stores one ID per area plus forward CSR offsets and packed edges. Flow is read fresh
from the engine on each graph start, so it does not enlarge or invalidate the topology cache. A synthetic graph
with 10,000 areas and 60,000 directed edges occupies 320,060 bytes (about 312.6 KiB). The standalone
round-trip test is `tests/nav_graph_test.cpp`.

Only copied graph, blocker, and survivor-eye data is processed on workers. Spawn rules, random Nav points,
flags, cooldowns, stuck/visibility traces, final path validation, and score tuning remain in SourcePawn on
the game thread. A candidate snapshot is therefore an ordered coarse filter, never permission to spawn.
The plugin automatically falls back to its existing SourcePawn implementation when this extension is not
available.

Install the platform binary with `anne_spawn_accel.autoload`, `anne_spawn_accel.games.txt`, and
`anne_spawn_accel.inc`. Autoloading at server startup is recommended, but late loading is supported;
`infected_control` detects the library dynamically and switches back to SourcePawn when it unloads.
The worker pool is created lazily by `AnneSpawn_NavGraphStart` and destroyed by
`AnneSpawn_NavGraphStop`, so merely autoloading the extension does not create background threads.
