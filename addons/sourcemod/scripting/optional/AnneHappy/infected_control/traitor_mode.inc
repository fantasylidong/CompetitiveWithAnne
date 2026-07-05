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
static bool g_ITNoDamageBlockedThisRound[MAXPLAYERS + 1];
static float g_ITSpawnDeadline[MAXPLAYERS + 1];
static Handle g_ITSpawnTimer[MAXPLAYERS + 1];
static StringMap g_ITNoDamageBlockedAuths = null;

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
        g_ITNoDamageBlockedAuths.SetValue(auth, 1);
}

static bool Traitor_IsNoDamageRoundBlocked(int client)
{
    if (client < 1 || client > MaxClients)
        return false;

    if (g_ITNoDamageBlockedThisRound[client])
        return true;

    if (g_ITNoDamageBlockedAuths == null)
        return false;

    char auth[TRAITOR_ROUND_AUTH_LENGTH];
    if (!Traitor_GetClientAuth(client, auth, sizeof(auth)))
        return false;

    int blocked;
    if (!g_ITNoDamageBlockedAuths.GetValue(auth, blocked))
        return false;

    g_ITNoDamageBlockedThisRound[client] = true;
    return true;
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
        case view_as<int>(SI_Smoker): return 3;
        case view_as<int>(SI_Boomer): return 3;
        case view_as<int>(SI_Hunter): return 1;
        case view_as<int>(SI_Spitter): return 3;
        case view_as<int>(SI_Jockey): return 1;
        case view_as<int>(SI_Charger): return 3;
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

    if (Traitor_IsNoDamageRoundBlocked(client))
    {
        CPrintToChat(client, "%t", "InfectedControl_TraitorRoundBlockedNoDamage");
        return false;
    }

    if (gCV.iTraitorAdminLimit > 0 && g_ITUsesThisRound[client] >= gCV.iTraitorAdminLimit)
    {
        CPrintToChat(client, "%t", "InfectedControl_TraitorLimitReached", gCV.iTraitorAdminLimit);
        return false;
    }

    return TraitorQuota_CanUse(client, Traitor_GetClassCost(zc));
}

static void Traitor_PrintPenaltyWarnings(int client, int zc)
{
    CPrintToChat(client, "%t", "InfectedControl_TraitorPenaltyNoDamageWarning");

    if (zc == TRAITOR_CLASS_TANK)
    {
        CPrintToChat(client, "%t",
            "InfectedControl_TraitorPenaltyTankDamageWarning",
            TRAITOR_TANK_MIN_DAMAGE,
            TRAITOR_TANK_BLOCK_DAYS);
    }
}

static void Traitor_FinalizeAliveClient(int client)
{
    if (client < 1 || client > MaxClients || g_ITState[client] != Traitor_Alive)
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
            TRAITOR_TANK_MIN_DAMAGE,
            TRAITOR_TANK_BLOCK_DAYS);
    }
}

static void Traitor_ClearClient(int client)
{
    if (client < 1 || client > MaxClients)
        return;

    g_ITState[client] = Traitor_None;
    g_ITClass[client] = 0;
    g_ITReleaseWave[client] = 0;
    g_ITWaitOrder[client] = 0;
    g_ITDidDamage[client] = false;
    g_ITDamageTotal[client] = 0;
    Traitor_CancelSpawnTimer(client);
}

void Traitor_ResetAll(bool moveClientsToSpec)
{
    Traitor_EnsureNoDamageBlockMap();
    g_ITNoDamageBlockedAuths.Clear();

    for (int client = 1; client <= MaxClients; client++)
    {
        if (moveClientsToSpec && Traitor_IsManagedClient(client) && IsClientInGame(client) && GetClientTeam(client) == TEAM_INFECTED)
            ChangeClientTeam(client, 1);

        Traitor_ClearClient(client);
        g_ITUsesThisRound[client] = 0;
        g_ITNoDamageBlockedThisRound[client] = false;
    }
    g_ITNextWaitOrder = 1;
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

    if (zc == TRAITOR_CLASS_TANK)
    {
        L4D_State_Transition(client, STATE_GHOST);
        L4D_SetClass(client, zc);
        return IsGhost(client) && GetEntProp(client, Prop_Send, "m_zombieClass") == TRAITOR_CLASS_TANK;
    }

    L4D_SetClass(client, zc);
    L4D_RespawnPlayer(client, false);
    L4D_SetClass(client, zc);
    L4D_BecomeGhost(client);

    return IsGhost(client);
}

static bool Traitor_QueueClient(int client, int zc)
{
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

    if (isNewQueue)
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

    if (!Traitor_CheckUseLimit(client))
        return;

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

void Traitor_OnPlayerHurt(int attacker, int victim, int damage)
{
    if (damage <= 0)
        return;

    if (!Traitor_IsAliveClient(attacker))
        return;

    if (!IsValidSurvivor(victim))
        return;

    g_ITDidDamage[attacker] = true;
    g_ITDamageTotal[attacker] += damage;
}

static void Traitor_PunishNoDamageClients()
{
    for (int client = 1; client <= MaxClients; client++)
    {
        if (g_ITState[client] != Traitor_Alive || g_ITDidDamage[client])
            continue;

        if (!IsValidClient(client)
            || GetClientTeam(client) != TEAM_INFECTED
            || !IsPlayerAlive(client)
            || IsGhost(client))
        {
            continue;
        }

        Traitor_SetNoDamageRoundBlock(client);
        CPrintToChat(client, "%t", "InfectedControl_TraitorNoDamagePunished");
        Debug_Print("[TRAITOR] %N slayed and round-blocked for no damage before next countdown", client);
        ForcePlayerSuicide(client);
    }
}

static void Traitor_BroadcastNextWaveStatus(int releaseWave)
{
    bool announced = false;

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
        announced = true;
    }

    if (!announced)
        CPrintToChatAll("%t", "InfectedControl_TraitorNextWaveNone");
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
    Traitor_PunishNoDamageClients();

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

    Traitor_FinalizeAliveClient(client);
    Traitor_ClearClient(client);
    InvalidateBucketShareCache();
    RecalcSiCapFromAlive(false);
    Traitor_ActivateWaitingClients();
    return true;
}

void Traitor_OnClientDisconnect(int client)
{
    bool freedSlot = (client >= 1 && client <= MaxClients && Traitor_IsSlotState(g_ITState[client]));
    Traitor_FinalizeAliveClient(client);
    Traitor_ClearClient(client);
    if (client >= 1 && client <= MaxClients)
    {
        g_ITUsesThisRound[client] = 0;
        g_ITNoDamageBlockedThisRound[client] = false;
    }
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
    Traitor_ClearClient(client);

    if (wasAlive)
        RecalcSiCapFromAlive(false);
    if (freedSlot)
        Traitor_ActivateWaitingClients();
}
