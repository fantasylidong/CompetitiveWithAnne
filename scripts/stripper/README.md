# Conditional Stripper filters

This project patches Stripper:Source so a config path is active only when its
`maps/` directory contains a filter matching the current map. The original map
prefix matching behavior is preserved. When no map filter matches, neither
`global_filters.cfg` nor a map filter is applied.

The build uses Stripper:Source git141 at commit
`2a08843241f1858d0727a91fa9dcb2382526f8cb` and produces the 32-bit Linux and
Windows L4D2 binaries shipped in `addons/stripper/bin`.

Run from the repository root:

```sh
scripts/stripper/build.sh
```

Docker is required. The script builds and tests both custom core libraries,
verifies that every active filter path covers all 57 official maps, then installs
official git141 L4D2 shims/loaders and the patched cores.
