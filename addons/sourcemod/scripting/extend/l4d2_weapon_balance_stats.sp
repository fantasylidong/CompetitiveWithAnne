#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <left4dhooks>
#include <l4d2util_constants>
#include <anne_db>

#undef REQUIRE_PLUGIN
#include <l4dstats>
#include <l4d2_weapon_attributes>
#define REQUIRE_PLUGIN

#define PLUGIN_VERSION "1.2.0"

#define WBS_TEAM_SURVIVOR 2
#define WBS_L4D2Team_Infected 3

#define WEP_COUNT 19
#define TARGET_COUNT 9
#define DIST_BUCKETS 5
#define MOVE_STATES 2
#define SKILL_TIERS 3
#define STAT_FIELDS 9
#define USAGE_FIELDS 6
#define MAX_SG_TRACKED 8
#define MAX_TRACKED_EDICTS 2048
#define SQL_BATCH_ROWS 32
#define SQL_QUERY_MAX 12288

enum
{
	TARGET_COMMON = 0,
	TARGET_SMOKER = 1,
	TARGET_BOOMER = 2,
	TARGET_HUNTER = 3,
	TARGET_SPITTER = 4,
	TARGET_JOCKEY = 5,
	TARGET_CHARGER = 6,
	TARGET_WITCH = 7,
	TARGET_TANK = 8
};

enum
{
	STAT_HITS = 0,
	STAT_HEADSHOTS = 1,
	STAT_RAW_DMG = 2,
	STAT_EFF_DMG = 3,
	STAT_KILLS = 4,
	STAT_SHOT_BURSTS = 5,
	STAT_ONE_SHOT_KILLS = 6,
	STAT_NEAR_KILL_MISSES = 7,
	STAT_COLLATERAL_HITS = 8
};

enum
{
	USAGE_SHOTS_FIRED = 0,
	USAGE_PELLETS_FIRED = 1,
	USAGE_RELOADS = 2,
	USAGE_HOLD_SECONDS = 3,
	USAGE_PICKUPS = 4,
	USAGE_SWAPS_AWAY = 5
};

enum struct PendingTankFight
{
	char fightId[40];
	int statDate;
	int createdAt;
	char rulesetKey[64];
	char anneVersion[64];
	char difficultyType[16];
	int difficulty;
	int siCount;
	int siSpawnTime;
	char weaponConfig[64];
	char configHash[24];
	char mapName[64];
	int tankMaxHp;
	int durationMs;
	int shooterCount;
	int killed;
	int weaponIdx;
	int rawDmg;
	int effDmg;
	int hits;
	int shots;
	int distSum;
}

enum struct TankFightState
{
	bool active;
	bool engaged;
	int maxHp;
	float startTime;
	int shooterMask;
	char rulesetKey[64];
	char anneVersion[64];
	char difficultyType[16];
	int difficulty;
	int siCount;
	int siSpawnTime;
	char weaponConfig[64];
	char configHash[24];
	int rawDmg[WEP_COUNT];
	int effDmg[WEP_COUNT];
	int hits[WEP_COUNT];
	int shots[WEP_COUNT];
	int distSum[WEP_COUNT];
}

static const int g_iTrackedWepIds[WEP_COUNT] =
{
	WEPID_PISTOL,
	WEPID_PISTOL_MAGNUM,
	WEPID_SMG,
	WEPID_SMG_SILENCED,
	WEPID_SMG_MP5,
	WEPID_PUMPSHOTGUN,
	WEPID_SHOTGUN_CHROME,
	WEPID_AUTOSHOTGUN,
	WEPID_SHOTGUN_SPAS,
	WEPID_RIFLE,
	WEPID_RIFLE_AK47,
	WEPID_RIFLE_DESERT,
	WEPID_RIFLE_SG552,
	WEPID_RIFLE_M60,
	WEPID_HUNTING_RIFLE,
	WEPID_SNIPER_MILITARY,
	WEPID_SNIPER_SCOUT,
	WEPID_SNIPER_AWP,
	WEPID_GRENADE_LAUNCHER
};

static const bool g_bWepIsShotgun[WEP_COUNT] =
{
	false, false,
	false, false, false,
	true, true, true, true,
	false, false, false, false, false,
	false, false, false, false,
	false
};

static const bool g_bWepIsSecondary[WEP_COUNT] =
{
	true, true,
	false, false, false,
	false, false, false, false,
	false, false, false, false, false,
	false, false, false, false,
	false
};

// 5 个交火距离档位上限平方：160u, 300u, 650u, 1200u, 1200u+
static const float g_fDistBucketMaxSq[DIST_BUCKETS - 1] =
{
	25600.0,    // 160^2
	90000.0,    // 300^2
	422500.0,   // 650^2
	1440000.0   // 1200^2
};

// 跑打判定阈值：水平速度 > 50u/s (50^2 = 2500)
#define MOVE_SPEED_SQ_THRESHOLD 2500.0

ConVar g_cvEnable;
ConVar g_cvDbConf;
ConVar g_cvDbPrefix;
ConVar g_cvMinHumans;

ConVar g_cvReadyCfgName;
ConVar g_cvGameMode;
ConVar g_cvAnneVersion;
ConVar g_cvWeaponConfig;
ConVar g_cvStatsRuleset;
ConVar g_cvDiffProfile;
ConVar g_cvZDifficulty;
ConVar g_cvAiEnable;
ConVar g_cvAiCurrentLevel;
ConVar g_cvAiFixedLevel;
ConVar g_cvAiCurrentLocked;
ConVar g_cvInfectedLimit;
ConVar g_cvSiSpawnInterval;
ConVar g_cvSgCenterPellet;
ConVar g_cvSgRing1Bullets;
ConVar g_cvSgRing1Factor;

bool g_bHookReadyCfg = false;
bool g_bHookGameMode = false;
bool g_bHookAnneVer = false;
bool g_bHookWeaponConfig = false;
bool g_bHookStatsRuleset = false;
bool g_bHookDiffProfile = false;
bool g_bHookZDifficulty = false;
bool g_bHookAiEnable = false;
bool g_bHookAiCurrentLevel = false;
bool g_bHookAiFixedLevel = false;
bool g_bHookAiCurrentLocked = false;
bool g_bHookInfectedLimit = false;
bool g_bHookSiSpawnInterval = false;
bool g_bHookSgCenter = false;
bool g_bHookSgRing1 = false;
bool g_bHookSgFactor = false;

Database g_hDb = null;
int g_iDbGen = 0;
bool g_bDbConnecting = false;
bool g_bSchemaReady = false;
bool g_bSchemaCreating = false;
float g_fNextDbRetry = 0.0;

StringMap g_smWeaponNameToIdx = null;
char g_sWeaponKeys[WEP_COUNT][32];
int g_iWepBullets[WEP_COUNT];

bool g_bRoundLive = false;
bool g_bRoundFinished = false;
bool g_bDirtyCombat = false;
bool g_bDirtyUsage = false;
bool g_bDirtySwaps = false;

char g_sDbPrefix[32];
char g_sCurrentMap[64];
char g_sActiveRuleset[64] = "legacy_unknown";
char g_sActiveDifficultyType[16] = "game";
int g_iActiveDifficulty = 1;
int g_iActiveSiCount = 0;
int g_iActiveSiSpawnTime = 0;
char g_sActiveWeaponConfig[64] = "default";
char g_sActiveAnneVersion[64] = "";
char g_sActiveConfigHash[24] = "";
char g_sActiveAttrsJson[12288];
int g_iActiveSgCenter = -1;
int g_iActiveSgRing1 = -1;
float g_fActiveSgFactor = -1.0;
bool g_bConfigPendingUpload = false;
bool g_bLightRefreshPending = false;
bool g_bLightRefreshQueued = false;
bool g_bFullRefreshPending = false;
Handle g_hFullRefreshTimer = null;
DataPack g_hFlushBackup = null;
ArrayList g_hUploadBackups;
int g_iFailedBatchSerial;

int g_iCombatStats[WEP_COUNT][TARGET_COUNT][DIST_BUCKETS][MOVE_STATES][SKILL_TIERS][STAT_FIELDS];
int g_iUsageStats[WEP_COUNT][MOVE_STATES][SKILL_TIERS][USAGE_FIELDS];
int g_iSwapMatrix[WEP_COUNT][WEP_COUNT];

ArrayList g_hPendingTanks = null;
TankFightState g_TankFight[MAXPLAYERS + 1];
int g_iTankFightSerial = 0;
char g_sSessionId[24];
int g_iLastSgShot[MAX_TRACKED_EDICTS];
int g_iShotSerial;

int g_iActiveWepEnt[MAXPLAYERS + 1];
int g_iActiveWepIdx[MAXPLAYERS + 1];
int g_iClientSlotWep[MAXPLAYERS + 1][2];
int g_iClientSkillTier[MAXPLAYERS + 1];
int g_iShotSeq[MAXPLAYERS + 1];
int g_iBulletHitTargetsInSeq[MAXPLAYERS + 1];

// 霰弹单发同帧归并槽（零 DataPack / 零堆分配）
int g_SgCount[MAXPLAYERS + 1];
int g_SgWepIdx[MAXPLAYERS + 1];
int g_SgMove[MAXPLAYERS + 1];
int g_SgTier[MAXPLAYERS + 1];
bool g_SgFlushPending[MAXPLAYERS + 1];
int g_SgTargetEnt[MAXPLAYERS + 1][MAX_SG_TRACKED];
int g_SgTargetClass[MAXPLAYERS + 1][MAX_SG_TRACKED];
int g_SgTargetDist[MAXPLAYERS + 1][MAX_SG_TRACKED];
int g_SgTargetPreHp[MAXPLAYERS + 1][MAX_SG_TRACKED];
int g_SgTargetMaxHp[MAXPLAYERS + 1][MAX_SG_TRACKED];
int g_SgTargetPostHp[MAXPLAYERS + 1][MAX_SG_TRACKED];
bool g_SgTargetKilled[MAXPLAYERS + 1][MAX_SG_TRACKED];

// 特感与 Tank 血量快照（避免致死溢出虚高）
int g_iClientLastHp[MAXPLAYERS + 1];
int g_iClientMaxHp[MAXPLAYERS + 1];
bool g_bClientHitOnce[MAXPLAYERS + 1];
bool g_bClientDeathCounted[MAXPLAYERS + 1];

// 实体缓存（Witch 与榴弹投射物，避免热路径类名比较）
bool g_bEntityIsWitch[MAX_TRACKED_EDICTS];
int g_iEntityPreHp[MAX_TRACKED_EDICTS];
int g_iEntityDamageAttacker[MAX_TRACKED_EDICTS];
int g_iEntityDamageTick[MAX_TRACKED_EDICTS];
bool g_bEntityIsGLProj[MAX_TRACKED_EDICTS];
bool g_bEntityDamageIsGL[MAX_TRACKED_EDICTS];

Handle g_hHoldTimer = null;
Handle g_hSnapshotTimer = null;

public Plugin myinfo =
{
	name = "L4D2 Weapon Balance Stats",
	author = "morzlee",
	description = "Low-overhead bucketed firearm telemetry (no friendly fire) for Anne weapon balancing",
	version = PLUGIN_VERSION,
	url = "https://github.com/fantasylidong/CompetitiveWithAnne"
};

bool g_bLateLoaded = false;

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	g_bLateLoaded = late;
	RegPluginLibrary("l4d2_weapon_balance_stats");
	return APLRes_Success;
}

public void OnPluginStart()
{
	g_cvEnable = CreateConVar("sm_weapon_balance_enable", "1", "启用枪械平衡数据采样统计 (1=开启, 0=关闭)", FCVAR_NONE, true, 0.0, true, 1.0);
	g_cvDbConf = CreateConVar("sm_weapon_balance_db_conf", "l4dstats", "databases.cfg 中的数据库配置段名称", FCVAR_NONE);
	g_cvDbPrefix = CreateConVar("sm_weapon_balance_db_prefix", "", "统计数据表前缀", FCVAR_NONE);
	g_cvMinHumans = CreateConVar("sm_weapon_balance_min_humans", "1", "至少多少名真人生还者时才计入统计", FCVAR_NONE, true, 1.0, true, 32.0);

	FormatEx(g_sSessionId, sizeof(g_sSessionId), "%08x%08x", GetURandomInt(), GetURandomInt());
	g_hPendingTanks = new ArrayList(sizeof(PendingTankFight));
	g_hUploadBackups = new ArrayList();
	BuildWeaponMaps();
	ResetAllClientState();
	ResetAllBuckets();

	HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);
	HookEvent("round_end", Event_RoundEnd, EventHookMode_PostNoCopy);
	HookEvent("map_transition", Event_RoundEnd, EventHookMode_PostNoCopy);
	HookEvent("finale_win", Event_RoundEnd, EventHookMode_PostNoCopy);
	HookEvent("mission_lost", Event_RoundEnd, EventHookMode_PostNoCopy);
	HookEvent("player_left_safe_area", Event_LeftSafeArea, EventHookMode_PostNoCopy);

	HookEvent("weapon_fire", Event_WeaponFire);
	HookEvent("weapon_reload", Event_WeaponReload);
	HookEvent("item_pickup", Event_ItemPickup);
	HookEvent("player_spawn", Event_PlayerSpawn);
	HookEvent("player_hurt", Event_PlayerHurt, EventHookMode_Pre);
	HookEvent("player_incapacitated", Event_PlayerIncap);
	HookEvent("player_death", Event_PlayerDeath);
	HookEvent("infected_hurt", Event_InfectedHurt, EventHookMode_Pre);
}

public void OnAllPluginsLoaded()
{
	RefreshCvarHandles();
	EnsureDbConnected();
	if (g_bLateLoaded)
	{
		if (g_hHoldTimer == null) g_hHoldTimer = CreateTimer(1.0, Timer_SampleHoldSeconds, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
		GetCurrentMap(g_sCurrentMap, sizeof(g_sCurrentMap));
		LowerString(g_sCurrentMap);
		ScanExistingInfected();
		RefreshWeaponConfigSnapshot();
		if (L4D_HasAnySurvivorLeftSafeArea())
		{
			ActivateRoundLive();
		}
		g_bLateLoaded = false;
	}
}

public void OnLibraryAdded(const char[] name)
{
	if (StrEqual(name, "annehappy_dynamic_ai_difficulty"))
	{
		RefreshCvarHandles();
		g_bLightRefreshPending = true;
	}
}

public void OnLibraryRemoved(const char[] name)
{
	if (StrEqual(name, "annehappy_dynamic_ai_difficulty")) g_bLightRefreshPending = true;
}

public void OnConfigsExecuted()
{
	RefreshCvarHandles();
	GetCurrentMap(g_sCurrentMap, sizeof(g_sCurrentMap));
	LowerString(g_sCurrentMap);

	if (g_hDb == null)
	{
		EnsureDbConnected();
	}

	delete g_hSnapshotTimer;
	g_hSnapshotTimer = CreateTimer(1.0, Timer_RefreshConfigSnapshot, _, TIMER_FLAG_NO_MAPCHANGE);
}

public void OnMapStart()
{
	g_bRoundFinished = false;
	g_bRoundLive = false;
	GetCurrentMap(g_sCurrentMap, sizeof(g_sCurrentMap));
	LowerString(g_sCurrentMap);

	ClearEntityCaches();
	ResetAllTankFights();

	delete g_hHoldTimer;
	g_hHoldTimer = CreateTimer(1.0, Timer_SampleHoldSeconds, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

public void OnMapEnd()
{
	g_bRoundFinished = true;
	g_bRoundLive = false;
	g_hHoldTimer = null;
	g_hSnapshotTimer = null;
	g_hFullRefreshTimer = null;
	g_bLightRefreshPending = false;
	FinalizeActiveTankFights(false);
	FlushAllStatsToDb();
}

public void OnPluginEnd()
{
	FinalizeActiveTankFights(false);
	FlushAllStatsToDb();
	// SourceMod may cancel callbacks after unload; preserve every in-flight payload.
	for (int i = 0; i < g_hUploadBackups.Length; i++)
	{
		DataPack backup = view_as<DataPack>(g_hUploadBackups.Get(i));
		backup.Reset();
		backup.ReadCell();
		SaveFailedBatch(backup);
	}
	if (g_hDb != null)
	{
		delete g_hDb;
		g_hDb = null;
	}
}

public void LGO_OnMatchModeUnloaded()
{
	g_bRoundFinished = true;
	g_bRoundLive = false;
	g_bLightRefreshPending = false;
	delete g_hFullRefreshTimer;
	FinalizeActiveTankFights(false);
	FlushAllStatsToDb();
}

public void OnRoundIsLive()
{
	ActivateRoundLive();
}

public void OnClientPutInServer(int client)
{
	ResetClientState(client);
}

public void OnClientDisconnect(int client)
{
	FlushClientShotgunBurst(client);
	FinalizeTankFight(client, false);
	ResetClientState(client);
}

public void OnEntityCreated(int entity, const char[] classname)
{
	if (entity <= MaxClients || entity >= MAX_TRACKED_EDICTS)
	{
		return;
	}

	if (StrEqual(classname, "infected") || StrEqual(classname, "witch"))
	{
		g_bEntityIsWitch[entity] = StrEqual(classname, "witch");
		g_iEntityPreHp[entity] = 0;
		SDKHook(entity, SDKHook_OnTakeDamage, OnInfectedTakeDamage);
	}
	else if (classname[0] == 'g' && strcmp(classname, "grenade_launcher_projectile") == 0)
	{
		g_bEntityIsGLProj[entity] = true;
	}
}

// Entity health at FireEvent time is not guaranteed to be pre-damage health.
// Capture it at the actual SDK damage boundary; the event consumes one matching snapshot.
public Action OnInfectedTakeDamage(int victim, int &attacker, int &inflictor, float &damage, int &damagetype)
{
	g_iEntityPreHp[victim] = 0;
	if (!g_cvEnable.BoolValue || !g_bRoundLive || !IsValidHumanSurvivor(attacker)) return Plugin_Continue;
	g_iEntityPreHp[victim] = GetEntProp(victim, Prop_Data, "m_iHealth");
	g_bEntityDamageIsGL[victim] = inflictor > MaxClients && inflictor < MAX_TRACKED_EDICTS && g_bEntityIsGLProj[inflictor];
	g_iEntityDamageAttacker[victim] = attacker;
	g_iEntityDamageTick[victim] = GetGameTickCount();
	return Plugin_Continue;
}

static void ScanExistingInfected()
{
	int entity = -1;
	while ((entity = FindEntityByClassname(entity, "infected")) != -1) OnEntityCreated(entity, "infected");
	entity = -1;
	while ((entity = FindEntityByClassname(entity, "witch")) != -1) OnEntityCreated(entity, "witch");
}

public void OnEntityDestroyed(int entity)
{
	if (entity <= MaxClients || entity >= MAX_TRACKED_EDICTS)
	{
		return;
	}

	g_bEntityIsWitch[entity] = false;
	g_iLastSgShot[entity] = 0;
	g_iEntityPreHp[entity] = 0;
	g_bEntityIsGLProj[entity] = false;
}

public Action Timer_RefreshConfigSnapshot(Handle timer)
{
	g_hSnapshotTimer = null;
	RefreshWeaponConfigSnapshot();
	return Plugin_Stop;
}

public Action Timer_SampleHoldSeconds(Handle timer)
{
	EnsureDbConnected();
	EnsureSchema();
	UploadConfigSnapshotIfReady();
	if (!g_cvEnable.BoolValue || !g_bRoundLive)
	{
		return Plugin_Continue;
	}

	if (!PrepareSampleContext() || !HasEnoughHumanSurvivors())
	{
		return Plugin_Continue;
	}

	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsClientInGame(client) || IsFakeClient(client) || GetClientTeam(client) != TEAM_SURVIVOR || !IsPlayerAlive(client))
		{
			continue;
		}

		UpdateClientSkillTier(client);
		int wepIdx = GetClientActiveWeaponIdxCached(client);
		if (wepIdx < 0)
		{
			continue;
		}

		int moveState = GetClientMoveState(client);
		int tier = g_iClientSkillTier[client];
		g_iUsageStats[wepIdx][moveState][tier][USAGE_HOLD_SECONDS]++;
		g_bDirtyUsage = true;
	}

	return Plugin_Continue;
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	g_bRoundFinished = false;
	g_bRoundLive = false;
	RefreshCvarHandles();
	ResetAllTankFights();
	for (int i = 1; i <= MaxClients; i++)
	{
		g_iActiveWepEnt[i] = -1;
		g_iActiveWepIdx[i] = -1;
		g_iClientSlotWep[i][0] = -1;
		g_iClientSlotWep[i][1] = -1;
		g_SgCount[i] = 0;
		g_SgFlushPending[i] = false;
		g_iClientLastHp[i] = 0;
		g_iClientMaxHp[i] = 0;
		g_bClientHitOnce[i] = false;
		g_bClientDeathCounted[i] = false;
	}

	delete g_hSnapshotTimer;
	g_hSnapshotTimer = CreateTimer(1.0, Timer_RefreshConfigSnapshot, _, TIMER_FLAG_NO_MAPCHANGE);
}

public void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
	g_bRoundFinished = true;
	g_bRoundLive = false;
	g_bLightRefreshPending = false;
	delete g_hFullRefreshTimer;
	for (int i = 1; i <= MaxClients; i++)
	{
		FlushClientShotgunBurst(i);
	}
	FinalizeActiveTankFights(false);
	FlushAllStatsToDb();
}

public void Event_LeftSafeArea(Event event, const char[] name, bool dontBroadcast)
{
	ActivateRoundLive();
}

static void ActivateRoundLive()
{
	if (!g_cvEnable.BoolValue || g_bRoundFinished)
	{
		return;
	}

	if (!g_bRoundLive)
	{
		RefreshWeaponConfigSnapshot();
		g_bRoundLive = true;

		for (int i = 1; i <= MaxClients; i++)
		{
			if (IsClientInGame(i) && !IsFakeClient(i) && GetClientTeam(i) == TEAM_SURVIVOR && IsPlayerAlive(i))
			{
				SyncClientSlotWeapons(i);
				UpdateClientSkillTier(i);
			}
			else if (IsClientInGame(i) && GetClientTeam(i) == L4D2Team_Infected && IsPlayerAlive(i))
			{
				g_iClientLastHp[i] = GetClientHealth(i);
				g_iClientMaxHp[i] = GetEntProp(i, Prop_Data, "m_iMaxHealth");
			}
		}
	}
}

public void Event_WeaponFire(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_cvEnable.BoolValue)
	{
		return;
	}

	int client = GetClientOfUserId(event.GetInt("userid"));
	if (!IsValidHumanSurvivor(client))
	{
		return;
	}

	if (!g_bRoundLive)
	{
		if (L4D_HasAnySurvivorLeftSafeArea())
		{
			ActivateRoundLive();
		}
		if (!g_bRoundLive)
		{
			return;
		}
	}

	if (!PrepareSampleContext() || !HasEnoughHumanSurvivors())
	{
		return;
	}

	int wepIdx = GetClientActiveWeaponIdxCached(client);
	if (wepIdx < 0)
	{
		return;
	}

	g_iShotSeq[client] = ++g_iShotSerial;
	g_iBulletHitTargetsInSeq[client] = 0;

	if (g_bWepIsShotgun[wepIdx] && g_SgCount[client] > 0)
	{
		FlushClientShotgunBurst(client);
	}

	int moveState = GetClientMoveState(client);
	int tier = g_iClientSkillTier[client];
	g_iUsageStats[wepIdx][moveState][tier][USAGE_SHOTS_FIRED]++;
	int pellets = event.GetInt("count");
	g_iUsageStats[wepIdx][moveState][tier][USAGE_PELLETS_FIRED] += (g_bWepIsShotgun[wepIdx] && pellets > 0) ? pellets : g_iWepBullets[wepIdx];
	g_bDirtyUsage = true;

	RecordTankFightShot(client, wepIdx);
}

public void Event_WeaponReload(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_cvEnable.BoolValue || !g_bRoundLive || !PrepareSampleContext() || !HasEnoughHumanSurvivors())
	{
		return;
	}

	int client = GetClientOfUserId(event.GetInt("userid"));
	if (!IsValidHumanSurvivor(client))
	{
		return;
	}

	int wepIdx = GetClientActiveWeaponIdxCached(client);
	if (wepIdx < 0)
	{
		return;
	}

	int moveState = GetClientMoveState(client);
	int tier = g_iClientSkillTier[client];
	g_iUsageStats[wepIdx][moveState][tier][USAGE_RELOADS]++;
	g_bDirtyUsage = true;
}

public void Event_ItemPickup(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_cvEnable.BoolValue || !g_bRoundLive || !PrepareSampleContext() || !HasEnoughHumanSurvivors())
	{
		return;
	}

	int client = GetClientOfUserId(event.GetInt("userid"));
	if (!IsValidHumanSurvivor(client) || !IsPlayerAlive(client))
	{
		return;
	}

	char item[64];
	event.GetString("item", item, sizeof(item));
	if (item[0] == '\0')
	{
		return;
	}

	if (strcmp(item, "melee") == 0 || strcmp(item, "chainsaw") == 0)
	{
		g_iClientSlotWep[client][1] = -1;
		return;
	}

	int newWep = LookupWeaponIdx(item);
	if (newWep < 0)
	{
		return;
	}

	int slot = g_bWepIsSecondary[newWep] ? 1 : 0;
	int oldWep = g_iClientSlotWep[client][slot];
	if (oldWep == newWep)
	{
		return;
	}

	int moveState = GetClientMoveState(client);
	int tier = g_iClientSkillTier[client];
	g_iUsageStats[newWep][moveState][tier][USAGE_PICKUPS]++;
	if (oldWep >= 0)
	{
		g_iUsageStats[oldWep][moveState][tier][USAGE_SWAPS_AWAY]++;
		g_iSwapMatrix[oldWep][newWep]++;
		g_bDirtySwaps = true;
	}
	g_bDirtyUsage = true;
	g_iClientSlotWep[client][slot] = newWep;
}

public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client <= 0 || client > MaxClients || !IsClientInGame(client))
	{
		return;
	}

	int team = GetClientTeam(client);
	if (team == TEAM_SURVIVOR)
	{
		if (!IsFakeClient(client) && g_bRoundLive)
		{
			SyncClientSlotWeapons(client);
			UpdateClientSkillTier(client);
		}
		return;
	}

	if (team != L4D2Team_Infected)
	{
		return;
	}

	int hp = GetClientHealth(client);
	int maxHp = GetEntProp(client, Prop_Data, "m_iMaxHealth");
	if (maxHp < hp)
	{
		maxHp = hp;
	}

	g_iClientLastHp[client] = hp;
	g_iClientMaxHp[client] = maxHp;
	g_bClientHitOnce[client] = false;
	g_bClientDeathCounted[client] = false;

	int zClass = GetEntProp(client, Prop_Send, "m_zombieClass");
	if (zClass == TARGET_TANK)
	{
		StartTankFight(client, maxHp);
	}
}

public Action Event_PlayerHurt(Event event, const char[] name, bool dontBroadcast)
{
	int victim = GetClientOfUserId(event.GetInt("userid"));
	if (victim <= 0 || victim > MaxClients || !IsClientInGame(victim) || GetClientTeam(victim) != L4D2Team_Infected)
	{
		return Plugin_Continue;
	}
	int zClass = GetEntProp(victim, Prop_Send, "m_zombieClass");
	if (zClass < 1 || zClass > TARGET_TANK || zClass == TARGET_WITCH || g_bClientDeathCounted[victim])
	{
		return Plugin_Continue;
	}
	// Tank dying emits artificial health/damage; the incap/death event owns its killing blow.
	if (zClass == TARGET_TANK && GetEntProp(victim, Prop_Send, "m_isIncapacitated") != 0)
	{
		return Plugin_Continue;
	}
	int remain = event.GetInt("health");
	int dmgHealth = event.GetInt("dmg_health");
	int preHp = g_iClientLastHp[victim];
	int curMax = GetEntProp(victim, Prop_Data, "m_iMaxHealth");
	if (curMax > g_iClientMaxHp[victim]) g_iClientMaxHp[victim] = curMax;
	if (remain > 0 && dmgHealth >= 0) preHp = remain + dmgHealth;
	else if (preHp <= 0) preHp = g_iClientMaxHp[victim];
	int maxHp = g_iClientMaxHp[victim] > 0 ? g_iClientMaxHp[victim] : preHp;
	bool killed = remain <= 0;
	int effDmg = killed ? preHp : dmgHealth;
	if (preHp > 0 && effDmg > preHp) effDmg = preHp;
	int rawDmg = dmgHealth > effDmg ? dmgHealth : effDmg;
	g_iClientLastHp[victim] = remain > 0 ? remain : 0;
	g_bClientHitOnce[victim] = true;
	g_bClientDeathCounted[victim] = killed;

	int attacker = GetClientOfUserId(event.GetInt("attacker"));
	if (!g_cvEnable.BoolValue || !g_bRoundLive || !IsValidHumanSurvivor(attacker)
		|| !PrepareSampleContext() || !HasEnoughHumanSurvivors())
	{
		return Plugin_Continue;
	}
	int damagetype = event.GetInt("type");
	bool isBullet = (damagetype & (DMG_BULLET | DMG_BUCKSHOT)) != 0;
	bool isBlast = (damagetype & DMG_BLAST) != 0;
	char wepStr[48];
	event.GetString("weapon", wepStr, sizeof(wepStr));
	int wepIdx = LookupWeaponIdx(wepStr);
	if (wepIdx < 0 || (!isBullet && !isBlast) || (isBlast && wepIdx != 18))
	{
		if (killed && zClass == TARGET_TANK) FinalizeTankFight(victim, true);
		return Plugin_Continue;
	}

	if (effDmg <= 0 && rawDmg <= 0)
	{
		return Plugin_Continue;
	}

	float posA[3], posV[3];
	GetClientAbsOrigin(attacker, posA);
	GetClientAbsOrigin(victim, posV);
	float distSq = GetVectorDistance(posA, posV, true);
	bool headshot = (event.GetInt("hitgroup") == 1);

	RecordHit(
		attacker,
		victim,
		wepIdx,
		zClass,
		distSq,
		headshot,
		rawDmg,
		effDmg,
		killed,
		preHp,
		maxHp,
		remain > 0 ? remain : 0
	);

	if (zClass == TARGET_TANK)
	{
		RecordTankFightHit(attacker, victim, wepIdx, rawDmg, effDmg, distSq);
		if (killed)
		{
			FinalizeTankFight(victim, true);
		}
	}

	return Plugin_Continue;
}

public void Event_PlayerIncap(Event event, const char[] name, bool dontBroadcast)
{
	int victim = GetClientOfUserId(event.GetInt("userid"));
	if (victim <= 0 || victim > MaxClients || !IsClientInGame(victim) || GetClientTeam(victim) != L4D2Team_Infected)
	{
		return;
	}

	if (GetEntProp(victim, Prop_Send, "m_zombieClass") != TARGET_TANK)
	{
		return;
	}

	RecordTankKillingBlow(event, victim, true);
}

public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
	int victim = GetClientOfUserId(event.GetInt("userid"));
	if (victim <= 0 || victim > MaxClients || !IsClientInGame(victim) || GetClientTeam(victim) != L4D2Team_Infected)
	{
		return;
	}
	if (GetEntProp(victim, Prop_Send, "m_zombieClass") == TARGET_TANK)
	{
		RecordTankKillingBlow(event, victim, false);
	}
	g_iClientLastHp[victim] = 0;
	g_bClientDeathCounted[victim] = true;
}

static void RecordTankKillingBlow(Event event, int victim, bool hasDamageType)
{
	int attacker = GetClientOfUserId(event.GetInt("attacker"));
	char weapon[48];
	event.GetString("weapon", weapon, sizeof(weapon));
	int wepIdx = LookupWeaponIdx(weapon);
	int type = hasDamageType ? event.GetInt("type") : (wepIdx == 18 ? DMG_BLAST : DMG_BULLET);
	bool firearm = (type & (DMG_BULLET | DMG_BUCKSHOT)) != 0 || ((type & DMG_BLAST) != 0 && wepIdx == 18);
	if (!g_bClientDeathCounted[victim] && g_iClientLastHp[victim] > 0 && wepIdx >= 0 && firearm
		&& g_cvEnable.BoolValue && g_bRoundLive && IsValidHumanSurvivor(attacker)
		&& PrepareSampleContext() && HasEnoughHumanSurvivors())
	{
		int hp = g_iClientLastHp[victim];
		float posA[3], posV[3];
		GetClientAbsOrigin(attacker, posA);
		GetClientAbsOrigin(victim, posV);
		float distSq = GetVectorDistance(posA, posV, true);
		RecordHit(attacker, victim, wepIdx, TARGET_TANK, distSq, event.GetBool("headshot"), hp, hp, true, hp, g_iClientMaxHp[victim], 0);
		RecordTankFightHit(attacker, victim, wepIdx, hp, hp, distSq);
	}
	g_iClientLastHp[victim] = 0;
	g_bClientDeathCounted[victim] = true;
	FinalizeTankFight(victim, true);
}

public Action Event_InfectedHurt(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_cvEnable.BoolValue || !g_bRoundLive || !PrepareSampleContext() || !HasEnoughHumanSurvivors())
	{
		return Plugin_Continue;
	}

	int attacker = GetClientOfUserId(event.GetInt("attacker"));
	if (!IsValidHumanSurvivor(attacker))
	{
		return Plugin_Continue;
	}

	int damagetype = event.GetInt("type");
	bool isBullet = (damagetype & (DMG_BULLET | DMG_BUCKSHOT)) != 0;
	bool isBlast = (damagetype & DMG_BLAST) != 0;
	if (!isBullet && !isBlast)
	{
		return Plugin_Continue;
	}

	int victim = event.GetInt("entityid");
	if (victim <= MaxClients || victim >= MAX_TRACKED_EDICTS || !IsValidEntity(victim)) return Plugin_Continue;
	if (g_iEntityDamageAttacker[victim] != attacker || g_iEntityDamageTick[victim] != GetGameTickCount()) return Plugin_Continue;
	int preHp = g_iEntityPreHp[victim];
	g_iEntityPreHp[victim] = 0;
	if (preHp <= 0) return Plugin_Continue;

	int wepIdx = -1;
	if (isBullet)
	{
		wepIdx = GetClientActiveWeaponIdxCached(attacker);
		if (wepIdx == 18)
		{
			wepIdx = -1;
		}
	}
	else if (isBlast && g_bEntityDamageIsGL[victim])
	{
		wepIdx = 18;
	}

	if (wepIdx < 0)
	{
		return Plugin_Continue;
	}

	int rawDmg = event.GetInt("amount");
	if (rawDmg <= 0)
	{
		return Plugin_Continue;
	}

	bool isWitch = g_bEntityIsWitch[victim];
	int targetClass = isWitch ? TARGET_WITCH : TARGET_COMMON;
	int maxHp = isWitch ? GetEntProp(victim, Prop_Data, "m_iMaxHealth") : preHp;
	if (maxHp < preHp)
	{
		maxHp = preHp;
	}

	int effDmg = (rawDmg > preHp) ? preHp : rawDmg;
	int postHp = preHp - rawDmg;
	bool killed = (postHp <= 0);
	if (postHp < 0)
	{
		postHp = 0;
	}

	float posA[3], posV[3];
	GetClientAbsOrigin(attacker, posA);
	GetEntPropVector(victim, Prop_Send, "m_vecOrigin", posV);
	float distSq = GetVectorDistance(posA, posV, true);
	bool headshot = (event.GetInt("hitgroup") == 1);

	RecordHit(
		attacker,
		victim,
		wepIdx,
		targetClass,
		distSq,
		headshot,
		rawDmg,
		effDmg,
		killed,
		preHp,
		maxHp,
		postHp
	);

	return Plugin_Continue;
}

static void RecordHit(
	int attacker,
	int victim,
	int wepIdx,
	int targetClass,
	float distSq,
	bool headshot,
	int rawDmg,
	int effDmg,
	bool killed,
	int preHp,
	int maxHp,
	int postHp
)
{
	int distBucket = DistSqToBucket(distSq);
	int moveState = GetClientMoveState(attacker);
	int tier = g_iClientSkillTier[attacker];

	g_iCombatStats[wepIdx][targetClass][distBucket][moveState][tier][STAT_HITS]++;
	if (headshot)
	{
		g_iCombatStats[wepIdx][targetClass][distBucket][moveState][tier][STAT_HEADSHOTS]++;
	}
	g_iCombatStats[wepIdx][targetClass][distBucket][moveState][tier][STAT_RAW_DMG] += rawDmg;
	g_iCombatStats[wepIdx][targetClass][distBucket][moveState][tier][STAT_EFF_DMG] += effDmg;
	if (killed)
	{
		g_iCombatStats[wepIdx][targetClass][distBucket][moveState][tier][STAT_KILLS]++;
	}

	if (g_bWepIsShotgun[wepIdx])
	{
		TrackShotgunPellet(attacker, victim, wepIdx, targetClass, distBucket, moveState, tier, preHp, maxHp, postHp, killed);
	}
	else if (wepIdx != 18) // 非榴弹枪械：统计单发穿射收益与单发秒杀阈值
	{
		if (g_iBulletHitTargetsInSeq[attacker] == 0)
		{
			g_iCombatStats[wepIdx][targetClass][distBucket][moveState][tier][STAT_SHOT_BURSTS]++;
		}
		else
		{
			g_iCombatStats[wepIdx][targetClass][distBucket][moveState][tier][STAT_COLLATERAL_HITS]++;
		}
		g_iBulletHitTargetsInSeq[attacker]++;

		if (targetClass >= TARGET_SMOKER && targetClass <= TARGET_WITCH && maxHp > 0 && preHp * 100 >= maxHp * 90)
		{
			if (killed)
			{
				g_iCombatStats[wepIdx][targetClass][distBucket][moveState][tier][STAT_ONE_SHOT_KILLS]++;
			}
			else if (postHp >= 1 && postHp <= 15)
			{
				g_iCombatStats[wepIdx][targetClass][distBucket][moveState][tier][STAT_NEAR_KILL_MISSES]++;
			}
		}
	}
	else
	{
		// 榴弹炮：每次直击或溅射单独计一次命中，避免将穿射误计入霰弹簇
		g_iCombatStats[wepIdx][targetClass][distBucket][moveState][tier][STAT_SHOT_BURSTS]++;
	}

	g_bDirtyCombat = true;
}

static void TrackShotgunPellet(
	int attacker,
	int victim,
	int wepIdx,
	int targetClass,
	int distBucket,
	int moveState,
	int tier,
	int preHp,
	int maxHp,
	int postHp,
	bool killed
)
{
	if (g_SgCount[attacker] == 0)
	{
		g_SgWepIdx[attacker] = wepIdx;
		g_SgMove[attacker] = moveState;
		g_SgTier[attacker] = tier;
	}
	else if (g_SgWepIdx[attacker] != wepIdx)
	{
		FlushClientShotgunBurst(attacker);
		g_SgWepIdx[attacker] = wepIdx;
		g_SgMove[attacker] = moveState;
		g_SgTier[attacker] = tier;
	}

	int count = g_SgCount[attacker];
	for (int i = 0; i < count; i++)
	{
		if (g_SgTargetEnt[attacker][i] == victim)
		{
			g_SgTargetPostHp[attacker][i] = postHp;
			if (killed)
			{
				g_SgTargetKilled[attacker][i] = true;
			}
			return;
		}
	}

	// 去重不依赖阈值槽容量；普通小僵尸不占用特感/女巫阈值槽。
	if (victim <= 0 || victim >= MAX_TRACKED_EDICTS || g_iLastSgShot[victim] == g_iShotSeq[attacker]) return;
	g_iLastSgShot[victim] = g_iShotSeq[attacker];
	g_iCombatStats[wepIdx][targetClass][distBucket][moveState][tier][STAT_SHOT_BURSTS]++;
	if (targetClass < TARGET_SMOKER || targetClass > TARGET_WITCH) return;

	if (count < MAX_SG_TRACKED)
	{
		g_SgTargetEnt[attacker][count] = victim;
		g_SgTargetClass[attacker][count] = targetClass;
		g_SgTargetDist[attacker][count] = distBucket;
		g_SgTargetPreHp[attacker][count] = preHp;
		g_SgTargetMaxHp[attacker][count] = maxHp;
		g_SgTargetPostHp[attacker][count] = postHp;
		g_SgTargetKilled[attacker][count] = killed;
		g_SgCount[attacker] = count + 1;

		if (!g_SgFlushPending[attacker])
		{
			g_SgFlushPending[attacker] = true;
			RequestFrame(Frame_FlushShotgunBurst, GetClientUserId(attacker));
		}
	}
}

public void Frame_FlushShotgunBurst(int userid)
{
	int client = GetClientOfUserId(userid);
	if (client <= 0 || client > MaxClients)
	{
		return;
	}
	FlushClientShotgunBurst(client);
}

static void FlushClientShotgunBurst(int client)
{
	if (client <= 0 || client > MaxClients)
	{
		return;
	}

	int count = g_SgCount[client];
	g_SgFlushPending[client] = false;
	if (count <= 0)
	{
		g_SgCount[client] = 0;
		return;
	}

	int wepIdx = g_SgWepIdx[client];
	int moveState = g_SgMove[client];
	int tier = g_SgTier[client];

	for (int i = 0; i < count; i++)
	{
		int targetClass = g_SgTargetClass[client][i];
		if (targetClass < TARGET_SMOKER || targetClass > TARGET_WITCH)
		{
			continue;
		}

		int maxHp = g_SgTargetMaxHp[client][i];
		int preHp = g_SgTargetPreHp[client][i];
		if (maxHp <= 0 || preHp * 100 < maxHp * 90)
		{
			continue;
		}

		int distBucket = g_SgTargetDist[client][i];
		if (g_SgTargetKilled[client][i])
		{
			g_iCombatStats[wepIdx][targetClass][distBucket][moveState][tier][STAT_ONE_SHOT_KILLS]++;
			g_bDirtyCombat = true;
		}
		else if (g_SgTargetPostHp[client][i] >= 1 && g_SgTargetPostHp[client][i] <= 15)
		{
			g_iCombatStats[wepIdx][targetClass][distBucket][moveState][tier][STAT_NEAR_KILL_MISSES]++;
			g_bDirtyCombat = true;
		}
	}

	g_SgCount[client] = 0;
}

static void SnapshotTankFightContext(int tank)
{
	strcopy(g_TankFight[tank].rulesetKey, sizeof(g_TankFight[].rulesetKey), g_sActiveRuleset);
	strcopy(g_TankFight[tank].anneVersion, sizeof(g_TankFight[].anneVersion), g_sActiveAnneVersion);
	strcopy(g_TankFight[tank].difficultyType, sizeof(g_TankFight[].difficultyType), g_sActiveDifficultyType);
	g_TankFight[tank].difficulty = g_iActiveDifficulty;
	g_TankFight[tank].siCount = g_iActiveSiCount;
	g_TankFight[tank].siSpawnTime = g_iActiveSiSpawnTime;
	strcopy(g_TankFight[tank].weaponConfig, sizeof(g_TankFight[].weaponConfig), g_sActiveWeaponConfig);
	strcopy(g_TankFight[tank].configHash, sizeof(g_TankFight[].configHash), g_sActiveConfigHash);
}

static void StartTankFight(int tank, int maxHp)
{
	ResetTankFightSlot(tank);
	g_TankFight[tank].active = true;
	g_TankFight[tank].maxHp = maxHp;
	SnapshotTankFightContext(tank);
}

static void RecordTankFightHit(int attacker, int tank, int wepIdx, int rawDmg, int effDmg, float distSq)
{
	if (!g_TankFight[tank].active)
	{
		StartTankFight(tank, g_iClientMaxHp[tank]);
	}
	if (!g_TankFight[tank].engaged)
	{
		if (g_bLightRefreshPending)
		{
			RefreshLightContext();
		}
		g_TankFight[tank].engaged = true;
		g_TankFight[tank].startTime = GetGameTime();
		SnapshotTankFightContext(tank);
	}
	if (g_iClientMaxHp[tank] > g_TankFight[tank].maxHp)
	{
		g_TankFight[tank].maxHp = g_iClientMaxHp[tank];
	}

	if (attacker >= 1 && attacker <= 31)
	{
		g_TankFight[tank].shooterMask |= (1 << (attacker - 1));
	}
	g_TankFight[tank].rawDmg[wepIdx] += rawDmg;
	g_TankFight[tank].effDmg[wepIdx] += effDmg;
	g_TankFight[tank].hits[wepIdx]++;
	g_TankFight[tank].distSum[wepIdx] += RoundToNearest(SquareRoot(distSq));
}

static void RecordTankFightShot(int attacker, int wepIdx)
{
	if (attacker < 1 || attacker > 31)
	{
		return;
	}

	int bit = (1 << (attacker - 1));
	int fallbackTank = -1;
	for (int t = 1; t <= MaxClients; t++)
	{
		if (!g_TankFight[t].active || !g_TankFight[t].engaged)
		{
			continue;
		}
		if ((g_TankFight[t].shooterMask & bit) != 0)
		{
			g_TankFight[t].shots[wepIdx]++;
			return;
		}
		if (fallbackTank == -1)
		{
			fallbackTank = t;
		}
	}

	if (fallbackTank != -1)
	{
		g_TankFight[fallbackTank].shots[wepIdx]++;
	}
}

static void FinalizeTankFight(int tank, bool killed)
{
	if (!g_TankFight[tank].active || !g_TankFight[tank].engaged)
	{
		ResetTankFightSlot(tank);
		return;
	}

	int durationMs = RoundToNearest((GetGameTime() - g_TankFight[tank].startTime) * 1000.0);
	if (durationMs < 100)
	{
		durationMs = 100;
	}

	int shooterCount = CountBits(g_TankFight[tank].shooterMask);
	if (shooterCount < 1)
	{
		shooterCount = 1;
	}

	int now = GetTime();
	int statDate = GetStatDateInt(now);
	char fightId[40];
	FormatEx(fightId, sizeof(fightId), "%s_%d", g_sSessionId, ++g_iTankFightSerial);

	for (int w = 0; w < WEP_COUNT; w++)
	{
		if (g_TankFight[tank].effDmg[w] <= 0 && g_TankFight[tank].shots[w] <= 0)
		{
			continue;
		}

		PendingTankFight item;
		strcopy(item.fightId, sizeof(item.fightId), fightId);
		item.statDate = statDate;
		item.createdAt = now;
		bool hasSnapshot = (g_TankFight[tank].rulesetKey[0] != '\0');
		strcopy(item.rulesetKey, sizeof(item.rulesetKey), hasSnapshot ? g_TankFight[tank].rulesetKey : g_sActiveRuleset);
		strcopy(item.anneVersion, sizeof(item.anneVersion), hasSnapshot ? g_TankFight[tank].anneVersion : g_sActiveAnneVersion);
		strcopy(item.difficultyType, sizeof(item.difficultyType), g_TankFight[tank].difficultyType[0] != '\0' ? g_TankFight[tank].difficultyType : g_sActiveDifficultyType);
		item.difficulty = g_TankFight[tank].difficulty;
		item.siCount = g_TankFight[tank].siCount;
		item.siSpawnTime = g_TankFight[tank].siSpawnTime;
		strcopy(item.weaponConfig, sizeof(item.weaponConfig), g_TankFight[tank].weaponConfig[0] != '\0' ? g_TankFight[tank].weaponConfig : g_sActiveWeaponConfig);
		strcopy(item.configHash, sizeof(item.configHash), g_TankFight[tank].configHash[0] != '\0' ? g_TankFight[tank].configHash : g_sActiveConfigHash);
		strcopy(item.mapName, sizeof(item.mapName), g_sCurrentMap);
		item.tankMaxHp = g_TankFight[tank].maxHp;
		item.durationMs = durationMs;
		item.shooterCount = shooterCount;
		item.killed = killed ? 1 : 0;
		item.weaponIdx = w;
		item.rawDmg = g_TankFight[tank].rawDmg[w];
		item.effDmg = g_TankFight[tank].effDmg[w];
		item.hits = g_TankFight[tank].hits[w];
		item.shots = g_TankFight[tank].shots[w];
		item.distSum = g_TankFight[tank].distSum[w];

		g_hPendingTanks.PushArray(item, sizeof(item));
	}

	ResetTankFightSlot(tank);
}

static void FinalizeActiveTankFights(bool killed)
{
	for (int t = 1; t <= MaxClients; t++)
	{
		if (g_TankFight[t].active)
		{
			FinalizeTankFight(t, killed);
		}
	}
}

static void ResetAllTankFights()
{
	for (int t = 1; t <= MaxClients; t++)
	{
		ResetTankFightSlot(t);
	}
}

static void ResetTankFightSlot(int tank)
{
	g_TankFight[tank].active = false;
	g_TankFight[tank].engaged = false;
	g_TankFight[tank].maxHp = 0;
	g_TankFight[tank].startTime = 0.0;
	g_TankFight[tank].shooterMask = 0;
	g_TankFight[tank].rulesetKey[0] = '\0';
	g_TankFight[tank].anneVersion[0] = '\0';
	g_TankFight[tank].difficultyType[0] = '\0';
	g_TankFight[tank].difficulty = 0;
	g_TankFight[tank].siCount = 0;
	g_TankFight[tank].siSpawnTime = 0;
	g_TankFight[tank].weaponConfig[0] = '\0';
	g_TankFight[tank].configHash[0] = '\0';
	for (int w = 0; w < WEP_COUNT; w++)
	{
		g_TankFight[tank].rawDmg[w] = 0;
		g_TankFight[tank].effDmg[w] = 0;
		g_TankFight[tank].hits[w] = 0;
		g_TankFight[tank].shots[w] = 0;
		g_TankFight[tank].distSum[w] = 0;
	}
}

// ---------------------------------------------------------------------------
// 配置快照与版本指纹（区分同一模式下的不同调参版本）
// ---------------------------------------------------------------------------

static bool PrepareSampleContext()
{
	if ((g_bFullRefreshPending || g_bLightRefreshPending) && HasDirtyStats() && !g_bSchemaReady) return false;
	if (g_bFullRefreshPending) RefreshWeaponConfigSnapshot();
	else if (g_bLightRefreshPending) RefreshLightContext();
	return !g_bLightRefreshPending && !g_bFullRefreshPending;
}

static void RefreshLightContext()
{
	RefreshCvarHandles();

	char newRuleset[64];
	DetectRulesetKey(newRuleset, sizeof(newRuleset));

	char newAnneVer[64];
	DetectAnneVersion(newRuleset, newAnneVer, sizeof(newAnneVer));

	char newDiffType[16];
	int newDifficulty = DetectDifficulty(newRuleset, newDiffType, sizeof(newDiffType));

	int newSiCount = 0;
	int newSiSpawnTime = 0;
	DetectSIConfig(newSiCount, newSiSpawnTime);

	bool changed = (g_sActiveConfigHash[0] != '\0') && (
		!StrEqual(g_sActiveRuleset, newRuleset, false)
		|| !StrEqual(g_sActiveAnneVersion, newAnneVer, false)
		|| !StrEqual(g_sActiveDifficultyType, newDiffType, false)
		|| g_iActiveDifficulty != newDifficulty
		|| g_iActiveSiCount != newSiCount
		|| g_iActiveSiSpawnTime != newSiSpawnTime
	);

	if (changed && !FlushAllStatsToDb())
	{
		g_bLightRefreshPending = true;
		return;
	}
	g_bLightRefreshPending = false;

	bool anneVerChanged = !StrEqual(g_sActiveAnneVersion, newAnneVer, false);
	strcopy(g_sActiveRuleset, sizeof(g_sActiveRuleset), newRuleset);
	strcopy(g_sActiveAnneVersion, sizeof(g_sActiveAnneVersion), newAnneVer);
	strcopy(g_sActiveDifficultyType, sizeof(g_sActiveDifficultyType), newDiffType);
	g_iActiveDifficulty = newDifficulty;
	g_iActiveSiCount = newSiCount;
	g_iActiveSiSpawnTime = newSiSpawnTime;

	if (anneVerChanged && g_sActiveConfigHash[0] != '\0')
	{
		g_bConfigPendingUpload = true;
		UploadConfigSnapshotIfReady();
	}
}

static void RefreshWeaponConfigSnapshot()
{
	RefreshCvarHandles();

	char newRuleset[64];
	DetectRulesetKey(newRuleset, sizeof(newRuleset));

	char newAnneVer[64];
	DetectAnneVersion(newRuleset, newAnneVer, sizeof(newAnneVer));

	char newDiffType[16];
	int newDifficulty = DetectDifficulty(newRuleset, newDiffType, sizeof(newDiffType));

	int newSiCount = 0;
	int newSiSpawnTime = 0;
	DetectSIConfig(newSiCount, newSiSpawnTime);

	char newWeaponConfig[64];
	if (g_cvWeaponConfig != null)
	{
		g_cvWeaponConfig.GetString(newWeaponConfig, sizeof(newWeaponConfig));
		TrimString(newWeaponConfig);
	}
	else
	{
		newWeaponConfig[0] = '\0';
	}
	if (newWeaponConfig[0] == '\0')
	{
		strcopy(newWeaponConfig, sizeof(newWeaponConfig), "default");
	}

	int sgCenter = g_cvSgCenterPellet != null ? g_cvSgCenterPellet.IntValue : -1;
	int sgRing1 = g_cvSgRing1Bullets != null ? g_cvSgRing1Bullets.IntValue : -1;
	float sgFactor = g_cvSgRing1Factor != null ? g_cvSgRing1Factor.FloatValue : -1.0;

	char attrsJson[12288];
	BuildWeaponAttrsJson(attrsJson, sizeof(attrsJson));

	char newHash[24];
	ComputeConfigHash(newWeaponConfig, sgCenter, sgRing1, sgFactor, attrsJson, newHash, sizeof(newHash));

	bool changed = (g_sActiveConfigHash[0] != '\0') && (
		!StrEqual(g_sActiveConfigHash, newHash, false)
		|| !StrEqual(g_sActiveRuleset, newRuleset, false)
		|| !StrEqual(g_sActiveAnneVersion, newAnneVer, false)
		|| !StrEqual(g_sActiveDifficultyType, newDiffType, false)
		|| g_iActiveDifficulty != newDifficulty
		|| g_iActiveSiCount != newSiCount
		|| g_iActiveSiSpawnTime != newSiSpawnTime
	);

	if (changed && !FlushAllStatsToDb())
	{
		g_bFullRefreshPending = true;
		return;
	}
	g_bLightRefreshPending = false;
	g_bFullRefreshPending = false;

	strcopy(g_sActiveRuleset, sizeof(g_sActiveRuleset), newRuleset);
	strcopy(g_sActiveDifficultyType, sizeof(g_sActiveDifficultyType), newDiffType);
	g_iActiveDifficulty = newDifficulty;
	g_iActiveSiCount = newSiCount;
	g_iActiveSiSpawnTime = newSiSpawnTime;
	strcopy(g_sActiveWeaponConfig, sizeof(g_sActiveWeaponConfig), newWeaponConfig);
	strcopy(g_sActiveAnneVersion, sizeof(g_sActiveAnneVersion), newAnneVer);
	strcopy(g_sActiveConfigHash, sizeof(g_sActiveConfigHash), newHash);
	strcopy(g_sActiveAttrsJson, sizeof(g_sActiveAttrsJson), attrsJson);
	g_iActiveSgCenter = sgCenter;
	g_iActiveSgRing1 = sgRing1;
	g_fActiveSgFactor = sgFactor;
	g_bConfigPendingUpload = true;

	UploadConfigSnapshotIfReady();
}

public void OnLightContextCvarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	if (StrEqual(oldValue, newValue, false))
	{
		return;
	}
	g_bLightRefreshPending = true;
	if (!g_bLightRefreshQueued)
	{
		g_bLightRefreshQueued = true;
		RequestFrame(Frame_RefreshLightContext);
	}
}

public void Frame_RefreshLightContext(any data)
{
	g_bLightRefreshQueued = false;
	if (g_bLightRefreshPending)
	{
		RefreshLightContext();
	}
}

public void OnFullConfigCvarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	if (StrEqual(oldValue, newValue, false))
	{
		return;
	}
	g_bFullRefreshPending = true;
	delete g_hFullRefreshTimer;
	g_hFullRefreshTimer = CreateTimer(0.2, Timer_DeferredFullRefresh, _, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_DeferredFullRefresh(Handle timer)
{
	g_hFullRefreshTimer = null;
	RefreshWeaponConfigSnapshot();
	return Plugin_Stop;
}

static void BuildWeaponAttrsJson(char[] out, int maxlen)
{
	bool hasWA = LibraryExists("l4d2_weapon_attributes")
		&& GetFeatureStatus(FeatureType_Native, "L4D2WA_GetWeaponTankDamageMult") == FeatureStatus_Available
		&& GetFeatureStatus(FeatureType_Native, "L4D2WA_GetWeaponReloadDurationMult") == FeatureStatus_Available;

	int len = 0;
	len += FormatEx(out[len], maxlen - len, "{");

	bool firstItem = true;
	for (int i = 0; i < WEP_COUNT; i++)
	{
		if (len >= maxlen - 512)
		{
			break;
		}
		char fullName[48];
		strcopy(fullName, sizeof(fullName), WeaponNames[g_iTrackedWepIds[i]]);
		if (!L4D2_IsValidWeapon(fullName))
		{
			g_iWepBullets[i] = 1;
			continue;
		}

		int damage = L4D2_GetIntWeaponAttribute(fullName, L4D2IWA_Damage);
		int bullets = L4D2_GetIntWeaponAttribute(fullName, L4D2IWA_Bullets);
		if (bullets < 1)
		{
			bullets = 1;
		}
		g_iWepBullets[i] = g_bWepIsShotgun[i] ? bullets : 1;

		int clipsize = L4D2_GetIntWeaponAttribute(fullName, L4D2IWA_ClipSize);
		int defclip = L4D2_GetIntWeaponAttribute(fullName, L4D2IWA_DefaultSize);
		float range = L4D2_GetFloatWeaponAttribute(fullName, L4D2FWA_Range);
		float rangemod = L4D2_GetFloatWeaponAttribute(fullName, L4D2FWA_RangeModifier);
		float gainrange = L4D2_GetFloatWeaponAttribute(fullName, L4D2FWA_GainRange);
		float cycletime = L4D2_GetFloatWeaponAttribute(fullName, L4D2FWA_CycleTime);
		float reloaddur = L4D2_GetFloatWeaponAttribute(fullName, L4D2FWA_ReloadDuration);
		float minstand = L4D2_GetFloatWeaponAttribute(fullName, L4D2FWA_MinStandingSpread);
		float minduck = L4D2_GetFloatWeaponAttribute(fullName, L4D2FWA_MinDuckingSpread);
		float maxmove = L4D2_GetFloatWeaponAttribute(fullName, L4D2FWA_MaxMovementSpread);
		float pershot = L4D2_GetFloatWeaponAttribute(fullName, L4D2FWA_SpreadPerShot);
		float decay = L4D2_GetFloatWeaponAttribute(fullName, L4D2FWA_SpreadDecay);
		float maxspread = L4D2_GetFloatWeaponAttribute(fullName, L4D2FWA_MaxSpread);
		float penlayers = L4D2_GetFloatWeaponAttribute(fullName, L4D2FWA_PenetrationNumLayers);
		float penpower = L4D2_GetFloatWeaponAttribute(fullName, L4D2FWA_PenetrationPower);
		float charpen = L4D2_GetFloatWeaponAttribute(fullName, L4D2FWA_CharPenetrationMaxDist);
		float pitch = L4D2_GetFloatWeaponAttribute(fullName, L4D2FWA_PelletScatterPitch);
		float yaw = L4D2_GetFloatWeaponAttribute(fullName, L4D2FWA_PelletScatterYaw);

		float tankMult = hasWA ? L4D2WA_GetWeaponTankDamageMult(g_sWeaponKeys[i]) : 1.0;
		float reloadMult = (hasWA && g_bWepIsShotgun[i]) ? L4D2WA_GetWeaponReloadDurationMult(g_sWeaponKeys[i]) : 1.0;

		len += FormatEx(out[len], maxlen - len,
			"%s\"%s\":{\"damage\":%d,\"bullets\":%d,\"clipsize\":%d,\"defclip\":%d,"
			... "\"range\":%.1f,\"rangemod\":%.4f,\"gainrange\":%.1f,\"cycletime\":%.4f,"
			... "\"reloadduration\":%.3f,\"reloaddurationmult\":%.3f,"
			... "\"minstandspread\":%.3f,\"minduckspread\":%.3f,\"maxmovespread\":%.3f,"
			... "\"spreadpershot\":%.3f,\"spreaddecay\":%.2f,\"maxspread\":%.2f,"
			... "\"penlayers\":%.0f,\"penpower\":%.1f,\"charpenmaxdist\":%.1f,"
			... "\"scatterpitch\":%.3f,\"scatteryaw\":%.3f,\"tankdamagemult\":%.3f}",
			firstItem ? "" : ",",
			g_sWeaponKeys[i],
			damage, bullets, clipsize, defclip,
			range, rangemod, gainrange, cycletime,
			reloaddur, reloadMult,
			minstand, minduck, maxmove,
			pershot, decay, maxspread,
			penlayers, penpower, charpen,
			pitch, yaw, tankMult
		);
		firstItem = false;
	}

	FormatEx(out[len], maxlen - len, "}");
}

static void ComputeConfigHash(
	const char[] weaponConfig,
	int sgCenter,
	int sgRing1,
	float sgFactor,
	const char[] attrsJson,
	char[] out,
	int maxlen
)
{
	char header[160];
	FormatEx(header, sizeof(header), "%s|%d|%d|%.2f|", weaponConfig, sgCenter, sgRing1, sgFactor);

	int h1 = 0x811c9dc5;
	int h2 = 0x9e3779b9;
	FnvMixString(header, h1, h2);
	FnvMixString(attrsJson, h1, h2);
	FormatEx(out, maxlen, "%08x%08x", h1, h2);
}

static void FnvMixString(const char[] s, int &h1, int &h2)
{
	for (int i = 0; s[i] != '\0'; i++)
	{
		int c = s[i] & 0xFF;
		h1 ^= c;
		h1 *= 16777619;
		h2 ^= (c + i);
		h2 = (h2 * 16777619) ^ ((h2 >>> 13) & 0x7FFFF);
	}
}

static void DetectRulesetKey(char[] ruleset, int maxlen)
{
	if (g_cvStatsRuleset != null)
	{
		g_cvStatsRuleset.GetString(ruleset, maxlen);
		TrimString(ruleset);
		if (ruleset[0] != '\0')
		{
			return;
		}
	}

	char readyCfg[128];
	readyCfg[0] = '\0';
	if (g_cvReadyCfgName != null)
	{
		g_cvReadyCfgName.GetString(readyCfg, sizeof(readyCfg));
		TrimString(readyCfg);
	}

	if (readyCfg[0] != '\0')
	{
		if (StrContains(readyCfg, "AnneHappy", false) != -1)
		{
			if (StrContains(readyCfg, "Shotgun", false) != -1 || StrContains(readyCfg, "喷子", false) != -1)
			{
				strcopy(ruleset, maxlen, "anne_shotgun");
				return;
			}
			if (StrContains(readyCfg, "HardCore", false) != -1)
			{
				strcopy(ruleset, maxlen, "anne_hardcore");
				return;
			}
			strcopy(ruleset, maxlen, "annehappy");
			return;
		}
		if (StrContains(readyCfg, "WitchParty", false) != -1)
		{
			strcopy(ruleset, maxlen, "witchparty");
			return;
		}
		if (StrContains(readyCfg, "AllCharger", false) != -1)
		{
			strcopy(ruleset, maxlen, "allcharger");
			return;
		}
		if (StrContains(readyCfg, "Alone", false) != -1)
		{
			strcopy(ruleset, maxlen, "alone");
			return;
		}
		if (StrContains(readyCfg, "1vht", false) != -1 || StrContains(readyCfg, "1vHunter", false) != -1)
		{
			strcopy(ruleset, maxlen, "hunters");
			return;
		}

		NormalizeRulesetSlug(readyCfg, ruleset, maxlen);
		if (ruleset[0] != '\0')
		{
			return;
		}
	}

	char gm[32];
	gm[0] = '\0';
	if (g_cvGameMode != null)
	{
		g_cvGameMode.GetString(gm, sizeof(gm));
		TrimString(gm);
		LowerString(gm);
	}

	if (gm[0] != '\0')
	{
		if (StrEqual(gm, "teamversus", false))
		{
			strcopy(ruleset, maxlen, "legacy_versus");
		}
		else if (StrEqual(gm, "teamscavenge", false))
		{
			strcopy(ruleset, maxlen, "legacy_scavenge");
		}
		else if (StrEqual(gm, "realismversus", false) || StrEqual(gm, "teamrealismversus", false) || StrEqual(gm, "mutation12", false))
		{
			strcopy(ruleset, maxlen, "legacy_realism_versus");
		}
		else if (StrContains(gm, "mutation", false) == 0 || StrContains(gm, "community", false) == 0)
		{
			FormatEx(ruleset, maxlen, "legacy_mutation_%s", gm);
		}
		else
		{
			FormatEx(ruleset, maxlen, "legacy_%s", gm);
		}
	}
	else
	{
		strcopy(ruleset, maxlen, "legacy_unknown");
	}
}

static void NormalizeRulesetSlug(const char[] src, char[] dst, int maxlen)
{
	char tokens[16][32];
	char base[128];
	base[0] = '\0';
	int tokenCount = ExplodeString(src, " ", tokens, sizeof(tokens), sizeof(tokens[]));
	for (int t = 0; t < tokenCount; t++)
	{
		if (tokens[t][0] == '\0')
		{
			continue;
		}
		int first = tokens[t][0];
		int second = tokens[t][1];
		bool startsVersion = (first == 'v' || first == 'V') && second >= '0' && second <= '9';
		bool numericVersion = first >= '0' && first <= '9' && StrContains(tokens[t], ".", false) != -1;
		if (startsVersion || numericVersion)
		{
			break;
		}
		if (base[0] != '\0')
		{
			StrCat(base, sizeof(base), "_");
		}
		StrCat(base, sizeof(base), tokens[t]);
	}

	int out = 0;
	bool lastSep = true;
	for (int i = 0; base[i] != '\0' && out < maxlen - 1; i++)
	{
		int c = base[i];
		bool isAlpha = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
		bool isDigit = (c >= '0' && c <= '9');
		if (isAlpha || isDigit)
		{
			dst[out++] = CharToLower(c);
			lastSep = false;
		}
		else if (!lastSep)
		{
			dst[out++] = '_';
			lastSep = true;
		}
	}
	if (out > 0 && dst[out - 1] == '_')
	{
		out--;
	}
	dst[out] = '\0';
}

static bool IsAnneRulesetKey(const char[] rulesetKey)
{
	return StrEqual(rulesetKey, "annehappy", false)
		|| StrEqual(rulesetKey, "anne_hardcore", false)
		|| StrEqual(rulesetKey, "anne_shotgun", false)
		|| StrEqual(rulesetKey, "witchparty", false)
		|| StrEqual(rulesetKey, "allcharger", false)
		|| StrEqual(rulesetKey, "alone", false)
		|| StrEqual(rulesetKey, "hunters", false);
}

static bool IsAnneModeActive(const char[] rulesetKey)
{
	if (IsAnneRulesetKey(rulesetKey))
	{
		return true;
	}
	Handle hText = FindPluginByFile("optional/AnneHappy/text.smx");
	if (hText == null)
	{
		hText = FindPluginByFile("text.smx");
	}
	return hText != null && GetPluginStatus(hText) == Plugin_Running;
}

static void DetectAnneVersion(const char[] rulesetKey, char[] anneVer, int maxlen)
{
	anneVer[0] = '\0';
	if (!IsAnneModeActive(rulesetKey))
	{
		return;
	}
	if (g_cvAnneVersion != null)
	{
		g_cvAnneVersion.GetString(anneVer, maxlen);
		TrimString(anneVer);
	}
}

static bool IsPvpGamemode(const char[] gm)
{
	return StrEqual(gm, "versus", false)
		|| StrEqual(gm, "teamversus", false)
		|| StrEqual(gm, "scavenge", false)
		|| StrEqual(gm, "teamscavenge", false)
		|| StrEqual(gm, "realismversus", false)
		|| StrEqual(gm, "teamrealismversus", false)
		|| StrEqual(gm, "mutation12", false)
		|| StrEqual(gm, "mutation13", false)
		|| StrEqual(gm, "mutation15", false)
		|| StrEqual(gm, "mutation18", false)
		|| StrEqual(gm, "mutation19", false);
}

static int GetAnneAIDifficultyLevel()
{
	if (!LibraryExists("annehappy_dynamic_ai_difficulty") || (g_cvAiEnable != null && !g_cvAiEnable.BoolValue))
	{
		return 0;
	}
	if (g_cvAiCurrentLevel != null)
	{
		int lvl = g_cvAiCurrentLevel.IntValue;
		if (lvl >= 1 && lvl <= 6)
		{
			return lvl;
		}
	}
	return 0;
}

static int GetGameDifficultyLevel()
{
	if (g_cvZDifficulty == null)
	{
		return 1;
	}
	char diff[32];
	g_cvZDifficulty.GetString(diff, sizeof(diff));
	TrimString(diff);
	if (StrEqual(diff, "easy", false))
	{
		return 0;
	}
	if (StrEqual(diff, "normal", false))
	{
		return 1;
	}
	if (StrEqual(diff, "hard", false))
	{
		return 2;
	}
	if (StrEqual(diff, "impossible", false))
	{
		return 3;
	}
	return 1;
}

static int DetectDifficulty(const char[] rulesetKey, char[] diffType, int maxlen)
{
	char overrideProfile[24];
	overrideProfile[0] = '\0';
	if (g_cvDiffProfile != null)
	{
		g_cvDiffProfile.GetString(overrideProfile, sizeof(overrideProfile));
		TrimString(overrideProfile);
		LowerString(overrideProfile);
	}

	if (StrEqual(overrideProfile, "anne_ai", false))
	{
		strcopy(diffType, maxlen, "anne_ai");
		return GetAnneAIDifficultyLevel();
	}
	if (StrEqual(overrideProfile, "none", false))
	{
		strcopy(diffType, maxlen, "none");
		return 0;
	}
	if (StrEqual(overrideProfile, "game", false))
	{
		strcopy(diffType, maxlen, "game");
		return GetGameDifficultyLevel();
	}

	bool hasActiveAiPlugin = LibraryExists("annehappy_dynamic_ai_difficulty") && g_cvAiCurrentLevel != null && (g_cvAiEnable == null || g_cvAiEnable.BoolValue);
	if (IsAnneRulesetKey(rulesetKey) || hasActiveAiPlugin)
	{
		strcopy(diffType, maxlen, "anne_ai");
		return GetAnneAIDifficultyLevel();
	}

	char gm[32];
	gm[0] = '\0';
	if (g_cvGameMode != null)
	{
		g_cvGameMode.GetString(gm, sizeof(gm));
		TrimString(gm);
	}
	if (IsPvpGamemode(gm))
	{
		strcopy(diffType, maxlen, "none");
		return 0;
	}

	strcopy(diffType, maxlen, "game");
	return GetGameDifficultyLevel();
}

static void DetectSIConfig(int &siCount, int &siSpawnTime)
{
	if (g_cvInfectedLimit != null)
	{
		int limit = g_cvInfectedLimit.IntValue;
		if (limit < 0) limit = 0;
		if (limit > 255) limit = 255;
		siCount = limit;

		int interval = g_cvSiSpawnInterval != null ? g_cvSiSpawnInterval.IntValue : 0;
		if (interval < 0) interval = 0;
		if (interval > 65535) interval = 65535;
		siSpawnTime = interval;
	}
	else
	{
		siCount = 0;
		siSpawnTime = 0;
	}
}

// ---------------------------------------------------------------------------
// 数据库连接、建表与异步事务落库（全部走 anne_db 共享连接池）
// ---------------------------------------------------------------------------

static void EnsureDbConnected()
{
	if (g_hDb != null || g_bDbConnecting)
	{
		return;
	}

	float now = GetEngineTime();
	if (now < g_fNextDbRetry)
	{
		return;
	}

	char conf[64];
	g_cvDbConf.GetString(conf, sizeof(conf));
	TrimString(conf);
	if (conf[0] == '\0')
	{
		strcopy(conf, sizeof(conf), "l4dstats");
	}

	if (!SQL_CheckConfig(conf))
	{
		LogError("[WeaponBalanceStats] databases.cfg 缺少配置段 \"%s\"。", conf);
		g_fNextDbRetry = now + 60.0;
		return;
	}

	g_cvDbPrefix.GetString(g_sDbPrefix, sizeof(g_sDbPrefix));
	TrimString(g_sDbPrefix);

	g_bDbConnecting = true;
	g_iDbGen++;
	AnneDB_ConnectCompat(OnDbConnected, conf, g_iDbGen, AnneDBLane_Shared);
}

public void OnDbConnected(Database db, const char[] error, any data)
{
	if (view_as<int>(data) != g_iDbGen)
	{
		if (db != null)
		{
			delete db;
		}
		return;
	}

	g_bDbConnecting = false;
	if (db == null || error[0] != '\0')
	{
		delete db;
		LogError("[WeaponBalanceStats] 数据库连接失败: %s", error);
		g_fNextDbRetry = GetEngineTime() + 30.0;
		return;
	}

	char driver[16];
	db.Driver.GetIdentifier(driver, sizeof(driver));
	if (!StrEqual(driver, "mysql", false))
	{
		LogError("[WeaponBalanceStats] 仅支持 MySQL，当前驱动为 \"%s\"。", driver);
		delete db;
		g_fNextDbRetry = GetEngineTime() + 120.0;
		return;
	}

	if (g_hDb != null)
	{
		delete g_hDb;
	}
	g_hDb = db;
	AnneDB_SetCharsetIfOwned(g_hDb, "utf8mb4");

	EnsureSchema();
}

static void EnsureSchema()
{
	if (g_hDb == null || g_bSchemaReady || g_bSchemaCreating || GetEngineTime() < g_fNextDbRetry)
	{
		return;
	}

	g_bSchemaCreating = true;
	Transaction txn = new Transaction();
	char query[2048];

	FormatEx(query, sizeof(query),
		"CREATE TABLE IF NOT EXISTS `%sweapon_balance_configs` ("
		... "`config_hash` char(16) CHARACTER SET ascii NOT NULL,"
		... "`weapon_config` varchar(64) NOT NULL DEFAULT '',"
		... "`anne_version` varchar(64) NOT NULL DEFAULT '',"
		... "`ruleset_key` varchar(64) CHARACTER SET ascii NOT NULL DEFAULT '',"
		... "`sg_center_pellet` tinyint NOT NULL DEFAULT -1,"
		... "`sg_ring1_bullets` smallint NOT NULL DEFAULT -1,"
		... "`sg_ring1_factor` decimal(6,2) NOT NULL DEFAULT -1.00,"
		... "`attrs_json` mediumtext NOT NULL,"
		... "`first_seen` int unsigned NOT NULL DEFAULT 0,"
		... "`last_seen` int unsigned NOT NULL DEFAULT 0,"
		... "PRIMARY KEY (`config_hash`),"
		... "KEY `idx_wbc_lookup` (`ruleset_key`,`weapon_config`,`last_seen`)"
		... ") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4",
		g_sDbPrefix);
	txn.AddQuery(query);

	FormatEx(query, sizeof(query),
		"CREATE TABLE IF NOT EXISTS `%sweapon_balance_daily` ("
		... "`stat_date` int unsigned NOT NULL,"
		... "`ruleset_key` varchar(64) CHARACTER SET ascii NOT NULL,"
		... "`anne_version` varchar(64) NOT NULL DEFAULT '',"
		... "`difficulty_type` varchar(16) CHARACTER SET ascii NOT NULL DEFAULT 'unknown',"
		... "`difficulty` tinyint unsigned NOT NULL DEFAULT 0,"
		... "`si_count` smallint unsigned NOT NULL DEFAULT 0,"
		... "`si_spawn_time` smallint unsigned NOT NULL DEFAULT 0,"
		... "`weapon_config` varchar(64) NOT NULL DEFAULT '',"
		... "`config_hash` char(16) CHARACTER SET ascii NOT NULL,"
		... "`weapon_key` varchar(32) CHARACTER SET ascii NOT NULL,"
		... "`target_class` tinyint unsigned NOT NULL,"
		... "`dist_bucket` tinyint unsigned NOT NULL,"
		... "`move_state` tinyint unsigned NOT NULL,"
		... "`skill_tier` tinyint unsigned NOT NULL,"
		... "`hits` int unsigned NOT NULL DEFAULT 0,"
		... "`headshots` int unsigned NOT NULL DEFAULT 0,"
		... "`raw_damage` bigint unsigned NOT NULL DEFAULT 0,"
		... "`effective_damage` bigint unsigned NOT NULL DEFAULT 0,"
		... "`kills` int unsigned NOT NULL DEFAULT 0,"
		... "`shot_bursts` int unsigned NOT NULL DEFAULT 0,"
		... "`one_shot_kills` int unsigned NOT NULL DEFAULT 0,"
		... "`near_kill_misses` int unsigned NOT NULL DEFAULT 0,"
		... "`collateral_hits` int unsigned NOT NULL DEFAULT 0,"
		... "PRIMARY KEY (`stat_date`,`ruleset_key`,`anne_version`,`difficulty_type`,`difficulty`,`si_count`,`si_spawn_time`,`weapon_config`,`config_hash`,`weapon_key`,`target_class`,`dist_bucket`,`move_state`,`skill_tier`),"
		... "KEY `idx_wbd_config_date` (`config_hash`,`stat_date`),"
		... "KEY `idx_wbd_ruleset_date` (`ruleset_key`,`weapon_config`,`stat_date`),"
		... "KEY `idx_wbd_mode_diff` (`ruleset_key`,`anne_version`,`difficulty_type`,`difficulty`,`si_count`,`si_spawn_time`,`stat_date`)"
		... ") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4",
		g_sDbPrefix);
	txn.AddQuery(query);

	FormatEx(query, sizeof(query),
		"CREATE TABLE IF NOT EXISTS `%sweapon_balance_usage_daily` ("
		... "`stat_date` int unsigned NOT NULL,"
		... "`ruleset_key` varchar(64) CHARACTER SET ascii NOT NULL,"
		... "`anne_version` varchar(64) NOT NULL DEFAULT '',"
		... "`difficulty_type` varchar(16) CHARACTER SET ascii NOT NULL DEFAULT 'unknown',"
		... "`difficulty` tinyint unsigned NOT NULL DEFAULT 0,"
		... "`si_count` smallint unsigned NOT NULL DEFAULT 0,"
		... "`si_spawn_time` smallint unsigned NOT NULL DEFAULT 0,"
		... "`weapon_config` varchar(64) NOT NULL DEFAULT '',"
		... "`config_hash` char(16) CHARACTER SET ascii NOT NULL,"
		... "`weapon_key` varchar(32) CHARACTER SET ascii NOT NULL,"
		... "`move_state` tinyint unsigned NOT NULL,"
		... "`skill_tier` tinyint unsigned NOT NULL,"
		... "`shots_fired` int unsigned NOT NULL DEFAULT 0,"
		... "`pellets_fired` int unsigned NOT NULL DEFAULT 0,"
		... "`reloads` int unsigned NOT NULL DEFAULT 0,"
		... "`hold_seconds` int unsigned NOT NULL DEFAULT 0,"
		... "`pickups` int unsigned NOT NULL DEFAULT 0,"
		... "`swaps_away` int unsigned NOT NULL DEFAULT 0,"
		... "PRIMARY KEY (`stat_date`,`ruleset_key`,`anne_version`,`difficulty_type`,`difficulty`,`si_count`,`si_spawn_time`,`weapon_config`,`config_hash`,`weapon_key`,`move_state`,`skill_tier`),"
		... "KEY `idx_wbud_config_date` (`config_hash`,`stat_date`),"
		... "KEY `idx_wbud_mode_diff` (`ruleset_key`,`anne_version`,`difficulty_type`,`difficulty`,`si_count`,`si_spawn_time`,`stat_date`)"
		... ") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4",
		g_sDbPrefix);
	txn.AddQuery(query);

	FormatEx(query, sizeof(query),
		"CREATE TABLE IF NOT EXISTS `%sweapon_balance_swaps_daily` ("
		... "`stat_date` int unsigned NOT NULL,"
		... "`ruleset_key` varchar(64) CHARACTER SET ascii NOT NULL,"
		... "`anne_version` varchar(64) NOT NULL DEFAULT '',"
		... "`difficulty_type` varchar(16) CHARACTER SET ascii NOT NULL DEFAULT 'unknown',"
		... "`difficulty` tinyint unsigned NOT NULL DEFAULT 0,"
		... "`si_count` smallint unsigned NOT NULL DEFAULT 0,"
		... "`si_spawn_time` smallint unsigned NOT NULL DEFAULT 0,"
		... "`weapon_config` varchar(64) NOT NULL DEFAULT '',"
		... "`config_hash` char(16) CHARACTER SET ascii NOT NULL,"
		... "`from_weapon_key` varchar(32) CHARACTER SET ascii NOT NULL,"
		... "`to_weapon_key` varchar(32) CHARACTER SET ascii NOT NULL,"
		... "`swap_count` int unsigned NOT NULL DEFAULT 0,"
		... "PRIMARY KEY (`stat_date`,`ruleset_key`,`anne_version`,`difficulty_type`,`difficulty`,`si_count`,`si_spawn_time`,`weapon_config`,`config_hash`,`from_weapon_key`,`to_weapon_key`),"
		... "KEY `idx_wbsd_mode_diff` (`ruleset_key`,`anne_version`,`difficulty_type`,`difficulty`,`si_count`,`si_spawn_time`,`stat_date`)"
		... ") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4",
		g_sDbPrefix);
	txn.AddQuery(query);

	FormatEx(query, sizeof(query),
		"CREATE TABLE IF NOT EXISTS `%sweapon_tank_fights` ("
		... "`id` bigint unsigned NOT NULL AUTO_INCREMENT,"
		... "`fight_id` varchar(40) CHARACTER SET ascii NOT NULL,"
		... "`stat_date` int unsigned NOT NULL,"
		... "`created_at` int unsigned NOT NULL,"
		... "`ruleset_key` varchar(64) CHARACTER SET ascii NOT NULL,"
		... "`anne_version` varchar(64) NOT NULL DEFAULT '',"
		... "`difficulty_type` varchar(16) CHARACTER SET ascii NOT NULL DEFAULT 'unknown',"
		... "`difficulty` tinyint unsigned NOT NULL DEFAULT 0,"
		... "`si_count` smallint unsigned NOT NULL DEFAULT 0,"
		... "`si_spawn_time` smallint unsigned NOT NULL DEFAULT 0,"
		... "`weapon_config` varchar(64) NOT NULL DEFAULT '',"
		... "`config_hash` char(16) CHARACTER SET ascii NOT NULL,"
		... "`map` varchar(64) NOT NULL DEFAULT '',"
		... "`tank_max_hp` int unsigned NOT NULL DEFAULT 0,"
		... "`duration_ms` int unsigned NOT NULL DEFAULT 0,"
		... "`shooter_count` tinyint unsigned NOT NULL DEFAULT 0,"
		... "`killed` tinyint unsigned NOT NULL DEFAULT 0,"
		... "`weapon_key` varchar(32) CHARACTER SET ascii NOT NULL,"
		... "`raw_damage` int unsigned NOT NULL DEFAULT 0,"
		... "`effective_damage` int unsigned NOT NULL DEFAULT 0,"
		... "`hits` int unsigned NOT NULL DEFAULT 0,"
		... "`shots_fired` int unsigned NOT NULL DEFAULT 0,"
		... "`dist_sum` bigint unsigned NOT NULL DEFAULT 0,"
		... "PRIMARY KEY (`id`),"
		... "KEY `idx_wtf_lookup` (`ruleset_key`,`weapon_config`,`config_hash`,`stat_date`),"
		... "KEY `idx_wtf_mode_diff` (`ruleset_key`,`anne_version`,`difficulty_type`,`difficulty`,`si_count`,`si_spawn_time`,`weapon_config`,`config_hash`,`stat_date`),"
		... "KEY `idx_wtf_fight` (`fight_id`)"
		... ") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4",
		g_sDbPrefix);
	txn.AddQuery(query);

	g_hDb.Execute(txn, OnSchemaTxnSuccess, OnSchemaTxnFailure, g_iDbGen);
}

public void OnSchemaTxnSuccess(Database db, any data, int numQueries, DBResultSet[] results, any[] queryData)
{
	if (g_hDb == null || data != g_iDbGen) return;

	char tDaily[96], tUsage[96], tSwaps[96], tTanks[96];
	FormatEx(tDaily, sizeof(tDaily), "%sweapon_balance_daily", g_sDbPrefix);
	FormatEx(tUsage, sizeof(tUsage), "%sweapon_balance_usage_daily", g_sDbPrefix);
	FormatEx(tSwaps, sizeof(tSwaps), "%sweapon_balance_swaps_daily", g_sDbPrefix);
	FormatEx(tTanks, sizeof(tTanks), "%sweapon_tank_fights", g_sDbPrefix);

	char escDaily[192], escUsage[192], escSwaps[192], escTanks[192];
	g_hDb.Escape(tDaily, escDaily, sizeof(escDaily));
	g_hDb.Escape(tUsage, escUsage, sizeof(escUsage));
	g_hDb.Escape(tSwaps, escSwaps, sizeof(escSwaps));
	g_hDb.Escape(tTanks, escTanks, sizeof(escTanks));

	char checkQuery[2048];
	FormatEx(checkQuery, sizeof(checkQuery),
		"SELECT 'col' AS kind, TABLE_NAME, COLUMN_NAME AS item_name "
		... "FROM information_schema.COLUMNS "
		... "WHERE TABLE_SCHEMA = DATABASE() "
		... "AND TABLE_NAME IN ('%s','%s','%s','%s') "
		... "AND COLUMN_NAME IN ('anne_version','difficulty_type','difficulty','si_count','si_spawn_time') "
		... "UNION ALL "
		... "SELECT 'idx' AS kind, TABLE_NAME, CONCAT(INDEX_NAME, ':', COLUMN_NAME) AS item_name "
		... "FROM information_schema.STATISTICS "
		... "WHERE TABLE_SCHEMA = DATABASE() "
		... "AND TABLE_NAME IN ('%s','%s','%s','%s') "
		... "AND ((INDEX_NAME = 'PRIMARY' AND (SEQ_IN_INDEX = 1 OR COLUMN_NAME = 'anne_version')) "
		... "OR (INDEX_NAME IN ('idx_wbd_mode_diff','idx_wbud_mode_diff','idx_wbsd_mode_diff','idx_wtf_mode_diff') "
		... "AND (SEQ_IN_INDEX = 1 OR COLUMN_NAME = 'anne_version')))",
		escDaily, escUsage, escSwaps, escTanks,
		escDaily, escUsage, escSwaps, escTanks
	);
	g_hDb.Query(OnSchemaVerifyDone, checkQuery, g_iDbGen);
}

public void OnSchemaVerifyDone(Database db, DBResultSet results, const char[] error, any data)
{
	if (g_hDb == null || data != g_iDbGen) return;

	if (results == null || error[0] != '\0')
	{
		g_bSchemaCreating = false;
		g_fNextDbRetry = GetEngineTime() + 10.0;
		LogError("[WeaponBalanceStats] 校验表结构列失败: %s", error);
		HandleDbConnectionError(error);
		return;
	}

	char tDaily[96], tUsage[96], tSwaps[96], tTanks[96];
	FormatEx(tDaily, sizeof(tDaily), "%sweapon_balance_daily", g_sDbPrefix);
	FormatEx(tUsage, sizeof(tUsage), "%sweapon_balance_usage_daily", g_sDbPrefix);
	FormatEx(tSwaps, sizeof(tSwaps), "%sweapon_balance_swaps_daily", g_sDbPrefix);
	FormatEx(tTanks, sizeof(tTanks), "%sweapon_tank_fights", g_sDbPrefix);

	int colMask[4];
	bool hasPk[4];
	bool hasNewPk[4];
	bool hasModeIdx[4];
	bool hasNewModeIdx[4];

	while (results.FetchRow())
	{
		char kind[16], tbl[96], item[96];
		results.FetchString(0, kind, sizeof(kind));
		results.FetchString(1, tbl, sizeof(tbl));
		results.FetchString(2, item, sizeof(item));

		int idx = -1;
		if (StrEqual(tbl, tDaily, false)) idx = 0;
		else if (StrEqual(tbl, tUsage, false)) idx = 1;
		else if (StrEqual(tbl, tSwaps, false)) idx = 2;
		else if (StrEqual(tbl, tTanks, false)) idx = 3;
		if (idx < 0)
		{
			continue;
		}

		if (StrEqual(kind, "col", false))
		{
			if (StrEqual(item, "difficulty_type", false)) colMask[idx] |= 1;
			else if (StrEqual(item, "difficulty", false)) colMask[idx] |= 2;
			else if (StrEqual(item, "si_count", false)) colMask[idx] |= 4;
			else if (StrEqual(item, "si_spawn_time", false)) colMask[idx] |= 8;
			else if (StrEqual(item, "anne_version", false)) colMask[idx] |= 16;
		}
		else
		{
			if (StrContains(item, "PRIMARY:", false) == 0)
			{
				hasPk[idx] = true;
				if (StrEqual(item, "PRIMARY:anne_version", false))
				{
					hasNewPk[idx] = true;
				}
			}
			else
			{
				hasModeIdx[idx] = true;
				if (StrContains(item, ":anne_version", false) != -1)
				{
					hasNewModeIdx[idx] = true;
				}
			}
		}
	}

	Transaction migrateTxn = new Transaction();
	int migrateCount = 0;

	for (int i = 0; i < 4; i++)
	{
		bool needCols = (colMask[i] != 31);
		bool needPk = (i < 3 && !hasNewPk[i]);
		bool needIdx = !hasNewModeIdx[i];
		if (!needCols && !needPk && !needIdx)
		{
			continue;
		}

		char tblName[96];
		if (i == 0) strcopy(tblName, sizeof(tblName), tDaily);
		else if (i == 1) strcopy(tblName, sizeof(tblName), tUsage);
		else if (i == 2) strcopy(tblName, sizeof(tblName), tSwaps);
		else strcopy(tblName, sizeof(tblName), tTanks);

		char alter[1536];
		int len = FormatEx(alter, sizeof(alter), "ALTER TABLE `%s` ", tblName);
		bool first = true;

		bool addedAnneCol = ((colMask[i] & 16) == 0);
		if (addedAnneCol)
		{
			len += FormatEx(alter[len], sizeof(alter) - len, "%sADD COLUMN `anne_version` varchar(64) NOT NULL DEFAULT '' AFTER `ruleset_key`", first ? "" : ", ");
			first = false;
		}
		if ((colMask[i] & 1) == 0)
		{
			len += FormatEx(alter[len], sizeof(alter) - len, "%sADD COLUMN `difficulty_type` varchar(16) CHARACTER SET ascii NOT NULL DEFAULT 'unknown' AFTER `%s`", first ? "" : ", ", addedAnneCol ? "anne_version" : "ruleset_key");
			first = false;
		}
		if ((colMask[i] & 2) == 0)
		{
			len += FormatEx(alter[len], sizeof(alter) - len, "%sADD COLUMN `difficulty` tinyint unsigned NOT NULL DEFAULT 0 AFTER `difficulty_type`", first ? "" : ", ");
			first = false;
		}
		if ((colMask[i] & 4) == 0)
		{
			len += FormatEx(alter[len], sizeof(alter) - len, "%sADD COLUMN `si_count` smallint unsigned NOT NULL DEFAULT 0 AFTER `difficulty`", first ? "" : ", ");
			first = false;
		}
		if ((colMask[i] & 8) == 0)
		{
			len += FormatEx(alter[len], sizeof(alter) - len, "%sADD COLUMN `si_spawn_time` smallint unsigned NOT NULL DEFAULT 0 AFTER `si_count`", first ? "" : ", ");
			first = false;
		}
		if (needPk)
		{
			if (hasPk[i])
			{
				len += FormatEx(alter[len], sizeof(alter) - len, "%sDROP PRIMARY KEY", first ? "" : ", ");
				first = false;
			}
			if (i == 0)
			{
				len += FormatEx(alter[len], sizeof(alter) - len, "%sADD PRIMARY KEY (`stat_date`,`ruleset_key`,`anne_version`,`difficulty_type`,`difficulty`,`si_count`,`si_spawn_time`,`weapon_config`,`config_hash`,`weapon_key`,`target_class`,`dist_bucket`,`move_state`,`skill_tier`)", first ? "" : ", ");
			}
			else if (i == 1)
			{
				len += FormatEx(alter[len], sizeof(alter) - len, "%sADD PRIMARY KEY (`stat_date`,`ruleset_key`,`anne_version`,`difficulty_type`,`difficulty`,`si_count`,`si_spawn_time`,`weapon_config`,`config_hash`,`weapon_key`,`move_state`,`skill_tier`)", first ? "" : ", ");
			}
			else
			{
				len += FormatEx(alter[len], sizeof(alter) - len, "%sADD PRIMARY KEY (`stat_date`,`ruleset_key`,`anne_version`,`difficulty_type`,`difficulty`,`si_count`,`si_spawn_time`,`weapon_config`,`config_hash`,`from_weapon_key`,`to_weapon_key`)", first ? "" : ", ");
			}
			first = false;
		}
		if (needIdx)
		{
			static const char idxNames[4][24] = {
				"idx_wbd_mode_diff",
				"idx_wbud_mode_diff",
				"idx_wbsd_mode_diff",
				"idx_wtf_mode_diff"
			};
			if (hasModeIdx[i])
			{
				len += FormatEx(alter[len], sizeof(alter) - len, "%sDROP INDEX `%s`", first ? "" : ", ", idxNames[i]);
				first = false;
			}
			if (i == 0)
				FormatEx(alter[len], sizeof(alter) - len, "%sADD KEY `idx_wbd_mode_diff` (`ruleset_key`,`anne_version`,`difficulty_type`,`difficulty`,`si_count`,`si_spawn_time`,`stat_date`)", first ? "" : ", ");
			else if (i == 1)
				FormatEx(alter[len], sizeof(alter) - len, "%sADD KEY `idx_wbud_mode_diff` (`ruleset_key`,`anne_version`,`difficulty_type`,`difficulty`,`si_count`,`si_spawn_time`,`stat_date`)", first ? "" : ", ");
			else if (i == 2)
				FormatEx(alter[len], sizeof(alter) - len, "%sADD KEY `idx_wbsd_mode_diff` (`ruleset_key`,`anne_version`,`difficulty_type`,`difficulty`,`si_count`,`si_spawn_time`,`stat_date`)", first ? "" : ", ");
			else
				FormatEx(alter[len], sizeof(alter) - len, "%sADD KEY `idx_wtf_mode_diff` (`ruleset_key`,`anne_version`,`difficulty_type`,`difficulty`,`si_count`,`si_spawn_time`,`weapon_config`,`config_hash`,`stat_date`)", first ? "" : ", ");
		}

		migrateTxn.AddQuery(alter);
		migrateCount++;
	}

	if (migrateCount == 0)
	{
		delete migrateTxn;
		g_bSchemaCreating = false;
		g_bSchemaReady = true;
		UploadConfigSnapshotIfReady();
		FlushAllStatsToDb();
		return;
	}

	g_hDb.Execute(migrateTxn, OnSchemaMigrateSuccess, OnSchemaTxnFailure, g_iDbGen);
}

public void OnSchemaMigrateSuccess(Database db, any data, int numQueries, DBResultSet[] results, any[] queryData)
{
	if (g_hDb == null || data != g_iDbGen) return;
	g_bSchemaCreating = false;
	g_bSchemaReady = true;
	UploadConfigSnapshotIfReady();
	FlushAllStatsToDb();
}

public void OnSchemaTxnFailure(Database db, any data, int numQueries, const char[] error, int failIndex, any[] queryData)
{
	if (data != g_iDbGen) return;
	g_fNextDbRetry = GetEngineTime() + 10.0;
	g_bSchemaCreating = false;
	LogError("[WeaponBalanceStats] 建表事务失败 (#%d): %s", failIndex, error);
	HandleDbConnectionError(error);
}

static void UploadConfigSnapshotIfReady()
{
	if (!g_bConfigPendingUpload || g_hDb == null || !g_bSchemaReady || g_sActiveConfigHash[0] == '\0' || GetEngineTime() < g_fNextDbRetry)
	{
		return;
	}

	char escHash[64], escWepCfg[160], escAnneVer[160], escRuleset[160], escJson[24576];
	g_hDb.Escape(g_sActiveConfigHash, escHash, sizeof(escHash));
	g_hDb.Escape(g_sActiveWeaponConfig, escWepCfg, sizeof(escWepCfg));
	g_hDb.Escape(g_sActiveAnneVersion, escAnneVer, sizeof(escAnneVer));
	g_hDb.Escape(g_sActiveRuleset, escRuleset, sizeof(escRuleset));
	g_hDb.Escape(g_sActiveAttrsJson, escJson, sizeof(escJson));

	int now = GetTime();
	char query[25600];
	FormatEx(query, sizeof(query),
		"INSERT INTO `%sweapon_balance_configs` "
		... "(`config_hash`,`weapon_config`,`anne_version`,`ruleset_key`,`sg_center_pellet`,`sg_ring1_bullets`,`sg_ring1_factor`,`attrs_json`,`first_seen`,`last_seen`) "
		... "VALUES ('%s','%s','%s','%s',%d,%d,%.2f,'%s',%d,%d) "
		... "ON DUPLICATE KEY UPDATE `anne_version` = VALUES(`anne_version`), `last_seen` = VALUES(`last_seen`)",
		g_sDbPrefix,
		escHash, escWepCfg, escAnneVer, escRuleset,
		g_iActiveSgCenter, g_iActiveSgRing1, g_fActiveSgFactor,
		escJson, now, now);

	g_bConfigPendingUpload = false;
	DataPack backup = new DataPack();
	backup.WriteCell(g_iDbGen);
	backup.WriteString(query);
	g_hUploadBackups.Push(backup);
	g_hDb.Query(OnSimpleQueryDone, query, backup);
}

public void OnSimpleQueryDone(Database db, DBResultSet results, const char[] error, any data)
{
	DataPack backup = view_as<DataPack>(data);
	backup.Reset();
	int generation = backup.ReadCell();
	if (error[0] != '\0')
	{
		SaveFailedBatch(backup);
		LogError("[WeaponBalanceStats] 写入配置快照失败: %s", error);
		if (generation == g_iDbGen)
		{
			g_bConfigPendingUpload = true;
			g_fNextDbRetry = GetEngineTime() + 10.0;
			HandleDbConnectionError(error);
		}
	}
	ReleaseUploadBackup(backup);
}

static bool FlushAllStatsToDb()
{
	for (int i = 1; i <= MaxClients; i++) FlushClientShotgunBurst(i);
	if (!HasDirtyStats())
	{
		return true;
	}

	if (g_hDb == null)
	{
		EnsureDbConnected();
		return false;
	}
	if (!g_bSchemaReady)
	{
		return false;
	}
	if (g_sActiveConfigHash[0] == '\0')
	{
		RefreshWeaponConfigSnapshot();
	}

	int now = GetTime();
	int statDate = GetStatDateInt(now);

	char escRuleset[160], escAnneVer[160], escDiffType[40], escWepCfg[160], escHash[64];
	g_hDb.Escape(g_sActiveRuleset, escRuleset, sizeof(escRuleset));
	g_hDb.Escape(g_sActiveAnneVersion, escAnneVer, sizeof(escAnneVer));
	g_hDb.Escape(g_sActiveDifficultyType, escDiffType, sizeof(escDiffType));
	g_hDb.Escape(g_sActiveWeaponConfig, escWepCfg, sizeof(escWepCfg));
	g_hDb.Escape(g_sActiveConfigHash, escHash, sizeof(escHash));

	Transaction txn = new Transaction();
	g_hFlushBackup = new DataPack();
	g_hFlushBackup.WriteCell(g_iDbGen);
	int queryCount = 0;

	if (g_bDirtyCombat)
	{
		AppendCombatFlushQueries(txn, statDate, escRuleset, escAnneVer, escDiffType, g_iActiveDifficulty, g_iActiveSiCount, g_iActiveSiSpawnTime, escWepCfg, escHash, queryCount);
	}
	if (g_bDirtyUsage)
	{
		AppendUsageFlushQueries(txn, statDate, escRuleset, escAnneVer, escDiffType, g_iActiveDifficulty, g_iActiveSiCount, g_iActiveSiSpawnTime, escWepCfg, escHash, queryCount);
	}
	if (g_bDirtySwaps)
	{
		AppendSwapFlushQueries(txn, escRuleset, escAnneVer, escDiffType, g_iActiveDifficulty, g_iActiveSiCount, g_iActiveSiSpawnTime, escWepCfg, escHash, statDate, queryCount);
	}
	if (g_hPendingTanks.Length > 0)
	{
		AppendTankFlushQueries(txn, queryCount);
	}

	if (queryCount <= 0)
	{
		delete txn;
		delete g_hFlushBackup;
		ResetAllBuckets();
		return true;
	}

	// 查询已携带原上下文；失败时将备份写入本地恢复文件，避免静默丢失。
	ResetAllBuckets();
	g_hUploadBackups.Push(g_hFlushBackup);
	g_hDb.Execute(txn, OnFlushTxnSuccess, OnFlushTxnFailure, g_hFlushBackup);
	g_hFlushBackup = null;
	return true;
}

static void AppendCombatFlushQueries(Transaction txn, int statDate, const char[] escRuleset, const char[] escAnneVer, const char[] escDiffType, int difficulty, int siCount, int siSpawnTime, const char[] escWepCfg, const char[] escHash, int &queryCount)
{
	char query[SQL_QUERY_MAX];
	char header[512];
	FormatEx(header, sizeof(header),
		"INSERT INTO `%sweapon_balance_daily` "
		... "(`stat_date`,`ruleset_key`,`anne_version`,`difficulty_type`,`difficulty`,`si_count`,`si_spawn_time`,`weapon_config`,`config_hash`,`weapon_key`,`target_class`,`dist_bucket`,`move_state`,`skill_tier`,"
		... "`hits`,`headshots`,`raw_damage`,`effective_damage`,`kills`,`shot_bursts`,`one_shot_kills`,`near_kill_misses`,`collateral_hits`) VALUES ",
		g_sDbPrefix);

	static const char suffix[] =
		" ON DUPLICATE KEY UPDATE "
		... "`hits`=`hits`+VALUES(`hits`),`headshots`=`headshots`+VALUES(`headshots`),"
		... "`raw_damage`=`raw_damage`+VALUES(`raw_damage`),`effective_damage`=`effective_damage`+VALUES(`effective_damage`),"
		... "`kills`=`kills`+VALUES(`kills`),`shot_bursts`=`shot_bursts`+VALUES(`shot_bursts`),"
		... "`one_shot_kills`=`one_shot_kills`+VALUES(`one_shot_kills`),"
		... "`near_kill_misses`=`near_kill_misses`+VALUES(`near_kill_misses`),"
		... "`collateral_hits`=`collateral_hits`+VALUES(`collateral_hits`)";

	int len = strcopy(query, sizeof(query), header);
	int rows = 0;

	for (int w = 0; w < WEP_COUNT; w++)
	{
		for (int c = 0; c < TARGET_COUNT; c++)
		{
			for (int d = 0; d < DIST_BUCKETS; d++)
			{
				for (int m = 0; m < MOVE_STATES; m++)
				{
					for (int t = 0; t < SKILL_TIERS; t++)
					{
						if (g_iCombatStats[w][c][d][m][t][STAT_HITS] <= 0 && g_iCombatStats[w][c][d][m][t][STAT_EFF_DMG] <= 0)
						{
							continue;
						}

						char row[512];
						int rowLen = FormatEx(row, sizeof(row),
							"(%d,'%s','%s','%s',%d,%d,%d,'%s','%s','%s',%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d)",
							statDate, escRuleset, escAnneVer, escDiffType, difficulty, siCount, siSpawnTime, escWepCfg, escHash, g_sWeaponKeys[w],
							c, d, m, t,
							g_iCombatStats[w][c][d][m][t][STAT_HITS],
							g_iCombatStats[w][c][d][m][t][STAT_HEADSHOTS],
							g_iCombatStats[w][c][d][m][t][STAT_RAW_DMG],
							g_iCombatStats[w][c][d][m][t][STAT_EFF_DMG],
							g_iCombatStats[w][c][d][m][t][STAT_KILLS],
							g_iCombatStats[w][c][d][m][t][STAT_SHOT_BURSTS],
							g_iCombatStats[w][c][d][m][t][STAT_ONE_SHOT_KILLS],
							g_iCombatStats[w][c][d][m][t][STAT_NEAR_KILL_MISSES],
							g_iCombatStats[w][c][d][m][t][STAT_COLLATERAL_HITS]
						);

						if (rows >= SQL_BATCH_ROWS || len + rowLen + 2 + sizeof(suffix) >= sizeof(query))
						{
							StrCat(query, sizeof(query), suffix);
							txn.AddQuery(query);
							g_hFlushBackup.WriteString(query);
							queryCount++;
							len = strcopy(query, sizeof(query), header);
							rows = 0;
						}

						if (rows > 0)
						{
							query[len++] = ',';
							query[len] = '\0';
						}
						len += strcopy(query[len], sizeof(query) - len, row);
						rows++;
					}
				}
			}
		}
	}

	if (rows > 0)
	{
		StrCat(query, sizeof(query), suffix);
		txn.AddQuery(query);
		g_hFlushBackup.WriteString(query);
		queryCount++;
	}
}

static void AppendUsageFlushQueries(Transaction txn, int statDate, const char[] escRuleset, const char[] escAnneVer, const char[] escDiffType, int difficulty, int siCount, int siSpawnTime, const char[] escWepCfg, const char[] escHash, int &queryCount)
{
	char query[SQL_QUERY_MAX];
	char header[512];
	FormatEx(header, sizeof(header),
		"INSERT INTO `%sweapon_balance_usage_daily` "
		... "(`stat_date`,`ruleset_key`,`anne_version`,`difficulty_type`,`difficulty`,`si_count`,`si_spawn_time`,`weapon_config`,`config_hash`,`weapon_key`,`move_state`,`skill_tier`,"
		... "`shots_fired`,`pellets_fired`,`reloads`,`hold_seconds`,`pickups`,`swaps_away`) VALUES ",
		g_sDbPrefix);

	static const char suffix[] =
		" ON DUPLICATE KEY UPDATE "
		... "`shots_fired`=`shots_fired`+VALUES(`shots_fired`),`pellets_fired`=`pellets_fired`+VALUES(`pellets_fired`),"
		... "`reloads`=`reloads`+VALUES(`reloads`),`hold_seconds`=`hold_seconds`+VALUES(`hold_seconds`),"
		... "`pickups`=`pickups`+VALUES(`pickups`),`swaps_away`=`swaps_away`+VALUES(`swaps_away`)";

	int len = strcopy(query, sizeof(query), header);
	int rows = 0;

	for (int w = 0; w < WEP_COUNT; w++)
	{
		for (int m = 0; m < MOVE_STATES; m++)
		{
			for (int t = 0; t < SKILL_TIERS; t++)
			{
				if (g_iUsageStats[w][m][t][USAGE_SHOTS_FIRED] <= 0
					&& g_iUsageStats[w][m][t][USAGE_RELOADS] <= 0
					&& g_iUsageStats[w][m][t][USAGE_HOLD_SECONDS] <= 0
					&& g_iUsageStats[w][m][t][USAGE_PICKUPS] <= 0
					&& g_iUsageStats[w][m][t][USAGE_SWAPS_AWAY] <= 0)
				{
					continue;
				}

				char row[512];
				int rowLen = FormatEx(row, sizeof(row),
					"(%d,'%s','%s','%s',%d,%d,%d,'%s','%s','%s',%d,%d,%d,%d,%d,%d,%d,%d)",
					statDate, escRuleset, escAnneVer, escDiffType, difficulty, siCount, siSpawnTime, escWepCfg, escHash, g_sWeaponKeys[w],
					m, t,
					g_iUsageStats[w][m][t][USAGE_SHOTS_FIRED],
					g_iUsageStats[w][m][t][USAGE_PELLETS_FIRED],
					g_iUsageStats[w][m][t][USAGE_RELOADS],
					g_iUsageStats[w][m][t][USAGE_HOLD_SECONDS],
					g_iUsageStats[w][m][t][USAGE_PICKUPS],
					g_iUsageStats[w][m][t][USAGE_SWAPS_AWAY]
				);

				if (rows >= SQL_BATCH_ROWS || len + rowLen + 2 + sizeof(suffix) >= sizeof(query))
				{
					StrCat(query, sizeof(query), suffix);
					txn.AddQuery(query);
					g_hFlushBackup.WriteString(query);
					queryCount++;
					len = strcopy(query, sizeof(query), header);
					rows = 0;
				}

				if (rows > 0)
				{
					query[len++] = ',';
					query[len] = '\0';
				}
				len += strcopy(query[len], sizeof(query) - len, row);
				rows++;
			}
		}
	}

	if (rows > 0)
	{
		StrCat(query, sizeof(query), suffix);
		txn.AddQuery(query);
		g_hFlushBackup.WriteString(query);
		queryCount++;
	}
}

static void AppendSwapFlushQueries(Transaction txn, const char[] escRuleset, const char[] escAnneVer, const char[] escDiffType, int difficulty, int siCount, int siSpawnTime, const char[] escWepCfg, const char[] escHash, int statDate, int &queryCount)
{
	char query[SQL_QUERY_MAX];
	char header[512];
	FormatEx(header, sizeof(header),
		"INSERT INTO `%sweapon_balance_swaps_daily` "
		... "(`stat_date`,`ruleset_key`,`anne_version`,`difficulty_type`,`difficulty`,`si_count`,`si_spawn_time`,`weapon_config`,`config_hash`,`from_weapon_key`,`to_weapon_key`,`swap_count`) VALUES ",
		g_sDbPrefix);

	static const char suffix[] = " ON DUPLICATE KEY UPDATE `swap_count`=`swap_count`+VALUES(`swap_count`)";
	int len = strcopy(query, sizeof(query), header);
	int rows = 0;

	for (int f = 0; f < WEP_COUNT; f++)
	{
		for (int to = 0; to < WEP_COUNT; to++)
		{
			if (g_iSwapMatrix[f][to] <= 0)
			{
				continue;
			}

			char row[512];
			int rowLen = FormatEx(row, sizeof(row),
				"(%d,'%s','%s','%s',%d,%d,%d,'%s','%s','%s','%s',%d)",
				statDate, escRuleset, escAnneVer, escDiffType, difficulty, siCount, siSpawnTime, escWepCfg, escHash, g_sWeaponKeys[f], g_sWeaponKeys[to], g_iSwapMatrix[f][to]
			);

			if (rows >= SQL_BATCH_ROWS || len + rowLen + 2 + sizeof(suffix) >= sizeof(query))
			{
				StrCat(query, sizeof(query), suffix);
				txn.AddQuery(query);
				g_hFlushBackup.WriteString(query);
				queryCount++;
				len = strcopy(query, sizeof(query), header);
				rows = 0;
			}

			if (rows > 0)
			{
				query[len++] = ',';
				query[len] = '\0';
			}
			len += strcopy(query[len], sizeof(query) - len, row);
			rows++;
		}
	}

	if (rows > 0)
	{
		StrCat(query, sizeof(query), suffix);
		txn.AddQuery(query);
		g_hFlushBackup.WriteString(query);
		queryCount++;
	}
}

static void AppendTankFlushQueries(Transaction txn, int &queryCount)
{
	int count = g_hPendingTanks.Length;
	if (count <= 0)
	{
		return;
	}

	char query[SQL_QUERY_MAX];
	char header[512];
	FormatEx(header, sizeof(header),
		"INSERT INTO `%sweapon_tank_fights` "
		... "(`fight_id`,`stat_date`,`created_at`,`ruleset_key`,`anne_version`,`difficulty_type`,`difficulty`,`si_count`,`si_spawn_time`,`weapon_config`,`config_hash`,`map`,"
		... "`tank_max_hp`,`duration_ms`,`shooter_count`,`killed`,`weapon_key`,`raw_damage`,`effective_damage`,`hits`,`shots_fired`,`dist_sum`) VALUES ",
		g_sDbPrefix);

	int len = strcopy(query, sizeof(query), header);
	int rows = 0;

	for (int i = 0; i < count; i++)
	{
		PendingTankFight item;
		g_hPendingTanks.GetArray(i, item, sizeof(item));

		char escFight[96], escRuleset[160], escAnneVer[160], escDiffType[40], escWepCfg[160], escHash[64], escMap[160];
		g_hDb.Escape(item.fightId, escFight, sizeof(escFight));
		g_hDb.Escape(item.rulesetKey, escRuleset, sizeof(escRuleset));
		g_hDb.Escape(item.anneVersion, escAnneVer, sizeof(escAnneVer));
		g_hDb.Escape(item.difficultyType, escDiffType, sizeof(escDiffType));
		g_hDb.Escape(item.weaponConfig, escWepCfg, sizeof(escWepCfg));
		g_hDb.Escape(item.configHash, escHash, sizeof(escHash));
		g_hDb.Escape(item.mapName, escMap, sizeof(escMap));

		char row[640];
		int rowLen = FormatEx(row, sizeof(row),
			"('%s',%d,%d,'%s','%s','%s',%d,%d,%d,'%s','%s','%s',%d,%d,%d,%d,'%s',%d,%d,%d,%d,%d)",
			escFight, item.statDate, item.createdAt, escRuleset, escAnneVer, escDiffType, item.difficulty, item.siCount, item.siSpawnTime, escWepCfg, escHash, escMap,
			item.tankMaxHp, item.durationMs, item.shooterCount, item.killed,
			g_sWeaponKeys[item.weaponIdx], item.rawDmg, item.effDmg, item.hits, item.shots, item.distSum
		);

		if (rows >= SQL_BATCH_ROWS || len + rowLen + 2 >= sizeof(query) - 32)
		{
			txn.AddQuery(query);
			g_hFlushBackup.WriteString(query);
			queryCount++;
			len = strcopy(query, sizeof(query), header);
			rows = 0;
		}

		if (rows > 0)
		{
			query[len++] = ',';
			query[len] = '\0';
		}
		len += strcopy(query[len], sizeof(query) - len, row);
		rows++;
	}

	if (rows > 0)
	{
		txn.AddQuery(query);
		g_hFlushBackup.WriteString(query);
		queryCount++;
	}
}

public void OnFlushTxnSuccess(Database db, any data, int numQueries, DBResultSet[] results, any[] queryData)
{
	DataPack backup = view_as<DataPack>(data);
	ReleaseUploadBackup(backup);
}

public void OnFlushTxnFailure(Database db, any data, int numQueries, const char[] error, int failIndex, any[] queryData)
{
	DataPack backup = view_as<DataPack>(data);
	backup.Reset();
	int generation = backup.ReadCell();
	SaveFailedBatch(backup);
	ReleaseUploadBackup(backup);
	LogError("[WeaponBalanceStats] 统计落库事务失败 (#%d): %s", failIndex, error);
	if (generation == g_iDbGen) HandleDbConnectionError(error);
}

static void ReleaseUploadBackup(DataPack backup)
{
	int index = g_hUploadBackups.FindValue(backup);
	if (index != -1) g_hUploadBackups.Erase(index);
	delete backup;
}

// 断线时 COMMIT 的结果可能不确定；保留 SQL 供核对后恢复，避免盲重放重复计数。
static void SaveFailedBatch(DataPack backup)
{
	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), "data/weapon_balance_failed_%s_%d.sql", g_sSessionId, ++g_iFailedBatchSerial);
	File file = OpenFile(path, "w");
	if (file == null)
	{
		LogError("[WeaponBalanceStats] 无法写入统计恢复文件: %s", path);
		return;
	}
	file.WriteLine("-- Verify whether the original transaction committed before replaying.");
	file.WriteLine("START TRANSACTION;");
	char query[25600];
	while (backup.IsReadable())
	{
		backup.ReadString(query, sizeof(query));
		// WriteLine formats into a 2048-byte native buffer; raw SQL may be 25KB.
		file.WriteString(query, false);
		file.WriteString(";\n", false);
	}
	file.WriteLine("COMMIT;");
	delete file;
	LogError("[WeaponBalanceStats] 待核对恢复 SQL 已保存: %s", path);
}

static void HandleDbConnectionError(const char[] error)
{
	if (StrContains(error, "gone away", false) != -1
		|| StrContains(error, "Lost connection", false) != -1
		|| StrContains(error, "Server shutdown", false) != -1)
	{
		if (g_hDb != null)
		{
			delete g_hDb;
			g_hDb = null;
		}
		g_iDbGen++;
		g_bSchemaCreating = false;
		g_bSchemaReady = false;
		g_fNextDbRetry = GetEngineTime() + 5.0;
	}
}

// ---------------------------------------------------------------------------
// 辅助函数
// ---------------------------------------------------------------------------

static void BuildWeaponMaps()
{
	g_smWeaponNameToIdx = new StringMap();
	for (int i = 0; i < WEP_COUNT; i++)
	{
		char fullName[48];
		strcopy(fullName, sizeof(fullName), WeaponNames[g_iTrackedWepIds[i]]);
		strcopy(g_sWeaponKeys[i], sizeof(g_sWeaponKeys[]), fullName[7]);
		g_smWeaponNameToIdx.SetValue(fullName, i);
		g_smWeaponNameToIdx.SetValue(g_sWeaponKeys[i], i);
		g_iWepBullets[i] = 1;
	}

	g_smWeaponNameToIdx.SetValue("dual_pistols", 0);
	g_smWeaponNameToIdx.SetValue("weapon_dual_pistol", 0);
	g_smWeaponNameToIdx.SetValue("grenade_launcher_projectile", 18);
}

static void BindContextCvar(ConVar &cv, const char[] name, bool &hooked, bool isFull)
{
	if (cv == null)
	{
		cv = FindConVar(name);
	}
	if (cv != null && !hooked)
	{
		hooked = true;
		if (isFull)
		{
			cv.AddChangeHook(OnFullConfigCvarChanged);
		}
		else
		{
			cv.AddChangeHook(OnLightContextCvarChanged);
		}
	}
}

static void RefreshCvarHandles()
{
	BindContextCvar(g_cvReadyCfgName, "l4d_ready_cfg_name", g_bHookReadyCfg, false);
	BindContextCvar(g_cvGameMode, "mp_gamemode", g_bHookGameMode, false);
	BindContextCvar(g_cvAnneVersion, "AnnePluginVersion", g_bHookAnneVer, true);
	BindContextCvar(g_cvWeaponConfig, "l4d2_player_attr_db_weapon_config", g_bHookWeaponConfig, true);
	BindContextCvar(g_cvStatsRuleset, "l4d_stats_map_record_ruleset", g_bHookStatsRuleset, false);
	BindContextCvar(g_cvDiffProfile, "l4d_stats_map_record_difficulty_profile", g_bHookDiffProfile, false);
	BindContextCvar(g_cvZDifficulty, "z_difficulty", g_bHookZDifficulty, false);
	BindContextCvar(g_cvAiEnable, "ah_ai_dynamic_enable", g_bHookAiEnable, false);
	BindContextCvar(g_cvAiCurrentLevel, "ah_ai_dynamic_current_level", g_bHookAiCurrentLevel, false);
	BindContextCvar(g_cvAiFixedLevel, "ah_ai_dynamic_fixed_level", g_bHookAiFixedLevel, false);
	BindContextCvar(g_cvAiCurrentLocked, "ah_ai_dynamic_current_locked", g_bHookAiCurrentLocked, false);
	BindContextCvar(g_cvInfectedLimit, "l4d_infected_limit", g_bHookInfectedLimit, false);
	BindContextCvar(g_cvSiSpawnInterval, "versus_special_respawn_interval", g_bHookSiSpawnInterval, false);
	BindContextCvar(g_cvSgCenterPellet, "sgspread_center_pellet", g_bHookSgCenter, true);
	BindContextCvar(g_cvSgRing1Bullets, "sgspread_ring1_bullets", g_bHookSgRing1, true);
	BindContextCvar(g_cvSgRing1Factor, "sgspread_ring1_factor", g_bHookSgFactor, true);
}

static int LookupWeaponIdx(const char[] name)
{
	if (name[0] == '\0')
	{
		return -1;
	}
	int idx = -1;
	if (g_smWeaponNameToIdx.GetValue(name, idx))
	{
		return idx;
	}
	return -1;
}

static int GetClientActiveWeaponIdxCached(int client)
{
	int ent = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
	if (ent <= 0 || !IsValidEntity(ent))
	{
		g_iActiveWepEnt[client] = -1;
		g_iActiveWepIdx[client] = -1;
		return -1;
	}

	if (ent == g_iActiveWepEnt[client])
	{
		return g_iActiveWepIdx[client];
	}

	char cls[48];
	GetEntityClassname(ent, cls, sizeof(cls));
	int idx = LookupWeaponIdx(cls);
	g_iActiveWepEnt[client] = ent;
	g_iActiveWepIdx[client] = idx;
	return idx;
}

static void SyncClientSlotWeapons(int client)
{
	for (int slot = 0; slot < 2; slot++)
	{
		int ent = GetPlayerWeaponSlot(client, slot);
		if (ent > 0 && IsValidEntity(ent))
		{
			char cls[48];
			GetEntityClassname(ent, cls, sizeof(cls));
			g_iClientSlotWep[client][slot] = LookupWeaponIdx(cls);
		}
		else
		{
			g_iClientSlotWep[client][slot] = -1;
		}
	}
}

static int GetClientMoveState(int client)
{
	float vel[3];
	GetEntPropVector(client, Prop_Data, "m_vecVelocity", vel);
	float speedSq = vel[0] * vel[0] + vel[1] * vel[1];
	return (speedSq > MOVE_SPEED_SQ_THRESHOLD) ? 1 : 0;
}

static void UpdateClientSkillTier(int client)
{
	if (!LibraryExists("l4d_stats")
		|| GetFeatureStatus(FeatureType_Native, "l4dstats_IsClientScoreReady") != FeatureStatus_Available
		|| GetFeatureStatus(FeatureType_Native, "l4dstats_GetClientScore") != FeatureStatus_Available)
	{
		g_iClientSkillTier[client] = 0;
		return;
	}

	if (!l4dstats_IsClientScoreReady(client))
	{
		return;
	}

	int score = l4dstats_GetClientScore(client);
	if (score >= 300000)
	{
		g_iClientSkillTier[client] = 2;
	}
	else if (score >= 50000)
	{
		g_iClientSkillTier[client] = 1;
	}
	else
	{
		g_iClientSkillTier[client] = 0;
	}
}

static int DistSqToBucket(float distSq)
{
	for (int i = 0; i < DIST_BUCKETS - 1; i++)
	{
		if (distSq <= g_fDistBucketMaxSq[i])
		{
			return i;
		}
	}
	return DIST_BUCKETS - 1;
}

static bool IsValidHumanSurvivor(int client)
{
	return (client > 0 && client <= MaxClients && IsClientInGame(client) && !IsFakeClient(client) && GetClientTeam(client) == TEAM_SURVIVOR);
}

static bool HasEnoughHumanSurvivors()
{
	int minHumans = g_cvMinHumans.IntValue;
	if (minHumans <= 1)
	{
		for (int i = 1; i <= MaxClients; i++)
		{
			if (IsClientInGame(i) && !IsFakeClient(i) && GetClientTeam(i) == TEAM_SURVIVOR)
			{
				return true;
			}
		}
		return false;
	}

	int count = 0;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && !IsFakeClient(i) && GetClientTeam(i) == TEAM_SURVIVOR)
		{
			count++;
			if (count >= minHumans)
			{
				return true;
			}
		}
	}
	return false;
}

static int GetStatDateInt(int unixTime)
{
	char buf[16];
	FormatTime(buf, sizeof(buf), "%Y%m%d", unixTime);
	return StringToInt(buf);
}

static int CountBits(int mask)
{
	int count = 0;
	int v = mask;
	while (v != 0)
	{
		count += (v & 1);
		v = (v >>> 1) & 0x7FFFFFFF;
	}
	return count;
}

static void LowerString(char[] str)
{
	for (int i = 0; str[i] != '\0'; i++)
	{
		str[i] = CharToLower(str[i]);
	}
}

static void ClearEntityCaches()
{
	for (int i = 0; i < MAX_TRACKED_EDICTS; i++)
	{
		g_bEntityIsWitch[i] = false;
		g_iEntityPreHp[i] = 0;
		g_iLastSgShot[i] = 0;
		g_bEntityIsGLProj[i] = false;
	}
}

static void ResetClientState(int client)
{
	if (client <= 0 || client > MaxClients)
	{
		return;
	}
	g_iActiveWepEnt[client] = -1;
	g_iActiveWepIdx[client] = -1;
	g_iClientSlotWep[client][0] = -1;
	g_iClientSlotWep[client][1] = -1;
	g_iClientSkillTier[client] = 0;
	g_iShotSeq[client] = ++g_iShotSerial;
	g_iBulletHitTargetsInSeq[client] = 0;
	g_SgCount[client] = 0;
	g_SgFlushPending[client] = false;
	g_iClientLastHp[client] = 0;
	g_iClientMaxHp[client] = 0;
	g_bClientHitOnce[client] = false;
	g_bClientDeathCounted[client] = false;
}

static void ResetAllClientState()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		ResetClientState(i);
	}
}

static bool HasDirtyStats()
{
	return g_bDirtyCombat || g_bDirtyUsage || g_bDirtySwaps || (g_hPendingTanks != null && g_hPendingTanks.Length > 0);
}

static void ResetAllBuckets()
{
	if (g_bDirtyCombat)
	{
		for (int w = 0; w < WEP_COUNT; w++)
			for (int c = 0; c < TARGET_COUNT; c++)
				for (int d = 0; d < DIST_BUCKETS; d++)
					for (int m = 0; m < MOVE_STATES; m++)
						for (int t = 0; t < SKILL_TIERS; t++)
							for (int f = 0; f < STAT_FIELDS; f++)
								g_iCombatStats[w][c][d][m][t][f] = 0;
		g_bDirtyCombat = false;
	}

	if (g_bDirtyUsage)
	{
		for (int w = 0; w < WEP_COUNT; w++)
			for (int m = 0; m < MOVE_STATES; m++)
				for (int t = 0; t < SKILL_TIERS; t++)
					for (int f = 0; f < USAGE_FIELDS; f++)
						g_iUsageStats[w][m][t][f] = 0;
		g_bDirtyUsage = false;
	}

	if (g_bDirtySwaps)
	{
		for (int f = 0; f < WEP_COUNT; f++)
			for (int to = 0; to < WEP_COUNT; to++)
				g_iSwapMatrix[f][to] = 0;
		g_bDirtySwaps = false;
	}

	if (g_hPendingTanks != null)
	{
		g_hPendingTanks.Clear();
	}
}
