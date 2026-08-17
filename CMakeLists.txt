cmake_minimum_required(VERSION 3.23)

project(ROBOTSERVER)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# -- BARE MINIMUM SUBMODULE SETUP --
# Turn off tests so it builds in minutes instead of an hour
set(BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(BUILD_PERF_TESTS OFF CACHE BOOL "" FORCE)
# Disable Intel Performance Primitives to fix internal header bugs
set(WITH_IPP OFF CACHE BOOL "" FORCE)
# Bundle OpenCV into one easy-to-link target
set(BUILD_opencv_world ON CACHE BOOL "" FORCE)

add_subdirectory(third-party/opencv)

set(CPR_ENABLE_TESTS OFF CACHE BOOL "" FORCE) # Don't build CPR tests
set(CPR_CURL_USE_LIBPSL OFF CACHE BOOL "" FORCE)
add_subdirectory(third-party/cpr)

set(JSON_BuildTests OFF CACHE INTERNAL "")
add_subdirectory(third-party/json)

include_directories(sensor_data_processors)

add_executable(ROBOTSERVER)

enable_testing()

add_subdirectory(sensor_data_processors)

target_sources(ROBOTSERVER
  PRIVATE
    main.cpp
)

target_link_libraries(ROBOTSERVER
  PRIVATE
    sensor_data_processors
    SDL2        # Links standard SDL2
    SDL2_image  # Links the image extension
    opencv_world
)
