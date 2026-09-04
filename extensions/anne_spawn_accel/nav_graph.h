#ifndef _INCLUDE_ANNE_SPAWN_ACCEL_NAV_GRAPH_H_
#define _INCLUDE_ANNE_SPAWN_ACCEL_NAV_GRAPH_H_

#include <cstdint>
#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

enum class AnneNavEdgeType : std::uint32_t
{
    Floor = 0,
    Ladder = 1,
    Elevator = 2,
};

enum AnneNavTopologyIssue : std::uint32_t
{
    AnneNavTopologyIssue_None = 0,
    AnneNavTopologyIssue_UnknownArea = 1u << 0,
    AnneNavTopologyIssue_InvalidFloorStorage = 1u << 1,
    AnneNavTopologyIssue_InvalidLadderStorage = 1u << 2,
    AnneNavTopologyIssue_DynamicElevator = 1u << 3,
    AnneNavTopologyIssue_UnresolvedDynamicElevator = 1u << 4,
};

constexpr std::uint32_t AnneNavTopologyIssue_FatalMask =
    AnneNavTopologyIssue_UnknownArea |
    AnneNavTopologyIssue_InvalidFloorStorage |
    AnneNavTopologyIssue_InvalidLadderStorage;

inline bool AnneNavTopologyHasFatalIssue(std::uint32_t issues)
{
    return (issues & AnneNavTopologyIssue_FatalMask) != 0;
}

struct AnneNavGraphMetadata
{
    std::string mapName;
    std::string baseCachePath;
    std::string cachePath;
    std::uint64_t fingerprint = 0;
    std::uint64_t dynamicStateFingerprint = 0;
    std::uint32_t topologyIssues = AnneNavTopologyIssue_None;
    std::vector<std::uint32_t> navIds;
    std::vector<float> centers;
    std::vector<float> flowDistances;
    float maxFlowDistance = 0.0f;
    std::uintptr_t navAreasListPointer = 0;
    std::vector<std::uintptr_t> areaPointers;
};

struct AnneNavGraphInputEdge
{
    std::uint32_t from = 0;
    std::uint32_t to = 0;
    AnneNavEdgeType type = AnneNavEdgeType::Floor;
};

struct AnneNavSearchTarget
{
    std::uint32_t index = 0;
    int client = 0;
};

class AnneNavGraph final
{
public:
    static constexpr std::uint32_t kTargetMask = 0x3fffffffu;
    static constexpr float kBoundarySlack = 32.0f;

    std::uint64_t fingerprint = 0;
    bool complete = false;
    bool hasElevatorEdges = false;
    std::uint32_t topologyIssues = AnneNavTopologyIssue_None;
    std::vector<std::uint32_t> navIds;
    std::vector<float> centers;
    std::vector<float> flowDistances;
    std::vector<float> resolvedFlowDistances;
    std::vector<float> flowResolveDistances;
    float maxFlowDistance = 0.0f;
    std::vector<std::uint32_t> offsets;
    std::vector<std::uint32_t> edges;
    std::vector<std::uint32_t> reverseOffsets;
    std::vector<std::uint32_t> reverseEdges;
    std::unordered_map<std::uint32_t, std::uint32_t> idToIndex;

    bool Finalize(std::string &error);
    bool FindIndex(std::uint32_t navId, std::uint32_t &index) const;
    bool BuildReverseReachability(std::uint32_t targetIndex, float maxDistance,
                                  const std::vector<std::uint8_t> &blocked,
                                  std::vector<float> &distances,
                                  std::vector<std::uint8_t> &usesSpecialEdge) const;
    bool BuildReverseReachability(
        const std::vector<AnneNavSearchTarget> &targets, float maxDistance,
        const std::vector<std::uint8_t> &blocked,
        std::vector<float> &distances,
        std::vector<std::uint8_t> &usesSpecialEdge,
        std::vector<int> &owners) const;

    static std::uint32_t PackEdge(std::uint32_t target, AnneNavEdgeType type);
    static std::uint32_t EdgeTarget(std::uint32_t edge);
    static AnneNavEdgeType EdgeType(std::uint32_t edge);
};

std::uint64_t AnneComputeNavTopologyFingerprint(
    std::uint64_t baseFingerprint,
    std::vector<AnneNavGraphInputEdge> inputEdges,
    std::uint32_t topologyIssues,
    std::uint64_t dynamicStateFingerprint = 0);

std::string AnneNavGraphVariantCachePath(
    const std::string &basePath,
    std::uint64_t fingerprint);

bool AnneBuildNavCandidateSnapshot(
    const AnneNavGraph &graph,
    std::uint32_t targetIndex,
    float maxPathDistance,
    const std::vector<std::uint8_t> &blocked,
    const std::vector<float> &survivorEyes,
    float minSurvivorDistance,
    std::vector<std::uint32_t> &areaIndices,
    std::vector<float> &candidatePathDistances,
    std::vector<float> &pathDistances,
    std::vector<std::uint8_t> &usesSpecialEdge);

bool AnneBuildRankedNavCandidateSnapshot(
    const AnneNavGraph &graph,
    std::uint32_t targetIndex,
    float maxPathDistance,
    const std::vector<std::uint8_t> &blocked,
    const std::vector<float> &survivorEyes,
    float minSurvivorDistance,
    float targetEyeZ,
    float highGroundMinHeight,
    float highGroundDistanceScale,
    std::vector<std::uint32_t> &areaIndices,
    std::vector<float> &candidatePathDistances,
    std::vector<float> &candidateRankDistances,
    std::vector<float> &pathDistances,
    std::vector<std::uint8_t> &usesSpecialEdge);

// Team snapshot: one reverse multi-source field. Distance is the minimum
// directed path to any target; owner is the client realizing it.
//
// When perTargetDistances is non-null it additionally receives one directed
// distance layer per target, laid out row-major as
// perTargetDistances[row * targets.size() + t] = candidate(row) -> targets[t],
// +inf when that target is not reachable within maxPathDistance. Consumers can
// re-derive "nearest remaining target" for any subset of the targets without
// rebuilding the snapshot (e.g. skipping a survivor that already carries its
// maximum number of Special Infected).
bool AnneBuildTeamNavCandidateSnapshot(
    const AnneNavGraph &graph,
    const std::vector<AnneNavSearchTarget> &targets,
    float maxPathDistance,
    const std::vector<std::uint8_t> &blocked,
    const std::vector<float> &survivorEyes,
    float minSurvivorDistance,
    std::vector<std::uint32_t> &areaIndices,
    std::vector<float> &candidatePathDistances,
    std::vector<int> &candidateOwners,
    std::vector<float> &pathDistances,
    std::vector<std::uint8_t> &usesSpecialEdge,
    std::vector<float> *perTargetDistances = nullptr);

// Resolves the effective distance/owner of one snapshot row when only the
// targets flagged in activeTargets participate. Returns false when no active
// target reaches the row. Ties prefer the lower client index.
bool AnneResolveTeamCandidateForActiveTargets(
    const std::vector<float> &perTargetDistances,
    const std::vector<int> &targetClients,
    const std::vector<std::uint8_t> &activeTargets,
    std::size_t row,
    float &distance,
    int &owner);

std::shared_ptr<AnneNavGraph> AnneBuildNavGraph(
    const AnneNavGraphMetadata &metadata,
    std::vector<AnneNavGraphInputEdge> inputEdges,
    bool complete,
    std::string &error);

std::shared_ptr<AnneNavGraph> AnneLoadNavGraph(
    const AnneNavGraphMetadata &metadata,
    std::string &error);

bool AnneSaveNavGraph(const AnneNavGraph &graph, const std::string &path, std::string &error);
bool AnneStageNavGraphCache(const AnneNavGraph &graph, const std::string &path,
                            std::string &temporaryPath, std::string &error);
bool AnnePublishNavGraphCache(const std::string &temporaryPath, const std::string &path,
                              std::string &error);
void AnneDiscardNavGraphCache(const std::string &temporaryPath);

#endif
