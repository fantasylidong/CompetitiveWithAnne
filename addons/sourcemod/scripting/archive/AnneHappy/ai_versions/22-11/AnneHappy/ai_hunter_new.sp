#pragma semicolon 1
#pragma newdecls required
#include <sourcemod>
#include <sdktools>
#include <left4dhooks>

ConVar g_hLungeInterval, g_hHunterPounceRe, g_hHunter_patch_convert_leap, g_hHunter_patch_crouch_pounce;

float
	g_fLungeInterval,
	g_fFastPounceProximity,
	g_fPounceVerticalAngle,
	g_fPounceAngleMean,
	g_fPounceAngleStd,
	g_fStraightPounceProximity,
	g_fWallDetectionDistance,
	g_fAimOffsetSensitivityHunter,
	g_fCanLungeTime[MAXPLAYERS + 1];

bool
	g_bIgnoreCrouch,
	g_bHasQueuedLunge[MAXPLAYERS + 1];

public Plugin myinfo = {
	name = "AI HUNTER",
	author = "Breezy",
	description = "Improves the AI behaviour of special infected",
	version = "1.0",
	url = "github.com/breezyplease"
};

public void OnPluginStart() {	
	
	
	
	
	
	
	
	g_hLungeInterval = 				FindConVar("z_lunge_interval");
	g_hHunterPounceRe = 			FindConVar("hunter_pounce_ready_range");
	g_hHunter_patch_convert_leap =  FindConVar("l4d2_hunter_patch_convert_leap");
	g_hHunter_patch_crouch_pounce = FindConVar("l4d2_hunter_patch_crouch_pounce");
	if(g_hHunter_patch_convert_leap)
		g_hHunter_patch_convert_leap.AddChangeHook(IgnoreCrouchCvarChanged);
	if(g_hHunter_patch_crouch_pounce)
		g_hHunter_patch_crouch_pounce.AddChangeHook(IgnoreCrouchCvarChanged);
	g_hLungeInterval.AddChangeHook(CvarChanged);
	
	
	
	
	
	
	
	
	HookEvent("round_end",		Event_RoundEnd, EventHookMode_PostNoCopy);
	HookEvent("player_spawn",	Event_PlayerSpawn);
	HookEvent("ability_use",	Event_AbilityUse);
}

public void OnAllPluginsLoaded() {
	if(g_hHunter_patch_convert_leap && g_hHunter_patch_crouch_pounce){
		IgnoreCrounchDetect();
	}
}
void IgnoreCrounchDetect(){
	g_bIgnoreCrouch = false;
	if (g_hHunter_patch_convert_leap && g_hHunter_patch_convert_leap.IntValue == 1) 
	{
		if (g_hHunter_patch_crouch_pounce && g_hHunter_patch_crouch_pounce.IntValue == 2)
		{
			g_bIgnoreCrouch = true;
		}			
	}
	if(g_bIgnoreCrouch){
		g_hHunterPounceRe.FloatValue = 0.0;
		FindConVar("z_pounce_crouch_delay").FloatValue =			0.0;
		FindConVar("hunter_committed_attack_range").FloatValue =	0.0;
	}else{
		g_hHunterPounceRe.FloatValue = 3000.0;
		FindConVar("z_pounce_crouch_delay").RestoreDefault();
		FindConVar("hunter_committed_attack_range").FloatValue =	3000.0;
	}
}

public void OnPluginEnd() {
	FindConVar("z_pounce_crouch_delay").RestoreDefault();
	FindConVar("z_pounce_silence_range").RestoreDefault();
	FindConVar("hunter_pounce_ready_range").RestoreDefault();
	FindConVar("hunter_pounce_max_loft_angle").RestoreDefault();
	FindConVar("hunter_committed_attack_range").RestoreDefault();
	FindConVar("hunter_leap_away_give_up_range").RestoreDefault();
}

public void OnConfigsExecuted() {
	GetCvars();
	TweakSettings();
}

void CvarChanged(ConVar convar, const char[] oldValue, const char[] newValue) {
	GetCvars();
}

void IgnoreCrouchCvarChanged(ConVar convar, const char[] oldValue, const char[] newValue) {
	IgnoreCrounchDetect();
}

void TweakSettings() {
	OnAllPluginsLoaded();
	FindConVar("z_pounce_silence_range").FloatValue =			999999.0;
	FindConVar("hunter_pounce_max_loft_angle").FloatValue =		0.0;
	FindConVar("hunter_leap_away_give_up_range").FloatValue =	0.0;
}

void GetCvars() {
	g_fLungeInterval =				g_hLungeInterval.FloatValue;
	g_fFastPounceProximity =		(3000.0);
	g_fPounceVerticalAngle =		(8.0);
	g_fPounceAngleMean =			(20.0);
	g_fPounceAngleStd =				(30.0);
	g_fStraightPounceProximity =	(200.0);
	g_fAimOffsetSensitivityHunter =	(180.0);
	g_fWallDetectionDistance =		(-1.0);
	if(g_bIgnoreCrouch){
		g_hHunterPounceRe.FloatValue = 0.0;
		FindConVar("z_pounce_crouch_delay").FloatValue =			0.0;
		FindConVar("hunter_committed_attack_range").FloatValue =	0.0;
	}else{
		g_hHunterPounceRe.FloatValue = 3000.0;
		FindConVar("z_pounce_crouch_delay").RestoreDefault();
		FindConVar("hunter_committed_attack_range").FloatValue =	3000.0;
	}
}

public void OnMapEnd() {
	for (int i = 1; i <= MaxClients; i++)
		g_fCanLungeTime[i] = 0.0;
}

void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast) {
	OnMapEnd();
}

void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast) {
	int client = GetClientOfUserId(event.GetInt("userid"));
	g_fCanLungeTime[client] = 0.0;
	g_bHasQueuedLunge[client] = false;
}

void Event_AbilityUse(Event event, const char[] name, bool dontBroadcast) {
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (!client || !IsClientInGame(client) || !IsFakeClient(client))
		return;

	static char ability[16];
	event.GetString("ability", ability, sizeof ability);
	if (strcmp(ability, "ability_lunge") == 0)
		Hunter_OnPounce(client);
}

public Action OnPlayerRunCmd(int client, int &buttons) {
	if (!IsClientInGame(client) || !IsFakeClient(client) || GetClientTeam(client) != 3 || !IsPlayerAlive(client) || GetEntProp(client, Prop_Send, "m_zombieClass") != 3 || GetEntProp(client, Prop_Send, "m_isGhost"))
		return Plugin_Continue;

	if (L4D_IsPlayerStaggering(client))
		return Plugin_Continue;

	static int flags;
	flags = GetEntityFlags(client);
	if (flags & FL_ONGROUND == 0 || (!g_bIgnoreCrouch && flags & FL_DUCKING == 0) ||!GetEntProp(client, Prop_Send, "m_hasVisibleThreats"))
		return Plugin_Continue;
	
	buttons &= ~IN_ATTACK2;

	static float vPos[3];
	GetClientAbsOrigin(client, vPos);
	if (NearestSurDistance(client, vPos) > g_fFastPounceProximity)
		return Plugin_Changed;

	buttons &= ~IN_ATTACK;	
	if (!g_bHasQueuedLunge[client]) {
		g_bHasQueuedLunge[client] = true;
		g_fCanLungeTime[client] = GetGameTime() + g_fLungeInterval;
	}
	else if (g_fCanLungeTime[client] < GetGameTime()) {
		buttons |= IN_ATTACK;
		g_bHasQueuedLunge[client] = false;
	}	

	return Plugin_Changed;
}

float NearestSurDistance(int client, const float vPos[3]) {
	static int i;
	static float vTar[3];
	static float dist;
	static float minDist;

	minDist = -1.0;
	for (i = 1; i <= MaxClients; i++) {
		if (i != client && IsClientInGame(i) && GetClientTeam(i) == 2 && IsPlayerAlive(i)) {
			GetClientAbsOrigin(i, vTar);
			dist = GetVectorDistance(vPos, vTar);
			if (minDist == -1.0 || dist < minDist)
				minDist = dist;
		}
	}

	return minDist;
}

void Hunter_OnPounce(int client) {
	static int ent;
	static float vPos[3];
	GetClientAbsOrigin(client, vPos);
	if (g_fWallDetectionDistance > 0.0 && HitWall(client, vPos)) {
		ent = GetEntPropEnt(client, Prop_Send, "m_customAbility");
		AngleLunge(ent, Math_GetRandomInt(0, 1) ? 45.0 : 315.0);
	}
	else {
		if (IsBeingWatched(client, g_fAimOffsetSensitivityHunter) && NearestSurDistance(client, vPos) > g_fStraightPounceProximity) {
			ent = GetEntPropEnt(client, Prop_Send, "m_customAbility");
			AngleLunge(ent, GaussianRNG(g_fPounceAngleMean, g_fPounceAngleStd));
			LimitLungeVerticality(ent);
		}	
	}
}

#define OBSTACLE_HEIGHT 18.0
bool HitWall(int client, float vStart[3]) {
	vStart[2] += OBSTACLE_HEIGHT;
	static float vAng[3];
	static float vEnd[3];
	GetClientEyeAngles(client, vAng);
	GetAngleVectors(vAng, vAng, NULL_VECTOR, NULL_VECTOR);
	NormalizeVector(vAng, vAng);
	vEnd = vAng;
	ScaleVector(vEnd, g_fWallDetectionDistance);
	AddVectors(vStart, vEnd, vEnd);

	static Handle hndl;
	hndl = TR_TraceHullFilterEx(vStart, vEnd, view_as<float>({-16.0, -16.0, 0.0}), view_as<float>({16.0, 16.0, 33.0}), MASK_PLAYERSOLID_BRUSHONLY, TraceEntityFilter);
	if (TR_DidHit(hndl)) {
		static float vPlane[3];
		TR_GetPlaneNormal(hndl, vPlane);
		if (RadToDeg(ArcCosine(GetVectorDotProduct(vAng, vPlane))) > 165.0) {
			delete hndl;
			return true;
		}
	}

	delete hndl;
	return false;
}

bool TraceEntityFilter(int entity, int contentsMask) {
	if (!entity || entity > MaxClients) {
		static char cls[5];
		GetEdictClassname(entity, cls, sizeof cls);
		return cls[3] != 'e' && cls[3] != 'c';
	}

	return false;
}

bool IsBeingWatched(int client, float offsetThreshold) {
	static int target;
	if (IsAliveSur((target = GetClientAimTarget(client))) && GetPlayerAimOffset(client, target) > offsetThreshold)
		return false;

	return true;
}

float GetPlayerAimOffset(int client, int target) {
	static float vAng[3];
	static float vPos[3];
	static float vDir[3];
	GetClientEyeAngles(target, vAng);
	vAng[0] = vAng[2] = 0.0;
	GetAngleVectors(vAng, vAng, NULL_VECTOR, NULL_VECTOR);
	NormalizeVector(vAng, vAng);

	GetClientAbsOrigin(client, vPos);
	GetClientAbsOrigin(target, vDir);
	vPos[2] = vDir[2] = 0.0;
	MakeVectorFromPoints(vDir, vPos, vDir);
	NormalizeVector(vDir, vDir);

	return RadToDeg(ArcCosine(GetVectorDotProduct(vAng, vDir)));
}

void AngleLunge(int ent, float turnAngle) {
	static float vLunge[3];
	GetEntPropVector(ent, Prop_Send, "m_queuedLunge", vLunge);
	turnAngle = DegToRad(turnAngle);

	static float vForcedLunge[3];
	vForcedLunge[0] = vLunge[0] * Cosine(turnAngle) - vLunge[1] * Sine(turnAngle);
	vForcedLunge[1] = vLunge[0] * Sine(turnAngle) + vLunge[1] * Cosine(turnAngle);
	vForcedLunge[2] = vLunge[2];

	SetEntPropVector(ent, Prop_Send, "m_queuedLunge", vForcedLunge);
}

void LimitLungeVerticality(int ent) {
	static float vLunge[3];
	GetEntPropVector(ent, Prop_Send, "m_queuedLunge", vLunge);

	static float fVertAngle;
	fVertAngle = DegToRad(g_fPounceVerticalAngle);

	static float vFlatLunge[3];
	vFlatLunge[1] = vLunge[1] * Cosine(fVertAngle) - vLunge[2] * Sine(fVertAngle);
	vFlatLunge[2] = vLunge[1] * Sine(fVertAngle) + vLunge[2] * Cosine(fVertAngle);
	vFlatLunge[0] = vLunge[0] * Cosine(fVertAngle) + vLunge[2] * Sine(fVertAngle);
	vFlatLunge[2] = vLunge[0] * -Sine(fVertAngle) + vLunge[2] * Cosine(fVertAngle);
	
	SetEntPropVector(ent, Prop_Send, "m_queuedLunge", vFlatLunge);
}

/** 
 * Thanks to Newteee:
 * Random number generator fit to a bellcurve. Function to generate Gaussian Random Number fit to a bellcurve with a specified mean and std
 * Uses Polar Form of the Box-Muller transformation
*/
float GaussianRNG(float mean, float std) {
	static float x1;
	static float x2;
	static float w;

	do {
		x1 = 2.0 * Math_GetRandomFloat(0.0, 1.0) - 1.0;
		x2 = 2.0 * Math_GetRandomFloat(0.0, 1.0) - 1.0;
		w = Pow(x1, 2.0) + Pow(x2, 2.0);
	} while (w >= 1.0);
	
	static const float e = 2.71828;
	w = SquareRoot(-2.0 * (Logarithm(w, e) / w));

	static float y1;
	static float y2;
	y1 = x1 * w;
	y2 = x2 * w;

	static float z1;
	static float z2;
	z1 = y1 * std + mean;
	z2 = y2 * std - mean;

	return Math_GetRandomFloat(0.0, 1.0) < 0.5 ? z1 : z2;
}

bool IsAliveSur(int client) {
	return client > 0 && client <= MaxClients && IsClientInGame(client) && GetClientTeam(client) == 2 && IsPlayerAlive(client);
}

// https://github.com/bcserv/smlib/blob/transitional_syntax/scripting/include/smlib/math.inc
/**
 * Returns a random, uniform Integer number in the specified (inclusive) range.
 * This is safe to use multiple times in a function.
 * The seed is set automatically for each plugin.
 * Rewritten by MatthiasVance, thanks.
 *
 * @param min			Min value used as lower border
 * @param max			Max value used as upper border
 * @return				Random Integer number between min and max
 */
int Math_GetRandomInt(int min, int max)
{
	int random = GetURandomInt();

	if (random == 0) {
		random++;
	}

	return RoundToCeil(float(random) / (float(2147483647) / float(max - min + 1))) + min - 1;
}

/**
 * Returns a random, uniform Float number in the specified (inclusive) range.
 * This is safe to use multiple times in a function.
 * The seed is set automatically for each plugin.
 *
 * @param min			Min value used as lower border
 * @param max			Max value used as upper border
 * @return				Random Float number between min and max
 */
float Math_GetRandomFloat(float min, float max)
{
	return (GetURandomFloat() * (max  - min)) + min;
}
