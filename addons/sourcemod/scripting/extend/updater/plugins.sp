
/* PluginPack Helpers */

static DataPackPos PluginPack_Plugin;
static DataPackPos PluginPack_Files;
static DataPackPos PluginPack_Status;
static DataPackPos PluginPack_URL;

int GetMaxPlugins()	{
	return g_hPluginPacks.Length;
}

bool IsValidPlugin(Handle plugin)	{
	/* Check if the plugin handle is pointing to a valid plugin. */
	Handle hIterator = GetPluginIterator();
	bool bIsValid = false;
	
	while(MorePlugins(hIterator))	{
		if(plugin == ReadPlugin(hIterator))	{
			bIsValid = true;
			break;
		}
	}
	
	delete hIterator;
	return bIsValid;
}

int PluginToIndex(Handle plugin)	{
	DataPack hPluginPack = null;
	
	int maxPlugins = GetMaxPlugins();
	for(int i = 0; i < maxPlugins; i++)	{
		hPluginPack = g_hPluginPacks.Get(i);
		hPluginPack.Position = PluginPack_Plugin;
		
		if(plugin == view_as<Handle>(hPluginPack.ReadCell()))
			return i;
	}
	
	return -1;
}

Handle IndexToPlugin(int index)	{
	DataPack hPluginPack = view_as<DataPack>(g_hPluginPacks.Get(index));
	hPluginPack.Position = PluginPack_Plugin;
	return view_as<Handle>(hPluginPack.ReadCell());
}

void Updater_AddPlugin(Handle plugin, const char[] url)	{
	int index = PluginToIndex(plugin);
	
	switch(index != -1)	{
		case true:	{
			// Remove plugin from removal queue.
			int maxPlugins = g_hRemoveQueue.Length;
			for(int i = 0; i < maxPlugins; i++)	{
				if(plugin == g_hRemoveQueue.Get(i))	{
					g_hRemoveQueue.Erase(i);
					break;
				}
			}
			
			// Update the url.
			Updater_SetURL(index, url);
		}
		case false:	{
			DataPack hPluginPack = new DataPack();
			ArrayList hFiles = new ArrayList(PLATFORM_MAX_PATH);
			
			PluginPack_Plugin = hPluginPack.Position;
			hPluginPack.WriteCell(view_as<int>(plugin));
			
			PluginPack_Files = hPluginPack.Position;
			hPluginPack.WriteCell(view_as<int>(hFiles));
			
			PluginPack_Status = hPluginPack.Position;
			hPluginPack.WriteCell(view_as<int>(Status_Idle));
			
			PluginPack_URL = hPluginPack.Position;
			hPluginPack.WriteString(url);
			
			g_hPluginPacks.Push(hPluginPack);
		}
	}
}

void Updater_QueueRemovePlugin(Handle plugin)	{
	/* Flag a plugin for removal. */
	int maxPlugins = g_hRemoveQueue.Length;
	for(int i = 0; i < maxPlugins; i++)	{
		// Make sure it wasn't previously flagged.
		if(plugin == g_hRemoveQueue.Get(i))
			return;
	}
	
	g_hRemoveQueue.Push(plugin);
	Updater_FreeMemory();
}

void Updater_RemovePlugin(int index)	{
	/* Warning: Removing a plugin will shift indexes. */
	CloseHandle(Updater_GetFiles(index)); // hFiles
	CloseHandle(GetArrayCell(g_hPluginPacks, index)); // hPluginPack
	g_hPluginPacks.Erase(index);
}

Handle Updater_GetFiles(int index)	{
	DataPack hPluginPack = g_hPluginPacks.Get(index);
	hPluginPack.Position = PluginPack_Files;
	return view_as<Handle>(hPluginPack.ReadCell());
}

UpdateStatus Updater_GetStatus(int index)	{
	DataPack hPluginPack = g_hPluginPacks.Get(index);
	hPluginPack.Position = PluginPack_Status;
	return view_as<UpdateStatus>(hPluginPack.ReadCell());
}

void Updater_SetStatus(int index, UpdateStatus status)	{
	DataPack hPluginPack = g_hPluginPacks.Get(index);
	hPluginPack.Position = PluginPack_Status;
	hPluginPack.WriteCell(view_as<int>(status));
}

void Updater_GetURL(int index, char[] buffer, int size)	{
	DataPack hPluginPack = g_hPluginPacks.Get(index);
	hPluginPack.Position = PluginPack_URL;
	hPluginPack.ReadString(buffer, size);
}

void Updater_SetURL(int index, const char[] url)	{
	DataPack hPluginPack = g_hPluginPacks.Get(index);
	hPluginPack.Position = PluginPack_URL;
	hPluginPack.WriteString(url);
}

/* Stocks */
stock void ReloadPlugin(Handle plugin=null)	{
	char filename[64];
	GetPluginFilename(plugin, filename, sizeof(filename));
	ServerCommand("sm plugins reload %s", filename);
}

stock void UnloadPlugin(Handle plugin=null)	{
	char filename[64];
	GetPluginFilename(plugin, filename, sizeof(filename));
	ServerCommand("sm plugins unload %s", filename);
}

stock void DisablePlugin(Handle plugin=null)	{
	char filename[64], path_disabled[PLATFORM_MAX_PATH], path_plugin[PLATFORM_MAX_PATH];
	
	GetPluginFilename(plugin, filename, sizeof(filename));
	BuildPath(Path_SM, path_disabled, sizeof(path_disabled), "plugins/disabled/%s", filename);
	BuildPath(Path_SM, path_plugin, sizeof(path_plugin), "plugins/%s", filename);
	
	if(FileExists(path_disabled))
		DeleteFile(path_disabled);
	
	if(!RenameFile(path_disabled, path_plugin))
		DeleteFile(path_plugin);
	
	ServerCommand("sm plugins unload %s", filename);
}
