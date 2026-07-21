# L4D2 个人近战属性使用指南

个人近战属性由 `l4d2_pma_native_attrs.smx` 提供，数据库协调器 `l4d2_player_attr_db.smx` 负责读取网页后台保存的规则并下发。

## 支持属性

当前只保留四项由服务器权威处理、适合按玩家设置的属性：

- `damage`：近战伤害，范围 `0-10000`。
- `damageflags`：伤害类型位标志，必须是不小于 `0` 的整数。
- `rumbleeffect`：手柄震动效果编号，范围 `0-255`。
- `decapitates`：是否使用斩首行为，接受 `1/0`、`true/false`、`yes/no`、`on/off`。

挥砍间隔、待机时间、轨迹范围、挥砍方向、命中时间窗和攻击段持续时间均已移除。这些值参与客户端预测，服务器单独给不同玩家修改会造成动画、声音或命中判定不同步。

## 管理员命令

```text
sm_pma_set <target> <melee|@active> <attr> <value> [attr value]...
sm_pma_clear <target>
sm_pma_list
sm_pma_dump [melee|@active]
```

示例：

```text
sm_pma_set @me @active damage 100 damageflags 4 decapitates 1
sm_pma_list
sm_pma_clear @me
```

## 数据库规则

网页后台只允许 `target_type=pma` 的上述四项属性。旧数据库中的 `trace`、`attackseg`、`refiredelay` 和 `weaponidletime` 行不会被读取，不需要手动删库。

插件启动后读取一次数据库规则并保存在内存。网页保存规则时会通知服务器执行 reload；玩家进服、切换武器或管理员手动执行 `sm_pattrdb_apply <target>` 时从内存缓存下发，不进行周期数据库轮询。

## 排查

```text
sm plugins list
sm_private_license_status
sm_pattrdb_status
sm_pma_list
```

需要详细日志时临时执行：

```text
sm_cvar l4d2_pma_log 1
sm_cvar l4d2_player_attr_db_log 1
```

测试完成后恢复为 `0`。
