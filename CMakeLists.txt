cmake_minimum_required(VERSION 3.12)
project(imac-fan-control CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# Поиск путей для NVML
find_path(NVML_INCLUDE_DIR 
    NAMES nvml.h
    PATHS
        ENV NVML_HEADERS
        ENV CPLUS_INCLUDE_PATH
    )

find_library(NVML_LIBRARY
    NAMES nvidia-ml
    PATHS ENV LIBRARY_PATH
    )

message(STATUS "NVML Include: ${NVML_INCLUDE_DIR}")
message(STATUS "NVML Library: ${NVML_LIBRARY}")

if(NOT NVML_INCLUDE_DIR OR NOT NVML_LIBRARY)
    message(FATAL_ERROR "NVML not found")
endif()


add_executable(imac-fan-control 
    src/main.cpp
)

target_include_directories(imac-fan-control PRIVATE ${NVML_INCLUDE_DIR})
target_link_libraries(imac-fan-control PRIVATE ${NVML_LIBRARY})
