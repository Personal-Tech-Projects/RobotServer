#include "SlamWorker.h"
#include <System.h> // Actual ORB-SLAM3 include
#include <iostream>

SlamWorker::SlamWorker(const std::string& vocabPath,
                       const std::string& settingsPath)
    : running_(false) {

    std::cout << "[SLAM] Booting ORB-SLAM3..." << std::endl;
    // Initialize the SLAM system in Monocular mode, with the visualizer enabled
    pSLAM_ = new ORB_SLAM3::System(vocabPath, settingsPath,
                                   ORB_SLAM3::System::MONOCULAR, true);
}

SlamWorker::~SlamWorker() {
    stop();
    if (pSLAM_) {
        pSLAM_->Shutdown();
        delete pSLAM_;
    }
}

void SlamWorker::start() {
    running_ = true;
    workerThread_ = std::thread(&SlamWorker::workerLoop, this);
    std::cout << "[SLAM] Worker started." << std::endl;
}

void SlamWorker::stop() {
    running_ = false;
    cv_.notify_all();
    if (workerThread_.joinable()) {
        workerThread_.join();
    }
}

void SlamWorker::enqueue(std::shared_ptr<SensorData> data) {
    // Only queue data if it actually contains an image
    if (data && data->image.has_value()) {
        std::lock_guard<std::mutex> lock(queueMutex_);
        queue_.push(data);
        cv_.notify_one();
    }
}

// Optional: if your dispatcher calls process() directly instead of enqueue()
void SlamWorker::process(std::shared_ptr<SensorData> data) { enqueue(data); }

void SlamWorker::workerLoop() {}