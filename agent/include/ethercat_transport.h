/**
 * ethercat_transport.h — EtherCAT transport for micro-ROS agent
 *
 * Uses the SOEM context-based API (ecx_* functions, SOEM ≥ 1.4).
 * Tunnels micro-ROS XRCE-DDS frames through EtherCAT VoE mailbox.
 *
 * VoE mailbox frame (type 0x0F):
 *   [0-1]  Length  — payload length (excl. 8-byte header)
 *   [2-3]  Address — 0
 *   [4]    Channel — 0
 *   [5]    Type    — 0x0F (VoE)
 *   [6-7]  Reserved
 *   [8..N] Payload — raw micro-ROS XRCE-DDS frame
 */
#pragma once

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>
#include <string>

// SOEM context-based API — must include nicdrv.h before ec_main.h so that
// ecx_portt is defined when ec_main.h references it inside ecx_context.
extern "C" {
#include "soem/ec_type.h"
#include "nicdrv.h"           // defines ecx_portt (Linux oshw)
#include "soem/ec_main.h"
#include "soem/ec_config.h"   // ecx_config_init, ecx_config_map_group
#include "soem/ec_dc.h"       // ecx_configdc
}

namespace micro_ros_ethercat {

constexpr uint16_t MAILBOX_SIZE   = 256;
constexpr uint8_t  VOE_TYPE       = 0x0F;
constexpr uint8_t  MAILBOX_HEADER = 8;

#pragma pack(push, 1)
struct MbxHeader {
    uint16_t length;
    uint16_t address;
    uint8_t  channel;
    uint8_t  type;
    uint16_t reserved;
};
#pragma pack(pop)
static_assert(sizeof(MbxHeader) == 8, "MbxHeader must be 8 bytes");

class EtherCATTransport {
public:
    explicit EtherCATTransport(const std::string &iface, int slave_n = 1);
    ~EtherCATTransport();

    bool    open();
    void    close();
    bool    is_open() const { return open_; }

    ssize_t write(const uint8_t *buf, size_t len, int timeout_ms = 100);
    ssize_t read(uint8_t *buf, size_t max_len, int timeout_ms = 100);

    uint16_t    station_address() const;
    const char *last_error() const;

private:
    bool send_mailbox(const uint8_t *payload, uint16_t len);
    bool recv_mailbox(uint8_t *payload, uint16_t *len, int timeout_ms);

    std::string   iface_;
    int           slave_n_;
    bool          open_;

    // SOEM context — the modern ecx_contextt struct embeds all master state
    // (port, slavelist, grouplist, ESI buffers, etc.) directly as fixed arrays.
    // ecx_init() populates it; no manual wiring needed.
    ecx_contextt  ctx_;

    // I/O buffer for process data (not used by mailbox transport, but required
    // by ecx_config_map).
    uint8_t       iobuf_[4096];
};

} // namespace micro_ros_ethercat
