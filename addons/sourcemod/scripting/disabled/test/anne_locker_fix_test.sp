#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <entitylump>

#define GROUPS 24
static const char TYPES[][] = { "pipebomb", "molotov", "adrenaline", "pills" };
static const char CLASSES[][] = {
    "weapon_pipe_bomb_spawn", "weapon_molotov_spawn", "weapon_adrenaline_spawn", "weapon_pain_pills_spawn"
};
static const char MODELS[][] = {
    "models/w_models/weapons/w_eq_pipebomb.mdl", "models/w_models/weapons/w_eq_molotov.mdl",
    "models/w_models/weapons/w_eq_adrenaline.mdl", "models/w_models/weapons/w_eq_painpills.mdl"
};

public Plugin myinfo = { name = "Anne locker fix engine test", author = "Anne", version = "1.0" };
ArrayList g_Created;
Handle g_Timer;
bool g_Running;
bool g_Baseline;
int g_Group, g_Failed;
char g_Log[PLATFORM_MAX_PATH];

public void OnPluginStart()
{
    g_Created = new ArrayList();
    BuildPath(Path_SM, g_Log, sizeof(g_Log), "logs/anne_locker_regression.log");
    RegServerCmd("sm_anne_locker_test", Command_Test, "Test c6m1 locker templates; use stop to cancel.");
}

void GroupName(int group, const char[] prefix, char[] name, int size)
{
    FormatEx(name, size, "%s%s-%d", prefix, TYPES[group / 6], group % 6 + 1);
}

// point_template may append &xxxx; -10 must never match -1.
bool Matches(const char[] name, const char[] expected)
{
    int len = strlen(expected);
    return strncmp(name, expected, len) == 0 && (name[len] == '\0' || name[len] == '&');
}

int LumpGroup(const char[] name, const char[] prefix)
{
    char expected[64];
    for (int group = 0; group < GROUPS; group++)
    {
        GroupName(group, prefix, expected, sizeof(expected));
        if (StrEqual(name, expected)) return group;
    }
    return -1;
}

bool SafeMap()
{
    char map[64];
    GetCurrentMap(map, sizeof(map));
    if (!StrEqual(map, "c6m1_riverbank", false)) return false;
    for (int client = 1; client <= MaxClients; client++)
        if (IsClientConnected(client) && !IsFakeClient(client)) return false;
    return true;
}

bool CheckLump()
{
    int displays[GROUPS], templates[GROUPS], weapons[GROUPS];
    bool valid = true;
    char classname[64], name[128], value[128], expected[64];
    for (int i = 0; i < EntityLump.Length(); i++)
    {
        EntityLumpEntry entry = EntityLump.Get(i);
        entry.GetNextKey("classname", classname, sizeof(classname));
        entry.GetNextKey("targetname", name, sizeof(name));
        int group = LumpGroup(name, "prop_");
        if (group != -1 && (StrEqual(classname, "prop_dynamic") || StrEqual(classname, "prop_dynamic_override")))
        {
            displays[group]++;
            entry.GetNextKey("model", value, sizeof(value));
            if (!StrEqual(value, MODELS[group / 6])) valid = false;
        }
        group = LumpGroup(name, "ptemplate_");
        if (group != -1 && StrEqual(classname, "point_template"))
        {
            templates[group]++;
            GroupName(group, "", expected, sizeof(expected));
            entry.GetNextKey("Template01", value, sizeof(value));
            if (!StrEqual(value, expected)) valid = false;
            GroupName(group, "prop_", expected, sizeof(expected));
            entry.GetNextKey("Template02", value, sizeof(value));
            if (!StrEqual(value, expected)) valid = false;
        }
        group = LumpGroup(name, "");
        if (group != -1 && StrEqual(classname, CLASSES[group / 6]))
        {
            weapons[group]++;
            entry.GetNextKey("count", value, sizeof(value));
            if (StringToInt(value) != 10) valid = false;
        }
        delete entry;
    }
    for (int group = 0; group < GROUPS; group++)
    {
        GroupName(group, "", expected, sizeof(expected));
        bool counts = displays[group] == (g_Baseline ? 22 : 5) && templates[group] == 1 && weapons[group] == 2;
        if (!counts) valid = false;
        LogToFileEx(g_Log, "LUMP %s display=%d template=%d weapon=%d", expected,
            displays[group], templates[group], weapons[group]);
    }
    LogToFileEx(g_Log, "LUMP %s: expected %d displays, 24 templates, 48 weapons with count=10",
        valid ? "PASS" : "FAIL", g_Baseline ? 528 : 120);
    return valid;
}

public void OnEntityCreated(int entity, const char[] classname)
{
    // Targetnames are assigned later; retain refs now and inspect after 0.2 s.
    if (g_Running && entity > MaxClients) g_Created.Push(EntIndexToEntRef(entity));
}

bool IsOurEntity(int entity)
{
    if (!HasEntProp(entity, Prop_Data, "m_iName")) return false;
    char name[128], expected[64];
    GetEntPropString(entity, Prop_Data, "m_iName", name, sizeof(name));
    GroupName(g_Group, "", expected, sizeof(expected));
    if (Matches(name, expected)) return true;
    GroupName(g_Group, "prop_", expected, sizeof(expected));
    if (Matches(name, expected)) return true;
    GroupName(g_Group, "brush_base_", expected, sizeof(expected));
    if (Matches(name, expected)) return true;
    // The original map uses a different word order for adrenaline's base.
    if (g_Group / 6 == 2)
    {
        FormatEx(expected, sizeof(expected), "brush_adrenaline_base-%d", g_Group % 6 + 1);
        return Matches(name, expected);
    }
    return false;
}

void Cleanup()
{
    // Never enumerate and remove existing entities: only refs captured for this group.
    for (int i = 0; i < g_Created.Length; i++)
    {
        int entity = EntRefToEntIndex(g_Created.Get(i));
        if (entity != INVALID_ENT_REFERENCE && IsValidEntity(entity) && IsOurEntity(entity))
            RemoveEntity(entity);
    }
    g_Created.Clear();
}

void StopTest(const char[] reason)
{
    bool running = g_Running;
    g_Running = false;
    delete g_Timer;
    Cleanup();
    if (running)
    {
        LogToFileEx(g_Log, "FAIL aborted: %s", reason);
        PrintToServer("[LockerTest] FAIL aborted: %s", reason);
    }
}

void SpawnNext()
{
    if (!g_Running) return;
    if (!SafeMap()) { StopTest("requires c6m1 and no human clients"); return; }
    char expected[64], name[128];
    GroupName(g_Group, "ptemplate_", expected, sizeof(expected));
    int entity = -1, found = -1, matches;
    while ((entity = FindEntityByClassname(entity, "point_template")) != -1)
    {
        GetEntPropString(entity, Prop_Data, "m_iName", name, sizeof(name));
        if (StrEqual(name, expected)) { found = entity; matches++; }
    }
    if (matches != 1 || !AcceptEntityInput(found, "ForceSpawn"))
    {
        StopTest("missing/duplicate template or ForceSpawn rejected");
        return;
    }
    g_Timer = CreateTimer(0.2, CheckSpawn, _, TIMER_FLAG_NO_MAPCHANGE);
}

public Action CheckSpawn(Handle timer)
{
    g_Timer = null;
    if (!SafeMap()) { StopTest("requires c6m1 and no human clients"); return Plugin_Stop; }
    int displays, weapons;
    bool valid = true;
    char classname[64], name[128], model[128], expected[64];
    for (int i = 0; i < g_Created.Length; i++)
    {
        int entity = EntRefToEntIndex(g_Created.Get(i));
        if (entity == INVALID_ENT_REFERENCE || !IsValidEntity(entity) || !IsOurEntity(entity)) continue;
        GetEntityClassname(entity, classname, sizeof(classname));
        GetEntPropString(entity, Prop_Data, "m_iName", name, sizeof(name));
        GroupName(g_Group, "prop_", expected, sizeof(expected));
        if (Matches(name, expected))
        {
            displays++;
            model[0] = '\0';
            if (HasEntProp(entity, Prop_Data, "m_ModelName"))
                GetEntPropString(entity, Prop_Data, "m_ModelName", model, sizeof(model));
            if ((!StrEqual(classname, "prop_dynamic") && !StrEqual(classname, "prop_dynamic_override"))
                || !StrEqual(model, MODELS[g_Group / 6]))
            {
                LogToFileEx(g_Log, "DETAIL display name=%s class=%s model=%s", name, classname, model);
                valid = false;
            }
        }
        GroupName(g_Group, "", expected, sizeof(expected));
        if (Matches(name, expected))
        {
            weapons++;
            if (!StrEqual(classname, CLASSES[g_Group / 6]))
            {
                LogToFileEx(g_Log, "DETAIL weapon name=%s class=%s expected=%s", name, classname, CLASSES[g_Group / 6]);
                valid = false;
            }
            // Compare with the unmodified map: medical spawns normalize to 1
            // at runtime, although all 48 definitions retain count=10.
            int expectedCount = g_Group / 6 < 2 ? 10 : 1;
            if (HasEntProp(entity, Prop_Data, "m_itemCount") && GetEntProp(entity, Prop_Data, "m_itemCount") != expectedCount)
            {
                LogToFileEx(g_Log, "DETAIL weapon name=%s m_itemCount=%d", name, GetEntProp(entity, Prop_Data, "m_itemCount"));
                valid = false;
            }
        }
    }
    valid = valid && displays == (g_Baseline ? 22 : 5) && weapons == 2;
    GroupName(g_Group, "", expected, sizeof(expected));
    LogToFileEx(g_Log, "%s %s display=%d weapon=%d (model/class/count checked)",
        valid ? "PASS" : "FAIL", expected, displays, weapons);
    if (!valid) g_Failed++;
    Cleanup();
    // Let deferred engine removals finish before allocating the next template.
    if (++g_Group < GROUPS) g_Timer = CreateTimer(0.1, NextGroup, _, TIMER_FLAG_NO_MAPCHANGE);
    else
    {
        g_Running = false;
        LogToFileEx(g_Log, "%s SUMMARY groups=24 failed=%d", g_Failed == 0 ? "PASS" : "FAIL", g_Failed);
        PrintToServer("[LockerTest] %s groups=24 failed=%d", g_Failed == 0 ? "PASS" : "FAIL", g_Failed);
    }
    return Plugin_Stop;
}

public Action NextGroup(Handle timer) { g_Timer = null; SpawnNext(); return Plugin_Stop; }

public Action Command_Test(int args)
{
    char arg[16];
    if (args > 0) GetCmdArg(1, arg, sizeof(arg));
    if (StrEqual(arg, "stop")) { StopTest("console stop"); return Plugin_Handled; }
    if (g_Running) { PrintToServer("[LockerTest] Already running."); return Plugin_Handled; }
    if (!SafeMap()) { PrintToServer("[LockerTest] Requires c6m1_riverbank and no human clients."); return Plugin_Handled; }
    g_Baseline = StrEqual(arg, "baseline");
    LogToFileEx(g_Log, "BEGIN locker regression baseline=%d", g_Baseline);
    if (!CheckLump()) { PrintToServer("[LockerTest] FAIL lump validation; no templates spawned."); return Plugin_Handled; }
    g_Group = 0;
    g_Failed = 0;
    g_Running = true;
    SpawnNext();
    return Plugin_Handled;
}

public void OnClientPutInServer(int client)
{
    if (g_Running && !IsFakeClient(client)) StopTest("human joined");
}
public void OnMapEnd() { StopTest("map ended"); }
public void OnPluginEnd() { StopTest("plugin unloaded"); delete g_Created; }
