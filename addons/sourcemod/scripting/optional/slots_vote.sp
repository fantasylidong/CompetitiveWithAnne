#pragma semicolon 1
#pragma newdecls required

#include <builtinvotes>
#include <colors>
#include <sourcemod>

#define L4D2Team_Spectator 1
#define SLOT_HARD_MAX 31

Handle g_hVote;
char   g_sSlots[32];
ConVar hMaxSlots, hNonAdminMinSlots;
ConVar hSvMaxPlayers, hVisibleMaxPlayers;
int    MaxSlots,NonAdminMinSlots;

public Plugin myinfo =
{
	name        = "Slots?! Voter",
	description = "Slots Voter",
	author      = "Sir",
	version     = "1.0",
	url         = "https://github.com/SirPlease/L4D2-Competitive-Rework/"
};

public void OnPluginStart()
{
	LoadTranslations("slots_vote.phrases");
	RegConsoleCmd("sm_slots", SlotsRequest);
	hMaxSlots = CreateConVar("slots_max_slots", "16", "Maximum amount of slots players can vote for.", _, true, 1.0, true, float(SLOT_HARD_MAX));
	hNonAdminMinSlots = CreateConVar("slots_nonAdmin_min_slots", "4", "Minimum amount of slots non-admin players can vote for.", _, true, 1.0, true, float(SLOT_HARD_MAX));
	hSvMaxPlayers = FindConVar("sv_maxplayers");
	hVisibleMaxPlayers = FindConVar("sv_visiblemaxplayers");
	MaxSlots  = hMaxSlots.IntValue;
	NonAdminMinSlots = hNonAdminMinSlots.IntValue;
	HookConVarChange(hMaxSlots, CVarChanged);
	HookConVarChange(hNonAdminMinSlots, CVarChanged);
}

Action SlotsRequest(int client, int args)
{

	if (args == 1)
	{
		char sSlots[64];
		GetCmdArg(1, sSlots, sizeof(sSlots));
		int Int = StringToInt(sSlots);
		bool bAdmin = client == 0 || CheckCommandAccess(client, "", ADMFLAG_GENERIC);
		int iMaxSlots = GetAllowedMaxSlots();

		if (Int < 1)
		{
			CPrintToChat(client, "%t %t", "Tag", "InvalidSlots", iMaxSlots);
		}
		else if (Int > iMaxSlots)
		{
			CPrintToChat(client, "%t %t", "Tag", "LimitSlotsAbove", iMaxSlots, MaxSlots);
		}
		else if (bAdmin)
		{
			char sName[MAX_NAME_LENGTH];
			if(client == 0)
				sName="远程管理员";
			else
				GetClientName(client, sName, sizeof(sName));
			CPrintToChatAll("%t %t", "Tag", "LimitedSlotsTo", sName, Int);
			ApplySlots(Int);
		}
		else{
			if(Int < NonAdminMinSlots)
			{
				CPrintToChat(client, "%t %t", "Tag", "SlotsVote_AdminOnlyBelowMinimumSlots", NonAdminMinSlots);
			}
			else
			{
				if (Int < GetConVarInt(FindConVar("survivor_limit")))
				{
					CPrintToChat(client, "%t %t", "Tag", "RequiredPlayers");
				}
				else if (StartSlotVote(client, sSlots))
				{
					strcopy(g_sSlots, sizeof(g_sSlots), sSlots);
					FakeClientCommand(client, "Vote Yes");
				}
			}
		}
		
	}
	else
	{
		CPrintToChat(client, "%t %t", "Tag", "SlotsUsage");
	}
	return Plugin_Handled;
}

bool StartSlotVote(int client, char[] Slots)
{
	if (GetClientTeam(client) <= L4D2Team_Spectator)
	{
		CPrintToChat(client, "%t %t", "Tag", "Spectators");
		return false;
	}

	if (!IsBuiltinVoteInProgress())
	{
		int iNumPlayers = 0;
		int[] iPlayers  = new int[MaxClients];

		// list of non-spectators players
		for (int i = 1; i <= MaxClients; i++)
		{
			if (!IsClientInGame(i) || IsFakeClient(i) || GetClientTeam(i) <= L4D2Team_Spectator)
			{
				continue;
			}

			iPlayers[iNumPlayers++] = i;
		}

		char sBuffer[64];
		FormatEx(sBuffer, sizeof(sBuffer), "%T", "LimitSlots", LANG_SERVER, Slots);

		g_hVote = CreateBuiltinVote(VoteActionHandler, BuiltinVoteType_Custom_YesNo, BuiltinVoteAction_Cancel | BuiltinVoteAction_VoteEnd | BuiltinVoteAction_End);
		SetBuiltinVoteArgument(g_hVote, sBuffer);
		SetBuiltinVoteInitiator(g_hVote, client);
		SetBuiltinVoteResultCallback(g_hVote, SlotVoteResultHandler);
		DisplayBuiltinVote(g_hVote, iPlayers, iNumPlayers, 20);
		return true;
	}

	CPrintToChat(client, "%t %t", "Tag", "CannotBeStarted");
	return false;
}

void VoteActionHandler(Handle vote, BuiltinVoteAction action, int param1, int param2)
{
	switch (action)
	{
		case BuiltinVoteAction_End:
		{
			delete vote;
			g_hVote = null;
		}
		case BuiltinVoteAction_Cancel:
		{
			DisplayBuiltinVoteFail(vote, view_as<BuiltinVoteFailReason>(param1));
		}
	}
}

void SlotVoteResultHandler(Handle vote, int num_votes, int num_clients, const int[][] client_info, int num_items, const int[][] item_info)
{
	for (int i = 0; i < num_items; i++)
	{
		if (item_info[i][BUILTINVOTEINFO_ITEM_INDEX] == BUILTINVOTES_VOTE_YES)
		{
			if (item_info[i][BUILTINVOTEINFO_ITEM_VOTES] > (num_votes / 2))
			{

				int Slots = StringToInt(g_sSlots, 10);
				if (Slots < 1 || Slots > GetAllowedMaxSlots())
				{
					DisplayBuiltinVoteFail(vote, BuiltinVoteFail_Loses);
					return;
				}

				char Buffer[32];
				FormatEx(Buffer, sizeof(Buffer), "%T", "LimitingSlots", LANG_SERVER);
				DisplayBuiltinVotePass(vote, Buffer);
				ApplySlots(Slots);
				return;
			}
		}
	}
	DisplayBuiltinVoteFail(vote, BuiltinVoteFail_Loses);
}

void CVarChanged(Handle cvar, char[] oldValue, char[] newValue)
{
	MaxSlots = GetConVarInt(hMaxSlots);
	NonAdminMinSlots = GetConVarInt(hNonAdminMinSlots);
}

int GetAllowedMaxSlots()
{
	return MaxSlots < SLOT_HARD_MAX ? MaxSlots : SLOT_HARD_MAX;
}

void ApplySlots(int slots)
{
	if (hSvMaxPlayers != null)
		hSvMaxPlayers.IntValue = slots;

	if (hVisibleMaxPlayers != null)
		hVisibleMaxPlayers.IntValue = slots;
}
