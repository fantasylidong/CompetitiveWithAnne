/*
*	Extra Menu API
*	Copyright (C) 2022 Silvers
*
*	This program is free software: you can redistribute it and/or modify
*	it under the terms of the GNU General Public License as published by
*	the Free Software Foundation, either version 3 of the License, or
*	(at your option) any later version.
*/

#if defined _extra_menu_api_included
 #endinput
#endif
#define _extra_menu_api_included

public SharedPlugin __pl_extramenu =
{
	name = "extra_menu",
	file = "extra_menu.smx",
#if defined REQUIRE_PLUGIN
	required = 1,
#else
	required = 0,
#endif
};

#if !defined REQUIRE_PLUGIN
public void __pl_extramenu_SetNTVOptional()
{
	MarkNativeAsOptional("ExtraMenu_Create");
	MarkNativeAsOptional("ExtraMenu_Delete");
	MarkNativeAsOptional("ExtraMenu_AddOptions");
	MarkNativeAsOptional("ExtraMenu_AddEntry");
	MarkNativeAsOptional("ExtraMenu_NewPage");
	MarkNativeAsOptional("ExtraMenu_Display");
}
#endif

enum EXTRA_MENU_TYPE
{
	MENU_ENTRY,
	MENU_SELECT_ONLY,
	MENU_SELECT_ONOFF,
	MENU_SELECT_LIST,
	MENU_SELECT_ADD,
}

native int ExtraMenu_Create(bool back = false, char[] translation = "", bool buttons_nums = false);
native bool ExtraMenu_Delete(int menu_id);
native bool ExtraMenu_AddEntry(int menu_id, char[] entry, EXTRA_MENU_TYPE type, bool close = false, int default_value = 0, any add_value = 0, any add_min = -999999, any add_max = 999999);
native bool ExtraMenu_AddOptions(int menu_id, char[] entry);
native void ExtraMenu_NewPage(int menu_id);
native bool ExtraMenu_Display(int client, int menu_id, int time = MENU_TIME_FOREVER);

forward void ExtraMenu_OnSelect(int client, int menu_id, int option, int value);
