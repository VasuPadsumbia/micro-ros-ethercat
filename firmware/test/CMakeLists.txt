cmake_minimum_required(VERSION 3.16)
include($ENV{IDF_PATH}/tools/cmake/project.cmake)
project(test_spi_transport)

# Reuse main component sources
set(EXTRA_COMPONENT_DIRS
    "${CMAKE_CURRENT_SOURCE_DIR}/../components"
    "${CMAKE_CURRENT_SOURCE_DIR}/../main"
)
