cmake_minimum_required(VERSION 3.16)

# ESP-IDF must be sourced before this file is processed
include($ENV{IDF_PATH}/tools/cmake/project.cmake)

project(micro_ros_ethercat_firmware)

# micro-ROS component is in firmware/components/micro_ros_espidf_component
# (cloned by setup.sh)
set(EXTRA_COMPONENT_DIRS "${CMAKE_CURRENT_SOURCE_DIR}/components")
