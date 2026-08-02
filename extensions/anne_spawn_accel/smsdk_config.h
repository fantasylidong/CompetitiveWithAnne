#ifndef _INCLUDE_ANNE_SPAWN_ACCEL_CONFIG_H_
#define _INCLUDE_ANNE_SPAWN_ACCEL_CONFIG_H_

#define SMEXT_CONF_NAME          "Anne Spawn Accel"
#define SMEXT_CONF_DESCRIPTION   "Directed Nav candidates, spawn traces, geometry, and path cache"
#define SMEXT_CONF_VERSION       "1.2.0"
#define SMEXT_CONF_AUTHOR        "AnneHappy"
#define SMEXT_CONF_URL           "https://github.com/morzlee/CompetitiveWithAnne"
#define SMEXT_CONF_LOGTAG        "ANNE-SPAWN"
#define SMEXT_CONF_LICENSE       "GPL"
#define SMEXT_CONF_DATESTRING    __DATE__

#define SMEXT_LINK(name) SDKExtension *g_pExtensionIface = name;

#define SMEXT_CONF_METAMOD
#define SMEXT_ENABLE_GAMECONF
#define SMEXT_ENABLE_GAMEHELPERS

#endif
