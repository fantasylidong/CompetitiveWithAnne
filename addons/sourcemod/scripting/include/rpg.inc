/*
*	rpg
*	Copyright (C) 2022 morzlee
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

#if defined _rpg_included
 #endinput
#endif
#define _rpg_included



public SharedPlugin __pl_rpg = 
{
	name = "rpg",
	file = "rpg.smx",
#if defined REQUIRE_PLUGIN
	required = 1,
#else
	required = 0,
#endif
};

#if !defined REQUIRE_PLUGIN
public void __pl_rpg_SetNTVOptional()
{
	MarkNativeAsOptional("L4D_RPG_GetValue");
	MarkNativeAsOptional("L4D_RPG_GetGlobalValue");
	MarkNativeAsOptional("L4D_RPG_SetGlobalValue");
	// 新增：玩家级 Setter
    MarkNativeAsOptional("L4D_RPG_SetValue");
}
#endif


// The options Values used for the natives:
enum TARGET_VALUE_INDEX
{
	INDEX_POINTS	= 0,	// (int)	- "用户分数"
	INDEX_BLOOD		= 1,	// (int)	- "用户是否开启回血"
	INDEX_MELEE		= 2,	// (int)	- "用户使用的开局近战"
	INDEX_HAT		= 3,	// (int)	- "用户使用的帽子"
	INDEX_GLOW		= 4,	// (int)	- "用户使用的轮廓"
	INDEX_SKIN		= 5,	// (int)	- "用户使用的皮肤"
	INDEX_FIRSTBUY	= 6,	// (int)	- "用户是不是还没白嫖枪械"
	INDEX_RECOIL	= 7,	// (int)	- "用户是否开启枪械抖动"
	INDEX_VALID		= 8,	// (int)	- "该局游戏是否有效"
	INDEX_USEBUY	= 9,	// (int)	- "该局游戏是否使用了B数"
}



/**
* @brief当此局游戏有效性发生变化时，发送此forward，valid代表变化成什么.
*
* @param	valid	此局游戏是否有效
*
* @return	void
*/
forward void OnValidValveChange(bool valid);

/**
* @brief当此局游戏有人用了B数时，发送此forward，usebuy代表变化成什么.
*
* @param	usebuy	此局游戏是否使用了B数
*
* @return	void
*/
forward void OnBuyValveChange(bool usebuy);



/**
* @brief 返回rpg插件里的值
*
* @param	index			需要获取数据的玩家
* @param	option			（0-7）
*
* @return	-1为获取失败，其余为正常
*/
native any L4D_RPG_GetValue(int client, TARGET_VALUE_INDEX option);

/**
* @brief 返回rpg插件里的值
*
* @param	index			需要获取此局数据
* @param	option			（8-9）
*
* @return	-1为获取失败，其余为正常
*/
native any L4D_RPG_GetGlobalValue(TARGET_VALUE_INDEX option);

/**
* @brief 设置rpg插件里的全局变量
*
* @param	index			需要获取此局数据
* @param	option			（8-9）
*
* @return	-1为设置失败，其余为正常
*/
native any L4D_RPG_SetGlobalValue(TARGET_VALUE_INDEX option, bool vaule);

/**
* @brief 设置rpg插件里的“玩家值”（如 INDEX_RECOIL 等）
*
* @param client   目标玩家
* @param option   TARGET_VALUE_INDEX（0-7）
* @param value    通常为int/bool（true=1/false=0）
*
* @return 1为成功，-1失败
*/
native any L4D_RPG_SetValue(int client, TARGET_VALUE_INDEX option, any value);