#if defined _l4d2_lobby_match_manager_policy_included
	#endinput
#endif
#define _l4d2_lobby_match_manager_policy_included

#define UNRESERVE_ANNE 1
#define UNRESERVE_WHEN_FULL 2
#define UNRESERVE_DEFAULT_EMPTY 3
#define ANNE_UNRESERVE_PLAYER_COUNT 3
#define LOBBY_CAMPAIGN_SWITCH_MAX_SLOTS 4

stock bool LobbyPolicy_IsLobbyFull(int playerCount, int maxLobbySlots)
{
	return playerCount >= maxLobbySlots;
}

stock bool LobbyPolicy_ShouldClearAnneReservation(int playerCount)
{
	return playerCount >= ANNE_UNRESERVE_PLAYER_COUNT;
}

stock bool LobbyPolicy_ShouldClearOnJoin(int unreserveType, int playerCount, int maxLobbySlots, bool anneLobbyReleased)
{
	if (unreserveType == UNRESERVE_ANNE)
		return !anneLobbyReleased && LobbyPolicy_ShouldClearAnneReservation(playerCount);

	if (unreserveType == UNRESERVE_WHEN_FULL)
		return LobbyPolicy_IsLobbyFull(playerCount, maxLobbySlots);

	return false;
}

stock bool LobbyPolicy_ShouldClearCampaignLobbyOnVersusSwitch(int unreserveType, const char[] reservationMode, int reservationMaxSlots, const char[] currentMode, int configuredPlayerSlots, bool noticeSent)
{
	if (noticeSent || unreserveType == UNRESERVE_ANNE)
		return false;

	return (StrEqual(reservationMode, "coop", false) || StrEqual(reservationMode, "campaign", false))
		&& reservationMaxSlots > 0
		&& reservationMaxSlots <= LOBBY_CAMPAIGN_SWITCH_MAX_SLOTS
		&& StrEqual(currentMode, "versus", false)
		&& configuredPlayerSlots > LOBBY_CAMPAIGN_SWITCH_MAX_SLOTS;
}

stock bool LobbyPolicy_ShouldBlockReservePatch(int unreserveType, bool anneLobbyReleased)
{
	return unreserveType == UNRESERVE_ANNE && anneLobbyReleased;
}

stock bool LobbyPolicy_ShouldClearDefaultReservation(int unreserveType, int playerCount, bool forceClearObserved, bool lobbyReservationObserved)
{
	if (unreserveType != UNRESERVE_DEFAULT_EMPTY || playerCount > 0)
		return false;

	if (!forceClearObserved && lobbyReservationObserved)
		return false;

	return true;
}
