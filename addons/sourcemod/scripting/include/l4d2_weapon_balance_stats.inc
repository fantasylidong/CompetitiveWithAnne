#if defined _l4d2_weapon_balance_stats_included
	#endinput
#endif
#define _l4d2_weapon_balance_stats_included

/**
 * 取得当前回合编号，与 player_combat_rounds.round_uid 相同。
 * 回合从生还者离开安全区（统计开始）时生成，回合结束后清空。
 *
 * @param buffer    输出缓冲区（建议 40 字节）
 * @param maxlen    缓冲区大小
 * @return          当前有进行中的回合返回 true，否则 false 且 buffer 为空串
 */
native bool L4D2WBS_GetRoundUid(char[] buffer, int maxlen);

public SharedPlugin __pl_l4d2_weapon_balance_stats =
{
	name = "l4d2_weapon_balance_stats",
	file = "extend/l4d2_weapon_balance_stats.smx",
#if defined REQUIRE_PLUGIN
	required = 1,
#else
	required = 0,
#endif
};

#if !defined REQUIRE_PLUGIN
public void __pl_l4d2_weapon_balance_stats_SetNTVOptional()
{
	MarkNativeAsOptional("L4D2WBS_GetRoundUid");
}
#endif
