// 仅供空测试服：先卸载 l4d_random_beam_item.smx，再加载本探针。
// 控制台：sm_anne_beam_budget_test。包含同份玩法源码，不测试/连接生产数据库。
#define OnPluginStart Production_OnPluginStart
#define OnAllPluginsLoaded Production_OnAllPluginsLoaded
#define OnPluginEnd Production_OnPluginEnd
#include "../../extend/l4d_random_beam_item.sp"
#undef OnPluginStart
#undef OnAllPluginsLoaded
#undef OnPluginEnd

bool btRunning;
bool btSavedEnabled;
bool btSavedRoundEnding;
int btSavedLimit, btSavedPlayerLimit, btSavedDemand;
int btGroup = -1;
int btItems[2] = { INVALID_ENT_REFERENCE, ... };
int btFailures;
Handle btStageTimer;
char btLogPath[PLATFORM_MAX_PATH];

public void OnPluginStart()
{
    Production_OnPluginStart();
    BuildPath(Path_SM, btLogPath, sizeof(btLogPath), "logs/anne_entity_regression.log");
    RegConsoleCmd("sm_anne_beam_budget_test", BeamTestCommand);
}

public void OnAllPluginsLoaded()
{
    // 生产回调会建表，故探针仅初始化需求分支所需的真实 SendProxy。
    g_bSendProxy = LibraryExists(SENDPROXY_LIB);
    HookAllBeamSendProxies();
}

public void OnPluginEnd()
{
    BeamTestRestore();
    Production_OnPluginEnd();
}

bool BeamTestEmpty()
{
    for (int client = 1; client <= MaxClients; client++)
        if (IsClientConnected(client))
            return false;
    return true;
}

void BeamTestCheck(const char[] test, bool passed)
{
    if (!passed) btFailures++;
    PrintToServer("ANNE_ENTITY_REGRESSION beam %s %s", test, passed ? "PASS" : "FAIL");
    LogToFileEx(btLogPath, "ANNE_ENTITY_REGRESSION beam %s %s", test, passed ? "PASS" : "FAIL");
}

public Action BeamTestCommand(int client, int args)
{
    if (client != 0 || !BeamTestEmpty() || btRunning)
    {
        ReplyToCommand(client, "ANNE_ENTITY_REGRESSION beam REJECT console_only_empty_server_required");
        return Plugin_Handled;
    }
    btFailures = 0;
    int config[CONFIG_ARRAYSIZE];
    bool prerequisites = g_bL4D2 && g_bSendProxy && !g_bRoundEnding
        && CountBeamEdicts() + 32 < GetMaxEntities()
        && g_smClassnameConfig.GetArray("weapon_adrenaline", config, sizeof(config));
    if (prerequisites)
    {
        btGroup = config[CONFIG_GROUP];
        prerequisites = config[CONFIG_ENABLE] == 0 && config[CONFIG_PLAYER] != 0
            && btGroup >= 0 && btGroup < MAX_GROUPS;
    }
    BeamTestCheck("prerequisites", prerequisites);
    if (!prerequisites) return Plugin_Handled;

    btSavedEnabled = g_bCvar_Enabled;
    btSavedRoundEnding = g_bRoundEnding;
    btSavedLimit = g_iCvar_EdictLimit;
    btSavedPlayerLimit = g_iCvar_PlayerEdictLimit;
    btSavedDemand = g_iGroupDemand[btGroup];
    btRunning = true;
    g_bCvar_Enabled = true;
    g_iCvar_EdictLimit = GetMaxEntities() - 16;
    g_iCvar_PlayerEdictLimit = GetMaxEntities() - 16;
    g_iGroupDemand[btGroup] = 1; // 只模拟需求计数，不修改或保存玩家偏好。
    btItems[0] = BeamTestItem("weapon_pain_pills", "anne_beam_budget_test_pills");
    btItems[1] = BeamTestItem("weapon_adrenaline", "anne_beam_budget_test_adrenaline");
    BeamTestCheck("items_created", BeamTestItemsValid());
    if (!BeamTestItemsValid())
    {
        BeamTestRestore();
        return Plugin_Handled;
    }
    BeamTestCreate();
    RequestFrame(BeamTestStage, 1);
    return Plugin_Handled;
}

int BeamTestItem(const char[] classname, const char[] name)
{
    int entity = CreateEntityByName(classname);
    if (entity <= MaxClients) return INVALID_ENT_REFERENCE;
    if (entity >= MAXENTITIES)
    {
        RemoveEntity(entity);
        return INVALID_ENT_REFERENCE;
    }
    DispatchKeyValue(entity, "targetname", name);
    DispatchSpawn(entity);
    float pos[3] = { 0.0, 0.0, -4096.0 };
    TeleportEntity(entity, pos, NULL_VECTOR, NULL_VECTOR);
    return EntIndexToEntRef(entity);
}

bool BeamTestItemsValid()
{
    return EntRefToEntIndex(btItems[0]) != INVALID_ENT_REFERENCE
        && EntRefToEntIndex(btItems[1]) != INVALID_ENT_REFERENCE;
}

int BeamTestChild(int slot)
{
    int item = EntRefToEntIndex(btItems[slot]);
    return item == INVALID_ENT_REFERENCE ? INVALID_ENT_REFERENCE : EntRefToEntIndex(ge_iChildEntRef[item]);
}

void BeamTestCreate()
{
    OnNextFrame(btItems[0]);
    OnNextFrame(btItems[1]);
}

void BeamTestRemoveChildren()
{
    for (int slot = 0; slot < 2; slot++)
    {
        int beam = BeamTestChild(slot);
        if (beam != INVALID_ENT_REFERENCE) RemoveEntity(beam);
    }
}

public void BeamTestStage(any stage)
{
    if (!btRunning) return;
    if (!BeamTestEmpty() || !BeamTestItemsValid())
    {
        BeamTestCheck("stage_environment", false);
        BeamTestRestore();
        return;
    }
    switch (stage)
    {
        case 1:
        {
            int pills = BeamTestChild(0), adrenaline = BeamTestChild(1);
            BeamTestCheck("low_default", pills != INVALID_ENT_REFERENCE && ge_bBeamDefault[pills]);
            BeamTestCheck("low_demand", adrenaline != INVALID_ENT_REFERENCE && !ge_bBeamDefault[adrenaline]);
            // RemoveEntity 延迟至引擎帧末回收；等待期间禁止排队回调重建。
            g_bCvar_Enabled = false;
            BeamTestRemoveChildren();
            btStageTimer = CreateTimer(0.2, BeamTestAfterWait, 2, TIMER_FLAG_NO_MAPCHANGE);
        }
        case 2:
        {
            bool childrenGone = BeamTestChild(0) == INVALID_ENT_REFERENCE
                && BeamTestChild(1) == INVALID_ENT_REFERENCE;
            BeamTestCheck("pressure_children_cleared", childrenGone);
            if (!childrenGone)
            {
                BeamTestRestore();
                BeamTestCheck("summary", false);
                return;
            }
            int used = CountBeamEdicts();
            g_iCvar_EdictLimit = used + 2; // 三实体预算必须拒绝，毋须填满 edict。
            g_bCvar_Enabled = true;
            BeamTestCreate();
            BeamTestCheck("pressure_default", BeamTestChild(0) == INVALID_ENT_REFERENCE);
            BeamTestCheck("pressure_demand", BeamTestChild(1) == INVALID_ENT_REFERENCE);
            BeamTestCheck("pressure_no_allocation", CountBeamEdicts() == used);
            BeamTestCheck("pressure_retry_queued", g_hBudgetRetry != null);
            g_iCvar_EdictLimit = GetMaxEntities() - 16;
            // 让生产 2 秒重试实际执行，验证无需新生成物品也会恢复。
            btStageTimer = CreateTimer(2.2, BeamTestAfterWait, 3, TIMER_FLAG_NO_MAPCHANGE);
        }
        case 3:
        {
            BeamTestCheck("recovery_default", BeamTestChild(0) != INVALID_ENT_REFERENCE);
            BeamTestCheck("recovery_demand", BeamTestChild(1) != INVALID_ENT_REFERENCE);
            g_bCvar_Enabled = false;
            BeamTestRemoveChildren();
            BeamTestCreate();
            btStageTimer = CreateTimer(0.2, BeamTestAfterWait, 4, TIMER_FLAG_NO_MAPCHANGE);
        }
        case 4:
        {
            BeamTestCheck("disabled_nextframe", BeamTestChild(0) == INVALID_ENT_REFERENCE
                && BeamTestChild(1) == INVALID_ENT_REFERENCE);
            g_bCvar_Enabled = true;
            BeamTestCreate();
            Event_RoundEnd(null, "round_end", true);
            BeamTestCreate(); // 回合结束期间，排队的 next-frame 也不能重新创建。
            btStageTimer = CreateTimer(0.2, BeamTestAfterWait, 5, TIMER_FLAG_NO_MAPCHANGE);
        }
        case 5:
        {
            int alive;
            for (int i = 0; i < g_alPluginEntities.Length; i++)
                if (EntRefToEntIndex(g_alPluginEntities.Get(i)) != INVALID_ENT_REFERENCE) alive++;
            BeamTestCheck("round_end_cleanup", alive == 0 && BeamTestChild(0) == INVALID_ENT_REFERENCE
                && BeamTestChild(1) == INVALID_ENT_REFERENCE);
            BeamTestCheck("round_end_retry_cancelled", g_hBudgetRetry == null);
            BeamTestRestore();
            QueueBeamBudgetRetry(); // 模拟首个 round_start 前已经排队的旧代重试。
            Event_RoundStart(null, "round_start", true); // 正常递增 generation，不回退旧代。
            BeamTestCheck("round_start_old_retry_cancelled", g_hBudgetRetry == null);
            RequestFrame(BeamTestRoundRestored);
        }
    }
}

public void BeamTestRoundRestored(any data)
{
    BeamTestCheck("round_start_restored", !g_bRoundEnding);
    BeamTestCheck("summary", btFailures == 0);
}

public Action BeamTestAfterWait(Handle timer, any stage)
{
    btStageTimer = null;
    BeamTestStage(stage);
    return Plugin_Stop;
}

void BeamTestRestore()
{
    if (!btRunning) return;
    delete btStageTimer;
    BeamTestRemoveChildren();
    for (int slot = 0; slot < 2; slot++)
    {
        int entity = EntRefToEntIndex(btItems[slot]);
        if (entity != INVALID_ENT_REFERENCE) RemoveEntity(entity);
        btItems[slot] = INVALID_ENT_REFERENCE;
    }
    delete g_hBudgetRetry;
    g_bCvar_Enabled = btSavedEnabled;
    g_bRoundEnding = btSavedRoundEnding;
    g_iCvar_EdictLimit = btSavedLimit;
    g_iCvar_PlayerEdictLimit = btSavedPlayerLimit;
    g_iGroupDemand[btGroup] = btSavedDemand;
    btRunning = false;
}
