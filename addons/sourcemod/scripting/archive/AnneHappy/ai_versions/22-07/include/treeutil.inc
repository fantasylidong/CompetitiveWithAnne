enum
{
	TEAM_SPECTATOR = 1,
	TEAM_SURVIVOR,
	TEAM_INFECTED
}

enum
{
	ZC_SMOKER = 1,
	ZC_BOOMER,
	ZC_HUNTER,
	ZC_SPITTER,
	ZC_JOCKEY,
	ZC_CHARGER,
	ZC_WITCH,
	ZC_TANK,
}

enum
{
	ID_HUNTER,
	ID_CHARGER,
	ID_CHARGER_WALL,
	ID_CHARGER_GROUND,
	ID_PINNED_GETUPANIM_SIZE_SPACE
}
enum
{
	ID_SINGLE_PISTOL,
	ID_DUAL_PISTOLS,
	ID_INCAPANIM_SIZE_SPACE
}
enum SurvivorCharacter
{
	SC_INVALID = -1,
	SC_NICK = 0,
	SC_ROCHELLE,
	SC_COACH,
	SC_ELLIS,
	SC_BILL,
	SC_ZOEY,
	SC_LOUIS,
	SC_FRANCIS,
	SC_SIZE_SPACE
};
stock const char SurvivorModels[SC_SIZE_SPACE][] =
{
	"models/survivors/survivor_gambler.mdl",	// 西装
	"models/survivors/survivor_producer.mdl",	// 女人
	"models/survivors/survivor_coach.mdl",		// 黑胖
	"models/survivors/survivor_mechanic.mdl",	// 帽子
	"models/survivors/survivor_namvet.mdl",		// 比尔
	"models/survivors/survivor_teenangst.mdl",	// 佐伊
	"models/survivors/survivor_manager.mdl",	// 路易斯
	"models/survivors/survivor_biker.mdl"		// 弗朗西斯
};
stock const int GetUpAnimations[SC_SIZE_SPACE][ID_PINNED_GETUPANIM_SIZE_SPACE] =
{
	{620, 667, 671, 672},	// 西装
	{629, 674, 678, 679},	// 女人
	{621, 656, 660, 661},	// 黑胖
	{625, 671, 675, 676},	// 帽子
	{528, 759, 763, 764},	// 比尔
	{537, 819, 823, 824},	// 佐伊
	{528, 759, 763, 764},	// 路易斯
	{531, 762, 766, 767}	// 弗朗西斯
};
stock const int IncappAnimations[SC_SIZE_SPACE][ID_PINNED_GETUPANIM_SIZE_SPACE] =
{
	// 0 位为持单手枪倒地的动画序列，1 位为持双手枪倒地的动画序列
	{612, 613},	// 西装
	{621, 622},	// 女人
	{613, 614},	// 黑胖
	{617, 618},	// 帽子
	{520, 521},	// 比尔
	{525, 526},	// 佐伊
	{520, 521},	// 路易斯
	{523, 524}	// 弗朗西斯
};

stock static StringMap mSurvivorModelsTrie = null;

#define PLUGIN_SCRIPTLOGIC "plugin_scripting_logic_entity"
#define COMMANDABOT_ATTACK "CommandABot({cmd = 0, bot = GetPlayerFromUserID(%i), target = GetPlayerFromUserID(%i)})"
#define COMMANDABOT_MOVE   "CommandABot({cmd = 1, pos = Vector(%f, %f, %f), bot = GetPlayerFromUserID(%i)})"
#define COMMANDABOT_RESET  "CommandABot({cmd = 3, bot = GetPlayerFromUserID(%i)})"

// *************************
// 			生还者
// *************************
// 判断是否有效玩家 id，有效返回 true，无效返回 false
stock bool IsValidClient(int client)
{
	if (client > 0 && client <= MaxClients && IsClientConnected(client) && IsClientInGame(client))
	{
		return true;
	}
	else
	{
		return false;
	}
}
// 判断生还者是否有效，有效返回 true，无效返回 false
stock bool IsValidSurvivor(int client)
{
	if (IsValidClient(client) && GetClientTeam(client) == view_as<int>(TEAM_SURVIVOR))
	{
		return true;
	}
	else
	{
		return false;
	}
}
// 判断玩家是否倒地，倒地返回 true，未倒地返回 false
// @client：需要判断的生还者客户端索引
stock bool IsClientIncapped(int client)
{
	if (!IsValidClient(client)) { return false; }
	return view_as<bool>(GetEntProp(client, Prop_Send, "m_isIncapacitated"));
}
// 判断生还者是否被控，被控返回 true，未被控返回 false
// @client：需要判断的生还者客户端索引
stock bool IsClientPinned(int client)
{
	if (!IsValidSurvivor(client)) { return false; }
	return GetEntPropEnt(client, Prop_Send, "m_tongueOwner") > 0 
			|| GetEntPropEnt(client, Prop_Send, "m_pounceAttacker") > 0 
			|| GetEntPropEnt(client, Prop_Send, "m_carryAttacker") > 0 || GetEntPropEnt(client, Prop_Send, "m_pummelAttacker") > 0 
			|| GetEntPropEnt(client, Prop_Send, "m_jockeyAttacker") > 0;
}
// 判断生还者被哪种类型的特感控制，生还者无效或未被控返回 -1
// @client：需要判断的生还者客户端索引
stock int GetClientPinnedInfectedType(int client)
{
	if (!IsValidClient(client)) { return -1; }
	else if (GetEntPropEnt(client, Prop_Send, "m_tongueOwner") > 0) { return ZC_SMOKER; }
	else if (GetEntPropEnt(client, Prop_Send, "m_pounceAttacker") > 0) { return ZC_HUNTER; }
	else if (GetEntPropEnt(client, Prop_Send, "m_carryAttacker") > 0 || GetEntPropEnt(client, Prop_Send, "m_pummelAttacker") > 0) { return ZC_CHARGER; }
	else if (GetEntPropEnt(client, Prop_Send, "m_jockeyAttacker") > 0) { return ZC_JOCKEY; }
	return -1;
}
// 判断生还者是否处于挂边状态，正在挂边返回 true，不在挂边返回 false
stock bool IsClientHanging(int client)
{
	if (IsValidSurvivor(client))
	{
		return view_as<bool>(GetEntProp(client, Prop_Send, "m_isHangingFromLedge", 1) || view_as<bool>(GetEntProp(client, Prop_Send, "m_isFallingFromLedge", 1)));
	}
	return false;
}
// 使用客户端 ID 识别生还者索引，有效返回生还者索引 ID，无效返回 -1
stock int IdentifySurvivor(int client)
{
	if (IsValidSurvivor(client))
	{
		char model_name[42] = {'\0'};
		GetClientModel(client, model_name, sizeof(model_name));
		return ModelToSorce(model_name);
	}
	return view_as<int>(SC_INVALID);
}
// 通过生还者模型名称返回生还者索引
stock int ModelToSorce(const char[] model_name)
{
	if (mSurvivorModelsTrie == null)
	{
		InitSurvivorModelTrie();
	}
	int sorce_index = -1;
	if (mSurvivorModelsTrie.GetValue(model_name, sorce_index))
	{
		return sorce_index;
	}
	return view_as<int>(SC_INVALID);
}
stock void InitSurvivorModelTrie()
{
	mSurvivorModelsTrie = new StringMap();
	for (int i = 0; i < view_as<int>(SC_SIZE_SPACE); i++)
	{
		mSurvivorModelsTrie.SetValue(SurvivorModels[i], i);
	}
}
// 获取当前客户端实血数量，返回实血数量，客户端无效则返回 -1
stock int GetPermanentHealth(int client)
{
	if (IsValidClient(client))
	{
		return GetEntProp(client, Prop_Send, "m_iHealth");
	}
	return -1;
}
// 获取当前生还者虚血数量，返回虚血数量，生还者无效则返回 -1
stock int GetSurvivorTempHealth(int client)
{
	if (IsValidSurvivor(client))
	{
		int temp_health = RoundToCeil(GetEntPropFloat(client, Prop_Send, "m_healthBuffer") - ((GetGameTime() - GetEntPropFloat(client, Prop_Send, "m_healthBufferTime")) * GetConVarFloat(FindConVar("pain_pills_decay_rate")))) - 1;
		return temp_health > 0 ? temp_health : 0;
	}
	return -1;
}
// 获取当前生还者倒地次数，返回倒地次数，生还者无效则返回 -1
stock int GetClientIncappedCount(int client)
{
	if (IsValidSurvivor(client))
	{
		return GetEntProp(client, Prop_Send, "m_currentReviveCount");
	}
	return -1;
}
// 随机获取一个未死亡，未被控，未倒地的生还者，如有则返回生还者 id，无则返回 0
stock int GetRandomMobileSurvivor()
{
	ArrayList survivorList = new ArrayList();
	for (int client = 1; client <= MaxClients; client++)
	{
		if (IsValidSurvivor(client)) { survivorList.Push(client); }
	}
	if (survivorList.Length == 0) { return 0; }
	int targetSurvivor = survivorList.Get(GetRandomInt(0, survivorList.Length - 1));
	delete survivorList;
	return targetSurvivor;
}
// 获取距离某玩家最近的有效（未死亡，未倒地，未被控）生还者，如有则返回生还者 id，玩家无效或未找到则返回 0
stock int GetClosetMobileSurvivor(int client, int exclude_client = -1)
{
	if (IsValidClient(client))
	{
		int target = -1;
		float selfPos[3] = {0.0}, targetPos[3] = {0.0};
		GetClientAbsOrigin(client, selfPos);
		// 遍历所有玩家
		ArrayList targetList = new ArrayList(2);
		for (int newTarget = 1; newTarget <= MaxClients; newTarget++)
		{
			// 找到了一个有效玩家
			if (IsValidSurvivor(newTarget) && IsPlayerAlive(newTarget) && !IsClientIncapped(newTarget) &&!IsClientPinned(newTarget) && newTarget != client && newTarget != exclude_client)
			{
				GetClientAbsOrigin(newTarget, targetPos);
				float dist = GetVectorDistance(selfPos, targetPos);
				// int Push(any value)，返回新增的索引值，集合中存储（0：距离，1：玩家索引）
				// void Set(int index, any value, int block, bool asChar)
				targetList.Set(targetList.Push(dist), newTarget, 1);
			}
		}
		if (targetList.Length == 0)
		{
			delete targetList;
			return 0;
		}
		targetList.Sort(Sort_Ascending, Sort_Float);
		target = targetList.Get(0, 1);
		delete targetList;
		return target;
	}
	return 0;
}
// 获取某玩家到最近或指定生还者的距离，如果存在有效最近或指定生还者则返回距离，无则返回 -1
stock int GetClosetSurvivorDistance(int client, int specific_survivor = -1)
{
	if (IsValidClient(client))
	{
		float self_pos[3] = {0.0}, target_pos[3] = {0.0};
		int target_survivor = -1;
		GetClientAbsOrigin(client, self_pos);
		if (IsValidSurvivor(specific_survivor))
		{
			target_survivor = specific_survivor;
		}
		else
		{
			target_survivor = GetClosetMobileSurvivor(client);
		}
		if (IsValidSurvivor(target_survivor))
		{
			GetEntPropVector(target_survivor, Prop_Send, "m_vecOrigin", target_pos);
			return RoundToNearest(GetVectorDistance(self_pos, target_pos));
		}
		else
		{
			return -1;
		}
	}
	else
	{
		return -1;
	}
}

// *************************
// 			特感方
// *************************
// 判断特感是否有效，有效返回 true，无效返回 false
stock bool IsValidInfected(int client)
{
	if (IsValidClient(client) && GetClientTeam(client) == view_as<int>(TEAM_INFECTED))
	{
		return true;
	}
	else
	{
		return false;
	}
}
// 判断是否 Bot 特感，是返回 true，否返回 false
stock bool IsBotInfected(int client)
{
	if (IsValidInfected(client) && IsFakeClient(client))
	{
		return true;
	}
	else
	{
		return false;
	}
}
// 获取特感类型，成功返回特感类型，失败返回 0
stock int GetInfectedClass(int client)
{
	if (IsValidInfected(client))
	{
		return GetEntProp(client, Prop_Send, "m_zombieClass");
	}
	else
	{
		return 0;
	}
}
// 判断特感是否处于灵魂状态，是返回 1，否返回 0，无效返回 -1
stock int IsInGhostState(int client)
{
	if (IsValidInfected(client))
	{
		return view_as<bool>(GetEntProp(client, Prop_Send, "m_isGhost"));
	}
	else
	{
		return -1;
	}
}

// *************************
// 			其他类
// *************************
// 获取生还者数量，可指定是否包含 bot 和死亡的玩家
stock int GetSurvivorCount(bool include_bot = true, bool include_death = false)
{
	int count = 0;
	for (int client = 1; client <= MaxClients; client++)
	{
		if (IsValidSurvivor(client) && include_bot && include_death)
		{
			count += 1;
		}
		else if (IsValidSurvivor(client) && !include_bot && !include_death)
		{
			if (!IsFakeClient(client) && IsPlayerAlive(client))
			{
				count += 1;
			}
		}
		else if (IsValidSurvivor(client) && !include_bot && include_death)
		{
			if (!IsFakeClient(client))
			{
				count += 1;
			}
		}
		else if (IsValidSurvivor(client) && include_bot && !include_death)
		{
			if (IsPlayerAlive(client))
			{
				count += 1;
			}
		}
	}
	return count;
}
// 检测某个坐标是否能被任意生还者看到，如果有一个生还者能看见这个位置，返回 true，所有生还者都不可见这个位置，返回 false
stock bool Pos_IsVisibleTo_Player(int self, float refpos[3])
{
	float target_pos[3] = {0.0};
	for (int client = 1; client <= MaxClients; client++)
	{
		if (IsClientConnected(client) && IsClientInGame(client) && GetClientTeam(client) == view_as<int>(TEAM_SURVIVOR) && IsPlayerAlive(client))
		{
			GetClientEyePosition(client, target_pos);
			Handle hTrace = TR_TraceRayFilterEx(refpos, target_pos, MASK_VISIBLE, RayType_EndPoint, TR_RayFilter, self);
			if (!TR_DidHit(hTrace) || TR_GetEntityIndex(hTrace) == client)
			{
				delete hTrace;
				hTrace = INVALID_HANDLE;
				return true;
			}
			delete hTrace;
			hTrace = INVALID_HANDLE;
		}
	}
	return false;
}
// 检测某个玩家是否能看到指定生还者，能看见返回 true，不能看见则返回 false
stock bool Player_IsVisible_To(int client, int target)
{
	float self_pos[3] = {0.0}, target_pos[3] = {0.0}, look_at[3] = {0.0}, vec_angles[3] = {0.0};
	GetClientEyePosition(client, self_pos);
	GetClientEyePosition(target, target_pos);
	MakeVectorFromPoints(self_pos, target_pos, look_at);
	GetVectorAngles(look_at, vec_angles);
	Handle hTrace = TR_TraceRayFilterEx(self_pos, vec_angles, MASK_VISIBLE, RayType_Infinite, TR_RayFilter, client);
	if (TR_DidHit(hTrace))
	{
		if(TR_GetEntityIndex(hTrace) == target)
		{
			delete hTrace;
			hTrace = INVALID_HANDLE;
			return true;
		}
	}
	delete hTrace;
	hTrace = INVALID_HANDLE;
	return false;
}
// 检测某个玩家是否能看到任意生还者，能看见返回 true，不能看见则返回 false
stock bool Player_IsVisible_To_AnyPlayer(int client)
{
	float self_pos[3] = {0.0};
	GetClientEyePosition(client, self_pos);
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientConnected(i) && IsClientInGame(i) && GetClientTeam(i) == view_as<int>(TEAM_SURVIVOR) && IsPlayerAlive(i))
		{
			float target_pos[3] = {0.0};
			GetClientEyePosition(i, target_pos);
			Handle hTrace = TR_TraceRayFilterEx(self_pos, target_pos, MASK_VISIBLE, RayType_EndPoint, TR_RayFilter, client);
			if (!TR_DidHit(hTrace) || TR_GetEntityIndex(hTrace) == i)
			{
				delete hTrace;
				hTrace = INVALID_HANDLE;
				return true;
			}
			delete hTrace;
			hTrace = INVALID_HANDLE;
		}
	}
	return false;
}
// 查找指定玩家指定范围内生还者或感染者团队成员数量，使用入参成员数组保存范围内的成员客户端索引，同时返回成员数量，无效则返回 -1
stock int Find_Ranged_Clients(int client, int[] targets, int team, float range, bool include_incapped = false, bool include_visible = true)
{
	// 检查入参合法性
	if (!IsValidClient(client) || team < view_as<int>(TEAM_SURVIVOR) || team > view_as<int>(TEAM_INFECTED))
	{
		return -1
	}
	int index = 0;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientConnected(i) && IsClientInGame(i) && (GetClientTeam(i) == team) && IsPlayerAlive(i) && (!include_incapped && GetEntProp(i, Prop_Send, "m_isIncapacitated") != 1))
		{
			float self_pos[3] = {0.0}, target_pos[3] = {0.0};
			GetClientEyePosition(client, self_pos);
			GetClientEyePosition(i, target_pos);
			// 自身与目标距离小于给定范围
			if (GetVectorDistance(self_pos, target_pos) <= range)
			{
				if (include_visible)
				{
					Handle hTrace = TR_TraceRayFilterEx(self_pos, target_pos, MASK_VISIBLE, RayType_EndPoint, TR_RayFilter, client);
					if (!TR_DidHit(hTrace) || TR_GetEntityIndex(hTrace) == i)
					{
						targets[index] = i;
						index += 1;
					}
					continue;
				}
				targets[index] = i;
				index += 1;
			}
		}
	}
	return index;
}
// 射线碰撞过滤器，返回 true 则通过检测，返回 false 则不通过检测
stock bool TR_RayFilter(int entity, int mask, int self)
{
	return entity != self;
}
// 运行脚本命令
stock void Logic_RunScript(const char[] code, any ...)
{
	int scriptent = FindEntityByTargetname(-1, PLUGIN_SCRIPTLOGIC);
	if (!scriptent || !IsValidEntity(scriptent))
	{
		scriptent = CreateEntityByName("logic_script");
		DispatchKeyValue(scriptent, "targetname", PLUGIN_SCRIPTLOGIC);
		DispatchSpawn(scriptent);
	}
	char buffer[512] = {'\0'};
	VFormat(buffer, sizeof(buffer), code, 2);
	SetVariantString(buffer);
	AcceptEntityInput(scriptent, "RunScriptCode");
}
// 找到脚本实体
stock int FindEntityByTargetname(int index, const char[] name)
{
	for (int entity = index; entity < GetMaxEntities(); entity++)
	{
		if (IsValidEntity(entity))
		{
			char entname[128] = {'\0'};
			GetEntPropString(entity, Prop_Data, "m_iName", entname, sizeof(entname));
			if (strcmp(name, entname) == 0)
			{
				return entity;
			}
		}
	}
	return -1;
}
// 获取玩家当前速度向量长度，成功返回速度大小，失败返回 -1.0
stock float GetCurrentSpeed(int client)
{
	if (IsValidClient(client) && GetClientTeam(client) != view_as<int>(TEAM_SPECTATOR))
	{
		float vec_speed[3] = {0.0};
		GetEntPropVector(client, Prop_Data, "m_vecVelocity", vec_speed);
		return (SquareRoot(Pow(vec_speed[0], 2.0) + Pow(vec_speed[1], 2.0)));
	}
	return -1.0
}
// 获取当前是否在对抗第二轮
stock bool InVersusSecondRound()
{
	return view_as<bool>(GameRules_GetProp("m_bInSecondHalfOfRound"));
}
// KMP 算法求解子串位置，主串中存在子串返回子串出现索引，否则返回 -1
stock int KMPGetPatternIndex(const char[] mainString, const char[] pattern)
{
	int p1 = 0, p2 = 0, i = 2, last = 0, len1 = strlen(mainString), len2 = strlen(pattern);
	int[] next = new int[len2];
	// 人为规定 next[0] = -1，next[1] = 0
	next[0] = -1;
	next[1] = 0;
	while (i < len2)
	{
		if (pattern[i - 1] == pattern[last]) next[i++] = ++last;
		else if (last > 0) last = next[last];
		else pattern[i++] = 0;
	}
	// 遍历两个字符串
	while (p1 < len1 && p2 < len2)
	{
		if (mainString[p1] == pattern[p2])
		{
			p1++;
			p2++;
		}
		else if (next[p2] == -1) p1++;
		else p2 = next[p2];
	}
	return p2 == len2 ? p1 - len2 : -1;
}

// *************************
// 			向量类
// *************************
// 向量复制
stock void CopyVectors(float origin[3], float result[3])
{
	result[0] = origin[0];
	result[1] = origin[1];
	result[2] = origin[2];
}
// 向量置零
stock void ZeroVector(float origin[3])
{
	origin = NULL_VECTOR;
}
// 是否为零向量
stock bool IsZeroVector(float origin[3])
{
	return origin[0] == NULL_VECTOR[0] && origin[1] == NULL_VECTOR[1] && origin[2] == NULL_VECTOR[2];
}

// *************************
// 			数据类
// *************************
// 获取服务器 tickrate 值，成功返回 tickrate 值，失败返回 -1
stock int GetServerTickRate()
{
	int tick_rate = -1;
	if (tick_rate == -1 && IsServerProcessing())
	{
		tick_rate = RoundToNearest(1.0 / GetTickInterval());
	}
	return tick_rate;
}
