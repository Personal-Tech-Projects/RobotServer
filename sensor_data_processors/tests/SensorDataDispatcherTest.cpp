#include "SensorDataDispatcher.h"
#include "SensorDataProcessorMock.h"

#include <gmock/gmock.h>
#include <gtest/gtest.h>

#include <memory>
#include <vector>

using ::testing::StrictMock;

TEST(SensorDataDispatcherTest, EnqueuesDataForInitialProcessor) {
    auto processor = std::make_shared<StrictMock<SensorDataProcessorMock>>();
    auto data = std::make_shared<SensorData>();
    SensorDataDispatcher dispatcher({processor});

    EXPECT_CALL(*processor, enqueue(data)).Times(1);

    dispatcher.enqueueData(data);
}

TEST(SensorDataDispatcherTest, EnqueuesEveryMessage) {
    auto processor = std::make_shared<StrictMock<SensorDataProcessorMock>>();
    auto data = std::make_shared<SensorData>();
    SensorDataDispatcher dispatcher({processor});

    EXPECT_CALL(*processor, enqueue(data)).Times(3);

    for (int i = 0; i < 3; ++i) {
        dispatcher.enqueueData(data);
    }
}

TEST(SensorDataDispatcherTest, EnqueuesDataForEveryProcessor) {
    auto first = std::make_shared<StrictMock<SensorDataProcessorMock>>();
    auto second = std::make_shared<StrictMock<SensorDataProcessorMock>>();
    auto data = std::make_shared<SensorData>();
    SensorDataDispatcher dispatcher({first, second});

    EXPECT_CALL(*first, enqueue(data)).Times(1);
    EXPECT_CALL(*second, enqueue(data)).Times(1);

    dispatcher.enqueueData(data);
}

TEST(SensorDataDispatcherTest, AddsValidProcessorAndIgnoresNull) {
    auto processor = std::make_shared<StrictMock<SensorDataProcessorMock>>();
    auto data = std::make_shared<SensorData>();
    SensorDataDispatcher dispatcher({});

    dispatcher.addProcessor(nullptr);
    dispatcher.addProcessor(processor);
    EXPECT_CALL(*processor, enqueue(data)).Times(1);

    dispatcher.enqueueData(data);
}
