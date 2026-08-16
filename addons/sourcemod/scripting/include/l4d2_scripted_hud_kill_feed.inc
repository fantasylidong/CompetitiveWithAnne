#if defined _l4d2_scripted_hud_kill_feed_included
    #endinput
#endif
#define _l4d2_scripted_hud_kill_feed_included

// Integrated from [L4D2] CS Kill Hud 2.0h by Miuwiki and Harry.
// The feed remains in the EMS slots reserved by l4d2_scripted_hud.

#define KILL_FEED_BASE              HUD_KILL_SHARE_FIRST
#define KILL_FEED_MAX_LINES         7
#define KILL_FEED_LINE_SIZE         128
#define KILL_FEED_CLASS_INFECTED    "infected"
#define KILL_FEED_CLASS_WITCH       "witch"

static ConVar g_hCvar_KillFeedLines;
static ConVar g_hCvar_KillFeedNoticeTime;
static ConVar g_hCvar_KillFeedBlockMessage;
static ConVar g_hCvar_KillFeedX;
static ConVar g_hCvar_KillFeedY;
static ConVar g_hCvar_KillFeedWidth;
static ConVar g_hCvar_KillFeedHeight;
static ConVar g_hCvar_KillFeedTextAlign;
static ConVar g_hCvar_KillFeedTeam;
static ConVar g_hCvar_KillFeedBlink;
static ConVar g_hCvar_KillFeedBackground;

static bool g_bKillFeedBlockMessage;
static bool g_bKillFeedBlink;
static bool g_bKillFeedBackground;
static int g_iKillFeedLines;
static int g_iKillFeedTextAlign;
static int g_iKillFeedTeam;
static float g_fKillFeedNoticeTime;
static float g_fKillFeedX;
static float g_fKillFeedY;
static float g_fKillFeedWidth;
static float g_fKillFeedHeight;
static int g_iKillFeedFlags;
static float g_fKillFeedPos[HUD_SLOT_COUNT][4];

static StringMap g_smKillFeedWeapons;
static StringMap g_smKillFeedSpecialWeapons;
static StringMap g_smKillFeedIgnoreWallWeapons;
static ArrayList g_aKillFeed;
static Handle g_hKillFeedTimer;
static Cookie g_hKillFeedCookie;
static bool g_bClientKillFeed[MAXPLAYERS + 1];
static bool g_bClientHasKillFeedCookie[MAXPLAYERS + 1];
static int g_iClientKillFeedCookieRevision[MAXPLAYERS + 1];

static const char g_sKillFeedType[][] =
{
    "■■‖:::::::>",
    "/̵͇̿̿/’̿’̿ ̿ ̿̿ ̿̿ ̿̿",
    "⌐╤═─",
    "︻╦╦═─",
    "▄︻═══∶∷",
    "︻╦̵̵͇̿̿̿̿╤───",
    "☆BOMB☆",
    "__∫∫∫∫__",
    "▄︻╤■══一",
    "︻■■■■ ●",
    "(●｀・ω・)=Ｏ",
    "↼■╦══",
    "X_X",
    "*皿*彡",
    "→‖",
    "→⊙",
    "(ﾒﾟДﾟ)ﾒ彡",
    "☠",
    "<ʖ͡=::::::⊃",
    "⬇ X_X",
    "SYSTEM X_X",
    "→☠"
};

void KillFeed_Init()
{
    g_hCvar_KillFeedLines = CreateConVar("l4d2_scripted_hud_kill_feed_lines", "7", "Number of kill feed lines (1-7).", CVAR_FLAGS, true, 1.0, true, float(KILL_FEED_MAX_LINES));
    g_hCvar_KillFeedNoticeTime = CreateConVar("l4d2_scripted_hud_kill_feed_notice_time", "2.0", "Seconds between removing old kill feed lines.", CVAR_FLAGS, true, 1.0);
    g_hCvar_KillFeedBlockMessage = CreateConVar("l4d2_scripted_hud_kill_feed_disable_standard_message", "1", "Hide the standard death message for clients who enabled their personal kill feed; disabled clients still receive the original event.", CVAR_FLAGS, true, 0.0, true, 1.0);
    g_hCvar_KillFeedX = CreateConVar("l4d2_scripted_hud_kill_feed_x", "0.50", "Kill feed horizontal position.", CVAR_FLAGS, true, -1.0, true, 1.0);
    g_hCvar_KillFeedY = CreateConVar("l4d2_scripted_hud_kill_feed_y", "0.06", "Kill feed vertical position.", CVAR_FLAGS, true, -1.0, true, 1.0);
    g_hCvar_KillFeedWidth = CreateConVar("l4d2_scripted_hud_kill_feed_width", "0.49", "Kill feed text width.", CVAR_FLAGS, true, 0.0, true, 2.0);
    g_hCvar_KillFeedHeight = CreateConVar("l4d2_scripted_hud_kill_feed_height", "0.04", "Kill feed line height.", CVAR_FLAGS, true, 0.0, true, 2.0);
    g_hCvar_KillFeedTextAlign = CreateConVar("l4d2_scripted_hud_kill_feed_text_align", "3", "Kill feed alignment: 1 left, 2 center, 3 right.", CVAR_FLAGS, true, 1.0, true, 3.0);
    g_hCvar_KillFeedTeam = CreateConVar("l4d2_scripted_hud_kill_feed_team", "0", "Kill feed audience: 0 all, 1 survivors, 2 infected.", CVAR_FLAGS, true, 0.0, true, 2.0);
    g_hCvar_KillFeedBlink = CreateConVar("l4d2_scripted_hud_kill_feed_blink", "1", "Blink new kill feed lines.", CVAR_FLAGS, true, 0.0, true, 1.0);
    g_hCvar_KillFeedBackground = CreateConVar("l4d2_scripted_hud_kill_feed_background", "0", "Show a transparent black background behind the kill feed.", CVAR_FLAGS, true, 0.0, true, 1.0);

    g_hCvar_KillFeedLines.AddChangeHook(KillFeed_ConVarChanged);
    g_hCvar_KillFeedNoticeTime.AddChangeHook(KillFeed_ConVarChanged);
    g_hCvar_KillFeedBlockMessage.AddChangeHook(KillFeed_ConVarChanged);
    g_hCvar_KillFeedX.AddChangeHook(KillFeed_ConVarChanged);
    g_hCvar_KillFeedY.AddChangeHook(KillFeed_ConVarChanged);
    g_hCvar_KillFeedWidth.AddChangeHook(KillFeed_ConVarChanged);
    g_hCvar_KillFeedHeight.AddChangeHook(KillFeed_ConVarChanged);
    g_hCvar_KillFeedTextAlign.AddChangeHook(KillFeed_ConVarChanged);
    g_hCvar_KillFeedTeam.AddChangeHook(KillFeed_ConVarChanged);
    g_hCvar_KillFeedBlink.AddChangeHook(KillFeed_ConVarChanged);
    g_hCvar_KillFeedBackground.AddChangeHook(KillFeed_ConVarChanged);

    g_smKillFeedWeapons = new StringMap();
    g_smKillFeedSpecialWeapons = new StringMap();
    g_smKillFeedIgnoreWallWeapons = new StringMap();
    g_aKillFeed = new ArrayList(ByteCountToCells(KILL_FEED_LINE_SIZE));
    g_hKillFeedCookie = new Cookie("l4d2_scripted_hud_kill_feed_v1", "Scripted HUD kill feed fallback preference", CookieAccess_Protected);
    KillFeed_LoadWeaponNames();
    KillFeed_RefreshCvars();
}

bool KillFeed_ClientIsEnabled(int client)
{
    return client >= 1 && client <= MaxClients && g_bClientKillFeed[client];
}

void KillFeed_SetClientEnabled(int client, bool enabled)
{
    if (client >= 1 && client <= MaxClients)
        g_bClientKillFeed[client] = enabled;
}

bool KillFeed_HasEnabledClient()
{
    for (int client = 1; client <= MaxClients; client++)
    {
        if (IsClientInGame(client) && !IsFakeClient(client) && g_bClientKillFeed[client])
            return true;
    }
    return false;
}

void KillFeed_ResetClient(int client)
{
    if (client < 1 || client > MaxClients)
        return;

    KillFeed_SetClientEnabled(client, false);
    g_bClientHasKillFeedCookie[client] = false;
    g_iClientKillFeedCookieRevision[client] = 0;
}

void KillFeed_LoadClientCookie(int client)
{
    if (client < 1 || client > MaxClients || IsFakeClient(client)
        || g_hKillFeedCookie == null || !AreClientCookiesCached(client))
        return;

    char value[32];
    g_hKillFeedCookie.Get(client, value, sizeof(value));
    if (value[0] == '\0')
        return;

    char parts[2][16];
    int count = ExplodeString(value, "|", parts, sizeof(parts), sizeof(parts[]));
    if (count < 1 || (!StrEqual(parts[0], "0") && !StrEqual(parts[0], "1")))
        return;

    g_bClientHasKillFeedCookie[client] = true;
    g_bClientKillFeed[client] = parts[0][0] == '1';
    g_iClientKillFeedCookieRevision[client] = 0;
    if (count >= 2)
    {
        int revision;
        int consumed = StringToIntEx(parts[1], revision);
        if (consumed > 0 && consumed == strlen(parts[1]) && revision >= 0)
            g_iClientKillFeedCookieRevision[client] = revision;
    }
}

void KillFeed_SaveClientCookie(int client, int revision)
{
    if (client < 1 || client > MaxClients || IsFakeClient(client)
        || g_hKillFeedCookie == null || !AreClientCookiesCached(client))
        return;

    char value[32];
    FormatEx(value, sizeof(value), "%d|%d", g_bClientKillFeed[client] ? 1 : 0, revision);
    g_hKillFeedCookie.Set(client, value);
    g_bClientHasKillFeedCookie[client] = true;
    g_iClientKillFeedCookieRevision[client] = revision;
}

bool KillFeed_HasClientCookie(int client)
{
    return client >= 1 && client <= MaxClients && g_bClientHasKillFeedCookie[client];
}

int KillFeed_GetClientCookieRevision(int client)
{
    if (client < 1 || client > MaxClients)
        return 0;

    return g_iClientKillFeedCookieRevision[client];
}

void KillFeed_ClientToggle(int client)
{
    if (client < 1 || client > MaxClients || !IsClientInGame(client) || IsFakeClient(client))
        return;

    g_bClientKillFeed[client] = !g_bClientKillFeed[client];
    SaveHUDPrefs(client);
    if (!KillFeed_HasEnabledClient())
        KillFeed_Reset();
    else
        KillFeed_Render();
}

void KillFeed_RefreshCvars()
{
    if (g_hCvar_KillFeedLines == null)
        return;

    g_iKillFeedLines = g_hCvar_KillFeedLines.IntValue;
    if (g_iKillFeedLines < 1)
        g_iKillFeedLines = 1;
    if (g_iKillFeedLines > KILL_FEED_MAX_LINES)
        g_iKillFeedLines = KILL_FEED_MAX_LINES;
    g_fKillFeedNoticeTime = g_hCvar_KillFeedNoticeTime.FloatValue;
    g_bKillFeedBlockMessage = g_hCvar_KillFeedBlockMessage.BoolValue;
    g_fKillFeedX = g_hCvar_KillFeedX.FloatValue;
    g_fKillFeedY = g_hCvar_KillFeedY.FloatValue;
    g_fKillFeedWidth = g_hCvar_KillFeedWidth.FloatValue;
    g_fKillFeedHeight = g_hCvar_KillFeedHeight.FloatValue;
    g_iKillFeedTextAlign = g_hCvar_KillFeedTextAlign.IntValue;
    g_iKillFeedTeam = g_hCvar_KillFeedTeam.IntValue;
    g_bKillFeedBlink = g_hCvar_KillFeedBlink.BoolValue;
    g_bKillFeedBackground = g_hCvar_KillFeedBackground.BoolValue;

    g_iKillFeedFlags = HUD_FLAG_TEXT;
    switch (g_iKillFeedTextAlign)
    {
        case HUD_TEXT_ALIGN_LEFT: g_iKillFeedFlags |= HUD_FLAG_ALIGN_LEFT;
        case HUD_TEXT_ALIGN_CENTER: g_iKillFeedFlags |= HUD_FLAG_ALIGN_CENTER;
        case HUD_TEXT_ALIGN_RIGHT: g_iKillFeedFlags |= HUD_FLAG_ALIGN_RIGHT;
    }
    switch (g_iKillFeedTeam)
    {
        case HUD_TEAM_SURVIVOR: g_iKillFeedFlags |= HUD_FLAG_TEAM_SURVIVORS;
        case HUD_TEAM_INFECTED: g_iKillFeedFlags |= HUD_FLAG_TEAM_INFECTED;
    }
    if (!g_bKillFeedBackground)
        g_iKillFeedFlags |= HUD_FLAG_NOBG;
    if (g_bKillFeedBlink)
        g_iKillFeedFlags |= HUD_FLAG_BLINK;

    for (int slot = KILL_FEED_BASE; slot < HUD_SLOT_COUNT; slot++)
    {
        g_fKillFeedPos[slot][0] = g_fKillFeedX;
        g_fKillFeedPos[slot][1] = g_fKillFeedY + float(slot - KILL_FEED_BASE) * g_fKillFeedHeight;
        g_fKillFeedPos[slot][2] = g_fKillFeedWidth;
        g_fKillFeedPos[slot][3] = g_fKillFeedHeight;
    }
}

void KillFeed_PrintCvars(int client)
{
    int enabledClients;
    for (int index = 1; index <= MaxClients; index++)
    {
        if (IsClientInGame(index) && !IsFakeClient(index) && g_bClientKillFeed[index])
            enabledClients++;
    }
    PrintToConsole(client, "l4d2_scripted_hud_kill_feed_enabled_clients : %i", enabledClients);
    PrintToConsole(client, "l4d2_scripted_hud_kill_feed_lines : %i", g_iKillFeedLines);
    PrintToConsole(client, "l4d2_scripted_hud_kill_feed_notice_time : %.2f", g_fKillFeedNoticeTime);
    PrintToConsole(client, "l4d2_scripted_hud_kill_feed_disable_standard_message : %b (%s)", g_bKillFeedBlockMessage, g_bKillFeedBlockMessage ? "true" : "false");
    PrintToConsole(client, "l4d2_scripted_hud_kill_feed_x/y : %.3f / %.3f", g_fKillFeedX, g_fKillFeedY);
    PrintToConsole(client, "l4d2_scripted_hud_kill_feed_width/height : %.3f / %.3f", g_fKillFeedWidth, g_fKillFeedHeight);
    PrintToConsole(client, "l4d2_scripted_hud_kill_feed_text_align/team : %i / %i", g_iKillFeedTextAlign, g_iKillFeedTeam);
    PrintToConsole(client, "l4d2_scripted_hud_kill_feed_blink/background : %b / %b", g_bKillFeedBlink, g_bKillFeedBackground);
}

void KillFeed_ConVarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    KillFeed_RefreshCvars();
    while (g_aKillFeed != null && g_aKillFeed.Length > g_iKillFeedLines)
        g_aKillFeed.Erase(0);
    KillFeed_Render();
}

void KillFeed_OnConfigsExecuted()
{
    KillFeed_RefreshCvars();
    KillFeed_Reset();
}

void KillFeed_OnMapStart()
{
    KillFeed_Reset();
}

void KillFeed_OnMapEnd()
{
    delete g_hKillFeedTimer;
    g_hKillFeedTimer = null;
    if (g_aKillFeed != null)
        g_aKillFeed.Clear();
}

void KillFeed_OnPluginEnd()
{
    KillFeed_Reset();
    delete g_aKillFeed;
    delete g_smKillFeedWeapons;
    delete g_smKillFeedSpecialWeapons;
    delete g_smKillFeedIgnoreWallWeapons;
}

void KillFeed_Reset()
{
    delete g_hKillFeedTimer;
    g_hKillFeedTimer = null;

    if (g_aKillFeed != null)
        g_aKillFeed.Clear();

    KillFeed_Render();
}

void KillFeed_EventPlayerDeathPre(Event event, bool dontBroadcast)
{
    if (dontBroadcast || event.BroadcastDisabled || event.GetBool("abort")
        || !g_bKillFeedBlockMessage || !KillFeed_HasEnabledClient())
        return;

    // BroadcastDisabled is global. Re-send the original event only to clients
    // who keep the native death message, so enabled recipients do not see it.
    event.BroadcastDisabled = true;
    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client) || IsFakeClient(client))
            continue;

        if (!KillFeed_ClientIsEnabled(client) || !KillFeed_ClientMatchesTeam(client))
            event.FireToClient(client);
    }
}

void KillFeed_EventPlayerDeath(Event event)
{
    if (!KillFeed_HasEnabledClient() || event.GetBool("abort"))
        return;

    int victim = GetClientOfUserId(event.GetInt("userid"));
    bool victimPlayer = victim > 0 && victim <= MaxClients && IsClientInGame(victim);
    int attacker = GetClientOfUserId(event.GetInt("attacker"));
    bool attackerPlayer = attacker > 0 && attacker <= MaxClients && IsClientInGame(attacker);
    int entityid = event.GetInt("entityid");
    bool headshot = event.GetBool("headshot");
    int damagetype = event.GetInt("type");

    static char victimName[64];
    if (victimPlayer)
    {
        FormatEx(victimName, sizeof(victimName), "%N", victim);
        if (IsFakeClient(victim))
        {
            int index = StrContains(victimName, ")");
            if (index != -1)
                FormatEx(victimName, sizeof(victimName), "%s", victimName[index + 1]);
        }
    }
    else if (KillFeed_IsWitch(entityid))
    {
        strcopy(victimName, sizeof(victimName), "Witch");
    }
    else
    {
        return;
    }

    static char killInfo[KILL_FEED_LINE_SIZE];
    if (!attackerPlayer)
    {
        if (!victimPlayer)
            return;

        int attackerEntity = event.GetInt("attackerentid");
        if (KillFeed_IsWitch(attackerEntity))
            FormatEx(killInfo, sizeof(killInfo), "    %s  %s", g_sKillFeedType[16], victimName);
        else if (KillFeed_IsCommonInfected(attackerEntity))
            FormatEx(killInfo, sizeof(killInfo), "    %s  %s", g_sKillFeedType[17], victimName);
        else if (damagetype & DMG_BURN)
            FormatEx(killInfo, sizeof(killInfo), "    %s  %s", g_sKillFeedType[7], victimName);
        else if (damagetype & DMG_FALL)
            FormatEx(killInfo, sizeof(killInfo), "    %s  %s", g_sKillFeedType[19], victimName);
        else if (damagetype & DMG_BLAST)
            FormatEx(killInfo, sizeof(killInfo), "    %s  %s", g_sKillFeedType[6], victimName);
        else
            FormatEx(killInfo, sizeof(killInfo), "    %s  %s", g_sKillFeedType[12], victimName);

        KillFeed_Display(killInfo);
        return;
    }

    int victimTeam = victimPlayer ? GetClientTeam(victim) : 0;
    int attackerTeam = GetClientTeam(attacker);
    static char weapon[64];
    event.GetString("weapon", weapon, sizeof(weapon));

    if (attacker == victim)
    {
        if (victimTeam == TEAM_SURVIVOR && damagetype == (DMG_PREVENT_PHYSICS_FORCE + DMG_NEVERGIB) && StrEqual(weapon, "world", false))
        {
            FormatEx(killInfo, sizeof(killInfo), "    %s  %s", g_sKillFeedType[20], victimName);
            KillFeed_Display(killInfo);
            return;
        }
        if (victimTeam == TEAM_INFECTED)
        {
            int zombieClass = GetEntProp(victim, Prop_Send, "m_zombieClass");
            if (damagetype & DMG_FALL)
                FormatEx(killInfo, sizeof(killInfo), "    %s  %s", g_sKillFeedType[19], victimName);
            else if (damagetype == (DMG_PREVENT_PHYSICS_FORCE + DMG_NEVERGIB) && StrEqual(weapon, "world", false))
                FormatEx(killInfo, sizeof(killInfo), "    %s  %s", g_sKillFeedType[20], victimName);
            else if (zombieClass == L4D2_ZOMBIECLASS_TANK && damagetype == DMG_BULLET && StrEqual(weapon, "tank_claw", false))
                FormatEx(killInfo, sizeof(killInfo), "    %s  %s", g_sKillFeedType[20], victimName);
            else if (zombieClass == L4D2_ZOMBIECLASS_TANK && StrEqual(weapon, "world", false) && damagetype == DMG_NEVERGIB)
                return;
            else
                killInfo[0] = '\0';

            if (killInfo[0] != '\0')
                KillFeed_Display(killInfo);
            return;
        }
    }

    if (attackerTeam == TEAM_INFECTED && victimPlayer
        && (victimTeam == TEAM_SURVIVOR || victimTeam == TEAM_INFECTED))
    {
        static char attackerName[64];
        FormatEx(attackerName, sizeof(attackerName), "%N", attacker);
        if (IsFakeClient(attacker))
        {
            int index = StrContains(attackerName, ")");
            if (index != -1)
                FormatEx(attackerName, sizeof(attackerName), "%s", attackerName[index + 1]);
        }
        FormatEx(killInfo, sizeof(killInfo), "%s  %s  %s", attackerName, g_sKillFeedType[13], victimName);
        KillFeed_Display(killInfo);
        return;
    }

    if (strncmp(weapon, "world", 5, false) == 0 || strncmp(weapon, "trigger_hurt", 12, false) == 0)
    {
        FormatEx(killInfo, sizeof(killInfo), "    %s  %s", g_sKillFeedType[12], victimName);
        KillFeed_Display(killInfo);
        return;
    }

    static char weaponType[64];
    if (!g_smKillFeedWeapons.GetString(weapon, weaponType, sizeof(weaponType)))
        strcopy(weaponType, sizeof(weaponType), g_sKillFeedType[21]);

    if (g_smKillFeedSpecialWeapons.ContainsKey(weaponType))
    {
        FormatEx(killInfo, sizeof(killInfo), "%N  %s  %s", attacker, weaponType, victimName);
    }
    else if (victimPlayer)
    {
        bool behindWall = !g_smKillFeedIgnoreWallWeapons.ContainsKey(weaponType) && KillFeed_IsPlayerKilledBehindWall(attacker, victim);
        if (headshot && behindWall)
            FormatEx(killInfo, sizeof(killInfo), "%N  %s %s %s  %s", attacker, g_sKillFeedType[14], g_sKillFeedType[15], weaponType, victimName);
        else if (headshot)
            FormatEx(killInfo, sizeof(killInfo), "%N  %s %s  %s", attacker, g_sKillFeedType[15], weaponType, victimName);
        else if (behindWall)
            FormatEx(killInfo, sizeof(killInfo), "%N  %s %s  %s", attacker, g_sKillFeedType[14], weaponType, victimName);
        else
            FormatEx(killInfo, sizeof(killInfo), "%N  %s  %s", attacker, weaponType, victimName);
    }
    else
    {
        bool behindWall = !g_smKillFeedIgnoreWallWeapons.ContainsKey(weaponType) && KillFeed_IsEntityKilledBehindWall(attacker, entityid);
        if (headshot && behindWall)
            FormatEx(killInfo, sizeof(killInfo), "%N  %s %s %s  %s", attacker, g_sKillFeedType[14], g_sKillFeedType[15], weaponType, victimName);
        else if (headshot)
            FormatEx(killInfo, sizeof(killInfo), "%N  %s %s  %s", attacker, g_sKillFeedType[15], weaponType, victimName);
        else if (behindWall)
            FormatEx(killInfo, sizeof(killInfo), "%N  %s %s  %s", attacker, g_sKillFeedType[14], weaponType, victimName);
        else
            FormatEx(killInfo, sizeof(killInfo), "%N  %s  %s", attacker, weaponType, victimName);
    }

    KillFeed_Display(killInfo);
}

void KillFeed_EventRoundStart()
{
    KillFeed_Reset();
}

void KillFeed_Display(const char[] info)
{
    if (!KillFeed_HasEnabledClient() || !IsScriptedHUDEnabled() || g_aKillFeed == null)
        return;

    g_aKillFeed.PushString(info);
    while (g_aKillFeed.Length > g_iKillFeedLines)
        g_aKillFeed.Erase(0);
    KillFeed_Render();

    delete g_hKillFeedTimer;
    g_hKillFeedTimer = CreateTimer(g_fKillFeedNoticeTime, KillFeed_Timer, _, TIMER_REPEAT);
}

void KillFeed_Render()
{
    // The queue is read by per-recipient SendProxy callbacks. Updating the
    // owned slots marks terror_gamerules dirty so all six callbacks are sent;
    // slots 8-14 themselves are never changed globally.
    if (IsScriptedHUDEnabled())
        UpdateHUD();
}

Action KillFeed_Timer(Handle timer)
{
    if (!KillFeed_HasEnabledClient() || !IsScriptedHUDEnabled() || g_aKillFeed == null || g_aKillFeed.Length == 0)
    {
        g_hKillFeedTimer = null;
        return Plugin_Stop;
    }

    g_aKillFeed.Erase(0);
    KillFeed_Render();
    return Plugin_Continue;
}

bool KillFeed_ClientMatchesTeam(int client)
{
    if (g_iKillFeedTeam == HUD_TEAM_ALL)
        return true;

    int team = GetClientTeam(client);
    return (g_iKillFeedTeam == HUD_TEAM_SURVIVOR && team == TEAM_SURVIVOR)
        || (g_iKillFeedTeam == HUD_TEAM_INFECTED && team == TEAM_INFECTED);
}

bool KillFeed_ClientShouldOverride(int client, int hud)
{
    return IsScriptedHUDEnabled()
        && hud >= KILL_FEED_BASE && hud < HUD_SLOT_COUNT
        && KillFeed_ClientIsEnabled(client)
        && KillFeed_ClientMatchesTeam(client);
}

bool KillFeed_HasLine(int hud)
{
    int index = hud - KILL_FEED_BASE;
    return g_aKillFeed != null && index >= 0 && index < g_aKillFeed.Length;
}

Action KillFeed_ProxyFlags(int &value, int hud, int client)
{
    if (!KillFeed_ClientShouldOverride(client, hud))
        return Plugin_Continue;

    if (KillFeed_HasLine(hud))
        value = g_iKillFeedFlags & ~HUD_FLAG_NOTVISIBLE;
    else
        value = HUD_FLAG_NOTVISIBLE | HUD_FLAG_TEXT | HUD_FLAG_NOBG;
    return Plugin_Changed;
}

Action KillFeed_ProxyString(char[] value, int maxlength, int hud, int client)
{
    if (!KillFeed_ClientShouldOverride(client, hud))
        return Plugin_Continue;

    value[0] = '\0';
    if (KillFeed_HasLine(hud))
        g_aKillFeed.GetString(hud - KILL_FEED_BASE, value, maxlength);
    return Plugin_Changed;
}

Action KillFeed_ProxyPosX(float &value, int hud, int client)
{
    if (!KillFeed_ClientShouldOverride(client, hud))
        return Plugin_Continue;

    value = g_fKillFeedPos[hud][0];
    return Plugin_Changed;
}

Action KillFeed_ProxyPosY(float &value, int hud, int client)
{
    if (!KillFeed_ClientShouldOverride(client, hud))
        return Plugin_Continue;

    value = g_fKillFeedPos[hud][1];
    return Plugin_Changed;
}

Action KillFeed_ProxyWidth(float &value, int hud, int client)
{
    if (!KillFeed_ClientShouldOverride(client, hud))
        return Plugin_Continue;

    value = g_fKillFeedPos[hud][2];
    return Plugin_Changed;
}

Action KillFeed_ProxyHeight(float &value, int hud, int client)
{
    if (!KillFeed_ClientShouldOverride(client, hud))
        return Plugin_Continue;

    value = g_fKillFeedPos[hud][3];
    return Plugin_Changed;
}

bool KillFeed_IsPlayerKilledBehindWall(int attacker, int victim)
{
    float attackerPos[3];
    float victimPos[3];
    GetClientEyePosition(attacker, attackerPos);
    GetClientEyePosition(victim, victimPos);
    Handle trace = TR_TraceRayFilterEx(attackerPos, victimPos, MASK_PLAYERSOLID, RayType_EndPoint, KillFeed_TraceNoPlayers, victim);
    bool blocked = trace != null && TR_DidHit(trace);
    delete trace;
    return blocked;
}

bool KillFeed_TraceNoPlayers(int entity, int mask, any data)
{
    return entity != data && (entity < 1 || entity > MaxClients);
}

bool KillFeed_IsEntityKilledBehindWall(int attacker, int entity)
{
    float angles[3];
    float origin[3];
    GetClientEyePosition(attacker, origin);
    GetClientEyeAngles(attacker, angles);
    Handle trace = TR_TraceRayFilterEx(origin, angles, MASK_SHOT, RayType_Infinite, KillFeed_TraceNoEntities);
    bool blocked = true;
    if (trace != null && TR_DidHit(trace) && TR_GetEntityIndex(trace) == entity)
        blocked = false;
    delete trace;
    return blocked;
}

bool KillFeed_TraceNoEntities(int entity, int mask, any data)
{
    return entity != data && (entity < 1 || entity > MaxClients);
}

void KillFeed_LoadWeaponNames()
{
    g_smKillFeedWeapons.SetString("melee", g_sKillFeedType[0]);
    g_smKillFeedWeapons.SetString("pistol", g_sKillFeedType[1]);
    g_smKillFeedWeapons.SetString("pistol_magnum", g_sKillFeedType[1]);
    g_smKillFeedWeapons.SetString("dual_pistols", g_sKillFeedType[1]);
    g_smKillFeedWeapons.SetString("smg", g_sKillFeedType[2]);
    g_smKillFeedWeapons.SetString("smg_silenced", g_sKillFeedType[2]);
    g_smKillFeedWeapons.SetString("smg_mp5", g_sKillFeedType[2]);
    g_smKillFeedWeapons.SetString("rifle", g_sKillFeedType[3]);
    g_smKillFeedWeapons.SetString("rifle_ak47", g_sKillFeedType[3]);
    g_smKillFeedWeapons.SetString("rifle_sg552", g_sKillFeedType[3]);
    g_smKillFeedWeapons.SetString("rifle_desert", g_sKillFeedType[3]);
    g_smKillFeedWeapons.SetString("pumpshotgun", g_sKillFeedType[4]);
    g_smKillFeedWeapons.SetString("shotgun_chrome", g_sKillFeedType[4]);
    g_smKillFeedWeapons.SetString("autoshotgun", g_sKillFeedType[4]);
    g_smKillFeedWeapons.SetString("shotgun_spas", g_sKillFeedType[4]);
    g_smKillFeedWeapons.SetString("hunting_rifle", g_sKillFeedType[5]);
    g_smKillFeedWeapons.SetString("sniper_military", g_sKillFeedType[5]);
    g_smKillFeedWeapons.SetString("sniper_scout", g_sKillFeedType[5]);
    g_smKillFeedWeapons.SetString("sniper_awp", g_sKillFeedType[5]);
    g_smKillFeedWeapons.SetString("pipe_bomb", g_sKillFeedType[6]);
    g_smKillFeedWeapons.SetString("env_explosion", g_sKillFeedType[6]);
    g_smKillFeedWeapons.SetString("inferno", g_sKillFeedType[7]);
    g_smKillFeedWeapons.SetString("entityflame", g_sKillFeedType[7]);
    g_smKillFeedWeapons.SetString("rifle_m60", g_sKillFeedType[8]);
    g_smKillFeedWeapons.SetString("grenade_launcher_projectile", g_sKillFeedType[9]);
    g_smKillFeedWeapons.SetString("boomer", g_sKillFeedType[10]);
    g_smKillFeedWeapons.SetString("player", g_sKillFeedType[10]);
    g_smKillFeedWeapons.SetString("prop_minigun_l4d1", g_sKillFeedType[11]);
    g_smKillFeedWeapons.SetString("prop_minigun", g_sKillFeedType[11]);
    g_smKillFeedWeapons.SetString("world", g_sKillFeedType[12]);
    g_smKillFeedWeapons.SetString("worldspawn", g_sKillFeedType[12]);
    g_smKillFeedWeapons.SetString("trigger_hurt", g_sKillFeedType[12]);
    g_smKillFeedWeapons.SetString("chainsaw", g_sKillFeedType[18]);

    g_smKillFeedSpecialWeapons.SetValue(g_sKillFeedType[6], true);
    g_smKillFeedSpecialWeapons.SetValue(g_sKillFeedType[7], true);
    g_smKillFeedSpecialWeapons.SetValue(g_sKillFeedType[10], true);
    g_smKillFeedSpecialWeapons.SetValue(g_sKillFeedType[21], true);
    g_smKillFeedIgnoreWallWeapons.SetValue(g_sKillFeedType[9], true);
    g_smKillFeedIgnoreWallWeapons.SetValue(g_sKillFeedType[0], true);
    g_smKillFeedIgnoreWallWeapons.SetValue(g_sKillFeedType[18], true);
    g_smKillFeedIgnoreWallWeapons.SetValue(g_sKillFeedType[21], true);
}

bool KillFeed_IsWitch(int entity)
{
    if (entity <= 0 || !IsValidEntity(entity))
        return false;

    char classname[64];
    GetEntityClassname(entity, classname, sizeof(classname));
    return StrEqual(classname, KILL_FEED_CLASS_WITCH, false);
}

bool KillFeed_IsCommonInfected(int entity)
{
    if (entity <= 0 || !IsValidEntity(entity))
        return false;

    char classname[64];
    GetEntityClassname(entity, classname, sizeof(classname));
    return StrEqual(classname, KILL_FEED_CLASS_INFECTED, false);
}
