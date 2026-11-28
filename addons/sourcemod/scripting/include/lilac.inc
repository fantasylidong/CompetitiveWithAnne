#if defined _lilac_included_
	#endinput
#endif
#define _lilac_included_

/**
 * Little Anti-Cheat（extend/lilac.smx）对外接口。
 * 与插件内部 lilac_globals.sp 的 CHEAT_* 编号一致，修改时两边同步。
 * 插件内部已用 #define 定义同名常量，所以这里只在外部插件中定义。
 */
#if !defined CHEAT_MAX
enum
{
	CHEAT_ANGLES          = 0,
	CHEAT_CHATCLEAR       = 1,
	CHEAT_CONVAR          = 2,
	CHEAT_NOLERP          = 3,
	CHEAT_BHOP            = 4,
	CHEAT_AIMBOT          = 5,
	CHEAT_AIMLOCK         = 6,
	CHEAT_ANTI_DUCK_DELAY = 7,
	CHEAT_NOISEMAKER_SPAM = 8,
	CHEAT_MACRO           = 9, // 宏不算作弊，但同样通过这些 forward 通知
	CHEAT_NEWLINE_NAME    = 10,
	CHEAT_MAX             = 11
};
#endif

/**
 * 即将记录一次检测前调用。返回 Plugin_Continue 以外的值可阻止这次检测
 * （例如某些模式自带的机制会被误判时）。
 *
 * @param client    被检测的玩家
 * @param cheat     CHEAT_* 编号
 */
forward Action lilac_allow_cheat_detection(int client, int cheat);

/**
 * 每次检测到（包括还没到记录 / 封禁次数的检测）都会调用。
 *
 * @param client    被检测的玩家
 * @param cheat     CHEAT_* 编号
 */
forward void lilac_cheater_detected(int client, int cheat);

/**
 * 决定封禁该玩家时调用（随后才真正执行封禁）。
 *
 * @param client    被封禁的玩家
 * @param cheat     CHEAT_* 编号
 */
forward void lilac_cheater_banned(int client, int cheat);
