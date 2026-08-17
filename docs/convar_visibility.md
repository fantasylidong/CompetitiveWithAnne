# ConVar visibility policy

Anne plugins use a private-by-default ConVar policy.

## Flag rules

- `FCVAR_NOTIFY` is reserved for values that are intentionally published to
  players and through `A2S_RULES`.
- Cross-plugin access through `FindConVar`, change hooks, or shared handles does
  not require `FCVAR_NOTIFY`.
- Configuration ConVars should use `FCVAR_NONE` unless another engine flag has
  a documented purpose.
- Existing `FCVAR_DONTRECORD`, `FCVAR_SPONLY`, `FCVAR_PRINTABLEONLY`,
  `FCVAR_PROTECTED`, `FCVAR_CHEAT`, and `FCVAR_REPLICATED` semantics must be
  preserved when removing `FCVAR_NOTIFY`.
- Secrets should not be stored in ConVars. `FCVAR_PROTECTED` is retained for
  existing security-sensitive vendor settings, but it is not a substitute for
  secret storage.
- Engine-owned ConVars are not assigned new flags by project plugins unless a
  specific compatibility fix documents the reason.

## Public allowlist

Only the following project ConVar may use `FCVAR_NOTIFY`:

- `anne_round_wipe_count`: publishes the current map wipe count for external
  server status consumers.

Adding another entry requires documenting its player-facing or external query
consumer in this file and updating the automated visibility check.

## Source boundaries

The policy applies to active, source-backed plugins shipped by this repository.
The following historical or upstream inputs are not rewritten as part of the
active migration:

- `addons/sourcemod/scripting/archive/`
- `addons/sourcemod/scripting/disabled/`
- `addons/sourcemod/scripting/dev_plugins/`
- `addons/sourcemod/scripting/sourcemod/`
- `infected_control26-07.sp` and `infected_control26-07/`
- binary-only plugins

Active vendor plugins may carry a local flags-only patch. Such patches must be
kept when syncing upstream.

## Deployment

SourceMod ConVars can survive a plugin reload. Visibility changes must be
verified after a clean SRCDS restart, using an external `A2S_RULES` query.

Use the repository query tool from a host outside the game server network:

```sh
python3 scripts/query_a2s_rules.py SERVER_ADDRESS --port 27015
python3 scripts/query_a2s_rules.py SERVER_ADDRESS --port 27015 --json > rules.json
```
