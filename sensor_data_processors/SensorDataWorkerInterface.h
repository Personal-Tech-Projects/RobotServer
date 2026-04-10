#pragma once

#include "WorkerInterface.h"

#include <cstdint>
#include <ctime>
#include <memory>
#include <optional>
#include <vector>

struct UserInputData {
    bool forward = false;
    bool backward = false;
    bool left = false;
    bool right = false;
};

enum class MovementType { Forward, Backward, Left, Right, Stop };

struct LLMInputData {
    MovementType type;
    float value;
};

struct ShapeData {
    int x, y, width, height;
    int r, g, b; // Added color specifications!
};

struct ImageData {
    std::vector<uint8_t> jpegBuffer;
    std::tm timestamp;
};

struct SensorData {
    std::optional<UserInputData> userInput;
    std::optional<LLMInputData> llmInput;
    std::optional<ShapeData> shape;
    std::optional<ImageData> image;
    std::optional<std::vector<int>> detectedObjects;
};

enum class Object { Dog, Cat };

class SensorDataWorkerInterface : public WorkerInterface {
  public:
    virtual ~SensorDataWorkerInterface() = default;

    virtual void process(std::shared_ptr<SensorData> data) = 0;

    virtual void enqueue(std::shared_ptr<SensorData> data) = 0;
};
