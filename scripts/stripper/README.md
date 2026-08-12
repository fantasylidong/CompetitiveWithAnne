# Per-map global Stripper filters

AnneHappy uses `cfg/stripper/zonemod_anne`. The complete source content lives at
`scripts/stripper/global_filters/zonemod_anne.cfg`. The generator keeps global
weapon, medicine, throwable, pickup, and competitive item policy in the runtime
`global_filters.cfg`; model, collision, environment, and map-entity sections are
prepended only to existing root Anne map configs. Other Stripper modes keep
their original global and map configs unchanged.

Stripper loads map configs at every underscore-delimited prefix. A map config
that already inherits from a shorter existing config must not contain another
generated global block. The generator detects that relationship automatically.

Regenerate and verify from the repository root:

```sh
python3 scripts/stripper/expand_global_filters.py
python3 scripts/stripper/expand_global_filters.py --check
```

When changing a shared filter, edit its file under
`scripts/stripper/global_filters/`, regenerate, and commit both the source and
expanded map configs.
