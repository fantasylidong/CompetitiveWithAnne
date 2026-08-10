#include "extension.h"
#include "nav_blocked.h"
#include "nav_graph.h"
#include "worker_pool.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <limits>
#include <memory>
#include <mutex>
#include <numeric>
#include <string>
#include <sys/stat.h>
#include <unordered_map>
#include <utility>
#include <vector>

namespace
{
constexpr int kMaxSnapshotClients = 64;
constexpr int kMaxGeometryBatch = 128;
constexpr int kMaxTopKCandidates = 4096;
constexpr int kMaxSpatialPoints = 100000;
constexpr int kTeamSurvivor = 2;
constexpr int kTeamInfected = 3;
constexpr int kSafetySafe = 0;
constexpr int kSafetyStuck = 1;
constexpr int kSafetyVisible = 2;
constexpr int kNavGraphIdle = 0;
constexpr int kNavGraphLoading = 1;
constexpr int kNavGraphBuilding = 2;
constexpr int kNavGraphReady = 3;
constexpr int kNavGraphFailed = 4;
constexpr int kNavGraphNeedBuild = 5;
constexpr int kNavGraphReadyPending = 6;
constexpr int kNavGraphDynamicWait = 7;
constexpr std::size_t kGraphWorkerCount = 2;
constexpr std::size_t kGraphWorkerQueueLimit = 32;
constexpr int kNavSnapshotBatchAreas = 512;
constexpr std::size_t kTopologyPollBatchAreas = 1024;
constexpr int kMaxFloorConnections = 4096;
constexpr int kMaxLadderConnections = 256;
constexpr float kBlockerSnapshotSeconds = 1.0f;
constexpr std::size_t kBlockedSnapshotSanityMinAreas = 128;
constexpr float kCandidateSpatialQuantum = 32.0f;
constexpr std::size_t kCandidateCacheLimit = 8;
constexpr std::size_t kCandidatePerfSampleCap = 256;
constexpr int kCandidatePending = -1;
constexpr int kCandidateUnavailable = -2;
constexpr int kNavDiagComplete = 1 << 0;
constexpr int kNavDiagCacheHit = 1 << 1;
constexpr int kNavDiagUnknownArea = 1 << 2;
constexpr int kNavDiagInvalidFloorStorage = 1 << 3;
constexpr int kNavDiagInvalidLadderStorage = 1 << 4;
constexpr int kNavDiagDynamicElevator = 1 << 5;
constexpr int kNavDiagUnresolvedDynamicElevator = 1 << 6;
constexpr std::size_t kUnknownAreaSampleCap = 8;
constexpr std::uint32_t kNavMeshElevator = 0x40000000u;
constexpr double kDynamicNavWarmPollSeconds = 0.1;
constexpr double kDynamicNavIdlePollSeconds = 1.0;
constexpr double kDynamicNavStableSeconds = 0.2;

enum class NavUnknownConnectionKind : std::uint8_t
{
    Floor,
    LadderTopForward,
    LadderTopLeft,
    LadderTopRight,
    LadderBottom,
};

struct NavUnknownAreaSample
{
    std::uint32_t sourceIndex = 0;
    std::uint32_t sourceNavId = 0;
    std::uintptr_t targetPointer = 0;
    NavUnknownConnectionKind kind = NavUnknownConnectionKind::Floor;
    int direction = -1;
    int slot = -1;
};

struct DynamicElevatorWatch
{
    std::uintptr_t pointer = 0;
    int entityReference = -1;
    int originOffset = -1;
    int velocityOffset = -1;
    int toggleStateOffset = -1;
    std::vector<std::uint32_t> areaIndices;
};

struct DynamicNavStateSample
{
    std::uint64_t fingerprint = 0;
    std::uint64_t floorConnections = 0;
    std::uint64_t ladderConnections = 0;
    std::uint64_t entityFingerprint = 0;
    std::uint32_t areaCount = 0;
    std::vector<std::uint64_t> areaFingerprints;
    bool moving = false;
    bool entitiesResolved = true;
    bool areaListValid = true;
    bool topologyReadable = true;
};

struct DynamicNavMonitor
{
    bool watching = false;
    bool hasDynamicAreas = false;
    bool dirty = false;
    bool moving = false;
    bool entitiesResolved = true;
    bool areaListValid = true;
    bool topologyReadable = true;
    double nextPollAt = 0.0;
    double lastChangeAt = 0.0;
    std::uint64_t rawFingerprint = 0;
    std::uint64_t capturedFingerprint = 0;
    std::uint64_t epoch = 0;
    std::uint64_t changes = 0;
    std::uint64_t rebuilds = 0;
    std::uint64_t cacheLoads = 0;
    std::uint64_t pollSamples = 0;
    std::uint64_t floorConnections = 0;
    std::uint64_t ladderConnections = 0;
    std::uint64_t entityFingerprint = 0;
    std::uint32_t areaCount = 0;
    std::size_t topologyPollCursor = 0;
    float pollLastMs = 0.0f;
    float pollMaxMs = 0.0f;
    std::vector<std::uint32_t> dynamicAreaIndices;
    std::vector<std::uint64_t> areaFingerprints;
    std::vector<DynamicElevatorWatch> elevators;
    std::unordered_map<std::uintptr_t, std::uint32_t> pointerToIndex;
};

struct NavGraphCapture
{
    std::shared_ptr<AnneNavGraphMetadata> metadata;
    std::unordered_map<std::uintptr_t, std::uint32_t> pointerToIndex;
    std::vector<AnneNavGraphInputEdge> edges;
    std::size_t cursor = 0;
    bool complete = true;
    bool forceRebuild = false;
    std::uint32_t topologyIssues = AnneNavTopologyIssue_None;
    std::uint64_t unknownAreaCount = 0;
    std::vector<NavUnknownAreaSample> unknownAreaSamples;
    std::vector<std::uint8_t> dynamicAreaMask;
    std::vector<std::uint32_t> dynamicAreaIndices;
    std::vector<DynamicElevatorWatch> elevators;
    DynamicNavStateSample dynamicStateAtStart;
};

struct ReachabilityResult
{
    std::uint64_t generation = 0;
    std::uint64_t serial = 0;
    std::uint32_t targetId = 0;
    float maxDistance = 0.0f;
    int team = 0;
    bool ignoreNavBlockers = false;
    int blockedEpoch = -1;
    std::vector<float> distances;
    std::vector<std::uint8_t> usesSpecialEdge;
    std::vector<std::uint32_t> reachable;
};

struct ReachabilityRequest
{
    std::uint64_t serial = 0;
    std::uint32_t targetId = 0;
    float maxDistance = 0.0f;
    int team = 0;
    bool ignoreNavBlockers = false;
    int blockedEpoch = -1;
};

struct NavCandidateResult
{
    std::uint64_t generation = 0;
    std::uint64_t serial = 0;
    std::uint64_t survivorSpatialKey = 0;
    int targetClient = 0;
    std::uint32_t targetId = 0;
    float maxPathDistance = 0.0f;
    float minSurvivorDistance = 0.0f;
    int blockedEpoch = -1;
    double completedAt = 0.0;
    float buildMs = 0.0f;
    std::vector<std::uint32_t> areaIndices;
    std::vector<float> pathDistances;
};

struct NavCandidateRequest
{
    std::uint64_t serial = 0;
    std::uint64_t generation = 0;
    std::uint64_t survivorSpatialKey = 0;
    int targetClient = 0;
    std::uint32_t targetId = 0;
    float maxPathDistance = 0.0f;
    float minSurvivorDistance = 0.0f;
    int blockedEpoch = -1;
};

struct NavCandidatePerf
{
    std::array<float, kCandidatePerfSampleCap> buildMs{};
    std::array<float, kCandidatePerfSampleCap> resultAgeMs{};
    std::size_t buildWrite = 0;
    std::size_t buildCount = 0;
    std::size_t ageWrite = 0;
    std::size_t ageCount = 0;
    std::uint64_t queued = 0;
    std::uint64_t published = 0;
    std::uint64_t cacheHits = 0;
    std::uint64_t coalesced = 0;
    std::uint64_t staleDrops = 0;
    std::uint64_t collectHits = 0;
    std::uint64_t collectPending = 0;
    std::uint64_t collectUnavailable = 0;
    int lastCandidateCount = 0;
    int lastRangeCandidateCount = 0;
};

struct SurvivorSnapshot
{
    int client = 0;
    bool incapacitated = false;
    Vector eyes;
    Vector eyesLeft;
    Vector eyesRight;
};

struct PathCacheKey
{
    std::uint32_t goalId;
    std::uint32_t startId;
    std::int32_t quantizedLength;
    std::int32_t exactLengthBits;
    std::int32_t blockedEpoch;
    std::int16_t team;
    bool ignoreNavBlockers;

    bool operator==(const PathCacheKey &other) const
    {
        return goalId == other.goalId && startId == other.startId &&
               quantizedLength == other.quantizedLength &&
               exactLengthBits == other.exactLengthBits &&
               blockedEpoch == other.blockedEpoch && team == other.team &&
               ignoreNavBlockers == other.ignoreNavBlockers;
    }
};

struct PathCacheKeyHash
{
    std::size_t operator()(const PathCacheKey &key) const
    {
        std::size_t value = static_cast<std::size_t>(key.goalId);
        value = value * 16777619u ^ static_cast<std::size_t>(key.startId);
        value = value * 16777619u ^ static_cast<std::uint32_t>(key.quantizedLength);
        value = value * 16777619u ^ static_cast<std::uint32_t>(key.exactLengthBits);
        value = value * 16777619u ^ static_cast<std::uint32_t>(key.blockedEpoch);
        value = value * 16777619u ^ static_cast<std::uint16_t>(key.team);
        return value * 16777619u ^ static_cast<std::size_t>(key.ignoreNavBlockers);
    }
};

using IsVisibleToPlayerFn = bool (*)(const Vector &, CBaseEntity *, int, int, float,
                                     const CBaseEntity *, void **, bool *);
using NavAreaBuildPathFn = bool (*)(void *, void *, const Vector *, const Vector *, void *,
                                    void **, float, int, bool);

IEngineTrace *g_EngineTrace = nullptr;
IStaticPropMgrServer *g_StaticPropMgr = nullptr;
IGameConfig *g_GameConfig = nullptr;
IsVisibleToPlayerFn g_IsVisibleToPlayer = nullptr;
NavAreaBuildPathFn g_NavAreaBuildPath = nullptr;
void *g_TheNavAreas = nullptr;
std::array<SurvivorSnapshot, kMaxSnapshotClients> g_Survivors{};
std::size_t g_SurvivorCount = 0;
std::uint64_t g_SurvivorSpatialKey = 0;
std::unordered_map<PathCacheKey, bool, PathCacheKeyHash> g_PathCache;
int g_PathCacheEpoch = -1;
int g_BlockTypeOffset = -1;
int g_NavAreaIdOffset = -1;
int g_NavAreaCenterOffset = -1;
int g_NavAreaFlowOffset = -1;
int g_NavAreaBlockedBitsOffset = -1;
int g_NavAreaAttributesOffset = -1;
int g_NavAreaConnectionsOffset = -1;
int g_NavAreaLaddersOffset = -1;
int g_NavAreaElevatorOffset = -1;
int g_NavAreasCountOffset = -1;
int g_LadderTopForwardOffset = -1;
int g_LadderTopLeftOffset = -1;
int g_LadderTopRightOffset = -1;
int g_LadderBottomOffset = -1;

AnneWorkerPool g_Workers;
std::atomic<int> g_NavGraphState{kNavGraphIdle};
std::atomic<std::uint64_t> g_NavGraphGeneration{0};
std::atomic<std::uint64_t> g_ReachabilitySerial{0};
std::atomic<std::uint64_t> g_NavCandidateSerial{0};
std::mutex g_GraphMutex;
std::shared_ptr<AnneNavGraphMetadata> g_NavMetadata;
std::shared_ptr<AnneNavGraph> g_NavGraph;
std::shared_ptr<AnneNavGraph> g_PendingNavGraph;
std::unique_ptr<NavGraphCapture> g_NavCapture;
std::vector<std::shared_ptr<ReachabilityResult>> g_ReachabilityCache;
std::vector<std::shared_ptr<ReachabilityResult>> g_PendingReachability;
std::vector<ReachabilityRequest> g_ReachabilityInFlight;
std::vector<std::shared_ptr<NavCandidateResult>> g_NavCandidateCache;
std::vector<std::shared_ptr<NavCandidateResult>> g_PendingNavCandidates;
std::vector<NavCandidateRequest> g_NavCandidateInFlight;
NavCandidatePerf g_NavCandidatePerf;
std::string g_NavGraphError;
std::vector<std::uint8_t> g_BlockedSnapshot;
float g_BlockedSnapshotTime = -1000.0f;
std::uint64_t g_BlockedSnapshotGeneration = 0;
int g_BlockedStateVersion = 0;
bool g_BlockedSnapshotIgnoreNavBlockers = false;
bool g_BlockedSnapshotValid = false;
int g_BlockedSnapshotTeam = -1;
std::size_t g_BlockedSnapshotBlockedCount = 0;
bool g_NavGraphForceRebuild = false;
bool g_NavGraphCacheHit = false;
std::uint64_t g_NavUnknownAreaCount = 0;
std::vector<NavUnknownAreaSample> g_NavUnknownAreaSamples;
DynamicNavMonitor g_DynamicNav;

template <typename T>
T ReadField(const void *base, int offset)
{
    T value{};
    std::memcpy(&value, static_cast<const std::uint8_t *>(base) + offset, sizeof(value));
    return value;
}

bool GetCells(IPluginContext *context, cell_t localAddress, cell_t *&cells)
{
    return context->LocalToPhysAddr(localAddress, &cells) == SP_ERROR_NONE && cells;
}

Vector ReadVector(const cell_t *cells, int offset = 0)
{
    return Vector(sp_ctof(cells[offset]), sp_ctof(cells[offset + 1]), sp_ctof(cells[offset + 2]));
}

bool IsFiniteVector(const Vector &value)
{
    return std::isfinite(value.x) && std::isfinite(value.y) && std::isfinite(value.z);
}

void *CellToPointer(cell_t value)
{
    return reinterpret_cast<void *>(
        static_cast<std::uintptr_t>(static_cast<std::uint32_t>(value)));
}

void SetGraphError(const std::string &error)
{
    std::lock_guard<std::mutex> lock(g_GraphMutex);
    g_NavGraphError = error;
}

void HashBytes(std::uint64_t &hash, const void *data, std::size_t size)
{
    constexpr std::uint64_t fnvPrime = 1099511628211ull;
    const auto *bytes = static_cast<const std::uint8_t *>(data);
    for (std::size_t i = 0; i < size; ++i)
    {
        hash ^= bytes[i];
        hash *= fnvPrime;
    }
}

double SteadySeconds()
{
    return std::chrono::duration<double>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
}

std::uint64_t ComputeSurvivorSpatialKey()
{
    std::uint64_t hash = 1469598103934665603ull;
    HashBytes(hash, &g_SurvivorCount, sizeof(g_SurvivorCount));
    for (std::size_t i = 0; i < g_SurvivorCount; ++i)
    {
        const SurvivorSnapshot &snapshot = g_Survivors[i];
        std::int32_t quantized[3] = {
            static_cast<std::int32_t>(std::floor(snapshot.eyes.x / kCandidateSpatialQuantum)),
            static_cast<std::int32_t>(std::floor(snapshot.eyes.y / kCandidateSpatialQuantum)),
            static_cast<std::int32_t>(std::floor(snapshot.eyes.z / kCandidateSpatialQuantum)),
        };
        HashBytes(hash, &snapshot.client, sizeof(snapshot.client));
        HashBytes(hash, &snapshot.incapacitated, sizeof(snapshot.incapacitated));
        HashBytes(hash, quantized, sizeof(quantized));
    }
    return hash;
}

bool NavCandidateMatches(const NavCandidateResult &result,
                         int targetClient, std::uint32_t targetId,
                         float maxPathDistance, float minSurvivorDistance,
                         std::uint64_t survivorSpatialKey, int blockedEpoch)
{
    return result.generation == g_NavGraphGeneration.load() &&
           result.targetClient == targetClient && result.targetId == targetId &&
           result.maxPathDistance + 0.01f >= maxPathDistance &&
           std::fabs(result.minSurvivorDistance - minSurvivorDistance) <= 0.01f &&
           result.survivorSpatialKey == survivorSpatialKey &&
           result.blockedEpoch == blockedEpoch;
}

bool NavCandidateRequestMatches(const NavCandidateRequest &request,
                                int targetClient, std::uint32_t targetId,
                                float maxPathDistance, float minSurvivorDistance,
                                std::uint64_t survivorSpatialKey, int blockedEpoch)
{
    return request.generation == g_NavGraphGeneration.load() &&
           request.targetClient == targetClient && request.targetId == targetId &&
           request.maxPathDistance + 0.01f >= maxPathDistance &&
           std::fabs(request.minSurvivorDistance - minSurvivorDistance) <= 0.01f &&
           request.survivorSpatialKey == survivorSpatialKey &&
           request.blockedEpoch == blockedEpoch;
}

std::shared_ptr<NavCandidateResult> FindNavCandidateLocked(
    int targetClient, std::uint32_t targetId,
    float maxPathDistance, float minSurvivorDistance,
    std::uint64_t survivorSpatialKey, int blockedEpoch)
{
    for (auto iterator = g_NavCandidateCache.rbegin();
         iterator != g_NavCandidateCache.rend(); ++iterator)
    {
        if (NavCandidateMatches(**iterator, targetClient, targetId,
                                maxPathDistance, minSurvivorDistance,
                                survivorSpatialKey, blockedEpoch))
        {
            return *iterator;
        }
    }
    return nullptr;
}

template <std::size_t Size>
void RecordCandidatePerfSample(std::array<float, Size> &samples,
                               std::size_t &write, std::size_t &count,
                               float value)
{
    samples[write] = std::max(0.0f, value);
    write = (write + 1) % Size;
    if (count < Size)
        ++count;
}

void ResetNavCandidatePerfLocked()
{
    g_NavCandidatePerf = NavCandidatePerf{};
}

template <std::size_t Size>
float CandidatePerfPercentile(const std::array<float, Size> &samples,
                              std::size_t count, float percentile)
{
    if (count == 0)
        return 0.0f;
    std::vector<float> sorted(samples.begin(), samples.begin() + count);
    std::sort(sorted.begin(), sorted.end());
    std::size_t index = static_cast<std::size_t>(
        std::ceil(static_cast<float>(count) * percentile));
    if (index > 0)
        --index;
    if (index >= sorted.size())
        index = sorted.size() - 1;
    return sorted[index];
}

void HashLooseMapFile(std::uint64_t &hash, const char *gameDirectory,
                      const char *mapName, const char *extension)
{
    char path[1024];
    std::snprintf(path, sizeof(path), "%s/maps/%s.%s",
                  gameDirectory, mapName, extension);
#if defined(_WIN32)
    struct _stat64 info{};
    if (_stat64(path, &info) != 0)
        return;
#else
    struct stat info{};
    if (stat(path, &info) != 0)
        return;
#endif
    std::uint64_t fileSize = static_cast<std::uint64_t>(info.st_size);
    std::int64_t modified = static_cast<std::int64_t>(info.st_mtime);
    HashBytes(hash, extension, std::strlen(extension));
    HashBytes(hash, &fileSize, sizeof(fileSize));
    HashBytes(hash, &modified, sizeof(modified));
}

std::shared_ptr<AnneNavGraphMetadata> CaptureNavMetadata(
    const char *mapName, const char *cachePath, float maxFlowDistance,
    std::string &error)
{
    if (!g_TheNavAreas || !mapName || !cachePath)
    {
        error = "TheNavAreas or graph path is unavailable";
        return nullptr;
    }

    void *areaList = ReadField<void *>(g_TheNavAreas, 0);
    int areaCount = ReadField<int>(g_TheNavAreas, g_NavAreasCountOffset);
    if (!areaList || areaCount <= 0 || areaCount > kMaxSpatialPoints)
    {
        error = "invalid TheNavAreas vector";
        return nullptr;
    }

    auto metadata = std::make_shared<AnneNavGraphMetadata>();
    metadata->mapName = mapName;
    metadata->baseCachePath = cachePath;
    metadata->cachePath = cachePath;
    metadata->navIds.reserve(areaCount);
    metadata->centers.reserve(static_cast<std::size_t>(areaCount) * 3);
    metadata->flowDistances.reserve(areaCount);
    metadata->maxFlowDistance = maxFlowDistance;
    metadata->navAreasListPointer = reinterpret_cast<std::uintptr_t>(areaList);
    metadata->areaPointers.reserve(areaCount);

    std::uint64_t fingerprint = 1469598103934665603ull;
    HashBytes(fingerprint, mapName, std::strlen(mapName));
    HashBytes(fingerprint, &areaCount, sizeof(areaCount));
    char gameDirectory[1024] = "";
    engine->GetGameDir(gameDirectory, sizeof(gameDirectory));
    HashLooseMapFile(fingerprint, gameDirectory, mapName, "bsp");
    HashLooseMapFile(fingerprint, gameDirectory, mapName, "nav");
    for (int i = 0; i < areaCount; ++i)
    {
        void *area = ReadField<void *>(areaList, i * static_cast<int>(sizeof(void *)));
        if (!area)
        {
            error = "TheNavAreas contains a null area";
            return nullptr;
        }

        std::uint32_t id = ReadField<std::uint32_t>(area, g_NavAreaIdOffset);
        Vector center(
            ReadField<float>(area, g_NavAreaCenterOffset),
            ReadField<float>(area, g_NavAreaCenterOffset + 4),
            ReadField<float>(area, g_NavAreaCenterOffset + 8));
        std::uint32_t attributes = ReadField<std::uint32_t>(area, g_NavAreaAttributesOffset);
        metadata->navIds.push_back(id);
        metadata->centers.push_back(center.x);
        metadata->centers.push_back(center.y);
        metadata->centers.push_back(center.z);
        metadata->flowDistances.push_back(ReadField<float>(area, g_NavAreaFlowOffset));
        metadata->areaPointers.push_back(reinterpret_cast<std::uintptr_t>(area));
        HashBytes(fingerprint, &id, sizeof(id));
        HashBytes(fingerprint, &center, sizeof(center));
        HashBytes(fingerprint, &attributes, sizeof(attributes));
    }
    metadata->fingerprint = fingerprint;
    return metadata;
}

void ResolveDynamicElevatorEntity(DynamicElevatorWatch &watch)
{
    if (!watch.pointer || !gamehelpers || !gpGlobals)
        return;

    CBaseEntity *resolved = nullptr;
    for (int index = gpGlobals->maxClients + 1; index < gpGlobals->maxEntities; ++index)
    {
        CBaseEntity *entity = gamehelpers->ReferenceToEntity(index);
        if (reinterpret_cast<std::uintptr_t>(entity) != watch.pointer)
            continue;
        const char *classname = gamehelpers->GetEntityClassname(entity);
        if (!classname || std::strcmp(classname, "func_elevator") != 0)
            return;
        resolved = entity;
        break;
    }
    if (!resolved)
        return;

    watch.entityReference = gamehelpers->EntityToBCompatRef(resolved);
    datamap_t *map = gamehelpers->GetDataMap(resolved);
    if (!map)
        return;

    auto resolveOffset = [map](const char *name) {
        sm_datatable_info_t info{};
        return gamehelpers->FindDataMapInfo(map, name, &info)
            ? info.actual_offset : -1;
    };
    watch.originOffset = resolveOffset("m_vecAbsOrigin");
    watch.velocityOffset = resolveOffset("m_vecAbsVelocity");
    watch.toggleStateOffset = resolveOffset("m_toggle_state");
}

void DiscoverDynamicNavState(NavGraphCapture &capture)
{
    std::size_t areaCount = capture.metadata->areaPointers.size();
    capture.dynamicAreaMask.assign(areaCount, 0);
    std::unordered_map<std::uintptr_t, std::size_t> elevatorToWatch;

    for (std::uint32_t index = 0; index < areaCount; ++index)
    {
        void *area = reinterpret_cast<void *>(capture.metadata->areaPointers[index]);
        std::uint32_t attributes = ReadField<std::uint32_t>(
            area, g_NavAreaAttributesOffset);
        void *elevator = ReadField<void *>(area, g_NavAreaElevatorOffset);
        if ((attributes & kNavMeshElevator) == 0 && !elevator)
            continue;

        capture.dynamicAreaMask[index] = 1;
        capture.dynamicAreaIndices.push_back(index);
        capture.topologyIssues |= AnneNavTopologyIssue_DynamicElevator;
        if (!elevator)
        {
            // NAV_MESH_ELEVATOR may be present while the engine does not expose
            // an elevator object for this stable state. The live directed
            // connections remain authoritative and are still watched.
            capture.topologyIssues |= AnneNavTopologyIssue_UnresolvedDynamicElevator;
            continue;
        }

        std::uintptr_t pointer = reinterpret_cast<std::uintptr_t>(elevator);
        auto inserted = elevatorToWatch.emplace(pointer, capture.elevators.size());
        if (inserted.second)
        {
            DynamicElevatorWatch watch;
            watch.pointer = pointer;
            capture.elevators.push_back(std::move(watch));
        }
        capture.elevators[inserted.first->second].areaIndices.push_back(index);
    }

    std::sort(capture.elevators.begin(), capture.elevators.end(),
              [&capture](const DynamicElevatorWatch &left,
                         const DynamicElevatorWatch &right) {
        std::uint32_t leftId = capture.metadata->navIds[left.areaIndices.front()];
        std::uint32_t rightId = capture.metadata->navIds[right.areaIndices.front()];
        return leftId < rightId;
    });
    for (DynamicElevatorWatch &watch : capture.elevators)
    {
        std::sort(watch.areaIndices.begin(), watch.areaIndices.end(),
                  [&capture](std::uint32_t left, std::uint32_t right) {
            return capture.metadata->navIds[left] < capture.metadata->navIds[right];
        });
        ResolveDynamicElevatorEntity(watch);
    }
}

std::uint32_t DynamicElevatorGroupKey(
    const AnneNavGraphMetadata &metadata,
    const std::vector<DynamicElevatorWatch> &watches,
    std::uintptr_t pointer)
{
    for (const DynamicElevatorWatch &watch : watches)
    {
        if (watch.pointer == pointer && !watch.areaIndices.empty())
            return metadata.navIds[watch.areaIndices.front()];
    }
    return std::numeric_limits<std::uint32_t>::max();
}

void HashLiveNavTarget(
    std::uint64_t &hash, void *target,
    const AnneNavGraphMetadata &metadata,
    const std::unordered_map<std::uintptr_t, std::uint32_t> &pointerToIndex)
{
    std::uintptr_t targetPointer = reinterpret_cast<std::uintptr_t>(target);
    std::uint32_t targetId = 0;
    if (target)
    {
        auto found = pointerToIndex.find(targetPointer);
        if (found != pointerToIndex.end())
        {
            targetId = metadata.navIds[found->second];
        }
        else
        {
            // Keep different unknown pointers distinguishable until the full
            // capture records the fatal unknown-area diagnostic.
            targetId = std::numeric_limits<std::uint32_t>::max();
            HashBytes(hash, &targetPointer, sizeof(targetPointer));
        }
    }
    HashBytes(hash, &targetId, sizeof(targetId));
}

void HashLiveFloorConnections(
    DynamicNavStateSample &sample, std::uint64_t &hash, void *area,
    const AnneNavGraphMetadata &metadata,
    const std::unordered_map<std::uintptr_t, std::uint32_t> &pointerToIndex)
{
    constexpr std::uint32_t floorKind = 0;
    for (int direction = 0; direction < 4; ++direction)
    {
        void *storage = ReadField<void *>(
            area, g_NavAreaConnectionsOffset + direction * 4);
        int count = storage ? ReadField<int>(storage, 0) : 0;
        HashBytes(hash, &floorKind, sizeof(floorKind));
        HashBytes(hash, &direction, sizeof(direction));
        HashBytes(hash, &count, sizeof(count));
        if (count < 0 || count > kMaxFloorConnections)
        {
            sample.topologyReadable = false;
            continue;
        }
        for (int slot = 0; slot < count; ++slot)
        {
            void *target = ReadField<void *>(storage, 4 + slot * 8);
            if (target)
                ++sample.floorConnections;
            HashLiveNavTarget(hash, target, metadata, pointerToIndex);
        }
    }
}

void HashLiveLadderConnections(
    DynamicNavStateSample &sample, std::uint64_t &hash, void *area,
    const AnneNavGraphMetadata &metadata,
    const std::unordered_map<std::uintptr_t, std::uint32_t> &pointerToIndex)
{
    constexpr std::uint32_t ladderKind = 1;
    for (int goingUp = 0; goingUp < 2; ++goingUp)
    {
        void *storage = ReadField<void *>(
            area, g_NavAreaLaddersOffset + (goingUp ? 0 : 4));
        int count = storage ? ReadField<int>(storage, 0) : 0;
        HashBytes(hash, &ladderKind, sizeof(ladderKind));
        HashBytes(hash, &goingUp, sizeof(goingUp));
        HashBytes(hash, &count, sizeof(count));
        if (count < 0 || count > kMaxLadderConnections)
        {
            sample.topologyReadable = false;
            continue;
        }
        for (int slot = 0; slot < count; ++slot)
        {
            void *ladder = ReadField<void *>(
                storage, 4 + slot * static_cast<int>(sizeof(void *)));
            bool validLadder = ladder != nullptr;
            HashBytes(hash, &validLadder, sizeof(validLadder));
            if (!validLadder)
            {
                sample.topologyReadable = false;
                continue;
            }

            if (goingUp)
            {
                const int endpointOffsets[] = {
                    g_LadderTopForwardOffset,
                    g_LadderTopLeftOffset,
                    g_LadderTopRightOffset,
                };
                for (int endpoint = 0; endpoint < 3; ++endpoint)
                {
                    HashBytes(hash, &endpoint, sizeof(endpoint));
                    void *target = ReadField<void *>(ladder, endpointOffsets[endpoint]);
                    if (target)
                        ++sample.ladderConnections;
                    HashLiveNavTarget(hash, target, metadata, pointerToIndex);
                }
            }
            else
            {
                constexpr int endpoint = 3;
                HashBytes(hash, &endpoint, sizeof(endpoint));
                void *target = ReadField<void *>(ladder, g_LadderBottomOffset);
                if (target)
                    ++sample.ladderConnections;
                HashLiveNavTarget(hash, target, metadata, pointerToIndex);
            }
        }
    }
}

std::uint64_t HashLiveAreaTopology(
    DynamicNavStateSample &sample, void *area, std::uint32_t row,
    const AnneNavGraphMetadata &metadata,
    const std::vector<DynamicElevatorWatch> &watches,
    const std::unordered_map<std::uintptr_t, std::uint32_t> &pointerToIndex)
{
    std::uint64_t hash = 1469598103934665603ull;
    std::uint32_t attributes = ReadField<std::uint32_t>(
        area, g_NavAreaAttributesOffset);
    void *elevator = ReadField<void *>(area, g_NavAreaElevatorOffset);
    std::uint32_t navId = metadata.navIds[row];
    HashBytes(hash, &navId, sizeof(navId));
    HashLiveFloorConnections(sample, hash, area, metadata, pointerToIndex);
    HashLiveLadderConnections(sample, hash, area, metadata, pointerToIndex);

    bool dynamicArea = (attributes & kNavMeshElevator) != 0 || elevator;
    HashBytes(hash, &dynamicArea, sizeof(dynamicArea));
    if (dynamicArea)
    {
        std::uint32_t elevatorBit = attributes & kNavMeshElevator;
        std::uint32_t groupKey = DynamicElevatorGroupKey(
            metadata, watches, reinterpret_cast<std::uintptr_t>(elevator));
        HashBytes(hash, &elevatorBit, sizeof(elevatorBit));
        HashBytes(hash, &groupKey, sizeof(groupKey));
    }
    return hash;
}

void HashDynamicEntities(
    DynamicNavStateSample &sample, const AnneNavGraphMetadata &metadata,
    const std::vector<DynamicElevatorWatch> &watches)
{
    std::uint64_t hash = 1469598103934665603ull;
    for (const DynamicElevatorWatch &watch : watches)
    {
        std::uint32_t memberCount = static_cast<std::uint32_t>(watch.areaIndices.size());
        HashBytes(hash, &memberCount, sizeof(memberCount));
        for (std::uint32_t index : watch.areaIndices)
        {
            std::uint32_t navId = metadata.navIds[index];
            HashBytes(hash, &navId, sizeof(navId));
        }

        CBaseEntity *entity = watch.entityReference >= 0
            ? gamehelpers->ReferenceToEntity(watch.entityReference) : nullptr;
        bool resolved = entity && watch.originOffset >= 0 &&
            reinterpret_cast<std::uintptr_t>(entity) == watch.pointer;
        sample.entitiesResolved = sample.entitiesResolved && resolved;
        HashBytes(hash, &resolved, sizeof(resolved));
        if (!resolved)
            continue;

        Vector origin(
            ReadField<float>(entity, watch.originOffset),
            ReadField<float>(entity, watch.originOffset + 4),
            ReadField<float>(entity, watch.originOffset + 8));
        std::int32_t quantizedOrigin[3] = {
            static_cast<std::int32_t>(std::lround(origin.x)),
            static_cast<std::int32_t>(std::lround(origin.y)),
            static_cast<std::int32_t>(std::lround(origin.z)),
        };
        HashBytes(hash, quantizedOrigin, sizeof(quantizedOrigin));
        if (watch.velocityOffset >= 0)
        {
            Vector velocity(
                ReadField<float>(entity, watch.velocityOffset),
                ReadField<float>(entity, watch.velocityOffset + 4),
                ReadField<float>(entity, watch.velocityOffset + 8));
            bool moving = velocity.LengthSqr() > 1.0f;
            sample.moving = sample.moving || moving;
            HashBytes(hash, &moving, sizeof(moving));
        }
        if (watch.toggleStateOffset >= 0)
        {
            int toggleState = ReadField<int>(entity, watch.toggleStateOffset);
            HashBytes(hash, &toggleState, sizeof(toggleState));
        }
    }
    sample.entityFingerprint = hash;
}

DynamicNavStateSample ComputeDynamicNavState(
    const AnneNavGraphMetadata &metadata,
    const std::vector<DynamicElevatorWatch> &watches,
    const std::unordered_map<std::uintptr_t, std::uint32_t> &pointerToIndex)
{
    DynamicNavStateSample sample;
    sample.fingerprint = 1469598103934665603ull;
    if (!g_TheNavAreas)
    {
        sample.areaListValid = false;
        return sample;
    }

    void *areaList = ReadField<void *>(g_TheNavAreas, 0);
    int areaCount = ReadField<int>(g_TheNavAreas, g_NavAreasCountOffset);
    sample.areaListValid = areaList && areaCount > 0 &&
        static_cast<std::size_t>(areaCount) == metadata.areaPointers.size() &&
        reinterpret_cast<std::uintptr_t>(areaList) == metadata.navAreasListPointer;
    sample.areaCount = areaCount > 0 ? static_cast<std::uint32_t>(areaCount) : 0;
    HashBytes(sample.fingerprint, &areaCount, sizeof(areaCount));
    if (!sample.areaListValid)
    {
        std::uintptr_t listPointer = reinterpret_cast<std::uintptr_t>(areaList);
        HashBytes(sample.fingerprint, &listPointer, sizeof(listPointer));
        return sample;
    }

    sample.areaFingerprints.resize(static_cast<std::size_t>(areaCount));
    for (int row = 0; row < areaCount; ++row)
    {
        void *area = ReadField<void *>(
            areaList, row * static_cast<int>(sizeof(void *)));
        if (reinterpret_cast<std::uintptr_t>(area) != metadata.areaPointers[row])
        {
            sample.areaListValid = false;
            HashBytes(sample.fingerprint, &row, sizeof(row));
            return sample;
        }
        std::uint64_t areaFingerprint = HashLiveAreaTopology(
            sample, area, static_cast<std::uint32_t>(row), metadata,
            watches, pointerToIndex);
        sample.areaFingerprints[row] = areaFingerprint;
        HashBytes(sample.fingerprint, &areaFingerprint, sizeof(areaFingerprint));
    }
    HashDynamicEntities(sample, metadata, watches);
    HashBytes(sample.fingerprint, &sample.entityFingerprint,
              sizeof(sample.entityFingerprint));
    return sample;
}

const char *UnknownConnectionKindName(NavUnknownConnectionKind kind)
{
    switch (kind)
    {
        case NavUnknownConnectionKind::Floor: return "floor";
        case NavUnknownConnectionKind::LadderTopForward: return "ladder_top_forward";
        case NavUnknownConnectionKind::LadderTopLeft: return "ladder_top_left";
        case NavUnknownConnectionKind::LadderTopRight: return "ladder_top_right";
        case NavUnknownConnectionKind::LadderBottom: return "ladder_bottom";
    }
    return "unknown";
}

void RecordUnknownArea(NavGraphCapture &capture, std::uint32_t from,
                       void *target, NavUnknownConnectionKind kind,
                       int direction, int slot)
{
    ++capture.unknownAreaCount;
    if (capture.unknownAreaSamples.size() >= kUnknownAreaSampleCap)
        return;

    NavUnknownAreaSample sample;
    sample.sourceIndex = from;
    if (from < capture.metadata->navIds.size())
        sample.sourceNavId = capture.metadata->navIds[from];
    sample.targetPointer = reinterpret_cast<std::uintptr_t>(target);
    sample.kind = kind;
    sample.direction = direction;
    sample.slot = slot;
    capture.unknownAreaSamples.push_back(sample);
}

bool AppendTopologyEdge(NavGraphCapture &capture, std::uint32_t from,
                        void *target, AnneNavEdgeType type,
                        NavUnknownConnectionKind kind, int direction, int slot)
{
    if (!target)
        return true;
    auto found = capture.pointerToIndex.find(reinterpret_cast<std::uintptr_t>(target));
    if (found == capture.pointerToIndex.end())
    {
        capture.complete = false;
        capture.topologyIssues |= AnneNavTopologyIssue_UnknownArea;
        RecordUnknownArea(capture, from, target, kind, direction, slot);
        return false;
    }
    if (found->second != from)
        capture.edges.push_back({from, found->second, type});
    return true;
}

void CaptureConnectionStorage(NavGraphCapture &capture, std::uint32_t from,
                              void *storage, int stride, int maxCount,
                              AnneNavEdgeType type, int direction)
{
    if (!storage)
        return;
    int count = ReadField<int>(storage, 0);
    if (count < 0 || count > maxCount)
    {
        capture.complete = false;
        capture.topologyIssues |= type == AnneNavEdgeType::Ladder
            ? AnneNavTopologyIssue_InvalidLadderStorage
            : AnneNavTopologyIssue_InvalidFloorStorage;
        return;
    }
    for (int i = 0; i < count; ++i)
    {
        void *target = ReadField<void *>(storage, 4 + i * stride);
        AppendTopologyEdge(capture, from, target, type,
                           NavUnknownConnectionKind::Floor, direction, i);
    }
}

void CaptureLadderStorage(NavGraphCapture &capture, std::uint32_t from,
                          void *storage, bool goingUp)
{
    if (!storage)
        return;
    int count = ReadField<int>(storage, 0);
    if (count < 0 || count > kMaxLadderConnections)
    {
        capture.complete = false;
        capture.topologyIssues |= AnneNavTopologyIssue_InvalidLadderStorage;
        return;
    }
    for (int i = 0; i < count; ++i)
    {
        void *ladder = ReadField<void *>(storage, 4 + i * static_cast<int>(sizeof(void *)));
        if (!ladder)
        {
            capture.complete = false;
            capture.topologyIssues |= AnneNavTopologyIssue_InvalidLadderStorage;
            continue;
        }
        if (goingUp)
        {
            AppendTopologyEdge(capture, from,
                               ReadField<void *>(ladder, g_LadderTopForwardOffset),
                               AnneNavEdgeType::Ladder,
                               NavUnknownConnectionKind::LadderTopForward, -1, i);
            AppendTopologyEdge(capture, from,
                               ReadField<void *>(ladder, g_LadderTopLeftOffset),
                               AnneNavEdgeType::Ladder,
                               NavUnknownConnectionKind::LadderTopLeft, -1, i);
            AppendTopologyEdge(capture, from,
                               ReadField<void *>(ladder, g_LadderTopRightOffset),
                               AnneNavEdgeType::Ladder,
                               NavUnknownConnectionKind::LadderTopRight, -1, i);
        }
        else
        {
            AppendTopologyEdge(capture, from,
                               ReadField<void *>(ladder, g_LadderBottomOffset),
                               AnneNavEdgeType::Ladder,
                               NavUnknownConnectionKind::LadderBottom, -1, i);
        }
    }
}

void CaptureAreaTopology(NavGraphCapture &capture, std::uint32_t index)
{
    void *area = reinterpret_cast<void *>(capture.metadata->areaPointers[index]);
    for (int direction = 0; direction < 4; ++direction)
    {
        CaptureConnectionStorage(
            capture, index,
            ReadField<void *>(area, g_NavAreaConnectionsOffset + direction * 4),
            8, kMaxFloorConnections, AnneNavEdgeType::Floor, direction);
    }
    CaptureLadderStorage(capture, index,
                         ReadField<void *>(area, g_NavAreaLaddersOffset), true);
    CaptureLadderStorage(capture, index,
                         ReadField<void *>(area, g_NavAreaLaddersOffset + 4), false);

    if ((ReadField<std::uint32_t>(area, g_NavAreaAttributesOffset)
            & kNavMeshElevator) != 0
        || ReadField<void *>(area, g_NavAreaElevatorOffset))
    {
        // Stable elevator states use their live directed floor connections. The
        // issue bit keeps monitoring/variant diagnostics active without making
        // an otherwise valid snapshot incomplete.
        capture.topologyIssues |= AnneNavTopologyIssue_DynamicElevator;
    }
}

void ClearReachabilityState()
{
    g_ReachabilityCache.clear();
    g_PendingReachability.clear();
    g_ReachabilityInFlight.clear();
    g_NavCandidateCache.clear();
    g_PendingNavCandidates.clear();
    g_NavCandidateInFlight.clear();
    g_BlockedSnapshot.clear();
    g_BlockedSnapshotTime = -1000.0f;
    g_BlockedSnapshotGeneration = 0;
    g_BlockedSnapshotIgnoreNavBlockers = false;
    g_BlockedSnapshotValid = false;
    g_BlockedSnapshotTeam = -1;
    g_BlockedSnapshotBlockedCount = 0;
    ++g_BlockedStateVersion;
}

void InstallDynamicNavMonitor(
    NavGraphCapture &capture,
    const DynamicNavStateSample &sample,
    bool dirty)
{
    g_DynamicNav.watching = true;
    g_DynamicNav.hasDynamicAreas = !capture.dynamicAreaIndices.empty();
    g_DynamicNav.dirty = dirty;
    g_DynamicNav.moving = sample.moving;
    g_DynamicNav.entitiesResolved = sample.entitiesResolved;
    g_DynamicNav.areaListValid = sample.areaListValid;
    g_DynamicNav.topologyReadable = sample.topologyReadable;
    g_DynamicNav.areaCount = sample.areaCount;
    g_DynamicNav.floorConnections = sample.floorConnections;
    g_DynamicNav.ladderConnections = sample.ladderConnections;
    g_DynamicNav.entityFingerprint = sample.entityFingerprint;
    g_DynamicNav.topologyPollCursor = 0;
    g_DynamicNav.areaFingerprints = sample.areaFingerprints;
    g_DynamicNav.rawFingerprint = sample.fingerprint;
    if (!dirty)
        g_DynamicNav.capturedFingerprint = sample.fingerprint;
    g_DynamicNav.lastChangeAt = SteadySeconds();
    g_DynamicNav.nextPollAt = g_DynamicNav.lastChangeAt +
        (dirty ? kDynamicNavWarmPollSeconds : kDynamicNavIdlePollSeconds);
    g_DynamicNav.dynamicAreaIndices = std::move(capture.dynamicAreaIndices);
    g_DynamicNav.elevators = std::move(capture.elevators);
    g_DynamicNav.pointerToIndex = std::move(capture.pointerToIndex);
}

void InvalidateDynamicNavGraph(const DynamicNavStateSample &sample, double now)
{
    {
        std::lock_guard<std::mutex> lock(g_GraphMutex);
        g_NavGraphGeneration.fetch_add(1);
        g_NavGraph.reset();
        g_PendingNavGraph.reset();
        g_NavCapture.reset();
        ClearReachabilityState();
        g_NavGraphCacheHit = false;
        g_NavGraphError = "directed Nav topology changed; waiting for a stable state";
        g_DynamicNav.dirty = true;
        g_DynamicNav.rawFingerprint = sample.fingerprint;
        g_DynamicNav.moving = sample.moving;
        g_DynamicNav.entitiesResolved = sample.entitiesResolved;
        g_DynamicNav.areaListValid = sample.areaListValid;
        g_DynamicNav.topologyReadable = sample.topologyReadable;
        g_DynamicNav.areaCount = sample.areaCount;
        g_DynamicNav.floorConnections = sample.floorConnections;
        g_DynamicNav.ladderConnections = sample.ladderConnections;
        g_DynamicNav.entityFingerprint = sample.entityFingerprint;
        g_DynamicNav.lastChangeAt = now;
        ++g_DynamicNav.epoch;
        ++g_DynamicNav.changes;
    }
    g_Workers.ClearPending();
    g_PathCache.clear();
    g_PathCacheEpoch = -1;
    g_NavGraphState.store(kNavGraphDynamicWait);
}

void StartDynamicNavRebuild(double now)
{
    std::shared_ptr<AnneNavGraphMetadata> previous;
    {
        std::lock_guard<std::mutex> lock(g_GraphMutex);
        previous = g_NavMetadata;
    }
    if (!previous)
        return;

    std::string error;
    std::shared_ptr<AnneNavGraphMetadata> metadata = CaptureNavMetadata(
        previous->mapName.c_str(), previous->baseCachePath.c_str(),
        previous->maxFlowDistance, error);
    if (!metadata)
    {
        std::lock_guard<std::mutex> lock(g_GraphMutex);
        g_NavGraphError = "dynamic Nav metadata recapture failed: " + error;
        g_DynamicNav.lastChangeAt = now;
        return;
    }

    {
        std::lock_guard<std::mutex> lock(g_GraphMutex);
        g_NavMetadata = std::move(metadata);
        g_NavGraphForceRebuild = false;
        g_NavUnknownAreaCount = 0;
        g_NavUnknownAreaSamples.clear();
        ++g_DynamicNav.rebuilds;
    }
    g_NavGraphState.store(kNavGraphNeedBuild);
}

void PollDynamicNavState(bool warm)
{
    int state = g_NavGraphState.load();
    if (!g_DynamicNav.watching ||
        (state != kNavGraphReady && state != kNavGraphReadyPending &&
         state != kNavGraphDynamicWait))
    {
        return;
    }

    double now = SteadySeconds();
    if (now < g_DynamicNav.nextPollAt)
        return;
    double interval = g_DynamicNav.dirty || warm
        ? kDynamicNavWarmPollSeconds : kDynamicNavIdlePollSeconds;
    g_DynamicNav.nextPollAt = now + interval;

    std::shared_ptr<AnneNavGraphMetadata> metadata;
    {
        std::lock_guard<std::mutex> lock(g_GraphMutex);
        metadata = g_NavMetadata;
    }
    if (!metadata)
        return;

    double pollStart = SteadySeconds();
    DynamicNavStateSample sample;
    sample.fingerprint = g_DynamicNav.rawFingerprint;
    sample.areaCount = g_DynamicNav.areaCount;
    sample.floorConnections = g_DynamicNav.floorConnections;
    sample.ladderConnections = g_DynamicNav.ladderConnections;
    sample.topologyReadable = g_DynamicNav.topologyReadable;
    HashDynamicEntities(sample, *metadata, g_DynamicNav.elevators);

    void *areaList = g_TheNavAreas ? ReadField<void *>(g_TheNavAreas, 0) : nullptr;
    int areaCount = g_TheNavAreas
        ? ReadField<int>(g_TheNavAreas, g_NavAreasCountOffset) : 0;
    bool areaListShapeValid = areaList && areaCount > 0 &&
        static_cast<std::size_t>(areaCount) == metadata->areaPointers.size() &&
        static_cast<std::size_t>(areaCount) == g_DynamicNav.areaFingerprints.size() &&
        reinterpret_cast<std::uintptr_t>(areaList) == metadata->navAreasListPointer;
    sample.areaListValid = g_DynamicNav.areaListValid && areaListShapeValid;

    bool topologyChanged = false;
    // Elevator transitions may rewrite live connection storage. The entity
    // state already keeps the graph invalid while moving; inspect edges only
    // after the mechanism stops so no transient engine pointer is dereferenced.
    if (sample.areaListValid && !sample.moving)
    {
        std::size_t count = static_cast<std::size_t>(areaCount);
        std::size_t batch = std::min(kTopologyPollBatchAreas, count);
        std::size_t cursor = g_DynamicNav.topologyPollCursor % count;
        for (std::size_t scanned = 0; scanned < batch; ++scanned)
        {
            std::size_t row = (cursor + scanned) % count;
            void *area = ReadField<void *>(
                areaList, static_cast<int>(row * sizeof(void *)));
            if (reinterpret_cast<std::uintptr_t>(area) != metadata->areaPointers[row])
            {
                sample.areaListValid = false;
                topologyChanged = true;
                break;
            }

            DynamicNavStateSample areaSample;
            std::uint64_t areaFingerprint = HashLiveAreaTopology(
                areaSample, area, static_cast<std::uint32_t>(row), *metadata,
                g_DynamicNav.elevators, g_DynamicNav.pointerToIndex);
            if (!areaSample.topologyReadable)
                sample.topologyReadable = false;
            if (areaFingerprint == g_DynamicNav.areaFingerprints[row])
                continue;

            g_DynamicNav.areaFingerprints[row] = areaFingerprint;
            HashBytes(sample.fingerprint, &row, sizeof(row));
            HashBytes(sample.fingerprint, &areaFingerprint, sizeof(areaFingerprint));
            topologyChanged = true;
        }
        g_DynamicNav.topologyPollCursor = (cursor + batch) % count;
    }
    else if (g_DynamicNav.areaListValid && !areaListShapeValid)
    {
        sample.fingerprint = 1469598103934665603ull;
        topologyChanged = true;
        std::uintptr_t listPointer = reinterpret_cast<std::uintptr_t>(areaList);
        HashBytes(sample.fingerprint, &listPointer, sizeof(listPointer));
        HashBytes(sample.fingerprint, &areaCount, sizeof(areaCount));
    }

    bool entityChanged = sample.entityFingerprint != g_DynamicNav.entityFingerprint;
    if (entityChanged)
        HashBytes(sample.fingerprint, &sample.entityFingerprint,
                  sizeof(sample.entityFingerprint));
    float pollMs = static_cast<float>((SteadySeconds() - pollStart) * 1000.0);
    g_DynamicNav.pollLastMs = pollMs;
    g_DynamicNav.pollMaxMs = std::max(g_DynamicNav.pollMaxMs, pollMs);
    ++g_DynamicNav.pollSamples;
    g_DynamicNav.areaCount = sample.areaCount;
    g_DynamicNav.floorConnections = sample.floorConnections;
    g_DynamicNav.ladderConnections = sample.ladderConnections;

    bool changed = topologyChanged || entityChanged ||
        sample.fingerprint != g_DynamicNav.rawFingerprint ||
        sample.moving != g_DynamicNav.moving ||
        sample.entitiesResolved != g_DynamicNav.entitiesResolved ||
        sample.areaListValid != g_DynamicNav.areaListValid ||
        sample.topologyReadable != g_DynamicNav.topologyReadable;
    if (changed)
    {
        g_DynamicNav.rawFingerprint = sample.fingerprint;
        g_DynamicNav.moving = sample.moving;
        g_DynamicNav.entitiesResolved = sample.entitiesResolved;
        g_DynamicNav.areaListValid = sample.areaListValid;
        g_DynamicNav.topologyReadable = sample.topologyReadable;
        g_DynamicNav.entityFingerprint = sample.entityFingerprint;
        g_DynamicNav.lastChangeAt = now;
        if (!g_DynamicNav.dirty)
            InvalidateDynamicNavGraph(sample, now);
    }

    if (g_DynamicNav.dirty && !sample.moving &&
        now - g_DynamicNav.lastChangeAt >= kDynamicNavStableSeconds)
    {
        StartDynamicNavRebuild(now);
    }
}

void PublishPendingResults()
{
    std::lock_guard<std::mutex> lock(g_GraphMutex);
    if (g_PendingNavGraph)
    {
        g_NavGraph = std::move(g_PendingNavGraph);
        ClearReachabilityState();
        g_PathCache.clear();
        g_NavGraphState.store(kNavGraphReady);
    }
    for (std::shared_ptr<ReachabilityResult> &result : g_PendingReachability)
    {
        g_ReachabilityInFlight.erase(
            std::remove_if(g_ReachabilityInFlight.begin(), g_ReachabilityInFlight.end(),
                           [&result](const ReachabilityRequest &request) {
                               return request.serial == result->serial;
                           }),
            g_ReachabilityInFlight.end());
        g_ReachabilityCache.erase(
            std::remove_if(g_ReachabilityCache.begin(), g_ReachabilityCache.end(),
                           [&result](const std::shared_ptr<ReachabilityResult> &cached) {
                               return cached->targetId == result->targetId &&
                                      cached->team == result->team &&
                                      cached->ignoreNavBlockers == result->ignoreNavBlockers &&
                                      cached->blockedEpoch == result->blockedEpoch &&
                                      cached->maxDistance <= result->maxDistance;
                           }),
            g_ReachabilityCache.end());
        g_ReachabilityCache.push_back(std::move(result));
    }
    g_PendingReachability.clear();
    while (g_ReachabilityCache.size() > 8)
        g_ReachabilityCache.erase(g_ReachabilityCache.begin());

    for (std::shared_ptr<NavCandidateResult> &result : g_PendingNavCandidates)
    {
        g_NavCandidateInFlight.erase(
            std::remove_if(g_NavCandidateInFlight.begin(), g_NavCandidateInFlight.end(),
                           [&result](const NavCandidateRequest &request) {
                               return request.serial == result->serial;
                           }),
            g_NavCandidateInFlight.end());

        bool stale = result->generation != g_NavGraphGeneration.load() ||
                     result->survivorSpatialKey != g_SurvivorSpatialKey ||
                     result->blockedEpoch != g_BlockedStateVersion;
        if (stale)
        {
            ++g_NavCandidatePerf.staleDrops;
            continue;
        }

        g_NavCandidateCache.erase(
            std::remove_if(g_NavCandidateCache.begin(), g_NavCandidateCache.end(),
                           [&result](const std::shared_ptr<NavCandidateResult> &cached) {
                               return cached->targetClient == result->targetClient &&
                                      cached->targetId == result->targetId &&
                                      cached->survivorSpatialKey == result->survivorSpatialKey &&
                                      cached->blockedEpoch == result->blockedEpoch &&
                                      cached->minSurvivorDistance == result->minSurvivorDistance &&
                                      cached->maxPathDistance <= result->maxPathDistance;
                           }),
            g_NavCandidateCache.end());
        RecordCandidatePerfSample(
            g_NavCandidatePerf.buildMs, g_NavCandidatePerf.buildWrite,
            g_NavCandidatePerf.buildCount, result->buildMs);
        ++g_NavCandidatePerf.published;
        g_NavCandidatePerf.lastCandidateCount =
            static_cast<int>(result->areaIndices.size());
        g_NavCandidateCache.push_back(std::move(result));
    }
    g_PendingNavCandidates.clear();
    while (g_NavCandidateCache.size() > kCandidateCacheLimit)
        g_NavCandidateCache.erase(g_NavCandidateCache.begin());
}

void QueueGraphLoadOrBuild(std::shared_ptr<AnneNavGraphMetadata> metadata,
                           std::vector<AnneNavGraphInputEdge> edges,
                           bool complete, bool forceRebuild,
                           std::uint64_t generation)
{
    bool queued = g_Workers.Enqueue(
        [metadata = std::move(metadata), edges = std::move(edges), complete,
         forceRebuild, generation]() mutable {
            if (g_NavGraphGeneration.load() != generation)
                return;

            std::uint64_t fingerprint = AnneComputeNavTopologyFingerprint(
                metadata->fingerprint, edges, metadata->topologyIssues,
                metadata->dynamicStateFingerprint);
            const std::string &basePath = metadata->baseCachePath.empty()
                ? metadata->cachePath : metadata->baseCachePath;
            std::string cachePath = AnneNavGraphVariantCachePath(
                basePath, fingerprint);
            {
                std::lock_guard<std::mutex> lock(g_GraphMutex);
                if (g_NavGraphGeneration.load() != generation)
                    return;
                metadata->fingerprint = fingerprint;
                metadata->cachePath = std::move(cachePath);
            }
            std::string error;
            std::shared_ptr<AnneNavGraph> graph;
            bool cacheHit = false;
            if (!forceRebuild)
            {
                graph = AnneLoadNavGraph(*metadata, error);
                cacheHit = graph != nullptr;
            }
            if (!graph)
            {
                error.clear();
                graph = AnneBuildNavGraph(
                    *metadata, std::move(edges), complete, error);
            }
            if (!graph)
            {
                {
                    std::lock_guard<std::mutex> lock(g_GraphMutex);
                    if (g_NavGraphGeneration.load() != generation)
                        return;
                    g_NavGraphError = error;
                    g_NavGraphState.store(kNavGraphFailed);
                }
                return;
            }
            if (g_NavGraphGeneration.load() != generation)
                return;

            std::string saveError;
            std::string temporaryPath;
            bool staged = false;
            if (!cacheHit)
            {
                staged = AnneStageNavGraphCache(
                    *graph, metadata->cachePath, temporaryPath, saveError);
                if (g_NavGraphGeneration.load() != generation)
                {
                    AnneDiscardNavGraphCache(temporaryPath);
                    return;
                }
            }

            bool stale = false;
            {
                std::lock_guard<std::mutex> lock(g_GraphMutex);
                stale = g_NavGraphGeneration.load() != generation;
                if (!stale)
                {
                    if (!cacheHit && staged)
                        AnnePublishNavGraphCache(
                            temporaryPath, metadata->cachePath, saveError);
                    temporaryPath.clear();
                }
                if (!stale)
                {
                    g_PendingNavGraph = std::move(graph);
                    g_NavGraphCacheHit = cacheHit;
                    if (cacheHit && metadata->dynamicStateFingerprint != 0)
                        ++g_DynamicNav.cacheLoads;
                    g_NavGraphError = cacheHit ? std::string() : saveError;
                    g_NavGraphState.store(kNavGraphReadyPending);
                }
            }
            if (stale)
                AnneDiscardNavGraphCache(temporaryPath);
        });
    if (!queued)
    {
        SetGraphError("Nav graph worker queue is full");
        g_NavGraphState.store(kNavGraphFailed);
    }
}

void PumpNavGraph(bool dynamicWarm = false)
{
    PollDynamicNavState(dynamicWarm);
    PublishPendingResults();
    int state = g_NavGraphState.load();
    if (state == kNavGraphNeedBuild)
    {
        std::shared_ptr<AnneNavGraphMetadata> metadata;
        {
            std::lock_guard<std::mutex> lock(g_GraphMutex);
            metadata = g_NavMetadata;
        }
        if (!metadata)
        {
            SetGraphError("Nav graph metadata disappeared before build");
            g_NavGraphState.store(kNavGraphFailed);
            return;
        }

        auto capture = std::make_unique<NavGraphCapture>();
        capture->metadata = metadata;
        capture->forceRebuild = g_NavGraphForceRebuild;
        capture->pointerToIndex.reserve(metadata->areaPointers.size() * 2);
        capture->edges.reserve(metadata->areaPointers.size() * 6);
        for (std::uint32_t i = 0; i < metadata->areaPointers.size(); ++i)
            capture->pointerToIndex.emplace(metadata->areaPointers[i], i);
        DiscoverDynamicNavState(*capture);
        capture->dynamicStateAtStart = ComputeDynamicNavState(
            *metadata, capture->elevators, capture->pointerToIndex);
        g_NavCapture = std::move(capture);
        g_NavGraphState.store(kNavGraphBuilding);
        state = kNavGraphBuilding;
    }

    if (state != kNavGraphBuilding || !g_NavCapture)
        return;

    std::size_t end = std::min(g_NavCapture->cursor + kNavSnapshotBatchAreas,
                               g_NavCapture->metadata->areaPointers.size());
    while (g_NavCapture->cursor < end)
    {
        CaptureAreaTopology(*g_NavCapture,
                            static_cast<std::uint32_t>(g_NavCapture->cursor));
        ++g_NavCapture->cursor;
    }
    if (g_NavCapture->cursor < g_NavCapture->metadata->areaPointers.size())
        return;

    DynamicNavStateSample dynamicStateAtEnd = ComputeDynamicNavState(
        *g_NavCapture->metadata, g_NavCapture->elevators,
        g_NavCapture->pointerToIndex);
    bool topologyUnstable =
        dynamicStateAtEnd.fingerprint !=
            g_NavCapture->dynamicStateAtStart.fingerprint ||
        dynamicStateAtEnd.moving || !dynamicStateAtEnd.areaListValid;
    if (topologyUnstable)
    {
        InstallDynamicNavMonitor(*g_NavCapture, dynamicStateAtEnd, true);
        g_NavGraphError = "directed Nav topology changed during capture; waiting for stability";
        g_NavCapture.reset();
        g_NavGraphState.store(kNavGraphDynamicWait);
        return;
    }

    std::uint64_t generation = g_NavGraphGeneration.load();
    std::shared_ptr<AnneNavGraphMetadata> metadata = g_NavCapture->metadata;
    std::vector<AnneNavGraphInputEdge> edges = std::move(g_NavCapture->edges);
    bool complete = g_NavCapture->complete;
    bool forceRebuild = g_NavCapture->forceRebuild;
    metadata->topologyIssues = g_NavCapture->topologyIssues;
    if (!g_NavCapture->dynamicAreaIndices.empty() &&
        !dynamicStateAtEnd.entitiesResolved)
    {
        // Entity resolution is an optional early movement signal. A complete
        // directed-edge capture remains protected by the all-area fingerprint.
        metadata->topologyIssues |= AnneNavTopologyIssue_UnresolvedDynamicElevator;
    }
    metadata->dynamicStateFingerprint = g_NavCapture->dynamicAreaIndices.empty()
        ? 0 : dynamicStateAtEnd.fingerprint;
    {
        std::lock_guard<std::mutex> lock(g_GraphMutex);
        if (g_NavGraphGeneration.load() == generation)
        {
            g_NavUnknownAreaCount = g_NavCapture->unknownAreaCount;
            g_NavUnknownAreaSamples = g_NavCapture->unknownAreaSamples;
        }
    }
    InstallDynamicNavMonitor(*g_NavCapture, dynamicStateAtEnd, false);
    g_NavCapture.reset();
    QueueGraphLoadOrBuild(
        std::move(metadata), std::move(edges), complete,
        forceRebuild, generation);
}

int PublicNavGraphState()
{
    int state = g_NavGraphState.load();
    if (state == kNavGraphNeedBuild)
        return kNavGraphBuilding;
    if (state == kNavGraphReadyPending)
        return kNavGraphLoading;
    if (state == kNavGraphDynamicWait)
        return kNavGraphBuilding;
    return state;
}

int CurrentBlockedEpoch()
{
    return g_BlockedStateVersion;
}

bool RefreshBlockedSnapshot(const AnneNavGraph &graph,
                            const AnneNavGraphMetadata &metadata,
                            int team, bool ignoreNavBlockers)
{
    float now = gpGlobals ? gpGlobals->curtime : 0.0f;
    std::uint64_t generation = g_NavGraphGeneration.load();
    bool sameShape = g_BlockedSnapshotGeneration == generation
        && g_BlockedSnapshot.size() == graph.navIds.size()
        && g_BlockedSnapshotTeam == team
        && g_BlockedSnapshotIgnoreNavBlockers == ignoreNavBlockers;
    if (sameShape && now - g_BlockedSnapshotTime < kBlockerSnapshotSeconds)
        return g_BlockedSnapshotValid;

    std::vector<std::uint8_t> next(graph.navIds.size(), 0);
    std::size_t blockedCount = 0;
    for (std::size_t i = 0; i < next.size(); ++i)
    {
        void *area = reinterpret_cast<void *>(metadata.areaPointers[i]);
        std::uint8_t blockedBits = ReadField<std::uint8_t>(
            area, g_NavAreaBlockedBitsOffset);
        bool isBlocked = AnneNavBlockedForTeam(blockedBits, team);
        if (ignoreNavBlockers)
        {
            constexpr std::uint32_t navMeshNavBlocker = 0x80000000u;
            std::uint32_t attributes =
                ReadField<std::uint32_t>(area, g_NavAreaAttributesOffset);
            if ((attributes & navMeshNavBlocker) != 0)
                isBlocked = false;
        }
        next[i] = isBlocked ? 1 : 0;
        if (isBlocked)
            ++blockedCount;
    }

    bool valid = next.size() < kBlockedSnapshotSanityMinAreas
        || blockedCount < next.size();
    if (!sameShape || next != g_BlockedSnapshot
        || valid != g_BlockedSnapshotValid)
    {
        g_BlockedSnapshot = std::move(next);
        g_BlockedSnapshotGeneration = generation;
        g_BlockedSnapshotTeam = team;
        g_BlockedSnapshotIgnoreNavBlockers = ignoreNavBlockers;
        g_BlockedSnapshotValid = valid;
        ++g_BlockedStateVersion;
        g_PathCache.clear();
        g_PathCacheEpoch = g_BlockedStateVersion;
    }
    g_BlockedSnapshotBlockedCount = blockedCount;
    g_BlockedSnapshotTime = now;
    return valid;
}

bool ReachabilityMatches(const ReachabilityResult &result, std::uint32_t targetId,
                         float maxDistance, int team, bool ignoreNavBlockers,
                         bool requireCurrentEpoch)
{
    return result.generation == g_NavGraphGeneration.load() &&
           result.targetId == targetId && result.maxDistance + 0.01f >= maxDistance &&
           result.team == team && result.ignoreNavBlockers == ignoreNavBlockers &&
           (!requireCurrentEpoch || result.blockedEpoch == CurrentBlockedEpoch());
}

std::shared_ptr<ReachabilityResult> FindReachabilityLocked(
    std::uint32_t targetId, float maxDistance, int team,
    bool ignoreNavBlockers, bool requireCurrentEpoch)
{
    for (auto iterator = g_ReachabilityCache.rbegin();
         iterator != g_ReachabilityCache.rend(); ++iterator)
    {
        if (ReachabilityMatches(**iterator, targetId, maxDistance, team,
                                ignoreNavBlockers, requireCurrentEpoch))
            return *iterator;
    }
    return nullptr;
}

bool PrepareReachability(std::uint32_t targetId, float maxDistance,
                         int team, bool ignoreNavBlockers)
{
    PumpNavGraph();
    if (g_NavGraphState.load() != kNavGraphReady || maxDistance <= 0.0f ||
        team != kTeamInfected)
        return false;

    std::shared_ptr<AnneNavGraph> graph;
    std::shared_ptr<AnneNavGraphMetadata> metadata;
    {
        std::lock_guard<std::mutex> lock(g_GraphMutex);
        graph = g_NavGraph;
        metadata = g_NavMetadata;
    }
    if (!graph || !metadata || metadata->areaPointers.size() != graph->navIds.size())
        return false;

    if (!RefreshBlockedSnapshot(*graph, *metadata, team, ignoreNavBlockers))
        return false;
    int epoch = CurrentBlockedEpoch();
    {
        std::lock_guard<std::mutex> lock(g_GraphMutex);
        if (FindReachabilityLocked(targetId, maxDistance, team,
                                   ignoreNavBlockers, true))
            return true;
        for (const ReachabilityRequest &request : g_ReachabilityInFlight)
        {
            if (request.targetId == targetId &&
                request.maxDistance + 0.01f >= maxDistance &&
                request.team == team &&
                request.ignoreNavBlockers == ignoreNavBlockers &&
                request.blockedEpoch == epoch)
                return false;
        }
    }

    std::uint32_t targetIndex;
    if (!graph->FindIndex(targetId, targetIndex))
        return false;

    std::vector<std::uint8_t> blocked = g_BlockedSnapshot;

    std::uint64_t generation = g_NavGraphGeneration.load();
    std::uint64_t serial = g_ReachabilitySerial.fetch_add(1) + 1;
    {
        std::lock_guard<std::mutex> lock(g_GraphMutex);
        g_ReachabilityInFlight.push_back(
            {serial, targetId, maxDistance, team, ignoreNavBlockers, epoch});
    }

    bool queued = g_Workers.Enqueue(
        [graph = std::move(graph), blocked = std::move(blocked), targetIndex,
         targetId, maxDistance, team, ignoreNavBlockers, epoch, generation, serial]() mutable {
            if (g_NavGraphGeneration.load() != generation)
                return;

            auto result = std::make_shared<ReachabilityResult>();
            result->generation = generation;
            result->serial = serial;
            result->targetId = targetId;
            result->maxDistance = maxDistance;
            result->team = team;
            result->ignoreNavBlockers = ignoreNavBlockers;
            result->blockedEpoch = epoch;
            if (!graph->BuildReverseReachability(targetIndex, maxDistance, blocked,
                                                  result->distances,
                                                  result->usesSpecialEdge))
                return;

            result->reachable.reserve(graph->navIds.size());
            for (std::uint32_t i = 0; i < result->distances.size(); ++i)
            {
                if (std::isfinite(result->distances[i]))
                    result->reachable.push_back(i);
            }
            std::sort(result->reachable.begin(), result->reachable.end(),
                      [&result](std::uint32_t left, std::uint32_t right) {
                          if (result->distances[left] != result->distances[right])
                              return result->distances[left] < result->distances[right];
                          return left < right;
                      });

            if (g_NavGraphGeneration.load() != generation)
                return;
            std::lock_guard<std::mutex> lock(g_GraphMutex);
            if (g_NavGraphGeneration.load() != generation)
                return;
            g_PendingReachability.push_back(std::move(result));
        });
    if (!queued)
    {
        std::lock_guard<std::mutex> lock(g_GraphMutex);
        g_ReachabilityInFlight.erase(
            std::remove_if(g_ReachabilityInFlight.begin(), g_ReachabilityInFlight.end(),
                           [serial](const ReachabilityRequest &request) {
                               return request.serial == serial;
                           }),
            g_ReachabilityInFlight.end());
        return false;
    }
    return false;
}

int PrepareNavCandidates(int targetClient, std::uint32_t targetId,
                         float maxPathDistance, float minSurvivorDistance,
                         float maxSnapshotAge)
{
    PumpNavGraph();
    if (g_NavGraphState.load() != kNavGraphReady || maxPathDistance <= 0.0f ||
        minSurvivorDistance < 0.0f || maxSnapshotAge < 0.0f)
    {
        return kCandidateUnavailable;
    }

    std::shared_ptr<AnneNavGraph> graph;
    std::shared_ptr<AnneNavGraphMetadata> metadata;
    {
        std::lock_guard<std::mutex> lock(g_GraphMutex);
        graph = g_NavGraph;
        metadata = g_NavMetadata;
    }
    if (!graph || !graph->complete || !metadata ||
        metadata->areaPointers.size() != graph->navIds.size())
    {
        return kCandidateUnavailable;
    }

    std::uint32_t targetIndex;
    if (!graph->FindIndex(targetId, targetIndex))
        return kCandidateUnavailable;

    if (!RefreshBlockedSnapshot(*graph, *metadata, kTeamInfected, false))
        return kCandidateUnavailable;
    int blockedEpoch = CurrentBlockedEpoch();
    std::uint64_t survivorSpatialKey = g_SurvivorSpatialKey;
    std::size_t targetSlot = g_SurvivorCount;
    std::vector<float> survivorEyes;
    survivorEyes.reserve(g_SurvivorCount * 3);
    for (std::size_t i = 0; i < g_SurvivorCount; ++i)
    {
        if (g_Survivors[i].client == targetClient)
            targetSlot = i;
        survivorEyes.push_back(g_Survivors[i].eyes.x);
        survivorEyes.push_back(g_Survivors[i].eyes.y);
        survivorEyes.push_back(g_Survivors[i].eyes.z);
    }
    if (targetSlot >= g_SurvivorCount)
        return kCandidatePending;

    double now = SteadySeconds();
    {
        std::lock_guard<std::mutex> lock(g_GraphMutex);
        std::shared_ptr<NavCandidateResult> cached = FindNavCandidateLocked(
            targetClient, targetId, maxPathDistance, minSurvivorDistance,
            survivorSpatialKey, blockedEpoch);
        if (cached && now - cached->completedAt <= maxSnapshotAge)
        {
            ++g_NavCandidatePerf.cacheHits;
            return 1;
        }
        for (const NavCandidateRequest &request : g_NavCandidateInFlight)
        {
            if (NavCandidateRequestMatches(
                    request, targetClient, targetId, maxPathDistance,
                    minSurvivorDistance, survivorSpatialKey, blockedEpoch))
            {
                ++g_NavCandidatePerf.coalesced;
                return 0;
            }
        }
    }

    std::vector<std::uint8_t> blocked = g_BlockedSnapshot;
    std::uint64_t generation = g_NavGraphGeneration.load();
    std::uint64_t serial = g_NavCandidateSerial.fetch_add(1) + 1;
    NavCandidateRequest request{
        serial, generation, survivorSpatialKey, targetClient, targetId,
        maxPathDistance, minSurvivorDistance, blockedEpoch};
    {
        std::lock_guard<std::mutex> lock(g_GraphMutex);
        g_NavCandidateInFlight.push_back(request);
    }

    bool queued = g_Workers.Enqueue(
        [graph = std::move(graph), blocked = std::move(blocked), targetIndex,
         survivorEyes = std::move(survivorEyes), request]() mutable {
            double buildStart = SteadySeconds();
            auto result = std::make_shared<NavCandidateResult>();
            result->generation = request.generation;
            result->serial = request.serial;
            result->survivorSpatialKey = request.survivorSpatialKey;
            result->targetClient = request.targetClient;
            result->targetId = request.targetId;
            result->maxPathDistance = request.maxPathDistance;
            result->minSurvivorDistance = request.minSurvivorDistance;
            result->blockedEpoch = request.blockedEpoch;

            std::vector<float> allPathDistances;
            std::vector<std::uint8_t> specialEdges;
            bool built = AnneBuildNavCandidateSnapshot(
                *graph, targetIndex, request.maxPathDistance,
                blocked, survivorEyes, request.minSurvivorDistance,
                result->areaIndices,
                result->pathDistances, allPathDistances, specialEdges);
            if (!built)
            {
                result->areaIndices.clear();
                result->pathDistances.clear();
            }

            result->completedAt = SteadySeconds();
            result->buildMs = static_cast<float>(
                (result->completedAt - buildStart) * 1000.0);

            std::lock_guard<std::mutex> lock(g_GraphMutex);
            g_PendingNavCandidates.push_back(std::move(result));
        });
    if (!queued)
    {
        std::lock_guard<std::mutex> lock(g_GraphMutex);
        g_NavCandidateInFlight.erase(
            std::remove_if(g_NavCandidateInFlight.begin(), g_NavCandidateInFlight.end(),
                           [serial](const NavCandidateRequest &pending) {
                               return pending.serial == serial;
                           }),
            g_NavCandidateInFlight.end());
        return kCandidatePending;
    }
    {
        std::lock_guard<std::mutex> lock(g_GraphMutex);
        ++g_NavCandidatePerf.queued;
    }
    return 0;
}

int GetEntityIndex(CBaseEntity *entity)
{
    if (!entity)
        return -1;
    return gamehelpers->ReferenceToIndex(gamehelpers->EntityToBCompatRef(entity));
}

class SpawnTraceFilter final : public CTraceFilter
{
public:
    enum class Mode
    {
        Visibility,
        Stuck,
    };

    explicit SpawnTraceFilter(Mode mode) : mode_(mode) {}

    bool ShouldHitEntity(IHandleEntity *handle, int) override
    {
        if (!handle)
            return true;

        // Static-prop trace handles are not CBaseEntity objects. Both safety modes
        // must treat them as solid without dereferencing them as game entities.
        if (g_StaticPropMgr && g_StaticPropMgr->IsStaticProp(handle))
            return true;

        IServerUnknown *unknown = static_cast<IServerUnknown *>(handle);
        CBaseEntity *entity = unknown->GetBaseEntity();
        if (!entity)
            return true;

        int index = GetEntityIndex(entity);
        if (index <= 0 || !gpGlobals || index >= gpGlobals->maxEntities)
            return false;
        if (index <= gpGlobals->maxClients)
            return false;

        const char *classname = gamehelpers->GetEntityClassname(entity);
        if (!classname)
            return false;

        if (mode_ == Mode::Visibility)
            return std::strcmp(classname, "infected") != 0 && std::strcmp(classname, "witch") != 0;

        if (std::strcmp(classname, "env_physics_blocker") != 0)
            return true;

        if (g_BlockTypeOffset < 0)
        {
            sm_datatable_info_t info;
            datamap_t *map = gamehelpers->GetDataMap(entity);
            if (map && gamehelpers->FindDataMapInfo(map, "m_nBlockType", &info))
                g_BlockTypeOffset = info.actual_offset;
        }

        if (g_BlockTypeOffset < 0)
            return true;

        int blockType = ReadField<int>(entity, g_BlockTypeOffset);
        return blockType != 1 && blockType != 2;
    }

private:
    Mode mode_;
};

SpawnTraceFilter g_VisibilityFilter(SpawnTraceFilter::Mode::Visibility);
SpawnTraceFilter g_StuckFilter(SpawnTraceFilter::Mode::Stuck);

bool RayClear(const Vector &start, const Vector &end, unsigned int mask)
{
    if (!g_EngineTrace)
        return false;

    Ray_t ray;
    trace_t trace;
    ray.Init(start, end);
    g_EngineTrace->TraceRay(ray, mask, &g_VisibilityFilter, &trace);
    return !trace.DidHit() || trace.fraction >= 0.99f;
}

bool IsPointStuck(const Vector &position)
{
    if (!g_EngineTrace)
        return true;

    static const Vector mins(-16.0f, -16.0f, 0.0f);
    static const Vector maxs(16.0f, 16.0f, 71.0f);
    Ray_t ray;
    trace_t trace;
    ray.Init(position, position, mins, maxs);
    g_EngineTrace->TraceRay(ray, MASK_PLAYERSOLID, &g_StuckFilter, &trace);
    return trace.DidHit();
}

bool IsPointVisible(const Vector &position, bool teleportMode, bool ignoreIncapSight, int rayMode)
{
    // Native safety is fail-closed. A missing engine interface or signature must
    // reject the point instead of calling through a stale pointer during unload.
    if (!g_EngineTrace || !g_IsVisibleToPlayer || !gamehelpers || !gpGlobals)
        return true;

    Vector head(position.x, position.y, position.z + 62.0f);
    Vector chest(position.x, position.y, position.z + 32.0f);
    constexpr unsigned int visibilityMask = MASK_VISIBLE & MASK_SHOT;

    for (std::size_t i = 0; i < g_SurvivorCount; ++i)
    {
        const SurvivorSnapshot &snapshot = g_Survivors[i];
        if (teleportMode && ignoreIncapSight && snapshot.incapacitated)
            continue;

        if (RayClear(snapshot.eyes, head, visibilityMask))
            return true;
        if (rayMode == 1 &&
            (RayClear(snapshot.eyesLeft, head, visibilityMask) ||
             RayClear(snapshot.eyesRight, head, visibilityMask)))
            return true;

        if (snapshot.client <= 0 || snapshot.client > gpGlobals->maxClients)
            continue;
        CBaseEntity *player = gamehelpers->ReferenceToEntity(snapshot.client);
        if (!player)
            continue;

        // IsVisibleToPlayer writes the resolved NavArea through this out parameter.
        // Passing nullptr here crashes on paths where the engine publishes it.
        void *visibleArea = nullptr;
        bool visibleFlag = true;
        if (g_IsVisibleToPlayer(chest, player, kTeamSurvivor, kTeamInfected, 0.0f,
                                nullptr, &visibleArea, &visibleFlag))
            return true;
    }
    return false;
}

void ComputeGeometry(const Vector &position, const Vector &center, int sectors,
                     const Vector &targetEye, float &minEyeDistanceSquared,
                     float &targetEyeDistance, int &sector)
{
    minEyeDistanceSquared = 1.0e20f;
    for (std::size_t i = 0; i < g_SurvivorCount; ++i)
    {
        const SurvivorSnapshot &snapshot = g_Survivors[i];
        Vector delta = position - snapshot.eyes;
        float distanceSquared = delta.LengthSqr();
        if (distanceSquared < minEyeDistanceSquared)
            minEyeDistanceSquared = distanceSquared;
    }

    targetEyeDistance = (position - targetEye).Length();
    sectors = std::max(1, sectors);
    constexpr float twoPi = 6.28318530717958647692f;
    float angle = std::atan2(position.y - center.y, position.x - center.x);
    if (angle < 0.0f)
        angle += twoPi;
    sector = static_cast<int>(std::floor(angle / (twoPi / static_cast<float>(sectors))));
    sector = std::clamp(sector, 0, sectors - 1);
}

std::uint64_t MakeCellKey(int x, int y)
{
    return (static_cast<std::uint64_t>(static_cast<std::uint32_t>(x)) << 32) |
           static_cast<std::uint32_t>(y);
}

cell_t Native_IsActive(IPluginContext *, const cell_t *)
{
    return 1;
}

cell_t Native_NavGraphStart(IPluginContext *context, const cell_t *params)
{
    if (params[0] != 4)
        return context->ThrowNativeError("AnneSpawn_NavGraphStart expects 4 parameters");

    char *mapName = nullptr;
    char *cachePath = nullptr;
    if (context->LocalToString(params[1], &mapName) != SP_ERROR_NONE || !mapName || !*mapName ||
        context->LocalToString(params[2], &cachePath) != SP_ERROR_NONE || !cachePath || !*cachePath)
        return context->ThrowNativeError("Invalid Nav graph map or cache path");
    float maxFlowDistance = sp_ctof(params[3]);
    if (!std::isfinite(maxFlowDistance) || maxFlowDistance <= 0.0f)
        return context->ThrowNativeError("Invalid Nav graph max flow distance");

    std::uint64_t generation;
    {
        std::lock_guard<std::mutex> lock(g_GraphMutex);
        generation = g_NavGraphGeneration.fetch_add(1) + 1;
        g_NavMetadata.reset();
        g_NavGraph.reset();
        g_PendingNavGraph.reset();
        g_NavCapture.reset();
        ClearReachabilityState();
        ResetNavCandidatePerfLocked();
        g_NavGraphError.clear();
        g_NavGraphForceRebuild = params[4] != 0;
        g_NavGraphCacheHit = false;
        g_NavUnknownAreaCount = 0;
        g_NavUnknownAreaSamples.clear();
        g_DynamicNav = DynamicNavMonitor{};
    }
    g_Workers.ClearPending();
    g_PathCache.clear();
    g_PathCacheEpoch = -1;
    g_NavGraphState.store(kNavGraphLoading);

    std::string error;
    std::shared_ptr<AnneNavGraphMetadata> metadata =
        CaptureNavMetadata(mapName, cachePath, maxFlowDistance, error);
    if (!metadata)
    {
        SetGraphError(error);
        g_NavGraphState.store(kNavGraphFailed);
        return 0;
    }
    {
        std::lock_guard<std::mutex> lock(g_GraphMutex);
        if (g_NavGraphGeneration.load() != generation)
            return 0;
        g_NavMetadata = metadata;
    }
    if (g_Workers.ThreadCount() == 0 &&
        !g_Workers.Start(kGraphWorkerCount, kGraphWorkerQueueLimit))
    {
        SetGraphError("Could not start Nav graph worker pool");
        g_NavGraphState.store(kNavGraphFailed);
        return 0;
    }

    // Cache validation needs every live directed floor/ladder edge. Pump first
    // captures that topology in bounded main-thread batches, then a worker hashes
    // it and either loads the matching v6 state cache or rebuilds it.
    g_NavGraphState.store(kNavGraphNeedBuild);
    return 1;
}

cell_t Native_NavGraphPump(IPluginContext *, const cell_t *params)
{
    bool dynamicWarm = params && params[0] >= 1 && params[1] != 0;
    PumpNavGraph(dynamicWarm);
    return PublicNavGraphState();
}

cell_t Native_NavGraphStop(IPluginContext *, const cell_t *)
{
    {
        std::lock_guard<std::mutex> lock(g_GraphMutex);
        g_NavGraphGeneration.fetch_add(1);
        g_NavMetadata.reset();
        g_NavGraph.reset();
        g_PendingNavGraph.reset();
        g_NavCapture.reset();
        ClearReachabilityState();
        g_NavGraphError.clear();
        g_NavGraphForceRebuild = false;
        g_NavGraphCacheHit = false;
        g_NavUnknownAreaCount = 0;
        g_NavUnknownAreaSamples.clear();
        g_DynamicNav = DynamicNavMonitor{};
    }
    g_Workers.Stop();
    g_PathCache.clear();
    g_PathCacheEpoch = -1;
    g_NavGraphState.store(kNavGraphIdle);
    return 0;
}

cell_t Native_NavGraphPrepareRange(IPluginContext *context, const cell_t *params)
{
    if (params[0] != 4)
        return context->ThrowNativeError("AnneSpawn_NavGraphPrepareRange expects 4 parameters");
    return PrepareReachability(static_cast<std::uint32_t>(params[1]), sp_ctof(params[2]),
                               params[3], params[4] != 0) ? 1 : 0;
}

cell_t Native_NavGraphCollectRange(IPluginContext *context, const cell_t *params)
{
    if (params[0] != 5)
        return context->ThrowNativeError("AnneSpawn_NavGraphCollectRange expects 5 parameters");

    float minDistance = std::max(0.0f, sp_ctof(params[2]));
    float maxDistance = sp_ctof(params[3]);
    int maxResults = params[5];
    if (maxDistance < minDistance || maxResults < 0 || maxResults > kMaxSpatialPoints)
        return context->ThrowNativeError("Invalid Nav graph range");

    PumpNavGraph();
    cell_t *output;
    if (maxResults > 0 && !GetCells(context, params[4], output))
        return context->ThrowNativeError("Invalid Nav graph range output array");

    std::shared_ptr<AnneNavGraph> graph;
    std::shared_ptr<ReachabilityResult> result;
    {
        std::lock_guard<std::mutex> lock(g_GraphMutex);
        graph = g_NavGraph;
        result = FindReachabilityLocked(
            static_cast<std::uint32_t>(params[1]), maxDistance,
            kTeamInfected, false, true);
    }
    if (!graph || !graph->complete || !result)
        return -1;

    int count = 0;
    for (std::uint32_t index : result->reachable)
    {
        float distance = result->distances[index];
        if (distance + 0.01f < minDistance)
            continue;
        if (distance > maxDistance + 0.01f)
            break;
        if (count >= maxResults)
            break;
        output[count++] = static_cast<cell_t>(index);
    }
    return count;
}

cell_t Native_NavCandidatesPrepare(IPluginContext *context, const cell_t *params)
{
    if (params[0] != 5)
        return context->ThrowNativeError("AnneSpawn_NavCandidatesPrepare expects 5 parameters");
    float maxPathDistance = sp_ctof(params[3]);
    float minSurvivorDistance = sp_ctof(params[4]);
    float maxSnapshotAge = sp_ctof(params[5]);
    if (!std::isfinite(maxPathDistance) || !std::isfinite(minSurvivorDistance) ||
        !std::isfinite(maxSnapshotAge))
    {
        return context->ThrowNativeError("Invalid Nav candidate prepare request");
    }
    return PrepareNavCandidates(
        params[1], static_cast<std::uint32_t>(params[2]), maxPathDistance,
        minSurvivorDistance, maxSnapshotAge);
}

cell_t Native_NavCandidatesCollect(IPluginContext *context, const cell_t *params)
{
    if (params[0] != 13)
        return context->ThrowNativeError("AnneSpawn_NavCandidatesCollect expects 13 parameters");

    int targetClient = params[1];
    std::uint32_t targetId = static_cast<std::uint32_t>(params[2]);
    float minNavDistance = std::max(0.0f, sp_ctof(params[3]));
    float maxNavDistance = sp_ctof(params[4]);
    float maxPathDistance = sp_ctof(params[5]);
    float minSurvivorDistance = sp_ctof(params[6]);
    float maxSnapshotAge = sp_ctof(params[7]);
    int startOffset = params[8];
    int maxResults = params[11];
    if (!std::isfinite(maxNavDistance) || !std::isfinite(maxPathDistance) ||
        !std::isfinite(minSurvivorDistance) || !std::isfinite(maxSnapshotAge) ||
        maxNavDistance < minNavDistance || maxPathDistance <= 0.0f ||
        minSurvivorDistance < 0.0f || maxSnapshotAge < 0.0f ||
        startOffset < 0 || maxResults < 0 || maxResults > kMaxSpatialPoints)
    {
        return context->ThrowNativeError("Invalid Nav candidate collect request");
    }

    cell_t *output = nullptr;
    cell_t *distanceOutput = nullptr;
    cell_t *ageOutput = nullptr;
    cell_t *totalOutput = nullptr;
    if ((maxResults > 0 && !GetCells(context, params[9], output)) ||
        (maxResults > 0 && !GetCells(context, params[10], distanceOutput)) ||
        !GetCells(context, params[12], ageOutput) ||
        !GetCells(context, params[13], totalOutput))
    {
        return context->ThrowNativeError("Invalid Nav candidate collect output");
    }
    ageOutput[0] = sp_ftoc(0.0f);
    totalOutput[0] = 0;

    PumpNavGraph();
    std::lock_guard<std::mutex> lock(g_GraphMutex);
    if (!g_NavGraph || !g_NavGraph->complete ||
        g_NavGraphState.load() != kNavGraphReady)
    {
        ++g_NavCandidatePerf.collectUnavailable;
        return kCandidateUnavailable;
    }

    std::shared_ptr<NavCandidateResult> result = FindNavCandidateLocked(
        targetClient, targetId, maxPathDistance, minSurvivorDistance,
        g_SurvivorSpatialKey, g_BlockedStateVersion);
    if (!result)
    {
        ++g_NavCandidatePerf.collectPending;
        return kCandidatePending;
    }

    float ageMs = static_cast<float>((SteadySeconds() - result->completedAt) * 1000.0);
    if (ageMs > maxSnapshotAge * 1000.0f + 0.01f)
    {
        ++g_NavCandidatePerf.collectPending;
        return kCandidatePending;
    }

    auto first = std::lower_bound(
        result->pathDistances.begin(), result->pathDistances.end(), minNavDistance);
    auto last = std::upper_bound(
        first, result->pathDistances.end(), maxNavDistance);
    std::size_t firstRow = static_cast<std::size_t>(
        std::distance(result->pathDistances.begin(), first));
    std::size_t total = static_cast<std::size_t>(std::distance(first, last));
    totalOutput[0] = static_cast<cell_t>(
        std::min<std::size_t>(total, static_cast<std::size_t>(std::numeric_limits<cell_t>::max())));
    g_NavCandidatePerf.lastRangeCandidateCount = totalOutput[0];
    ageOutput[0] = sp_ftoc(ageMs);

    std::size_t offset = static_cast<std::size_t>(startOffset);
    int count = 0;
    if (offset < total)
    {
        std::size_t available = total - offset;
        count = static_cast<int>(std::min<std::size_t>(
            available, static_cast<std::size_t>(maxResults)));
        for (int row = 0; row < count; ++row)
        {
            output[row] = static_cast<cell_t>(
                result->areaIndices[firstRow + offset + static_cast<std::size_t>(row)]);
            distanceOutput[row] = sp_ftoc(
                result->pathDistances[firstRow + offset + static_cast<std::size_t>(row)]);
        }
    }

    RecordCandidatePerfSample(
        g_NavCandidatePerf.resultAgeMs, g_NavCandidatePerf.ageWrite,
        g_NavCandidatePerf.ageCount, ageMs);
    ++g_NavCandidatePerf.collectHits;
    return count;
}

cell_t Native_NavCandidatesGetPerf(IPluginContext *context, const cell_t *params)
{
    if (params[0] != 4)
        return context->ThrowNativeError("AnneSpawn_NavCandidatesGetPerf expects 4 parameters");
    int timingCount = params[2];
    int counterCount = params[4];
    if (timingCount < 10 || counterCount < 13)
        return context->ThrowNativeError("Nav candidate perf output arrays are too small");

    cell_t *timings = nullptr;
    cell_t *counters = nullptr;
    if (!GetCells(context, params[1], timings) || !GetCells(context, params[3], counters))
        return context->ThrowNativeError("Invalid Nav candidate perf output arrays");

    std::lock_guard<std::mutex> lock(g_GraphMutex);
    auto lastSample = [](const auto &samples, std::size_t write, std::size_t count) {
        if (count == 0)
            return 0.0f;
        std::size_t index = (write + samples.size() - 1) % samples.size();
        return samples[index];
    };
    float values[10] = {
        lastSample(g_NavCandidatePerf.buildMs, g_NavCandidatePerf.buildWrite,
                   g_NavCandidatePerf.buildCount),
        CandidatePerfPercentile(g_NavCandidatePerf.buildMs,
                                g_NavCandidatePerf.buildCount, 0.50f),
        CandidatePerfPercentile(g_NavCandidatePerf.buildMs,
                                g_NavCandidatePerf.buildCount, 0.95f),
        CandidatePerfPercentile(g_NavCandidatePerf.buildMs,
                                g_NavCandidatePerf.buildCount, 0.99f),
        CandidatePerfPercentile(g_NavCandidatePerf.buildMs,
                                g_NavCandidatePerf.buildCount, 1.00f),
        lastSample(g_NavCandidatePerf.resultAgeMs, g_NavCandidatePerf.ageWrite,
                   g_NavCandidatePerf.ageCount),
        CandidatePerfPercentile(g_NavCandidatePerf.resultAgeMs,
                                g_NavCandidatePerf.ageCount, 0.50f),
        CandidatePerfPercentile(g_NavCandidatePerf.resultAgeMs,
                                g_NavCandidatePerf.ageCount, 0.95f),
        CandidatePerfPercentile(g_NavCandidatePerf.resultAgeMs,
                                g_NavCandidatePerf.ageCount, 0.99f),
        CandidatePerfPercentile(g_NavCandidatePerf.resultAgeMs,
                                g_NavCandidatePerf.ageCount, 1.00f),
    };
    for (int i = 0; i < 10; ++i)
        timings[i] = sp_ftoc(values[i]);

    auto toCell = [](std::uint64_t value) {
        return static_cast<cell_t>(std::min<std::uint64_t>(
            value, static_cast<std::uint64_t>(std::numeric_limits<cell_t>::max())));
    };
    counters[0] = static_cast<cell_t>(g_NavCandidatePerf.buildCount);
    counters[1] = toCell(g_NavCandidatePerf.queued);
    counters[2] = toCell(g_NavCandidatePerf.published);
    counters[3] = toCell(g_NavCandidatePerf.cacheHits);
    counters[4] = toCell(g_NavCandidatePerf.coalesced);
    counters[5] = toCell(g_NavCandidatePerf.staleDrops);
    counters[6] = toCell(g_NavCandidatePerf.collectHits);
    counters[7] = toCell(g_NavCandidatePerf.collectPending);
    counters[8] = toCell(g_NavCandidatePerf.collectUnavailable);
    counters[9] = g_NavCandidatePerf.lastCandidateCount;
    counters[10] = static_cast<cell_t>(g_NavCandidateInFlight.size());
    counters[11] = static_cast<cell_t>(g_NavCandidateCache.size());
    counters[12] = g_NavCandidatePerf.lastRangeCandidateCount;
    return 1;
}

cell_t Native_NavCandidatesResetPerf(IPluginContext *, const cell_t *params)
{
    if (params[0] != 0)
        return 0;
    std::lock_guard<std::mutex> lock(g_GraphMutex);
    ResetNavCandidatePerfLocked();
    return 0;
}

cell_t Native_NavGraphGetAreaCount(IPluginContext *, const cell_t *)
{
    std::lock_guard<std::mutex> lock(g_GraphMutex);
    return g_NavGraph ? static_cast<cell_t>(g_NavGraph->navIds.size()) : 0;
}

cell_t Native_NavGraphGetEdgeCount(IPluginContext *, const cell_t *)
{
    std::lock_guard<std::mutex> lock(g_GraphMutex);
    return g_NavGraph ? static_cast<cell_t>(g_NavGraph->edges.size()) : 0;
}

cell_t Native_NavGraphGetDiagnostics(IPluginContext *context, const cell_t *params)
{
    if (params[0] != 2 || params[2] <= 0)
        return context->ThrowNativeError(
            "AnneSpawn_NavGraphGetDiagnostics expects a non-empty output buffer");

    int flags = 0;
    std::string reason;
    {
        std::lock_guard<std::mutex> lock(g_GraphMutex);
        int state = PublicNavGraphState();
        const char *stateName = state == kNavGraphReady ? "ready" :
            state == kNavGraphFailed ? "failed" :
            state == kNavGraphBuilding ? "building" :
            state == kNavGraphLoading ? "loading" : "idle";
        reason = "state=";
        reason += stateName;
        reason += " source=";
        reason += g_NavGraphCacheHit ? "cache" : "build";
        if (g_NavMetadata && !g_NavMetadata->mapName.empty())
        {
            reason += " map=";
            reason += g_NavMetadata->mapName;
        }
        if (g_NavMetadata && g_NavMetadata->fingerprint != 0)
        {
            char fingerprintText[40];
            std::snprintf(
                fingerprintText, sizeof(fingerprintText),
                " variant=%016llx",
                static_cast<unsigned long long>(g_NavMetadata->fingerprint));
            reason += fingerprintText;
        }

        std::uint32_t issues = g_NavGraph
            ? g_NavGraph->topologyIssues
            : (g_NavMetadata ? g_NavMetadata->topologyIssues
                             : AnneNavTopologyIssue_None);
        if (g_NavGraph && g_NavGraph->complete)
        {
            flags |= kNavDiagComplete;
            reason += " topology=complete";
        }
        else
        {
            reason += " topology=incomplete";
        }
        if (g_NavGraphCacheHit)
            flags |= kNavDiagCacheHit;
        if (g_NavGraph
            && g_BlockedSnapshotGeneration == g_NavGraphGeneration.load()
            && g_BlockedSnapshot.size() == g_NavGraph->navIds.size())
        {
            char blockerText[128];
            std::snprintf(
                blockerText, sizeof(blockerText),
                " blockers=%llu/%llu blocker_team=%d blocker_valid=%d",
                static_cast<unsigned long long>(g_BlockedSnapshotBlockedCount),
                static_cast<unsigned long long>(g_BlockedSnapshot.size()),
                g_BlockedSnapshotTeam, g_BlockedSnapshotValid ? 1 : 0);
            reason += blockerText;
        }

        auto appendIssue = [&reason](const char *name) {
            reason += reason.find(" issues=") == std::string::npos ? " issues=" : ",";
            reason += name;
        };
        if ((issues & AnneNavTopologyIssue_UnknownArea) != 0)
        {
            flags |= kNavDiagUnknownArea;
            appendIssue("unknown_area");
            reason += " unknown_count=";
            reason += std::to_string(g_NavUnknownAreaCount);
            std::size_t sampleCount = std::min<std::size_t>(
                g_NavUnknownAreaSamples.size(), 3);
            for (std::size_t i = 0; i < sampleCount; ++i)
            {
                const NavUnknownAreaSample &sample = g_NavUnknownAreaSamples[i];
                char sampleText[192];
                std::snprintf(
                    sampleText, sizeof(sampleText),
                    " unknown[%llu]=%u@%u:%s:dir%d:slot%d->0x%llx",
                    static_cast<unsigned long long>(i), sample.sourceNavId,
                    sample.sourceIndex, UnknownConnectionKindName(sample.kind),
                    sample.direction, sample.slot,
                    static_cast<unsigned long long>(sample.targetPointer));
                reason += sampleText;
            }
        }
        if ((issues & AnneNavTopologyIssue_InvalidFloorStorage) != 0)
        {
            flags |= kNavDiagInvalidFloorStorage;
            appendIssue("invalid_floor_storage");
        }
        if ((issues & AnneNavTopologyIssue_InvalidLadderStorage) != 0)
        {
            flags |= kNavDiagInvalidLadderStorage;
            appendIssue("invalid_ladder_storage");
        }
        if ((issues & AnneNavTopologyIssue_DynamicElevator) != 0)
        {
            flags |= kNavDiagDynamicElevator;
            appendIssue("dynamic_elevator");
        }
        if ((issues & AnneNavTopologyIssue_UnresolvedDynamicElevator) != 0)
        {
            flags |= kNavDiagUnresolvedDynamicElevator;
            appendIssue("unresolved_dynamic_elevator");
        }
        if (g_DynamicNav.watching)
        {
            const char *dynamicState = g_DynamicNav.dirty
                ? (g_DynamicNav.moving ? "moving" : "stabilizing")
                : "stable";
            char dynamicText[768];
            std::snprintf(
                dynamicText, sizeof(dynamicText),
                " topology_watch=all_directed topology_areas=%u"
                " topology_floor_edges=%llu topology_ladder_edges=%llu"
                " topology_poll_batch=%llu topology_poll_cursor=%llu"
                " topology_readable=%d topology_captured_hash=%016llx"
                " dynamic_state=%s dynamic_areas=%llu dynamic_elevators=%llu"
                " dynamic_resolved=%d dynamic_list_valid=%d dynamic_epoch=%llu"
                " dynamic_changes=%llu dynamic_rebuilds=%llu dynamic_cache_loads=%llu"
                " dynamic_hash=%016llx dynamic_poll_ms=%.3f/%.3f dynamic_polls=%llu",
                g_DynamicNav.areaCount,
                static_cast<unsigned long long>(g_DynamicNav.floorConnections),
                static_cast<unsigned long long>(g_DynamicNav.ladderConnections),
                static_cast<unsigned long long>(kTopologyPollBatchAreas),
                static_cast<unsigned long long>(g_DynamicNav.topologyPollCursor),
                g_DynamicNav.topologyReadable ? 1 : 0,
                static_cast<unsigned long long>(g_DynamicNav.capturedFingerprint),
                dynamicState,
                static_cast<unsigned long long>(g_DynamicNav.dynamicAreaIndices.size()),
                static_cast<unsigned long long>(g_DynamicNav.elevators.size()),
                g_DynamicNav.entitiesResolved ? 1 : 0,
                g_DynamicNav.areaListValid ? 1 : 0,
                static_cast<unsigned long long>(g_DynamicNav.epoch),
                static_cast<unsigned long long>(g_DynamicNav.changes),
                static_cast<unsigned long long>(g_DynamicNav.rebuilds),
                static_cast<unsigned long long>(g_DynamicNav.cacheLoads),
                static_cast<unsigned long long>(g_DynamicNav.rawFingerprint),
                g_DynamicNav.pollLastMs, g_DynamicNav.pollMaxMs,
                static_cast<unsigned long long>(g_DynamicNav.pollSamples));
            reason += dynamicText;
        }
        if (!g_NavGraphError.empty())
        {
            reason += " note=";
            reason += g_NavGraphError;
        }
    }
    context->StringToLocal(params[1], params[2], reason.c_str());
    return flags;
}

cell_t Native_NavGraphCollectProgress(IPluginContext *context, const cell_t *params)
{
    if (params[0] != 4)
        return context->ThrowNativeError(
            "AnneSpawn_NavGraphCollectProgress expects 4 parameters");

    int maxResults = params[2];
    bool mapInvalid = params[3] != 0;
    float maxResolveDistance = sp_ctof(params[4]);
    if (maxResults < 0 || maxResults > kMaxSpatialPoints ||
        !std::isfinite(maxResolveDistance) || maxResolveDistance < 0.0f)
        return context->ThrowNativeError("Invalid Nav graph progress request");

    cell_t *output = nullptr;
    if (maxResults > 0 && !GetCells(context, params[1], output))
        return context->ThrowNativeError("Invalid Nav graph progress output array");

    std::lock_guard<std::mutex> lock(g_GraphMutex);
    if (!g_NavGraph || g_NavGraphState.load() != kNavGraphReady)
        return -1;

    int count = std::min(maxResults, static_cast<int>(g_NavGraph->navIds.size()));
    for (int i = 0; i < count; ++i)
    {
        float flow = g_NavGraph->flowDistances[i];
        bool valid = std::isfinite(flow) && flow >= 0.0f &&
                     flow <= g_NavGraph->maxFlowDistance;
        if (!valid && mapInvalid &&
            std::isfinite(g_NavGraph->flowResolveDistances[i]) &&
            (maxResolveDistance <= 0.0f ||
             g_NavGraph->flowResolveDistances[i] <= maxResolveDistance))
        {
            flow = g_NavGraph->resolvedFlowDistances[i];
            valid = std::isfinite(flow) && flow >= 0.0f &&
                    flow <= g_NavGraph->maxFlowDistance;
        }
        output[i] = sp_ftoc(valid ? flow : -1.0f);
    }
    return count;
}

cell_t Native_NavGraphCollectProgressPage(IPluginContext *context, const cell_t *params)
{
    if (params[0] != 5)
        return context->ThrowNativeError(
            "AnneSpawn_NavGraphCollectProgressPage expects 5 parameters");

    int maxResults = params[2];
    int offset = params[3];
    bool mapInvalid = params[4] != 0;
    float maxResolveDistance = sp_ctof(params[5]);
    if (maxResults < 0 || maxResults > kMaxSpatialPoints || offset < 0 ||
        !std::isfinite(maxResolveDistance) || maxResolveDistance < 0.0f)
        return context->ThrowNativeError("Invalid paged Nav graph progress request");

    cell_t *output = nullptr;
    if (maxResults > 0 && !GetCells(context, params[1], output))
        return context->ThrowNativeError(
            "Invalid paged Nav graph progress output array");

    std::lock_guard<std::mutex> lock(g_GraphMutex);
    if (!g_NavGraph || g_NavGraphState.load() != kNavGraphReady)
        return -1;

    int areaCount = static_cast<int>(g_NavGraph->navIds.size());
    if (offset >= areaCount)
        return 0;
    int count = std::min(maxResults, areaCount - offset);
    for (int i = 0; i < count; ++i)
    {
        int areaIndex = offset + i;
        float flow = g_NavGraph->flowDistances[areaIndex];
        bool valid = std::isfinite(flow) && flow >= 0.0f &&
                     flow <= g_NavGraph->maxFlowDistance;
        if (!valid && mapInvalid &&
            std::isfinite(g_NavGraph->flowResolveDistances[areaIndex]) &&
            (maxResolveDistance <= 0.0f ||
             g_NavGraph->flowResolveDistances[areaIndex] <= maxResolveDistance))
        {
            flow = g_NavGraph->resolvedFlowDistances[areaIndex];
            valid = std::isfinite(flow) && flow >= 0.0f &&
                    flow <= g_NavGraph->maxFlowDistance;
        }
        output[i] = sp_ftoc(valid ? flow : -1.0f);
    }
    return count;
}

cell_t Native_GetWorkerCount(IPluginContext *, const cell_t *)
{
    return static_cast<cell_t>(g_Workers.ThreadCount());
}

cell_t Native_SetSurvivorSnapshot(IPluginContext *context, const cell_t *params)
{
    if (params[0] != 6)
        return context->ThrowNativeError("AnneSpawn_SetSurvivorSnapshot expects 6 parameters");

    int count = params[6];
    if (count < 0 || count > kMaxSnapshotClients)
        return context->ThrowNativeError("Invalid survivor snapshot count %d", count);

    cell_t *clients;
    cell_t *incapacitated;
    cell_t *eyes;
    cell_t *eyesLeft;
    cell_t *eyesRight;
    if (!GetCells(context, params[1], clients) || !GetCells(context, params[2], incapacitated) ||
        !GetCells(context, params[3], eyes) || !GetCells(context, params[4], eyesLeft) ||
        !GetCells(context, params[5], eyesRight))
        return context->ThrowNativeError("Invalid survivor snapshot arrays");

    g_SurvivorCount = 0;
    for (int i = 0; i < count; ++i)
    {
        SurvivorSnapshot &snapshot = g_Survivors[static_cast<std::size_t>(i)];
        snapshot.client = clients[i];
        snapshot.incapacitated = incapacitated[i] != 0;
        snapshot.eyes = ReadVector(eyes, i * 3);
        snapshot.eyesLeft = ReadVector(eyesLeft, i * 3);
        snapshot.eyesRight = ReadVector(eyesRight, i * 3);
        if (!gpGlobals || snapshot.client <= 0 || snapshot.client > gpGlobals->maxClients ||
            !IsFiniteVector(snapshot.eyes) || !IsFiniteVector(snapshot.eyesLeft) ||
            !IsFiniteVector(snapshot.eyesRight))
        {
            return context->ThrowNativeError("Invalid survivor snapshot entry %d", i);
        }
    }
    g_SurvivorCount = static_cast<std::size_t>(count);
    g_SurvivorSpatialKey = ComputeSurvivorSpatialKey();
    return 1;
}

cell_t Native_ClearSurvivorSnapshot(IPluginContext *, const cell_t *)
{
    g_SurvivorCount = 0;
    g_SurvivorSpatialKey = 0;
    return 0;
}

cell_t Native_TestPointSafety(IPluginContext *context, const cell_t *params)
{
    if (params[0] != 4)
        return context->ThrowNativeError("AnneSpawn_TestPointSafety expects 4 parameters");

    cell_t *positionCells;
    if (!GetCells(context, params[1], positionCells))
        return context->ThrowNativeError("Invalid spawn position");

    Vector position = ReadVector(positionCells);
    if (!IsFiniteVector(position))
        return context->ThrowNativeError("Invalid spawn position vector");
    if (IsPointStuck(position))
        return kSafetyStuck;
    return IsPointVisible(position, params[2] != 0, params[3] != 0, params[4])
        ? kSafetyVisible
        : kSafetySafe;
}

cell_t Native_ComputePointGeometry(IPluginContext *context, const cell_t *params)
{
    if (params[0] != 7)
        return context->ThrowNativeError("AnneSpawn_ComputePointGeometry expects 7 parameters");

    cell_t *positionCells;
    cell_t *centerCells;
    cell_t *targetEyeCells;
    cell_t *minDistanceOut;
    cell_t *targetDistanceOut;
    cell_t *sectorOut;
    if (!GetCells(context, params[1], positionCells) || !GetCells(context, params[2], centerCells) ||
        !GetCells(context, params[4], targetEyeCells) || !GetCells(context, params[5], minDistanceOut) ||
        !GetCells(context, params[6], targetDistanceOut) || !GetCells(context, params[7], sectorOut))
        return context->ThrowNativeError("Invalid geometry parameters");

    float minDistanceSquared;
    float targetDistance;
    int sector;
    ComputeGeometry(ReadVector(positionCells), ReadVector(centerCells), params[3],
                    ReadVector(targetEyeCells), minDistanceSquared, targetDistance, sector);
    *minDistanceOut = sp_ftoc(minDistanceSquared);
    *targetDistanceOut = sp_ftoc(targetDistance);
    *sectorOut = sector;
    return 1;
}

cell_t Native_ComputeGeometryBatch(IPluginContext *context, const cell_t *params)
{
    if (params[0] != 8)
        return context->ThrowNativeError("AnneSpawn_ComputeGeometryBatch expects 8 parameters");

    int count = params[2];
    if (count < 0 || count > kMaxGeometryBatch)
        return context->ThrowNativeError("Invalid geometry batch count %d", count);

    cell_t *positions;
    cell_t *centerCells;
    cell_t *targetEyeCells;
    cell_t *minDistanceOut;
    cell_t *targetDistanceOut;
    cell_t *sectorOut;
    if (!GetCells(context, params[1], positions) || !GetCells(context, params[3], centerCells) ||
        !GetCells(context, params[5], targetEyeCells) || !GetCells(context, params[6], minDistanceOut) ||
        !GetCells(context, params[7], targetDistanceOut) || !GetCells(context, params[8], sectorOut))
        return context->ThrowNativeError("Invalid geometry batch arrays");

    Vector center = ReadVector(centerCells);
    Vector targetEye = ReadVector(targetEyeCells);
    for (int i = 0; i < count; ++i)
    {
        float minDistanceSquared;
        float targetDistance;
        int sector;
        ComputeGeometry(ReadVector(positions, i * 3), center, params[4], targetEye,
                        minDistanceSquared, targetDistance, sector);
        minDistanceOut[i] = sp_ftoc(minDistanceSquared);
        targetDistanceOut[i] = sp_ftoc(targetDistance);
        sectorOut[i] = sector;
    }
    return 1;
}

cell_t Native_SelectTopK(IPluginContext *context, const cell_t *params)
{
    if (params[0] != 4)
        return context->ThrowNativeError("AnneSpawn_SelectTopK expects 4 parameters");

    int count = params[2];
    int topK = params[3];
    if (count < 0 || count > kMaxTopKCandidates || topK < 0)
        return context->ThrowNativeError("Invalid top-k dimensions %d/%d", count, topK);
    topK = std::min(topK, count);

    cell_t *scores;
    cell_t *output;
    if (!GetCells(context, params[1], scores) || !GetCells(context, params[4], output))
        return context->ThrowNativeError("Invalid top-k arrays");

    std::vector<int> indices(count);
    std::iota(indices.begin(), indices.end(), 0);
    auto scoreOrder = [scores](int left, int right) {
        float leftScore = sp_ctof(scores[left]);
        float rightScore = sp_ctof(scores[right]);
        if (!std::isfinite(leftScore))
            leftScore = -std::numeric_limits<float>::infinity();
        if (!std::isfinite(rightScore))
            rightScore = -std::numeric_limits<float>::infinity();
        if (leftScore == rightScore)
            return left < right;
        return leftScore > rightScore;
    };
    std::partial_sort(indices.begin(), indices.begin() + topK, indices.end(), scoreOrder);
    for (int i = 0; i < topK; ++i)
        output[i] = indices[i];
    return topK;
}

cell_t Native_MapNearest2D(IPluginContext *context, const cell_t *params)
{
    if (params[0] != 8)
        return context->ThrowNativeError("AnneSpawn_MapNearest2D expects 8 parameters");

    int validCount = params[3];
    int queryCount = params[5];
    float cellSize = sp_ctof(params[6]);
    float radius = std::max(0.0f, sp_ctof(params[7]));
    if (validCount < 0 || validCount > kMaxSpatialPoints || queryCount < 0 ||
        queryCount > kMaxSpatialPoints || cellSize <= 0.0f)
        return context->ThrowNativeError("Invalid spatial map dimensions");

    cell_t *validXY;
    cell_t *validAreaIndices;
    cell_t *queryXY;
    cell_t *outputAreaIndices;
    if (!GetCells(context, params[1], validXY) || !GetCells(context, params[2], validAreaIndices) ||
        !GetCells(context, params[4], queryXY) || !GetCells(context, params[8], outputAreaIndices))
        return context->ThrowNativeError("Invalid spatial map arrays");

    std::unordered_map<std::uint64_t, std::vector<int>> grid;
    grid.reserve(static_cast<std::size_t>(validCount) * 2);
    for (int i = 0; i < validCount; ++i)
    {
        int cellX = static_cast<int>(std::floor(sp_ctof(validXY[i * 2]) / cellSize));
        int cellY = static_cast<int>(std::floor(sp_ctof(validXY[i * 2 + 1]) / cellSize));
        grid[MakeCellKey(cellX, cellY)].push_back(i);
    }

    int maxLayer = radius > 0.1f ? static_cast<int>(std::ceil(radius / cellSize)) : 6;
    maxLayer = std::clamp(maxLayer, 0, 48);
    float radiusSquared = radius > 0.1f ? radius * radius : -1.0f;

    for (int query = 0; query < queryCount; ++query)
    {
        float queryX = sp_ctof(queryXY[query * 2]);
        float queryY = sp_ctof(queryXY[query * 2 + 1]);
        int queryCellX = static_cast<int>(std::floor(queryX / cellSize));
        int queryCellY = static_cast<int>(std::floor(queryY / cellSize));
        float bestDistanceSquared = std::numeric_limits<float>::max();
        int bestArea = -1;

        for (int layer = 0; layer <= maxLayer; ++layer)
        {
            bool foundThisRing = false;
            int minX = queryCellX - layer;
            int maxX = queryCellX + layer;
            int minY = queryCellY - layer;
            int maxY = queryCellY + layer;

            for (int cellY = minY; cellY <= maxY; ++cellY)
            {
                for (int cellX = minX; cellX <= maxX; ++cellX)
                {
                    if (cellX != minX && cellX != maxX && cellY != minY && cellY != maxY)
                        continue;
                    auto found = grid.find(MakeCellKey(cellX, cellY));
                    if (found == grid.end())
                        continue;

                    for (int validRow : found->second)
                    {
                        float deltaX = queryX - sp_ctof(validXY[validRow * 2]);
                        float deltaY = queryY - sp_ctof(validXY[validRow * 2 + 1]);
                        float distanceSquared = deltaX * deltaX + deltaY * deltaY;
                        if (radiusSquared > 0.0f && distanceSquared > radiusSquared)
                            continue;
                        if (distanceSquared < bestDistanceSquared)
                        {
                            bestDistanceSquared = distanceSquared;
                            bestArea = validAreaIndices[validRow];
                            foundThisRing = true;
                        }
                    }
                }
            }
            if (foundThisRing)
                break;
        }
        outputAreaIndices[query] = bestArea;
    }
    return 1;
}

cell_t Native_PathExists(IPluginContext *context, const cell_t *params)
{
    if (params[0] != 9)
        return context->ThrowNativeError("AnneSpawn_PathExists expects 9 parameters");

    void *navGoal = CellToPointer(params[1]);
    void *navStart = CellToPointer(params[3]);
    if (!navGoal || !navStart)
        return 0;

    float maxPathLength = sp_ctof(params[5]);
    std::uint32_t goalId = static_cast<std::uint32_t>(params[2]);
    std::uint32_t startId = static_cast<std::uint32_t>(params[4]);

    bool canUseGraph = false;
    {
        std::lock_guard<std::mutex> lock(g_GraphMutex);
        canUseGraph = g_NavGraph && g_NavGraph->complete;
    }
    if (canUseGraph)
    {
        PrepareReachability(startId, maxPathLength + AnneNavGraph::kBoundarySlack,
                            params[7], params[8] != 0);
    }

    std::shared_ptr<AnneNavGraph> graph;
    std::shared_ptr<ReachabilityResult> reachability;
    {
        std::lock_guard<std::mutex> lock(g_GraphMutex);
        graph = g_NavGraph;
        reachability = FindReachabilityLocked(
            startId, maxPathLength + AnneNavGraph::kBoundarySlack,
            params[7], params[8] != 0, true);
    }
    if (graph && graph->complete && reachability)
    {
        std::uint32_t goalIndex;
        if (graph->FindIndex(goalId, goalIndex))
        {
            float distance = reachability->distances[goalIndex];
            if (!std::isfinite(distance))
            {
                return 0;
            }
            else
            {
                bool special = reachability->usesSpecialEdge[goalIndex] != 0;
                if (!special && distance <= maxPathLength - AnneNavGraph::kBoundarySlack)
                    return 1;
                if (!special && distance > maxPathLength + AnneNavGraph::kBoundarySlack)
                    return 0;
            }
        }
    }

    bool dynamicTopologyDirty = false;
    {
        std::lock_guard<std::mutex> lock(g_GraphMutex);
        dynamicTopologyDirty = g_DynamicNav.dirty;
    }
    // Invalidation clears this cache before a dynamic state can rebuild. While
    // dirty, never retain an engine fallback result from a moving topology.
    bool useCache = params[9] != 0 && !dynamicTopologyDirty;
    int blockedEpoch = CurrentBlockedEpoch();
    if (useCache && g_PathCacheEpoch != blockedEpoch)
    {
        g_PathCache.clear();
        g_PathCacheEpoch = blockedEpoch;
    }

    PathCacheKey key{
        goalId,
        startId,
        params[6],
        params[5],
        blockedEpoch,
        static_cast<std::int16_t>(params[7]),
        params[8] != 0,
    };
    if (useCache)
    {
        auto found = g_PathCache.find(key);
        if (found != g_PathCache.end())
            return found->second ? 1 : 0;
    }

    // ShortestPathCost is stateless in L4D2. Give its reference parameter valid aligned storage
    // instead of relying on the null storage used by the equivalent Left4DHooks SDKCall.
    alignas(void *) std::uint8_t shortestPathCost = 0;
    bool result = g_NavAreaBuildPath(navGoal, navStart, nullptr, nullptr,
                                     &shortestPathCost, nullptr,
                                     maxPathLength, params[7], params[8] != 0);
    if (useCache)
        g_PathCache.emplace(key, result);
    return result ? 1 : 0;
}

cell_t Native_ClearPathCache(IPluginContext *, const cell_t *)
{
    g_PathCache.clear();
    g_PathCacheEpoch = -1;
    return 0;
}

sp_nativeinfo_t g_Natives[] = {
    {"AnneSpawn_IsActive", Native_IsActive},
    {"AnneSpawn_NavGraphStart", Native_NavGraphStart},
    {"AnneSpawn_NavGraphPump", Native_NavGraphPump},
    {"AnneSpawn_NavGraphStop", Native_NavGraphStop},
    {"AnneSpawn_NavGraphPrepareRange", Native_NavGraphPrepareRange},
    {"AnneSpawn_NavGraphCollectRange", Native_NavGraphCollectRange},
    {"AnneSpawn_NavCandidatesPrepare", Native_NavCandidatesPrepare},
    {"AnneSpawn_NavCandidatesCollect", Native_NavCandidatesCollect},
    {"AnneSpawn_NavCandidatesGetPerf", Native_NavCandidatesGetPerf},
    {"AnneSpawn_NavCandidatesResetPerf", Native_NavCandidatesResetPerf},
    {"AnneSpawn_NavGraphGetAreaCount", Native_NavGraphGetAreaCount},
    {"AnneSpawn_NavGraphGetEdgeCount", Native_NavGraphGetEdgeCount},
    {"AnneSpawn_NavGraphGetDiagnostics", Native_NavGraphGetDiagnostics},
    {"AnneSpawn_NavGraphCollectProgress", Native_NavGraphCollectProgress},
    {"AnneSpawn_NavGraphCollectProgressPage", Native_NavGraphCollectProgressPage},
    {"AnneSpawn_GetWorkerCount", Native_GetWorkerCount},
    {"AnneSpawn_SetSurvivorSnapshot", Native_SetSurvivorSnapshot},
    {"AnneSpawn_ClearSurvivorSnapshot", Native_ClearSurvivorSnapshot},
    {"AnneSpawn_TestPointSafety", Native_TestPointSafety},
    {"AnneSpawn_ComputePointGeometry", Native_ComputePointGeometry},
    {"AnneSpawn_ComputeGeometryBatch", Native_ComputeGeometryBatch},
    {"AnneSpawn_SelectTopK", Native_SelectTopK},
    {"AnneSpawn_MapNearest2D", Native_MapNearest2D},
    {"AnneSpawn_PathExists", Native_PathExists},
    {"AnneSpawn_ClearPathCache", Native_ClearPathCache},
    {nullptr, nullptr},
};
}

AnneSpawnAccelExtension g_AnneSpawnAccel;
CGlobalVars *gpGlobals = nullptr;
SMEXT_LINK(&g_AnneSpawnAccel);

bool AnneSpawnAccelExtension::SDK_OnMetamodLoad(ISmmAPI *ismm, char *error, size_t maxlen, bool)
{
    GET_V_IFACE_ANY(GetEngineFactory, g_EngineTrace, IEngineTrace, INTERFACEVERSION_ENGINETRACE_SERVER);
    GET_V_IFACE_ANY(GetEngineFactory, g_StaticPropMgr, IStaticPropMgrServer,
                    INTERFACEVERSION_STATICPROPMGR_SERVER);
    gpGlobals = ismm->GetCGlobals();
    if (!g_EngineTrace || !g_StaticPropMgr || !gpGlobals)
    {
        std::snprintf(error, maxlen,
                      "Could not resolve engine trace, static prop manager, or CGlobalVars");
        return false;
    }
    return true;
}

bool AnneSpawnAccelExtension::SDK_OnLoad(char *error, size_t maxlength, bool)
{
    if (std::strcmp(g_pSM->GetGameFolderName(), "left4dead2") != 0)
    {
        std::snprintf(error, maxlength, "Anne Spawn Accel only supports Left 4 Dead 2");
        return false;
    }

    char configError[256] = "";
    if (!gameconfs->LoadGameConfigFile("anne_spawn_accel.games", &g_GameConfig,
                                       configError, sizeof(configError)))
    {
        std::snprintf(error, maxlength, "Could not load anne_spawn_accel.games: %s", configError);
        return false;
    }

    void *visibleAddress = nullptr;
    void *pathAddress = nullptr;
    void *navAreasAddress = nullptr;
    if (!g_GameConfig->GetMemSig("IsVisibleToPlayer", &visibleAddress) || !visibleAddress ||
        !g_GameConfig->GetMemSig("NavAreaBuildPath", &pathAddress) || !pathAddress ||
        !g_GameConfig->GetAddress("TheNavAreas", &navAreasAddress) || !navAreasAddress)
    {
        std::snprintf(error, maxlength,
                      "Could not resolve IsVisibleToPlayer, NavAreaBuildPath, or TheNavAreas");
        SDK_OnUnload();
        return false;
    }

    struct RequiredOffset
    {
        const char *name;
        int *value;
    };
    RequiredOffset requiredOffsets[] = {
        {"CNavArea::ID", &g_NavAreaIdOffset},
        {"CNavArea::Center", &g_NavAreaCenterOffset},
        {"TerrorNavArea::FlowDistance", &g_NavAreaFlowOffset},
        {"CNavArea::BlockedBits", &g_NavAreaBlockedBitsOffset},
        {"CNavArea::Attributes", &g_NavAreaAttributesOffset},
        {"CNavArea::Connections", &g_NavAreaConnectionsOffset},
        {"CNavArea::Ladders", &g_NavAreaLaddersOffset},
        {"CNavArea::Elevator", &g_NavAreaElevatorOffset},
        {"TheNavAreas::Count", &g_NavAreasCountOffset},
        {"CNavLadder::TopForward", &g_LadderTopForwardOffset},
        {"CNavLadder::TopLeft", &g_LadderTopLeftOffset},
        {"CNavLadder::TopRight", &g_LadderTopRightOffset},
        {"CNavLadder::Bottom", &g_LadderBottomOffset},
    };
    for (const RequiredOffset &required : requiredOffsets)
    {
        if (!g_GameConfig->GetOffset(required.name, required.value) || *required.value < 0)
        {
            std::snprintf(error, maxlength, "Could not resolve offset %s", required.name);
            SDK_OnUnload();
            return false;
        }
    }

    g_IsVisibleToPlayer = reinterpret_cast<IsVisibleToPlayerFn>(visibleAddress);
    g_NavAreaBuildPath = reinterpret_cast<NavAreaBuildPathFn>(pathAddress);
    g_TheNavAreas = navAreasAddress;
    g_PathCache.reserve(4096);

    sharesys->AddNatives(myself, g_Natives);
    sharesys->RegisterLibrary(myself, "anne_spawn_accel");
    return true;
}

void AnneSpawnAccelExtension::SDK_OnUnload()
{
    {
        std::lock_guard<std::mutex> lock(g_GraphMutex);
        g_NavGraphGeneration.fetch_add(1);
    }
    g_Workers.Stop();
    {
        std::lock_guard<std::mutex> lock(g_GraphMutex);
        g_NavMetadata.reset();
        g_NavGraph.reset();
        g_PendingNavGraph.reset();
        g_NavCapture.reset();
        ClearReachabilityState();
        g_NavGraphError.clear();
        g_NavGraphForceRebuild = false;
        g_NavGraphCacheHit = false;
        g_NavUnknownAreaCount = 0;
        g_NavUnknownAreaSamples.clear();
        g_DynamicNav = DynamicNavMonitor{};
    }
    g_NavGraphState.store(kNavGraphIdle);
    g_SurvivorCount = 0;
    g_SurvivorSpatialKey = 0;
    g_PathCache.clear();
    g_PathCacheEpoch = -1;
    g_IsVisibleToPlayer = nullptr;
    g_NavAreaBuildPath = nullptr;
    g_TheNavAreas = nullptr;
    g_EngineTrace = nullptr;
    g_StaticPropMgr = nullptr;
    gpGlobals = nullptr;
    g_BlockTypeOffset = -1;
    if (g_GameConfig)
    {
        gameconfs->CloseGameConfigFile(g_GameConfig);
        g_GameConfig = nullptr;
    }
}
