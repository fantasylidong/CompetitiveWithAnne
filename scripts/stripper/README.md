# Per-map global Stripper filters

AnneHappy uses `cfg/stripper/zonemod_anne`. Its runtime `global_filters.cfg`
file is intentionally empty. The source content lives at
`scripts/stripper/global_filters/zonemod_anne.cfg` and is prepended to every
root Anne map config by `expand_global_filters.py`. Other Stripper modes keep
their original global and map configs unchanged.

Stripper loads map configs at every underscore-delimited prefix. A map config
that already inherits from a shorter existing config must not contain another
generated global block. The generator detects that relationship automatically.

Regenerate and verify from the repository root:

```sh
python3 scripts/stripper/expand_global_filters.py
python3 scripts/stripper/expand_global_filters.py --check
```

`test_expanded_filters.cpp` is a Linux binary-level smoke test. It loads the
shipped official core and verifies both the shared and map-specific sections of
the generated `c2m1_highway.cfg`.

When changing a shared filter, edit its file under
`scripts/stripper/global_filters/`, regenerate, and commit both the source and
expanded map configs.
