/**
 * ethercat_transport.cpp — EtherCAT transport implementation using SOEM
 */
#include "ethercat_transport.h"

#include <cstring>
#include <cstdio>
#include <cerrno>
#include <chrono>
#include <thread>

extern "C" {
#include "ethercat.h"
#include "ethercattype.h"
}

namespace micro_ros_ethercat {

static char soem_error_buf[512] = "none";

// ── Constructor / destructor ──────────────────────────────────────────────────
EtherCATTransport::EtherCATTransport(const std::string &iface, int slave_n)
    : iface_(iface), slave_n_(slave_n), open_(false)
{
    memset(iobuf_, 0, sizeof(iobuf_));
}

EtherCATTransport::~EtherCATTransport()
{
    if (open_) close();
}

// ── open() ────────────────────────────────────────────────────────────────────
bool EtherCATTransport::open()
{
    // Initialise SOEM master on the interface
    if (!ec_init(iface_.c_str())) {
        snprintf(soem_error_buf, sizeof(soem_error_buf),
                 "ec_init('%s') failed", iface_.c_str());
        fprintf(stderr, "[ethercat_transport] %s\n", soem_error_buf);
        return false;
    }

    // Find slaves
    int found = ec_config_init(FALSE);
    if (found <= 0) {
        snprintf(soem_error_buf, sizeof(soem_error_buf),
                 "No EtherCAT slaves found on %s", iface_.c_str());
        fprintf(stderr, "[ethercat_transport] %s\n", soem_error_buf);
        ec_close();
        return false;
    }

    printf("[ethercat_transport] Found %d slave(s)\n", found);

    if (slave_n_ > found) {
        snprintf(soem_error_buf, sizeof(soem_error_buf),
                 "Slave %d not found (only %d slaves)", slave_n_, found);
        ec_close();
        return false;
    }

    // Print slave info
    printf("[ethercat_transport] Slave %d: %s  VendorID=0x%08X  ProductCode=0x%08X\n",
           slave_n_,
           ec_slave[slave_n_].name,
           (unsigned)ec_slave[slave_n_].eep_id,
           (unsigned)ec_slave[slave_n_].eep_man);

    // Configure process data (not used for mailbox-only operation, but required)
    ec_config_map(iobuf_);
    ec_configdc();

    // Request PRE-OP state
    ec_slave[0].state = EC_STATE_PRE_OP;
    ec_writestate(0);
    ec_statecheck(0, EC_STATE_PRE_OP, EC_TIMEOUTSTATE);

    if (ec_slave[0].state != EC_STATE_PRE_OP) {
        snprintf(soem_error_buf, sizeof(soem_error_buf),
                 "Could not reach PRE-OP state (current: 0x%02X)",
                 ec_slave[0].state);
        ec_close();
        return false;
    }

    printf("[ethercat_transport] Slave in PRE-OP state\n");
    open_ = true;
    return true;
}

// ── close() ───────────────────────────────────────────────────────────────────
void EtherCATTransport::close()
{
    if (!open_) return;

    // Request INIT state
    ec_slave[0].state = EC_STATE_INIT;
    ec_writestate(0);
    ec_close();
    open_ = false;
    printf("[ethercat_transport] Closed\n");
}

// ── send_mailbox() ─────────────────────────────────────────────────────────────
bool EtherCATTransport::send_mailbox(const uint8_t *payload, uint16_t len)
{
    if (!open_ || len + MAILBOX_HEADER > MAILBOX_SIZE) return false;

    // Build VoE mailbox frame
    static uint8_t mbx_buf[MAILBOX_SIZE];
    MbxHeader *hdr = reinterpret_cast<MbxHeader *>(mbx_buf);
    hdr->length   = len;
    hdr->address  = 0;
    hdr->channel  = 0;
    hdr->type     = VOE_TYPE;  // VoE
    hdr->reserved = 0;
    memcpy(mbx_buf + MAILBOX_HEADER, payload, len);

    // SOEM mailbox write: ec_mbxsend(slave, mbx, timeout_us)
    int rc = ec_mbxsend(slave_n_, reinterpret_cast<ec_mbxbuft *>(mbx_buf),
                        EC_TIMEOUTTXM);
    if (rc <= 0) {
        snprintf(soem_error_buf, sizeof(soem_error_buf),
                 "ec_mbxsend failed: rc=%d", rc);
        return false;
    }
    return true;
}

// ── recv_mailbox() ─────────────────────────────────────────────────────────────
bool EtherCATTransport::recv_mailbox(uint8_t *payload, uint16_t *len,
                                     int timeout_ms)
{
    if (!open_) return false;

    static uint8_t mbx_buf[MAILBOX_SIZE];
    memset(mbx_buf, 0, sizeof(mbx_buf));

    // Poll until timeout
    auto deadline = std::chrono::steady_clock::now() +
                    std::chrono::milliseconds(timeout_ms);

    while (std::chrono::steady_clock::now() < deadline) {
        int rc = ec_mbxreceive(slave_n_,
                               reinterpret_cast<ec_mbxbuft *>(mbx_buf),
                               0 /* non-blocking */);
        if (rc > 0) {
            const MbxHeader *hdr = reinterpret_cast<const MbxHeader *>(mbx_buf);
            uint16_t plen = hdr->length;
            if (plen > MAILBOX_SIZE - MAILBOX_HEADER)
                plen = MAILBOX_SIZE - MAILBOX_HEADER;
            memcpy(payload, mbx_buf + MAILBOX_HEADER, plen);
            *len = plen;
            return true;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    return false; // timeout
}

// ── write() ───────────────────────────────────────────────────────────────────
ssize_t EtherCATTransport::write(const uint8_t *buf, size_t len, int timeout_ms)
{
    if (!open_ || len == 0) return -1;
    if (len > MAILBOX_SIZE - MAILBOX_HEADER) {
        fprintf(stderr, "[ethercat_transport] write: payload too large (%zu)\n", len);
        return -1;
    }

    // Retry loop
    auto deadline = std::chrono::steady_clock::now() +
                    std::chrono::milliseconds(timeout_ms);
    do {
        if (send_mailbox(buf, static_cast<uint16_t>(len)))
            return static_cast<ssize_t>(len);
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    } while (std::chrono::steady_clock::now() < deadline);

    return -1;
}

// ── read() ────────────────────────────────────────────────────────────────────
ssize_t EtherCATTransport::read(uint8_t *buf, size_t max_len, int timeout_ms)
{
    if (!open_ || max_len == 0) return -1;

    uint16_t len = 0;
    if (!recv_mailbox(buf, &len, timeout_ms)) return 0; // timeout, not an error

    return static_cast<ssize_t>(len > max_len ? max_len : len);
}

// ── station_address() ─────────────────────────────────────────────────────────
uint16_t EtherCATTransport::station_address() const
{
    if (!open_ || slave_n_ < 1) return 0;
    return ec_slave[slave_n_].configadr;
}

// ── last_error() ──────────────────────────────────────────────────────────────
const char *EtherCATTransport::last_error() const
{
    return soem_error_buf;
}

} // namespace micro_ros_ethercat
