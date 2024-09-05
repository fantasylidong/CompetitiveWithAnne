#pragma semicolon 1
#pragma newdecls required
// 头文件
#include <sourcemod>
#include <updater>
#define UPDATE_URL    "http://home.trygek.com:8880/left4dead2/addons/sourcemod/Anne_Updater.txt"

// 插件基本信息，根据 GPL 许可证条款，需要修改插件请勿修改此信息！
public Plugin myinfo = 
{
	name 			= "My plugins/file auto update",
	author 			= "东",
	description 	= "自动更新插件等文件",
	version 		= "2022.05.05",
	url 			= "https://github.com/fantasylidong/"
}
static bool firstStart = true;
public void OnPluginStart()
{
    if (LibraryExists("updater"))
    {
        Updater_AddPlugin(UPDATE_URL);
        if(firstStart){
            ServerCommand("sm_updater_forcecheck");
            firstStart = false;
        }   
    } 
}
public void OnLibraryAdded(const char[] name)
{
    if (StrEqual(name, "updater"))
    {
        Updater_AddPlugin(UPDATE_URL);
        if(firstStart){
            ServerCommand("sm_updater_forcecheck");
            firstStart = false;
        }   
    }
}