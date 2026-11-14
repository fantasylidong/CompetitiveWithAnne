#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sourcescramble>
#define L4D2IWA_CLIPSIZE 2
native int L4D2_GetIntWeaponAttribute(const char[] weaponName, int attr);

public Plugin myinfo =
{
	name = "SG-552 Tickrate Fix",
	author = "bullet28",
	description = "Tries to fix strange FOV behavior when using SG-552 with increased tickrate",
	version = "2.1",
	url = "https://forums.alliedmods.net/showthread.php?p=2687318"
}

Handle hCycleZoom;
MemoryPatch hZoomPatch;

bool bPatched;
bool bLastFrameWasInZoom[MAXPLAYERS + 1];
bool bUnZooming[MAXPLAYERS + 1];

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max) {
	MarkNativeAsOptional("L4D2_GetIntWeaponAttribute");
	return APLRes_Success;
}

public void OnPluginStart() {
	GameData hGameData = LoadGameConfigFile("lfd_both_fixSG552");
	if (hGameData == null) {
		SetFailState("Failed to load gamedata: \"lfd_both_fixSG552\"");
		return;
	}

	StartPrepSDKCall(SDKCall_Entity);
	if (PrepSDKCall_SetFromConf(hGameData, SDKConf_Virtual, "CTerrorGun::CycleZoom") == false) {
		delete hGameData;
		SetFailState("Failed to find signature: \"CTerrorGun::CycleZoom\"");
		return;
	}

	hCycleZoom = EndPrepSDKCall();
	if (hCycleZoom == null) {
		delete hGameData;
		SetFailState("Failed to create SDKCall: \"CTerrorGun::CycleZoom\"");
		return;
	}

	hZoomPatch = MemoryPatch.CreateFromConf(hGameData, "zoom");
	if (!hZoomPatch) {
		LogMessage("Failed to create patch for \"zoom\". Skipping...");
	} else if (!hZoomPatch.Validate()) {
		delete hZoomPatch;
		hZoomPatch = null;
		LogMessage("Failed to verify patch for \"zoom\". Skipping...");
	}

	delete hGameData;

	HookEvent("weapon_fire", eventWeaponFire);
}

public void OnPluginEnd() {
	if (bPatched && hZoomPatch != null) {
		hZoomPatch.Disable();
		bPatched = false;
	}
}

public void OnClientDisconnect(int client) {
	bLastFrameWasInZoom[client] = false;
	bUnZooming[client] = false;
}

public void eventWeaponFire(Event event, const char[] name, bool dontBroadcast) {
	if (event.GetInt("weaponid") != 34)
		return;

	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client <= 0 || !IsClientInGame(client) || IsFakeClient(client))
		return;

	if (GetEntPropEnt(client, Prop_Send, "m_hZoomOwner") == -1)
		return;

	int weapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
	if (!isWeaponSG552(weapon))
		return;

	int clip = GetEntProp(weapon, Prop_Send, "m_iClip1");
	if (clip != 1)
		return;

	SDKCall(hCycleZoom, weapon);
}

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float fAngles[3], int &weapon) {
	if (!IsClientInGame(client) || IsFakeClient(client) || GetClientTeam(client) != 2 || !IsPlayerAlive(client)) {
		bLastFrameWasInZoom[client] = false;
		return Plugin_Continue;
	}

	bool zoomedNow = GetEntPropEnt(client, Prop_Send, "m_hZoomOwner") != -1;
	if (!bLastFrameWasInZoom[client] && !zoomedNow) {
		return Plugin_Continue;
	}

	int activeWeapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
	if (!isWeaponSG552(activeWeapon)) {
		bLastFrameWasInZoom[client] = false;
		return Plugin_Continue;
	}

	if (!(GetEntityFlags(client) & FL_ONGROUND)) {
		if (bLastFrameWasInZoom[client]) {
			bLastFrameWasInZoom[client] = false;
			UnZoom(client, activeWeapon, true);
		}

		return Plugin_Continue;
	}

	if (!zoomedNow) {
		bLastFrameWasInZoom[client] = false;
		return Plugin_Continue;
	}

	bLastFrameWasInZoom[client] = true;

	if (buttons & IN_RELOAD) {
		if (!GetEntProp(activeWeapon, Prop_Data, "m_bInReload")) {
			int maxClip = GetSG552MaxClip();
			if (GetEntProp(activeWeapon, Prop_Data, "m_iClip1") != maxClip) {
				UnZoom(client, activeWeapon, false);
			}
		}
	} else if (buttons & IN_JUMP) {
		UnZoom(client, activeWeapon, true);
	}

	return Plugin_Continue;
}

int GetSG552MaxClip() {
	if (GetFeatureStatus(FeatureType_Native, "L4D2_GetIntWeaponAttribute") == FeatureStatus_Available) {
		int clipSize = L4D2_GetIntWeaponAttribute("weapon_rifle_sg552", L4D2IWA_CLIPSIZE);
		if (clipSize > 0) {
			return clipSize;
		}
	}
	return 50;
}

void UnZoom(int client, int activeWeapon, bool bFalling) {
	bUnZooming[client] = true;

	if (!bPatched) {
		if (hZoomPatch != null) {
			hZoomPatch.Enable();
		}
		RequestFrame(FrameUnPatchZoom);
		bPatched = true;
	}

	if (zoomToggleAllowed(client)) {
		if (!bFalling) bUnZooming[client] = false;
		SDKCall(hCycleZoom, activeWeapon);
	}
}

public void FrameUnPatchZoom() {
	for (int i = 1; i <= MaxClients; i++) {
		if (bUnZooming[i] && IsClientInGame(i) && !IsFakeClient(i) && !(GetEntityFlags(i) & FL_ONGROUND)) {
			if (zoomToggleAllowed(i)) {
				int m_hActiveWeapon = GetEntPropEnt(i, Prop_Send, "m_hActiveWeapon");
				if (isWeaponSG552(m_hActiveWeapon)) {
					SDKCall(hCycleZoom, m_hActiveWeapon);
				}
				bUnZooming[i] = false;
			} else {
				RequestFrame(FrameUnPatchZoom);
				return;
			}
		}

		bUnZooming[i] = false;
	}

	if (hZoomPatch != null) {
		hZoomPatch.Disable();
	}
	bPatched = false;
}

bool zoomToggleAllowed(int client) {
	int m_iFOVStart = GetEntProp(client, Prop_Send, "m_iFOVStart");
	float m_flFOVTime = GetEntPropFloat(client, Prop_Send, "m_flFOVTime");
	return m_iFOVStart == 55 && GetGameTime() > m_flFOVTime;
}

bool isWeaponSG552(int entity) {
	if (entity > MaxClients && IsValidEntity(entity)) {
		char classname[32];
		GetEntityClassname(entity, classname, sizeof(classname));
		if (StrEqual(classname, "weapon_rifle_sg552")) {
			return true;
		}
	}

	return false;
}
