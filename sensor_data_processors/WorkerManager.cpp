#include "WorkerManager.h"
#include "SDLWorker.h"
#include <iostream>

WorkerManager::WorkerManager(
    std::shared_ptr<SensorDataDispatcherInterface> dispatcher,
    std::vector<std::shared_ptr<WorkerInterface>> workers,
    std::vector<std::shared_ptr<WorkerInterface>> asyncWorkers)
    : dispatcher_(std::move(dispatcher)), workers_(std::move(workers)),
      asyncWorkers_(std::move(asyncWorkers)) {}

void WorkerManager::start() {
    for (auto& worker : workers_) {
        worker->start();
    }
    for (auto& worker : asyncWorkers_) {
        std::thread workerThread([worker]() { worker->start(); });
        workerThreads_.push_back(std::move(workerThread));
    }
}

void WorkerManager::stop() {
    for (auto& worker : workers_) {
        worker->stop();
    }
    for (auto& worker : asyncWorkers_) {
        worker->stop();
    }
    for (auto& workerThread : workerThreads_) {
        workerThread.join();
    }
}
