#if defined _anne_nextbot_included
    #endinput
#endif
#define _anne_nextbot_included

#define ANNE_NEXTBOT_LIBRARY "anne_nextbot"

enum AnneNextBotPathConsumer
{
    AnneNextBotPathConsumer_Tank = (1 << 0),
    AnneNextBotPathConsumer_Charger = (1 << 1),
    AnneNextBotPathConsumer_Boomer = (1 << 2),
    AnneNextBotPathConsumer_Spitter = (1 << 3)
};

enum AnneNextBotPathSegmentType
{
    AnneNextBotPathSegment_OnGround = 0,
    AnneNextBotPathSegment_DropDown,
    AnneNextBotPathSegment_ClimbUp,
    AnneNextBotPathSegment_JumpGap,
    AnneNextBotPathSegment_LadderUp,
    AnneNextBotPathSegment_LadderDown
};

native bool AnneNextBot_IsActive();
native bool AnneNextBot_IsPathBrokerActive();

native bool AnneNextBot_SetPathConsumer(
    AnneNextBotPathConsumer consumer,
    bool enabled
);

native bool AnneNextBot_GetPathSnapshotInfo(
    int client,
    int &segmentCount,
    int &currentSegmentIndex,
    bool &complete,
    float &age
);

native bool AnneNextBot_GetPathSegment(
    int client,
    int segmentIndex,
    Address &navArea,
    int &traverseType,
    float goal[3],
    int &segmentType,
    float pathForward[3],
    float &length,
    float &distanceFromStart
);

// These mutations are valid only from the matching snapshot-updated forward.
native bool AnneNextBot_SetPathGoal(int client, int segmentIndex);
native bool AnneNextBot_InvalidatePath(int client);

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

forward void AnneNextBot_OnTankPathSnapshotUpdated(int client);
forward void AnneNextBot_OnChargerPathSnapshotUpdated(int client);
forward void AnneNextBot_OnBoomerPathSnapshotUpdated(int client);
forward void AnneNextBot_OnSpitterPathSnapshotUpdated(int client);
