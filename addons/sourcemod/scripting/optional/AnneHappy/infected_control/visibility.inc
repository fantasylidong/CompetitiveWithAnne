#if defined _infected_control_visibility_included
    #endinput
#endif
#define _infected_control_visibility_included

// 生还者眼位和左右视点每帧只采集一次，候选扫描期间复用固定数组。
static int g_VisibilitySnapshotClients[MAXPLAYERS + 1];
static bool g_VisibilitySnapshotIncap[MAXPLAYERS + 1];
static float g_VisibilitySnapshotEyes[MAXPLAYERS + 1][3];
static float g_VisibilitySnapshotEyesL[MAXPLAYERS + 1][3];
static float g_VisibilitySnapshotEyesR[MAXPLAYERS + 1][3];
static float g_VisibilitySnapshotEyesFlat[(MAXPLAYERS + 1) * 3];
static float g_VisibilitySnapshotEyesLFlat[(MAXPLAYERS + 1) * 3];
static float g_VisibilitySnapshotEyesRFlat[(MAXPLAYERS + 1) * 3];
static float g_VisibilitySnapshotForward[MAXPLAYERS + 1][2];
static int g_VisibilitySnapshotCount;
static int g_VisibilitySnapshotRayMode;
static int g_VisibilitySnapshotTick = -1;
static bool g_VisibilitySnapshotReady;

stock bool Visibility_HasCurrentEyeSnapshot()
{
    return g_VisibilitySnapshotReady
        && g_VisibilitySnapshotTick == GetGameTickCount();
}

stock void Visibility_ClearEyeSnapshot()
{
    if (g_bSpawnAccel)
        AnneSpawn_ClearSurvivorSnapshot();

    g_VisibilitySnapshotCount = 0;
    g_VisibilitySnapshotRayMode = 0;
    g_VisibilitySnapshotTick = -1;
    g_VisibilitySnapshotReady = false;
}

stock void Visibility_RefreshEyeSnapshot()
{
    const float SIDE = 16.0;
    g_VisibilitySnapshotReady = false;
    g_VisibilitySnapshotCount = 0;

    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client) || GetClientTeam(client) != TEAM_SURVIVOR || !IsPlayerAlive(client))
            continue;

        int slot = g_VisibilitySnapshotCount++;
        g_VisibilitySnapshotClients[slot] = client;
        g_VisibilitySnapshotIncap[slot] = L4D_IsPlayerIncapacitated(client);
        GetClientEyePosition(client, g_VisibilitySnapshotEyes[slot]);

        // 搜索会话可能跨帧并保留旧 ray mode，因此左右眼位始终同步刷新。
        float ang[3], fwd[3], right[3], up[3];
        GetClientEyeAngles(client, ang);
        GetAngleVectors(ang, fwd, right, up);
        g_VisibilitySnapshotForward[slot][0] = fwd[0];
        g_VisibilitySnapshotForward[slot][1] = fwd[1];

        g_VisibilitySnapshotEyesL[slot][0] = g_VisibilitySnapshotEyes[slot][0] - right[0] * SIDE;
        g_VisibilitySnapshotEyesL[slot][1] = g_VisibilitySnapshotEyes[slot][1] - right[1] * SIDE;
        g_VisibilitySnapshotEyesL[slot][2] = g_VisibilitySnapshotEyes[slot][2] - right[2] * SIDE;
        g_VisibilitySnapshotEyesR[slot][0] = g_VisibilitySnapshotEyes[slot][0] + right[0] * SIDE;
        g_VisibilitySnapshotEyesR[slot][1] = g_VisibilitySnapshotEyes[slot][1] + right[1] * SIDE;
        g_VisibilitySnapshotEyesR[slot][2] = g_VisibilitySnapshotEyes[slot][2] + right[2] * SIDE;

        for (int axis = 0; axis < 3; axis++)
        {
            int flatIndex = slot * 3 + axis;
            g_VisibilitySnapshotEyesFlat[flatIndex] = g_VisibilitySnapshotEyes[slot][axis];
            g_VisibilitySnapshotEyesLFlat[flatIndex] = g_VisibilitySnapshotEyesL[slot][axis];
            g_VisibilitySnapshotEyesRFlat[flatIndex] = g_VisibilitySnapshotEyesR[slot][axis];
        }
    }

    g_VisibilitySnapshotRayMode = gCV.iVisRayMode;
    if (g_VisibilitySnapshotRayMode == 2)
        g_VisibilitySnapshotRayMode = (g_VisibilitySnapshotCount > 4) ? 0 : 1;

    if (g_bSpawnAccel)
    {
        AnneSpawn_SetSurvivorSnapshot(
            g_VisibilitySnapshotClients,
            g_VisibilitySnapshotIncap,
            g_VisibilitySnapshotEyesFlat,
            g_VisibilitySnapshotEyesLFlat,
            g_VisibilitySnapshotEyesRFlat,
            g_VisibilitySnapshotCount
        );
    }

    g_VisibilitySnapshotTick = GetGameTickCount();
    g_VisibilitySnapshotReady = true;
}

stock int Visibility_GetEyeSnapshotCount()
{
    return Visibility_HasCurrentEyeSnapshot() ? g_VisibilitySnapshotCount : 0;
}

stock bool Visibility_GetEyeSnapshot(int slot, int &client, float eyes[3], float viewDir[2])
{
    if (!Visibility_HasCurrentEyeSnapshot() || slot < 0 || slot >= g_VisibilitySnapshotCount)
        return false;

    client = g_VisibilitySnapshotClients[slot];
    eyes[0] = g_VisibilitySnapshotEyes[slot][0];
    eyes[1] = g_VisibilitySnapshotEyes[slot][1];
    eyes[2] = g_VisibilitySnapshotEyes[slot][2];
    viewDir[0] = g_VisibilitySnapshotForward[slot][0];
    viewDir[1] = g_VisibilitySnapshotForward[slot][1];
    return true;
}

stock bool Visibility_GetClientEyeSnapshot(int wantedClient, float eyes[3])
{
    if (!Visibility_HasCurrentEyeSnapshot())
        return false;

    for (int slot = 0; slot < g_VisibilitySnapshotCount; slot++)
    {
        if (g_VisibilitySnapshotClients[slot] != wantedClient)
            continue;
        eyes[0] = g_VisibilitySnapshotEyes[slot][0];
        eyes[1] = g_VisibilitySnapshotEyes[slot][1];
        eyes[2] = g_VisibilitySnapshotEyes[slot][2];
        return true;
    }
    return false;
}

bool RayClear(const float src[3], const float dst[3], int mask)
{
    // Trace filter 回调不得嵌套发起 Trace；这里使用同步全局结果避免热路径 Handle 分配。
    TR_TraceRayFilter(src, dst, mask, RayType_EndPoint, TraceFilter);
    return !TR_DidHit() || TR_GetFraction() >= 0.99;
}

int GetEffectiveVisibilityRayMode()
{
    if (Visibility_HasCurrentEyeSnapshot())
        return g_VisibilitySnapshotRayMode;

    int mode = gCV.iVisRayMode;
    if (mode == 2)
        mode = (CountAliveSurvivors() > 4) ? 0 : 1;
    return mode;
}

bool IsPosVisibleSDKWithMode(float pos[3], bool teleportMode, int effectiveRayMode)
{
    float head[3];
    head[0] = pos[0]; head[1] = pos[1]; head[2] = pos[2] + 62.0;

    float chest[3];
    chest[0] = pos[0]; chest[1] = pos[1]; chest[2] = pos[2] + 32.0;

    const int visMask = (MASK_VISIBLE & MASK_SHOT);
    const float SIDE = 16.0;

    if (Visibility_HasCurrentEyeSnapshot())
    {
        for (int slot = 0; slot < g_VisibilitySnapshotCount; slot++)
        {
            if (teleportMode && g_VisibilitySnapshotIncap[slot] && gCV.bIgnoreIncapSight)
                continue;

            if (RayClear(g_VisibilitySnapshotEyes[slot], head, visMask))
                return true;

            if (effectiveRayMode == 1
                && (RayClear(g_VisibilitySnapshotEyesL[slot], head, visMask)
                    || RayClear(g_VisibilitySnapshotEyesR[slot], head, visMask)))
                return true;

            int client = g_VisibilitySnapshotClients[slot];
            if (L4D2_IsVisibleToPlayer(client, TEAM_SURVIVOR, TEAM_INFECTED, 0, chest))
                return true;
        }
        return false;
    }

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || GetClientTeam(i) != TEAM_SURVIVOR || !IsPlayerAlive(i))
            continue;
        if (teleportMode && L4D_IsPlayerIncapacitated(i) && gCV.bIgnoreIncapSight)
            continue;

        float eyes[3];
        GetClientEyePosition(i, eyes);

        if (RayClear(eyes, head, visMask))
            return true;

        if (effectiveRayMode == 1)
        {
            float ang[3], fwd[3], right[3], up[3];
            GetClientEyeAngles(i, ang);
            GetAngleVectors(ang, fwd, right, up);

            float eyesL[3];
            eyesL[0] = eyes[0] - right[0] * SIDE;
            eyesL[1] = eyes[1] - right[1] * SIDE;
            eyesL[2] = eyes[2] - right[2] * SIDE;

            float eyesR[3];
            eyesR[0] = eyes[0] + right[0] * SIDE;
            eyesR[1] = eyes[1] + right[1] * SIDE;
            eyesR[2] = eyes[2] + right[2] * SIDE;

            if (RayClear(eyesL, head, visMask) || RayClear(eyesR, head, visMask))
                return true;
        }

        if (L4D2_IsVisibleToPlayer(i, TEAM_SURVIVOR, TEAM_INFECTED, 0, chest))
            return true;
    }

    return false;
}

bool IsPosVisibleSDK(float pos[3], bool teleportMode)
{
    return IsPosVisibleSDKWithMode(pos, teleportMode, GetEffectiveVisibilityRayMode());
}

stock bool TraceFilter_Stuck(int entity, int contentsMask)
{
    if (entity <= MaxClients || !IsValidEntity(entity))
        return false;

    static char sClassName[20];
    GetEntityClassname(entity, sClassName, sizeof(sClassName));
    if (strcmp(sClassName, "env_physics_blocker") == 0 && !EnvBlockType(entity))
        return false;

    return true;
}

stock bool EnvBlockType(int entity)
{
    int BlockType = GetEntProp(entity, Prop_Data, "m_nBlockType");
    return !(BlockType == 1 || BlockType == 2);
}

bool WillStuck(const float at[3])
{
    static const float mins[3] = { -16.0, -16.0, 0.0 };
    static const float maxs[3] = {  16.0,  16.0, 71.0 };
    TR_TraceHullFilter(at, at, mins, maxs, MASK_PLAYERSOLID, TraceFilter_Stuck);
    return TR_DidHit();
}

stock bool TraceFilter(int entity, int contentsMask)
{
    if (entity <= MaxClients || !IsValidEntity(entity))
        return false;

    static char sClassName[32];
    GetEntityClassname(entity, sClassName, sizeof(sClassName));
    if (strcmp(sClassName, "infected") == 0 || strcmp(sClassName, "witch") == 0)
        return false;

    return true;
}
