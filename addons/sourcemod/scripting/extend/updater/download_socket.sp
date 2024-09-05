
/* Extension Helper - Socket */

#define MAX_REDIRECTS 5

static DataPackPos DLPack_Header;
static DataPackPos DLPack_Redirects;
static DataPackPos DLPack_File;
static DataPackPos DLPack_Request;

void Download_Socket(const char[] url, const char[] dest)
{
	char sURL[MAX_URL_LENGTH];
	PrefixURL(sURL, sizeof(sURL), url);
	
	if (strncmp(sURL, "https://", 8) == 0)
	{
		char sError[256];
		FormatEx(sError, sizeof(sError), "Socket does not support HTTPs (URL: %s).", sURL);
		DownloadEnded(false, sError);
		return;
	}
	
	Handle hFile = OpenFile(dest, "wb");
	
	if (hFile == INVALID_HANDLE)
	{
		char sError[256];
		FormatEx(sError, sizeof(sError), "Error writing to file: %s", dest);
		DownloadEnded(false, sError);
		return;
	}
	
	// Format HTTP GET method.
	char hostname[64];
	char location[128];
	char filename[64];
	char sRequest[MAX_URL_LENGTH+128];
	ParseURL(sURL, hostname, sizeof(hostname), location, sizeof(location), filename, sizeof(filename));
	FormatEx(sRequest, sizeof(sRequest), "GET %s/%s HTTP/1.0\r\nHost: %s\r\nConnection: close\r\nPragma: no-cache\r\nCache-Control: no-cache\r\n\r\n", location, filename, hostname);
	
	Handle hDLPack = CreateDataPack();
	
	DLPack_Header = GetPackPosition(hDLPack);
	WritePackCell(hDLPack, 0);
	
	DLPack_Redirects = GetPackPosition(hDLPack);
	WritePackCell(hDLPack, 0);
	
	DLPack_File = GetPackPosition(hDLPack);
	WritePackCell(hDLPack, view_as<int>(hFile));
	
	DLPack_Request = GetPackPosition(hDLPack);
	WritePackString(hDLPack, sRequest);
	
	Handle socket = SocketCreate(SOCKET_TCP, OnSocketError);
	SocketSetArg(socket, hDLPack);
	SocketSetOption(socket, ConcatenateCallbacks, 4096);
	SocketConnect(socket, OnSocketConnected, OnSocketReceive, OnSocketDisconnected, hostname, 80);
}

public void OnSocketConnected(Handle socket, any hDLPack)
{
	char sRequest[MAX_URL_LENGTH+128];
	SetPackPosition(hDLPack, DLPack_Request);
	ReadPackString(hDLPack, sRequest, sizeof(sRequest));
	
	SocketSend(socket, sRequest);
}

public void OnSocketReceive(Handle socket, char[] data, const int size, any hDLPack)
{
	int idx = 0;
	
	// Check if the HTTP header has already been parsed.
	SetPackPosition(hDLPack, DLPack_Header);
	bool bParsedHeader = view_as<bool>(ReadPackCell(hDLPack));
	int iRedirects = ReadPackCell(hDLPack);
	
	if (!bParsedHeader)
	{
		// Parse header data.
		if ((idx = StrContains(data, "\r\n\r\n")) == -1)
		{
			idx = 0;
		}
		else
		{			
			idx += 4;
		}
	
		if (strncmp(data, "HTTP/", 5) == 0)
		{
			// Check for location header.
			int idx2 = StrContains(data, "\nLocation: ", false);
			
			if (idx2 > -1 && (idx2 < idx || !idx))
			{
				if (++iRedirects > MAX_REDIRECTS)
				{
					CloseSocketHandles(socket, hDLPack);
					DownloadEnded(false, "Socket error: too many redirects.");
					return;
				}
				else
				{
					SetPackPosition(hDLPack, DLPack_Redirects);
					WritePackCell(hDLPack, iRedirects);
				}
			
				// skip to url
				idx2 += 11;
				
				char sURL[MAX_URL_LENGTH];
				strcopy(sURL, (FindCharInString(data[idx2], '\r') + 1), data[idx2]);
				
				PrefixURL(sURL, sizeof(sURL), sURL);
				
#if defined DEBUG
				Updater_DebugLog("  [ ]  Redirected: %s", sURL);
#endif
				
				if (strncmp(sURL, "https://", 8) == 0)
				{
					CloseSocketHandles(socket, hDLPack);
					
					char sError[256];
					FormatEx(sError, sizeof(sError), "Socket does not support HTTPs (URL: %s).", sURL);
					DownloadEnded(false, sError);
					return;
				}
				
				char hostname[64];
				char location[128];
				char filename[64];
				char sRequest[MAX_URL_LENGTH+128];
				ParseURL(sURL, hostname, sizeof(hostname), location, sizeof(location), filename, sizeof(filename));
				FormatEx(sRequest, sizeof(sRequest), "GET %s/%s HTTP/1.0\r\nHost: %s\r\nConnection: close\r\nPragma: no-cache\r\nCache-Control: no-cache\r\n\r\n", location, filename, hostname);
				
				SetPackPosition(hDLPack, DLPack_Request); // sRequest
				WritePackString(hDLPack, sRequest);
				
				Handle newSocket = SocketCreate(SOCKET_TCP, OnSocketError);
				SocketSetArg(newSocket, hDLPack);
				SocketSetOption(newSocket, ConcatenateCallbacks, 4096);
				SocketConnect(newSocket, OnSocketConnected, OnSocketReceive, OnSocketDisconnected, hostname, 80);
				
				CloseHandle(socket);
				return;
			}
			
			// Check HTTP status code
			char sStatusCode[64];
			strcopy(sStatusCode, (FindCharInString(data, '\r') - 8), data[9]);
			
			if (strncmp(sStatusCode, "200", 3) != 0)
			{
				CloseSocketHandles(socket, hDLPack);
			
				char sError[256];
				FormatEx(sError, sizeof(sError), "Socket error: %s", sStatusCode);
				DownloadEnded(false, sError);
				return;
			}
		}
		
		SetPackPosition(hDLPack, DLPack_Header);
		WritePackCell(hDLPack, 1);	// bParsedHeader
	}
	
	// Write data to file.
	SetPackPosition(hDLPack, DLPack_File);
	Handle hFile = view_as<Handle>(ReadPackCell(hDLPack));
	
	while (idx < size)
	{
		WriteFileCell(hFile, data[idx++], 1);
	}
}

public void OnSocketDisconnected(Handle socket, any hDLPack)
{
	CloseSocketHandles(socket, hDLPack);
	
	DownloadEnded(true);
}

public void OnSocketError(Handle socket, const int errorType, const int errorNum, any hDLPack)
{
	CloseSocketHandles(socket, hDLPack);

	char sError[256];
	FormatEx(sError, sizeof(sError), "Socket error: %d (Error code %d)", errorType, errorNum);
	DownloadEnded(false, sError);
}

void CloseSocketHandles(Handle socket, Handle hDLPack)
{
	SetPackPosition(hDLPack, DLPack_File);
	CloseHandle(view_as<Handle>(ReadPackCell(hDLPack)));	// hFile
	CloseHandle(hDLPack);
	CloseHandle(socket);
}
