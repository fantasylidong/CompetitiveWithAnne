#pragma semicolon 1
#include <sourcemod>
#include <clientprefs>
#include <sdktools>
#include <left4dhooks>
#undef REQUIRE_PLUGIN
#include <adminmenu>
#include <rpg>
#define PLUGIN_NAME "玩家排名系统"
#define PLUGIN_VERSION "1.5"
#define PLUGIN_DESCRIPTION "求生之路2状态和排名系统."

#define MAX_LINE_WIDTH 64
#define MAX_MESSAGE_WIDTH 256
#define MAX_QUERY_COUNTER 256
#define DB_CONF_NAME "l4dstats"

#define GAMEMODE_UNKNOWN -1
#define GAMEMODE_COOP 0
#define GAMEMODE_VERSUS 1
#define GAMEMODE_REALISM 2
#define GAMEMODE_SURVIVAL 3
#define GAMEMODE_SCAVENGE 4
#define GAMEMODE_REALISMVERSUS 5
#define GAMEMODE_OTHERMUTATIONS 6
#define GAMEMODES 7

#define INF_ID_SMOKER 1
#define INF_ID_BOOMER 2
#define INF_ID_HUNTER 3
#define INF_ID_SPITTER_L4D2 4
#define INF_ID_JOCKEY_L4D2 5
#define INF_ID_CHARGER_L4D2 6
#define INF_ID_WITCH_L4D1 4
#define INF_ID_WITCH_L4D2 7
#define INF_ID_TANK_L4D1 5
#define INF_ID_TANK_L4D2 8

#define TEAM_UNDEFINED 0
#define TEAM_SPECTATORS 1
#define TEAM_SURVIVORS 2
#define TEAM_INFECTED 3

#define INF_WEAROFF_TIME 0.5

//#define Engine_Left4Dead 40
//#define SERVER_VERSION_L4D2 50

#define CLEAR_DATABASE_CONFIRMTIME 10.0

#define CM_UNKNOWN -1
#define CM_RANK 0
#define CM_TOP10 1
#define CM_NEXTRANK 2
#define CM_NEXTRANKFULL 3

#define SOUND_RANKVOTE "items/suitchargeok1.wav"
#define SOUND_MAPTIME_START_L4D1 "UI/Beep23.wav"
#define SOUND_MAPTIME_START_L4D2 "level/countdown.wav"
#define SOUND_MAPTIME_IMPROVE_L4D1 "UI/Pickup_Secret01.wav"
#define SOUND_MAPTIME_IMPROVE_L4D2 "level/bell_normal.wav"
#define SOUND_RANKMENU_SHOW_L4D1 "UI/Menu_Horror01.wav"
#define SOUND_RANKMENU_SHOW_L4D2 "ui/menu_horror01.wav"
#define SOUND_BOOMER_VOMIT_L4D1 "player/Boomer/fall/boomer_dive_01.wav"
#define SOUND_BOOMER_VOMIT_L4D2 "player/Boomer/fall/boomer_dive_01.wav"
#define SOUND_HUNTER_PERFECT_L4D1 "player/hunter/voice/pain/lunge_attack_3.wav"
#define SOUND_HUNTER_PERFECT_L4D2 "player/hunter/voice/pain/lunge_attack_3.wav"
#define SOUND_TANK_BULLDOZER_L4D1 "player/tank/voice/yell/hulk_yell_8.wav"
#define SOUND_TANK_BULLDOZER_L4D2 "player/tank/voice/yell/tank_throw_11.wav"
#define SOUND_CHARGER_RAM "player/charger/voice/alert/charger_alert_02.wav"

#define RANKVOTE_NOVOTE -1
#define RANKVOTE_NO 0
#define RANKVOTE_YES 1

new String:TM_MENU_CURRENT[4] = " <<";

new String:DB_PLAYERS_TOTALPOINTS[1024] = "points + points_survivors + points_infected + points_realism + points_survival + points_scavenge_survivors + points_scavenge_infected + points_realism_survivors + points_realism_infected + points_mutations";
new String:DB_PLAYERS_TOTALPLAYTIME[1024] = "playtime + playtime_versus + playtime_realism + playtime_survival + playtime_scavenge + playtime_realismversus + playtime_mutations";

new String:RANKVOTE_QUESTION[128] = "Do you want to shuffle teams by player PPM?";

// Message of the day
new String:MOTD_TITLE[32] = "今日消息";
new String:MessageOfTheDay[1024];

// Set to false when stats seem to work properly
new bool:DEBUG = true;

new bool:CommandsRegistered = false;
// Sounds
new bool:EnableSounds_Rankvote = true;
new bool:EnableSounds_Maptime_Start = true;
new bool:EnableSounds_Maptime_Improve = true;
new bool:EnableSounds_Rankmenu_Show = true;
new bool:EnableSounds_Boomer_Vomit = true;
new bool:EnableSounds_Hunter_Perfect = true;
new bool:EnableSounds_Tank_Bulldozer = true;
new bool:EnableSounds_Charger_Ram = true;
new String:StatsSound_MapTime_Start[32];
new String:StatsSound_MapTime_Improve[32];
new String:StatsSound_Rankmenu_Show[32];
new String:StatsSound_Boomer_Vomit[32];
new String:StatsSound_Hunter_Perfect[32];
new String:StatsSound_Tank_Bulldozer[32];
new bool:Isstart = false;
new bool:g_broundend = false;
// Server version
EngineVersion EngineVersion1 =  Engine_Left4Dead;

// Database handle
new Handle:db = INVALID_HANDLE;
new String:DbPrefix[MAX_LINE_WIDTH] = "";

// Update Timer handle
new Handle:UpdateTimer = INVALID_HANDLE;

// Gamemode
new String:CurrentGamemode[MAX_LINE_WIDTH];
new String:CurrentGamemodeLabel[MAX_LINE_WIDTH];
new CurrentGamemodeID = GAMEMODE_UNKNOWN;
new String:CurrentMutation[MAX_LINE_WIDTH];
ConVar cvar_mode;

// Disable check Cvar handles
new Handle:cvar_Difficulty = INVALID_HANDLE;
new Handle:cvar_Gamemode = INVALID_HANDLE;
new Handle:cvar_Cheats = INVALID_HANDLE;

new Handle:cvar_SurvivorLimit = INVALID_HANDLE;
new Handle:cvar_InfectedLimit = INVALID_HANDLE;

// Game event booleans
new bool:PlayerVomited = false;
new bool:PlayerVomitedIncap = false;
new bool:PanicEvent = false;
new bool:PanicEventIncap = false;
new bool:CampaignOver = false;
new bool:WitchExists = false;
new bool:WitchDisturb = false;

// Anti-Stat Whoring vars
new CurrentPoints[MAXPLAYERS + 1];
new TankCount = 0;

new bool:ClientRankMute[MAXPLAYERS + 1];

// Cvar handles
new Handle:cvar_EnableRankVote = INVALID_HANDLE;
new Handle:cvar_HumansNeeded = INVALID_HANDLE;
new Handle:cvar_UpdateRate = INVALID_HANDLE;
//new Handle:cvar_AnnounceRankMinChange = INVALID_HANDLE;
new Handle:cvar_AnnounceRankChange = INVALID_HANDLE;
new Handle:cvar_AnnouncePlayerJoined = INVALID_HANDLE;
new Handle:cvar_AnnounceMotd = INVALID_HANDLE;
new Handle:cvar_AnnounceMode = INVALID_HANDLE;
new Handle:cvar_AnnounceRankChangeIVal = INVALID_HANDLE;
new Handle:cvar_AnnounceToTeam = INVALID_HANDLE;
//new Handle:cvar_AnnounceSpecial = INVALID_HANDLE;
new Handle:cvar_MedkitMode = INVALID_HANDLE;
new Handle:cvar_SiteURL = INVALID_HANDLE;
new Handle:cvar_RankOnJoin = INVALID_HANDLE;
new Handle:cvar_SilenceChat = INVALID_HANDLE;
new Handle:cvar_DisabledMessages = INVALID_HANDLE;
//new Handle:cvar_MaxPoints = INVALID_HANDLE;
new Handle:cvar_DbPrefix = INVALID_HANDLE;
//new Handle:cvar_LeaderboardTime = INVALID_HANDLE;
new Handle:cvar_EnableNegativeScore = INVALID_HANDLE;
new Handle:cvar_FriendlyFireMode = INVALID_HANDLE;
new Handle:cvar_FriendlyFireMultiplier = INVALID_HANDLE;
new Handle:cvar_FriendlyFireCooldown = INVALID_HANDLE;
new Handle:cvar_FriendlyFireCooldownMode = INVALID_HANDLE;
new Handle:FriendlyFireTimer[MAXPLAYERS + 1][MAXPLAYERS + 1];
new bool:FriendlyFireCooldown[MAXPLAYERS + 1][MAXPLAYERS + 1];
new FriendlyFirePrm[MAXPLAYERS][2];
new Handle:FriendlyFireDamageTrie = INVALID_HANDLE;
new FriendlyFirePrmCounter = 0;

new Handle:cvar_Enable = INVALID_HANDLE;
new Handle:cvar_EnableCoop = INVALID_HANDLE;
new Handle:cvar_EnableSv = INVALID_HANDLE;
new Handle:cvar_EnableVersus = INVALID_HANDLE;
new Handle:cvar_EnableTeamVersus = INVALID_HANDLE;
new Handle:cvar_EnableRealism = INVALID_HANDLE;
new Handle:cvar_EnableScavenge = INVALID_HANDLE;
new Handle:cvar_EnableTeamScavenge = INVALID_HANDLE;
new Handle:cvar_EnableRealismVersus = INVALID_HANDLE;
new Handle:cvar_EnableTeamRealismVersus = INVALID_HANDLE;
new Handle:cvar_EnableMutations = INVALID_HANDLE;

new Handle:cvar_RealismMultiplier = INVALID_HANDLE;
new Handle:cvar_RealismVersusSurMultiplier = INVALID_HANDLE;
new Handle:cvar_RealismVersusInfMultiplier = INVALID_HANDLE;
new Handle:cvar_EnableSvMedicPoints = INVALID_HANDLE;

new Handle:cvar_Infected = INVALID_HANDLE;
new Handle:cvar_Hunter = INVALID_HANDLE;
new Handle:cvar_Smoker = INVALID_HANDLE;
new Handle:cvar_Boomer = INVALID_HANDLE;
new Handle:cvar_Spitter = INVALID_HANDLE;
new Handle:cvar_Jockey = INVALID_HANDLE;
new Handle:cvar_Charger = INVALID_HANDLE;

new Handle:cvar_Pills = INVALID_HANDLE;
new Handle:cvar_Adrenaline = INVALID_HANDLE;
new Handle:cvar_Medkit = INVALID_HANDLE;
new Handle:cvar_Defib = INVALID_HANDLE;
new Handle:cvar_SmokerDrag = INVALID_HANDLE;
new Handle:cvar_ChokePounce = INVALID_HANDLE;
new Handle:cvar_JockeyRide = INVALID_HANDLE;
new Handle:cvar_ChargerPlummel = INVALID_HANDLE;
new Handle:cvar_ChargerCarry = INVALID_HANDLE;
new Handle:cvar_Revive = INVALID_HANDLE;
new Handle:cvar_Rescue = INVALID_HANDLE;
new Handle:cvar_Protect = INVALID_HANDLE;

new Handle:cvar_Tank = INVALID_HANDLE;
new Handle:cvar_Panic = INVALID_HANDLE;
new Handle:cvar_BoomerMob = INVALID_HANDLE;
new Handle:cvar_SafeHouse = INVALID_HANDLE;
new Handle:cvar_Witch = INVALID_HANDLE;
new Handle:cvar_WitchCrowned = INVALID_HANDLE;
new Handle:cvar_VictorySurvivors = INVALID_HANDLE;
new Handle:cvar_VictoryInfected = INVALID_HANDLE;

new Handle:cvar_FFire = INVALID_HANDLE;
new Handle:cvar_FIncap = INVALID_HANDLE;
new Handle:cvar_FKill = INVALID_HANDLE;
new Handle:cvar_InSafeRoom = INVALID_HANDLE;
new Handle:cvar_Restart = INVALID_HANDLE;
new Handle:cvar_CarAlarm = INVALID_HANDLE;
new Handle:cvar_BotScoreMultiplier = INVALID_HANDLE;

new Handle:cvar_SurvivorDeath = INVALID_HANDLE;
new Handle:cvar_SurvivorIncap = INVALID_HANDLE;

// L4D2 misc
new Handle:cvar_AmmoUpgradeAdded = INVALID_HANDLE;
new Handle:cvar_GascanPoured = INVALID_HANDLE;

new MaxPounceDistance;
new MinPounceDistance;
new MaxPounceDamage;
new Handle:cvar_HunterDamageCap = INVALID_HANDLE;
new Float:HunterPosition[MAXPLAYERS + 1][3];
new Handle:cvar_HunterPerfectPounceDamage = INVALID_HANDLE;
new Handle:cvar_HunterPerfectPounceSuccess = INVALID_HANDLE;
new Handle:cvar_HunterNicePounceDamage = INVALID_HANDLE;
new Handle:cvar_HunterNicePounceSuccess = INVALID_HANDLE;

new BoomerHitCounter[MAXPLAYERS + 1];
new bool:BoomerVomitUpdated[MAXPLAYERS + 1];
new Handle:cvar_BoomerSuccess = INVALID_HANDLE;
new Handle:cvar_BoomerPerfectHits = INVALID_HANDLE;
new Handle:cvar_BoomerPerfectSuccess = INVALID_HANDLE;
new Handle:TimerBoomerPerfectCheck[MAXPLAYERS + 1];

new InfectedDamageCounter[MAXPLAYERS + 1];
new Handle:cvar_InfectedDamage = INVALID_HANDLE;
new Handle:TimerInfectedDamageCheck[MAXPLAYERS + 1];

new Handle:cvar_TankDamageCap = INVALID_HANDLE;
new Handle:cvar_TankDamageTotal = INVALID_HANDLE;
new Handle:cvar_TankDamageTotalSuccess = INVALID_HANDLE;

new ChargerCarryVictim[MAXPLAYERS + 1];
new ChargerPlummelVictim[MAXPLAYERS + 1];
new JockeyVictim[MAXPLAYERS + 1];
new JockeyRideStartTime[MAXPLAYERS + 1];

new SmokerDamageCounter[MAXPLAYERS + 1];
new SpitterDamageCounter[MAXPLAYERS + 1];
new JockeyDamageCounter[MAXPLAYERS + 1];
new ChargerDamageCounter[MAXPLAYERS + 1];
new ChargerImpactCounter[MAXPLAYERS + 1];
new Handle:ChargerImpactCounterTimer[MAXPLAYERS + 1];
new Handle:cvar_ChargerRamHits = INVALID_HANDLE;
new Handle:cvar_ChargerRamSuccess = INVALID_HANDLE;
new TankDamageCounter[MAXPLAYERS + 1];
new TankDamageTotalCounter[MAXPLAYERS + 1];
new TankPointsCounter[MAXPLAYERS + 1];
new TankSurvivorKillCounter[MAXPLAYERS + 1];
new Handle:cvar_TankThrowRockSuccess = INVALID_HANDLE;

new Handle:cvar_PlayerLedgeSuccess = INVALID_HANDLE;
new Handle:cvar_Matador = INVALID_HANDLE;

new ClientInfectedType[MAXPLAYERS + 1];

new PlayerBlinded[MAXPLAYERS + 1][2];
new PlayerParalyzed[MAXPLAYERS + 1][2];
new PlayerLunged[MAXPLAYERS + 1][2];
new PlayerPlummeled[MAXPLAYERS + 1][2];
new PlayerCarried[MAXPLAYERS + 1][2];
new PlayerJockied[MAXPLAYERS + 1][2];

// Rank panel vars
new RankTotal = 0;
new ClientRank[MAXPLAYERS + 1];
new ClientNextRank[MAXPLAYERS + 1];
new ClientPoints[MAXPLAYERS + 1];
new GameModeRankTotal = 0;
new ClientGameModeRank[MAXPLAYERS + 1];
new ClientGameModePoints[MAXPLAYERS + 1][GAMEMODES];

// Misc arrays
new TimerPoints[MAXPLAYERS + 1];
new TimerKills[MAXPLAYERS + 1];
new TimerHeadshots[MAXPLAYERS + 1];
new Pills[4096];
new Adrenaline[4096];

new String:QueryBuffer[MAX_QUERY_COUNTER][MAX_QUERY_COUNTER];
new QueryCounter = 0;

new AnnounceCounter[MAXPLAYERS + 1];
new PostAdminCheckRetryCounter[MAXPLAYERS + 1];

// For every medkit used the points earned by the Survivor team is calculated with this formula:
// NormalPointsEarned * (1 - MedkitsUsedCounter * cvar_MedkitUsedPointPenalty)
// Minimum formula result = 0 (Cannot be negative)
new MedkitsUsedCounter = 0;
new Handle:cvar_MedkitUsedPointPenalty = INVALID_HANDLE;
new Handle:cvar_MedkitUsedPointPenaltyMax = INVALID_HANDLE;
new Handle:cvar_MedkitUsedFree = INVALID_HANDLE;
new Handle:cvar_MedkitUsedRealismFree = INVALID_HANDLE;
new Handle:cvar_MedkitBotMode = INVALID_HANDLE;

new ProtectedFriendlyCounter[MAXPLAYERS + 1];
new Handle:TimerProtectedFriendly[MAXPLAYERS + 1];

// Announce rank
new Handle:TimerRankChangeCheck[MAXPLAYERS + 1];
new RankChangeLastRank[MAXPLAYERS + 1];
new bool:RankChangeFirstCheck[MAXPLAYERS + 1];

// MapTiming
new Float:MapTimingStartTime = -1.0;
new bool:MapTimingBlocked = false;
new Handle:MapTimingSurvivors = INVALID_HANDLE; // Survivors at the beginning of the map
new Handle:MapTimingInfected = INVALID_HANDLE; // Survivors at the beginning of the map
new String:MapTimingMenuInfo[MAXPLAYERS + 1][MAX_LINE_WIDTH];
float FastestTime = -1.0;

// When an admin calls for clear database, the client id is stored here for a period of time.
// The admin must then call the clear command again to confirm the call. After the second call
// the database is cleared. The confirm must be done in the time set by CLEAR_DATABASE_CONFIRMTIME.
new ClearDatabaseCaller = -1;
new Handle:ClearDatabaseTimer = INVALID_HANDLE;
//new Handle:ClearPlayerMenu = INVALID_HANDLE;

// Create handle for the admin menu
new Handle:RankAdminMenu = INVALID_HANDLE;
new TopMenuObject:MenuClear = INVALID_TOPMENUOBJECT;
new TopMenuObject:MenuClearPlayers = INVALID_TOPMENUOBJECT;
new TopMenuObject:MenuClearMaps = INVALID_TOPMENUOBJECT;
new TopMenuObject:MenuClearAll = INVALID_TOPMENUOBJECT;
new TopMenuObject:MenuRemoveCustomMaps = INVALID_TOPMENUOBJECT;
new TopMenuObject:MenuCleanPlayers = INVALID_TOPMENUOBJECT;
new TopMenuObject:MenuClearTimedMaps = INVALID_TOPMENUOBJECT;

bool g_brpgAvailable = false;

// Administrative Cvars
new Handle:cvar_AdminPlayerCleanLastOnTime = INVALID_HANDLE;
new Handle:cvar_AdminPlayerCleanPlatime = INVALID_HANDLE;

// Players can request a vote for team shuffle based on the player ranks ONCE PER MAP
new PlayerRankVote[MAXPLAYERS + 1];
new Handle:RankVoteTimer = INVALID_HANDLE;
new Handle:PlayerRankVoteTrie = INVALID_HANDLE; // Survivors at the beginning of the map
new Handle:cvar_RankVoteTime = INVALID_HANDLE;

new Handle:cvar_Top10PPMMin = INVALID_HANDLE;

new bool:SurvivalStarted = false;

new Handle:L4DStatsConf = INVALID_HANDLE;
new Handle:L4DStatsSHS = INVALID_HANDLE;
new Handle:L4DStatsTOB = INVALID_HANDLE;

new Float:ClientMapTime[MAXPLAYERS + 1];

new Handle:cvar_Lan = INVALID_HANDLE;
new Handle:cvar_SoundsEnabled = INVALID_HANDLE;

new Handle:MeleeKillTimer[MAXPLAYERS + 1];
new MeleeKillCounter[MAXPLAYERS + 1];
new ClientPlayTime[MAXPLAYERS + 1];
new bool:ClientEnabled[MAXPLAYERS + 1];
new CheckPlayerPoint[100];
Handle AnnounceGameTime, SuccessGetPlayerTime;
// Plugin Info
public Plugin:myinfo =
{
	name = PLUGIN_NAME,
	author = "Mikko Andersson (muukis), 东",
	description = PLUGIN_DESCRIPTION,
	version = PLUGIN_VERSION,
	url = "https://github.com/fantasylidong/L4d2_plugins"
};

//Startup
public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	//API
	RegPluginLibrary("l4d_stats");
	
	CreateNative("l4dstats_GetClientScore", Native_GetClientScore);
	CreateNative("l4dstats_AdddClientScore", Native_AddClientScore);
	CreateNative("l4dstats_GetClientPlayTime", Native_GetClientPlayTime);
	CreateNative("l4dstats_IsTopPlayer", Native_IsTopPlayer);

	//forward
	AnnounceGameTime = CreateGlobalForward("l4dstats_AnnounceGameTime", ET_Ignore,Param_Cell);
	SuccessGetPlayerTime = CreateGlobalForward("l4dstats_SuccessGetPlayerTime", ET_Ignore,Param_Cell);

	return APLRes_Success;
}

//API
public int Native_GetClientScore(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	
	if (client < 1 || client > MaxClients)
	{
		return ThrowNativeError(SP_ERROR_NATIVE, "Invalid client index (%d)", client);
	}
	if (!IsClientConnected(client))
	{
		return ThrowNativeError(SP_ERROR_NATIVE, "Client %d is not connected", client);
	}
	if(IsFakeClient(client)){
		return ThrowNativeError(SP_ERROR_NATIVE, "Client %d is A bot", client);
	}
	
	return ClientPoints[client];
}

public int Native_GetClientPlayTime(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	
	if (client < 1 || client > MaxClients)
	{
		return ThrowNativeError(SP_ERROR_NATIVE, "Invalid client index (%d)", client);
	}
	if (!IsClientConnected(client))
	{
		return ThrowNativeError(SP_ERROR_NATIVE, "Client %d is not connected", client);
	}
	if(IsFakeClient(client)){
		return ThrowNativeError(SP_ERROR_NATIVE, "Client %d is A bot", client);
	}
	
	return ClientPlayTime[client];
}

public int Native_IsTopPlayer(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	int ranklimit = GetNativeCell(2);
	if (client < 1 || client > MaxClients)
	{
		return ThrowNativeError(SP_ERROR_NATIVE, "Invalid client index (%d)", client);
	}
	if (!IsClientConnected(client))
	{
		return ThrowNativeError(SP_ERROR_NATIVE, "Client %d is not connected", client);
	}
	if(IsFakeClient(client)){
		return ThrowNativeError(SP_ERROR_NATIVE, "Client %d is A bot", client);
	}
	if(ranklimit<1 || ranklimit>100){
		return ThrowNativeError(SP_ERROR_NATIVE, "rank limit value wrong");
	}

	if(ClientPoints[client] >= CheckPlayerPoint[ranklimit-1] && CheckPlayerPoint[ranklimit-1]> 0)
		return 1;
	else
		return 0;
}

// Find a player from Top 100 ranking Points.
public GetTop100PlayerScore()
{
	decl String:query[512];
	Format(query, sizeof(query), "SELECT (%s) as totalpoints FROM %splayers ORDER BY totalpoints DESC LIMIT 100", DB_PLAYERS_TOTALPOINTS, DbPrefix);
	SQL_TQuery(db, GetTop100PlayersScore, query,0);
}

// Send the Top 10 player's info to the client.
public GetTop100PlayersScore(Handle:owner, Handle:hndl, const String:error[], any:client)
{
	if (hndl == INVALID_HANDLE)
	{
		LogError("GetPlayerScore failed! Reason: %s", error);
		return;
	}
	
	int i=0;
	while (SQL_FetchRow(hndl))
	{
		CheckPlayerPoint[i++] = SQL_FetchInt(hndl, 0);
	}
}

public int Native_AddClientScore(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	
	if (client < 1 || client > MaxClients)
	{
		return ThrowNativeError(SP_ERROR_NATIVE, "Invalid client index (%d)", client);
	}
	if (!IsClientConnected(client))
	{
		return ThrowNativeError(SP_ERROR_NATIVE, "Client %d is not connected", client);
	}
	if(IsFakeClient(client)){
		return ThrowNativeError(SP_ERROR_NATIVE, "Client %d is A bot", client);
	}
	
	int Score = GetNativeCell(2);
	CurrentPoints[client]+=Score;
	return ClientPoints[client];
}


// Here we go!
public OnPluginStart()
{
	CommandsRegistered = false;
	// Require Left 4 Dead (2)
	decl String:game_name[64];
	GetGameFolderName(game_name, sizeof(game_name));

	if (!StrEqual(game_name, "left4dead", false) &&
			!StrEqual(game_name, "left4dead2", false))
	{
		SetFailState("Plugin supports Left 4 Dead and Left 4 Dead 2 only.");
		return;
	}
	
	EngineVersion1 = GetEngineVersion();

	if (EngineVersion1 == Engine_Left4Dead)
	{
		strcopy(StatsSound_MapTime_Start, sizeof(StatsSound_MapTime_Start), SOUND_MAPTIME_START_L4D1);
		strcopy(StatsSound_MapTime_Improve, sizeof(StatsSound_MapTime_Improve), SOUND_MAPTIME_IMPROVE_L4D1);
		strcopy(StatsSound_Rankmenu_Show, sizeof(StatsSound_Rankmenu_Show), SOUND_RANKMENU_SHOW_L4D1);
		strcopy(StatsSound_Boomer_Vomit, sizeof(StatsSound_Boomer_Vomit), SOUND_BOOMER_VOMIT_L4D1);
		strcopy(StatsSound_Hunter_Perfect, sizeof(StatsSound_Hunter_Perfect), SOUND_HUNTER_PERFECT_L4D1);
		strcopy(StatsSound_Tank_Bulldozer, sizeof(StatsSound_Tank_Bulldozer), SOUND_TANK_BULLDOZER_L4D1);
	}
	else
	{
		strcopy(StatsSound_MapTime_Start, sizeof(StatsSound_MapTime_Start), SOUND_MAPTIME_START_L4D2);
		strcopy(StatsSound_MapTime_Improve, sizeof(StatsSound_MapTime_Improve), SOUND_MAPTIME_IMPROVE_L4D2);
		strcopy(StatsSound_Rankmenu_Show, sizeof(StatsSound_Rankmenu_Show), SOUND_RANKMENU_SHOW_L4D2);
		strcopy(StatsSound_Boomer_Vomit, sizeof(StatsSound_Boomer_Vomit), SOUND_BOOMER_VOMIT_L4D2);
		strcopy(StatsSound_Hunter_Perfect, sizeof(StatsSound_Hunter_Perfect), SOUND_HUNTER_PERFECT_L4D2);
		strcopy(StatsSound_Tank_Bulldozer, sizeof(StatsSound_Tank_Bulldozer), SOUND_TANK_BULLDOZER_L4D2);
	}

	// Plugin version public Cvar
	CreateConVar("l4d_stats_version", PLUGIN_VERSION, "Custom Player Stats Version", 0|FCVAR_SPONLY|FCVAR_REPLICATED|FCVAR_NOTIFY|FCVAR_DONTRECORD);

	// Disable setting Cvars
	cvar_Difficulty = FindConVar("z_difficulty");
	cvar_Gamemode = FindConVar("mp_gamemode");
	cvar_Cheats = FindConVar("sv_cheats");
	if(FindConVar("l4d_ready_cfg_name"))
		cvar_mode = FindConVar("l4d_ready_cfg_name");
	cvar_Lan = FindConVar("sv_lan");
	if (GetConVarInt(cvar_Lan))
		LogMessage("ATTENTION! %s in LAN environment is based on IP address rather than Steam ID. The statistics are not reliable when they are base on IP!", PLUGIN_NAME);

	HookConVarChange(cvar_Lan, action_LanChanged);

	cvar_SurvivorLimit = FindConVar("survivor_limit");
	cvar_InfectedLimit = FindConVar("z_max_player_zombies");

	// Administrative Cvars
	cvar_AdminPlayerCleanLastOnTime = CreateConVar("l4d_stats_adm_cleanoldplayers", "0", "How many months old players (last online time) will be cleaned. 0 = Disabled", 0, true, 0.0);
	cvar_AdminPlayerCleanPlatime = CreateConVar("l4d_stats_adm_cleanplaytime", "10", "How many minutes of playtime to not get cleaned from stats. 0 = Disabled", 0, true, 0.0);

	// Config/control Cvars
	cvar_EnableRankVote = CreateConVar("l4d_stats_enablerankvote", "1", "Enable voting of team shuffle by player PPM (Points Per Minute)", 0, true, 0.0, true, 1.0);
	cvar_HumansNeeded = CreateConVar("l4d_stats_minhumans", "1", "Minimum Human players before stats will be enabled", 0, true, 1.0, true, 4.0);
	cvar_UpdateRate = CreateConVar("l4d_stats_updaterate", "90", "Number of seconds between Common Infected point earn announcement/update", 0, true, 30.0);
	//cvar_AnnounceRankMinChange = CreateConVar("l4d_stats_announcerankminpoint", "500", "Minimum change to points before rank change announcement", 0, true, 0.0);
	cvar_AnnounceRankChange = CreateConVar("l4d_stats_announcerank", "1", "Chat announcment for rank change", 0, true, 0.0, true, 1.0);
	cvar_AnnounceRankChangeIVal = CreateConVar("l4d_stats_announcerankinterval", "60", "Rank change check interval", 0, true, 10.0);
	cvar_AnnouncePlayerJoined = CreateConVar("l4d_stats_announceplayerjoined", "1", "Chat announcment for player joined.", 0, true, 0.0, true, 1.0);
	cvar_AnnounceMotd = CreateConVar("l4d_stats_announcemotd", "1", "Chat announcment for the message of the day.", 0, true, 0.0, true, 1.0);
	cvar_AnnounceMode = CreateConVar("l4d_stats_announcemode", "1", "Chat announcment mode. 0 = Off, 1 = Player Only, 2 = Player Only w/ Public Headshots, 3 = All Public", 0, true, 0.0, true, 3.0);
	cvar_AnnounceToTeam = CreateConVar("l4d_stats_announceteam", "2", "Chat announcment team messages to the team only mode. 0 = Print messages to all teams, 1 = Print messages to own team only, 2 = Print messages to own team and spectators only", 0, true, 0.0, true, 2.0);
	//cvar_AnnounceSpecial = CreateConVar("l4d_stats_announcespecial", "1", "Chat announcment mode for special events. 0 = Off, 1 = Player Only, 2 = Print messages to all teams, 3 = Print messages to own team only, 4 = Print messages to own team and spectators only", 0, true, 0.0, true, 4.0);
	cvar_MedkitMode = CreateConVar("l4d_stats_medkitmode", "0", "Medkit point award mode. 0 = Based on amount healed, 1 = Static amount", 0, true, 0.0, true, 1.0);
	cvar_SiteURL = CreateConVar("l4d_stats_siteurl", "https://sb.trygek.com/l4d_stats/", "Community site URL, for rank panel display", 0);
	cvar_RankOnJoin = CreateConVar("l4d_stats_rankonjoin", "0", "Display player's rank when they connect. 0 = Disable, 1 = Enable", 0, true, 0.0, true, 1.0);
	cvar_SilenceChat = CreateConVar("l4d_stats_silencechat", "0", "Silence chat triggers. 0 = Show chat triggers, 1 = Silence chat triggers", 0, true, 0.0, true, 1.0);
	cvar_DisabledMessages = CreateConVar("l4d_stats_disabledmessages", "1", "Show 'Stats Disabled' messages, allow chat commands to work when stats disabled. 0 = Hide messages/disable chat, 1 = Show messages/allow chat", 0, true, 0.0, true, 1.0);
	//cvar_MaxPoints = CreateConVar("l4d_stats_maxpoints", "500", "Maximum number of points that can be earned in a single map. Normal = x1, Adv = x2, Expert = x3", 0, true, 500.0);
	cvar_DbPrefix = CreateConVar("l4d_stats_dbprefix", "", "Prefix for your stats tables", 0);
	//cvar_LeaderboardTime = CreateConVar("l4d_stats_leaderboardtime", "14", "Time in days to show Survival Leaderboard times", 0, true, 1.0);
	cvar_EnableNegativeScore = CreateConVar("l4d_stats_enablenegativescore", "1", "Enable point losses (negative score)", 0, true, 0.0, true, 1.0);
	cvar_FriendlyFireMode = CreateConVar("l4d_stats_ffire_mode", "2", "Friendly fire mode. 0 = Normal, 1 = Cooldown, 2 = Damage based", 0, true, 0.0, true, 2.0);
	cvar_FriendlyFireMultiplier = CreateConVar("l4d_stats_ffire_multiplier", "1.5", "Friendly fire damage multiplier (Formula: Score = Damage * Multiplier)", 0, true, 0.0);
	cvar_FriendlyFireCooldown = CreateConVar("l4d_stats_ffire_cooldown", "10.0", "Time in seconds for friendly fire cooldown", 0, true, 1.0);
	cvar_FriendlyFireCooldownMode = CreateConVar("l4d_stats_ffire_cooldownmode", "1", "Friendly fire cooldown mode. 0 = Disable, 1 = Player specific, 2 = General", 0, true, 0.0, true, 2.0);

	// Game mode Cvars
	cvar_Enable = CreateConVar("l4d_stats_enable", "1", "Enable/Disable all stat tracking", 0, true, 0.0, true, 1.0);
	cvar_EnableCoop = CreateConVar("l4d_stats_enablecoop", "1", "Enable/Disable coop stat tracking", 0, true, 0.0, true, 1.0);
	cvar_EnableSv = CreateConVar("l4d_stats_enablesv", "1", "Enable/Disable survival stat tracking", 0, true, 0.0, true, 1.0);
	cvar_EnableVersus = CreateConVar("l4d_stats_enableversus", "1", "Enable/Disable versus stat tracking", 0, true, 0.0, true, 1.0);
	cvar_EnableTeamVersus = CreateConVar("l4d_stats_enableteamversus", "1", "[L4D2] Enable/Disable team versus stat tracking", 0, true, 0.0, true, 1.0);
	cvar_EnableRealism = CreateConVar("l4d_stats_enablerealism", "1", "[L4D2] Enable/Disable realism stat tracking", 0, true, 0.0, true, 1.0);
	cvar_EnableScavenge = CreateConVar("l4d_stats_enablescavenge", "1", "[L4D2] Enable/Disable scavenge stat tracking", 0, true, 0.0, true, 1.0);
	cvar_EnableTeamScavenge = CreateConVar("l4d_stats_enableteamscavenge", "1", "[L4D2] Enable/Disable team scavenge stat tracking", 0, true, 0.0, true, 1.0);
	cvar_EnableRealismVersus = CreateConVar("l4d_stats_enablerealismvs", "1", "[L4D2] Enable/Disable realism versus stat tracking", 0, true, 0.0, true, 1.0);
	cvar_EnableTeamRealismVersus = CreateConVar("l4d_stats_enableteamrealismvs", "1", "[L4D2] Enable/Disable team realism versus stat tracking", 0, true, 0.0, true, 1.0);
	cvar_EnableMutations = CreateConVar("l4d_stats_enablemutations", "1", "[L4D2] Enable/Disable mutations stat tracking", 0, true, 0.0, true, 1.0);

	// Game mode depended Cvars
	cvar_RealismMultiplier = CreateConVar("l4d_stats_realismmultiplier", "1", "[L4D2] Realism score multiplier for coop score", 0, true, 1.0);
	cvar_RealismVersusSurMultiplier = CreateConVar("l4d_stats_realismvsmultiplier_s", "1", "[L4D2] Realism score multiplier for survivors versus score", 0, true, 1.0);
	cvar_RealismVersusInfMultiplier = CreateConVar("l4d_stats_realismvsmultiplier_i", "1", "[L4D2] Realism score multiplier for infected versus score", 0, true, 0.0, true, 1.0);
	cvar_EnableSvMedicPoints = CreateConVar("l4d_stats_medicpointssv", "1", "Survival medic points enabled", 0, true, 0.0, true, 1.0);

	// Infected point Cvars
	cvar_Infected = CreateConVar("l4d_stats_infected", "1", "Base score for killing a Common Infected", 0, true, 1.0);
	cvar_Hunter = CreateConVar("l4d_stats_hunter", "3", "Base score for killing a Hunter", 0, true, 1.0);
	cvar_Smoker = CreateConVar("l4d_stats_smoker", "3", "Base score for killing a Smoker", 0, true, 1.0);
	cvar_Boomer = CreateConVar("l4d_stats_boomer", "2", "Base score for killing a Boomer", 0, true, 1.0);
	cvar_Spitter = CreateConVar("l4d_stats_spitter", "3", "[L4D2] Base score for killing a Spitter", 0, true, 1.0);
	cvar_Jockey = CreateConVar("l4d_stats_jockey", "4", "[L4D2] Base score for killing a Jockey", 0, true, 1.0);
	cvar_Charger = CreateConVar("l4d_stats_charger", "5", "[L4D2] Base score for killing a Charger", 0, true, 1.0);
	cvar_InfectedDamage = CreateConVar("l4d_stats_infected_damage", "1", "The amount of damage inflicted to Survivors to earn 1 point", 0, true, 1.0);

	// Misc personal gain Cvars
	cvar_Pills = CreateConVar("l4d_stats_pills", "15", "Base score for giving Pills to a friendly", 0, true, 1.0);
	cvar_Adrenaline = CreateConVar("l4d_stats_adrenaline", "15", "[L4D2] Base score for giving Adrenaline to a friendly", 0, true, 1.0);
	cvar_Medkit = CreateConVar("l4d_stats_medkit", "20", "Base score for using a Medkit on a friendly", 0, true, 1.0);
	cvar_Defib = CreateConVar("l4d_stats_defib", "20", "[L4D2] Base score for using a Defibrillator on a friendly", 0, true, 1.0);
	cvar_SmokerDrag = CreateConVar("l4d_stats_smokerdrag", "2", "Base score for saving a friendly from a Smoker Tongue Drag", 0, true, 1.0);
	cvar_JockeyRide = CreateConVar("l4d_stats_jockeyride", "2", "[L4D2] Base score for saving a friendly from a Jockey Ride", 0, true, 1.0);
	cvar_ChargerPlummel = CreateConVar("l4d_stats_chargerplummel", "5", "[L4D2] Base score for saving a friendly from a Charger Plummel", 0, true, 1.0);
	cvar_ChargerCarry = CreateConVar("l4d_stats_chargercarry", "15", "[L4D2] Base score for saving a friendly from a Charger Carry", 0, true, 1.0);
	cvar_ChokePounce = CreateConVar("l4d_stats_chokepounce", "2", "Base score for saving a friendly from a Hunter Pounce / Smoker Choke", 0, true, 1.0);
	cvar_Revive = CreateConVar("l4d_stats_revive", "10", "Base score for Revive a friendly from Incapacitated state", 0, true, 1.0);
	cvar_Rescue = CreateConVar("l4d_stats_rescue", "10", "Base score for Rescue a friendly from a closet", 0, true, 1.0);
	cvar_Protect = CreateConVar("l4d_stats_protect", "2", "Base score for Protect a friendly in combat", 0, true, 1.0);
	cvar_PlayerLedgeSuccess = CreateConVar("l4d_stats_ledgegrap", "20", "Base score for causing a survivor to grap a ledge", 0, true, 1.0);
	cvar_Matador = CreateConVar("l4d_stats_matador", "20", "[L4D2] Base score for killing a charging Charger with a melee weapon", 0, true, 1.0);
	cvar_WitchCrowned = CreateConVar("l4d_stats_witchcrowned", "30", "Base score for Crowning a Witch", 0, true, 1.0);

	// Team gain Cvars
	cvar_Tank = CreateConVar("l4d_stats_tank", "40", "Base team score for killing a Tank", 0, true, 1.0);
	cvar_Panic = CreateConVar("l4d_stats_panic", "5", "Base team score for surviving a Panic Event with no Incapacitations", 0, true, 1.0);
	cvar_BoomerMob = CreateConVar("l4d_stats_boomermob", "3", "Base team score for surviving a Boomer Mob with no Incapacitations", 0, true, 1.0);
	cvar_SafeHouse = CreateConVar("l4d_stats_safehouse", "50", "Base score for reaching a Safe House", 0, true, 1.0);
	cvar_Witch = CreateConVar("l4d_stats_witch", "5", "Base score for Not Disturbing a Witch", 0, true, 1.0);
	cvar_VictorySurvivors = CreateConVar("l4d_stats_campaign", "45", "Base score for Completing a Campaign", 0, true, 1.0);
	cvar_VictoryInfected = CreateConVar("l4d_stats_infected_win", "35", "Base victory score for Infected Team", 0, true, 1.0);

	// Point loss Cvars
	cvar_FFire = CreateConVar("l4d_stats_ffire", "25", "Base score for Friendly Fire", 0, true, 1.0);
	cvar_FIncap = CreateConVar("l4d_stats_fincap", "75", "Base score for a Friendly Incap", 0, true, 1.0);
	cvar_FKill = CreateConVar("l4d_stats_fkill", "250", "Base score for a Friendly Kill", 0, true, 1.0);
	cvar_InSafeRoom = CreateConVar("l4d_stats_insaferoom", "5", "Base score for letting Infected in the Safe Room", 0, true, 1.0);
	cvar_Restart = CreateConVar("l4d_stats_restart", "200", "Base score for a Round Restart", 0, true, 1.0);
	cvar_MedkitUsedPointPenalty = CreateConVar("l4d_stats_medkitpenalty", "0.1", "Score reduction for all Survivor earned points for each used Medkit (Formula: Score = NormalPoints * (1 - MedkitsUsed * MedkitPenalty))", 0, true, 0.0, true, 0.5);
	cvar_MedkitUsedPointPenaltyMax = CreateConVar("l4d_stats_medkitpenaltymax", "0.6", "Maximum score reduction (the score reduction will not go over this value when a Medkit is used)", 0, true, 0.0, true, 1.0);
	cvar_MedkitUsedFree = CreateConVar("l4d_stats_medkitpenaltyfree", "0", "Team Survivors can use this many Medkits for free without any reduction to the score", 0, true, 0.0);
	cvar_MedkitUsedRealismFree = CreateConVar("l4d_stats_medkitpenaltyfree_r", "4", "Team Survivors can use this many Medkits for free without any reduction to the score when playing in Realism gamemodes (-1 = use the value in l4d_stats_medkitpenaltyfree)", 0, true, -1.0);
	cvar_MedkitBotMode = CreateConVar("l4d_stats_medkitbotmode", "1", "Add score reduction when bot uses a medkit. 0 = No, 1 = Bot uses a Medkit to a human player, 2 = Bot uses a Medkit to other than itself, 3 = Yes", 0, true, 0.0, true, 2.0);
	cvar_CarAlarm = CreateConVar("l4d_stats_caralarm", "50", "[L4D2] Base score for a Triggering Car Alarm", 0, true, 1.0);
	cvar_BotScoreMultiplier = CreateConVar("l4d_stats_botscoremultiplier", "1.0", "Multiplier to use when receiving bot related score penalty. 0 = Disable", 0, true, 0.0);

	// Survivor point Cvars
	cvar_SurvivorDeath = CreateConVar("l4d_stats_survivor_death", "50", "Base score for killing a Survivor", 0, true, 1.0);
	cvar_SurvivorIncap = CreateConVar("l4d_stats_survivor_incap", "25", "Base score for incapacitating a Survivor", 0, true, 1.0);

	// Hunter point Cvars
	cvar_HunterPerfectPounceDamage = CreateConVar("l4d_stats_perfectpouncedamage", "25", "The amount of damage from a pounce to earn Perfect Pounce (Death From Above) success points", 0, true, 1.0);
	cvar_HunterPerfectPounceSuccess = CreateConVar("l4d_stats_perfectpouncesuccess", "25", "Base score for a successful Perfect Pounce", 0, true, 1.0);
	cvar_HunterNicePounceDamage = CreateConVar("l4d_stats_nicepouncedamage", "15", "The amount of damage from a pounce to earn Nice Pounce (Pain From Above) success points", 0, true, 1.0);
	cvar_HunterNicePounceSuccess = CreateConVar("l4d_stats_nicepouncesuccess", "10", "Base score for a successful Nice Pounce", 0, true, 1.0);
	cvar_HunterDamageCap = CreateConVar("l4d_stats_hunterdamagecap", "25", "Hunter stored damage cap", 0, true, 25.0);

	if (EngineVersion1 == Engine_Left4Dead)
	{
		MaxPounceDistance = GetConVarInt(FindConVar("z_pounce_damage_range_max"));
		MinPounceDistance = GetConVarInt(FindConVar("z_pounce_damage_range_min"));
	}
	else
	{
		MaxPounceDistance = 1024;
		MinPounceDistance = 300;
	}
	MaxPounceDamage = GetConVarInt(FindConVar("z_hunter_max_pounce_bonus_damage"));

	// Boomer point Cvars
	cvar_BoomerSuccess = CreateConVar("l4d_stats_boomersuccess", "5", "Base score for a successfully vomiting on survivor", 0, true, 1.0);
	cvar_BoomerPerfectHits = CreateConVar("l4d_stats_boomerperfecthits", "4", "The number of survivors that needs to get blinded to earn Boomer Perfect Vomit Award and success points", 0, true, 4.0);
	cvar_BoomerPerfectSuccess = CreateConVar("l4d_stats_boomerperfectsuccess", "30", "Base score for a successful Boomer Perfect Vomit", 0, true, 1.0);

	// Tank point Cvars
	cvar_TankDamageCap = CreateConVar("l4d_stats_tankdmgcap", "800", "Maximum inflicted damage done by Tank to earn Infected damagepoints", 0, true, 150.0);
	cvar_TankDamageTotal = CreateConVar("l4d_stats_bulldozer", "500", "Damage inflicted by Tank to earn Bulldozer Award and success points", 0, true, 200.0);
	cvar_TankDamageTotalSuccess = CreateConVar("l4d_stats_bulldozersuccess", "50", "Base score for Bulldozer Award", 0, true, 1.0);
	cvar_TankThrowRockSuccess = CreateConVar("l4d_stats_tankthrowrocksuccess", "5", "Base score for a Tank thrown rock hit", 0, true, 0.0);

	// Charger point Cvars
	cvar_ChargerRamSuccess = CreateConVar("l4d_stats_chargerramsuccess", "40", "Base score for a successful Charger Scattering Ram", 0, true, 1.0);
	cvar_ChargerRamHits = CreateConVar("l4d_stats_chargerramhits", "4", "The number of impacts on survivors to earn Scattering Ram Award and success points", 0, true, 2.0);

	// Misc L4D2 Cvars
	cvar_AmmoUpgradeAdded = CreateConVar("l4d_stats_deployammoupgrade", "10", "[L4D2] Base score for deploying ammo upgrade pack", 0, true, 0.0);
	cvar_GascanPoured = CreateConVar("l4d_stats_gascanpoured", "5", "[L4D2] Base score for successfully pouring a gascan", 0, true, 0.0);

	// Other Cvars
	cvar_Top10PPMMin = CreateConVar("l4d_stats_top10ppmplaytime", "30", "Minimum playtime (minutes) to show in top10 ppm list", 0, true, 1.0);
	cvar_RankVoteTime = CreateConVar("l4d_stats_rankvotetime", "20", "Time to wait people to vote", 0, true, 10.0);

	cvar_SoundsEnabled = CreateConVar("l4d_stats_soundsenabled", "1", "Play sounds on certain events", 0, true, 0.0, true, 1.0);

	// Make that config!
	//AutoExecConfig(true, "l4d_stats");

	// Personal Gain Events
	HookEvent("round_end",	Event_RoundEnd);
	HookEvent("player_death", event_PlayerDeath);
	HookEvent("infected_death", event_InfectedDeath);
	HookEvent("tank_killed", event_TankKilled);
	if (EngineVersion1 == Engine_Left4Dead)
	{
		HookEvent("weapon_given", event_GivePills);
	}
	else
	{
		HookEvent("defibrillator_used", event_DefibPlayer);
	}
	HookEvent("heal_success", event_HealPlayer);
	HookEvent("revive_success", event_RevivePlayer);
	HookEvent("tongue_pull_stopped", event_TongueSave);
	HookEvent("choke_stopped", event_ChokeSave);
	HookEvent("pounce_stopped", event_PounceSave);
	HookEvent("lunge_pounce", event_PlayerPounced);
	HookEvent("player_ledge_grab", event_PlayerLedge);
	HookEvent("player_falldamage", event_PlayerFallDamage);
	HookEvent("melee_kill", event_MeleeKill);

	// Personal Loss Events
	HookEvent("friendly_fire", event_FriendlyFire);
	HookEvent("player_incapacitated", event_PlayerIncap);

	// Team Gain Events
	HookEvent("finale_vehicle_leaving", event_CampaignWin);
	HookEvent("map_transition", event_MapTransitionPre, EventHookMode_Pre);
	HookEvent("map_transition", event_MapTransition);
	//HookEvent("create_panic_event", event_PanicEvent);
	HookEvent("player_now_it", event_PlayerBlind);
	//HookEvent("player_no_longer_it", event_PlayerBlindEnd);
	HookEvent("award_earned", event_Award_L4D2);
	HookEvent("witch_spawn", event_WitchSpawn);
	HookEvent("witch_killed", event_WitchCrowned);
	HookEvent("witch_harasser_set", event_WitchDisturb);
	HookEvent("round_start", event_RoundStart);
	// Record player positions when an ability is used
	HookEvent("ability_use", event_AbilityUse);
	// Set player specific counters (BoomerHitCounter etc)
	HookEvent("player_spawn", event_PlayerSpawn);

	// Set player specific counters (BoomerHitCounter etc)
	HookEvent("player_hurt", event_PlayerHurt);

	// Smoker stats
	HookEvent("tongue_grab", event_SmokerGrap);
	HookEvent("tongue_release", event_SmokerRelease);
	if (EngineVersion1 == Engine_Left4Dead)
	{
		HookEvent("tongue_broke_victim_died", event_SmokerRelease);
	}
	HookEvent("choke_end", event_SmokerRelease);
	HookEvent("tongue_broke_bent", event_SmokerRelease);
	// Hooked previously ^
	//HookEvent("choke_stopped", event_SmokerRelease);
	//HookEvent("tongue_pull_stopped", event_SmokerRelease);

	// Hunter stats
	HookEvent("pounce_end", event_HunterRelease);

	if (EngineVersion1 != Engine_Left4Dead)
	{
		// Spitter stats
		//HookEvent("spitter_killed", event_SpitterKilled);

		// Jockey stats
		HookEvent("jockey_ride", event_JockeyStart);
		HookEvent("jockey_ride_end", event_JockeyRelease);
		HookEvent("jockey_killed", event_JockeyKilled);

		// Charger stats
		HookEvent("charger_impact", event_ChargerImpact);
		HookEvent("charger_killed", event_ChargerKilled);
		HookEvent("charger_carry_start", event_ChargerCarryStart);
		HookEvent("charger_carry_end", event_ChargerCarryRelease);
		HookEvent("charger_pummel_start", event_ChargerPummelStart);
		HookEvent("charger_pummel_end", event_ChargerPummelRelease);

		// Misc L4D2 events
		HookEvent("upgrade_pack_used", event_UpgradePackAdded);
		HookEvent("gascan_pour_completed", event_GascanPoured);
		HookEvent("triggered_car_alarm", event_CarAlarm);
		HookEvent("survival_round_start", event_SurvivalStart); // Timed Maps event
		HookEvent("scavenge_round_halftime", event_ScavengeHalftime);
		HookEvent("scavenge_round_start", event_ScavengeRoundStart);
	}

	// Achievements
	HookEvent("achievement_earned", event_Achievement);

	// Timed Maps events
	HookEvent("door_open", event_DoorOpen, EventHookMode_Post); // When the saferoom door opens...
	HookEvent("player_left_start_area", event_StartArea, EventHookMode_Post); // When a survivor leaves the start area...
	HookEvent("player_team", event_PlayerTeam, EventHookMode_Post); // When a survivor changes team...

	// Startup the plugin's timers
	//CreateTimer(1.0, InitPlayers); // Called in OnMapStart
	CreateTimer(60.0, timer_UpdatePlayers, INVALID_HANDLE, TIMER_REPEAT);
	UpdateTimer = CreateTimer(GetConVarFloat(cvar_UpdateRate), timer_ShowTimerScore, INVALID_HANDLE, TIMER_REPEAT);
	HookConVarChange(cvar_UpdateRate, action_TimerChanged);
	HookConVarChange(cvar_DbPrefix, action_DbPrefixChanged);

	// Gamemode
	GetConVarString(cvar_Gamemode, CurrentGamemode, sizeof(CurrentGamemode));
	CurrentGamemodeID = GetCurrentGamemodeID();
	SetCurrentGamemodeName();
	HookConVarChange(cvar_Gamemode, action_GamemodeChanged);
	HookConVarChange(cvar_Difficulty, action_DifficultyChanged);

	//RegConsoleCmd("l4d_stats_test", cmd_StatsTest);

	MapTimingSurvivors = CreateTrie();
	MapTimingInfected = CreateTrie();
	FriendlyFireDamageTrie = CreateTrie();
	PlayerRankVoteTrie = CreateTrie();

	new Handle:topmenu;
	if (LibraryExists("adminmenu") && ((topmenu = GetAdminTopMenu()) != INVALID_HANDLE))
		OnAdminMenuReady(topmenu);

	if (FileExists("addons/sourcemod/gamedata/l4d_stats.txt"))
	{
		// SDK handles for team shuffle
		L4DStatsConf = LoadGameConfigFile("l4d_stats");
		if (L4DStatsConf == INVALID_HANDLE)
		{
			LogError("Could not load gamedata/l4d_stats.txt");
		}
		else
		{
			StartPrepSDKCall(SDKCall_Player);
			PrepSDKCall_SetFromConf(L4DStatsConf, SDKConf_Signature, "SetHumanSpec");
			PrepSDKCall_AddParameter(SDKType_CBasePlayer, SDKPass_Pointer);
			L4DStatsSHS = EndPrepSDKCall();

			StartPrepSDKCall(SDKCall_Player);
			PrepSDKCall_SetFromConf(L4DStatsConf, SDKConf_Signature, "TakeOverBot");
			PrepSDKCall_AddParameter(SDKType_Bool, SDKPass_Plain);
			L4DStatsTOB = EndPrepSDKCall();
		}
	}
	else
	{
		LogMessage("Rank Vote is disabled because could not load gamedata/l4d_stats.txt");
	}

	// Sounds
	if (EnableSounds_Rankvote)
	{
		EnableSounds_Rankvote = PrecacheSound(SOUND_RANKVOTE); // Sound from rankvote team switch
	}
	else
	{
		EnableSounds_Rankvote = true;
	}

	if (EnableSounds_Maptime_Start)
	{
		EnableSounds_Maptime_Start = PrecacheSound(StatsSound_MapTime_Start); // Sound map timer start
	}
	else
	{
		EnableSounds_Maptime_Start = true;
	}

	if (EnableSounds_Maptime_Improve)
	{
		EnableSounds_Maptime_Improve = PrecacheSound(StatsSound_MapTime_Improve); // Sound from improving personal map timing
	}
	else
	{
		EnableSounds_Maptime_Improve = true;
	}

	if (EnableSounds_Rankmenu_Show)
	{
		EnableSounds_Rankmenu_Show = PrecacheSound(StatsSound_Rankmenu_Show); // Sound from showing the rankmenu
	}
	else
	{
		EnableSounds_Rankmenu_Show = true;
	}

	if (EnableSounds_Boomer_Vomit)
	{
		EnableSounds_Boomer_Vomit = PrecacheSound(StatsSound_Boomer_Vomit); // Sound from a successful boomer vomit (Perfect Blindness)
	}
	else
	{
		EnableSounds_Boomer_Vomit = true;
	}

	if (EnableSounds_Hunter_Perfect)
	{
		EnableSounds_Hunter_Perfect = PrecacheSound(StatsSound_Hunter_Perfect); // Sound from a hunter perfect pounce (Death From Above)
	}
	else
	{
		EnableSounds_Hunter_Perfect = true;
	}

	if (EnableSounds_Tank_Bulldozer)
	{
		EnableSounds_Tank_Bulldozer = PrecacheSound(StatsSound_Tank_Bulldozer); // Sound from a tank bulldozer
	}
	else
	{
		EnableSounds_Tank_Bulldozer = true;
	}

	if (EngineVersion1 != Engine_Left4Dead)
	{
		if (EnableSounds_Charger_Ram)
		{
			EnableSounds_Charger_Ram = PrecacheSound(SOUND_CHARGER_RAM); // Sound from a charger scattering ram
		}
		else
		{
			EnableSounds_Charger_Ram = true;
		}
	}
	else
	{
		EnableSounds_Charger_Ram = false;
	}
}


public OnConfigsExecuted()
{
	GetConVarString(cvar_DbPrefix, DbPrefix, sizeof(DbPrefix));

	// Init MySQL connections
	if (!ConnectDB())
	{
		SetFailState("Connecting to database failed. Read error log for further details.");
		return;
	}

	if (CommandsRegistered)
		return;

	CommandsRegistered = true;

	// Register chat commands for rank panels
	RegConsoleCmd("say", cmd_Say);
	RegConsoleCmd("say_team", cmd_Say);

	// Register console commands for rank panels
	RegConsoleCmd("sm_rank", cmd_ShowRank);
	RegConsoleCmd("sm_top10", cmd_ShowTop10);
	RegConsoleCmd("sm_top10ppm", cmd_ShowTop10PPM);
	RegConsoleCmd("sm_nextrank", cmd_ShowNextRank);
	RegConsoleCmd("sm_showtimer", cmd_ShowTimedMapsTimer);
	RegConsoleCmd("sm_showrank", cmd_ShowRanks);
	RegConsoleCmd("sm_showppm", cmd_ShowPPMs);
	RegConsoleCmd("sm_rankvote", cmd_RankVote);
	RegConsoleCmd("sm_timedmaps", cmd_TimedMaps);
	RegConsoleCmd("sm_maptimes", cmd_MapTimes);
	RegConsoleCmd("sm_showmaptimes", cmd_ShowMapTimes);
	RegConsoleCmd("sm_rankmenu", cmd_ShowRankMenu);
	RegConsoleCmd("sm_rankmutetoggle", cmd_ToggleClientRankMute);
	RegConsoleCmd("sm_rankmute", cmd_ClientRankMute);
	RegConsoleCmd("sm_showmotd", cmd_ShowMotd);
	RegConsoleCmd("sm_resetscore", cmd_ResetScore);

	// Register administrator command for clearing all stats (BE CAREFUL)
	//RegAdminCmd("sm_rank_admin", cmd_RankAdmin, ADMFLAG_ROOT, "Display admin panel for Rank");
	//RegAdminCmd("sm_rank_clear", cmd_ClearRank, ADMFLAG_ROOT, "Clear all stats from database (asks a confirmation before clearing the database)");
	//RegAdminCmd("sm_rank_shuffle", cmd_ShuffleTeams, ADMFLAG_KICK, "Shuffle teams by player PPM (Points Per Minute)");
	RegAdminCmd("sm_rank_motd", cmd_SetMotd, ADMFLAG_GENERIC, "Set Message Of The Day");
	
	// Read the settings etc from the database.
	ReadDb();
	GetTop100PlayerScore();
}

// Load our categories and menus

public OnAdminMenuReady(Handle:TopMenu1)
{
	// Block us from being called twice
	if (TopMenu1 == RankAdminMenu)
		return;
/*
	RankAdminMenu = TopMenu;

	// Add a category to the SourceMod menu called "Player Stats"
	AddToTopMenu(RankAdminMenu, "玩家排名系统", TopMenuObject_Category, ClearRankCategoryHandler, INVALID_TOPMENUOBJECT);

	// Get a handle for the catagory we just added so we can add items to it
	new TopMenuObject:statscommands = FindTopMenuCategory(RankAdminMenu, "玩家排名系统");

	// Don't attempt to add items to the catagory if for some reason the catagory doesn't exist
	if (statscommands == INVALID_TOPMENUOBJECT)
		return;

	// The order that items are added to menus has no relation to the order that they appear. Items are sorted alphabetically automatically
	// Assign the menus to global values so we can easily check what a menu is when it is chosen
	MenuClearPlayers = AddToTopMenu(RankAdminMenu, "清除某个玩家统计记录", TopMenuObject_Item, ClearRankTopItemHandler, statscommands, "sm_rank_admin_clearplayers", ADMFLAG_ROOT);
	MenuClearMaps = AddToTopMenu(RankAdminMenu, "清除所有地图统计", TopMenuObject_Item, ClearRankTopItemHandler, statscommands, "sm_rank_admin_clearallmaps", ADMFLAG_ROOT);
	MenuClearAll = AddToTopMenu(RankAdminMenu, "清除所有", TopMenuObject_Item, ClearRankTopItemHandler, statscommands, "sm_rank_admin_clearall", ADMFLAG_ROOT);
	MenuClearTimedMaps = AddToTopMenu(RankAdminMenu, "清除所有地图时间统计数据", TopMenuObject_Item, ClearRankTopItemHandler, statscommands, "sm_rank_admin_cleartimedmaps", ADMFLAG_ROOT);
	MenuRemoveCustomMaps = AddToTopMenu(RankAdminMenu, "清除自定义地图", TopMenuObject_Item, ClearRankTopItemHandler, statscommands, "sm_rank_admin_removecustom", ADMFLAG_ROOT);
	MenuCleanPlayers = AddToTopMenu(RankAdminMenu, "清除玩家数据", TopMenuObject_Item, ClearRankTopItemHandler, statscommands, "sm_rank_admin_removeplayers", ADMFLAG_ROOT);
	MenuClear = AddToTopMenu(RankAdminMenu, "管理员清除", TopMenuObject_Item, ClearRankTopItemHandler, statscommands, "sm_rank_admin_clear", ADMFLAG_ROOT);
	*/
}

public OnLibraryRemoved(const String:name[])
{
	if (StrEqual(name, "adminmenu"))
		RankAdminMenu = INVALID_HANDLE;
	if ( StrEqual(name, "rpg") ) { g_brpgAvailable = false; }
}

public void OnAllPluginsLoaded()
{
	g_brpgAvailable = LibraryExists("rpg");
}


public void OnLibraryAdded(const char[] name)
{
    if ( StrEqual(name, "rpg") ) { g_brpgAvailable = true; }
}
// This handles the top level "Player Stats" category and how it is displayed on the core admin menu

public ClearRankCategoryHandler(Handle:topmenu, TopMenuAction:action, TopMenuObject:object_id, client, String:buffer[], maxlength)
{
	if (action == TopMenuAction_DisplayOption)
		Format(buffer, maxlength, "玩家排名系统");
	else if (action == TopMenuAction_DisplayTitle)
		Format(buffer, maxlength, "玩家排名系统");
}

public Action:Menu_CreateClearMenu(client, args)
{
	new Handle:menu = CreateMenu(Menu_CreateClearMenuHandler);

	SetMenuTitle(menu, "清除:");
	SetMenuExitBackButton(menu, true);
	SetMenuExitButton(menu, true);

	AddMenuItem(menu, "cps", "清除正在游玩玩家的记录");
	AddMenuItem(menu, "ctm", "清除已记录的地图时间数据");

	DisplayMenu(menu, client, 30);

	return Plugin_Handled;
}

public Menu_CreateClearMenuHandler(Handle:menu, MenuAction:action, param1, param2)
{
	switch (action)
	{
		case MenuAction_Select:
		{
			switch (param2)
			{
				case 0:
				{
					DisplayClearPanel(param1);
				}
				case 1:
				{
					Menu_CreateClearTMMenu(param1, 0);
				}
			}
		}
		case MenuAction_End:
		{
			CloseHandle(menu);
		}
		case MenuAction_Cancel:
		{
			if (param2 == MenuCancel_ExitBack && RankAdminMenu != INVALID_HANDLE)
				DisplayTopMenu(RankAdminMenu, param1, TopMenuPosition_LastCategory);
		}
	}
}

public Action:Menu_CreateClearTMMenu(client, args)
{
	new Handle:menu = CreateMenu(Menu_CreateClearTMMenuHandler);

	SetMenuTitle(menu, "清除已记录的地图:");
	SetMenuExitBackButton(menu, true);
	SetMenuExitButton(menu, true);

	AddMenuItem(menu, "ctma",  "所有");
	AddMenuItem(menu, "ctmc",  "战役");
	AddMenuItem(menu, "ctmsu", "生存");
	AddMenuItem(menu, "ctmr",  "写实");
	AddMenuItem(menu, "ctmm",  "突变");

	DisplayMenu(menu, client, 30);

	return Plugin_Handled;
}

public Menu_CreateClearTMMenuHandler(Handle:menu, MenuAction:action, param1, param2)
{
	switch (action)
	{
		case MenuAction_Select:
		{
			switch (param2)
			{
				case 0:
				{
					DisplayYesNoPanel(param1, "你想清除地图记录数据统计吗?", ClearTMAllPanelHandler);
				}
				case 1:
				{
					DisplayYesNoPanel(param1, "你想清除所有战役游戏模式的地图记录统计吗?", ClearTMCoopPanelHandler);
				}
				case 2:
				{
					DisplayYesNoPanel(param1, "你想清除所有生存的地图记录统计吗?", ClearTMSurvivalPanelHandler);
				}
				case 3:
				{
					DisplayYesNoPanel(param1, "你想清除所有写实游戏模式的地图记录统计吗?", ClearTMRealismPanelHandler);
				}
				case 4:
				{
					DisplayYesNoPanel(param1, "你想清除所有突变游戏模式的地图记录统计吗?", ClearTMMutationsPanelHandler);
				}
			}
		}
		case MenuAction_End:
		{
			CloseHandle(menu);
		}
		case MenuAction_Cancel:
		{
			if (param2 == MenuCancel_ExitBack && RankAdminMenu != INVALID_HANDLE)
			{
				DisplayTopMenu(RankAdminMenu, param1, TopMenuPosition_LastCategory);
			}
		}
	}
}

// This deals with what happens someone opens the "Player Stats" category from the menu
public ClearRankTopItemHandler(Handle:topmenu, TopMenuAction:action, TopMenuObject:object_id, client, String:buffer[], maxlength)
{
	// When an item is displayed to a player tell the menu to format the item
	if (action == TopMenuAction_DisplayOption)
	{
		if (object_id == MenuClearPlayers)
		{
			Format(buffer, maxlength, "清除玩家");
		}
		else if (object_id == MenuClearMaps)
		{
			Format(buffer, maxlength, "清除地图");
		}
		else if (object_id == MenuClearAll)
		{
			Format(buffer, maxlength, "清除所有");
		}
		else if (object_id == MenuClearTimedMaps)
		{
			Format(buffer, maxlength, "清除已经记录的时间");
		}
		else if (object_id == MenuRemoveCustomMaps)
		{
			Format(buffer, maxlength, "移除三方地图统计");
		}
		else if (object_id == MenuCleanPlayers)
		{
			Format(buffer, maxlength, "清除玩家");
		}
		else if (object_id == MenuClear)
		{
			Format(buffer, maxlength, "更多");
		}
	}

	// When an item is selected do the following
	else if (action == TopMenuAction_SelectOption)
	{
		if (object_id == MenuClearPlayers)
		{
			DisplayYesNoPanel(client, "你真的想清除这个玩家的玩家记录吗?", ClearPlayersPanelHandler);
		}
		else if (object_id == MenuClearMaps)
		{
			DisplayYesNoPanel(client, "你真的想清除这个玩家的所有地图的统计记录吗?", ClearMapsPanelHandler);
		}
		else if (object_id == MenuClearAll)
		{
			DisplayYesNoPanel(client, "你真的想清除所有玩家的统计记录吗?", ClearAllPanelHandler);
		}
		else if (object_id == MenuClearTimedMaps)
		{
			DisplayYesNoPanel(client, "你真的想清除所有玩家的地图纪律吗?", ClearTMAllPanelHandler);
		}
		else if (object_id == MenuRemoveCustomMaps)
		{
			DisplayYesNoPanel(client, "你真的想去除这张三方地图的统计吗?", RemoveCustomMapsPanelHandler);
		}
		else if (object_id == MenuCleanPlayers)
		{
			DisplayYesNoPanel(client, "你真的想清除这名玩家的游玩记录吗?", CleanPlayersPanelHandler);
		}
		else if (object_id == MenuClear)
		{
			Menu_CreateClearMenu(client, 0);
		}
	}
}

// Reset all boolean variables when a map changes.

public OnMapStart()
{
	GetConVarString(cvar_Gamemode, CurrentGamemode, sizeof(CurrentGamemode));
	CurrentGamemodeID = GetCurrentGamemodeID();
	SetCurrentGamemodeName();
	ResetVars();
}

// Init player on connect, and update total rank and client rank.

public OnClientPostAdminCheck(client)
{
	if (db == INVALID_HANDLE)
	{
		return;
	}

	InitializeClientInf(client);
	PostAdminCheckRetryCounter[client] = 0;

	if (IsClientBot(client))
	{
		return;
	}

	CreateTimer(1.0, ClientPostAdminCheck, client);
}

public Action:ClientPostAdminCheck(Handle:timer, any:client)
{
	if (!IsClientInGame(client))
	{
		if (PostAdminCheckRetryCounter[client]++ < 10)
		{
			CreateTimer(3.0, ClientPostAdminCheck, client);
		}

		return;
	}

	StartRankChangeCheck(client);

	decl String:SteamID[MAX_LINE_WIDTH];
	GetClientRankAuthString(client, SteamID, sizeof(SteamID));

	CheckPlayerDB(client);

	TimerPoints[client] = 0;
	TimerKills[client] = 0;
	TimerHeadshots[client] = 0;

	CreateTimer(10.0, RankConnect, client);
	CreateTimer(15.0, AnnounceConnect, client);

	AnnouncePlayerConnect(client);
}

public OnPluginEnd()
{
	if (db == INVALID_HANDLE)
		return;

	new maxplayers = MaxClients;

	for (new i = 1; i <= maxplayers; i++)
	{
		if (IsClientConnected(i) && IsClientInGame(i) && !IsClientBot(i))
		{
			switch (GetClientTeam(i))
			{
				case TEAM_SURVIVORS:
					InterstitialPlayerUpdate(i);
				case TEAM_INFECTED:
					DoInfectedFinalChecks(i);
			}
		}
	}

	CloseHandle(db);
	db = INVALID_HANDLE;

	CommandsRegistered = false;

	//if (ClearPlayerMenu != INVALID_HANDLE)
	//{
	//	CloseHandle(ClearPlayerMenu);
	//	ClearPlayerMenu = INVALID_HANDLE;
	//}
}

// Show rank on connect.

public Action:RankConnect(Handle:timer, any:value)
{
	if (GetConVarBool(cvar_RankOnJoin) && !InvalidGameMode())
	{
		cmd_ShowRank(value, 0);
	}
}

// Announce on player connect!

public Action:AnnounceConnect(Handle:timer, any:client)
{
	if (!GetConVarBool(cvar_AnnounceMode))
	{
		return;
	}

	if (!IsClientConnected(client) || !IsClientInGame(client))
	{
		if (AnnounceCounter[client] > 10)
		{
			AnnounceCounter[client] = 0;
		}
		else
		{
			AnnounceCounter[client]++;
			CreateTimer(5.0, AnnounceConnect, client);
		}

		return;
	}

	AnnounceCounter[client]++;
	Call_StartForward(AnnounceGameTime);//转发触发
	Call_PushCell(client);//按顺序将参数push进forward传参列表里
	Call_Finish();//转发结束

	ShowMOTD(client);
	StatsPrintToChat2(client, true, "输入 \x05rankmenu \x01来操作 \x04%s\x01!", PLUGIN_NAME);
}

// Update the player's interstitial stats, since they may have
// gotten points between the last update and when they disconnect.

public OnClientDisconnect(client)
{
	InitializeClientInf(client);
	PlayerRankVote[client] = RANKVOTE_NOVOTE;
	ClientRankMute[client] = false;

	if (TimerRankChangeCheck[client] != INVALID_HANDLE)
		CloseHandle(TimerRankChangeCheck[client]);

	TimerRankChangeCheck[client] = INVALID_HANDLE;

	if (IsClientBot(client))
		return;

	if (MapTimingStartTime >= 0.0)
	{
		decl String:ClientID[MAX_LINE_WIDTH];
		GetClientRankAuthString(client, ClientID, sizeof(ClientID));

		RemoveFromTrie(MapTimingSurvivors, ClientID);
		RemoveFromTrie(MapTimingInfected, ClientID);
	}

	if (IsClientInGame(client))
	{
		switch (GetClientTeam(client))
		{
			case TEAM_SURVIVORS:
				InterstitialPlayerUpdate(client);
			case TEAM_INFECTED:
				DoInfectedFinalChecks(client);
		}
	}

	new maxplayers = MaxClients;

	for (new i = 1; i <= maxplayers; i++)
	{
		if (i != client && IsClientConnected(i) && IsClientInGame(i) && !IsClientBot(i))
			return;
	}

	// If we get this far, ALL HUMAN PLAYERS LEFT THE SERVER
	CampaignOver = true;

	if (RankVoteTimer != INVALID_HANDLE)
	{
		CloseHandle(RankVoteTimer);
		RankVoteTimer = INVALID_HANDLE;
	}
}

public action_LanChanged(Handle:convar, const String:oldValue[], const String:newValue[])
{
	if (GetConVarInt(cvar_Lan))
		LogMessage("ATTENTION! %s in LAN environment is based on IP address rather than Steam ID. The statistics are not reliable when they are base on IP!", PLUGIN_NAME);
}

// Update the Database prefix when the Cvar is changed.

public action_DbPrefixChanged(Handle:convar, const String:oldValue[], const String:newValue[])
{
	if (convar == cvar_DbPrefix)
	{
		if (StrEqual(DbPrefix, newValue))
			return;

		if (db != INVALID_HANDLE && !CheckDatabaseValidity(DbPrefix))
		{
			strcopy(DbPrefix, sizeof(DbPrefix), oldValue);
			SetConVarString(cvar_DbPrefix, DbPrefix);
		}
		else
			strcopy(DbPrefix, sizeof(DbPrefix), newValue);
	}
}

// Update the Update Timer when the Cvar is changed.

public action_TimerChanged(Handle:convar, const String:oldValue[], const String:newValue[])
{
	if (convar == cvar_UpdateRate)
	{
		CloseHandle(UpdateTimer);

		new NewTime = StringToInt(newValue);
		UpdateTimer = CreateTimer(float(NewTime), timer_ShowTimerScore, INVALID_HANDLE, TIMER_REPEAT);
	}
}

// Update the CurrentGamemode when the Cvar is changed.

public action_DifficultyChanged(Handle:convar, const String:oldValue[], const String:newValue[])
{
	if (convar == cvar_Difficulty)
	{
		MapTimingStartTime = -1.0;
		MapTimingBlocked = true;
	}
}

// Update the CurrentGamemode when the Cvar is changed.

public action_GamemodeChanged(Handle:convar, const String:oldValue[], const String:newValue[])
{
	if (convar == cvar_Gamemode)
	{
		GetConVarString(cvar_Gamemode, CurrentGamemode, sizeof(CurrentGamemode));
		CurrentGamemodeID = GetCurrentGamemodeID();
		SetCurrentGamemodeName();
	}
}

public SetCurrentGamemodeName()
{
	switch (CurrentGamemodeID)
	{
		case GAMEMODE_COOP:
		{
			Format(CurrentGamemodeLabel, sizeof(CurrentGamemodeLabel), "战役");
		}
		case GAMEMODE_VERSUS:
		{
			Format(CurrentGamemodeLabel, sizeof(CurrentGamemodeLabel), "对抗");
		}
		case GAMEMODE_REALISM:
		{
			Format(CurrentGamemodeLabel, sizeof(CurrentGamemodeLabel), "写实");
		}
		case GAMEMODE_SURVIVAL:
		{
			Format(CurrentGamemodeLabel, sizeof(CurrentGamemodeLabel), "生存");
		}
		case GAMEMODE_SCAVENGE:
		{
			Format(CurrentGamemodeLabel, sizeof(CurrentGamemodeLabel), "清道夫");
		}
		case GAMEMODE_REALISMVERSUS:
		{
			Format(CurrentGamemodeLabel, sizeof(CurrentGamemodeLabel), "写实对抗");
		}
		case GAMEMODE_OTHERMUTATIONS:
		{
			Format(CurrentGamemodeLabel, sizeof(CurrentGamemodeLabel), "突变模式");
		}
		default:
		{
			Format(CurrentGamemodeLabel, sizeof(CurrentGamemodeLabel), "未知模式");
		}
	}

	if (CurrentGamemodeID == GAMEMODE_OTHERMUTATIONS)
	{
		GetConVarString(cvar_Gamemode, CurrentMutation, sizeof(CurrentMutation));
	}
	else
	{
		CurrentMutation[0] = 0;
	}
}

public Action Event_RoundEnd(Handle:event, String:event_name[], bool:dontBroadcast)
{
	if(!g_broundend && (AnneMultiPlayerMode() || SinglePlayerMode())){
		g_broundend = true;
	}else{
		return Plugin_Handled;
	}
	if(!L4D_HasAnySurvivorLeftSafeArea())
		return Plugin_Continue;
	if(!Isstart)
		return Plugin_Continue;
	UpdateMapStat("restarts", 1);
	int Score=200;
	if (!GetConVarBool(cvar_EnableNegativeScore))
		return Plugin_Continue;
	if (AnneMultiPlayerMode() || (FindConVar("survivor_limit").IntValue > 2)){
		Score = 200;
	}
	else{
		Score = 0;
	}
	

	
	for(int i = 1; i <= MaxClients; i++){
		if(IsClientConnected(i) && IsClientInGame(i) && (GetClientTeam(i) == 2 || ClientEnabled[i]) && !IsFakeClient(i) && Score > 0){
			StatsPrintToChat(i, "\x03所有参与玩家 \x01都 \x03掉了 \x04%i \x01分 by \x03大家又坐牢了!", Score);
			decl String:UpdatePoints[32];
			decl String:UserID[MAX_LINE_WIDTH];
			GetClientRankAuthString(i, UserID, sizeof(UserID));

			switch (CurrentGamemodeID)
			{
				case GAMEMODE_VERSUS:
				{
					Format(UpdatePoints, sizeof(UpdatePoints), "points_survivors");
				}
				case GAMEMODE_REALISM:
				{
					Format(UpdatePoints, sizeof(UpdatePoints), "points_realism");
				}
				case GAMEMODE_SURVIVAL:
				{
					Format(UpdatePoints, sizeof(UpdatePoints), "points_survival");
				}
				case GAMEMODE_SCAVENGE:
				{
					Format(UpdatePoints, sizeof(UpdatePoints), "points_scavenge_survivors");
				}
				case GAMEMODE_REALISMVERSUS:
				{
					Format(UpdatePoints, sizeof(UpdatePoints), "points_realism_survivors");
				}
				case GAMEMODE_OTHERMUTATIONS:
				{
					Format(UpdatePoints, sizeof(UpdatePoints), "points_mutations");
				}
				default:
				{
					Format(UpdatePoints, sizeof(UpdatePoints), "points");
				}
			}

			decl String:query[1024];
			Format(query, sizeof(query), "UPDATE %splayers SET %s = %s + %i WHERE steamid = '%s'", DbPrefix, UpdatePoints, UpdatePoints, Score * -1, UserID);
			SendSQLUpdate(query);
		}
	}
	Isstart=false;	
	return Plugin_Continue;
}

// Scavenge round start event (occurs when door opens or players leave the start area)

public Action:event_ScavengeRoundStart(Handle:event, const String:name[], bool:dontBroadcast)
{
	event_RoundStart(event, name, dontBroadcast);

	StartMapTiming();
}

// Called after the connection to the database is established

public Action:event_RoundStart(Handle:event, const String:name[], bool:dontBroadcast)
{
	ResetVars();
	CheckCurrentMapDB();
	MapTimingStartTime = 0.0;
	MapTimingBlocked = false;
	g_broundend = false;
	ResetRankChangeCheck();
}


// Make connection to database.

bool:ConnectDB()
{
	if (db != INVALID_HANDLE)
		return true;

	if (SQL_CheckConfig(DB_CONF_NAME))
	{
		new String:Error[256];
		db = SQL_Connect(DB_CONF_NAME, true, Error, sizeof(Error));

		if (db == INVALID_HANDLE)
		{
			LogError("Failed to connect to database: %s", Error);
			CloseHandle(db);
			return false;
		}
		else if (!SQL_FastQuery(db, "SET NAMES 'utf8mb4'"))
		{
			if (SQL_GetError(db, Error, sizeof(Error)))
				LogError("Failed to update encoding to utf8mb4: %s", Error);
			else
				LogError("Failed to update encoding to utf8mb4: unknown");
			CloseHandle(db);
		}

		if (!CheckDatabaseValidity(DbPrefix))
		{
			LogError("Database is missing required table or tables.");
			CloseHandle(db);
			return false;
		}
	}
	else
	{
		LogError("Databases.cfg missing '%s' entry!", DB_CONF_NAME);
		CloseHandle(db);
		return false;
	}

	return true;
}

bool:CheckDatabaseValidity(const String:Prefix[])
{
	if (!DoFastQuery(0, "SELECT * FROM %splayers WHERE 1 = 2", Prefix) ||
			!DoFastQuery(0, "SELECT * FROM %smaps WHERE 1 = 2", Prefix) ||
			!DoFastQuery(0, "SELECT * FROM %stimedmaps WHERE 1 = 2", Prefix) ||
			!DoFastQuery(0, "SELECT * FROM %ssettings WHERE 1 = 2", Prefix))
	{
		return false;
	}

	return true;
}

public Action:timer_ProtectedFriendly(Handle:timer, any:data)
{
	TimerProtectedFriendly[data] = INVALID_HANDLE;
	new ProtectedFriendlies = ProtectedFriendlyCounter[data];
	ProtectedFriendlyCounter[data] = 0;

	if (data == 0 || !IsClientConnected(data) || !IsClientInGame(data) || IsClientBot(data))
		return;

	new Score = ModifyScoreDifficulty(GetConVarInt(cvar_Protect) * ProtectedFriendlies, 2, 3, TEAM_SURVIVORS);
	AddScore(data, Score);

	UpdateMapStat("points", Score);

	decl String:UpdatePoints[32];
	decl String:UserID[MAX_LINE_WIDTH];
	GetClientRankAuthString(data, UserID, sizeof(UserID));
	decl String:UserName[MAX_LINE_WIDTH];
	GetClientName(data, UserName, sizeof(UserName));

	switch (CurrentGamemodeID)
	{
		case GAMEMODE_VERSUS:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_survivors");
		}
		case GAMEMODE_REALISM:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_realism");
		}
		case GAMEMODE_SURVIVAL:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_survival");
		}
		case GAMEMODE_SCAVENGE:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_scavenge_survivors");
		}
		case GAMEMODE_REALISMVERSUS:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_realism_survivors");
		}
		case GAMEMODE_OTHERMUTATIONS:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_mutations");
		}
		default:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points");
		}
	}

	decl String:query[1024];
	Format(query, sizeof(query), "UPDATE %splayers SET %s = %s + %i, award_protect = award_protect + %i WHERE steamid = '%s'", DbPrefix, UpdatePoints, UpdatePoints, Score, ProtectedFriendlies, UserID);
	SendSQLUpdate(query);

	if (Score > 0)
	{
		new Mode = GetConVarInt(cvar_AnnounceMode);

		if (Mode == 1 || Mode == 2)
			StatsPrintToChat(data, "你\x05 保护队友 \x01获得了 \x04%i \x01分！!", Score);
		else if (Mode == 3)
			StatsPrintToChatAll("\x05%s\x05 保护队友 \x01获得了 \x04%i \x01分！\x01!", UserName, Score);
	}
}
// Team infected damage score

public Action:timer_InfectedDamageCheck(Handle:timer, any:data)
{
	TimerInfectedDamageCheck[data] = INVALID_HANDLE;

	if (data == 0 || IsClientBot(data))
		return;

	new InfectedDamage = GetConVarInt(cvar_InfectedDamage);

	new Score = 0;
	new DamageCounter = 0;

	if (InfectedDamage > 1)
	{
		if (InfectedDamageCounter[data] < InfectedDamage)
			return;

		new TotalDamage = InfectedDamageCounter[data];

		while (TotalDamage >= InfectedDamage)
		{
			DamageCounter += InfectedDamage;
			TotalDamage -= InfectedDamage;
			Score++;
		}
	}
	else
	{
		DamageCounter = InfectedDamageCounter[data];
		Score = InfectedDamageCounter[data];
	}

	Score = ModifyScoreDifficultyFloat(Score, 0.75, 0.5, TEAM_INFECTED);

	if (Score > 0)
	{
		InfectedDamageCounter[data] -= DamageCounter;

		new Mode = GetConVarInt(cvar_AnnounceMode);

		decl String:query[1024];
		decl String:iID[MAX_LINE_WIDTH];

		GetClientRankAuthString(data, iID, sizeof(iID));

		if (CurrentGamemodeID == GAMEMODE_VERSUS)
		{
			Format(query, sizeof(query), "UPDATE %splayers SET points_infected = points_infected + %i WHERE steamid = '%s'", DbPrefix, Score, iID);
		}
		else if (CurrentGamemodeID == GAMEMODE_REALISMVERSUS)
		{
			Format(query, sizeof(query), "UPDATE %splayers SET points_realism_infected = points_realism_infected + %i WHERE steamid = '%s'", DbPrefix, Score, iID);
		}
		else if (CurrentGamemodeID == GAMEMODE_SCAVENGE)
		{
			Format(query, sizeof(query), "UPDATE %splayers SET points_scavenge_infected = points_scavenge_infected + %i WHERE steamid = '%s'", DbPrefix, Score, iID);
		}
		else
		{
			Format(query, sizeof(query), "UPDATE %splayers SET points_mutations = points_mutations + %i WHERE steamid = '%s'", DbPrefix, Score, iID);
		}

		SendSQLUpdate(query);

		UpdateMapStat("points_infected", Score);

		if (Mode == 1 || Mode == 2)
		{
			if (InfectedDamage > 1)
				StatsPrintToChat(data, "你因给生还者造成了 \x04%i \x01分的伤害获得了 \x04%i \x01分！", DamageCounter, Score);
		}
		else if (Mode == 3)
		{
			decl String:Name[MAX_LINE_WIDTH];
			GetClientName(data, Name, sizeof(Name));
			if (InfectedDamage > 1)
				StatsPrintToChatAll("\x05%s 因给生还者造成了 \x04%i \x01分的伤害获得了 \x04%i \x01分!", Name, DamageCounter, Score);
		}
	}
}

// Get Boomer points

GetBoomerPoints(VictimCount)
{
	if (VictimCount <= 0)
		return 0;

	return GetConVarInt(cvar_BoomerSuccess) * VictimCount;
}

// Calculate Boomer vomit hits and check Boomer Perfect Blindness award

public Action:timer_BoomerBlindnessCheck(Handle:timer, any:data)
{
	TimerBoomerPerfectCheck[data] = INVALID_HANDLE;

	if (data > 0 && !IsClientBot(data) && IsClientInGame(data) && GetClientTeam(data) == TEAM_INFECTED && BoomerHitCounter[data] > 0)
	{
		new HitCounter = BoomerHitCounter[data];
		BoomerHitCounter[data] = 0;
		new OriginalHitCounter = HitCounter;
		new BoomerPerfectHits = GetConVarInt(cvar_BoomerPerfectHits);
		new BoomerPerfectSuccess = GetConVarInt(cvar_BoomerPerfectSuccess);
		new Score = 0;
		new AwardCounter = 0;

		//PrintToConsole(0, "timer_BoomerBlindnessCheck -> HitCounter = %i / BoomerPerfectHits = %i", HitCounter, BoomerPerfectHits);

		while (HitCounter >= BoomerPerfectHits)
		{
			HitCounter -= BoomerPerfectHits;
			Score += BoomerPerfectSuccess;
			AwardCounter++;
			//PrintToConsole(0, "timer_BoomerBlindnessCheck -> Score = %i", Score);
		}

		Score += GetBoomerPoints(HitCounter);
		//PrintToConsole(0, "timer_BoomerBlindnessCheck -> Total Score = %i", Score);
		Score = ModifyScoreDifficultyFloat(Score, 0.75, 0.5, TEAM_INFECTED);

		decl String:query[1024];
		decl String:iID[MAX_LINE_WIDTH];
		GetClientRankAuthString(data, iID, sizeof(iID));

		if (CurrentGamemodeID == GAMEMODE_VERSUS)
			Format(query, sizeof(query), "UPDATE %splayers SET points_infected = points_infected + %i, award_perfect_blindness = award_perfect_blindness + %i, infected_boomer_blinded = infected_boomer_blinded + %i, infected_boomer_vomits = infected_boomer_vomits + %i WHERE steamid = '%s'", DbPrefix, Score, AwardCounter, OriginalHitCounter, (BoomerVomitUpdated[data] ? 0 : 1), iID);
		else if (CurrentGamemodeID == GAMEMODE_REALISMVERSUS)
			Format(query, sizeof(query), "UPDATE %splayers SET points_realism_infected = points_realism_infected + %i, award_perfect_blindness = award_perfect_blindness + %i, infected_boomer_blinded = infected_boomer_blinded + %i, infected_boomer_vomits = infected_boomer_vomits + %i WHERE steamid = '%s'", DbPrefix, Score, AwardCounter, OriginalHitCounter, (BoomerVomitUpdated[data] ? 0 : 1), iID);
		else if (CurrentGamemodeID == GAMEMODE_SCAVENGE)
			Format(query, sizeof(query), "UPDATE %splayers SET points_scavenge_infected = points_scavenge_infected + %i, award_perfect_blindness = award_perfect_blindness + %i, infected_boomer_blinded = infected_boomer_blinded + %i, infected_boomer_vomits = infected_boomer_vomits + %i WHERE steamid = '%s'", DbPrefix, Score, AwardCounter, OriginalHitCounter, (BoomerVomitUpdated[data] ? 0 : 1), iID);
		else
			Format(query, sizeof(query), "UPDATE %splayers SET points_mutations = points_mutations + %i, award_perfect_blindness = award_perfect_blindness + %i, infected_boomer_blinded = infected_boomer_blinded + %i, infected_boomer_vomits = infected_boomer_vomits + %i WHERE steamid = '%s'", DbPrefix, Score, AwardCounter, OriginalHitCounter, (BoomerVomitUpdated[data] ? 0 : 1), iID);

		SendSQLUpdate(query);

		if (!BoomerVomitUpdated[data])
			UpdateMapStat("infected_boomer_vomits", 1);
		UpdateMapStat("infected_boomer_blinded", HitCounter);

		BoomerVomitUpdated[data] = false;

		if (Score > 0)
		{
			UpdateMapStat("points_infected", Score);

			new Mode = GetConVarInt(cvar_AnnounceMode);

			if (Mode == 1 || Mode == 2)
			{
				if (AwardCounter > 0)
					StatsPrintToChat(data, "你完美的糊生还者的眼，获得 \x04%i \x01 分!", Score);
				else
					StatsPrintToChat(data, "你获得了 \x04%i \x01分!", Score);
			}
			else if (Mode == 3)
			{
				decl String:Name[MAX_LINE_WIDTH];
				GetClientName(data, Name, sizeof(Name));
				if (AwardCounter > 0)
					StatsPrintToChatAll("\x05%s \x01完美的糊生还者的眼，获得 \x04%i \x01 分!", Name, Score);
				else
					StatsPrintToChatAll("\x05%s \x01获得了 \x04%i \x01分!", Name, Score);
			}
		}

		if (AwardCounter > 0 && EnableSounds_Boomer_Vomit && GetConVarBool(cvar_SoundsEnabled))
			EmitSoundToAll(StatsSound_Boomer_Vomit);
	}
}


// Perform player init.

public Action:InitPlayers(Handle:timer)
{
	if (db == INVALID_HANDLE)
		return;

	decl String:query[64];
	Format(query, sizeof(query), "SELECT COUNT(*) FROM %splayers", DbPrefix);
	SQL_TQuery(db, GetRankTotal, query);

	new maxplayers = MaxClients;

	for (new i = 1; i <= maxplayers; i++)
	{
		if (IsClientConnected(i) && IsClientInGame(i) && !IsClientBot(i))
		{
			CheckPlayerDB(i);

			QueryClientPoints(i);

			TimerPoints[i] = 0;
			TimerKills[i] = 0;
		}
	}
}

QueryClientPoints(Client, SQLTCallback:callback=INVALID_FUNCTION)
{
	decl String:SteamID[MAX_LINE_WIDTH];

	GetClientRankAuthString(Client, SteamID, sizeof(SteamID));
	QueryClientPointsSteamID(Client, SteamID, callback);
}

QueryClientPointsSteamID(Client, const String:SteamID[], SQLTCallback:callback=INVALID_FUNCTION)
{
	if (callback == INVALID_FUNCTION)
		callback = GetClientPoints;

	decl String:query[512];

	Format(query, sizeof(query), "SELECT %s FROM %splayers WHERE steamid = '%s'", DB_PLAYERS_TOTALPOINTS, DbPrefix, SteamID);

	SQL_TQuery(db, callback, query, Client);
}

QueryClientPointsDP(Handle:dp, SQLTCallback:callback)
{
	decl String:query[1024], String:SteamID[MAX_LINE_WIDTH];

	ResetPack(dp);

	ReadPackCell(dp);
	ReadPackString(dp, SteamID, sizeof(SteamID));

	Format(query, sizeof(query), "SELECT %s FROM %splayers WHERE steamid = '%s'", DB_PLAYERS_TOTALPOINTS, DbPrefix, SteamID);

	SQL_TQuery(db, callback, query, dp);
}

QueryClientRank(Client, SQLTCallback:callback=INVALID_FUNCTION)
{
	if (callback == INVALID_FUNCTION)
		callback = GetClientRank;

	decl String:query[256];

	Format(query, sizeof(query), "SELECT COUNT(*) FROM %splayers WHERE %s >= %i", DbPrefix, DB_PLAYERS_TOTALPOINTS, ClientPoints[Client]);

	SQL_TQuery(db, callback, query, Client);
}

QueryClientRankDP(Handle:dp, SQLTCallback:callback)
{
	decl String:query[256];

	ResetPack(dp);

	new Client = ReadPackCell(dp);

	Format(query, sizeof(query), "SELECT COUNT(*) FROM %splayers WHERE %s >= %i", DbPrefix, DB_PLAYERS_TOTALPOINTS, ClientPoints[Client]);

	SQL_TQuery(db, callback, query, dp);
}

QueryClientGameModeRankDP(Handle:dp, SQLTCallback:callback)
{
	if (!InvalidGameMode())
	{
		decl String:query[1024];

		ResetPack(dp);

		new Client = ReadPackCell(dp);

		switch (CurrentGamemodeID)
		{
			case GAMEMODE_VERSUS:
			{
				Format(query, sizeof(query), "SELECT COUNT(*) FROM %splayers WHERE playtime_versus > 0 AND points_survivors + points_infected >= %i", DbPrefix, ClientGameModePoints[Client][GAMEMODE_VERSUS]);
			}
			case GAMEMODE_REALISM:
			{
				Format(query, sizeof(query), "SELECT COUNT(*) FROM %splayers WHERE playtime_realism > 0 AND points_realism >= %i", DbPrefix, ClientGameModePoints[Client][GAMEMODE_REALISM]);
			}
			case GAMEMODE_SURVIVAL:
			{
				Format(query, sizeof(query), "SELECT COUNT(*) FROM %splayers WHERE playtime_survival > 0 AND points_survival >= %i", DbPrefix, ClientGameModePoints[Client][GAMEMODE_SURVIVAL]);
			}
			case GAMEMODE_SCAVENGE:
			{
				Format(query, sizeof(query), "SELECT COUNT(*) FROM %splayers WHERE playtime_scavenge > 0 AND points_scavenge_survivors + points_scavenge_infected >= %i", DbPrefix, ClientGameModePoints[Client][GAMEMODE_SCAVENGE]);
			}
			case GAMEMODE_REALISMVERSUS:
			{
				Format(query, sizeof(query), "SELECT COUNT(*) FROM %splayers WHERE playtime_realismversus > 0 AND points_realism_survivors + points_realism_infected >= %i", DbPrefix, ClientGameModePoints[Client][GAMEMODE_REALISMVERSUS]);
			}
			case GAMEMODE_OTHERMUTATIONS:
			{
				Format(query, sizeof(query), "SELECT COUNT(*) FROM %splayers WHERE playtime_mutations > 0 AND points_mutations >= %i", DbPrefix, ClientGameModePoints[Client][GAMEMODE_OTHERMUTATIONS]);
			}
			default:
			{
				Format(query, sizeof(query), "SELECT COUNT(*) FROM %splayers WHERE playtime > 0 AND points >= %i", DbPrefix, ClientGameModePoints[Client][GAMEMODE_COOP]);
			}
		}

		SQL_TQuery(db, callback, query, dp);
	}
}
/*
QueryClientGameModePoints(Client, SQLTCallback:callback=INVALID_FUNCTION)
{
	decl String:SteamID[MAX_LINE_WIDTH];

	GetClientRankAuthString(Client, SteamID, sizeof(SteamID));
	QueryClientGameModePointsStmID(Client, SteamID, callback);
}

QueryClientGameModePointsStmID(Client, const String:SteamID[], SQLTCallback:callback=INVALID_FUNCTION)
{
	if (cbGetRankTotal == INVALID_HANDLE)
		callback = GetClientGameModePoints;

	decl String:query[1024];

	Format(query, sizeof(query), "SELECT points, points_survivors + points_infected, points_realism, points_survival, points_scavenge_survivors + points_scavenge_infected + points_realism_survivors + points_realism_infected, points_mutations FROM %splayers WHERE steamid = '%s'", DbPrefix, SteamID);

	SQL_TQuery(db, callback, query, Client);
}
*/
QueryClientGameModePointsDP(Handle:dp, SQLTCallback:callback)
{
	decl String:query[1024], String:SteamID[MAX_LINE_WIDTH];

	ResetPack(dp);

	ReadPackCell(dp);
	ReadPackString(dp, SteamID, sizeof(SteamID));

	Format(query, sizeof(query), "SELECT points, points_survivors + points_infected, points_realism, points_survival, points_scavenge_survivors + points_scavenge_infected, points_realism_survivors + points_realism_infected, points_mutations FROM %splayers WHERE steamid = '%s'", DbPrefix, SteamID);

	SQL_TQuery(db, callback, query, dp);
}
/*
QueryRanks()
{
	QueryRank_1();
	QueryRank_2();
}
*/
QueryRank_1(Handle:dp=INVALID_HANDLE, SQLTCallback:callback=INVALID_FUNCTION)
{
	if (callback == INVALID_FUNCTION)
		callback = GetRankTotal;

	decl String:query[1024];

	Format(query, sizeof(query), "SELECT COUNT(*) FROM %splayers", DbPrefix);

	SQL_TQuery(db, callback, query, dp);
}

QueryRank_2(Handle:dp=INVALID_HANDLE, SQLTCallback:callback=INVALID_FUNCTION)
{
	if (callback == INVALID_FUNCTION)
		callback = GetGameModeRankTotal;

	decl String:query[1024];

	switch (CurrentGamemodeID)
	{
		case GAMEMODE_VERSUS:
		{
			Format(query, sizeof(query), "SELECT COUNT(*) FROM %splayers WHERE playtime_versus > 0", DbPrefix);
		}
		case GAMEMODE_REALISM:
		{
			Format(query, sizeof(query), "SELECT COUNT(*) FROM %splayers WHERE playtime_realism > 0", DbPrefix);
		}
		case GAMEMODE_SURVIVAL:
		{
			Format(query, sizeof(query), "SELECT COUNT(*) FROM %splayers WHERE playtime_survival > 0", DbPrefix);
		}
		case GAMEMODE_SCAVENGE:
		{
			Format(query, sizeof(query), "SELECT COUNT(*) FROM %splayers WHERE playtime_scavenge > 0", DbPrefix);
		}
		case GAMEMODE_REALISMVERSUS:
		{
			Format(query, sizeof(query), "SELECT COUNT(*) FROM %splayers WHERE playtime_realismversus > 0", DbPrefix);
		}
		case GAMEMODE_OTHERMUTATIONS:
		{
			Format(query, sizeof(query), "SELECT COUNT(*) FROM %splayers WHERE playtime_mutations > 0", DbPrefix);
		}
		default:
		{
			Format(query, sizeof(query), "SELECT COUNT(*) FROM %splayers WHERE playtime > 0", DbPrefix);
		}
	}

	SQL_TQuery(db, callback, query, dp);
}

QueryClientStats(Client, CallingMethod=CM_UNKNOWN)
{
	decl String:SteamID[MAX_LINE_WIDTH];

	GetClientRankAuthString(Client, SteamID, sizeof(SteamID));
	QueryClientStatsSteamID(Client, SteamID, CallingMethod);
}

QueryClientStatsSteamID(Client, const String:SteamID[], CallingMethod=CM_UNKNOWN)
{
	new Handle:dp = CreateDataPack();

	WritePackCell(dp, Client);
	WritePackString(dp, SteamID);
	WritePackCell(dp, CallingMethod);

	QueryClientStatsDP(dp);
}

QueryClientStatsDP(Handle:dp)
{
	QueryClientGameModePointsDP(dp, QueryClientStatsDP_1);
}

public QueryClientStatsDP_1(Handle:owner, Handle:hndl, const String:error[], any:dp)
{
	if (hndl == INVALID_HANDLE)
	{
		LogError("QueryClientStatsDP_1 Query failed: %s", error);
		return;
	}

	ResetPack(dp);
	GetClientGameModePoints(owner, hndl, error, ReadPackCell(dp));

	QueryClientPointsDP(dp, QueryClientStatsDP_2);
}

public QueryClientStatsDP_2(Handle:owner, Handle:hndl, const String:error[], any:dp)
{
	if (hndl == INVALID_HANDLE)
	{
		LogError("QueryClientStatsDP_2 Query failed: %s", error);
		return;
	}

	ResetPack(dp);
	GetClientPoints(owner, hndl, error, ReadPackCell(dp));

	QueryClientGameModeRankDP(dp, QueryClientStatsDP_3);
}

public QueryClientStatsDP_3(Handle:owner, Handle:hndl, const String:error[], any:dp)
{
	if (hndl == INVALID_HANDLE)
	{
		LogError("QueryClientStatsDP_3 Query failed: %s", error);
		return;
	}

	ResetPack(dp);
	GetClientGameModeRank(owner, hndl, error, ReadPackCell(dp));

	QueryClientRankDP(dp, QueryClientStatsDP_4);
}

public QueryClientStatsDP_4(Handle:owner, Handle:hndl, const String:error[], any:dp)
{
	if (hndl == INVALID_HANDLE)
	{
		LogError("QueryClientStatsDP_4 Query failed: %s", error);
		return;
	}

	ResetPack(dp);
	GetClientRank(owner, hndl, error, ReadPackCell(dp));

	QueryRank_1(dp, QueryClientStatsDP_5);
}

public QueryClientStatsDP_5(Handle:owner, Handle:hndl, const String:error[], any:dp)
{
	if (hndl == INVALID_HANDLE)
	{
		LogError("QueryClientStatsDP_5 Query failed: %s", error);
		return;
	}

	ResetPack(dp);
	GetRankTotal(owner, hndl, error, ReadPackCell(dp));

	QueryRank_2(dp, QueryClientStatsDP_6);
}

public QueryClientStatsDP_6(Handle:owner, Handle:hndl, const String:error[], any:dp)
{
	if (hndl == INVALID_HANDLE)
	{
		if (dp != INVALID_HANDLE)
			CloseHandle(dp);

		LogError("QueryClientStatsDP_6 Query failed: %s", error);
		return;
	}

	decl String:SteamID[MAX_LINE_WIDTH];

	ResetPack(dp);

	new Client = ReadPackCell(dp);
	ReadPackString(dp, SteamID, sizeof(SteamID));
	new CallingMethod = ReadPackCell(dp);

	GetGameModeRankTotal(owner, hndl, error, Client);

	// Callback
	if (CallingMethod == CM_RANK)
	{
		QueryClientStatsDP_Rank(Client, SteamID);
	}
	else if (CallingMethod == CM_TOP10)
	{
		QueryClientStatsDP_Top10(Client, SteamID);
	}
	else if (CallingMethod == CM_NEXTRANK)
	{
		QueryClientStatsDP_NextRank(Client, SteamID);
	}
	else if (CallingMethod == CM_NEXTRANKFULL)
	{
		QueryClientStatsDP_NextRankFull(Client, SteamID);
	}

	// Clean your mess up
	CloseHandle(dp);
	dp = INVALID_HANDLE;
}

QueryClientStatsDP_Rank(Client, const String:SteamID[])
{
	decl String:query[1024];
	Format(query, sizeof(query), "SELECT name, %s, %s, kills, versus_kills_survivors + scavenge_kills_survivors + realism_kills_survivors + mutations_kills_survivors, headshots FROM %splayers WHERE steamid = '%s'", DB_PLAYERS_TOTALPLAYTIME, DB_PLAYERS_TOTALPOINTS, DbPrefix, SteamID);
	SQL_TQuery(db, DisplayRank, query, Client);
}

QueryClientStatsDP_Top10(Client, const String:SteamID[])
{
	decl String:query[1024];
	Format(query, sizeof(query), "SELECT name, %s, %s, kills, versus_kills_survivors + scavenge_kills_survivors + realism_kills_survivors + mutations_kills_survivors, headshots FROM %splayers WHERE steamid = '%s'", DB_PLAYERS_TOTALPLAYTIME, DB_PLAYERS_TOTALPOINTS, DbPrefix, SteamID);
	SQL_TQuery(db, DisplayRank, query, Client);
}

QueryClientStatsDP_NextRank(Client, const String:SteamID[])
{
	decl String:query[1024];
	Format(query, sizeof(query), "SELECT (%s + 1) - %i FROM %splayers WHERE (%s) >= %i AND steamid <> '%s' ORDER BY (%s) ASC LIMIT 1", DB_PLAYERS_TOTALPOINTS, ClientPoints[Client], DbPrefix, DB_PLAYERS_TOTALPOINTS, ClientPoints[Client], SteamID, DB_PLAYERS_TOTALPOINTS);
	SQL_TQuery(db, DisplayClientNextRank, query, Client);

	if (TimerRankChangeCheck[Client] != INVALID_HANDLE)
		TriggerTimer(TimerRankChangeCheck[Client], true);
}

QueryClientStatsDP_NextRankFull(Client, const String:SteamID[])
{
	decl String:query[2048];
	Format(query, sizeof(query), "SELECT (%s + 1) - %i FROM %splayers WHERE (%s) >= %i AND steamid <> '%s' ORDER BY (%s) ASC LIMIT 1", DB_PLAYERS_TOTALPOINTS, ClientPoints[Client], DbPrefix, DB_PLAYERS_TOTALPOINTS, ClientPoints[Client], SteamID, DB_PLAYERS_TOTALPOINTS);
	SQL_TQuery(db, GetClientNextRank, query, Client);

	decl String:query1[1024], String:query2[256], String:query3[1024];
	Format(query1, sizeof(query1), "SELECT name, (%s) AS totalpoints FROM %splayers WHERE (%s) >= %i AND steamid <> '%s' ORDER BY totalpoints ASC LIMIT 3", DB_PLAYERS_TOTALPOINTS, DbPrefix, DB_PLAYERS_TOTALPOINTS, ClientPoints[Client], SteamID);
	Format(query2, sizeof(query2), "SELECT name, %i AS totalpoints FROM %splayers WHERE steamid = '%s'", ClientPoints[Client], DbPrefix, SteamID);
	Format(query3, sizeof(query3), "SELECT name, (%s) as totalpoints FROM %splayers WHERE (%s) < %i ORDER BY totalpoints DESC LIMIT 3", DB_PLAYERS_TOTALPOINTS, DbPrefix, DB_PLAYERS_TOTALPOINTS, ClientPoints[Client]);
	Format(query, sizeof(query), "(%s) UNION (%s) UNION (%s) ORDER BY totalpoints DESC", query1, query2, query3);
	SQL_TQuery(db, DisplayNextRankFull, query, Client);

	if (TimerRankChangeCheck[Client] != INVALID_HANDLE)
		TriggerTimer(TimerRankChangeCheck[Client], true);
}

// Check if a map is already in the DB.

CheckCurrentMapDB()
{
	if (StatsDisabled(true))
		return;

	decl String:MapName[MAX_LINE_WIDTH];
	GetCurrentMap(MapName, sizeof(MapName));

	decl String:query[512];
	Format(query, sizeof(query), "SELECT name FROM %smaps WHERE LOWER(name) = LOWER('%s') AND gamemode = %i AND mutation = '%s'", DbPrefix, MapName, GetCurrentGamemodeID(), CurrentMutation);

	SQL_TQuery(db, InsertMapDB, query);
}

// Insert a map into the database if they do not already exist.

public InsertMapDB(Handle:owner, Handle:hndl, const String:error[], any:data)
{
	if (db == INVALID_HANDLE)
		return;

	if (StatsDisabled(true))
		return;

	if (!SQL_GetRowCount(hndl))
	{
		decl String:MapName[MAX_LINE_WIDTH];
		GetCurrentMap(MapName, sizeof(MapName));

		decl String:query[512];
		Format(query, sizeof(query), "INSERT IGNORE INTO %smaps SET name = LOWER('%s'), custom = 1, gamemode = %i", DbPrefix, MapName, GetCurrentGamemodeID());

		SQL_TQuery(db, SQLErrorCheckCallback, query);
	}
}

// Check if a player is already in the DB, and update their timestamp and playtime.

CheckPlayerDB(client)
{
	if (StatsDisabled())
		return;

	if (IsClientBot(client))
		return;

	decl String:SteamID[MAX_LINE_WIDTH];
	GetClientRankAuthString(client, SteamID, sizeof(SteamID));

	decl String:query[512];
	Format(query, sizeof(query), "SELECT steamid FROM %splayers WHERE steamid = '%s'", DbPrefix, SteamID);
	SQL_TQuery(db, InsertPlayerDB, query, client);

	ReadClientRankMuteSteamID(client, SteamID);
}

ReadClientRankMute(Client)
{
	// Check stats disabled and is client bot before calling this method!

	decl String:SteamID[MAX_LINE_WIDTH];
	GetClientRankAuthString(Client, SteamID, sizeof(SteamID));

	ReadClientRankMuteSteamID(Client, SteamID);
}

ReadClientRankMuteSteamID(Client, const String:SteamID[])
{
	// Check stats disabled and is client bot before calling this method!

	decl String:query[512];
	Format(query, sizeof(query), "SELECT mute FROM %ssettings WHERE steamid = '%s'", DbPrefix, SteamID);
	SQL_TQuery(db, GetClientRankMute, query, Client);
}

// Insert a player into the database if they do not already exist.

public InsertPlayerDB(Handle:owner, Handle:hndl, const String:error[], any:client)
{
	if (db == INVALID_HANDLE || IsClientBot(client))
	{
		return;
	}

	if (hndl == INVALID_HANDLE)
	{
		LogError("InsertPlayerDB failed! Reason: %s", error);
		return;
	}

	if (StatsDisabled())
	{
		return;
	}

	if (!SQL_GetRowCount(hndl))
	{
		new String:SteamID[MAX_LINE_WIDTH];
		GetClientRankAuthString(client, SteamID, sizeof(SteamID));

		new String:query[512];
		Format(query, sizeof(query), "INSERT IGNORE INTO %splayers SET steamid = '%s'", DbPrefix, SteamID);
		SQL_TQuery(db, SQLErrorCheckCallback, query);
	}

	UpdatePlayer(client);
}

// Insert a player into the settings database if they do not already exist.

public SetClientRankMute(Handle:owner, Handle:hndl, const String:error[], any:client)
{
	if (db == INVALID_HANDLE || IsClientBot(client))
		return;

	if (hndl == INVALID_HANDLE)
	{
		LogError("SetClientRankMute failed! Reason: %s", error);
		return;
	}

	if (StatsDisabled())
		return;

	if (SQL_GetAffectedRows(owner) == 0)
	{
		// Something went wrong!
		ClientRankMute[client] = false;
		return;
	}

	ReadClientRankMute(client);
}

// Insert a player into the settings database if they do not already exist.

public GetClientRankMute(Handle:owner, Handle:hndl, const String:error[], any:client)
{
	if (db == INVALID_HANDLE || IsClientBot(client))
	{
		return;
	}

	if (hndl == INVALID_HANDLE)
	{
		LogError("GetClientRankMute failed! Reason: %s", error);
		return;
	}

	if (StatsDisabled())
	{
		return;
	}

	if (!SQL_GetRowCount(hndl))
	{
		new String:SteamID[MAX_LINE_WIDTH];
		GetClientRankAuthString(client, SteamID, sizeof(SteamID));

		new String:query[512];
		Format(query, sizeof(query), "INSERT IGNORE INTO %ssettings SET steamid = '%s'", DbPrefix, SteamID);
		SQL_TQuery(db, SetClientRankMute, query, client);
	}
	else
	{
		while (SQL_FetchRow(hndl))
		{
			ClientRankMute[client] = (SQL_FetchInt(hndl, 0) != 0);
		}
	}
}

// Run a SQL query, used for UPDATE's only.

SendSQLUpdate(const String:query[], SQLTCallback:callback=INVALID_FUNCTION)
{
	if (db == INVALID_HANDLE)
	{
		return;
	}

	if (callback == INVALID_FUNCTION)
	{
		callback = SQLErrorCheckCallback;
	}

	if (DEBUG)
	{
		if (QueryCounter >= 256)
		{
			QueryCounter = 0;
		}

		new queryid = QueryCounter++;

		Format(QueryBuffer[queryid], MAX_QUERY_COUNTER, query);

		SQL_TQuery(db, callback, query, queryid);
	}
	else
	{
		SQL_TQuery(db, callback, query);
	}
}

// Report error on sql query;

public SQLErrorCheckCallback(Handle:owner, Handle:hndl, const String:error[], any:queryid)
{
	if (db == INVALID_HANDLE)
	{
		return;
	}

	if(!StrEqual("", error))
	{
		if (DEBUG)
		{
			LogError("SQL Error: %s (Query: \"%s\")", error, QueryBuffer[queryid]);
		}
		else
		{
			LogError("SQL Error: %s", error);
		}
	}
}

stock bool IsPlayer(int client)
{
	int team = GetClientTeam(client);
	return (team == 2 || team == 3);
}

// Perform player update of name, playtime, and timestamp.

public UpdatePlayer(client)
{
	if (!IsClientConnected(client) && !IsClientInGame(client))
	{
		return;
	}


	decl String:SteamID[MAX_LINE_WIDTH];
	GetClientRankAuthString(client, SteamID, sizeof(SteamID));

	decl String:Name[MAX_LINE_WIDTH];
	GetClientName(client, Name, sizeof(Name));

	ReplaceString(Name, sizeof(Name), "<?php", "");
	ReplaceString(Name, sizeof(Name), "<?PHP", "");
	ReplaceString(Name, sizeof(Name), "?>", "");
	ReplaceString(Name, sizeof(Name), "\\", "");
	ReplaceString(Name, sizeof(Name), "\"", "");
	ReplaceString(Name, sizeof(Name), "'", "");
	ReplaceString(Name, sizeof(Name), ";", "");
	ReplaceString(Name, sizeof(Name), "�", "");
	ReplaceString(Name, sizeof(Name), "`", "");

	UpdatePlayerFull(client, SteamID, Name);
}

// Perform player update of name, playtime, and timestamp.

public UpdatePlayerFull(Client, const String:SteamID[], const String:Name[])
{
	// Client can be ZERO! Look at UpdatePlayerCallback.

	decl String:Playtime[32];

	switch (CurrentGamemodeID)
	{
		case GAMEMODE_VERSUS:
		{
			Format(Playtime, sizeof(Playtime), "playtime_versus");
		}
		case GAMEMODE_REALISM:
		{
			Format(Playtime, sizeof(Playtime), "playtime_realism");
		}
		case GAMEMODE_SURVIVAL:
		{
			Format(Playtime, sizeof(Playtime), "playtime_survival");
		}
		case GAMEMODE_SCAVENGE:
		{
			Format(Playtime, sizeof(Playtime), "playtime_scavenge");
		}
		case GAMEMODE_REALISMVERSUS:
		{
			Format(Playtime, sizeof(Playtime), "playtime_realismversus");
		}
		case GAMEMODE_OTHERMUTATIONS:
		{
			Format(Playtime, sizeof(Playtime), "playtime_mutations");
		}
		default:
		{
			Format(Playtime, sizeof(Playtime), "playtime");
		}
	}

	decl String:IP[16];
	GetClientIP(Client, IP, sizeof(IP));

	decl String:query[512];	
	//方便网页显示具体游玩模式
	int mode = 0;
	if(IsAnne() == 1)
	{
		mode = 1;
	}else if(IsWitchParty())
	{
		mode = 2;
	}else if(IsAllCharger())
	{
		mode = 3;
	}else if(IsAlone())
	{
		mode = 4;
	}else if(Is1vht())
	{
		mode = 5;
	}else if(IsAnne() == 2)
	{
		mode = 6;
	}
	//旁观者更新时间戳，但是不增加游戏时间，这样来方便统计在线人数
	if(!IsPlayer(Client))
		Format(query, sizeof(query), "UPDATE %splayers SET lastontime = UNIX_TIMESTAMP(), lastannemode = %i, lastgamemode = %i, name = '%s', ip = '%s' WHERE steamid = '%s'", DbPrefix, mode, CurrentGamemodeID, Name, IP, SteamID);
	else
		Format(query, sizeof(query), "UPDATE %splayers SET lastontime = UNIX_TIMESTAMP(), %s = %s + 1, lastannemode = %i, lastgamemode = %i, name = '%s', ip = '%s' WHERE steamid = '%s'", DbPrefix, Playtime, Playtime, mode, CurrentGamemodeID, Name, IP, SteamID);
	
	SQL_TQuery(db, UpdatePlayerCallback, query, Client);
}

// Report error on sql query;

public UpdatePlayerCallback(Handle:owner, Handle:hndl, const String:error[], any:client)
{
	if (db == INVALID_HANDLE)
	{
		return;
	}

	if (!StrEqual("", error))
	{
		if (client > 0)
		{
			decl String:SteamID[MAX_LINE_WIDTH];
			GetClientRankAuthString(client, SteamID, sizeof(SteamID));

			UpdatePlayerFull(0, SteamID, "INVALID_CHARACTERS");

			return;
		}

		LogError("SQL Error: %s", error);
	}
}

// Perform a map stat update.
public UpdateMapStat(const String:Field[], Score)
{
	if (Score <= 0)
	{
		return;
	}

	decl String:MapName[64];
	GetCurrentMap(MapName, sizeof(MapName));

	decl String:DiffSQL[MAX_LINE_WIDTH];
	decl String:Difficulty[MAX_LINE_WIDTH];
	GetConVarString(cvar_Difficulty, Difficulty, sizeof(Difficulty));

	if (StrEqual(Difficulty, "normal", false)) Format(DiffSQL, sizeof(DiffSQL), "nor");
	else if (StrEqual(Difficulty, "hard", false)) Format(DiffSQL, sizeof(DiffSQL), "adv");
	else if (StrEqual(Difficulty, "impossible", false)) Format(DiffSQL, sizeof(DiffSQL), "exp");
	else return;

	decl String:FieldSQL[MAX_LINE_WIDTH];
	Format(FieldSQL, sizeof(FieldSQL), "%s_%s", Field, DiffSQL);

	decl String:query[512];
	Format(query, sizeof(query), "UPDATE %smaps SET %s = %s + %i WHERE LOWER(name) = LOWER('%s') and gamemode = %i", DbPrefix, FieldSQL, FieldSQL, Score, MapName, GetCurrentGamemodeID());
	SendSQLUpdate(query);
}

// Perform a map stat update.
public UpdateMapStatFloat(const String:Field[], Float:Value)
{
	if (Value <= 0)
	{
		return;
	}

	decl String:MapName[64];
	GetCurrentMap(MapName, sizeof(MapName));

	decl String:DiffSQL[MAX_LINE_WIDTH];
	decl String:Difficulty[MAX_LINE_WIDTH];
	GetConVarString(cvar_Difficulty, Difficulty, sizeof(Difficulty));

	if (StrEqual(Difficulty, "normal", false)) Format(DiffSQL, sizeof(DiffSQL), "nor");
	else if (StrEqual(Difficulty, "hard", false)) Format(DiffSQL, sizeof(DiffSQL), "adv");
	else if (StrEqual(Difficulty, "impossible", false)) Format(DiffSQL, sizeof(DiffSQL), "exp");
	else return;

	decl String:FieldSQL[MAX_LINE_WIDTH];
	Format(FieldSQL, sizeof(FieldSQL), "%s_%s", Field, DiffSQL);

	decl String:query[512];
	Format(query, sizeof(query), "UPDATE %smaps SET %s = %s + %f WHERE LOWER(name) = LOWER('%s') and gamemode = %i", DbPrefix, FieldSQL, FieldSQL, Value, MapName, GetCurrentGamemodeID());
	SendSQLUpdate(query);
}

// End blinded state.

public Action:timer_EndBoomerBlinded(Handle:timer, any:data)
{
	PlayerBlinded[data][0] = 0;
	PlayerBlinded[data][1] = 0;
}

// End blinded state.

public Action:timer_EndSmokerParalyzed(Handle:timer, any:data)
{
	PlayerParalyzed[data][0] = 0;
	PlayerParalyzed[data][1] = 0;
}

// End lunging state.

public Action:timer_EndHunterLunged(Handle:timer, any:data)
{
	PlayerLunged[data][0] = 0;
	PlayerLunged[data][1] = 0;
}

// End plummel state.

public Action:timer_EndChargerPlummel(Handle:timer, any:data)
{
	ChargerPlummelVictim[PlayerPlummeled[data][1]] = 0;
	PlayerPlummeled[data][0] = 0;
	PlayerPlummeled[data][1] = 0;
}

// End charge impact counter state.

public Action:timer_EndCharge(Handle:timer, any:data)
{
	ChargerImpactCounterTimer[data] = INVALID_HANDLE;
	new Counter = ChargerImpactCounter[data];
	ChargerImpactCounter[data] = 0;

	new Score = 0;
	new String:ScoreSet[256] = "";

	if (Counter >= GetConVarInt(cvar_ChargerRamHits))
	{
		Score = ModifyScoreDifficultyFloat(GetConVarInt(cvar_ChargerRamSuccess), 0.9, 0.8, TEAM_INFECTED);

		if (CurrentGamemodeID == GAMEMODE_VERSUS)
		{
			Format(ScoreSet, sizeof(ScoreSet), "points_infected = points_infected + %i", Score);
		}
		else if (CurrentGamemodeID == GAMEMODE_REALISMVERSUS)
		{
			Format(ScoreSet, sizeof(ScoreSet), "points_realism_infected = points_realism_infected + %i", Score);
		}
		else if (CurrentGamemodeID == GAMEMODE_SCAVENGE)
		{
			Format(ScoreSet, sizeof(ScoreSet), "points_scavenge_infected = points_scavenge_infected + %i", Score);
		}
		else
		{
			Format(ScoreSet, sizeof(ScoreSet), "points_mutations = points_mutations + %i", Score);
		}

		StrCat(ScoreSet, sizeof(ScoreSet), ", award_scatteringram = award_scatteringram + 1, ");

		if (EnableSounds_Charger_Ram && GetConVarBool(cvar_SoundsEnabled))
			EmitSoundToAll(SOUND_CHARGER_RAM);
	}
	//UPDATE players SET points_infected = points_infected + 40, award_scatteringram = acharger_impacts = charger_impacts + 4 WHERE steamid = 'STEAM_1:1:12345678'

	decl String:AttackerID[MAX_LINE_WIDTH];
	GetClientRankAuthString(data, AttackerID, sizeof(AttackerID));

	decl String:query[512];
	Format(query, sizeof(query), "UPDATE %splayers SET %scharger_impacts = charger_impacts + %i WHERE steamid = '%s'", DbPrefix, ScoreSet, Counter, AttackerID);
	SendSQLUpdate(query);

	if (Score > 0)
		UpdateMapStat("points_infected", Score);

	if (Counter > 0)
		UpdateMapStat("charger_impacts", Counter);

	new Mode = 0;
	if (Score > 0)
		Mode = GetConVarInt(cvar_AnnounceMode);

	if ((Mode == 1 || Mode == 2) && IsClientConnected(data) && IsClientInGame(data))
		StatsPrintToChat(data, "你用牛撞了\x03%i \x01幸存者获得了 \x04%i \x01分!", Counter, Score);
	else if (Mode == 3)
	{
		decl String:AttackerName[MAX_LINE_WIDTH];
		GetClientName(data, AttackerName, sizeof(AttackerName));
		StatsPrintToChatAll("\x05%s \x01用牛撞了\x03%i \x01幸存者获得了 \x04%i \x01分s!", AttackerName, Counter, Score);
	}
}

// End carried state.

public Action:timer_EndChargerCarry(Handle:timer, any:data)
{
	ChargerCarryVictim[PlayerCarried[data][1]] = 0;
	PlayerCarried[data][0] = 0;
	PlayerCarried[data][1] = 0;
}

// End jockey ride state.

public Action:timer_EndJockeyRide(Handle:timer, any:data)
{
	JockeyVictim[PlayerCarried[data][1]] = 0;
	PlayerJockied[data][0] = 0;
	PlayerJockied[data][1] = 0;
}

// End friendly fire damage counter.

public Action:timer_FriendlyFireDamageEnd(Handle:timer, any:dp)
{
	ResetPack(dp);

	new HumanDamage = ReadPackCell(dp);
	new BotDamage = ReadPackCell(dp);
	new Attacker = ReadPackCell(dp);

	// This may fail! What happens when a player skips and another joins with the same Client ID (is this even possible in such short time?)
	FriendlyFireTimer[Attacker][0] = INVALID_HANDLE;

	decl String:AttackerID[MAX_LINE_WIDTH];
	ReadPackString(dp, AttackerID, sizeof(AttackerID));
	decl String:AttackerName[MAX_LINE_WIDTH];
	ReadPackString(dp, AttackerName, sizeof(AttackerName));

	// The damage is read and turned into lost points...
	ResetPack(dp);
	WritePackCell(dp, 0); // Human damage
	WritePackCell(dp, 0); // Bot damage

	if (HumanDamage <= 0 && BotDamage <= 0)
		return;

	new Score = 0;
		
	if (GetConVarBool(cvar_EnableNegativeScore))
	{
		if (HumanDamage > 0)
			Score += ModifyScoreDifficultyNR(RoundToNearest(GetConVarFloat(cvar_FriendlyFireMultiplier) * HumanDamage), 2, 4, TEAM_SURVIVORS);

		if (BotDamage > 0)
			{
				new Float:BotScoreMultiplier = GetConVarFloat(cvar_BotScoreMultiplier);

				if (BotScoreMultiplier > 0.0)
					Score += ModifyScoreDifficultyNR(RoundToNearest(GetConVarFloat(cvar_FriendlyFireMultiplier) * BotDamage), 2, 4, TEAM_SURVIVORS);
			}
		}
        char UpdatePoints[32];
        switch (CurrentGamemodeID)
		{
			case GAMEMODE_VERSUS:
			{
				Format(UpdatePoints, sizeof(UpdatePoints), "points_survivors");
			}
			case GAMEMODE_REALISM:
			{
				Format(UpdatePoints, sizeof(UpdatePoints), "points_realism");
			}
			case GAMEMODE_SURVIVAL:
			{
				Format(UpdatePoints, sizeof(UpdatePoints), "points_survival");
			}
			case GAMEMODE_SCAVENGE:
			{
				Format(UpdatePoints, sizeof(UpdatePoints), "points_scavenge_survivors");
			}
			case GAMEMODE_REALISMVERSUS:
			{
				Format(UpdatePoints, sizeof(UpdatePoints), "points_realism_survivors");
			}
			case GAMEMODE_OTHERMUTATIONS:
			{
				Format(UpdatePoints, sizeof(UpdatePoints), "points_mutations");
			}
			default:
			{
				Format(UpdatePoints, sizeof(UpdatePoints), "points");
			}
		}
        if(IsNormalMode()){
			Score = RoundToFloor(Score / 5.0);
		}

        decl String:query[1024];
        Format(query, sizeof(query), "UPDATE %splayers SET %s = %s - %i, award_friendlyfire = award_friendlyfire + 1 WHERE steamid = '%s'", DbPrefix, UpdatePoints, UpdatePoints, Score, AttackerID);
        SendSQLUpdate(query);
        
        new Mode = 0;
        if (Score > 0)
        	Mode = GetConVarInt(cvar_AnnounceMode);
        
        if ((Mode == 1 || Mode == 2) && IsClientConnected(Attacker) && IsClientInGame(Attacker))
        	StatsPrintToChat(Attacker, "你因为造成了\x05(%i 血)的友伤\x01  \x03失去了 \x04%i \x01分!", HumanDamage + BotDamage, Score);
        else if (Mode == 3)
        	StatsPrintToChatAll("\x05%s \x01因为造成了\x05(%i 血)的友伤\x01  \x03失去了 \x04%i \x01分!", AttackerName,HumanDamage + BotDamage, Score );

}

// Start team shuffle.

public Action:timer_ShuffleTeams(Handle:timer, any:data)
{
	if (CheckHumans())
		return;

	decl String:query[1024];
	Format(query, sizeof(query), "SELECT steamid FROM %splayers WHERE ", DbPrefix);

	new maxplayers = MaxClients;
	decl String:SteamID[MAX_LINE_WIDTH], String:where[512];
	new counter = 0, team;

	for (new i = 1; i <= maxplayers; i++)
	{
		if (IsClientBot(i) || !IsClientConnected(i) || !IsClientInGame(i))
			continue;

		team = GetClientTeam(i);

		if (team != TEAM_SURVIVORS && team != TEAM_INFECTED)
			continue;

		if (counter++ > 0)
			StrCat(query, sizeof(query), "OR ");

		GetClientRankAuthString(i, SteamID, sizeof(SteamID));
		Format(where, sizeof(where), "steamid = '%s' ", SteamID);
		StrCat(query, sizeof(query), where);
	}

	if (counter <= 1)
	{
		StatsPrintToChatAllPreFormatted2(true, "Team shuffle by player PPM failed because there was \x03not enough players\x01!");
		return;
	}

	Format(where, sizeof(where), "ORDER BY (%s) / (%s) DESC", DB_PLAYERS_TOTALPOINTS, DB_PLAYERS_TOTALPLAYTIME);
	StrCat(query, sizeof(query), where);

	SQL_TQuery(db, ExecuteTeamShuffle, query);
}

// End of RANKVOTE.

public Action:timer_RankVote(Handle:timer, any:data)
{
	RankVoteTimer = INVALID_HANDLE;

	if (!CheckHumans())
	{
		new humans = 0, votes = 0, yesvotes = 0, novotes = 0, WinningVoteCount = 0;

		CheckRankVotes(humans, votes, yesvotes, novotes, WinningVoteCount);

		StatsPrintToChatAll2(true, "Vote to shuffle teams by player PPM \x03%s \x01with \x04%i (yes) against %i (no)\x01.", (yesvotes > novotes ? "PASSED" : "DID NOT PASS"), yesvotes, novotes);

		if (yesvotes > novotes)
		{
			CreateTimer(3.0, timer_ShuffleTeams);
		}
	}
}

// End friendly fire cooldown.

public Action:timer_FriendlyFireCooldownEnd(Handle:timer, any:data)
{
	FriendlyFireCooldown[FriendlyFirePrm[data][0]][FriendlyFirePrm[data][1]] = false;
	FriendlyFireTimer[FriendlyFirePrm[data][0]][FriendlyFirePrm[data][1]] = INVALID_HANDLE;
}

// End friendly fire cooldown.

public Action:timer_MeleeKill(Handle:timer, any:data)
{
	MeleeKillTimer[data] = INVALID_HANDLE;
	new Counter = MeleeKillCounter[data];
	MeleeKillCounter[data] = 0;

	if (Counter <= 0 || IsClientBot(data) || !IsClientConnected(data) || !IsClientInGame(data) || GetClientTeam(data) != TEAM_SURVIVORS)
		return;

	decl String:query[512], String:clientID[MAX_LINE_WIDTH];
	GetClientRankAuthString(data, clientID, sizeof(clientID));
	Format(query, sizeof(query), "UPDATE %splayers SET melee_kills = melee_kills + %i WHERE steamid = '%s'", DbPrefix, Counter, clientID);
	SendSQLUpdate(query);
}

// Perform minutely updates of player database.
// Reports Disabled message if in Versus, Easy mode, not enough Human players, and if cheats are active.

public Action:timer_UpdatePlayers(Handle:timer, Handle:hndl)
{
	if (CheckHumans())
	{
		if (GetConVarBool(cvar_DisabledMessages))
		{
			StatsPrintToChatAllPreFormatted("求生之路排名系统现在处于 \x04关闭\x01 状态, 没有足够玩家!");
		}

		return;
	}

	if (StatsDisabled())
		return;

	UpdateMapStat("playtime", 1);

	new maxplayers = MaxClients;
	for (new i = 1; i <= maxplayers; i++)
	{
		if (IsClientConnected(i) && IsClientInGame(i) && !IsClientBot(i))
			CheckPlayerDB(i);
	}
}

// Display rank change.

public Action:timer_ShowRankChange(Handle:timer, any:client)
{
	DoShowRankChange(client);
}

public DoShowRankChange(Client)
{
	if (StatsDisabled())
		return;

	decl String:ClientID[MAX_LINE_WIDTH];
	GetClientRankAuthString(Client, ClientID, sizeof(ClientID));

	QueryClientPointsSteamID(Client, ClientID, GetClientPointsRankChange);
}

// Display player rank.

public Action:timer_ShowPlayerJoined(Handle:timer, any:client)
{
	DoShowPlayerJoined(client);
}

public OnClientAuthorized(Client, const String:SteamID[]){
	if (!Client)
		return;
	if (StrEqual(SteamID, "BOT", false)) {
		return;
	}
	decl String:query[1024];
	Format(query, sizeof(query), "SELECT %s FROM %splayers WHERE steamid = '%s'", DB_PLAYERS_TOTALPLAYTIME, DbPrefix, SteamID);
	SQL_TQuery(db, GetBasicInf, query, Client);
}
// Send the RANK panel to the client's display.
public GetBasicInf(Handle:owner, Handle:hndl, const String:error[], any:client)
{
	if (!client)
		return;

	if (hndl == INVALID_HANDLE)
	{
		LogError("GetBasicInf Query failed: %s", error);
		return;
	}

	new Playtime;
	new String:Name[32];

	if (SQL_FetchRow(hndl))
	{
		Playtime = SQL_FetchInt(hndl, 0);
		ClientPlayTime[client] = Playtime;
		Call_StartForward(SuccessGetPlayerTime);//转发触发
		Call_PushCell(client);//按顺序将参数push进forward传参列表里
		Call_Finish();//转发结束
	}
	else
	{
		GetClientName(client, Name, sizeof(Name));
		Playtime = 0;
	}
}
public DoShowPlayerJoined(client)
{
	if (StatsDisabled())
	{
		return;
	}

	decl String:clientId[MAX_LINE_WIDTH];
	GetClientRankAuthString(client, clientId, sizeof(clientId));

	QueryClientPointsSteamID(client, clientId, GetClientPointsPlayerJoined);
}

// Display common Infected scores to each player.

public Action:timer_ShowTimerScore(Handle:timer, Handle:hndl)
{
	if (StatsDisabled())
		return;

	new Mode = GetConVarInt(cvar_AnnounceMode);
	decl String:Name[MAX_LINE_WIDTH];

	new maxplayers = MaxClients;
	for (new i = 1; i <= maxplayers; i++)
	{
		if (IsClientConnected(i) && IsClientInGame(i) && !IsClientBot(i))
		{
			// if (CurrentPoints[i] > GetConVarInt(cvar_MaxPoints))
			//     continue;

			TimerPoints[i] = GetMedkitPointReductionScore(TimerPoints[i]);

			if (TimerPoints[i] > 0 && TimerKills[i] > 0)
			{
				if (Mode == 1 || Mode == 2)
				{
					StatsPrintToChat(i, "你击杀了 \x05%i \x01 个感染者获得\x04%i \x01分!", TimerKills[i], TimerPoints[i]);
				}
				else if (Mode == 3)
				{
					GetClientName(i, Name, sizeof(Name));
					StatsPrintToChatAll("\x05%s \x01击杀了 \x05%i \x01 个感染者获得\x04%i \x01分!", Name, TimerKills[i], TimerPoints[i]);
				}
			}

			InterstitialPlayerUpdate(i);
		}

		TimerPoints[i] = 0;
		TimerKills[i] = 0;
		TimerHeadshots[i] = 0;
	}

}

// Update a player's stats, used for interstitial updating.

public InterstitialPlayerUpdate(client)
{
	decl String:ClientID[MAX_LINE_WIDTH];
	GetClientRankAuthString(client, ClientID, sizeof(ClientID));

	decl String:UpdatePoints[32];

	switch (CurrentGamemodeID)
	{
		case GAMEMODE_VERSUS:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_survivors");
		}
		case GAMEMODE_REALISM:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_realism");
		}
		case GAMEMODE_SURVIVAL:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_survival");
		}
		case GAMEMODE_SCAVENGE:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_scavenge_survivors");
		}
		case GAMEMODE_REALISMVERSUS:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_realism_survivors");
		}
		case GAMEMODE_OTHERMUTATIONS:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_mutations");
		}
		default:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points");
		}
	}

	new len = 0;
	decl String:query[1024];
	len += Format(query[len], sizeof(query)-len, "UPDATE %splayers SET %s = %s + %i, ", DbPrefix, UpdatePoints, UpdatePoints, TimerPoints[client]);
	len += Format(query[len], sizeof(query)-len, "kills = kills + %i, kill_infected = kill_infected + %i, ", TimerKills[client], TimerKills[client]);
	len += Format(query[len], sizeof(query)-len, "headshots = headshots + %i ", TimerHeadshots[client]);
	len += Format(query[len], sizeof(query)-len, "WHERE steamid = '%s'", ClientID);
	SendSQLUpdate(query);

	UpdateMapStat("kills", TimerKills[client]);
	UpdateMapStat("points", TimerPoints[client]);

	AddScore(client, TimerPoints[client]);
}

// Player Death event. Used for killing AI Infected. +2 on headshot, and global announcement.
// Team Kill code is in the awards section. Tank Kill code is in Tank section.

public Action:event_PlayerDeath(Handle:event, const String:name[], bool:dontBroadcast)
{
	if (StatsDisabled() || CampaignOver)
		return;

	new Attacker = GetClientOfUserId(GetEventInt(event, "attacker"));
	new Victim = GetClientOfUserId(GetEventInt(event, "userid"));
	new bool:AttackerIsBot = GetEventBool(event, "attackerisbot");
	new bool:VictimIsBot = GetEventBool(event, "victimisbot");
	new VictimTeam = -1;

	// Self inflicted death does not count
	if (Attacker == Victim)
		return;

	if (!VictimIsBot)
		DoInfectedFinalChecks(Victim, ClientInfectedType[Victim]);

	if (Victim > 0)
		VictimTeam = GetClientTeam(Victim);

	if (Attacker == 0 || AttackerIsBot)
	{
		// Attacker is normal indected but the Victim was infected by blinding and/or paralysation.
		if (Attacker == 0
				&& VictimTeam == TEAM_SURVIVORS
				&& (PlayerBlinded[Victim][0] && PlayerBlinded[Victim][1]
					|| PlayerParalyzed[Victim][0] && PlayerParalyzed[Victim][1]
					|| PlayerLunged[Victim][0] && PlayerLunged[Victim][1]
					|| PlayerCarried[Victim][0] && PlayerCarried[Victim][1]
					|| PlayerPlummeled[Victim][0] && PlayerPlummeled[Victim][1]
					|| PlayerJockied[Victim][0] && PlayerJockied[Victim][1])
				&& IsGamemodeVersus())
			PlayerDeathExternal(Victim);

		if (CurrentGamemodeID == GAMEMODE_SURVIVAL && Victim > 0 && VictimTeam == TEAM_SURVIVORS)
			CheckSurvivorsAllDown();

		return;
	}

	new Mode = GetConVarInt(cvar_AnnounceMode);
	new AttackerTeam = GetClientTeam(Attacker);
	decl String:AttackerName[MAX_LINE_WIDTH];
	decl String:AttackerID[MAX_LINE_WIDTH];
	GetClientRankAuthString(Attacker, AttackerID, sizeof(AttackerID));
	decl String:VictimName[MAX_LINE_WIDTH];
	new VictimInfType = -1;

	if (Victim > 0)
	{
		GetClientName(Victim, VictimName, sizeof(VictimName));

		if (VictimTeam == TEAM_INFECTED)
			VictimInfType = GetInfType(Victim);
	}
	else
	{
		GetEventString(event, "victimname", VictimName, sizeof(VictimName));

		if (StrEqual(VictimName, "hunter", false))
		{
			VictimTeam = TEAM_INFECTED;
			VictimInfType = INF_ID_HUNTER;
		}
		else if (StrEqual(VictimName, "smoker", false))
		{
			VictimTeam = TEAM_INFECTED;
			VictimInfType = INF_ID_SMOKER;
		}
		else if (StrEqual(VictimName, "boomer", false))
		{
			VictimTeam = TEAM_INFECTED;
			VictimInfType = INF_ID_BOOMER;
		}
		if (StrEqual(VictimName, "spitter", false))
		{
			VictimTeam = TEAM_INFECTED;
			VictimInfType = INF_ID_SPITTER_L4D2;
		}
		else if (StrEqual(VictimName, "jockey", false))
		{
			VictimTeam = TEAM_INFECTED;
			VictimInfType = INF_ID_JOCKEY_L4D2;
		}
		else if (StrEqual(VictimName, "charger", false))
		{
			VictimTeam = TEAM_INFECTED;
			VictimInfType = INF_ID_CHARGER_L4D2;
		}
		else if (StrEqual(VictimName, "tank", false))
		{
			VictimTeam = TEAM_INFECTED;
			VictimInfType = INF_ID_TANK_L4D2;
		}
		else
			return;
	}

	// The wearoff should now work properly! Don't initialize
	//if (Victim > 0 && (VictimInfType == INF_ID_HUNTER || VictimInfType == INF_ID_SMOKER))
	//	InitializeClientInf(Victim);

	if (VictimTeam == TEAM_SURVIVORS)
		CheckSurvivorsAllDown();

	// Team Kill: Attacker is a Survivor and Victim is Survivor
	if (AttackerTeam == TEAM_SURVIVORS && VictimTeam == TEAM_SURVIVORS && L4D_HasAnySurvivorLeftSafeArea())
	{
		new Score = 0;
		if (GetConVarBool(cvar_EnableNegativeScore))
		{
			if (!IsClientBot(Victim))
				Score = ModifyScoreDifficultyNR(GetConVarInt(cvar_FKill), 2, 4, TEAM_SURVIVORS);
			else
			{
				new Float:BotScoreMultiplier = GetConVarFloat(cvar_BotScoreMultiplier);

				if (BotScoreMultiplier > 0.0)
					Score = RoundToNearest(ModifyScoreDifficultyNR(GetConVarInt(cvar_FKill), 2, 4, TEAM_SURVIVORS) * BotScoreMultiplier);
			}
		}
		else
			Mode = 0;

		decl String:UpdatePoints[32];

		switch (CurrentGamemodeID)
		{
			case GAMEMODE_VERSUS:
			{
				Format(UpdatePoints, sizeof(UpdatePoints), "points_survivors");
			}
			case GAMEMODE_REALISM:
			{
				Format(UpdatePoints, sizeof(UpdatePoints), "points_realism");
			}
			case GAMEMODE_SURVIVAL:
			{
				Format(UpdatePoints, sizeof(UpdatePoints), "points_survival");
			}
			case GAMEMODE_SCAVENGE:
			{
				Format(UpdatePoints, sizeof(UpdatePoints), "points_scavenge_survivors");
			}
			case GAMEMODE_REALISMVERSUS:
			{
				Format(UpdatePoints, sizeof(UpdatePoints), "points_realism_survivors");
			}
			case GAMEMODE_OTHERMUTATIONS:
			{
				Format(UpdatePoints, sizeof(UpdatePoints), "points_mutations");
			}
			default:
			{
				Format(UpdatePoints, sizeof(UpdatePoints), "points");
			}
		}
		if(IsNormalMode()){
			Score = RoundToFloor(Score / 5.0);
		}

		decl String:query[1024];
		Format(query, sizeof(query), "UPDATE %splayers SET %s = %s - %i, award_teamkill = award_teamkill + 1 WHERE steamid = '%s'", DbPrefix, UpdatePoints, UpdatePoints, Score, AttackerID);

		SendSQLUpdate(query);

		if (Mode == 1 || Mode == 2)
			StatsPrintToChat(Attacker, "你因为队内误杀 \x05%s\x01 \x03失去了 \x04%i \x01分!", VictimName, Score);
		else if (Mode == 3)
			StatsPrintToChatAll("\x05%s \x01因为队内误杀 \x05%s\x01 \x03失去了 \x04%i \x01分!!", AttackerName, VictimName, Score);
	}

	// Attacker is a Survivor
	else if (AttackerTeam == TEAM_SURVIVORS && VictimTeam == TEAM_INFECTED)
	{
		int human = CheckSurvivorsHumans();
		if( human < 3 || IsWitchParty() || IsAllCharger() || (g_brpgAvailable && !L4D_RPG_GetGlobalValue(INDEX_VALID)))
			return;
		new Score = 0;
		decl String:InfectedType[8];

		if (VictimInfType == INF_ID_HUNTER)
		{
			Format(InfectedType, sizeof(InfectedType), "hunter");
			Score = ModifyScoreDifficultyNR(GetConVarInt(cvar_Hunter), 2, 3, TEAM_SURVIVORS);
		}
		else if (VictimInfType == INF_ID_SMOKER)
		{
			Format(InfectedType, sizeof(InfectedType), "smoker");
			Score = ModifyScoreDifficultyNR(GetConVarInt(cvar_Smoker), 2, 3, TEAM_SURVIVORS);
		}
		else if (VictimInfType == INF_ID_BOOMER)
		{
			Format(InfectedType, sizeof(InfectedType), "boomer");
			Score = ModifyScoreDifficultyNR(GetConVarInt(cvar_Boomer), 2, 3, TEAM_SURVIVORS);
		}
		else if (VictimInfType == INF_ID_SPITTER_L4D2)
		{
			Format(InfectedType, sizeof(InfectedType), "spitter");
			Score = ModifyScoreDifficultyNR(GetConVarInt(cvar_Spitter), 2, 3, TEAM_SURVIVORS);
		}
		else if (VictimInfType == INF_ID_JOCKEY_L4D2)
		{
			Format(InfectedType, sizeof(InfectedType), "jockey");
			Score = ModifyScoreDifficultyNR(GetConVarInt(cvar_Jockey), 2, 3, TEAM_SURVIVORS);
		}
		else if (VictimInfType == INF_ID_CHARGER_L4D2)
		{
			Format(InfectedType, sizeof(InfectedType), "charger");
			Score = ModifyScoreDifficultyNR(GetConVarInt(cvar_Charger), 2, 3, TEAM_SURVIVORS);
		}
		else
			return;

		new String:Headshot[32];
		if (GetEventBool(event, "headshot"))
		{
			Format(Headshot, sizeof(Headshot), ", headshots = headshots + 1");
			Score = Score + 2;
		}

		Score = GetMedkitPointReductionScore(Score);

		decl String:UpdatePoints[32];

		switch (CurrentGamemodeID)
		{
			case GAMEMODE_VERSUS:
			{
				Format(UpdatePoints, sizeof(UpdatePoints), "points_survivors");
			}
			case GAMEMODE_REALISM:
			{
				Format(UpdatePoints, sizeof(UpdatePoints), "points_realism");
			}
			case GAMEMODE_SURVIVAL:
			{
				Format(UpdatePoints, sizeof(UpdatePoints), "points_survival");
			}
			case GAMEMODE_SCAVENGE:
			{
				Format(UpdatePoints, sizeof(UpdatePoints), "points_scavenge_survivors");
			}
			case GAMEMODE_REALISMVERSUS:
			{
				Format(UpdatePoints, sizeof(UpdatePoints), "points_realism_survivors");
			}
			case GAMEMODE_OTHERMUTATIONS:
			{
				Format(UpdatePoints, sizeof(UpdatePoints), "points_mutations");
			}
			default:
			{
				Format(UpdatePoints, sizeof(UpdatePoints), "points");
			}
		}

		new len = 0;
		decl String:query[1024];
		len += Format(query[len], sizeof(query)-len, "UPDATE %splayers SET %s = %s + %i, ", DbPrefix, UpdatePoints, UpdatePoints, Score);
		len += Format(query[len], sizeof(query)-len, "kills = kills + 1, kill_%s = kill_%s + 1", InfectedType, InfectedType);
		len += Format(query[len], sizeof(query)-len, "%s WHERE steamid = '%s'", Headshot, AttackerID);
		SendSQLUpdate(query);

		if (Mode && Score > 0)
		{
			if (GetEventBool(event, "headshot"))
			{
				if (Mode > 1)
				{
					GetClientName(Attacker, AttackerName, sizeof(AttackerName));
					StatsPrintToChatAll("\x05%s \x04爆头杀死 \x05%s \x01获得 \x04%i \x01分 !", AttackerName, VictimName, Score);
				}
				else
					StatsPrintToChat(Attacker, "你 \x04爆头杀死 \x05%s \x01 获得 \x04%i \x01分!", VictimName, Score);
			}
			else
			{
				if (Mode > 1)
				{
					GetClientName(Attacker, AttackerName, sizeof(AttackerName));
					StatsPrintToChatAll("\x05%s \x04杀死 \x05%s \x01获得 \x04%i \x01分 !", AttackerName, VictimName, Score);
				}
				else
					StatsPrintToChat(Attacker, "你 \x04杀死 \x05%s \x01 获得 \x04%i \x01分!", VictimName, Score);
			}
		}

		UpdateMapStat("kills", 1);
		UpdateMapStat("points", Score);
		AddScore(Attacker, Score);
	}

	// Attacker is an Infected
	else if (AttackerTeam == TEAM_INFECTED && VictimTeam == TEAM_SURVIVORS)
		SurvivorDiedNamed(Attacker, Victim, VictimName, AttackerID, -1, Mode);

	if (VictimTeam == TEAM_SURVIVORS)
	{
		if (PanicEvent)
			PanicEventIncap = true;

		if (PlayerVomited)
			PlayerVomitedIncap = true;
	}
}

stock int IsAnne(){
	decl String:plugin_name[MAX_LINE_WIDTH];
	if(cvar_mode == null && FindConVar("l4d_ready_cfg_name"))
	{
		cvar_mode = FindConVar("l4d_ready_cfg_name");
	}
	if(cvar_mode == null) return 0;
	GetConVarString(cvar_mode, plugin_name, sizeof(plugin_name));
	if(StrContains(plugin_name, "AnneHappy", false) != -1)
	{
		if(StrContains(plugin_name, "HardCore", false) != -1)
			return 2;
		else
			return 1;
	}else
	{
		return 0;
	}
}

stock bool IsAllCharger(){
	decl String:plugin_name[MAX_LINE_WIDTH];
	if(cvar_mode == null && FindConVar("l4d_ready_cfg_name"))
	{
		cvar_mode = FindConVar("l4d_ready_cfg_name");
	}
	if(cvar_mode == null) return false;
	GetConVarString(cvar_mode, plugin_name, sizeof(plugin_name));
	if(StrContains(plugin_name, "AllCharger", false) != -1)
	{
		return true;
	}else
	{
		return false;
	}
}

stock bool Is1vht(){
	decl String:plugin_name[MAX_LINE_WIDTH];
	if(cvar_mode == null && FindConVar("l4d_ready_cfg_name"))
	{
		cvar_mode = FindConVar("l4d_ready_cfg_name");
	}
	if(cvar_mode == null) return false;
	GetConVarString(cvar_mode, plugin_name, sizeof(plugin_name));
	if(StrContains(plugin_name, "1vHunters", false) != -1)
	{
		return true;
	}else
	{
		return false;
	}
}

stock bool IsWitchParty(){
	decl String:plugin_name[MAX_LINE_WIDTH];
	if(cvar_mode == null && FindConVar("l4d_ready_cfg_name"))
	{
		cvar_mode = FindConVar("l4d_ready_cfg_name");
	}
	if(cvar_mode == null) return false;
	GetConVarString(cvar_mode, plugin_name, sizeof(plugin_name));
	if(StrContains(plugin_name, "WitchParty", false) != -1)
	{
		return true;
	}else
	{
		return false;
	}
}

stock bool IsAlone(){
	decl String:plugin_name[MAX_LINE_WIDTH];
	if(cvar_mode == null && FindConVar("l4d_ready_cfg_name"))
	{
		cvar_mode = FindConVar("l4d_ready_cfg_name");
	}
	if(cvar_mode == null) return false;
	GetConVarString(cvar_mode, plugin_name, sizeof(plugin_name));
	if(StrContains(plugin_name, "Alone", false) != -1)
	{
		return true;
	}else
	{
		return false;
	}
}

stock bool SinglePlayerMode(){
	if(Is1vht() || IsAlone()){
		return true;
	}
	return false;
}

stock bool AnneMultiPlayerMode(){
	if(IsAnne() || IsWitchParty() || IsAllCharger()){
		return true;
	}
	return false;
}

stock bool IsAboveFourPeople()
{
	ConVar survivorManager = FindConVar("l4d_multislots_survivors_manager_enable");
	if( survivorManager == null)
	{
		return false;
	}
	else
	{
		if(survivorManager.BoolValue)
		{
			return true;
		}else
		{
			return false;
		}
	}
}

stock int getSurvivorNum()
{
	int count = 0;
	for(int i = 1; i <= MaxClients; i++)
	{
		if(IsClientConnected(i) && IsClientInGame(i) && GetClientTeam(i) == 2)
		{
			count ++;
		}
	}
	return count;
}


// Common Infected death code. +1 on headshot.

public Action:event_InfectedDeath(Handle:event, const String:name[], bool:dontBroadcast)
{
	if (StatsDisabled() || CampaignOver)
		return;

	new Attacker = GetClientOfUserId(GetEventInt(event, "attacker"));

	if (!Attacker || IsClientBot(Attacker) || GetClientTeam(Attacker) == TEAM_INFECTED)
		return;
	new Score =0;
	if (AnneMultiPlayerMode())
		Score = ModifyScoreDifficultyNR(2, 1, 1, TEAM_SURVIVORS);
	else if(IsNormalMode())
		Score = ModifyScoreDifficultyNR(2, 2, 3, TEAM_SURVIVORS);
	else {
		Score = ModifyScoreDifficultyNR(GetConVarInt(cvar_Infected), 2, 3, TEAM_SURVIVORS);
	}

	if (GetEventBool(event, "headshot"))
	{
		Score = Score + 1;
		TimerHeadshots[Attacker] = TimerHeadshots[Attacker] + 1;
	}

	TimerPoints[Attacker] = TimerPoints[Attacker] + Score;
	TimerKills[Attacker] = TimerKills[Attacker] + 1;

	// Melee?
	if (EngineVersion1 != Engine_Left4Dead)
	{
		new WeaponID = GetEventInt(event, "weapon_id");

		if (WeaponID == 19)
			IncrementMeleeKills(Attacker);
	}

	//decl String:AttackerName[MAX_LINE_WIDTH];
	//GetClientName(Attacker, AttackerName, sizeof(AttackerName));

	//LogMessage("[DEBUG] %s killed an infected (Weapon ID: %i)", AttackerName, WeaponID);
	//PrintToConsoleAll("[DEBUG] %s killed an infected (Weapon ID: %i)", AttackerName, WeaponID);
}

// Check player validity before calling this method!
IncrementMeleeKills(client)
{
	if (MeleeKillTimer[client] != INVALID_HANDLE)
		CloseHandle(MeleeKillTimer[client]);

	MeleeKillCounter[client]++;
	MeleeKillTimer[client] = CreateTimer(5.0, timer_MeleeKill, client);
}

// Tank death code. Points are given to all players.

public Action:event_TankKilled(Handle:event, const String:name[], bool:dontBroadcast)
{
	if (StatsDisabled() || CampaignOver)
	{
		return;
	}

	if (TankCount >= 3)
	{
		return;
	}

	new BaseScore = ModifyScoreDifficulty(GetConVarInt(cvar_Tank), 2, 4, TEAM_SURVIVORS);
	new Mode = GetConVarInt(cvar_AnnounceMode);
	new Deaths = 0;
	new Players = 0;

	new maxplayers = MaxClients;
	for (new i = 1; i <= maxplayers; i++)
	{
		if (IsClientConnected(i) && IsClientInGame(i) && !IsClientBot(i))
		{
			Players++;

			if (!IsPlayerAlive(i))
			{
				Deaths++;
			}
		}
	}

	// This was proposed by AlliedModders users el_psycho and PatriotGames (Thanks!)
	new Score = (BaseScore * ((Players - Deaths) / Players)) / Players;

	// HardCore 奖励增加100%
	if(IsAnne() == 2)
	{
		Score *= 2;
	}
	

	decl String:UpdatePoints[32];

	switch (CurrentGamemodeID)
	{
		case GAMEMODE_VERSUS:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_survivors");
		}
		case GAMEMODE_REALISM:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_realism");
		}
		case GAMEMODE_SURVIVAL:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_survival");
		}
		case GAMEMODE_SCAVENGE:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_scavenge_survivors");
		}
		case GAMEMODE_REALISMVERSUS:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_realism_survivors");
		}
		case GAMEMODE_OTHERMUTATIONS:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_mutations");
		}
		default:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points");
		}
	}

	decl String:iID[MAX_LINE_WIDTH];
	decl String:query[512];

	for (new i = 1; i <= maxplayers; i++)
	{
		if (IsClientConnected(i) && IsClientInGame(i) && !IsClientBot(i) && GetClientTeam(i) == TEAM_SURVIVORS)
		{
			GetClientRankAuthString(i, iID, sizeof(iID));
			Format(query, sizeof(query), "UPDATE %splayers SET %s = %s + %i, award_tankkill = award_tankkill + 1 WHERE steamid = '%s'", DbPrefix, UpdatePoints, UpdatePoints, Score, iID);
			SendSQLUpdate(query);

			AddScore(i, Score);
		}
	}

	if (Mode && Score > 0)
	{
		StatsPrintToChatTeam(TEAM_SURVIVORS, "\x03所有幸存者因 \x05%i 死亡击杀一个Tank \x01获得 \x04%i \x01分 !", Deaths, Score);
	}

	UpdateMapStat("kills", 1);
	UpdateMapStat("points", Score);
	TankCount = TankCount + 1;
}

// Adrenaline give code. Special note, Adrenalines can only be given once. (Even if it's initially given by a bot!)

GiveAdrenaline(Giver, Recipient, AdrenalineID = -1)
{
	// Stats enabled is checked by the caller

	if (CurrentGamemodeID == GAMEMODE_SURVIVAL && !SurvivalStarted)
		return;

	if (AdrenalineID < 0)
		AdrenalineID = GetPlayerWeaponSlot(Recipient, 4);

	if (AdrenalineID < 0 || Adrenaline[AdrenalineID] == 1)
		return;
	else
		Adrenaline[AdrenalineID] = 1;

	if (IsClientBot(Giver))
		return;
	
	if(g_brpgAvailable && !L4D_RPG_GetGlobalValue(INDEX_VALID))
		return;

	decl String:RecipientName[MAX_LINE_WIDTH];
	GetClientName(Recipient, RecipientName, sizeof(RecipientName));
	decl String:RecipientID[MAX_LINE_WIDTH];
	GetClientRankAuthString(Recipient, RecipientID, sizeof(RecipientID));

	decl String:GiverName[MAX_LINE_WIDTH];
	GetClientName(Giver, GiverName, sizeof(GiverName));
	decl String:GiverID[MAX_LINE_WIDTH];
	GetClientRankAuthString(Giver, GiverID, sizeof(GiverID));

	new Score = ModifyScoreDifficulty(GetConVarInt(cvar_Adrenaline), 2, 4, TEAM_SURVIVORS);
	decl String:UpdatePoints[32];

	switch (CurrentGamemodeID)
	{
		case GAMEMODE_VERSUS:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_survivors");
		}
		case GAMEMODE_REALISM:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_realism");
		}
		case GAMEMODE_SURVIVAL:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_survival");
		}
		case GAMEMODE_SCAVENGE:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_scavenge_survivors");
		}
		case GAMEMODE_REALISMVERSUS:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_realism_survivors");
		}
		case GAMEMODE_OTHERMUTATIONS:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_mutations");
		}
		default:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points");
		}
	}

	decl String:query[1024];
	Format(query, sizeof(query), "UPDATE %splayers SET %s = %s + %i, award_adrenaline = award_adrenaline + 1 WHERE steamid = '%s'", DbPrefix, UpdatePoints, UpdatePoints, Score, GiverID);
	SendSQLUpdate(query);

	UpdateMapStat("points", Score);
	AddScore(Giver, Score);

	if (Score > 0)
	{
		new Mode = GetConVarInt(cvar_AnnounceMode);

		if (Mode == 1 || Mode == 2)
			StatsPrintToChat(Giver, "你赠送肾上腺素给 \x05%s \x01获得了 \x04%i \x01分!", RecipientName, Score);
		else if (Mode == 3)
			StatsPrintToChatAll("\x05%s 赠送肾上腺素给 \x05%s \x01获得了 \x04%i \x01分!", GiverName, RecipientName, Score);
	}
}

// Pill give event. (From give a weapon)

public Action:event_GivePills(Handle:event, const String:name[], bool:dontBroadcast)
{
	if (StatsDisabled())
		return;

	// If given weapon != 12 (Pain Pills) then return
	if (GetEventInt(event, "weapon") != 12)
		return;

	if (CurrentGamemodeID == GAMEMODE_SURVIVAL && !GetConVarBool(cvar_EnableSvMedicPoints))
		return;

	new Recipient = GetClientOfUserId(GetEventInt(event, "userid"));
	new Giver = GetClientOfUserId(GetEventInt(event, "giver"));
	new PillsID = GetEventInt(event, "weaponentid");

	GivePills(Giver, Recipient, PillsID);
}

// Pill give code. Special note, Pills can only be given once. (Even if it's initially given by a bot!)

GivePills(Giver, Recipient, PillsID = -1)
{
	// Stats enabled is checked by the caller

	if (CurrentGamemodeID == GAMEMODE_SURVIVAL && !SurvivalStarted)
		return;

	if (PillsID < 0)
		PillsID = GetPlayerWeaponSlot(Recipient, 4);

	if (PillsID < 0 || Pills[PillsID] == 1)
		return;
	else
		Pills[PillsID] = 1;

	if (IsClientBot(Giver))
		return;
	
	if(g_brpgAvailable && !L4D_RPG_GetGlobalValue(INDEX_VALID))
		return;

	decl String:RecipientName[MAX_LINE_WIDTH];
	GetClientName(Recipient, RecipientName, sizeof(RecipientName));
	decl String:RecipientID[MAX_LINE_WIDTH];
	GetClientRankAuthString(Recipient, RecipientID, sizeof(RecipientID));

	decl String:GiverName[MAX_LINE_WIDTH];
	GetClientName(Giver, GiverName, sizeof(GiverName));
	decl String:GiverID[MAX_LINE_WIDTH];
	GetClientRankAuthString(Giver, GiverID, sizeof(GiverID));

	new Score = ModifyScoreDifficulty(GetConVarInt(cvar_Pills), 2, 4, TEAM_SURVIVORS);
	decl String:UpdatePoints[32];

	switch (CurrentGamemodeID)
	{
		case GAMEMODE_VERSUS:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_survivors");
		}
		case GAMEMODE_REALISM:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_realism");
		}
		case GAMEMODE_SURVIVAL:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_survival");
		}
		case GAMEMODE_SCAVENGE:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_scavenge_survivors");
		}
		case GAMEMODE_REALISMVERSUS:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_realism_survivors");
		}
		case GAMEMODE_OTHERMUTATIONS:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_mutations");
		}
		default:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points");
		}
	}

	decl String:query[1024];
	Format(query, sizeof(query), "UPDATE %splayers SET %s = %s + %i, award_pills = award_pills + 1 WHERE steamid = '%s'", DbPrefix, UpdatePoints, UpdatePoints, Score, GiverID);
	SendSQLUpdate(query);

	UpdateMapStat("points", Score);
	AddScore(Giver, Score);

	if (Score > 0)
	{
		new Mode = GetConVarInt(cvar_AnnounceMode);

		if (Mode == 1 || Mode == 2)
			StatsPrintToChat(Giver, "你赠送药丸给 \x05%s \x01获得了 \x04%i \x01分!", RecipientName, Score);
		else if (Mode == 3)
			StatsPrintToChatAll("\x05%s \x01赠送药丸给 \x05%s \x01获得了 \x04%i \x01分!", GiverName, RecipientName, Score);
	}
}

// Defibrillator used code.

public Action:event_DefibPlayer(Handle:event, const String:name[], bool:dontBroadcast)
{
	if (StatsDisabled() || CampaignOver)
		return;

	if (CurrentGamemodeID == GAMEMODE_SURVIVAL && (!SurvivalStarted || !GetConVarBool(cvar_EnableSvMedicPoints)))
		return;

	new Recipient = GetClientOfUserId(GetEventInt(event, "subject"));
	new Giver = GetClientOfUserId(GetEventInt(event, "userid"));

	new bool:GiverIsBot = IsClientBot(Giver);
	new bool:RecipientIsBot = IsClientBot(Recipient);

	if (CurrentGamemodeID != GAMEMODE_SURVIVAL && (!GiverIsBot || (GiverIsBot && (GetConVarInt(cvar_MedkitBotMode) >= 2 || (!RecipientIsBot && GetConVarInt(cvar_MedkitBotMode) >= 1)))))
	{
		MedkitsUsedCounter++;
		AnnounceMedkitPenalty();
	}

	if (IsClientBot(Giver))
		return;

	// How is this possible?
	if (Recipient == Giver)
		return;

	decl String:RecipientName[MAX_LINE_WIDTH];
	GetClientName(Recipient, RecipientName, sizeof(RecipientName));
	decl String:RecipientID[MAX_LINE_WIDTH];
	GetClientRankAuthString(Recipient, RecipientID, sizeof(RecipientID));

	decl String:GiverName[MAX_LINE_WIDTH];
	GetClientName(Giver, GiverName, sizeof(GiverName));
	decl String:GiverID[MAX_LINE_WIDTH];
	GetClientRankAuthString(Giver, GiverID, sizeof(GiverID));

	new Score = ModifyScoreDifficulty(GetConVarInt(cvar_Defib), 2, 4, TEAM_SURVIVORS);

	decl String:UpdatePoints[32];

	switch (CurrentGamemodeID)
	{
		case GAMEMODE_VERSUS:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_survivors");
		}
		case GAMEMODE_REALISM:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_realism");
		}
		case GAMEMODE_SURVIVAL:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_survival");
		}
		case GAMEMODE_SCAVENGE:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_scavenge_survivors");
		}
		case GAMEMODE_REALISMVERSUS:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_realism_survivors");
		}
		case GAMEMODE_OTHERMUTATIONS:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_mutations");
		}
		default:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points");
		}
	}

	decl String:query[1024];
	Format(query, sizeof(query), "UPDATE %splayers SET %s = %s + %i, award_defib = award_defib + 1 WHERE steamid = '%s'", DbPrefix, UpdatePoints, UpdatePoints, Score, GiverID);
	SendSQLUpdate(query);

	UpdateMapStat("points", Score);
	AddScore(Giver, Score);

	if (Score > 0)
	{
		new Mode = GetConVarInt(cvar_AnnounceMode);
		if (Mode == 1 || Mode == 2)
			StatsPrintToChat(Giver, "你用电击器复活了 \x05%s\x01 获得了 \x04%i \x01分!", RecipientName, Score);
		else if (Mode == 3)
			StatsPrintToChatAll("\x05%s \x01用电击器复活了 \x05%s\x01 获得了 \x04%i \x01分!", GiverName, RecipientName, Score);
	}
}

// Medkit give code.

public Action:event_HealPlayer(Handle:event, const String:name[], bool:dontBroadcast)
{
	if (StatsDisabled() || CampaignOver)
		return;

	if (CurrentGamemodeID == GAMEMODE_SURVIVAL && (!SurvivalStarted || !GetConVarBool(cvar_EnableSvMedicPoints)))
		return;

	new Recipient = GetClientOfUserId(GetEventInt(event, "subject"));
	new Giver = GetClientOfUserId(GetEventInt(event, "userid"));
	new Amount = GetEventInt(event, "health_restored");

	new bool:GiverIsBot = IsClientBot(Giver);
	new bool:RecipientIsBot = IsClientBot(Recipient);

	if (CurrentGamemodeID != GAMEMODE_SURVIVAL && (!GiverIsBot || (GiverIsBot && (GetConVarInt(cvar_MedkitBotMode) >= 2 || (!RecipientIsBot && GetConVarInt(cvar_MedkitBotMode) >= 1)))))
	{
		MedkitsUsedCounter++;
		AnnounceMedkitPenalty();
	}

	if (GiverIsBot)
		return;

	if (Recipient == Giver)
		return;

	decl String:RecipientName[MAX_LINE_WIDTH];
	GetClientName(Recipient, RecipientName, sizeof(RecipientName));
	decl String:RecipientID[MAX_LINE_WIDTH];
	GetClientRankAuthString(Recipient, RecipientID, sizeof(RecipientID));

	decl String:GiverName[MAX_LINE_WIDTH];
	GetClientName(Giver, GiverName, sizeof(GiverName));
	decl String:GiverID[MAX_LINE_WIDTH];
	GetClientRankAuthString(Giver, GiverID, sizeof(GiverID));

	new Score = (Amount + 1) / 2;
	if (GetConVarInt(cvar_MedkitMode))
		Score = ModifyScoreDifficulty(GetConVarInt(cvar_Medkit), 2, 4, TEAM_SURVIVORS);
	else
		Score = ModifyScoreDifficulty(Score, 2, 3, TEAM_SURVIVORS);

	decl String:UpdatePoints[32];

	switch (CurrentGamemodeID)
	{
		case GAMEMODE_VERSUS:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_survivors");
		}
		case GAMEMODE_REALISM:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_realism");
		}
		case GAMEMODE_SURVIVAL:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_survival");
		}
		case GAMEMODE_SCAVENGE:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_scavenge_survivors");
		}
		case GAMEMODE_REALISMVERSUS:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_realism_survivors");
		}
		case GAMEMODE_OTHERMUTATIONS:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_mutations");
		}
		default:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points");
		}
	}

	decl String:query[1024];
	Format(query, sizeof(query), "UPDATE %splayers SET %s = %s + %i, award_medkit = award_medkit + 1 WHERE steamid = '%s'", DbPrefix, UpdatePoints, UpdatePoints, Score, GiverID);
	SendSQLUpdate(query);

	UpdateMapStat("points", Score);
	AddScore(Giver, Score);

	if (Score > 0)
	{
		new Mode = GetConVarInt(cvar_AnnounceMode);
		if (Mode == 1 || Mode == 2) 
			StatsPrintToChat(Giver, "你用医疗包治疗了 \x05%s\x01 获得了 \x04%i \x01分!", RecipientName, Score);
		else if (Mode == 3)
			StatsPrintToChatAll("\x05%s \x01用医疗包治疗了 \x05%s\x01 获得了 \x04%i \x01分!", GiverName, RecipientName, Score);
	}
}

// Friendly fire code.

public Action:event_FriendlyFire(Handle:event, const String:name[], bool:dontBroadcast)
{
	if (StatsDisabled() || CampaignOver)
		return;

	new Attacker = GetClientOfUserId(GetEventInt(event, "attacker"));
	new Victim = GetClientOfUserId(GetEventInt(event, "victim"));

	if (!Attacker || !Victim)
		return;

//	if (IsClientBot(Victim))
//		return;

	new FFMode = GetConVarInt(cvar_FriendlyFireMode);

	if (FFMode == 1)
	{
		new CooldownMode = GetConVarInt(cvar_FriendlyFireCooldownMode);

		if (CooldownMode == 1 || CooldownMode == 2)
		{
			new Target = 0;

			// Player specific : CooldownMode = 1
			// General : CooldownMode = 2
			if (CooldownMode == 1)
				Target = Victim;

			if (FriendlyFireCooldown[Attacker][Target])
				return;

			FriendlyFireCooldown[Attacker][Target] = true;

			if (FriendlyFirePrmCounter >= MAXPLAYERS)
				FriendlyFirePrmCounter = 0;

			FriendlyFirePrm[FriendlyFirePrmCounter][0] = Attacker;
			FriendlyFirePrm[FriendlyFirePrmCounter][1] = Target;
			FriendlyFireTimer[Attacker][Target] = CreateTimer(GetConVarFloat(cvar_FriendlyFireCooldown), timer_FriendlyFireCooldownEnd, FriendlyFirePrmCounter++);
		}
	}
	else if (FFMode == 2)
	{
		// Friendly fire is calculated in player_hurt event (Damage based)
		return;
	}

	UpdateFriendlyFire(Attacker, Victim);
}

// Campaign win code.

public Action:event_CampaignWin(Handle:event, const String:name[], bool:dontBroadcast)
{
	if (CampaignOver || StatsDisabled())
		return;

	CampaignOver = true;

	StopMapTiming();
	new Float:TotalTime = GetEngineTime() - MapTimingStartTime;
	if(TotalTime < 30.0)
	{
		StatsPrintToChatAll("记录时间小于30s，数据应该不对，没有分数奖励!(PS: 30s能完成的图算啥图)");
		return;
	}

	if (CurrentGamemodeID == GAMEMODE_SCAVENGE ||
			CurrentGamemodeID == GAMEMODE_SURVIVAL)
		return;

	new Score = ModifyScoreDifficulty(GetConVarInt(cvar_VictorySurvivors), 4, 12, TEAM_SURVIVORS);
	new Mode = GetConVarInt(cvar_AnnounceMode);
	new SurvivorCount = GetEventInt(event, "survivorcount");
	new ClientTeam, bool:NegativeScore = GetConVarBool(cvar_EnableNegativeScore);
	if(SurvivorCount>4)
		SurvivorCount=4;
	Score *= SurvivorCount;

	decl String:query[1024];
	decl String:iID[MAX_LINE_WIDTH];
	decl String:UpdatePoints[32], String:UpdatePointsPenalty[32];

	switch (CurrentGamemodeID)
	{
		case GAMEMODE_VERSUS:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_survivors");
			Format(UpdatePointsPenalty, sizeof(UpdatePointsPenalty), "points_infected");
		}
		case GAMEMODE_REALISM:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_realism");
		}
		case GAMEMODE_REALISMVERSUS:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_realism_survivors");
			Format(UpdatePointsPenalty, sizeof(UpdatePointsPenalty), "points_realism_infected");
		}
		case GAMEMODE_OTHERMUTATIONS:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_mutations");
		}
		default:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points");
		}
	}

	if((AnneMultiPlayerMode() || SinglePlayerMode())){
		if((g_brpgAvailable && !L4D_RPG_GetGlobalValue(INDEX_VALID)) || !IsThisRoundValid())
		{
			Score = RoundToFloor(Score * 0.4);
		}
		else
		{
			int inf= GetAnneInfectedNumber();
			if(inf < 4)
			{
				if(AnneMultiPlayerMode())
					Score = RoundToFloor(Score * (1 - (4 - inf) * 0.2));
			}
			else if(inf > 4)
				Score = RoundToFloor(Score + Score * (inf - 4) * 0.1);
			else if(inf > 6)
				Score = RoundToFloor(Score + Score * (inf - 4) * 0.2);
			else if(inf>8)
				Score = RoundToFloor(Score + Score * (inf-4)*0.3);
		}	
	}

	if(IsAboveFourPeople())
	{
		Score = RoundToFloor(Score * (4.0 / getSurvivorNum()));
	}

	if(IsGaoJiRenJiEnabled())
	{
		Score = RoundToFloor(Score * 0.5);
	}

	// HardCore 奖励增加50%
	if(IsAnne() == 2)
	{
		Score = RoundToFloor(1.5 * Score);
	}

	if(!CheckIsOfficalMap())return;

	new maxplayers = MaxClients;
	for (new i = 1; i <= maxplayers; i++)
	{
		if (IsClientConnected(i) && IsClientInGame(i) && !IsClientBot(i))
		{
			ClientTeam = GetClientTeam(i);

			if (ClientTeam == TEAM_SURVIVORS)
			{
				GetClientRankAuthString(i, iID, sizeof(iID));

				Format(query, sizeof(query), "UPDATE %splayers SET %s = %s + %i, award_campaigns = award_campaigns + 1 WHERE steamid = '%s'", DbPrefix, UpdatePoints, UpdatePoints, Score, iID);
				SendSQLUpdate(query);

				if (Score > 0)
				{
					UpdateMapStat("points", Score);
					AddScore(i, Score);
				}
			}
			else if (ClientTeam == TEAM_INFECTED && NegativeScore)
			{
				GetClientRankAuthString(i, iID, sizeof(iID));

				Format(query, sizeof(query), "UPDATE %splayers SET %s = %s - %i WHERE steamid = '%s'", DbPrefix, UpdatePointsPenalty, UpdatePointsPenalty, Score, iID);
				SendSQLUpdate(query);

				if (Score < 0)
					AddScore(i, Score * (-1));
			}
		}
	}

	if (Mode && Score > 0)
	{
		StatsPrintToChatTeam(TEAM_SURVIVORS, "\x03所有幸存者因 \x05%i 幸存者\x04完成了救援关 \x01获得了 \x04%i \x01分!", SurvivorCount, Score);

		if (NegativeScore)
			StatsPrintToChatTeam(TEAM_INFECTED, "\x03所有感染者因 \x04没能阻拦幸存者完成救援关\x01! \x03失去了 \x04%i \x01分", Score);
	}
}

// Safe House reached code. Points are given to all players.
// Also, Witch Not Disturbed code, points also given to all players.

public Action:event_MapTransitionPre(Handle:event, const String:name[], bool:dontBroadcast)
{
	if (StatsDisabled())
		return;
	g_broundend = true;
}

public Action:event_MapTransition(Handle:event, const String:name[], bool:dontBroadcast)
{
	if (StatsDisabled())
		return;
	CheckSurvivorsWin();
}

// Begin panic event.

public Action:event_PanicEvent(Handle:event, const String:name[], bool:dontBroadcast)
{
	if (StatsDisabled())
		return;

	if (CampaignOver || PanicEvent)
		return;

	PanicEvent = true;

	if (CurrentGamemodeID == GAMEMODE_SURVIVAL)
	{
		SurvivalStart();
		return;
	}

	CreateTimer(75.0, timer_PanicEventEnd);
}

// Panic Event with no Incaps code. Points given to all players.

public Action:timer_PanicEventEnd(Handle:timer, Handle:hndl)
{
	if (StatsDisabled())
		return;

	if (CampaignOver || CurrentGamemodeID == GAMEMODE_SURVIVAL)
		return;

	new Mode = GetConVarInt(cvar_AnnounceMode);

	if (PanicEvent && !PanicEventIncap)
	{
		new Score = ModifyScoreDifficulty(GetConVarInt(cvar_Panic), 2, 4, TEAM_SURVIVORS);

		if (Score > 0)
		{
			decl String:query[1024];
			decl String:iID[MAX_LINE_WIDTH];
			decl String:UpdatePoints[32];

			switch (CurrentGamemodeID)
			{
				case GAMEMODE_VERSUS:
				{
					Format(UpdatePoints, sizeof(UpdatePoints), "points_survivors");
				}
				case GAMEMODE_REALISM:
				{
					Format(UpdatePoints, sizeof(UpdatePoints), "points_realism");
				}
				case GAMEMODE_SCAVENGE:
				{
					Format(UpdatePoints, sizeof(UpdatePoints), "points_scavenge_survivors");
				}
				case GAMEMODE_REALISMVERSUS:
				{
					Format(UpdatePoints, sizeof(UpdatePoints), "points_realism_survivors");
				}
				case GAMEMODE_OTHERMUTATIONS:
				{
					Format(UpdatePoints, sizeof(UpdatePoints), "points_mutations");
				}
				default:
				{
					Format(UpdatePoints, sizeof(UpdatePoints), "points");
				}
			}

			new maxplayers = MaxClients;
			for (new i = 1; i <= maxplayers; i++)
			{
				if (IsClientConnected(i) && IsClientInGame(i) && !IsClientBot(i))
				{
					GetClientRankAuthString(i, iID, sizeof(iID));
					Format(query, sizeof(query), "UPDATE %splayers SET %s = %s + %i WHERE steamid = '%s' ", DbPrefix, UpdatePoints, UpdatePoints, Score, iID);
					SendSQLUpdate(query);
					UpdateMapStat("points", Score);
					AddScore(i, Score);
				}
			}

			if (Mode)
				StatsPrintToChatTeam(TEAM_SURVIVORS, "\x03所有幸存者因 \x05尸潮事件过后没有倒地或者死亡 \x01获得了 \x04%i \x01分!", Score);
		}
	}

	PanicEvent = false;
	PanicEventIncap = false;
}

// Begin Boomer blind.

public Action:event_PlayerBlind(Handle:event, const String:name[], bool:dontBroadcast)
{
	if (StatsDisabled() || CampaignOver)
		return;

	new Attacker = GetClientOfUserId(GetEventInt(event, "attacker"));

	if (StatsGetClientTeam(Attacker) != TEAM_INFECTED)
		return;

	PlayerVomited = true;

//	new bool:Infected = GetEventBool(event, "infected");
//
//	if (!Infected)
//		return;

	new Victim = GetClientOfUserId(GetEventInt(event, "userid"));

	if (IsClientBot(Attacker))
		return;

	PlayerBlinded[Victim][0] = 1;
	PlayerBlinded[Victim][1] = Attacker;

	BoomerHitCounter[Attacker]++;

	if (TimerBoomerPerfectCheck[Attacker] != INVALID_HANDLE)
	{
		CloseHandle(TimerBoomerPerfectCheck[Attacker]);
		TimerBoomerPerfectCheck[Attacker] = INVALID_HANDLE;
	}

	TimerBoomerPerfectCheck[Attacker] = CreateTimer(6.0, timer_BoomerBlindnessCheck, Attacker);
}

// Boomer Mob Survival with no Incaps code. Points are given to all players.

public Action:event_PlayerBlindEnd(Handle:event, const String:name[], bool:dontBroadcast)
{
	if (StatsDisabled())
		return;

	new Player = GetClientOfUserId(GetEventInt(event, "userid"));

	if (StatsGetClientTeam(Player) != TEAM_SURVIVORS)
		return;

	if (Player > 0)
		CreateTimer(INF_WEAROFF_TIME, timer_EndBoomerBlinded, Player);

	new Mode = GetConVarInt(cvar_AnnounceMode);

	if (PlayerVomited && !PlayerVomitedIncap)
	{
		new Score = ModifyScoreDifficulty(GetConVarInt(cvar_BoomerMob), 2, 5, TEAM_SURVIVORS);

		if (Score > 0)
		{
			decl String:query[1024];
			decl String:iID[MAX_LINE_WIDTH];
			decl String:UpdatePoints[32];

			switch (CurrentGamemodeID)
			{
				case GAMEMODE_VERSUS:
				{
					Format(UpdatePoints, sizeof(UpdatePoints), "points_survivors");
				}
				case GAMEMODE_REALISM:
				{
					Format(UpdatePoints, sizeof(UpdatePoints), "points_realism");
				}
				case GAMEMODE_SURVIVAL:
				{
					Format(UpdatePoints, sizeof(UpdatePoints), "points_survival");
				}
				case GAMEMODE_SCAVENGE:
				{
					Format(UpdatePoints, sizeof(UpdatePoints), "points_scavenge_survivors");
				}
				case GAMEMODE_REALISMVERSUS:
				{
					Format(UpdatePoints, sizeof(UpdatePoints), "points_realism_survivors");
				}
				case GAMEMODE_OTHERMUTATIONS:
				{
					Format(UpdatePoints, sizeof(UpdatePoints), "points_mutations");
				}
				default:
				{
					Format(UpdatePoints, sizeof(UpdatePoints), "points");
				}
			}

			new maxplayers = MaxClients;
			for (new i = 1; i <= maxplayers; i++)
			{
				if (IsClientConnected(i) && IsClientInGame(i) && !IsClientBot(i) && GetClientTeam(i) == 2)
				{
					GetClientRankAuthString(i, iID, sizeof(iID));
					Format(query, sizeof(query), "UPDATE %splayers SET %s = %s + %i WHERE steamid = '%s' ", DbPrefix, UpdatePoints, UpdatePoints, Score, iID);
					SendSQLUpdate(query);
					UpdateMapStat("points", Score);
					AddScore(i, Score);
				}
			}
			if (Mode)
				StatsPrintToChatTeam(TEAM_SURVIVORS, "\x03所有幸存者因 \x05boomer爆炸后无人死亡 \x01获得了 \x04%i \x01分!", Score);
		}
	}

	PlayerVomited = false;
	PlayerVomitedIncap = false;
}

// Friendly Incapicitate code. Also handles if players should be awarded
// points for surviving a Panic Event or Boomer Mob without incaps.

PlayerIncap(Attacker, Victim)
{
	// Stats enabled and CampaignOver is checked by the caller

	if (PanicEvent)
		PanicEventIncap = true;

	if (PlayerVomited)
		PlayerVomitedIncap = true;

	if (Victim <= 0)
		return;

	if (!Attacker || IsClientBot(Attacker))
	{
		// Attacker is normal indected but the Victim was infected by blinding and/or paralysation.
		if (Attacker == 0
				&& Victim > 0
				&& (PlayerBlinded[Victim][0] && PlayerBlinded[Victim][1]
					|| PlayerParalyzed[Victim][0] && PlayerParalyzed[Victim][1]
					|| PlayerLunged[Victim][0] && PlayerLunged[Victim][1]
					|| PlayerCarried[Victim][0] && PlayerCarried[Victim][1]
					|| PlayerPlummeled[Victim][0] && PlayerPlummeled[Victim][1]
					|| PlayerJockied[Victim][0] && PlayerJockied[Victim][1])
				&& IsGamemodeVersus())
			PlayerIncapExternal(Victim);

		if (CurrentGamemodeID == GAMEMODE_SURVIVAL && Victim > 0)
			CheckSurvivorsAllDown();

		return;
	}

	new AttackerTeam = GetClientTeam(Attacker);
	new VictimTeam = GetClientTeam(Victim);
	new Mode = GetConVarInt(cvar_AnnounceMode);

	if (VictimTeam == TEAM_SURVIVORS)
		CheckSurvivorsAllDown();

	// Attacker is a Survivor
	if (AttackerTeam == TEAM_SURVIVORS && VictimTeam == TEAM_SURVIVORS)
	{
		decl String:AttackerID[MAX_LINE_WIDTH];
		GetClientRankAuthString(Attacker, AttackerID, sizeof(AttackerID));
		decl String:AttackerName[MAX_LINE_WIDTH];
		GetClientName(Attacker, AttackerName, sizeof(AttackerName));

		decl String:VictimName[MAX_LINE_WIDTH];
		GetClientName(Victim, VictimName, sizeof(VictimName));

		new Score = 0;
		if (GetConVarBool(cvar_EnableNegativeScore))
		{
			if (!IsClientBot(Victim))
				Score = ModifyScoreDifficultyNR(GetConVarInt(cvar_FIncap), 2, 4, TEAM_SURVIVORS);
			else
			{
				new Float:BotScoreMultiplier = GetConVarFloat(cvar_BotScoreMultiplier);

				if (BotScoreMultiplier > 0.0)
					Score = RoundToNearest(ModifyScoreDifficultyNR(GetConVarInt(cvar_FIncap), 2, 4, TEAM_SURVIVORS) * BotScoreMultiplier);
			}
		}
		else
			Mode = 0;

		decl String:UpdatePoints[32];

		switch (CurrentGamemodeID)
		{
			case GAMEMODE_VERSUS:
			{
				Format(UpdatePoints, sizeof(UpdatePoints), "points_survivors");
			}
			case GAMEMODE_REALISM:
			{
				Format(UpdatePoints, sizeof(UpdatePoints), "points_realism");
			}
			case GAMEMODE_SURVIVAL:
			{
				Format(UpdatePoints, sizeof(UpdatePoints), "points_survival");
			}
			case GAMEMODE_SCAVENGE:
			{
				Format(UpdatePoints, sizeof(UpdatePoints), "points_scavenge_survivors");
			}
			case GAMEMODE_REALISMVERSUS:
			{
				Format(UpdatePoints, sizeof(UpdatePoints), "points_realism_survivors");
			}
			case GAMEMODE_OTHERMUTATIONS:
			{
				Format(UpdatePoints, sizeof(UpdatePoints), "points_mutations");
			}
			default:
			{
				Format(UpdatePoints, sizeof(UpdatePoints), "points");
			}
		}
		if(IsNormalMode()){
			Score = RoundToFloor(Score / 5.0);
		}

		decl String:query[512];
		Format(query, sizeof(query), "UPDATE %splayers SET %s = %s - %i, award_fincap = award_fincap + 1 WHERE steamid = '%s'", DbPrefix, UpdatePoints, UpdatePoints, Score, AttackerID);
		SendSQLUpdate(query);

		if (Mode == 1 || Mode == 2)
			StatsPrintToChat(Attacker, "你 \x03失去了 \x04%i \x01分 by \x03黑倒了 \x05%s\x01!", Score, VictimName);
		else if (Mode == 3)
			StatsPrintToChatAll("\x05%s \x01 \x03失去了\x04%i \x01分 by \x03黒倒了 \x05%s\x01!", AttackerName, Score, VictimName);
	}

	// Attacker is an Infected
	else if (AttackerTeam == TEAM_INFECTED && VictimTeam == TEAM_SURVIVORS)
	{
		SurvivorIncappedByInfected(Attacker, Victim, Mode);
	}
}

// Friendly Incapacitate event.

public Action:event_PlayerIncap(Handle:event, const String:name[], bool:dontBroadcast)
{
	if (StatsDisabled() || CampaignOver)
		return;

	new Attacker = GetClientOfUserId(GetEventInt(event, "attacker"));
	new Victim = GetClientOfUserId(GetEventInt(event, "userid"));

	if(L4D_HasAnySurvivorLeftSafeArea())PlayerIncap(Attacker, Victim);
}

// Save friendly from being dragged by Smoker.

public Action:event_TongueSave(Handle:event, const String:name[], bool:dontBroadcast)
{
	if (StatsDisabled())
		return;

	new Victim = GetClientOfUserId(GetEventInt(event, "victim"));
	new Savior = GetClientOfUserId(GetEventInt(event, "userid"));

	HunterSmokerSave(Savior, Victim, GetConVarInt(cvar_SmokerDrag), 2, 3, "Smoker", "award_smoker");
}

// Save friendly from being choked by Smoker.

public Action:event_ChokeSave(Handle:event, const String:name[], bool:dontBroadcast)
{
	if (StatsDisabled())
		return;

	new Victim = GetClientOfUserId(GetEventInt(event, "victim"));
	new Savior = GetClientOfUserId(GetEventInt(event, "userid"));

	HunterSmokerSave(Savior, Victim, GetConVarInt(cvar_ChokePounce), 2, 3, "Smoker", "award_smoker");
}

// Save friendly from being pounced by Hunter.

public Action:event_PounceSave(Handle:event, const String:name[], bool:dontBroadcast)
{
	if (StatsDisabled())
		return;

	new Savior = GetClientOfUserId(GetEventInt(event, "userid"));
	new Victim = GetClientOfUserId(GetEventInt(event, "Victim"));

	if (Victim > 0)
		CreateTimer(INF_WEAROFF_TIME, timer_EndHunterLunged, Victim);

	HunterSmokerSave(Savior, Victim, GetConVarInt(cvar_ChokePounce), 2, 3, "Hunter", "award_hunter");
}

// Player is hanging from a ledge.

public Action:event_PlayerFallDamage(Handle:event, const String:name[], bool:dontBroadcast)
{
	if (StatsDisabled() || CampaignOver || !IsGamemodeVersus())
		return;

	new Victim = GetClientOfUserId(GetEventInt(event, "userid"));
	new Attacker = GetClientOfUserId(GetEventInt(event, "causer"));
	new Damage = RoundToNearest(GetEventFloat(event, "damage"));

	if (Attacker == 0 && PlayerJockied[Victim][0] && PlayerJockied[Victim][1])
		Attacker = PlayerJockied[Victim][1];

	if (Attacker == 0 || IsClientBot(Attacker) || GetClientTeam(Attacker) != TEAM_INFECTED || GetClientTeam(Victim) != TEAM_SURVIVORS || Damage <= 0)
		return;

	new VictimHealth = GetClientHealth(Victim);
	new VictimIsIncap = GetEntProp(Victim, Prop_Send, "m_isIncapacitated");

	// If the victim health is zero or below zero or is incapacitated don't count the damage from the fall
	if (VictimHealth <= 0 || VictimIsIncap != 0)
		return;

	// Damage should never exceed the amount of healt the fallen survivor had before falling down.
	if (VictimHealth < Damage)
		Damage = VictimHealth;

	if (Damage <= 0)
		return;

	SurvivorHurt(Attacker, Victim, Damage);
}

// Player melee killed an infected

public Action:event_MeleeKill(Handle:event, const String:name[], bool:dontBroadcast)
{
	if (StatsDisabled() || CampaignOver)
		return;

	new Attacker = GetClientOfUserId(GetEventInt(event, "userid"));
	//new EntityID = GetEventInt(event, "entityid");
	//new bool:Ambushed = GetEventBool(event, "ambush");

	if (Attacker == 0 || IsClientBot(Attacker) || GetClientTeam(Attacker) != TEAM_SURVIVORS || !IsClientConnected(Attacker) || !IsClientInGame(Attacker))
		return;

	IncrementMeleeKills(Attacker);
}

// Player is hanging from a ledge.

public Action:event_PlayerLedge(Handle:event, const String:name[], bool:dontBroadcast)
{
	if (StatsDisabled() || !IsGamemodeVersus())
		return;

	new Attacker = GetClientOfUserId(GetEventInt(event, "causer"));
	new Victim = GetClientOfUserId(GetEventInt(event, "userid"));

	if (Attacker == 0 && PlayerJockied[Victim][0] && PlayerJockied[Victim][1])
		Attacker = PlayerJockied[Victim][1];

	if (Attacker == 0 || IsClientBot(Attacker) || GetClientTeam(Attacker) != TEAM_INFECTED)
		return;

	new Score = ModifyScoreDifficultyFloat(GetConVarInt(cvar_PlayerLedgeSuccess), 0.9, 0.8, TEAM_INFECTED);

	if (Score > 0)
	{
		decl String:VictimName[MAX_LINE_WIDTH];
		GetClientName(Victim, VictimName, sizeof(VictimName));

		new Mode = GetConVarInt(cvar_AnnounceMode);

		decl String:ClientID[MAX_LINE_WIDTH];
		GetClientRankAuthString(Attacker, ClientID, sizeof(ClientID));

		decl String:query[1024];
		if (CurrentGamemodeID == GAMEMODE_VERSUS)
			Format(query, sizeof(query), "UPDATE %splayers SET points_infected = points_infected + %i, award_ledgegrab = award_ledgegrab + 1 WHERE steamid = '%s'", DbPrefix, Score, ClientID);
		else if (CurrentGamemodeID == GAMEMODE_REALISMVERSUS)
			Format(query, sizeof(query), "UPDATE %splayers SET points_realism_infected = points_realism_infected + %i, award_ledgegrab = award_ledgegrab + 1 WHERE steamid = '%s'", DbPrefix, Score, ClientID);
		else if (CurrentGamemodeID == GAMEMODE_SCAVENGE)
			Format(query, sizeof(query), "UPDATE %splayers SET points_scavenge_infected = points_scavenge_infected + %i, award_ledgegrab = award_ledgegrab + 1 WHERE steamid = '%s'", DbPrefix, Score, ClientID);
		else
			Format(query, sizeof(query), "UPDATE %splayers SET points_mutations = points_mutations + %i, award_ledgegrab = award_ledgegrab + 1 WHERE steamid = '%s'", DbPrefix, Score, ClientID);

		SendSQLUpdate(query);

		UpdateMapStat("points_infected", Score);

		if (Mode == 1 || Mode == 2)
			StatsPrintToChat(Attacker, "你造成玩家 \x05%s\x01 挂边获得 \x04%i \x01分!", VictimName, Score);
		else if (Mode == 3)
		{
			decl String:AttackerName[MAX_LINE_WIDTH];
			GetClientName(Attacker, AttackerName, sizeof(AttackerName));
			StatsPrintToChatAll("\x05%s \x01造成玩家 \x05%s\x01 挂边获得 \x04%i \x01分!", AttackerName, VictimName, Score);
		}
	}
}

// Player spawned in game.

public Action:event_PlayerSpawn(Handle:event, const String:name[], bool:dontBroadcast)
{
	if (StatsDisabled())
		return;

	new Player = GetClientOfUserId(GetEventInt(event, "userid"));

	if (Player == 0)
		return;

	InitializeClientInf(Player);

	ClientInfectedType[Player] = 0;
	BoomerHitCounter[Player] = 0;
	BoomerVomitUpdated[Player] = false;
	SmokerDamageCounter[Player] = 0;
	SpitterDamageCounter[Player] = 0;
	JockeyDamageCounter[Player] = 0;
	ChargerDamageCounter[Player] = 0;
	ChargerImpactCounter[Player] = 0;
	TankPointsCounter[Player] = 0;
	TankDamageCounter[Player] = 0;
	TankDamageTotalCounter[Player] = 0;
	TankSurvivorKillCounter[Player] = 0;
	ChargerCarryVictim[Player] = 0;
	ChargerPlummelVictim[Player] = 0;
	JockeyVictim[Player] = 0;
	JockeyRideStartTime[Player] = 0;

	PlayerBlinded[Player][0] = 0;
	PlayerBlinded[Player][1] = 0;
	PlayerParalyzed[Player][0] = 0;
	PlayerParalyzed[Player][1] = 0;
	PlayerLunged[Player][0] = 0;
	PlayerLunged[Player][1] = 0;
	PlayerPlummeled[Player][0] = 0;
	PlayerPlummeled[Player][1] = 0;
	PlayerCarried[Player][0] = 0;
	PlayerCarried[Player][1] = 0;
	PlayerJockied[Player][0] = 0;
	PlayerJockied[Player][1] = 0;

	if (!IsClientBot(Player))
		SetClientInfectedType(Player);

	if (ChargerImpactCounterTimer[Player] != INVALID_HANDLE)
		CloseHandle(ChargerImpactCounterTimer[Player]);

	ChargerImpactCounterTimer[Player] = INVALID_HANDLE;
}

// Player hurt. Used for calculating damage points for the Infected players and also
// the friendly fire damage when Friendly Fire Mode is set to Damage Based.

public Action:event_PlayerHurt(Handle:event, const String:name[], bool:dontBroadcast)
{
	if (StatsDisabled() || CampaignOver)
		return;

	new Attacker = GetClientOfUserId(GetEventInt(event, "attacker"));
	new Victim = GetClientOfUserId(GetEventInt(event, "userid"));

	// Self inflicted damage does not count
	if (Attacker == Victim)
		return;

	if (Attacker == 0 || IsClientBot(Attacker))
	{
		// Attacker is normal indected but the Victim was infected by blinding and/or paralysation.
		if (Attacker == 0
				&& Victim > 0
				&& (PlayerBlinded[Victim][0] && PlayerBlinded[Victim][1]
					|| PlayerParalyzed[Victim][0] && PlayerParalyzed[Victim][1]
					|| PlayerLunged[Victim][0] && PlayerLunged[Victim][1]
					|| PlayerCarried[Victim][0] && PlayerCarried[Victim][1]
					|| PlayerPlummeled[Victim][0] && PlayerPlummeled[Victim][1]
					|| PlayerJockied[Victim][0] && PlayerJockied[Victim][1])
				&& IsGamemodeVersus())
			SurvivorHurtExternal(event, Victim);

		return;
	}

	new Damage = GetEventInt(event, "dmg_health");
	new AttackerTeam = GetClientTeam(Attacker);
	new AttackerInfType = -1;

	new VictimTeam = GetClientTeam(Victim);
	if (AttackerTeam == VictimTeam && AttackerTeam == TEAM_INFECTED)
		return;

	if (Attacker > 0&&L4D_HasAnySurvivorLeftSafeArea())
	{
		if (AttackerTeam == TEAM_INFECTED)
			AttackerInfType = ClientInfectedType[Attacker];
		else if (AttackerTeam == TEAM_SURVIVORS && GetConVarInt(cvar_FriendlyFireMode) == 2)
		{
			if (VictimTeam == TEAM_SURVIVORS)
			{
				if (FriendlyFireTimer[Attacker][0] != INVALID_HANDLE)
				{
					CloseHandle(FriendlyFireTimer[Attacker][0]);
					FriendlyFireTimer[Attacker][0] = INVALID_HANDLE;
				}

				decl String:AttackerID[MAX_LINE_WIDTH];
				GetClientRankAuthString(Attacker, AttackerID, sizeof(AttackerID));
				decl String:AttackerName[MAX_LINE_WIDTH];
				GetClientName(Attacker, AttackerName, sizeof(AttackerName));

				// Using datapack to deliver the needed info so that the attacker can't escape the penalty by disconnecting

				new Handle:dp = INVALID_HANDLE;
				new OldHumanDamage = 0;
				new OldBotDamage = 0;

				if (!GetTrieValue(FriendlyFireDamageTrie, AttackerID, dp))
				{
					dp = CreateDataPack();
					SetTrieValue(FriendlyFireDamageTrie, AttackerID, dp);
				}
				else
				{
					// Read old damage value
					ResetPack(dp);
					OldHumanDamage = ReadPackCell(dp);
					OldBotDamage = ReadPackCell(dp);
				}

				if (IsClientBot(Victim))
					OldBotDamage += Damage;
				else
					OldHumanDamage += Damage;

				ResetPack(dp, true);

				WritePackCell(dp, OldHumanDamage);
				WritePackCell(dp, OldBotDamage);
				WritePackCell(dp, Attacker);
				WritePackString(dp, AttackerID);
				WritePackString(dp, AttackerName);

				// This may fail! What happens when a player skips and another joins with the same Client ID (is this even possible in such short time?)
				FriendlyFireTimer[Attacker][0] = CreateTimer(5.0, timer_FriendlyFireDamageEnd, dp);

				return;
			}
		}
	}
	if (AttackerInfType < 0)
		return;

//	decl String:AttackerID[MAX_LINE_WIDTH];
//	GetClientRankAuthString(Attacker, AttackerID, sizeof(AttackerID));

//	new Mode;
//	new Victim = GetClientOfUserId(GetEventInt(event, "userid"));
//	decl String:VictimName[MAX_LINE_WIDTH];
//	new VictimTeam = 0;
//	new Score = 0;

//	if (Victim > 0)
//	{
//		GetClientName(Victim, VictimName, sizeof(VictimName));
//		VictimTeam = GetClientTeam(Victim);
//	}
//	else
//		Format(VictimName, sizeof(VictimName), "UNKNOWN");

//	if (VictimTeam == TEAM_INFECTED)
//	{
//		decl String:query[1024];
//
//		Score = GetConVarInt(cvar_FFire);
//		Format(query, sizeof(query), "UPDATE %splayers SET points_infected = points_infected - %i WHERE steamid = '%s'", DbPrefix, Score, AttackerID);
//		SendSQLUpdate(query);
//
//		UpdateMapStat("points_infected", Score * -1);
//		Mode = GetConVarInt(cvar_AnnounceMode);
//
//		if (Mode == 1 || Mode == 2)
//			StatsPrintToChat(Attacker, "You have \x03LOST \x04%i \x01points for \x03Friendly Firing \x05%s\x01!", Score, VictimName);
//		else if (Mode == 3)
//		{
//			decl String:AttackerName[MAX_LINE_WIDTH];
//			GetClientName(Attacker, AttackerName, sizeof(AttackerName));
//			StatsPrintToChatAll("\x05%s \x01has \x03LOST \x04%i \x01points for \x03Friendly Firing \x05%s\x01!", AttackerName, Score, VictimName);
//		}
//
//		return;
//	}

	SurvivorHurt(Attacker, Victim, Damage, AttackerInfType, event);
}

// Smoker events.

public Action:event_SmokerGrap(Handle:event, const String:name[], bool:dontBroadcast)
{
	if (StatsDisabled() || !IsGamemodeVersus() || CampaignOver)
		return;

	new Attacker = GetClientOfUserId(GetEventInt(event, "userid"));
	new Victim = GetClientOfUserId(GetEventInt(event, "victim"));

	PlayerParalyzed[Victim][0] = 1;
	PlayerParalyzed[Victim][1] = Attacker;
}

// Jockey events.

public Action:event_JockeyStart(Handle:event, const String:name[], bool:dontBroadcast)
{
	if (StatsDisabled() || CampaignOver)
		return;

	new Attacker = GetClientOfUserId(GetEventInt(event, "userid"));
	new Victim = GetClientOfUserId(GetEventInt(event, "victim"));

	PlayerJockied[Victim][0] = 1;
	PlayerJockied[Victim][1] = Attacker;

	JockeyVictim[Attacker] = Victim;
	JockeyRideStartTime[Attacker] = 0;

	if (Attacker == 0 || IsClientBot(Attacker) || !IsClientConnected(Attacker) || !IsClientInGame(Attacker))
		return;

	JockeyRideStartTime[Attacker] = GetTime();

	decl String:query[1024];
	decl String:iID[MAX_LINE_WIDTH];
	GetClientRankAuthString(Attacker, iID, sizeof(iID));
	Format(query, sizeof(query), "UPDATE %splayers SET jockey_rides = jockey_rides + 1 WHERE steamid = '%s'", DbPrefix, iID);
	SendSQLUpdate(query);
	UpdateMapStat("jockey_rides", 1);
}

public Action:event_JockeyRelease(Handle:event, const String:name[], bool:dontBroadcast)
{
	if (StatsDisabled() || CampaignOver)
		return;

	new Jockey = GetClientOfUserId(GetEventInt(event, "userid"));
	new Victim = GetClientOfUserId(GetEventInt(event, "victim"));
	new Rescuer = GetClientOfUserId(GetEventInt(event, "rescuer"));
	new Float:RideLength = GetEventFloat(event, "ride_length");

	if (Rescuer > 0 && !IsClientBot(Rescuer) && IsClientInGame(Rescuer))
	{
		decl String:query[1024], String:JockeyName[MAX_LINE_WIDTH], String:VictimName[MAX_LINE_WIDTH], String:RescuerName[MAX_LINE_WIDTH], String:RescuerID[MAX_LINE_WIDTH], String:UpdatePoints[32];
		new Score = ModifyScoreDifficulty(GetConVarInt(cvar_JockeyRide), 2, 3, TEAM_SURVIVORS);

		GetClientRankAuthString(Rescuer, RescuerID, sizeof(RescuerID));

		switch (CurrentGamemodeID)
		{
			case GAMEMODE_VERSUS:
			{
				Format(UpdatePoints, sizeof(UpdatePoints), "points_survivors");
			}
			case GAMEMODE_REALISM:
			{
				Format(UpdatePoints, sizeof(UpdatePoints), "points_realism");
			}
			case GAMEMODE_SURVIVAL:
			{
				Format(UpdatePoints, sizeof(UpdatePoints), "points_survival");
			}
			case GAMEMODE_SCAVENGE:
			{
				Format(UpdatePoints, sizeof(UpdatePoints), "points_scavenge_survivors");
			}
			case GAMEMODE_REALISMVERSUS:
			{
				Format(UpdatePoints, sizeof(UpdatePoints), "points_realism_survivors");
			}
			case GAMEMODE_OTHERMUTATIONS:
			{
				Format(UpdatePoints, sizeof(UpdatePoints), "points_mutations");
			}
			default:
			{
				Format(UpdatePoints, sizeof(UpdatePoints), "points");
			}
		}

		Format(query, sizeof(query), "UPDATE %splayers SET %s = %s + %i, award_jockey = award_jockey + 1 WHERE steamid = '%s'", DbPrefix, UpdatePoints, UpdatePoints, Score, RescuerID);
		SendSQLUpdate(query);

		if (Score > 0)
		{
			UpdateMapStat("points", Score);
			AddScore(Rescuer, Score);
		}

		GetClientName(Jockey, JockeyName, sizeof(JockeyName));
		GetClientName(Victim, VictimName, sizeof(VictimName));

		new Mode = GetConVarInt(cvar_AnnounceMode);

		if (Score > 0)
		{
			if (Mode == 1 || Mode == 2)
				StatsPrintToChat(Rescuer, "你将 \x05%s \x01从 \x04%s\x01 手里救下获得\x04%i \x01分!", VictimName, JockeyName, Score);
			else if (Mode == 3)
			{
				GetClientName(Rescuer, RescuerName, sizeof(RescuerName));
				StatsPrintToChatAll("\x05%s \x01将 \x05%s \x01从 \x04%s\x01 手里救下获得\x04%i \x01分!", RescuerName, VictimName, JockeyName, Score);
			}
		}
	}

	JockeyVictim[Jockey] = 0;

	if (Jockey == 0 || IsClientBot(Jockey) || !IsClientInGame(Jockey))
	{
		PlayerJockied[Victim][0] = 0;
		PlayerJockied[Victim][1] = 0;
		JockeyRideStartTime[Victim] = 0;
		return;
	}

	UpdateJockeyRideLength(Jockey, RideLength);

	if (Victim > 0)
		CreateTimer(INF_WEAROFF_TIME, timer_EndJockeyRide, Victim);
}

public Action:event_JockeyKilled(Handle:event, const String:name[], bool:dontBroadcast)
{
	if (StatsDisabled())
		return;

	new Attacker = GetClientOfUserId(GetEventInt(event, "userid"));

	if (Attacker == 0 || IsClientBot(Attacker) || !IsClientInGame(Attacker))
		return;

	new Victim = GetClientOfUserId(GetEventInt(event, "victim"));

	if (Victim > 0)
		CreateTimer(INF_WEAROFF_TIME, timer_EndJockeyRide, Victim);
}

// Charger events.

public Action:event_ChargerKilled(Handle:event, const String:name[], bool:dontBroadcast)
{
	int human = CheckSurvivorsHumans();
	if (StatsDisabled() || CampaignOver || human < 3)
		return;

	new Killer = GetClientOfUserId(GetEventInt(event, "attacker"));

	if (Killer == 0 || IsClientBot(Killer) || !IsClientInGame(Killer))
		return;

	new Charger = GetClientOfUserId(GetEventInt(event, "userid"));
	decl String:query[1024], String:KillerName[MAX_LINE_WIDTH], String:KillerID[MAX_LINE_WIDTH], String:UpdatePoints[32];
	new Score = 0;
	new bool:IsMatador = GetEventBool(event, "melee") && GetEventBool(event, "charging");

	GetClientRankAuthString(Killer, KillerID, sizeof(KillerID));

	switch (CurrentGamemodeID)
	{
		case GAMEMODE_VERSUS:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_survivors");
		}
		case GAMEMODE_REALISM:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_realism");
		}
		case GAMEMODE_SURVIVAL:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_survival");
		}
		case GAMEMODE_SCAVENGE:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_scavenge_survivors");
		}
		case GAMEMODE_REALISMVERSUS:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_realism_survivors");
		}
		case GAMEMODE_OTHERMUTATIONS:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_mutations");
		}
		default:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points");
		}
	}

	if (ChargerCarryVictim[Charger])
	{
		Score += ModifyScoreDifficulty(GetConVarInt(cvar_ChargerCarry), 2, 3, TEAM_SURVIVORS);
	}
	else if (ChargerPlummelVictim[Charger])
	{
		Score += ModifyScoreDifficulty(GetConVarInt(cvar_ChargerPlummel), 2, 3, TEAM_SURVIVORS);
	}

	if (IsMatador)
	{
		// Give a Matador award
		Score += ModifyScoreDifficulty(GetConVarInt(cvar_Matador), 2, 3, TEAM_SURVIVORS);
	}

	Format(query, sizeof(query), "UPDATE %splayers SET %s = %s + %i, award_charger = award_charger + 1%s WHERE steamid = '%s'", DbPrefix, UpdatePoints, UpdatePoints, Score, (IsMatador ? ", award_matador = award_matador + 1" : ""), KillerID);
	SendSQLUpdate(query);

	if (Score <= 0)
		return;

	UpdateMapStat("points", Score);
	AddScore(Killer, Score);

	new Mode = GetConVarInt(cvar_AnnounceMode);

	if (Mode)
	{
		GetClientName(Killer, KillerName, sizeof(KillerName));

		if (IsMatador)
		{
			if (Mode == 1 || Mode == 2)
				StatsPrintToChat(Killer, "你 \x04秒了个牛\x01 获得 \x04%i \x01分!", Score);
			else if (Mode == 3)
				StatsPrintToChatAll("\x05%s \x01 \x04秒了个牛\x01 获得 \x04%i \x01分!", KillerName, Score);
		}
		else
		{
			decl String:VictimName[MAX_LINE_WIDTH], String:ChargerName[MAX_LINE_WIDTH];

			GetClientName(Charger, ChargerName, sizeof(ChargerName));

			if (ChargerCarryVictim[Charger] > 0 && (IsClientBot(ChargerCarryVictim[Charger]) || (IsClientConnected(ChargerCarryVictim[Charger]) && IsClientInGame(ChargerCarryVictim[Charger]))))
			{
				GetClientName(ChargerCarryVictim[Charger], VictimName, sizeof(VictimName));
				Format(VictimName, sizeof(VictimName), "\x05%s\x01", VictimName);
			}
			else
				Format(VictimName, sizeof(VictimName), "a survivor");

			if (Mode == 1 || Mode == 2)
				StatsPrintToChat(Killer, "你将 \x05%s\x01 从 \x04%s\x01 手里救下获得 \x04%i \x01分!", VictimName, ChargerName, Score);
			else if (Mode == 3)
				StatsPrintToChatAll("\x05%s \x01将 \x05%s\x01 从 \x04%s\x01 手里救下获得 \x04%i \x01分!", KillerName, VictimName, ChargerName, Score);
		}
	}
}

public Action:event_ChargerCarryStart(Handle:event, const String:name[], bool:dontBroadcast)
{
	if (StatsDisabled())
		return;

	new Attacker = GetClientOfUserId(GetEventInt(event, "userid"));
	new Victim = GetClientOfUserId(GetEventInt(event, "victim"));

	PlayerCarried[Victim][0] = 1;
	PlayerCarried[Victim][1] = Attacker;

	ChargerCarryVictim[Attacker] = Victim;

	if (IsClientBot(Attacker) || !IsClientConnected(Attacker) || !IsClientInGame(Attacker))
		return;

	IncrementImpactCounter(Attacker);
}

public Action:event_ChargerCarryRelease(Handle:event, const String:name[], bool:dontBroadcast)
{
	if (StatsDisabled())
		return;

	//new Attacker = GetClientOfUserId(GetEventInt(event, "userid"));
	new Victim = GetClientOfUserId(GetEventInt(event, "victim"));

	//if (Attacker == 0 || IsClientBot(Attacker) || !IsClientInGame(Attacker))
	//{
	//	ChargerCarryVictim[Attacker] = 0;
	//	PlayerCarried[Victim][0] = 0;
	//	PlayerCarried[Victim][1] = 0;
	//	return;
	//}

	if (Victim > 0)
		CreateTimer(INF_WEAROFF_TIME, timer_EndChargerCarry, Victim);
}

public Action:event_ChargerImpact(Handle:event, const String:name[], bool:dontBroadcast)
{
	if (StatsDisabled() || CampaignOver)
		return;

	new Attacker = GetClientOfUserId(GetEventInt(event, "userid"));

	if (Attacker == 0 || IsClientBot(Attacker) || !IsClientConnected(Attacker) || !IsClientInGame(Attacker))
		return;

	//new Victim = GetClientOfUserId(GetEventInt(event, "victim"));
	IncrementImpactCounter(Attacker);
}

IncrementImpactCounter(client)
{
	if (ChargerImpactCounterTimer[client] != INVALID_HANDLE)
		CloseHandle(ChargerImpactCounterTimer[client]);

	ChargerImpactCounterTimer[client] = CreateTimer(3.0, timer_EndCharge, client);

	ChargerImpactCounter[client]++;
}

public Action:event_ChargerPummelStart(Handle:event, const String:name[], bool:dontBroadcast)
{
	if (StatsDisabled())
		return;

	new Attacker = GetClientOfUserId(GetEventInt(event, "userid"));

	// There is no delay on charger carry once the plummel starts
	ChargerCarryVictim[Attacker] = 0;

	new Victim = GetClientOfUserId(GetEventInt(event, "victim"));

	PlayerPlummeled[Victim][0] = 1;
	PlayerPlummeled[Victim][1] = Attacker;

	ChargerPlummelVictim[Attacker] = Victim;

	//if (Attacker == 0 || IsClientBot(Attacker) || !IsClientInGame(Attacker))
	//	return;
}

public Action:event_ChargerPummelRelease(Handle:event, const String:name[], bool:dontBroadcast)
{
	if (StatsDisabled())
		return;

	new Attacker = GetClientOfUserId(GetEventInt(event, "userid"));
	new Victim = GetClientOfUserId(GetEventInt(event, "victim"));

	if (Attacker == 0 || IsClientBot(Attacker) || !IsClientInGame(Attacker))
	{
		PlayerPlummeled[Victim][0] = 0;
		PlayerPlummeled[Victim][1] = 0;
		ChargerPlummelVictim[Attacker] = 0;
		return;
	}

	if (Victim > 0)
		CreateTimer(INF_WEAROFF_TIME, timer_EndChargerPlummel, Victim);
}

// Hunter events.

public Action:event_HunterRelease(Handle:event, const String:name[], bool:dontBroadcast)
{
	if (StatsDisabled())
		return;

	new Player = GetClientOfUserId(GetEventInt(event, "victim"));

	if (Player > 0)
		CreateTimer(INF_WEAROFF_TIME, timer_EndHunterLunged, Player);
}

// Smoker events.

public Action:event_SmokerRelease(Handle:event, const String:name[], bool:dontBroadcast)
{
	if (StatsDisabled())
		return;

	new Player = GetClientOfUserId(GetEventInt(event, "victim"));

	if (Player > 0)
		CreateTimer(INF_WEAROFF_TIME, timer_EndSmokerParalyzed, Player);
}

// L4D2 ammo upgrade deployed event.

public Action:event_UpgradePackAdded(Handle:event, const String:name[], bool:dontBroadcast)
{
	if (StatsDisabled() || CampaignOver)
		return;

	if (CurrentGamemodeID == GAMEMODE_SURVIVAL && !SurvivalStarted)
		return;

	new Player = GetClientOfUserId(GetEventInt(event, "userid"));

	if (Player == 0 || IsClientBot(Player))
		return;

	new Score = GetConVarInt(cvar_AmmoUpgradeAdded);

	if (Score > 0)
		Score = ModifyScoreDifficulty(Score, 2, 3, TEAM_SURVIVORS);

	decl String:PlayerID[MAX_LINE_WIDTH];
	GetClientRankAuthString(Player, PlayerID, sizeof(PlayerID));

	decl String:UpdatePoints[32];

	switch (CurrentGamemodeID)
	{
		case GAMEMODE_VERSUS:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_survivors");
		}
		case GAMEMODE_REALISM:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_realism");
		}
		case GAMEMODE_SURVIVAL:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_survival");
		}
		case GAMEMODE_SCAVENGE:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_scavenge_survivors");
		}
		case GAMEMODE_REALISMVERSUS:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_realism_survivors");
		}
		case GAMEMODE_OTHERMUTATIONS:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_mutations");
		}
		default:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points");
		}
	}

	decl String:query[1024];
	Format(query, sizeof(query), "UPDATE %splayers SET %s = %s + %i, award_upgrades_added = award_upgrades_added + 1 WHERE steamid = '%s'", DbPrefix, UpdatePoints, UpdatePoints, Score, PlayerID);

	SendSQLUpdate(query);

	if (Score > 0)
	{
		new Mode = GetConVarInt(cvar_AnnounceMode);

		if (!Mode)
			return;

		new EntityID = GetEventInt(event, "upgradeid");
		decl String:ModelName[128];
		GetEntPropString(EntityID, Prop_Data, "m_ModelName", ModelName, sizeof(ModelName));

		if (StrContains(ModelName, "incendiary_ammo", false) >= 0)
			strcopy(ModelName, sizeof(ModelName), "Incendiary Ammo");
		else if (StrContains(ModelName, "exploding_ammo", false) >= 0)
			strcopy(ModelName, sizeof(ModelName), "Exploding Ammo");
		else
			strcopy(ModelName, sizeof(ModelName), "UNKNOWN");

		if (Mode == 1 || Mode == 2)
			StatsPrintToChat(Player, "你部署一个 \x05%s\x01获得 \x04%i \x01分!", ModelName, Score);
		else if (Mode == 3)
		{
			decl String:PlayerName[MAX_LINE_WIDTH];
			GetClientName(Player, PlayerName, sizeof(PlayerName));
			StatsPrintToChatAll("\x05%s \x01部署一个 \x05%s\x01获得 \x04%i \x01分!", PlayerName, ModelName, Score);
		}
	}
}

// L4D2 gascan pour completed event.

public Action:event_GascanPoured(Handle:event, const String:name[], bool:dontBroadcast)
{
	if (StatsDisabled() || CampaignOver)
		return;

	new Player = GetClientOfUserId(GetEventInt(event, "userid"));

	if (Player == 0 || IsClientBot(Player))
		return;

	new Score = GetConVarInt(cvar_GascanPoured);

	if (Score > 0)
		Score = ModifyScoreDifficulty(Score, 2, 3, TEAM_SURVIVORS);

	decl String:PlayerID[MAX_LINE_WIDTH];
	GetClientRankAuthString(Player, PlayerID, sizeof(PlayerID));

	decl String:UpdatePoints[32];

	switch (CurrentGamemodeID)
	{
		case GAMEMODE_VERSUS:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_survivors");
		}
		case GAMEMODE_REALISM:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_realism");
		}
		case GAMEMODE_SURVIVAL:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_survival");
		}
		case GAMEMODE_SCAVENGE:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_scavenge_survivors");
		}
		case GAMEMODE_REALISMVERSUS:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_realism_survivors");
		}
		case GAMEMODE_OTHERMUTATIONS:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_mutations");
		}
		default:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points");
		}
	}

	decl String:query[1024];
	Format(query, sizeof(query), "UPDATE %splayers SET %s = %s + %i, award_gascans_poured = award_gascans_poured + 1 WHERE steamid = '%s'", DbPrefix, UpdatePoints, UpdatePoints, Score, PlayerID);

	SendSQLUpdate(query);

	if (Score > 0)
	{
		new Mode = GetConVarInt(cvar_AnnounceMode);

		if (Mode == 1 || Mode == 2)
			StatsPrintToChat(Player, "你成功 \x04灌了桶油\x01 获得了 \x04%i \x01分!", Score);
		else if (Mode == 3)
		{
			decl String:PlayerName[MAX_LINE_WIDTH];
			GetClientName(Player, PlayerName, sizeof(PlayerName));
			StatsPrintToChatAll("\x05%s \x01成功 \x04灌了桶油\x01 获得了 \x04%i \x01分!", PlayerName, Score);
		}
	}
}

// Achievement earned.

/*
56 - Helping Hand
57 - Field Medic
58 - Pharm-Assist
59 - My Bodyguard
60 - Dead Stop
61 - Crownd
62 - Untouchables
63 -
64 - Drag and Drop
65 - Blind Luck
66 - Akimbo Assassin
67 -
68 - Hero Closet
69 - Hunter Punter
70 - Tongue Twister
71 - No Smoking Section
72 -
73 - 101 Cremations
74 - Do Not Disturb
75 - Man Vs Tank
76 - TankBusters
77 - Safety First
78 - No-one Left Behind
79 -
80 -
81 - Unbreakable
82 - Witch Hunter
83 - Red Mist
84 - Pyrotechnician
85 - Zombie Genocidest
86 - Dead Giveaway
87 - Stand Tall
88 -
89 -
90 - Zombicidal Maniac
91 - What are you trying to Prove?
92 -
93 - Nothing Special
94 - Burn the Witch
95 - Towering Inferno
96 - Spinal Tap
97 - Stomach Upset
98 - Brain Salad
99 - Jump Shot
100 - Mercy Killer
101 - Back 2 Help
102 - Toll Collector
103 - Dead Baron
104 - Grim Reaper
105 - Ground Cover
106 - Clean Kill
107 - Big Drag
108 - Chain Smoker
109 - Barf Bagged
110 - Double Jump
111 - All 4 Dead
112 - Dead Wreckening
113 - Lamb 2 Slaughter
114 - Outbreak
*/

public Action:event_Achievement(Handle:event, const String:name[], bool:dontBroadcast)
{
	if (StatsDisabled())
	{
		return;
	}

	new Player = GetClientOfUserId(GetEventInt(event, "player"));
	new Achievement = GetEventInt(event, "achievement");

	if (IsClientBot(Player))
	{
		return;
	}

	if (DEBUG)
	{
		LogMessage("Achievement earned: %i", Achievement);
	}
}

// Saferoom door opens.

public Action:event_DoorOpen(Handle:event, const String:name[], bool:dontBroadcast)
{
	if(MapTimingBlocked || MapTimingStartTime != 0.0 || !GetEventBool(event, "checkpoint") || !GetEventBool(event, "closed") || CurrentGamemodeID == GAMEMODE_SURVIVAL || StatsDisabled())
	{
		MapTimingBlocked = true;
		return Plugin_Continue;
	}

	StartMapTiming();
	Isstart = true;

	return Plugin_Continue;
}

public Action:event_StartArea(Handle:event, const String:name[], bool:dontBroadcast)
{
	if(MapTimingBlocked || MapTimingStartTime != 0.0 || CurrentGamemodeID == GAMEMODE_SURVIVAL || StatsDisabled())
	{
		MapTimingBlocked = true;
		return Plugin_Continue;
	}
	StartMapTiming();
	Isstart = true;

	return Plugin_Continue;
}

public Action:event_PlayerTeam(Handle:event, const String:name[], bool:dontBroadcast)
{
	if(MapTimingBlocked || MapTimingStartTime != 0.0 || GetEventBool(event, "isbot"))
	{
		return Plugin_Continue;
	}

	new Player = GetClientOfUserId(GetEventInt(event, "userid"));
	//new NewTeam = GetEventInt(event, "team");
	//new OldTeam = GetEventInt(event, "oldteam");

	if (Player <= 0)
	{
		return Plugin_Continue;
	}

	decl String:PlayerID[MAX_LINE_WIDTH];
	GetClientRankAuthString(Player, PlayerID, sizeof(PlayerID));

	RemoveFromTrie(MapTimingSurvivors, PlayerID);
	RemoveFromTrie(MapTimingInfected, PlayerID);

	return Plugin_Continue;
}

// AbilityUse.

public Action:event_AbilityUse(Handle:event, const String:name[], bool:dontBroadcast)
{
	if (StatsDisabled())
		return;

	new Player = GetClientOfUserId(GetEventInt(event, "userid"));
	GetClientAbsOrigin(Player, HunterPosition[Player]);

	if (!IsClientBot(Player) && GetClientInfectedType(Player) == INF_ID_BOOMER)
	{
		decl String:query[1024];
		decl String:iID[MAX_LINE_WIDTH];
		GetClientRankAuthString(Player, iID, sizeof(iID));
		Format(query, sizeof(query), "UPDATE %splayers SET infected_boomer_vomits = infected_boomer_vomits + 1 WHERE steamid = '%s'", DbPrefix, iID);
		SendSQLUpdate(query);
		UpdateMapStat("infected_boomer_vomits", 1);
		BoomerVomitUpdated[Player] = true;
	}
}

// Player got pounced.

public Action:event_PlayerPounced(Handle:event, const String:name[], bool:dontBroadcast)
{
	if (StatsDisabled() || CampaignOver)
		return;

	new Attacker = GetClientOfUserId(GetEventInt(event, "userid"));
	new Victim = GetClientOfUserId(GetEventInt(event, "victim"));

	PlayerLunged[Victim][0] = 1;
	PlayerLunged[Victim][1] = Attacker;

	if (IsClientBot(Attacker))
		return;

	new Float:PouncePosition[3];

	GetClientAbsOrigin(Attacker, PouncePosition);
	new PounceDistance = RoundToNearest(GetVectorDistance(HunterPosition[Attacker], PouncePosition));

	if (PounceDistance < MinPounceDistance)
		return;

	new Dmg = RoundToNearest((((PounceDistance - float(MinPounceDistance)) / float(MaxPounceDistance - MinPounceDistance)) * float(MaxPounceDamage)) + 1);
	new DmgCap = GetConVarInt(cvar_HunterDamageCap);

	if (Dmg > DmgCap)
		Dmg = DmgCap;

	new PerfectDmgLimit = GetConVarInt(cvar_HunterPerfectPounceDamage);
	new NiceDmgLimit = GetConVarInt(cvar_HunterNicePounceDamage);

	UpdateHunterDamage(Attacker, Dmg);

	if (Dmg < NiceDmgLimit && Dmg < PerfectDmgLimit)
		return;

	new Mode = GetConVarInt(cvar_AnnounceMode);

	decl String:AttackerName[MAX_LINE_WIDTH];
	GetClientName(Attacker, AttackerName, sizeof(AttackerName));
	decl String:AttackerID[MAX_LINE_WIDTH];
	GetClientRankAuthString(Attacker, AttackerID, sizeof(AttackerID));
	decl String:VictimName[MAX_LINE_WIDTH];
	GetClientName(Victim, VictimName, sizeof(VictimName));

	new Score = 0;
	decl String:Label[32];
	decl String:query[1024];

	if (Dmg >= PerfectDmgLimit)
	{
		Score = GetConVarInt(cvar_HunterPerfectPounceSuccess);
		if (CurrentGamemodeID == GAMEMODE_VERSUS)
			Format(query, sizeof(query), "UPDATE %splayers SET points_infected = points_infected + %i, award_pounce_perfect = award_pounce_perfect + 1 WHERE steamid = '%s'", DbPrefix, Score, AttackerID);
		else if (CurrentGamemodeID == GAMEMODE_REALISMVERSUS)
			Format(query, sizeof(query), "UPDATE %splayers SET points_realism_infected = points_realism_infected + %i, award_pounce_perfect = award_pounce_perfect + 1 WHERE steamid = '%s'", DbPrefix, Score, AttackerID);
		else if (CurrentGamemodeID == GAMEMODE_SCAVENGE)
			Format(query, sizeof(query), "UPDATE %splayers SET points_scavenge_infected = points_scavenge_infected + %i, award_pounce_perfect = award_pounce_perfect + 1 WHERE steamid = '%s'", DbPrefix, Score, AttackerID);
		else
			Format(query, sizeof(query), "UPDATE %splayers SET points_mutations = points_mutations + %i, award_pounce_perfect = award_pounce_perfect + 1 WHERE steamid = '%s'", DbPrefix, Score, AttackerID);
		Format(Label, sizeof(Label), "Death From Above");

		if (EnableSounds_Hunter_Perfect && GetConVarBool(cvar_SoundsEnabled))
			EmitSoundToAll(StatsSound_Hunter_Perfect);
	}
	else
	{
		Score = GetConVarInt(cvar_HunterNicePounceSuccess);
		if (CurrentGamemodeID == GAMEMODE_VERSUS)
			Format(query, sizeof(query), "UPDATE %splayers SET points_infected = points_infected + %i, award_pounce_nice = award_pounce_nice + 1 WHERE steamid = '%s'", DbPrefix, Score, AttackerID);
		else if (CurrentGamemodeID == GAMEMODE_REALISMVERSUS)
			Format(query, sizeof(query), "UPDATE %splayers SET points_realism_infected = points_realism_infected + %i, award_pounce_nice = award_pounce_nice + 1 WHERE steamid = '%s'", DbPrefix, Score, AttackerID);
		else if (CurrentGamemodeID == GAMEMODE_SCAVENGE)
			Format(query, sizeof(query), "UPDATE %splayers SET points_scavenge_infected = points_scavenge_infected + %i, award_pounce_nice = award_pounce_nice + 1 WHERE steamid = '%s'", DbPrefix, Score, AttackerID);
		else
			Format(query, sizeof(query), "UPDATE %splayers SET points_mutations = points_mutations + %i, award_pounce_nice = award_pounce_nice + 1 WHERE steamid = '%s'", DbPrefix, Score, AttackerID);
		Format(Label, sizeof(Label), "Pain From Above");
	}

	SendSQLUpdate(query);
	UpdateMapStat("points_infected", Score);

	if (Mode == 1 || Mode == 2)
		StatsPrintToChat(Attacker, "你在\x05%s\x01身上完成了一个 \x05%s \x01扑倒，获得 \x04%i \x01分!", VictimName, Label, Score);
	else if (Mode == 3)
		StatsPrintToChatAll("\x05%s 在\x05%s\x01身上完成了一个 \x05%s \x01扑倒，获得 \x04%i \x01分!", AttackerName, VictimName, Label, Score);
}

// Revive friendly code.

public Action:event_RevivePlayer(Handle:event, const String:name[], bool:dontBroadcast)
{
	if (StatsDisabled())
		return;

	if (CurrentGamemodeID == GAMEMODE_SURVIVAL && !SurvivalStarted)
		return;

	if (GetEventBool(event, "ledge_hang"))
		return;

	new Savior = GetClientOfUserId(GetEventInt(event, "userid"));
	new Victim = GetClientOfUserId(GetEventInt(event, "subject"));
	new Mode = GetConVarInt(cvar_AnnounceMode);

	if (IsClientBot(Savior) || IsClientBot(Victim) || Savior == Victim)
		return;
		

	decl String:SaviorName[MAX_LINE_WIDTH];
	GetClientName(Savior, SaviorName, sizeof(SaviorName));
	decl String:SaviorID[MAX_LINE_WIDTH];
	GetClientRankAuthString(Savior, SaviorID, sizeof(SaviorID));

	decl String:VictimName[MAX_LINE_WIDTH];
	GetClientName(Victim, VictimName, sizeof(VictimName));
	decl String:VictimID[MAX_LINE_WIDTH];
	GetClientRankAuthString(Victim, VictimID, sizeof(VictimID));

	new Score = ModifyScoreDifficulty(GetConVarInt(cvar_Revive), 2, 3, TEAM_SURVIVORS);

	decl String:UpdatePoints[32];

	switch (CurrentGamemodeID)
	{
		case GAMEMODE_VERSUS:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_survivors");
		}
		case GAMEMODE_REALISM:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_realism");
		}
		case GAMEMODE_SURVIVAL:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_survival");
		}
		case GAMEMODE_SCAVENGE:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_scavenge_survivors");
		}
		case GAMEMODE_REALISMVERSUS:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_realism_survivors");
		}
		case GAMEMODE_OTHERMUTATIONS:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_mutations");
		}
		default:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points");
		}
	}

	decl String:query[1024];
	Format(query, sizeof(query), "UPDATE %splayers SET %s = %s + %i, award_revive = award_revive + 1 WHERE steamid = '%s'", DbPrefix, UpdatePoints, UpdatePoints, Score, SaviorID);
	SendSQLUpdate(query);

	UpdateMapStat("points", Score);
	AddScore(Savior, Score);

	if (Score > 0)
	{
		if (Mode == 1 || Mode == 2)
			StatsPrintToChat(Savior, "你因拉起 \x05%s\x01 获得 \x04%i \x01分!", VictimName, Score);
		else if (Mode == 3)
			StatsPrintToChatAll("\x05%s \x01因拉起 \x05%s\x01 获得 \x04%i \x01分!", SaviorName, VictimName, Score);
	}
}

/*
L4D1:

56 - Helping Hand
57 - Field Medic
58 - Pharm-Assist
59 - My Bodyguard
60 - Dead Stop
61 - Crownd
62 - Untouchables
63 -
64 - Drag and Drop
65 - Blind Luck
66 - Akimbo Assassin
67 -
68 - Hero Closet
69 - Hunter Punter
70 - Tongue Twister
71 - No Smoking Section
72 -
73 - 101 Cremations
74 - Do Not Disturb
75 - Man Vs Tank
76 - TankBusters
77 - Safety First
78 - No-one Left Behind
79 -
80 -
81 - Unbreakable
82 - Witch Hunter
83 - Red Mist
84 - Pyrotechnician
85 - Zombie Genocidest
86 - Dead Giveaway
87 - Stand Tall
88 -
89 -
90 - Zombicidal Maniac
91 - What are you trying to Prove?
92 -
93 - Nothing Special
94 - Burn the Witch
95 - Towering Inferno
96 - Spinal Tap
97 - Stomach Upset
98 - Brain Salad
99 - Jump Shot
100 - Mercy Killer
101 - Back 2 Help
102 - Toll Collector
103 - Dead Baron
104 - Grim Reaper
105 - Ground Cover
106 - Clean Kill
107 - Big Drag
108 - Chain Smoker
109 - Barf Bagged
110 - Double Jump
111 - All 4 Dead
112 - Dead Wreckening
113 - Lamb 2 Slaughter
114 - Outbreak
*/


/*
L4D2:
0 - End of Campaign (Not 100% Sure)
7 - End of Level (Not 100% Sure)
8 - End of Level (Not 100% Sure)
17 - Kill Tank
22 - Random Director Mob
23 - End of Level (Not 100% Sure)
40 - End of Campaign (Not 100% Sure)
67 - Protect Friendly
68 - Give Pain Pills
69 - Give Adrenaline
70 - Give Heatlh (Heal using Med Pack)
71 - End of Level (Not 100% Sure)
72 - End of Campaign (Not 100% Sure)
75 - Save Friendly from Ledge Grasp
76 - Save Friendly from Special Infected
80 - Hero Closet Rescue Survivor
81 - Kill Tank with no deaths
84 - Team Kill
85 - Incap Friendly
86 - Left Friendly for Dead
87 - Friendly Fire
89 - Incap Friendly
95 - Let infected in safe room
99 - Round Restart (All Dead)
*/

// Miscellaneous events and awards. See specific award for info.

public Action:event_Award_L4D2(Handle:event, const String:name[], bool:dontBroadcast)
{
	if (StatsDisabled())
	{
		return;
	}

	new PlayerID = GetEventInt(event, "userid");

	if (!PlayerID)
	{
		return;
	}

	new User = GetClientOfUserId(PlayerID);

	if (IsClientBot(User))
	{
		return;
	}

	new SubjectID = GetEventInt(event, "subjectentid");
	new Mode = GetConVarInt(cvar_AnnounceMode);
	decl String:UserName[MAX_LINE_WIDTH];
	GetClientName(User, UserName, sizeof(UserName));

	new Recipient;
	decl String:RecipientName[MAX_LINE_WIDTH];

	new Score = 0;
	new String:AwardSQL[128];
	new AwardID = GetEventInt(event, "award");

	//StatsPrintToChat(User, "[TEST] Your actions gave you award (ID = %i)", AwardID);

	if (AwardID == 67) // Protect friendly
	{
		if (!SubjectID)
		{
			return;
		}

		ProtectedFriendlyCounter[User]++;

		if (TimerProtectedFriendly[User] != INVALID_HANDLE)
		{
			CloseHandle(TimerProtectedFriendly[User]);
			TimerProtectedFriendly[User] = INVALID_HANDLE;
		}

		TimerProtectedFriendly[User] = CreateTimer(3.0, timer_ProtectedFriendly, User);

		return;
	}

	if (AwardID == 68) // Pills given
	{
		if (!SubjectID)
		{
			return;
		}

		if (CurrentGamemodeID == GAMEMODE_SURVIVAL && !GetConVarBool(cvar_EnableSvMedicPoints))
		{
			return;
		}

		Recipient = GetClientOfUserId(GetClientUserId(SubjectID));

		GivePills(User, Recipient);

		return;
	}

	if (AwardID == 69) // Adrenaline given
	{
		if (!SubjectID)
		{
			return;
		}

		if (CurrentGamemodeID == GAMEMODE_SURVIVAL && !GetConVarBool(cvar_EnableSvMedicPoints))
		{
			return;
		}

		Recipient = GetClientOfUserId(GetClientUserId(SubjectID));

		GiveAdrenaline(User, Recipient);

		return;
	}

	if (AwardID == 85) // Incap friendly
	{
		if (!SubjectID)
		{
			return;
		}

		Recipient = GetClientOfUserId(GetClientUserId(SubjectID));

		PlayerIncap(User, Recipient);

		return;
	}

	if (AwardID == 80) // Respawn friendly
	{
		if (!SubjectID)
		{
			return;
		}

		Recipient = GetClientOfUserId(GetClientUserId(SubjectID));

		if (IsClientBot(Recipient))
		{
			return;
		}

		Score = ModifyScoreDifficulty(GetConVarInt(cvar_Rescue), 2, 3, TEAM_SURVIVORS);
		GetClientName(Recipient, RecipientName, sizeof(RecipientName));
		Format(AwardSQL, sizeof(AwardSQL), ", award_rescue = award_rescue + 1");
		UpdateMapStat("points", Score);
		AddScore(User, Score);

		if (Score > 0)
		{
			if (Mode == 1 || Mode == 2)
			{
				StatsPrintToChat(User, "你解救  \x05%s\x01获得 \x04%i \x01分!", RecipientName, Score);
			}
			else if (Mode == 3)
			{
				StatsPrintToChatAll("\x05%s 解救  \x05%s\x01获得 \x04%i \x01分!", UserName, RecipientName, Score);
			}
		}
	}
	else if (AwardID == 81) // Kill Tank with no deaths
	{
		Score = ModifyScoreDifficulty(0, 1, 1, TEAM_SURVIVORS);
		Format(AwardSQL, sizeof(AwardSQL), ", award_tankkillnodeaths = award_tankkillnodeaths + 1");
	}
// Moved to event_PlayerDeath
//	else if (AwardID == 84 && !CampaignOver) // Team kill
//	{
//		if (!SubjectID)
//			return;
//
//		Recipient = GetClientOfUserId(GetClientUserId(SubjectID));
//
//		Format(AwardSQL, sizeof(AwardSQL), ", award_teamkill = award_teamkill + 1");
//		Score = ModifyScoreDifficultyNR(GetConVarInt(cvar_FKill), 2, 4, TEAM_SURVIVORS);
//		Score = Score * -1;
//
//		if (Mode == 1 || Mode == 2)
//			StatsPrintToChat(User, "You have \x03LOST \x04%i \x01points for \x03Team Killing!", Score);
//		else if (Mode == 3)
//			StatsPrintToChatAll("\x05%s \x01has \x03LOST \x04%i \x01points for \x03Team Killing!", UserName, Score);
//	}
	else if (AwardID == 86) // Left friendly for dead
	{
		Format(AwardSQL, sizeof(AwardSQL), ", award_left4dead = award_left4dead + 1");
		Score = ModifyScoreDifficulty(0, 1, 1, TEAM_SURVIVORS);
	}
	else if (AwardID == 95) // Let infected in safe room
	{
		Format(AwardSQL, sizeof(AwardSQL), ", award_letinsafehouse = award_letinsafehouse + 1");

		Score = 0;
		if (GetConVarBool(cvar_EnableNegativeScore))
			Score = ModifyScoreDifficultyNR(GetConVarInt(cvar_InSafeRoom), 2, 4, TEAM_SURVIVORS);
		else
			Mode = 0;

		if (Mode == 1 || Mode == 2)
			StatsPrintToChat(User, "你 \x03失去了 \x04%i \x01分 by 让\x03感染者进入安全门!", Score);
		else if (Mode == 3)
			StatsPrintToChatAll("\x05%s \x01has \x03失去了 \x04%i \x01分 by 让\x03感染者进入安全门!", UserName, Score);

		Score = Score * -1;
	}
	else if (AwardID == 99) // Round restart
	{
		UpdateMapStat("restarts", 1);
		if(!Isstart)
			return;
		Score=200;
		if (!GetConVarBool(cvar_EnableNegativeScore))
			return;
		if (AnneMultiPlayerMode() || (FindConVar("survivor_limit").IntValue > 2)){
			Score = 200;
		}
		else {
			Score= 0;
		}
		if (Mode && Score > 0)
			StatsPrintToChat(User, "\x03所有幸存者 \x01都 \x03掉了 \x04%i \x01分 by \x03大家又坐牢了!", Score);
		Mode=0;
		Score = Score * -1;
		Isstart=false;
	}
	else
	{
//StatsPrintToChat(User, "[DEBUG] event_Award => %i", AwardID);
		return;
	}

	decl String:UpdatePoints[32];
	decl String:UserID[MAX_LINE_WIDTH];
	GetClientRankAuthString(User, UserID, sizeof(UserID));

	switch (CurrentGamemodeID)
	{
		case GAMEMODE_VERSUS:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_survivors");
		}
		case GAMEMODE_REALISM:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_realism");
		}
		case GAMEMODE_SURVIVAL:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_survival");
		}
		case GAMEMODE_SCAVENGE:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_scavenge_survivors");
		}
		case GAMEMODE_REALISMVERSUS:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_realism_survivors");
		}
		case GAMEMODE_OTHERMUTATIONS:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_mutations");
		}
		default:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points");
		}
	}

	decl String:query[1024];
	Format(query, sizeof(query), "UPDATE %splayers SET %s = %s + %i%s WHERE steamid = '%s'", DbPrefix, UpdatePoints, UpdatePoints, Score, AwardSQL, UserID);
	SendSQLUpdate(query);
}

// Scavenge halftime code.

public Action:event_ScavengeHalftime(Handle:event, const String:name[], bool:dontBroadcast)
{
	if (StatsDisabled() || CampaignOver)
		return;

	CampaignOver = true;

	new maxplayers = MaxClients;

	for (new i = 1; i <= maxplayers; i++)
	{
		if (IsClientConnected(i) && IsClientInGame(i) && !IsClientBot(i))
		{
			switch (GetClientTeam(i))
			{
				case TEAM_SURVIVORS:
					InterstitialPlayerUpdate(i);
				case TEAM_INFECTED:
					DoInfectedFinalChecks(i);
			}
		}
	}
}

// Survival started code.

public Action:event_SurvivalStart(Handle:event, const String:name[], bool:dontBroadcast)
{
	if (StatsDisabled())
		return;

	SurvivalStart();
}

public SurvivalStart()
{
	UpdateMapStat("restarts", 1);
	SurvivalStarted = true;
	MapTimingStartTime = 0.0;
	MapTimingBlocked = false;
	StartMapTiming();
}

// Car alarm triggered code.
// ====================================================================================================
// Hook Events (L4D2)
// ====================================================================================================

public Action:event_CarAlarm(Handle:event, const String:name[], bool:dontBroadcast)
{
	if (StatsDisabled() || CurrentGamemodeID == GAMEMODE_SURVIVAL || !GetConVarBool(cvar_EnableNegativeScore))
		return;

	new Score = ModifyScoreDifficultyNR(GetConVarInt(cvar_CarAlarm), 2, 3, TEAM_SURVIVORS);
	UpdateMapStat("caralarm", 1);

	if (Score <= 0)
		return;

	decl String:UpdatePoints[32];
	decl String:query[1024];

	switch (CurrentGamemodeID)
	{
		case GAMEMODE_VERSUS:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_survivors");
		}
		case GAMEMODE_REALISM:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_realism");
		}
		case GAMEMODE_SURVIVAL:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_survival");
		}
		case GAMEMODE_SCAVENGE:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_scavenge_survivors");
		}
		case GAMEMODE_REALISMVERSUS:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_realism_survivors");
		}
		case GAMEMODE_OTHERMUTATIONS:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_mutations");
		}
		default:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points");
		}
	}
	int attacker = GetClientOfUserId(GetEventInt(event, "userid"));
	new Mode = GetConVarInt(cvar_AnnounceMode);
	Score*=2;
	decl String:iID[MAX_LINE_WIDTH];

	if (IsClientConnected(attacker) && IsClientInGame(attacker) && !IsClientBot(attacker) && GetClientTeam(attacker) == TEAM_SURVIVORS)
	{
		GetClientRankAuthString(attacker, iID, sizeof(iID));
		Format(query, sizeof(query), "UPDATE %splayers SET %s = %s - %i WHERE steamid = '%s'", DbPrefix, UpdatePoints, UpdatePoints, Score, iID);
		SendSQLUpdate(query);

		if (Mode)
			StatsPrintToChatAll("\x04%N \x03失去了 \x04%i \x01分 by \x03又特么打警报车是吧.jpg\x01!", attacker, Score);
	}
}

// Reset Witch existence in the world when a new one is created.

public Action:event_WitchSpawn(Handle:event, const String:name[], bool:dontBroadcast)
{
	if (StatsDisabled())
		return;

	WitchExists = true;
}

// Witch was crowned!

public Action:event_WitchCrowned(Handle:event, const String:name[], bool:dontBroadcast)
{
	if (StatsDisabled() || CurrentGamemodeID == GAMEMODE_SURVIVAL)
		return;

	new Killer = GetClientOfUserId(GetEventInt(event, "userid"));
	new bool:Crowned = GetEventBool(event, "oneshot");

	if (Crowned && Killer > 0 && !IsClientBot(Killer) && IsClientConnected(Killer) && IsClientInGame(Killer))
	{
		decl String:SteamID[MAX_LINE_WIDTH];
		GetClientRankAuthString(Killer, SteamID, sizeof(SteamID));

		new Score = ModifyScoreDifficulty(GetConVarInt(cvar_WitchCrowned), 2, 3, TEAM_SURVIVORS);
		decl String:UpdatePoints[32];

		switch (CurrentGamemodeID)
		{
			case GAMEMODE_VERSUS:
			{
				Format(UpdatePoints, sizeof(UpdatePoints), "points_survivors");
			}
			case GAMEMODE_REALISM:
			{
				Format(UpdatePoints, sizeof(UpdatePoints), "points_realism");
			}
			case GAMEMODE_SURVIVAL:
			{
				Format(UpdatePoints, sizeof(UpdatePoints), "points_survival");
			}
			case GAMEMODE_SCAVENGE:
			{
				Format(UpdatePoints, sizeof(UpdatePoints), "points_scavenge_survivors");
			}
			case GAMEMODE_REALISMVERSUS:
			{
				Format(UpdatePoints, sizeof(UpdatePoints), "points_realism_survivors");
			}
			case GAMEMODE_OTHERMUTATIONS:
			{
				Format(UpdatePoints, sizeof(UpdatePoints), "points_mutations");
			}
			default:
			{
				Format(UpdatePoints, sizeof(UpdatePoints), "points");
			}
		}
		if(IsWitchParty())
		{
			Score = RoundToCeil(Score / 2.0);
		}

		decl String:query[1024];
		Format(query, sizeof(query), "UPDATE %splayers SET %s = %s + %i, award_witchcrowned = award_witchcrowned + 1 WHERE steamid = '%s'", DbPrefix, UpdatePoints, UpdatePoints, Score, SteamID);
		SendSQLUpdate(query);

		if (Score > 0 && GetConVarInt(cvar_AnnounceMode))
		{
			decl String:Name[MAX_LINE_WIDTH];
			GetClientName(Killer, Name, sizeof(Name));

			StatsPrintToChatTeam(TEAM_SURVIVORS, "\x05%s \x04对Witch洒洒水 \x01获得\x04%i \x01分!", Name, Score);
		}
	}
}

// Witch was disturbed!

public Action:event_WitchDisturb(Handle:event, const String:name[], bool:dontBroadcast)
{
	if (StatsDisabled())
		return;

	if (WitchExists)
	{
		WitchDisturb = true;

		if (!GetEventInt(event, "userid"))
			return;

		new User = GetClientOfUserId(GetEventInt(event, "userid"));

		if (IsClientBot(User))
			return;

		decl String:UserID[MAX_LINE_WIDTH];
		GetClientRankAuthString(User, UserID, sizeof(UserID));

		decl String:query[1024];
		Format(query, sizeof(query), "UPDATE %splayers SET award_witchdisturb = award_witchdisturb + 1 WHERE steamid = '%s'", DbPrefix, UserID);
		SendSQLUpdate(query);
	}
}

// DEBUG
//public Action:cmd_StatsTest(client, args)
//{
//	new String:CurrentMode[16];
//	GetConVarString(cvar_Gamemode, CurrentMode, sizeof(CurrentMode));
//	PrintToConsole(0, "Gamemode: %s", CurrentMode);
//	UpdateMapStat("playtime", 10);
//	PrintToConsole(0, "Added 10 seconds to maps table current map.");
//	new Float:ReductionFactor = GetMedkitPointReductionFactor();
//
//	StatsPrintToChat(client, "\x03ALL SURVIVORS \x01now earns only \x04%i percent \x01of their normal points after using their \x05%i%s Medkit\x01!", RoundToNearest(ReductionFactor * 100), MedkitsUsedCounter, (MedkitsUsedCounter == 1 ? "st" : (MedkitsUsedCounter == 2 ? "nd" : (MedkitsUsedCounter == 3 ? "rd" : "th"))), GetClientTeam(client));
//}

/*
-----------------------------------------------------------------------------
Chat/command handling and panels for Rank and Top10
-----------------------------------------------------------------------------
*/

public Action:HandleCommands(client, const String:Text[])
{
	if (strcmp(Text, "rankmenu", false) == 0)
	{
		cmd_ShowRankMenu(client, 0);
		if (GetConVarBool(cvar_SilenceChat))
			return Plugin_Handled;
	}

	else if (strcmp(Text, "rank", false) == 0)
	{
		cmd_ShowRank(client, 0);
		if (GetConVarBool(cvar_SilenceChat))
			return Plugin_Handled;
	}

	else if (strcmp(Text, "showrank", false) == 0)
	{
		cmd_ShowRanks(client, 0);
		if (GetConVarBool(cvar_SilenceChat))
			return Plugin_Handled;
	}

	else if (strcmp(Text, "showppm", false) == 0)
	{
		cmd_ShowPPMs(client, 0);
		if (GetConVarBool(cvar_SilenceChat))
			return Plugin_Handled;
	}

	else if (strcmp(Text, "top10", false) == 0)
	{
		cmd_ShowTop10(client, 0);
		if (GetConVarBool(cvar_SilenceChat))
			return Plugin_Handled;
	}

	else if (strcmp(Text, "top10ppm", false) == 0)
	{
		cmd_ShowTop10PPM(client, 0);
		if (GetConVarBool(cvar_SilenceChat))
			return Plugin_Handled;
	}

	else if (strcmp(Text, "nextrank", false) == 0)
	{
		cmd_ShowNextRank(client, 0);
		if (GetConVarBool(cvar_SilenceChat))
			return Plugin_Handled;
	}

	else if (strcmp(Text, "showtimer", false) == 0)
	{
		cmd_ShowTimedMapsTimer(client, 0);
		if (GetConVarBool(cvar_SilenceChat))
			return Plugin_Handled;
	}

	else if (strcmp(Text, "timedmaps", false) == 0)
	{
		cmd_TimedMaps(client, 0);
		if (GetConVarBool(cvar_SilenceChat))
			return Plugin_Handled;
	}

	else if (strcmp(Text, "showmaptime", false) == 0)
	{
		cmd_ShowMapTimes(client, 0);
		if (GetConVarBool(cvar_SilenceChat))
			return Plugin_Handled;
	}

	else if (strcmp(Text, "maptimes", false) == 0)
	{
		cmd_MapTimes(client, 0);
		if (GetConVarBool(cvar_SilenceChat))
			return Plugin_Handled;
	}

	else if (strcmp(Text, "rankvote", false) == 0)
	{
		cmd_RankVote(client, 0);
		if (GetConVarBool(cvar_SilenceChat))
			return Plugin_Handled;
	}

	else if (strcmp(Text, "rankmutetoggle", false) == 0)
	{
		cmd_ToggleClientRankMute(client, 0);
		if (GetConVarBool(cvar_SilenceChat))
			return Plugin_Handled;
	}

	else if (strcmp(Text, "showmotd", false) == 0)
	{
		cmd_ShowMotd(client, 0);
		if (GetConVarBool(cvar_SilenceChat))
			return Plugin_Handled;
	}

	return Plugin_Continue;
}

// Parse chat for RANK and TOP10 triggers.
public Action:cmd_Say(client, args)
{
	decl String:Text[192];
	//new String:Command[64];
	new Start = 0;

	GetCmdArgString(Text, sizeof(Text));

	new TextLen = strlen(Text);

	// This apparently happens sometimes?
	if (TextLen <= 0)
	{
		return Plugin_Continue;
	}

	if (Text[TextLen-1] == '"')
	{
		Text[TextLen-1] = '\0';
		Start = 1;
	}

	// Command is never set? This will always result to false.
	//if (strcmp(Command, "say2", false) == 0)
	//	Start += 4;

	return HandleCommands(client, Text[Start]);
}

// Show current Timed Maps timer.
public Action:cmd_ShowTimedMapsTimer(client, args)
{
	if (client != 0 && !IsClientConnected(client) && !IsClientInGame(client))
		return Plugin_Handled;

	if (client != 0 && IsClientBot(client))
		return Plugin_Handled;

	if (MapTimingStartTime <= 0.0)
	{
		if (client == 0)
		{
			PrintToConsole(0, "[RANK] Map timer has not started");
		}
		else
		{
			StatsPrintToChatPreFormatted(client, "地图计时器还没开始计时");
		}

		return Plugin_Handled;
	}

	new Float:CurrentMapTimer = GetEngineTime() - MapTimingStartTime;
	decl String:TimeLabel[32];

	SetTimeLabel(CurrentMapTimer, TimeLabel, sizeof(TimeLabel));

	if (client == 0)
		PrintToConsole(0, "[RANK] 当前地图时间: %s", TimeLabel);
	else
		StatsPrintToChat(client, "当前地图时间: \x04%s", TimeLabel);

	return Plugin_Handled;
}

// Begin generating the NEXTRANK display panel.
public Action:cmd_ShowNextRank(client, args)
{
	if (!IsClientConnected(client) && !IsClientInGame(client))
		return Plugin_Handled;

	if (IsClientBot(client))
		return Plugin_Handled;

	decl String:SteamID[MAX_LINE_WIDTH];
	GetClientRankAuthString(client, SteamID, sizeof(SteamID));

	QueryClientStatsSteamID(client, SteamID, CM_NEXTRANK);

	return Plugin_Handled;
}

// Clear database.
//public Action:cmd_RankAdmin(client, args)
//{
//	if (!client)
//		return Plugin_Handled;
//
//	new Handle:RankAdminPanel = CreatePanel();
//
//	SetPanelTitle(RankAdminPanel, "Rank Admin:");
//
//	DrawPanelItem(RankAdminPanel, "Clear...");
//	DrawPanelItem(RankAdminPanel, "Clear Players");
//	DrawPanelItem(RankAdminPanel, "Clear Maps");
//	DrawPanelItem(RankAdminPanel, "Clear All");
//
//	SendPanelToClient(RankAdminPanel, client, RankAdminPanelHandler, 30);
//	CloseHandle(RankAdminPanel);
//
//	return Plugin_Handled;
//}

DisplayYesNoPanel(client, const String:title[], MenuHandler:handler, delay=30)
{
	if (!client)
		return;

	new Handle:panel = CreatePanel();

	SetPanelTitle(panel, title);

	DrawPanelItem(panel, "是");
	DrawPanelItem(panel, "否");

	SendPanelToClient(panel, client, handler, delay);
	CloseHandle(panel);
}

public bool:IsTeamGamemode()
{
	return IsGamemode("versus") ||
				 IsGamemode("realismversus") ||
				 IsGamemode("scavenge") ||
				 IsGamemode("mutation11") ||	// Healthpackalypse!
				 IsGamemode("mutation12") ||	// Realism Versus
				 IsGamemode("mutation13") ||	// Follow the Liter
				 IsGamemode("mutation15") ||	// Versus Survival
				 IsGamemode("mutation18") ||	// Bleed Out Versus
				 IsGamemode("mutation19") ||	// Taaannnkk!
				 IsGamemode("community3") ||	// Riding My Survivor
				 IsGamemode("community6");		// Confogl
}

// Run Team Shuffle.
public Action:cmd_ShuffleTeams(client, args)
{
	if (!IsTeamGamemode())
	{
		PrintToConsole(client, "[RANK] Team shuffle 在这个模式不启用!");
		return Plugin_Handled;
	}

	if (RankVoteTimer != INVALID_HANDLE)
	{
		CloseHandle(RankVoteTimer);
		RankVoteTimer = INVALID_HANDLE;

		StatsPrintToChatAllPreFormatted("Team shuffle 被管理员执行.");
	}

	PrintToConsole(client, "[RANK] Executing team shuffle...");
	CreateTimer(1.0, timer_ShuffleTeams);

	return Plugin_Handled;
}

// Set Message Of The Day.
public Action:cmd_SetMotd(client, args)
{
	decl String:arg[1024];

	GetCmdArgString(arg, sizeof(arg));

	UpdateServerSettings(client, "motdmessage", arg, MOTD_TITLE);

	return Plugin_Handled;
}

// Clear database.
public Action:cmd_ClearRank(client, args)
{
	if (client == 0)
	{
		PrintToConsole(client, "[RANK] Clear Stats: Database clearing from server console currently disabled because of a bug in it! Run the command from in-game console or from Admin Panel.");
		
		return Plugin_Handled;
	}

	if (ClearDatabaseTimer != INVALID_HANDLE)
	{
		CloseHandle(ClearDatabaseTimer);
	}

	ClearDatabaseTimer = INVALID_HANDLE;

	if (ClearDatabaseCaller == client)
	{
		PrintToConsole(client, "[RANK] Clear Stats: Started clearing the database!");
		ClearDatabaseCaller = -1;

		ClearStatsAll(client);

		return Plugin_Handled;
	}

	PrintToConsole(client, "[RANK] Clear Stats: To clear the database, execute this command again in %.2f seconds!", CLEAR_DATABASE_CONFIRMTIME);
	ClearDatabaseCaller = client;

	ClearDatabaseTimer = CreateTimer(CLEAR_DATABASE_CONFIRMTIME, timer_ClearDatabase);

	return Plugin_Handled;
}

public ClearStatsMaps(client)
{
	if (!DoFastQuery(client, "START TRANSACTION"))
	{
		return;
	}

	decl String:query[256];
	Format(query, sizeof(query), "SELECT * FROM %smaps WHERE 1 = 2", DbPrefix);

	SQL_TQuery(db, ClearStatsMapsHandler, query, client);
}

public ClearStatsAll(client)
{
	if (!DoFastQuery(client, "START TRANSACTION"))
	{
		return;
	}

	if (!DoFastQuery(client, "DELETE FROM %stimedmaps", DbPrefix))
	{
		PrintToConsole(client, "[RANK] Clear Stats: Clearing timedmaps table failed. Executing rollback...");
		DoFastQuery(client, "ROLLBACK");
		PrintToConsole(client, "[RANK] Clear Stats: Failure!");

		return;
	}

	if (!DoFastQuery(client, "DELETE FROM %splayers", DbPrefix))
	{
		PrintToConsole(client, "[RANK] Clear Stats: Clearing players table failed. Executing rollback...");
		DoFastQuery(client, "ROLLBACK");
		PrintToConsole(client, "[RANK] Clear Stats: Failure!");

		return;
	}

	decl String:query[256];
	Format(query, sizeof(query), "SELECT * FROM %smaps WHERE 1 = 2", DbPrefix);

	SQL_TQuery(db, ClearStatsMapsHandler, query, client);
}

public ClearStatsPlayers(client)
{
	if (!DoFastQuery(client, "START TRANSACTION"))
	{
		return;
	}

	if (!DoFastQuery(client, "DELETE FROM %splayers", DbPrefix))
	{
		PrintToConsole(client, "[RANK] Clear Stats: Clearing players table failed. Executing rollback...");
		DoFastQuery(client, "ROLLBACK");
		PrintToConsole(client, "[RANK] Clear Stats: Failure!");
	}
	else
	{
		DoFastQuery(client, "COMMIT");
		PrintToConsole(client, "[RANK] Clear Stats: Ranks succesfully cleared!");
	}
}

public ClearStatsMapsHandler(Handle:owner, Handle:hndl, const String:error[], any:client)
{
	if (hndl == INVALID_HANDLE)
	{
		PrintToConsole(client, "[RANK] Clear Stats: Query failed! (%s)", error);
		DoFastQuery(client, "ROLLBACK");
		PrintToConsole(client, "[RANK] Clear Stats: Failure!");
		return;
	}

	new FieldCount = SQL_GetFieldCount(hndl);
	decl String:FieldName[MAX_LINE_WIDTH];
	decl String:FieldSet[MAX_LINE_WIDTH];

	new Counter = 0;
	decl String:query[4096];
	Format(query, sizeof(query), "UPDATE %smaps SET", DbPrefix);

	for (new i = 0; i < FieldCount; i++)
	{
		SQL_FieldNumToName(hndl, i, FieldName, sizeof(FieldName));

		if (StrEqual(FieldName, "name", false) ||
				StrEqual(FieldName, "gamemode", false) ||
				StrEqual(FieldName, "custom", false))
		{
			continue;
		}

		if (Counter++ > 0)
		{
			StrCat(query, sizeof(query), ",");
		}

		Format(FieldSet, sizeof(FieldSet), " %s = 0", FieldName);
		StrCat(query, sizeof(query), FieldSet);
	}

	if (!DoFastQuery(client, query))
	{
		PrintToConsole(client, "[RANK] Clear Stats: Clearing maps table failed. Executing rollback...");
		DoFastQuery(client, "ROLLBACK");
		PrintToConsole(client, "[RANK] Clear Stats: Failure!");
	}
	else
	{
		DoFastQuery(client, "COMMIT");
		PrintToConsole(client, "[RANK] Clear Stats: Stats succesfully cleared!", query);
	}
}

bool:DoFastQuery(Client, const String:Query[], any:...)
{
	new String:FormattedQuery[4096];
	VFormat(FormattedQuery, sizeof(FormattedQuery), Query, 3);

	new String:Error[1024];

	if (!SQL_FastQuery(db, FormattedQuery))
	{
		if (SQL_GetError(db, Error, sizeof(Error)))
		{
			PrintToConsole(Client, "[RANK] Fast query failed! (Error = \"%s\") Query = \"%s\"", Error, FormattedQuery);
			LogError("Fast query failed! (Error = \"%s\") Query = \"%s\"", Error, FormattedQuery);
		}
		else
		{
			PrintToConsole(Client, "[RANK] Fast query failed! Query = \"%s\"", FormattedQuery);
			LogError("Fast query failed! Query = \"%s\"", FormattedQuery);
		}

		return false;
	}

	return true;
}

public Action:timer_ClearDatabase(Handle:timer, any:data)
{
	ClearDatabaseTimer = INVALID_HANDLE;
	ClearDatabaseCaller = -1;
}

// Begin generating the RANKMENU display panel.
public Action:cmd_ShowRankMenu(client, args)
{
	if (client <= 0)
	{
		if (client == 0)
			PrintToConsole(0, "[RANK] 你必须在游戏中才能操作排名榜单");

		return Plugin_Handled;
	}

	if (!IsClientConnected(client) && !IsClientInGame(client))
		return Plugin_Handled;

	if (IsClientBot(client))
		return Plugin_Handled;

	DisplayRankMenu(client);

	return Plugin_Handled;
}

public DisplayRankMenu(client)
{
	decl String:Title[MAX_LINE_WIDTH];

	Format(Title, sizeof(Title), "%s:", PLUGIN_NAME);

	new Handle:menu = CreateMenu(Menu_CreateRankMenuHandler);

	SetMenuTitle(menu, Title);
	SetMenuExitBackButton(menu, false);
	SetMenuExitButton(menu, true);


	AddMenuItem(menu, "rank", "显示当前排名");
	AddMenuItem(menu, "top10", "显示TOP10玩家");
	AddMenuItem(menu, "top10ppm", "显示TOP10 PPM玩家");
	AddMenuItem(menu, "nextrank", "下一名达标要求");
	AddMenuItem(menu, "showtimer", "显示当前地图游玩时间");
	AddMenuItem(menu, "showrank", "展示他人排名");
	AddMenuItem(menu, "showppm", "展示他人PPM排名");
	if (GetConVarBool(cvar_EnableRankVote) && IsTeamGamemode())
	{
		AddMenuItem(menu, "rankvote", "Vote for team shuffle by PPM");
	}
	AddMenuItem(menu, "timedmaps", "显示所有地图游玩时间记录");
	if (IsSingleTeamGamemode())
	{
		AddMenuItem(menu, "maptimes", "显示当前地图游玩时间记录");
	}
	if (GetConVarInt(cvar_AnnounceMode))
	{
		AddMenuItem(menu, "showsettings", "修改Rank插件提醒设置");
	}
	//AddMenuItem(menu, "showmaptimes", "显示他人地图的游玩时间记录");

	Format(Title, sizeof(Title), "关于 %s，它由Mikko Andersson编写，由东汉化并对数值进行调整", PLUGIN_NAME);
	AddMenuItem(menu, "Rank插件说明", Title);

	DisplayMenu(menu, client, 30);

	if (EnableSounds_Rankmenu_Show && GetConVarBool(cvar_SoundsEnabled))
		EmitSoundToClient(client, StatsSound_Rankmenu_Show);
}

NotServerConsoleCommand()
{
	PrintToConsole(0, "[RANK] Error: Most of the rank commands including this one are not available from server console.");
}

// Begin generating the RANK display panel.
public Action:cmd_ShowRank(client, args)
{
	if (client == 0)
	{
		NotServerConsoleCommand();
		return Plugin_Handled;
	}

	if (!IsClientConnected(client) && !IsClientInGame(client))
		return Plugin_Handled;

	if (IsClientBot(client))
		return Plugin_Handled;

	decl String:SteamID[MAX_LINE_WIDTH];
	GetClientRankAuthString(client, SteamID, sizeof(SteamID));

	QueryClientStatsSteamID(client, SteamID, CM_RANK);

	return Plugin_Handled;
}

// Generate client's point total.
public GetClientPointsPlayerJoined(Handle:owner, Handle:hndl, const String:error[], any:client)
{
	GetClientPointsWorker(owner, hndl, error, client, GetClientRankPlayerJoined);
}

// Generate client's point total.
public GetClientPointsRankChange(Handle:owner, Handle:hndl, const String:error[], any:client)
{
	GetClientPointsWorker(owner, hndl, error, client, GetClientRankRankChange);
}

// Generate client's point total.
GetClientPointsWorker(Handle:owner, Handle:hndl, const String:error[], any:client, SQLTCallback:callback=INVALID_FUNCTION)
{
	if (!client)
	{
		return;
	}
	
	if (callback == INVALID_FUNCTION)
	{
		LogError("GetClientPointsWorker method invoke failed: SQLTCallback:callback=INVALID_FUNCTION");
		return;
	}

	if (hndl == INVALID_HANDLE)
	{
		LogError("GetClientPointsWorker Query failed: %s", error);
		return;
	}

	GetClientPoints(owner, hndl, error, client);
	QueryClientRank(client, callback);
}

// Generate client's point total.
public GetClientPoints(Handle:owner, Handle:hndl, const String:error[], any:client)
{
	if (!client)
		return;

	if (hndl == INVALID_HANDLE)
	{
		LogError("GetClientPoints Query failed: %s", error);
		return;
	}

	if (SQL_FetchRow(hndl))
	{
		ClientPoints[client] = SQL_FetchInt(hndl, 0);
	}
}

// Generate client's gamemode point total.
public GetClientGameModePoints(Handle:owner, Handle:hndl, const String:error[], any:client)
{
	if (!client)
		return;

	if (hndl == INVALID_HANDLE)
	{
		LogError("GetClientGameModePoints Query failed: %s", error);
		return;
	}

	while (SQL_FetchRow(hndl))
	{
		ClientGameModePoints[client][GAMEMODE_COOP] = SQL_FetchInt(hndl, GAMEMODE_COOP);
		ClientGameModePoints[client][GAMEMODE_VERSUS] = SQL_FetchInt(hndl, GAMEMODE_VERSUS);
		ClientGameModePoints[client][GAMEMODE_REALISM] = SQL_FetchInt(hndl, GAMEMODE_REALISM);
		ClientGameModePoints[client][GAMEMODE_SURVIVAL] = SQL_FetchInt(hndl, GAMEMODE_SURVIVAL);
		ClientGameModePoints[client][GAMEMODE_SCAVENGE] = SQL_FetchInt(hndl, GAMEMODE_SCAVENGE);
		ClientGameModePoints[client][GAMEMODE_REALISMVERSUS] = SQL_FetchInt(hndl, GAMEMODE_REALISMVERSUS);
		ClientGameModePoints[client][GAMEMODE_OTHERMUTATIONS] = SQL_FetchInt(hndl, GAMEMODE_OTHERMUTATIONS);
	}
}

// Generate client's next rank.
public DisplayClientNextRank(Handle:owner, Handle:hndl, const String:error[], any:client)
{
	if (!client)
		return;

	if (hndl == INVALID_HANDLE)
	{
		LogError("GetClientRankRankChange Query failed: %s", error);
		return;
	}

	GetClientNextRank(owner, hndl, error, client);

	DisplayNextRank(client);
}

// Generate client's next rank.
public GetClientNextRank(Handle:owner, Handle:hndl, const String:error[], any:client)
{
	if (!client)
		return;

	if (hndl == INVALID_HANDLE)
	{
		LogError("GetClientRankRankChange Query failed: %s", error);
		return;
	}

	if (SQL_FetchRow(hndl))
		ClientNextRank[client] = SQL_FetchInt(hndl, 0);
	else
		ClientNextRank[client] = 0;
}

// Generate client's rank.
public GetClientRankRankChange(Handle:owner, Handle:hndl, const String:error[], any:client)
{
	if (!client)
		return;

	if (hndl == INVALID_HANDLE)
	{
		LogError("GetClientRankRankChange Query failed: %s", error);
		return;
	}

	GetClientRank(owner, hndl, error, client);

	if (RankChangeLastRank[client] != ClientRank[client])
	{
		new RankChange = RankChangeLastRank[client] - ClientRank[client];

		if (!RankChangeFirstCheck[client] && RankChange == 0)
			return;

		RankChangeLastRank[client] = ClientRank[client];

		if (RankChangeFirstCheck[client])
		{
			RankChangeFirstCheck[client] = false;
			return;
		}

		if (!GetConVarInt(cvar_AnnounceMode) || !GetConVarBool(cvar_AnnounceRankChange))
			return;

		decl String:Label[16];
		if (RankChange > 0)
			Format(Label, sizeof(Label), "上升");
		else
		{
			RankChange *= -1;
			Format(Label, sizeof(Label), "下降");
		}

		if (!IsClientBot(client) && IsClientConnected(client) && IsClientInGame(client))
			StatsPrintToChat(client, "你的排名%s了 \x04%i 名\x01! \x05(Rank: %i)", Label, RankChange,  RankChangeLastRank[client]);
	}
}

// Generate client's rank.
public GetClientRankPlayerJoined(Handle:owner, Handle:hndl, const String:error[], any:client)
{
	if (!client)
	{
		return;
	}

	if (hndl == INVALID_HANDLE)
	{
		LogError("GetClientRankPlayerJoined Query failed: %s", error);
		return;
	}

	GetClientRank(owner, hndl, error, client);

	decl String:userName[MAX_LINE_WIDTH];
	GetClientName(client, userName, sizeof(userName));

	if (ClientRank[client] > 0)
	{
		StatsPrintToChatAll("玩家 \x05%s \x01进入游戏! (排名: \x03%i \x01/ 分数: \x03%i\x01)", userName, ClientRank[client], ClientPoints[client]);
	}
	else
	{
		StatsPrintToChatAll("玩家 \x05%s \x01进入游戏! (未进入排行榜)", userName);
	}
}

// Generate client's rank.
public GetClientRank(Handle:owner, Handle:hndl, const String:error[], any:client)
{
	if (!client)
		return;

	if (hndl == INVALID_HANDLE)
	{
		LogError("GetClientRank Query failed: %s", error);
		return;
	}

	if (SQL_FetchRow(hndl))
		ClientRank[client] = SQL_FetchInt(hndl, 0);
}

// Generate client's rank.
public GetClientGameModeRank(Handle:owner, Handle:hndl, const String:error[], any:client)
{
	if (!client)
		return;

	if (hndl == INVALID_HANDLE)
	{
		LogError("GetClientGameModeRank Query failed: %s", error);
		return;
	}

	while (SQL_FetchRow(hndl))
		ClientGameModeRank[client] = SQL_FetchInt(hndl, 0);
}

// Generate total rank amount.
public GetRankTotal(Handle:owner, Handle:hndl, const String:error[], any:data)
{
	if (hndl == INVALID_HANDLE)
	{
		LogError("GetRankTotal Query failed: %s", error);
		return;
	}

	while (SQL_FetchRow(hndl))
		RankTotal = SQL_FetchInt(hndl, 0);
}

// Generate total gamemode rank amount.
public GetGameModeRankTotal(Handle:owner, Handle:hndl, const String:error[], any:data)
{
	if (hndl == INVALID_HANDLE)
	{
		LogError("GetGameModeRankTotal Query failed: %s", error);
		return;
	}

	while (SQL_FetchRow(hndl))
		GameModeRankTotal = SQL_FetchInt(hndl, 0);
}

// Send the NEXTRANK panel to the client's display.
public DisplayNextRank(client)
{
	if (!client)
		return;

	new Handle:NextRankPanel = CreatePanel();
	new String:Value[MAX_LINE_WIDTH];

	SetPanelTitle(NextRankPanel, "下一名达标要求:");

	if (ClientNextRank[client])
	{
		Format(Value, sizeof(Value), "还需要分数: %i", ClientNextRank[client]);
		DrawPanelText(NextRankPanel, Value);

		Format(Value, sizeof(Value), "当前排名: %i", ClientRank[client]);
		DrawPanelText(NextRankPanel, Value);
	}
	else
		DrawPanelText(NextRankPanel, "你目前位于于第一名");

	DrawPanelItem(NextRankPanel, "更多...");
	DrawPanelItem(NextRankPanel, "关闭");
	SendPanelToClient(NextRankPanel, client, NextRankPanelHandler, 30);
	CloseHandle(NextRankPanel);
}

// Send the NEXTRANK panel to the client's display.
public DisplayNextRankFull(Handle:owner, Handle:hndl, const String:error[], any:client)
{
	if (!client)
		return;

	if (hndl == INVALID_HANDLE)
	{
		LogError("DisplayNextRankFull Query failed: %s", error);
		return;
	}

	if(SQL_GetRowCount(hndl) <= 1)
		return;

	new Points;
	decl String:Name[32];

	new Handle:NextRankPanel = CreatePanel();
	new String:Value[MAX_LINE_WIDTH];

	SetPanelTitle(NextRankPanel, "下一名达标要求:");

	if (ClientNextRank[client])
	{
		Format(Value, sizeof(Value), "还需要分数: %i", ClientNextRank[client]);
		DrawPanelText(NextRankPanel, Value);

		Format(Value, sizeof(Value), "当前排名: %i", ClientRank[client]);
		DrawPanelText(NextRankPanel, Value);
	}
	else
		DrawPanelText(NextRankPanel, "你目前位于于第一名");

	while (SQL_FetchRow(hndl))
	{
		SQL_FetchString(hndl, 0, Name, sizeof(Name));
		Points = SQL_FetchInt(hndl, 1);

		Format(Value, sizeof(Value), "%i 分数: %s", Points, Name);
		DrawPanelText(NextRankPanel, Value);
	}

	DrawPanelItem(NextRankPanel, "关闭");
	SendPanelToClient(NextRankPanel, client, NextRankFullPanelHandler, 30);
	CloseHandle(NextRankPanel);
}

// Send the RANK panel to the client's display.
public DisplayRank(Handle:owner, Handle:hndl, const String:error[], any:client)
{
	if (!client)
		return;

	if (hndl == INVALID_HANDLE)
	{
		LogError("DisplayRank Query failed: %s", error);
		return;
	}

	new Float:PPM;
	new Playtime, Points, InfectedKilled, SurvivorsKilled, Headshots;
	new String:Name[32];

	if (SQL_FetchRow(hndl))
	{
		SQL_FetchString(hndl, 0, Name, sizeof(Name));
		Playtime = SQL_FetchInt(hndl, 1);
		ClientPlayTime[client] = Playtime;
		Points = SQL_FetchInt(hndl, 2);
		InfectedKilled = SQL_FetchInt(hndl, 3);
		SurvivorsKilled = SQL_FetchInt(hndl, 4);
		Headshots = SQL_FetchInt(hndl, 5);
		PPM = float(Points) / float(Playtime);
	}
	else
	{
		GetClientName(client, Name, sizeof(Name));
		Playtime = 0;
		Points = 0;
		InfectedKilled = 0;
		SurvivorsKilled = 0;
		Headshots = 0;
		PPM = 0.0;
	}

	new Handle:RankPanel = CreatePanel();
	new String:Value[MAX_LINE_WIDTH];
	new String:URL[MAX_LINE_WIDTH];

	GetConVarString(cvar_SiteURL, URL, sizeof(URL));
	new Float:HeadshotRatio = Headshots == 0 ? 0.00 : float(Headshots)/float(InfectedKilled)*100;

	Format(Value, sizeof(Value), "%s的排名" , Name);
	SetPanelTitle(RankPanel, Value);

	Format(Value, sizeof(Value), "排名: %i  (共%i)" , ClientRank[client], RankTotal);
	DrawPanelText(RankPanel, Value);

	if (!InvalidGameMode())
	{
		Format(Value, sizeof(Value), "%s 排名: %i (共%i)" ,CurrentGamemodeLabel , ClientGameModeRank[client], GameModeRankTotal);
		DrawPanelText(RankPanel, Value);
	}

	if (Playtime > 60)
	{
		Format(Value, sizeof(Value), "游玩时间: %.2f 小时" , float(Playtime)/ 60.0);
		DrawPanelText(RankPanel, Value);
	}
	else
	{
		Format(Value, sizeof(Value), "游玩时间: %i 分钟" , Playtime);
		DrawPanelText(RankPanel, Value);
	}

	Format(Value, sizeof(Value), "目前分数: %i" , Points);
	DrawPanelText(RankPanel, Value);

	Format(Value, sizeof(Value), "每分钟获取分数: %.2f" , PPM);
	DrawPanelText(RankPanel, Value);

	Format(Value, sizeof(Value), "消灭的小僵尸: %i" , InfectedKilled);
	DrawPanelText(RankPanel, Value);

	Format(Value, sizeof(Value), "杀死的生还者: %i" , SurvivorsKilled);
	DrawPanelText(RankPanel, Value);

	Format(Value, sizeof(Value), "爆头数量: %i" , Headshots);
	DrawPanelText(RankPanel, Value);

	Format(Value, sizeof(Value), "爆头比率: %.2f \%" , HeadshotRatio);
	DrawPanelText(RankPanel, Value);

	if (!StrEqual(URL, "", false))
	{
		Format(Value, sizeof(Value), "完整数据可以在 %s 查看", URL);
		DrawPanelText(RankPanel, Value);
	}

	//DrawPanelItem(RankPanel, "Next Rank");
	DrawPanelItem(RankPanel, "关闭");
	SendPanelToClient(RankPanel, client, RankPanelHandler, 30);
	CloseHandle(RankPanel);
}

public StartRankVote(client)
{
	if (L4DStatsConf == INVALID_HANDLE)
	{
		if (client > 0)
		{
			StatsPrintToChatPreFormatted(client, "\x04Rank投票\x01是 \x03关闭的\x01. \x05插件设置失败.");
		}
		else
		{
			PrintToConsole(0, "[RANK] The Rank Vote is DISABLED! Could not load gamedata/l4d_stats.txt.");
		}
	}

	else if (!GetConVarBool(cvar_EnableRankVote))
	{
		if (client > 0)
		{
			StatsPrintToChatPreFormatted(client, "The \x04Rank Vote \x01is \x03DISABLED\x01.");
		}
		else
		{
			PrintToConsole(0, "[RANK] The Rank Vote is DISABLED.");
		}
	}

	else
	{
		InitializeRankVote(client);
	}
}

// Toggle client rank mute.
public Action:cmd_ToggleClientRankMute(client, args)
{
	if (client == 0)
		return Plugin_Handled;

	if (!IsClientConnected(client) && !IsClientInGame(client) && IsClientBot(client))
		return Plugin_Handled;

	new String:SteamID[MAX_LINE_WIDTH];
	GetClientRankAuthString(client, SteamID, sizeof(SteamID));

	ClientRankMute[client] = !ClientRankMute[client];

	decl String:query[256];
	Format(query, sizeof(query), "UPDATE %ssettings SET mute = %i WHERE steamid = '%s'", DbPrefix, (ClientRankMute[client] ? 1 : 0), SteamID);
	SendSQLUpdate(query);

	AnnounceClientRankMute(client);

	return Plugin_Handled;
}

ShowRankMuteUsage(client)
{
	PrintToConsole(client, "[RANK] Command usage: sm_rankmute <0|1>");
}

// Show current message of the day.
public Action:cmd_ShowMotd(client, args)
{
	ShowMOTD(client, true);
}

// Set client rank mute.
public Action:cmd_ClientRankMute(client, args)
{
	if (client == 0)
		return Plugin_Handled;

	if (!IsClientConnected(client) && !IsClientInGame(client) && IsClientBot(client))
		return Plugin_Handled;

	if (args != 1)
	{
		ShowRankMuteUsage(client);
		return Plugin_Handled;
	}

	decl String:arg[MAX_LINE_WIDTH];
	GetCmdArgString(arg, sizeof(arg));

	if (!StrEqual(arg, "0") && !StrEqual(arg, "1"))
	{
		ShowRankMuteUsage(client);
		return Plugin_Handled;
	}
	
	decl String:SteamID[MAX_LINE_WIDTH];
	GetClientRankAuthString(client, SteamID, sizeof(SteamID));

	ClientRankMute[client] = StrEqual(arg, "1");

	decl String:query[256];
	Format(query, sizeof(query), "UPDATE %ssettings SET mute = %s WHERE steamid = '%s'", DbPrefix, arg, SteamID);
	SendSQLUpdate(query);

	AnnounceClientRankMute(client);

	return Plugin_Handled;
}

AnnounceClientRankMute(client)
{
	StatsPrintToChat2(client, true, "你 %s \x01the \x05%s\x01.", (ClientRankMute[client] ? "\x04已经禁用" : "\x03解除禁用"), PLUGIN_NAME);
}

// Start RANKVOTE.
public Action:cmd_RankVote(client, args)
{
	if (client == 0)
	{
		StartRankVote(client);
		return Plugin_Handled;
	}

	if (!IsClientConnected(client) && !IsClientInGame(client) && IsClientBot(client))
	{
		return Plugin_Handled;
	}

	new ClientFlags = GetUserFlagBits(client);
	new bool:IsAdmin = ((ClientFlags & ADMFLAG_GENERIC) == ADMFLAG_GENERIC);

	new ClientTeam = GetClientTeam(client);

	if (!IsAdmin && ClientTeam != TEAM_SURVIVORS && ClientTeam != TEAM_INFECTED)
	{
		StatsPrintToChatPreFormatted2(client, true, "The spectators cannot initiate the \x04Rank Vote\x01.");
		return Plugin_Handled;
	}

	StartRankVote(client);

	return Plugin_Handled;
}

// Generate the TIMEDMAPS display menu.
public Action:cmd_TimedMaps(client, args)
{
	if (client == 0 || !IsClientConnected(client) && !IsClientInGame(client) && IsClientBot(client))
		return Plugin_Handled;

	decl String:query[256];
	Format(query, sizeof(query), "SELECT DISTINCT tm.gamemode, tm.mutation FROM %stimedmaps AS tm INNER JOIN %splayers AS p ON tm.steamid = p.steamid", DbPrefix, DbPrefix);
	SQL_TQuery(db, CreateTimedMapsMenu, query, client);

	return Plugin_Handled;
}

// Generate the MAPTIME display menu.
public Action:cmd_MapTimes(client, args)
{
	if (client == 0 || !IsClientConnected(client) && !IsClientInGame(client) && IsClientBot(client))
		return Plugin_Handled;

	decl String:Info[MAX_LINE_WIDTH], String:CurrentMapName[MAX_LINE_WIDTH];

	GetCurrentMap(CurrentMapName, sizeof(CurrentMapName));
	Format(Info, sizeof(Info), "%i\\%s", CurrentGamemodeID, CurrentMapName);

	DisplayTimedMapsMenu3FromInfo(client, Info);

	return Plugin_Handled;
}

// Generate the SHOWMAPTIME display menu.
public Action:cmd_ShowMapTimes(client, args)
{
	if (client == 0 || !IsClientConnected(client) && !IsClientInGame(client) && IsClientBot(client))
		return Plugin_Handled;

	StatsPrintToChatPreFormatted2(client, true, "\x05NOT IMPLEMENTED YET");

	return Plugin_Handled;
}

// Generate the SHOWPPM display menu.
public Action:cmd_ShowPPMs(client, args)
{
	if (!IsClientConnected(client) && !IsClientInGame(client) && IsClientBot(client))
		return Plugin_Handled;

	decl String:query[1024];
	//Format(query, sizeof(query), "SELECT COUNT(*) FROM %splayers", DbPrefix);
	//SQL_TQuery(db, GetRankTotal, query);

	Format(query, sizeof(query), "SELECT steamid, name, (%s) / (%s) AS ppm FROM %splayers WHERE ", DB_PLAYERS_TOTALPOINTS, DB_PLAYERS_TOTALPLAYTIME, DbPrefix);

	new maxplayers = MaxClients;
	decl String:SteamID[MAX_LINE_WIDTH], String:where[512];
	new counter = 0;

	for (new i = 1; i <= maxplayers; i++)
	{
		if (IsClientBot(i) || !IsClientConnected(i) || !IsClientInGame(i))
			continue;

		if (counter++ > 0)
			StrCat(query, sizeof(query), "OR ");

		GetClientRankAuthString(i, SteamID, sizeof(SteamID));
		Format(where, sizeof(where), "steamid = '%s' ", SteamID);
		StrCat(query, sizeof(query), where);
	}

	if (counter == 0)
		return Plugin_Handled;

	if (counter == 1)
	{
		cmd_ShowRank(client, 0);
		return Plugin_Handled;
	}

	StrCat(query, sizeof(query), "ORDER BY ppm DESC");

	SQL_TQuery(db, CreatePPMMenu, query, client);

	return Plugin_Handled;
}

// Generate the SHOWRANK display menu.
public Action:cmd_ShowRanks(client, args)
{
	if (!IsClientConnected(client) && !IsClientInGame(client) && IsClientBot(client))
		return Plugin_Handled;

	decl String:query[1024];
	//Format(query, sizeof(query), "SELECT COUNT(*) FROM %splayers", DbPrefix);
	//SQL_TQuery(db, GetRankTotal, query);

	Format(query, sizeof(query), "SELECT steamid, name, %s AS totalpoints FROM %splayers WHERE ", DB_PLAYERS_TOTALPOINTS, DbPrefix);

	new maxplayers = MaxClients;
	decl String:SteamID[MAX_LINE_WIDTH], String:where[512];
	new counter = 0;

	for (new i = 1; i <= maxplayers; i++)
	{
		if (IsClientBot(i) || !IsClientConnected(i) || !IsClientInGame(i))
			continue;

		if (counter++ > 0)
			StrCat(query, sizeof(query), "OR ");

		GetClientRankAuthString(i, SteamID, sizeof(SteamID));
		Format(where, sizeof(where), "steamid = '%s' ", SteamID);
		StrCat(query, sizeof(query), where);
	}

	if (counter == 0)
		return Plugin_Handled;

	if (counter == 1)
	{
		cmd_ShowRank(client, 0);
		return Plugin_Handled;
	}

	StrCat(query, sizeof(query), "ORDER BY totalpoints DESC");

	SQL_TQuery(db, CreateRanksMenu, query, client);

	return Plugin_Handled;
}

// Generate the TOPPPM display panel.
public Action:cmd_ShowTop10PPM(client, args)
{
	if (!IsClientConnected(client) && !IsClientInGame(client) && IsClientBot(client))
		return Plugin_Handled;

	decl String:query[1024];
	Format(query, sizeof(query), "SELECT COUNT(*) FROM %splayers", DbPrefix);
	SQL_TQuery(db, GetRankTotal, query);

	Format(query, sizeof(query), "SELECT name, (%s) / (%s) AS ppm FROM %splayers WHERE (%s) >= %i ORDER BY ppm DESC, (%s) DESC LIMIT 10", DB_PLAYERS_TOTALPOINTS, DB_PLAYERS_TOTALPLAYTIME, DbPrefix, DB_PLAYERS_TOTALPLAYTIME, GetConVarInt(cvar_Top10PPMMin), DB_PLAYERS_TOTALPLAYTIME);
	SQL_TQuery(db, DisplayTop10PPM, query, client);

	return Plugin_Handled;
}

// Reget currently score(client)
public Action cmd_ResetScore(client, args)
{
	if (!IsClientConnected(client) && !IsClientInGame(client) && IsClientBot(client))
		return Plugin_Handled;
	QueryClientPoints(client);
	return Plugin_Handled;
}

// Generate the TOP10 display panel.
public Action:cmd_ShowTop10(client, args)
{
	if (!IsClientConnected(client) && !IsClientInGame(client) && IsClientBot(client))
		return Plugin_Handled;

	decl String:query[512];
	Format(query, sizeof(query), "SELECT COUNT(*) FROM %splayers", DbPrefix);
	SQL_TQuery(db, GetRankTotal, query);

	Format(query, sizeof(query), "SELECT name FROM %splayers ORDER BY %s DESC LIMIT 10", DbPrefix, DB_PLAYERS_TOTALPOINTS);
	SQL_TQuery(db, DisplayTop10, query, client);

	return Plugin_Handled;
}

// Find a player from Top 10 ranking.
public GetClientFromTop10(client, rank)
{
	decl String:query[512];
	Format(query, sizeof(query), "SELECT (%s) as totalpoints, steamid FROM %splayers ORDER BY totalpoints DESC LIMIT %i,1", DB_PLAYERS_TOTALPOINTS, DbPrefix, rank);
	SQL_TQuery(db, GetClientTop10, query, client);
}

// Find a player from Top 10 PPM ranking.
public GetClientFromTop10PPM(client, rank)
{
	decl String:query[1024];
	Format(query, sizeof(query), "SELECT (%s) AS totalpoints, steamid, (%s) AS totalplaytime FROM %splayers WHERE (%s) >= %i ORDER BY (totalpoints / totalplaytime) DESC, totalplaytime DESC LIMIT %i,1", DB_PLAYERS_TOTALPOINTS, DB_PLAYERS_TOTALPLAYTIME, DbPrefix, DB_PLAYERS_TOTALPLAYTIME, GetConVarInt(cvar_Top10PPMMin), rank);
	SQL_TQuery(db, GetClientTop10, query, client);
}

// Send the Top 10 player's info to the client.
public GetClientTop10(Handle:owner, Handle:hndl, const String:error[], any:client)
{
	if (!client || hndl == INVALID_HANDLE)
	{
		LogError("GetClientTop10 failed! Reason: %s", error);
		return;
	}

	decl String:SteamID[MAX_LINE_WIDTH];

	while (SQL_FetchRow(hndl))
	{
		SQL_FetchString(hndl, 1, SteamID, sizeof(SteamID));

		QueryClientStatsSteamID(client, SteamID, CM_TOP10);
	}
}

public ExecuteTeamShuffle(Handle:owner, Handle:hndl, const String:error[], any:data)
{
	if (hndl == INVALID_HANDLE)
	{
		LogError("ExecuteTeamShuffle failed! Reason: %s", error);
		return;
	}

	decl String:SteamID[MAX_LINE_WIDTH];
	new i, team, maxplayers = MaxClients, client, topteam;
	new SurvivorsLimit = GetConVarInt(cvar_SurvivorLimit), InfectedLimit = GetConVarInt(cvar_InfectedLimit);
	new Handle:PlayersTrie = CreateTrie();
	new Handle:InfectedArray = CreateArray();
	new Handle:SurvivorArray = CreateArray();

	for (i = 1; i <= maxplayers; i++)
	{
		if (IsClientConnected(i) && IsClientInGame(i) && !IsClientBot(i))
		{
			GetClientRankAuthString(i, SteamID, sizeof(SteamID));

			if (!SetTrieValue(PlayersTrie, SteamID, i, false))
			{
				LogError("ExecuteTeamShuffle failed! Reason: Duplicate SteamID while generating shuffled teams.");
				StatsPrintToChatAllPreFormatted2(true, "Team shuffle failed in an error.");

				SetConVarBool(cvar_EnableRankVote, false);

				ClearTrie(PlayersTrie);
				CloseHandle(PlayersTrie);

				CloseHandle(hndl);

				return;
			}

			switch (GetClientTeam(i))
			{
				case TEAM_SURVIVORS:
					PushArrayCell(SurvivorArray, i);
				case TEAM_INFECTED:
					PushArrayCell(InfectedArray, i);
			}
		}
	}

	new SurvivorCounter = GetArraySize(SurvivorArray);
	new InfectedCounter = GetArraySize(InfectedArray);

	i = 0;
	topteam = 0;

	while (SQL_FetchRow(hndl))
	{
		SQL_FetchString(hndl, 0, SteamID, sizeof(SteamID));

		if (GetTrieValue(PlayersTrie, SteamID, client))
		{
			team = GetClientTeam(client);

			if (i == 0)
			{
				if (team == TEAM_SURVIVORS)
				{
					RemoveFromArray(SurvivorArray, FindValueInArray(SurvivorArray, client));
				}
				else
				{
					RemoveFromArray(InfectedArray, FindValueInArray(InfectedArray, client));
				}

				topteam = team;
				i++;

				continue;
			}

			if (i++ % 2)
			{
				if (topteam == TEAM_SURVIVORS && team == TEAM_INFECTED)
				{
					RemoveFromArray(InfectedArray, FindValueInArray(InfectedArray, client));
				}
				else if (topteam == TEAM_INFECTED && team == TEAM_SURVIVORS)
				{
					RemoveFromArray(SurvivorArray, FindValueInArray(SurvivorArray, client));
				}
			}
			else
			{
				if (topteam == TEAM_SURVIVORS && team == TEAM_SURVIVORS)
				{
					RemoveFromArray(SurvivorArray, FindValueInArray(SurvivorArray, client));
				}
				else if (topteam == TEAM_INFECTED && team == TEAM_INFECTED)
				{
					RemoveFromArray(InfectedArray, FindValueInArray(InfectedArray, client));
				}
			}
		}
	}

	if (GetArraySize(SurvivorArray) > 0 || GetArraySize(InfectedArray) > 0)
	{
		new NewSurvivorCounter = SurvivorCounter - GetArraySize(SurvivorArray) + GetArraySize(InfectedArray);
		new NewInfectedCounter = InfectedCounter - GetArraySize(InfectedArray) + GetArraySize(SurvivorArray);

		if (NewSurvivorCounter > SurvivorsLimit || NewInfectedCounter > InfectedLimit)
		{
			LogError("ExecuteTeamShuffle failed! Reason: Team size limits block Rank Vote functionality. (Survivors Limit = %i [%i] / Infected Limit = %i [%i])", SurvivorsLimit, NewSurvivorCounter, InfectedLimit, NewInfectedCounter);
			StatsPrintToChatAllPreFormatted2(true, "Team shuffle failed in an error.");

			SetConVarBool(cvar_EnableRankVote, false);
		}
		else
		{
			CampaignOver = true;

			decl String:Name[32];

			// Change Survivors team to Spectators (TEMPORARILY)
			for (i = 0; i < GetArraySize(SurvivorArray); i++)
			{
				ChangeRankPlayerTeam(GetArrayCell(SurvivorArray, i), TEAM_SPECTATORS);
			}

			// Change Infected team to Survivors
			for (i = 0; i < GetArraySize(InfectedArray); i++)
			{
				client = GetArrayCell(InfectedArray, i);
				GetClientName(client, Name, sizeof(Name));

				ChangeRankPlayerTeam(client, TEAM_SURVIVORS);

				StatsPrintToChatAll2(true, "\x05%s \x01加入到了 \x03Survivors\x01阵营!", Name);
			}

			// Change Spectators (TEMPORARILY) team to Infected
			for (i = 0; i < GetArraySize(SurvivorArray); i++)
			{
				client = GetArrayCell(SurvivorArray, i);
				GetClientName(client, Name, sizeof(Name));

				ChangeRankPlayerTeam(client, TEAM_INFECTED);

				StatsPrintToChatAll2(true, "\x05%s \x01加入到了 \x03Infected\x01阵营!", Name);
			}

			StatsPrintToChatAllPreFormatted2(true, "Team shuffle by player PPM \x03DONE\x01.");

			if (EnableSounds_Rankvote && GetConVarBool(cvar_SoundsEnabled))
				EmitSoundToAll(SOUND_RANKVOTE);
		}
	}
	else
	{
		StatsPrintToChatAllPreFormatted2(true, "Teams are already even by player PPM.");
	}

	ClearArray(SurvivorArray);
	ClearArray(InfectedArray);
	ClearTrie(PlayersTrie);

	CloseHandle(SurvivorArray);
	CloseHandle(InfectedArray);
	CloseHandle(PlayersTrie);

	CloseHandle(hndl);
}

public CreateRanksMenu(Handle:owner, Handle:hndl, const String:error[], any:client)
{
	if (!client || hndl == INVALID_HANDLE)
	{
		LogError("CreateRanksMenu failed! Reason: %s", error);
		return;
	}

	decl String:SteamID[MAX_LINE_WIDTH];
	new Handle:menu = CreateMenu(Menu_CreateRanksMenuHandler);

	decl String:Name[32], String:DisplayName[MAX_LINE_WIDTH];

	SetMenuTitle(menu, "Player Ranks:");
	SetMenuExitBackButton(menu, false);
	SetMenuExitButton(menu, true);

	while (SQL_FetchRow(hndl))
	{
		SQL_FetchString(hndl, 0, SteamID, sizeof(SteamID));
		SQL_FetchString(hndl, 1, Name, sizeof(Name));

		ReplaceString(Name, sizeof(Name), "&lt;", "<");
		ReplaceString(Name, sizeof(Name), "&gt;", ">");
		ReplaceString(Name, sizeof(Name), "&#37;", "%");
		ReplaceString(Name, sizeof(Name), "&#61;", "=");
		ReplaceString(Name, sizeof(Name), "&#42;", "*");

		Format(DisplayName, sizeof(DisplayName), "%s (%i points)", Name, SQL_FetchInt(hndl, 2));

		AddMenuItem(menu, SteamID, DisplayName);
	}

	DisplayMenu(menu, client, 30);
}

public CreateTimedMapsMenu(Handle:owner, Handle:hndl, const String:error[], any:client)
{
	if (!client || hndl == INVALID_HANDLE)
	{
		LogError("CreateTimedMapsMenu failed! Reason: %s", error);
		return;
	}

	if (SQL_GetRowCount(hndl) <= 0)
	{
		new Handle:TimedMapsPanel = CreatePanel();
		SetPanelTitle(TimedMapsPanel, "地图玩过的时间:");

		DrawPanelText(TimedMapsPanel, "这地图还没被玩过!");
		DrawPanelItem(TimedMapsPanel, "Close");

		SendPanelToClient(TimedMapsPanel, client, TimedMapsPanelHandler, 30);
		CloseHandle(TimedMapsPanel);

		return;
	}

	new Gamemode;
	new Handle:menu = CreateMenu(Menu_CreateTimedMapsMenuHandler);
	decl String:GamemodeTitle[32], String:GamemodeInfo[2]; //, MutationInfo[MAX_LINE_WIDTH];

	SetMenuTitle(menu, "Timed Maps:");
	SetMenuExitBackButton(menu, false);
	SetMenuExitButton(menu, true);

	while (SQL_FetchRow(hndl))
	{
		Gamemode = SQL_FetchInt(hndl, 0);
		IntToString(Gamemode, GamemodeInfo, sizeof(GamemodeInfo));

		switch (Gamemode)
		{
			case GAMEMODE_COOP:
				strcopy(GamemodeTitle, sizeof(GamemodeTitle), "Co-op");
			case GAMEMODE_SURVIVAL:
				strcopy(GamemodeTitle, sizeof(GamemodeTitle), "Survival");
			case GAMEMODE_REALISM:
				strcopy(GamemodeTitle, sizeof(GamemodeTitle), "Realism");
			case GAMEMODE_OTHERMUTATIONS:
			{
				strcopy(GamemodeTitle, sizeof(GamemodeTitle), "Mutations");
				//SQL_FetchString(hndl, 1, MutationInfo, sizeof(MutationInfo));
				//Format(GamemodeTitle, sizeof(GamemodeTitle), "Mutations (%s)", MutationInfo);
			}
			default:
				continue;
		}

		if (CurrentGamemodeID == Gamemode)
			StrCat(GamemodeTitle, sizeof(GamemodeTitle), TM_MENU_CURRENT);

		AddMenuItem(menu, GamemodeInfo, GamemodeTitle);
	}

	DisplayMenu(menu, client, 30);

	return;
}

public Menu_CreateTimedMapsMenuHandler(Handle:menu, MenuAction:action, param1, param2)
{
	if (menu == INVALID_HANDLE)
		return;

	if (action == MenuAction_End)
		CloseHandle(menu);

	if (action != MenuAction_Select || param1 <= 0 || IsClientBot(param1))
		return;

	decl String:Info[2];
	new bool:found = GetMenuItem(menu, param2, Info, sizeof(Info));

	if (!found)
		return;

	DisplayTimedMapsMenu2FromInfo(param1, Info);
}

bool:TimedMapsMenuInfoMarker(String:Info[], MenuNumber)
{
	if (Info[0] == '\0' || MenuNumber < 2)
		return false;

	new Position = -1, TempPosition;

	for (new i = 0; i < MenuNumber; i++)
	{
		TempPosition = FindCharInString(Info[Position + 1], '\\');

		if (TempPosition < 0)
		{
			if (i + 2 == MenuNumber)
				return true;
			else
				return false;
		}

		Position += 1 + TempPosition;

		if (i + 2 >= MenuNumber)
		{
			Info[Position] = '\0';
			return true;
		}
	}

	return false;
}

public DisplayTimedMapsMenu2FromInfo(client, String:Info[])
{
	if (!TimedMapsMenuInfoMarker(Info, 2))
	{
		cmd_TimedMaps(client, 0);
		return;
	}

	strcopy(MapTimingMenuInfo[client], MAX_LINE_WIDTH, Info);

	new Gamemode = StringToInt(Info);

	DisplayTimedMapsMenu2(client, Gamemode);
}

public DisplayTimedMapsMenu2(client, Gamemode)
{
	decl String:query[256];
	Format(query, sizeof(query), "SELECT DISTINCT tm.gamemode, tm.map FROM %stimedmaps AS tm INNER JOIN %splayers AS p ON tm.steamid = p.steamid WHERE tm.gamemode = %i ORDER BY tm.map ASC", DbPrefix, DbPrefix, Gamemode);
	SQL_TQuery(db, CreateTimedMapsMenu2, query, client);
}

public CreateTimedMapsMenu2(Handle:owner, Handle:hndl, const String:error[], any:client)
{
	if (!client || hndl == INVALID_HANDLE)
	{
		LogError("CreateTimedMapsMenu2 failed! Reason: %s", error);
		return;
	}

	if (SQL_GetRowCount(hndl) <= 0)
	{
		new Handle:TimedMapsPanel = CreatePanel();
		SetPanelTitle(TimedMapsPanel, "模式时间:");

		DrawPanelText(TimedMapsPanel, "这模式还没被玩过!");
		DrawPanelItem(TimedMapsPanel, "Close");

		SendPanelToClient(TimedMapsPanel, client, TimedMapsPanelHandler, 30);
		CloseHandle(TimedMapsPanel);

		return;
	}

	new Handle:menu = CreateMenu(Menu_CreateTimedMapsMenu2Hndl), Gamemode;
	decl String:Map[MAX_LINE_WIDTH], String:Info[MAX_LINE_WIDTH], String:CurrentMapName[MAX_LINE_WIDTH];

	GetCurrentMap(CurrentMapName, sizeof(CurrentMapName));

	SetMenuTitle(menu, "Timed Maps:");
	SetMenuExitBackButton(menu, true);
	SetMenuExitButton(menu, true);

	while (SQL_FetchRow(hndl))
	{
		Gamemode = SQL_FetchInt(hndl, 0);
		SQL_FetchString(hndl, 1, Map, sizeof(Map));

		Format(Info, sizeof(Info), "%i\\%s", Gamemode, Map);

		if (CurrentGamemodeID == Gamemode && StrEqual(CurrentMapName, Map))
			StrCat(Map, sizeof(Map), TM_MENU_CURRENT);

		AddMenuItem(menu, Info, Map);
	}

	DisplayMenu(menu, client, 30);
}

public Menu_CreateTimedMapsMenu2Hndl(Handle:menu, MenuAction:action, param1, param2)
{
	if (menu == INVALID_HANDLE)
		return;

	if (action == MenuAction_End)
		CloseHandle(menu);

	if (action == MenuAction_Cancel)
	{
		if (param2 == MenuCancel_ExitBack)
			cmd_TimedMaps(param1, 0);

		return;
	}

	if (action != MenuAction_Select || param1 <= 0 || IsClientBot(param1))
		return;

	decl String:Info[MAX_LINE_WIDTH];
	new bool:found = GetMenuItem(menu, param2, Info, sizeof(Info));

	if (!found)
		return;

	DisplayTimedMapsMenu3FromInfo(param1, Info);
}

public DisplayTimedMapsMenu3FromInfo(client, String:Info[])
{
	if (!TimedMapsMenuInfoMarker(Info, 3))
	{
		cmd_TimedMaps(client, 0);
		return;
	}

	strcopy(MapTimingMenuInfo[client], MAX_LINE_WIDTH, Info);

	decl String:GamemodeInfo[2], String:Map[MAX_LINE_WIDTH];

	strcopy(GamemodeInfo, sizeof(GamemodeInfo), Info);
	GamemodeInfo[1] = 0;

	strcopy(Map, sizeof(Map), Info[2]);

	DisplayTimedMapsMenu3(client, StringToInt(GamemodeInfo), Map);
}

public DisplayTimedMapsMenu3(client, Gamemode, const String:Map[])
{
	new Handle:dp = CreateDataPack();

	WritePackCell(dp, client);
	WritePackCell(dp, Gamemode);
	WritePackString(dp, Map);

	decl String:SteamID[MAX_LINE_WIDTH];
	GetClientRankAuthString(client, SteamID, sizeof(SteamID));

	decl String:query[256];
	Format(query, sizeof(query), "SELECT tm.time FROM %stimedmaps AS tm INNER JOIN %splayers AS p ON tm.steamid = p.steamid WHERE tm.gamemode = %i AND tm.map = '%s' AND p.steamid = '%s'", DbPrefix, DbPrefix, Gamemode, Map, SteamID);
	SQL_TQuery(db, DisplayTimedMapsMenu3_2, query, dp);
}

public DisplayTimedMapsMenu3_2(Handle:owner, Handle:hndl, const String:error[], any:dp)
{
	if (hndl == INVALID_HANDLE)
	{
		if (dp != INVALID_HANDLE)
			CloseHandle(dp);

		LogError("DisplayTimedMapsMenu3_2 failed! Reason: %s", error);
		return;
	}

	ResetPack(dp);

	new client = ReadPackCell(dp);
	new Gamemode = ReadPackCell(dp);
	decl String:Map[MAX_LINE_WIDTH];
	ReadPackString(dp, Map, sizeof(Map));

	CloseHandle(dp);

	if (SQL_FetchRow(hndl))
		ClientMapTime[client] = SQL_FetchFloat(hndl, 0);
	else
		ClientMapTime[client] = 0.0;

	decl String:query[256];
	Format(query, sizeof(query), "SELECT DISTINCT tm.gamemode, tm.map, tm.time FROM %stimedmaps AS tm INNER JOIN %splayers AS p ON tm.steamid = p.steamid WHERE tm.gamemode = %i AND tm.map = '%s' ORDER BY tm.time %s", DbPrefix, DbPrefix, Gamemode, Map, (Gamemode == GAMEMODE_SURVIVAL ? "DESC" : "ASC"));
	SQL_TQuery(db, CreateTimedMapsMenu3, query, client);
}

public CreateTimedMapsMenu3(Handle:owner, Handle:hndl, const String:error[], any:client)
{
	if (!client || hndl == INVALID_HANDLE)
	{
		LogError("CreateTimedMapsMenu3 failed! Reason: %s", error);
		return;
	}

	if (SQL_GetRowCount(hndl) <= 0)
	{
		new Handle:TimedMapsPanel = CreatePanel();
		SetPanelTitle(TimedMapsPanel, "Timed Maps:");

		DrawPanelText(TimedMapsPanel, "这地图还没被玩过!");
		DrawPanelItem(TimedMapsPanel, "Close");

		SendPanelToClient(TimedMapsPanel, client, TimedMapsPanelHandler, 30);
		CloseHandle(TimedMapsPanel);

		return;
	}

	new Handle:menu = CreateMenu(Menu_CreateTimedMapsMenu3Hndl), Float:MapTime;
	decl String:Map[MAX_LINE_WIDTH], String:Info[MAX_LINE_WIDTH], String:Value[MAX_LINE_WIDTH];

	SetMenuTitle(menu, "Timed Maps:");
	SetMenuExitBackButton(menu, true);
	SetMenuExitButton(menu, true);

	while (SQL_FetchRow(hndl))
	{
		SQL_FetchString(hndl, 1, Map, sizeof(Map));
		MapTime = SQL_FetchFloat(hndl, 2);

		SetTimeLabel(MapTime, Value, sizeof(Value));

		Format(Info, sizeof(Info), "%i\\%s\\%f", SQL_FetchInt(hndl, 0), Map, MapTime);

		if (ClientMapTime[client] > 0.0 && ClientMapTime[client] == MapTime)
			StrCat(Value, sizeof(Value), TM_MENU_CURRENT);

		AddMenuItem(menu, Info, Value);
	}

	DisplayMenu(menu, client, 30);
}

public Menu_CreateTimedMapsMenu3Hndl(Handle:menu, MenuAction:action, param1, param2)
{
	if (menu == INVALID_HANDLE)
		return;

	if (action == MenuAction_End)
		CloseHandle(menu);

	if (action == MenuAction_Cancel)
	{
		if (param2 == MenuCancel_ExitBack)
			DisplayTimedMapsMenu2FromInfo(param1, MapTimingMenuInfo[param1]);

		return;
	}

	if (action != MenuAction_Select || param1 <= 0 || IsClientBot(param1))
		return;

	decl String:Info[MAX_LINE_WIDTH];
	new bool:found = GetMenuItem(menu, param2, Info, sizeof(Info));

	if (!found)
		return;

	DisplayTimedMapsMenu4FromInfo(param1, Info);
}

public DisplayTimedMapsMenu4FromInfo(client, String:Info[])
{
	if (!TimedMapsMenuInfoMarker(Info, 4))
	{
		cmd_TimedMaps(client, 0);
		return;
	}

	strcopy(MapTimingMenuInfo[client], MAX_LINE_WIDTH, Info);

	decl String:GamemodeInfo[2], String:Map[MAX_LINE_WIDTH];

	strcopy(GamemodeInfo, sizeof(GamemodeInfo), Info);
	GamemodeInfo[1] = 0;

	new Position = FindCharInString(Info[2], '\\');

	if (Position < 0)
	{
		LogError("Timed Maps menu 4 error: Info = \"%s\"", Info);
		return;
	}

	Position += 2;

	strcopy(Map, sizeof(Map), Info[2]);
	Map[Position - 2] = '\0';

	decl String:MapTime[MAX_LINE_WIDTH];
	strcopy(MapTime, sizeof(MapTime), Info[Position + 1]);

	DisplayTimedMapsMenu4(client, StringToInt(GamemodeInfo), Map, StringToFloat(MapTime));
}

public DisplayTimedMapsMenu4(client, Gamemode, const String:Map[], Float:MapTime)
{
	decl String:query[256];
	Format(query, sizeof(query), "SELECT tm.steamid, p.name FROM %stimedmaps AS tm INNER JOIN %splayers AS p ON tm.steamid = p.steamid WHERE tm.gamemode = %i AND tm.map = '%s' AND tm.time = %f ORDER BY p.name ASC", DbPrefix, DbPrefix, Gamemode, Map, MapTime);
	SQL_TQuery(db, CreateTimedMapsMenu4, query, client);
}

public CreateTimedMapsMenu4(Handle:owner, Handle:hndl, const String:error[], any:client)
{
	if (!client || hndl == INVALID_HANDLE)
	{
		LogError("CreateTimedMapsMenu4 failed! Reason: %s", error);
		return;
	}

	new Handle:menu = CreateMenu(Menu_CreateTimedMapsMenu4Hndl);

	decl String:Name[32], String:SteamID[MAX_LINE_WIDTH];

	SetMenuTitle(menu, "Timed Maps:");
	SetMenuExitBackButton(menu, true);
	SetMenuExitButton(menu, true);

	while (SQL_FetchRow(hndl))
	{
		SQL_FetchString(hndl, 0, SteamID, sizeof(SteamID));
		SQL_FetchString(hndl, 1, Name, sizeof(Name));

		ReplaceString(Name, sizeof(Name), "&lt;", "<");
		ReplaceString(Name, sizeof(Name), "&gt;", ">");
		ReplaceString(Name, sizeof(Name), "&#37;", "%");
		ReplaceString(Name, sizeof(Name), "&#61;", "=");
		ReplaceString(Name, sizeof(Name), "&#42;", "*");

		AddMenuItem(menu, SteamID, Name);
	}

	DisplayMenu(menu, client, 30);
}

public Menu_CreateTimedMapsMenu4Hndl(Handle:menu, MenuAction:action, param1, param2)
{
	if (menu == INVALID_HANDLE)
		return;

	if (action == MenuAction_End)
		CloseHandle(menu);

	if (action == MenuAction_Cancel)
	{
		if (param2 == MenuCancel_ExitBack)
			DisplayTimedMapsMenu3FromInfo(param1, MapTimingMenuInfo[param1]);

		return;
	}

	if (action != MenuAction_Select || param1 <= 0 || IsClientBot(param1))
		return;

	decl String:SteamID[MAX_LINE_WIDTH];
	new bool:found = GetMenuItem(menu, param2, SteamID, sizeof(SteamID));

	if (!found)
		return;

	QueryClientStatsSteamID(param1, SteamID, CM_RANK);
}

public CreatePPMMenu(Handle:owner, Handle:hndl, const String:error[], any:client)
{
	if (!client || hndl == INVALID_HANDLE)
	{
		LogError("CreatePPMMenu failed! Reason: %s", error);
		return;
	}

	decl String:SteamID[MAX_LINE_WIDTH];
	new Handle:menu = CreateMenu(Menu_CreateRanksMenuHandler);

	decl String:Name[32], String:DisplayName[MAX_LINE_WIDTH];

	SetMenuTitle(menu, "Player PPM:");
	SetMenuExitBackButton(menu, false);
	SetMenuExitButton(menu, true);

	while (SQL_FetchRow(hndl))
	{
		SQL_FetchString(hndl, 0, SteamID, sizeof(SteamID));
		SQL_FetchString(hndl, 1, Name, sizeof(Name));

		ReplaceString(Name, sizeof(Name), "&lt;", "<");
		ReplaceString(Name, sizeof(Name), "&gt;", ">");
		ReplaceString(Name, sizeof(Name), "&#37;", "%");
		ReplaceString(Name, sizeof(Name), "&#61;", "=");
		ReplaceString(Name, sizeof(Name), "&#42;", "*");

		Format(DisplayName, sizeof(DisplayName), "%s (PPM: %.2f)", Name, SQL_FetchFloat(hndl, 2));

		AddMenuItem(menu, SteamID, DisplayName);
	}

	DisplayMenu(menu, client, 30);
}

public Menu_CreateRanksMenuHandler(Handle:menu, MenuAction:action, param1, param2)
{
	if (menu == INVALID_HANDLE)
		return;

	if (action == MenuAction_End)
		CloseHandle(menu);

	if (action != MenuAction_Select || param1 <= 0 || IsClientBot(param1))
		return;

	decl String:SteamID[MAX_LINE_WIDTH];
	new bool:found = GetMenuItem(menu, param2, SteamID, sizeof(SteamID));

	if (!found)
		return;

	QueryClientStatsSteamID(param1, SteamID, CM_RANK);
}

public Menu_CreateRankMenuHandler(Handle:menu, MenuAction:action, param1, param2)
{
	if (menu == INVALID_HANDLE)
		return;

	if (action == MenuAction_End)
		CloseHandle(menu);

	if (action != MenuAction_Select || param1 <= 0 || IsClientBot(param1))
		return;

	decl String:Info[MAX_LINE_WIDTH];
	new bool:found = GetMenuItem(menu, param2, Info, sizeof(Info));

	if (!found)
		return;

	if (strcmp(Info, "rankabout", false) == 0)
	{
		DisplayAboutPanel(param1);
		return;
	}

	else if (strcmp(Info, "showsettings", false) == 0)
	{
		DisplaySettingsPanel(param1);
		return;
	}

	HandleCommands(param1, Info);
}

// Send the RANKABOUT panel to the client's display.
public DisplayAboutPanel(client)
{
	decl String:Value[MAX_LINE_WIDTH];

	new Handle:panel = CreatePanel();

	Format(Value, sizeof(Value), "关于 %s:", PLUGIN_NAME);
	SetPanelTitle(panel, Value);

	Format(Value, sizeof(Value), "版本: %s", PLUGIN_VERSION);
	DrawPanelText(panel, Value);

	Format(Value, sizeof(Value), "作者: %s", "Mikko Andersson (muukis) translator:东");
	DrawPanelText(panel, Value);

	Format(Value, sizeof(Value), "描述: %s", "记录玩家的游戏记录.");
	DrawPanelText(panel, Value);

	DrawPanelItem(panel, "后退");
	DrawPanelItem(panel, "关闭");

	SendPanelToClient(panel, client, AboutPanelHandler, 30);
	CloseHandle(panel);
}

// Send the RANKABOUT panel to the client's display.
public DisplaySettingsPanel(client)
{
	decl String:Value[MAX_LINE_WIDTH];

	new Handle:panel = CreatePanel();

	Format(Value, sizeof(Value), "%s 设置:", PLUGIN_NAME);
	SetPanelTitle(panel, Value);

	DrawPanelItem(panel, (ClientRankMute[client] ? "解除rank提示禁用 (当前状态: 已禁用)" : "禁用rank提示 (当前状态: 未禁用)"));

	DrawPanelItem(panel, "后退");
	DrawPanelItem(panel, "关闭");

	SendPanelToClient(panel, client, SettingsPanelHandler, 30);
	CloseHandle(panel);
}



// Send the TOP10 panel to the client's display.
public DisplayTop10(Handle:owner, Handle:hndl, const String:error[], any:client)
{
	if (!client || hndl == INVALID_HANDLE)
	{
		LogError("DisplayTop10 failed! Reason: %s", error);
		return;
	}

	new String:Name[32];

	new Handle:Top10Panel = CreatePanel();
	SetPanelTitle(Top10Panel, "Top 10 玩家");

	while (SQL_FetchRow(hndl))
	{
		SQL_FetchString(hndl, 0, Name, sizeof(Name));

		ReplaceString(Name, sizeof(Name), "&lt;", "<");
		ReplaceString(Name, sizeof(Name), "&gt;", ">");
		ReplaceString(Name, sizeof(Name), "&#37;", "%");
		ReplaceString(Name, sizeof(Name), "&#61;", "=");
		ReplaceString(Name, sizeof(Name), "&#42;", "*");

		DrawPanelItem(Top10Panel, Name);
	}

	SendPanelToClient(Top10Panel, client, Top10PanelHandler, 30);
	CloseHandle(Top10Panel);
}

// Send the TOP10PPM panel to the client's display.
public DisplayTop10PPM(Handle:owner, Handle:hndl, const String:error[], any:client)
{
	if (!client || hndl == INVALID_HANDLE)
	{
		LogError("DisplayTop10PPM failed! Reason: %s", error);
		return;
	}

	decl String:Name[32], String:Disp[MAX_LINE_WIDTH];

	new Handle:TopPPMPanel = CreatePanel();
	SetPanelTitle(TopPPMPanel, "Top 10 PPM 玩家");

	while (SQL_FetchRow(hndl))
	{
		SQL_FetchString(hndl, 0, Name, sizeof(Name));

		ReplaceString(Name, sizeof(Name), "&lt;", "<");
		ReplaceString(Name, sizeof(Name), "&gt;", ">");
		ReplaceString(Name, sizeof(Name), "&#37;", "%");
		ReplaceString(Name, sizeof(Name), "&#61;", "=");
		ReplaceString(Name, sizeof(Name), "&#42;", "*");

		Format(Disp, sizeof(Disp), "%s (PPM: %.2f)", Name, SQL_FetchFloat(hndl, 1));

		DrawPanelItem(TopPPMPanel, Disp);
	}

	SendPanelToClient(TopPPMPanel, client, Top10PPMPanelHandler, 30);
	CloseHandle(TopPPMPanel);
}

// Handler for RANK panel.
public RankPanelHandler(Handle:menu, MenuAction:action, param1, param2)
{
}

// Handler for NEXTRANK panel.
public NextRankPanelHandler(Handle:menu, MenuAction:action, param1, param2)
{
	if (param2 == 1)
		QueryClientStats(param1, CM_NEXTRANKFULL);
}

// Handler for NEXTRANK panel.
public NextRankFullPanelHandler(Handle:menu, MenuAction:action, param1, param2)
{
}

// Handler for TIMEDMAPS panel.
public TimedMapsPanelHandler(Handle:menu, MenuAction:action, param1, param2)
{
}

// Handler for RANKADMIN panel.
//public RankAdminPanelHandler(Handle:menu, MenuAction:action, param1, param2)
//{
//	if (action != MenuAction_Select)
//		return;
//
//	if (param2 == 1)
//		DisplayClearPanel(param1);
//	else if (param2 == 2)
//		DisplayYesNoPanel(param1, "Do you really want to clear the player stats?", ClearPlayersPanelHandler);
//	else if (param2 == 3)
//		DisplayYesNoPanel(param1, "Do you really want to clear the map stats?", ClearMapsPanelHandler);
//	else if (param2 == 4)
//		DisplayYesNoPanel(param1, "Do you really want to clear all stats?", ClearAllPanelHandler);
//}

// Handler for RANKADMIN panel.
public ClearPlayersPanelHandler(Handle:menu, MenuAction:action, param1, param2)
{
	if (action != MenuAction_Select)
		return;

	if (param2 == 1)
	{
		ClearStatsPlayers(param1);
		StatsPrintToChatPreFormatted(param1, "All player stats cleared!");
	}
	//else if (param2 == 2)
	//	cmd_RankAdmin(param1, 0);
}

// Handler for RANKADMIN panel.
public ClearMapsPanelHandler(Handle:menu, MenuAction:action, param1, param2)
{
	if (action != MenuAction_Select)
		return;

	if (param2 == 1)
	{
		ClearStatsMaps(param1);
		StatsPrintToChatPreFormatted(param1, "All map stats cleared!");
	}
	//else if (param2 == 2)
	//	cmd_RankAdmin(param1, 0);
}

// Handler for RANKADMIN panel.
public ClearAllPanelHandler(Handle:menu, MenuAction:action, param1, param2)
{
	if (action != MenuAction_Select)
		return;

	if (param2 == 1)
	{
		ClearStatsAll(param1);
		StatsPrintToChatPreFormatted(param1, "All stats cleared!");
	}
	//else if (param2 == 2)
	//	cmd_RankAdmin(param1, 0);
}

// Handler for RANKADMIN panel.
public CleanPlayersPanelHandler(Handle:menu, MenuAction:action, param1, param2)
{
	if (action != MenuAction_Select)
		return;

	if (param2 == 1)
	{
		new LastOnTimeMonths = GetConVarInt(cvar_AdminPlayerCleanLastOnTime);
		new PlaytimeMinutes = GetConVarInt(cvar_AdminPlayerCleanPlatime);

		if (LastOnTimeMonths || PlaytimeMinutes)
		{
			new bool:Success = true;

			if (LastOnTimeMonths)
				Success &= DoFastQuery(param1, "DELETE FROM %splayers WHERE lastontime < UNIX_TIMESTAMP(DATE_SUB(NOW(), INTERVAL %i MONTH))", DbPrefix, LastOnTimeMonths);

			if (PlaytimeMinutes)
				Success &= DoFastQuery(param1, "DELETE FROM %splayers WHERE %s < %i AND lastontime < UNIX_TIMESTAMP(DATE_SUB(NOW(), INTERVAL 1 HOUR))", DbPrefix, DB_PLAYERS_TOTALPLAYTIME, PlaytimeMinutes);

			if (Success)
				StatsPrintToChatPreFormatted(param1, "Player cleaning successful!");
			else
				StatsPrintToChatPreFormatted(param1, "Player cleaning failed!");
		}
		else
			StatsPrintToChatPreFormatted(param1, "Player cleaning is disabled by configurations!");
	}
	//else if (param2 == 2)
	//	cmd_RankAdmin(param1, 0);
}

// Handler for RANKADMIN panel.
public RemoveCustomMapsPanelHandler(Handle:menu, MenuAction:action, param1, param2)
{
	if (action != MenuAction_Select)
		return;

	if (param2 == 1)
	{
		if (DoFastQuery(param1, "DELETE FROM %smaps WHERE custom = 1", DbPrefix))
			StatsPrintToChatPreFormatted(param1, "All custom maps removed!");
		else
			StatsPrintToChatPreFormatted(param1, "Removing custom maps failed!");
	}
	//else if (param2 == 2)
	//	cmd_RankAdmin(param1, 0);
}

// Handler for RANKADMIN panel.
public ClearTMAllPanelHandler(Handle:menu, MenuAction:action, param1, param2)
{
	if (action != MenuAction_Select)
		return;

	if (param2 == 1)
	{
		if (DoFastQuery(param1, "DELETE FROM %stimedmaps", DbPrefix))
			StatsPrintToChatPreFormatted(param1, "All map timings removed!");
		else
			StatsPrintToChatPreFormatted(param1, "Removing map timings failed!");
	}
	//else if (param2 == 2)
	//	cmd_RankAdmin(param1, 0);
}

// Handler for RANKADMIN panel.
public ClearTMCoopPanelHandler(Handle:menu, MenuAction:action, param1, param2)
{
	if (action != MenuAction_Select)
		return;

	if (param2 == 1)
	{
		if (DoFastQuery(param1, "DELETE FROM %stimedmaps WHERE gamemode = %i", DbPrefix, GAMEMODE_COOP))
			StatsPrintToChatPreFormatted(param1, "Clearing map timings for Coop successful!");
		else
			StatsPrintToChatPreFormatted(param1, "Clearing map timings for Coop failed!");
	}
	//else if (param2 == 2)
	//	cmd_RankAdmin(param1, 0);
}

// Handler for RANKADMIN panel.
public ClearTMSurvivalPanelHandler(Handle:menu, MenuAction:action, param1, param2)
{
	if (action != MenuAction_Select)
		return;

	if (param2 == 1)
	{
		if (DoFastQuery(param1, "DELETE FROM %stimedmaps WHERE gamemode = %i", DbPrefix, GAMEMODE_SURVIVAL))
			StatsPrintToChatPreFormatted(param1, "Clearing map timings for Survival successful!");
		else
			StatsPrintToChatPreFormatted(param1, "Clearing map timings for Survival failed!");
	}
	//else if (param2 == 2)
	//	cmd_RankAdmin(param1, 0);
}

// Handler for RANKADMIN panel.
public ClearTMRealismPanelHandler(Handle:menu, MenuAction:action, param1, param2)
{
	if (action != MenuAction_Select)
		return;

	if (param2 == 1)
	{
		if (DoFastQuery(param1, "DELETE FROM %stimedmaps WHERE gamemode = %i", DbPrefix, GAMEMODE_REALISM))
			StatsPrintToChatPreFormatted(param1, "Clearing map timings for Realism successful!");
		else
			StatsPrintToChatPreFormatted(param1, "Clearing map timings for Realism failed!");
	}
	//else if (param2 == 2)
	//	cmd_RankAdmin(param1, 0);
}

// Handler for RANKADMIN panel.
public ClearTMMutationsPanelHandler(Handle:menu, MenuAction:action, param1, param2)
{
	if (action != MenuAction_Select)
		return;

	if (param2 == 1)
	{
		if (DoFastQuery(param1, "DELETE FROM %stimedmaps WHERE gamemode = %i", DbPrefix, GAMEMODE_OTHERMUTATIONS))
			StatsPrintToChatPreFormatted(param1, "Clearing map timings for Mutations successful!");
		else
			StatsPrintToChatPreFormatted(param1, "Clearing map timings for Mutations failed!");
	}
	//else if (param2 == 2)
	//	cmd_RankAdmin(param1, 0);
}

// Handler for RANKVOTE panel.
public RankVotePanelHandler(Handle:menu, MenuAction:action, param1, param2)
{
	if (action != MenuAction_Select || RankVoteTimer == INVALID_HANDLE || param1 <= 0 || IsClientBot(param1))
		return;

	if (param2 == 1 || param2 == 2)
	{
		new team = GetClientTeam(param1);

		if (team != TEAM_SURVIVORS && team != TEAM_INFECTED)
			return;

		new OldPlayerRankVote = PlayerRankVote[param1];

		if (param2 == 1)
			PlayerRankVote[param1] = RANKVOTE_YES;
		else if (param2 == 2)
			PlayerRankVote[param1] = RANKVOTE_NO;

		new humans = 0, votes = 0, yesvotes = 0, novotes = 0, WinningVoteCount = 0;

		CheckRankVotes(humans, votes, yesvotes, novotes, WinningVoteCount);

		if (yesvotes >= WinningVoteCount || novotes >= WinningVoteCount)
		{
			if (RankVoteTimer != INVALID_HANDLE)
			{
				CloseHandle(RankVoteTimer);
				RankVoteTimer = INVALID_HANDLE;
			}

			StatsPrintToChatAll("Vote to shuffle teams by player PPM \x03%s \x01with \x04%i (yes) against %i (no)\x01.", (yesvotes >= WinningVoteCount ? "PASSED" : "DID NOT PASS"), yesvotes, novotes);

			if (yesvotes >= WinningVoteCount)
				CreateTimer(2.0, timer_ShuffleTeams);
		}

		if (OldPlayerRankVote != RANKVOTE_NOVOTE)
			return;

		decl String:Name[32];
		GetClientName(param1, Name, sizeof(Name));

		StatsPrintToChatAll("\x05%s \x01voted. \x04%i/%i \x01players have voted.", Name, votes, humans);
	}
}

CheckRankVotes(&Humans, &Votes, &YesVotes, &NoVotes, &WinningVoteCount)
{
	Humans = 0;
	Votes = 0;
	YesVotes = 0;
	NoVotes = 0;
	WinningVoteCount = 0;

	new i, team, maxplayers = MaxClients;

	for (i = 1; i <= maxplayers; i++)
	{
		if (IsClientConnected(i) && IsClientInGame(i) && !IsClientBot(i))
		{
			team = GetClientTeam(i);

			if (team == TEAM_SURVIVORS || team == TEAM_INFECTED)
			{
				Humans++;

				if (PlayerRankVote[i] != RANKVOTE_NOVOTE)
				{
					Votes++;

					if (PlayerRankVote[i] == RANKVOTE_YES)
						YesVotes++;
				}
			}
		}
	}

	// More than half of the players are needed to vot YES for rankvote pass
	WinningVoteCount = RoundToNearest(float(Humans) / 2) + 1 - (Humans % 2);
	NoVotes = Votes - YesVotes;
}

DisplayClearPanel(client, delay=30)
{
	if (!client)
		return;

	//if (ClearPlayerMenu != INVALID_HANDLE)
	//{
	//	CloseHandle(ClearPlayerMenu);
	//	ClearPlayerMenu = INVALID_HANDLE;
	//}

	new Handle:ClearPlayerMenu = CreateMenu(DisplayClearPanelHandler);
	new maxplayers = MaxClients;
	decl String:id[3], String:Name[32];

	for (new i = 1; i <= maxplayers; i++)
	{
		if (IsClientBot(i) || !IsClientConnected(i) || !IsClientInGame(i))
			continue;

		GetClientName(i, Name, sizeof(Name));
		IntToString(i, id, sizeof(id));

		AddMenuItem(ClearPlayerMenu, id, Name);
	}

	SetMenuTitle(ClearPlayerMenu, "Clear player stats:");
	DisplayMenu(ClearPlayerMenu, client, delay);
}

// Handler for RANKADMIN panel.
public DisplayClearPanelHandler(Handle:menu, MenuAction:action, param1, param2)
{
	if (menu == INVALID_HANDLE)
		return;

	if (action == MenuAction_End)
		CloseHandle(menu);

	if (action != MenuAction_Select || param1 <= 0 || IsClientBot(param1))
		return;

	decl String:id[3];
	new bool:found = GetMenuItem(menu, param2, id, sizeof(id));

	if (!found)
		return;

	new client = StringToInt(id);

	decl String:SteamID[MAX_LINE_WIDTH];
	GetClientRankAuthString(client, SteamID, sizeof(SteamID));

	if (DoFastQuery(param1, "DELETE FROM %splayers WHERE steamid = '%s'", DbPrefix, SteamID))
	{
		DoFastQuery(param1, "DELETE FROM %stimedmaps WHERE steamid = '%s'", DbPrefix, SteamID);

		ClientPoints[client] = 0;
		ClientRank[client] = 0;

		decl String:Name[32];
		GetClientName(client, Name, sizeof(Name));

		StatsPrintToChatPreFormatted(client, "你的游玩记录已被清除!");
		if (client != param1)
			StatsPrintToChat(param1, "玩家 \x05%s \x01游玩记录清除!", Name);
	}
	else
		StatsPrintToChatPreFormatted(param1, "清除玩家游玩记录失败!");
}

// Handler for RANKABOUT panel.
public AboutPanelHandler(Handle:menu, MenuAction:action, param1, param2)
{
	if (action == MenuAction_Select)
	{
		if (param2 == 1)
			cmd_ShowRankMenu(param1, 0);
	}
}

// Handler for RANK SETTINGS panel.
public SettingsPanelHandler(Handle:menu, MenuAction:action, param1, param2)
{
	if (action == MenuAction_Select)
	{
		if (param2 == 1)
			cmd_ToggleClientRankMute(param1, 0);
		if (param2 == 2)
			cmd_ShowRankMenu(param1, 0);
	}
}

// Handler for TOP10 panel. param1 handle param2 client
public Top10PanelHandler(Handle:menu, MenuAction:action, param1, param2)
{
	if (action == MenuAction_Select)
	{
		if (param2 == 0)
			param2 = 10;

		GetClientFromTop10(param1, param2 - 1);
	}
}

// Handler for TOP10PPM panel.
public Top10PPMPanelHandler(Handle:menu, MenuAction:action, param1, param2)
{
	if (action == MenuAction_Select)
	{
		if (param2 == 0)
			param2 = 10;

		GetClientFromTop10PPM(param1, param2 - 1);
	}
}

/*
-----------------------------------------------------------------------------
Private functions
-----------------------------------------------------------------------------
*/

HunterSmokerSave(Savior, Victim, BasePoints, AdvMult, ExpertMult, String:SaveFrom[], String:SQLField[])
{
	int human = CheckSurvivorsHumans();
	if (StatsDisabled() || human < 3)
		return;

	if (IsClientBot(Savior) || IsClientBot(Victim))
		return;

	new Mode = GetConVarInt(cvar_AnnounceMode);

	decl String:SaviorName[MAX_LINE_WIDTH];
	GetClientName(Savior, SaviorName, sizeof(SaviorName));
	decl String:SaviorID[MAX_LINE_WIDTH];
	GetClientRankAuthString(Savior, SaviorID, sizeof(SaviorID));

	decl String:VictimName[MAX_LINE_WIDTH];
	GetClientName(Victim, VictimName, sizeof(VictimName));
	decl String:VictimID[MAX_LINE_WIDTH];
	GetClientRankAuthString(Victim, VictimID, sizeof(VictimID));

	if (StrEqual(SaviorID, VictimID))
		return;

	new Score = ModifyScoreDifficulty(BasePoints, AdvMult, ExpertMult, TEAM_SURVIVORS);
	decl String:UpdatePoints[32];

	switch (CurrentGamemodeID)
	{
		case GAMEMODE_VERSUS:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_survivors");
		}
		case GAMEMODE_REALISM:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_realism");
		}
		case GAMEMODE_SURVIVAL:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_survival");
		}
		case GAMEMODE_SCAVENGE:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_scavenge_survivors");
		}
		case GAMEMODE_REALISMVERSUS:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_realism_survivors");
		}
		case GAMEMODE_OTHERMUTATIONS:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_mutations");
		}
		default:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points");
		}
	}

	decl String:query[1024];
	Format(query, sizeof(query), "UPDATE %splayers SET %s = %s + %i, %s = %s + 1 WHERE steamid = '%s'", DbPrefix, UpdatePoints, UpdatePoints, Score, SQLField, SQLField, SaviorID);
	SendSQLUpdate(query);

	if (Score <= 0)
		return;

	if (Mode)
		StatsPrintToChat(Savior, "你因把 \x05%s\x01 从 \x04%s\x01 里救了出来获得 \x04%i \x01分!", VictimName, SaveFrom, Score);

	UpdateMapStat("points", Score);
	AddScore(Savior, Score);
}

bool:IsClientBot(client)
{
	if (client == 0 || !IsClientConnected(client) || IsFakeClient(client))
	{
		return true;
	}

	decl String:SteamID[MAX_LINE_WIDTH];
	GetClientRankAuthString(client, SteamID, sizeof(SteamID));

	if (StrEqual(SteamID, "BOT", false))
	{
		return true;
	}

	return false;
}

ModifyScoreRealism(BaseScore, ClientTeam, bool:ToCeil=true)
{
	
	if (EngineVersion1 != Engine_Left4Dead)
	{
		decl Handle:Multiplier;
		CurrentGamemodeID=GetCurrentGamemodeID();
		if (CurrentGamemodeID == GAMEMODE_REALISM)
			Multiplier = cvar_RealismMultiplier;
		else if (CurrentGamemodeID == GAMEMODE_REALISMVERSUS)
		{
			if (ClientTeam == TEAM_SURVIVORS)
				Multiplier = cvar_RealismVersusSurMultiplier;
			else if(ClientTeam == TEAM_INFECTED)
				Multiplier = cvar_RealismVersusInfMultiplier;
			else
				return BaseScore;
		}
		else
			return BaseScore;

		if (ToCeil)
			BaseScore = RoundToCeil(GetConVarFloat(Multiplier) * BaseScore);
		else
			BaseScore = RoundToFloor(GetConVarFloat(Multiplier) * BaseScore);
	}

	return BaseScore;
}

ModifyScoreDifficultyFloatNR(BaseScore, Float:AdvMult, Float:ExpMult, ClientTeam, bool:ToCeil=true)
{
	return ModifyScoreDifficultyFloat(BaseScore, AdvMult, ExpMult, ClientTeam, ToCeil, false);
}

ModifyScoreDifficultyFloat(BaseScore, Float:AdvMult, Float:ExpMult, ClientTeam, bool:ToCeil=true, bool:Reduction = true)
{
	if (BaseScore <= 0)
	{
		return 0;
	}

	decl String:Difficulty[MAX_LINE_WIDTH];
	GetConVarString(cvar_Difficulty, Difficulty, sizeof(Difficulty));

	new Float:ModifiedScore;

	if (StrEqual(Difficulty, "Hard", false)) ModifiedScore = BaseScore * AdvMult;
	else if (StrEqual(Difficulty, "Impossible", false)) ModifiedScore = BaseScore * ExpMult;
	else return ModifyScoreRealism(BaseScore, ClientTeam);

	new Score = 0;
	if (ToCeil)
	{
		Score = RoundToCeil(ModifiedScore);
	}
	else
	{
		Score = RoundToFloor(ModifiedScore);
	}

	if (ClientTeam == TEAM_SURVIVORS && Reduction)
	{
		Score = GetMedkitPointReductionScore(Score);
	}

	return ModifyScoreRealism(Score, ClientTeam, ToCeil);
}

// Score modifier without point reduction. Usable for minus points.

ModifyScoreDifficultyNR(BaseScore, AdvMult, ExpMult, ClientTeam)
{
	return ModifyScoreDifficulty(BaseScore, AdvMult, ExpMult, ClientTeam, false);
}

ModifyScoreDifficulty(BaseScore, AdvMult, ExpMult, ClientTeam, bool:Reduction = true)
{
	decl String:Difficulty[MAX_LINE_WIDTH];
	GetConVarString(cvar_Difficulty, Difficulty, sizeof(Difficulty));

	if (StrEqual(Difficulty, "hard", false)) BaseScore = BaseScore * AdvMult;
	if (StrEqual(Difficulty, "impossible", false)) BaseScore = BaseScore * ExpMult;

	if (ClientTeam == TEAM_SURVIVORS && Reduction)
	{
		BaseScore = GetMedkitPointReductionScore(BaseScore);
	}

	return ModifyScoreRealism(BaseScore, ClientTeam);
}

IsDifficultyEasy()
{
	decl String:Difficulty[MAX_LINE_WIDTH];
	GetConVarString(cvar_Difficulty, Difficulty, sizeof(Difficulty));

	if (StrEqual(Difficulty, "easy", false))
	{
		return true;
	}

	return false;
}

InvalidGameMode()
{
	// Currently will always return False in Survival and Versus gamemodes.
	// This will be removed in a future version when stats for those versions work.

	if (CurrentGamemodeID == GAMEMODE_COOP && GetConVarBool(cvar_EnableCoop))
	{
		return false;
	}
	else if (CurrentGamemodeID == GAMEMODE_SURVIVAL && GetConVarBool(cvar_EnableSv))
	{
		return false;
	}
	else if (CurrentGamemodeID == GAMEMODE_VERSUS && GetConVarBool(cvar_EnableVersus))
	{
		return false;
	}
	else if (CurrentGamemodeID == GAMEMODE_SCAVENGE && GetConVarBool(cvar_EnableScavenge))
	{
		return false;
	}
	else if (CurrentGamemodeID == GAMEMODE_REALISM && GetConVarBool(cvar_EnableRealism))
	{
		return false;
	}
	else if (CurrentGamemodeID == GAMEMODE_REALISMVERSUS && GetConVarBool(cvar_EnableRealismVersus))
	{
		return false;
	}
	else if (CurrentGamemodeID == GAMEMODE_OTHERMUTATIONS && GetConVarBool(cvar_EnableMutations))
	{
		return false;
	}

	return true;
}

stock int CheckSurvivorsHumans()
{
	new humans = 0;
	for (new i = 1; i <= MaxClients; i++)
	{
		if (IsClientConnected(i) && IsClientInGame(i) && !IsClientBot(i) && GetClientTeam(i) == 2)
		{
			humans++;
		}
	}
	return humans;
}

bool:CheckHumans()
{
	new MinHumans = GetConVarInt(cvar_HumansNeeded);
	new Humans = 0;
	new maxplayers = MaxClients;

	for (new i = 1; i <= maxplayers; i++)
	{
		if (IsClientConnected(i) && IsClientInGame(i) && !IsClientBot(i))
		{
			Humans++;
		}
	}

	if (Humans < MinHumans)
	{
		return true;
	}
	else
	{
		return false;
	}
}

ResetInfVars()
{
	new i;

	// Reset all Infected variables
	for (i = 0; i < MAXPLAYERS + 1; i++)
	{
		BoomerHitCounter[i] = 0;
		BoomerVomitUpdated[i] = false;
		InfectedDamageCounter[i] = 0;
		SmokerDamageCounter[i] = 0;
		SpitterDamageCounter[i] = 0;
		JockeyDamageCounter[i] = 0;
		ChargerDamageCounter[i] = 0;
		ChargerImpactCounter[i] = 0;
		TankPointsCounter[i] = 0;
		TankDamageCounter[i] = 0;
		ClientInfectedType[i] = 0;
		TankSurvivorKillCounter[i] = 0;
		TankDamageTotalCounter[i] = 0;
		ChargerCarryVictim[i] = 0;
		ChargerPlummelVictim[i] = 0;
		JockeyVictim[i] = 0;
		JockeyRideStartTime[i] = 0;

		PlayerBlinded[i][0] = 0;
		PlayerBlinded[i][1] = 0;
		PlayerParalyzed[i][0] = 0;
		PlayerParalyzed[i][1] = 0;
		PlayerLunged[i][0] = 0;
		PlayerLunged[i][1] = 0;
		PlayerPlummeled[i][0] = 0;
		PlayerPlummeled[i][1] = 0;
		PlayerCarried[i][0] = 0;
		PlayerCarried[i][1] = 0;
		PlayerJockied[i][0] = 0;
		PlayerJockied[i][1] = 0;

		TimerBoomerPerfectCheck[i] = INVALID_HANDLE;
		TimerInfectedDamageCheck[i] = INVALID_HANDLE;

		TimerProtectedFriendly[i] = INVALID_HANDLE;
		ProtectedFriendlyCounter[i] = 0;

		if (ChargerImpactCounterTimer[i] != INVALID_HANDLE)
		{
			CloseHandle(ChargerImpactCounterTimer[i]);
		}

		ChargerImpactCounterTimer[i] = INVALID_HANDLE;
	}
}

public Action L4D_OnFirstSurvivorLeftSafeArea(int client){
	for (int i = 1; i <= MaxClients; i++)
	{
		if(IsClientInGame(i) && GetClientTeam(i) == 2)
			ClientEnabled[i] = true;
	}
	//开局提示该难度完成最快速度
	if(!IsNormalMode())GetThisModeBestTime();
	return Plugin_Continue;
}

ResetVars()
{
	ClearTrie(FriendlyFireDamageTrie);
	ClearTrie(PlayerRankVoteTrie);

	PlayerVomited = false;
	PlayerVomitedIncap = false;
	PanicEvent = false;
	PanicEventIncap = false;
	CampaignOver = false;
	WitchExists = false;
	WitchDisturb = false;
	MedkitsUsedCounter = 0;

	// Reset kill/point score timer amount
	CreateTimer(1.0, InitPlayers);

	TankCount = 0;

	new i, j, maxplayers = MaxClients;
	for (i = 1; i <= maxplayers; i++)
	{
		AnnounceCounter[i] = 0;
		CurrentPoints[i] = 0;
		ClientRankMute[i] = false;
		ClientEnabled[i] = false;
	}

	for (i = 0; i < MAXPLAYERS + 1; i++)
	{
		if (TimerRankChangeCheck[i] != INVALID_HANDLE)
			CloseHandle(TimerRankChangeCheck[i]);

		TimerRankChangeCheck[i] = INVALID_HANDLE;

		for (j = 0; j < MAXPLAYERS + 1; j++)
		{
			FriendlyFireCooldown[i][j] = false;
			FriendlyFireTimer[i][j] = INVALID_HANDLE;
		}

		if (MeleeKillTimer[i] != INVALID_HANDLE)
			CloseHandle(MeleeKillTimer[i]);
		MeleeKillTimer[i] = INVALID_HANDLE;
		MeleeKillCounter[i] = 0;

		PostAdminCheckRetryCounter[i] = 0;
	}

	ResetInfVars();
}

public ResetRankChangeCheck()
{
	new maxplayers = MaxClients;

	for (new i = 1; i <= maxplayers; i++)
		StartRankChangeCheck(i);
}

public StartRankChangeCheck(Client)
{
	if (TimerRankChangeCheck[Client] != INVALID_HANDLE)
		CloseHandle(TimerRankChangeCheck[Client]);

	TimerRankChangeCheck[Client] = INVALID_HANDLE;

	if (Client == 0 || IsClientBot(Client))
		return;

	RankChangeFirstCheck[Client] = true;
	DoShowRankChange(Client);
	TimerRankChangeCheck[Client] = CreateTimer(GetConVarFloat(cvar_AnnounceRankChangeIVal), timer_ShowRankChange, Client, TIMER_REPEAT);
}

StatsDisabled(bool:MapCheck = false)
{
	if (!GetConVarBool(cvar_Enable))
		return true;

	if (InvalidGameMode())
		return true;

	if (!MapCheck && IsDifficultyEasy())
		return true;

	if (!MapCheck && CheckHumans())
		return true;

	if (!MapCheck && GetConVarBool(cvar_Cheats))
		return true;

	if (db == INVALID_HANDLE)
		return true;

	return false;
}

// Check that player the score is in the map score limits and return the value that is addable.

public AddScore(Client, Score)
{
	// ToDo: use cvar_MaxPoints to check if the score is within the map limits
	CurrentPoints[Client] += Score;

	//if (GetConVarBool(cvar_AnnounceRankChange))
	//{
	//}

	return Score;
}

public UpdateSmokerDamage(Client, Damage)
{
	if (Client <= 0 || Damage <= 0 || IsClientBot(Client))
		return;

	decl String:iID[MAX_LINE_WIDTH];
	GetClientRankAuthString(Client, iID, sizeof(iID));

	decl String:query[1024];
	Format(query, sizeof(query), "UPDATE %splayers SET infected_smoker_damage = infected_smoker_damage + %i WHERE steamid = '%s'", DbPrefix, Damage, iID);
	SendSQLUpdate(query);

	UpdateMapStat("infected_smoker_damage", Damage);
}

public UpdateSpitterDamage(Client, Damage)
{
	if (Client <= 0 || Damage <= 0 || IsClientBot(Client))
		return;

	decl String:iID[MAX_LINE_WIDTH];
	GetClientRankAuthString(Client, iID, sizeof(iID));

	decl String:query[1024];
	Format(query, sizeof(query), "UPDATE %splayers SET infected_spitter_damage = infected_spitter_damage + %i WHERE steamid = '%s'", DbPrefix, Damage, iID);
	SendSQLUpdate(query);

	UpdateMapStat("infected_spitter_damage", Damage);
}

public UpdateJockeyDamage(Client, Damage)
{
	if (Client <= 0 || Damage <= 0 || IsClientBot(Client))
		return;

	decl String:iID[MAX_LINE_WIDTH];
	GetClientRankAuthString(Client, iID, sizeof(iID));

	decl String:query[1024];
	Format(query, sizeof(query), "UPDATE %splayers SET infected_jockey_damage = infected_jockey_damage + %i WHERE steamid = '%s'", DbPrefix, Damage, iID);
	SendSQLUpdate(query);

	UpdateMapStat("infected_jockey_damage", Damage);
}

UpdateJockeyRideLength(Client, Float:RideLength=-1.0)
{
	if (Client <= 0 || RideLength == 0 || IsClientBot(Client) || (RideLength < 0 && JockeyRideStartTime[Client] <= 0))
		return;

	if (RideLength < 0)
		RideLength = float(GetTime() - JockeyRideStartTime[Client]);

	decl String:iID[MAX_LINE_WIDTH];
	GetClientRankAuthString(Client, iID, sizeof(iID));

	decl String:query[1024];
	Format(query, sizeof(query), "UPDATE %splayers SET infected_jockey_ridetime = infected_jockey_ridetime + %f WHERE steamid = '%s'", DbPrefix, RideLength, iID);
	SendSQLUpdate(query);

	UpdateMapStatFloat("infected_jockey_ridetime", RideLength);
}

public UpdateChargerDamage(Client, Damage)
{
	if (Client <= 0 || Damage <= 0 || IsClientBot(Client))
		return;

	decl String:iID[MAX_LINE_WIDTH];
	GetClientRankAuthString(Client, iID, sizeof(iID));

	decl String:query[1024];
	Format(query, sizeof(query), "UPDATE %splayers SET infected_charger_damage = infected_charger_damage + %i WHERE steamid = '%s'", DbPrefix, Damage, iID);
	SendSQLUpdate(query);

	UpdateMapStat("infected_charger_damage", Damage);
}

public CheckSurvivorsWin()
{
	//StatsPrintToChatTeam(TEAM_SURVIVORS, "\x03有调用CheckSurvivorsWin方法!");
	if (CampaignOver)
		return;
	if (!Isstart)
		return;

	CampaignOver = true;
	//StatsPrintToChatTeam(TEAM_SURVIVORS, "\x03CampaignOver值没问题!");
	if(!StopMapTiming())return;
	CurrentGamemodeID = GetCurrentGamemodeID();
	// Return if gamemode is Scavenge or Survival
	if (CurrentGamemodeID == GAMEMODE_SCAVENGE ||
			CurrentGamemodeID == GAMEMODE_SURVIVAL)
		return;
	//StatsPrintToChatTeam(TEAM_SURVIVORS, "\x03Gameid没问题");
	new Score = ModifyScoreDifficulty(GetConVarInt(cvar_Witch), 5, 10, TEAM_SURVIVORS);
	new Mode = GetConVarInt(cvar_AnnounceMode);
	decl String:iID[MAX_LINE_WIDTH];
	decl String:query[1024];
	new maxplayers = MaxClients;
	decl String:UpdatePoints[32], String:UpdatePointsPenalty[32];
	new ClientTeam, bool:NegativeScore = GetConVarBool(cvar_EnableNegativeScore);

	switch (CurrentGamemodeID)
	{
		case GAMEMODE_VERSUS:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_survivors");
			Format(UpdatePointsPenalty, sizeof(UpdatePointsPenalty), "points_infected");
		}
		case GAMEMODE_REALISM:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_realism");
		}
		case GAMEMODE_REALISMVERSUS:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_realism_survivors");
			Format(UpdatePointsPenalty, sizeof(UpdatePointsPenalty), "points_realism_infected");
		}
		case GAMEMODE_OTHERMUTATIONS:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_mutations");
		}
		default:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points");
		}
	}
	//StatsPrintToChatTeam(TEAM_SURVIVORS, "\x03Witch分数为%d",Score);
	if (Score > 0 && WitchExists && !WitchDisturb)
	{
		for (new i = 1; i <= maxplayers; i++)
		{
			if (IsClientConnected(i) && IsClientInGame(i) && !IsClientBot(i) && GetClientTeam(i) == TEAM_SURVIVORS)
			{
				GetClientRankAuthString(i, iID, sizeof(iID));
				Format(query, sizeof(query), "UPDATE %splayers SET %s = %s + %i WHERE steamid = '%s'", DbPrefix, UpdatePoints, UpdatePoints, Score, iID);
				SendSQLUpdate(query);
				UpdateMapStat("points", Score);
				AddScore(i, Score);
			}
		}

		if (Mode)
			StatsPrintToChatTeam(TEAM_SURVIVORS, "\x03所有幸存者因 \x05没有惊扰Witch \x01获得\x04%i \x01额外过关分!", Score);
	}
	//StatsPrintToChatTeam(TEAM_SURVIVORS, "\x03过关分数为%d",Score);
	Score = 0;
	new Deaths = 0;
	new BaseScore = ModifyScoreDifficulty(GetConVarInt(cvar_SafeHouse), 2, 2, TEAM_SURVIVORS);

	for (new i = 1; i <= maxplayers; i++)
	{
		if (IsClientConnected(i) && IsClientInGame(i)  && GetClientTeam(i) == TEAM_SURVIVORS)
		{
			if (IsPlayerAlive(i))
				Score = Score + BaseScore;
			else
				Deaths++;
		}
	}
	if(Score>400)
		Score=400;
	
	if (SinglePlayerMode())
	{
		int addScore = 0;
		if( GetAnneInfectedNumber() > 3 && ((g_brpgAvailable && L4D_RPG_GetGlobalValue(INDEX_VALID)) && IsThisRoundValid())){
			addScore = (GetAnneInfectedNumber() - 3) * 100;
		}
		char buffer[256];
		Format(buffer, sizeof(buffer), "\x03单人模式 \x01没有\x04特感击杀奖励，所以过关奖励分数\x053倍");
		if(addScore > 0){
			Format(buffer, sizeof(buffer), "%s, 获得难度分数补贴 %d 分", buffer, addScore);
		}
		StatsPrintToChatTeam(TEAM_SURVIVORS, buffer);
		Score *=3;
	}

	if((AnneMultiPlayerMode() || SinglePlayerMode()) && ((g_brpgAvailable && L4D_RPG_GetGlobalValue(INDEX_VALID)) && IsThisRoundValid())){
		int inf = GetAnneInfectedNumber();
		if(inf>4)
			Score=RoundToFloor(Score+Score*(inf-4)*0.2);
		else if(inf>6)
			Score=RoundToFloor(Score+Score*(inf-4)*0.3);
		else if(inf>8)
			Score=RoundToFloor(Score+Score*(inf-4)*0.4);
	}

	if(IsAboveFourPeople())
	{
		Score = RoundToFloor(Score * (4.0 / getSurvivorNum()));
	}

	if(IsGaoJiRenJiEnabled())
	{
		Score = RoundToFloor(Score * 0.5);
	}

	// HardCore 奖励增加50%
	if(IsAnne() == 2)
	{
		Score = RoundToFloor(1.5 * Score);
	}

	if(!CheckIsOfficalMap())return;

	new String:All4Safe[64] = "";
	if (Deaths == 0)
		Format(All4Safe, sizeof(All4Safe), ", award_allinsafehouse = award_allinsafehouse + 1");

	for (new i = 1; i <= maxplayers; i++)
	{
		if (IsClientConnected(i) && IsClientInGame(i) && !IsClientBot(i))
		{
			ClientTeam = GetClientTeam(i);

			if (ClientTeam == TEAM_SURVIVORS)
			{
				InterstitialPlayerUpdate(i);

				GetClientRankAuthString(i, iID, sizeof(iID));
				Format(query, sizeof(query), "UPDATE %splayers SET %s = %s + %i%s WHERE steamid = '%s'", DbPrefix, UpdatePoints, UpdatePoints, Score, All4Safe, iID);
				SendSQLUpdate(query);
				UpdateMapStat("points", Score);
				AddScore(i, Score);
			}
			else if (ClientTeam == TEAM_INFECTED && NegativeScore)
			{
				DoInfectedFinalChecks(i);

				GetClientRankAuthString(i, iID, sizeof(iID));
				Format(query, sizeof(query), "UPDATE %splayers SET %s = %s - %i WHERE steamid = '%s'", DbPrefix, UpdatePoints, UpdatePoints, Score, iID);
				SendSQLUpdate(query);
				AddScore(i, Score * (-1));
			}
			if (TimerRankChangeCheck[i] != INVALID_HANDLE)
				TriggerTimer(TimerRankChangeCheck[i], true);
		}
	}

	if (Mode && Score > 0)
	{
		StatsPrintToChatTeam(TEAM_SURVIVORS, "\x03所有幸存者因 \x05%i 死亡到达安全门 \x01获得 \x04%i \x01分!", Deaths, Score);

		if (NegativeScore)
			StatsPrintToChatTeam(TEAM_INFECTED, "\x03所有感染者因 \x05让幸存者进了安全门 \x01失去了 \x04%i \x01分!", Score);
	}

	PlayerVomited = false;
	PanicEvent = false;
}

stock int GetAnneInfectedNumber(){
	return GetConVarInt(FindConVar("l4d_infected_limit"));
}

stock int GetAnneSISpawnTime()
{
	return GetConVarInt(FindConVar("versus_special_respawn_interval"));
}

stock char[] GetAnneVersion()
{
	char version[255];
	GetConVarString(FindConVar("AnnePluginVersion"), version, sizeof(version));
	return version;
}

IsSingleTeamGamemode()
{
	if (CurrentGamemodeID == GAMEMODE_SCAVENGE ||
			CurrentGamemodeID == GAMEMODE_VERSUS ||
			CurrentGamemodeID == GAMEMODE_REALISMVERSUS)
		return false;

	return true;
}

CheckSurvivorsAllDown()
{
	if (CampaignOver ||
				CurrentGamemodeID == GAMEMODE_COOP ||
				CurrentGamemodeID == GAMEMODE_REALISM)
		return;

	new maxplayers = MaxClients;
	new ClientTeam;
	new bool:ClientIsAlive, bool:ClientIsBot, bool:ClientIsIncap;
	new KilledSurvivor[MaxClients];
	new AliveInfected[MaxClients];
	new Infected[MaxClients];
	new InfectedCounter = 0, AliveInfectedCounter = 0;
	new i;

	// Add to killing score on all incapacitated surviviors
	new IncapCounter = 0;

	for (i = 1; i <= maxplayers; i++)
	{
		if (!IsClientInGame(i))
			continue;

		ClientIsBot = IsClientBot(i);
		ClientIsIncap = IsClientIncapacitated(i);
		ClientIsAlive = IsClientAlive(i);

		if (ClientIsBot || IsClientInGame(i))
			ClientTeam = GetClientTeam(i);
		else 
			continue;

		// Client is not dead and not incapped -> game continues!
		if (ClientTeam == TEAM_SURVIVORS && ClientIsAlive && !ClientIsIncap)
			return;

		if (ClientTeam == TEAM_INFECTED && !ClientIsBot)
		{
			if (ClientIsAlive)
				AliveInfected[AliveInfectedCounter++] = i;

			Infected[InfectedCounter++] = i;
		}
		else if (ClientTeam == TEAM_SURVIVORS && ClientIsAlive)
			KilledSurvivor[IncapCounter++] = i;
	}

	// If we ever get this far it means the surviviors are all down or dead!

	CampaignOver = true;

	// Stop the timer and return if gamemode is Survival
	if (CurrentGamemodeID == GAMEMODE_SURVIVAL)
	{
		SurvivalStarted = false;
		StopMapTiming();
		return;
	}

	// If we ever get this far it means the current gamemode is NOT Survival

	for (i = 1; i <= maxplayers; i++)
	{
		if (IsClientConnected(i) && !IsFakeClient(i) && IsClientInGame(i))
		{
			if (GetClientTeam(i) == TEAM_SURVIVORS)
				InterstitialPlayerUpdate(i);

			if (TimerRankChangeCheck[i] != INVALID_HANDLE)
				TriggerTimer(TimerRankChangeCheck[i], true);
		}
	}

	decl String:query[1024];
	decl String:ClientID[MAX_LINE_WIDTH];
	new Mode = GetConVarInt(cvar_AnnounceMode);

	for (i = 0; i < AliveInfectedCounter; i++)
		DoInfectedFinalChecks(AliveInfected[i]);

	new Score = ModifyScoreDifficultyFloat(GetConVarInt(cvar_VictoryInfected), 0.75, 0.5, TEAM_INFECTED) * IncapCounter;

	if (Score > 0)
		for (i = 0; i < InfectedCounter; i++)
		{
			GetClientRankAuthString(Infected[i], ClientID, sizeof(ClientID));

			if (CurrentGamemodeID == GAMEMODE_VERSUS)
				Format(query, sizeof(query), "UPDATE %splayers SET points_infected = points_infected + %i, award_infected_win = award_infected_win + 1 WHERE steamid = '%s'", DbPrefix, Score, ClientID);
			else if (CurrentGamemodeID == GAMEMODE_REALISMVERSUS)
				Format(query, sizeof(query), "UPDATE %splayers SET points_realism_infected = points_realism_infected + %i, award_infected_win = award_infected_win + 1 WHERE steamid = '%s'", DbPrefix, Score, ClientID);
			else if (CurrentGamemodeID == GAMEMODE_SCAVENGE)
				Format(query, sizeof(query), "UPDATE %splayers SET points_scavenge_infected = points_scavenge_infected + %i, award_scavenge_infected_win = award_scavenge_infected_win + 1 WHERE steamid = '%s'", DbPrefix, Score, ClientID);
			else
				Format(query, sizeof(query), "UPDATE %splayers SET points_mutations = points_mutations + %i, award_scavenge_infected_win = award_scavenge_infected_win + 1 WHERE steamid = '%s'", DbPrefix, Score, ClientID);

			SendSQLUpdate(query);
		}

	UpdateMapStat("infected_win", 1);
	if (IncapCounter > 0)
		UpdateMapStat("survivor_kills", IncapCounter);
	if (Score > 0)
		UpdateMapStat("points_infected", Score);

	if (Score > 0 && Mode)
		StatsPrintToChatTeam(TEAM_INFECTED, "\x03所有感染者 \x05因杀死了所有幸存者 \x01获得 \x04%i \x01分!", Score);

	if (!GetConVarBool(cvar_EnableNegativeScore))
		return;

	if (CurrentGamemodeID == GAMEMODE_VERSUS)
	{
		Score = ModifyScoreDifficultyFloatNR(GetConVarInt(cvar_Restart), 0.75, 0.5, TEAM_SURVIVORS);
	}
	else if (CurrentGamemodeID == GAMEMODE_REALISMVERSUS)
	{
		Score = ModifyScoreDifficultyFloatNR(GetConVarInt(cvar_Restart), 0.6, 0.3, TEAM_SURVIVORS);
	}
	else
	{
		Score = ModifyScoreDifficultyNR(GetConVarInt(cvar_Restart), 2, 3, TEAM_SURVIVORS);
		Score = 400 - Score;
	}

	for (i = 0; i < IncapCounter; i++)
	{
		GetClientRankAuthString(KilledSurvivor[i], ClientID, sizeof(ClientID));

		if (CurrentGamemodeID == GAMEMODE_VERSUS)
			Format(query, sizeof(query), "UPDATE %splayers SET points_survivors = points_survivors - %i WHERE steamid = '%s'", DbPrefix, Score, ClientID);
		else if (CurrentGamemodeID == GAMEMODE_REALISMVERSUS)
			Format(query, sizeof(query), "UPDATE %splayers SET points_realism_survivors = points_realism_survivors - %i WHERE steamid = '%s'", DbPrefix, Score, ClientID);
		else if (CurrentGamemodeID == GAMEMODE_SCAVENGE)
			Format(query, sizeof(query), "UPDATE %splayers SET points_scavenge_survivors = points_scavenge_survivors - %i WHERE steamid = '%s'", DbPrefix, Score, ClientID);
		else
			Format(query, sizeof(query), "UPDATE %splayers SET points_mutations = points_mutations - %i WHERE steamid = '%s'", DbPrefix, Score, ClientID);

		SendSQLUpdate(query);
	}

	if (Mode && Score > 0)
		StatsPrintToChatTeam(TEAM_SURVIVORS, "\x03所有幸存者 \x01 \x03失去了 \x04%i \x01分 by \x03全部坐牢\x01!", Score);
}

bool:IsClientIncapacitated(client)
{
	return GetEntProp(client, Prop_Send, "m_isIncapacitated") != 0 ||
				 GetEntProp(client, Prop_Send, "m_isHangingFromLedge") != 0;
}

bool:IsClientAlive(client)
{
	if (!IsClientConnected(client))
		return false;

	if (IsFakeClient(client))
		return GetClientHealth(client) > 0 && GetEntProp(client, Prop_Send, "m_lifeState") == 0;
	else if (!IsClientInGame(client))
			return false;

	return IsPlayerAlive(client);
}

bool:IsGamemode(const String:Gamemode[])
{
	if (StrContains(CurrentGamemode, Gamemode, false) != -1)
	{
		return true;
	}

	return false;
}

GetGamemodeID(const String:Gamemode[])
{
	if (StrEqual(Gamemode, "coop", false))
	{
		return GAMEMODE_COOP;
	}
	else if (StrEqual(Gamemode, "survival", false))
	{
		return GAMEMODE_SURVIVAL;
	}
	else if (StrEqual(Gamemode, "versus", false))
	{
		return GAMEMODE_VERSUS;
	}
	else if (StrEqual(Gamemode, "teamversus", false) && GetConVarInt(cvar_EnableTeamVersus))
	{
		return GAMEMODE_VERSUS;
	}
	else if (StrEqual(Gamemode, "scavenge", false))
	{
		return GAMEMODE_SCAVENGE;
	}
	else if (StrEqual(Gamemode, "teamscavenge", false) && GetConVarInt(cvar_EnableTeamScavenge))
	{
		return GAMEMODE_SCAVENGE;
	}
	else if (StrEqual(Gamemode, "realism", false))
	{
		return GAMEMODE_REALISM;
	}
	else if (StrEqual(Gamemode, "mutation12", false))
	{
		return GAMEMODE_REALISMVERSUS;
	}
	else if (StrEqual(Gamemode, "teamrealismversus", false) && GetConVarInt(cvar_EnableTeamRealismVersus))
	{
		return GAMEMODE_REALISMVERSUS;
	}
	else if (StrContains(Gamemode, "mutation", false) == 0 ||
					 StrContains(Gamemode, "community", false) == 0)
	{
		return GAMEMODE_OTHERMUTATIONS;
	}

	return GAMEMODE_UNKNOWN;
}

GetCurrentGamemodeID()
{
	new String:CurrentMode[16];
	GetConVarString(cvar_Gamemode, CurrentMode, sizeof(CurrentMode));

	return GetGamemodeID(CurrentMode);
}

IsGamemodeVersus()
{
	return IsGamemode("versus") || (IsGamemode("teamversus") && GetConVarBool(cvar_EnableTeamVersus));
}
/*
IsGamemodeRealism()
{
	return IsGamemode("realism");
}

IsGamemodeRealismVersus()
{
	return IsGamemode("mutation12");
}

IsGamemodeScavenge()
{
	return IsGamemode("scavege") || (IsGamemode("teamscavege") && GetConVarBool(cvar_EnableTeamScavenge));
}

IsGamemodeCoop()
{
	return IsGamemode("coop");
}
*/
GetSurvivorKillScore()
{
	return ModifyScoreDifficultyFloat(GetConVarInt(cvar_SurvivorDeath), 0.75, 0.5, TEAM_INFECTED);
}

DoInfectedFinalChecks(Client, ClientInfType = -1)
{
	if (Client == 0)
		return;

	if (ClientInfType < 0)
		ClientInfType = ClientInfectedType[Client];

	if (ClientInfType == INF_ID_SMOKER)
	{
		new Damage = SmokerDamageCounter[Client];
		SmokerDamageCounter[Client] = 0;
		UpdateSmokerDamage(Client, Damage);
	}
	else if (EngineVersion1 != Engine_Left4Dead && ClientInfType == INF_ID_SPITTER_L4D2)
	{
		new Damage = SpitterDamageCounter[Client];
		SpitterDamageCounter[Client] = 0;
		UpdateSpitterDamage(Client, Damage);
	}
	else if (EngineVersion1 != Engine_Left4Dead && ClientInfType == INF_ID_JOCKEY_L4D2)
	{
		new Damage = JockeyDamageCounter[Client];
		JockeyDamageCounter[Client] = 0;
		UpdateJockeyDamage(Client, Damage);
		UpdateJockeyRideLength(Client);
	}
	else if (EngineVersion1 != Engine_Left4Dead && ClientInfType == INF_ID_CHARGER_L4D2)
	{
		new Damage = ChargerDamageCounter[Client];
		ChargerDamageCounter[Client] = 0;
		UpdateChargerDamage(Client, Damage);
	}
}

GetInfType(Client)
{
	// Client > 0 && ClientTeam == TEAM_INFECTED checks are done by the caller

	new InfType = GetEntProp(Client, Prop_Send, "m_zombieClass");

	// Make the conversion so that everything gets stored in the correct fields
	if (EngineVersion1 == Engine_Left4Dead)
	{
		if (InfType == INF_ID_WITCH_L4D1)
			return INF_ID_WITCH_L4D2;

		if (InfType == INF_ID_TANK_L4D1)
			return INF_ID_TANK_L4D2;
	}

	return InfType;
}

SetClientInfectedType(Client)
{
	// Bot check is done by the caller

	if (Client <= 0)
		return;

	new ClientTeam = GetClientTeam(Client);

	if (ClientTeam == TEAM_INFECTED)
	{
		ClientInfectedType[Client] = GetInfType(Client);

		if (ClientInfectedType[Client] != INF_ID_SMOKER
				&& ClientInfectedType[Client] != INF_ID_BOOMER
				&& ClientInfectedType[Client] != INF_ID_HUNTER
				&& ClientInfectedType[Client] != INF_ID_SPITTER_L4D2
				&& ClientInfectedType[Client] != INF_ID_JOCKEY_L4D2
				&& ClientInfectedType[Client] != INF_ID_CHARGER_L4D2
				&& ClientInfectedType[Client] != INF_ID_TANK_L4D2)
			return;

		decl String:ClientID[MAX_LINE_WIDTH];
		GetClientRankAuthString(Client, ClientID, sizeof(ClientID));

		decl String:query[1024];
		Format(query, sizeof(query), "UPDATE %splayers SET infected_spawn_%i = infected_spawn_%i + 1 WHERE steamid = '%s'", DbPrefix, ClientInfectedType[Client], ClientInfectedType[Client], ClientID);
		SendSQLUpdate(query);

		new String:Spawn[32];
		Format(Spawn, sizeof(Spawn), "infected_spawn_%i", ClientInfectedType[Client]);
		UpdateMapStat(Spawn, 1);
	}
	else
		ClientInfectedType[Client] = 0;
}

TankDamage(Client, Damage)
{
	if (Client <= 0 || Damage <= 0)
		return 0;

	// Update only the Tank inflicted damage related statistics
	UpdateTankDamage(Client, Damage);

	// If value is negative then client has already received the Bulldozer Award
	if (TankDamageTotalCounter[Client] >= 0)
	{
		TankDamageTotalCounter[Client] += Damage;
		new TankDamageTotal = GetConVarInt(cvar_TankDamageTotal);

		if (TankDamageTotalCounter[Client] >= TankDamageTotal)
		{
			TankDamageTotalCounter[Client] = -1; // Just one award per Tank
			new Score = ModifyScoreDifficultyFloat(GetConVarInt(cvar_TankDamageTotalSuccess), 0.75, 0.5, TEAM_INFECTED);

			if (Score > 0)
			{
				decl String:ClientID[MAX_LINE_WIDTH];
				GetClientRankAuthString(Client, ClientID, sizeof(ClientID));

				decl String:query[1024];

				if (CurrentGamemodeID == GAMEMODE_VERSUS)
					Format(query, sizeof(query), "UPDATE %splayers SET points_infected = points_infected + %i, award_bulldozer = award_bulldozer + 1 WHERE steamid = '%s'", DbPrefix, Score, ClientID);
				else if (CurrentGamemodeID == GAMEMODE_REALISMVERSUS)
					Format(query, sizeof(query), "UPDATE %splayers SET points_realism_infected = points_realism_infected + %i, award_bulldozer = award_bulldozer + 1 WHERE steamid = '%s'", DbPrefix, Score, ClientID);
				else if (CurrentGamemodeID == GAMEMODE_SCAVENGE)
					Format(query, sizeof(query), "UPDATE %splayers SET points_scavenge_infected = points_scavenge_infected + %i, award_bulldozer = award_bulldozer + 1 WHERE steamid = '%s'", DbPrefix, Score, ClientID);
				else
					Format(query, sizeof(query), "UPDATE %splayers SET points_mutations = points_mutations + %i, award_bulldozer = award_bulldozer + 1 WHERE steamid = '%s'", DbPrefix, Score, ClientID);

				SendSQLUpdate(query);

				UpdateMapStat("points_infected", Score);

				new Mode = GetConVarInt(cvar_AnnounceMode);

				if (Mode == 1 || Mode == 2)
					StatsPrintToChat(Client, "你给幸存者造成了价值 \x04%i\x01 分的伤害获得 \x04%i \x01分!", TankDamageTotal, Score);
				else if (Mode == 3)
				{
					decl String:Name[MAX_LINE_WIDTH];
					GetClientName(Client, Name, sizeof(Name));
					StatsPrintToChatAll("\x05%s \x01给幸存者造成了价值 \x04%i\x01 分的伤害获得 \x04%i \x01分!", Name, TankDamageTotal, Score);
				}

				if (EnableSounds_Tank_Bulldozer && GetConVarBool(cvar_SoundsEnabled))
					EmitSoundToAll(StatsSound_Tank_Bulldozer);
			}
		}
	}

	new DamageLimit = GetConVarInt(cvar_TankDamageCap);

	if (TankDamageCounter[Client] >= DamageLimit)
		return 0;

	TankDamageCounter[Client] += Damage;

	if (TankDamageCounter[Client] > DamageLimit)
		Damage -= TankDamageCounter[Client] - DamageLimit;

	return Damage;
}

UpdateFriendlyFire(Attacker, Victim)
{
	decl String:AttackerName[MAX_LINE_WIDTH];
	GetClientName(Attacker, AttackerName, sizeof(AttackerName));
	decl String:AttackerID[MAX_LINE_WIDTH];
	GetClientRankAuthString(Attacker, AttackerID, sizeof(AttackerID));

	decl String:VictimName[MAX_LINE_WIDTH];
	GetClientName(Victim, VictimName, sizeof(VictimName));

	new Score = 0;
	if (GetConVarBool(cvar_EnableNegativeScore))
	{
		if (!IsClientBot(Victim))
			Score = ModifyScoreDifficultyNR(GetConVarInt(cvar_FFire), 2, 4, TEAM_SURVIVORS);
		else
		{
			new Float:BotScoreMultiplier = GetConVarFloat(cvar_BotScoreMultiplier);

			if (BotScoreMultiplier > 0.0)
				Score = RoundToNearest(ModifyScoreDifficultyNR(GetConVarInt(cvar_FFire), 2, 4, TEAM_SURVIVORS) * BotScoreMultiplier);
		}
	}

	decl String:UpdatePoints[32];

	switch (CurrentGamemodeID)
	{
		case GAMEMODE_VERSUS:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_survivors");
		}
		case GAMEMODE_REALISM:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_realism");
		}
		case GAMEMODE_SURVIVAL:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_survival");
		}
		case GAMEMODE_SCAVENGE:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_scavenge_survivors");
		}
		case GAMEMODE_REALISMVERSUS:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_realism_survivors");
		}
		case GAMEMODE_OTHERMUTATIONS:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points_mutations");
		}
		default:
		{
			Format(UpdatePoints, sizeof(UpdatePoints), "points");
		}
	}
	if(IsNormalMode()){
		Score = RoundToFloor(Score / 5.0);
	}

	decl String:query[1024];
	Format(query, sizeof(query), "UPDATE %splayers SET %s = %s - %i, award_friendlyfire = award_friendlyfire + 1 WHERE steamid = '%s'", DbPrefix, UpdatePoints, UpdatePoints, Score, AttackerID);
	SendSQLUpdate(query);

	new Mode = 0;
	if (Score > 0)
		Mode = GetConVarInt(cvar_AnnounceMode);

	if (Mode == 1 || Mode == 2)
		StatsPrintToChat(Attacker, "你已经 \x03失去了 \x04%i \x01分 by \x03黑枪了 \x05%s\x01!", Score, VictimName);
	else if (Mode == 3)
		StatsPrintToChatAll("\x05%s \x01已经 \x03失去了 \x04%i \x01分 by \x03黑枪了 \x05%s\x01!", AttackerName, Score, VictimName);
}

UpdateHunterDamage(Client, Damage)
{
	if (Damage <= 0)
		return;

	decl String:ClientID[MAX_LINE_WIDTH];
	GetClientRankAuthString(Client, ClientID, sizeof(ClientID));

	decl String:query[1024];
	Format(query, sizeof(query), "UPDATE %splayers SET infected_hunter_pounce_dmg = infected_hunter_pounce_dmg + %i, infected_hunter_pounce_counter = infected_hunter_pounce_counter + 1 WHERE steamid = '%s'", DbPrefix, Damage, ClientID);
	SendSQLUpdate(query);

	UpdateMapStat("infected_hunter_pounce_counter", 1);
	UpdateMapStat("infected_hunter_pounce_damage", Damage);
}

UpdateTankDamage(Client, Damage)
{
	if (Damage <= 0)
		return;

	decl String:ClientID[MAX_LINE_WIDTH];
	GetClientRankAuthString(Client, ClientID, sizeof(ClientID));

	decl String:query[1024];
	Format(query, sizeof(query), "UPDATE %splayers SET infected_tank_damage = infected_tank_damage + %i WHERE steamid = '%s'", DbPrefix, Damage, ClientID);
	SendSQLUpdate(query);

	UpdateMapStat("infected_tank_damage", Damage);
}
/*
UpdatePlayerScore(Client, Score)
{
	if (Score == 0)
		return;

	switch (CurrentGamemodeID)
	{
		case GAMEMODE_VERSUS:
		{
			UpdatePlayerScoreVersus(Client, GetClientTeam(Client), Score);
		}
		case GAMEMODE_REALISM:
		{
			UpdatePlayerScoreRealismVersus(Client, GetClientTeam(Client), Score);
		}
		case GAMEMODE_SURVIVAL:
		{
			UpdatePlayerScore2(Client, Score, "points_survival");
		}
		case GAMEMODE_SCAVENGE:
		{
			UpdatePlayerScoreScavenge(Client, GetClientTeam(Client), Score);
		}
		case GAMEMODE_OTHERMUTATIONS:
		{
			UpdatePlayerScore2(Client, Score, "points_mutations");
		}
		default:
		{
			UpdatePlayerScore2(Client, Score, "points");
		}
	}
}

UpdatePlayerScoreVersus(Client, ClientTeam, Score)
{
	if (Score == 0)
		return;

	if (ClientTeam == TEAM_SURVIVORS)
		UpdatePlayerScore2(Client, Score, "points_survivors");
	else if (ClientTeam == TEAM_INFECTED)
		UpdatePlayerScore2(Client, Score, "points_infected");
}

UpdatePlayerScoreRealismVersus(Client, ClientTeam, Score)
{
	if (Score == 0)
		return;

	if (ClientTeam == TEAM_SURVIVORS)
		UpdatePlayerScore2(Client, Score, "points_realism_survivors");
	else if (ClientTeam == TEAM_INFECTED)
		UpdatePlayerScore2(Client, Score, "points_realism_infected");
}

UpdatePlayerScoreScavenge(Client, ClientTeam, Score)
{
	if (Score == 0)
		return;

	if (ClientTeam == TEAM_SURVIVORS)
		UpdatePlayerScore2(Client, Score, "points_scavenge_survivors");
	else if (ClientTeam == TEAM_INFECTED)
		UpdatePlayerScore2(Client, Score, "points_scavenge_infected");
}
*/
UpdatePlayerScore2(Client, Score, const String:Points[])
{
	if (Score == 0)
		return;

	decl String:ClientID[MAX_LINE_WIDTH];
	GetClientRankAuthString(Client, ClientID, sizeof(ClientID));

	decl String:query[1024];
	Format(query, sizeof(query), "UPDATE %splayers SET %s = %s + %i WHERE steamid = '%s'", DbPrefix, Points, Points, Score, ClientID);
	SendSQLUpdate(query);

	if (Score > 0)
		UpdateMapStat("points", Score);

	AddScore(Client, Score);
}

UpdateTankSniper(Client)
{
	if (Client <= 0)
		return;

	decl String:ClientID[MAX_LINE_WIDTH];
	GetClientRankAuthString(Client, ClientID, sizeof(ClientID));

	UpdateTankSniperSteamID(ClientID);
}

UpdateTankSniperSteamID(const String:ClientID[])
{
	decl String:query[1024];
	Format(query, sizeof(query), "UPDATE %splayers SET infected_tanksniper = infected_tanksniper + 1 WHERE steamid = '%s'", DbPrefix, ClientID);
	SendSQLUpdate(query);

	UpdateMapStat("infected_tanksniper", 1);
}

// Survivor died.

SurvivorDied(Attacker, Victim, AttackerInfType = -1, Mode = -1)
{
	if (!Attacker || !Victim || StatsGetClientTeam(Attacker) != TEAM_INFECTED || StatsGetClientTeam(Victim) != TEAM_SURVIVORS)
		return;

	decl String:AttackerID[MAX_LINE_WIDTH];
	GetClientRankAuthString(Attacker, AttackerID, sizeof(AttackerID));

	decl String:VictimName[MAX_LINE_WIDTH];
	GetClientName(Victim, VictimName, sizeof(VictimName));

	SurvivorDiedNamed(Attacker, Victim, VictimName, AttackerID, AttackerInfType, Mode);
}

// An Infected player killed a Survivor.

SurvivorDiedNamed(Attacker, Victim, const String:VictimName[], const String:AttackerID[], AttackerInfType = -1, Mode = -1)
{
	if (!Attacker || !Victim || StatsGetClientTeam(Attacker) != TEAM_INFECTED || StatsGetClientTeam(Victim) != TEAM_SURVIVORS)
		return;

//LogError("SurvivorDiedNamed - VictimName = %s", VictimName);

	if (AttackerInfType < 0)
	{
		if (ClientInfectedType[Attacker] == 0)
			SetClientInfectedType(Attacker);

		AttackerInfType = ClientInfectedType[Attacker];
	}

	if (EngineVersion1 == Engine_Left4Dead)
	{
		if (AttackerInfType != INF_ID_SMOKER
				&& AttackerInfType != INF_ID_BOOMER
				&& AttackerInfType != INF_ID_HUNTER
				&& AttackerInfType != INF_ID_TANK_L4D2) // SetClientInfectedType sets tank id to L4D2
			return;
	}
	else
	{
		if (AttackerInfType != INF_ID_SMOKER
				&& AttackerInfType != INF_ID_BOOMER
				&& AttackerInfType != INF_ID_HUNTER
				&& AttackerInfType != INF_ID_SPITTER_L4D2
				&& AttackerInfType != INF_ID_JOCKEY_L4D2
				&& AttackerInfType != INF_ID_CHARGER_L4D2
				&& AttackerInfType != INF_ID_TANK_L4D2)
			return;
	}

	new Score = GetSurvivorKillScore();

	new len = 0;
	decl String:query[1024];

	if (CurrentGamemodeID == GAMEMODE_VERSUS)
		len += Format(query[len], sizeof(query)-len, "UPDATE %splayers SET points_infected = points_infected + %i, versus_kills_survivors = versus_kills_survivors + 1 ", DbPrefix, Score);
	else if (CurrentGamemodeID == GAMEMODE_REALISMVERSUS)
		len += Format(query[len], sizeof(query)-len, "UPDATE %splayers SET points_realism_infected = points_realism_infected + %i, realism_kills_survivors = realism_kills_survivors + 1 ", DbPrefix, Score);
	else if (CurrentGamemodeID == GAMEMODE_SCAVENGE)
		len += Format(query[len], sizeof(query)-len, "UPDATE %splayers SET points_scavenge_infected = points_scavenge_infected + %i, scavenge_kills_survivors = scavenge_kills_survivors + 1 ", DbPrefix, Score);
	else
		len += Format(query[len], sizeof(query)-len, "UPDATE %splayers SET points_mutations = points_mutations + %i, mutations_kills_survivors = mutations_kills_survivors + 1 ", DbPrefix, Score);
	len += Format(query[len], sizeof(query)-len, "WHERE steamid = '%s'", AttackerID);
	SendSQLUpdate(query);

	if (Mode < 0)
		Mode = GetConVarInt(cvar_AnnounceMode);

	if (Mode)
	{
		if (Mode > 2)
		{
			decl String:AttackerName[MAX_LINE_WIDTH];
			GetClientName(Attacker, AttackerName, sizeof(AttackerName));
			StatsPrintToChatAll("\x05%s 杀了 \x05%s \x01获得了 \x04%i \x01分!", AttackerName, VictimName, Score);
		}
		else
			StatsPrintToChat(Attacker, "你杀了 \x05%s \x01获得了 \x04%i \x01分!", VictimName, Score);
	}

	UpdateMapStat("survivor_kills", 1);
	UpdateMapStat("points_infected", Score);
	AddScore(Attacker, Score);
}

// Survivor got hurt.

SurvivorHurt(Attacker, Victim, Damage, AttackerInfType = -1, Handle:event = INVALID_HANDLE)
{
	if (!Attacker || !Victim || Damage <= 0 || Attacker == Victim)
		return;

	if (AttackerInfType < 0)
	{
		new AttackerTeam = GetClientTeam(Attacker);

		if (Attacker > 0 && AttackerTeam == TEAM_INFECTED)
			AttackerInfType = GetInfType(Attacker);
	}

	if (AttackerInfType != INF_ID_SMOKER
			&& AttackerInfType != INF_ID_BOOMER
			&& AttackerInfType != INF_ID_HUNTER
			&& AttackerInfType != INF_ID_SPITTER_L4D2
			&& AttackerInfType != INF_ID_JOCKEY_L4D2
			&& AttackerInfType != INF_ID_CHARGER_L4D2
			&& AttackerInfType != INF_ID_TANK_L4D2)
		return;

	if (TimerInfectedDamageCheck[Attacker] != INVALID_HANDLE)
	{
		CloseHandle(TimerInfectedDamageCheck[Attacker]);
		TimerInfectedDamageCheck[Attacker] = INVALID_HANDLE;
	}

	new VictimHealth = GetClientHealth(Victim);

	if (VictimHealth < 0)
		Damage += VictimHealth;

	if (Damage <= 0)
		return;

	if (AttackerInfType == INF_ID_TANK_L4D2 && event != INVALID_HANDLE)
	{
		InfectedDamageCounter[Attacker] += TankDamage(Attacker, Damage);

		decl String:Weapon[16];
		GetEventString(event, "weapon", Weapon, sizeof(Weapon));

		new RockHit = GetConVarInt(cvar_TankThrowRockSuccess);

		if (RockHit > 0 && strcmp(Weapon, "tank_rock", false) == 0)
		{
			if (CurrentGamemodeID == GAMEMODE_VERSUS)
				UpdatePlayerScore2(Attacker, RockHit, "points_infected");
			else if (CurrentGamemodeID == GAMEMODE_REALISMVERSUS)
				UpdatePlayerScore2(Attacker, RockHit, "points_realism_infected");
			else if (CurrentGamemodeID == GAMEMODE_SCAVENGE)
				UpdatePlayerScore2(Attacker, RockHit, "points_scavenge_infected");
			else
				UpdatePlayerScore2(Attacker, RockHit, "points_mutations");
			UpdateTankSniper(Attacker);

			decl String:VictimName[MAX_LINE_WIDTH];

			if (Victim > 0)
				GetClientName(Victim, VictimName, sizeof(VictimName));
			else
				Format(VictimName, sizeof(VictimName), "UNKNOWN");

			new Mode = GetConVarInt(cvar_AnnounceMode);

			if (Mode == 1 || Mode == 2)
				StatsPrintToChat(Attacker, "你因为丢石头到 \x05%s\x01头上获得 \x04%i \x01分!", VictimName, RockHit);
			else if (Mode == 3)
			{
				decl String:AttackerName[MAX_LINE_WIDTH];
				GetClientName(Attacker, AttackerName, sizeof(AttackerName));
				StatsPrintToChatAll("\x05%s \x01丢石头到\x05%s\x01头上获得 \x04%i \x01分!", AttackerName, VictimName, RockHit);
			}
		}
	}
	else
		InfectedDamageCounter[Attacker] += Damage;

	if (AttackerInfType == INF_ID_SMOKER)
		SmokerDamageCounter[Attacker] += Damage;
	else if (AttackerInfType == INF_ID_SPITTER_L4D2)
		SpitterDamageCounter[Attacker] += Damage;
	else if (AttackerInfType == INF_ID_JOCKEY_L4D2)
		JockeyDamageCounter[Attacker] += Damage;
	else if (AttackerInfType == INF_ID_CHARGER_L4D2)
		ChargerDamageCounter[Attacker] += Damage;

	TimerInfectedDamageCheck[Attacker] = CreateTimer(5.0, timer_InfectedDamageCheck, Attacker);
}

// Survivor was hurt by normal infected while being blinded and/or paralyzed.

SurvivorHurtExternal(Handle:event, Victim)
{
	if (event == INVALID_HANDLE || !Victim)
		return;

	new Damage = GetEventInt(event, "dmg_health");

	new VictimHealth = GetClientHealth(Victim);

	if (VictimHealth < 0)
		Damage += VictimHealth;

	if (Damage <= 0)
		return;

	new Attacker;

	if (PlayerBlinded[Victim][0] && PlayerBlinded[Victim][1])
	{
		Attacker = PlayerBlinded[Victim][1];

		if (Attacker && !IsClientBot(Attacker) && IsClientInGame(Attacker))
			SurvivorHurt(Attacker, Victim, Damage);
	}

	if (PlayerParalyzed[Victim][0] && PlayerParalyzed[Victim][1])
	{
		Attacker = PlayerParalyzed[Victim][1];

		if (Attacker && !IsClientBot(Attacker) && IsClientInGame(Attacker))
			SurvivorHurt(Attacker, Victim, Damage);
	}
	else if (PlayerLunged[Victim][0] && PlayerLunged[Victim][1])
	{
		Attacker = PlayerLunged[Victim][1];

		if (Attacker && !IsClientBot(Attacker) && IsClientInGame(Attacker))
			SurvivorHurt(Attacker, Victim, Damage);
	}
	else if (PlayerPlummeled[Victim][0] && PlayerPlummeled[Victim][1])
	{
		Attacker = PlayerPlummeled[Victim][1];

		if (Attacker && !IsClientBot(Attacker) && IsClientInGame(Attacker))
			SurvivorHurt(Attacker, Victim, Damage);
	}
	else if (PlayerCarried[Victim][0] && PlayerCarried[Victim][1])
	{
		Attacker = PlayerCarried[Victim][1];

		if (Attacker && !IsClientBot(Attacker) && IsClientInGame(Attacker))
			SurvivorHurt(Attacker, Victim, Damage);
	}
	else if (PlayerJockied[Victim][0] && PlayerJockied[Victim][1])
	{
		Attacker = PlayerJockied[Victim][1];

		if (Attacker && !IsClientBot(Attacker) && IsClientInGame(Attacker))
			SurvivorHurt(Attacker, Victim, Damage);
	}
}

PlayerDeathExternal(Victim)
{
	if (!Victim || StatsGetClientTeam(Victim) != TEAM_SURVIVORS)
		return;

	CheckSurvivorsAllDown();

	new Attacker = 0;

	if (PlayerBlinded[Victim][0] && PlayerBlinded[Victim][1])
	{
		Attacker = PlayerBlinded[Victim][1];

		if (Attacker && !IsClientBot(Attacker) && IsClientInGame(Attacker))
			SurvivorDied(Attacker, Victim, INF_ID_BOOMER);
	}

	if (PlayerParalyzed[Victim][0] && PlayerParalyzed[Victim][1])
	{
		Attacker = PlayerParalyzed[Victim][1];

		if (Attacker && !IsClientBot(Attacker) && IsClientInGame(Attacker))
			SurvivorDied(Attacker, Victim, INF_ID_SMOKER);
	}
	else if (PlayerLunged[Victim][0] && PlayerLunged[Victim][1])
	{
		Attacker = PlayerLunged[Victim][1];

		if (Attacker && !IsClientBot(Attacker) && IsClientInGame(Attacker))
			SurvivorDied(Attacker, Victim, INF_ID_HUNTER);
	}
	else if (PlayerJockied[Victim][0] && PlayerJockied[Victim][1])
	{
		Attacker = PlayerJockied[Victim][1];

		if (Attacker && !IsClientBot(Attacker) && IsClientInGame(Attacker))
			SurvivorDied(Attacker, Victim, INF_ID_HUNTER);
	}
	else if (PlayerCarried[Victim][0] && PlayerCarried[Victim][1])
	{
		Attacker = PlayerCarried[Victim][1];

		if (Attacker && !IsClientBot(Attacker) && IsClientInGame(Attacker))
			SurvivorDied(Attacker, Victim, INF_ID_HUNTER);
	}
	else if (PlayerPlummeled[Victim][0] && PlayerPlummeled[Victim][1])
	{
		Attacker = PlayerPlummeled[Victim][1];

		if (Attacker && !IsClientBot(Attacker) && IsClientInGame(Attacker))
			SurvivorDied(Attacker, Victim, INF_ID_HUNTER);
	}
}

PlayerIncapExternal(Victim)
{
	if (!Victim || StatsGetClientTeam(Victim) != TEAM_SURVIVORS)
		return;

	CheckSurvivorsAllDown();

	new Attacker = 0;

	if (PlayerBlinded[Victim][0] && PlayerBlinded[Victim][1])
	{
		Attacker = PlayerBlinded[Victim][1];
		SurvivorIncappedByInfected(Attacker, Victim);
	}

	if (PlayerParalyzed[Victim][0] && PlayerParalyzed[Victim][1])
	{
		Attacker = PlayerParalyzed[Victim][1];
		SurvivorIncappedByInfected(Attacker, Victim);
	}
	else if (PlayerLunged[Victim][0] && PlayerLunged[Victim][1])
	{
		Attacker = PlayerLunged[Victim][1];
		SurvivorIncappedByInfected(Attacker, Victim);
	}
	else if (PlayerPlummeled[Victim][0] && PlayerPlummeled[Victim][1])
	{
		Attacker = PlayerPlummeled[Victim][1];
		SurvivorIncappedByInfected(Attacker, Victim);
	}
	else if (PlayerCarried[Victim][0] && PlayerCarried[Victim][1])
	{
		Attacker = PlayerCarried[Victim][1];
		SurvivorIncappedByInfected(Attacker, Victim);
	}
	else if (PlayerJockied[Victim][0] && PlayerJockied[Victim][1])
	{
		Attacker = PlayerJockied[Victim][1];
		SurvivorIncappedByInfected(Attacker, Victim);
	}
}

SurvivorIncappedByInfected(Attacker, Victim, Mode = -1)
{
	if (Attacker > 0 && !IsClientConnected(Attacker) || Attacker > 0 && IsClientBot(Attacker))
		return;

	decl String:AttackerID[MAX_LINE_WIDTH];
	GetClientRankAuthString(Attacker, AttackerID, sizeof(AttackerID));
	decl String:AttackerName[MAX_LINE_WIDTH];
	GetClientName(Attacker, AttackerName, sizeof(AttackerName));

	decl String:VictimName[MAX_LINE_WIDTH];
	GetClientName(Victim, VictimName, sizeof(VictimName));

	new Score = ModifyScoreDifficultyFloat(GetConVarInt(cvar_SurvivorIncap), 0.75, 0.5, TEAM_INFECTED);

	if (Score <= 0)
		return;

	decl String:query[512];

	if (CurrentGamemodeID == GAMEMODE_VERSUS)
		Format(query, sizeof(query), "UPDATE %splayers SET points_infected = points_infected + %i, award_survivor_down = award_survivor_down + 1 WHERE steamid = '%s'", DbPrefix, Score, AttackerID);
	else if (CurrentGamemodeID == GAMEMODE_REALISMVERSUS)
		Format(query, sizeof(query), "UPDATE %splayers SET points_realism_infected = points_realism_infected + %i, award_survivor_down = award_survivor_down + 1 WHERE steamid = '%s'", DbPrefix, Score, AttackerID);
	else if (CurrentGamemodeID == GAMEMODE_SCAVENGE)
		Format(query, sizeof(query), "UPDATE %splayers SET points_scavenge_infected = points_scavenge_infected + %i, award_survivor_down = award_survivor_down + 1 WHERE steamid = '%s'", DbPrefix, Score, AttackerID);
	else
		Format(query, sizeof(query), "UPDATE %splayers SET points_mutations = points_mutations + %i, award_survivor_down = award_survivor_down + 1 WHERE steamid = '%s'", DbPrefix, Score, AttackerID);
	SendSQLUpdate(query);

	UpdateMapStat("points_infected", Score);

	if (Mode < 0)
		Mode = GetConVarInt(cvar_AnnounceMode);

	if (Mode == 1 || Mode == 2)
		StatsPrintToChat(Attacker, "你制伏 \x05%s \x01获得 \x04%i \x01分!", VictimName, Score);
	else if (Mode == 3)
		StatsPrintToChatAll("\x05%s 制伏 \x05%s \x01获得 \x04%i \x01分!", AttackerName, VictimName, Score);
}

Float:GetMedkitPointReductionFactor()
{
	if (MedkitsUsedCounter <= 0)
		return 1.0;

	new Float:Penalty = GetConVarFloat(cvar_MedkitUsedPointPenalty);

	// If Penalty is set to ZERO: There is no reduction.
	if (Penalty <= 0.0)
		return 1.0;

	new PenaltyFree = -1;

	if (CurrentGamemodeID == GAMEMODE_REALISM || CurrentGamemodeID == GAMEMODE_REALISMVERSUS)
		PenaltyFree = GetConVarInt(cvar_MedkitUsedRealismFree);

	if (PenaltyFree < 0)
		PenaltyFree = GetConVarInt(cvar_MedkitUsedFree);

	if (PenaltyFree >= MedkitsUsedCounter)
		return 1.0;

	Penalty *= MedkitsUsedCounter - PenaltyFree;

	new Float:PenaltyMax = GetConVarFloat(cvar_MedkitUsedPointPenaltyMax);

	if (Penalty > PenaltyMax)
		return 1.0 - PenaltyMax;

	return 1.0 - Penalty;
}

// Calculate the score with the medkit point reduction

GetMedkitPointReductionScore(Score, bool:ToCeil = false)
{
	new Float:ReductionFactor = GetMedkitPointReductionFactor();

	if (ReductionFactor == 1.0)
		return Score;

	if (ToCeil)
		return RoundToCeil(Score * ReductionFactor);
	else
		return RoundToFloor(Score * ReductionFactor);
}

AnnounceMedkitPenalty(Mode = -1)
{
	new Float:ReductionFactor = GetMedkitPointReductionFactor();

	if (ReductionFactor == 1.0)
		return;

	if (Mode < 0)
		Mode = GetConVarInt(cvar_AnnounceMode);

	if (Mode)
		StatsPrintToChatTeam(TEAM_SURVIVORS, "\x03所有幸存者 \x01现在只能获得正常分数的百分之 \x04%i \x01，因为用了他们的第 \x05%i 个医疗包%s\x01!", RoundToNearest(ReductionFactor * 100), MedkitsUsedCounter,  (EngineVersion1 == Engine_Left4Dead ? "" : "或电击器"));
}

GetClientInfectedType(Client)
{
	if (Client > 0 && GetClientTeam(Client) == TEAM_INFECTED)
		return GetInfType(Client);

	return 0;
}

InitializeClientInf(Client)
{
	for (new i = 1; i <= MAXPLAYERS; i++)
	{
		if (PlayerParalyzed[i][1] == Client)
		{
			PlayerParalyzed[i][0] = 0;
			PlayerParalyzed[i][1] = 0;
		}
		if (PlayerLunged[i][1] == Client)
		{
			PlayerLunged[i][0] = 0;
			PlayerLunged[i][1] = 0;
		}
		if (PlayerCarried[i][1] == Client)
		{
			PlayerCarried[i][0] = 0;
			PlayerCarried[i][1] = 0;
		}
		if (PlayerPlummeled[i][1] == Client)
		{
			PlayerPlummeled[i][0] = 0;
			PlayerPlummeled[i][1] = 0;
		}
		if (PlayerJockied[i][1] == Client)
		{
			PlayerJockied[i][0] = 0;
			PlayerJockied[i][1] = 0;
		}
	}
}

// Print a chat message to a specific team instead of all players

public StatsPrintToChatTeam(Team, const String:Message[], any:...)
{
	new String:FormattedMessage[MAX_MESSAGE_WIDTH];
	VFormat(FormattedMessage, sizeof(FormattedMessage), Message, 3);

	new AnnounceToTeam = GetConVarInt(cvar_AnnounceToTeam);

	if (Team > 0 && AnnounceToTeam)
	{
		new maxplayers = MaxClients;
		new ClientTeam;

		for (new i = 1; i <= maxplayers; i++)
		{
			if (IsClientConnected(i) && IsClientInGame(i) && !IsClientBot(i))
			{
				ClientTeam = GetClientTeam(i);
				if (ClientTeam == Team || (ClientTeam == TEAM_SPECTATORS && AnnounceToTeam == 2))
				{
					StatsPrintToChatPreFormatted(i, FormattedMessage);
				}
			}
		}
	}
	else
		StatsPrintToChatAllPreFormatted(FormattedMessage);
}

// Debugging...
/*
public PrintToConsoleAll(const String:Message[], any:...)
{
	new String:FormattedMessage[MAX_MESSAGE_WIDTH];
	VFormat(FormattedMessage, sizeof(FormattedMessage), Message, 2);

	PrintToConsole(0, FormattedMessage);

	new maxplayers = MaxClients;

	for (new i = 1; i <= maxplayers; i++)
		if (IsClientConnected(i) && IsClientInGame(i) && !IsClientBot(i))
			PrintToConsole(i, FormattedMessage);
}*/

// Disable map timings when opposing team has human players. The time is too much depending on opposing team that is is comparable.

MapTimingEnabled()
{
	return MapTimingBlocked || CurrentGamemodeID == GAMEMODE_COOP || CurrentGamemodeID == GAMEMODE_SURVIVAL || CurrentGamemodeID == GAMEMODE_REALISM || CurrentGamemodeID == GAMEMODE_OTHERMUTATIONS;
}

public StartMapTiming()
{
	if (!MapTimingEnabled() || MapTimingStartTime != 0.0 || StatsDisabled())
	{
		return;
	}

	MapTimingStartTime = GetEngineTime();

	new ClientTeam, maxplayers = MaxClients;
	decl String:ClientID[MAX_LINE_WIDTH];

	ClearTrie(MapTimingSurvivors);
	ClearTrie(MapTimingInfected);

	new bool:SoundsEnabled = EnableSounds_Maptime_Start && GetConVarBool(cvar_SoundsEnabled);

	for (new i = 1; i <= maxplayers; i++)
	{
		if (IsClientConnected(i) && IsClientInGame(i) && !IsClientBot(i))
		{
			ClientTeam = GetClientTeam(i);

			if (ClientTeam == TEAM_SURVIVORS)
			{
				GetClientRankAuthString(i, ClientID, sizeof(ClientID));
				SetTrieValue(MapTimingSurvivors, ClientID, 1, true);

				if (SoundsEnabled)
					EmitSoundToClient(i, StatsSound_MapTime_Start);
			}
			else if (ClientTeam == TEAM_INFECTED)
			{
				GetClientRankAuthString(i, ClientID, sizeof(ClientID));
				SetTrieValue(MapTimingInfected, ClientID, 1, true);
			}
		}
	}
}

GetCurrentDifficulty()
{
	decl String:Difficulty[MAX_LINE_WIDTH];
	GetConVarString(cvar_Difficulty, Difficulty, sizeof(Difficulty));

	if (StrEqual(Difficulty, "normal", false)) return 1;
	else if (StrEqual(Difficulty, "hard", false)) return 2;
	else if (StrEqual(Difficulty, "impossible", false)) return 3;
	else return 0;
}

public bool StopMapTiming()
{
	if (!MapTimingEnabled() || MapTimingStartTime <= 0.0 || StatsDisabled())
	{
		return false;
	}
	if(g_brpgAvailable && !L4D_RPG_GetGlobalValue(INDEX_VALID))
	{
		if (GetConVarInt(cvar_AnnounceMode))
		{
			StatsPrintToChatAll("此次结果因修改难度或开启高级人机或使用管理员功能导致 \x04无效 \x01，不记录这张地图游戏时间!");
		}
		MapTimingStartTime = -1.0;
		MapTimingBlocked = true;
		return false;
	}
	if(!IsNormalMode() && !IsThisRoundValid())
	{
		if (GetConVarInt(cvar_AnnounceMode))
		{
			StatsPrintToChatAll("此次结果因关闭tank连跳导致 \x04无效 \x01，不记录这张地图游戏时间!");
		}
		MapTimingStartTime = -1.0;
		MapTimingBlocked = true;
		return false;
	}
	int mode = 0;
	if(IsWitchParty())
	{
		mode = 2;
	}else if(IsAllCharger())
	{
		mode = 3;
	}else if(IsAlone())
	{
		mode = 4;
	}else if(Is1vht())
	{
		mode = 5;
	}else if(IsAnne() == 1)
	{
		mode = 1;
	}else if(IsAnne() == 2)
	{
		mode = 6;
	}
	ConVar multiplayer = FindConVar("l4d_multislots_survivors_manager_enable");
	if(mode > 0 && (multiplayer == null || multiplayer.IntValue == 1 || GetConVarInt(cvar_SurvivorLimit) > 4))
	{
		StatsPrintToChatAll("启用了多人运动模式，不记录这张地图游戏时间!");
		MapTimingStartTime = -1.0;
		MapTimingBlocked = true;
		return false;
	}

	new Float:TotalTime = GetEngineTime() - MapTimingStartTime;
	if(TotalTime < 30.0)
	{
		StatsPrintToChatAll("记录时间小于30s，数据应该不对，没有分数奖励!(PS: 30s能完成的图算啥图)");
		return false;
	}

	MapTimingStartTime = -1.0;
	MapTimingBlocked = true;

	new Handle:dp = INVALID_HANDLE;
	new ClientTeam, enabled, maxplayers = MaxClients;
	decl String:ClientID[MAX_LINE_WIDTH], String:MapName[MAX_LINE_WIDTH], String:query[512];

	GetCurrentMap(MapName, sizeof(MapName));

	new i, PlayerCounter = 0, InfectedCounter = (CurrentGamemodeID == GAMEMODE_VERSUS || CurrentGamemodeID == GAMEMODE_SCAVENGE ? 0 : 1);

	for (i = 1; i <= maxplayers; i++)
	{
		if (IsClientConnected(i) && IsClientInGame(i) && !IsClientBot(i))
		{
			ClientTeam = GetClientTeam(i);
			GetClientRankAuthString(i, ClientID, sizeof(ClientID));

			if (ClientTeam == TEAM_SURVIVORS && GetTrieValue(MapTimingSurvivors, ClientID, enabled))
			{
				if (enabled)
					PlayerCounter++;
			}
			else if (IsNormalMode() && ClientTeam == TEAM_INFECTED)
			{
				InfectedCounter++;
				if (GetTrieValue(MapTimingInfected, ClientID, enabled))
				{
					if (enabled)
						PlayerCounter++;
				}
			}
		}
	}

	// Game ended because all of the infected team left the server... don't record the time!
	//if (InfectedCounter <= 0)
		//return;

	new GameDifficulty = GetCurrentDifficulty();
	if(mode > 0)
		GetThisModeBestTime(g_brpgAvailable && L4D_RPG_GetGlobalValue(INDEX_USEBUY));	
	for (i = 1; i <= maxplayers; i++)
	{
		if (IsClientConnected(i) && IsClientInGame(i) && !IsClientBot(i))
		{
			ClientTeam = GetClientTeam(i);

			if (ClientTeam == TEAM_SURVIVORS)
			{
				GetClientRankAuthString(i, ClientID, sizeof(ClientID));

				if (GetTrieValue(MapTimingSurvivors, ClientID, enabled))
				{
					if (enabled)
					{
						dp = CreateDataPack();

						WritePackString(dp, MapName);
						WritePackCell(dp, CurrentGamemodeID);
						WritePackString(dp, ClientID);
						WritePackFloat(dp, TotalTime);
						WritePackCell(dp, i);
						if(mode > 0)
							PlayerCounter = GetConVarInt(cvar_SurvivorLimit);
						WritePackCell(dp, PlayerCounter);
						WritePackCell(dp, GameDifficulty);
						WritePackString(dp, CurrentMutation);

						if(mode > 0)
						{
							Format(query, sizeof(query), "SELECT time FROM %stimedmaps WHERE map = '%s' AND gamemode = %i AND difficulty = %i AND mutation = '%s' AND steamid = '%s' AND sinum = %i AND sitime = %i AND anneversion = '%s' AND mode = %i AND usebuy = %i AND auto = %i AND players = %i", DbPrefix, MapName, CurrentGamemodeID, GameDifficulty, CurrentMutation, ClientID, GetAnneInfectedNumber(), GetAnneSISpawnTime(), GetAnneVersion(), mode, g_brpgAvailable && L4D_RPG_GetGlobalValue(INDEX_USEBUY), IsAutoSpawnTime(), PlayerCounter);
						}
						else
						{
							Format(query, sizeof(query), "SELECT time FROM %stimedmaps WHERE map = '%s' AND gamemode = %i AND difficulty = %i AND mutation = '%s' AND steamid = '%s' AND mode = %i", DbPrefix, MapName, CurrentGamemodeID, GameDifficulty, CurrentMutation, ClientID, mode);
						}
						SQL_TQuery(db, UpdateMapTimingStat, query, dp);
					}
				}
 			}
		}
	}

	ClearTrie(MapTimingSurvivors);
	return true;
}

GetThisModeBestTime(int UseBuy=0)
{

	decl String:MapName[MAX_LINE_WIDTH], String:query[512];

	GetCurrentMap(MapName, sizeof(MapName));

	new GameDifficulty = GetCurrentDifficulty();
	int mode = 1;
	if(IsWitchParty())
	{
		mode = 2;
	}else if(IsAllCharger())
	{
		mode = 3;
	}else if(IsAlone())
	{
		mode = 4;
	}else if(Is1vht())
	{
		mode = 5;
	}else if(IsAnne() == 1)
	{
		mode = 1;
	}else if(IsAnne() == 2)
	{
		mode = 6;
	}
	Format(query, sizeof(query), "SELECT time FROM %stimedmaps WHERE map = '%s' AND gamemode = %i AND difficulty = %i AND mutation = '%s'  AND sinum = %i AND sitime = %i AND anneversion = '%s' AND mode = %i AND usebuy = %i AND auto = %i AND players = %i ORDER BY time LIMIT 1",\
	 		DbPrefix, MapName, CurrentGamemodeID, GameDifficulty, CurrentMutation, GetAnneInfectedNumber(), GetAnneSISpawnTime(),\
			GetAnneVersion(), mode, UseBuy, IsAutoSpawnTime(), GetConVarInt(cvar_SurvivorLimit));
	LogMessage("GetFastTimequery: %s", query);
	SQL_TQuery(db, GetFastTime, query);
}

public GetFastTime(Handle:owner, Handle:hndl, const String:error[], any:dp)
{
	new Mode = GetConVarInt(cvar_AnnounceMode);
	if (SQL_GetRowCount(hndl) > 0)
	{
		SQL_FetchRow(hndl);
		FastestTime = SQL_FetchFloat(hndl, 0);
		char TimeLabel[32];
		SetTimeLabel(FastestTime, TimeLabel, sizeof(TimeLabel));
		if (Mode)
		{
			StatsPrintToChatAll("当前模式该难度\x04 [%s使用B数] \x01最快通关速度为\x04 %s \x01." , (g_brpgAvailable && L4D_RPG_GetGlobalValue(INDEX_USEBUY))?"":"不", TimeLabel);
		}
	}
	else{
		if (Mode)
		{
			StatsPrintToChatAll("你来到无人的荒野，当前模式该难度没有最快纪录，快来挑战一下吧");
		}
	}
}


public UpdateMapTimingStat(Handle:owner, Handle:hndl, const String:error[], any:dp)
{
	int mode = 0;
	if(IsWitchParty())
	{
		mode = 2;
	}else if(IsAllCharger())
	{
		mode = 3;
	}else if(IsAlone())
	{
		mode = 4;
	}else if(Is1vht())
	{
		mode = 5;
	}else if(IsAnne() == 1)
	{
		mode = 1;
	}else if(IsAnne() == 2)
	{
		mode = 6;
	}
	ResetPack(dp);

	decl String:MapName[MAX_LINE_WIDTH], String:ClientID[MAX_LINE_WIDTH], String:query[512], String:TimeLabel[32], String:Mutation[MAX_LINE_WIDTH];
	new GamemodeID, Float:TotalTime, Float:OldTime, Client, PlayerCounter, GameDifficulty;
	ReadPackString(dp, MapName, sizeof(MapName));
	GamemodeID = ReadPackCell(dp);
	ReadPackString(dp, ClientID, sizeof(ClientID));
	TotalTime = ReadPackFloat(dp);
	Client = ReadPackCell(dp);
	PlayerCounter = ReadPackCell(dp);
	GameDifficulty = ReadPackCell(dp);
	ReadPackString(dp, Mutation, sizeof(Mutation));

	CloseHandle(dp);

	// Return if client is not a human player
	if (IsClientBot(Client) || !IsClientInGame(Client))
		return;

	new Mode = GetConVarInt(cvar_AnnounceMode);

	if (SQL_GetRowCount(hndl) > 0)
	{
		SQL_FetchRow(hndl);
		OldTime = SQL_FetchFloat(hndl, 0);
		if(TotalTime < 30.0)
		{
			StatsPrintToChat(Client, "记录时间小于30s，数据应该不对，此次记录不进行记录!");
			return;
		}

		if ((CurrentGamemodeID != GAMEMODE_SURVIVAL && OldTime <= TotalTime) || (CurrentGamemodeID == GAMEMODE_SURVIVAL && OldTime >= TotalTime))
		{
			if (Mode)
			{
				SetTimeLabel(OldTime, TimeLabel, sizeof(TimeLabel));
				if(mode > 0)
				{
					StatsPrintToChat(Client, "下次继续努力哦，这张图 \x04Anne%s \x01版本该难度的最快完成时间 \x04%s \x01 并没有提升!", GetAnneVersion(), TimeLabel);
				}
				else
				{
					StatsPrintToChat(Client, "下次继续努力哦，这张图最快完成时间 \x04%s \x01 并没有提升!", TimeLabel);
				}
			}
			if(mode > 0)
			{
				Format(query, sizeof(query), "UPDATE %stimedmaps SET plays = plays + 1, modified = NOW() WHERE map = '%s' AND gamemode = %i AND difficulty = %i AND mutation = '%s' AND steamid = '%s' AND sinum = %i AND sitime = %i AND anneversion = '%s' AND mode = %i AND usebuy = %i AND auto = %i", DbPrefix, MapName, GamemodeID, GameDifficulty, Mutation, ClientID, GetAnneInfectedNumber(), GetAnneSISpawnTime(), GetAnneVersion(), mode, g_brpgAvailable && L4D_RPG_GetGlobalValue(INDEX_USEBUY), IsAutoSpawnTime());
			}
			else
			{
				Format(query, sizeof(query), "UPDATE %stimedmaps SET plays = plays + 1, modified = NOW() WHERE map = '%s' AND gamemode = %i AND difficulty = %i AND mutation = '%s' AND steamid = '%s' AND mode = %i", DbPrefix, MapName, GamemodeID, GameDifficulty, Mutation, ClientID, mode);
			}
		}
		else
		{
			if (Mode)
			{
				SetTimeLabel(TotalTime, TimeLabel, sizeof(TimeLabel));
				StatsPrintToChat(Client, "牛逼，你刷新了%s这张图 \x04Anne%s \x01版本该难度的最快完成时间，目前是 \x04%s\x01!", FastestTime < TotalTime?"目前":"你", GetAnneVersion(), TimeLabel);

			}

			if(mode > 0)
			{
				Format(query, sizeof(query), "UPDATE %stimedmaps SET plays = plays + 1, time = %f, players = %i, modified = NOW() WHERE map = '%s' AND gamemode = %i AND difficulty = %i AND mutation = '%s' AND steamid = '%s' AND sinum = %i AND sitime = %i AND anneversion = '%s' AND mode = %i AND usebuy = %i AND auto = %i", DbPrefix, TotalTime, PlayerCounter, MapName, GamemodeID, GameDifficulty, Mutation, ClientID, GetAnneInfectedNumber(), GetAnneSISpawnTime(), GetAnneVersion(), mode, g_brpgAvailable && L4D_RPG_GetGlobalValue(INDEX_USEBUY), IsAutoSpawnTime());
			}
			else
			{
				Format(query, sizeof(query), "UPDATE %stimedmaps SET plays = plays + 1, time = %f, players = %i, modified = NOW() WHERE map = '%s' AND gamemode = %i AND difficulty = %i AND mutation = '%s' AND steamid = '%s' AND mode = %i", DbPrefix, TotalTime, PlayerCounter, MapName, GamemodeID, GameDifficulty, Mutation, ClientID, mode);
			}
			
			if (EnableSounds_Maptime_Improve && GetConVarBool(cvar_SoundsEnabled))
				EmitSoundToClient(Client, StatsSound_MapTime_Improve);
		}
	}
	else
	{
		if (Mode)
		{
			SetTimeLabel(TotalTime, TimeLabel, sizeof(TimeLabel));
			StatsPrintToChat(Client, "你花费了 \x04%s \x01来完成这张地图!", TimeLabel);
		}

		if(mode > 0)
		{
			Format(query, sizeof(query), "INSERT INTO %stimedmaps (map, gamemode, difficulty, mutation, steamid, plays, time, players, sinum, sitime, anneversion, mode, usebuy, auto, modified, created) VALUES ('%s', %i, %i, '%s', '%s', 1, %f, %i, %i, %i, '%s', %i, %i, %i, NOW(), NOW())", DbPrefix, MapName, GamemodeID, GameDifficulty, Mutation, ClientID, TotalTime, PlayerCounter, GetAnneInfectedNumber(), GetAnneSISpawnTime(), GetAnneVersion(), mode, g_brpgAvailable && L4D_RPG_GetGlobalValue(INDEX_USEBUY), IsAutoSpawnTime());
		}
		else
		{
			Format(query, sizeof(query), "INSERT INTO %stimedmaps (map, gamemode, difficulty, mutation, steamid, plays, time, players, mode, modified, created) VALUES ('%s', %i, %i, '%s', '%s', 1, %f, %i, %i, NOW(), NOW())", DbPrefix, MapName, GamemodeID, GameDifficulty, Mutation, ClientID, TotalTime, PlayerCounter, mode);
		}
	}

	FastestTime = -1.0;

	SendSQLUpdate(query);
}

public SetTimeLabel(Float:TheSeconds, String:TimeLabel[], maxsize)
{
	new FlooredSeconds = RoundToFloor(TheSeconds);
	new FlooredSecondsMod = FlooredSeconds % 60;
	new Float:Seconds = TheSeconds - float(FlooredSeconds) + float(FlooredSecondsMod);
	new Minutes = (TheSeconds < 60.0 ? 0 : RoundToNearest(float(FlooredSeconds - FlooredSecondsMod) / 60));
	new MinutesMod = Minutes % 60;
	new Hours = (Minutes < 60 ? 0 : RoundToNearest(float(Minutes - MinutesMod) / 60));
	Minutes = MinutesMod;

	if (Hours > 0)
		Format(TimeLabel, maxsize, "%i小时 %i分钟 %.1f秒", Hours, Minutes, Seconds);
	else if (Minutes > 0)
		Format(TimeLabel, maxsize, "%i 分钟 %.1f 秒", Minutes, Seconds);
	else
		Format(TimeLabel, maxsize, "%.1f 秒", Seconds);
}

public DisplayRankVote(client)
{
	DisplayYesNoPanel(client, RANKVOTE_QUESTION, RankVotePanelHandler, RoundToNearest(GetConVarFloat(cvar_RankVoteTime)));
}

// Initialize RANKVOTE
public InitializeRankVote(client)
{
	if (StatsDisabled())
	{
		if (client == 0)
		{
			PrintToConsole(0, "[RANK] Cannot initiate vote when the plugin is disabled!");
		}
		else
		{
			StatsPrintToChatPreFormatted2(client, true, "Cannot initiate vote when the plugin is disabled!");
		}

		return;
	}

	// No TEAM gamemodes are allowed
	if (!IsTeamGamemode())
	{
		if (client == 0)
		{
			PrintToConsole(0, "[RANK] The Rank Vote is not enabled in this gamemode!");
		}
		else
		{
			if (EngineVersion1 == Engine_Left4Dead)
			{
				StatsPrintToChatPreFormatted2(client, true, "The \x04Rank Vote \x01is enabled in \x03Versus \x01gamemode!");
			}
			else
			{
				StatsPrintToChatPreFormatted2(client, true, "The \x04Rank Vote \x01is enabled in \x03Versus\x01, \x03Realism Versus \x01and \x03Scavenge \x01gamemodes!");
			}
		}

		return;
	}

	if (RankVoteTimer != INVALID_HANDLE)
	{
		if (client > 0)
		{
			DisplayRankVote(client);
		}
		else
		{
			PrintToConsole(client, "[RANK] The Rank Vote is already initiated!");
		}

		return;
	}

	new bool:IsAdmin = (client > 0 ? ((GetUserFlagBits(client) & ADMFLAG_GENERIC) == ADMFLAG_GENERIC) : true);

	new team;
	decl String:ClientID[MAX_LINE_WIDTH];

	if (!IsAdmin && client > 0 && GetTrieValue(PlayerRankVoteTrie, ClientID, team))
	{
		StatsPrintToChatPreFormatted2(client, true, "You can initiate a \x04Rank Vote \x01only once per map!");
		return;
	}

	if (!IsAdmin && client > 0)
	{
		GetClientRankAuthString(client, ClientID, sizeof(ClientID));
		SetTrieValue(PlayerRankVoteTrie, ClientID, 1, true);
	}

	RankVoteTimer = CreateTimer(GetConVarFloat(cvar_RankVoteTime), timer_RankVote);

	new i;

	for (i = 0; i <= MAXPLAYERS; i++)
	{
		PlayerRankVote[i] = RANKVOTE_NOVOTE;
	}

	new maxplayers = MaxClients;

	for (i = 1; i <= maxplayers; i++)
	{
		if (IsClientConnected(i) && IsClientInGame(i) && !IsClientBot(i))
		{
			team = GetClientTeam(i);

			if (team == TEAM_SURVIVORS || team == TEAM_INFECTED)
			{
				DisplayRankVote(i);
			}
		}
	}

	if (client > 0)
	{
		decl String:UserName[MAX_LINE_WIDTH];
		GetClientName(client, UserName, sizeof(UserName));

		StatsPrintToChatAll2(true, "The \x04Rank Vote \x01was initiated by \x05%s\x01!", UserName);
	}
	else
	{
		StatsPrintToChatAllPreFormatted2(true, "The \x04Rank Vote \x01was initiated from Server Console!");
	}
}

/*
	From plugin:
		name = "L4D2 Score/Team Manager",
		author = "Downtown1 & AtomicStryker",
		description = "Manage teams and scores in L4D2",
		version = 1.1.2,
		url = "http://forums.alliedmods.net/showthread.php?p=1029519"
*/

stock bool:ChangeRankPlayerTeam(client, team)
{
	if(GetClientTeam(client) == team) return true;

	if(team != TEAM_SURVIVORS)
	{
		//we can always swap to infected or spectator, it has no actual limit
		ChangeClientTeam(client, team);
		return true;
	}

	if(GetRankTeamHumanCount(team) == GetRankTeamMaxHumans(team))
		return false;

	new bot;
	//for survivors its more tricky
	for (bot = 1; bot < MaxClients + 1 && (!IsClientConnected(bot) || !IsFakeClient(bot) || (GetClientTeam(bot) != TEAM_SURVIVORS)); bot++) {}

	if (bot == MaxClients + 1)
	{
		new String:command[] = "sb_add";
		new flags = GetCommandFlags(command);
		SetCommandFlags(command, flags & ~FCVAR_CHEAT);

		ServerCommand("sb_add");

		SetCommandFlags(command, flags);

		return false;
	}

	//have to do this to give control of a survivor bot
	SDKCall(L4DStatsSHS, bot, client);
	SDKCall(L4DStatsTOB, client, true);

	return true;
}

/*
	From plugin:
		name = "L4D2 Score/Team Manager",
		author = "Downtown1 & AtomicStryker",
		description = "Manage teams and scores in L4D2",
		version = 1.1.2,
		url = "http://forums.alliedmods.net/showthread.php?p=1029519"
*/

stock bool:IsRankClientInGameHuman(client)
{
	if (client > 0) return IsClientInGame(client) && !IsFakeClient(client);
	else return false;
}

/*
	From plugin:
		name = "L4D2 Score/Team Manager",
		author = "Downtown1 & AtomicStryker",
		description = "Manage teams and scores in L4D2",
		version = 1.1.2,
		url = "http://forums.alliedmods.net/showthread.php?p=1029519"
*/

stock GetRankTeamHumanCount(team)
{
	new humans = 0;
	
	for(new i = 1; i < MaxClients + 1; i++)
	{
		if(IsRankClientInGameHuman(i) && GetClientTeam(i) == team)
		{
			humans++;
		}
	}
	
	return humans;
}

stock GetRankTeamMaxHumans(team)
{
	switch (team)
	{
		case TEAM_SURVIVORS:
			return GetConVarInt(cvar_SurvivorLimit);
		case TEAM_INFECTED:
			return GetConVarInt(cvar_InfectedLimit);
		case TEAM_SPECTATORS:
			return MaxClients;
	}
	
	return -1;
}

GetClientRankAuthString(client, String:auth[], maxlength)
{
	if (GetConVarInt(cvar_Lan))
	{
		GetClientAuthId(client,AuthId_Engine, auth, maxlength);

		if (!StrEqual(auth, "BOT", false))
		{
			GetClientIP(client, auth, maxlength);
		}
	}
	else
	{
		GetClientAuthId(client, AuthId_Engine,auth, maxlength);

		if (StrEqual(auth, "STEAM_ID_LAN", false))
		{
			GetClientIP(client, auth, maxlength);
		}
	}
}

public StatsPrintToChatAll(const String:Message[], any:...)
{
	new String:FormattedMessage[MAX_MESSAGE_WIDTH];
	VFormat(FormattedMessage, sizeof(FormattedMessage), Message, 2);

	StatsPrintToChatAllPreFormatted(FormattedMessage);
}

public StatsPrintToChatAll2(bool:Forced, const String:Message[], any:...)
{
	new String:FormattedMessage[MAX_MESSAGE_WIDTH];
	VFormat(FormattedMessage, sizeof(FormattedMessage), Message, 2);

	StatsPrintToChatAllPreFormatted2(Forced, FormattedMessage);
}

public StatsPrintToChatAllPreFormatted(const String:Message[])
{
	new maxplayers = MaxClients;

	for (new i = 1; i <= maxplayers; i++)
	{
		if (IsClientConnected(i) && IsClientInGame(i) && !IsClientBot(i))
		{
			StatsPrintToChatPreFormatted(i, Message);
		}
	}
}

public StatsPrintToChatAllPreFormatted2(bool:Forced, const String:Message[])
{
	new maxplayers = MaxClients;

	for (new i = 1; i <= maxplayers; i++)
	{
		if (IsClientConnected(i) && IsClientInGame(i) && !IsClientBot(i))
		{
			StatsPrintToChatPreFormatted2(i, Forced, Message);
		}
	}
}

public StatsPrintToChat(Client, const String:Message[], any:...)
{
	// CHECK IF CLIENT HAS MUTED THE PLUGIN
	if (ClientRankMute[Client])
	{
		return;
	}

	new String:FormattedMessage[MAX_MESSAGE_WIDTH];
	VFormat(FormattedMessage, sizeof(FormattedMessage), Message, 3);

	StatsPrintToChatPreFormatted(Client, FormattedMessage);
}

public StatsPrintToChat2(Client, bool:Forced, const String:Message[], any:...)
{
	// CHECK IF CLIENT HAS MUTED THE PLUGIN
	if (!Forced && ClientRankMute[Client])
	{
		return;
	}

	new String:FormattedMessage[MAX_MESSAGE_WIDTH];
	VFormat(FormattedMessage, sizeof(FormattedMessage), Message, 4);

	StatsPrintToChatPreFormatted2(Client, Forced, FormattedMessage);
}

public StatsPrintToChatPreFormatted(Client, const String:Message[])
{
	StatsPrintToChatPreFormatted2(Client, false, Message);
}

public StatsPrintToChatPreFormatted2(Client, bool:Forced, const String:Message[])
{
	// CHECK IF CLIENT HAS MUTED THE PLUGIN
	if (!Forced && ClientRankMute[Client])
	{
		return;
	}

	PrintToChat(Client, "\x04[\x03RANK\x04] \x01%s", Message);
}

stock StatsGetClientTeam(client)
{
	if (client <= 0 || !IsClientConnected(client))
	{
		return TEAM_UNDEFINED;
	}

	if (IsFakeClient(client) || IsClientInGame(client))
	{
		return GetClientTeam(client);
	}

	return TEAM_UNDEFINED;
}

bool:UpdateServerSettings(Client, const String:Key[], const String:Value[], const String:Desc[])
{
	new Handle:statement = INVALID_HANDLE;
	decl String:error[1024], String:query[2048];

	// Add a row if it does not previously exist
	if (!DoFastQuery(Client, "INSERT IGNORE INTO %sserver_settings SET sname = '%s', svalue = ''", DbPrefix, Key))
	{
		PrintToConsole(Client, "[RANK] %s: Setting a new MOTD value failure!", Desc);
		return false;
	}

	Format(query, sizeof(query), "UPDATE %sserver_settings SET svalue = ? WHERE sname = '%s'", DbPrefix, Key);

	statement = SQL_PrepareQuery(db, query, error, sizeof(error));

	if (statement == INVALID_HANDLE)
	{
		PrintToConsole(Client, "[RANK] %s: Update failed! (Reason: Cannot create SQL statement)");
		return false;
	}

	new bool:retval = true;
	SQL_BindParamString(statement, 0, Value, false);

	if (!SQL_Execute(statement))
	{
		if (SQL_GetError(db, error, sizeof(error)))
		{
			PrintToConsole(Client, "[RANK] %s: Update failed! (Error = \"%s\")", Desc, error);
			LogError("%s: Update failed! (Error = \"%s\")", Desc, error);
		}
		else
		{
			PrintToConsole(Client, "[RANK] %s: Update failed!", Desc);
			LogError("%s: Update failed!", Desc);
		}
		
		retval = false;
	}
	else
	{
		PrintToConsole(Client, "[RANK] %s: Update successful!", Desc);

		if (StrEqual(Key, "motdmessage", false))
		{
			strcopy(MessageOfTheDay, sizeof(MessageOfTheDay), Value);
			ShowMOTDAll();
		}
	}

	CloseHandle(statement);
	
	return retval;
}

ShowMOTDAll()
{
	new maxplayers = MaxClients;

	for (new i = 1; i <= maxplayers; i++)
	{
		if (IsClientConnected(i) && IsClientInGame(i) && !IsClientBot(i))
		{
			ShowMOTD(i);
		}
	}
}

ShowMOTD(client, bool:forced=false)
{
	if (!forced && !GetConVarBool(cvar_AnnounceMotd))
	{
		return;
	}

	StatsPrintToChat2(client, forced, "\x05%s: \x01%s", MOTD_TITLE, MessageOfTheDay);
}

AnnouncePlayerConnect(client)
{
	if (!GetConVarBool(cvar_AnnouncePlayerJoined))
	{
		return;
	}

	DoShowPlayerJoined(client);
}

ReadDb()
{
	ReadDbMotd();
}

ReadDbMotd()
{
	decl String:query[512];
	Format(query, sizeof(query), "SELECT svalue FROM %sserver_settings WHERE sname = 'motdmessage' LIMIT 1", DbPrefix);
	SQL_TQuery(db, ReadDbMotdCallback, query);
}

public ReadDbMotdCallback(Handle:owner, Handle:hndl, const String:error[], any:data)
{
	if (hndl == INVALID_HANDLE)
	{
		LogError("ReadDbMotdCallback Query failed: %s", error);
		return;
	}

	if (SQL_FetchRow(hndl))
	{
		SQL_FetchString(hndl, 0, MessageOfTheDay, sizeof(MessageOfTheDay));
	}
}

stock bool IsGaoJiRenJiEnabled()
{
	ConVar gjrj = FindConVar("sb_fix_enabled");
	if(gjrj == null)
	{
		return false;
	}
	else if(gjrj.BoolValue)
	{
		return true;
	}
	return false;
}

stock bool IsNormalMode()
{
	ConVar cvar = FindConVar("l4d_infected_limit");
	if(cvar == null) return true;
	return false;
}

stock int IsAutoSpawnTime()
{
	ConVar cvar = FindConVar("inf_EnableAutoSpawnTime");
	if(cvar_mode == null) return false;
	return cvar.IntValue;
}

stock bool IsThisRoundValid()
{
	ConVar tank_bhop = FindConVar("ai_Tank_Bhop");
	if(AnneMultiPlayerMode())
	{
		return tank_bhop.BoolValue;
	}
	return true;
}

stock bool CheckIsOfficalMap(){
	char mapname[256];
	GetCurrentMap(mapname,sizeof(mapname));
	if(( (mapname[0]=='c') && (mapname[2]=='m') &&(mapname[4]=='_'))||((mapname[0]=='c')&&(mapname[3]=='m')&&(mapname[5]=='_')))
		return true;
	return false;
}