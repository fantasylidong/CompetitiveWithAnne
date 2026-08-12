#if defined _infected_control_event_pressure_included
    #endinput
#endif
#define _infected_control_event_pressure_included

#define EVENT_PRESSURE_REASON_ALARM_CAR 1
#define EVENT_PRESSURE_ALARM_CAR_HOLD 10.0
#define EVENT_PRESSURE_MAP_PANIC_HOLD 60.0

enum EventPressurePanicKind
{
    EventPressurePanic_None = 0,
    EventPressurePanic_AlarmCar,
    EventPressurePanic_MapEvent
}

static DynamicDetour g_hMapPanicDetour = null;
static bool g_bMapPanicDetourActive = false;
static bool g_bPanicGameEventActive = false;
static bool g_bFinaleEventActive = false;
static bool g_bHoldoutEventActive = false;
static bool g_bForwardInfiniteHordeActive = false;
static bool g_bForwardFinaleEventActive = false;
static bool g_bFinalMap = false;
static float g_fMapPanicActiveUntil = 0.0;
static EventPressurePanicKind g_eMapPanicKind = EventPressurePanic_None;

void EventPressure_Init()
{
    GameData gameData = new GameData("trigger_horde_notify");
    if (gameData == null)
    {
        LogError("[IC][AntiBait] Missing trigger_horde_notify gamedata; using game-event fallback for panic detection");
        return;
    }

    g_hMapPanicDetour = DynamicDetour.FromConf(gameData, "CDirector::OnMapInvokedPanicEvent");
    delete gameData;

    if (g_hMapPanicDetour == null)
    {
        LogError("[IC][AntiBait] Missing CDirector::OnMapInvokedPanicEvent detour; using game-event fallback");
        return;
    }

    if (!g_hMapPanicDetour.Enable(Hook_Post, EventPressure_OnMapPanicPost))
    {
        LogError("[IC][AntiBait] Failed to enable map panic detour; using game-event fallback");
        delete g_hMapPanicDetour;
        return;
    }

    g_bMapPanicDetourActive = true;
}

void EventPressure_Shutdown()
{
    g_bMapPanicDetourActive = false;
    delete g_hMapPanicDetour;
}

void EventPressure_Reset()
{
    g_bPanicGameEventActive = false;
    g_bFinaleEventActive = false;
    g_bHoldoutEventActive = false;
    g_bForwardInfiniteHordeActive = false;
    g_bForwardFinaleEventActive = false;
    g_fMapPanicActiveUntil = 0.0;
    g_eMapPanicKind = EventPressurePanic_None;
}

bool EventPressure_ShouldBypassAntiBait()
{
    return g_bPanicGameEventActive
        || EventPressure_IsMapPanicWindowActive()
        || g_bFinaleEventActive
        || g_bHoldoutEventActive
        || g_bForwardInfiniteHordeActive
        || g_bForwardFinaleEventActive;
}

void EventPressure_OnMapStart()
{
    g_bFinalMap = L4D_IsMissionFinalMap(true);
    if (!g_bFinalMap)
        return;

    int entity = -1;
    while ((entity = FindEntityByClassname(entity, "trigger_finale")) != -1)
        HookSingleEntityOutput(entity, "UseStart", EventPressure_OnFinaleUseStart, true);
}

void EventPressure_OnMapEnd()
{
    g_bFinalMap = false;
}

void EventPressure_OnEntityCreated(int entity, const char[] classname)
{
    if (!g_bFinalMap || entity <= MaxClients || !StrEqual(classname, "trigger_finale"))
        return;

    HookSingleEntityOutput(entity, "UseStart", EventPressure_OnFinaleUseStart, true);
}

static bool EventPressure_IsMapPanicWindowActive()
{
    if (g_fMapPanicActiveUntil <= 0.0)
        return false;

    float now = GetGameTime();
    if (now < g_fMapPanicActiveUntil)
        return true;

    Debug_Print("[EVENT] map panic window ended kind=%d", view_as<int>(g_eMapPanicKind));
    g_fMapPanicActiveUntil = 0.0;
    g_eMapPanicKind = EventPressurePanic_None;
    return false;
}

static void EventPressure_ArmMapPanic(EventPressurePanicKind kind, float duration,
                                      const char[] source, int client = 0)
{
    float now = GetGameTime();
    float activeUntil = now + duration;
    if (activeUntil > g_fMapPanicActiveUntil)
    {
        g_fMapPanicActiveUntil = activeUntil;
        g_eMapPanicKind = kind;
    }

    if (client > 0 && client <= MaxClients && IsClientInGame(client))
    {
        Debug_Print("[EVENT] map panic detected source=%s kind=%d client=%N hold=%.1fs",
            source, view_as<int>(kind), client, duration);
    }
    else
    {
        Debug_Print("[EVENT] map panic detected source=%s kind=%d hold=%.1fs",
            source, view_as<int>(kind), duration);
    }
}

static void EventPressure_SetFinaleActive(const char[] source)
{
    if (!g_bFinaleEventActive)
        Debug_Print("[EVENT] finale pressure detected source=%s", source);
    g_bFinaleEventActive = true;
}

public MRESReturn EventPressure_OnMapPanicPost(int pThis, Handle hReturn, Handle hParams)
{
    // Match trigger_horde_notify: param 2 is panic_event_reason_t
    // (0/other = map event, 1 = alarm car).
    // Unlike its chat notification, event pressure does not require a player
    // activator; scripted/world-triggered panic events must still be detected.
    int client = DHookIsNullParam(hParams, 1) ? 0 : DHookGetParam(hParams, 1);

    int reason = DHookGetParam(hParams, 2);
    if (reason == EVENT_PRESSURE_REASON_ALARM_CAR)
    {
        EventPressure_ArmMapPanic(EventPressurePanic_AlarmCar,
            EVENT_PRESSURE_ALARM_CAR_HOLD, "director_detour", client);
    }
    else
    {
        EventPressure_ArmMapPanic(EventPressurePanic_MapEvent,
            EVENT_PRESSURE_MAP_PANIC_HOLD, "director_detour", client);
    }

    return MRES_Ignored;
}

public void EventPressure_OnPanicStart(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_bPanicGameEventActive)
        Debug_Print("[EVENT] panic game event started");
    g_bPanicGameEventActive = true;

    if (!g_bMapPanicDetourActive)
    {
        EventPressure_ArmMapPanic(EventPressurePanic_MapEvent,
            EVENT_PRESSURE_MAP_PANIC_HOLD, "game_event_fallback");
    }
}

public void EventPressure_OnPanicEnd(Event event, const char[] name, bool dontBroadcast)
{
    if (g_bPanicGameEventActive)
        Debug_Print("[EVENT] panic game event finished; classified window remains=%d",
            EventPressure_IsMapPanicWindowActive());
    g_bPanicGameEventActive = false;
}

public void EventPressure_OnFinaleStart(Event event, const char[] name, bool dontBroadcast)
{
    EventPressure_SetFinaleActive(name);
}

static void EventPressure_OnFinaleUseStart(const char[] output, int caller, int activator, float delay)
{
    EventPressure_SetFinaleActive("trigger_finale.UseStart");
}

public void OnHoldOutBonusStart(int time)
{
    Debug_Print("[EVENT] holdout pressure started duration=%ds", time);
    g_bHoldoutEventActive = true;
}

public void OnHoldOutBonusEnd(int bonus, int time)
{
    Debug_Print("[EVENT] holdout pressure ended bonus=%d duration=%ds", bonus, time);
    g_bHoldoutEventActive = false;
}

// Optional compatibility with trigger_horde_notify and older horde-state producers.
public void L4D2_HordeStatus(int status)
{
    switch (status)
    {
        case 0:
        {
            g_bForwardInfiniteHordeActive = false;
            g_bForwardFinaleEventActive = false;
            Debug_Print("[EVENT] external horde pressure cleared");
        }
        case 1:
        {
            g_bForwardInfiniteHordeActive = true;
            Debug_Print("[EVENT] external infinite horde detected");
        }
        case 2:
        {
            EventPressure_ArmMapPanic(EventPressurePanic_AlarmCar,
                EVENT_PRESSURE_ALARM_CAR_HOLD, "L4D2_HordeStatus");
        }
        case 3:
        {
            EventPressure_ArmMapPanic(EventPressurePanic_MapEvent,
                EVENT_PRESSURE_MAP_PANIC_HOLD, "L4D2_HordeStatus");
        }
        case 4:
        {
            g_bForwardFinaleEventActive = true;
            Debug_Print("[EVENT] external finale horde detected");
        }
    }
}
