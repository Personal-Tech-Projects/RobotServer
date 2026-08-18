#pragma once
#include "SensorDataDispatcher.h"
#include "SensorDataWorkerInterface.h"
#include <atomic>
#include <chrono>
#include <folly/ProducerConsumerQueue.h>
#include <memory>
#include <netinet/in.h>
#include <optional>
#include <vector>

class RobotControlWorker : public SensorDataWorkerInterface {
  public:
    explicit RobotControlWorker(
        std::shared_ptr<std::atomic<bool>> autonomousArmed);
    virtual ~RobotControlWorker() override = default;

    void start() override;
    void stop() override;
    void process(std::shared_ptr<SensorData> data) override;
    void enqueue(std::shared_ptr<SensorData> data) override;

  private:
    folly::ProducerConsumerQueue<std::shared_ptr<SensorData>> queue_;
    std::atomic<bool> isRunning_{false};
    void processUserInput(std::shared_ptr<SensorData> data);
    void processLLMInput(std::shared_ptr<SensorData> data);
    void sendUDP(const char* message);
    void drainKeepalives();
    void serviceAutonomousMovement();
    void clearAutonomousMovement();
    int arduinoSocket_{-1};
    int listenSocket_{-1};
    struct sockaddr_in arduinoAddr_;
    const char* autonomousCommand_{"MOTOR, STOP"};
    std::chrono::steady_clock::time_point autonomousUntil_{};
    std::chrono::steady_clock::time_point nextAutonomousHeartbeat_{};
    std::shared_ptr<std::atomic<bool>> autonomousArmed_;
};
