/**  
 * l4d2_hitsound_plus.sp
 *
 * 本版要点：
 * - 数据库保存音效四项、图标三项、两个范围开关及播放模式
 * - 玩家可套用音效预设，也可按爆头/命中/击杀/爆头击杀分别选择实际存在的声音
 * - 音效预设中的空成员自动写为 0；图标保留套装和单项开关
 * - 管理员可将命中/击杀/爆头图标分别指定为任意图标套装
 * - KV fallback 保留对旧 KV 键 Snd/Overlay/SndHeadKill 的一次性继承
 * - 保留 FastDL、builtin=1 跳过、统一预缓存、RegPluginLibrary
 *
 * 配置文件：
 *   addons/sourcemod/configs/hitsound_sets.cfg   （音效套装：headshot/hit/kill，支持 builtin）
 *   addons/sourcemod/configs/hitsound_sounds.cfg （去重公共音效库：稳定ID/name/path/builtin/stack）
 *   addons/sourcemod/configs/hiticon_sets.cfg    （图标套装：head/hit/kill，支持 builtin）
 *
 * 音效套装可选定制键：
 *   "headshot_kill"  爆头击杀专用音；留空/缺省 = 沿用 headshot 音
 *   "stack"          1/缺省 = 每个事件立即播放；0 = 同帧合并为一条（击杀>爆头>命中）
 *   "apply_special_only"  选中该套装时写入「仅特感」开关（0/1）；缺省 = 不改
 *
 * 四个音效字段：正数=兼容来源套装ID，负数=公共音效ID，0=关闭；爆头击杀0=跟随普通爆头音。
 * 致死那发只由死亡事件播一声。hurt 不再为超杀补播。
 * 播放一律 SNDCHAN_AUTO；能发就发，被引擎掐断也无所谓。
 *
 * 重要编号约定：
 *   - 套装ID：1..N，0 表示禁用
 *   - 数组索引：内部数组存放为 0..N-1（故读取时用 setId-1）
 *
 * SQL 字段由外部手动维护，表名默认 ConVar: sm_hitsound_db_table = RPG；四个音效列必须为有符号整数。
 * RPG 表需包含：hitsound_head/hit/kill、hiticon_head/hit/kill、
 * hitsound_si_only、hiticon_si_only、hitsound_stack_mode、hitsound_headkill。
 * 缺少最后两列时执行 database/migrations/20260820_hitsound_personal_prefs.sql。
 * 四个音效列为 unsigned 时执行 database/migrations/20260823_hitsound_sound_catalog.sql。
 *
 * commands:
 *   !snd    -> 主菜单（音效预设 + 四类公共音效任选 + 图标与范围设置）
 *   sm_hitsound_reload -> 重新从 DB/KV 读取所有在线玩家的偏好
 */

#pragma semicolon 1

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <adminmenu>

#define PLUGIN_VERSION "2.8.0"
#define CVAR_FLAGS     FCVAR_NONE
#define IsValidClient(%1) (1 <= %1 && %1 <= MaxClients && IsClientInGame(%1))
#define OVERLAY_CLEAN_INTERVAL 0.1
#define SOUND_CATALOG_MAX_ID 127
#define PREF_VALUE_MISSING 1000

// --------------------- Library expose ---------------------
public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    RegPluginLibrary("l4d2_hitsound_plus");
    RegPluginLibrary("l4d2_hitsound"); // 兼容别名
    return APLRes_Success;
}

// --------------------- ConVars ---------------------
ConVar cv_enable;
ConVar cv_debug; // 调试总开关
ConVar cv_sound_enable;
ConVar cv_pic_enable;     // 全局启/停覆盖图功能（大总开关）
ConVar cv_blast;
ConVar cv_showtime;
// 新玩家默认是否启用覆盖图：1=给默认套装1（若存在），0=默认禁用
ConVar cv_overlay_default_enable;

ConVar cv_db_enable;
ConVar cv_db_conf;
ConVar cv_db_table;       // 可配置表名（默认 RPG）

enum SoundFeedbackPriority
{
    SOUND_FEEDBACK_NONE = 0,
    SOUND_FEEDBACK_HIT,
    SOUND_FEEDBACK_HEADSHOT,
    SOUND_FEEDBACK_KILL,
    SOUND_FEEDBACK_HEADSHOT_KILL
};

enum SoundChoiceType
{
    SOUND_CHOICE_HEADSHOT = 0,
    SOUND_CHOICE_HIT,
    SOUND_CHOICE_KILL,
    SOUND_CHOICE_HEADSHOT_KILL
};

// --------------------- State ---------------------
// 「最近套装」用于非管理员在“特定开关”重新开启时恢复为最近一次套装选择（不入库）
int  g_SndSuite [MAXPLAYERS + 1] = {0, ...}; // 最近一次“音效套装（玩家）”
int  g_IcSuite  [MAXPLAYERS + 1] = {0, ...}; // 最近一次“图标套装（玩家）”

// 音效字段：0=关闭（爆头击杀为跟随）；正数=兼容套装ID；负数=公共音效ID。
int  g_SndHead  [MAXPLAYERS + 1] = {0, ...};
int  g_SndHit   [MAXPLAYERS + 1] = {0, ...};
int  g_SndKill  [MAXPLAYERS + 1] = {0, ...};
int  g_SndHeadKill[MAXPLAYERS + 1] = {0, ...};

int  g_IcHead   [MAXPLAYERS + 1] = {0, ...};
int  g_IcHit    [MAXPLAYERS + 1] = {0, ...};
int  g_IcKill   [MAXPLAYERS + 1] = {0, ...};

bool g_SndSpecialOnly[MAXPLAYERS + 1] = { false, ... };
bool g_IcSpecialOnly [MAXPLAYERS + 1] = { false, ... };

// 0=跟随声音来源 stack；1=强制叠加；2=强制合并
int  g_SndStackMode [MAXPLAYERS + 1] = { 0, ... };
bool g_PrefsLoaded[MAXPLAYERS + 1] = { false, ... };
bool g_PrefsDirty [MAXPLAYERS + 1] = { false, ... };
bool g_DBLoadInFlight[MAXPLAYERS + 1] = { false, ... };
bool g_DBSavePending[MAXPLAYERS + 1] = { false, ... };
bool g_DBSaveInFlight[MAXPLAYERS + 1] = { false, ... };
bool g_HasLegacyHeadKillPref[MAXPLAYERS + 1] = { false, ... };
int  g_PrefsRevision[MAXPLAYERS + 1] = { 0, ... };

Handle g_hDB = INVALID_HANDLE;
bool   g_DBConnecting = false;

Handle g_hOverlayCleanTimer = INVALID_HANDLE;
float  g_OverlayExpiresAt[MAXPLAYERS + 1] = { 0.0, ... };
bool   g_OverlayActive[MAXPLAYERS + 1] = { false, ... };
int    g_OverlaySetId[MAXPLAYERS + 1] = { 0, ... };
int    g_OverlayType[MAXPLAYERS + 1] = { -1, ... };
int    g_ActiveOverlayCount = 0;
float  g_OverlayShowTime = 0.3;
bool   g_IsVictimDeadPlayer[MAXPLAYERS + 1] = { false, ... };
bool   g_SoundFramePending[MAXPLAYERS + 1] = { false, ... };
SoundFeedbackPriority g_PendingSoundPriority[MAXPLAYERS + 1] = { SOUND_FEEDBACK_NONE, ... };
char   g_PendingSoundSample[MAXPLAYERS + 1][PLATFORM_MAX_PATH];

// Fallback KV
Handle g_SoundStore = INVALID_HANDLE;
char   g_SavePath[256];

// --------------------- Sound sets ---------------------
Handle g_SetNames    = INVALID_HANDLE;
Handle g_SetHeadshot = INVALID_HANDLE;
Handle g_SetHit      = INVALID_HANDLE;
Handle g_SetKill     = INVALID_HANDLE;
Handle g_SetHeadKill = INVALID_HANDLE; // 爆头击杀专用音（可选；空 = 回退 headshot）
Handle g_SetStack    = INVALID_HANDLE; // 1 = 逐事件立即播放（不做同帧合并去重；缺省 1）
Handle g_SetApplySpecialOnly = INVALID_HANDLE; // -1=不套用；0/1
int    g_SetCount    = 0; // 套装总数（音效），套装ID有效范围：1..g_SetCount

// --------------------- Deduplicated sound catalog ---------------------
Handle g_SoundIds     = INVALID_HANDLE; // 稳定ID 1..127；个人字段中编码为负数
Handle g_SoundNames   = INVALID_HANDLE;
Handle g_SoundPaths   = INVALID_HANDLE;
Handle g_SoundBuiltin = INVALID_HANDLE;
Handle g_SoundStack   = INVALID_HANDLE;
int    g_SoundCount   = 0;

// --------------------- Overlay icon sets（玩家自选） ---------------------
Handle g_OvNames = INVALID_HANDLE;
Handle g_OvHead  = INVALID_HANDLE; // materials 基名（不含扩展名）
Handle g_OvHit   = INVALID_HANDLE;
Handle g_OvKill  = INVALID_HANDLE;
int    g_OvCount = 0; // 套装总数（图标），套装ID有效范围：1..g_OvCount

// --------------------- Enums ---------------------
enum OverlayType
{
    KILL_HEADSHOT = 0,
    HIT_ARMOR,
    KILL_NORMAL
};

// --------------------- Plugin Info ---------------------
public Plugin myinfo =
{
    name = "L4D2 Hit/Kill Feedback Plus",
    author = "TsukasaSato , Hesh233 (branch) , merged/updated by ChatGPT",
    description = "去重公共音效库、四类任意选音与三类图标偏好入库",
    version = PLUGIN_VERSION
};

// ========================================================
// Helpers
// ========================================================
stock void DBG(const char[] fmt, any ...)
{
    if (!GetConVarBool(cv_debug)) return;
    char buf[512];
    VFormat(buf, sizeof(buf), fmt, 2); // 2 = 第一个可变参数位置
    LogMessage("[hitsound-dbg] %s", buf);
}

static int SafeFetchInt(Handle hndl, int col)
{
    return (col < SQL_GetFieldCount(hndl)) ? SQL_FetchInt(hndl, col) : 0;
}

static bool IsSafeSQLIdentifier(const char[] value)
{
    int len = strlen(value);
    if (len <= 0)
        return false;

    for (int i = 0; i < len; i++)
    {
        int c = value[i];
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_'))
            return false;
    }

    return true;
}

static void GetDBTableName(char[] table, int maxlen)
{
    GetConVarString(cv_db_table, table, maxlen);
    TrimString(table);

    if (!IsSafeSQLIdentifier(table))
        strcopy(table, maxlen, "RPG");
}

static int FindSoundCatalogIndexById(int soundId)
{
    for (int i = 0; i < g_SoundCount; i++)
    {
        if (GetArrayCell(g_SoundIds, i) == soundId) return i;
    }
    return -1;
}

static int FindSoundCatalogIdByPath(const char[] sample)
{
    if (sample[0] == '\0') return 0;

    char configured[PLATFORM_MAX_PATH];
    for (int i = 0; i < g_SoundCount; i++)
    {
        GetArrayString(g_SoundPaths, i, configured, sizeof(configured));
        if (StrEqual(configured, sample, false)) return GetArrayCell(g_SoundIds, i);
    }
    return 0;
}

static bool GetSoundCatalogPath(int soundId, char[] out, int maxlen)
{
    int idx = FindSoundCatalogIndexById(soundId);
    if (idx < 0) { out[0] = '\0'; return false; }
    GetArrayString(g_SoundPaths, idx, out, maxlen);
    return out[0] != '\0';
}

static void GetSoundCatalogName(int soundId, char[] out, int maxlen)
{
    int idx = FindSoundCatalogIndexById(soundId);
    if (idx < 0) { strcopy(out, maxlen, "未知音效"); return; }
    GetArrayString(g_SoundNames, idx, out, maxlen);
}

static void ClampSoundChoice(int &v)
{
    if (v > 0 && v > g_SetCount) v = 0;
    else if (v < 0 && FindSoundCatalogIndexById(-v) < 0) v = 0;
}

static void ClampSoundPreset(int &v)
{
    if (v < 0 || v > g_SetCount) v = 0;
}
static void ClampSetIc(int &v)
{
    if (v < 0) v = 0;
    // 有效范围 1..g_OvCount
    if (v > g_OvCount) v = 0;
}
static void MarkDirtyAndSave(int client)
{
    if (!IsValidClient(client) || IsFakeClient(client) || !g_PrefsLoaded[client])
    {
        LogError("[hitsound] 拒绝保存尚未加载完成的玩家偏好 (client=%d)。", client);
        return;
    }

    g_PrefsRevision[client]++;
    g_PrefsDirty[client] = true;

    if (GetConVarBool(cv_db_enable) && g_hDB != INVALID_HANDLE) {
        g_DBSavePending[client] = true;
        KV_SavePlayer(client);
        KV_SetDBPendingFlag(client, true);
        DB_SavePlayerPrefs(client);
    } else if (GetConVarBool(cv_db_enable)) {
        g_DBSavePending[client] = true;
        KV_SavePlayer(client);
        KV_SetDBPendingFlag(client, true);
    } else {
        KV_SavePlayer(client);
        g_PrefsDirty[client] = false;
        g_DBSavePending[client] = false;
        KV_SetDBPendingFlag(client, false);
    }
}

static bool IsSpecialInfectedClient(int client)
{
    if (!IsValidClient(client) || GetClientTeam(client) != 3) return false;

    int zClass = GetEntProp(client, Prop_Send, "m_zombieClass");
    return (1 <= zClass && zClass <= 6) || zClass == 8;
}

static bool ShouldShowIconFeedback(int attacker, bool specialTarget)
{
    return !g_IcSpecialOnly[attacker] || specialTarget;
}

static bool ShouldPlaySoundFeedback(int attacker, bool specialTarget)
{
    return !g_SndSpecialOnly[attacker] || specialTarget;
}

static bool KV_HasPendingDBSave(int client)
{
    char uid[128] = "";
    if (!GetClientAuthId(client, AuthId_Engine, uid, sizeof(uid), true) || uid[0] == '\0')
        return false;

    bool pending = false;
    if (KvJumpToKey(g_SoundStore, uid, false))
    {
        pending = (KvGetNum(g_SoundStore, "DBPending", 0) != 0);
        KvGoBack(g_SoundStore);
    }
    KvRewind(g_SoundStore);
    return pending;
}

static void KV_SetDBPendingFlag(int client, bool pending)
{
    char uid[128] = "";
    if (!GetClientAuthId(client, AuthId_Engine, uid, sizeof(uid), true) || uid[0] == '\0')
        return;

    if (!pending && !KvJumpToKey(g_SoundStore, uid, false))
    {
        KvRewind(g_SoundStore);
        return;
    }

    if (pending)
        KvJumpToKey(g_SoundStore, uid, true);

    KvSetNum(g_SoundStore, "DBPending", pending ? 1 : 0);
    KvGoBack(g_SoundStore);
    KvRewind(g_SoundStore);
    KeyValuesToFile(g_SoundStore, g_SavePath);
}

// 根据“音效套装ID(1..N)”与类型取路径：which 0=headshot, 1=hit, 2=kill, 3=headshot_kill
static bool GetSoundPath_BySet(int setId, SoundChoiceType which, char[] out, int maxlen)
{
    if (setId <= 0 || setId > g_SetCount) { out[0] = '\0'; return false; }
    int idx = setId - 1;
    if (which == SOUND_CHOICE_HEADSHOT)      GetArrayString(g_SetHeadshot, idx, out, maxlen);
    else if (which == SOUND_CHOICE_HIT) GetArrayString(g_SetHit, idx, out, maxlen);
    else if (which == SOUND_CHOICE_HEADSHOT_KILL) GetArrayString(g_SetHeadKill, idx, out, maxlen);
    else                 GetArrayString(g_SetKill,     idx, out, maxlen);
    return (out[0] != '\0');
}

static bool GetEffectiveSoundPath_BySet(int setId, SoundChoiceType which, char[] out, int maxlen)
{
    if (which != SOUND_CHOICE_HEADSHOT_KILL)
        return GetSoundPath_BySet(setId, which, out, maxlen);

    if (GetSoundPath_BySet(setId, SOUND_CHOICE_HEADSHOT_KILL, out, maxlen))
        return true;

    return GetSoundPath_BySet(setId, SOUND_CHOICE_HEADSHOT, out, maxlen);
}

static bool SoundSetHasConfiguredPath(int setId, SoundChoiceType which)
{
    char sample[PLATFORM_MAX_PATH];
    return GetSoundPath_BySet(setId, which, sample, sizeof(sample));
}

static bool SoundSetHasChoice(int setId, SoundChoiceType which)
{
    char sample[PLATFORM_MAX_PATH];
    return GetEffectiveSoundPath_BySet(setId, which, sample, sizeof(sample));
}

static bool GetSoundPathByChoice(int choice, SoundChoiceType which, char[] out, int maxlen)
{
    if (choice < 0)
        return GetSoundCatalogPath(-choice, out, maxlen);

    if (choice <= 0) { out[0] = '\0'; return false; }
    if (which == SOUND_CHOICE_HEADSHOT_KILL)
        return GetEffectiveSoundPath_BySet(choice, which, out, maxlen);
    return GetSoundPath_BySet(choice, which, out, maxlen);
}

static int GetSoundChoice(int client, SoundChoiceType which)
{
    if (which == SOUND_CHOICE_HEADSHOT) return g_SndHead[client];
    if (which == SOUND_CHOICE_HIT) return g_SndHit[client];
    if (which == SOUND_CHOICE_KILL) return g_SndKill[client];
    return g_SndHeadKill[client];
}

static void SetSoundChoice(int client, SoundChoiceType which, int choice)
{
    if (which == SOUND_CHOICE_HEADSHOT) g_SndHead[client] = choice;
    else if (which == SOUND_CHOICE_HIT) g_SndHit[client] = choice;
    else if (which == SOUND_CHOICE_KILL) g_SndKill[client] = choice;
    else g_SndHeadKill[client] = choice;
}

static int GetSoundPresetValue(int setId, SoundChoiceType which)
{
    if (setId <= 0 || setId > g_SetCount) return 0;

    // 爆头击杀没有专用成员时用 0 表示跟随普通爆头音。
    if (which == SOUND_CHOICE_HEADSHOT_KILL)
        return SoundSetHasConfiguredPath(setId, SOUND_CHOICE_HEADSHOT_KILL) ? setId : 0;

    return SoundSetHasConfiguredPath(setId, which) ? setId : 0;
}

static void ApplySoundPreset(int client, int setId)
{
    g_SndSuite[client] = setId;
    g_SndHead[client] = GetSoundPresetValue(setId, SOUND_CHOICE_HEADSHOT);
    g_SndHit[client] = GetSoundPresetValue(setId, SOUND_CHOICE_HIT);
    g_SndKill[client] = GetSoundPresetValue(setId, SOUND_CHOICE_KILL);
    g_SndHeadKill[client] = GetSoundPresetValue(setId, SOUND_CHOICE_HEADSHOT_KILL);
}

static bool DoesSoundPresetMatch(int client, int setId)
{
    return g_SndHead[client] == GetSoundPresetValue(setId, SOUND_CHOICE_HEADSHOT)
        && g_SndHit[client] == GetSoundPresetValue(setId, SOUND_CHOICE_HIT)
        && g_SndKill[client] == GetSoundPresetValue(setId, SOUND_CHOICE_KILL)
        && g_SndHeadKill[client] == GetSoundPresetValue(setId, SOUND_CHOICE_HEADSHOT_KILL);
}

static int FindMatchingSoundPreset(int client)
{
    for (int setId = 1; setId <= g_SetCount; setId++)
    {
        if (DoesSoundPresetMatch(client, setId)) return setId;
    }
    return 0;
}

static bool NormalizePlayerSelections(int client)
{
    int oldSndHead = g_SndHead[client];
    int oldSndHit = g_SndHit[client];
    int oldSndKill = g_SndKill[client];
    int oldSndHeadKill = g_SndHeadKill[client];
    int oldSndSuite = g_SndSuite[client];
    int oldIcHead = g_IcHead[client];
    int oldIcHit = g_IcHit[client];
    int oldIcKill = g_IcKill[client];
    int oldIcSuite = g_IcSuite[client];

    ClampSoundChoice(g_SndHead[client]);
    ClampSoundChoice(g_SndHit[client]);
    ClampSoundChoice(g_SndKill[client]);
    ClampSoundChoice(g_SndHeadKill[client]);
    ClampSoundPreset(g_SndSuite[client]);
    ClampSetIc(g_IcHead[client]);
    ClampSetIc(g_IcHit[client]);
    ClampSetIc(g_IcKill[client]);
    ClampSetIc(g_IcSuite[client]);

    if (g_SndHead[client] > 0 && !SoundSetHasChoice(g_SndHead[client], SOUND_CHOICE_HEADSHOT)) g_SndHead[client] = 0;
    if (g_SndHit[client] > 0 && !SoundSetHasChoice(g_SndHit[client], SOUND_CHOICE_HIT)) g_SndHit[client] = 0;
    if (g_SndKill[client] > 0 && !SoundSetHasChoice(g_SndKill[client], SOUND_CHOICE_KILL)) g_SndKill[client] = 0;
    if (g_SndHeadKill[client] > 0 && !SoundSetHasChoice(g_SndHeadKill[client], SOUND_CHOICE_HEADSHOT_KILL)) g_SndHeadKill[client] = 0;

    return oldSndHead != g_SndHead[client]
        || oldSndHit != g_SndHit[client]
        || oldSndKill != g_SndKill[client]
        || oldSndHeadKill != g_SndHeadKill[client]
        || oldSndSuite != g_SndSuite[client]
        || oldIcHead != g_IcHead[client]
        || oldIcHit != g_IcHit[client]
        || oldIcKill != g_IcKill[client]
        || oldIcSuite != g_IcSuite[client];
}

static bool IsStackSource(int choice)
{
    if (choice < 0)
    {
        int idx = FindSoundCatalogIndexById(-choice);
        return idx >= 0 && GetArrayCell(g_SoundStack, idx) != 0;
    }
    if (choice <= 0 || choice > g_SetCount) return false;
    return GetArrayCell(g_SetStack, choice - 1) != 0;
}

static bool ShouldStackFeedback(int client, int choice)
{
    if (g_SndStackMode[client] == 1) return true;
    if (g_SndStackMode[client] == 2) return false;
    return IsStackSource(choice);
}

static int ParseOptionalPrefInt(const char[] s, int minVal, int maxVal)
{
    if (s[0] == '\0') return -1;
    int v = StringToInt(s);
    if (v < minVal || v > maxVal) return -1;
    return v;
}

static bool ApplySoundSetPersonalDefaults(int client, int setId)
{
    if (setId <= 0 || setId > g_SetCount) return false;

    int v = GetArrayCell(g_SetApplySpecialOnly, setId - 1);
    if (v < 0) return false;

    g_SndSpecialOnly[client] = (v != 0);
    return true;
}

// 击杀事件取样本：爆头击杀优先套装的 headshot_kill，未配置则回退 headshot
static bool GetKillSoundSample(int attacker, bool headshot, char[] out, int maxlen, int &choice)
{
    if (headshot && g_SndHeadKill[attacker] != 0)
    {
        choice = g_SndHeadKill[attacker];
        return GetSoundPathByChoice(choice, SOUND_CHOICE_HEADSHOT_KILL, out, maxlen);
    }

    choice = headshot ? g_SndHead[attacker] : g_SndKill[attacker];
    if (choice == 0) { out[0] = '\0'; return false; }

    return GetSoundPathByChoice(choice, headshot ? SOUND_CHOICE_HEADSHOT : SOUND_CHOICE_KILL, out, maxlen);
}

static void ResetPendingSoundFeedback(int client)
{
    g_SoundFramePending[client] = false;
    g_PendingSoundPriority[client] = SOUND_FEEDBACK_NONE;
    g_PendingSoundSample[client][0] = '\0';
}

static void QueueSoundFeedback(int client, int choice, const char[] sample, SoundFeedbackPriority priority)
{
    if (!GetConVarBool(cv_enable) || !GetConVarBool(cv_sound_enable) || !IsValidClient(client) || sample[0] == '\0') return;

    // 叠加播放：逐事件立即播放，可同帧叠加（复刻老 killsound 行为）
    if (ShouldStackFeedback(client, choice))
    {
        EmitSoundToClient(client, sample, SOUND_FROM_PLAYER, SNDCHAN_AUTO, SNDLEVEL_NORMAL);
        return;
    }

    if (priority > g_PendingSoundPriority[client])
    {
        g_PendingSoundPriority[client] = priority;
        strcopy(g_PendingSoundSample[client], PLATFORM_MAX_PATH, sample);
    }

    if (!g_SoundFramePending[client])
    {
        g_SoundFramePending[client] = true;
        RequestFrame(Frame_PlayPendingSoundFeedback, GetClientUserId(client));
    }
}

public void Frame_PlayPendingSoundFeedback(any userid)
{
    int client = GetClientOfUserId(userid);
    if (!IsValidClient(client) || !g_SoundFramePending[client]) return;

    char sample[PLATFORM_MAX_PATH];
    strcopy(sample, sizeof(sample), g_PendingSoundSample[client]);
    ResetPendingSoundFeedback(client);

    if (!GetConVarBool(cv_enable) || !GetConVarBool(cv_sound_enable) || sample[0] == '\0') return;

    EmitSoundToClient(client, sample, SOUND_FROM_PLAYER, SNDCHAN_AUTO, SNDLEVEL_NORMAL);
}

// 根据“图标套装ID(1..N)”与类型取 base：which 0=head 1=hit 2=kill
static bool GetOverlayBase_BySet(int setId, int which, char[] out, int maxlen)
{
    if (setId <= 0 || setId > g_OvCount) { out[0]='\0'; return false; }
    int idx = setId - 1;
    if (which == 0)      GetArrayString(g_OvHead, idx, out, maxlen);
    else if (which == 1) GetArrayString(g_OvHit,  idx, out, maxlen);
    else                 GetArrayString(g_OvKill, idx, out, maxlen);
    return (out[0] != '\0');
}

static void ShowOverlayBySet(int client, int setId, int which)
{
    if (!GetConVarBool(cv_enable) || !GetConVarBool(cv_pic_enable) || setId <= 0 || setId > g_OvCount) return;

    float expiresAt = GetEngineTime() + g_OverlayShowTime;

    if (g_OverlayActive[client] && g_OverlaySetId[client] == setId && g_OverlayType[client] == which)
    {
        g_OverlayExpiresAt[client] = expiresAt;
        return;
    }

    char base[PLATFORM_MAX_PATH];
    if (!GetOverlayBase_BySet(setId, which, base, sizeof(base))) return;

    ClientCommand(client, "r_screenoverlay \"%s\"", base);
    g_OverlayExpiresAt[client] = expiresAt;

    if (!g_OverlayActive[client])
    {
        g_OverlayActive[client] = true;
        g_ActiveOverlayCount++;
    }
    g_OverlaySetId[client] = setId;
    g_OverlayType[client] = which;

    if (g_hOverlayCleanTimer == INVALID_HANDLE)
    {
        g_hOverlayCleanTimer = CreateTimer(
            OVERLAY_CLEAN_INTERVAL,
            Timer_CleanOverlays,
            _,
            TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE
        );
    }
}

static void ResetClientOverlayState(int client, bool clearOverlay)
{
    bool wasActive = g_OverlayActive[client];
    if (wasActive)
    {
        g_OverlayActive[client] = false;
        if (g_ActiveOverlayCount > 0)
            g_ActiveOverlayCount--;
    }
    g_OverlayExpiresAt[client] = 0.0;
    g_OverlaySetId[client] = 0;
    g_OverlayType[client] = -1;

    if (clearOverlay && wasActive && IsValidClient(client) && !IsFakeClient(client))
        ClientCommand(client, "r_screenoverlay \"\"");
}

static void StopOverlayCleanTimer()
{
    if (g_hOverlayCleanTimer != INVALID_HANDLE)
    {
        Handle timer = g_hOverlayCleanTimer;
        g_hOverlayCleanTimer = INVALID_HANDLE;
        if (IsValidHandle(timer))
            KillTimer(timer);
    }
}

static void ResetAllOverlayState(bool clearOverlays)
{
    StopOverlayCleanTimer();

    for (int client = 1; client <= MaxClients; client++)
        ResetClientOverlayState(client, clearOverlays);

    g_ActiveOverlayCount = 0;
}

// ========================================================
// Init
// ========================================================
public void OnPluginStart()
{
	LoadTranslations("l4d2_hitsound.phrases");
    char game[64];
    GetGameFolderName(game, sizeof(game));
    if (!StrEqual(game, "left4dead2", false))
    {
        SetFailState("本插件仅支持 L4D2!");
    }

    CreateConVar("l4d2_hitsound_plus_ver", PLUGIN_VERSION, "Plugin version", 0);

    cv_enable                 = CreateConVar("sm_hitsound_enable", "1", "是否开启本插件(0关,1开)", CVAR_FLAGS);
    cv_sound_enable           = CreateConVar("sm_hitsound_sound_enable", "1", "是否开启音效(0关,1开)", CVAR_FLAGS);
    cv_pic_enable             = CreateConVar("sm_hitsound_pic_enable", "1", "是否开启覆盖图标(0关,1开 总开关)", CVAR_FLAGS);
    cv_blast                  = CreateConVar("sm_blast_damage_enable", "0", "是否开启爆炸反馈提示(0关,1开 建议关)", CVAR_FLAGS);
    cv_showtime               = CreateConVar("sm_hitsound_showtime", "0.3", "覆盖图标显示时长(秒)", CVAR_FLAGS);
    cv_overlay_default_enable = CreateConVar("sm_hitsound_overlay_default", "1", "新玩家默认是否启用覆盖图(1给套装1,0禁用)", CVAR_FLAGS);

    cv_db_enable              = CreateConVar("sm_hitsound_db_enable", "1", "是否启用 RPG 表存储(1启用,0禁用；运行时修改需重载插件)", CVAR_FLAGS);
    cv_db_conf                = CreateConVar("sm_hitsound_db_conf", "rpg", "databases.cfg 中的连接名（运行时修改需重载插件）", CVAR_FLAGS);
    cv_db_table               = CreateConVar("sm_hitsound_db_table", "RPG", "存储表名（运行时修改需重载插件）", CVAR_FLAGS);
    cv_debug                  = CreateConVar("sm_hitsound_debug", "0", "调试输出(0关,1开)", CVAR_FLAGS);

    g_OverlayShowTime = GetConVarFloat(cv_showtime);
    if (g_OverlayShowTime < 0.0)
        g_OverlayShowTime = 0.0;
    HookConVarChange(cv_showtime, ConVarChanged_OverlayShowTime);
    HookConVarChange(cv_enable, ConVarChanged_FeedbackEnable);
    HookConVarChange(cv_pic_enable, ConVarChanged_FeedbackEnable);

    int overlayFlags = GetCommandFlags("r_screenoverlay");
    if (overlayFlags != INVALID_FCVAR_FLAGS && (overlayFlags & FCVAR_CHEAT) != 0)
        SetCommandFlags("r_screenoverlay", overlayFlags & ~FCVAR_CHEAT);

    // Fallback KV
    g_SoundStore = CreateKeyValues("SoundSelect6");
    BuildPath(Path_SM, g_SavePath, sizeof(g_SavePath), "data/SoundSelect.txt");
    if (FileExists(g_SavePath)) FileToKeyValues(g_SoundStore, g_SavePath);
    else KeyValuesToFile(g_SoundStore, g_SavePath);

    // Arrays
    g_SetNames    = CreateArray(64);
    g_SetHeadshot = CreateArray(PLATFORM_MAX_PATH);
    g_SetHit      = CreateArray(PLATFORM_MAX_PATH);
    g_SetKill     = CreateArray(PLATFORM_MAX_PATH);
    g_SetHeadKill = CreateArray(PLATFORM_MAX_PATH);
    g_SetStack    = CreateArray(1);
    g_SetApplySpecialOnly = CreateArray(1);

    g_SoundIds     = CreateArray(1);
    g_SoundNames   = CreateArray(64);
    g_SoundPaths   = CreateArray(PLATFORM_MAX_PATH);
    g_SoundBuiltin = CreateArray(1);
    g_SoundStack   = CreateArray(1);

    g_OvNames = CreateArray(64);
    g_OvHead  = CreateArray(PLATFORM_MAX_PATH);
    g_OvHit   = CreateArray(PLATFORM_MAX_PATH);
    g_OvKill  = CreateArray(PLATFORM_MAX_PATH);

    // Load configs
    LoadHitSoundSets();
    LoadHitSoundCatalog();
    LoadHitIconSets();
    if (IsServerProcessing())
        PrecacheAllAssets();

    RegConsoleCmd("sm_snd",   Cmd_MenuMain, "主菜单：音效预设、四类公共音效任选、图标与范围设置");
    RegAdminCmd ("sm_hitsound_reload", Cmd_ReloadAll, ADMFLAG_ROOT, "重新从 DB/KV 读取所有在线玩家的偏好");

    AutoExecConfig(true, "l4d2_hitsound_plus");

    // 始终挂钩；总开关在事件入口动态判断，确保 cfg 延迟执行和运行时切换都生效。
    HookEvent("infected_hurt",       Event_InfectedHurt,  EventHookMode_Pre);
    HookEvent("infected_death",      Event_InfectedDeath);
    HookEvent("player_death",        Event_PlayerDeath);
    HookEvent("player_hurt",         Event_PlayerHurt,    EventHookMode_Pre);
    HookEvent("tank_spawn",          Event_TankSpawn);
    HookEvent("player_spawn",        Event_PlayerSpawn);
    HookEvent("round_start",         Event_RoundStart,    EventHookMode_Post);
    HookEvent("player_incapacitated",Event_PlayerIncap);
}

public void ConVarChanged_OverlayShowTime(ConVar convar, const char[] oldValue, const char[] newValue)
{
    g_OverlayShowTime = GetConVarFloat(convar);
    if (g_OverlayShowTime < 0.0)
        g_OverlayShowTime = 0.0;
}

public void ConVarChanged_FeedbackEnable(ConVar convar, const char[] oldValue, const char[] newValue)
{
    if (GetConVarBool(cv_enable) && GetConVarBool(cv_pic_enable)) return;

    ResetAllOverlayState(true);
    if (!GetConVarBool(cv_enable))
    {
        for (int client = 1; client <= MaxClients; client++)
            ResetPendingSoundFeedback(client);
    }
}

public void OnMapEnd()
{
    ResetAllOverlayState(false);
    for (int client = 1; client <= MaxClients; client++)
        ResetPendingSoundFeedback(client);
    // 数据库连接保持跨地图运行。
    g_DBConnecting = false;
}

// 在执行完 cfg（例如加载模式/exec zonemod/药抗）后，重新加载在线玩家的偏好
public void OnConfigsExecuted()
{
    if (GetConVarBool(cv_db_enable) && g_hDB == INVALID_HANDLE)
    {
        StartDBConnect();
    }

    ReloadAllPlayersPrefs();
}

public void OnPluginEnd()
{
    ResetAllOverlayState(true);

    if (g_hDB != INVALID_HANDLE)
    {
        CloseHandle(g_hDB);
        g_hDB = INVALID_HANDLE;
    }
}

// ========================================================
// Config loading
// ========================================================
static void AddConfiguredSoundDownload(int soundId, const char[] soundName, const char[] sample)
{
    if (sample[0] == '\0') return;

    char path[PLATFORM_MAX_PATH];
    Format(path, sizeof(path), "sound/%s", sample);
    if (!FileExists(path, true))
        LogError("[hitsound] 公共音效 S%02d '%s' 文件不存在: %s", soundId, soundName, path);

    DBG("FDL add: %s", path);
    AddFileToDownloadsTable(path);
}

void LoadHitSoundSets()
{
    ClearArray(g_SetNames);
    ClearArray(g_SetHeadshot);
    ClearArray(g_SetHit);
    ClearArray(g_SetKill);
    ClearArray(g_SetHeadKill);
    ClearArray(g_SetStack);
    ClearArray(g_SetApplySpecialOnly);
    g_SetCount = 0;

    Handle kv = CreateKeyValues("HitSoundSets");
    if (!FileToKeyValues(kv, "addons/sourcemod/configs/hitsound_sets.cfg"))
    {
        CloseHandle(kv);
        SetFailState("[hitsound] 未找到 hitsound_sets.cfg，拒绝加载以保护旧套餐偏好。");
        return;
    }

    bool valid = true;
    KvRewind(kv);
    if (KvGotoFirstSubKey(kv))
    {
        do {
            char section[16], name[64];
            char sh[PLATFORM_MAX_PATH], hi[PLATFORM_MAX_PATH], ki[PLATFORM_MAX_PATH], hk[PLATFORM_MAX_PATH];
            char applySpecial[8];
            int  isbuiltin = 0;
            int  stack = 0;

            KvGetSectionName(kv, section, sizeof(section));
            int setId = StringToInt(section);
            if (setId != g_SetCount + 1)
            {
                LogError("[hitsound] 套餐段必须按稳定ID 1..N 连续排列；期望 %d，实际 '%s'。", g_SetCount + 1, section);
                valid = false;
                continue;
            }

            KvGetString(kv, "name", name, sizeof(name), "未命名音效套装");
            KvGetString(kv, "headshot", sh, sizeof(sh), "");
            KvGetString(kv, "hit",      hi, sizeof(hi), "");
            KvGetString(kv, "kill",     ki, sizeof(ki), "");
            KvGetString(kv, "headshot_kill", hk, sizeof(hk), "");
            isbuiltin = KvGetNum(kv, "builtin", 0);
            stack     = KvGetNum(kv, "stack", 1); // 缺省叠加播放；显式 "stack 0" 才启用同帧合并
            KvGetString(kv, "apply_special_only", applySpecial, sizeof(applySpecial), "");
            DBG("SoundSet #%d '%s' builtin=%d stack=%d hs='%s' hit='%s' kill='%s' hskill='%s'",
                g_SetCount+1, name, isbuiltin, stack, sh, hi, ki, hk);

            PushArrayString(g_SetNames, name);
            PushArrayString(g_SetHeadshot, sh);
            PushArrayString(g_SetHit, hi);
            PushArrayString(g_SetKill, ki);
            PushArrayString(g_SetHeadKill, hk);
            PushArrayCell(g_SetStack, stack != 0 ? 1 : 0);
            PushArrayCell(g_SetApplySpecialOnly, ParseOptionalPrefInt(applySpecial, 0, 1));
            g_SetCount++;

        } while (KvGotoNextKey(kv));
    }
    CloseHandle(kv);

    if (!valid || g_SetCount == 0)
    {
        SetFailState("[hitsound] hitsound_sets.cfg 校验失败，拒绝加载以保护旧套餐偏好。");
        return;
    }
    LogMessage("[hitsound] 已加载 %d 套音效配置。", g_SetCount);
}

static bool ValidateSoundCatalogCoverage()
{
    bool valid = true;
    char sample[PLATFORM_MAX_PATH];
    for (int setId = 1; setId <= g_SetCount; setId++)
    {
        for (int type = view_as<int>(SOUND_CHOICE_HEADSHOT); type <= view_as<int>(SOUND_CHOICE_HEADSHOT_KILL); type++)
        {
            if (!GetSoundPath_BySet(setId, view_as<SoundChoiceType>(type), sample, sizeof(sample))) continue;
            if (FindSoundCatalogIdByPath(sample) == 0)
            {
                LogError("[hitsound] 套餐 #%d 引用了公共音效库中不存在的路径: %s", setId, sample);
                valid = false;
            }
        }
    }
    return valid;
}

void LoadHitSoundCatalog()
{
    ClearArray(g_SoundIds);
    ClearArray(g_SoundNames);
    ClearArray(g_SoundPaths);
    ClearArray(g_SoundBuiltin);
    ClearArray(g_SoundStack);
    g_SoundCount = 0;

    Handle kv = CreateKeyValues("HitSoundCatalog");
    if (!FileToKeyValues(kv, "addons/sourcemod/configs/hitsound_sounds.cfg"))
    {
        CloseHandle(kv);
        SetFailState("[hitsound] 未找到 hitsound_sounds.cfg，拒绝加载以保护已有公共音效偏好。");
        return;
    }

    bool valid = true;
    KvRewind(kv);
    if (KvGotoFirstSubKey(kv))
    {
        do {
            char section[16], name[64], sample[PLATFORM_MAX_PATH];
            KvGetSectionName(kv, section, sizeof(section));
            int soundId = StringToInt(section);
            KvGetString(kv, "name", name, sizeof(name), "未命名音效");
            KvGetString(kv, "path", sample, sizeof(sample), "");
            TrimString(sample);

            if (soundId < 1 || soundId > SOUND_CATALOG_MAX_ID)
            {
                LogError("[hitsound] 公共音效ID '%s' 超出 1..%d，已跳过。", section, SOUND_CATALOG_MAX_ID);
                valid = false;
                continue;
            }
            if (FindSoundCatalogIndexById(soundId) >= 0)
            {
                LogError("[hitsound] 公共音效ID S%02d 重复，已跳过后一个定义。", soundId);
                valid = false;
                continue;
            }
            if (sample[0] == '\0')
            {
                LogError("[hitsound] 公共音效 S%02d 路径为空，已跳过。", soundId);
                valid = false;
                continue;
            }

            int duplicateId = FindSoundCatalogIdByPath(sample);
            if (duplicateId > 0)
            {
                LogError("[hitsound] 公共音效 S%02d 与 S%02d 路径重复，已跳过: %s", soundId, duplicateId, sample);
                valid = false;
                continue;
            }

            int isBuiltin = KvGetNum(kv, "builtin", 0) != 0 ? 1 : 0;
            int stack = KvGetNum(kv, "stack", 1) != 0 ? 1 : 0;
            PushArrayCell(g_SoundIds, soundId);
            PushArrayString(g_SoundNames, name);
            PushArrayString(g_SoundPaths, sample);
            PushArrayCell(g_SoundBuiltin, isBuiltin);
            PushArrayCell(g_SoundStack, stack);
            g_SoundCount++;

            if (isBuiltin)
                DBG("FDL skip(builtin): sound/%s", sample);
            else
                AddConfiguredSoundDownload(soundId, name, sample);
        } while (KvGotoNextKey(kv));
    }
    CloseHandle(kv);

    if (!ValidateSoundCatalogCoverage()) valid = false;
    if (!valid || g_SoundCount == 0)
    {
        SetFailState("[hitsound] hitsound_sounds.cfg 校验失败，拒绝加载以保护已有偏好。");
        return;
    }
    LogMessage("[hitsound] 已加载 %d 个去重公共音效。", g_SoundCount);
}

void LoadHitIconSets()
{
    ClearArray(g_OvNames);
    ClearArray(g_OvHead);
    ClearArray(g_OvHit);
    ClearArray(g_OvKill);
    g_OvCount = 0;

    Handle kv = CreateKeyValues("HitIconSets");
    if (!FileToKeyValues(kv, "addons/sourcemod/configs/hiticon_sets.cfg"))
    {
        LogMessage("[hitsound] 未找到 hiticon_sets.cfg，玩家仅可选择禁用(0)。");
        CloseHandle(kv);
        return;
    }

    KvRewind(kv);
    if (KvGotoFirstSubKey(kv))
    {
        do {
            char name[64];
            char head[PLATFORM_MAX_PATH], hit[PLATFORM_MAX_PATH], kill[PLATFORM_MAX_PATH];
            int  isbuiltin = 0;

            KvGetString(kv, "name", name, sizeof(name), "未命名图标套装");
            // 支持 headshot/head
            KvGetString(kv, "head", head, sizeof(head), "");
            if (head[0] == '\0') KvGetString(kv, "headshot", head, sizeof(head), "");
            KvGetString(kv, "hit",  hit,  sizeof(hit),  "");
            KvGetString(kv, "kill", kill, sizeof(kill), "");
            isbuiltin = KvGetNum(kv, "builtin", 0);
            DBG("IconSet  #%d '%s' builtin=%d head='%s' hit='%s' kill='%s'",
                g_OvCount+1, name, isbuiltin, head, hit, kill);

            PushArrayString(g_OvNames, name);
            PushArrayString(g_OvHead, head);
            PushArrayString(g_OvHit, hit);
            PushArrayString(g_OvKill, kill);
            g_OvCount++;

            if (!isbuiltin)
            {
                if (head[0] != '\0') {
                    char p1[PLATFORM_MAX_PATH]; Format(p1, sizeof(p1), "materials/%s.vmt", head); DBG("FDL add: %s", p1); AddFileToDownloadsTable(p1);
                    char p2[PLATFORM_MAX_PATH]; Format(p2, sizeof(p2), "materials/%s.vtf", head); DBG("FDL add: %s", p2); AddFileToDownloadsTable(p2);
                }
                if (hit[0] != '\0') {
                    char p1[PLATFORM_MAX_PATH]; Format(p1, sizeof(p1), "materials/%s.vmt", hit);  DBG("FDL add: %s", p1); AddFileToDownloadsTable(p1);
                    char p2[PLATFORM_MAX_PATH]; Format(p2, sizeof(p2), "materials/%s.vtf", hit);  DBG("FDL add: %s", p2); AddFileToDownloadsTable(p2);
                }
                if (kill[0] != '\0') {
                    char p1[PLATFORM_MAX_PATH]; Format(p1, sizeof(p1), "materials/%s.vmt", kill); DBG("FDL add: %s", p1); AddFileToDownloadsTable(p1);
                    char p2[PLATFORM_MAX_PATH]; Format(p2, sizeof(p2), "materials/%s.vtf", kill); DBG("FDL add: %s", p2); AddFileToDownloadsTable(p2);
                }
            }
            else
            {
                if (head[0] != '\0') { DBG("FDL skip(builtin): materials/%s.vmt", head); DBG("FDL skip(builtin): materials/%s.vtf", head); }
                if (hit[0]  != '\0') { DBG("FDL skip(builtin): materials/%s.vmt", hit ); DBG("FDL skip(builtin): materials/%s.vtf", hit ); }
                if (kill[0] != '\0') { DBG("FDL skip(builtin): materials/%s.vmt", kill); DBG("FDL skip(builtin): materials/%s.vtf", kill); }
            }
        } while (KvGotoNextKey(kv));
    }
    CloseHandle(kv);

    LogMessage("[hitsound] 已加载 %d 套图标覆盖主题（0=禁用）。", g_OvCount);
}

// ========================================================
// DB Connect callback
// ========================================================
static void StartDBConnect()
{
    if (!GetConVarBool(cv_db_enable)) return;
    if (g_hDB != INVALID_HANDLE || g_DBConnecting) return;

    char confName[32];
    GetConVarString(cv_db_conf, confName, sizeof(confName));
    TrimString(confName);

    if (!SQL_CheckConfig(confName))
    {
        LogError("[hitsound] databases.cfg 缺少 '%s' 配置。", confName);
        return;
    }

    g_DBConnecting = true;

    char error[256];
    g_hDB = SQL_Connect(confName, false, error, sizeof(error));
    g_DBConnecting = false;

    if (g_hDB == INVALID_HANDLE)
    {
        LogError("[hitsound] 数据库连接失败: %s", error);
        return;
    }

    if (!SQL_SetCharset(g_hDB, "utf8mb4"))
        LogError("[hitsound] 设置数据库字符集 utf8mb4 失败。");

    LogMessage("[hitsound] 数据库连接成功。");
}

// ========================================================
// Persistence: DB + Fallback
// ========================================================
public void OnClientPutInServer(int client)
{
    if (IsFakeClient(client)) return;

    ResetPendingSoundFeedback(client);
    ResetClientOverlayState(client, false);
    g_IsVictimDeadPlayer[client] = false;
    g_PrefsRevision[client]++;

    // 最近套装（仅内存）
    g_SndSuite[client] = 0;
    g_IcSuite [client] = (GetConVarBool(cv_overlay_default_enable) && g_OvCount >= 1) ? 1 : 0;

    // 七个表现字段默认
    g_SndHead[client] = 0;
    g_SndHit [client] = 0;
    g_SndKill[client] = 0;
    g_SndHeadKill[client] = 0;

    if (g_IcSuite[client] >= 1) {
        g_IcHead[client] = g_IcSuite[client];
        g_IcHit [client] = g_IcSuite[client];
        g_IcKill[client] = g_IcSuite[client];
    } else {
        g_IcHead[client] = g_IcHit[client] = g_IcKill[client] = 0;
    }

    g_SndSpecialOnly[client] = false;
    g_IcSpecialOnly [client] = false;
    g_SndStackMode [client] = 0;
    g_HasLegacyHeadKillPref[client] = false;
    KV_LoadExtraPrefs(client);

    g_PrefsLoaded[client] = false;
    g_PrefsDirty [client] = false;
    g_DBLoadInFlight[client] = false;
    g_DBSavePending[client] = false;
    g_DBSaveInFlight[client] = false;
    TryLoadPlayerPrefs(client);
}

public void OnClientAuthorized(int client, const char[] auth)
{
    if (client <= 0 || client > MaxClients || IsFakeClient(client)) return;
    if (!IsClientInGame(client)) return;
    if (g_PrefsLoaded[client]) return;

    if (GetConVarBool(cv_db_enable))
        TryLoadPlayerPrefs(client);
}

public void OnClientPostAdminCheck(int client)
{
    if (client <= 0 || client > MaxClients || IsFakeClient(client)) return;
    if (!g_PrefsLoaded[client]) TryLoadPlayerPrefs(client);
}

public void OnClientDisconnect(int client)
{
    if (IsFakeClient(client)) return;

    if (GetConVarBool(cv_db_enable) && g_hDB != INVALID_HANDLE)
    {
        if (g_PrefsDirty[client] || g_DBSavePending[client])
        {
            DB_SavePlayerPrefs(client);
        }
    }
    else
    {
        if (g_PrefsDirty[client])
        {
            KV_SavePlayer(client);
        }
    }

    ResetPendingSoundFeedback(client);
    ResetClientOverlayState(client, false);
    if (g_ActiveOverlayCount == 0)
        StopOverlayCleanTimer();

    g_PrefsLoaded[client] = false;
    g_PrefsDirty [client] = false;
    g_DBLoadInFlight[client] = false;
    g_DBSavePending[client] = false;
    g_DBSaveInFlight[client] = false;
    g_HasLegacyHeadKillPref[client] = false;
    g_PrefsRevision[client]++;
}

static void TryLoadPlayerPrefs(int client)
{
    if (client <= 0 || client > MaxClients) return;
    if (!IsClientInGame(client) || IsFakeClient(client)) return;
    if (g_PrefsLoaded[client]) return;
    if (g_DBLoadInFlight[client]) return;

    char storageUid[128];
    if (!GetClientAuthId(client, AuthId_Engine, storageUid, sizeof(storageUid), true) || storageUid[0] == '\0')
        return;

    if (!GetConVarBool(cv_db_enable))
    {
        KV_LoadPlayer(client);
        g_PrefsLoaded[client] = true;
        g_PrefsDirty [client] = false;
        return;
    }

    if (g_hDB == INVALID_HANDLE)
    {
        StartDBConnect();
        if (g_DBLoadInFlight[client]) return;
        if (g_hDB == INVALID_HANDLE)
        {
            KV_LoadPlayer(client);
            g_PrefsLoaded[client] = true;
            g_PrefsDirty [client] = false;
            return;
        }
    }

    char sid[64];
    if (!GetClientAuthId(client, AuthId_Steam2, sid, sizeof(sid), true) || sid[0] == '\0')
    {
        // 等待 OnClientAuthorized / OnClientPostAdminCheck，避免用空身份创建 KV 节并跳过 DB。
        return;
    }

    // OnClientPutInServer 可能早于认证完成，此处用已就绪身份补读迁移键。
    KV_LoadExtraPrefs(client);

    if (KV_HasPendingDBSave(client))
    {
        KV_LoadPlayer(client);
        g_PrefsLoaded[client] = true;
        g_PrefsDirty [client] = true;
        g_DBSavePending[client] = true;
        DB_SavePlayerPrefs(client);
        return;
    }

    DB_RequestLoadPlayer(client, sid);
}

// 主动为一个玩家发起 DB 读取
public void DB_RequestLoadPlayer(int client, const char[] sid)
{
    char table[64];
    GetDBTableName(table, sizeof(table));

    char q[512];
    SQL_FormatQuery(g_hDB, q, sizeof(q),
        "SELECT \
           hitsound_head, hitsound_hit, hitsound_kill, \
           hiticon_head,  hiticon_hit,  hiticon_kill, \
           hitsound_si_only, hiticon_si_only, \
           hitsound_stack_mode, hitsound_headkill \
         FROM `%!s` \
         WHERE steamid='%s' \
         LIMIT 1;",
        table, sid);

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteCell(g_PrefsRevision[client]);
    g_DBLoadInFlight[client] = true;
    SQL_TQuery(g_hDB, SQL_OnLoadPrefs, q, pack);
}

// 为所有在线玩家重新加载偏好（插件重载 / 执行模式 cfg 后调用）
public void ReloadAllPlayersPrefs()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i))
            continue;

        CancelClientMenu(i, true);

        // 兼容插件晚加载：在新 DB 列首次回写前先取得旧 KV 个人偏好。
        KV_LoadExtraPrefs(i);

        if (GetConVarBool(cv_db_enable) && g_hDB != INVALID_HANDLE)
        {
            if (g_DBSavePending[i] || g_PrefsDirty[i])
            {
                DB_SavePlayerPrefs(i);
            }
            else if (g_DBLoadInFlight[i])
            {
                continue;
            }
            else
            {
                g_PrefsLoaded[i] = false;
                g_DBLoadInFlight[i] = false;
                TryLoadPlayerPrefs(i);
            }
        }
        else
        {
            g_PrefsLoaded[i] = false;
            TryLoadPlayerPrefs(i);
            if (!GetConVarBool(cv_db_enable) && g_PrefsLoaded[i])
            {
                g_DBSavePending[i] = false;
                g_DBSaveInFlight[i] = false;
                KV_SetDBPendingFlag(i, false);
            }
        }
    }
}

public void SQL_OnLoadPrefs(Handle owner, Handle hndl, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();
    int userid = pack.ReadCell();
    int loadRevision = pack.ReadCell();
    delete pack;

    int client = GetClientOfUserId(userid);
    if (client <= 0 || !IsClientInGame(client)) return;

    g_DBLoadInFlight[client] = false;

    if (loadRevision != g_PrefsRevision[client] || g_DBSavePending[client] || g_PrefsDirty[client])
    {
        g_PrefsLoaded[client] = true;
        if (GetConVarBool(cv_db_enable) && g_hDB != INVALID_HANDLE)
            DB_SavePlayerPrefs(client);
        return;
    }

    if (hndl == INVALID_HANDLE || error[0] != '\0')
    {
        LogError("[hitsound] 加载玩家配置失败: %s", error);
        KV_LoadPlayer(client);
        g_PrefsLoaded[client] = true;
        g_PrefsDirty [client] = false;
        KV_SavePlayer(client);
        return;
    }

    if (SQL_GetRowCount(hndl) > 0 && SQL_FetchRow(hndl))
    {
        int hs_head = SafeFetchInt(hndl, 0);
        int hs_hit  = SafeFetchInt(hndl, 1);
        int hs_kill = SafeFetchInt(hndl, 2);
        int ic_head = SafeFetchInt(hndl, 3);
        int ic_hit  = SafeFetchInt(hndl, 4);
        int ic_kill = SafeFetchInt(hndl, 5);
        int snd_si_only = SafeFetchInt(hndl, 6);
        int ic_si_only  = SafeFetchInt(hndl, 7);
        bool migrateStackMode = SQL_IsFieldNull(hndl, 8);
        bool migrateHeadKill = SQL_IsFieldNull(hndl, 9);
        int stackMode = migrateStackMode ? g_SndStackMode[client] : SafeFetchInt(hndl, 8);
        int headKillSet;
        if (!migrateHeadKill)
        {
            headKillSet = SafeFetchInt(hndl, 9);
        }
        else if (g_HasLegacyHeadKillPref[client])
        {
            headKillSet = g_SndHeadKill[client];
        }
        else
        {
            // 旧版本默认沿用爆头来源；只有该来源确有专用音时才保存非零值。
            headKillSet = SoundSetHasConfiguredPath(hs_head, SOUND_CHOICE_HEADSHOT_KILL) ? hs_head : 0;
        }
        if (stackMode < 0 || stackMode > 2) stackMode = 0;
        ClampSoundChoice(headKillSet);

        ClampSoundChoice(hs_head); ClampSoundChoice(hs_hit); ClampSoundChoice(hs_kill);
        ClampSetIc (ic_head); ClampSetIc (ic_hit); ClampSetIc (ic_kill);

        g_SndHead[client] = hs_head;
        g_SndHit [client] = hs_hit;
        g_SndKill[client] = hs_kill;

        g_IcHead [client] = ic_head;
        g_IcHit  [client] = ic_hit;
        g_IcKill [client] = ic_kill;

        g_SndSpecialOnly[client] = (snd_si_only != 0);
        g_IcSpecialOnly [client] = (ic_si_only != 0);
        g_SndStackMode [client] = stackMode;
        g_SndHeadKill[client] = headKillSet;

        bool normalized = NormalizePlayerSelections(client);

        int matchingPreset = FindMatchingSoundPreset(client);
        if (matchingPreset > 0) g_SndSuite[client] = matchingPreset;
        if (g_IcHead[client]>0 && g_IcHead[client]==g_IcHit[client] && g_IcHead[client]==g_IcKill[client])
            g_IcSuite[client] = g_IcHead[client];

        g_PrefsLoaded[client] = true;
        g_PrefsDirty [client] = false;
        KV_SavePlayer(client);

        // NULL 表示列刚迁移：保留旧 KV 偏好并回写数据库。
        if (migrateStackMode || migrateHeadKill || normalized)
        {
            g_PrefsDirty[client] = true;
            g_DBSavePending[client] = true;
            KV_SetDBPendingFlag(client, true);
            DB_SavePlayerPrefs(client);
        }
    }
    else
    {
        // 无 DB 行时导入旧 KV（若存在），并建立一份完整 DB 快照。
        KV_LoadPlayer(client);
        NormalizePlayerSelections(client);
        g_PrefsLoaded[client] = true;
        g_PrefsDirty [client] = true;
        g_DBSavePending[client] = true;
        KV_SavePlayer(client);
        KV_SetDBPendingFlag(client, true);
        DB_SavePlayerPrefs(client);
    }
}

void DB_SavePlayerPrefs(int client)
{
    if (!IsValidClient(client) || IsFakeClient(client) || !g_PrefsLoaded[client]) return;

    if (g_hDB == INVALID_HANDLE)
    {
        g_DBSavePending[client] = true;
        g_PrefsDirty[client] = true;
        KV_SetDBPendingFlag(client, true);
        return;
    }

    // 每个玩家只允许一条 UPSERT 在途；后续点击由回调合并成最新快照。
    if (g_DBSaveInFlight[client]) return;

    char sid[64];
    if (!GetClientAuthId(client, AuthId_Steam2, sid, sizeof(sid), true) || sid[0] == '\0')
    {
        g_DBSavePending[client] = true;
        g_PrefsDirty[client] = true;
        KV_SetDBPendingFlag(client, true);
        return;
    }
    char table[64]; GetDBTableName(table, sizeof(table));

    int hs_head = g_SndHead[client], hs_hit = g_SndHit[client], hs_kill = g_SndKill[client];
    int ic_head = g_IcHead [client], ic_hit = g_IcHit [client], ic_kill = g_IcKill[client];
    int snd_si_only = g_SndSpecialOnly[client] ? 1 : 0;
    int ic_si_only  = g_IcSpecialOnly [client] ? 1 : 0;
    int stack_mode  = g_SndStackMode [client];
    int headkill_set = g_SndHeadKill[client];

    char q[1536];
    SQL_FormatQuery(g_hDB, q, sizeof(q),
        "INSERT INTO `%!s` ( \
            steamid, hitsound_head, hitsound_hit, hitsound_kill, \
            hiticon_head, hiticon_hit, hiticon_kill, \
            hitsound_si_only, hiticon_si_only, \
            hitsound_stack_mode, hitsound_headkill \
        ) \
        VALUES ('%s', %d, %d, %d, %d, %d, %d, %d, %d, %d, %d) \
        ON DUPLICATE KEY UPDATE \
            hitsound_head=VALUES(hitsound_head), \
            hitsound_hit =VALUES(hitsound_hit), \
            hitsound_kill=VALUES(hitsound_kill), \
            hiticon_head =VALUES(hiticon_head), \
            hiticon_hit  =VALUES(hiticon_hit), \
            hiticon_kill =VALUES(hiticon_kill), \
            hitsound_si_only=VALUES(hitsound_si_only), \
            hiticon_si_only =VALUES(hiticon_si_only), \
            hitsound_stack_mode=VALUES(hitsound_stack_mode), \
            hitsound_headkill=VALUES(hitsound_headkill);",
        table, sid, hs_head, hs_hit, hs_kill, ic_head, ic_hit, ic_kill,
        snd_si_only, ic_si_only, stack_mode, headkill_set);

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteCell(g_PrefsRevision[client]);
    g_DBSaveInFlight[client] = true;
    SQL_TQuery(g_hDB, SQL_OnSavePrefs, q, pack);
}

public void SQL_OnSavePrefs(Handle owner, Handle hndl, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();
    int userid = pack.ReadCell();
    int saveRevision = pack.ReadCell();
    delete pack;

    int client = GetClientOfUserId(userid);

    if (client > 0 && IsClientInGame(client))
        g_DBSaveInFlight[client] = false;

    if (hndl == INVALID_HANDLE || error[0] != '\0')
    {
        if (client > 0 && IsClientInGame(client))
        {
            g_PrefsDirty[client] = true;
            g_DBSavePending[client] = true;
            KV_SavePlayer(client);
            KV_SetDBPendingFlag(client, true);
        }

        LogError("[hitsound] 保存玩家配置失败: %s", error);
        return;
    }

    if (client <= 0 || !IsClientInGame(client)) return;

    if (saveRevision == g_PrefsRevision[client])
    {
        g_PrefsDirty[client] = false;
        g_DBSavePending[client] = false;
        KV_SetDBPendingFlag(client, false);
    }
    else if (GetConVarBool(cv_db_enable) && g_hDB != INVALID_HANDLE)
    {
        DB_SavePlayerPrefs(client);
    }
}

// KeyValues fallback
void KV_SavePlayer(int client)
{
    char uid[128] = "";
    if (!GetClientAuthId(client, AuthId_Engine, uid, sizeof(uid), true) || uid[0] == '\0')
        return;

    KvJumpToKey(g_SoundStore, uid, true);

    KvSetNum(g_SoundStore, "SndSuite", g_SndSuite[client]);
    KvSetNum(g_SoundStore, "IcSuite",  g_IcSuite[client]);

    KvSetNum(g_SoundStore, "SndHead", g_SndHead[client]);
    KvSetNum(g_SoundStore, "SndHit",  g_SndHit[client]);
    KvSetNum(g_SoundStore, "SndKill", g_SndKill[client]);

    KvSetNum(g_SoundStore, "IcHead",  g_IcHead[client]);
    KvSetNum(g_SoundStore, "IcHit",   g_IcHit[client]);
    KvSetNum(g_SoundStore, "IcKill",  g_IcKill[client]);

    KvSetNum(g_SoundStore, "SndSpecialOnly", g_SndSpecialOnly[client] ? 1 : 0);
    KvSetNum(g_SoundStore, "IcSpecialOnly",  g_IcSpecialOnly [client] ? 1 : 0);
    KvSetNum(g_SoundStore, "SndStackMode", g_SndStackMode[client]);
    KvSetNum(g_SoundStore, "SndHeadKillSet", g_SndHeadKill[client]);
    KvSetNum(g_SoundStore, "SndHeadKill", g_SndHeadKill[client] != 0 ? 1 : 0); // 兼容旧版回滚

    KvGoBack(g_SoundStore);
    KvRewind(g_SoundStore);
    KeyValuesToFile(g_SoundStore, g_SavePath);
}

void KV_LoadExtraPrefs(int client)
{
    char uid[128] = "";
    g_HasLegacyHeadKillPref[client] = false;
    if (!GetClientAuthId(client, AuthId_Engine, uid, sizeof(uid), true) || uid[0] == '\0')
        return;

    if (KvJumpToKey(g_SoundStore, uid, false))
    {
        int sndSuite = KvGetNum(g_SoundStore, "SndSuite", -1);
        int icSuite = KvGetNum(g_SoundStore, "IcSuite", -1);
        if (sndSuite >= 0)
        {
            ClampSoundPreset(sndSuite);
            g_SndSuite[client] = sndSuite;
        }
        if (icSuite >= 0)
        {
            ClampSetIc(icSuite);
            g_IcSuite[client] = icSuite;
        }

        int mode = KvGetNum(g_SoundStore, "SndStackMode", 0);
        if (mode < 0 || mode > 2) mode = 0;
        g_SndStackMode[client] = mode;

        int headKillSet = KvGetNum(g_SoundStore, "SndHeadKillSet", PREF_VALUE_MISSING);
        if (headKillSet != PREF_VALUE_MISSING)
        {
            g_HasLegacyHeadKillPref[client] = true;
        }
        else
        {
            int legacyEnabled = KvGetNum(g_SoundStore, "SndHeadKill", -1);
            if (legacyEnabled >= 0)
            {
                g_HasLegacyHeadKillPref[client] = true;
                headKillSet = legacyEnabled != 0
                    ? KvGetNum(g_SoundStore, "SndHead", KvGetNum(g_SoundStore, "SndSuite", 0))
                    : 0;
            }
        }
        if (g_HasLegacyHeadKillPref[client])
        {
            ClampSoundChoice(headKillSet);
            g_SndHeadKill[client] = headKillSet;
        }
        KvGoBack(g_SoundStore);
    }
    KvRewind(g_SoundStore);
}

void KV_LoadPlayer(int client)
{
    char uid[128] = "";
    if (!GetClientAuthId(client, AuthId_Engine, uid, sizeof(uid), true) || uid[0] == '\0')
        return;

    if (!KvJumpToKey(g_SoundStore, uid, false))
    {
        KvRewind(g_SoundStore);
        NormalizePlayerSelections(client);
        return;
    }

    g_SndSuite[client] = KvGetNum(g_SoundStore, "SndSuite", 0);
    int storedIcSuite = KvGetNum(g_SoundStore, "IcSuite", -1);
    bool hasIcSuite = storedIcSuite >= 0;
    g_IcSuite[client] = hasIcSuite
        ? storedIcSuite
        : ((GetConVarBool(cv_overlay_default_enable) && g_OvCount >= 1) ? 1 : 0);

    int sndHead = KvGetNum(g_SoundStore, "SndHead", PREF_VALUE_MISSING);
    int sndHit  = KvGetNum(g_SoundStore, "SndHit",  PREF_VALUE_MISSING);
    int sndKill = KvGetNum(g_SoundStore, "SndKill", PREF_VALUE_MISSING);
    bool hasSoundFields = sndHead != PREF_VALUE_MISSING || sndHit != PREF_VALUE_MISSING || sndKill != PREF_VALUE_MISSING;
    g_SndHead[client] = sndHead != PREF_VALUE_MISSING ? sndHead : 0;
    g_SndHit [client] = sndHit  != PREF_VALUE_MISSING ? sndHit  : 0;
    g_SndKill[client] = sndKill != PREF_VALUE_MISSING ? sndKill : 0;

    int icHead = KvGetNum(g_SoundStore, "IcHead", -1);
    int icHit  = KvGetNum(g_SoundStore, "IcHit",  -1);
    int icKill = KvGetNum(g_SoundStore, "IcKill", -1);
    bool hasIconFields = icHead >= 0 || icHit >= 0 || icKill >= 0;
    g_IcHead[client] = icHead >= 0 ? icHead : 0;
    g_IcHit [client] = icHit  >= 0 ? icHit  : 0;
    g_IcKill[client] = icKill >= 0 ? icKill : 0;

    g_SndSpecialOnly[client] = (KvGetNum(g_SoundStore, "SndSpecialOnly", 0) != 0);
    g_IcSpecialOnly [client] = (KvGetNum(g_SoundStore, "IcSpecialOnly",  0) != 0);

    // 兼容旧 KV 键：仅当新三项键都不存在时读取旧 Snd；显式 0 必须保留为关闭。
    if (!hasSoundFields) {
        int old = KvGetNum(g_SoundStore, "Snd", 0);
        if (old>0 && old<=g_SetCount) ApplySoundPreset(client, old);
    }

    int stackMode = KvGetNum(g_SoundStore, "SndStackMode", 0);
    if (stackMode < 0 || stackMode > 2) stackMode = 0;
    g_SndStackMode[client] = stackMode;

    int headKillSet = KvGetNum(g_SoundStore, "SndHeadKillSet", PREF_VALUE_MISSING);
    if (headKillSet == PREF_VALUE_MISSING)
    {
        int legacyEnabled = KvGetNum(g_SoundStore, "SndHeadKill", -1);
        if (legacyEnabled == 0)
            headKillSet = 0;
        else
            headKillSet = SoundSetHasConfiguredPath(g_SndHead[client], SOUND_CHOICE_HEADSHOT_KILL) ? g_SndHead[client] : 0;
    }
    ClampSoundChoice(headKillSet);
    g_SndHeadKill[client] = headKillSet;
    // 兼容旧 KV 键：仅当新三项键都不存在时读取旧 IcSuite/Overlay。
    if (!hasIconFields) {
        if (!hasIcSuite) {
            int oldOv = KvGetNum(g_SoundStore, "Overlay", -1);
            if (oldOv >= 0) {
                ClampSetIc(oldOv);
                g_IcSuite[client] = oldOv;
            }
        }

        if (g_IcSuite[client]>=1) {
            g_IcHead[client]=g_IcHit[client]=g_IcKill[client]=g_IcSuite[client];
        }
    }

    NormalizePlayerSelections(client);
    int matchingPreset = FindMatchingSoundPreset(client);
    if (matchingPreset > 0) g_SndSuite[client] = matchingPreset;

    KvGoBack(g_SoundStore);
    KvRewind(g_SoundStore);
}

// ========================================================
// Events
// ========================================================
public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(GetEventInt(event, "userid"));
    if (client > 0 && client <= MaxClients)
        g_IsVictimDeadPlayer[client] = false;
}

public Action Event_PlayerIncap(Handle event, const char[] name, bool dontBroadcast)
{
    int victim = GetClientOfUserId(GetEventInt(event, "userid"));
    if (IsValidClient(victim) && GetClientTeam(victim) == 3 && GetEntProp(victim, Prop_Send, "m_zombieClass") == 8)
        g_IsVictimDeadPlayer[victim] = true;
    return Plugin_Continue;
}

public Action Event_TankSpawn(Handle event, const char[] name, bool dontBroadcast)
{
    int tank = GetClientOfUserId(GetEventInt(event, "userid"));
    if (IsValidClient(tank))
        g_IsVictimDeadPlayer[tank] = false;
    return Plugin_Continue;
}

public Action Event_PlayerDeath(Handle event, const char[] name, bool dontBroadcast)
{
    if (!GetConVarBool(cv_enable)) return Plugin_Continue;

    int victim     = GetClientOfUserId(GetEventInt(event, "userid"));
    int attacker   = GetClientOfUserId(GetEventInt(event, "attacker"));
    bool headshot  = GetEventBool(event, "headshot");
    int  damagetype= GetEventInt(event, "type");

    if (damagetype & DMG_DIRECT) return Plugin_Changed;
    if (GetConVarInt(cv_blast) == 0 && (damagetype & DMG_BLAST)) return Plugin_Changed;

    if (IsValidClient(victim) && GetClientTeam(victim) == 3 &&
        IsValidClient(attacker) && GetClientTeam(attacker) == 2 && !IsFakeClient(attacker))
    {
        bool specialTarget = IsSpecialInfectedClient(victim);

        // 图标（按项）
        if (GetConVarInt(cv_pic_enable) == 1 && ShouldShowIconFeedback(attacker, specialTarget))
        {
            int setId = headshot ? g_IcHead[attacker] : g_IcKill[attacker];
            if (setId > 0) ShowOverlayBySet(attacker, setId, headshot ? 0 : 2);
        }

        // 音效（按项）：致死只在这里播一声
        if (GetConVarInt(cv_sound_enable) == 1 && ShouldPlaySoundFeedback(attacker, specialTarget))
        {
            char s[PLATFORM_MAX_PATH];
            int setId;
            if (GetKillSoundSample(attacker, headshot, s, sizeof(s), setId))
            {
                QueueSoundFeedback(attacker, setId, s, headshot ? SOUND_FEEDBACK_HEADSHOT_KILL : SOUND_FEEDBACK_KILL);
            }
        }
    }

    return Plugin_Continue;
}

public Action Event_PlayerHurt(Handle event, const char[] name, bool dontBroadcast)
{
    if (!GetConVarBool(cv_enable)) return Plugin_Continue;

    int victim     = GetClientOfUserId(GetEventInt(event, "userid"));
    int attacker   = GetClientOfUserId(GetEventInt(event, "attacker"));
    int health     = GetEventInt(event, "health");
    int damagetype = GetEventInt(event, "type");
    bool headshot  = (GetEventInt(event, "hitgroup") == 1);

    if (damagetype & DMG_DIRECT) return Plugin_Changed;
    if (GetConVarInt(cv_blast) == 0 && (damagetype & DMG_BLAST)) return Plugin_Changed;

    if (IsValidClient(victim) && IsValidClient(attacker) && !IsFakeClient(attacker)
        && GetClientTeam(attacker) == 2 && GetClientTeam(victim) == 3)
    {
        bool specialTarget = IsSpecialInfectedClient(victim);
        if (health <= 0)
            g_IsVictimDeadPlayer[victim] = true;

        if (!g_IsVictimDeadPlayer[victim])
        {
            // 图标：爆头/命中（致死帧走击杀覆盖图）
            if (GetConVarInt(cv_pic_enable) == 1 && ShouldShowIconFeedback(attacker, specialTarget))
            {
                int setId = headshot ? g_IcHead[attacker] : g_IcHit[attacker];
                if (setId > 0) ShowOverlayBySet(attacker, setId, headshot ? 0 : 1);
            }

            // 音效：爆头/命中。致死由死亡事件播一声；火/燃烧弹过滤保持不变
            if (GetConVarInt(cv_sound_enable) == 1 && ShouldPlaySoundFeedback(attacker, specialTarget))
            {
                char weapon[64];
                GetEventString(event, "weapon", weapon, sizeof(weapon));
                if (!StrEqual(weapon, "entityflame", false) && !StrEqual(weapon, "inferno", false))
                {
                    char s2[PLATFORM_MAX_PATH];
                    int choice = headshot ? g_SndHead[attacker] : g_SndHit[attacker];
                    if (choice != 0 && GetSoundPathByChoice(choice, headshot ? SOUND_CHOICE_HEADSHOT : SOUND_CHOICE_HIT, s2, sizeof(s2)))
                        QueueSoundFeedback(attacker, choice, s2, headshot ? SOUND_FEEDBACK_HEADSHOT : SOUND_FEEDBACK_HIT);
                }
            }
        }
    }
    return Plugin_Changed;
}

public Action Event_InfectedDeath(Handle event, const char[] name, bool dontBroadcast)
{
    if (!GetConVarBool(cv_enable)) return Plugin_Continue;

    int attacker   = GetClientOfUserId(GetEventInt(event, "attacker"));
    bool headshot  = GetEventBool(event, "headshot");
    bool blast     = GetEventBool(event, "blast");
    int  weaponID  = GetEventInt(event, "weapon_id");

    if (weaponID == 0) return Plugin_Changed;
    if (GetConVarInt(cv_blast) == 0 && blast) return Plugin_Changed;

    if (IsValidClient(attacker) && GetClientTeam(attacker) == 2 && !IsFakeClient(attacker))
    {
        bool specialTarget = false;

        // 图标：击杀/爆头
        if (GetConVarInt(cv_pic_enable) == 1 && ShouldShowIconFeedback(attacker, specialTarget))
        {
            int setId = headshot ? g_IcHead[attacker] : g_IcKill[attacker];
            if (setId > 0) ShowOverlayBySet(attacker, setId, headshot ? 0 : 2);
        }

        // 音效：击杀/爆头
        if (GetConVarInt(cv_sound_enable) == 1 && ShouldPlaySoundFeedback(attacker, specialTarget))
        {
            char s[PLATFORM_MAX_PATH];
            int setId;
            if (GetKillSoundSample(attacker, headshot, s, sizeof(s), setId))
            {
                QueueSoundFeedback(attacker, setId, s, headshot ? SOUND_FEEDBACK_HEADSHOT_KILL : SOUND_FEEDBACK_KILL);
            }
        }
    }
    return Plugin_Continue;
}

public Action Event_InfectedHurt(Handle event, const char[] name, bool dontBroadcast)
{
    if (!GetConVarBool(cv_enable)) return Plugin_Continue;

    int victim     = GetEventInt(event, "entityid");
    int attacker   = GetClientOfUserId(GetEventInt(event, "attacker"));
    if (victim <= MaxClients || !IsValidEntity(victim)) return Plugin_Continue;

    int hp         = GetEntProp(victim, Prop_Data, "m_iHealth");
    int amount     = GetEventInt(event, "amount");
    int damagetype = GetEventInt(event, "type");
    bool headshot  = (GetEventInt(event, "hitgroup") == 1);

    if (damagetype & DMG_DIRECT) return Plugin_Changed;
    if (GetConVarInt(cv_blast) == 0 && (damagetype & DMG_BLAST)) return Plugin_Changed;

    if (IsValidClient(attacker) && !IsFakeClient(attacker) && GetClientTeam(attacker) == 2)
    {
        bool specialTarget = false;
        // infected_hurt 是扣血前事件，必须用本次伤害推算致死帧。
        bool dead = (hp - amount <= 0);

        if (!dead)
        {
            // 图标：爆头/命中
            if (GetConVarInt(cv_pic_enable) == 1 && ShouldShowIconFeedback(attacker, specialTarget))
            {
                int setId = headshot ? g_IcHead[attacker] : g_IcHit[attacker];
                if (setId > 0) ShowOverlayBySet(attacker, setId, headshot ? 0 : 1);
            }

            // 音效：爆头/命中。致死由死亡事件播一声
            if (GetConVarInt(cv_sound_enable) == 1 && ShouldPlaySoundFeedback(attacker, specialTarget))
            {
                char s2[PLATFORM_MAX_PATH];
                int choice = headshot ? g_SndHead[attacker] : g_SndHit[attacker];
                if (choice != 0 && GetSoundPathByChoice(choice, headshot ? SOUND_CHOICE_HEADSHOT : SOUND_CHOICE_HIT, s2, sizeof(s2)))
                    QueueSoundFeedback(attacker, choice, s2, headshot ? SOUND_FEEDBACK_HEADSHOT : SOUND_FEEDBACK_HIT);
            }
        }
    }
    return Plugin_Changed;
}

public void Event_RoundStart(Handle event, const char[] name, bool dontBroadcast)
{
    ResetAllOverlayState(true);
    for (int client = 1; client <= MaxClients; client++)
    {
        ResetPendingSoundFeedback(client);
        g_IsVictimDeadPlayer[client] = false;
    }
}

// ========================================================
// Shared overlay clean timer
// ========================================================
public Action Timer_CleanOverlays(Handle timer)
{
    if (timer != g_hOverlayCleanTimer)
        return Plugin_Stop;

    float now = GetEngineTime();
    for (int client = 1; client <= MaxClients; client++)
    {
        if (!g_OverlayActive[client] || now < g_OverlayExpiresAt[client])
            continue;

        ResetClientOverlayState(client, true);
    }

    if (g_ActiveOverlayCount == 0)
    {
        g_hOverlayCleanTimer = INVALID_HANDLE;
        return Plugin_Stop;
    }

    return Plugin_Continue;
}

// ========================================================
// Map start: rebuild downloads + precache all
// ========================================================
public void OnMapStart()
{
    DBG("OnMapStart: rebuild downloads table (soundSets=%d, sounds=%d, iconSets=%d)", g_SetCount, g_SoundCount, g_OvCount);
    LoadHitSoundSets();
    LoadHitSoundCatalog();
    LoadHitIconSets();
    PrecacheAllAssets();
}

static void PrecacheAllAssets()
{
    // ---- Sounds ----
    char s[PLATFORM_MAX_PATH], soundName[64];
    for (int i = 0; i < g_SoundCount; i++)
    {
        int soundId = GetArrayCell(g_SoundIds, i);
        GetArrayString(g_SoundNames, i, soundName, sizeof(soundName));
        GetArrayString(g_SoundPaths, i, s, sizeof(s));
        if (s[0] && !PrecacheSound(s, true))
            LogError("[hitsound] 无法预缓存公共音效 S%02d '%s': %s", soundId, soundName, s);
    }

    // ---- Overlays (materials) ----
    char b[PLATFORM_MAX_PATH], vmt[PLATFORM_MAX_PATH], vtf[PLATFORM_MAX_PATH];
    for (int j = 0; j < g_OvCount; j++)
    {
        GetArrayString(g_OvHead, j, b, sizeof(b));
        if (b[0]) {
            Format(vmt, sizeof(vmt), "%s.vmt", b); PrecacheDecal(vmt, true);
            Format(vtf, sizeof(vtf), "%s.vtf", b); PrecacheDecal(vtf, true);
        }

        GetArrayString(g_OvHit, j, b, sizeof(b));
        if (b[0]) {
            Format(vmt, sizeof(vmt), "%s.vmt", b); PrecacheDecal(vmt, true);
            Format(vtf, sizeof(vtf), "%s.vtf", b); PrecacheDecal(vtf, true);
        }

        GetArrayString(g_OvKill, j, b, sizeof(b));
        if (b[0]) {
            Format(vmt, sizeof(vmt), "%s.vmt", b); PrecacheDecal(vmt, true);
            Format(vtf, sizeof(vtf), "%s.vtf", b); PrecacheDecal(vtf, true);
        }
    }

    DBG("PrecacheAllAssets done: soundSets=%d, sounds=%d, iconSets=%d", g_SetCount, g_SoundCount, g_OvCount);
}

// ========================================================
// Commands & Menus
// ========================================================

public Action Cmd_ReloadAll(int client, int args)
{
    ReloadAllPlayersPrefs();
    if (client > 0)
        ReplyToCommand(client, "%t", "L4D2Hitsound_ReloadRequested");
    return Plugin_Handled;
}

static bool EnsurePlayerPrefsReady(int client, bool notify = true)
{
    if (!IsValidClient(client) || IsFakeClient(client)) return false;
    if (g_PrefsLoaded[client]) return true;

    TryLoadPlayerPrefs(client);
    if (g_PrefsLoaded[client]) return true;

    if (notify) PrintToChat(client, "%t", "L4D2Hitsound_PreferencesLoading");
    return false;
}

static void FormatMenuSetValue(int setId, int maxCount, char[] buffer, int maxlen)
{
    if (setId > 0 && setId <= maxCount)
    {
        Format(buffer, maxlen, "#%d", setId);
        return;
    }

    strcopy(buffer, maxlen, "关");
}

static int GetCatalogIdForChoice(int choice, SoundChoiceType which)
{
    if (choice < 0)
        return FindSoundCatalogIndexById(-choice) >= 0 ? -choice : 0;

    char sample[PLATFORM_MAX_PATH];
    if (choice > 0 && GetSoundPathByChoice(choice, which, sample, sizeof(sample)))
        return FindSoundCatalogIdByPath(sample);
    return 0;
}

static void FormatSoundMenuValue(int choice, SoundChoiceType which, char[] buffer, int maxlen)
{
    int soundId = GetCatalogIdForChoice(choice, which);
    if (soundId > 0)
    {
        Format(buffer, maxlen, "S%02d", soundId);
        return;
    }

    if (choice > 0)
    {
        Format(buffer, maxlen, "#%d", choice);
        return;
    }

    strcopy(buffer, maxlen, which == SOUND_CHOICE_HEADSHOT_KILL ? "跟随" : "关");
}

static void FormatSoundSource(int choice, SoundChoiceType which, char[] buffer, int maxlen)
{
    if (choice == 0)
    {
        strcopy(buffer, maxlen, which == SOUND_CHOICE_HEADSHOT_KILL ? "跟随普通爆头音" : "关闭");
        return;
    }

    int soundId = GetCatalogIdForChoice(choice, which);
    if (soundId > 0)
    {
        char name[64];
        GetSoundCatalogName(soundId, name, sizeof(name));
        Format(buffer, maxlen, "S%02d %s", soundId, name);
        return;
    }

    Format(buffer, maxlen, "无效来源(%d)", choice);
}

static void FormatPresetMember(int setId, SoundChoiceType which, char[] buffer, int maxlen)
{
    char sample[PLATFORM_MAX_PATH];
    if (!GetSoundPath_BySet(setId, which, sample, sizeof(sample)))
    {
        strcopy(buffer, maxlen, which == SOUND_CHOICE_HEADSHOT_KILL ? "随头" : "关");
        return;
    }

    int soundId = FindSoundCatalogIdByPath(sample);
    if (soundId > 0) Format(buffer, maxlen, "S%02d", soundId);
    else strcopy(buffer, maxlen, "缺失");
}

static void BuildSoundPresetSummary(int setId, char[] buffer, int maxlen)
{
    char head[12], hit[12], kill[12], headKill[12];
    FormatPresetMember(setId, SOUND_CHOICE_HEADSHOT, head, sizeof(head));
    FormatPresetMember(setId, SOUND_CHOICE_HIT, hit, sizeof(hit));
    FormatPresetMember(setId, SOUND_CHOICE_KILL, kill, sizeof(kill));
    FormatPresetMember(setId, SOUND_CHOICE_HEADSHOT_KILL, headKill, sizeof(headKill));
    Format(buffer, maxlen, "头:%s 中:%s 杀:%s 爆杀:%s", head, hit, kill, headKill);
}

static void GetSoundChoiceName(SoundChoiceType which, char[] buffer, int maxlen)
{
    if (which == SOUND_CHOICE_HEADSHOT) strcopy(buffer, maxlen, "爆头音");
    else if (which == SOUND_CHOICE_HIT) strcopy(buffer, maxlen, "命中音");
    else if (which == SOUND_CHOICE_KILL) strcopy(buffer, maxlen, "击杀音");
    else strcopy(buffer, maxlen, "爆头击杀音");
}

public Action Cmd_MenuMain(int client, int args)
{
    if (!IsValidClient(client) || IsFakeClient(client))
    {
        if (client == 0) ReplyToCommand(client, "[hitsound] sm_snd 只能由游戏内玩家使用。");
        return Plugin_Handled;
    }
    if (!EnsurePlayerPrefsReady(client)) return Plugin_Handled;

    Handle menu = CreateMenu(MenuHandler_Main);
    char title[256];

    char sndHead[8], sndHit[8], sndKill[8], sndHeadKill[8];
    char icHead[8],  icHit[8],  icKill[8];
    char sndScope[16], icScope[16];

    FormatSoundMenuValue(g_SndHead[client], SOUND_CHOICE_HEADSHOT, sndHead, sizeof(sndHead));
    FormatSoundMenuValue(g_SndHit [client], SOUND_CHOICE_HIT, sndHit, sizeof(sndHit));
    FormatSoundMenuValue(g_SndKill[client], SOUND_CHOICE_KILL, sndKill, sizeof(sndKill));
    FormatSoundMenuValue(g_SndHeadKill[client], SOUND_CHOICE_HEADSHOT_KILL, sndHeadKill, sizeof(sndHeadKill));

    FormatMenuSetValue(g_IcHead[client], g_OvCount, icHead, sizeof(icHead));
    FormatMenuSetValue(g_IcHit [client], g_OvCount, icHit,  sizeof(icHit ));
    FormatMenuSetValue(g_IcKill[client], g_OvCount, icKill, sizeof(icKill));

    strcopy(sndScope, sizeof(sndScope), g_SndSpecialOnly[client] ? "仅特感" : "全部");
    strcopy(icScope,  sizeof(icScope),  g_IcSpecialOnly [client] ? "仅特感" : "全部");

    Format(title, sizeof(title),
        "命中反馈设置\n音效(爆头/命中/击杀/爆头击杀): %s/%s/%s/%s [%s]\n图标(爆头/命中/击杀): %s/%s/%s [%s]",
        sndHead, sndHit, sndKill, sndHeadKill, sndScope, icHead, icHit, icKill, icScope);
    SetMenuTitle(menu, title);

    // 玩家：按套装设置
    AddMenuItem(menu, "sound_sets", "音效预设");
    AddMenuItem(menu, "icon_sets",  "图标套装（玩家）");

    // 特定开关/选择（非管理员也可用）
    AddMenuItem(menu, "snd_toggle_each", "单项音效选择（可试听）");
    AddMenuItem(menu, "ico_toggle_each", "特定图标开关（命中/击杀/爆头）");

    char stackLabel[160];
    char modeName[16];
    if (g_SndStackMode[client] == 1)      strcopy(modeName, sizeof(modeName), "强制叠加");
    else if (g_SndStackMode[client] == 2) strcopy(modeName, sizeof(modeName), "强制合并");
    else                                  strcopy(modeName, sizeof(modeName), "跟随声音");
    Format(stackLabel, sizeof(stackLabel), "音效播放模式：%s（点击切换）", modeName);
    AddMenuItem(menu, "snd_stack_mode", stackLabel);
    AddMenuItem(menu, "snd_special_only", g_SndSpecialOnly[client] ? "音效范围：仅特感/Tank" : "音效范围：全部感染者");
    AddMenuItem(menu, "ico_special_only", g_IcSpecialOnly [client] ? "图标范围：仅特感/Tank" : "图标范围：全部感染者");

    // 音效单项已对所有玩家开放；管理员额外保留图标来源选择。
    if (CheckCommandAccess(client, "hitsound_admin", ADMFLAG_GENERIC, true)) {
        AddMenuItem(menu, "ico_set_hit",      "击中图标单独设置 [管理员专用]");
        AddMenuItem(menu, "ico_set_kill",     "击杀图标单独设置 [管理员专用]");
        AddMenuItem(menu, "ico_set_headshot", "爆头图标单独设置 [管理员专用]");
    }

    SetMenuExitButton(menu, true);
    DisplayMenu(menu, client, MENU_TIME_FOREVER);
    return Plugin_Handled;
}

public int MenuHandler_Main(Handle menu, MenuAction action, int client, int item)
{
    if (action == MenuAction_End) { CloseHandle(menu); }

    if (action == MenuAction_Select)
    {
        if (!EnsurePlayerPrefsReady(client)) return 0;
        char info[32]; GetMenuItem(menu, item, info, sizeof(info));

        if (StrEqual(info, "sound_sets"))
        {
            OpenSoundSetMenu_Player(client);
            return 0;
        }
        if (StrEqual(info, "icon_sets"))
        {
            OpenIconSetMenu_Player(client);
            return 0;
        }
        if (StrEqual(info, "snd_toggle_each"))
        {
            OpenToggleEachMenu(client, true);
            return 0;
        }
        if (StrEqual(info, "ico_toggle_each"))
        {
            OpenToggleEachMenu(client, false);
            return 0;
        }
        if (StrEqual(info, "snd_stack_mode"))
        {
            g_SndStackMode[client] = (g_SndStackMode[client] + 1) % 3;
            switch (g_SndStackMode[client])
            {
                case 1:  PrintToChat(client, "%t", "L4D2Hitsound_StackModeStack");
                case 2:  PrintToChat(client, "%t", "L4D2Hitsound_StackModeMerge");
                default: PrintToChat(client, "%t", "L4D2Hitsound_StackModeFollow");
            }
            MarkDirtyAndSave(client);
            Cmd_MenuMain(client, 0);
            return 0;
        }
        if (StrEqual(info, "snd_special_only"))
        {
            g_SndSpecialOnly[client] = !g_SndSpecialOnly[client];
            if (g_SndSpecialOnly[client]) PrintToChat(client, "%t", "L4D2Hitsound_SoundEffectRangeSpecial");
            else PrintToChat(client, "%t", "L4D2Hitsound_SoundEffectRangeAll");
            MarkDirtyAndSave(client);
            Cmd_MenuMain(client, 0);
            return 0;
        }
        if (StrEqual(info, "ico_special_only"))
        {
            g_IcSpecialOnly[client] = !g_IcSpecialOnly[client];
            if (g_IcSpecialOnly[client]) PrintToChat(client, "%t", "L4D2Hitsound_IconRangeSpecial");
            else PrintToChat(client, "%t", "L4D2Hitsound_IconRangeAll");
            MarkDirtyAndSave(client);
            Cmd_MenuMain(client, 0);
            return 0;
        }

        // 管理员图标来源设置
        if (StrEqual(info, "ico_set_hit"))       { OpenAdminIconSelectMenu(client, 1); return 0; }
        if (StrEqual(info, "ico_set_kill"))      { OpenAdminIconSelectMenu(client, 2); return 0; }
        if (StrEqual(info, "ico_set_headshot"))  { OpenAdminIconSelectMenu(client, 0); return 0; }
    }
    return 0;
}

// ------------------ 子菜单：音效预设 ------------------
static void OpenSoundSetMenu_Player(int client)
{
    Handle m = CreateMenu(MenuHandler_SndSets_Player);
    char title[128];
    char cur[64] = "自定义";
    int matchingPreset = FindMatchingSoundPreset(client);
    if (matchingPreset > 0)
        GetArrayString(g_SetNames, matchingPreset - 1, cur, sizeof(cur));
    else if (g_SndHead[client] == 0 && g_SndHit[client] == 0 && g_SndKill[client] == 0 && g_SndHeadKill[client] == 0)
        strcopy(cur, sizeof(cur), "关闭");
    Format(title, sizeof(title), "选择音效预设（当前: %s）", cur);
    SetMenuTitle(m, title);

    AddMenuItem(m, "snd_0", "0 - 关闭四项音效");
    for (int i = 1; i <= g_SetCount; i++)
    {
        char key[16], name[64], summary[96], label[192];
        Format(key, sizeof(key), "snd_%d", i);
        GetArrayString(g_SetNames, i-1, name, sizeof(name));
        BuildSoundPresetSummary(i, summary, sizeof(summary));
        Format(label, sizeof(label), "%d - %s [%s]", i, name, summary);
        AddMenuItem(m, key, label);
    }

    SetMenuExitBackButton(m, true);
    DisplayMenu(m, client, MENU_TIME_FOREVER);
}

public int MenuHandler_SndSets_Player(Handle menu, MenuAction action, int client, int item)
{
    if (action == MenuAction_End) { CloseHandle(menu); }
    if (action == MenuAction_Cancel && item == MenuCancel_ExitBack)
    {
        Cmd_MenuMain(client, 0);
        return 0;
    }
    if (action == MenuAction_Select)
    {
        if (!EnsurePlayerPrefsReady(client)) return 0;
        char info[16]; GetMenuItem(menu, item, info, sizeof(info));
        if (StrContains(info, "snd_", false) == 0)
        {
            ReplaceString(info, sizeof(info), "snd_", "");
            int val = StringToInt(info); // 0..g_SetCount
            if (val < 0) val = 0;
            if (val > g_SetCount) val = 0;

            ApplySoundPreset(client, val);

            PrintToChat(client, "%t", "L4D2Hitsound_HitsoundSoundEffectPackageFour", val);
            if (ApplySoundSetPersonalDefaults(client, val))
                PrintToChat(client, "%t", "L4D2Hitsound_SetPlaybackPreset");
            MarkDirtyAndSave(client);

            OpenSoundSetMenu_Player(client);
        }
    }
    return 0;
}

static void OpenSoundChoiceMenu(int client, SoundChoiceType which)
{
    Handle m = CreateMenu(MenuHandler_SoundChoice);
    char current[96], choiceName[32];
    FormatSoundSource(GetSoundChoice(client, which), which, current, sizeof(current));
    GetSoundChoiceName(which, choiceName, sizeof(choiceName));

    char title[160];
    Format(title, sizeof(title), "选择%s（当前: %s）", choiceName, current);
    SetMenuTitle(m, title);

    char zeroKey[32];
    Format(zeroKey, sizeof(zeroKey), "sndpick_%d_0", which);
    AddMenuItem(m, zeroKey, which == SOUND_CHOICE_HEADSHOT_KILL ? "0 - 跟随普通爆头音" : "0 - 关闭此音效");

    for (int i = 0; i < g_SoundCount; i++)
    {
        char key[32], name[64], label[160];
        int soundId = GetArrayCell(g_SoundIds, i);
        Format(key, sizeof(key), "sndpick_%d_-%d", which, soundId);
        GetArrayString(g_SoundNames, i, name, sizeof(name));
        Format(label, sizeof(label), "S%02d - %s", soundId, name);
        AddMenuItem(m, key, label);
    }

    SetMenuExitBackButton(m, true);
    DisplayMenu(m, client, MENU_TIME_FOREVER);
}

static void PrintSoundChoiceChanged(int client, SoundChoiceType which, int choice)
{
    char code[16];
    FormatSoundMenuValue(choice, which, code, sizeof(code));

    if (which == SOUND_CHOICE_HEADSHOT)
    {
        if (choice != 0) PrintToChat(client, "%t", "L4D2Hitsound_HeadshotSoundEffectSet", code);
        else PrintToChat(client, "%t", "L4D2Hitsound_HeadshotSoundEffectTurnedOff");
    }
    else if (which == SOUND_CHOICE_HIT)
    {
        if (choice != 0) PrintToChat(client, "%t", "L4D2Hitsound_HitSoundEffectSet", code);
        else PrintToChat(client, "%t", "L4D2Hitsound_HitSoundEffectTurnedOff");
    }
    else if (which == SOUND_CHOICE_KILL)
    {
        if (choice != 0) PrintToChat(client, "%t", "L4D2Hitsound_KillSoundEffectSet", code);
        else PrintToChat(client, "%t", "L4D2Hitsound_KillSoundEffectTurnedOff");
    }
    else if (choice == 0)
        PrintToChat(client, "%t", "L4D2Hitsound_HeadKillSoundFollow");
    else
        PrintToChat(client, "%t", "L4D2Hitsound_HeadKillSoundSet", code);
}

static void PreviewSoundChoice(int client, SoundChoiceType which, int choice)
{
    if (!GetConVarBool(cv_enable) || !GetConVarBool(cv_sound_enable)) return;

    if (which == SOUND_CHOICE_HEADSHOT_KILL && choice == 0)
    {
        choice = g_SndHead[client];
        which = SOUND_CHOICE_HEADSHOT;
    }
    if (choice == 0) return;

    char sample[PLATFORM_MAX_PATH];
    if (GetSoundPathByChoice(choice, which, sample, sizeof(sample)))
        EmitSoundToClient(client, sample, SOUND_FROM_PLAYER, SNDCHAN_AUTO, SNDLEVEL_NORMAL);
}

public int MenuHandler_SoundChoice(Handle menu, MenuAction action, int client, int item)
{
    if (action == MenuAction_End) { CloseHandle(menu); }
    if (action == MenuAction_Cancel && item == MenuCancel_ExitBack)
    {
        OpenToggleEachMenu(client, true);
        return 0;
    }
    if (action == MenuAction_Select)
    {
        if (!EnsurePlayerPrefsReady(client)) return 0;

        char info[32]; GetMenuItem(menu, item, info, sizeof(info));
        if (StrContains(info, "sndpick_", false) != 0) return 0;

        ReplaceString(info, sizeof(info), "sndpick_", "");
        char parts[2][8];
        if (ExplodeString(info, "_", parts, sizeof(parts), sizeof(parts[])) != 2) return 0;

        SoundChoiceType which = view_as<SoundChoiceType>(StringToInt(parts[0]));
        int choice = StringToInt(parts[1]);
        if (which < SOUND_CHOICE_HEADSHOT || which > SOUND_CHOICE_HEADSHOT_KILL) return 0;
        ClampSoundChoice(choice);
        if (choice > 0) choice = 0; // 公共菜单只接受 0 或负数公共ID。

        SetSoundChoice(client, which, choice);
        PrintSoundChoiceChanged(client, which, choice);
        MarkDirtyAndSave(client);
        PreviewSoundChoice(client, which, choice);
        OpenSoundChoiceMenu(client, which);
    }
    return 0;
}

// ------------------ 子菜单：图标套装（玩家） ------------------
static void OpenIconSetMenu_Player(int client)
{
    Handle m = CreateMenu(MenuHandler_OvSets_Player);
    char title[128];
    char cur[64] = "关闭";
    if (g_IcHead[client]>0 && g_IcHead[client]==g_IcHit[client] && g_IcHead[client]==g_IcKill[client] && g_IcHead[client] <= g_OvCount)
        GetArrayString(g_OvNames, g_IcHead[client]-1, cur, sizeof(cur));
    Format(title, sizeof(title), "选择图标套装（玩家，当前: %s）", cur);
    SetMenuTitle(m, title);

    AddMenuItem(m, "ov_0", "0 - 关闭三项图标");
    for (int i = 1; i <= g_OvCount; i++)
    {
        char key[16], name[64], label[96];
        Format(key, sizeof(key), "ov_%d", i);
        GetArrayString(g_OvNames, i-1, name, sizeof(name));
        Format(label, sizeof(label), "%d - %s", i, name);
        AddMenuItem(m, key, label);
    }

    SetMenuExitBackButton(m, true);
    DisplayMenu(m, client, MENU_TIME_FOREVER);
}

public int MenuHandler_OvSets_Player(Handle menu, MenuAction action, int client, int item)
{
    if (action == MenuAction_End) { CloseHandle(menu); }
    if (action == MenuAction_Cancel && item == MenuCancel_ExitBack)
    {
        Cmd_MenuMain(client, 0);
        return 0;
    }
    if (action == MenuAction_Select)
    {
        if (!EnsurePlayerPrefsReady(client)) return 0;
        char info[16]; GetMenuItem(menu, item, info, sizeof(info));
        if (StrContains(info, "ov_", false) == 0)
        {
            ReplaceString(info, sizeof(info), "ov_", "");
            int val = StringToInt(info); // 0..g_OvCount
            if (val < 0) val = 0;
            if (val > g_OvCount) val = 0;

            g_IcSuite[client] = val; // 记住最近套装
            g_IcHead[client] = g_IcHit[client] = g_IcKill[client] = val;

            char name[64] = "关闭";
            if (val >= 1 && val <= g_OvCount) GetArrayString(g_OvNames, val-1, name, sizeof(name));
            PrintToChat(client, "%t", "L4D2Hitsound_HitsoundIconSetThreeItems", val, name);

            MarkDirtyAndSave(client);
            OpenIconSetMenu_Player(client);
        }
    }
    return 0;
}

// ------------------ 子菜单：单项音效选择 / 图标开关 ------------------
static void OpenToggleEachMenu(int client, bool sound)
{
    Handle m = CreateMenu(MenuHandler_ToggleEach);
    SetMenuTitle(m, sound ? "单项音效选择" : "特定图标开关");

    if (sound)
    {
        char current[96], label[160];
        FormatSoundSource(g_SndHead[client], SOUND_CHOICE_HEADSHOT, current, sizeof(current));
        Format(label, sizeof(label), "爆头音：%s", current);
        AddMenuItem(m, "tgsnd_head", label);

        FormatSoundSource(g_SndHit[client], SOUND_CHOICE_HIT, current, sizeof(current));
        Format(label, sizeof(label), "命中音：%s", current);
        AddMenuItem(m, "tgsnd_hit", label);

        FormatSoundSource(g_SndKill[client], SOUND_CHOICE_KILL, current, sizeof(current));
        Format(label, sizeof(label), "击杀音：%s", current);
        AddMenuItem(m, "tgsnd_kill", label);

        FormatSoundSource(g_SndHeadKill[client], SOUND_CHOICE_HEADSHOT_KILL, current, sizeof(current));
        Format(label, sizeof(label), "爆头击杀音：%s", current);
        AddMenuItem(m, "tgsnd_headkill", label);
    }
    else
    {
        AddMenuItem(m, "tgico_hit",  "命中图标 开/关");
        AddMenuItem(m, "tgico_kill", "击杀图标 开/关");
        AddMenuItem(m, "tgico_head", "爆头图标 开/关");
    }

    SetMenuExitBackButton(m, true);
    DisplayMenu(m, client, MENU_TIME_FOREVER);
}

public int MenuHandler_ToggleEach(Handle menu, MenuAction action, int client, int item)
{
    if (action == MenuAction_End) { CloseHandle(menu); }
    if (action == MenuAction_Cancel && item == MenuCancel_ExitBack)
    {
        Cmd_MenuMain(client, 0);
        return 0;
    }
    if (action == MenuAction_Select)
    {
        if (!EnsurePlayerPrefsReady(client)) return 0;
        char info[32]; GetMenuItem(menu, item, info, sizeof(info));

        // 四类音效分别进入同一个去重公共音效库，可跨用途任选并试听。
        if (StrEqual(info, "tgsnd_hit"))
        {
            OpenSoundChoiceMenu(client, SOUND_CHOICE_HIT);
            return 0;
        }
        if (StrEqual(info, "tgsnd_kill"))
        {
            OpenSoundChoiceMenu(client, SOUND_CHOICE_KILL);
            return 0;
        }
        if (StrEqual(info, "tgsnd_head"))
        {
            OpenSoundChoiceMenu(client, SOUND_CHOICE_HEADSHOT);
            return 0;
        }
        if (StrEqual(info, "tgsnd_headkill"))
        {
            OpenSoundChoiceMenu(client, SOUND_CHOICE_HEADSHOT_KILL);
            return 0;
        }

        // 图标三项
        if (StrEqual(info, "tgico_hit"))
        {
            if (g_IcHit[client] == 0) {
                if (g_IcSuite[client] <= 0) { PrintToChat(client, "%t", "L4D2Hitsound_SelectSuitIconSuitPlayer"); }
                else { g_IcHit[client] = g_IcSuite[client]; PrintToChat(client, "%t", "L4D2Hitsound_HitIconTurnedSet", g_IcHit[client]); MarkDirtyAndSave(client); }
            } else {
                g_IcHit[client] = 0; PrintToChat(client, "%t", "L4D2Hitsound_HitIconClosed"); MarkDirtyAndSave(client);
            }
            OpenToggleEachMenu(client, false);
            return 0;
        }
        if (StrEqual(info, "tgico_kill"))
        {
            if (g_IcKill[client] == 0) {
                if (g_IcSuite[client] <= 0) { PrintToChat(client, "%t", "L4D2Hitsound_SelectSuitIconSuitPlayer"); }
                else { g_IcKill[client] = g_IcSuite[client]; PrintToChat(client, "%t", "L4D2Hitsound_KillIconTurnedSet", g_IcKill[client]); MarkDirtyAndSave(client); }
            } else {
                g_IcKill[client] = 0; PrintToChat(client, "%t", "L4D2Hitsound_KillIconClosed"); MarkDirtyAndSave(client);
            }
            OpenToggleEachMenu(client, false);
            return 0;
        }
        if (StrEqual(info, "tgico_head"))
        {
            if (g_IcHead[client] == 0) {
                if (g_IcSuite[client] <= 0) { PrintToChat(client, "%t", "L4D2Hitsound_SelectSuitIconSuitPlayer"); }
                else { g_IcHead[client] = g_IcSuite[client]; PrintToChat(client, "%t", "L4D2Hitsound_HeadshotIconTurnedSet", g_IcHead[client]); MarkDirtyAndSave(client); }
            } else {
                g_IcHead[client] = 0; PrintToChat(client, "%t", "L4D2Hitsound_HeadshotIconClosed"); MarkDirtyAndSave(client);
            }
            OpenToggleEachMenu(client, false);
            return 0;
        }
    }
    return 0;
}

// ------------------ 子菜单：管理员图标来源设置 ------------------
static void OpenAdminIconSelectMenu(int client, int which) // which: 0=head/1=hit/2=kill
{
    if (!CheckCommandAccess(client, "hitsound_admin", ADMFLAG_GENERIC, true)) {
        PrintToChat(client, "%t", "L4D2Hitsound_NotPermissionUseMenu");
        Cmd_MenuMain(client, 0);
        return;
    }

    Handle m = CreateMenu(MenuHandler_AdminIconPick);
    if (which==0) SetMenuTitle(m, "爆头图标：选择套装ID（含0=关闭）");
    if (which==1) SetMenuTitle(m, "命中图标：选择套装ID（含0=关闭）");
    if (which==2) SetMenuTitle(m, "击杀图标：选择套装ID（含0=关闭）");

    char zeroKey[32];
    Format(zeroKey, sizeof(zeroKey), "adm_ic_%d_0", which);
    AddMenuItem(m, zeroKey, "0 - 关闭此项");

    for (int i = 1; i <= g_OvCount; i++)
    {
        char key[32], name[64], label[96];
        Format(key, sizeof(key), "adm_ic_%d_%d", which, i);
        GetArrayString(g_OvNames, i-1, name, sizeof(name));
        Format(label, sizeof(label), "%d - %s", i, name);
        AddMenuItem(m, key, label);
    }

    SetMenuExitBackButton(m, true);
    DisplayMenu(m, client, MENU_TIME_FOREVER);
}

public int MenuHandler_AdminIconPick(Handle menu, MenuAction action, int client, int item)
{
    if (action == MenuAction_End) { CloseHandle(menu); }
    if (action == MenuAction_Cancel && item == MenuCancel_ExitBack)
    {
        Cmd_MenuMain(client, 0);
        return 0;
    }
    if (action == MenuAction_Select)
    {
        if (!EnsurePlayerPrefsReady(client)) return 0;
        char info[32]; GetMenuItem(menu, item, info, sizeof(info));

        if (StrContains(info, "adm_ic_", false) != 0) return 0;
        ReplaceString(info, sizeof(info), "adm_ic_", "");
        char parts[2][8];
        if (ExplodeString(info, "_", parts, sizeof(parts), sizeof(parts[])) != 2) return 0;

        int which = StringToInt(parts[0]);
        int setId = StringToInt(parts[1]);
        if (which < 0 || which > 2) return 0;
        ClampSetIc(setId);

        if (which==0) { g_IcHead[client]=setId; PrintToChat(client, "%t", "L4D2Hitsound_HeadshotIconSet", setId); }
        if (which==1) { g_IcHit [client]=setId; PrintToChat(client, "%t", "L4D2Hitsound_HitIconSet", setId); }
        if (which==2) { g_IcKill[client]=setId; PrintToChat(client, "%t", "L4D2Hitsound_KillIconSet", setId); }
        if (g_IcHead[client]>0 && g_IcHead[client]==g_IcHit[client] && g_IcHead[client]==g_IcKill[client]) g_IcSuite[client]=g_IcHead[client];

        MarkDirtyAndSave(client);
        OpenAdminIconSelectMenu(client, which);
    }
    return 0;
}
