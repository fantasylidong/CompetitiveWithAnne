#ifndef _INCLUDE_ANNE_SPAWN_ACCEL_EXTENSION_H_
#define _INCLUDE_ANNE_SPAWN_ACCEL_EXTENSION_H_

#if defined(_WIN32) && !defined(NOMINMAX)
#define NOMINMAX
#endif

#include "smsdk_ext.h"

#include <IEngineTrace.h>
#include <datamap.h>

class AnneSpawnAccelExtension final : public SDKExtension
{
public:
    bool SDK_OnLoad(char *error, size_t maxlength, bool late) override;
    void SDK_OnUnload() override;
    bool SDK_OnMetamodLoad(ISmmAPI *ismm, char *error, size_t maxlength, bool late) override;
};

extern AnneSpawnAccelExtension g_AnneSpawnAccel;
extern CGlobalVars *gpGlobals;

#endif
