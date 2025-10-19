#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

/**
 * L4D2 Saferoom Medkit Refill (KV-Count 简化版)
 * -------------------------------------------------
 * 逻辑：按生还者人数，把安全门附近的医疗包实体的 KeyValue "count" 改成 2（可拿两次）。
 * 默认基数为 4 人：若有第 5 人，就给其中 1 个医疗包设置 count=2。
 *
 * 优点：实现极简，无需补实体；兼容你给的 “SetUpdateEntCount” 思路。
 *
 * 支持的类名优先级：
 *   1) weapon_first_aid_kit_spawn（最常见的安全屋医疗包 spawner）
 *   2) weapon_first_aid_kit（若地图直接放了实物，也尝试设置）
 *
 * 注意：
 *   - 我们只修改“距离最近的检查点门半径内”的若干个医疗包，避免影响路上散落物资。
 *   - 若地图里没有上述类名，或某些地图不支持在实物上改 count，则不会生效（这类图可再换回“补实体”的方案）。
 */

#define PLUGIN_NAME        "Saferoom Medkit Refill (KV)"
#define PLUGIN_AUTHOR      "morzlee"
#define PLUGIN_VERSION     "1.1.0"

public Plugin myinfo =
{
    name        = PLUGIN_NAME,
    author      = PLUGIN_AUTHOR,
    description = "Set medkit 'count' by KV near saferoom based on survivor count.",
    version     = PLUGIN_VERSION,
    url         = ""
};

// ======================
// Configurable ConVars
// ======================
ConVar gC_Enable;          // sr_medkit_enable
ConVar gC_Base;            // sr_medkit_base
ConVar gC_Radius;          // sr_medkit_radius
ConVar gC_ScanDelay;       // sr_medkit_scan_delay
ConVar gC_Debug;           // sr_medkit_debug

bool  g_bEnable;
int   g_iBase;
float g_fRadius;
float g_fScanDelay;
bool  g_bDebug;

// ======================
// Utils
// ======================
stock void Dbg(const char[] fmt, any ...)
{
    if (!g_bDebug) return;
    char buffer[256];
    VFormat(buffer, sizeof(buffer), fmt, 2);
    PrintToServer("[SRMedkitKV] %s", buffer);
}

bool IsValidClientSurvivor(int client)
{
    return (1 <= client <= MaxClients && IsClientInGame(client) && GetClientTeam(client) == 2);
}

int CountSurvivors()
{
    int n = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsValidClientSurvivor(i)) n++;
    }
    return n;
}

// 采集所有检查点门位置
int CollectCheckpointDoorPositions(float posList[][3], int maxCount)
{
    int count = 0;
    int ent = -1;
    while ((ent = FindEntityByClassname(ent, "prop_door_rotating_checkpoint")) != -1)
    {
        if (count >= maxCount) break;
        GetEntPropVector(ent, Prop_Send, "m_vecOrigin", posList[count]);
        count++;
    }
    return count;
}

float DistToNearestDoor(const float pt[3])
{
    float doors[16][3];
    int dcount = CollectCheckpointDoorPositions(doors, 16);
    if (dcount <= 0)
        return 999999.0;

    float best = 999999.0;
    for (int i = 0; i < dcount; i++)
    {
        float dx = pt[0] - doors[i][0];
        float dy = pt[1] - doors[i][1];
        float dz = pt[2] - doors[i][2];
        float dist = SquareRoot(dx*dx + dy*dy + dz*dz);
        if (dist < best) best = dist;
    }
    return best;
}

// 搜索目标类名并收集在安全门半径内的实体（按离门距离排序）
int CollectAndSortByDoor(const char[] classname, int[] outEnt, int maxOut)
{
    int tempEnt[64];
    float tempPos[64][3];
    float tempDist[64];
    int found = 0;

    int ent = -1;
    while ((ent = FindEntityByClassname(ent, classname)) != -1)
    {
        if (!IsValidEntity(ent)) continue;
        if (found >= 64) break;
        GetEntPropVector(ent, Prop_Send, "m_vecOrigin", tempPos[found]);
        float d = DistToNearestDoor(tempPos[found]);
        if (d <= g_fRadius)
        {
            tempEnt[found] = ent;
            tempDist[found] = d;
            found++;
        }
    }

    // 简单选择排序按距离升序
    for (int i = 0; i < found; i++)
    {
        int best = i;
        for (int j = i + 1; j < found; j++)
        {
            if (tempDist[j] < tempDist[best]) best = j;
        }
        if (best != i)
        {
            int te = tempEnt[i]; tempEnt[i] = tempEnt[best]; tempEnt[best] = te;
            float td = tempDist[i]; tempDist[i] = tempDist[best]; tempDist[best] = td;
        }
    }

    int take = (found < maxOut ? found : maxOut);
    for (int k = 0; k < take; k++)
        outEnt[k] = tempEnt[k];

    return take;
}


// 只对给定实体数组里的前 n 个设置 count 值（避免改到全部）
void SetEntArrayCount(int[] entList, int n, int value)
{
    char s[8];
    IntToString(value, s, sizeof(s));
    for (int i = 0; i < n; i++)
    {
        if (IsValidEntity(entList[i]))
        {
            DispatchKeyValue(entList[i], "count", s);
            Dbg("set count=%d on ent=%d", value, entList[i]);
        }
    }
}

// ======================
// Lifecycle & Events
// ======================
public void OnPluginStart()
{
    gC_Enable    = CreateConVar("sr_medkit_enable", "1", "是否启用安全屋医疗包'count'调整 (1=启用,0=关闭)", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    gC_Base      = CreateConVar("sr_medkit_base",   "4", "基础医疗包/玩家基数(通常为4)", FCVAR_NOTIFY, true, 1.0, true, 8.0);
    gC_Radius    = CreateConVar("sr_medkit_radius", "700.0", "判定为安全屋内医疗包的半径(以最近检查点门为基准)", FCVAR_NOTIFY, true, 100.0, true, 3000.0);
    gC_ScanDelay = CreateConVar("sr_medkit_scan_delay", "1.5", "回合开始后延迟多少秒进行扫描(等待实体生成)", FCVAR_NOTIFY, true, 0.0, true, 10.0);
    gC_Debug     = CreateConVar("sr_medkit_debug",  "0", "调试日志", FCVAR_NONE, true, 0.0, true, 1.0);

    AutoExecConfig(true, "sr_medkit_refill_kv");

    HookEvent("round_start",  Evt_RoundStart, EventHookMode_PostNoCopy);

    HookConVarChange(gC_Enable,    CvarChanged);
    HookConVarChange(gC_Base,      CvarChanged);
    HookConVarChange(gC_Radius,    CvarChanged);
    HookConVarChange(gC_ScanDelay, CvarChanged);
    HookConVarChange(gC_Debug,     CvarChanged);

    RegAdminCmd("sm_srmedkit_apply", Cmd_ApplyNow, ADMFLAG_GENERIC, "立即按当前生还者人数应用一次 count 设置");

    ReadCvars();
}

void ReadCvars()
{
    g_bEnable     = gC_Enable.BoolValue;
    g_iBase       = gC_Base.IntValue;
    g_fRadius     = gC_Radius.FloatValue;
    g_fScanDelay  = gC_ScanDelay.FloatValue;
    g_bDebug      = gC_Debug.BoolValue;
}

public void CvarChanged(ConVar cvar, const char[] oldValue, const char[] newValue)
{
    ReadCvars();
}

public void Evt_RoundStart(Event e, const char[] name, bool dontBroadcast)
{
    if (!g_bEnable) return;
    CreateTimer(g_fScanDelay, Timer_ApplyOnce, _, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_ApplyOnce(Handle timer)
{
    ApplyOnce();
    return Plugin_Stop;
}

public Action Cmd_ApplyNow(int client, int args)
{
    ApplyOnce();
    ReplyToCommand(client, "[SRMedkitKV] applied.");
    return Plugin_Handled;
}

// ======================
// Core
// ======================
void ApplyOnce()
{
    if (!g_bEnable) return;

    int survivors = CountSurvivors();
    int extra = survivors - g_iBase; // 例：5 - 4 = 1 ⇒ 需要把 1 个医疗包的 count 设置为 2
    if (extra <= 0)
    {
        Dbg("no extra needed: survivors=%d base=%d", survivors, g_iBase);
        return;
    }

    int ents[64];
    int total = 0;

    // 先找 spawn 版
    int got = CollectAndSortByDoor("weapon_first_aid_kit_spawn", ents, 64);
    total += got;

    // 若 spawn 不足，再补找实物（有些图直接放实物）
    if (total < extra)
    {
        int offs = total;
        got = CollectAndSortByDoor("weapon_first_aid_kit", ents[offs], 64 - offs);
        total += got;
    }

    if (total <= 0)
    {
        Dbg("no medkits near checkpoint doors");
        return;
    }

    int assign = (extra < total ? extra : total);
    SetEntArrayCount(ents, assign, 2); // 让前 assign 个可拿 2 次

    Dbg("applied: survivors=%d base=%d extra=%d assigned=%d (found=%d)", survivors, g_iBase, extra, assign, total);
}
