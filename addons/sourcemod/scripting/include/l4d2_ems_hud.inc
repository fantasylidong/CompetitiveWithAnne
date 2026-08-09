#if defined _l4d2_ems_hud_included
 #endinput
#endif
#define _l4d2_ems_hud_included

// ====================================================================================================
// "L4D2 EMS HUD Functions" by "sorallll"
// Version: 1.0.8
// ====================================================================================================

#include <sdktools>

#define HUD_LEFT_TOP                   0
#define HUD_LEFT_BOT                   1
#define HUD_MID_TOP                    2
#define HUD_MID_BOT                    3
#define HUD_RIGHT_TOP                  4
#define HUD_RIGHT_BOT                  5
#define HUD_TICKER                     6
#define HUD_FAR_LEFT                   7
#define HUD_FAR_RIGHT                  8
#define HUD_MID_BOX                    9
#define HUD_SCORE_TITLE               10
#define HUD_SCORE_1                   11
#define HUD_SCORE_2                   12
#define HUD_SCORE_3                   13
#define HUD_SCORE_4                   14

#define MAX_SIZE_HUD                  15

#define HUD_FLAG_PRESTR               (1<<0)
#define HUD_FLAG_POSTSTR              (1<<1)
#define HUD_FLAG_BEEP                 (1<<2)
#define HUD_FLAG_BLINK                (1<<3)
#define HUD_FLAG_AS_TIME              (1<<4)
#define HUD_FLAG_COUNTDOWN_WARN       (1<<5)
#define HUD_FLAG_NOBG                 (1<<6)
#define HUD_FLAG_ALLOWNEGTIMER        (1<<7)
#define HUD_FLAG_ALIGN_LEFT           (1<<8)
#define HUD_FLAG_ALIGN_CENTER         (1<<9)
#define HUD_FLAG_ALIGN_RIGHT          (3<<8)
#define HUD_FLAG_TEAM_SURVIVORS       (1<<10)
#define HUD_FLAG_TEAM_INFECTED        (1<<11)
#define HUD_FLAG_TEAM_MASK            (3<<10)
#define HUD_FLAG_UNKNOWN1             (1<<12)
#define HUD_FLAG_TEXT                 (1<<13)
#define HUD_FLAG_NOTVISIBLE           (1<<14)

stock void EnableHUD()
{
    GameRules_SetProp("m_bChallengeModeActive", true, _, _, true);
}

stock void HUDSetLayout(int slot, int flags, const char[] dataval, any ...)
{
    static char str[128];
    VFormat(str, sizeof(str), dataval, 4);

	GameRules_SetProp("m_iScriptedHUDFlags", flags, _, slot, true);
    GameRules_SetPropString("m_szScriptedHUDStringSet", str, true, slot);
}

stock void HUDPlace(int slot, float x, float y, float width, float height)
{
    GameRules_SetPropFloat("m_fScriptedHUDPosX", x, slot, true);
    GameRules_SetPropFloat("m_fScriptedHUDPosY", y, slot, true);
    GameRules_SetPropFloat("m_fScriptedHUDWidth", width, slot, true);
    GameRules_SetPropFloat("m_fScriptedHUDHeight", height, slot, true);
}

stock void ResetHUD(int slot)
{
    GameRules_SetProp("m_iScriptedHUDFlags", HUD_FLAG_NOTVISIBLE, _, slot, true);
}

stock void RemoveHUD(int slot)
{
    GameRules_SetProp("m_iScriptedHUDInts", 0, _, slot, true);
    GameRules_SetPropFloat("m_fScriptedHUDFloats", 0.0, slot, true);
    GameRules_SetProp("m_iScriptedHUDFlags", HUD_FLAG_NOTVISIBLE, _, slot, true);
    GameRules_SetPropFloat("m_fScriptedHUDPosX", 0.0, slot, true);
    GameRules_SetPropFloat("m_fScriptedHUDPosY", 0.0, slot, true);
    GameRules_SetPropFloat("m_fScriptedHUDWidth", 0.0, slot, true);
    GameRules_SetPropFloat("m_fScriptedHUDHeight", 0.0, slot, true);
    GameRules_SetPropString("m_szScriptedHUDStringSet", "", true, slot);
}

stock bool HUDSlotIsUsed(int slot)
{
    return !(GameRules_GetProp("m_iScriptedHUDFlags", _, slot) & HUD_FLAG_NOTVISIBLE);
}

stock void RemoveAllHUD()
{
    for (int slot; slot < MAX_SIZE_HUD; slot++)
        RemoveHUD(slot);
}
