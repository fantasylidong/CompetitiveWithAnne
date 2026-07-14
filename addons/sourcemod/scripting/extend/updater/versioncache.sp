/* Persisted manifest version cache */

#define VERSION_CACHE_ROOT "UpdaterVersionCache"
#define VERSION_CACHE_FILE "data/updater_versions.txt"
#define VERSION_CACHE_TEMP_FILE "data/updater_versions.txt.temp"
#define VERSION_CACHE_BACKUP_FILE "data/updater_versions.txt.backup"
#define VERSION_CACHE_KEY_LENGTH 32
#define METADATA_PENDING_VERSION "pending_version"
#define METADATA_PENDING_CACHE_KEY "pending_cache_key"

void Updater_BuildVersionCacheKey(const char[] url, char[] cacheKey, int maxLength)
{
	// Two non-cryptographic hashes keep private update URLs out of the cache file.
	int hashDjb2 = 5381;
	int hashSdbm = 0;

	for (int i = 0; url[i] != '\0'; i++)
	{
		hashDjb2 = ((hashDjb2 << 5) + hashDjb2) ^ url[i];
		hashSdbm = url[i] + (hashSdbm << 6) + (hashSdbm << 16) - hashSdbm;
	}

	FormatEx(cacheKey, maxLength, "url_%08x_%08x", hashDjb2, hashSdbm);
}

void Updater_GetCurrentVersionCacheKey(int index, char[] cacheKey, int maxLength)
{
	char url[MAX_URL_LENGTH];
	Updater_GetURL(index, url, sizeof(url));
	Updater_BuildVersionCacheKey(url, cacheKey, maxLength);
}

void Updater_GetVersionCachePaths(char[] path, int pathLength, char[] tempPath, int tempPathLength, char[] backupPath, int backupPathLength)
{
	BuildPath(Path_SM, path, pathLength, VERSION_CACHE_FILE);
	BuildPath(Path_SM, tempPath, tempPathLength, VERSION_CACHE_TEMP_FILE);
	BuildPath(Path_SM, backupPath, backupPathLength, VERSION_CACHE_BACKUP_FILE);
}

bool Updater_RecoverVersionCache(const char[] path, const char[] backupPath)
{
	if (!FileExists(path) && FileExists(backupPath) && !RenameFile(path, backupPath))
	{
		Updater_Log("Unable to recover updater version cache from backup: %s", backupPath);
		return false;
	}

	return true;
}

bool Updater_GetCachedVersion(int index, char[] version, int maxLength)
{
	version[0] = '\0';

	char path[PLATFORM_MAX_PATH], tempPath[PLATFORM_MAX_PATH], backupPath[PLATFORM_MAX_PATH];
	Updater_GetVersionCachePaths(path, sizeof(path), tempPath, sizeof(tempPath), backupPath, sizeof(backupPath));
	if (!Updater_RecoverVersionCache(path, backupPath))
	{
		return false;
	}

	if (!FileExists(path))
	{
		return false;
	}

	KeyValues cache = new KeyValues(VERSION_CACHE_ROOT);
	if (!cache.ImportFromFile(path))
	{
		Updater_Log("Unable to parse updater version cache: %s", path);
		delete cache;
		return false;
	}

	char cacheKey[VERSION_CACHE_KEY_LENGTH];
	Updater_GetCurrentVersionCacheKey(index, cacheKey, sizeof(cacheKey));

	bool found = cache.JumpToKey(cacheKey);
	if (found)
	{
		cache.GetString("version", version, maxLength, "");
		found = version[0] != '\0';
	}

	delete cache;
	return found;
}

void Updater_SetPendingVersion(int index, const char[] version)
{
	char cacheKey[VERSION_CACHE_KEY_LENGTH];
	Updater_GetCurrentVersionCacheKey(index, cacheKey, sizeof(cacheKey));

	StringMap metadata = Updater_GetMetadata(index);
	metadata.SetString(METADATA_PENDING_VERSION, version);
	metadata.SetString(METADATA_PENDING_CACHE_KEY, cacheKey);
}

void Updater_ClearPendingVersion(int index)
{
	StringMap metadata = Updater_GetMetadata(index);
	metadata.Remove(METADATA_PENDING_VERSION);
	metadata.Remove(METADATA_PENDING_CACHE_KEY);
}

bool Updater_WriteCachedVersion(const char[] cacheKey, const char[] version, const char[] pluginFile)
{
	char path[PLATFORM_MAX_PATH], tempPath[PLATFORM_MAX_PATH], backupPath[PLATFORM_MAX_PATH];
	Updater_GetVersionCachePaths(path, sizeof(path), tempPath, sizeof(tempPath), backupPath, sizeof(backupPath));
	if (!Updater_RecoverVersionCache(path, backupPath))
	{
		return false;
	}

	KeyValues cache = new KeyValues(VERSION_CACHE_ROOT);
	if (FileExists(path) && !cache.ImportFromFile(path))
	{
		Updater_Log("Refusing to overwrite invalid updater version cache: %s", path);
		delete cache;
		return false;
	}

	cache.JumpToKey(cacheKey, true);
	cache.SetString("plugin", pluginFile);
	cache.SetString("version", version);
	cache.SetNum("updated_at", GetTime());
	cache.Rewind();

	if (FileExists(tempPath) && !DeleteFile(tempPath))
	{
		Updater_Log("Unable to remove stale updater version cache temp file: %s", tempPath);
		delete cache;
		return false;
	}

	bool exported = cache.ExportToFile(tempPath);
	delete cache;

	if (!exported)
	{
		Updater_Log("Unable to write updater version cache temp file: %s", tempPath);
		return false;
	}

	if (FileExists(backupPath) && !DeleteFile(backupPath))
	{
		Updater_Log("Unable to remove stale updater version cache backup: %s", backupPath);
		DeleteFile(tempPath);
		return false;
	}

	bool hadPreviousCache = FileExists(path);
	if (hadPreviousCache && !RenameFile(backupPath, path))
	{
		Updater_Log("Unable to back up updater version cache: %s", path);
		DeleteFile(tempPath);
		return false;
	}

	if (!RenameFile(path, tempPath))
	{
		Updater_Log("Unable to install updater version cache: %s", path);
		if (hadPreviousCache && !RenameFile(path, backupPath))
		{
			Updater_Log("Unable to restore updater version cache backup: %s", backupPath);
		}
		DeleteFile(tempPath);
		return false;
	}

	if (hadPreviousCache && FileExists(backupPath) && !DeleteFile(backupPath))
	{
		Updater_Log("Unable to remove updater version cache backup: %s", backupPath);
	}

	return true;
}

bool Updater_CommitPendingVersion(int index)
{
	char version[UPDATER_VERSION_LENGTH], cacheKey[VERSION_CACHE_KEY_LENGTH];
	version[0] = '\0';
	cacheKey[0] = '\0';
	StringMap metadata = Updater_GetMetadata(index);

	bool hasVersion = metadata.GetString(METADATA_PENDING_VERSION, version, sizeof(version));
	bool hasCacheKey = metadata.GetString(METADATA_PENDING_CACHE_KEY, cacheKey, sizeof(cacheKey));
	char pluginFile[PLATFORM_MAX_PATH];
	GetPluginFilename(IndexToPlugin(index), pluginFile, sizeof(pluginFile));
	bool saved = hasVersion && hasCacheKey && version[0] != '\0' && cacheKey[0] != '\0'
		&& Updater_WriteCachedVersion(cacheKey, version, pluginFile);

	Updater_ClearPendingVersion(index);
	return saved;
}
