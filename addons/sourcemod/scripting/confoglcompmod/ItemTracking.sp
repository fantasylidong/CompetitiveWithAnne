#if defined __item_tracking_included
    #endinput
#endif
#define __item_tracking_included

#define IT_MODULE_NAME			"ItemTracking"

#define PF_KEEP        0
#define PF_CULL_WINDOW 1
#define PF_CULL_SEP    2
#define PF_CULL_LIMIT  3
#define PF_CULL_ROUTE  4
#define PF_NO_FLOW     -1   // no nav/flow data: always kept, excluded from spacing

#define PF_FILL_AREA_ATTEMPTS 32

static int PF_GLOW_KEEP[3] = {255, 255, 255};   // white
static int PF_GLOW_FILL[3] = {0, 255, 0};       // green
static int PF_GLOW_CULL[5][3] = {
    {0, 0, 0},          // PF_KEEP (unused)
    {255, 0, 0},        // PF_CULL_WINDOW: red
    {255, 165, 0},      // PF_CULL_SEP: orange
    {0, 255, 255},      // PF_CULL_LIMIT: cyan
    {255, 0, 255}       // PF_CULL_ROUTE: magenta
};

// Item lists for tracking/decoding/etc
enum /*ItemList*/
{
    IL_PainPills,
    IL_Adrenaline,
    // Not sure we need these.
    //IL_FirstAid,
    //IL_Defib,
    IL_PipeBomb,
    IL_Molotov,
    IL_VomitJar,

    ItemList_Size
};

// Names for cvars, kv, descriptions
// [ItemIndex][shortname = 0, fullname = 1, spawnname = 2]
enum /*ItemNames*/
{
    IN_shortname,
    IN_longname,
    IN_officialname,
    IN_modelname,

    ItemNames_Size
};

// Settings for item limiting.
/*enum ItemLimitSettings
{
    Handle:cvar,
    limitnum
};*/

// For spawn entires adt_array
enum struct ItemTracking
{
    int IT_entity;
    float IT_origins;
    float IT_origins1;
    float IT_origins2;
    float IT_angles;
    float IT_angles1;
    float IT_angles2;
}

// Shortest start->goal route, measured once per filter pass
enum struct PFRoute
{
    Address pStart;
    Address pGoal;
    float fStartFlow;
    float fRouteLen;
    float fScale;   // BuildPath length per flow unit
}

static const char g_sItemNames[ItemList_Size][ItemNames_Size][] =
{
    {
        "pills",
        "pain pills",
        "pain_pills",
        "painpills"
    },
    {
        "adrenaline",
        "adrenaline shots",
        "adrenaline",
        "adrenaline"
    },
    /*{
        "kits",
        "first aid kits",
        "first_aid_kit",
        "medkit"
    },
    {
        "defib",
        "defibrillators",
        "defibrillator",
        "defibrillator"
    },*/
    {
        "pipebomb",
        "pipe bombs",
        "pipe_bomb",
        "pipebomb"
    },
    {
        "molotov",
        "molotovs",
        "molotov",
        "molotov"
    },
    {
        "vomitjar",
        "bile bombs",
        "vomitjar",
        "bile_flask"
    }
};

static int
    g_iItemLimits[ItemList_Size] = {0, ...}, // Current item limits array
    g_iSaferoomCount[2] = {0, ...};

static bool
    g_bIsRound1Over = false; // Is round 1 over?

static ConVar
    g_hCvarEnabled = null,
    g_hSurvivorLimit = null,
    g_hCvarConsistentSpawns = null,
    g_hCvarMapSpecificSpawns = null,
    g_hCvarIgnorePlayerItems = null,
    g_hCvarPillFlowMin = null,
    g_hCvarPillFlowMax = null,
    g_hCvarPillFlowSeparation = null,
    g_hCvarPillFlowFinale = null,
    g_hCvarPillFlowMaxDetour = null,
    g_hCvarPillFlowFill = null,
    g_hCvarPillFlowFillMin = null,
    g_hCvarPillFlowFillMax = null,
    g_hCvarPillFlowVisualize = null,
    g_hCvarLimits[ItemList_Size] = {null, ...}; // CVAR Handle Array for item limits

static bool
    g_bPillLimitHandled = false; // Pill flow filter ran and owns the pills limit this round

static ArrayList
    g_hItemSpawns[ItemList_Size] = {null, ...}; // ADT Array Handle for actual item spawns

static StringMap
    g_hItemListTrie = null;

void IT_OnModuleStart()
{
    g_hCvarEnabled = CreateConVarEx("enable_itemtracking", "0", "Enable the itemtracking module", _, true, 0.0, true, 1.0);
    g_hCvarConsistentSpawns = CreateConVarEx("itemtracking_savespawns", "0", "Keep item spawns the same on both rounds", _, true, 0.0, true, 1.0);
    g_hCvarMapSpecificSpawns = CreateConVarEx("itemtracking_mapspecific", "0", "Change how mapinfo.txt overrides work. 0 = ignore mapinfo.txt, 1 = allow limit reduction, 2 = allow limit increases.", _, true, 0.0, true, 3.0);
    g_hCvarIgnorePlayerItems = CreateConVarEx("itemtracking_playeritems", "0", "Ignore items that players spawn with. 0 = Nope, 1 = Yes. (Non-issue in versus modes)", _, true, 0.0, true, 1.0);

    // Pill flow window. Per-map override keys in mapinfo.txt (map section):
    // "pillflow_min", "pillflow_max", "pillflow_separation", "pillflow_max_detour", "pillflow_fill", "pillflow_fill_min", "pillflow_fill_max"
    // (floats, same meaning as the cvars).
    g_hCvarPillFlowMin = CreateConVarEx("pills_flow_min", "0", "Minimum map flow fraction (0.0-1.0) where pain pills may spawn. Pills earlier than this are removed. 0 with max 1 and separation 0 = flow filter off.", _, true, 0.0, true, 1.0);
    g_hCvarPillFlowMax = CreateConVarEx("pills_flow_max", "1", "Maximum map flow fraction (0.0-1.0) where pain pills may spawn. Pills later than this are removed.", _, true, 0.0, true, 1.0);
    g_hCvarPillFlowSeparation = CreateConVarEx("pills_flow_separation", "0", "Minimum flow-fraction gap between two kept pill spawns (0.05 = 5% of map flow). Of a too-close pair the earlier spawn wins. 0 = no separation enforced.", _, true, 0.0, true, 1.0);
    g_hCvarPillFlowFinale = CreateConVarEx("pills_flow_finale", "0", "Apply the pill flow window on finale maps. 0 = finales exempt.", _, true, 0.0, true, 1.0);
    g_hCvarPillFlowMaxDetour = CreateConVarEx("pills_flow_max_detour", "0", "Maximum detour (nav units) a pill spawn may sit off the shortest start->end route; a dead-end side room of depth d is a detour of d. Off-route pills are removed. 0 = off.", _, true, 0.0);
    g_hCvarPillFlowFill = CreateConVarEx("pills_flow_fill", "0", "Fill missing pills at random progress positions on the main route, including maps with no original pills. 0 = off.", _, true, 0.0, true, 1.0);
    g_hCvarPillFlowFillMin = CreateConVarEx("pills_flow_fill_min", "0.3", "Minimum map flow fraction for randomly spawned fill pills.", _, true, 0.0, true, 1.0);
    g_hCvarPillFlowFillMax = CreateConVarEx("pills_flow_fill_max", "1.0", "Maximum map flow fraction for randomly spawned fill pills; saferoom nav areas are excluded.", _, true, 0.0, true, 1.0);
    g_hCvarPillFlowVisualize = CreateConVarEx("pills_flow_visualize", "0", "Debug: 1 = don't remove pills, glow instead: white = kept, green = spawned to fill the limit, red = outside flow window, magenta = off the main route, orange = too close to previous pill, cyan = over the pills limit. 2 = remove as normal, then glow the surviving pills white/green.", _, true, 0.0, true, 2.0);

    char sNameBuf[64], sCvarDescBuf[256];
    // Create itemlimit cvars
    for (int i = 0; i < ItemList_Size; i++) {
        FormatEx(sNameBuf, sizeof(sNameBuf), "%s_limit", g_sItemNames[i][IN_shortname]);
        FormatEx(sCvarDescBuf, sizeof(sCvarDescBuf), "Limits the number of %s on each map. -1: no limit; >=0: limit to cvar value", g_sItemNames[i][IN_longname]);

        g_hCvarLimits[i] = CreateConVarEx(sNameBuf, "-1", sCvarDescBuf);
    }

    // Create name translation trie
    CreateItemListTrie();

    // Create item spawns array;
    ItemTracking curitem;

    for (int i = 0; i < ItemList_Size; i++) {
        g_hItemSpawns[i] = new ArrayList(sizeof(curitem));
    }

    HookEvent("round_start", _IT_RoundStartEvent, EventHookMode_PostNoCopy);
    HookEvent("round_end", _IT_RoundEndEvent, EventHookMode_PostNoCopy);

    g_hSurvivorLimit = FindConVar("survivor_limit");
}




void IT_OnMapStart()
{
    for (int i = 0; i < ItemList_Size; i++) {
        g_iItemLimits[i] = g_hCvarLimits[i].IntValue;
    }

    int iCvarValue = g_hCvarMapSpecificSpawns.IntValue;
    if (iCvarValue) {
        int itemlimit = 0, temp = 0;
        KeyValues kOverrideLimits = new KeyValues("ItemLimits");
        CopyMapSubsection(kOverrideLimits, "ItemLimits");

        for (int i = 0; i < ItemList_Size; i++) {
            itemlimit = g_hCvarLimits[i].IntValue;

            temp = kOverrideLimits.GetNum(g_sItemNames[i][IN_officialname], itemlimit);

            if (((g_iItemLimits[i] > temp) && (iCvarValue & 1)) || ((g_iItemLimits[i] < temp) && (iCvarValue & 2))) {
                g_iItemLimits[i] = temp;
            }

            g_hItemSpawns[i].Clear();
        }

        delete kOverrideLimits;
    }

    g_bIsRound1Over = false;
}

static void _IT_RoundEndEvent(Event hEvent, const char[] sEventName, bool bDontBroadcast)
{
    g_bIsRound1Over = true;
}

static void _IT_RoundStartEvent(Event hEvent, const char[] sEventName, bool bDontBroadcast)
{
    g_iSaferoomCount[START_SAFEROOM - 1] = 0;
    g_iSaferoomCount[END_SAFEROOM - 1] = 0;

    // Since OnMapStart only happens once on scavenge mode, g_bIsRound1Over can only be once false because 
    // evey round_end event will turn it to true. This casues items spawning at the same position during the whole scavenge match.
    if (IsScavengeMode()) {
        if (!InSecondHalfOfRound()) {
            g_bIsRound1Over = false;
        }
    }

    // Mapstart happens after round_start most of the time, so we need to wait for g_bIsRound1Over.
    // Plus, we don't want to have conflicts with EntityRemover.
    CreateTimer(1.0, IT_RoundStartTimer, _, TIMER_FLAG_NO_MAPCHANGE);
}

static Action IT_RoundStartTimer(Handle hTimer)
{
    if (!g_bIsRound1Over) {
        // Round1
        if (IsModuleEnabled()) {
            EnumAndElimSpawns();
        }
    } else {
        // Round2
        if (IsModuleEnabled()) {
            if (g_hCvarConsistentSpawns.BoolValue) {
                GenerateStoredSpawns();
            } else {
                EnumAndElimSpawns();
            }
        }
    }

    return Plugin_Stop;
}

static void EnumAndElimSpawns()
{
    if (IsDebugEnabled()) {
        LogMessage("[%s] Resetting g_iSaferoomCount and Enumerating and eliminating spawns...", IT_MODULE_NAME);
    }

    EnumerateSpawns();
    g_bPillLimitHandled = ApplyPillFlowFilter();
    RemoveToLimits();
}

static void GenerateStoredSpawns()
{
    KillRegisteredItems();
    SpawnItems();

    // Repaint glows on the respawned entities.
    if (g_hCvarPillFlowVisualize.IntValue > 0) {
        ApplyPillFlowFilter();
    }
}

// l4d2lib plugin
// For 3.0 rounds library
/*public void L4D2_OnRealRoundStart(int roundNum)
{
    if (roundNum == 1) {
        EnumerateSpawns();
        RemoveToLimits();
    } else {
        // We kill off all items we recognize.
        // Unlimited items will be replaced, limited items will be spawned,
        // and killed items will stay killed
        KillRegisteredItems();
        // Spawn up the same items that existed in round 1
        SpawnItems();
    }
}*/

// Produces the lookup trie for weapon spawn entities
//		to translate to our ADT array of spawns
static void CreateItemListTrie()
{
    g_hItemListTrie = new StringMap();
    g_hItemListTrie.SetValue("weapon_pain_pills_spawn", IL_PainPills);
    g_hItemListTrie.SetValue("weapon_pain_pills", IL_PainPills);
    g_hItemListTrie.SetValue("weapon_adrenaline_spawn", IL_Adrenaline);
    g_hItemListTrie.SetValue("weapon_adrenaline", IL_Adrenaline);
    g_hItemListTrie.SetValue("weapon_pipe_bomb_spawn", IL_PipeBomb);
    g_hItemListTrie.SetValue("weapon_pipe_bomb", IL_PipeBomb);
    g_hItemListTrie.SetValue("weapon_molotov_spawn", IL_Molotov);
    g_hItemListTrie.SetValue("weapon_molotov", IL_Molotov);
    g_hItemListTrie.SetValue("weapon_vomitjar_spawn", IL_VomitJar);
    g_hItemListTrie.SetValue("weapon_vomitjar", IL_VomitJar);
}

static void KillRegisteredItems()
{
    int itemindex = 0, psychonic = GetEntityCount();
    int iSurvivorLimit = g_hSurvivorLimit.IntValue;
    bool bKeepPlayerItems = g_hCvarIgnorePlayerItems.BoolValue;

    for (int i = (MaxClients + 1); i <= psychonic; i++) {
        if (!IsValidEdict(i)) {
            continue;
        }

        itemindex = GetItemIndexFromEntity(i);
        if (itemindex >= 0/* && !IsEntityInSaferoom(i)*/) {
            if (IsEntityInSaferoom(i, START_SAFEROOM) && g_iSaferoomCount[START_SAFEROOM - 1] < iSurvivorLimit) {
                g_iSaferoomCount[START_SAFEROOM - 1]++;
            } else if (IsEntityInSaferoom(i, END_SAFEROOM) && g_iSaferoomCount[END_SAFEROOM - 1] < iSurvivorLimit) {
                g_iSaferoomCount[END_SAFEROOM - 1]++;
            } else {
                // Kill items we're tracking;
                // Exception for if the item is in a player's inventory.
                if (bKeepPlayerItems && HasEntProp(i, Prop_Send, "m_hOwner") && GetEntPropEnt(i, Prop_Send, "m_hOwner") > 0)
                  continue;
                
                KillEntity(i);
                /*if (!AcceptEntityInput(i, "kill")) {
                    Debug_LogError(IT_MODULE_NAME, "Error killing instance of item %s", g_sItemNames[itemindex][IN_longname]);
                }*/
            }
        }
    }
}

static void SpawnItems()
{
    ItemTracking curitem;

    float origins[3], angles[3];
    int arrsize = 0, itement = 0, wepid = 0;

    for (int itemidx = 0; itemidx < ItemList_Size; itemidx++) {
        arrsize = g_hItemSpawns[itemidx].Length;

        for (int idx = 0; idx < arrsize; idx++) {
            g_hItemSpawns[itemidx].GetArray(idx, curitem, sizeof(curitem));

            GetSpawnOrigins(origins, curitem);
            GetSpawnAngles(angles, curitem);
            wepid = GetWeaponIDFromItemList(itemidx);

            if (IsDebugEnabled()) {
                LogMessage("[%s] Spawning an instance of item %s (%d, wepid %d), number %d, at %.02f %.02f %.02f", \
                                IT_MODULE_NAME, g_sItemNames[itemidx][IN_officialname], itemidx, wepid, idx, origins[0], origins[1], origins[2]);
            }

            itement = CreateItemSpawn(itemidx, origins, angles);
            if (itement == -1) {
                continue;
            }

            /*
                Keep the stored entry pointing at the live entity so passes that
                run after the respawn (e.g. the pill flow filter) address the
                round-2 entity, not the killed round-1 one.
            */
            curitem.IT_entity = itement;
            g_hItemSpawns[itemidx].SetArray(idx, curitem, sizeof(curitem));
        }
    }
}

static int CreateItemSpawn(int itemidx, const float origins[3], const float angles[3])
{
    int itement = CreateEntityByName("weapon_spawn");
    if (itement == -1) {
        return -1;
    }

    char sModelname[PLATFORM_MAX_PATH];
    FormatEx(sModelname, sizeof(sModelname), "models/w_models/weapons/w_eq_%s.mdl", g_sItemNames[itemidx][IN_modelname]);

    SetEntProp(itement, Prop_Send, "m_weaponID", GetWeaponIDFromItemList(itemidx));
    SetEntityModel(itement, sModelname);
    DispatchKeyValue(itement, "count", "1");
    TeleportEntity(itement, origins, angles, NULL_VECTOR);
    DispatchSpawn(itement);
    SetEntityMoveType(itement, MOVETYPE_NONE);

    return itement;
}

static void EnumerateSpawns()
{
    /*
        Start every enumeration from a clean slate.
        Without this, configs running savespawns 0 stack round-2 entries on round-1 leftovers
        and mapspecific 0 leaks spawns across maps (OnMapStart only clears when mapspecific != 0)
    */
    for (int i = 0; i < ItemList_Size; i++) {
        g_hItemSpawns[i].Clear();
    }

    ItemTracking curitem;

    float origins[3], angles[3];
    int itemindex = 0, psychonic = GetEntityCount();
    int iSurvivorLimit = g_hSurvivorLimit.IntValue;

    for (int i = (MaxClients + 1); i <= psychonic; i++) {
        if (!IsValidEdict(i)) {
            continue;
        }

        itemindex = GetItemIndexFromEntity(i);
        if (itemindex >= 0/* && !IsEntityInSaferoom(i)*/) {
            if (IsEntityInSaferoom(i, START_SAFEROOM)) {
                if (g_iSaferoomCount[START_SAFEROOM - 1] < iSurvivorLimit) {
                    g_iSaferoomCount[START_SAFEROOM - 1]++;
                } else {
                    KillEntity(i);
                    /*if (!AcceptEntityInput(i, "kill")) {
                        Debug_LogError(IT_MODULE_NAME, "Error killing instance of item %s", g_sItemNames[itemindex][IN_longname]);
                    }*/
                }
            } else if (IsEntityInSaferoom(i, END_SAFEROOM)) {
                if (g_iSaferoomCount[END_SAFEROOM - 1] < iSurvivorLimit) {
                    g_iSaferoomCount[END_SAFEROOM - 1]++;
                } else {
                    KillEntity(i);
                    /*if (!AcceptEntityInput(i, "kill")) {
                        Debug_LogError(IT_MODULE_NAME, "Error killing instance of item %s", g_sItemNames[itemindex][IN_longname]);
                    }*/
                }
            } else {
                int mylimit = g_iItemLimits[itemindex];
                if (IsDebugEnabled()) {
                    LogMessage("[%s] Found an instance of item %s (%d), with limit %d", IT_MODULE_NAME, g_sItemNames[itemindex][IN_longname], itemindex, mylimit);
                }

                // Item limit is zero, justkill it as we find it
                if (!mylimit) {
                    if (IsDebugEnabled()) {
                        LogMessage("[%s] Killing spawn", IT_MODULE_NAME);
                    }

                    KillEntity(i);
                    /*if (!AcceptEntityInput(i, "kill")) {
                        Debug_LogError(IT_MODULE_NAME, "Error killing instance of item %s", g_sItemNames[itemindex][IN_longname]);
                    }*/
                } else {
                    // Store entity, angles, origin
                    curitem.IT_entity = i;

                    GetEntPropVector(i, Prop_Send, "m_vecOrigin", origins);
                    GetEntPropVector(i, Prop_Send, "m_angRotation", angles);

                    if (IsDebugEnabled()) {
                        LogMessage("[%s] Saving spawn #%d at %.02f %.02f %.02f", IT_MODULE_NAME, g_hItemSpawns[itemindex].Length, origins[0], origins[1], origins[2]);
                    }

                    SetSpawnOrigins(origins, curitem);
                    SetSpawnAngles(angles, curitem);

                    // Push this instance onto our array for that item
                    g_hItemSpawns[itemindex].PushArray(curitem, sizeof(curitem));
                }
            }
        }
    }
}

static void RemoveToLimits()
{
    ItemTracking curitem;

    int curlimit = 0, killidx = 0;

    for (int itemidx = 0; itemidx < ItemList_Size; itemidx++) {
        // The pill flow filter already enforced the pills limit (evenly spaced by flow instead of random)
        if (itemidx == IL_PainPills && g_bPillLimitHandled) {
            continue;
        }

        curlimit = g_iItemLimits[itemidx];

        if (curlimit > 0) {
            // Kill off item spawns until we've reduced the item to the limit
            while (g_hItemSpawns[itemidx].Length > curlimit) {
                // Pick a random
                killidx = GetURandomIntRange(0, (g_hItemSpawns[itemidx].Length - 1));

                if (IsDebugEnabled()) {
                    LogMessage("[%s] Killing randomly chosen %s (%d) #%d", IT_MODULE_NAME, g_sItemNames[itemidx][IN_longname], itemidx, killidx);
                }

                g_hItemSpawns[itemidx].GetArray(killidx, curitem, sizeof(curitem));

                if (IsValidEdict(curitem.IT_entity)) {
                    KillEntity(curitem.IT_entity);

                    /*if (!AcceptEntityInput(curitem.IT_entity, "kill")) {
                        Debug_LogError(IT_MODULE_NAME, "Error killing instance of item %s", g_sItemNames[itemidx][IN_longname]);
                    }*/
                }

                g_hItemSpawns[itemidx].Erase(killidx);
            }
        }
        // If limit is 0, they're already dead. If it's negative, we kill nothing.
    }
}

static float PF_GetSetting(const char[] sKey, ConVar hCvar)
{
    if (IsMapDataAvailable()) {
        return GetMapValueFloat(sKey, hCvar.FloatValue);
    }

    return hCvar.FloatValue;
}

// Returns true when the filter is active (= it owns the pills limit this round).
static bool ApplyPillFlowFilter()
{
    float fFlowMin = PF_GetSetting("pillflow_min", g_hCvarPillFlowMin);
    float fFlowMax = PF_GetSetting("pillflow_max", g_hCvarPillFlowMax);
    float fSep = PF_GetSetting("pillflow_separation", g_hCvarPillFlowSeparation);
    float fMaxDetour = PF_GetSetting("pillflow_max_detour", g_hCvarPillFlowMaxDetour);
    bool bFill = (PF_GetSetting("pillflow_fill", g_hCvarPillFlowFill) > 0.0);

    if (fFlowMin <= 0.0 && fFlowMax >= 1.0 && fSep <= 0.0 && fMaxDetour <= 0.0 && !bFill) {
        return false;
    }

    if (fFlowMax < fFlowMin) {
        LogError("[%s] pillflow_max (%.2f) < pillflow_min (%.2f); pill flow filter disabled.", IT_MODULE_NAME, fFlowMax, fFlowMin);
        return false;
    }

    if (!g_hCvarPillFlowFinale.BoolValue && L4D_IsMissionFinalMap()) {
        if (IsDebugEnabled()) {
            LogMessage("[%s] Finale map, pill flow filter skipped.", IT_MODULE_NAME);
        }
        return false;
    }

    float fMaxFlowDist = L4D2Direct_GetMapMaxFlowDistance();
    if (fMaxFlowDist <= 0.0) {
        return false;
    }

    ArrayList hSpawns = g_hItemSpawns[IL_PainPills];
    int iCount = hSpawns.Length;
    int iLimit = g_iItemLimits[IL_PainPills];
    int iVisualize = g_hCvarPillFlowVisualize.IntValue;
    bool bVisualize = (iVisualize == 1);   // mode 1 glows instead of removing; mode 2 removes and glows survivors

    bFill = bFill && iLimit > 0;

    PFRoute route;
    bool bRoute = fMaxDetour > 0.0 && iCount > 0 && PF_BuildRoute(fMaxFlowDist, route);

    if (!iCount) {
        if (bFill) {
            PF_FillToLimit(hSpawns, iLimit, fMaxFlowDist, fFlowMin, fFlowMax, iVisualize > 0);
        }
        return true;
    }

    ItemTracking curitem;
    float fOrigins[3];

    // Resolve each stored pill spawn to a flow fraction and apply the window.
    float[] fPct = new float[iCount];
    float[] fFlowRaw = new float[iCount];
    Address[] pNavs = new Address[iCount];
    int[] iReason = new int[iCount];

    for (int i = 0; i < iCount; i++) {
        hSpawns.GetArray(i, curitem, sizeof(curitem));
        GetSpawnOrigins(fOrigins, curitem);

        Address pNav = L4D_GetNearestNavArea(fOrigins, 120.0, true, false, false, 2);
        if (pNav == Address_Null) {
            pNav = L4D2Direct_GetTerrorNavArea(fOrigins);
        }

        float fFlow = (pNav != Address_Null) ? L4D2Direct_GetTerrorNavAreaFlow(pNav) : -1.0;
        pNavs[i] = pNav;
        fFlowRaw[i] = fFlow;
        if (fFlow < 0.0) {
            fPct[i] = -1.0;
            iReason[i] = PF_NO_FLOW;
            continue;
        }

        fPct[i] = fFlow / fMaxFlowDist;
        if (fPct[i] > 1.0) {
            fPct[i] = 1.0;
        }

        if (fPct[i] < fFlowMin || fPct[i] > fFlowMax) {
            iReason[i] = PF_CULL_WINDOW;
        }
    }

    // Off-route spawns go before spacing, so they can't win a cluster over an on-route neighbour.
    if (fMaxDetour > 0.0 && bRoute) {
        PF_ApplyRouteFilter(route, iCount, pNavs, fFlowRaw, iReason, fMaxDetour);
    }

    // Index order sorted by ascending flow (spacing passes walk the map start->end).
    int[] iOrder = new int[iCount];
    for (int i = 0; i < iCount; i++) {
        iOrder[i] = i;
    }
    for (int i = 1; i < iCount; i++) {
        int tmp = iOrder[i];
        int j = i - 1;
        while (j >= 0 && fPct[iOrder[j]] > fPct[tmp]) {
            iOrder[j + 1] = iOrder[j];
            j--;
        }
        iOrder[j + 1] = tmp;
    }

    // Minimum flow separation; of a too-close cluster the earliest spawn wins.
    if (fSep > 0.0) {
        float fLastKept = -1.0;
        for (int k = 0; k < iCount; k++) {
            int i = iOrder[k];
            if (iReason[i] != PF_KEEP) {
                continue;
            }
            if (fLastKept >= 0.0 && fPct[i] - fLastKept < fSep) {
                iReason[i] = PF_CULL_SEP;
            } else {
                fLastKept = fPct[i];
            }
        }
    }

    /*
        Enforce the pills limit here, evenly spaced by flow.
        Spawns without flow data can't be spaced, so they occupy limit slots off the top.
    */
    if (iLimit >= 0) {
        int iKept = 0, iNoFlow = 0;
        for (int i = 0; i < iCount; i++) {
            if (iReason[i] == PF_KEEP) {
                iKept++;
            } else if (iReason[i] == PF_NO_FLOW) {
                iNoFlow++;
            }
        }

        int iSlots = iLimit - iNoFlow;
        if (iSlots < 0) {
            /*
                More flowless spawns than the limit alone allows: remove the extra.
                No flow data means there is nothing to space them by, so array order decides
            */
            int iExcess = -iSlots;
            for (int i = iCount - 1; i >= 0 && iExcess > 0; i--) {
                if (iReason[i] == PF_NO_FLOW) {
                    iReason[i] = PF_CULL_LIMIT;
                    iExcess--;
                }
            }
            iSlots = 0;
        }

        if (iSlots < iKept) {
            bool[] bSelected = new bool[iCount];
            for (int slot = 0; slot < iSlots; slot++) {
                // Ideal flow for this slot
                float fWant = fFlowMin + (fFlowMax - fFlowMin) * (float(slot) + 0.5) / float(iSlots);

                int best = -1;
                float fBestDist = 0.0;
                for (int i = 0; i < iCount; i++) {
                    if (iReason[i] != PF_KEEP || bSelected[i]) {
                        continue;
                    }
                    float d = fPct[i] - fWant;
                    if (d < 0.0) {
                        d = -d;
                    }
                    if (best == -1 || d < fBestDist) {
                        best = i;
                        fBestDist = d;
                    }
                }
                if (best != -1) {
                    bSelected[best] = true;
                }
            }

            for (int i = 0; i < iCount; i++) {
                if (iReason[i] == PF_KEEP && !bSelected[i]) {
                    iReason[i] = PF_CULL_LIMIT;
                }
            }
        }
    }

    // Apply: kill+erase culled spawns (descending so indices stay valid), or
    // just glow everything in visualize mode.
    int iRemoved[5] = {0, ...};   // indexed by PF_CULL_* reason
    int iKeptTotal = 0;
    for (int i = iCount - 1; i >= 0; i--) {
        hSpawns.GetArray(i, curitem, sizeof(curitem));

        if (iReason[i] <= PF_KEEP) {
            iKeptTotal++;
            if (IsDebugEnabled()) {
                LogMessage("[%s] Pill spawn %d flow=%.1f%% KEPT%s", IT_MODULE_NAME, curitem.IT_entity,
                    fPct[i] * 100.0, iReason[i] == PF_NO_FLOW ? " (no flow data)" : "");
            }
            if (iVisualize > 0) {
                L4D2_SetEntityGlow(curitem.IT_entity, L4D2Glow_Constant, 0, 0, PF_GLOW_KEEP, false);
            }
            continue;
        }

        if (IsDebugEnabled()) {
            static const char sReasons[5][] = {"", "outside window", "separation", "limit spacing", "off route"};
            LogMessage("[%s] Pill spawn %d flow=%.1f%% %s (%s)", IT_MODULE_NAME, curitem.IT_entity,
                fPct[i] * 100.0, bVisualize ? "WOULD REMOVE" : "REMOVED", sReasons[iReason[i]]);
        }
        iRemoved[iReason[i]]++;

        if (bVisualize) {
            L4D2_SetEntityGlow(curitem.IT_entity, L4D2Glow_Constant, 0, 0, PF_GLOW_CULL[iReason[i]], false);
        } else {
            if (IsValidEdict(curitem.IT_entity)) {
                KillEntity(curitem.IT_entity);
            }
            hSpawns.Erase(i);
        }
    }

    if (IsDebugEnabled()) {
        LogMessage("[%s] Pill flow window %.0f%%-%.0f%% sep %.1f%% detour %.0f: %d kept, %d %s (window), %d (off route), %d (separation), %d (limit spacing).%s",
            IT_MODULE_NAME, fFlowMin * 100.0, fFlowMax * 100.0, fSep * 100.0, fMaxDetour,
            iCount - iRemoved[PF_CULL_WINDOW] - iRemoved[PF_CULL_ROUTE] - iRemoved[PF_CULL_SEP] - iRemoved[PF_CULL_LIMIT],
            iRemoved[PF_CULL_WINDOW], bVisualize ? "flagged" : "removed",
            iRemoved[PF_CULL_ROUTE], iRemoved[PF_CULL_SEP], iRemoved[PF_CULL_LIMIT],
            bVisualize ? " (visualize: nothing deleted; white = kept, red = window, magenta = route, orange = separation, cyan = limit)" : "");
    }

    if (bFill) {
        PF_FillToLimit(hSpawns, iLimit - iKeptTotal, fMaxFlowDist,
            fFlowMin, fFlowMax, iVisualize > 0);
    }

    return true;
}

/*
    Main-route test. For a spot on the shortest start->goal route, flow(spot) + path(spot->goal)
    equals the route length; a dead-end side room of depth d adds 2d. Flow and BuildPath lengths
    aren't measured identically, so the route is measured once with the BuildPath metric and flow
    is scaled by that ratio.
*/
static bool PF_BuildRoute(float fMaxFlowDist, PFRoute route)
{
    float fGoalFlow;
    if (!PF_FindRouteEnds(fMaxFlowDist, route.pStart, route.fStartFlow, route.pGoal, fGoalFlow)) {
        LogMessage("[%s] No start/goal nav area found; pill route check skipped.", IT_MODULE_NAME);
        return false;
    }

    float fRouteFlow = fGoalFlow - route.fStartFlow;
    route.fRouteLen = PF_MeasurePath(route.pStart, route.pGoal, fRouteFlow * 0.5, fRouteFlow * 2.0);
    if (route.fRouteLen <= 0.0) {
        LogMessage("[%s] Start->goal route not walkable (flow %.0f); pill route check skipped.", IT_MODULE_NAME, fRouteFlow);
        return false;
    }

    route.fScale = route.fRouteLen / fRouteFlow;

    if (IsDebugEnabled()) {
        LogMessage("[%s] Pill route: start area %d (flow %.0f), goal area %d (flow %.0f), path %.0f, scale %.3f",
            IT_MODULE_NAME, L4D_GetNavAreaID(route.pStart), route.fStartFlow, L4D_GetNavAreaID(route.pGoal), fGoalFlow,
            route.fRouteLen, route.fScale);
    }

    return true;
}

static bool PF_IsOnRoute(const PFRoute route, Address pArea, float fFlow, float fMaxDetour)
{
    if (pArea == route.pGoal) {
        return true;
    }

    // Path budget from the spot to the goal that still keeps the detour within fMaxDetour.
    float fBudget = route.fRouteLen - route.fScale * (fFlow - route.fStartFlow) + 2.0 * fMaxDetour;
    return (fBudget > 0.0 && PF_PathWithin(pArea, route.pGoal, fBudget));
}

static void PF_ApplyRouteFilter(const PFRoute route, int iCount, const Address[] pNavs, const float[] fFlowRaw, int[] iReason, float fMaxDetour)
{
    for (int i = 0; i < iCount; i++) {
        if (iReason[i] != PF_KEEP) {
            continue;
        }

        bool bOnRoute = PF_IsOnRoute(route, pNavs[i], fFlowRaw[i], fMaxDetour);

        if (IsDebugEnabled()) {
            LogMessage("[%s] Pill area %d flow %.0f: %s", IT_MODULE_NAME, L4D_GetNavAreaID(pNavs[i]), fFlowRaw[i], bOnRoute ? "on route" : "off route");
        }

        if (!bOnRoute) {
            iReason[i] = PF_CULL_ROUTE;
        }
    }
}

static void PF_FillToLimit(ArrayList hSpawns, int iMissing,
    float fMaxFlowDist, float fFlowMin, float fFlowMax, bool bGlow)
{
    if (iMissing <= 0) {
        return;
    }

    float fFillMin = PF_GetSetting("pillflow_fill_min", g_hCvarPillFlowFillMin);
    float fFillMax = PF_GetSetting("pillflow_fill_max", g_hCvarPillFlowFillMax);
    if (fFillMin < fFlowMin) {
        fFillMin = fFlowMin;
    }
    if (fFillMax > fFlowMax) {
        fFillMax = fFlowMax;
    }
    if (fFillMax <= fFillMin) {
        LogMessage("[%s] Pill fill: invalid progress range %.2f-%.2f.", IT_MODULE_NAME, fFillMin, fFillMax);
        return;
    }

    ArrayList hAllAreas = new ArrayList();
    ArrayList hCandidates = new ArrayList(2);
    L4D_GetAllNavAreas(hAllAreas);
    for (int i = 0; i < hAllAreas.Length; i++) {
        Address pArea = view_as<Address>(hAllAreas.Get(i));
        int iFlags = L4D_GetNavArea_SpawnAttributes(pArea);
        if (!(iFlags & NAV_SPAWN_ESCAPE_ROUTE) ||
            iFlags & (NAV_SPAWN_PLAYER_START | NAV_SPAWN_CHECKPOINT | NAV_SPAWN_RESCUE_VEHICLE | NAV_SPAWN_RESCUE_CLOSET)) {
            continue;
        }

        float fFlow = L4D2Direct_GetTerrorNavAreaFlow(pArea);
        if (fFlow < fFillMin * fMaxFlowDist || fFlow > fFillMax * fMaxFlowDist) {
            continue;
        }

        int iRow = hCandidates.Push(fFlow);
        hCandidates.Set(iRow, pArea, 1);
    }
    delete hAllAreas;
    hCandidates.SortCustom(PF_SortByFirstFloat);

    int iSpawned;
    for (int choice = 0; choice < iMissing * 3 && iSpawned < iMissing; choice++) {
        float fProgress = choice < iMissing
            ? (float(choice) + GetRandomFloat(0.0, 1.0)) / float(iMissing)
            : GetRandomFloat(0.0, 1.0);
        float fTarget = (fFillMin + fProgress * (fFillMax - fFillMin)) * fMaxFlowDist;
        int iRight = 0;
        int iEnd = hCandidates.Length;
        while (iRight < iEnd && hCandidates.Get(iRight, 0) < fTarget) {
            iRight++;
        }
        int iLeft = iRight - 1;

        for (int attempt = 0; attempt < PF_FILL_AREA_ATTEMPTS && (iLeft >= 0 || iRight < iEnd); attempt++) {
            int iIndex;
            if (iLeft >= 0 && (iRight == iEnd ||
                fTarget - hCandidates.Get(iLeft, 0) <= hCandidates.Get(iRight, 0) - fTarget)) {
                iIndex = iLeft--;
            } else {
                iIndex = iRight++;
            }

            Address pArea = view_as<Address>(hCandidates.Get(iIndex, 1));
            float fFlow = hCandidates.Get(iIndex, 0);
            float fOrigin[3];
            if (!PF_FindRouteSpawnSpot(pArea, fOrigin) || PF_NearExistingPill(hSpawns, fOrigin)) {
                continue;
            }

            float fAngles[3];
            fAngles[1] = GetRandomFloat(0.0, 360.0);
            int iEnt = CreateItemSpawn(IL_PainPills, fOrigin, fAngles);
            if (iEnt == -1) {
                continue;
            }

            if (bGlow) {
                L4D2_SetEntityGlow(iEnt, L4D2Glow_Constant, 0, 0, PF_GLOW_FILL, false);
            }

            ItemTracking curitem;
            curitem.IT_entity = iEnt;
            SetSpawnOrigins(fOrigin, curitem);
            SetSpawnAngles(fAngles, curitem);
            hSpawns.PushArray(curitem, sizeof(curitem));
            iSpawned++;

            if (IsDebugEnabled()) {
                LogMessage("[%s] Pill fill: spawned %d on main route at flow %.1f%% (%.0f %.0f %.0f)",
                    IT_MODULE_NAME, iEnt, fFlow / fMaxFlowDist * 100.0, fOrigin[0], fOrigin[1], fOrigin[2]);
            }
            break;
        }
    }

    delete hCandidates;
    if (iSpawned < iMissing) {
        LogMessage("[%s] Pill fill: spawned %d of %d missing pills on the main route.", IT_MODULE_NAME, iSpawned, iMissing);
    }
}

static int PF_SortByFirstFloat(int index1, int index2, Handle array, Handle hndl)
{
    ArrayList hList = view_as<ArrayList>(array);
    float a = hList.Get(index1, 0), b = hList.Get(index2, 0);
    return (a < b) ? -1 : ((a > b) ? 1 : 0);
}

static bool PF_FindRouteSpawnSpot(Address pArea, float fOut[3])
{
    L4D_FindRandomSpot(view_as<int>(pArea), fOut);
    float fStart[3], fEnd[3];
    fStart = fOut;
    fEnd = fOut;
    fStart[2] += 16.0;
    fEnd[2] -= 64.0;

    Handle hTrace = TR_TraceRayFilterEx(fStart, fEnd, MASK_PLAYERSOLID, RayType_EndPoint, PF_TraceSolidOnly);
    bool bGround = !TR_StartSolid(hTrace) && TR_DidHit(hTrace);
    if (bGround) {
        TR_GetEndPosition(fOut, hTrace);
    }
    delete hTrace;
    if (!bGround) {
        return false;
    }

    fOut[2] += 2.0;
    if (L4D_GetNearestNavArea(fOut, 80.0, true, false, true, L4D2Team_Survivor) != pArea) {
        return false;
    }

    if (IsMapDataAvailable()) {
        float fPoint[3];
        GetMapValueVector("start_point", fPoint);
        float fStartDist = GetMapValueFloat("start_dist");
        float fExtraDist = GetMapValueFloat("start_extra_dist");
        if (fExtraDist > fStartDist) {
            fStartDist = fExtraDist;
        }
        if (GetVectorDistance(fOut, fPoint) <= fStartDist) {
            return false;
        }
        GetMapValueVector("end_point", fPoint);
        if (GetVectorDistance(fOut, fPoint) <= GetMapValueFloat("end_dist")) {
            return false;
        }
    }

    static const float fMins[3] = {-8.0, -8.0, 0.0};
    static const float fMaxs[3] = {8.0, 8.0, 12.0};
    hTrace = TR_TraceHullFilterEx(fOut, fOut, fMins, fMaxs, MASK_PLAYERSOLID, PF_TraceSolidOnly);
    bool bClear = !TR_StartSolid(hTrace) && !TR_DidHit(hTrace);
    delete hTrace;
    return bClear;
}

static bool PF_NearExistingPill(ArrayList hSpawns, const float fOrigin[3])
{
    ItemTracking curitem;
    float fOther[3];
    for (int i = 0; i < hSpawns.Length; i++) {
        hSpawns.GetArray(i, curitem, sizeof(curitem));
        GetSpawnOrigins(fOther, curitem);
        if (GetVectorDistance(fOrigin, fOther) < 128.0) {
            return true;
        }
    }
    return false;
}

// Hits world and props; ignores players and other items.
static bool PF_TraceSolidOnly(int iEntity, int iContentsMask)
{
    if (iEntity > 0 && iEntity <= MaxClients) {
        return false;
    }

    if (iEntity > MaxClients && IsValidEdict(iEntity)) {
        char sClass[16];
        GetEdictClassname(iEntity, sClass, sizeof(sClass));
        if (strncmp(sClass, "weapon_", 7) == 0) {
            return false;
        }
    }

    return true;
}

// Start = lowest-flow area. Goal = end-checkpoint area nearest the map's max flow, else any area nearest it (no end saferoom).
static bool PF_FindRouteEnds(float fMaxFlowDist, Address &pStart, float &fStartFlow, Address &pGoal, float &fGoalFlow)
{
    ArrayList hAreas = new ArrayList();
    L4D_GetAllNavAreas(hAreas);

    Address pAny = Address_Null;
    float fAnyFlow = 0.0, fAnyDiff = 0.0, fGoalDiff = 0.0;
    pStart = Address_Null;
    pGoal = Address_Null;

    int iAreas = hAreas.Length;
    for (int i = 0; i < iAreas; i++) {
        Address pArea = view_as<Address>(hAreas.Get(i));
        float fFlow = L4D2Direct_GetTerrorNavAreaFlow(pArea);
        if (fFlow < 0.0) {
            continue;
        }

        if (pStart == Address_Null || fFlow < fStartFlow) {
            pStart = pArea;
            fStartFlow = fFlow;
        }

        float fDiff = FloatAbs(fFlow - fMaxFlowDist);
        if (pAny == Address_Null || fDiff < fAnyDiff) {
            pAny = pArea;
            fAnyFlow = fFlow;
            fAnyDiff = fDiff;
        }

        if (fFlow > fMaxFlowDist * 0.5 && (L4D_GetNavArea_SpawnAttributes(pArea) & NAV_SPAWN_CHECKPOINT)
            && (pGoal == Address_Null || fDiff < fGoalDiff)) {
            pGoal = pArea;
            fGoalFlow = fFlow;
            fGoalDiff = fDiff;
        }
    }

    delete hAreas;

    if (pGoal == Address_Null) {
        pGoal = pAny;
        fGoalFlow = fAnyFlow;
    }

    return (pStart != Address_Null && pGoal != Address_Null && fGoalFlow > fStartFlow);
}

// Walkable survivor path length between two areas, found by bisecting BuildPath's length cap; -1.0 if longer than fHigh.
static float PF_MeasurePath(Address pFrom, Address pTo, float fLow, float fHigh)
{
    if (!PF_PathWithin(pFrom, pTo, fHigh)) {
        return -1.0;
    }

    for (int i = 0; i < 8; i++) {
        float fMid = (fLow + fHigh) * 0.5;
        if (PF_PathWithin(pFrom, pTo, fMid)) {
            fHigh = fMid;
        } else {
            fLow = fMid;
        }
    }

    return fHigh;
}

// Event nav blockers are ignored: items are placed at round start, before crescendo gates open.
static bool PF_PathWithin(Address pFrom, Address pTo, float fMaxLen)
{
    return L4D2_NavAreaBuildPath(pFrom, pTo, fMaxLen, L4D2Team_Survivor, true);
}

static void SetSpawnOrigins(const float buf[3], ItemTracking spawn)
{
    spawn.IT_origins = buf[0];
    spawn.IT_origins1 = buf[1];
    spawn.IT_origins2 = buf[2];
}

static void SetSpawnAngles(const float buf[3], ItemTracking spawn)
{
    spawn.IT_angles = buf[0];
    spawn.IT_angles1 = buf[1];
    spawn.IT_angles2 = buf[2];
}

static void GetSpawnOrigins(float buf[3], const ItemTracking spawn)
{
    buf[0] = spawn.IT_origins;
    buf[1] = spawn.IT_origins1;
    buf[2] = spawn.IT_origins2;
}

static void GetSpawnAngles(float buf[3], const ItemTracking spawn)
{
    buf[0] = spawn.IT_angles;
    buf[1] = spawn.IT_angles1;
    buf[2] = spawn.IT_angles2;
}

static int GetWeaponIDFromItemList(int id)
{
    switch (id) {
        case IL_PainPills: {
            return WEPID_PAIN_PILLS;
        }
        case IL_Adrenaline: {
            return  WEPID_ADRENALINE;
        }
        case IL_PipeBomb: {
            return WEPID_PIPE_BOMB;
        }
        case IL_Molotov: {
            return WEPID_MOLOTOV;
        }
        case IL_VomitJar: {
            return WEPID_VOMITJAR;
        }
    }

    return -1;
}

static int GetItemIndexFromEntity(int entity)
{
    char classname[MAX_ENTITY_NAME_LENGTH];
    int index;

    GetEdictClassname(entity, classname, sizeof(classname));
    if (g_hItemListTrie.GetValue(classname, index)) {
        return index;
    }

    if (strcmp(classname, "weapon_spawn") == 0 || strcmp(classname, "weapon_item_spawn") == 0) {
        int id = GetEntProp(entity, Prop_Send, "m_weaponID");
        switch (id) {
            case WEPID_VOMITJAR: {
                return IL_VomitJar;
            }
            case WEPID_PIPE_BOMB: {
                return IL_PipeBomb;
            }
            case WEPID_MOLOTOV: {
                return IL_Molotov;
            }
            case WEPID_PAIN_PILLS: {
                return IL_PainPills;
            }
            case WEPID_ADRENALINE: {
                return IL_Adrenaline;
            }
        }
    }

    return -1;
}

static bool IsModuleEnabled()
{
    return (IsPluginEnabled() && g_hCvarEnabled.BoolValue);
}

stock bool IsScavengeMode()
{
    char   sCurGameMode[64];
    ConVar hCurGameMode = FindConVar("mp_gamemode");
    hCurGameMode.GetString(sCurGameMode, sizeof(sCurGameMode));
    if (strcmp(sCurGameMode, "scavenge") == 0)
        return true;
    else
        return false;
}

stock bool InSecondHalfOfRound()
{
    return view_as<bool>(GameRules_GetProp("m_bInSecondHalfOfRound"));
}
