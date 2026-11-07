/*
 * l4d2_ammo_bit_widener_ext
 * Copyright (C) 2026 ExpCharacter
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */
// Written with ChatGPT 6.1 sol high + deepseek flash.
//
// Widens m_iAmmo through the sendtable extension by Crimson-DawnLight:
//   https://github.com/Crimson-DawnLight/L4D2MutiMod (extensions/sendtable, v1.0.0)
// The extension is a separate binary; this plugin only calls its natives and
// does not embed or modify its code. Schema patching, buffer growth, framing
// and the CRC marker all live inside the extension.
// Requires SourceMod 1.12; the extension refuses SM 1.11 (IPlayerManager).
#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sendtable>

#define PLUGIN_VERSION "1.1.0"

public Plugin myinfo =
{
    name = "L4D2 Ammo Bit Widener (SendTable extension)",
    author = "ExpCharacter",
    description = "Widen m_iAmmo and m_iClip1 to 16 bits through sendtable.ext",
    version = PLUGIN_VERSION,
    url = "https://github.com/ExpCharacter/oh-my-l4d2-plugins"
};

#define AMMO_CLASS        "CTerrorPlayer"
#define AMMO_TABLE        "m_iAmmo"
#define AMMO_BITS_VANILLA 10
#define AMMO_BITS_TARGET  16

#define CLIP_CLASS        "CBaseCombatWeapon"
#define CLIP_PROP         "m_iClip1"
#define CLIP_BITS_VANILLA 8
#define CLIP_BITS_TARGET  16

bool g_WaitForMap;

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int maxlength)
{
    g_WaitForMap = late;
    return APLRes_Success;
}

public void OnPluginStart()
{
    RegServerCmd("sm_ammo_bit_widener_ext_status", Cmd_Status);

    if (g_WaitForMap)
    {
        LogMessage("Late load: waiting for the next map initialization before widening ammo and clip");
        return;
    }

    ApplyBits();
}

public void OnMapInit(const char[] mapName)
{
    // Unlike OnMapStart, this is not replayed when a plugin is hot-loaded.
    if (!g_WaitForMap)
        return;
    g_WaitForMap = false;
    ApplyBits();
}

void ApplyBits()
{
    // Both props ride the same late-load wait, so a hot reload never changes the
    // schema under clients that already negotiated. m_iAmmo is the per-player
    // array; m_iClip1 is a direct member of DT_BaseCombatWeapon. An ammo failure
    // stays fatal, a clip failure only leaves that field at its stock width.
    if (!WidenProp(AMMO_CLASS, AMMO_TABLE, AMMO_BITS_VANILLA, AMMO_BITS_TARGET, true))
        SetFailState("%s could not be widened", AMMO_TABLE);

    WidenProp(CLIP_CLASS, CLIP_PROP, CLIP_BITS_VANILLA, CLIP_BITS_TARGET, false);
}

bool WidenProp(const char[] netClass, const char[] prop, int vanillaBits, int targetBits, bool elements)
{
    // Confogl can reload this plugin while the tables are already widened.
    int bits = SendTable.GetBits(netClass, prop);
    if (bits == -1)
    {
        LogError("%s.%s not found; the send table layout changed", netClass, prop);
        return false;
    }

    if (bits == targetBits)
    {
        return true;
    }

    if (bits != vanillaBits)
    {
        LogError("%s is %d bits, expected %d (vanilla) or %d (widened)", prop, bits, vanillaBits, targetBits);
        return false;
    }

    // expectedBits guards against a game update changing the vanilla width:
    // the call fails instead of widening an already different schema.
    bool ok;
    if (elements)
        ok = SendTable.SetElementBits(netClass, prop, targetBits, vanillaBits);
    else
        ok = SendTable.SetBits(netClass, prop, targetBits, vanillaBits);
    if (!ok)
    {
        LogError("%s widen failed: class/prop missing or expectedBits mismatch", prop);
        return false;
    }

    return true;
}

public Action Cmd_Status(int args)
{
    int ammoBits = SendTable.GetBits(AMMO_CLASS, AMMO_TABLE);
    int clipBits = SendTable.GetBits(CLIP_CLASS, CLIP_PROP);
    PrintToServer("[ammo_bit_widener-ext] %s bits=%d expected=%d; %s bits=%d expected=%d; waiting_for_map=%d",
                  AMMO_TABLE, ammoBits, AMMO_BITS_TARGET, CLIP_PROP, clipBits, CLIP_BITS_TARGET, g_WaitForMap);
    return Plugin_Handled;
}
