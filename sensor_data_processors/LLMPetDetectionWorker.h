#pragma once
#include "SensorDataDispatcher.h"
#include "SensorDataWorkerInterface.h"
#include <atomic>
#include <folly/ProducerConsumerQueue.h>
#include <memory>
#include <optional>
#include <string>
#include <vector>

class LLMPetDetectionWorker : public SensorDataWorkerInterface {
  public:
    LLMPetDetectionWorker(std::shared_ptr<SensorDataDispatcherInterface>,
                          std::shared_ptr<std::atomic<bool>> autonomousArmed);
    virtual ~LLMPetDetectionWorker() override = default;

    void start() override;
    void stop() override;
    void process(std::shared_ptr<SensorData> data) override;
    void enqueue(std::shared_ptr<SensorData> data) override;

  private:
    std::optional<Object> askGemini(const std::vector<uint8_t>& imageBuffer);

    std::shared_ptr<SensorDataDispatcherInterface> dispatcher_;
    folly::ProducerConsumerQueue<std::shared_ptr<SensorData>> queue_;
    std::string apiKey_;
    std::atomic<bool> isRunning_{false};
    std::shared_ptr<std::atomic<bool>> autonomousArmed_;
    std::vector<std::shared_ptr<SensorData>> cachedImages_ =
        std::vector<std::shared_ptr<SensorData>>(10);
    int cachedImagesIndex_ = 0;
};
