#if defined _anne_nextbot_included
    #endinput
#endif
#define _anne_nextbot_included

#define ANNE_NEXTBOT_LIBRARY "anne_nextbot"

enum AnneNextBotPathConsumer
{
    AnneNextBotPathConsumer_Tank = (1 << 0),
    AnneNextBotPathConsumer_Charger = (1 << 1)
};

native bool AnneNextBot_IsActive();
native bool AnneNextBot_IsPathBrokerActive();

native bool AnneNextBot_SetPathConsumer(
    AnneNextBotPathConsumer consumer,
    bool enabled
);

native bool AnneNextBot_Configure(
    bool enabled,
    int globalUpdateTicks,
    int commonTicks,
    int smokerTicks,
    int boomerTicks,
    int hunterTicks,
    int spitterTicks,
    int jockeyTicks,
    int chargerTicks,
    int witchTicks,
    int tankTicks,
    int survivorBotTicks
);

forward void AnneNextBot_OnTankPathFollowerUpdate(int client, int pathFollower);
forward void AICharger3_OnPathFollowerUpdate(int client, int pathFollower);
