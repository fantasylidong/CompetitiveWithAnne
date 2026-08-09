#if defined _infected_control_event_pressure_included
    #endinput
#endif
#define _infected_control_event_pressure_included

static DynamicDetour g_hMapPanicDetour = null;
static bool g_bPanicEventActive = false;
static bool g_bFinaleEventActive = false;
static bool g_bHoldoutEventActive = false;

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
    }
}

void EventPressure_Shutdown()
{
    delete g_hMapPanicDetour;
}

void EventPressure_Reset()
{
    g_bPanicEventActive = false;
    g_bFinaleEventActive = false;
    g_bHoldoutEventActive = false;
}

bool EventPressure_ShouldBypassAntiBait()
{
    return g_bPanicEventActive || g_bFinaleEventActive || g_bHoldoutEventActive;
}

public MRESReturn EventPressure_OnMapPanicPost(int pThis, Handle hReturn, Handle hParams)
{
    g_bPanicEventActive = true;
    return MRES_Ignored;
}

public void EventPressure_OnPanicStart(Event event, const char[] name, bool dontBroadcast)
{
    g_bPanicEventActive = true;
}

public void EventPressure_OnPanicEnd(Event event, const char[] name, bool dontBroadcast)
{
    g_bPanicEventActive = false;
}

public void EventPressure_OnFinaleStart(Event event, const char[] name, bool dontBroadcast)
{
    g_bFinaleEventActive = true;
}

public void OnHoldOutBonusStart(int time)
{
    g_bHoldoutEventActive = true;
}

public void OnHoldOutBonusEnd(int bonus, int time)
{
    g_bHoldoutEventActive = false;
}
