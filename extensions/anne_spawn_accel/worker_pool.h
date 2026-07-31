#ifndef _INCLUDE_ANNE_SPAWN_ACCEL_WORKER_POOL_H_
#define _INCLUDE_ANNE_SPAWN_ACCEL_WORKER_POOL_H_

#include <condition_variable>
#include <cstddef>
#include <deque>
#include <functional>
#include <mutex>
#include <thread>
#include <vector>

class AnneWorkerPool final
{
public:
    AnneWorkerPool() = default;
    ~AnneWorkerPool();

    bool Start(std::size_t threadCount, std::size_t maxQueuedJobs);
    bool Enqueue(std::function<void()> job);
    void ClearPending();
    void Stop();
    std::size_t ThreadCount() const;

private:
    void RunWorker();

    mutable std::mutex mutex_;
    std::condition_variable wake_;
    std::deque<std::function<void()>> jobs_;
    std::vector<std::thread> workers_;
    std::size_t maxQueuedJobs_ = 0;
    bool stopping_ = true;
};

#endif
