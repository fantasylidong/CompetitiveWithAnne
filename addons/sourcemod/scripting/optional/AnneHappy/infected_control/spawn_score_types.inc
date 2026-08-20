#if defined _infected_control_spawn_score_types_included
    #endinput
#endif
#define _infected_control_spawn_score_types_included

enum SIClass
{
    SI_None    = 0,
    SI_Smoker  = 1,
    SI_Boomer  = 2,
    SI_Hunter  = 3,
    SI_Spitter = 4,
    SI_Jockey  = 5,
    SI_Charger = 6
};

// 单次最终入选刷点的评分快照（只打印最终点）
enum struct SpawnScoreDbg
{
    float total;
    float baseTotal;
    float weightedQuality;
    float dist;
    float hght;
    float flow;
    float flowBase;
    float flowPenalty;
    float dispRaw;
    float dispScaled;
    float dispKernel;
    float penK;
    float extraPen;
    float behindPen;
    float lowHeightPen;
    float targetFootZ;
    float lowHeightDrop;
    float lowHeightMultiplier;
    float highHeightBonus;
    float highHeightRise;        // 带符号：候选中心 - 目标眼位
    float highHeightDropFactor;  // 高点奖励的可落下折算系数
    float dropQuality;           // 0..1，直落落点离最近生还者的接近度
    float tacticalQuality;

    float dTargetEye;
    float navDistance;
    float navRankDistance;
    float navDistanceEffective;
    float navHighSortScale;
    float navHighGroundComp;
    float ringEff;
    float sweet;
    float width;

    int candBucket;
    int centerBucket;
    int deltaFlow;
    int lowHeightSteps;
    int highHeightSteps;
    int sector;
    int areaIdx;
    bool rawBadFlow;
    bool flowBucketKnown;

    float pos[3];
}
