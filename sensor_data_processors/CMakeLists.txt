cmake_minimum_required(VERSION 3.23)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

set(CMAKE_PREFIX_PATH "${CMAKE_CURRENT_SOURCE_DIR}/../../folly-deps/installed")

find_package(folly REQUIRED)
find_package(gflags REQUIRED)
find_package(SDL2 REQUIRED)

add_library(sensor_data_processors STATIC)

add_subdirectory(${PROJECT_SOURCE_DIR}/third-party/googletest ${CMAKE_BINARY_DIR}/googletest)

add_subdirectory(tests)

target_include_directories(sensor_data_processors
  SYSTEM PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${PROJECT_BINARY_DIR}
    ${PROJECT_SOURCE_DIR}/third-party/opencv/include
    ${PROJECT_SOURCE_DIR}/third-party/opencv/modules/core/include
    ${PROJECT_SOURCE_DIR}/third-party/opencv/modules/calib3d/include
    ${PROJECT_SOURCE_DIR}/third-party/opencv/modules/features2d/include
    ${PROJECT_SOURCE_DIR}/third-party/opencv/modules/flann/include
    ${PROJECT_SOURCE_DIR}/third-party/opencv/modules/highgui/include
    ${PROJECT_SOURCE_DIR}/third-party/opencv/modules/imgcodecs/include
    ${PROJECT_SOURCE_DIR}/third-party/opencv/modules/imgproc/include
    ${PROJECT_SOURCE_DIR}/third-party/opencv/modules/ml/include
    ${PROJECT_SOURCE_DIR}/third-party/opencv/modules/objdetect/include
    ${PROJECT_SOURCE_DIR}/third-party/opencv/modules/photo/include
    ${PROJECT_SOURCE_DIR}/third-party/opencv/modules/stitching/include
    ${PROJECT_SOURCE_DIR}/third-party/opencv/modules/video/include
    ${PROJECT_SOURCE_DIR}/third-party/opencv/modules/videoio/include
    ${PROJECT_SOURCE_DIR}/third-party/opencv/modules/dnn/include
)

target_link_libraries(sensor_data_processors
  PUBLIC
    Folly::folly
    SDL2::SDL2
    opencv_world
    cpr::cpr
    nlohmann_json::nlohmann_json
)

target_sources(sensor_data_processors
  PRIVATE
   SensorDataDispatcher.cpp
   SDLWorker.cpp
   WorkerManager.cpp
   RemoteWebcamProviderWorker.cpp
   LLMPetDetectionWorker.cpp
   RobotControlWorker.cpp

  PUBLIC
    FILE_SET myHeaders
    TYPE HEADERS
    BASE_DIRS
      .
    FILES
      SensorDataWorkerInterface.h
      SensorDataDispatcher.h
      WorkerInterface.h
      SDLWorker.h
      WorkerManager.h
      RemoteWebcamProviderWorker.h
      LLMPetDetectionWorker.h
      RobotControlWorker.h
)

target_compile_definitions(sensor_data_processors
  PRIVATE 
    MODEL_DIR=\"${PROJECT_SOURCE_DIR}/build/\"
)
