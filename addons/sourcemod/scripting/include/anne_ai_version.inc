#if defined _anne_ai_version_included
 #endinput
#endif
#define _anne_ai_version_included

#include <sourcemod>

// AnnePluginVersion accepts legacy dates (21-7-7), release months (2026-08),
// and suffixed test labels (2026-11测试版, 2026-11-beta).
stock int AnneAI_ParseVersionMonth(const char[] value)
{
	if (strlen(value) >= 64)
		return 0;
	char version[64];
	strcopy(version, sizeof(version), value);
	TrimString(version);
	if (StrEqual(version, "Latest", false))
		return 999912;

	ReplaceString(version, sizeof(version), ".", "-");
	ReplaceString(version, sizeof(version), "/", "-");

	int pos = 0;
	int yearDigits = 0;
	int year = 0;
	while (version[pos] >= '0' && version[pos] <= '9')
	{
		if (++yearDigits > 4)
			return 0;
		year = year * 10 + (version[pos] - '0');
		pos++;
	}
	if ((yearDigits != 2 && yearDigits != 4) || version[pos] != '-')
		return 0;
	pos++;

	int monthDigits = 0;
	int month = 0;
	while (version[pos] >= '0' && version[pos] <= '9')
	{
		if (++monthDigits > 2)
			return 0;
		month = month * 10 + (version[pos] - '0');
		pos++;
	}
	if (monthDigits < 1 || month < 1 || month > 12)
		return 0;

	if (version[pos] == '-' && version[pos + 1] >= '0' && version[pos + 1] <= '9')
	{
		pos++;
		int dayDigits = 0;
		int day = 0;
		while (version[pos] >= '0' && version[pos] <= '9')
		{
			if (++dayDigits > 2)
				return 0;
			day = day * 10 + (version[pos] - '0');
			pos++;
		}
		if (day < 1 || day > 31)
			return 0;
		if (version[pos] == '-' && version[pos + 1] >= '0' && version[pos + 1] <= '9')
			return 0;
	}

	if (year > 0 && year < 100)
		year += 2000;
	if (year < 2000)
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
	return version >= 202206 && version < 202611;
}

stock bool AnneAI_IsDynamicDifficultyAvailable()
{
	if (AnneAI_GetVersionMonth() < 202611
		|| !LibraryExists("annehappy_dynamic_ai_difficulty"))
		return false;
	Handle plugin = FindPluginByFile("optional/AnneHappy/annehappy_dynamic_ai_difficulty.smx");
	if (plugin == null)
		plugin = FindPluginByFile("annehappy_dynamic_ai_difficulty.smx");
	return plugin != null && GetPluginStatus(plugin) == Plugin_Running;
}
