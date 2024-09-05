/* Extension Helper - SteamWorks */

void Download_SteamWorks(const char[] url, const char[] dest)	{
	char sURL[MAX_URL_LENGTH];
	PrefixURL(sURL, sizeof(sURL), url);
	
	DataPack hDLPack = new DataPack();
	hDLPack.WriteString(dest);

	Handle hRequest = SteamWorks_CreateHTTPRequest(k_EHTTPMethodGET, sURL);
	SteamWorks_SetHTTPRequestHeaderValue(hRequest, "Pragma", "no-cache");
	SteamWorks_SetHTTPRequestHeaderValue(hRequest, "Cache-Control", "no-cache");
	SteamWorks_SetHTTPCallbacks(hRequest, OnSteamWorksHTTPComplete);
	SteamWorks_SetHTTPRequestContextValue(hRequest, hDLPack);
	SteamWorks_SendHTTPRequest(hRequest);
}

void OnSteamWorksHTTPComplete(Handle hRequest, bool bFailure, bool bRequestSuccessful, EHTTPStatusCode eStatusCode, DataPack hDLPack)	{
	char sDest[PLATFORM_MAX_PATH];
	hDLPack.Reset();
	hDLPack.ReadString(sDest, sizeof(sDest));
	delete hDLPack;
	
	switch(bRequestSuccessful && eStatusCode == k_EHTTPStatusCode200OK)	{
		case true:	{
			SteamWorks_WriteHTTPResponseBodyToFile(hRequest, sDest);
			DownloadEnded(true);
		}
		case false:	{
			char sError[256];
			FormatEx(sError, sizeof(sError), "SteamWorks error (status code %i). Request successful: %s", eStatusCode, bRequestSuccessful ? "True" : "False");
			DownloadEnded(false, sError);
		}
	}
	
	delete hRequest;
}

static DataPackPos QueuePack_URL;

void FinalizeDownload(int index)	{
	/* Strip the temporary file extension from downloaded files. */
	char newpath[PLATFORM_MAX_PATH], oldpath[PLATFORM_MAX_PATH];
	ArrayList hFiles = view_as<ArrayList>(Updater_GetFiles(index));
	
	int maxFiles = hFiles.Length;
	for(int i = 0; i < maxFiles; i++)	{
		hFiles.GetString(i, newpath, sizeof(newpath));
		Format(oldpath, sizeof(oldpath), "%s.%s", newpath, TEMP_FILE_EXT);
		
		// Rename doesn't overwrite on Windows. Make sure the path is clear.
		if(FileExists(newpath))
			DeleteFile(newpath);
		
		RenameFile(newpath, oldpath);
	}
	
	hFiles.Clear();
}

void AbortDownload(int index)	{
	/* Delete all downloaded temporary files. */
	char path[PLATFORM_MAX_PATH];
	ArrayList hFiles = view_as<ArrayList>(Updater_GetFiles(index));
	
	int maxFiles = hFiles.Length;
	for(int i = 0; i < maxFiles; i++)	{
		hFiles.GetString(0, path, sizeof(path));
		Format(path, sizeof(path), "%s.%s", path, TEMP_FILE_EXT);
		
		if(FileExists(path))
			DeleteFile(path);
	}
	
	hFiles.Clear();
}

void ProcessDownloadQueue(bool force=false)	{
	if(!force && (g_bDownloading || !g_hDownloadQueue.Length))
		return;
	
	DataPack hQueuePack = view_as<DataPack>(g_hDownloadQueue.Get(0));
	hQueuePack.Position = QueuePack_URL;
	
	char url[MAX_URL_LENGTH], dest[PLATFORM_MAX_PATH];
	hQueuePack.ReadString(url, sizeof(url));
	hQueuePack.ReadString(dest, sizeof(dest));
	
	if (!STEAMWORKS_AVAILABLE())
		SetFailState(EXTENSION_ERROR);
	
#if defined DEBUG
	Updater_DebugLog("Download started:");
	Updater_DebugLog("  [0]  URL: %s", url);
	Updater_DebugLog("  [1]  Destination: %s", dest);
#endif
	
	g_bDownloading = true;
	
	switch(SteamWorks_IsLoaded())	{
		case true: Download_SteamWorks(url, dest);
		case false: CreateTimer(10.0, Timer_RetryQueue);
	}
}

Action Timer_RetryQueue(Handle timer)	{
	ProcessDownloadQueue(true);
	return Plugin_Stop;
}

void AddToDownloadQueue(int index, const char[] url, const char[] dest)	{
	DataPack hQueuePack = new DataPack();
	hQueuePack.WriteCell(index);
	
	QueuePack_URL = hQueuePack.Position;
	hQueuePack.WriteString(url);
	hQueuePack.WriteString(dest);
	
	g_hDownloadQueue.Push(hQueuePack);
	
	ProcessDownloadQueue();
}

void DownloadEnded(bool successful, const char[] error="")	{
	DataPack hQueuePack = view_as<DataPack>(g_hDownloadQueue.Get(0));
	hQueuePack.Reset();
	
	char url[MAX_URL_LENGTH], dest[PLATFORM_MAX_PATH];
	int index = hQueuePack.ReadCell();
	hQueuePack.ReadString(url, sizeof(url));
	hQueuePack.ReadString(dest, sizeof(dest));
	
	// Remove from the queue.
	delete hQueuePack;
	g_hDownloadQueue.Erase(0);
	
	#if defined DEBUG
	Updater_DebugLog("  [2]  Successful: %s", successful ? "Yes" : "No");
	#endif
	
	switch(Updater_GetStatus(index))	{
		case Status_Checking:	{
			if(!successful || !ParseUpdateFile(index, dest))	{
				Updater_SetStatus(index, Status_Idle);
				
				#if defined DEBUG
				if (error[0] != '\0')
					Updater_DebugLog("  [2]  %s", error);
				#endif
			}
		}
		
		case Status_Downloading:	{
			switch(successful)	{
				case true:	{
					// Check if this was the last file we needed.
					char lastfile[PLATFORM_MAX_PATH];
					ArrayList hFiles = view_as<ArrayList>(Updater_GetFiles(index));
					
					hFiles.GetString(hFiles.Length - 1, lastfile, sizeof(lastfile));
					Format(lastfile, sizeof(lastfile), "%s.%s", lastfile, TEMP_FILE_EXT);
					
					if(StrEqual(dest, lastfile))	{
						Handle hPlugin = IndexToPlugin(index);
						
						Fwd_OnPluginUpdating(hPlugin);
						FinalizeDownload(index);
						
						char sName[64];
						if(!GetPluginInfo(hPlugin, PlInfo_Name, sName, sizeof(sName)))
							strcopy(sName, sizeof(sName), "Null");
						
						Updater_Log("Successfully updated and installed \"%s\".", sName);
						Updater_SetStatus(index, Status_Updated);
						Fwd_OnPluginUpdated(hPlugin);
					}
				}
				case false:	{
					// Failed during an update.
					AbortDownload(index);
					Updater_SetStatus(index, Status_Error);
					
					char filename[64];
					GetPluginFilename(IndexToPlugin(index), filename, sizeof(filename));
					Updater_Log("Error downloading update for plugin: %s", filename);
					Updater_Log("  [0]  URL: %s", url);
					Updater_Log("  [1]  Destination: %s", dest);
					
					if(error[0] != '\0')
						Updater_Log("  [2]  %s", error);
				}
			}
		}
		
		case Status_Error:	{
			// Delete any additional files that this plugin had queued.
			if (successful && FileExists(dest))
				DeleteFile(dest);
		}
	}
	
	g_bDownloading = false;
	ProcessDownloadQueue();
}
