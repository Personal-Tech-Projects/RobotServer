#pragma once

#include <atomic>
#include <memory>
#include <mutex>

#include "WorkerInterface.h"
#include "SensorDataDispatcherInterface.h"
#include "SensorDataWorkerInterface.h"
#include <folly/ProducerConsumerQueue.h>

class SDLWorker : public SensorDataWorkerInterface {
public: 
    SDLWorker(std::shared_ptr<SensorDataDispatcherInterface> dispatcher,
              std::shared_ptr<std::atomic<bool>> autonomousArmed);
    virtual ~SDLWorker() override = default;
    void start() override;
    void stop() override;
    void process(std::shared_ptr<SensorData> data) override;
    void enqueue(std::shared_ptr<SensorData> data) override;
private:
    std::shared_ptr<SensorDataDispatcherInterface> dispatcher_;
    std::atomic<bool> isRunning{false};
    std::shared_ptr<std::atomic<bool>> autonomousArmed_;

    std::mutex dataMutex_;
    std::shared_ptr<SensorData> latestData_ = nullptr;
    folly::ProducerConsumerQueue<std::shared_ptr<SensorData>> queue_;
};
