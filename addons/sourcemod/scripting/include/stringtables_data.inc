#if defined _stringtables_data_included
	#endinput
#endif
#define _stringtables_data_included

#include <sdktools>

Handle g_hStringTableDeleteAll;
Handle g_hStringTableGetTable;
Address g_pStringTableContainer = Address_Null;

methodmap INetworkStringTable
{
	public INetworkStringTable(int index)
	{
		InitStringTableSDKCalls();
		return view_as<INetworkStringTable>(SDKCall(g_hStringTableGetTable, g_pStringTableContainer, index));
	}

	public void DeleteStrings()
	{
		SDKCall(g_hStringTableDeleteAll, this);
	}
}

void InitStringTableSDKCalls()
{
	static bool initialized;
	if (initialized)
		return;

	initialized = true;

	StartPrepSDKCall(SDKCall_Raw);
	bool linux = PrepSDKCall_SetSignature(SDKLibrary_Engine, "@_ZN19CNetworkStringTable16DeleteAllStringsEv", 0);
	if (!linux && !PrepSDKCall_SetSignature(SDKLibrary_Engine, "\x53\x56\x8B\xF1\x8B\x4E\x38\x33\xDB", 9))
		SetFailState("Failed to find CNetworkStringTable::DeleteAllStrings");

	g_hStringTableDeleteAll = EndPrepSDKCall();
	if (g_hStringTableDeleteAll == null)
		SetFailState("Failed to prepare CNetworkStringTable::DeleteAllStrings");

	StartPrepSDKCall(SDKCall_Raw);
	PrepSDKCall_SetVirtual(linux ? 5 : 4);
	PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
	PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
	g_hStringTableGetTable = EndPrepSDKCall();
	if (g_hStringTableGetTable == null)
		SetFailState("Failed to prepare INetworkStringTableContainer::GetTable");

	StartPrepSDKCall(SDKCall_Static);
	if (!PrepSDKCall_SetSignature(SDKLibrary_Engine, "@CreateInterface", 0))
		SetFailState("Failed to find CreateInterface");

	PrepSDKCall_AddParameter(SDKType_String, SDKPass_Pointer);
	PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Pointer, VDECODE_FLAG_ALLOWNULL);
	PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
	Handle createInterface = EndPrepSDKCall();
	if (createInterface == null)
		SetFailState("Failed to prepare CreateInterface");

	char interfaceName[36];
	for (int version = 1; version <= 10 && g_pStringTableContainer == Address_Null; version++)
	{
		FormatEx(interfaceName, sizeof(interfaceName), "VEngineServerStringTable%03d", version);
		g_pStringTableContainer = view_as<Address>(SDKCall(createInterface, interfaceName, 0));
	}

	delete createInterface;

	if (g_pStringTableContainer == Address_Null)
		SetFailState("Failed to find VEngineServerStringTable interface");
}
