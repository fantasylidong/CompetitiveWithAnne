#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dlfcn.h>
#include <string>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

#include "gameshim/intercom.h"

static std::vector<std::string> g_logs;

static void LogMessage(const char* format, ...)
{
	char buffer[1024];
	va_list args;
	va_start(args, format);
	vsnprintf(buffer, sizeof(buffer), format, args);
	va_end(args);
	g_logs.push_back(buffer);
}

static void PathFormat(char* buffer, size_t length, const char* format, ...)
{
	va_list args;
	va_start(args, format);
	vsnprintf(buffer, length, format, args);
	va_end(args);
}

static const char* GetMapName()
{
	return "conditional_filter_test";
}

static void Require(bool condition, const char* message)
{
	if (!condition)
	{
		fprintf(stderr, "FAIL: %s\n", message);
		exit(1);
	}
}

static void MakeDirectory(const std::string& path)
{
	Require(mkdir(path.c_str(), 0755) == 0, ("mkdir " + path).c_str());
}

static void WriteFile(const std::string& path, const char* contents)
{
	FILE* file = fopen(path.c_str(), "wt");
	Require(file != NULL, ("open " + path).c_str());
	Require(fputs(contents, file) >= 0, ("write " + path).c_str());
	Require(fclose(file) == 0, ("close " + path).c_str());
}

static bool Contains(const char* text, const char* value)
{
	return strstr(text, value) != NULL;
}

int main(int argc, char** argv)
{
	Require(argc == 2, "usage: test_conditional_filters <stripper.core.so>");

	char root_template[] = "/tmp/stripper-conditional-test.XXXXXX";
	char* root = mkdtemp(root_template);
	Require(root != NULL, "mkdtemp");

	const std::string game_path(root);
	const std::string cfg_path = game_path + "/cfg";
	const std::string stripper_path = cfg_path + "/stripper";
	const std::string test_path = stripper_path + "/test";
	const std::string maps_path = test_path + "/maps";
	MakeDirectory(cfg_path);
	MakeDirectory(stripper_path);
	MakeDirectory(test_path);
	MakeDirectory(maps_path);

	const std::string global_filter = test_path + "/global_filters.cfg";
	WriteFile(global_filter,
		"filter:\n"
		"{\n"
		"\t\"classname\" \"global_marker\"\n"
		"}\n");

	void* library = dlopen(argv[1], RTLD_NOW);
	Require(library != NULL, dlerror());
	STRIPPER_LOAD load = reinterpret_cast<STRIPPER_LOAD>(dlsym(library, "LoadStripper"));
	Require(load != NULL, "LoadStripper export");

	stripper_game_t game = {
		game_path.c_str(),
		"addons/stripper",
		"cfg/stripper/test",
		LogMessage,
		PathFormat,
		GetMapName
	};
	stripper_core_t core = {};
	load(&game, &core);

	const char* entities =
		"{\n\"classname\" \"global_marker\"\n}\n"
		"{\n\"classname\" \"map_marker\"\n}\n"
		"{\n\"classname\" \"untouched\"\n}\n";

	const char* unconfigured = core.parse_map("unknown_map", entities);
	Require(Contains(unconfigured, "global_marker"), "global filter must be skipped");
	Require(Contains(unconfigured, "map_marker"), "map entity must be unchanged");
	Require(Contains(unconfigured, "untouched"), "unrelated entity must remain");
	Require(!g_logs.empty() && Contains(g_logs.back().c_str(), "unconfigured map"),
		"skip must be logged");

	WriteFile(maps_path + "/known.cfg",
		"filter:\n"
		"{\n"
		"\t\"classname\" \"map_marker\"\n"
		"}\n");

	const char* configured = core.parse_map("known_variant", entities);
	Require(!Contains(configured, "global_marker"), "global filter must run");
	Require(!Contains(configured, "map_marker"), "prefix map filter must run");
	Require(Contains(configured, "untouched"), "unrelated entity must remain after filtering");

	Require(unlink(global_filter.c_str()) == 0, "remove global fixture");
	const char* no_global = core.parse_map("known_variant", entities);
	Require(Contains(no_global, "global_marker"), "missing global filter must not remove entities");
	Require(!Contains(no_global, "map_marker"), "map filter must run without global filter");
	Require(!g_logs.empty() && Contains(g_logs.back().c_str(), "Could not find global filter"),
		"missing global filter must be logged");

	core.unload();
	dlclose(library);
	puts("conditional Stripper filter tests passed");
	return 0;
}
