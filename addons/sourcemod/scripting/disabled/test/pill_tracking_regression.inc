static char g_PillRegressionCase[32];
static ArrayList g_PillRegressionSaved;
static int g_PillRegressionUnknown = INVALID_ENT_REFERENCE;
static int g_PillRegressionFirst;
static int g_PillRegressionKnown;
static float g_PillRegressionElapsed;
static float g_PillRegressionDetour;

static void PillRegression_Assert(bool condition, const char[] message)
{
    if (!condition) {
        ThrowError("PILL_REGRESSION_FAIL %s", message);
    }
}

static Action PillRegression_Command(int args)
{
    for (int client = 1; client <= MaxClients; client++) {
        if (IsClientConnected(client) && !IsFakeClient(client)) {
            PrintToServer("PILL_REGRESSION_REFUSED humans present");
            return Plugin_Handled;
        }
    }
    GetCmdArg(1, g_PillRegressionCase, sizeof(g_PillRegressionCase));
    g_PillRegressionDetour = g_hCvarPillFlowMaxDetour.FloatValue;
    if (StrEqual(g_PillRegressionCase, "routes")) {
        PillRegression_Routes();
        return Plugin_Handled;
    }
    if (!StrEqual(g_PillRegressionCase, "map")) {
        for (int entity = MaxClients + 1; entity < GetMaxEntities(); entity++) {
            if (IsValidEntity(entity) && GetItemIndexFromEntity(entity) == IL_PainPills) {
                KillEntity(entity);
            }
        }
    }
    CreateTimer(0.1, PillRegression_Run, _, TIMER_FLAG_NO_MAPCHANGE);
    PrintToServer("PILL_REGRESSION_ACCEPTED");
    return Plugin_Handled;
}

static void PillRegression_Routes()
{
    float maxFlow = L4D2Direct_GetMapMaxFlowDistance();
    PFRoute route;
    PillRegression_Assert(PF_BuildRoute(maxFlow, route), "diagnostic route missing");
    ArrayList areas = new ArrayList();
    L4D_GetAllNavAreas(areas);
    Address nearest[4];
    float differences[4] = {999999.0, ...};
    for (int i = 0; i < areas.Length; i++) {
        Address area = areas.Get(i);
        if (!(L4D_GetNavArea_SpawnAttributes(area) & NAV_SPAWN_ESCAPE_ROUTE)) {
            continue;
        }
        float flow = L4D2Direct_GetTerrorNavAreaFlow(area);
        for (int bin = 0; bin < 4; bin++) {
            float difference = FloatAbs(flow / maxFlow - (0.45 + float(bin) * 0.1));
            if (difference < differences[bin]) {
                differences[bin] = difference;
                nearest[bin] = area;
            }
        }
    }
    delete areas;
    float start[3], goal[3];
    L4D_GetNavAreaCenter(route.pStart, start);
    L4D_GetNavAreaCenter(route.pGoal, goal);
    LogMessage("PILL_ROUTE_DIAG direct=%.0f", L4D2_NavAreaTravelDistance(start, goal, true));
    for (int bin = 0; bin < 4; bin++) {
        Address area = nearest[bin];
        float point[3];
        L4D_GetNavAreaCenter(area, point);
        float flow = L4D2Direct_GetTerrorNavAreaFlow(area);
        LogMessage("PILL_ROUTE_DIAG progress=%.1f area=%d onroute=%d start=%.0f goal=%.0f detour_budget=%.0f",
            flow / maxFlow * 100.0, L4D_GetNavAreaID(area), PF_IsOnRoute(route, area, g_PillRegressionDetour),
            L4D2_NavAreaTravelDistance(start, point, true), L4D2_NavAreaTravelDistance(point, goal, true),
            route.fRouteLen + 2.0 * g_PillRegressionDetour);
    }
    LogMessage("PILL_REGRESSION_PASS case=routes first=4 second=4 known=4 spots=4 finale=0");
}

static Action PillRegression_Run(Handle timer)
{
    bool fixture = !StrEqual(g_PillRegressionCase, "map");
    g_PillRegressionUnknown = INVALID_ENT_REFERENCE;
    if (fixture) {
        g_hCvarMapSpecificSpawns.IntValue = 0;
        g_hCvarPillFlowMin.FloatValue = 0.0;
        g_hCvarPillFlowMax.FloatValue = 1.0;
        g_hCvarPillFlowMaxDetour.FloatValue = 0.0;
        g_hCvarPillFlowFill.BoolValue = false;
        g_hCvarPillFlowRequireValid.BoolValue = false;
        g_hCvarLimits[IL_PainPills].IntValue = StrEqual(g_PillRegressionCase, "unlimited") ? -1 : 4;
        if (StrEqual(g_PillRegressionCase, "zero")) {
            g_hCvarLimits[IL_PainPills].IntValue = 0;
        }
        if (!StrEqual(g_PillRegressionCase, "generic") && !StrEqual(g_PillRegressionCase, "unlimited")) {
            g_hCvarPillFlowMin.FloatValue = 0.3;
            g_hCvarPillFlowMax.FloatValue = 0.9;
        }
        float maxFlow = L4D2Direct_GetMapMaxFlowDistance();
        ArrayList areas = new ArrayList();
        L4D_GetAllNavAreas(areas);
        float origin[3], angles[3];
        ArrayList doors = PF_CollectDoorClearances();
        bool found;
        for (int index = 0; index < areas.Length; index++) {
            Address area = view_as<Address>(areas.Get(index));
            float progress = L4D2Direct_GetTerrorNavAreaFlow(area) / maxFlow;
            if (progress >= 0.4 && progress <= 0.8 && (L4D_GetNavArea_SpawnAttributes(area) & NAV_SPAWN_ESCAPE_ROUTE)
                && PF_FindRouteSpawnSpot(area, doors, origin)) {
                found = true;
                break;
            }
        }
        delete areas;
        delete doors;
        PillRegression_Assert(found, "fixture location missing");
        bool fill = StrEqual(g_PillRegressionCase, "fill");
        int stacked = CreateItemSpawn(IL_PainPills, origin, angles, fill ? 0 : 7);
        PillRegression_Assert(stacked != -1 && IT_GetSpawnCount(stacked) == (fill ? 0 : 7), "stack creation count");
        if (fill) {
            ArrayList flows = new ArrayList();
            flows.Push(40.0);
            flows.Push(80.0);
            flows.Push(42.0);
            flows.Push(46.0);
            flows.Push(50.0);
            float gapMin, gapMax;
            float target = PF_PickFillGap(flows, gapMin, gapMax);
            PillRegression_Assert(gapMin == 50.0 && gapMax == 80.0 && target >= 62.0 && target <= 68.0, "largest gap ignores retained pills");
            flows.Push(target);
            PF_PickFillGap(flows, gapMin, gapMax);
            PillRegression_Assert(gapMax - gapMin < 30.0, "successful fill did not split gap");
            delete flows;
            g_hCvarPillFlowFill.BoolValue = true;
            g_hCvarPillFlowMaxDetour.FloatValue = g_PillRegressionDetour;
            g_hCvarPillFlowRequireValid.BoolValue = true;
        }
        int empty = CreateItemSpawn(IL_PainPills, origin, angles);
        SetEntProp(empty, Prop_Data, "m_itemCount", 0);
        PillRegression_Assert(IT_GetSpawnCount(empty) == 0, "empty count");
        if (StrEqual(g_PillRegressionCase, "strict") || StrEqual(g_PillRegressionCase, "unknown")) {
            origin[2] += 2048.0;
            TeleportEntity(stacked, origin, NULL_VECTOR, NULL_VECTOR);
            Address area = L4D_GetNearestNavArea(origin, 120.0, true, false, false, 2);
            if (area == Address_Null) {
                area = L4D2Direct_GetTerrorNavArea(origin);
            }
            PillRegression_Assert(area == Address_Null || L4D2Direct_GetTerrorNavAreaFlow(area) < 0.0, "fixture must have unreadable flow");
            if (StrEqual(g_PillRegressionCase, "strict")) {
                g_PillRegressionUnknown = EntIndexToEntRef(stacked);
                g_hCvarPillFlowFill.BoolValue = true;
                g_hCvarPillFlowRequireValid.BoolValue = true;
            }
        }
    }
    IT_OnMapStart();
    IsPluginEnabled(true, true);
    g_hCvarEnabled.BoolValue = true;
    g_hCvarConsistentSpawns.BoolValue = true;
    g_iSaferoomCount[0] = 0;
    g_iSaferoomCount[1] = 0;
    float started = GetEngineTime();
    IT_RoundStartTimer(null);
    g_PillRegressionElapsed = GetEngineTime() - started;
    delete g_PillRegressionSaved;
    g_PillRegressionSaved = g_hItemSpawns[IL_PainPills].Clone();
    CreateTimer(0.1, PillRegression_First, _, TIMER_FLAG_NO_MAPCHANGE);
    return Plugin_Stop;
}

static int PillRegression_Actual()
{
    int total;
    for (int entity = MaxClients + 1; entity < GetMaxEntities(); entity++) {
        if (!IsValidEntity(entity) || GetItemIndexFromEntity(entity) != IL_PainPills
            || IsEntityInSaferoom(entity, START_SAFEROOM) || IsEntityInSaferoom(entity, END_SAFEROOM)) {
            continue;
        }
        int count = IT_GetSpawnCount(entity);
        PillRegression_Assert(count > 0, "empty spawn remains in world");
        total += count;
    }
    return total;
}

static Action PillRegression_First(Handle timer)
{
    ArrayList saved = g_PillRegressionSaved;
    ItemTracking item;
    int firstTotal, knownTotal;
    float maxFlow = L4D2Direct_GetMapMaxFlowDistance();
    bool fill = StrEqual(g_PillRegressionCase, "fill");
    PFRoute route;
    ArrayList doors = PF_CollectDoorClearances();
    if (fill) {
        PillRegression_Assert(PF_BuildRoute(maxFlow, route), "fill route missing");
    }
    for (int index = 0; index < saved.Length; index++) {
        saved.GetArray(index, item, sizeof(item));
        PillRegression_Assert(IsValidEntity(item.IT_entity), "missing first half entity");
        int count = IT_GetSpawnCount(item.IT_entity);
        PillRegression_Assert(count > 0 && count == item.IT_count, "stored bottle count mismatch");
        firstTotal += count;
        float origin[3];
        GetSpawnOrigins(origin, item);
        Address area = L4D_GetNearestNavArea(origin, 120.0, true, false, false, 2);
        if (area == Address_Null) {
            area = L4D2Direct_GetTerrorNavArea(origin);
        }
        float flow = area == Address_Null ? -1.0 : L4D2Direct_GetTerrorNavAreaFlow(area);
        if (flow >= 0.0) {
            knownTotal += count;
            LogMessage("PILL_REGRESSION_POINT count=%d progress=%.1f%%", count, flow / maxFlow * 100.0);
        }
        if (fill) {
            PillRegression_Assert(flow >= maxFlow * 0.4 && flow <= maxFlow * 0.8, "fill progress range");
            PillRegression_Assert(PF_IsOnRoute(route, area, g_PillRegressionDetour), "fill off main route");
            PillRegression_Assert(!PF_NearAmmoPile(origin), "fill overlaps ammo pile");
            PillRegression_Assert(!PF_NearDoor(doors, origin), "fill overlaps door clearance");
        }
    }
    delete doors;
    PillRegression_Assert(PillRegression_Actual() == firstTotal, "untracked first half bottles");
    if (!StrEqual(g_PillRegressionCase, "map") && !StrEqual(g_PillRegressionCase, "strict")
        && !StrEqual(g_PillRegressionCase, "zero") && !fill) {
        PillRegression_Assert(saved.Length == 1, "stack fixture must remain one spot");
    }
    if (g_PillRegressionUnknown != INVALID_ENT_REFERENCE) {
        PillRegression_Assert(EntRefToEntIndex(g_PillRegressionUnknown) == INVALID_ENT_REFERENCE, "unknown point was not replaced");
    }
    for (int index = 0; index < saved.Length; index++) {
        saved.GetArray(index, item, sizeof(item));
        KillEntity(item.IT_entity);
    }
    g_PillRegressionFirst = firstTotal;
    g_PillRegressionKnown = knownTotal;
    CreateTimer(0.1, PillRegression_Restore, _, TIMER_FLAG_NO_MAPCHANGE);
    return Plugin_Stop;
}

static Action PillRegression_Restore(Handle timer)
{
    PillRegression_Assert(PillRegression_Actual() == 0, "simulated consumption incomplete");
    g_iSaferoomCount[0] = 0;
    g_iSaferoomCount[1] = 0;
    g_bIsRound1Over = true;
    IT_RoundStartTimer(null);
    CreateTimer(0.1, PillRegression_Second, _, TIMER_FLAG_NO_MAPCHANGE);
    return Plugin_Stop;
}

static Action PillRegression_Second(Handle timer)
{
    ArrayList saved = g_PillRegressionSaved;
    ItemTracking item;
    PillRegression_Assert(saved.Length == g_hItemSpawns[IL_PainPills].Length, "second half spot count");
    int secondTotal;
    for (int index = 0; index < saved.Length; index++) {
        ItemTracking restored;
        saved.GetArray(index, item, sizeof(item));
        g_hItemSpawns[IL_PainPills].GetArray(index, restored, sizeof(restored));
        PillRegression_Assert(IsValidEntity(restored.IT_entity), "missing restored entity");
        int count = IT_GetSpawnCount(restored.IT_entity);
        PillRegression_Assert(count == item.IT_count && count == restored.IT_count, "second half bottle count");
        float expected[3], actual[3];
        GetSpawnOrigins(expected, item);
        GetEntPropVector(restored.IT_entity, Prop_Data, "m_vecAbsOrigin", actual);
        PillRegression_Assert(GetVectorDistance(expected, actual) < 0.1, "second half position");
        secondTotal += count;
    }
    delete g_PillRegressionSaved;
    PillRegression_Assert(PillRegression_Actual() == secondTotal, "untracked second half bottles");
    int firstTotal = g_PillRegressionFirst;
    int knownTotal = g_PillRegressionKnown;
    bool finale = L4D_IsMissionFinalMap();
    int expectedTotal = StrEqual(g_PillRegressionCase, "unlimited") ? 7 : 4;
    if (StrEqual(g_PillRegressionCase, "zero")) {
        expectedTotal = 0;
    }
    if (!StrEqual(g_PillRegressionCase, "map") || !finale) {
        PillRegression_Assert(firstTotal == expectedTotal && secondTotal == expectedTotal, "actual bottle limit");
        if (g_hCvarPillFlowRequireValid.BoolValue) {
            PillRegression_Assert(knownTotal == firstTotal, "unreadable pill remains");
        }
    }
    char map[64];
    GetCurrentMap(map, sizeof(map));
    LogMessage("PILL_REGRESSION_PASS case=%s map=%s first=%d second=%d known=%d spots=%d finale=%d elapsed=%.4f",
        g_PillRegressionCase, map, firstTotal, secondTotal, knownTotal, g_hItemSpawns[IL_PainPills].Length, finale, g_PillRegressionElapsed);
    return Plugin_Stop;
}
