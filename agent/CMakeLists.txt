cmake_minimum_required(VERSION 3.16)
project(micro_ros_ethercat_agent CXX C)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# ── SOEM ─────────────────────────────────────────────────────────────────────
if(NOT DEFINED SOEM_DIR)
    set(SOEM_DIR "${CMAKE_CURRENT_SOURCE_DIR}/soem")
endif()

if(NOT EXISTS "${SOEM_DIR}/CMakeLists.txt")
    message(FATAL_ERROR
        "SOEM not found at ${SOEM_DIR}. "
        "Run: bash setup.sh  or  git clone https://github.com/OpenEtherCATsociety/SOEM ${SOEM_DIR}")
endif()

add_subdirectory(${SOEM_DIR} soem_build)

# ── Agent target ─────────────────────────────────────────────────────────────
add_executable(micro_ros_ethercat_agent
    src/main.cpp
    src/ethercat_transport.cpp
    src/soem_bridge.cpp
)

target_include_directories(micro_ros_ethercat_agent PRIVATE
    include
    ${SOEM_DIR}/soem
    ${SOEM_DIR}/osal
    ${SOEM_DIR}/osal/linux
    ${SOEM_DIR}/oshw/linux
)

target_link_libraries(micro_ros_ethercat_agent PRIVATE
    soem
    pthread
    rt
)

target_compile_options(micro_ros_ethercat_agent PRIVATE
    -Wall -Wextra -Wpedantic
)

# ── Tests (Google Test) ───────────────────────────────────────────────────────
option(BUILD_TESTS "Build unit tests" OFF)

if(BUILD_TESTS)
    enable_testing()
    find_package(GTest REQUIRED)

    add_executable(test_ethercat_transport
        test/test_ethercat_transport.cpp
        src/ethercat_transport.cpp
    )

    target_include_directories(test_ethercat_transport PRIVATE
        include
        ${SOEM_DIR}/soem
        ${SOEM_DIR}/osal
        ${SOEM_DIR}/osal/linux
        ${SOEM_DIR}/oshw/linux
        test
    )

    target_link_libraries(test_ethercat_transport PRIVATE
        soem
        GTest::gtest_main
        pthread
        rt
    )

    include(GoogleTest)
    gtest_discover_tests(test_ethercat_transport)
endif()

# ── Install ───────────────────────────────────────────────────────────────────
install(TARGETS micro_ros_ethercat_agent
        RUNTIME DESTINATION bin)
