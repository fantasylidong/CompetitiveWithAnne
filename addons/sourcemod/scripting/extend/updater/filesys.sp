
/* File System Parsers */

// Strip filename from path.
void StripPathFilename(char[] path)	{
	strcopy(path, FindCharInString(path, '/', true) + 1, path);
}

// Return the filename and extension from a given path.
void GetPathBasename(char[] path, char[] buffer, int maxlength)	{
	int check = -1;
	
	switch((check = FindCharInString(path, '/', true)) != -1
	|| (check = FindCharInString(path, '\\', true)) != -1)	{
		case true: strcopy(buffer, maxlength, path[check+1]);
		case false: strcopy(buffer, maxlength, path);
	}
}

// Add http protocol to url if it's missing.
void PrefixURL(char[] buffer, int maxlength, const char[] url)	{
	switch(strncmp(url, "http://", 7) != 0 && strncmp(url, "https://", 8) != 0)	{
		case true: Format(buffer, maxlength, "http://%s", url);
		case false: strcopy(buffer, maxlength, url);
	}
}

// Split URL into hostname, location, and filename. No trailing slashes.
stock void ParseURL(const char[] url, char[] host, int maxHost, char[] location, int maxLoc, char[] filename, int maxName)	{
	// Strip url prefix.
	int idx = StrContains(url, "://");
	idx = (idx != -1) ? idx + 3 : 0;
	
	char dirs[16][64];
	int total = ExplodeString(url[idx], "/", dirs, sizeof(dirs), sizeof(dirs[]));
	
	// host
	Format(host, maxHost, "%s", dirs[0]);
	
	// location
	location[0] = '\0';
	for(int i = 1; i < total - 1; i++)	{
		Format(location, maxLoc, "%s/%s", location, dirs[i]);
	}
	
	// filename
	Format(filename, maxName, "%s", dirs[total-1]);
}

// Converts Updater SMC file paths into paths relative to the game folder.
void ParseSMCPathForLocal(const char[] path, char[] buffer, int maxlength)	{
	char dirs[16][64];
	int total = ExplodeString(path, "/", dirs, sizeof(dirs), sizeof(dirs[]));
	
	switch(StrEqual(dirs[0], "Path_SM"))	{
		case true: BuildPath(Path_SM, buffer, maxlength, "");
		case false: buffer[0] = '\0'; // Path_Mod
	}
	
	// Construct the path and create directories if needed.
	for(int i = 1; i < total - 1; i++){
		Format(buffer, maxlength, "%s%s/", buffer, dirs[i]);

		if(!DirExists(buffer))
			CreateDirectory(buffer, 511);
	}
	
	// Add the filename to the end of the path.
	Format(buffer, maxlength, "%s%s", buffer, dirs[total-1]);
}

// Converts Updater SMC file paths into paths relative to the plugin's update URL.
void ParseSMCPathForDownload(const char[] path, char[] buffer, int maxlength)	{
	char dirs[16][64];
	int total = ExplodeString(path, "/", dirs, sizeof(dirs), sizeof(dirs[]));
	
	// Construct the path.
	buffer[0] = '\0';
	for(int i = 1; i < total; i++)	{
		Format(buffer, maxlength, "%s/%s", buffer, dirs[i]);
	}
}

// Parses a plugin's update file.
// Logs update notes and begins download if required.
// Returns true if an update was available.
static ArrayList SMC_Sections;
static StringMap SMC_DataTrie;
static DataPack SMC_DataPack;
static int SMC_LineNum;

bool ParseUpdateFile(int index, const char[] path)	{
	/* Return true if an update was available. */
	SMC_Sections = new ArrayList(64);
	SMC_DataTrie = new StringMap();
	SMC_DataPack = new DataPack();
	SMC_LineNum = 0;
	
	SMCParser smc = new SMCParser();
	SMC_SetRawLine(smc, Updater_RawLine);
	SMC_SetReaders(smc, Updater_NewSection, Updater_KeyValue, Updater_EndSection);
	
	char sBuffer[MAX_URL_LENGTH];
	DataPack hPack;
	bool bUpdate = false;
	SMCError err = SMC_ParseFile(smc, path);
	
	switch(err == SMCError_Okay)	{
		case true:	{
			// Initialize data
			Handle hPlugin = IndexToPlugin(index);
			ArrayList hFiles = view_as<ArrayList>(Updater_GetFiles(index));
			hFiles.Clear();
			
			// current version.
			char sCurrentVersion[16];
			
			if(!GetPluginInfo(hPlugin, PlInfo_Version, sCurrentVersion, sizeof(sCurrentVersion)))
				strcopy(sCurrentVersion, sizeof(sCurrentVersion), "Null");
			
			// latest version.
			char smcLatestVersion[16];
			
			if(SMC_DataTrie.GetValue("version->latest", hPack))	{
				hPack.Reset();
				hPack.ReadString(smcLatestVersion, sizeof(smcLatestVersion));
			}
			
			// Check if we have the latest version.
			if(!StrEqual(sCurrentVersion, smcLatestVersion))	{
				char sFilename[64], sName[64];
				GetPluginFilename(hPlugin, sFilename, sizeof(sFilename));
				
				switch(GetPluginInfo(hPlugin, PlInfo_Name, sName, sizeof(sName)))	 {
					case true: Updater_Log("Update available for \"%s\" (%s). Current: %s - Latest: %s", sName, sFilename, sCurrentVersion, smcLatestVersion);
					case false: Updater_Log("Update available for \"%s\". Current: %s - Latest: %s", sFilename, sCurrentVersion, smcLatestVersion);
				}
				
				if(SMC_DataTrie.GetValue("information->notes", hPack))	{
					hPack.Reset();
					
					int iCount = 0;
					while(IsPackReadable(hPack, 1))	{
						hPack.ReadString(sBuffer, sizeof(sBuffer));
						Updater_Log("  [%i]  %s", iCount++, sBuffer);
					}
				}
				
				// Log update notes, save file list, and begin downloading.
				switch(g_bGetDownload && Fwd_OnPluginDownloading(hPlugin) == Plugin_Continue)	{
					case true:	 {
						// Get previous version.
						char smcPrevVersion[16];
						if(SMC_DataTrie.GetValue("version->previous", hPack))	{
							hPack.Reset();
							hPack.ReadString(smcPrevVersion, sizeof(smcPrevVersion));
						}
						
						// Check if we only need the patch files.
						if(StrEqual(sCurrentVersion, smcPrevVersion) && SMC_DataTrie.GetValue("patch->plugin", hPack))	{
							ParseSMCFilePack(index, hPack, hFiles);
							
							if(g_bGetSource && SMC_DataTrie.GetValue("patch->source", hPack))
								ParseSMCFilePack(index, hPack, hFiles);
						}
						else if(SMC_DataTrie.GetValue("files->plugin", hPack))	{
							ParseSMCFilePack(index, hPack, hFiles);
							
							if(g_bGetSource && GetTrieValue(SMC_DataTrie, "files->source", hPack))
								ParseSMCFilePack(index, hPack, hFiles);
						}
						
						Updater_SetStatus(index, Status_Downloading);
					}
					
					// We don't want to spam the logs with the same update notification.
					case false: Updater_SetStatus(index, Status_Updated);
				}
				
				bUpdate = true;
			}
			
			#if defined DEBUG
			int iCount = 0;
			
			Updater_DebugLog(" ");
			Updater_DebugLog("SMC DEBUG");
			SMC_DataPack.Reset();
			
			while(IsPackReadable(SMC_DataPack, 1))	{
				SMC_DataPack.ReadString(sBuffer, sizeof(sBuffer));
				Updater_DebugLog("%s", sBuffer);
				
				if(SMC_DataTrie.GetValue(sBuffer, hPack))	{
					iCount = 0;
					hPack.Reset();
					
					while(IsPackReadable(hPack, 1))	{
						hPack.ReadString(sBuffer, sizeof(sBuffer));
						Updater_DebugLog("  [%i]  %s", iCount++, sBuffer);
					}
				}
			}
			Updater_DebugLog("END SMC DEBUG");
			Updater_DebugLog(" ");
			#endif
		}
		case false:	{
			Updater_Log("SMC parsing error on line %d", SMC_LineNum);
			
			Updater_GetURL(index, sBuffer, sizeof(sBuffer));
			Updater_Log("  [0]  URL: %s", sBuffer);
			
			if (SMC_GetErrorString(err, sBuffer, sizeof(sBuffer)))
				Updater_Log("  [1]  ERROR: %s", sBuffer);
		}
	}
	
	// Clean up SMC data.
	SMC_DataPack.Reset();
	
	while(IsPackReadable(SMC_DataPack, 1))	{
		SMC_DataPack.ReadString(sBuffer, sizeof(sBuffer));
		
		if(SMC_DataTrie.GetValue(sBuffer, hPack))
			delete hPack;
	}
	
	delete SMC_Sections;
	delete SMC_DataTrie;
	delete SMC_DataPack;
	delete smc;
	
	return bUpdate;
}

void ParseSMCFilePack(int index, DataPack hPack, ArrayList hFiles)	{
	// Prepare URL
	char urlprefix[MAX_URL_LENGTH], url[MAX_URL_LENGTH], dest[PLATFORM_MAX_PATH], sBuffer[MAX_URL_LENGTH];
	Updater_GetURL(index, urlprefix, sizeof(urlprefix));
	StripPathFilename(urlprefix);

	hPack.Reset();

	while(IsPackReadable(hPack, 1))	{
		hPack.ReadString(sBuffer, sizeof(sBuffer));
		
		// Merge url.
		ParseSMCPathForDownload(sBuffer, url, sizeof(url));
		Format(url, sizeof(url), "%s%s", urlprefix, url);
		
		// Make sure the current plugin path matches the update.
		ParseSMCPathForLocal(sBuffer, dest, sizeof(dest));
		
		char sLocalBase[64], sPluginBase[64], sFilename[64];
		GetPathBasename(dest, sLocalBase, sizeof(sLocalBase));
		GetPathBasename(sFilename, sPluginBase, sizeof(sPluginBase));
		
		if(StrEqual(sLocalBase, sPluginBase))	{
			StripPathFilename(dest);
			Format(dest, sizeof(dest), "%s/%s", dest, sFilename);
		}
		
		// Save the file location for later.
		hFiles.PushString(dest);
		
		// Add temporary file extension.
		Format(dest, sizeof(dest), "%s.%s", dest, TEMP_FILE_EXT);
		
		// Begin downloading file.
		AddToDownloadQueue(index, url, dest);
	}
}

SMCResult Updater_RawLine(SMCParser smc, const char[] line, int lineno)	{
	SMC_LineNum = lineno;
	return SMCParse_Continue;
}

SMCResult Updater_NewSection(SMCParser smc, const char[] name, bool opt_quotes)	{
	SMC_Sections.PushString(name);
	return SMCParse_Continue;
}

SMCResult Updater_KeyValue(SMCParser smc, const char[] key, const char[] value, bool key_quotes, bool value_quotes)	{
	char sCurSection[MAX_URL_LENGTH], sKey[MAX_URL_LENGTH];
	DataPack hPack;
	
	SMC_Sections.GetString(SMC_Sections.Length-1, sCurSection, sizeof(sCurSection));
	FormatEx(sKey, sizeof(sKey), "%s->%s", sCurSection, key);
	StringToLower(sKey);
	
	if (!SMC_DataTrie.GetValue(sKey, hPack))	{
		hPack = new DataPack();
		SMC_DataTrie.SetValue(sKey, hPack);
		SMC_DataPack.WriteString(sKey);
	}
	
	hPack.WriteString(value);
	return SMCParse_Continue;
}

SMCResult Updater_EndSection(SMCParser smc)	{
	if(SMC_Sections.Length)
		SMC_Sections.Erase(SMC_Sections.Length-1);
	
	return SMCParse_Continue;
}

stock void StringToLower(char[] input)	{
	int length = strlen(input);
	
	for(int i = 0; i < length; i++)	{
		input[i] = CharToLower(input[i]);
	}
}
