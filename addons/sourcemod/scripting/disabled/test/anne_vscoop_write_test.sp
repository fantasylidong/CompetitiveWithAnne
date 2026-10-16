#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <left4dhooks>
#include <sourcescramble>

// Run the real production callbacks against owned memory, never the Director.
#define myinfo Production_Info
#define OnPluginStart Production_OnPluginStart
#define AskPluginLoad2 Production_AskPluginLoad2
#define L4D_GetPointer Test_GetPointer
#include "../../optional/AnneHappy/versus_coop_mode.sp"
#undef myinfo
#undef OnPluginStart
#undef AskPluginLoad2
#undef L4D_GetPointer

MemoryBlock g_TestMemory;

public Plugin myinfo = {
    name = "Anne versus coop field-width regression", author = "Anne", version = "1.0"
};

Address Test_GetPointer(PointerType type)
{
    #pragma unused type
    return g_TestMemory.Address;
}

public void OnPluginStart()
{
    RegServerCmd("sm_vscoop_write_test", Command_Test);
}

void SeedMemory()
{
    for (int offset = 0; offset < g_TestMemory.Size; offset++)
        g_TestMemory.StoreToOffset(offset, 0xA5, NumberType_Int8);
}

bool CheckMemory(int first, int second)
{
    for (int offset = 0; offset < g_TestMemory.Size; offset++)
    {
        int expected = offset == m_bIsFirstRoundFinished ? first
            : (offset == m_bIsSecondRoundFinished ? second : 0xA5);
        int actual = g_TestMemory.LoadFromOffset(offset, NumberType_Int8);
        if (actual != expected)
        {
            PrintToServer("[VsCoopWriteTest] FAIL offset=%d expected=%02x actual=%02x", offset, expected, actual);
            return false;
        }
    }
    return true;
}

Action Command_Test(int args)
{
    GameData gd = new GameData("versus_coop_mode");
    if (gd == null) return Plugin_Handled;
    GetOffsets(gd);
    delete gd;
    g_TestMemory = new MemoryBlock(m_bIsSecondRoundFinished + 16);
    int failed;
    for (int transition = 0; transition <= 1; transition++)
    {
        SeedMemory();
        g_bTransitionFired = transition != 0;
        DD_CDirectorVersusMode_RestartVsMode_Pre(Address_Null, null);
        if (!CheckMemory(transition, 0xA5)) failed++;
        // The engine may modify the second flag between the two callbacks.
        g_TestMemory.StoreToOffset(m_bIsSecondRoundFinished, 1, NumberType_Int8);
        DD_CDirectorVersusMode_RestartVsMode_Post(Address_Null, null);
        if (!CheckMemory(transition, transition ? 1 : 0) || g_bTransitionFired) failed++;
    }
    delete g_TestMemory;
    PrintToServer("[VsCoopWriteTest] %s cases=4 failures=%d; adjacent bytes checked",
        failed ? "FAIL" : "PASS", failed);
    return Plugin_Handled;
}
