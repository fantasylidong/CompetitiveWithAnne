# SendTable extension (`sendtable.ext`)

## Upstream & Source Locations

- **Extension upstream repository**: [`Crimson-DawnLight/L4D2MutiMod` (`extensions/sendtable`, v1.0.0, commit `06568bf`)](https://github.com/Crimson-DawnLight/L4D2MutiMod/tree/main/extensions/sendtable)
- **Plugin & packaged distribution upstream**: [`ExpCharacter/oh-my-l4d2-plugins` (`l4d2_ammo_bit_widener_ext`, commit `a4238cd`)](https://github.com/ExpCharacter/oh-my-l4d2-plugins/tree/main/l4d2_ammo_bit_widener_ext)

## Repository File Mapping

| Component | Path in Repository |
|---|---|
| Linux extension binary | `addons/sourcemod/extensions/sendtable.ext.so` |
| Windows extension binary | `addons/sourcemod/extensions/sendtable.ext.dll` |
| SourcePawn include | `addons/sourcemod/scripting/include/sendtable.inc` |
| Plugin source (`.sp`) | `addons/sourcemod/scripting/l4d2_ammo_bit_widener_ext.sp` |
| Compiled plugin (`.smx`) | `addons/sourcemod/plugins/l4d2_ammo_bit_widener_ext.smx` |
| Mode load config | `cfg/sharedplugins.cfg` (`sm plugins load l4d2_ammo_bit_widener_ext.smx`) |

## Notes

- Supports SourceMod **1.12** (`IPlayerManager` check rejects 1.11; 1.13+ is not supported).
- Requires no gamedata files under `addons/sourcemod/gamedata/`.
- `SendTable.SetBits` and `SendTable.SetElementBits` must be applied during startup `OnPluginStart` before `LevelInit` completes.
