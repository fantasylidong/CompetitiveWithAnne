#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <entitylump>

#define OnMapInit Production_OnMapInit
#define OnPluginStart Production_OnPluginStart
#define myinfo Production_Info
#include "../../fixes/l4d2_supply_box_fix.sp"
#undef OnMapInit
#undef OnPluginStart
#undef myinfo

#define CASES 12
static const char FIXTURE_SUPPLIES[][] = { "pipebomb", "molotov", "adrenaline", "pills" };
static const char FIXTURE_MODELS[][] = {
    "models/w_models/weapons/w_eq_pipebomb.mdl",
    "models/w_models/weapons/w_eq_molotov.mdl",
    "models/w_models/weapons/w_eq_adrenaline.mdl",
    "models/w_models/weapons/w_eq_painpills.mdl"
};
static const char SUFFIXES[CASES][] = {
    "7", "101", "19", "23", "29", "31", "37", "7-extra", "7&001", "0", "01", "43"
};
static const int TYPES[CASES] = { 0, 1, 2, 3, 0, 1, 3, 0, 1, 2, 3, 2 };
static const int EXPECTED[CASES] = { 5, 5, 3, 8, 8, 8, 8, 8, 8, 8, 8, 8 };
char g_TestLog[PLATFORM_MAX_PATH];
bool g_Completed;
int g_Failed;

public Plugin myinfo = {
    name = "Anne supply box EntityLump fixture test", author = "Anne", version = "1.0"
};

public void OnPluginStart()
{
    Production_OnPluginStart();
    BuildPath(Path_SM, g_TestLog, sizeof(g_TestLog), "logs/anne_supply_box_fixture.log");
    RegServerCmd("sm_supply_box_fixture_result", Command_Result);
}

void Check(bool success, const char[] label)
{
    if (!success) g_Failed++;
    LogToFileEx(g_TestLog, "%s %s", success ? "PASS" : "FAIL", label);
}

void Name(int group, bool template, char[] name, int size)
{
    FormatEx(name, size, "%s_%s-%s", template ? "ptemplate" : "prop", FIXTURE_SUPPLIES[TYPES[group]], SUFFIXES[group]);
}

bool IsFixture(EntityLumpEntry entry)
{
    char value[8];
    entry.GetNextKey("anne_supply_test", value, sizeof(value));
    return StrEqual(value, "1");
}

// Hash all keys/values in order; exclude only the three intended display groups.
// Thus templates, unrelated fixtures and every original map entry must survive.
int Snapshot(int &count)
{
    int hash = 0x811c9dc5;
    count = 0;
    char key[256], value[2048], classname[64], groupText[16];
    for (int i = 0; i < EntityLump.Length(); i++)
    {
        EntityLumpEntry entry = EntityLump.Get(i);
        entry.GetNextKey("anne_supply_case", groupText, sizeof(groupText));
        entry.GetNextKey("classname", classname, sizeof(classname));
        if (IsFixture(entry) && StringToInt(groupText) < 3 && StrEqual(classname, "prop_dynamic_override"))
        {
            delete entry;
            continue;
        }
        count++;
        for (int pair = 0; pair < entry.Length; pair++)
        {
            entry.Get(pair, key, sizeof(key), value, sizeof(value));
            for (int c = 0; key[c]; c++) hash = (hash ^ key[c]) * 16777619;
            hash = (hash ^ 0) * 16777619;
            for (int c = 0; value[c]; c++) hash = (hash ^ value[c]) * 16777619;
            hash = (hash ^ 0) * 16777619;
        }
        hash = (hash ^ 255) * 16777619;
        delete entry;
    }
    return hash;
}

EntityLumpEntry AppendFixture(int group, const char[] classname, const char[] name)
{
    EntityLumpEntry entry = EntityLump.Get(EntityLump.Append());
    char value[16];
    IntToString(group, value, sizeof(value));
    entry.Append("classname", classname);
    entry.Append("targetname", name);
    entry.Append("anne_supply_test", "1");
    entry.Append("anne_supply_case", value);
    return entry;
}

void AddFixtures()
{
    char name[128], prop[128], key[32];
    for (int group = 0; group < CASES; group++)
    {
        Name(group, false, prop, sizeof(prop));
        if (group != 6) // Missing-template group must remain untouched.
        {
            Name(group, true, name, sizeof(name));
            EntityLumpEntry entry = AppendFixture(group, group == 11 ? "logic_relay" : "point_template", name);
            // The nonreferencing case mentions its prop only outside Template01..16.
            int slot = group == 1 ? 16 : (group == 2 ? 8 : (group == 3 ? 17 : 1));
            FormatEx(key, sizeof(key), "Template%02d", slot);
            entry.Append(key, prop);
            delete entry;
        }
        for (int display = 0; display < (group == 2 ? 3 : 8); display++)
        {
            EntityLumpEntry entry = AppendFixture(group, group == 4 ? "prop_dynamic" : "prop_dynamic_override", prop);
            entry.Append("model", FIXTURE_MODELS[group == 5 ? 0 : TYPES[group]]);
            delete entry;
        }
    }
}

void CheckCounts()
{
    int displays[CASES], templates[CASES];
    char value[16], classname[64], label[160];
    for (int i = 0; i < EntityLump.Length(); i++)
    {
        EntityLumpEntry entry = EntityLump.Get(i);
        if (IsFixture(entry))
        {
            entry.GetNextKey("anne_supply_case", value, sizeof(value));
            int group = StringToInt(value);
            entry.GetNextKey("classname", classname, sizeof(classname));
            if (StrEqual(classname, "prop_dynamic_override") || StrEqual(classname, "prop_dynamic")) displays[group]++;
            else templates[group]++;
        }
        delete entry;
    }
    for (int group = 0; group < CASES; group++)
    {
        FormatEx(label, sizeof(label), "case=%d type=%s suffix=%s displays=%d expected=%d templates=%d",
            group, FIXTURE_SUPPLIES[TYPES[group]], SUFFIXES[group], displays[group], EXPECTED[group], templates[group]);
        Check(displays[group] == EXPECTED[group] && templates[group] == (group == 6 ? 0 : 1), label);
    }
}

void CleanupFixtures()
{
    for (int i = EntityLump.Length() - 1; i >= 0; i--)
    {
        EntityLumpEntry entry = EntityLump.Get(i);
        bool fixture = IsFixture(entry);
        delete entry;
        if (fixture) EntityLump.Erase(i);
    }
}

public void OnMapInit(const char[] mapName)
{
    g_Completed = false;
    g_Failed = 0;
    if (!StrEqual(mapName, "c2m1_highway")) return;
    for (int client = 1; client <= MaxClients; client++)
        if (IsClientConnected(client) && !IsFakeClient(client)) return;
    // Refuse maps containing real supply templates, before invoking production.
    char classname[64], name[128];
    for (int i = 0; i < EntityLump.Length(); i++)
    {
        EntityLumpEntry entry = EntityLump.Get(i);
        entry.GetNextKey("classname", classname, sizeof(classname));
        entry.GetNextKey("targetname", name, sizeof(name));
        delete entry;
        if (StrEqual(classname, "point_template") && FindSupply(name) != -1)
        {
            Check(false, "map contains an original supply template; aborted");
            g_Completed = true;
            LogToFileEx(g_TestLog, "FAIL SUMMARY completed=1 failed=%d map=%s aborted=1", g_Failed, mapName);
            return;
        }
    }
    int originalLength = EntityLump.Length();
    AddFixtures();
    int beforeCount, afterCount;
    int beforeHash = Snapshot(beforeCount);
    Production_OnMapInit(mapName);
    CheckCounts();
    Check(g_Processed && g_Removed == 6 && g_Kept == 13, "first pass removed=6 kept=13");
    int afterHash = Snapshot(afterCount);
    Check(beforeCount == afterCount && beforeHash == afterHash, "all nontarget entries unchanged");
    int onceLength = EntityLump.Length();
    Production_OnMapInit(mapName);
    Check(g_Removed == 0 && g_Kept == 13 && EntityLump.Length() == onceLength, "second pass is idempotent");
    CheckCounts();
    CleanupFixtures(); // No fixture is handed to the engine's entity parser.
    Check(EntityLump.Length() == originalLength, "all fixtures removed before engine parsing");
    g_Completed = true;
    LogToFileEx(g_TestLog, "%s SUMMARY completed=1 failed=%d map=%s", g_Failed ? "FAIL" : "PASS", g_Failed, mapName);
}

public Action Command_Result(int args)
{
    PrintToServer("[SupplyBoxFixture] completed=%d failed=%d result=%s", g_Completed, g_Failed,
        !g_Completed ? "PENDING (load before changing to empty c2m1_highway)" : (g_Failed ? "FAIL" : "PASS"));
    return Plugin_Handled;
}
