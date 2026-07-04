/*
*	Extra Menu API
*	Copyright (C) 2022 Silvers
*
*	This program is free software: you can redistribute it and/or modify
*	it under the terms of the GNU General Public License as published by
*	the Free Software Foundation, either version 3 of the License, or
*	(at your option) any later version.
*
*	This program is distributed in the hope that it will be useful,
*	but WITHOUT ANY WARRANTY; without even the implied warranty of
*	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
*	GNU General Public License for more details.
*
*	You should have received a copy of the GNU General Public License
*	along with this program.  If not, see <https://www.gnu.org/licenses/>.
*/



#define PLUGIN_VERSION 		"1.5"

/*======================================================================================
	Plugin Info:

*	Name	:	[ANY] Extra Menu API
*	Author	:	SilverShot
*	Descrp	:	Allows plugins to create menus with more than 1-7 selectable entries and more functionality.
*	Link	:	https://forums.alliedmods.net/showthread.php?t=338863
*	Plugins	:	https://sourcemod.net/plugins.php?exact=exact&sortby=title&search=1&author=Silvers

========================================================================================
	Change Log:
1.5 (2024年9月7日)
	- AddEntry将返回该项的index
	- 新type: MENU_SELECT_CVARADD/MENU_SELECT_CVARONOFF
	- 在include包装了相关方法

1.4 (15-Oct-2022)
	- New feature: Native "ExtraMenu_Create" can now create menus that use 1/2/3/4 to move and select instead of freezing the player and using W/A/S/D keys.
	- Added new "translations/extra_menu.phrases.txt" translation file to support the new menu type.
	- Changed to store the menu data in StringMaps, for lower memory and an unlimited number of menus.
	- This is still ultra fast to store and retrieve the menu data.

1.3 (27-Aug-2022)
	- Fixed not deleting some handles when deleting a menu.

1.2 (15-Aug-2022)
	- Fixed errors thrown when displaying a menu and the clients index is 0.
	- Increased the maximum length of rows to support multi-byte characters.
	- Added a "meter" option demonstration to the "extra_menu_test" plugin.

1.1 (04-Aug-2022)
	- Fixed the button sounds not playing.
	- Fixed the menu not ending when interrupted by another menu.

1.0 (30-Jul-2022)
	- Initial release.

======================================================================================*/


#include <sourcemod>
#include <sdktools>
#include <extra_menu>

#pragma semicolon 1
#pragma newdecls required


#define MAX_MENU_LEN		4096	// Maximum string length per menu
#define MAX_LINE_LEN		512		// Maximum string length per row
#define MAX_LEN_OPTIONS		512		// Maximum length of options string
#define MAX_CVAR_LEN 128
#define MAX_LEN_TRANS		64		// Maximum length of translation file name for menu
#define MAX_KEYS			4		// Maximum length of keys value
#define MAX_WAIT			0.2		// Delay between moving and selecting in the menu
#define SPLIT_CHAR			"|"		// The character used to split a menus options for the MENU_SELECT_LIST type
#define VERIFY_INDEXES		false	// True = Verifies a menu index exists when accessing. False = Only when creating (should only be required here), errors would be caused by plugins written incorrectly


int g_iSelected[MAXPLAYERS+1];					// Selected row in menu
int g_iPageOpen[MAXPLAYERS+1];					// Selected page in menu
int g_iMenuTime[MAXPLAYERS+1];					// Time to display menu
bool g_bMenuOpen[MAXPLAYERS+1];					// Menu open?
bool g_bMenuNums[MAXPLAYERS+1];					// Buttons menu
int g_iMenuID[MAXPLAYERS+1] = {-1, ...};		// Selected menu being viewed
float g_fLastSel[MAXPLAYERS+1];					// Last row selection
float g_fLastOpt[MAXPLAYERS+1];					// Last option selection
Menu g_hMenu[MAXPLAYERS+1];						// Menu handle for auto close option selection

bool g_bTranslation;
ConVar g_hCvarSoundMove, g_hCvarSoundClick;
char g_sCvarSoundMove[PLATFORM_MAX_PATH], g_sCvarSoundClick[PLATFORM_MAX_PATH];

StringMap g_AllMenus;

GlobalForward g_hFWD_ExtraMenu_OnSelect;

void EnsureMenuStore()
{
	if( g_AllMenus == null )
	{
		g_AllMenus = new StringMap();
	}
}



// ====================================================================================================
//					MENU STRUCT
// ====================================================================================================
#define MAX_DATA 10	// Maximum number of "ROW_*" data to store

enum
{
	ROW_TYPE,		// Type of menu entry
	ROW_DEFS,		// Default option value for the menu
	ROW_INCRE,		// Increment/decrement value
	ROW_IN_MAX,		// Increment/decrement minimum value
	ROW_IN_MIN,		// Increment/decrement maximum value
	ROW_INDEX,		// Menu row index sent to forward
	ROW_PAGE,		// Row page number that it belongs to
	ROW_OPTIONS,	// ArrayList of options for the "MENU_SELECT_LIST" type
	ROW_OPS_LEN,	// Number of options for the "MENU_SELECT_LIST" type
	ROW_CLOSE,		// Close menu after use
}
#define ROW_CVARNAME 0
enum struct MenuData 
{
	// Variables
	int menu_id;						// Plugin that created the menu
	ArrayList RowsData;					// Data list for each row entry
	ArrayList RowsCvar;
	ArrayList MenuList;					// String list of entries
	ArrayList MenuVals[MAXPLAYERS+1];	// Each players selected value for the menu
	char Translation[MAX_LEN_TRANS];	// Translation file, if available
	int MenuLastUser[MAXPLAYERS+1];		// UserID of person using, if different reset
	int TotalItem;						// Total number of selectable items
	int CurrPage;
	int MenuTime;
	int TotalPage;
	bool MenuBack;
	bool MenuNums;

	// Create menu
	void Create(int menu_id, bool back, bool buttons_nums)
	{
		this.menu_id = menu_id;
		this.MenuList = new ArrayList(ByteCountToCells(MAX_LINE_LEN));
		this.RowsData = new ArrayList(MAX_DATA);
		this.RowsCvar = new ArrayList(ByteCountToCells(MAX_CVAR_LEN));
		this.TotalItem = 0;
		this.TotalPage = 0;
		this.MenuBack = back;
		this.MenuNums = buttons_nums;

		for( int i = 1; i <= MaxClients; i++ )
		{
			this.MenuVals[i] = new ArrayList();
		}
	}

	// Delete menu
	void Delete()
	{
		this.menu_id = -1;

		// Delete options ArrayList's
		ArrayList aHand;
		int length = this.RowsData.Length;
		for( int i = 0; i < length; i++ )
		{
			aHand = this.RowsData.Get(i, ROW_OPTIONS);
			if( aHand != null )
			{
				delete aHand;
			}
		}

		// Delete user selections
		for( int i = 1; i <= MaxClients; i++ )
		{
			delete this.MenuVals[i];
		}

		// Delete handles
		delete this.MenuList;
		delete this.RowsData;
		delete this.RowsCvar;
	}

	// Add Entry
	int AddEntry(const char[] entry, EXTRA_MENU_TYPE type, bool close, int default_value, any add_value, any add_min, any add_max, const char[] convar)
	{
		this.MenuList.PushString(entry);

		int index = this.RowsData.Push(type);
		this.RowsCvar.PushString(convar);
		this.RowsData.Set(index, default_value, ROW_DEFS);
		this.RowsData.Set(index, add_value, ROW_INCRE);
		this.RowsData.Set(index, add_min, ROW_IN_MIN);
		this.RowsData.Set(index, add_max, ROW_IN_MAX);
		this.RowsData.Set(index, this.TotalPage, ROW_PAGE);
		this.RowsData.Set(index, 0, ROW_OPTIONS);
		this.RowsData.Set(index, 0, ROW_OPS_LEN);
		this.RowsData.Set(index, close, ROW_CLOSE);
		this.RowsCvar.SetString(index, convar);

		// Store indexes of selectable entries, for using in the forward
		if( type != MENU_ENTRY )
		{
			this.RowsData.Set(index, this.TotalItem, ROW_INDEX);
			this.TotalItem++;
		}
		else
		{
			this.RowsData.Set(index, -1, ROW_INDEX);
		}

		// Rows default values
		for( int i = 1; i <= MaxClients; i++ )
		{
			this.MenuVals[i].Push(default_value);
		}
		return this.TotalItem - 1;
	}
}



// ====================================================================================================
//					PLUGIN INFO / START
// ====================================================================================================
public Plugin myinfo =
{
	name = "[ANY] Extra Menu API",
	author = "SilverShot",
	description = "Allows plugins to create menus with more than 1-7 selectable entries and more functionality.",
	version = PLUGIN_VERSION,
	url = "https://forums.alliedmods.net/showthread.php?t=338863"
}

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	EnsureMenuStore();

	// Natives
	CreateNative("ExtraMenu_Create",		Native_CreateMenu);
	CreateNative("ExtraMenu_Delete",		Native_DeleteMenu);
	CreateNative("ExtraMenu_AddEntry",		Native_AddEntry);
	CreateNative("ExtraMenu_AddOptions",	Native_AddOptions);
	CreateNative("ExtraMenu_NewPage",		Native_AddPage);
	CreateNative("ExtraMenu_Display",		Native_Display);

	// Forward
	g_hFWD_ExtraMenu_OnSelect				= new GlobalForward("ExtraMenu_OnSelect", ET_Event, Param_Cell, Param_Cell, Param_Cell, Param_Cell);

	// Register library
	RegPluginLibrary("extra_menu");

	return APLRes_Success;
}

public void OnPluginStart()
{
	// Translations
	LoadTranslations("core.phrases");

	char sPath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, sPath, sizeof(sPath), "translations/extra_menu.phrases.txt");
	if( FileExists(sPath) )
	{
		g_bTranslation = true;
		LoadTranslations("extra_menu.phrases");
	}

	// Sound path
	char sTemp[64];
	EngineVersion engine = GetEngineVersion();
	switch( engine )
	{
		case Engine_Left4Dead, Engine_Left4Dead2:
		{
			sTemp = "buttons/blip1.wav";
		}
		default:
		{
			sTemp = "buttons/combine_button7.wav";
		}
	}

	// Cvars
	g_hCvarSoundMove =		CreateConVar("extra_menu_sound_move",	"buttons/button14.wav", 		"Path to the sound to play when moving through the menu. Or \"\" for no sound.", FCVAR_NOTIFY);
	g_hCvarSoundClick =		CreateConVar("extra_menu_sound_click",	sTemp,							"Path to the sound to play when clicking a menu option. Or \"\" for no sound.", FCVAR_NOTIFY);
	CreateConVar("extra_menu_version", PLUGIN_VERSION, "Extra Menu API plugin version.", FCVAR_NOTIFY|FCVAR_DONTRECORD);
	AutoExecConfig(true, "extra_menu_api");

	g_hCvarSoundMove.AddChangeHook(ConVarChanged_Cvars);
	g_hCvarSoundClick.AddChangeHook(ConVarChanged_Cvars);

	// Initialize menus
	EnsureMenuStore();
}



// ====================================================================================================
//					CVARS
// ====================================================================================================
public void OnConfigsExecuted()
{
	GetCvars();
}

void ConVarChanged_Cvars(Handle convar, const char[] oldValue, const char[] newValue)
{
	GetCvars();
}

void GetCvars()
{
	g_hCvarSoundMove.GetString(g_sCvarSoundMove, sizeof(g_sCvarSoundMove));
	g_hCvarSoundClick.GetString(g_sCvarSoundClick, sizeof(g_sCvarSoundClick));
}



// ====================================================================================================
//					NATIVES
// ====================================================================================================
int Native_CreateMenu(Handle plugin, int numParams)
{
	char sKey[MAX_KEYS];

	for( int i = 0; i != -1; i++ )
	{
		IntToString(i, sKey, sizeof(sKey));

		if( !g_AllMenus.ContainsKey(sKey) )
		{
			bool back = GetNativeCell(1);

			bool buttons_nums;
			if( numParams > 2 )
				buttons_nums = GetNativeCell(3);

			MenuData data;

			data.Create(i, back, buttons_nums);
			// data.menu_id = view_as<int>(plugin) + i; // Create a more unique ID based on plugin handle? Not valid since the plugins built around indexes
			data.menu_id = i;

			// Load translations
			if( numParams > 1 )
			{
				char trans[MAX_LEN_TRANS];
				GetNativeString(2, trans, sizeof(trans));
				data.Translation = trans;
				if( trans[0] ) LoadTranslations(trans);
			}

			g_AllMenus.SetArray(sKey, data, sizeof(data));

			return i;
		}
	}

	return 0;
}

int Native_DeleteMenu(Handle plugin, int numParams)
{
	int menu_id = GetNativeCell(1);

	char sKey[MAX_KEYS];
	IntToString(menu_id, sKey, sizeof(sKey));

	if( g_AllMenus.ContainsKey(sKey) )
	{
		MenuData data;
		g_AllMenus.GetArray(sKey, data, sizeof(data));

		data.Delete();
		g_AllMenus.Remove(sKey);
	}

	return false;
}

int Native_AddEntry(Handle plugin, int numParams)
{
	int menu_id = GetNativeCell(1);

	char sKey[MAX_KEYS];
	IntToString(menu_id, sKey, sizeof(sKey));

	#if VERIFY_INDEXES
	if( g_AllMenus.ContainsKey(sKey) )
	#endif
	{
		MenuData data;
		g_AllMenus.GetArray(sKey, data, sizeof(data));

		int maxlength;
		GetNativeStringLength(2, maxlength);
		maxlength += 1;
		char[] entry = new char[maxlength];
		GetNativeString(2, entry, maxlength);

		EXTRA_MENU_TYPE type = GetNativeCell(3);
		bool close = GetNativeCell(4);
		int default_value = GetNativeCell(5);
		int add_value = GetNativeCell(6);
		int add_min = GetNativeCell(7);
		int add_max = GetNativeCell(8);

		char cvar[MAX_CVAR_LEN];
		strcopy(cvar, sizeof(cvar), "");
		if( numParams > 8 )
		{
			GetNativeString(9, cvar, sizeof(cvar));
		}
		int value = data.AddEntry(entry, type, close, default_value, add_value, add_min, add_max, cvar);

		g_AllMenus.SetArray(sKey, data, sizeof(data));
		return value;
	}

	#if VERIFY_INDEXES
	return false;
	#endif
}

int Native_AddOptions(Handle plugin, int numParams)
{
	int menu_id = GetNativeCell(1);

	char sKey[MAX_KEYS];
	IntToString(menu_id, sKey, sizeof(sKey));

	#if VERIFY_INDEXES
	if( g_AllMenus.ContainsKey(sKey) )
	#endif
	{
		MenuData data;
		g_AllMenus.GetArray(sKey, data, sizeof(data));

		int length = data.RowsData.Length;

		ArrayList aHand = data.RowsData.Get(length - 1, ROW_OPTIONS);

		if( aHand == null )
		{
			aHand = new ArrayList(ByteCountToCells(MAX_LEN_OPTIONS));
			data.RowsData.Set(length - 1, aHand, ROW_OPTIONS);

			int maxlength;
			GetNativeStringLength(2, maxlength);
			maxlength += 2;
			char[] entry = new char[maxlength];
			GetNativeString(2, entry, maxlength);

			// Add whole row for translation
			aHand.PushString(entry);

			if( data.Translation[0] )
			{
				Format(entry, maxlength, "%t", entry, LANG_SERVER);
			}

			// Add each individually
			StrCat(entry, maxlength, SPLIT_CHAR);
			int last;
			int pos = 1;
			int total;
			while( pos )
			{
				pos = StrContains(entry[last], SPLIT_CHAR);
				if( pos == -1 )
				{
					break;
				}

				last = last + pos + 1;
				total++;
			}

			data.RowsData.Set(length - 1, total, ROW_OPS_LEN);

			g_AllMenus.SetArray(sKey, data, sizeof(data));
		}
	}

	return true;
}

int Native_AddPage(Handle plugin, int numParams)
{
	int menu_id = GetNativeCell(1);

	char sKey[MAX_KEYS];
	IntToString(menu_id, sKey, sizeof(sKey));

	#if VERIFY_INDEXES
	if( g_AllMenus.ContainsKey(sKey) )
	#endif
	{
		MenuData data;
		g_AllMenus.GetArray(sKey, data, sizeof(data));

		data.TotalPage++;

		g_AllMenus.SetArray(sKey, data, sizeof(data));

		return true;
	}

	#if VERIFY_INDEXES
	return false;
	#endif
}

int Native_Display(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	if( !client ) return false;

	int menu_id = GetNativeCell(2);

	char sKey[MAX_KEYS];
	IntToString(menu_id, sKey, sizeof(sKey));

	#if VERIFY_INDEXES
	if( g_AllMenus.ContainsKey(sKey) )
	#endif
	{
		MenuData data;
		g_AllMenus.GetArray(sKey, data, sizeof(data));

		g_iSelected[client] = -1;

		// Displaying to a new client? Reset some things
		if( data.MenuLastUser[client] != GetClientUserId(client) )
		{
			// Last user
			data.MenuLastUser[client] = GetClientUserId(client);

			// Initialize menu with default values
			int length = data.RowsData.Length;

			for( int x = 0; x < length; x++ )
			{
				data.MenuVals[client].Set(x, data.RowsData.Get(x, ROW_DEFS));

				// Default selected option
				if( g_iSelected[client] == -1 && data.RowsData.Get(x, ROW_TYPE) != MENU_ENTRY )
				{
					g_iSelected[client] = x;
				}
			}

			g_AllMenus.SetArray(sKey, data, sizeof(data));
		}
		else
		{
			// Set the default selected option to the first valid entry
			int length = data.RowsData.Length;

			for( int x = 0; x < length; x++ )
			{
				if( data.RowsData.Get(x, ROW_TYPE) != MENU_ENTRY )
				{
					g_iSelected[client] = x;
					break;
				}
			}
		}

		// Menu open time and display
		int time = GetNativeCell(3);

		g_iPageOpen[client] = 0;
		g_iMenuTime[client] = time;
		DisplayExtraMenu(client, menu_id);
		return true;
	}

	#if VERIFY_INDEXES
	return false;
	#endif
}



// ====================================================================================================
//					RESET STUFF
// ====================================================================================================
public void OnClientPutInServer(int client)
{
	g_bMenuOpen[client] = false;
	g_bMenuNums[client] = false;
	g_iSelected[client] = 0;
	g_iPageOpen[client] = 0;
	g_fLastSel[client] = 0.0;
	g_fLastOpt[client] = 0.0;
	g_iMenuID[client] = -1;
	g_hMenu[client] = null;
}

public void OnMapEnd()
{
	for( int i = 1; i <= MaxClients; i++ )
	{
		OnClientPutInServer(i);
	}
}



// ====================================================================================================
//					DISPLAY MENU
// ====================================================================================================
void DisplayExtraMenu(int client, int menu_id)
{
	static char sVals[32];
	static char sOpts[MAX_LEN_OPTIONS];
	static char sTemp[MAX_LINE_LEN];
	static char sMenu[MAX_MENU_LEN];

	sMenu[0] = '\x0';

	char sKey[MAX_KEYS];
	IntToString(menu_id, sKey, sizeof(sKey));

	#if VERIFY_INDEXES
	if( g_AllMenus.ContainsKey(sKey) )
	#endif
	{
		MenuData data;
		g_AllMenus.GetArray(sKey, data, sizeof(data));

		int pages = data.TotalPage;
		int length = data.RowsData.Length;
		int selected = g_iSelected[client];

		for( int i = 0; i < length; i++ )
		{
			// Viewing current page
			if( pages == 0 || g_iPageOpen[client] == data.RowsData.Get(i, ROW_PAGE) )
			{
				// Get menu row type and string
				data.MenuList.GetString(i, sTemp, sizeof(sTemp));

				// Translation
				if( data.Translation[0] )
				{
					if( strcmp(sTemp, " ") ) // Not a "spacer" line
					{
						Format(sTemp, sizeof(sTemp), "%T", sTemp, client);
					}
				}

				// Selectable entry
				if( data.RowsData.Get(i, ROW_TYPE) != MENU_ENTRY )
				{
					if( selected == i )
					{
						Format(sTemp, sizeof(sTemp), "➤%s", sTemp);
					} else {
						Format(sTemp, sizeof(sTemp), "   %s", sTemp);
					}

					// Entry type
					switch( data.RowsData.Get(i, ROW_TYPE) )
					{
						// Selectable on/off
						case MENU_SELECT_ONOFF:
						{
							if( data.MenuVals[client].Get(i) == 1 )
							{
								ReplaceString(sTemp, sizeof(sTemp), "_OPT_", "[●]");
							} else {
								ReplaceString(sTemp, sizeof(sTemp), "_OPT_", "[○]");
							}
						}
						case MENU_SELECT_CVARONOFF:
						{
							char buffer[32];
							data.RowsCvar.GetString(i, buffer, sizeof(buffer));

							if(GetConVarBool(FindConVar(buffer)))
							{
								ReplaceString(sTemp, sizeof(sTemp), "_OPT_", "[●]");
							} else {
								ReplaceString(sTemp, sizeof(sTemp), "_OPT_", "[○]");
							}
						}

						// Increment/decrement
						case MENU_SELECT_ADD:
						{
							float value = float(data.MenuVals[client].Get(i));
							FloatToString(value, sVals, sizeof(sVals));
							ReplaceString(sVals, sizeof(sVals), ".000000", "");
							ReplaceString(sTemp, sizeof(sTemp), "_OPT_", sVals);
						}

						case MENU_SELECT_CVARADD:
						{
							char buffer[32];
							data.RowsCvar.GetString(i, buffer, sizeof(buffer));
							float value = GetConVarFloat(FindConVar(buffer));
							FloatToString(value, sVals, sizeof(sVals));
							ReplaceString(sVals, sizeof(sVals), ".000000", "");
							ReplaceString(sTemp, sizeof(sTemp), "_OPT_", sVals);
						}

						// List options
						case MENU_SELECT_LIST:
						{
							ArrayList aHand = data.RowsData.Get(i, ROW_OPTIONS);
							if( aHand != null )
							{
								aHand.GetString(0, sOpts, sizeof(sOpts));

								// Translations
								if( data.Translation[0] )
								{
									Format(sOpts, sizeof(sOpts), "%T", sOpts, client);
								}

								// Loop each option, find selected in list
								StrCat(sOpts, sizeof(sOpts), SPLIT_CHAR);

								int opt = data.MenuVals[client].Get(i);
								int pos = 1;
								int last;
								int total;

								while( pos )
								{
									pos = StrContains(sOpts[last], SPLIT_CHAR);

									if( pos == -1 )
									{
										// End of line
										break;
									}
									else
									{
										if( opt == total )
										{
											sOpts[last + pos] = 0;
											ReplaceString(sTemp, sizeof(sTemp), "_OPT_", sOpts[last]);
											break;
										}

										total++;
									}

									last = last + pos + 1;
								}

							}
						}
					}
				}

				// Concatenate string
				StrCat(sMenu, sizeof(sMenu), sTemp);
				StrCat(sMenu, sizeof(sMenu), "\n");
			}
			}

		// Create menu
		Menu hMenu = new Menu(MenuExtra_Handler);
		hMenu.SetTitle(sMenu);
		hMenu.ExitButton = false;

		// Pages
		if( pages || data.MenuBack )
		{
			if( data.MenuNums )
			{
				if( g_bTranslation )
				{
					Format(sTemp, sizeof(sTemp), "%T", "EXTRA_MENU_LEFT", client);
					hMenu.AddItem("", sTemp);
					Format(sTemp, sizeof(sTemp), "%T", "EXTRA_MENU_RIGHT", client);
					hMenu.AddItem("", sTemp);
					Format(sTemp, sizeof(sTemp), "%T", "EXTRA_MENU_UP", client);
					hMenu.AddItem("", sTemp);
					Format(sTemp, sizeof(sTemp), "%T", "EXTRA_MENU_DOWN", client);
					hMenu.AddItem("", sTemp);
				}
				else
				{
					hMenu.AddItem("", "Select Left");
					hMenu.AddItem("", "Select Right");
					hMenu.AddItem("", "Move Up");
					hMenu.AddItem("", "Move Down");
				}

				hMenu.AddItem("", "Ignore 5", ITEMDRAW_DISABLED|ITEMDRAW_NOTEXT);
				hMenu.AddItem("", "Ignore 6", ITEMDRAW_DISABLED|ITEMDRAW_NOTEXT);
				hMenu.AddItem("", "Ignore 7", ITEMDRAW_SPACER);

				if( g_iPageOpen[client] > 0 || data.MenuBack )
				{
					Format(sTemp, sizeof(sTemp), "%T", "Previous", client);
					hMenu.AddItem("", sTemp);
				} else {
					hMenu.AddItem("", "Ignore 8", ITEMDRAW_DISABLED|ITEMDRAW_NOTEXT);
				}

				if( g_iPageOpen[client] < data.TotalPage )
				{
					Format(sTemp, sizeof(sTemp), "%T", "Next", client);
					hMenu.AddItem("", sTemp);
				} else {
					hMenu.AddItem("", "Ignore 9", ITEMDRAW_DISABLED|ITEMDRAW_NOTEXT);
				}

				hMenu.Pagination = false;
				hMenu.ExitButton = true;
			}
			else
			{
				if( g_iPageOpen[client] > 0 || data.MenuBack )
				{
					Format(sTemp, sizeof(sTemp), "%T", "Previous", client);
					hMenu.AddItem("", sTemp);
				} else {
					hMenu.AddItem("", "Ignore 1", ITEMDRAW_DISABLED|ITEMDRAW_NOTEXT);
				}

				if( g_iPageOpen[client] < data.TotalPage )
				{
					Format(sTemp, sizeof(sTemp), "%T", "Next", client);
					hMenu.AddItem("", sTemp);
				} else {
					hMenu.AddItem("", "Ignore 2", ITEMDRAW_DISABLED|ITEMDRAW_NOTEXT);
				}

				Format(sTemp, sizeof(sTemp), "%T", "Exit", client);
				hMenu.AddItem("", sTemp);
			}
		}
		else
		{
			if( data.MenuNums )
			{
				if( g_bTranslation )
				{
					Format(sTemp, sizeof(sTemp), "%T", "EXTRA_MENU_LEFT", client);
					hMenu.AddItem("", sTemp);
					Format(sTemp, sizeof(sTemp), "%T", "EXTRA_MENU_RIGHT", client);
					hMenu.AddItem("", sTemp);
					Format(sTemp, sizeof(sTemp), "%T", "EXTRA_MENU_UP", client);
					hMenu.AddItem("", sTemp);
					Format(sTemp, sizeof(sTemp), "%T", "EXTRA_MENU_DOWN", client);
					hMenu.AddItem("", sTemp);
				}
				else
				{
					hMenu.AddItem("", "Select Left");
					hMenu.AddItem("", "Select Right");
					hMenu.AddItem("", "Move Up");
					hMenu.AddItem("", "Move Down");
				}

				hMenu.Pagination = false;
				hMenu.ExitButton = true;
			}
			else
			{
				hMenu.AddItem("", "Ignore 1", ITEMDRAW_DISABLED|ITEMDRAW_NOTEXT);
				hMenu.AddItem("", "Ignore 2", ITEMDRAW_DISABLED|ITEMDRAW_NOTEXT);

				Format(sTemp, sizeof(sTemp), "%T", "Exit", client);
				hMenu.AddItem("", sTemp);
			}
		}


		// Display
		hMenu.Display(client, g_iMenuTime[client]);

		g_hMenu[client] = hMenu;
		g_iMenuID[client] = menu_id;
		g_bMenuOpen[client] = true;
		g_bMenuNums[client] = data.MenuNums;

		// Freeze client
		if( !data.MenuNums )
		{
			SetEntityMoveType(client, MOVETYPE_NONE);
		}
	}
}



// ====================================================================================================
//					MENU HANDLER
// ====================================================================================================
int MenuExtra_Handler(Menu menu, MenuAction action, int client, int type)
{
	switch( action )
	{
		case MenuAction_Select:
		{
			if( g_bMenuNums[client] )
			{
				switch( type )
				{
					case 0: // Left
					{
						if( GetGameTime() > g_fLastOpt[client] ) // Last selected option timeout
						{
							OnButton_Left(client);
						}
						else
						{
							// Redisplay menu
							g_fLastSel[client] = GetGameTime() + MAX_WAIT;
							DisplayExtraMenu(client, g_iMenuID[client]);
						}
					}
					case 1: // Right
					{
						if( GetGameTime() > g_fLastOpt[client] ) // Last selected option timeout
						{
							OnButton_Right(client);
						}
						else
						{
							// Redisplay menu
							g_fLastSel[client] = GetGameTime() + MAX_WAIT;
							DisplayExtraMenu(client, g_iMenuID[client]);
						}
					}
					case 2: // Up
					{
						if( GetGameTime() > g_fLastSel[client] ) // Last selected row timeout
						{
							OnButton_Up(client);
						}
						else
						{
							// Redisplay menu
							g_fLastSel[client] = GetGameTime() + MAX_WAIT;
							DisplayExtraMenu(client, g_iMenuID[client]);
						}
					}
					case 3: // Down
					{
						if( GetGameTime() > g_fLastSel[client] ) // Last selected row timeout
						{
							OnButton_Down(client);
						}
						else
						{
							// Redisplay menu
							g_fLastSel[client] = GetGameTime() + MAX_WAIT;
							DisplayExtraMenu(client, g_iMenuID[client]);
						}
					}
					case 7: // Previous
					{
						OnButton_Back(client);
					}
					case 8: // Next
					{
						OnButton_Next(client);
					}
					case 9: // Exit
					{
						OnButton_Exit(client);
						CancelMenu(menu);
					}
				}
			}
			else
			{
				switch( type )
				{
					case 0: // Back
					{
						OnButton_Back(client);
					}

					case 1: // Next
					{
						OnButton_Next(client);
					}

					case 2: // Exit
					{
						OnButton_Exit(client);
						CancelMenu(menu);
					}
				}
			}
		}
		case MenuAction_Cancel:
		{
			switch( type )
			{
				case MenuCancel_Exit, MenuCancel_Interrupted, MenuCancel_Timeout:
				{
					g_bMenuOpen[client] = false;

					if( !g_bMenuNums[client] )
					{
						SetEntityMoveType(client, MOVETYPE_WALK);
					}
					else if( type == MenuCancel_Exit )
					{
						OnButton_Exit(client);
					}
				}
			}
		}
		case MenuAction_End:
		{
			delete menu;
		}
	}

	return 0;
}



// ====================================================================================================
//					MENU MOVEMENT
// ====================================================================================================
public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon, int &subtype, int &cmdnum, int &tickcount, int &seed, int mouse[2])
{
	if( g_bMenuOpen[client] && !g_bMenuNums[client] ) // Menu is open AND using W/A/S/D
	{
		if( GetGameTime() > g_fLastSel[client] ) // Last selected row timeout
		{
			if( buttons & IN_BACK )
			{
				OnButton_Down(client);
			}
			else if( buttons & IN_FORWARD )
			{
				OnButton_Up(client);
			}
		}

		if( GetGameTime() > g_fLastOpt[client] ) // Last selected option timeout
		{
			if( buttons & IN_MOVERIGHT )
			{
				OnButton_Right(client);
			}
			else if( buttons & IN_MOVELEFT )
			{
				OnButton_Left(client);
			}
		}
	}

	return Plugin_Continue;
}



// ====================================================================================================
//					MENU CLICKS
// ====================================================================================================
void OnButton_Up(int client)
{
	int menu_id = g_iMenuID[client];

	char sKey[MAX_KEYS];
	IntToString(menu_id, sKey, sizeof(sKey));

	#if VERIFY_INDEXES
	if( g_AllMenus.ContainsKey(sKey) )
	#endif
	{
		MenuData data;
		g_AllMenus.GetArray(sKey, data, sizeof(data));

		int length = data.RowsData.Length;

		g_iSelected[client]--;

		int max = -1;
		int min = g_iSelected[client];

		// Validate prev entry index
		if( min < 0 || g_iPageOpen[client] != data.RowsData.Get(min, ROW_PAGE) || data.RowsData.Get(min, ROW_TYPE) == MENU_ENTRY )
		{
			min = -1;

			// Find min/max index for current page
			for( int i = length - 1; i >= 0 ; i-- )
			{
				if( g_iPageOpen[client] == data.RowsData.Get(i, ROW_PAGE) && data.RowsData.Get(i, ROW_TYPE) != MENU_ENTRY )
				{
					if( max == -1 ) max = i;
					if( min == -1 && i <= g_iSelected[client] ) min = i;
				}
			}

			if( min == -1 )
			{
				g_iSelected[client] = max;
			}
			else
			{
				g_iSelected[client] = min;
			}
		}

		// Sound
		if( g_sCvarSoundMove[0] )
		{
			EmitSoundToClient(client, g_sCvarSoundMove);
		}

		// Redisplay menu
		g_fLastSel[client] = GetGameTime() + MAX_WAIT;
		DisplayExtraMenu(client, g_iMenuID[client]);
	}
}

void OnButton_Down(int client)
{
	int menu_id = g_iMenuID[client];

	char sKey[MAX_KEYS];
	IntToString(menu_id, sKey, sizeof(sKey));

	#if VERIFY_INDEXES
	if( g_AllMenus.ContainsKey(sKey) )
	#endif
	{
		MenuData data;
		g_AllMenus.GetArray(sKey, data, sizeof(data));

		int length = data.RowsData.Length;

		g_iSelected[client]++;

		int max = g_iSelected[client];
		int min = -1;

		// Validate next entry index
		if( max >= length || data.RowsData.Get(max, ROW_TYPE) == MENU_ENTRY || g_iPageOpen[client] != data.RowsData.Get(max, ROW_PAGE) )
		{
			max = -1;

			// Find min/max index for current page
			for( int i = 0; i < length; i++ )
			{
				if( data.RowsData.Get(i, ROW_TYPE) != MENU_ENTRY && g_iPageOpen[client] == data.RowsData.Get(i, ROW_PAGE) )
				{
					if( min == -1 ) min = i;
					if( max == -1 && i >= g_iSelected[client] ) max = i;
				}
			}

			if( max == -1 || max >= length )
			{
				g_iSelected[client] = min;
			}
			else
			{
				g_iSelected[client] = max;
			}
		}

		// Sound
		if( g_sCvarSoundMove[0] )
		{
			EmitSoundToClient(client, g_sCvarSoundMove);
		}

		// Redisplay menu
		g_fLastSel[client] = GetGameTime() + MAX_WAIT;
		DisplayExtraMenu(client, g_iMenuID[client]);
	}
}

void OnButton_Left(int client)
{
	int menu_id = g_iMenuID[client];

	char sKey[MAX_KEYS];
	IntToString(menu_id, sKey, sizeof(sKey));

	#if VERIFY_INDEXES
	if( g_AllMenus.ContainsKey(sKey) )
	#endif
	{
		MenuData data;
		g_AllMenus.GetArray(sKey, data, sizeof(data));

		bool trigger = true;
		int index = g_iSelected[client];

		// Depending on menu type, toggle of or decrement value
		switch( data.RowsData.Get(index, ROW_TYPE) )
		{
			case MENU_SELECT_ONOFF:
			{
				if( data.MenuVals[client].Get(index) == 1 ) // Prevent triggering if already unselected
				{
					data.MenuVals[client].Set(index, 0);
				}
				else
				{
					trigger = false;
				}
			}
			case MENU_SELECT_CVARONOFF:
			{
				if( data.MenuVals[client].Get(index) == 1 ) // Prevent triggering if already unselected
				{
					char buffer[32];
					data.RowsCvar.GetString(index, buffer, sizeof(buffer));
					SetConVarBool(FindConVar(buffer), false);
					data.MenuVals[client].Set(index, 0);
				}
				else
				{
					trigger = false;
				}
			}

			case MENU_SELECT_ADD:
			{
				// Decrement, validate value
				int new_val = data.RowsData.Get(index, ROW_INCRE);
				int old_val = data.MenuVals[client].Get(index);
				int min = data.RowsData.Get(index, ROW_IN_MIN);
				new_val = old_val - new_val;
				if( new_val < min ) new_val = min;

				data.MenuVals[client].Set(index, new_val);
			}

			case MENU_SELECT_CVARADD:
			{
				// Decrement, validate value
				char buffer[32];
				data.RowsCvar.GetString(index, buffer, sizeof(buffer));
				int old_val = GetConVarInt(FindConVar(buffer));
				int new_val = data.RowsData.Get(index, ROW_INCRE);
				int min = data.RowsData.Get(index, ROW_IN_MIN);
				new_val = old_val - new_val;
				if( new_val < min ) new_val = min;
				SetConVarInt(FindConVar(buffer), new_val);
				data.MenuVals[client].Set(index, new_val);
			}

			case MENU_SELECT_LIST:
			{
				// Get size of list of options and select last
				ArrayList aHand;
				aHand = data.RowsData.Get(index, ROW_OPTIONS);

				if( aHand != null )
				{
					int length = data.RowsData.Get(index, ROW_OPS_LEN);

					int opt = data.MenuVals[client].Get(index) - 1;
					if( opt < 0 )
					{
						opt = length - 1;
					}

					data.MenuVals[client].Set(index, opt);
				}
			}

			case MENU_ENTRY:
			{
				trigger = false;
			}
		}

		// Sound
		if( g_sCvarSoundClick[0] )
		{
			EmitSoundToClient(client, g_sCvarSoundClick);
		}

		// Display
		g_fLastOpt[client] = GetGameTime() + MAX_WAIT;

		if( data.RowsData.Get(index, ROW_CLOSE) == false )
		{
			DisplayExtraMenu(client, g_iMenuID[client]);
		}
		else
		{
			CloseExtraMenu(client);
		}

		// Fire forward on selection
		if( trigger )
		{
			Call_StartForward(g_hFWD_ExtraMenu_OnSelect);
			Call_PushCell(client);
			Call_PushCell(menu_id);
			Call_PushCell(data.RowsData.Get(index, ROW_INDEX));
			Call_PushCell(data.MenuVals[client].Get(index));
			Call_Finish();
		}

		g_AllMenus.SetArray(sKey, data, sizeof(data));
	}
}

void OnButton_Right(int client)
{
	int menu_id = g_iMenuID[client];

	char sKey[MAX_KEYS];
	IntToString(menu_id, sKey, sizeof(sKey));

	#if VERIFY_INDEXES
	if( g_AllMenus.ContainsKey(sKey) )
	#endif
	{
		MenuData data;
		g_AllMenus.GetArray(sKey, data, sizeof(data));

		bool trigger = true;
		int index = g_iSelected[client];

		// Depending on menu type, toggle on or increment value
		switch( data.RowsData.Get(index, ROW_TYPE) )
		{
			case MENU_SELECT_ONOFF:
			{
				if( data.MenuVals[client].Get(index) == 0 ) // Prevent triggering if already selected
				{
					data.MenuVals[client].Set(index, 1);
				}
				else
				{
					trigger = false;
				}
			}
			case MENU_SELECT_CVARONOFF:
			{
				if( data.MenuVals[client].Get(index) == 0 ) // Prevent triggering if already selected
				{
					char buffer[32];
					data.RowsCvar.GetString(index, buffer, sizeof(buffer));
					SetConVarBool(FindConVar(buffer), true);
					data.MenuVals[client].Set(index, 1);
				}
				else
				{
					trigger = false;
				}
			}

			case MENU_SELECT_ADD:
			{
				// Increment, validate value
				int new_val = data.RowsData.Get(index, ROW_INCRE);
				int old_val = data.MenuVals[client].Get(index);
				int max = data.RowsData.Get(index, ROW_IN_MAX);
				new_val = old_val + new_val;
				if( new_val > max ) new_val = max;

				data.MenuVals[client].Set(index, new_val);
			}
			case MENU_SELECT_CVARADD:
			{
				// Increment, validate value
				char buffer[32];
				data.RowsCvar.GetString(index, buffer, sizeof(buffer));
				int old_val = GetConVarInt(FindConVar(buffer));
				int new_val = data.RowsData.Get(index, ROW_INCRE);
				int max = data.RowsData.Get(index, ROW_IN_MAX);
				new_val = old_val + new_val;
				if( new_val > max ) new_val = max;
				SetConVarInt(FindConVar(buffer), new_val);
				data.MenuVals[client].Set(index, new_val);
			}

			case MENU_SELECT_LIST:
			{
				// Get size of list of options and select next
				ArrayList aHand;
				aHand = data.RowsData.Get(index, ROW_OPTIONS);

				if( aHand != null )
				{
					int length = data.RowsData.Get(index, ROW_OPS_LEN);

					int opt = data.MenuVals[client].Get(index) + 1;
					if( opt >= length )
					{
						opt = 0;
					}

					data.MenuVals[client].Set(index, opt);
				}
			}

			case MENU_ENTRY:
			{
				trigger = false;
			}
		}

		// Sound
		if( g_sCvarSoundClick[0] )
		{
			EmitSoundToClient(client, g_sCvarSoundClick);
		}

		// Display
		g_fLastOpt[client] = GetGameTime() + MAX_WAIT;

		if( data.RowsData.Get(index, ROW_CLOSE) == false )
		{
			DisplayExtraMenu(client, g_iMenuID[client]);
		}
		else
		{
			CloseExtraMenu(client);
		}

		// Fire forward on selection
		if( trigger )
		{
			Call_StartForward(g_hFWD_ExtraMenu_OnSelect);
			Call_PushCell(client);
			Call_PushCell(menu_id);
			Call_PushCell(data.RowsData.Get(index, ROW_INDEX));
			Call_PushCell(data.MenuVals[client].Get(index));
			Call_Finish();
		}

		g_AllMenus.SetArray(sKey, data, sizeof(data));
	}
}

void OnButton_Back(int client)
{
	int menu_id = g_iMenuID[client];

	char sKey[MAX_KEYS];
	IntToString(menu_id, sKey, sizeof(sKey));

	#if VERIFY_INDEXES
	if( g_AllMenus.ContainsKey(sKey) )
	#endif
	{
		MenuData data;
		g_AllMenus.GetArray(sKey, data, sizeof(data));

		g_iPageOpen[client]--;
		if( g_iPageOpen[client] < 0 )
		{
			g_iPageOpen[client] = 0;
			Call_StartForward(g_hFWD_ExtraMenu_OnSelect);
			Call_PushCell(client);
			Call_PushCell(menu_id);
			Call_PushCell(-2);
			Call_PushCell(0);
			Call_Finish();
		}

		// New selected index for page
		else if( g_iPageOpen[client] >= 0 )
		{
			int length = data.RowsData.Length;

			for( int i = 0; i < length; i++ )
			{
				// Default selected option
				if( data.RowsData.Get(i, ROW_TYPE) != MENU_ENTRY && g_iPageOpen[client] == data.RowsData.Get(i, ROW_PAGE) )
				{
					g_iSelected[client] = i;
					break;
				}
			}

			DisplayExtraMenu(client, g_iMenuID[client]);
		}
	}
}

void OnButton_Next(int client)
{
	int menu_id = g_iMenuID[client];

	char sKey[MAX_KEYS];
	IntToString(menu_id, sKey, sizeof(sKey));

	#if VERIFY_INDEXES
	if( g_AllMenus.ContainsKey(sKey) )
	#endif
	{
		MenuData data;
		g_AllMenus.GetArray(sKey, data, sizeof(data));


		// New page
		g_iPageOpen[client]++;
		if( g_iPageOpen[client] > data.TotalPage) g_iPageOpen[client] = data.TotalPage;

		// New selected index for page
		int length = data.RowsData.Length;

		for( int i = 0; i < length; i++ )
		{
			// Default selected option
			if( data.RowsData.Get(i, ROW_TYPE) != MENU_ENTRY && g_iPageOpen[client] == data.RowsData.Get(i, ROW_PAGE) )
			{
				g_iSelected[client] = i;
				break;
			}
		}

		DisplayExtraMenu(client, g_iMenuID[client]);
	}
}

void OnButton_Exit(int client)
{
	int menu_id = g_iMenuID[client];

	char sKey[MAX_KEYS];
	IntToString(menu_id, sKey, sizeof(sKey));

	#if VERIFY_INDEXES
	if( g_AllMenus.ContainsKey(sKey) )
	#endif
	{
		MenuData data;
		g_AllMenus.GetArray(sKey, data, sizeof(data));

		Call_StartForward(g_hFWD_ExtraMenu_OnSelect);
		Call_PushCell(client);
		Call_PushCell(menu_id);
		Call_PushCell(-1);
		Call_PushCell(0);
		Call_Finish();

		g_iMenuID[client] = -1;
		g_iSelected[client] = 0;
		g_bMenuOpen[client] = false;

		if( !data.MenuNums )
		{
			SetEntityMoveType(client, MOVETYPE_WALK);
		}
	}
}



// ====================================================================================================
//					CLOSE MENU
// ====================================================================================================
// Send a blank menu to the client when auto close is enabled. CancelMenu() would throw invalid handle errors and CancelClientMenu() did nothing.
// ClientCommand(client, "slot10"); works but shows "FCVAR_SERVER_CAN_EXECUTE prevented server running command: menuselect" in client console.
void CloseExtraMenu(int client)
{
	g_iMenuID[client] = -1;
	g_iSelected[client] = 0;
	g_bMenuOpen[client] = false;

	if( !g_bMenuNums[client] )
	{
		SetEntityMoveType(client, MOVETYPE_WALK);
	}

	Menu hMenu = new Menu(MenuClose_Handler);
	hMenu.SetTitle(" ");
	hMenu.ExitButton = false;
	hMenu.AddItem(" ", " ", ITEMDRAW_DISABLED|ITEMDRAW_NOTEXT);
	hMenu.Display(client, 1);
	delete hMenu;
}

int MenuClose_Handler(Menu menu, MenuAction action, int client, int type)
{
	switch( action )
	{
		case MenuAction_End:
		{
			delete menu;
		}
	}

	return 0;
}
