cmake_minimum_required(VERSION 3.16)
project(micro_ros_ethercat_agent CXX C)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# ── SOEM submodule ────────────────────────────────────────────────────────────
if(NOT DEFINED SOEM_DIR)
    set(SOEM_DIR "${CMAKE_CURRENT_SOURCE_DIR}/soem")
endif()

if(NOT EXISTS "${SOEM_DIR}/CMakeLists.txt")
    message(FATAL_ERROR
        "SOEM not found at ${SOEM_DIR}.\n"
        "Run: git submodule update --init --recursive")
endif()

add_subdirectory(${SOEM_DIR} soem_build)

# SOEM generates ec_options.h into the build tree
set(SOEM_GENERATED_INCLUDE "${CMAKE_CURRENT_BINARY_DIR}/soem_build/include")

# Combined include dirs used by both agent and tests
set(SOEM_INCLUDE_DIRS
    "${SOEM_DIR}/include"
    "${SOEM_DIR}/osal"
    "${SOEM_DIR}/osal/linux"
    "${SOEM_DIR}/oshw/linux"
    "${SOEM_GENERATED_INCLUDE}"
)

# ── Agent executable ──────────────────────────────────────────────────────────
add_executable(micro_ros_ethercat_agent
    src/main.cpp
    src/ethercat_transport.cpp
    src/soem_bridge.cpp
)

target_include_directories(micro_ros_ethercat_agent PRIVATE
    include
    ${SOEM_INCLUDE_DIRS}
)

target_link_libraries(micro_ros_ethercat_agent PRIVATE soem pthread rt)
target_compile_options(micro_ros_ethercat_agent PRIVATE -Wall -Wextra)

# ── Unit tests (Google Test, no libsoem — mock provides all symbols) ──────────
option(BUILD_TESTS "Build GTest unit tests" OFF)

if(BUILD_TESTS)
    enable_testing()
    find_package(GTest REQUIRED)

    add_executable(test_ethercat_transport
        test/test_ethercat_transport.cpp
        test/mock_soem.cpp          # provides ecx_* implementations
        src/ethercat_transport.cpp  # code under test
    )

    target_include_directories(test_ethercat_transport PRIVATE
        include
        test                        # mock_soem.h
        ${SOEM_INCLUDE_DIRS}
    )

    # Do NOT link libsoem — mock_soem.cpp provides all symbols
    target_link_libraries(test_ethercat_transport PRIVATE
        GTest::gtest_main
        pthread
        rt
    )

    target_compile_options(test_ethercat_transport PRIVATE -Wall -Wextra)

    include(GoogleTest)
    gtest_discover_tests(test_ethercat_transport)
endif()

# ── Install ───────────────────────────────────────────────────────────────────
install(TARGETS micro_ros_ethercat_agent RUNTIME DESTINATION bin)
