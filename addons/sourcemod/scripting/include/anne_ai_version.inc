#if defined _anne_ai_version_included
 #endinput
#endif
#define _anne_ai_version_included

#include <sourcemod>

// AnnePluginVersion accepts both legacy dates (21-7-7) and release months (2026-08).
stock int AnneAI_ParseVersionMonth(const char[] value)
{
	if (strlen(value) >= 32)
		return 0;
	char version[32];
	strcopy(version, sizeof(version), value);
	TrimString(version);
	if (StrEqual(version, "Latest", false))
		return 999912;

	ReplaceString(version, sizeof(version), ".", "-");
	ReplaceString(version, sizeof(version), "/", "-");
	int separators;
	for (int i = 0; version[i] != '\0'; i++)
	{
		if (version[i] == '-')
			separators++;
		else if (version[i] < '0' || version[i] > '9')
			return 0;
	}
	if (separators < 1 || separators > 2)
		return 0;
	char parts[3][12];
	int count = ExplodeString(version, "-", parts, sizeof(parts), sizeof(parts[]));
	int yearLength = strlen(parts[0]);
	if (count != separators + 1 || (yearLength != 2 && yearLength != 4)
		|| strlen(parts[1]) < 1 || strlen(parts[1]) > 2)
		return 0;
	if (count == 3 && (strlen(parts[2]) < 1 || strlen(parts[2]) > 2
		|| StringToInt(parts[2]) < 1 || StringToInt(parts[2]) > 31))
		return 0;

	int year = StringToInt(parts[0]);
	int month = StringToInt(parts[1]);
	if (year > 0 && year < 100)
		year += 2000;
	if (year < 2000 || month < 1 || month > 12)
		return 0;
	return year * 100 + month;
}

stock int AnneAI_GetVersionMonth()
{
	ConVar versionCvar = FindConVar("AnnePluginVersion");
	if (versionCvar == null)
		return 0;
	char version[64];
	versionCvar.GetString(version, sizeof(version));
	return AnneAI_ParseVersionMonth(version);
}

stock bool AnneAI_IsArchivedVersion()
{
	int version = AnneAI_GetVersionMonth();
	return version >= 202206 && version < 202608;
}

stock bool AnneAI_IsDynamicDifficultyAvailable()
{
	if (AnneAI_GetVersionMonth() < 202608
		|| !LibraryExists("annehappy_dynamic_ai_difficulty"))
		return false;
	Handle plugin = FindPluginByFile("optional/AnneHappy/annehappy_dynamic_ai_difficulty.smx");
	if (plugin == null)
		plugin = FindPluginByFile("annehappy_dynamic_ai_difficulty.smx");
	return plugin != null && GetPluginStatus(plugin) == Plugin_Running;
}
