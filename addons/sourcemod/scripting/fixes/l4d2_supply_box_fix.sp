#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <entitylump>

// Filter the map text before CreateEdict. Killing entities in OnMapStart or
// OnEntityCreated is too late for CleanUpMap's bulk-creation peak.
#define FIX_VERSION "1.1.0"
#define DISPLAY_LIMIT 5
#define SUPPLY_COUNT 4

static const char SUPPLIES[SUPPLY_COUNT][] = {
    "pipebomb", "molotov", "adrenaline", "pills"
};
static const char MODELS[SUPPLY_COUNT][] = {
    "models/w_models/weapons/w_eq_pipebomb.mdl",
    "models/w_models/weapons/w_eq_molotov.mdl",
    "models/w_models/weapons/w_eq_adrenaline.mdl",
    "models/w_models/weapons/w_eq_painpills.mdl"
};

bool g_Processed;
int g_Removed, g_Kept;

public Plugin myinfo = {
    name = "L4D2 Supply Box Fix",
    author = "Anne",
    description = "Reduce footlocker display models before map entity allocation",
    version = FIX_VERSION
};

public void OnPluginStart()
{
    if (GetEngineVersion() != Engine_Left4Dead2)
        SetFailState("This plugin requires Left 4 Dead 2 and SourceMod 1.12 EntityLump.");
    RegServerCmd("sm_supply_box_fix_status", Command_Status);
}

// Recognize the standard supply-box template on any map, with any positive
// locker number. Do not accept instance suffixes, wildcards or partial names.
int FindSupply(const char[] name)
{
    char prefix[32];
    for (int supply = 0; supply < SUPPLY_COUNT; supply++)
    {
        FormatEx(prefix, sizeof(prefix), "ptemplate_%s-", SUPPLIES[supply]);
        int length = strlen(prefix);
        if (strncmp(name, prefix, length) != 0 || name[length] < '1' || name[length] > '9')
            continue;
        for (int i = length + 1; name[i] != '\0'; i++)
        {
            if (name[i] < '0' || name[i] > '9')
                return -1;
        }
        return supply;
    }
    return -1;
}

public void OnMapInit(const char[] mapName)
{
    g_Processed = false;
    g_Removed = 0;
    g_Kept = 0;
    StringMap referenced = new StringMap();
    StringMap kept = new StringMap();
    char classname[64], name[256], value[256], key[32], expected[256];

    // Only thin a group still referenced by its original point_template.
    // Other map filters may have removed a template or changed its contents.
    for (int i = 0; i < EntityLump.Length(); i++)
    {
        EntityLumpEntry entry = EntityLump.Get(i);
        entry.GetNextKey("classname", classname, sizeof(classname));
        entry.GetNextKey("targetname", name, sizeof(name));
        int supply = FindSupply(name);
        if (StrEqual(classname, "point_template") && supply != -1)
        {
            FormatEx(expected, sizeof(expected), "prop_%s", name[10]);
            for (int slot = 1; slot <= 16; slot++)
            {
                FormatEx(key, sizeof(key), "Template%02d", slot);
                entry.GetNextKey(key, value, sizeof(value));
                if (StrEqual(value, expected))
                    referenced.SetValue(expected, supply);
            }
        }
        delete entry;
    }

    // Descending indices keep Erase from skipping entries. Keep up to five
    // displays per referenced variant, without adding any to smaller groups.
    for (int i = EntityLump.Length() - 1; i >= 0; i--)
    {
        EntityLumpEntry entry = EntityLump.Get(i);
        entry.GetNextKey("classname", classname, sizeof(classname));
        entry.GetNextKey("targetname", name, sizeof(name));
        entry.GetNextKey("model", value, sizeof(value));
        int supply;
        bool match = StrEqual(classname, "prop_dynamic_override") && referenced.GetValue(name, supply);
        if (match)
            match = StrEqual(value, MODELS[supply]);
        delete entry;
        if (!match)
            continue;
        int count = 0;
        kept.GetValue(name, count);
        if (count >= DISPLAY_LIMIT)
        {
            EntityLump.Erase(i);
            g_Removed++;
        }
        else
        {
            kept.SetValue(name, count + 1);
            g_Kept++;
        }
    }
    delete referenced;
    delete kept;
    g_Processed = true;
    if (g_Kept > 0)
        LogMessage("Supply box fix: map=%s removed=%d kept=%d limit=%d (display models only)",
            mapName, g_Removed, g_Kept, DISPLAY_LIMIT);
}

Action Command_Status(int args)
{
    PrintToServer("[SupplyBoxFix] version=%s processed=%d removed=%d kept=%d limit=%d; changes require a map load, not just a round restart",
        FIX_VERSION, g_Processed, g_Removed, g_Kept, DISPLAY_LIMIT);
    return Plugin_Handled;
}
