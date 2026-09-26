#if defined _anne_db_included
	#endinput
#endif
#define _anne_db_included

// anne_db：全服数据库连接中心。
// 每个物理 MySQL 目标（driver/host/port/user/pass/database 相同）只保留一条共享连接，
// 通过 CloneHandle 分发给各插件。SourceMod 只有一个 DB 工作线程，线程查询本来就串行，
// 共享连接不会损失吞吐。插件未加载或配置不是 MySQL 时，*Compat stock 自动回退到原生连接。

#define ANNE_DB_LIBRARY "anne_db"

enum AnneDBLane
{
	// 默认通道：线程查询为主；偶尔的同步查询必须用 AnneDB_Locked* stock。
	AnneDBLane_Shared = 0,
	// 游戏过程中必须同步读写的插件专用，避免同步查询排在其他插件的慢查询后面。
	// 该通道上的同步查询同样必须用 AnneDB_Locked* stock（连接中心会在上面跑线程保活）。
	AnneDBLane_Sync = 1
};

/**
 * 该 databases.cfg 配置是否由 anne_db 托管（只托管 MySQL）。
 */
native bool AnneDB_IsManaged(const char[] conf);

/**
 * 异步获取连接，语义对应 Database.Connect。回调在下一帧或连接完成后触发，
 * db 是调用插件自己持有的 Clone，不用时 delete 即可（只释放自己的引用）。
 *
 * @return  false 表示该配置未托管，回调不会触发，调用方应自行连接。
 */
native bool AnneDB_Connect(SQLConnectCallback callback, const char[] conf, any data = 0, AnneDBLane lane = AnneDBLane_Shared);

/**
 * 异步获取连接，语义对应 SQL_TConnect。owner 为驱动句柄，hndl 为调用插件自己的 Clone。
 *
 * @return  false 表示该配置未托管，回调不会触发。
 */
native bool AnneDB_TConnect(SQLTCallback callback, const char[] conf, any data = 0, AnneDBLane lane = AnneDBLane_Shared);

/**
 * 同步获取连接，语义对应 SQL_Connect。已连接时立即返回 Clone；
 * 未连接时 allowBlock=true 会在主线程连接一次（整个服务器每条通道最多一次），
 * allowBlock=false 只触发后台连接并返回 null。最近刚失败过时直接返回 null，不会阻塞。
 */
native Database AnneDB_ConnectSync(const char[] conf, char[] error, int maxlength, AnneDBLane lane = AnneDBLane_Shared, bool allowBlock = true);

/**
 * 句柄是否指向 anne_db 管理的连接。是的话调用方不要再 SetCharset / SET NAMES，
 * 字符集由连接中心统一设置，否则会改掉其他插件的连接状态。
 */
native bool AnneDB_IsProviderConnection(Handle database);

// 只能检测调用方插件自己引用了的 native：插件没用到的 native 不在它的 native 表里，
// GetFeatureStatus 会一直判定为不可用。所以每个 stock 都检测它自己要调用的那个 native。
stock bool AnneDB_NativeReady(const char[] nativeName)
{
	return LibraryExists(ANNE_DB_LIBRARY)
		&& GetFeatureStatus(FeatureType_Native, nativeName) == FeatureStatus_Available;
}

// 只在同时调用了 AnneDB_IsManaged 的插件里有意义（AnneDB_CanManage 会调用它）。
stock bool AnneDB_Available()
{
	return AnneDB_NativeReady("AnneDB_IsManaged");
}

stock bool AnneDB_CanManage(const char[] conf)
{
	return AnneDB_Available() && AnneDB_IsManaged(conf);
}

stock bool AnneDB_IsShared(Handle database)
{
	return database != null
		&& AnneDB_NativeReady("AnneDB_IsProviderConnection")
		&& AnneDB_IsProviderConnection(database);
}

// Database.Connect 的替代品；未托管时原样调用 Database.Connect。
stock void AnneDB_ConnectCompat(SQLConnectCallback callback, const char[] conf, any data = 0, AnneDBLane lane = AnneDBLane_Shared)
{
	if (!AnneDB_CanManage(conf)
		|| !AnneDB_NativeReady("AnneDB_Connect")
		|| !AnneDB_Connect(callback, conf, data, lane))
		Database.Connect(callback, conf, data);
}

// SQL_TConnect 的替代品；未托管时原样调用 SQL_TConnect。
stock void AnneDB_TConnectCompat(SQLTCallback callback, const char[] conf, any data = 0, AnneDBLane lane = AnneDBLane_Shared)
{
	if (!AnneDB_CanManage(conf)
		|| !AnneDB_NativeReady("AnneDB_TConnect")
		|| !AnneDB_TConnect(callback, conf, data, lane))
		SQL_TConnect(callback, conf, data);
}

// SQL_Connect(conf, false, ...) 的替代品；未托管时保持原来的同步连接行为（忽略 allowBlock）。
stock Database AnneDB_ConnectSyncCompat(const char[] conf, char[] error, int maxlength, AnneDBLane lane = AnneDBLane_Shared, bool allowBlock = true)
{
	if (AnneDB_CanManage(conf) && AnneDB_NativeReady("AnneDB_ConnectSync"))
		return AnneDB_ConnectSync(conf, error, maxlength, lane, allowBlock);

	return SQL_Connect(conf, false, error, maxlength);
}

// 只在连接不是共享连接时设置字符集。共享连接的字符集由 anne_db 统一设置。
stock bool AnneDB_SetCharsetIfOwned(Handle database, const char[] charset)
{
	if (AnneDB_IsShared(database))
		return true;

	return SQL_SetCharset(database, charset);
}

/**
 * 加锁执行同步 FastQuery，并在锁内取出错误、影响行数和自增 ID。
 * 共享连接上的所有同步查询都必须走这里，否则会和 DB 工作线程抢同一条连接。
 */
stock bool AnneDB_LockedFastQuery(Handle database, const char[] query, char[] error, int maxlength, int &affectedRows = 0, int &insertId = 0)
{
	SQL_LockDatabase(database);
	bool ok = SQL_FastQuery(database, query);
	if (ok)
	{
		affectedRows = SQL_GetAffectedRows(database);
		insertId = SQL_GetInsertId(database);
	}
	else if (maxlength > 0)
	{
		SQL_GetError(database, error, maxlength);
	}
	SQL_UnlockDatabase(database);
	return ok;
}

/**
 * 加锁执行同步 Query。结果集已完整取回（mysql_store_result），解锁后可以继续读取。
 */
stock DBResultSet AnneDB_LockedQuery(Handle database, const char[] query, char[] error, int maxlength)
{
	SQL_LockDatabase(database);
	DBResultSet results = SQL_Query(database, query);
	if (results == null && maxlength > 0)
		SQL_GetError(database, error, maxlength);
	SQL_UnlockDatabase(database);
	return results;
}

// 始终作为可选依赖：连接中心不存在时各插件回退到自己的连接。
#if !defined ANNE_DB_PROVIDER
public SharedPlugin __pl_anne_db =
{
	name = ANNE_DB_LIBRARY,
	file = "anne_db.smx",
	required = 0,
};

public void __pl_anne_db_SetNTVOptional()
{
	MarkNativeAsOptional("AnneDB_IsManaged");
	MarkNativeAsOptional("AnneDB_Connect");
	MarkNativeAsOptional("AnneDB_TConnect");
	MarkNativeAsOptional("AnneDB_ConnectSync");
	MarkNativeAsOptional("AnneDB_IsProviderConnection");
}
#endif
