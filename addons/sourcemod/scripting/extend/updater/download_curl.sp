
/* Extension Helper - cURL */

void Download_cURL(const char[] url, const char[] dest)
{
	char sURL[MAX_URL_LENGTH];
	PrefixURL(sURL, sizeof(sURL), url);
	
	Handle hFile = curl_OpenFile(dest, "wb");
	
	if (hFile == INVALID_HANDLE)
	{
		char sError[256];
		FormatEx(sError, sizeof(sError), "Error writing to file: %s", dest);
		DownloadEnded(false, sError);
		return;
	}
	
	int CURL_Default_opt[][2] = {
		{view_as<int>(CURLOPT_NOSIGNAL),		1},
		{view_as<int>(CURLOPT_NOPROGRESS),		1},
		{view_as<int>(CURLOPT_TIMEOUT),			30},
		{view_as<int>(CURLOPT_CONNECTTIMEOUT),	60},
		{view_as<int>(CURLOPT_VERBOSE),			0}
	};
	
	Handle headers = curl_slist();
	curl_slist_append(headers, "Pragma: no-cache");
	curl_slist_append(headers, "Cache-Control: no-cache");
	
	Handle hDLPack = CreateDataPack();
	WritePackCell(hDLPack, view_as<int>(hFile));
	WritePackCell(hDLPack, view_as<int>(headers));
	
	Handle curl = curl_easy_init();
	curl_easy_setopt_int_array(curl, CURL_Default_opt, sizeof(CURL_Default_opt));
	curl_easy_setopt_handle(curl, CURLOPT_WRITEDATA, hFile);
	curl_easy_setopt_string(curl, CURLOPT_URL, url);
	curl_easy_setopt_handle(curl, CURLOPT_HTTPHEADER, headers);
	curl_easy_perform_thread(curl, OnCurlComplete, hDLPack);
}

public void OnCurlComplete(Handle curl, CURLcode code, any hDLPack)
{
	ResetPack(hDLPack);
	CloseHandle(ReadPackCell(hDLPack));	// hFile
	CloseHandle(ReadPackCell(hDLPack));	// headers
	CloseHandle(hDLPack);
	CloseHandle(curl);
	
	if(code == CURLE_OK)
	{
		DownloadEnded(true);
	}
	else
	{
		char sError[256];
		curl_easy_strerror(code, sError, sizeof(sError));
		Format(sError, sizeof(sError), "cURL error: %s", sError);
		DownloadEnded(false, sError);
	}
}
