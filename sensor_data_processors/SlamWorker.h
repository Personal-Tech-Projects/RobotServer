#pragma once

#include "SensorDataWorkerInterface.h"
#include <condition_variable>
#include <mutex>
#include <opencv2/opencv.hpp>
#include <queue>
#include <string>
#include <thread>

// Forward declaration so we don't have to include the massive System.h header
// everywhere
namespace ORB_SLAM3 {
class System;
}

class SlamWorker : public SensorDataWorkerInterface {
  public:
    SlamWorker(const std::string& vocabPath, const std::string& settingsPath);
    ~SlamWorker() override;

    // From WorkerInterface (to manage the background thread)
    void start() override;
    void stop() override;

    // From SensorDataWorkerInterface (Dispatcher calls this)
    void enqueue(std::shared_ptr<SensorData> data) override;
    void process(std::shared_ptr<SensorData> data) override;

  private:
    void workerLoop();

    ORB_SLAM3::System* pSLAM_;
    bool running_;

    // Threading for async processing
    std::thread workerThread_;
    std::mutex queueMutex_;
    std::condition_variable cv_;
    std::queue<std::shared_ptr<SensorData>> queue_;
};