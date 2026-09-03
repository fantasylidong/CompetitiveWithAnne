/** Double-include prevention */
#if defined _SI_Target_limit_included_
  #endinput
#endif
#define _SI_Target_limit_included_

// l4d_target_override 只被下面几个可选 stock 使用，且全部用 GetFeatureStatus 守卫。
// 保持调用方的 REQUIRE_PLUGIN 状态，避免传递包含把它变成一条硬依赖。
#if defined REQUIRE_PLUGIN
	#undef REQUIRE_PLUGIN
	#include <l4d_target_override>
	#define REQUIRE_PLUGIN
#else
	#include <l4d_target_override>
#endif

/**
 * Adds two numbers together.
 *
 * @param client    An Player Index.
 * @return        How many enabled (control) SI currently target this player.
 */
native int GetClientTargetNum(int client);

/**
 * Adds two numbers together.
 *
 * @param client    An Player Index.
 * @return        return true the player is already target by limit number, otherwise false.
 */
native int IsClientReachLimit(int client);

/**
 * Current configured SI target capacity for this survivor.
 * @param client    A player index.
 */
native int GetClientTargetLimit(int client);

/**
 * Whether this SI class is constrained by the shared control-SI target limit.
 * @param zombieClass    Zombie class number (1=Smoker ... 6=Charger, 8=Tank).
 * @return               1 when the class takes a slot from the shared pool, 0 otherwise.
 */
native int IsClassTargetLimited(int zombieClass);

/**
 * Helper for AI plugins rewriting targets in L4D2_OnChooseVictim:
 * returns true when the candidate victim must be rejected because the
 * attacker's class is limited and the victim already carries the maximum
 * number of control-SI locks. Falls back to "never block" when either
 * SI_Target_limit or l4d_target_override is unavailable.
 *
 * @param attacker    The AI Special Infected client index (must be in game).
 * @param victim      The candidate Survivor client index.
 */
stock bool SITL_TargetCapBlocks(int attacker, int victim)
{
	if (victim < 1 || victim > MaxClients || !IsClientInGame(victim))
		return false;
	if (GetFeatureStatus(FeatureType_Native, "IsClassTargetLimited") != FeatureStatus_Available
		|| GetFeatureStatus(FeatureType_Native, "IsClientReachLimit") != FeatureStatus_Available)
	{
		return false;
	}
	if (!IsClassTargetLimited(GetEntProp(attacker, Prop_Send, "m_zombieClass")))
		return false;
	// Keeping the ledger's current victim is not a new slot, never block it
	if (GetFeatureStatus(FeatureType_Native, "L4D_TargetOverride_GetValue") == FeatureStatus_Available
		&& L4D_TargetOverride_GetValue(attacker, VALUE_INDEX_VICTIM) == victim)
	{
		return false;
	}
	return IsClientReachLimit(victim) != 0;
}

/**
 * Helper for AI plugins rewriting targets in L4D2_OnChooseVictim:
 * registers the rewritten victim in the l4d_target_override "targeted"
 * ledger so both targeting channels share one consistent count.
 * Silently does nothing when l4d_target_override is unavailable.
 *
 * @param attacker    The AI Special Infected client index.
 * @param victim      The Survivor client index chosen as target (0 = clear).
 */
stock void SITL_CommitVictim(int attacker, int victim)
{
	if (GetFeatureStatus(FeatureType_Native, "L4D_TargetOverride_SetLastVictim") == FeatureStatus_Available)
		L4D_TargetOverride_SetLastVictim(attacker, victim);
}

// name 必须与插件里 RegPluginLibrary("si_target_limit") 完全一致（大小写敏感），
// 否则以硬依赖方式引用时会报 "Could not find required plugin"。
public SharedPlugin __pl_SI_Target_limit =
{
	name = "si_target_limit",
	file = "SI_Target_limit.smx",
#if defined REQUIRE_PLUGIN
	required = 1,
#else
	required = 0,
#endif
};

#if !defined REQUIRE_PLUGIN
public void __pl_SI_Target_limit_SetNTVOptional()
{
	MarkNativeAsOptional("GetClientTargetNum");
	MarkNativeAsOptional("IsClientReachLimit");
	MarkNativeAsOptional("GetClientTargetLimit");
	MarkNativeAsOptional("IsClassTargetLimited");
}
#endif
