#include "../nav_blocked.h"
#include "../nav_graph.h"

#include <algorithm>
#include <cassert>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>

namespace
{
void TestPackedBlockedBits()
{
    assert(!AnneNavBlockedForTeam(0, 2));
    assert(!AnneNavBlockedForTeam(0, 3));
    assert(AnneNavBlockedForTeam(1, 2));
    assert(!AnneNavBlockedForTeam(1, 3));
    assert(!AnneNavBlockedForTeam(2, 2));
    assert(AnneNavBlockedForTeam(2, 3));
    assert(AnneNavBlockedForTeam(3, 2));
    assert(AnneNavBlockedForTeam(3, 3));
    assert(!AnneNavBlockedForTeam(3, -1));
}

void TestDirectedReachability()
{
    AnneNavGraphMetadata metadata;
    metadata.mapName = "directed_reachability_test";
    metadata.navIds = {1, 2, 3};
    metadata.centers = {0.0f, 0.0f, 0.0f,
                        300.0f, 0.0f, 0.0f,
                        600.0f, 0.0f, 0.0f};
    metadata.flowDistances = {0.0f, 300.0f, 600.0f};
    metadata.maxFlowDistance = 600.0f;
    std::vector<AnneNavGraphInputEdge> edges = {
        {0, 1, AnneNavEdgeType::Floor},
        {1, 2, AnneNavEdgeType::Floor},
    };
    std::string error;
    std::shared_ptr<AnneNavGraph> graph =
        AnneBuildNavGraph(metadata, std::move(edges), true, error);
    assert(graph && error.empty());

    std::vector<std::uint8_t> blocked(3, 0);
    std::vector<float> distances;
    std::vector<std::uint8_t> special;
    assert(graph->BuildReverseReachability(2, 1000.0f, blocked, distances, special));
    assert(std::isfinite(distances[0]) && std::isfinite(distances[1]));
    assert(graph->BuildReverseReachability(0, 1000.0f, blocked, distances, special));
    assert(distances[0] == 0.0f);
    assert(!std::isfinite(distances[1]) && !std::isfinite(distances[2]));

    blocked = {0, 1, 0};
    assert(graph->BuildReverseReachability(2, 1000.0f, blocked, distances, special));
    assert(!std::isfinite(distances[0]) && !std::isfinite(distances[1]));
    assert(distances[2] == 0.0f);

    blocked = {0, 0, 1};
    assert(graph->BuildReverseReachability(2, 1000.0f, blocked, distances, special));
    assert(!std::isfinite(distances[0]) && !std::isfinite(distances[1])
        && !std::isfinite(distances[2]));
}

void TestCandidateOrderUsesDirectedPath()
{
    AnneNavGraphMetadata metadata;
    metadata.mapName = "candidate_path_order_test";
    metadata.navIds = {1, 2, 3, 4};
    metadata.centers = {0.0f, 0.0f, 0.0f,
                        0.0f, 0.0f, 300.0f,
                        1000.0f, 0.0f, 0.0f,
                        600.0f, 0.0f, 0.0f};
    metadata.flowDistances = {0.0f, 100.0f, 200.0f, 300.0f};
    metadata.maxFlowDistance = 300.0f;
    std::vector<AnneNavGraphInputEdge> edges = {
        {1, 2, AnneNavEdgeType::Floor},
        {2, 0, AnneNavEdgeType::Floor},
        {3, 0, AnneNavEdgeType::Floor},
    };
    std::string error;
    std::shared_ptr<AnneNavGraph> graph =
        AnneBuildNavGraph(metadata, std::move(edges), true, error);
    assert(graph && error.empty());

    std::vector<std::uint8_t> blocked(4, 0);
    std::vector<float> survivorEyes = {0.0f, 0.0f, 0.0f};
    std::vector<std::uint32_t> candidates;
    std::vector<float> candidatePathDistances;
    std::vector<float> allPathDistances;
    std::vector<std::uint8_t> specialEdges;
    assert(AnneBuildNavCandidateSnapshot(
        *graph, 0, 3000.0f, blocked, survivorEyes, 250.0f,
        candidates, candidatePathDistances, allPathDistances, specialEdges));
    assert(candidates.size() == 3);
    assert(candidates[0] == 3 && candidates[1] == 2 && candidates[2] == 1);
    assert(candidatePathDistances[0] < candidatePathDistances[2]);
}

void TestCandidateOrderUsesHighGroundRank()
{
    AnneNavGraphMetadata metadata;
    metadata.mapName = "candidate_high_ground_rank_test";
    metadata.navIds = {1, 2, 3};
    metadata.centers = {0.0f, 0.0f, 0.0f,
                        400.0f, 0.0f, 0.0f,
                        600.0f, 0.0f, 200.0f};
    metadata.flowDistances = {0.0f, 100.0f, 200.0f};
    metadata.maxFlowDistance = 200.0f;
    std::vector<AnneNavGraphInputEdge> edges = {
        {1, 0, AnneNavEdgeType::Floor},
        {2, 0, AnneNavEdgeType::Floor},
    };
    std::string error;
    std::shared_ptr<AnneNavGraph> graph =
        AnneBuildNavGraph(metadata, std::move(edges), true, error);
    assert(graph && error.empty());

    std::vector<std::uint8_t> blocked(3, 0);
    std::vector<float> survivorEyes = {0.0f, 0.0f, 0.0f};
    std::vector<std::uint32_t> candidates;
    std::vector<float> rawDistances;
    std::vector<float> rankDistances;
    std::vector<float> allPathDistances;
    std::vector<std::uint8_t> specialEdges;
    assert(AnneBuildRankedNavCandidateSnapshot(
        *graph, 0, 2000.0f, blocked, survivorEyes, 250.0f,
        0.0f, 100.0f, 0.5f,
        candidates, rawDistances, rankDistances,
        allPathDistances, specialEdges));
    assert((candidates == std::vector<std::uint32_t>{2, 1}));
    assert(rawDistances[0] > rawDistances[1]);
    assert(rankDistances[0] < rankDistances[1]);

    assert(AnneBuildNavCandidateSnapshot(
        *graph, 0, 2000.0f, blocked, survivorEyes, 250.0f,
        candidates, rawDistances, allPathDistances, specialEdges));
    assert((candidates == std::vector<std::uint32_t>{1, 2}));
    assert(std::is_sorted(rawDistances.begin(), rawDistances.end()));
}

void TestTopologyIssueCompletenessAndCache()
{
    constexpr std::uint64_t baseFingerprint = 0x1020304050607080ull;
    std::vector<AnneNavGraphInputEdge> edges = {
        {0, 1, AnneNavEdgeType::Floor},
        {1, 2, AnneNavEdgeType::Ladder},
    };
    std::vector<AnneNavGraphInputEdge> reordered = {
        {1, 2, AnneNavEdgeType::Ladder},
        {0, 1, AnneNavEdgeType::Floor},
        {0, 1, AnneNavEdgeType::Floor},
    };
    std::vector<AnneNavGraphInputEdge> changed = {
        {0, 1, AnneNavEdgeType::Floor},
        {2, 1, AnneNavEdgeType::Ladder},
    };
    std::uint64_t fingerprint = AnneComputeNavTopologyFingerprint(
        baseFingerprint, edges, AnneNavTopologyIssue_None);
    assert(fingerprint == AnneComputeNavTopologyFingerprint(
        baseFingerprint, reordered, AnneNavTopologyIssue_None));
    assert(fingerprint != AnneComputeNavTopologyFingerprint(
        baseFingerprint, changed, AnneNavTopologyIssue_None));
    assert(fingerprint != AnneComputeNavTopologyFingerprint(
        baseFingerprint, edges, AnneNavTopologyIssue_DynamicElevator));
    assert(fingerprint != AnneComputeNavTopologyFingerprint(
        baseFingerprint, edges, AnneNavTopologyIssue_None, 0x1234ull));

    const std::string variantA = AnneNavGraphVariantCachePath(
        "/tmp/anne_spawn_accel/map.anvg", fingerprint);
    const std::string variantB = AnneNavGraphVariantCachePath(
        "/tmp/anne_spawn_accel/map.anvg", fingerprint + 1);
    assert(variantA != variantB);
    assert(variantA.find(".anvg") == variantA.size() - 5);
    assert(AnneNavGraphVariantCachePath("/tmp/map", fingerprint).find(".anvg") !=
           std::string::npos);

    const std::string cachePath =
        "/tmp/anne_spawn_accel_nav_graph_incomplete_test.anvg";
    AnneNavGraphMetadata metadata;
    metadata.mapName = "topology_incomplete_test";
    metadata.cachePath = cachePath;
    std::vector<AnneNavGraphInputEdge> dynamicEdges = {
        {0, 1, AnneNavEdgeType::Floor},
        {1, 2, AnneNavEdgeType::Elevator},
    };
    metadata.fingerprint = AnneComputeNavTopologyFingerprint(
        baseFingerprint, dynamicEdges, AnneNavTopologyIssue_DynamicElevator);
    metadata.topologyIssues = AnneNavTopologyIssue_DynamicElevator;
    metadata.navIds = {1, 2, 3};
    metadata.centers = {0.0f, 0.0f, 0.0f,
                        100.0f, 0.0f, 0.0f,
                        200.0f, 0.0f, 0.0f};
    metadata.flowDistances = {0.0f, 100.0f, 200.0f};
    metadata.maxFlowDistance = 200.0f;

    std::string error;
    std::shared_ptr<AnneNavGraph> graph =
        AnneBuildNavGraph(metadata, dynamicEdges, true, error);
    assert(graph && error.empty());
    assert(graph->complete);
    assert(graph->hasElevatorEdges);
    assert(graph->topologyIssues == AnneNavTopologyIssue_DynamicElevator);

    std::vector<std::uint8_t> blocked(3, 0);
    std::vector<float> survivorEyes = {10000.0f, 10000.0f, 10000.0f};
    std::vector<std::uint32_t> candidates;
    std::vector<float> candidatePathDistances;
    std::vector<float> allPathDistances;
    std::vector<std::uint8_t> specialEdges;
    assert(AnneBuildNavCandidateSnapshot(
        *graph, 2, 1000.0f, blocked, survivorEyes, 250.0f,
        candidates, candidatePathDistances, allPathDistances, specialEdges));
    assert((candidates == std::vector<std::uint32_t>{2, 1, 0}));
    assert(candidatePathDistances[0] < candidatePathDistances[1]
        && candidatePathDistances[1] < candidatePathDistances[2]);
    assert(AnneSaveNavGraph(*graph, cachePath, error));

    std::shared_ptr<AnneNavGraph> loaded = AnneLoadNavGraph(metadata, error);
    assert(loaded && loaded->complete);
    assert(loaded->topologyIssues == AnneNavTopologyIssue_DynamicElevator);

    const std::uint32_t fatalIssues[] = {
        AnneNavTopologyIssue_UnknownArea,
        AnneNavTopologyIssue_InvalidFloorStorage,
        AnneNavTopologyIssue_InvalidLadderStorage,
        AnneNavTopologyIssue_DynamicElevator | AnneNavTopologyIssue_UnknownArea,
    };
    for (std::uint32_t issues : fatalIssues)
    {
        AnneNavGraphMetadata fatalMetadata = metadata;
        fatalMetadata.topologyIssues = issues;
        fatalMetadata.fingerprint = AnneComputeNavTopologyFingerprint(
            baseFingerprint, edges, issues);
        std::shared_ptr<AnneNavGraph> fatalGraph =
            AnneBuildNavGraph(fatalMetadata, edges, true, error);
        assert(fatalGraph && !fatalGraph->complete);
    }

    AnneNavGraphMetadata unresolvedEntityMetadata = metadata;
    unresolvedEntityMetadata.topologyIssues =
        AnneNavTopologyIssue_DynamicElevator |
        AnneNavTopologyIssue_UnresolvedDynamicElevator;
    unresolvedEntityMetadata.fingerprint = AnneComputeNavTopologyFingerprint(
        baseFingerprint, dynamicEdges, unresolvedEntityMetadata.topologyIssues);
    std::shared_ptr<AnneNavGraph> unresolvedEntityGraph = AnneBuildNavGraph(
        unresolvedEntityMetadata, dynamicEdges, true, error);
    assert(unresolvedEntityGraph && unresolvedEntityGraph->complete);

    AnneNavGraphMetadata staleMetadata = metadata;
    staleMetadata.fingerprint++;
    assert(!AnneLoadNavGraph(staleMetadata, error));
    std::remove(cachePath.c_str());
}

void TestGenericTopologyVariantCachesCoexist()
{
    namespace fs = std::filesystem;
    fs::path root = fs::temp_directory_path() /
        ("anne_spawn_accel_variants_" + std::to_string(
            std::chrono::steady_clock::now().time_since_epoch().count()));
    fs::path basePath = root / "dynamic_map.anvg";

    AnneNavGraphMetadata metadata;
    metadata.mapName = "dynamic_map";
    metadata.baseCachePath = basePath.string();
    metadata.navIds = {1, 2, 3};
    metadata.centers = {0.0f, 0.0f, 0.0f,
                        100.0f, 0.0f, 0.0f,
                        200.0f, 0.0f, 0.0f};
    metadata.flowDistances = {0.0f, 100.0f, 200.0f};
    metadata.maxFlowDistance = 200.0f;
    std::vector<AnneNavGraphInputEdge> edgesA = {
        {0, 1, AnneNavEdgeType::Floor},
    };
    std::vector<AnneNavGraphInputEdge> edgesB = {
        {1, 2, AnneNavEdgeType::Floor},
    };

    constexpr std::uint64_t baseFingerprint = 0x1234567890abcdefull;
    AnneNavGraphMetadata metadataA = metadata;
    metadataA.fingerprint = AnneComputeNavTopologyFingerprint(
        baseFingerprint, edgesA, AnneNavTopologyIssue_None);
    metadataA.topologyIssues = AnneNavTopologyIssue_None;
    metadataA.cachePath = AnneNavGraphVariantCachePath(
        metadataA.baseCachePath, metadataA.fingerprint);
    AnneNavGraphMetadata metadataB = metadata;
    metadataB.fingerprint = AnneComputeNavTopologyFingerprint(
        baseFingerprint, edgesB, AnneNavTopologyIssue_None);
    metadataB.topologyIssues = AnneNavTopologyIssue_None;
    metadataB.cachePath = AnneNavGraphVariantCachePath(
        metadataB.baseCachePath, metadataB.fingerprint);

    std::string error;
    std::shared_ptr<AnneNavGraph> graphA =
        AnneBuildNavGraph(metadataA, edgesA, true, error);
    std::shared_ptr<AnneNavGraph> graphB =
        AnneBuildNavGraph(metadataB, edgesB, true, error);
    assert(graphA && graphA->complete && graphB && graphB->complete);
    assert(AnneSaveNavGraph(*graphA, metadataA.cachePath, error));
    assert(AnneSaveNavGraph(*graphB, metadataB.cachePath, error));
    assert(metadataA.cachePath != metadataB.cachePath);
    assert(fs::is_regular_file(metadataA.cachePath));
    assert(fs::is_regular_file(metadataB.cachePath));
    std::shared_ptr<AnneNavGraph> loadedAFirst = AnneLoadNavGraph(metadataA, error);
    std::shared_ptr<AnneNavGraph> loadedB = AnneLoadNavGraph(metadataB, error);
    std::shared_ptr<AnneNavGraph> loadedASecond = AnneLoadNavGraph(metadataA, error);
    assert(loadedAFirst && loadedB && loadedASecond);
    assert(loadedAFirst->complete && loadedB->complete && loadedASecond->complete);
    assert(loadedAFirst->fingerprint == loadedASecond->fingerprint);
    assert(loadedAFirst->edges == loadedASecond->edges);
    assert(loadedAFirst->fingerprint != loadedB->fingerprint);
    fs::remove_all(root);
}

void TestCacheIoLifecycle()
{
    namespace fs = std::filesystem;
    fs::path root = fs::temp_directory_path() /
        ("anne_spawn_accel_cache_io_" + std::to_string(
            std::chrono::steady_clock::now().time_since_epoch().count()));
    fs::path cachePath = root / "nested" / "cache.anvg";

    AnneNavGraphMetadata metadata;
    metadata.mapName = "cache_io_test";
    metadata.cachePath = cachePath.string();
    metadata.fingerprint = 0x778899aabbccddeeull;
    metadata.navIds = {10, 20};
    metadata.centers = {0.0f, 0.0f, 0.0f,
                        100.0f, 0.0f, 0.0f};
    metadata.flowDistances = {0.0f, 100.0f};
    metadata.maxFlowDistance = 100.0f;
    std::vector<AnneNavGraphInputEdge> edges = {
        {0, 1, AnneNavEdgeType::Floor},
    };

    std::string error = "stale error";
    std::shared_ptr<AnneNavGraph> graph =
        AnneBuildNavGraph(metadata, std::move(edges), true, error);
    assert(graph);
    error = "stale error";
    assert(AnneSaveNavGraph(*graph, cachePath.string(), error));
    assert(error.empty() && fs::is_regular_file(cachePath));

    fs::path blockingParent = root / "not_a_directory";
    {
        std::ofstream marker(blockingParent);
        marker << "keep";
    }
    std::string temporaryPath;
    assert(!AnneStageNavGraphCache(
        *graph, (blockingParent / "cache.anvg").string(), temporaryPath, error));
    assert(error.find("stage=prepare_parent") != std::string::npos);
    assert(fs::is_regular_file(blockingParent));

    fs::path publishTarget = root / "existing_directory";
    fs::create_directory(publishTarget);
    assert(AnneStageNavGraphCache(
        *graph, publishTarget.string(), temporaryPath, error));
    assert(!AnnePublishNavGraphCache(
        temporaryPath, publishTarget.string(), error));
    assert(error.find("stage=publish") != std::string::npos);
    assert(fs::is_directory(publishTarget));
    assert(!fs::exists(temporaryPath));

    fs::remove_all(root);
}

long Percentile(std::vector<long> values, double percentile)
{
    assert(!values.empty());
    std::sort(values.begin(), values.end());
    std::size_t index = static_cast<std::size_t>(
        std::ceil(static_cast<double>(values.size()) * percentile));
    if (index > 0)
        --index;
    return values[std::min(index, values.size() - 1)];
}
}

int main()
{
    TestPackedBlockedBits();
    TestDirectedReachability();
    TestCandidateOrderUsesDirectedPath();
    TestCandidateOrderUsesHighGroundRank();
    TestTopologyIssueCompletenessAndCache();
    TestGenericTopologyVariantCachesCoexist();
    TestCacheIoLifecycle();
    constexpr std::uint32_t areaCount = 10000;
    constexpr std::uint32_t edgesPerArea = 6;
    const std::string cachePath = "/tmp/anne_spawn_accel_nav_graph_test.anvg";

    AnneNavGraphMetadata metadata;
    metadata.mapName = "nav_graph_test";
    metadata.cachePath = cachePath;
    metadata.fingerprint = 0x123456789abcdef0ull;
    metadata.navIds.reserve(areaCount);
    metadata.centers.reserve(areaCount * 3);
    metadata.flowDistances.reserve(areaCount);
    metadata.maxFlowDistance = static_cast<float>(areaCount) * 10.0f;
    for (std::uint32_t i = 0; i < areaCount; ++i)
    {
        metadata.navIds.push_back(i + 1);
        metadata.centers.push_back(static_cast<float>(i % 100) * 32.0f);
        metadata.centers.push_back(static_cast<float>(i / 100) * 32.0f);
        metadata.centers.push_back(0.0f);
        metadata.flowDistances.push_back(static_cast<float>(i) * 10.0f);
    }
    metadata.flowDistances[5000] = -1.0f;

    std::vector<AnneNavGraphInputEdge> inputEdges;
    inputEdges.reserve(areaCount * edgesPerArea);
    for (std::uint32_t from = 0; from < areaCount; ++from)
    {
        for (std::uint32_t step = 1; step <= edgesPerArea; ++step)
        {
            inputEdges.push_back(
                {from, (from + step) % areaCount, AnneNavEdgeType::Floor});
        }
    }

    std::string error;
    std::shared_ptr<AnneNavGraph> graph =
        AnneBuildNavGraph(metadata, std::move(inputEdges), true, error);
    assert(graph && error.empty());
    assert(graph->navIds.size() == areaCount);
    assert(graph->edges.size() == areaCount * edgesPerArea);
    assert(graph->resolvedFlowDistances.size() == areaCount);
    assert(graph->resolvedFlowDistances[5000] >= 0.0f);
    assert(AnneSaveNavGraph(*graph, cachePath, error));

    std::ifstream cache(cachePath, std::ios::binary | std::ios::ate);
    assert(cache);
    std::streamsize cacheBytes = cache.tellg();
    cache.close();

    auto loadStart = std::chrono::steady_clock::now();
    std::shared_ptr<AnneNavGraph> loaded = AnneLoadNavGraph(metadata, error);
    auto loadMicros = std::chrono::duration_cast<std::chrono::microseconds>(
        std::chrono::steady_clock::now() - loadStart).count();
    assert(loaded && loaded->edges.size() == graph->edges.size());
    assert(loaded->resolvedFlowDistances[5000] == graph->resolvedFlowDistances[5000]);

    std::vector<std::uint8_t> blocked(areaCount, 0);
    std::vector<float> distances;
    std::vector<std::uint8_t> special;
    assert(loaded->BuildReverseReachability(0, 1000000.0f, blocked,
                                            distances, special));
    assert(distances.size() == areaCount && distances[0] == 0.0f);

    const std::uint32_t targetIndex = 5050;
    std::vector<float> survivorEyes;
    for (std::uint32_t survivorIndex : {targetIndex, 100u, 2500u, 9900u})
    {
        std::size_t center = static_cast<std::size_t>(survivorIndex) * 3;
        survivorEyes.push_back(loaded->centers[center]);
        survivorEyes.push_back(loaded->centers[center + 1]);
        survivorEyes.push_back(loaded->centers[center + 2]);
    }

    std::vector<std::uint32_t> candidates;
    std::vector<float> candidatePathDistances;
    assert(AnneBuildNavCandidateSnapshot(
        *loaded, targetIndex, 1000000.0f, blocked, survivorEyes, 250.0f,
        candidates, candidatePathDistances, distances, special));
    assert(candidates.size() == candidatePathDistances.size() && !candidates.empty());
    assert(std::is_sorted(candidatePathDistances.begin(), candidatePathDistances.end()));
    for (std::uint32_t candidate : candidates)
    {
        std::size_t center = static_cast<std::size_t>(candidate) * 3;
        for (std::size_t survivor = 0; survivor < survivorEyes.size() / 3; ++survivor)
        {
            float dx = loaded->centers[center] - survivorEyes[survivor * 3];
            float dy = loaded->centers[center + 1] - survivorEyes[survivor * 3 + 1];
            float dz = loaded->centers[center + 2] - survivorEyes[survivor * 3 + 2];
            assert(dx * dx + dy * dy + dz * dz >= 250.0f * 250.0f);
        }
        assert(std::isfinite(distances[candidate]));
    }

    constexpr int benchmarkRuns = 200;
    std::vector<long> candidateBuildMicros;
    std::vector<long> rankedCandidateBuildMicros;
    candidateBuildMicros.reserve(benchmarkRuns);
    rankedCandidateBuildMicros.reserve(benchmarkRuns);
    std::vector<float> candidateRankDistances;
    for (int run = 0; run < benchmarkRuns; ++run)
    {
        auto start = std::chrono::steady_clock::now();
        assert(AnneBuildNavCandidateSnapshot(
            *loaded, targetIndex, 1000000.0f, blocked, survivorEyes, 250.0f,
            candidates, candidatePathDistances, distances, special));
        candidateBuildMicros.push_back(
            std::chrono::duration_cast<std::chrono::microseconds>(
                std::chrono::steady_clock::now() - start).count());

        start = std::chrono::steady_clock::now();
        assert(AnneBuildRankedNavCandidateSnapshot(
            *loaded, targetIndex, 1000000.0f, blocked, survivorEyes, 250.0f,
            -200.0f, 64.0f, 0.5f,
            candidates, candidatePathDistances, candidateRankDistances,
            distances, special));
        rankedCandidateBuildMicros.push_back(
            std::chrono::duration_cast<std::chrono::microseconds>(
                std::chrono::steady_clock::now() - start).count());
    }

    std::cout << "areas=" << loaded->navIds.size()
              << " edges=" << loaded->edges.size()
              << " cache_bytes=" << cacheBytes
              << " warm_load_us=" << loadMicros << '\n';
    std::cout << "candidate_build_us runs=" << benchmarkRuns
              << " p50=" << Percentile(candidateBuildMicros, 0.50)
              << " p95=" << Percentile(candidateBuildMicros, 0.95)
              << " max=" << Percentile(candidateBuildMicros, 1.00)
              << " candidates=" << candidates.size() << '\n';
    std::cout << "ranked_candidate_build_us runs=" << benchmarkRuns
              << " p50=" << Percentile(rankedCandidateBuildMicros, 0.50)
              << " p95=" << Percentile(rankedCandidateBuildMicros, 0.95)
              << " max=" << Percentile(rankedCandidateBuildMicros, 1.00)
              << " candidates=" << candidates.size() << '\n';
    std::remove(cachePath.c_str());
    return 0;
}
