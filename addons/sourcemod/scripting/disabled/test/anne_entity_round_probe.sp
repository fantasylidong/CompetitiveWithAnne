#pragma semicolon 1
#pragma newdecls required
#include <sourcemod>
#include <sdktools>
public Plugin myinfo = { name = "Anne entity round probe", author = "Anne", version = "1.0" };
int starts, ends, peak, created;
public void OnPluginStart()
{
    HookEvent("round_start", RoundStart);
    HookEvent("round_end", RoundEnd);
    HookEvent("mission_lost", RoundEnd);
    RegServerCmd("anne_entity_probe", Status);
}
int Used()
{
    int count, limit = GetMaxEntities();
    for (int e = 0; e < limit; e++) if (IsValidEdict(e)) count++;
    return count;
}
public void OnEntityCreated(int entity, const char[] classname)
{
    if (++created % 32 != 0) return;
    int used = Used();
    if (used > peak) peak = used;
}
void RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    starts++;
    LogMessage("round_start starts=%d ends=%d used=%d peak=%d", starts, ends, Used(), peak);
}
void RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
    ends++;
    LogMessage("%s starts=%d ends=%d used=%d peak=%d", name, starts, ends, Used(), peak);
}
Action Status(int args)
{
    PrintToServer("[EntityProbe] starts=%d ends=%d used=%d sampled_peak=%d created=%d", starts, ends, Used(), peak, created);
    return Plugin_Handled;
}
