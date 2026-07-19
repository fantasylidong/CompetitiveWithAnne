#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <dhooks>

#define GAMEDATA_FILE         "l4d2_block_no_steam_logon"
#define DETOUR_FUNCTION       "CSteam3Server::OnValidateAuthTicketResponseHelper"
#define SDKCALL_GETCLIENTNAME "CBaseClient::GetClientName"
#define SDKCALL_ISTIMINGOUT   "CNetChan::IsTimingOut"
#define SDKCALL_DISCONNECT    "CBaseClient::Disconnect"
#define SDKCALL_GETNETCHANNEL "CBaseClient::GetNetChannel"
#define OFFSET_NAME           "CBaseClient->m_Name"
#define CLIENTNAME_TIMED_OUT  "%s timed out."

#define PLUGIN_VERSION "1.2.4-anne"

Handle g_hSDKCall_GetClientName;
Handle g_hSDKCall_IsTimingOut;
Handle g_hSDKCall_Disconnect;
Handle g_hSDKCall_GetNetChannel;

GlobalForward g_hFWD_OnValidateAuthTicketResponseHelper = null;
ConVar g_hCvar_Enable = null;
ConVar g_hCvar_CheckTimeOut = null;

bool g_bEnable = false;
bool g_bCheckTimeOut = false;

enum OperatingSystem
{
	OS_Windows = 0,
	OS_Linux = 1
}

OperatingSystem g_iOS = OS_Linux;
int g_iOff_CBaseClient_m_Name = -1;

enum EAuthSessionResponse
{
	k_EAuthSessionResponseOK = 0,
	k_EAuthSessionResponseUserNotConnectedToSteam = 1,
	k_EAuthSessionResponseNoLicenseOrExpired = 2,
	k_EAuthSessionResponseVACBanned = 3,
	k_EAuthSessionResponseLoggedInElseWhere = 4,
	k_EAuthSessionResponseVACCheckTimedOut = 5,
	k_EAuthSessionResponseAuthTicketCanceled = 6,
	k_EAuthSessionResponseAuthTicketInvalidAlreadyUsed = 7,
	k_EAuthSessionResponseAuthTicketInvalid = 8
}

methodmap INetChannel
{
	public bool IsTimingOut()
	{
		return SDKCall(g_hSDKCall_IsTimingOut, view_as<Address>(this));
	}
}

methodmap CBaseClient
{
	public INetChannel GetNetChannel()
	{
		return view_as<INetChannel>(SDKCall(g_hSDKCall_GetNetChannel, view_as<Address>(this)));
	}

	public void Disconnect(const char[] reason)
	{
		SDKCall(g_hSDKCall_Disconnect, view_as<Address>(this), reason);
	}

	public void GetClientName(char[] name, int maxlen)
	{
		SDKCall(g_hSDKCall_GetClientName, view_as<Address>(this), name, maxlen);
	}
}

public Plugin myinfo =
{
	name = "[L4D2] Block No Steam Logon",
	author = "blueblur, AnneHappy",
	description = "Bypasses Steam auth responses 1 and 6 while preserving other auth failures.",
	version = PLUGIN_VERSION,
	url = "https://github.com/blueblur0730/modified-plugins"
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int errMax)
{
	if (GetEngineVersion() != Engine_Left4Dead2)
	{
		strcopy(error, errMax, "Plugin only supports Left 4 Dead 2.");
		return APLRes_SilentFailure;
	}

	// forward void OnValidateAuthTicketResponseHelper(EAuthSessionResponse response, const char[] name);
	g_hFWD_OnValidateAuthTicketResponseHelper = new GlobalForward(
		"OnValidateAuthTicketResponseHelper",
		ET_Event,
		Param_Any,
		Param_String
	);
	RegPluginLibrary("l4d2_block_no_steam_logon");
	return APLRes_Success;
}

public void OnPluginStart()
{
	CreateConVar(
		"l4d2_block_no_steam_logon_version",
		PLUGIN_VERSION,
		"Plugin version.",
		FCVAR_NOTIFY | FCVAR_DONTRECORD
	);

	g_hCvar_Enable = CreateConVar(
		"l4d2_block_no_steam_logon_enable",
		"1",
		"Prevent disconnection for Steam auth responses 1 and 6.",
		_,
		true,
		0.0,
		true,
		1.0
	);
	g_hCvar_Enable.AddChangeHook(OnCvarChange);

	g_hCvar_CheckTimeOut = CreateConVar(
		"l4d2_block_no_steam_logon_check_timeout",
		"1",
		"Disconnect the client when its network channel is timing out.",
		_,
		true,
		0.0,
		true,
		1.0
	);
	g_hCvar_CheckTimeOut.AddChangeHook(OnCvarChange);

	OnCvarChange(null, "", "");
	InitGameData();
}

void OnCvarChange(ConVar convar, const char[] oldValue, const char[] newValue)
{
	g_bEnable = g_hCvar_Enable.BoolValue;
	g_bCheckTimeOut = g_hCvar_CheckTimeOut.BoolValue;
}

MRESReturn DTR_OnValidateAuthTicketResponseHelper_Pre(DHookParam params)
{
	CBaseClient baseClient = view_as<CBaseClient>(params.Get(1));
	if (view_as<Address>(baseClient) == Address_Null)
		return MRES_Ignored;

	char name[128];
	switch (g_iOS)
	{
		case OS_Windows:
		{
			ReadMemoryString(
				view_as<Address>(baseClient) + view_as<Address>(g_iOff_CBaseClient_m_Name),
				name,
				sizeof(name)
			);
		}
		case OS_Linux:
		{
			baseClient.GetClientName(name, sizeof(name));
			if (name[0] == '\0')
			{
				ReadMemoryString(
					view_as<Address>(baseClient) + view_as<Address>(g_iOff_CBaseClient_m_Name),
					name,
					sizeof(name)
				);
			}
		}
	}

	EAuthSessionResponse response = view_as<EAuthSessionResponse>(params.Get(2));
	PrintLog("Steam auth failure: name=%s response=%d", name, response);

	Call_StartForward(g_hFWD_OnValidateAuthTicketResponseHelper);
	Call_PushCell(response);
	Call_PushString(name);
	Call_Finish();

	if (g_bCheckTimeOut)
	{
		INetChannel netChannel = baseClient.GetNetChannel();
		if (netChannel && netChannel.IsTimingOut())
		{
			char reason[128];
			Format(reason, sizeof(reason), CLIENTNAME_TIMED_OUT, name);
			PrintLog("Disconnecting timed out client: name=%s", name);
			baseClient.Disconnect(reason);
			return MRES_Supercede;
		}
	}

	if (!g_bEnable)
		return MRES_Ignored;

	switch (response)
	{
		case k_EAuthSessionResponseUserNotConnectedToSteam,
			k_EAuthSessionResponseAuthTicketCanceled:
		{
			PrintLog("Bypassing Steam auth disconnection: name=%s response=%d", name, response);
			return MRES_Supercede;
		}
	}

	return MRES_Ignored;
}

void InitGameData()
{
	GameData gameData = new GameData(GAMEDATA_FILE);
	if (!gameData)
		SetFailState("Missing or invalid gamedata: %s.txt", GAMEDATA_FILE);

	g_iOS = view_as<OperatingSystem>(gameData.GetOffset("OS"));
	if (g_iOS != OS_Windows && g_iOS != OS_Linux)
		SetFailState("Invalid operating system in gamedata.");

	g_iOff_CBaseClient_m_Name = gameData.GetOffset(OFFSET_NAME);
	if (g_iOff_CBaseClient_m_Name == -1)
		SetFailState("Missing offset: %s", OFFSET_NAME);

	DynamicDetour detour = DynamicDetour.FromConf(gameData, DETOUR_FUNCTION);
	if (!detour)
		SetFailState("Missing detour setup: %s", DETOUR_FUNCTION);
	if (!detour.Enable(Hook_Pre, DTR_OnValidateAuthTicketResponseHelper_Pre))
		SetFailState("Failed to enable detour: %s", DETOUR_FUNCTION);
	delete detour;

	if (g_iOS == OS_Linux)
	{
		StartPrepSDKCall(SDKCall_Raw);
		if (!PrepSDKCall_SetFromConf(gameData, SDKConf_Signature, SDKCALL_GETCLIENTNAME))
			SetFailState("Missing signature: %s", SDKCALL_GETCLIENTNAME);
		PrepSDKCall_SetReturnInfo(SDKType_String, SDKPass_Pointer);
		g_hSDKCall_GetClientName = EndPrepSDKCall();
		if (!g_hSDKCall_GetClientName)
			SetFailState("Failed to prepare SDKCall: %s", SDKCALL_GETCLIENTNAME);
	}

	StartPrepSDKCall(SDKCall_Raw);
	if (!PrepSDKCall_SetFromConf(gameData, SDKConf_Virtual, SDKCALL_ISTIMINGOUT))
		SetFailState("Missing offset: %s", SDKCALL_ISTIMINGOUT);
	PrepSDKCall_SetReturnInfo(SDKType_Bool, SDKPass_Plain);
	g_hSDKCall_IsTimingOut = EndPrepSDKCall();
	if (!g_hSDKCall_IsTimingOut)
		SetFailState("Failed to prepare SDKCall: %s", SDKCALL_ISTIMINGOUT);

	StartPrepSDKCall(SDKCall_Raw);
	if (!PrepSDKCall_SetFromConf(gameData, SDKConf_Signature, SDKCALL_DISCONNECT))
		SetFailState("Missing signature: %s", SDKCALL_DISCONNECT);
	PrepSDKCall_AddParameter(SDKType_String, SDKPass_Pointer);
	g_hSDKCall_Disconnect = EndPrepSDKCall();
	if (!g_hSDKCall_Disconnect)
		SetFailState("Failed to prepare SDKCall: %s", SDKCALL_DISCONNECT);

	StartPrepSDKCall(SDKCall_Raw);
	if (!PrepSDKCall_SetFromConf(gameData, SDKConf_Virtual, SDKCALL_GETNETCHANNEL))
		SetFailState("Missing offset: %s", SDKCALL_GETNETCHANNEL);
	PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
	g_hSDKCall_GetNetChannel = EndPrepSDKCall();
	if (!g_hSDKCall_GetNetChannel)
		SetFailState("Failed to prepare SDKCall: %s", SDKCALL_GETNETCHANNEL);

	delete gameData;
}

stock void PrintLog(const char[] message, any ...)
{
	char formatted[256];
	VFormat(formatted, sizeof(formatted), message, 2);

	static char path[PLATFORM_MAX_PATH];
	if (path[0] == '\0')
		BuildPath(Path_SM, path, sizeof(path), "/logs/l4d2_block_no_steam_logon.log");

	LogToFileEx(path, formatted);
}

stock void ReadMemoryString(Address address, char[] buffer, int size)
{
	int max = size - 1;
	int i = 0;

	for (; i < max; i++)
	{
		buffer[i] = view_as<char>(LoadFromAddress(address + view_as<Address>(i), NumberType_Int8));
		if (buffer[i] == '\0')
			return;
	}

	buffer[i] = '\0';
}
