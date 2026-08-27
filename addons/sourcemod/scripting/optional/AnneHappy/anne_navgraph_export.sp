#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <left4dhooks>

#define PLUGIN_VERSION "1.2"

/*
 * 把当前地图的 Nav 图导出为 JSON，供 NewAnneWeb 的"刷特位置选择可视化"
 * 页面加载真实地图数据（方案 A）。
 *
 * 输出: addons/sourcemod/data/anne_navgraph/<map>.json
 * 结构:
 * {
 *   "version": 2,
 *   "map": "c2m1_highway",
 *   "maxFlow": 12345.6,
 *   "areas": [[id, cx,cy,cz, nwx,nwy,nwz, sex,sey,sez, flow, attr], ...],
 *   "edges": [[srcIndex, dstIndex], ...],       // 有向，NORTH/EAST/SOUTH/WEST 地面连接
 *   "ents": [["classname", x,y,z, yaw, minx,miny,minz, maxx,maxy,maxz], ...]
 * }
 *
 * 说明：
 * - flow 为引擎原始 flow 距离；异常值（NaN/负数/超上限）导出为 -1，
 *   页面按 Nav 邻接继承最近的有效值（与 anne_spawn_accel 的做法一致）。
 * - 邻接来自 CNavArea 四方向地面连接；梯子/电梯边不含在内（占比极小，
 *   仅影响个别依赖梯子的连通性展示）。
 * - ents 为运行时实体快照（武器/物资点、blocker、门、电梯、可动 solid），
 *   天然包含 stripper 修改后的结果；物品类 bbox 全零。director 在回合开始
 *   时可能按物品密度删减部分预置点，此处导出的是地图加载后的候选点集合。
 * - 一次性在单帧内写完，2 万区域约 200-500ms，请在非对局时执行。
 */

public Plugin myinfo =
{
	name = "Anne NavGraph Export",
	author = "morzlee & Anne",
	description = "导出当前地图 Nav 图 JSON 供刷特可视化页使用",
	version = PLUGIN_VERSION,
	url = "https://github.com/fantasylidong/CompetitiveWithAnne"
};

public void OnPluginStart()
{
	RegAdminCmd("sm_navgraph_export", Cmd_NavGraphExport, ADMFLAG_ROOT,
		"导出当前地图 Nav 图为 JSON（写入 data/anne_navgraph/，请在非对局时执行）");
}

public Action Cmd_NavGraphExport(int client, int args)
{
	ArrayList areas = new ArrayList();
	L4D_GetAllNavAreas(areas);
	int count = areas.Length;
	if (count <= 0)
	{
		ReplyToCommand(client, "[NavGraph] 当前地图没有 Nav 区域，无法导出");
		delete areas;
		return Plugin_Handled;
	}

	char map[PLATFORM_MAX_PATH];
	GetCurrentMap(map, sizeof map);
	// workshop 地图名可能带路径分隔符，统一替换
	ReplaceString(map, sizeof map, "/", "_");
	ReplaceString(map, sizeof map, "\\", "_");

	char dir[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, dir, sizeof dir, "data/anne_navgraph");
	if (!DirExists(dir) && !CreateDirectory(dir, 511))
	{
		ReplyToCommand(client, "[NavGraph] 无法创建目录 %s", dir);
		delete areas;
		return Plugin_Handled;
	}

	char path[PLATFORM_MAX_PATH];
	FormatEx(path, sizeof path, "%s/%s.json", dir, map);
	File file = OpenFile(path, "w");
	if (file == null)
	{
		ReplyToCommand(client, "[NavGraph] 无法写入 %s", path);
		delete areas;
		return Plugin_Handled;
	}

	float startTime = GetEngineTime();

	// Nav 地址 -> 数组下标（edges 引用下标以压缩体积）
	StringMap addrToIndex = new StringMap();
	char key[24];
	for (int i = 0; i < count; i++)
	{
		FormatEx(key, sizeof key, "%x", areas.Get(i));
		addrToIndex.SetValue(key, i);
	}

	float maxFlow = L4D2Direct_GetMapMaxFlowDistance();
	char head[192];
	FormatEx(head, sizeof head,
		"{\"version\":2,\"map\":\"%s\",\"maxFlow\":%.1f,\"areas\":[", map, maxFlow);
	file.WriteString(head, false);

	char line[256];
	for (int i = 0; i < count; i++)
	{
		Address area = areas.Get(i);
		int id = L4D_GetNavAreaID(area);

		float center[3];
		L4D_GetNavAreaCenter(area, center);
		float nw[3];
		L4D_NavArea_GetCorner(area, NORTH_WEST, nw);
		float se[3];
		L4D_NavArea_GetCorner(area, SOUTH_EAST, se);

		float flow = L4D2Direct_GetTerrorNavAreaFlow(area);
		// 反向比较同时拦截 NaN；异常 flow 统一导出 -1
		if (!(flow >= 0.0) || !(flow <= maxFlow))
			flow = -1.0;

		int attr = L4D_GetNavArea_SpawnAttributes(area);

		FormatEx(line, sizeof line,
			"%s[%d,%.1f,%.1f,%.1f,%.1f,%.1f,%.1f,%.1f,%.1f,%.1f,%.1f,%d]",
			(i > 0) ? "," : "", id,
			center[0], center[1], center[2],
			nw[0], nw[1], nw[2],
			se[0], se[1], se[2],
			flow, attr);
		file.WriteString(line, false);
	}
	file.WriteString("],\"edges\":[", false);

	int edgeCount = 0;
	ArrayList adjacent = new ArrayList();
	for (int i = 0; i < count; i++)
	{
		Address area = areas.Get(i);
		for (int direction = 0; direction < 4; direction++)
		{
			adjacent.Clear();
			if (L4D_NavArea_GetAdjacentAreas(area, direction, adjacent) <= 0)
				continue;
			int adjCount = adjacent.Length;
			for (int row = 0; row < adjCount; row++)
			{
				FormatEx(key, sizeof key, "%x", adjacent.Get(row));
				int target;
				if (!addrToIndex.GetValue(key, target))
					continue;
				FormatEx(line, sizeof line, "%s[%d,%d]",
					(edgeCount > 0) ? "," : "", i, target);
				file.WriteString(line, false);
				edgeCount++;
			}
		}
	}
	file.WriteString("],\"ents\":[", false);
	int entCount = ExportEntities(file);
	file.WriteString("]}", false);

	delete adjacent;
	delete addrToIndex;
	delete areas;
	delete file;

	float elapsedMs = (GetEngineTime() - startTime) * 1000.0;
	ReplyToCommand(client, "[NavGraph] 已导出 %d 个区域 / %d 条边 / %d 个实体，耗时 %.0fms -> %s",
		count, edgeCount, entCount, elapsedMs, path);
	LogMessage("[NavGraph] exported %d areas / %d edges / %d ents in %.0fms -> %s",
		count, edgeCount, entCount, elapsedMs, path);
	return Plugin_Handled;
}

// 物品类：只导位置（bbox 全零）。两种形态都要：
// 1) weapon_*_spawn 生成点（可反复拿取的堆）；
// 2) 直接放置的物品实例（weapon_first_aid_kit / weapon_pain_pills 等
//    无 _spawn 后缀，安全屋桌面、场景散落的单件物品都是这种形态）。
// 统一按 weapon_ 前缀收，实例形态由调用方用 owner 检查排除被持有武器。
static bool IsItemClassname(const char[] cls)
{
	if (strncmp(cls, "weapon_", 7) == 0)
		return true;
	return strcmp(cls, "upgrade_spawn") == 0
		|| strcmp(cls, "upgrade_ammo_explosive") == 0
		|| strcmp(cls, "upgrade_ammo_incendiary") == 0
		|| strcmp(cls, "upgrade_laser_sight") == 0
		|| strcmp(cls, "prop_health_cabinet") == 0;
}

// 被玩家/bot 持有的武器实例不属于地图点位
static bool IsCarriedItem(int entity)
{
	if (HasEntProp(entity, Prop_Send, "m_hOwner"))
	{
		if (GetEntPropEnt(entity, Prop_Send, "m_hOwner") > 0)
			return true;
	}
	if (HasEntProp(entity, Prop_Send, "m_hOwnerEntity"))
	{
		if (GetEntPropEnt(entity, Prop_Send, "m_hOwnerEntity") > 0)
			return true;
	}
	return false;
}

// 阻挡/可动 solid 类：带 yaw 和本地 bbox。运行时枚举天然包含 stripper
// 增删改之后的结果（env_*_blocker 基本都来自 stripper）。
static bool IsSolidClassname(const char[] cls)
{
	return strcmp(cls, "env_physics_blocker") == 0
		|| strcmp(cls, "env_player_blocker") == 0
		|| strcmp(cls, "func_brush") == 0
		|| strcmp(cls, "func_playerinfected_clip") == 0
		|| strcmp(cls, "func_breakable") == 0
		|| strcmp(cls, "func_door") == 0
		|| strcmp(cls, "func_door_rotating") == 0
		|| strcmp(cls, "func_movelinear") == 0
		|| strcmp(cls, "func_elevator") == 0
		|| strcmp(cls, "prop_door_rotating") == 0
		|| strcmp(cls, "prop_wall_breakable") == 0
		|| strcmp(cls, "prop_dynamic") == 0
		|| strcmp(cls, "prop_dynamic_override") == 0
		|| strcmp(cls, "prop_physics") == 0
		|| strcmp(cls, "prop_car_alarm") == 0;
}

static int ExportEntities(File file)
{
	char cls[64];
	char line[320];
	int written = 0;
	int maxEnts = GetMaxEntities();
	for (int entity = MaxClients + 1; entity < maxEnts; entity++)
	{
		if (!IsValidEntity(entity))
			continue;
		if (!GetEntityClassname(entity, cls, sizeof cls))
			continue;

		bool item = IsItemClassname(cls);
		bool solid = !item && IsSolidClassname(cls);
		if (!item && !solid)
			continue;
		if (item && IsCarriedItem(entity))
			continue;

		float origin[3];
		GetEntPropVector(entity, Prop_Send, "m_vecOrigin", origin);

		float yaw = 0.0;
		float mins[3];
		float maxs[3];
		mins = NULL_VECTOR;
		maxs = NULL_VECTOR;
		if (solid)
		{
			if (HasEntProp(entity, Prop_Data, "m_angRotation"))
			{
				float angles[3];
				GetEntPropVector(entity, Prop_Data, "m_angRotation", angles);
				yaw = angles[1];
			}
			if (HasEntProp(entity, Prop_Send, "m_vecMins"))
			{
				GetEntPropVector(entity, Prop_Send, "m_vecMins", mins);
				GetEntPropVector(entity, Prop_Send, "m_vecMaxs", maxs);
			}
		}

		FormatEx(line, sizeof line,
			"%s[\"%s\",%.1f,%.1f,%.1f,%.1f,%.1f,%.1f,%.1f,%.1f,%.1f,%.1f]",
			(written > 0) ? "," : "", cls,
			origin[0], origin[1], origin[2], yaw,
			mins[0], mins[1], mins[2],
			maxs[0], maxs[1], maxs[2]);
		file.WriteString(line, false);
		written++;
	}
	return written;
}
