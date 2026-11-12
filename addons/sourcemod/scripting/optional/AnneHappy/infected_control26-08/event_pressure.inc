#if defined _infected_control_event_pressure_included
    #endinput
#endif
#define _infected_control_event_pressure_included

#define EVENT_PRESSURE_REASON_ALARM_CAR 1
#define EVENT_PRESSURE_ALARM_CAR_HOLD 10.0
#define EVENT_PRESSURE_MAP_PANIC_HOLD 60.0
#define EVENT_PRESSURE_C5M2_MAP "c5m2_park"
#define EVENT_PRESSURE_C5M2_START_CLASS "trigger_once"
#define EVENT_PRESSURE_C5M2_START_NAME "finale_start_trigger"
#define EVENT_PRESSURE_C5M2_END_CLASS "func_button"
#define EVENT_PRESSURE_C5M2_END_NAME "finale_alarm_stop_button"
#define EVENT_PRESSURE_C5M2_END_DELAY 5.0
#define EVENT_PRESSURE_PANIC_EVENT_HOLD 60.0

enum EventPressurePanicKind
{
    EventPressurePanic_None = 0,
    EventPressurePanic_AlarmCar,
    EventPressurePanic_MapEvent
}

static DynamicDetour g_hMapPanicDetour = null;
static bool g_bMapPanicDetourActive = false;
// create_panic_event 的滚动有效窗口：每次收到新的 panic 事件都刷新，
// panic_event_finished 立即清除。带超时是为了防止三方图只发 create 不发
// finished 时整回合旁路 Anti-Bait；真正的无限尸潮由脚本重复触发 panic
// 事件（会不断刷新窗口）或由 L4D2_HordeStatus(1) 转发覆盖。
static float g_fPanicGameEventUntil = 0.0;
static bool g_bFinaleEventActive = false;
static bool g_bHoldoutEventActive = false;
static bool g_bForwardInfiniteHordeActive = false;
static bool g_bForwardFinaleEventActive = false;
static bool g_bEqualiserFiniteEventConfigured = false;
static bool g_bEqualiserFiniteEventActive = false;
static bool g_bFinalMap = false;
static bool g_bC5M2Map = false;
static bool g_bScriptedMapEventActive = false;
static bool g_bScriptedMapEventCompleted = false;
static bool g_bScriptedHordeObserved = false;
static float g_fMapPanicActiveUntil = 0.0;
static float g_fScriptedMapEventEndAt = 0.0;
static float g_fEventPressurePauseStartedAt = 0.0;
static EventPressurePanicKind g_eMapPanicKind = EventPressurePanic_None;

void EventPressure_Init()
{
    GameData gameData = new GameData("infected_control");
    if (gameData == null)
    {
        LogError("[IC][AntiBait] Missing infected_control gamedata; using game-event fallback for panic detection");
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
    g_fPanicGameEventUntil = 0.0;
    g_bFinaleEventActive = false;
    g_bHoldoutEventActive = false;
    g_bForwardInfiniteHordeActive = false;
    g_bForwardFinaleEventActive = false;
    g_bEqualiserFiniteEventConfigured = false;
    g_bEqualiserFiniteEventActive = false;
    g_bScriptedMapEventActive = false;
    g_bScriptedMapEventCompleted = false;
    g_bScriptedHordeObserved = false;
    g_fMapPanicActiveUntil = 0.0;
    g_fScriptedMapEventEndAt = 0.0;
    g_fEventPressurePauseStartedAt = 0.0;
    g_eMapPanicKind = EventPressurePanic_None;
}

void EventPressure_OnPause()
{
    if (g_fEventPressurePauseStartedAt <= 0.0)
        g_fEventPressurePauseStartedAt = GetGameTime();
}

void EventPressure_OnUnpause()
{
    if (g_fEventPressurePauseStartedAt <= 0.0)
        return;

    float pausedFor = FloatMax(0.0, GetGameTime() - g_fEventPressurePauseStartedAt);
    if (g_fMapPanicActiveUntil > 0.0)
        g_fMapPanicActiveUntil += pausedFor;
    if (g_fScriptedMapEventEndAt > 0.0)
        g_fScriptedMapEventEndAt += pausedFor;
    if (g_fPanicGameEventUntil > 0.0)
        g_fPanicGameEventUntil += pausedFor;
    g_fEventPressurePauseStartedAt = 0.0;
}

static float EventPressure_GetTime()
{
    if (g_fEventPressurePauseStartedAt > 0.0)
        return g_fEventPressurePauseStartedAt;
    return GetGameTime();
}

static bool EventPressure_IsPanicGameEventActive()
{
    return g_fPanicGameEventUntil > 0.0 && EventPressure_GetTime() < g_fPanicGameEventUntil;
}

bool EventPressure_ShouldBypassAntiBait()
{
    EventPressure_UpdateScriptedMapEvent();
    return EventPressure_IsPanicGameEventActive()
        || EventPressure_IsMapPanicWindowActive()
        || g_bFinaleEventActive
        || g_bHoldoutEventActive
        || g_bForwardInfiniteHordeActive
        || g_bForwardFinaleEventActive
        || g_bEqualiserFiniteEventActive
        || (!g_bEqualiserFiniteEventConfigured && g_bScriptedMapEventActive);
}

static void EventPressure_SetEqualiserFiniteEventConfigured(bool configured,
                                                            int commonLimit,
                                                            const char[] source)
{
    if (g_bEqualiserFiniteEventConfigured == configured)
        return;

    g_bEqualiserFiniteEventConfigured = configured;
    Debug_Print("[EVENT] finite horde authority configured=%d source=%s limit=%d",
        configured ? 1 : 0, source, commonLimit);

    if (configured)
    {
        g_fPanicGameEventUntil = 0.0;
        g_bForwardInfiniteHordeActive = false;
        if (g_eMapPanicKind == EventPressurePanic_MapEvent)
        {
            g_fMapPanicActiveUntil = 0.0;
            g_eMapPanicKind = EventPressurePanic_None;
        }

        if (g_bScriptedMapEventActive)
        {
            g_bScriptedMapEventActive = false;
            g_bScriptedHordeObserved = false;
            g_fScriptedMapEventEndAt = 0.0;
            Debug_Print("[EVENT] scripted entity fallback superseded by finite horde authority");
        }

        if (g_bC5M2Map)
            EventPressure_UnhookC5M2Outputs();
    }
    else if (g_bC5M2Map)
    {
        EventPressure_HookC5M2Outputs();
    }
}

static void EventPressure_SetEqualiserFiniteEvent(bool active, int commonLimit,
                                                  int commonSpawned,
                                                  const char[] source)
{
    if (g_bEqualiserFiniteEventActive == active)
        return;

    g_bEqualiserFiniteEventActive = active;
    if (active)
    {
        Debug_Print("[EVENT] finite horde detected source=%s limit=%d spawned=%d",
            source, commonLimit, commonSpawned);
        WaveDecider_OnEventPressureStarted(source);
    }
    else
    {
        Debug_Print("[EVENT] finite horde ended source=%s limit=%d spawned=%d",
            source, commonLimit, commonSpawned);
    }
}

void EventPressure_SyncEqualiserState(const char[] source)
{
    if (!LibraryExists("l4d2_horde_equaliser"))
    {
        EventPressure_SetEqualiserFiniteEvent(false, -1, -1, source);
        EventPressure_SetEqualiserFiniteEventConfigured(false, -1, source);
        return;
    }

    if (GetFeatureStatus(FeatureType_Native,
            "L4D2HordeEqualiser_IsFiniteEventActive") != FeatureStatus_Available
        || GetFeatureStatus(FeatureType_Native,
            "L4D2HordeEqualiser_GetFiniteEventLimit") != FeatureStatus_Available)
    {
        return;
    }

    int commonLimit = L4D2HordeEqualiser_GetFiniteEventLimit();
    bool configured = commonLimit > 0;
    EventPressure_SetEqualiserFiniteEventConfigured(configured, commonLimit, source);
    EventPressure_SetEqualiserFiniteEvent(
        configured && L4D2HordeEqualiser_IsFiniteEventActive(),
        commonLimit, -1, source);
}

void EventPressure_OnEqualiserLibraryRemoved()
{
    EventPressure_SetEqualiserFiniteEvent(false, -1, -1, "horde_equaliser_unloaded");
    EventPressure_SetEqualiserFiniteEventConfigured(false, -1, "horde_equaliser_unloaded");
}

public void L4D2HordeEqualiser_OnFiniteEventStateChanged(bool active,
                                                         int commonLimit,
                                                         int commonSpawned)
{
    bool configured = commonLimit > 0;
    EventPressure_SetEqualiserFiniteEventConfigured(configured, commonLimit,
        "horde_equaliser_forward");
    EventPressure_SetEqualiserFiniteEvent(configured && active, commonLimit, commonSpawned,
        "horde_equaliser_forward");
}

void EventPressure_OnMapStart()
{
    EventPressure_OnRoundStart();
}

void EventPressure_OnRoundStart()
{
    char mapName[PLATFORM_MAX_PATH];
    GetCurrentMap(mapName, sizeof mapName);
    g_bC5M2Map = StrEqual(mapName, EVENT_PRESSURE_C5M2_MAP, false);
    g_bFinalMap = L4D_IsMissionFinalMap(true);
    EventPressure_SyncEqualiserState("round_start");

    if (g_bFinalMap)
    {
        int entity = -1;
        while ((entity = FindEntityByClassname(entity, "trigger_finale")) != -1)
        {
            UnhookSingleEntityOutput(entity, "UseStart", EventPressure_OnFinaleUseStart);
            HookSingleEntityOutput(entity, "UseStart", EventPressure_OnFinaleUseStart, true);
        }
    }

    if (g_bC5M2Map && !g_bEqualiserFiniteEventConfigured)
        EventPressure_HookC5M2Outputs();
}

void EventPressure_OnMapEnd()
{
    g_bFinalMap = false;
    g_bC5M2Map = false;
    g_bEqualiserFiniteEventConfigured = false;
    g_bEqualiserFiniteEventActive = false;
    g_bScriptedMapEventActive = false;
    g_bScriptedMapEventCompleted = false;
    g_bScriptedHordeObserved = false;
    g_fScriptedMapEventEndAt = 0.0;
}

void EventPressure_OnEntityCreated(int entity, const char[] classname)
{
    if (entity <= MaxClients)
        return;

    if (g_bFinalMap && StrEqual(classname, "trigger_finale"))
    {
        UnhookSingleEntityOutput(entity, "UseStart", EventPressure_OnFinaleUseStart);
        HookSingleEntityOutput(entity, "UseStart", EventPressure_OnFinaleUseStart, true);
    }

    if (g_bC5M2Map && !g_bEqualiserFiniteEventConfigured
        && (StrEqual(classname, EVENT_PRESSURE_C5M2_START_CLASS)
            || StrEqual(classname, EVENT_PRESSURE_C5M2_END_CLASS)))
    {
        RequestFrame(EventPressure_OnC5M2EntityCreatedFrame, EntIndexToEntRef(entity));
    }
}

static int EventPressure_FindNamedEntity(const char[] classname, const char[] targetName)
{
    int entity = -1;
    char name[64];
    while ((entity = FindEntityByClassname(entity, classname)) != -1)
    {
        if (!HasEntProp(entity, Prop_Data, "m_iName"))
            continue;

        GetEntPropString(entity, Prop_Data, "m_iName", name, sizeof name);
        if (StrEqual(name, targetName, false))
            return entity;
    }
    return -1;
}

static void EventPressure_HookC5M2Entity(int entity)
{
    if (entity <= MaxClients || !IsValidEntity(entity)
        || !HasEntProp(entity, Prop_Data, "m_iName"))
    {
        return;
    }

    char classname[64], name[64];
    GetEntityClassname(entity, classname, sizeof classname);
    GetEntPropString(entity, Prop_Data, "m_iName", name, sizeof name);

    if (StrEqual(classname, EVENT_PRESSURE_C5M2_START_CLASS)
        && StrEqual(name, EVENT_PRESSURE_C5M2_START_NAME, false))
    {
        UnhookSingleEntityOutput(entity, "OnStartTouch", EventPressure_OnC5M2Start);
        HookSingleEntityOutput(entity, "OnStartTouch", EventPressure_OnC5M2Start, true);
    }
    else if (StrEqual(classname, EVENT_PRESSURE_C5M2_END_CLASS)
        && StrEqual(name, EVENT_PRESSURE_C5M2_END_NAME, false))
    {
        UnhookSingleEntityOutput(entity, "OnPressed", EventPressure_OnC5M2EndPressed);
        HookSingleEntityOutput(entity, "OnPressed", EventPressure_OnC5M2EndPressed, true);
    }
}

static void EventPressure_HookC5M2Outputs()
{
    if (!g_bC5M2Map || g_bEqualiserFiniteEventConfigured)
        return;

    int startEntity = EventPressure_FindNamedEntity(
        EVENT_PRESSURE_C5M2_START_CLASS, EVENT_PRESSURE_C5M2_START_NAME);
    int endEntity = EventPressure_FindNamedEntity(
        EVENT_PRESSURE_C5M2_END_CLASS, EVENT_PRESSURE_C5M2_END_NAME);

    if (startEntity != -1)
        EventPressure_HookC5M2Entity(startEntity);
    if (endEntity != -1)
        EventPressure_HookC5M2Entity(endEntity);

    Debug_Print("[EVENT] c5m2 scripted hooks start=%d end=%d", startEntity, endEntity);
}

static void EventPressure_UnhookC5M2Outputs()
{
    int startEntity = EventPressure_FindNamedEntity(
        EVENT_PRESSURE_C5M2_START_CLASS, EVENT_PRESSURE_C5M2_START_NAME);
    int endEntity = EventPressure_FindNamedEntity(
        EVENT_PRESSURE_C5M2_END_CLASS, EVENT_PRESSURE_C5M2_END_NAME);

    if (startEntity != -1)
        UnhookSingleEntityOutput(startEntity, "OnStartTouch", EventPressure_OnC5M2Start);
    if (endEntity != -1)
        UnhookSingleEntityOutput(endEntity, "OnPressed", EventPressure_OnC5M2EndPressed);
}

public void EventPressure_OnC5M2EntityCreatedFrame(any entityRef)
{
    if (!g_bC5M2Map || g_bEqualiserFiniteEventConfigured)
        return;

    int entity = EntRefToEntIndex(entityRef);
    if (entity == INVALID_ENT_REFERENCE)
        return;

    EventPressure_HookC5M2Entity(entity);
}

static void EventPressure_StartScriptedMapEvent(const char[] source, int activator = 0)
{
    if (g_bEqualiserFiniteEventConfigured || g_bScriptedMapEventCompleted)
        return;

    g_fScriptedMapEventEndAt = 0.0;
    if (g_bScriptedMapEventActive)
        return;

    g_bScriptedMapEventActive = true;
    g_bScriptedHordeObserved = false;
    if (activator > 0 && activator <= MaxClients && IsClientInGame(activator))
    {
        Debug_Print("[EVENT] scripted map event started map=%s source=%s client=%N",
            EVENT_PRESSURE_C5M2_MAP, source, activator);
    }
    else
    {
        Debug_Print("[EVENT] scripted map event started map=%s source=%s",
            EVENT_PRESSURE_C5M2_MAP, source);
    }
    WaveDecider_OnEventPressureStarted(source);
}

static void EventPressure_UpdateScriptedMapEvent()
{
    if (!g_bScriptedMapEventActive || g_fScriptedMapEventEndAt <= 0.0
        || EventPressure_GetTime() < g_fScriptedMapEventEndAt)
    {
        return;
    }

    g_bScriptedMapEventActive = false;
    g_bScriptedHordeObserved = false;
    g_fScriptedMapEventEndAt = 0.0;
    Debug_Print("[EVENT] scripted map event ended map=%s source=director_EndScript",
        EVENT_PRESSURE_C5M2_MAP);
}

void EventPressure_Update()
{
    EventPressure_UpdateScriptedMapEvent();
}

static bool EventPressure_GetHordeMonitorSignal(int &countdown)
{
    CountdownTimer mobTimer = L4D2Direct_GetMobSpawnTimer();
    if (!CTimer_HasStarted(mobTimer))
    {
        countdown = -1;
        return false;
    }

    countdown = RoundFloat(CTimer_GetRemainingTime(mobTimer));
    return countdown > -1 && countdown <= 10;
}

public Action L4D_OnSpawnMob(int &amount)
{
    if (!g_bC5M2Map || g_bEqualiserFiniteEventConfigured)
        return Plugin_Continue;

    int countdown;
    if (!EventPressure_GetHordeMonitorSignal(countdown))
        return Plugin_Continue;

    if (!g_bScriptedMapEventActive && !g_bScriptedMapEventCompleted)
    {
        int startEntity = EventPressure_FindNamedEntity(
            EVENT_PRESSURE_C5M2_START_CLASS, EVENT_PRESSURE_C5M2_START_NAME);
        int endEntity = EventPressure_FindNamedEntity(
            EVENT_PRESSURE_C5M2_END_CLASS, EVENT_PRESSURE_C5M2_END_NAME);
        if (startEntity == -1 && endEntity != -1)
            EventPressure_StartScriptedMapEvent("c5m2_horde_monitor_recovery");
    }

    if (g_bScriptedMapEventActive && !g_bScriptedHordeObserved)
    {
        g_bScriptedHordeObserved = true;
        Debug_Print("[EVENT] scripted horde activity confirmed map=%s amount=%d countdown=%d",
            EVENT_PRESSURE_C5M2_MAP, amount, countdown);
    }

    return Plugin_Continue;
}

static void EventPressure_OnC5M2Start(const char[] output, int caller, int activator, float delay)
{
    if (g_bEqualiserFiniteEventConfigured)
        return;

    EventPressure_StartScriptedMapEvent("c5m2_finale_start_trigger", activator);
}

static void EventPressure_OnC5M2EndPressed(const char[] output, int caller, int activator, float delay)
{
    if (g_bEqualiserFiniteEventConfigured)
        return;

    g_bScriptedMapEventCompleted = true;

    if (!g_bScriptedMapEventActive)
    {
        int startEntity = EventPressure_FindNamedEntity(
            EVENT_PRESSURE_C5M2_START_CLASS, EVENT_PRESSURE_C5M2_START_NAME);
        if (startEntity == -1)
        {
            // The plugin may have been loaded after the start trigger was consumed.
            // Recover the active edge before applying the map's delayed EndScript.
            g_bScriptedMapEventCompleted = false;
            EventPressure_StartScriptedMapEvent("c5m2_stop_button_recovery", activator);
            g_bScriptedMapEventCompleted = true;
        }
    }

    if (!g_bScriptedMapEventActive)
    {
        Debug_Print("[EVENT] c5m2 stop pressed before scripted event became active");
        return;
    }

    g_fScriptedMapEventEndAt = EventPressure_GetTime() + EVENT_PRESSURE_C5M2_END_DELAY;
    Debug_Print("[EVENT] scripted map event stop pressed map=%s; end in %.1fs",
        EVENT_PRESSURE_C5M2_MAP, EVENT_PRESSURE_C5M2_END_DELAY);
}

static bool EventPressure_IsMapPanicWindowActive()
{
    if (g_fMapPanicActiveUntil <= 0.0)
        return false;

    float now = EventPressure_GetTime();
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
    float now = EventPressure_GetTime();
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

    WaveDecider_OnEventPressureStarted(source);
}

static void EventPressure_SetFinaleActive(const char[] source)
{
    if (g_bFinaleEventActive)
        return;

    Debug_Print("[EVENT] finale pressure detected source=%s", source);
    g_bFinaleEventActive = true;
    WaveDecider_OnEventPressureStarted(source);
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
    else if (g_bEqualiserFiniteEventConfigured)
    {
        Debug_Print("[EVENT] map panic ignored; finite horde authority is configured");
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
    if (g_bEqualiserFiniteEventConfigured)
    {
        Debug_Print("[EVENT] panic game event ignored; finite horde authority is configured");
        return;
    }

    bool firstStart = !EventPressure_IsPanicGameEventActive();
    if (firstStart)
        Debug_Print("[EVENT] panic game event started (hold=%.0fs, refreshed per event)",
            EVENT_PRESSURE_PANIC_EVENT_HOLD);
    // 每个新的 panic 事件都刷新窗口；连续/无限尸潮脚本会不断触发该事件。
    g_fPanicGameEventUntil = EventPressure_GetTime() + EVENT_PRESSURE_PANIC_EVENT_HOLD;

    if (firstStart)
        WaveDecider_OnEventPressureStarted("create_panic_event");

    if (!g_bMapPanicDetourActive)
    {
        EventPressure_ArmMapPanic(EventPressurePanic_MapEvent,
            EVENT_PRESSURE_MAP_PANIC_HOLD, "game_event_fallback");
    }
}

public void EventPressure_OnPanicEnd(Event event, const char[] name, bool dontBroadcast)
{
    if (EventPressure_IsPanicGameEventActive())
        Debug_Print("[EVENT] panic game event finished; classified window remains=%d",
            EventPressure_IsMapPanicWindowActive());
    g_fPanicGameEventUntil = 0.0;
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
    if (g_bHoldoutEventActive)
        return;

    Debug_Print("[EVENT] holdout pressure started duration=%ds", time);
    g_bHoldoutEventActive = true;
    WaveDecider_OnEventPressureStarted("holdout_bonus");
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
            if (g_bEqualiserFiniteEventConfigured)
            {
                Debug_Print("[EVENT] external infinite horde ignored; finite horde authority is configured");
                return;
            }

            if (!g_bForwardInfiniteHordeActive)
            {
                g_bForwardInfiniteHordeActive = true;
                Debug_Print("[EVENT] external infinite horde detected");
                WaveDecider_OnEventPressureStarted("L4D2_HordeStatus:infinite");
            }
        }
        case 2:
        {
            EventPressure_ArmMapPanic(EventPressurePanic_AlarmCar,
                EVENT_PRESSURE_ALARM_CAR_HOLD, "L4D2_HordeStatus");
        }
        case 3:
        {
            if (g_bEqualiserFiniteEventConfigured)
            {
                Debug_Print("[EVENT] external map panic ignored; finite horde authority is configured");
                return;
            }

            EventPressure_ArmMapPanic(EventPressurePanic_MapEvent,
                EVENT_PRESSURE_MAP_PANIC_HOLD, "L4D2_HordeStatus");
        }
        case 4:
        {
            if (!g_bForwardFinaleEventActive)
            {
                g_bForwardFinaleEventActive = true;
                Debug_Print("[EVENT] external finale horde detected");
                WaveDecider_OnEventPressureStarted("L4D2_HordeStatus:finale");
            }
        }
    }
}
