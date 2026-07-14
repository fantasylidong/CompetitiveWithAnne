#if defined _infected_control_traitor_mode_included
    #endinput
#endif
#define _infected_control_traitor_mode_included

#define TRAITOR_SPAWN_WINDOW_SECONDS 5
#define TRAITOR_ROUND_AUTH_LENGTH 64
#define TRAITOR_CLASS_TANK ZC_TANK
#define TRAITOR_CLASS_MASK_TANK (1 << SI_COUNT)
#define TRAITOR_CLASS_MASK_ALL ((1 << (SI_COUNT + 1)) - 1)
#define TRAITOR_TANK_MIN_DAMAGE 100
#define TRAITOR_TANK_BLOCK_SECONDS (3 * 24 * 60 * 60)
#define TRAITOR_TANK_BLOCK_DAYS 3
#define TRAITOR_NO_DAMAGE_BLOCK_ROUNDS 3
#define TRAITOR_POST_DEATH_DAMAGE_WINDOW 8.0 // covers the default Spitter acid lifetime plus event delay

enum TraitorState
{
    Traitor_None = 0,
    Traitor_Waiting,
    Traitor_Armed,
    Traitor_SpawnLocked,
    Traitor_SpawnAllowed,
    Traitor_Alive
}

static TraitorState g_ITState[MAXPLAYERS + 1];
static int g_ITClass[MAXPLAYERS + 1];
static int g_ITReleaseWave[MAXPLAYERS + 1];
static int g_ITUsesThisRound[MAXPLAYERS + 1];
static int g_ITWaitOrder[MAXPLAYERS + 1];
static int g_ITNextWaitOrder = 1;
static bool g_ITDidDamage[MAXPLAYERS + 1];
static int g_ITDamageTotal[MAXPLAYERS + 1];
static int g_ITPendingDamageAttacker[MAXPLAYERS + 1];
static bool g_ITSkipNextDamagePost[MAXPLAYERS + 1];
static int g_ITPendingIncapAttacker[MAXPLAYERS + 1];
static bool g_ITSurvivorIncapped[MAXPLAYERS + 1];
static bool g_ITDamageLedgerActive[MAXPLAYERS + 1];
static float g_ITDamageLedgerExpire[MAXPLAYERS + 1];
static int g_ITDamageLedgerClass[MAXPLAYERS + 1];
static bool g_ITDamageSummaryPending[MAXPLAYERS + 1];
static ConVar g_ITSurvivorIncapHealth = null;
static bool g_ITNoDamageBlockedThisRound[MAXPLAYERS + 1];
static float g_ITSpawnDeadline[MAXPLAYERS + 1];
static Handle g_ITSpawnTimer[MAXPLAYERS + 1];
static bool g_ITRefreshPending[MAXPLAYERS + 1];
static int g_ITRefreshClass[MAXPLAYERS + 1];
static float g_ITRefreshOrigin[MAXPLAYERS + 1][3];
static StringMap g_ITNoDamageBlockedAuths = null;

static bool Traitor_IsSurvivorIncapacitated(int client)
{
    return IsValidSurvivor(client)
        && (g_ITSurvivorIncapped[client]
            || GetEntProp(client, Prop_Send, "m_isIncapacitated") != 0
            || GetEntProp(client, Prop_Send, "m_isHangingFromLedge") != 0
            || GetEntProp(client, Prop_Send, "m_isFallingFromLedge") != 0);
}

static bool Traitor_IsSurvivorTeamWiped()
{
    int survivorCount = 0;
    int uprightCount = 0;

    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsValidSurvivor(client))
            continue;

        survivorCount++;
        if (!IsPlayerAlive(client) || Traitor_IsSurvivorIncapacitated(client))
            continue;

        uprightCount++;
    }

    return survivorCount == 0 || uprightCount == 0;
}

static bool Traitor_IsDamageLedgerActive(int client)
{
    if (client < 1 || client > MaxClients || !g_ITDamageLedgerActive[client])
        return false;

    if (g_ITDamageLedgerExpire[client] > 0.0 && GetGameTime() > g_ITDamageLedgerExpire[client])
    {
        g_ITDamageLedgerActive[client] = false;
        g_ITDamageLedgerExpire[client] = 0.0;
        g_ITDamageLedgerClass[client] = 0;
        g_ITDidDamage[client] = false;
        g_ITDamageTotal[client] = 0;
        return false;
    }

    return true;
}

static bool Traitor_IsDamageAttributor(int client)
{
    return Traitor_IsAliveClient(client) || Traitor_IsDamageLedgerActive(client);
}

static bool Traitor_IsClassAttributor(int client, int zc)
{
    if (client < 1 || client > MaxClients)
        return false;

    if (Traitor_IsAliveClient(client))
        return g_ITClass[client] == zc;

    return Traitor_IsDamageLedgerActive(client) && g_ITDamageLedgerClass[client] == zc;
}

static float Traitor_GetPostDeathDamageWindow(int zc)
{
    if (zc == view_as<int>(SI_Spitter))
        return TRAITOR_POST_DEATH_DAMAGE_WINDOW;

    if (zc == view_as<int>(SI_Boomer))
        return 1.0;

    return 0.5;
}

static int Traitor_GetMinimumIncapHealth()
{
    if (g_ITSurvivorIncapHealth == null)
        g_ITSurvivorIncapHealth = FindConVar("survivor_incap_health");

    int maximum = (g_ITSurvivorIncapHealth != null) ? g_ITSurvivorIncapHealth.IntValue : 300;
    if (maximum < 2)
        maximum = 300;

    int minimum = RoundToCeil(float(maximum) * 0.5);
    return (minimum > 0) ? minimum : 1;
}

static bool Traitor_ShouldCancelTankIncapHit(int victim, float damage)
{
    int currentIncapHealth = GetEntProp(victim, Prop_Send, "m_iHealth");
    int minimumIncapHealth = Traitor_GetMinimumIncapHealth();
    int incomingDamage = RoundToCeil(damage);

    // Incap HP are stored in m_iHealth.  Preserve the lower half of the
    // configured incap pool; if this hit would cross that line, cancel the
    // entire hit instead of clipping it to the line.
    return currentIncapHealth <= minimumIncapHealth
        || incomingDamage <= 0
        || currentIncapHealth - incomingDamage < minimumIncapHealth;
}

static bool Traitor_OpenDamageLedger(int client)
{
    if (client < 1 || client > MaxClients || g_ITState[client] != Traitor_Alive)
        return false;

    g_ITDamageLedgerActive[client] = true;
    g_ITDamageLedgerClass[client] = g_ITClass[client];
    g_ITDamageLedgerExpire[client] = GetGameTime() + Traitor_GetPostDeathDamageWindow(g_ITClass[client]);
    return true;
}

void Traitor_HookClientDamage(int client)
{
    if (client < 1 || client > MaxClients || !IsClientInGame(client))
        return;

    if (g_ITState[client] == Traitor_None)
    {
        g_ITDamageLedgerActive[client] = false;
        g_ITDamageLedgerExpire[client] = 0.0;
        g_ITDamageLedgerClass[client] = 0;
        g_ITDidDamage[client] = false;
        g_ITDamageTotal[client] = 0;
        g_ITDamageSummaryPending[client] = false;
    }

    SDKHook(client, SDKHook_OnTakeDamage, Traitor_OnTakeDamage);
    SDKHook(client, SDKHook_OnTakeDamagePost, Traitor_OnTakeDamagePost);
}

void Traitor_UnhookClientDamage(int client)
{
    if (client < 1 || client > MaxClients)
        return;

    SDKUnhook(client, SDKHook_OnTakeDamage, Traitor_OnTakeDamage);
    SDKUnhook(client, SDKHook_OnTakeDamagePost, Traitor_OnTakeDamagePost);
    g_ITPendingDamageAttacker[client] = 0;
    g_ITSkipNextDamagePost[client] = false;
    g_ITPendingIncapAttacker[client] = 0;
    g_ITSurvivorIncapped[client] = false;
}

static void Traitor_RecordDamage(int attacker, int damage)
{
    if (damage <= 0 || (!Traitor_IsAliveClient(attacker) && !Traitor_IsDamageLedgerActive(attacker)))
        return;

    g_ITDidDamage[attacker] = true;
    g_ITDamageTotal[attacker] += damage;
}

static void Traitor_AnnounceDamageSummary(int client)
{
    if (!IsValidClient(client))
        return;

    CPrintToChat(client, "%t", "InfectedControl_TraitorDamageSummary", g_ITDamageTotal[client]);
}

static void Traitor_FlushDamageSummary(int client)
{
    if (client < 1 || client > MaxClients || !g_ITDamageSummaryPending[client])
        return;

    g_ITDamageSummaryPending[client] = false;
    Traitor_AnnounceDamageSummary(client);

    g_ITDamageLedgerActive[client] = false;
    g_ITDamageLedgerExpire[client] = 0.0;
    g_ITDamageLedgerClass[client] = 0;
    g_ITDidDamage[client] = false;
    g_ITDamageTotal[client] = 0;
}

static Action Timer_TraitorDamageSummary(Handle timer, int userid)
{
    int client = GetClientOfUserId(userid);
    if (client < 1 || client > MaxClients || !g_ITDamageSummaryPending[client])
        return Plugin_Stop;

    // The post-death attribution window is complete.  Do not let the next
    // player who receives this client index inherit the old damage ledger.
    Traitor_FlushDamageSummary(client);
    return Plugin_Stop;
}

static void Traitor_QueueDamageSummary(int client, float delay)
{
    if (!IsValidClient(client))
        return;

    g_ITDamageSummaryPending[client] = true;
    CreateTimer(delay + 0.1, Timer_TraitorDamageSummary, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

public Action Traitor_OnTakeDamage(int victim, int &attacker, int &inflictor, float &damage, int &damagetype)
{
    if (!IsValidSurvivor(victim))
        return Plugin_Continue;

    g_ITPendingDamageAttacker[victim] = 0;
    g_ITSkipNextDamagePost[victim] = false;

    if (damage <= 0.0 || attacker < 1 || attacker > MaxClients || !Traitor_IsDamageAttributor(attacker))
        return Plugin_Continue;

    if (Traitor_IsSurvivorIncapacitated(victim))
    {
        // A Tank traitor may beat down only the upper half of incap HP.  Hits
        // that stay above the line are applied, but are intentionally omitted
        // from the Tank's 100-damage qualification total.
        if (Traitor_IsAliveClient(attacker) && g_ITClass[attacker] == TRAITOR_CLASS_TANK)
        {
            if (Traitor_ShouldCancelTankIncapHit(victim, damage))
            {
                damage = 0.0;
                return Plugin_Handled;
            }
        }

        return Plugin_Continue;
    }

    // Keep the attacker from the pre-damage state.  The post hook then uses
    // the final damage value after every other damage modifier has run.
    g_ITPendingDamageAttacker[victim] = attacker;
    return Plugin_Continue;
}

public void Traitor_OnTakeDamagePost(int victim, int attacker, int inflictor, float damage, int damagetype)
{
    if (victim < 1 || victim > MaxClients)
        return;

    int recordedAttacker = g_ITPendingDamageAttacker[victim];
    g_ITPendingDamageAttacker[victim] = 0;

    if (g_ITSkipNextDamagePost[victim])
    {
        g_ITSkipNextDamagePost[victim] = false;
        return;
    }

    if (recordedAttacker <= 0 || damage <= 0.0)
        return;

    Traitor_RecordDamage(recordedAttacker, RoundToNearest(damage));
}

public Action L4D_OnIncapacitated(int client, int &inflictor, int &attacker, float &damage, int &damagetype, int &weapon)
{
    if (client < 1 || client > MaxClients || !IsValidSurvivor(client))
        return Plugin_Continue;

    g_ITPendingIncapAttacker[client] = 0;
    g_ITSkipNextDamagePost[client] = false;

    if (damage > 0.0 && Traitor_IsDamageAttributor(attacker))
    {
        g_ITPendingIncapAttacker[client] = attacker;
        g_ITSkipNextDamagePost[client] = true;
    }

    return Plugin_Continue;
}

public void L4D_OnIncapacitated_Post(int client, int inflictor, int attacker, float damage, int damagetype, int weapon)
{
    if (client < 1 || client > MaxClients)
        return;

    int recordedAttacker = g_ITPendingIncapAttacker[client];
    g_ITPendingIncapAttacker[client] = 0;
    if (recordedAttacker > 0 && damage > 0.0)
        Traitor_RecordDamage(recordedAttacker, RoundToNearest(damage));
}

public void L4D_OnIncapacitated_PostHandled(int client, int inflictor, int attacker, float damage, int damagetype, int weapon)
{
    if (client < 1 || client > MaxClients)
        return;

    g_ITPendingIncapAttacker[client] = 0;
    g_ITSkipNextDamagePost[client] = false;
}

public void L4D_OnVomitedUpon_Post(int victim, int attacker, bool boomerExplosion)
{
    if (!IsValidSurvivor(victim)
        || attacker < 1
        || attacker > MaxClients
        || !Traitor_IsClassAttributor(attacker, view_as<int>(SI_Boomer)))
    {
        return;
    }

    // Boomer bile has no player_hurt health event, but it is a successful
    // versus attack and must prevent the no-damage traitor penalty.
    g_ITDidDamage[attacker] = true;
}

public void L4D2_CInsectSwarm_CanHarm_Post(int acid, int spitter, int entity)
{
    if (!IsValidSurvivor(entity)
        || !Traitor_IsClassAttributor(spitter, view_as<int>(SI_Spitter)))
    {
        return;
    }

    // The acid entity can continue ticking after its Spitter has died.  The
    // CanHarm forward preserves the original creator even when the later
    // SDK damage event no longer reports a live player as the attacker.
    g_ITDidDamage[spitter] = true;
}

void Traitor_OnSurvivorIncapacitated(int client)
{
    if (IsValidSurvivor(client))
        g_ITSurvivorIncapped[client] = true;
}

void Traitor_OnSurvivorRevived(int client)
{
    if (client >= 1 && client <= MaxClients)
        g_ITSurvivorIncapped[client] = false;
}

void Traitor_OnSurvivorDeath(int client)
{
    if (client >= 1 && client <= MaxClients)
        g_ITSurvivorIncapped[client] = false;
}

static void Traitor_ResetSurvivorDamageState()
{
    for (int client = 1; client <= MaxClients; client++)
    {
        g_ITPendingDamageAttacker[client] = 0;
        g_ITSurvivorIncapped[client] = false;
    }
}

static bool Traitor_IsManagedClient(int client)
{
    return IsValidClient(client) && g_ITState[client] != Traitor_None;
}

public any Native_InfectedControlIsTraitorClient(Handle plugin, int numParams)
{
    int client = GetNativeCell(1);
    return view_as<any>(Traitor_IsManagedClient(client));
}

bool Traitor_IsActiveClient(int client)
{
    return Traitor_IsAliveClient(client) && g_ITClass[client] >= 1 && g_ITClass[client] <= SI_COUNT;
}

bool Traitor_IsAliveClient(int client)
{
    return IsValidClient(client)
        && !IsFakeClient(client)
        && GetClientTeam(client) == TEAM_INFECTED
        && g_ITState[client] == Traitor_Alive
        && IsPlayerAlive(client)
        && !IsGhost(client)
        && Traitor_IsSupportedClass(g_ITClass[client]);
}

bool IsCountedSpecial(int client)
{
    return IsInfectedBot(client) || Traitor_IsActiveClient(client);
}

static bool Traitor_IsReservedState(TraitorState state)
{
    return state == Traitor_SpawnLocked || state == Traitor_SpawnAllowed;
}

static bool Traitor_IsSlotState(TraitorState state)
{
    return state == Traitor_Armed
        || state == Traitor_SpawnLocked
        || state == Traitor_SpawnAllowed
        || state == Traitor_Alive;
}

static void Traitor_CancelSpawnTimer(int client)
{
    if (client < 1 || client > MaxClients)
        return;

    if (g_ITSpawnTimer[client] != INVALID_HANDLE)
    {
        KillTimer(g_ITSpawnTimer[client]);
        g_ITSpawnTimer[client] = INVALID_HANDLE;
    }
    g_ITSpawnDeadline[client] = 0.0;
}

static void Traitor_EnsureNoDamageBlockMap()
{
    if (g_ITNoDamageBlockedAuths == null)
        g_ITNoDamageBlockedAuths = new StringMap();
}

static bool Traitor_GetClientAuth(int client, char[] auth, int maxlen)
{
    if (!IsValidClient(client) || IsFakeClient(client))
        return false;

    if (!GetClientAuthId(client, AuthId_Steam2, auth, maxlen, true))
        return false;

    return auth[0] != '\0'
        && !StrEqual(auth, "BOT", false)
        && !StrEqual(auth, "STEAM_ID_PENDING", false)
        && !StrEqual(auth, "STEAM_ID_STOP_IGNORING_RETVALS", false);
}

static void Traitor_SetNoDamageRoundBlock(int client)
{
    if (client < 1 || client > MaxClients)
        return;

    g_ITNoDamageBlockedThisRound[client] = true;
    Traitor_EnsureNoDamageBlockMap();

    char auth[TRAITOR_ROUND_AUTH_LENGTH];
    if (Traitor_GetClientAuth(client, auth, sizeof(auth)))
    {
        int remaining;
        if (!g_ITNoDamageBlockedAuths.GetValue(auth, remaining)
            || remaining < TRAITOR_NO_DAMAGE_BLOCK_ROUNDS)
        {
            g_ITNoDamageBlockedAuths.SetValue(auth, TRAITOR_NO_DAMAGE_BLOCK_ROUNDS);
        }
    }
}

static int Traitor_GetNoDamageBlockRounds(int client)
{
    if (client < 1 || client > MaxClients)
        return 0;

    if (g_ITNoDamageBlockedAuths == null)
        return g_ITNoDamageBlockedThisRound[client] ? 1 : 0;

    char auth[TRAITOR_ROUND_AUTH_LENGTH];
    if (!Traitor_GetClientAuth(client, auth, sizeof(auth)))
        return g_ITNoDamageBlockedThisRound[client] ? 1 : 0;

    int remaining;
    if (!g_ITNoDamageBlockedAuths.GetValue(auth, remaining) || remaining <= 0)
    {
        g_ITNoDamageBlockedThisRound[client] = false;
        return 0;
    }

    g_ITNoDamageBlockedThisRound[client] = true;
    return remaining;
}

static void Traitor_AdvanceNoDamageRoundBlocks()
{
    Traitor_EnsureNoDamageBlockMap();

    StringMapSnapshot snapshot = g_ITNoDamageBlockedAuths.Snapshot();
    char auth[TRAITOR_ROUND_AUTH_LENGTH];
    for (int i = 0; i < snapshot.Length; i++)
    {
        snapshot.GetKey(i, auth, sizeof(auth));

        int remaining;
        if (!g_ITNoDamageBlockedAuths.GetValue(auth, remaining))
            continue;

        remaining--;
        if (remaining <= 0)
            g_ITNoDamageBlockedAuths.Remove(auth);
        else
            g_ITNoDamageBlockedAuths.SetValue(auth, remaining);
    }
    delete snapshot;

    for (int client = 1; client <= MaxClients; client++)
        g_ITNoDamageBlockedThisRound[client] = false;
}

void Traitor_OnRoundStart()
{
    Traitor_AdvanceNoDamageRoundBlocks();
}

int Traitor_CountReservedClassSlots(int zc)
{
    if (zc < 1 || zc > SI_COUNT)
        return 0;

    int count = 0;
    for (int client = 1; client <= MaxClients; client++)
    {
        if (Traitor_IsReservedState(g_ITState[client]) && g_ITClass[client] == zc)
            count++;
    }
    return count;
}

int Traitor_CountReservedSlots()
{
    int count = 0;
    for (int client = 1; client <= MaxClients; client++)
    {
        if (Traitor_IsReservedState(g_ITState[client]))
            count++;
    }
    return count;
}

static int Traitor_CountReservedSlotsForWave(int waveIndex)
{
    int count = 0;
    for (int client = 1; client <= MaxClients; client++)
    {
        if (Traitor_IsReservedState(g_ITState[client])
            && g_ITReleaseWave[client] == waveIndex
            && g_ITClass[client] != TRAITOR_CLASS_TANK)
        {
            count++;
        }
    }
    return count;
}

bool Traitor_HasSpawnWork()
{
    for (int client = 1; client <= MaxClients; client++)
    {
        if (g_ITState[client] == Traitor_SpawnLocked || g_ITState[client] == Traitor_SpawnAllowed)
            return true;
    }
    return false;
}

int Traitor_AdjustWaveSpawnBudget(int baseBudget, int waveIndex)
{
    int reserved = Traitor_CountReservedSlotsForWave(waveIndex);
    int budget = baseBudget - reserved;
    if (budget < 0)
        budget = 0;

    Debug_Print("[TRAITOR] wave=%d baseBudget=%d reserved=%d aiBudget=%d", waveIndex, baseBudget, reserved, budget);
    return budget;
}

static int Traitor_CountManagedSlots()
{
    int count = 0;
    for (int client = 1; client <= MaxClients; client++)
    {
        if (Traitor_IsSlotState(g_ITState[client]))
            count++;
    }
    return count;
}

static int Traitor_GetWaitingPosition(int client)
{
    if (client < 1 || client > MaxClients || g_ITState[client] != Traitor_Waiting || g_ITWaitOrder[client] <= 0)
        return 0;

    int pos = 1;
    int order = g_ITWaitOrder[client];
    for (int other = 1; other <= MaxClients; other++)
    {
        if (other == client || g_ITState[other] != Traitor_Waiting || g_ITWaitOrder[other] <= 0)
            continue;

        if (g_ITWaitOrder[other] < order)
            pos++;
    }
    return pos;
}

static int Traitor_FindNextWaitingClient()
{
    int bestClient = 0;
    int bestOrder = 0;

    for (int client = 1; client <= MaxClients; client++)
    {
        if (g_ITState[client] != Traitor_Waiting)
            continue;

        if (!IsValidClient(client))
        {
            Traitor_ClearClient(client);
            continue;
        }

        if (!Traitor_IsClassSelectable(g_ITClass[client]))
        {
            CPrintToChat(client, "%t", "InfectedControl_TraitorClassDisabled");
            Traitor_ClearClient(client);
            continue;
        }

        if (g_ITClass[client] == TRAITOR_CLASS_TANK && !TraitorQuota_CanUseTank(client))
        {
            Traitor_ClearClient(client);
            continue;
        }

        int order = g_ITWaitOrder[client];
        if (order <= 0)
            order = 999999;

        if (bestClient == 0 || order < bestOrder)
        {
            bestClient = client;
            bestOrder = order;
        }
    }

    return bestClient;
}

void Traitor_ActivateWaitingClients()
{
    if (!gCV.bTraitorEnable || gCV.iTraitorMaxSlots <= 0)
        return;

    while (Traitor_CountManagedSlots() < gCV.iTraitorMaxSlots)
    {
        int client = Traitor_FindNextWaitingClient();
        if (client <= 0)
            return;

        int zc = g_ITClass[client];
        g_ITState[client] = Traitor_Armed;
        g_ITReleaseWave[client] = 0;
        g_ITWaitOrder[client] = 0;

        char className[64];
        Traitor_FormatClassName(zc, client, className, sizeof(className));
        CPrintToChat(client, "%t", "InfectedControl_TraitorWaitPromoted", className);
        Debug_Print("[TRAITOR] %N promoted from waitlist as %s", client, g_sInfectedClassNames[zc]);
    }
}

static void Traitor_ReplaceExpiredSlotWithAI(int client)
{
    if (client < 1 || client > MaxClients)
        return;

    if (g_ITClass[client] != TRAITOR_CLASS_TANK && gST.siQueueCount < gCV.iSiLimit)
        gST.siQueueCount++;

    Debug_Print("[TRAITOR] %N spawn window expired, returned slot to AI queue=%d", client, gST.siQueueCount);
}

static void Traitor_ShowSpawnCountdown(int client)
{
    if (!IsValidClient(client) || g_ITSpawnDeadline[client] <= 0.0)
        return;

    int seconds = RoundToCeil(g_ITSpawnDeadline[client] - GetGameTime());
    if (seconds < 1)
        seconds = 1;

    PrintHintText(client, "%t", "InfectedControl_TraitorSpawnCountdown", seconds);
}

static int Traitor_GetAllowedClassMask()
{
    int mask = gCV.iTraitorClassMask;
    if (mask <= 0)
        mask = TRAITOR_CLASS_MASK_ALL;

    return mask & TRAITOR_CLASS_MASK_ALL;
}

static bool Traitor_IsSupportedClass(int zc)
{
    return (zc >= 1 && zc <= SI_COUNT) || zc == TRAITOR_CLASS_TANK;
}

static int Traitor_GetClassBit(int zc)
{
    if (zc >= 1 && zc <= SI_COUNT)
        return 1 << (zc - 1);

    if (zc == TRAITOR_CLASS_TANK)
        return TRAITOR_CLASS_MASK_TANK;

    return 0;
}

static bool Traitor_IsClassSelectable(int zc)
{
    if (!Traitor_IsSupportedClass(zc))
        return false;

    int bit = Traitor_GetClassBit(zc);
    return (Traitor_GetAllowedClassMask() & bit) != 0;
}

static int Traitor_CountSelectableClasses()
{
    int count = 0;
    for (int zc = 1; zc <= SI_COUNT; zc++)
    {
        if (Traitor_IsClassSelectable(zc))
            count++;
    }

    if (Traitor_IsClassSelectable(TRAITOR_CLASS_TANK))
        count++;

    return count;
}

int Traitor_PickRandomEnabledClass()
{
    int classes[SI_COUNT + 1];
    int count = 0;

    for (int zc = 1; zc <= SI_COUNT; zc++)
    {
        if (!Traitor_IsClassSelectable(zc))
            continue;

        classes[count++] = zc;
    }

    if (Traitor_IsClassSelectable(TRAITOR_CLASS_TANK))
        classes[count++] = TRAITOR_CLASS_TANK;

    if (count <= 0)
        return 0;

    return classes[GetRandomInt(0, count - 1)];
}

static bool Traitor_IsRandomClassArg(const char[] arg)
{
    return StrEqual(arg, "random", false) || StrEqual(arg, "随机", false);
}

static int Traitor_ParseClass(const char[] arg)
{
    if (StrEqual(arg, "sm", false) || StrEqual(arg, "smoker", false) || StrEqual(arg, "舌", false))
        return view_as<int>(SI_Smoker);

    if (StrEqual(arg, "bm", false) || StrEqual(arg, "boomer", false) || StrEqual(arg, "胖", false) || StrEqual(arg, "胖子", false))
        return view_as<int>(SI_Boomer);

    if (StrEqual(arg, "ht", false) || StrEqual(arg, "hunter", false) || StrEqual(arg, "猎", false) || StrEqual(arg, "猎人", false))
        return view_as<int>(SI_Hunter);

    if (StrEqual(arg, "sp", false) || StrEqual(arg, "spitter", false) || StrEqual(arg, "口水", false))
        return view_as<int>(SI_Spitter);

    if (StrEqual(arg, "jk", false) || StrEqual(arg, "jockey", false) || StrEqual(arg, "猴", false) || StrEqual(arg, "猴子", false))
        return view_as<int>(SI_Jockey);

    if (StrEqual(arg, "ch", false) || StrEqual(arg, "charger", false) || StrEqual(arg, "牛", false))
        return view_as<int>(SI_Charger);

    if (StrEqual(arg, "tank", false) || StrEqual(arg, "tk", false) || StrEqual(arg, "坦克", false))
        return TRAITOR_CLASS_TANK;

    return 0;
}

static int Traitor_GetClassCost(int zc)
{
    switch (zc)
    {
        case view_as<int>(SI_Smoker): return 5;
        case view_as<int>(SI_Boomer): return 5;
        case view_as<int>(SI_Hunter): return 2;
        case view_as<int>(SI_Spitter): return 5;
        case view_as<int>(SI_Jockey): return 2;
        case view_as<int>(SI_Charger): return 5;
        case TRAITOR_CLASS_TANK: return 50;
    }

    return 1;
}

static bool Traitor_GetClassPhrase(int zc, char[] phrase, int maxlen)
{
    switch (zc)
    {
        case view_as<int>(SI_Smoker):
        {
            strcopy(phrase, maxlen, "InfectedControl_TraitorClassSmoker");
            return true;
        }
        case view_as<int>(SI_Boomer):
        {
            strcopy(phrase, maxlen, "InfectedControl_TraitorClassBoomer");
            return true;
        }
        case view_as<int>(SI_Hunter):
        {
            strcopy(phrase, maxlen, "InfectedControl_TraitorClassHunter");
            return true;
        }
        case view_as<int>(SI_Spitter):
        {
            strcopy(phrase, maxlen, "InfectedControl_TraitorClassSpitter");
            return true;
        }
        case view_as<int>(SI_Jockey):
        {
            strcopy(phrase, maxlen, "InfectedControl_TraitorClassJockey");
            return true;
        }
        case view_as<int>(SI_Charger):
        {
            strcopy(phrase, maxlen, "InfectedControl_TraitorClassCharger");
            return true;
        }
        case TRAITOR_CLASS_TANK:
        {
            strcopy(phrase, maxlen, "InfectedControl_TraitorClassTank");
            return true;
        }
    }

    phrase[0] = '\0';
    return false;
}

static void Traitor_FormatClassName(int zc, int client, char[] buffer, int maxlen)
{
    char phrase[64];
    if (Traitor_GetClassPhrase(zc, phrase, sizeof(phrase)))
    {
        Format(buffer, maxlen, "%T", phrase, client);
        return;
    }

    if (zc >= 0 && zc < sizeof(g_sInfectedClassNames))
        strcopy(buffer, maxlen, g_sInfectedClassNames[zc]);
    else
        strcopy(buffer, maxlen, "unknown");
}

static bool Traitor_CheckUseLimit(int client, int zc = 0)
{
    if (zc == TRAITOR_CLASS_TANK && !TraitorQuota_CanUseTank(client))
        return false;

    if (g_ITState[client] != Traitor_None)
        return true;

    int noDamageBlockRounds = (zc != TRAITOR_CLASS_TANK) ? Traitor_GetNoDamageBlockRounds(client) : 0;
    if (noDamageBlockRounds > 0)
    {
        CPrintToChat(client, "%t", "InfectedControl_TraitorRoundBlockedNoDamage", noDamageBlockRounds);
        return false;
    }

    if (zc != TRAITOR_CLASS_TANK
        && gCV.iTraitorAdminLimit > 0
        && g_ITUsesThisRound[client] >= gCV.iTraitorAdminLimit)
    {
        CPrintToChat(client, "%t", "InfectedControl_TraitorLimitReached", gCV.iTraitorAdminLimit);
        return false;
    }

    return TraitorQuota_CanUse(client, Traitor_GetClassCost(zc));
}

static void Traitor_FinalizeAliveClient(int client)
{
    if (client < 1 || client > MaxClients || g_ITState[client] != Traitor_Alive)
        return;

    if (Traitor_IsSurvivorTeamWiped())
        return;

    if (g_ITClass[client] != TRAITOR_CLASS_TANK)
        return;

    if (g_ITDamageTotal[client] >= TRAITOR_TANK_MIN_DAMAGE)
        return;

    if (TraitorQuota_BlockTank(client, TRAITOR_TANK_BLOCK_SECONDS))
    {
        CPrintToChat(client, "%t",
            "InfectedControl_TraitorTankDamagePunished",
            g_ITDamageTotal[client],
            TRAITOR_TANK_MIN_DAMAGE);
        CPrintToChat(client, "%t",
            "InfectedControl_TraitorTankBlockApplied",
            TRAITOR_TANK_BLOCK_DAYS);
    }
}

static void Traitor_ClearClient(int client, bool preserveDamageLedger = false)
{
    if (client < 1 || client > MaxClients)
        return;

    g_ITState[client] = Traitor_None;
    g_ITClass[client] = 0;
    g_ITReleaseWave[client] = 0;
    g_ITWaitOrder[client] = 0;
    if (!preserveDamageLedger)
    {
        g_ITDidDamage[client] = false;
        g_ITDamageTotal[client] = 0;
        g_ITDamageLedgerActive[client] = false;
        g_ITDamageLedgerExpire[client] = 0.0;
        g_ITDamageLedgerClass[client] = 0;
    }
    g_ITRefreshPending[client] = false;
    g_ITRefreshClass[client] = 0;
    Traitor_CancelSpawnTimer(client);
}

void Traitor_ResetAll(bool moveClientsToSpec)
{
    Traitor_EnsureNoDamageBlockMap();
    // No-damage blocks are decremented explicitly on round_start and must
    // survive the normal per-round traitor state reset.

    for (int client = 1; client <= MaxClients; client++)
    {
        if (moveClientsToSpec && Traitor_IsManagedClient(client) && IsClientInGame(client) && GetClientTeam(client) == TEAM_INFECTED)
            ChangeClientTeam(client, 1);

        bool preserveDamageSummary = g_ITDamageSummaryPending[client];
        Traitor_ClearClient(client, preserveDamageSummary);
        g_ITUsesThisRound[client] = 0;
        g_ITNoDamageBlockedThisRound[client] = false;
        if (!preserveDamageSummary)
        {
            g_ITDamageLedgerActive[client] = false;
            g_ITDamageLedgerExpire[client] = 0.0;
            g_ITDamageLedgerClass[client] = 0;
        }
    }
    g_ITNextWaitOrder = 1;
    Traitor_ResetSurvivorDamageState();
}

bool Traitor_IsRegistrationOpen()
{
    if (!gCV.bTraitorEnable || !gST.bLate)
        return false;

    WaveDecisionState state = WaveDecider_GetState();
    return state == WD_EarlyCheck || state == WD_Idle;
}

static bool Traitor_PrepareGhostClient(int client, int zc)
{
    if (!IsValidClient(client))
        return false;

    if (GetClientTeam(client) == TEAM_SURVIVOR && IsPlayerAlive(client))
        L4D_ReplaceWithBot(client);

    if (GetClientTeam(client) != TEAM_INFECTED)
        ChangeClientTeam(client, TEAM_INFECTED);

    if (GetClientTeam(client) != TEAM_INFECTED)
        return false;

    // A spectator does not have a dead infected body for RoundRespawn to
    // revive.  Enter the infected ghost state directly first; the respawn
    // path below remains a fallback for game builds that reject the direct
    // transition for an already-dead infected player.
    L4D_State_Transition(client, STATE_GHOST);
    L4D_SetClass(client, zc);

    if (!IsGhost(client))
    {
        if (!IsPlayerAlive(client))
            L4D_RespawnPlayer(client, false);

        L4D_SetClass(client, zc);
        L4D_BecomeGhost(client);
    }

    // Some builds only apply the player state on the next transition after
    // RoundRespawn.  Retry the direct transition once before reporting a
    // failed registration.
    if (!IsGhost(client))
    {
        L4D_State_Transition(client, STATE_GHOST);
        L4D_SetClass(client, zc);
    }

    return IsGhost(client) && GetEntProp(client, Prop_Send, "m_zombieClass") == zc;
}

static void Traitor_PrintPenaltyWarnings(int client, int zc)
{
    if (zc != TRAITOR_CLASS_TANK)
    {
        CPrintToChat(client, "%t", "InfectedControl_TraitorPenaltyNoDamageWarning");
        CPrintToChat(client, "%t", "InfectedControl_TraitorPenaltyNoDamageBlock", TRAITOR_NO_DAMAGE_BLOCK_ROUNDS);
        return;
    }

    CPrintToChat(client, "%t",
        "InfectedControl_TraitorPenaltyTankDamageWarning",
        TRAITOR_TANK_MIN_DAMAGE);
    CPrintToChat(client, "%t",
        "InfectedControl_TraitorPenaltyTankDamageBlock",
        TRAITOR_TANK_BLOCK_DAYS);
}

static bool Traitor_ShouldReplaceTankWithAI(int client)
{
    return client >= 1
        && client <= MaxClients
        && g_ITState[client] == Traitor_Alive
        && g_ITClass[client] == TRAITOR_CLASS_TANK
        && Traitor_IsAliveClient(client);
}

static void Traitor_ReplaceTankWithAI(int client)
{
    if (!Traitor_ShouldReplaceTankWithAI(client))
        return;

    Debug_Print("[TRAITOR] %N disconnected while controlling Tank, handing Tank to AI", client);
    L4D_ReplaceWithBot(client);
}

static bool Traitor_QueueRefreshBot(int bot, int zc)
{
    if (!IsInfectedBot(bot) || !IsPlayerAlive(bot) || GetInfectedClass(bot) != zc)
        return false;

    TeleportQueue_Push(zc);

    if (gST.siAlive[zc - 1] > 0)
        gST.siAlive[zc - 1]--;
    if (gST.totalSI > 0)
        gST.totalSI--;

    gST.teleCount[bot] = 0;
    g_LastSpawnTime[bot] = 0.0;
    InvalidateBucketShareCache();

    Debug_Print("[TRAITOR] AI bot %N class=%s queued for forced teleport refresh", bot, g_sInfectedClassNames[zc]);
    KickClient(bot, "Traitor SI refresh");
    return true;
}

void Traitor_OnPlayerBotReplace(int player, int bot)
{
    if (player < 1 || player > MaxClients || !g_ITRefreshPending[player])
        return;

    int zc = g_ITRefreshClass[player];
    if (Traitor_QueueRefreshBot(bot, zc))
    {
        g_ITRefreshPending[player] = false;
        g_ITRefreshClass[player] = 0;
    }
}

static Action Timer_TraitorRefreshFallback(Handle timer, int userid)
{
    int player = GetClientOfUserId(userid);
    if (player < 1 || player > MaxClients || !g_ITRefreshPending[player])
        return Plugin_Stop;

    int zc = g_ITRefreshClass[player];
    int bestBot = 0;
    float bestDistance = 128.0;

    for (int bot = 1; bot <= MaxClients; bot++)
    {
        if (!IsInfectedBot(bot) || !IsPlayerAlive(bot) || GetInfectedClass(bot) != zc)
            continue;

        float origin[3];
        GetClientAbsOrigin(bot, origin);
        float distance = GetVectorDistance(origin, g_ITRefreshOrigin[player]);
        if (distance < bestDistance)
        {
            bestDistance = distance;
            bestBot = bot;
        }
    }

    if (bestBot > 0 && Traitor_QueueRefreshBot(bestBot, zc))
    {
        g_ITRefreshPending[player] = false;
        g_ITRefreshClass[player] = 0;
    }
    else
    {
        Debug_Print("[TRAITOR] no replacement AI found for refresh fallback player=%d class=%d", player, zc);
        g_ITRefreshPending[player] = false;
        g_ITRefreshClass[player] = 0;
    }

    return Plugin_Stop;
}

static bool Traitor_QueueClient(int client, int zc)
{
    if (g_ITState[client] == Traitor_None && g_ITDamageSummaryPending[client])
        Traitor_FlushDamageSummary(client);

    if (!gCV.bTraitorEnable)
    {
        CPrintToChat(client, "%t", "InfectedControl_TraitorDisabled");
        return false;
    }

    if (!Traitor_IsRegistrationOpen())
    {
        CPrintToChat(client, "%t", "InfectedControl_TraitorWindowClosed");
        return false;
    }

    if (g_ITState[client] != Traitor_None && g_ITState[client] != Traitor_Waiting && g_ITState[client] != Traitor_Armed)
    {
        CPrintToChat(client, "%t", "InfectedControl_TraitorPending");
        return false;
    }

    if (gCV.iTraitorMaxSlots <= 0)
    {
        CPrintToChat(client, "%t", "InfectedControl_TraitorNoSlot");
        return false;
    }

    if (!Traitor_IsClassSelectable(zc))
    {
        CPrintToChat(client, "%t", "InfectedControl_TraitorClassDisabled");
        return false;
    }

    if (!Traitor_CheckUseLimit(client, zc))
        return false;

    bool isNewQueue = (g_ITState[client] == Traitor_None);
    bool hasSlot = (g_ITState[client] == Traitor_Armed || Traitor_CountManagedSlots() < gCV.iTraitorMaxSlots);

    g_ITState[client] = hasSlot ? Traitor_Armed : Traitor_Waiting;
    g_ITClass[client] = zc;
    g_ITReleaseWave[client] = 0;
    if (!hasSlot && g_ITWaitOrder[client] <= 0)
        g_ITWaitOrder[client] = g_ITNextWaitOrder++;
    else if (hasSlot)
        g_ITWaitOrder[client] = 0;

    if (isNewQueue && zc != TRAITOR_CLASS_TANK)
        g_ITUsesThisRound[client]++;

    char className[64];
    Traitor_FormatClassName(zc, client, className, sizeof(className));
    if (hasSlot)
    {
        CPrintToChat(client, "%t", "InfectedControl_TraitorQueued", className);
        Debug_Print("[TRAITOR] %N queued as %s use=%d/%d", client, g_sInfectedClassNames[zc], g_ITUsesThisRound[client], gCV.iTraitorAdminLimit);
    }
    else
    {
        CPrintToChat(client, "%t", "InfectedControl_TraitorWaiting", className, Traitor_GetWaitingPosition(client));
        Debug_Print("[TRAITOR] %N waitlisted as %s pos=%d use=%d/%d", client, g_sInfectedClassNames[zc], Traitor_GetWaitingPosition(client), g_ITUsesThisRound[client], gCV.iTraitorAdminLimit);
    }
    Traitor_PrintPenaltyWarnings(client, zc);
    return true;
}

static void Traitor_AddClassMenuItem(Menu menu, int zc, int client)
{
    char info[8];
    IntToString(zc, info, sizeof(info));

    char display[64];
    Traitor_FormatClassName(zc, client, display, sizeof(display));
    menu.AddItem(info, display);
}

static void Traitor_ShowClassMenu(int client)
{
    if (!gCV.bTraitorEnable)
    {
        CPrintToChat(client, "%t", "InfectedControl_TraitorDisabled");
        return;
    }

    if (!Traitor_IsRegistrationOpen())
    {
        CPrintToChat(client, "%t", "InfectedControl_TraitorWindowClosed");
        return;
    }

    if (gCV.iTraitorMaxSlots <= 0)
    {
        CPrintToChat(client, "%t", "InfectedControl_TraitorNoSlot");
        return;
    }

    if (Traitor_CountSelectableClasses() <= 0)
    {
        CPrintToChat(client, "%t", "InfectedControl_TraitorNoEnabledClass");
        return;
    }

    Menu menu = new Menu(Traitor_MenuHandler);
    menu.SetTitle("%T", "InfectedControl_TraitorMenuTitle", client);
    menu.ExitButton = true;

    char randomText[64];
    Format(randomText, sizeof(randomText), "%T", "InfectedControl_TraitorMenuRandom", client);
    menu.AddItem("random", randomText);

    for (int zc = 1; zc <= SI_COUNT; zc++)
    {
        if (!Traitor_IsClassSelectable(zc))
            continue;

        Traitor_AddClassMenuItem(menu, zc, client);
    }

    if (Traitor_IsClassSelectable(TRAITOR_CLASS_TANK))
        Traitor_AddClassMenuItem(menu, TRAITOR_CLASS_TANK, client);

    if (!menu.Display(client, MENU_TIME_FOREVER))
        delete menu;
}

public int Traitor_MenuHandler(Menu menu, MenuAction action, int client, int item)
{
    if (action == MenuAction_End)
    {
        delete menu;
        return 0;
    }

    if (action != MenuAction_Select)
        return 0;

    if (!IsValidClient(client))
        return 0;

    char info[16];
    if (!menu.GetItem(item, info, sizeof(info)))
        return 0;

    int zc = 0;
    if (StrEqual(info, "random", false))
        zc = Traitor_PickRandomEnabledClass();
    else
        zc = StringToInt(info);

    if (zc <= 0)
    {
        CPrintToChat(client, "%t", "InfectedControl_TraitorNoEnabledClass");
        return 0;
    }

    Traitor_QueueClient(client, zc);
    return 0;
}

static void Traitor_ReleaseNoDamageClientsToAI()
{
    if (Traitor_IsSurvivorTeamWiped())
        return;

    bool freedSlot = false;

    for (int client = 1; client <= MaxClients; client++)
    {
        if (g_ITState[client] != Traitor_Alive
            || g_ITClass[client] == TRAITOR_CLASS_TANK
            || g_ITDidDamage[client])
            continue;

        if (!IsValidClient(client)
            || GetClientTeam(client) != TEAM_INFECTED
            || !IsPlayerAlive(client)
            || IsGhost(client))
        {
            continue;
        }

        int zc = g_ITClass[client];
        Traitor_SetNoDamageRoundBlock(client);
        CPrintToChat(client, "%t", "InfectedControl_TraitorNoDamagePunished");
        CPrintToChat(client, "%t", "InfectedControl_TraitorNoDamageBlockApplied", TRAITOR_NO_DAMAGE_BLOCK_ROUNDS);

        // Revoke the human traitor role before handing the infected body to
        // the game AI.  This avoids the player_death path and lets the
        // existing AI teleport/refresh monitor manage the replacement.
        bool canReplace = IsValidClient(client)
            && GetClientTeam(client) == TEAM_INFECTED
            && IsPlayerAlive(client)
            && !IsGhost(client);

        Debug_Print("[TRAITOR] %N had no damage before next countdown; role revoked and AI takeover=%d", client, canReplace);
        Traitor_ClearClient(client);

        if (canReplace)
        {
            g_ITRefreshPending[client] = true;
            g_ITRefreshClass[client] = zc;
            GetClientAbsOrigin(client, g_ITRefreshOrigin[client]);
            L4D_ReplaceWithBot(client);
            CreateTimer(0.15, Timer_TraitorRefreshFallback, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
        }

        freedSlot = true;
    }

    if (freedSlot)
    {
        InvalidateBucketShareCache();
        RecalcSiCapFromAlive(false);
        Traitor_ActivateWaitingClients();
        CreateTimer(0.2, Timer_TraitorRefreshRecalc, _, TIMER_FLAG_NO_MAPCHANGE);
    }
}

static Action Timer_TraitorRefreshRecalc(Handle timer)
{
    RecalcSiCapFromAlive(false);
    return Plugin_Stop;
}

static void Traitor_BroadcastNextWaveStatus(int releaseWave)
{
    for (int client = 1; client <= MaxClients; client++)
    {
        if (!(g_ITState[client] == Traitor_SpawnLocked && g_ITReleaseWave[client] == releaseWave))
            continue;

        if (!IsValidClient(client))
            continue;

        char playerName[MAX_NAME_LENGTH];
        GetClientName(client, playerName, sizeof(playerName));

        char className[64];
        Traitor_FormatClassName(g_ITClass[client], client, className, sizeof(className));

        CPrintToChatAll("%t", "InfectedControl_TraitorNextWaveRegistered", playerName, className);
    }
}

Action Traitor_OnPlayerRunCmd(int client, int &buttons)
{
    return Traitor_TryAutoBhop(client, buttons);
}

static Action Traitor_TryAutoBhop(int client, int &buttons)
{
    if (!(buttons & IN_JUMP))
        return Plugin_Continue;

    if (!Traitor_IsAliveClient(client))
        return Plugin_Continue;

    if (GetEntityFlags(client) & FL_ONGROUND)
        return Plugin_Continue;

    buttons &= ~IN_JUMP;
    return Plugin_Changed;
}

void Traitor_OnFinalRefreshStarted()
{
    Traitor_ReleaseNoDamageClientsToAI();

    int releaseWave = gST.waveIndex + 1;
    bool freedSlot = false;

    for (int client = 1; client <= MaxClients; client++)
    {
        if (g_ITState[client] != Traitor_Armed)
            continue;

        if (!IsValidClient(client) || !Traitor_PrepareGhostClient(client, g_ITClass[client]))
        {
            Traitor_ClearClient(client);
            if (IsValidClient(client))
                CPrintToChat(client, "%t", "InfectedControl_TraitorFailed");
            freedSlot = true;
            continue;
        }

        g_ITState[client] = Traitor_SpawnLocked;
        g_ITReleaseWave[client] = releaseWave;
        float seconds = DifficultyStrategy_GetConfiguredWaveDelay();
        CPrintToChat(client, "%t", "InfectedControl_TraitorWaveCountdown", RoundToCeil(seconds));
        CPrintToChat(client, "%t", "InfectedControl_TraitorPending");
        Debug_Print("[TRAITOR] %N locked for wave %d as %s", client, releaseWave, g_sInfectedClassNames[g_ITClass[client]]);
    }

    Traitor_BroadcastNextWaveStatus(releaseWave);

    if (freedSlot)
        Traitor_ActivateWaitingClients();
}

void Traitor_OnWaveReleased(int waveIndex)
{
    for (int client = 1; client <= MaxClients; client++)
    {
        if (g_ITState[client] == Traitor_SpawnLocked && g_ITReleaseWave[client] == waveIndex)
            Traitor_StartSpawnWindow(client);
    }
}

static void Traitor_StartSpawnWindow(int client)
{
    if (!IsValidClient(client) || g_ITState[client] != Traitor_SpawnLocked)
        return;

    g_ITState[client] = Traitor_SpawnAllowed;
    Traitor_CancelSpawnTimer(client);
    g_ITSpawnDeadline[client] = GetGameTime() + float(TRAITOR_SPAWN_WINDOW_SECONDS);
    g_ITSpawnTimer[client] = CreateTimer(1.0, Timer_TraitorSpawnCountdown, GetClientUserId(client), TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    CPrintToChat(client, "%t", "InfectedControl_TraitorSpawnWindow", TRAITOR_SPAWN_WINDOW_SECONDS);
    CPrintToChat(client, "%t", "InfectedControl_TraitorSpawnAllowed");
    Traitor_ShowSpawnCountdown(client);
    Debug_Print("[TRAITOR] %N spawn attempts allowed wave=%d deadline=%.2f", client, gST.waveIndex, g_ITSpawnDeadline[client]);
}

static Action Timer_TraitorSpawnCountdown(Handle timer, int userid)
{
    int client = GetClientOfUserId(userid);
    if (client <= 0 || client > MaxClients)
        return Plugin_Stop;

    if (g_ITSpawnTimer[client] != timer)
        return Plugin_Stop;

    if (!IsValidClient(client) || g_ITState[client] != Traitor_SpawnAllowed)
    {
        g_ITSpawnTimer[client] = INVALID_HANDLE;
        g_ITSpawnDeadline[client] = 0.0;
        return Plugin_Stop;
    }

    int seconds = RoundToCeil(g_ITSpawnDeadline[client] - GetGameTime());
    if (seconds > 0)
    {
        PrintHintText(client, "%t", "InfectedControl_TraitorSpawnCountdown", seconds);
        return Plugin_Continue;
    }

    g_ITSpawnTimer[client] = INVALID_HANDLE;
    CPrintToChat(client, "%t", "InfectedControl_TraitorSpawnExpired");
    Traitor_ReplaceExpiredSlotWithAI(client);
    Traitor_ClearClient(client);
    Traitor_ActivateWaitingClients();
    return Plugin_Stop;
}

public Action Cmd_Traitor(int client, int args)
{
    if (!client || !IsClientInGame(client))
        return Plugin_Handled;

    if (args < 1)
    {
        Traitor_ShowClassMenu(client);
        return Plugin_Handled;
    }

    char arg[32];
    GetCmdArg(1, arg, sizeof(arg));

    int zc = 0;
    if (Traitor_IsRandomClassArg(arg))
        zc = Traitor_PickRandomEnabledClass();
    else
        zc = Traitor_ParseClass(arg);

    if (zc == 0)
    {
        if (Traitor_IsRandomClassArg(arg))
            CPrintToChat(client, "%t", "InfectedControl_TraitorNoEnabledClass");
        else
            CPrintToChat(client, "%t", "InfectedControl_TraitorUnsupportedClass");
        return Plugin_Handled;
    }

    Traitor_QueueClient(client, zc);
    return Plugin_Handled;
}

public Action Cmd_TraitorCancel(int client, int args)
{
    if (!client || !IsClientInGame(client))
        return Plugin_Handled;

    if (g_ITState[client] == Traitor_None || g_ITState[client] == Traitor_Alive)
    {
        CPrintToChat(client, "%t", "InfectedControl_TraitorNotQueued");
        return Plugin_Handled;
    }

    bool freedSlot = Traitor_IsSlotState(g_ITState[client]);
    Traitor_ClearClient(client);
    CPrintToChat(client, "%t", "InfectedControl_TraitorCancelled");
    if (freedSlot)
        Traitor_ActivateWaitingClients();
    return Plugin_Handled;
}

public Action L4D_OnMaterializeFromGhostPre(int client)
{
    if (!Traitor_IsManagedClient(client))
        return Plugin_Continue;

    if (!IsValidClient(client)
        || g_ITState[client] != Traitor_SpawnAllowed
        || gST.waveIndex < g_ITReleaseWave[client]
        || (g_ITClass[client] != TRAITOR_CLASS_TANK && gST.totalSI >= gCV.iSiLimit))
    {
        CPrintToChat(client, "%t", "InfectedControl_TraitorWaitForWave");
        return Plugin_Handled;
    }

    if (!TraitorQuota_CanUse(client, Traitor_GetClassCost(g_ITClass[client])))
        return Plugin_Handled;

    if (g_ITClass[client] == TRAITOR_CLASS_TANK && !TraitorQuota_CanUseTank(client))
        return Plugin_Handled;

    return Plugin_Continue;
}

public void L4D_OnMaterializeFromGhost(int client)
{
    if (!Traitor_IsManagedClient(client) || g_ITState[client] != Traitor_SpawnAllowed)
        return;

    int zc = GetEntProp(client, Prop_Send, "m_zombieClass");
    if (!Traitor_IsSupportedClass(zc))
        zc = g_ITClass[client];

    if (!Traitor_IsSupportedClass(zc))
    {
        Traitor_ClearClient(client);
        return;
    }

    TraitorQuota_Consume(client, Traitor_GetClassCost(zc));

    g_ITState[client] = Traitor_Alive;
    g_ITClass[client] = zc;
    g_ITDamageLedgerActive[client] = true;
    g_ITDamageLedgerExpire[client] = 0.0;
    g_ITDamageLedgerClass[client] = zc;
    g_ITDidDamage[client] = false;
    g_ITDamageTotal[client] = 0;
    Traitor_CancelSpawnTimer(client);
    if (zc >= 1 && zc <= SI_COUNT)
    {
        gST.siAlive[zc - 1]++;
        gST.totalSI++;
    }
    char className[64];
    Traitor_FormatClassName(zc, client, className, sizeof(className));
    CPrintToChat(client, "%t", "InfectedControl_TraitorSpawned", className);
    CPrintToChat(client, "%t", "InfectedControl_TraitorBhopEnabled");
    Debug_Print("[TRAITOR] %N materialized as %s", client, g_sInfectedClassNames[zc]);
}

bool Traitor_OnPlayerDeath(int client)
{
    if (!Traitor_IsManagedClient(client))
        return false;

    bool wasAlive = (g_ITState[client] == Traitor_Alive);
    float summaryDelay = wasAlive ? Traitor_GetPostDeathDamageWindow(g_ITClass[client]) : 0.0;
    Traitor_FinalizeAliveClient(client);
    bool preserveDamageLedger = Traitor_OpenDamageLedger(client);
    Traitor_ClearClient(client, preserveDamageLedger);
    if (wasAlive)
        Traitor_QueueDamageSummary(client, summaryDelay);
    InvalidateBucketShareCache();
    RecalcSiCapFromAlive(false);
    Traitor_ActivateWaitingClients();
    return true;
}

void Traitor_OnClientDisconnect(int client)
{
    if (client < 1 || client > MaxClients)
        return;

    if (g_ITState[client] == Traitor_None)
        return;

    bool freedSlot = (client >= 1 && client <= MaxClients && Traitor_IsSlotState(g_ITState[client]));
    bool wasAlive = (client >= 1 && client <= MaxClients && g_ITState[client] == Traitor_Alive);

    Traitor_ReplaceTankWithAI(client);
    Traitor_FinalizeAliveClient(client);
    bool preserveDamageLedger = Traitor_OpenDamageLedger(client);
    Traitor_ClearClient(client, preserveDamageLedger);
    if (client >= 1 && client <= MaxClients)
    {
        g_ITUsesThisRound[client] = 0;
        g_ITNoDamageBlockedThisRound[client] = false;
    }
    if (wasAlive)
        RecalcSiCapFromAlive(false);
    if (freedSlot)
        Traitor_ActivateWaitingClients();
}

void Traitor_OnClientTeamChanged(int client, int oldTeam, int newTeam)
{
    if (!Traitor_IsManagedClient(client))
        return;

    if (oldTeam == newTeam)
        return;

    if (newTeam == TEAM_INFECTED)
        return;

    bool wasAlive = (g_ITState[client] == Traitor_Alive);
    bool freedSlot = Traitor_IsSlotState(g_ITState[client]);
    Traitor_FinalizeAliveClient(client);
    bool preserveDamageLedger = Traitor_OpenDamageLedger(client);
    Traitor_ClearClient(client, preserveDamageLedger);

    if (wasAlive)
        RecalcSiCapFromAlive(false);
    if (freedSlot)
        Traitor_ActivateWaitingClients();
}
