#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dlfcn.h>

#include "gameshim/intercom.h"

static const char *g_map_name = "c2m1_highway";

static void LogMessage(const char *, ...)
{
}

static void PathFormat(char *buffer, size_t length, const char *format, ...)
{
    va_list args;
    va_start(args, format);
    vsnprintf(buffer, length, format, args);
    va_end(args);
}

static const char *GetMapName()
{
    return g_map_name;
}

static void Require(bool condition, const char *message)
{
    if (!condition)
    {
        std::fprintf(stderr, "FAIL: %s\n", message);
        std::exit(1);
    }
}

int main(int argc, char **argv)
{
    Require(argc == 3, "usage: test_expanded_filters <core.so> <repository-root>");

    void *library = dlopen(argv[1], RTLD_NOW);
    Require(library != nullptr, dlerror());
    STRIPPER_LOAD load = reinterpret_cast<STRIPPER_LOAD>(dlsym(library, "LoadStripper"));
    Require(load != nullptr, "LoadStripper export");

    stripper_game_t game = {
        argv[2],
        "addons/stripper",
        "cfg/stripper/zonemod_anne",
        LogMessage,
        PathFormat,
        GetMapName,
    };
    stripper_core_t core = {};
    load(&game, &core);

    const char *entities =
        "{\n\"classname\" \"info_zombie_spawn\"\n\"population\" \"witch\"\n}\n"
        "{\n\"classname\" \"prop_dynamic\"\n"
        "\"model\" \"models/props_downtown/metal_door_112.mdl\"\n}\n"
        "{\n\"classname\" \"test_control_entity\"\n}\n";
    const char *filtered = core.parse_map(g_map_name, entities);

    Require(std::strstr(filtered, "info_zombie_spawn") == nullptr,
            "expanded global witch filter did not run");
    Require(std::strstr(filtered, "metal_door_112.mdl") == nullptr,
            "map-specific metal door filter did not run");
    Require(std::strstr(filtered, "test_control_entity") != nullptr,
            "unrelated entity was removed");

    core.unload();
    dlclose(library);
    std::puts("Expanded Stripper config test passed");
    return 0;
}
