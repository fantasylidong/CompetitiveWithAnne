#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <left4dhooks>
#include <colors>

#define PLUGIN_VERSION "1.0.0"

#define WEPID_PAIN_PILLS 15
#define MAX_PILL_SPOTS   64

public Plugin myinfo =
{
    name        = "Anne Pill Hint",
    author      = "morzlee",
    description = "When survivors leave the saferoom, tells them at what map progress each pain pill lies",
    version     = PLUGIN_VERSION,
    url         = "https://github.com/fantasylidong/CompetitiveWithAnne"
};

bool g_bAnnounced;

public void OnPluginStart()
{
    LoadTranslations("anne_pill_hint.phrases");
    HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);
}

void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    g_bAnnounced = false;
}

public void L4D_OnFirstSurvivorLeftSafeArea_Post(int client)
{
    // Door-lock teleports can fire this more than once per round.
    if (g_bAnnounced) {
        return;
    }
    g_bAnnounced = true;

    AnnouncePills();
}

void AnnouncePills()
{
    float fMaxFlow = L4D2Direct_GetMapMaxFlowDistance();
    if (fMaxFlow <= 0.0) {
        return;
    }

    // Progress percent per spot (-1 = no flow data) and how many pills lie there
    int iPct[MAX_PILL_SPOTS], iNum[MAX_PILL_SPOTS];
    int iSpots = 0, iTotal = 0;

    static const char sClasses[][] = {"weapon_pain_pills_spawn", "weapon_spawn", "weapon_pain_pills"};
    for (int c = 0; c < sizeof(sClasses); c++) {
        int iEnt = -1;
        while ((iEnt = FindEntityByClassname(iEnt, sClasses[c])) != -1 && iSpots < MAX_PILL_SPOTS) {
            int iCount = GetPillCount(iEnt, c);
            if (iCount <= 0) {
                continue;
            }

            float fPos[3];
            GetEntPropVector(iEnt, Prop_Data, "m_vecAbsOrigin", fPos);

            Address pNav = L4D_GetNearestNavArea(fPos, 120.0, true, false, false, 2);
            if (pNav == Address_Null) {
                pNav = L4D2Direct_GetTerrorNavArea(fPos);
            }

            // Saferoom pills aren't on the way.
            if (pNav != Address_Null && (L4D_GetNavArea_SpawnAttributes(pNav) & NAV_SPAWN_CHECKPOINT)) {
                continue;
            }

            float fFlow = (pNav != Address_Null) ? L4D2Direct_GetTerrorNavAreaFlow(pNav) : -1.0;
            int iThisPct = -1;
            if (fFlow >= 0.0) {
                iThisPct = RoundToNearest(fFlow / fMaxFlow * 100.0);
                if (iThisPct > 100) {
                    iThisPct = 100;
                }
            }

            iPct[iSpots] = iThisPct;
            iNum[iSpots] = iCount;
            iSpots++;
            iTotal += iCount;
        }
    }

    SortSpots(iPct, iNum, iSpots);

    for (int client = 1; client <= MaxClients; client++) {
        if (!IsClientInGame(client) || IsFakeClient(client)) {
            continue;
        }

        if (!iTotal) {
            CPrintToChat(client, "%T", "PillHint_None", client);
            continue;
        }

        char sList[512], sSep[16];
        FormatEx(sSep, sizeof(sSep), "%T", "PillHint_Separator", client);
        BuildSpotList(iPct, iNum, iSpots, sSep, sList, sizeof(sList));
        CPrintToChat(client, "%T", "PillHint_List", client, iTotal, sList);
    }
}

// Pills this entity hands out; 0 when it isn't a free-standing pill.
int GetPillCount(int iEnt, int iClassIdx)
{
    switch (iClassIdx) {
        case 1: {
            if (GetEntProp(iEnt, Prop_Send, "m_weaponID") != WEPID_PAIN_PILLS) {
                return 0;
            }
        }
        case 2: {
            // Carried pills have an owner.
            return (GetEntPropEnt(iEnt, Prop_Send, "m_hOwnerEntity") == -1) ? 1 : 0;
        }
    }

    int iCount = HasEntProp(iEnt, Prop_Data, "m_itemCount") ? GetEntProp(iEnt, Prop_Data, "m_itemCount") : 1;
    return (iCount > 0) ? iCount : 1;
}

// Ascending progress; unknown (-1) last.
void SortSpots(int[] iPct, int[] iNum, int iSpots)
{
    for (int i = 1; i < iSpots; i++) {
        int p = iPct[i], n = iNum[i];
        int j = i - 1;
        while (j >= 0 && SpotAfter(iPct[j], p)) {
            iPct[j + 1] = iPct[j];
            iNum[j + 1] = iNum[j];
            j--;
        }
        iPct[j + 1] = p;
        iNum[j + 1] = n;
    }
}

bool SpotAfter(int a, int b)
{
    if (a == -1) {
        return (b != -1);
    }
    return (b != -1 && a > b);
}

// "38%, 52%×2, 71%": pills at the same percent are merged.
void BuildSpotList(const int[] iPct, const int[] iNum, int iSpots, const char[] sSep, char[] sOut, int iMaxLen)
{
    sOut[0] = '\0';

    int i = 0;
    while (i < iSpots) {
        int iSame = iNum[i];
        int j = i + 1;
        while (j < iSpots && iPct[j] == iPct[i]) {
            iSame += iNum[j];
            j++;
        }

        char sItem[16];
        if (iPct[i] < 0) {
            strcopy(sItem, sizeof(sItem), "?");
        } else {
            FormatEx(sItem, sizeof(sItem), "%d%%", iPct[i]);
        }
        if (iSame > 1) {
            Format(sItem, sizeof(sItem), "%s×%d", sItem, iSame);
        }

        if (sOut[0] != '\0') {
            StrCat(sOut, iMaxLen, sSep);
        }
        StrCat(sOut, iMaxLen, sItem);

        i = j;
    }
}
