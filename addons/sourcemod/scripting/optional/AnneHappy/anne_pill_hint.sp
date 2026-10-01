#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <left4dhooks>
#include <colors>
#undef REQUIRE_PLUGIN
#include <confogl>

#define PLUGIN_VERSION "1.0.2"

#define WEPID_PAIN_PILLS 15
#define PILL_HINT_MESSAGE_BYTES 190

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
    g_bAnnounced = AnnouncePills();
}

bool AnnouncePills()
{
    float fMaxFlow = L4D2Direct_GetMapMaxFlowDistance();
    if (fMaxFlow <= 0.0) {
        return false;
    }

    // Progress percent per spot (-1 = no flow data) and how many pills lie there
    int maxSpots = GetMaxEntities();
    int[] iPct = new int[maxSpots];
    int[] iNum = new int[maxSpots];
    int iSpots = 0, iTotal = 0;
    bool sharedSaferoom = GetFeatureStatus(FeatureType_Native, "LGO_IsEntityInSaferoom") == FeatureStatus_Available;

    static const char sClasses[][] = {"weapon_pain_pills_spawn", "weapon_spawn", "weapon_pain_pills"};
    for (int c = 0; c < sizeof(sClasses); c++) {
        int iEnt = -1;
        while ((iEnt = FindEntityByClassname(iEnt, sClasses[c])) != -1 && iSpots < maxSpots) {
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
            if (sharedSaferoom ? LGO_IsEntityInSaferoom(iEnt)
                : (pNav != Address_Null && (L4D_GetNavArea_SpawnAttributes(pNav) & NAV_SPAWN_CHECKPOINT) != 0)) {
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

        char sSep[16], header[MAX_MESSAGE_LENGTH], continuation[MAX_MESSAGE_LENGTH], unknown[32];
        FormatEx(sSep, sizeof(sSep), "%T", "PillHint_Separator", client);
        FormatEx(header, sizeof(header), "%T", "PillHint_List", client, iTotal, "");
        FormatEx(continuation, sizeof(continuation), "%T", "PillHint_Continue", client);
        FormatEx(unknown, sizeof(unknown), "%T", "PillHint_Unknown", client);
        ArrayList lines = BuildSpotLines(iPct, iNum, iSpots, sSep, header, continuation, unknown);
        char message[MAX_MESSAGE_LENGTH];
        for (int line = 0; line < lines.Length; line++) {
            lines.GetString(line, message, sizeof(message));
            CPrintToChat(client, "%s", message);
        }
        delete lines;
    }
    return true;
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
    return (iCount > 0) ? iCount : 0;
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

ArrayList BuildSpotLines(const int[] iPct, const int[] iNum, int iSpots, const char[] separator,
    const char[] header, const char[] continuation, const char[] unknown)
{
    ArrayList lines = new ArrayList(ByteCountToCells(MAX_MESSAGE_LENGTH));
    char message[MAX_MESSAGE_LENGTH];
    strcopy(message, sizeof(message), header);
    bool hasItems;

    for (int spot = 0; spot < iSpots; spot++) {
        char sItem[32];
        if (iPct[spot] < 0) {
            strcopy(sItem, sizeof(sItem), unknown);
        } else {
            FormatEx(sItem, sizeof(sItem), "%d%%", iPct[spot]);
        }

        for (int pill = 0; pill < iNum[spot]; pill++) {
            if (strlen(message) + (hasItems ? strlen(separator) : 0) + strlen(sItem) > PILL_HINT_MESSAGE_BYTES) {
                if (!hasItems) {
                    delete lines;
                    ThrowError("Pill hint translation exceeds the chat message budget");
                }
                lines.PushString(message);
                strcopy(message, sizeof(message), continuation);
                hasItems = false;
            }
            if (strlen(message) + strlen(sItem) > PILL_HINT_MESSAGE_BYTES) {
                delete lines;
                ThrowError("Pill hint continuation exceeds the chat message budget");
            }
            if (hasItems) {
                StrCat(message, sizeof(message), separator);
            }
            StrCat(message, sizeof(message), sItem);
            hasItems = true;
        }
    }
    if (hasItems) {
        lines.PushString(message);
    }
    return lines;
}
