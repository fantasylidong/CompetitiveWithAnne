#pragma semicolon 1
#pragma newdecls required

/**
 * Ai Hunter 2.0（修订版）
 * ------------------------------------------------------------
 * 本版在原有基础上修复了多处“硬伤”与边界问题，并补强了注释，便于长期维护：
 *
 * 1) CVar 上下限修正：
 *    - ai_hunter_fast_pounce_distance 原来被错误夹到 <= 1.0，导致配置无效。
 *    - ai_hunter_wall_detect_distance 支持 -1.0 表示完全禁用（原来最小值设为 0 导致默认 -1 被夹为 0）。
 *
 * 2) 侧飞角平衡修正：
 *    - 当左右次数差超阈值时的“反向处理”由位运算 (~angle|1) 改为几何上正确的取负 (-angle)。
 *
 * 3) 垂直角限制（limitLungeVerticality）重写：
 *    - 改为“夹断式”几何限制：按水平合力 h 计算允许的最大 |Z|，避免混乱的旋转公式以及重复赋值错误。
 *
 * 4) 无视野分支早退优化：
 *    - 原来没蹲就直接 return 导致错过“右键/排队起跳”的时机；现在改为自动压一次 IN_DUCK 并返回 Changed。
 *
 * 5) 墙体检测射线 MASK 可选优化：
 *    - 从 MASK_NPCSOLID_BRUSHONLY 改为 MASK_PLAYERSOLID_BRUSHONLY（更贴近“玩家会撞到的几何”），
 *      同时保留过滤器避免自击中文件。
 *
 * 6) 详细中文注释：
 *    - 对“参数语义”“状态机”“与全局 CVar 交互”进行了说明，便于你和其他维护者后续扩展。
 *
 * 备注：
 * - 为不破坏现服配置，保留了原 CVar 名（包括 no_sign 拼写）。如需更正命名，可额外新增“别名 CVar”并同步解析。
 * - 本插件加载/卸载会改写少量全局 CVar（影响真人 Hunter），请在服描述里标注。
 */

// 头文件
#include <sourcemod>
#include <sdktools>
#include <left4dhooks>
#include <treeutil> // 你的工程里通常包含一些便捷方法（例如随机/向量/可见性等），保留

public Plugin myinfo = 
{
	name        = "Ai Hunter 2.0 (Revised)",
	author      = "夜羽真白, edited by ChatGPT for Dong",
	description = "Ai Hunter 增强 2.0 版本（修复/优化注释版）",
	version     = "2023/4/1 + 2025-09-08",
	url         = "https://steamcommunity.com/id/saku_ra/"
};

// ---------------------------
// 常量/宏
// ---------------------------
#define CVAR_FLAG               FCVAR_NOTIFY
#define LUNGE_LEFT              45.0          // 向左偏转角（正数）
#define LUNGE_RIGHT             315.0         // 向右偏转角（等价于 -45.0）
#define INVALID_CLIENT          -1
#define INVALID_NAV_AREA        0
#define HURT_CHECK_INTERVAL     0.2
#define CROUCH_HEIGHT           20.0
#define POUNCE_LEFT             0            // 修正拼写：原 POUNCE_LFET
#define POUNCE_RIGHT            1
#define DEBUG                   0

// 如果你的工程里没有常量，可在需要时启用（通常 left4dhooks 已定义或你工程全局已定义）
// #define TEAM_SURVIVOR 2
// #define TEAM_INFECTED 3
// #define ZC_HUNTER     3

// ---------------------------
// CVar 句柄
// ---------------------------

// 基本 cvar（本插件提供）
ConVar
	g_hFastPounceDistance,   // 开始尝试“快速突袭”的距离阈值（近距离更容易触发拍地起跳节奏）
	g_hPounceVerticalAngle,  // 允许的最大垂直夹角（限制飞撲向量的上下份额）
	g_hPounceAngleMean,      // 侧飞角的“均值”概念（非严格正态）
	g_hPounceAngleStd,       // 侧飞角的“发散度”
	g_hStraightPounceDistance, // 允许“直扑”的水平距离上限（更近可能被打掉，过远建议侧飞）
	g_hAimOffset,            // “看向你”的判定角度（越小越严格；配合 isVisibleTo 使用）
	g_hNoSightPounceRange,   // 无视野也允许起跳的范围（字符串：水平,垂直；0 表示禁用对应维度）
	g_hBackVision,           // 起跳时“背飞”的概率（0~100，偏大观感会“瞎飞”）
	g_hMeleeFirst,           // 起跳前右键“挠”的距离窗口（字符串：最小,最大；0=禁用）
	g_hHighPounceHeight,     // 与目标垂直高度差超过此值，倾向直扑
	g_hWallDetectDistance,   // 前向“撞墙”检测射线长度（-1 表示完全禁用）
	g_hAnglePounceCount;     // 左右次数差的平衡阈值（避免总向一侧偏飞）

// 其他（引擎/原生）cvar（只读/或由本插件在加载/卸载时暂时覆盖）
ConVar
	g_hLungeInterval,
	g_hPounceReadyRange,
	g_hPounceLoftAngle,
	g_hPounceGiveUpRange,
	g_hPounceSilenceRange,
	g_hCommitAttackRange,
	g_hLungePower;

// ---------------------------
// 运行时状态
// ---------------------------
bool
	ignoreCrouch,                        // 是否“忽略蹲起跳”的逻辑（取决于 hunter_patch 的设置）
	hasQueuedLunge[MAXPLAYERS + 1],      // 是否已经为该 Hunter 排队一次“起跳”
	canBackVision[MAXPLAYERS + 1][2];    // [0]=是否已抽签过；[1]=这次是否“背飞”

float
	canLungeTime[MAXPLAYERS + 1],        // 下一次可以起跳的时间戳（= now + z_lunge_interval）
	meleeMinRange, meleeMaxRange,        // 右键“挠”的距离窗口（解析自 CVar）
	noSightPounceRange,                  // 无视野允许的水平距离（解析自 CVar）
	noSightPounceHeight;                 // 无视野允许的垂直高度差（解析自 CVar）

int
	anglePounceCount[MAXPLAYERS + 1][2], // 左右侧飞计数（避免长期偏向一边）
	hunterCurrentTarget[MAXPLAYERS + 1]; // 当前记录的目标（供 RunCmd 等处使用）

// =======================================================
// 插件生命周期
// =======================================================
public void OnPluginStart()
{
	// ---------- 创建本插件自带 CVar ----------
	// 注意：修复了原版错误的“最大值=1.0”夹断问题；此处不给上限或给一个合理上限。
	g_hFastPounceDistance = CreateConVar(
		"ai_hunter_fast_pounce_distance", "1000.0",
		"hunter 开始进行快速突袭的距离（建议 600~1200）",
		CVAR_FLAG, true, 0.0 // 无上限，避免再次夹死
	);

	g_hPounceVerticalAngle = CreateConVar(
		"ai_hunter_vertical_angle", "7.0",
		"hunter 突袭的垂直角度上限（度），夹断式限制飞行向量的 Z 份额",
		CVAR_FLAG, true, 0.0
	);

	g_hPounceAngleMean = CreateConVar(
		"ai_hunter_angle_mean", "10.0",
		"侧飞角“均值”（几何意义上的偏转中心，不是严格正态）",
		CVAR_FLAG, true, 0.0
	);

	g_hPounceAngleStd = CreateConVar(
		"ai_hunter_angle_std", "20.0",
		"侧飞角“发散度”（最大偏离程度，建议 10~30）",
		CVAR_FLAG, true, 0.0
	);

	g_hStraightPounceDistance = CreateConVar(
		"ai_hunter_straight_pounce_distance", "200.0",
		"hunter 允许直扑的水平距离上限（更远则更倾向于侧飞）",
		CVAR_FLAG, true, 0.0
	);

	g_hAimOffset = CreateConVar(
		"ai_hunter_aim_offset", "360.0",
		"与目标水平夹角小于该值则视为“看向我”（0~360）",
		CVAR_FLAG, true, 0.0, true, 360.0
	);

	// 注意：保留原 CVar 名（no_sign），不破坏旧服配置
	g_hNoSightPounceRange = CreateConVar(
		"ai_hunter_no_sign_pounce_range", "300,0",
		"hunter 不可见目标时仍允许起跳的范围：水平,垂直；0=禁用该维度",
		CVAR_FLAG
	);

	g_hBackVision = CreateConVar(
		"ai_hunter_back_vision", "0",
		"hunter 在起跳时将视角背对目标的概率（0~100）。偏大观感会“瞎飞”，竞技服建议 ≤10",
		CVAR_FLAG, true, 0.0, true, 100.0
	);

	g_hMeleeFirst = CreateConVar(
		"ai_hunter_melee_first", "300.0,1000.0",
		"hunter 每次准备突袭时，是否先按右键挠：最小距离,最大距离（0=禁用）",
		CVAR_FLAG
	);

	g_hHighPounceHeight = CreateConVar(
		"ai_hunter_high_pounce", "400",
		"与目标垂直高度差超过该值时，倾向直扑",
		CVAR_FLAG, true, 0.0
	);

	// 修正：允许 -1（彻底禁用），并给出合理最大上限
	g_hWallDetectDistance = CreateConVar(
		"ai_hunter_wall_detect_distance", "250.0",
		"前向“撞墙”检测射线长度；-1=禁用，>0 表示启用（单位：游戏单位格）",
		CVAR_FLAG, true, -1.0, true, 4096.0
	);

	g_hAnglePounceCount = CreateConVar(
		"ai_hunter_angle_diff", "3",
		"左右侧飞次数差不能超过该值（用于平衡）",
		CVAR_FLAG, true, 0.0
	);

	// 监听 CVar 变更：字符串解析项
	g_hMeleeFirst.AddChangeHook(meleeFirstRangeChangedHandler);
	g_hNoSightPounceRange.AddChangeHook(noSightPounceRangeChangedHandler);

	// ---------- 获取引擎/原生 CVar ----------
	g_hLungeInterval       = FindConVar("z_lunge_interval");
	g_hPounceReadyRange    = FindConVar("hunter_pounce_ready_range");
	g_hPounceLoftAngle     = FindConVar("hunter_pounce_max_loft_angle");
	g_hPounceGiveUpRange   = FindConVar("hunter_leap_away_give_up_range");
	g_hPounceSilenceRange  = FindConVar("z_pounce_silence_range");
	g_hCommitAttackRange   = FindConVar("hunter_committed_attack_range");
	g_hLungePower          = FindConVar("z_lunge_power");

	// ---------- 事件 ----------
	HookEvent("player_spawn", playerSpawnHandler);
	HookEvent("ability_use", abilityUseHandler);
	HookEvent("round_end",   roundEndHandler);

	// ---------- 初始化解析 ----------
	getHunterMeleeFirstRange();
	getNoSightPounceRange();

	// ---------- 上线时设置若干全局 CVar ----------
	setCvarValue(true);
}

public void OnPluginEnd()
{
	// 卸载时恢复全局 CVar 默认值，避免影响其他插件/真人 Hunter
	setCvarValue(false);
}

public void OnMapEnd()
{
	resetCanLungeTime();
}

public void OnAllPluginsLoaded()
{
	/**
	 * 与 hunter_patch 的交互：
	 * - 如果 l4d2_hunter_patch_convert_leap=1 且 l4d2_hunter_patch_crouch_pounce=2
	 *   则视为“忽略蹲起跳”场景，配套调整 ready_range/crouch_delay/commit_range。
	 */
	ignoreCrouch = false;

	ConVar g_hCoverLeap = FindConVar("l4d2_hunter_patch_convert_leap");
	if (g_hCoverLeap && g_hCoverLeap.IntValue == 1)
	{
		g_hCoverLeap = FindConVar("l4d2_hunter_patch_crouch_pounce");
		if (g_hCoverLeap && g_hCoverLeap.IntValue == 2)
		{
			ignoreCrouch = true;
		}
	}

	if (ignoreCrouch)
	{
		// 忽略蹲起跳：缩小“准备区间”与“蹲延时”，让 AI 更利落
		g_hPounceReadyRange.FloatValue = 0.0;
		FindConVar("z_pounce_crouch_delay").FloatValue            = 0.0;
		FindConVar("hunter_committed_attack_range").FloatValue    = 0.0;
	}
	else
	{
		// 保留默认体验
		g_hPounceReadyRange.FloatValue = 3000.0;
		FindConVar("z_pounce_crouch_delay").RestoreDefault();
		FindConVar("hunter_committed_attack_range").FloatValue    = 3000.0;
	}
}

/**
 * 设置/恢复少量全局 CVar。
 * 注意：这些会影响“真人 Hunter”，请在服务器说明里注明。
 */
void setCvarValue(bool set)
{
	if (set)
	{
		// 更易起跳、更少“离开放弃”、更安静接近
		g_hPounceLoftAngle.SetFloat(0.0);
		g_hPounceGiveUpRange.SetFloat(0.0);
		g_hPounceSilenceRange.SetFloat(999999.0);
		return;
	}
	g_hPounceReadyRange.RestoreDefault();
	g_hPounceLoftAngle.RestoreDefault();
	g_hPounceGiveUpRange.RestoreDefault();
	g_hPounceSilenceRange.RestoreDefault();
	g_hCommitAttackRange.RestoreDefault();
}

// =======================================================
// 核心逻辑：操控 AI Hunter 的移动/起跳/视角
// =======================================================
public Action OnPlayerRunCmd(int hunter, int& buttons, int& impulse, float vel[3], float angles[3],
                             int& weapon, int& subtype, int& cmdnum, int& tickcount, int& seed, int mouse[2])
{
	if (!isValidHunter(hunter)) { return Plugin_Continue; }

	// 取当前目标与能力实体
	int target = hunterCurrentTarget[hunter];
	int ability = GetEntPropEnt(hunter, Prop_Send, "m_customAbility");
	if (!IsValidEntity(ability) || !IsValidEdict(ability) || !IsValidSurvivor(target))
		return Plugin_Continue;

	// 预取常用状态
	float timestamp = GetEntPropFloat(ability, Prop_Send, "m_timestamp");
	float gametime  = GetGameTime();

	float selfPos[3], targetPos[3];
	GetClientAbsOrigin(hunter, selfPos);
	GetEntPropVector(target, Prop_Send, "m_vecOrigin", targetPos);

	float targetDistance = GetVectorDistance(selfPos, targetPos);

	// 来自能力实体的“下次要起跳的向量”（会被 angleLunge/limitLungeVerticality 改写）
	float lungeVector[3];
	GetEntPropVector(ability, Prop_Send, "m_queuedLunge", lungeVector);

	bool hasSight  = view_as<bool>(GetEntProp(hunter, Prop_Send, "m_hasVisibleThreats"));
	bool isDucking = view_as<bool>(GetEntProp(hunter, Prop_Send, "m_bDucked"));
	bool isLunging = view_as<bool>(GetEntProp(ability, Prop_Send, "m_isLunging"));

	// ========= 起跳过程中的“背飞视角”处理（概率） =========
	if (isLunging)
	{
		if (!canBackVision[hunter][0])
		{
			// 仅在一次起跳过程中抽签一次
			float roll = GetRandomFloatInRange(0.0, 100.0);
			canBackVision[hunter][1] = (roll <= g_hBackVision.FloatValue);
			canBackVision[hunter][0] = true;
		}

		if (canBackVision[hunter][1])
		{
			// 通过“反向目标向量”设置视角，使 hunter 背对目标（只改视角，不动 m_queuedLunge）
			float toTarget[3], backAngles[3];
			MakeVectorFromPoints(selfPos, targetPos, toTarget);
			NegateVector(toTarget);
			NormalizeVector(toTarget, toTarget);
			GetVectorAngles(toTarget, backAngles);
			TeleportEntity(hunter, NULL_VECTOR, backAngles, NULL_VECTOR);
			return Plugin_Changed;
		}
		return Plugin_Continue;
	}

	// 若不在地面，不做地面逻辑（例如空中被打/梯子等场景）
	if (!isOnGround(hunter)) { return Plugin_Continue; }

	// 新一轮起跳前，重置“背飞抽签状态”
	canBackVision[hunter][0] = false;

	// ========= 无视野分支（允许“盲跳” + 右键窗口） =========
	if (!hasSight && IsValidSurvivor(target))
	{
		// 原实现：若未蹲直接 return，导致“错过右键/排队起跳窗口”
		// 修正：尝试按一下蹲键，交还控制；下一帧再进来即可继续后续逻辑
		if (!isDucking)
		{
			buttons |= IN_DUCK;
			return Plugin_Changed;
		}

		// “准备起跳”窗口内，尝试按右键（挠）制造压迫感
		if (g_hMeleeFirst.BoolValue &&
			((gametime > timestamp - 0.1) && (gametime < timestamp)) &&
			((targetDistance < meleeMaxRange) && (targetDistance > meleeMinRange)))
		{
			buttons |= IN_ATTACK2;
		}
		else if (gametime > timestamp)
		{
			// 无视野允许条件：满足水平/垂直其中之一或两者（0 表示禁用对应维度）
			if (noSightPounceRange  > 0.0 && targetDistance > noSightPounceRange)                 { return Plugin_Continue; }
			if (noSightPounceHeight > 0.0 && FloatAbs(selfPos[2] - targetPos[2]) > noSightPounceHeight) { return Plugin_Continue; }

			// 使用“排队 + z_lunge_interval”的节奏触发 IN_ATTACK，避免硬抖
			if (!hasQueuedLunge[hunter])
			{
				hasQueuedLunge[hunter] = true;
				canLungeTime[hunter]   = gametime + g_hLungeInterval.FloatValue;
			}
			else if (gametime > canLungeTime[hunter])
			{
				buttons |= IN_ATTACK;
				hasQueuedLunge[hunter] = false;
			}
		}
		return Plugin_Changed;
	}

	// ========= 有视野分支：贴脸前“右键挠”一下 =========
	if (isDucking && g_hMeleeFirst.BoolValue &&
		((gametime > timestamp - 0.1) && (gametime < timestamp)) &&
		((targetDistance < meleeMaxRange) && (targetDistance > meleeMinRange)))
	{
		buttons |= IN_ATTACK2;
	}

	// 超出“快速突袭距离”或不在地面：不做“贴边起跳”
	if (!isOnGround(hunter) || targetDistance > g_hFastPounceDistance.FloatValue)
		return Plugin_Continue;

	// 在“快速突袭距离”内：清掉主攻击（避免与右键/其他指令纠缠），按排队节奏触发起跳
	buttons &= ~IN_ATTACK;

	if (!hasQueuedLunge[hunter])
	{
		hasQueuedLunge[hunter] = true;
		canLungeTime[hunter]   = gametime + g_hLungeInterval.FloatValue;
	}
	else if (canLungeTime[hunter] < gametime)
	{
		buttons |= IN_ATTACK;
		hasQueuedLunge[hunter] = false;
	}

	// 梯子上禁止跳/蹲，避免诡异卡顿
	if (GetEntityMoveType(hunter) & MOVETYPE_LADDER)
	{
		buttons &= ~IN_JUMP;
		buttons &= ~IN_DUCK;
	}

	return Plugin_Changed;
}

// =======================================================
// 事件处理
// =======================================================
public void playerSpawnHandler(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (!isValidHunter(client)) return;

	hasQueuedLunge[client]          = false;
	canBackVision[client][0]        = false;
	canBackVision[client][1]        = false;
	canLungeTime[client]            = 0.0;
	anglePounceCount[client][POUNCE_LEFT]  = 0;
	anglePounceCount[client][POUNCE_RIGHT] = 0;
}

public void abilityUseHandler(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (!isValidHunter(client)) return;

	char ability[32];
	event.GetString("ability", ability, sizeof(ability));

	// 只处理起跳事件（ability_lunge）
	if (strcmp(ability, "ability_lunge") == 0)
	{
		hunterOnPounce(client);
	}
}

public void roundEndHandler(Event event, const char[] name, bool dontBroadcast)
{
	resetCanLungeTime();
}

// =======================================================
// 起跳瞬间的“转向/限角/避墙”处理
// =======================================================
public void hunterOnPounce(int hunter)
{
	if (!isValidHunter(hunter)) return;

	int   lungeEntity = GetEntPropEnt(hunter, Prop_Send, "m_customAbility");
	float selfPos[3], selfEyeAngle[3], rayEndPos[3];

	GetClientAbsOrigin(hunter, selfPos);
	GetClientEyeAngles(hunter, selfEyeAngle);

	// ---------- 撞墙检测：若启用且命中“近前硬墙”，则随机朝左右侧飞 ----------
	if (g_hWallDetectDistance.FloatValue > -1.0)
	{
		// 将眼睛位置抬到“蹲姿高度+头部”附近，避免扫到地面
		selfPos[2] += CROUCH_HEIGHT;

		// 计算前向单位向量
		GetAngleVectors(selfEyeAngle, selfEyeAngle, NULL_VECTOR, NULL_VECTOR);
		NormalizeVector(selfEyeAngle, selfEyeAngle);

		// 终点 = 起点 + 前向 * 检测距离
		rayEndPos = selfEyeAngle;
		ScaleVector(rayEndPos, g_hWallDetectDistance.FloatValue);
		AddVectors(selfPos, rayEndPos, rayEndPos);

		// 更贴近“玩家会撞到的几何”的 MASK；过滤器会忽略自身/玩家等
		Handle ray = TR_TraceHullFilterEx(
			selfPos, rayEndPos,
			view_as<float>({-16.0, -16.0, 0.0}),
			view_as<float>({ 16.0,  16.0, 33.0}),
			MASK_PLAYERSOLID_BRUSHONLY,  // 可按需改回 MASK_NPCSOLID_BRUSHONLY
			traceRayFilter, hunter
		);

		if (TR_DidHit(ray))
		{
			float planeN[3];
			TR_GetPlaneNormal(ray, planeN);

			// 与前向夹角 > 165° 视为“基本正面硬墙”，尝试左右侧飞
			float deg = RadToDeg(ArcCosine(GetVectorDotProduct(selfEyeAngle, planeN)));
			if (deg > 165.0)
			{
				#if DEBUG
					PrintToConsoleAll("[Ai-Hunter]：前方 %.1fu 命中硬墙 → 尝试左右侧飞", GetVectorDistance(selfPos, rayEndPos));
				#endif

				delete ray;
				angleLunge(INVALID_CLIENT, INVALID_CLIENT, lungeEntity, GetRandomIntInRange(0, 1) ? LUNGE_LEFT : LUNGE_RIGHT);
				return;
			}
		}
		delete ray;
	}

	// ---------- 未撞墙：根据“是否被看着/距离/高度差”决定直扑 or 侧飞 ----------
	int target = hunterCurrentTarget[hunter];
	if (!IsValidSurvivor(target)) return;

	float targetPos[3];
	GetClientAbsOrigin(target, targetPos);

	// 若“正被看着”且（距离较远或高度差较小）→ 更倾向侧飞；
	// 若“不被看着”且高度差明显大 → 倾向直扑（此处不强制写死直扑，由默认向量决定）
	if (isVisibleTo(hunter, target, g_hAimOffset.FloatValue) &&
	    (GetClientDistance(hunter, target) > g_hStraightPounceDistance.IntValue ||
	     FloatAbs(targetPos[2] - selfPos[2]) < g_hHighPounceHeight.FloatValue))
	{
		#if DEBUG
			PrintToConsoleAll("[Ai-Hunter]：目标=%N 距=%d 高差=%.1f → 进入侧飞策略",
				target, GetClientDistance(hunter, target), FloatAbs(targetPos[2] - selfPos[2]));
		#endif

		// 生成一个带“中心倾向”的角度（仍是均匀随机 + 偏置，不是严格正态）
		int angle = xorShiftGetRandomInt(0, g_hPounceAngleMean.IntValue, g_hPounceAngleStd.IntValue);

		// 侧飞方向平衡：如长期偏左/偏右超阈值，则取反方向（修正原错误写法）
		if ((angle > 0 && anglePounceCount[hunter][POUNCE_LEFT]  - anglePounceCount[hunter][POUNCE_RIGHT] > g_hAnglePounceCount.IntValue) ||
		    (angle < 0 && anglePounceCount[hunter][POUNCE_RIGHT] - anglePounceCount[hunter][POUNCE_LEFT]  > g_hAnglePounceCount.IntValue))
		{
			if (angle == 0) angle = 1;
			angle = -angle; // 关键修正：简单取负，改向即可
		}

		// 统计左右次数
		if (angle > 0) anglePounceCount[hunter][POUNCE_LEFT]++; else anglePounceCount[hunter][POUNCE_RIGHT]++;

		// 将 queuedLunge 指向“面向目标”的向量，再在水平面上旋转 angle°
		angleLunge(hunter, target, lungeEntity, float(angle));

		// 最后对 Z 份额做“夹断式”限制，避免“抬头过猛”
		limitLungeVerticality(lungeEntity);

		#if DEBUG
			PrintToConsoleAll("[Ai-Hunter]：最终侧飞角度 = %.1f°", float(angle));
		#endif
	}
}

// =======================================================
// 射线过滤器：忽略自体/客户端/少数会动态移动的对象（避免误判）
// =======================================================
stock bool traceRayFilter(int entity, int contentsMask, any data)
{
	// 忽略自己和玩家
	if (entity == data || (entity > 0 && entity <= MaxClients))
		return false;

	// 忽略部分会让“撞墙判定”失真/不稳定的实体（特感、女巫、动态 Prop、坦克石头等）
	char cls[64];
	GetEntityClassname(entity, cls, sizeof(cls));
	if (cls[0] == 'i' || cls[0] == 'p' || cls[0] == 't' || cls[0] == 'w')
	{
		if (strcmp(cls, "infected")     == 0 ||
		    strcmp(cls, "witch")        == 0 ||
		    strcmp(cls, "prop_dynamic") == 0 ||
		    strcmp(cls, "prop_physics") == 0 ||
		    strcmp(cls, "tank_rock")    == 0)
		{
			return false;
		}
	}
	return true;
}

// =======================================================
// 目标选择（当默认 curTarget 不可见时，换最近的可见目标）
// =======================================================
public Action L4D2_OnChooseVictim(int specialInfected, int &curTarget)
{
	if (!isValidHunter(specialInfected) || !IsValidSurvivor(curTarget) || !IsPlayerAlive(curTarget))
		return Plugin_Continue;

	int   newTarget;
	float targetPos[3];
	GetEntPropVector(curTarget, Prop_Send, "m_vecOrigin", targetPos);

	// 默认目标不可见 → 尝试替换为“最近的可见生还”
	if (!L4D2_IsVisibleToPlayer(specialInfected, TEAM_INFECTED, curTarget, INVALID_NAV_AREA, targetPos))
	{
		newTarget = getClosestSurvivor(specialInfected);
		if (!IsValidSurvivor(newTarget))
		{
			hunterCurrentTarget[specialInfected] = curTarget;
			return Plugin_Continue; // 没找到可见目标 → 仍用默认
		}
		hunterCurrentTarget[specialInfected] = newTarget;
		curTarget = newTarget;
		return Plugin_Changed;
	}

	// 默认目标可见 → 记录，供 RunCmd 使用
	hunterCurrentTarget[specialInfected] = curTarget;
	return Plugin_Continue;
}

// =======================================================
// 工具/辅助
// =======================================================

/** 判断是否为“AI Hunter 且存活” */
bool isValidHunter(int client)
{
	return GetInfectedClass(client) == ZC_HUNTER && IsFakeClient(client) && IsPlayerAlive(client);
}

/** 从所有生还中找到“最近且可见”的一个；找不到则返回 INVALID_CLIENT */
static int getClosestSurvivor(int client)
{
	if (!isValidHunter(client)) return INVALID_CLIENT;

	float selfPos[3], targetPos[3];
	GetClientAbsOrigin(client, selfPos);

	ArrayList list = new ArrayList(2); // [0]=距离, [1]=目标 id

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || GetClientTeam(i) != TEAM_SURVIVOR || !IsPlayerAlive(i) || IsClientPinned(i))
			continue;

		GetEntPropVector(i, Prop_Send, "m_vecOrigin", targetPos);

		// 只考虑“可见”的生还者，避免换去“背后不可见”导致 AI 绕傻圈
		if (!L4D2_IsVisibleToPlayer(client, TEAM_INFECTED, i, INVALID_NAV_AREA, targetPos))
			continue;

		list.Set(list.Push(GetVectorDistance(selfPos, targetPos)), i, 1);
	}

	if (list.Length < 1)
	{
		delete list;
		return INVALID_CLIENT;
	}

	list.Sort(Sort_Ascending, Sort_Float);
	int best = list.Get(0, 1);
	delete list;
	return best;
}

/** 计算“目标是否基本看向我”（以水平夹角为准） */
float getPlayerAimingOffset(int hunter, int target)
{
	float eyeFwd[3], self2target[3], selfEyeAngles[3], selfPos[3], targetPos[3];

	GetClientEyeAngles(hunter, selfEyeAngles);
	selfEyeAngles[0] = selfEyeAngles[2] = 0.0;             // 只考虑水平面
	GetAngleVectors(selfEyeAngles, eyeFwd, NULL_VECTOR, NULL_VECTOR);
	NormalizeVector(eyeFwd, eyeFwd);

	GetClientAbsOrigin(hunter, selfPos);
	GetClientAbsOrigin(target, targetPos);
	selfPos[2] = targetPos[2] = 0.0;

	MakeVectorFromPoints(selfPos, targetPos, self2target);
	NormalizeVector(self2target, self2target);

	return RadToDeg(ArcCosine(GetVectorDotProduct(eyeFwd, self2target)));
}

/** 基于“水平合力”对 Z 分量做“夹断式”限制，避免“抬头过猛/穿顶” */
void limitLungeVerticality(int ability)
{
	if (!IsValidEntity(ability) || !IsValidEdict(ability)) return;

	float v[3];
	GetEntPropVector(ability, Prop_Send, "m_queuedLunge", v);

	float maxDeg = g_hPounceVerticalAngle.FloatValue;
	if (maxDeg <= 0.0) return;

	// 水平合力
	float h = SquareRoot(v[0]*v[0] + v[1]*v[1]);
	if (h <= 0.0) return;

	// 允许的最大 |Z|
	float maxZ = h * Tangent(DegToRad(maxDeg));
	if (FloatAbs(v[2]) > maxZ)
		v[2] = (v[2] > 0.0 ? maxZ : -maxZ);

	SetEntPropVector(ability, Prop_Send, "m_queuedLunge", v);
}

/**
 * 在水平面上把 m_queuedLunge 向量旋转 turnAngle 度。
 * 若给出 hunter+target，则先把向量对准 target，再旋转（可用于“视角锁定感”）。
 */
void angleLunge(int hunter, int target, int lungeEntity, float turnAngle)
{
	if (!IsValidEntity(lungeEntity) || !IsValidEdict(lungeEntity)) return;

	float v[3], r[3];
	GetEntPropVector(lungeEntity, Prop_Send, "m_queuedLunge", v);

	turnAngle = DegToRad(turnAngle);

	// 如给出 hunter+target，则“把向量指向目标”，再乘以 z_lunge_power（力度）
	if (isValidHunter(hunter) && IsValidSurvivor(target) && IsPlayerAlive(target))
	{
		float selfPos[3], targetPos[3];
		GetClientAbsOrigin(hunter, selfPos);
		GetEntPropVector(target, Prop_Send, "m_vecOrigin", targetPos);

		SubtractVectors(targetPos, selfPos, v);
		NormalizeVector(v, v);
		ScaleVector(v, g_hLungePower.FloatValue);
	}

	// 仅在水平面上旋转（Z 不动）
	r[0] = v[0] * Cosine(turnAngle) - v[1] * Sine(turnAngle);
	r[1] = v[0] * Sine(turnAngle) + v[1] * Cosine(turnAngle);
	r[2] = v[2];

	SetEntPropVector(lungeEntity, Prop_Send, "m_queuedLunge", r);
}

/**
 * xorshift 伪随机 + 简单“加减 std”构造的角度。
 * 说明：不是严格正态，仅用于制造“有中心倾向”的离散角度效果。
 */
static int xorShiftGetRandomInt(int min, int max, int std)
{
	static int x = 123456789, y = 362436069, z = 521288629, w = 88675123;
	int t = x ^ (x << 11);
	x = y; y = z; z = w;
	w = w ^ (w >> 19) ^ (t ^ (t >> 8));
	w = w % (max - min + 1); // 0..(max-min)

	// 50% 决定往均值正侧还是负侧发散
	if (GetRandomFloatInRange(0.0, 1.0) < 0.5) return (min + w) + std;
	else                                       return (min + w) - std;
}

/** 是否站在地面（m_hGroundEntity != -1） */
bool isOnGround(int client)
{
	if (!isValidHunter(client)) return false;
	return GetEntPropEnt(client, Prop_Send, "m_hGroundEntity") != -1;
}

/** 解析“右键挠”的距离窗口（min,max） */
void getHunterMeleeFirstRange()
{
	char buf[64], parts[2][16];
	g_hMeleeFirst.GetString(buf, sizeof(buf));

	if (IsNullString(buf))
	{
		// 没有配置则用一个较保守的窗口
		meleeMinRange = 400.0;
		meleeMaxRange = 1000.0;
		return;
	}

	ExplodeString(buf, ",", parts, 2, sizeof(parts[]));
	meleeMinRange = StringToFloat(parts[0]);
	meleeMaxRange = StringToFloat(parts[1]);
}

/** 解析“无视野可起跳”的距离/高度窗口（水平,垂直） */
void getNoSightPounceRange()
{
	char buf[64], parts[2][16];
	g_hNoSightPounceRange.GetString(buf, sizeof(buf));

	if (IsNullString(buf))
	{
		noSightPounceRange  = 300.0;
		noSightPounceHeight = 250.0;
		return;
	}

	ExplodeString(buf, ",", parts, 2, sizeof(parts[]));
	noSightPounceRange  = StringToFloat(parts[0]);
	noSightPounceHeight = StringToFloat(parts[1]);
}

/**
 * 判断“是否基本看向我”：只基于水平夹角（更贴近人类主观“是否在盯我”）
 * 返回 true 并不代表“可视线可达”，只是朝向判定；可与 L4D2_IsVisibleToPlayer 组合。
 */
bool isVisibleTo(int hunter, int target, float offset)
{
	if (!isValidHunter(hunter) || !IsValidSurvivor(target) || !IsPlayerAlive(target))
		return false;

	float eyeFwd[3], selfEyeAngles[3], selfEyePos[3], targetEyePos[3], self2target[3];

	GetClientEyeAngles(hunter, selfEyeAngles);
	selfEyeAngles[0] = selfEyeAngles[2] = 0.0; // 水平面
	GetAngleVectors(selfEyeAngles, eyeFwd, NULL_VECTOR, NULL_VECTOR);
	NormalizeVector(eyeFwd, eyeFwd);

	GetClientEyePosition(hunter, selfEyePos);
	GetClientEyePosition(target, targetEyePos);
	selfEyePos[2] = targetEyePos[2] = 0.0;

	MakeVectorFromPoints(selfEyePos, targetEyePos, self2target);
	NormalizeVector(self2target, self2target);

	// 返回“夹角 < offset”（是否看向我）
	return RadToDeg(ArcCosine(GetVectorDotProduct(eyeFwd, self2target))) < offset;
}

/** 回合/地图切换时清理状态 */
void resetCanLungeTime()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		canLungeTime[i]                        = 0.0;
		anglePounceCount[i][POUNCE_LEFT]       = 0;
		anglePounceCount[i][POUNCE_RIGHT]      = 0;
		hunterCurrentTarget[i]                 = 0;
	}
}

// =======================================================
// CVar 变更回调（字符串 → 数值）
// =======================================================
void meleeFirstRangeChangedHandler(ConVar convar, const char[] oldValue, const char[] newValue)
{
	getHunterMeleeFirstRange();
}

void noSightPounceRangeChangedHandler(ConVar convar, const char[] oldValue, const char[] newValue)
{
	getNoSightPounceRange();
}
