#ifndef _INCLUDE_ANNE_NEXTBOT_EXTENSION_H_
#define _INCLUDE_ANNE_NEXTBOT_EXTENSION_H_

#if defined(_WIN32) && !defined(NOMINMAX)
#define NOMINMAX
#endif

#include "smsdk_ext.h"
#include <CDetour/detours.h>

class AnneNextBotExtension final : public SDKExtension
{
public:
    bool SDK_OnLoad(char *error, size_t maxlength, bool late) override;
    void SDK_OnUnload() override;
    bool SDK_OnMetamodLoad(ISmmAPI *ismm, char *error, size_t maxlength, bool late) override;
};

extern AnneNextBotExtension g_AnneNextBot;
extern CGlobalVars *gpGlobals;

#endif
