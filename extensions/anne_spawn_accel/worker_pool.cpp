#include "worker_pool.h"

#include <utility>

AnneWorkerPool::~AnneWorkerPool()
{
    Stop();
}

bool AnneWorkerPool::Start(std::size_t threadCount, std::size_t maxQueuedJobs)
{
    Stop();
    if (threadCount == 0 || maxQueuedJobs == 0)
        return false;

    {
        std::lock_guard<std::mutex> lock(mutex_);
        stopping_ = false;
        maxQueuedJobs_ = maxQueuedJobs;
    }

    try
    {
        workers_.reserve(threadCount);
        for (std::size_t i = 0; i < threadCount; ++i)
            workers_.emplace_back(&AnneWorkerPool::RunWorker, this);
    }
    catch (...)
    {
        Stop();
        return false;
    }
    return true;
}

bool AnneWorkerPool::Enqueue(std::function<void()> job)
{
    if (!job)
        return false;

    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (stopping_ || jobs_.size() >= maxQueuedJobs_)
            return false;
        jobs_.push_back(std::move(job));
    }
    wake_.notify_one();
    return true;
}

void AnneWorkerPool::Stop()
{
    {
        std::lock_guard<std::mutex> lock(mutex_);
        stopping_ = true;
        jobs_.clear();
    }
    wake_.notify_all();

    for (std::thread &worker : workers_)
    {
        if (worker.joinable())
            worker.join();
    }
    workers_.clear();
    maxQueuedJobs_ = 0;
}

std::size_t AnneWorkerPool::ThreadCount() const
{
    std::lock_guard<std::mutex> lock(mutex_);
    return workers_.size();
}

void AnneWorkerPool::RunWorker()
{
    while (true)
    {
        std::function<void()> job;
        {
            std::unique_lock<std::mutex> lock(mutex_);
            wake_.wait(lock, [this] { return stopping_ || !jobs_.empty(); });
            if (stopping_ && jobs_.empty())
                return;
            job = std::move(jobs_.front());
            jobs_.pop_front();
        }
        try
        {
            job();
        }
        catch (...)
        {
            // Keep the extension alive if an isolated worker task runs out of memory.
        }
    }
}
