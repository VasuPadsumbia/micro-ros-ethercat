/**
 * soem_bridge.h — Bridge between EtherCAT transport and micro-ROS agent
 *
 * Wraps EtherCATTransport in the micro-ros-agent CustomAgent interface.
 * The bridge:
 *   1. Opens SOEM master on the specified interface
 *   2. Connects to the micro-ROS EtherCAT slave
 *   3. Provides a transport object for the micro-ros-agent to use
 *
 * Usage:
 *   SoemBridge bridge("eth0");
 *   bridge.run();  // blocks forever, spawns agent internally
 */
#pragma once

#include <string>
#include <memory>
#include <atomic>
#include "ethercat_transport.h"

namespace micro_ros_ethercat {

class SoemBridge {
public:
    explicit SoemBridge(const std::string &iface, int slave_n = 1);
    ~SoemBridge();

    /**
     * Start the bridge:
     *  - Opens EtherCAT transport
     *  - Starts micro-ros-agent with the EtherCAT custom transport
     *  - Blocks until shutdown() is called or a fatal error occurs
     *
     * @return 0 on clean shutdown, non-zero on error
     */
    int run();

    /** Signal the bridge to shut down (thread-safe). */
    void shutdown();

    bool is_running() const { return running_; }

private:
    std::string iface_;
    int         slave_n_;
    std::atomic<bool> running_;
    std::unique_ptr<EtherCATTransport> transport_;
};

} // namespace micro_ros_ethercat
