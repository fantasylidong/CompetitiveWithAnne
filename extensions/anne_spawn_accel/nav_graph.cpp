#include "nav_graph.h"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <limits>
#include <queue>
#include <utility>

namespace
{
constexpr char kDiskMagic[8] = {'A', 'N', 'N', 'E', 'N', 'A', 'V', '3'};
constexpr std::uint32_t kDiskVersion = 3;
constexpr std::uint32_t kMaxDiskAreas = 100000;
constexpr std::uint32_t kMaxDiskEdges = 2000000;
constexpr std::uint32_t kDiskFlagComplete = 1u << 0;

#pragma pack(push, 1)
struct DiskHeader
{
    char magic[8];
    std::uint32_t version;
    std::uint32_t headerSize;
    std::uint64_t fingerprint;
    std::uint32_t areaCount;
    std::uint32_t edgeCount;
    std::uint32_t flags;
    std::uint32_t payloadCrc32;
    std::uint32_t reserved[4];
};
#pragma pack(pop)

std::uint32_t Crc32UpdateState(std::uint32_t crc, const void *data, std::size_t size)
{
    const auto *bytes = static_cast<const std::uint8_t *>(data);
    for (std::size_t i = 0; i < size; ++i)
    {
        crc ^= bytes[i];
        for (int bit = 0; bit < 8; ++bit)
            crc = (crc >> 1) ^ (0xedb88320u & (0u - (crc & 1u)));
    }
    return crc;
}

std::uint32_t CacheCrc(std::uint64_t fingerprint, std::uint32_t areaCount,
                       std::uint32_t edgeCount, std::uint32_t flags,
                       const std::vector<std::uint32_t> &ids,
                       const std::vector<std::uint32_t> &offsets,
                       const std::vector<std::uint32_t> &edges)
{
    std::uint32_t crc = 0xffffffffu;
    crc = Crc32UpdateState(crc, &fingerprint, sizeof(fingerprint));
    crc = Crc32UpdateState(crc, &areaCount, sizeof(areaCount));
    crc = Crc32UpdateState(crc, &edgeCount, sizeof(edgeCount));
    crc = Crc32UpdateState(crc, &flags, sizeof(flags));
    if (!ids.empty())
        crc = Crc32UpdateState(crc, ids.data(), ids.size() * sizeof(ids[0]));
    if (!offsets.empty())
        crc = Crc32UpdateState(crc, offsets.data(), offsets.size() * sizeof(offsets[0]));
    if (!edges.empty())
        crc = Crc32UpdateState(crc, edges.data(), edges.size() * sizeof(edges[0]));
    return ~crc;
}

template <typename T>
bool ReadVector(std::ifstream &file, std::vector<T> &values, std::size_t count)
{
    values.resize(count);
    if (count == 0)
        return true;
    return static_cast<bool>(file.read(reinterpret_cast<char *>(values.data()),
                                       static_cast<std::streamsize>(count * sizeof(T))));
}

template <typename T>
bool WriteVector(std::ofstream &file, const std::vector<T> &values)
{
    if (values.empty())
        return true;
    return static_cast<bool>(file.write(reinterpret_cast<const char *>(values.data()),
                                        static_cast<std::streamsize>(values.size() * sizeof(T))));
}

float CenterDistance(const std::vector<float> &centers, std::uint32_t left, std::uint32_t right)
{
    std::size_t a = static_cast<std::size_t>(left) * 3;
    std::size_t b = static_cast<std::size_t>(right) * 3;
    float x = centers[a] - centers[b];
    float y = centers[a + 1] - centers[b + 1];
    float z = centers[a + 2] - centers[b + 2];
    return std::sqrt(x * x + y * y + z * z);
}
}

std::uint32_t AnneNavGraph::PackEdge(std::uint32_t target, AnneNavEdgeType type)
{
    return (static_cast<std::uint32_t>(type) << 30) | (target & kTargetMask);
}

std::uint32_t AnneNavGraph::EdgeTarget(std::uint32_t edge)
{
    return edge & kTargetMask;
}

AnneNavEdgeType AnneNavGraph::EdgeType(std::uint32_t edge)
{
    return static_cast<AnneNavEdgeType>(edge >> 30);
}

bool AnneNavGraph::Finalize(std::string &error)
{
    std::size_t count = navIds.size();
    if (count == 0 || count > kMaxDiskAreas || centers.size() != count * 3 ||
        flowDistances.size() != count || !std::isfinite(maxFlowDistance) ||
        maxFlowDistance <= 0.0f ||
        offsets.size() != count + 1 || offsets.back() != edges.size() ||
        edges.size() > kMaxDiskEdges)
    {
        error = "invalid Nav graph dimensions";
        return false;
    }
    if (offsets.front() != 0)
    {
        error = "invalid Nav graph CSR offsets";
        return false;
    }
    for (std::size_t i = 0; i < count; ++i)
    {
        if (offsets[i] > offsets[i + 1] || offsets[i + 1] > edges.size())
        {
            error = "invalid Nav graph CSR offsets";
            return false;
        }
    }

    idToIndex.clear();
    idToIndex.reserve(count * 2);
    for (std::uint32_t i = 0; i < count; ++i)
    {
        if (!idToIndex.emplace(navIds[i], i).second)
        {
            error = "duplicate NavArea ID in graph";
            return false;
        }
    }

    std::vector<std::uint32_t> incoming(count, 0);
    hasElevatorEdges = false;
    for (std::uint32_t edge : edges)
    {
        std::uint32_t target = EdgeTarget(edge);
        if (target >= count)
        {
            error = "Nav graph edge target is out of range";
            return false;
        }
        if (EdgeType(edge) == AnneNavEdgeType::Elevator)
            hasElevatorEdges = true;
        incoming[target]++;
    }

    reverseOffsets.assign(count + 1, 0);
    for (std::size_t i = 0; i < count; ++i)
        reverseOffsets[i + 1] = reverseOffsets[i] + incoming[i];
    reverseEdges.resize(edges.size());
    std::vector<std::uint32_t> cursor = reverseOffsets;

    for (std::uint32_t from = 0; from < count; ++from)
    {
        for (std::uint32_t row = offsets[from]; row < offsets[from + 1]; ++row)
        {
            std::uint32_t edge = edges[row];
            std::uint32_t target = EdgeTarget(edge);
            reverseEdges[cursor[target]++] = PackEdge(from, EdgeType(edge));
        }
    }

    struct FlowQueueEntry
    {
        float distance;
        std::uint32_t index;
        std::uint32_t source;
    };
    struct FurtherFlowFirst
    {
        bool operator()(const FlowQueueEntry &left, const FlowQueueEntry &right) const
        {
            if (left.distance != right.distance)
                return left.distance > right.distance;
            if (left.source != right.source)
                return left.source > right.source;
            return left.index > right.index;
        }
    };

    const float infinity = std::numeric_limits<float>::infinity();
    resolvedFlowDistances = flowDistances;
    flowResolveDistances.assign(count, infinity);
    std::vector<std::uint32_t> flowSources(count, kTargetMask);
    std::priority_queue<FlowQueueEntry, std::vector<FlowQueueEntry>, FurtherFlowFirst> open;
    for (std::uint32_t i = 0; i < count; ++i)
    {
        float flow = flowDistances[i];
        if (!std::isfinite(flow) || flow < 0.0f || flow > maxFlowDistance)
            continue;
        flowResolveDistances[i] = 0.0f;
        flowSources[i] = i;
        open.push({0.0f, i, i});
    }

    auto relaxFlow = [&](const FlowQueueEntry &current, std::uint32_t next) {
        float nextDistance = current.distance + CenterDistance(centers, current.index, next);
        bool betterDistance = nextDistance + 0.01f < flowResolveDistances[next];
        bool betterSource = std::fabs(nextDistance - flowResolveDistances[next]) <= 0.01f &&
                            current.source < flowSources[next];
        if (!betterDistance && !betterSource)
            return;
        flowResolveDistances[next] = nextDistance;
        flowSources[next] = current.source;
        resolvedFlowDistances[next] = flowDistances[current.source];
        open.push({nextDistance, next, current.source});
    };

    while (!open.empty())
    {
        FlowQueueEntry current = open.top();
        open.pop();
        if (current.distance > flowResolveDistances[current.index] + 0.01f ||
            current.source != flowSources[current.index])
            continue;

        for (std::uint32_t row = offsets[current.index]; row < offsets[current.index + 1]; ++row)
            relaxFlow(current, EdgeTarget(edges[row]));
        for (std::uint32_t row = reverseOffsets[current.index];
             row < reverseOffsets[current.index + 1]; ++row)
            relaxFlow(current, EdgeTarget(reverseEdges[row]));
    }
    return true;
}

bool AnneNavGraph::FindIndex(std::uint32_t navId, std::uint32_t &index) const
{
    auto found = idToIndex.find(navId);
    if (found == idToIndex.end())
        return false;
    index = found->second;
    return true;
}

bool AnneNavGraph::BuildReverseReachability(
    std::uint32_t targetIndex, float maxDistance,
    const std::vector<std::uint8_t> &blocked,
    std::vector<float> &distances,
    std::vector<std::uint8_t> &usesSpecialEdge) const
{
    std::size_t count = navIds.size();
    if (targetIndex >= count || blocked.size() != count)
        return false;

    float infinity = std::numeric_limits<float>::infinity();
    distances.assign(count, infinity);
    usesSpecialEdge.assign(count, 0);
    if (blocked[targetIndex])
        return true;

    struct QueueEntry
    {
        float distance;
        std::uint32_t index;
        std::uint8_t special;
    };
    struct FurtherFirst
    {
        bool operator()(const QueueEntry &left, const QueueEntry &right) const
        {
            if (left.distance != right.distance)
                return left.distance > right.distance;
            return left.special > right.special;
        }
    };

    std::priority_queue<QueueEntry, std::vector<QueueEntry>, FurtherFirst> open;
    distances[targetIndex] = 0.0f;
    open.push({0.0f, targetIndex, 0});

    while (!open.empty())
    {
        QueueEntry current = open.top();
        open.pop();
        if (current.distance > distances[current.index] + 0.01f ||
            current.special != usesSpecialEdge[current.index])
            continue;

        for (std::uint32_t row = reverseOffsets[current.index];
             row < reverseOffsets[current.index + 1]; ++row)
        {
            std::uint32_t edge = reverseEdges[row];
            std::uint32_t previous = EdgeTarget(edge);
            if (blocked[previous])
                continue;

            float nextDistance = current.distance + CenterDistance(centers, current.index, previous);
            if (nextDistance > maxDistance)
                continue;
            std::uint8_t nextSpecial = current.special || EdgeType(edge) != AnneNavEdgeType::Floor;
            bool betterDistance = nextDistance + 0.01f < distances[previous];
            bool betterType = std::fabs(nextDistance - distances[previous]) <= 0.01f &&
                              nextSpecial < usesSpecialEdge[previous];
            if (!betterDistance && !betterType)
                continue;

            distances[previous] = nextDistance;
            usesSpecialEdge[previous] = nextSpecial;
            open.push({nextDistance, previous, nextSpecial});
        }
    }
    return true;
}

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
    std::vector<std::uint8_t> &usesSpecialEdge)
{
    std::size_t survivorCount = survivorEyes.size() / 3;
    if (survivorEyes.size() % 3 != 0 || survivorCount == 0 ||
        targetIndex >= graph.navIds.size() ||
        maxPathDistance <= 0.0f || minSurvivorDistance < 0.0f)
    {
        return false;
    }
    if (!graph.BuildReverseReachability(targetIndex, maxPathDistance, blocked,
                                        pathDistances, usesSpecialEdge))
    {
        return false;
    }

    struct Candidate
    {
        float pathDistance;
        std::uint32_t index;
    };
    std::vector<Candidate> candidates;
    candidates.reserve(graph.navIds.size());
    float minSurvivorDistanceSquared = minSurvivorDistance * minSurvivorDistance;

    for (std::uint32_t index = 0; index < graph.navIds.size(); ++index)
    {
        if (!std::isfinite(pathDistances[index]))
            continue;

        const float *center = &graph.centers[static_cast<std::size_t>(index) * 3];
        float nearestSquared = std::numeric_limits<float>::infinity();
        for (std::size_t survivor = 0; survivor < survivorCount; ++survivor)
        {
            const float *eye = &survivorEyes[survivor * 3];
            float dx = center[0] - eye[0];
            float dy = center[1] - eye[1];
            float dz = center[2] - eye[2];
            nearestSquared = std::min(nearestSquared, dx * dx + dy * dy + dz * dz);
        }
        if (nearestSquared < minSurvivorDistanceSquared)
            continue;

        candidates.push_back({pathDistances[index], index});
    }

    std::sort(candidates.begin(), candidates.end(),
              [](const Candidate &left, const Candidate &right) {
                  if (left.pathDistance != right.pathDistance)
                      return left.pathDistance < right.pathDistance;
                  return left.index < right.index;
              });

    areaIndices.resize(candidates.size());
    candidatePathDistances.resize(candidates.size());
    for (std::size_t row = 0; row < candidates.size(); ++row)
    {
        areaIndices[row] = candidates[row].index;
        candidatePathDistances[row] = candidates[row].pathDistance;
    }
    return true;
}

std::shared_ptr<AnneNavGraph> AnneBuildNavGraph(
    const AnneNavGraphMetadata &metadata,
    std::vector<AnneNavGraphInputEdge> inputEdges,
    bool complete,
    std::string &error)
{
    auto graph = std::make_shared<AnneNavGraph>();
    graph->fingerprint = metadata.fingerprint;
    graph->complete = complete;
    graph->navIds = metadata.navIds;
    graph->centers = metadata.centers;
    graph->flowDistances = metadata.flowDistances;
    graph->maxFlowDistance = metadata.maxFlowDistance;

    std::sort(inputEdges.begin(), inputEdges.end(), [](const auto &left, const auto &right) {
        if (left.from != right.from)
            return left.from < right.from;
        if (left.to != right.to)
            return left.to < right.to;
        return static_cast<std::uint32_t>(left.type) < static_cast<std::uint32_t>(right.type);
    });
    inputEdges.erase(std::unique(inputEdges.begin(), inputEdges.end(), [](const auto &left, const auto &right) {
        return left.from == right.from && left.to == right.to && left.type == right.type;
    }), inputEdges.end());

    std::size_t count = graph->navIds.size();
    graph->offsets.assign(count + 1, 0);
    for (const AnneNavGraphInputEdge &edge : inputEdges)
    {
        if (edge.from >= count || edge.to >= count || edge.from == edge.to)
            continue;
        graph->offsets[edge.from + 1]++;
    }
    for (std::size_t i = 0; i < count; ++i)
        graph->offsets[i + 1] += graph->offsets[i];

    graph->edges.reserve(graph->offsets.back());
    for (const AnneNavGraphInputEdge &edge : inputEdges)
    {
        if (edge.from >= count || edge.to >= count || edge.from == edge.to)
            continue;
        graph->edges.push_back(AnneNavGraph::PackEdge(edge.to, edge.type));
    }
    if (!graph->Finalize(error))
        return nullptr;
    return graph;
}

std::shared_ptr<AnneNavGraph> AnneLoadNavGraph(
    const AnneNavGraphMetadata &metadata,
    std::string &error)
{
    std::ifstream file(metadata.cachePath, std::ios::binary);
    if (!file)
    {
        error = "cache miss";
        return nullptr;
    }

    DiskHeader header{};
    if (!file.read(reinterpret_cast<char *>(&header), sizeof(header)) ||
        std::memcmp(header.magic, kDiskMagic, sizeof(kDiskMagic)) != 0 ||
        header.version != kDiskVersion || header.headerSize != sizeof(DiskHeader))
    {
        error = "invalid Nav graph cache header";
        return nullptr;
    }
    if (header.fingerprint != metadata.fingerprint ||
        header.areaCount != metadata.navIds.size() || header.areaCount == 0 ||
        header.areaCount > kMaxDiskAreas || header.edgeCount > kMaxDiskEdges)
    {
        error = "stale Nav graph cache";
        return nullptr;
    }

    auto graph = std::make_shared<AnneNavGraph>();
    graph->fingerprint = header.fingerprint;
    graph->complete = (header.flags & kDiskFlagComplete) != 0;
    graph->centers = metadata.centers;
    graph->flowDistances = metadata.flowDistances;
    graph->maxFlowDistance = metadata.maxFlowDistance;
    if (!ReadVector(file, graph->navIds, header.areaCount) ||
        !ReadVector(file, graph->offsets, static_cast<std::size_t>(header.areaCount) + 1) ||
        !ReadVector(file, graph->edges, header.edgeCount))
    {
        error = "truncated Nav graph cache";
        return nullptr;
    }
    if (graph->navIds != metadata.navIds ||
        CacheCrc(header.fingerprint, header.areaCount, header.edgeCount, header.flags,
                 graph->navIds, graph->offsets, graph->edges) != header.payloadCrc32)
    {
        error = "Nav graph cache checksum mismatch";
        return nullptr;
    }
    if (!graph->Finalize(error))
        return nullptr;
    return graph;
}

bool AnneStageNavGraphCache(const AnneNavGraph &graph, const std::string &path,
                            std::string &temporaryPath, std::string &error)
{
    DiskHeader header{};
    std::memcpy(header.magic, kDiskMagic, sizeof(kDiskMagic));
    header.version = kDiskVersion;
    header.headerSize = sizeof(DiskHeader);
    header.fingerprint = graph.fingerprint;
    header.areaCount = static_cast<std::uint32_t>(graph.navIds.size());
    header.edgeCount = static_cast<std::uint32_t>(graph.edges.size());
    header.flags = graph.complete ? kDiskFlagComplete : 0;
    header.payloadCrc32 = CacheCrc(header.fingerprint, header.areaCount,
                                   header.edgeCount, header.flags,
                                   graph.navIds, graph.offsets, graph.edges);

    static std::atomic<std::uint64_t> temporarySerial{0};
    temporaryPath = path + ".tmp." +
        std::to_string(temporarySerial.fetch_add(1) + 1);
    std::ofstream file(temporaryPath, std::ios::binary | std::ios::trunc);
    if (!file || !file.write(reinterpret_cast<const char *>(&header), sizeof(header)) ||
        !WriteVector(file, graph.navIds) || !WriteVector(file, graph.offsets) ||
        !WriteVector(file, graph.edges))
    {
        error = "could not write Nav graph cache";
        file.close();
        std::remove(temporaryPath.c_str());
        return false;
    }
    file.close();
    if (!file)
    {
        error = "could not flush Nav graph cache";
        std::remove(temporaryPath.c_str());
        return false;
    }
    return true;
}

bool AnnePublishNavGraphCache(const std::string &temporaryPath, const std::string &path,
                              std::string &error)
{
#if defined(_WIN32)
    std::remove(path.c_str());
#endif
    if (std::rename(temporaryPath.c_str(), path.c_str()) != 0)
    {
        error = "could not publish Nav graph cache";
        std::remove(temporaryPath.c_str());
        return false;
    }
    return true;
}

void AnneDiscardNavGraphCache(const std::string &temporaryPath)
{
    if (!temporaryPath.empty())
        std::remove(temporaryPath.c_str());
}

bool AnneSaveNavGraph(const AnneNavGraph &graph, const std::string &path, std::string &error)
{
    std::string temporaryPath;
    if (!AnneStageNavGraphCache(graph, path, temporaryPath, error))
        return false;
    return AnnePublishNavGraphCache(temporaryPath, path, error);
}
