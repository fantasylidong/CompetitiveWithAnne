#ifndef ANNE_SPAWN_ACCEL_NAV_BLOCKED_H
#define ANNE_SPAWN_ACCEL_NAV_BLOCKED_H

#include <cstdint>

inline bool AnneNavBlockedForTeam(std::uint8_t blockedBits, int team)
{
    if (team < 0)
        return false;
    std::uint8_t mask = static_cast<std::uint8_t>(
        1u << (static_cast<unsigned int>(team) & 1u));
    return (blockedBits & mask) != 0;
}

#endif
