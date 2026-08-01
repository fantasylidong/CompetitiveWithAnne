#ifndef _INCLUDE_ANNE_NEXTBOT_CONFIG_H_
#define _INCLUDE_ANNE_NEXTBOT_CONFIG_H_

#define SMEXT_CONF_NAME          "Anne NextBot"
#define SMEXT_CONF_DESCRIPTION   "Native NextBot scheduling and PathFollower routing for AnneHappy"
#define SMEXT_CONF_VERSION       "1.1.0"
#define SMEXT_CONF_AUTHOR        "AnneHappy"
#define SMEXT_CONF_URL           "https://github.com/morzlee/CompetitiveWithAnne"
#define SMEXT_CONF_LOGTAG        "ANNE-NEXTBOT"
#define SMEXT_CONF_LICENSE       "GPL"
#define SMEXT_CONF_DATESTRING    __DATE__

#define SMEXT_LINK(name) SDKExtension *g_pExtensionIface = name;

#define SMEXT_CONF_METAMOD
#define SMEXT_ENABLE_FORWARDSYS
#define SMEXT_ENABLE_GAMECONF
#define SMEXT_ENABLE_GAMEHELPERS

#endif
