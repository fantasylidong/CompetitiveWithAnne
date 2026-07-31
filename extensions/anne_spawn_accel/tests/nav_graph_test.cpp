#include "../nav_graph.h"

#include <cassert>
#include <chrono>
#include <cstdio>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>

int main()
{
    constexpr std::uint32_t areaCount = 10000;
    constexpr std::uint32_t edgesPerArea = 6;
    const std::string cachePath = "/tmp/anne_spawn_accel_nav_graph_test.anvg";

    AnneNavGraphMetadata metadata;
    metadata.mapName = "nav_graph_test";
    metadata.cachePath = cachePath;
    metadata.fingerprint = 0x123456789abcdef0ull;
    metadata.navIds.reserve(areaCount);
    metadata.centers.reserve(areaCount * 3);
    for (std::uint32_t i = 0; i < areaCount; ++i)
    {
        metadata.navIds.push_back(i + 1);
        metadata.centers.push_back(static_cast<float>(i % 100) * 32.0f);
        metadata.centers.push_back(static_cast<float>(i / 100) * 32.0f);
        metadata.centers.push_back(0.0f);
    }

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

    std::vector<std::uint8_t> blocked(areaCount, 0);
    std::vector<float> distances;
    std::vector<std::uint8_t> special;
    assert(loaded->BuildReverseReachability(0, 1000000.0f, blocked,
                                            distances, special));
    assert(distances.size() == areaCount && distances[0] == 0.0f);

    std::cout << "areas=" << loaded->navIds.size()
              << " edges=" << loaded->edges.size()
              << " cache_bytes=" << cacheBytes
              << " warm_load_us=" << loadMicros << '\n';
    std::remove(cachePath.c_str());
    return 0;
}
