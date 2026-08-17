add_executable(sensor_data_dispatcher_test
  SensorDataDispatcherTest.cpp
  SensorDataProcessorMock.cpp
)

target_include_directories(sensor_data_dispatcher_test PRIVATE .)

target_link_libraries(sensor_data_dispatcher_test
  PRIVATE
    sensor_data_processors
    GTest::gtest
    GTest::gmock
    GTest::gtest_main
)

add_test(
  NAME SensorDataDispatcherTest
  COMMAND sensor_data_dispatcher_test
)
