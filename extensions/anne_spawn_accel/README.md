# Anne Spawn Accel extension

This SourceMod extension accelerates the expensive, stable primitives used by `infected_control`:

- spawn hull and survivor-visibility traces with native trace filters;
- candidate geometry batches and stable top-k selection;
- two-dimensional NavArea nearest-neighbor mapping during bucket construction;
- a bounded two-thread work queue for graph I/O, graph assembly, and distance fields;
- a versioned, checksummed binary Nav graph cache in `data/anne_spawn_accel/navgraph`;
- asynchronous reachable-range candidate queries and integer-keyed path fallback caching.

The main thread only snapshots engine-owned Nav pointers in bounded batches. Workers never dereference
engine objects: they consume copied IDs, centers, edges, and blocker bytes. Ordinary floor paths use a
reverse distance field shared by every candidate for the same survivor NavArea. `NavAreaBuildPath`
remains the conservative fallback while the cache is unavailable and for ladder/elevator paths or
queries close to the maximum-distance boundary.

The binary payload stores one ID per area plus forward CSR offsets and packed edges. A synthetic graph
with 10,000 areas and 60,000 directed edges occupies 320,060 bytes (about 312.6 KiB). The standalone
round-trip test is `tests/nav_graph_test.cpp`.

Spawn rules, wave decisions, class selection, cooldowns, and score tuning remain in SourcePawn. The
plugin automatically falls back to its existing SourcePawn implementation when this extension is not
available.

Install the platform binary with `anne_spawn_accel.autoload`, `anne_spawn_accel.games.txt`, and
`anne_spawn_accel.inc`. Autoloading at server startup is recommended, but late loading is supported;
`infected_control` detects the library dynamically and switches back to SourcePawn when it unloads.
The worker pool is created lazily by `AnneSpawn_NavGraphStart` and destroyed by
`AnneSpawn_NavGraphStop`, so merely autoloading the extension does not create background threads.
