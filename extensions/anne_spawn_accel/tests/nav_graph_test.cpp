#include "../nav_graph.h"

#include <algorithm>
#include <cassert>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>

namespace
{
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
    TestDirectedReachability();
    TestCandidateOrderUsesDirectedPath();
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
    candidateBuildMicros.reserve(benchmarkRuns);
    for (int run = 0; run < benchmarkRuns; ++run)
    {
        auto start = std::chrono::steady_clock::now();
        assert(AnneBuildNavCandidateSnapshot(
            *loaded, targetIndex, 1000000.0f, blocked, survivorEyes, 250.0f,
            candidates, candidatePathDistances, distances, special));
        candidateBuildMicros.push_back(
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
    std::remove(cachePath.c_str());
    return 0;
}
