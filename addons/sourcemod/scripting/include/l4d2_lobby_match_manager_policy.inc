#if defined _l4d2_lobby_match_manager_policy_included
	#endinput
#endif
#define _l4d2_lobby_match_manager_policy_included

#define UNRESERVE_ALWAYS 1
#define UNRESERVE_WHEN_FULL 2
#define UNRESERVE_DEFAULT_EMPTY 3

stock bool LobbyPolicy_IsLobbyFull(int playerCount, int maxLobbySlots)
{
	return playerCount >= maxLobbySlots;
}

stock bool LobbyPolicy_ShouldClearAlwaysReservation(bool hasReservation, int playerCount, int maxLobbySlots)
{
	if (!hasReservation)
		return true;

	return LobbyPolicy_IsLobbyFull(playerCount, maxLobbySlots);
}

stock bool LobbyPolicy_ShouldClearOnJoin(int unreserveType, bool hasReservation, int playerCount, int maxLobbySlots)
{
	if (unreserveType == UNRESERVE_ALWAYS)
		return LobbyPolicy_ShouldClearAlwaysReservation(hasReservation, playerCount, maxLobbySlots);

	if (unreserveType == UNRESERVE_WHEN_FULL)
		return LobbyPolicy_IsLobbyFull(playerCount, maxLobbySlots);

	return false;
}

stock bool LobbyPolicy_ShouldBlockReservePatch(int unreserveType, bool hasReservation, int playerCount, int maxLobbySlots)
{
	if (unreserveType != UNRESERVE_ALWAYS)
		return false;

	return LobbyPolicy_ShouldClearAlwaysReservation(hasReservation, playerCount, maxLobbySlots);
}

stock bool LobbyPolicy_ShouldClearDefaultReservation(int unreserveType, int playerCount, bool forceClearObserved, bool lobbyReservationObserved)
{
	if (unreserveType != UNRESERVE_DEFAULT_EMPTY || playerCount > 0)
		return false;

	if (!forceClearObserved && lobbyReservationObserved)
		return false;

	return true;
}
