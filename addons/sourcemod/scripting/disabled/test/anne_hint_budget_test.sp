// 仅供空测试服：先卸载 l4d2_item_hint.smx，再加载本探针。
// 控制台：sm_anne_hint_budget_test。只创建少量实体，不连接数据库。
#define OnPluginStart Production_OnPluginStart
#define OnPluginEnd Production_OnPluginEnd
#include "../../extend/l4d2_item_hint.sp"
#undef OnPluginStart
#undef OnPluginEnd

bool htRunning;
bool htSavedRoundEnding;
Handle htStageTimer;
int htFailures;
int htRefs[7] = { INVALID_ENT_REFERENCE, ... };
int htResumeRef = INVALID_ENT_REFERENCE;
char htLogPath[PLATFORM_MAX_PATH];

public void OnPluginStart()
{
    Production_OnPluginStart();
    BuildPath(Path_SM, htLogPath, sizeof(htLogPath), "logs/anne_entity_regression.log");
    RegConsoleCmd("sm_anne_hint_budget_test", HintTestCommand);
}

public void OnPluginEnd()
{
    HintTestCleanup();
    Production_OnPluginEnd();
}

bool HintTestEmpty()
{
    for (int client = 1; client <= MaxClients; client++)
        if (IsClientConnected(client)) return false;
    return true;
}

void HintTestCheck(const char[] test, bool passed)
{
    if (!passed) htFailures++;
    PrintToServer("ANNE_ENTITY_REGRESSION hint %s %s", test, passed ? "PASS" : "FAIL");
    LogToFileEx(htLogPath, "ANNE_ENTITY_REGRESSION hint %s %s", test, passed ? "PASS" : "FAIL");
}

int HintTestUsed()
{
    int used;
    for (int entity = 0; entity < GetMaxEntities(); entity++)
        if (IsValidEdict(entity)) used++;
    return used;
}

int HintTestEntity(const char[] classname, const char[] name, int needed = 1)
{
    int entity = CreateHintEntity(classname, needed);
    if (!CheckIfEntityMax(entity)) return INVALID_ENT_REFERENCE;
    DispatchKeyValue(entity, "targetname", name);
    if (StrEqual(classname, CLASSNAME_ENV_SPRITE))
    {
        PrecacheModel("sprites/glow01.vmt", true);
        DispatchKeyValue(entity, "model", "sprites/glow01.vmt");
    }
    DispatchSpawn(entity);
    return EntIndexToEntRef(entity);
}

public Action HintTestCommand(int client, int args)
{
    if (client != 0 || !HintTestEmpty() || htRunning)
    {
        ReplyToCommand(client, "ANNE_ENTITY_REGRESSION hint REJECT console_only_empty_server_required");
        return Plugin_Handled;
    }
    htFailures = 0;
    HintTestCheck("active_round_prerequisite", !g_bRoundEnding);
    if (g_bRoundEnding) return Plugin_Handled;
    HintTestCheck("name_01", IsSpotMarkerName("l4d_mark_hint-01"));
    HintTestCheck("name_32", IsSpotMarkerName("l4d_mark_hint-32"));
    HintTestCheck("name_bare", !IsSpotMarkerName("l4d_mark_hint"));
    HintTestCheck("name_x", !IsSpotMarkerName("l4d_mark_hint-x"));
    HintTestCheck("name_extra", !IsSpotMarkerName("l4d_mark_hint-01-extra"));
    int used = HintTestUsed();
    if (used + 16 >= ENTITY_SAFE_LIMIT)
    {
        HintTestCheck("low_pressure_prerequisite", false);
        return Plugin_Handled;
    }
    htSavedRoundEnding = g_bRoundEnding;
    htRunning = true;
    int entity = CreateHintEntity(CLASSNAME_ENV_SPRITE, GetMaxEntities());
    HintTestCheck("pressure_rejected", entity == -1);
    HintTestCheck("pressure_no_allocation", HintTestUsed() == used);
    if (entity != -1) RemoveEntity(entity);

    // 虚拟预留量验证边界算术，不增加占用到 1800。
    entity = CreateHintEntity(CLASSNAME_INFO_TARGET, ENTITY_SAFE_LIMIT - HintTestUsed() + 1);
    HintTestCheck("budget_over_boundary", entity == -1);
    if (entity != -1) RemoveEntity(entity);
    entity = CreateHintEntity(CLASSNAME_INFO_TARGET, ENTITY_SAFE_LIMIT - HintTestUsed());
    HintTestCheck("budget_exact_boundary", entity > MaxClients && IsValidEntity(entity));
    if (entity != -1) RemoveEntity(entity);

    htRefs[0] = HintTestEntity(CLASSNAME_INFO_TARGET, "l4d_mark_hint-01", 2);
    htRefs[1] = HintTestEntity(CLASSNAME_ENV_SPRITE, "l4d_mark_hint-32");
    htRefs[2] = HintTestEntity(CLASSNAME_INFO_TARGET, "l4d_mark_hint");
    htRefs[3] = HintTestEntity(CLASSNAME_ENV_SPRITE, "l4d_mark_hint-x");
    htRefs[4] = HintTestEntity(CLASSNAME_INFO_TARGET, "l4d_mark_hint-01-extra");
    int pairBefore = HintTestUsed();
    htRefs[5] = HintTestEntity(CLASSNAME_INFO_TARGET, "anne_hint_budget_test_pair", 2);
    htRefs[6] = HintTestEntity(CLASSNAME_ENV_SPRITE, "anne_hint_budget_test_pair");
    bool allCreated = true;
    for (int i = 0; i < sizeof(htRefs); i++)
        if (EntRefToEntIndex(htRefs[i]) == INVALID_ENT_REFERENCE) allCreated = false;
    HintTestCheck("low_allocation", allCreated);
    HintTestCheck("two_entity_budget", EntRefToEntIndex(htRefs[5]) != INVALID_ENT_REFERENCE
        && EntRefToEntIndex(htRefs[6]) != INVALID_ENT_REFERENCE && HintTestUsed() == pairBefore + 2);
    RemoveAllSpotMark();
    // Kill 输入在引擎帧末才删除实体，不能在同批 RequestFrame 中断言。
    htStageTimer = CreateTimer(0.2, HintTestAfterCleanup, 0, TIMER_FLAG_NO_MAPCHANGE);
    return Plugin_Handled;
}

public Action HintTestAfterCleanup(Handle timer, any data)
{
    htStageTimer = null;
    if (!htRunning) return Plugin_Stop;
    bool empty = HintTestEmpty();
    HintTestCheck("stage_environment", empty);
    if (!empty)
    {
        HintTestCleanup();
        HintTestCheck("summary", false);
        return Plugin_Stop;
    }
    HintTestCheck("owned_target_removed", EntRefToEntIndex(htRefs[0]) == INVALID_ENT_REFERENCE);
    HintTestCheck("owned_sprite_removed", EntRefToEntIndex(htRefs[1]) == INVALID_ENT_REFERENCE);
    bool controlsAlive = true;
    for (int i = 2; i < sizeof(htRefs); i++)
        if (EntRefToEntIndex(htRefs[i]) == INVALID_ENT_REFERENCE) controlsAlive = false;
    HintTestCheck("controls_preserved", controlsAlive);
    Event_Round_End(null, "round_end", true);
    int before = HintTestUsed();
    int entity = CreateHintEntity(CLASSNAME_ENV_SPRITE);
    HintTestCheck("round_end_rejected", entity == -1);
    HintTestCheck("round_end_no_allocation", HintTestUsed() == before);
    if (entity != -1) RemoveEntity(entity);
    Event_RoundStart(null, "round_start", true);
    htResumeRef = HintTestEntity(CLASSNAME_INFO_TARGET, "anne_hint_budget_test_roundstart", 2);
    HintTestCheck("round_start_allocation", htResumeRef != INVALID_ENT_REFERENCE);
    HintTestCleanup();
    HintTestCheck("summary", htFailures == 0);
    return Plugin_Stop;
}

void HintTestCleanup()
{
    delete htStageTimer;
    for (int i = 0; i < sizeof(htRefs); i++)
    {
        int entity = EntRefToEntIndex(htRefs[i]);
        if (entity != INVALID_ENT_REFERENCE) RemoveEntity(entity);
        htRefs[i] = INVALID_ENT_REFERENCE;
    }
    int entity = EntRefToEntIndex(htResumeRef);
    if (entity != INVALID_ENT_REFERENCE) RemoveEntity(entity);
    htResumeRef = INVALID_ENT_REFERENCE;
    if (htRunning) g_bRoundEnding = htSavedRoundEnding;
    htRunning = false;
}
