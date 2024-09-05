
/* API - Natives & Forwards */

static PrivateForward fwd_OnPluginChecking;
static PrivateForward fwd_OnPluginDownloading;
static PrivateForward fwd_OnPluginUpdating;
static PrivateForward fwd_OnPluginUpdated;

void API_Init()	{
	CreateNative("Updater_AddPlugin", Native_AddPlugin);
	CreateNative("Updater_RemovePlugin", Native_RemovePlugin);
	CreateNative("Updater_ForceUpdate", Native_ForceUpdate);
	CreateNative("Updater_ReloadPlugin", Native_ReloadPlugin);
	
	fwd_OnPluginChecking = new PrivateForward(ET_Event);
	fwd_OnPluginDownloading = new PrivateForward(ET_Event);
	fwd_OnPluginUpdating = new PrivateForward(ET_Ignore);
	fwd_OnPluginUpdated = new PrivateForward(ET_Ignore);
}

// native Updater_AddPlugin(const char[] url);
any Native_AddPlugin(Handle plugin, int params)	{
	char url[MAX_URL_LENGTH];
	GetNativeString(1, url, sizeof(url));
	Updater_AddPlugin(plugin, url);
	
	return 0;
}

// native Updater_RemovePlugin();
any Native_RemovePlugin(Handle plugin, int params)	{
	if(PluginToIndex(plugin) != -1)
		Updater_QueueRemovePlugin(plugin);
	
	return 0;
}

// native bool Updater_ForceUpdate();
any Native_ForceUpdate(Handle plugin, int numParams)	{
	int index = PluginToIndex(plugin);
	
	if(index == -1)
		ThrowNativeError(SP_ERROR_NOT_FOUND, "Plugin not found in updater.");
	else if (Updater_GetStatus(index) == Status_Idle)	{
		Updater_Check(index);
		return 1;
	}
	
	return 0;
}

// native void Updater_ReloadPlugin();
any Native_ReloadPlugin(Handle plugin, int params)	{
	Handle hPlugin = GetNativeCell(1);
	
	char filename[64];
	GetPluginFilename(hPlugin == null ? plugin : hPlugin, filename, sizeof(filename));
	ServerCommand("sm plugins reload %s", filename);
	
	return 0;
}

// forward Action Updater_OnPluginChecking();
Action Fwd_OnPluginChecking(Handle plugin)	{
	Action result = Plugin_Continue;
	Function func = GetFunctionByName(plugin, "Updater_OnPluginChecking");
	
	if(func != INVALID_FUNCTION && fwd_OnPluginChecking.AddFunction(plugin, func))	{
		Call_StartForward(fwd_OnPluginChecking);
		Call_Finish(result);
		fwd_OnPluginChecking.RemoveAllFunctions(plugin);
	}
	
	return result;
}

// forward Action Updater_OnPluginDownloading();
Action Fwd_OnPluginDownloading(Handle plugin)	{
	Action result = Plugin_Continue;
	Function func = GetFunctionByName(plugin, "Updater_OnPluginDownloading");
	
	if(func != INVALID_FUNCTION && fwd_OnPluginDownloading.AddFunction(plugin, func))	{
		Call_StartForward(fwd_OnPluginDownloading);
		Call_Finish(result);
		fwd_OnPluginDownloading.RemoveAllFunctions(plugin);
	}
	
	return result;
}

// forward void Updater_OnPluginUpdating();
void Fwd_OnPluginUpdating(Handle plugin)	{
	Function func = GetFunctionByName(plugin, "Updater_OnPluginUpdating");
	
	if(func != INVALID_FUNCTION && fwd_OnPluginUpdating.AddFunction(plugin, func))	{
		Call_StartForward(fwd_OnPluginUpdating);
		Call_Finish();
		fwd_OnPluginUpdating.RemoveAllFunctions(plugin);
	}
}

// forward void Updater_OnPluginUpdated();
void Fwd_OnPluginUpdated(Handle plugin)	{
	Function func = GetFunctionByName(plugin, "Updater_OnPluginUpdated");
	
	if(func != INVALID_FUNCTION && fwd_OnPluginUpdated.AddFunction(plugin, func))	{
		Call_StartForward(fwd_OnPluginUpdated);
		Call_Finish();
		fwd_OnPluginUpdated.RemoveAllFunctions(plugin);
	}
}
