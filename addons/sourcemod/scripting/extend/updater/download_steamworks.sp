
/* Extension Helper - SteamWorks */

void Download_SteamWorks(const char[] url, const char[] dest)
{
	char sURL[MAX_URL_LENGTH];
	PrefixURL(sURL, sizeof(sURL), url);
	
	Handle hDLPack = CreateDataPack();
	WritePackString(hDLPack, dest);

	Handle hRequest = SteamWorks_CreateHTTPRequest(k_EHTTPMethodGET, sURL);
	SteamWorks_SetHTTPRequestHeaderValue(hRequest, "Pragma", "no-cache");
	SteamWorks_SetHTTPRequestHeaderValue(hRequest, "Cache-Control", "no-cache");
	SteamWorks_SetHTTPCallbacks(hRequest, OnSteamWorksHTTPComplete);
	SteamWorks_SetHTTPRequestContextValue(hRequest, hDLPack);
	SteamWorks_SendHTTPRequest(hRequest);
}

public void OnSteamWorksHTTPComplete(Handle hRequest, bool bFailure, bool bRequestSuccessful, EHTTPStatusCode eStatusCode, any hDLPack)
{
	char sDest[PLATFORM_MAX_PATH];
	ResetPack(hDLPack);
	ReadPackString(hDLPack, sDest, sizeof(sDest));
	CloseHandle(hDLPack);
	
	if (bRequestSuccessful && eStatusCode == k_EHTTPStatusCode200OK)
	{
		SteamWorks_WriteHTTPResponseBodyToFile(hRequest, sDest);
		DownloadEnded(true);
	}
	else
	{
		char sError[256];
		FormatEx(sError, sizeof(sError), "SteamWorks error (status code %i). Request successful: %s", view_as<int>(eStatusCode), bRequestSuccessful ? "True" : "False");
		DownloadEnded(false, sError);
	}
	
	CloseHandle(hRequest);
}
