#if defined _l4d2_scripted_hud_proxies_included
 #endinput
#endif
#define _l4d2_scripted_hud_proxies_included

// Left4SendProxy deduplicates array hooks by callback, so every slot needs unique
// function pointers. These wrappers only exist to give each element its own address.

#define HUD_PROXY_CALLBACKS(%1) \
public Action ProxyHUD%1Flags(const char[] prop, int &value, int element, int client) { return ProxyHUDFlags(value, %1, client); } \
public Action ProxyHUD%1String(const char[] prop, char[] value, int maxlength, int element, int client) { return ProxyHUDString(value, maxlength, %1, client); } \
public Action ProxyHUD%1PosX(const char[] prop, float &value, int element, int client) { return ProxyHUDPosX(value, %1, client); } \
public Action ProxyHUD%1PosY(const char[] prop, float &value, int element, int client) { return ProxyHUDPosY(value, %1, client); } \
public Action ProxyHUD%1Width(const char[] prop, float &value, int element, int client) { return ProxyHUDWidth(value, %1, client); } \
public Action ProxyHUD%1Height(const char[] prop, float &value, int element, int client) { return ProxyHUDHeight(value, %1, client); }

HUD_PROXY_CALLBACKS(0)
HUD_PROXY_CALLBACKS(1)
HUD_PROXY_CALLBACKS(2)
HUD_PROXY_CALLBACKS(3)
HUD_PROXY_CALLBACKS(4)
HUD_PROXY_CALLBACKS(5)
HUD_PROXY_CALLBACKS(6)
HUD_PROXY_CALLBACKS(7)
HUD_PROXY_CALLBACKS(8)
HUD_PROXY_CALLBACKS(9)
HUD_PROXY_CALLBACKS(10)
HUD_PROXY_CALLBACKS(11)
HUD_PROXY_CALLBACKS(12)
HUD_PROXY_CALLBACKS(13)
HUD_PROXY_CALLBACKS(14)

#define HOOK_HUD_SLOT(%1) \
    if (hud == %1) \
    { \
        if (!g_bHUDProxyHooked[%1][HUD_PROXY_FLAGS]) \
            g_bHUDProxyHooked[%1][HUD_PROXY_FLAGS] = SendProxy_HookGameRules("m_iScriptedHUDFlags", Prop_Int, ProxyHUD%1Flags, %1); \
        if (!g_bHUDProxyHooked[%1][HUD_PROXY_STRING]) \
            g_bHUDProxyHooked[%1][HUD_PROXY_STRING] = SendProxy_HookGameRules("m_szScriptedHUDStringSet", Prop_String, ProxyHUD%1String, %1); \
        if (!g_bHUDProxyHooked[%1][HUD_PROXY_POS_X]) \
            g_bHUDProxyHooked[%1][HUD_PROXY_POS_X] = SendProxy_HookGameRules("m_fScriptedHUDPosX", Prop_Float, ProxyHUD%1PosX, %1); \
        if (!g_bHUDProxyHooked[%1][HUD_PROXY_POS_Y]) \
            g_bHUDProxyHooked[%1][HUD_PROXY_POS_Y] = SendProxy_HookGameRules("m_fScriptedHUDPosY", Prop_Float, ProxyHUD%1PosY, %1); \
        if (!g_bHUDProxyHooked[%1][HUD_PROXY_WIDTH]) \
            g_bHUDProxyHooked[%1][HUD_PROXY_WIDTH] = SendProxy_HookGameRules("m_fScriptedHUDWidth", Prop_Float, ProxyHUD%1Width, %1); \
        if (!g_bHUDProxyHooked[%1][HUD_PROXY_HEIGHT]) \
            g_bHUDProxyHooked[%1][HUD_PROXY_HEIGHT] = SendProxy_HookGameRules("m_fScriptedHUDHeight", Prop_Float, ProxyHUD%1Height, %1); \
        return; \
    }

#define UNHOOK_HUD_SLOT(%1) \
    if (hud == %1) \
    { \
        if (g_bHUDProxyHooked[%1][HUD_PROXY_FLAGS]) SendProxy_UnhookGameRules("m_iScriptedHUDFlags", ProxyHUD%1Flags, %1); \
        if (g_bHUDProxyHooked[%1][HUD_PROXY_STRING]) SendProxy_UnhookGameRules("m_szScriptedHUDStringSet", ProxyHUD%1String, %1); \
        if (g_bHUDProxyHooked[%1][HUD_PROXY_POS_X]) SendProxy_UnhookGameRules("m_fScriptedHUDPosX", ProxyHUD%1PosX, %1); \
        if (g_bHUDProxyHooked[%1][HUD_PROXY_POS_Y]) SendProxy_UnhookGameRules("m_fScriptedHUDPosY", ProxyHUD%1PosY, %1); \
        if (g_bHUDProxyHooked[%1][HUD_PROXY_WIDTH]) SendProxy_UnhookGameRules("m_fScriptedHUDWidth", ProxyHUD%1Width, %1); \
        if (g_bHUDProxyHooked[%1][HUD_PROXY_HEIGHT]) SendProxy_UnhookGameRules("m_fScriptedHUDHeight", ProxyHUD%1Height, %1); \
        return; \
    }
