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

// SOEM context-based API (soem/include/soem/)
extern "C" {
#include "soem/ec_type.h"
#include "soem/ec_main.h"
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

    // SOEM context — owns all master state (no global variables)
    ecx_contextt  ctx_;
    ec_slavet     slaves_[EC_MAXSLAVE];
    ec_groupt     groups_[EC_MAXGROUP];
    uint8_t       esibuf_[EC_MAXEEPBUF];
    uint32_t      esimap_[EC_MAXEEPBITMAP];
    ec_eringt     ering_;
    ecx_portt     port_;
    ec_idxstackT  idxstack_;
    boolean       ecaterror_;
    int64         dc_time_;
    ec_SMcommtypet sm_commtype_[EC_MAX_MAPT];
    ec_PDOassignt  pdo_assign_[EC_MAX_MAPT];
    ec_PDOdesct    pdo_desc_[EC_MAX_MAPT];
    ec_eepromSMt   sm_;
    ec_eepromFMMUt fmmu_;
    char           iobuf_[4096];
};

} // namespace micro_ros_ethercat
