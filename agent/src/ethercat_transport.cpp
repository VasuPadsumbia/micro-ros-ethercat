/**
 * ethercat_transport.cpp — EtherCAT transport using SOEM context-based API
 */
#include "ethercat_transport.h"

#include <cstring>
#include <cstdio>
#include <chrono>
#include <thread>

namespace micro_ros_ethercat {

static char soem_error_buf[512] = "none";

// ── Constructor ───────────────────────────────────────────────────────────────
EtherCATTransport::EtherCATTransport(const std::string &iface, int slave_n)
    : iface_(iface), slave_n_(slave_n), open_(false)
{
    // The modern ecx_contextt embeds all arrays directly in the struct.
    // Zero-initialise the whole context; ecx_init() will populate it.
    memset(&ctx_,   0, sizeof(ctx_));
    memset(iobuf_,  0, sizeof(iobuf_));
}

EtherCATTransport::~EtherCATTransport()
{
    if (open_) close();
}

// ── open() ────────────────────────────────────────────────────────────────────
bool EtherCATTransport::open()
{
    if (!ecx_init(&ctx_, iface_.c_str())) {
        snprintf(soem_error_buf, sizeof(soem_error_buf),
                 "ecx_init('%s') failed — check interface name and permissions",
                 iface_.c_str());
        fprintf(stderr, "[ethercat_transport] %s\n", soem_error_buf);
        return false;
    }

    int found = ecx_config_init(&ctx_);
    if (found <= 0) {
        snprintf(soem_error_buf, sizeof(soem_error_buf),
                 "No EtherCAT slaves found on %s", iface_.c_str());
        fprintf(stderr, "[ethercat_transport] %s\n", soem_error_buf);
        ecx_close(&ctx_);
        return false;
    }

    printf("[ethercat_transport] Found %d slave(s) on %s\n", found, iface_.c_str());

    if (slave_n_ > found) {
        snprintf(soem_error_buf, sizeof(soem_error_buf),
                 "Slave %d requested but only %d found", slave_n_, found);
        ecx_close(&ctx_);
        return false;
    }

    printf("[ethercat_transport] Slave %d: '%s'  VendorID=0x%08X  Product=0x%08X\n",
           slave_n_,
           ctx_.slavelist[slave_n_].name,
           (unsigned)ctx_.slavelist[slave_n_].eep_id,
           (unsigned)ctx_.slavelist[slave_n_].eep_man);

    ecx_config_map_group(&ctx_, iobuf_, 0);
    ecx_configdc(&ctx_);

    ctx_.slavelist[0].state = EC_STATE_PRE_OP;
    ecx_writestate(&ctx_, 0);
    ecx_statecheck(&ctx_, 0, EC_STATE_PRE_OP, EC_TIMEOUTSTATE);

    if (ctx_.slavelist[0].state != EC_STATE_PRE_OP) {
        snprintf(soem_error_buf, sizeof(soem_error_buf),
                 "Could not reach PRE-OP (state=0x%02X)", ctx_.slavelist[0].state);
        ecx_close(&ctx_);
        return false;
    }

    printf("[ethercat_transport] Slave in PRE-OP\n");
    open_ = true;
    return true;
}

// ── close() ───────────────────────────────────────────────────────────────────
void EtherCATTransport::close()
{
    if (!open_) return;
    ctx_.slavelist[0].state = EC_STATE_INIT;
    ecx_writestate(&ctx_, 0);
    ecx_close(&ctx_);
    open_ = false;
    printf("[ethercat_transport] Closed\n");
}

// ── send_mailbox() ─────────────────────────────────────────────────────────────
bool EtherCATTransport::send_mailbox(const uint8_t *payload, uint16_t len)
{
    if (len + MAILBOX_HEADER > MAILBOX_SIZE) return false;

    static ec_mbxbuft mbx;
    memset(&mbx, 0, sizeof(mbx));

    MbxHeader *hdr = reinterpret_cast<MbxHeader *>(&mbx);
    hdr->length   = len;
    hdr->address  = 0;
    hdr->channel  = 0;
    hdr->type     = VOE_TYPE;
    hdr->reserved = 0;
    memcpy(reinterpret_cast<uint8_t *>(&mbx) + MAILBOX_HEADER, payload, len);

    int rc = ecx_mbxsend(&ctx_, slave_n_, &mbx, EC_TIMEOUTTXM);
    if (rc <= 0) {
        snprintf(soem_error_buf, sizeof(soem_error_buf),
                 "ecx_mbxsend failed: rc=%d", rc);
        return false;
    }
    return true;
}

// ── recv_mailbox() ─────────────────────────────────────────────────────────────
bool EtherCATTransport::recv_mailbox(uint8_t *payload, uint16_t *len, int timeout_ms)
{
    ec_mbxbuft *mbx_ptr = nullptr;
    auto deadline = std::chrono::steady_clock::now() +
                    std::chrono::milliseconds(timeout_ms);

    while (std::chrono::steady_clock::now() < deadline) {
        int rc = ecx_mbxreceive(&ctx_, slave_n_, &mbx_ptr, 0);
        if (rc > 0 && mbx_ptr) {
            const MbxHeader *hdr = reinterpret_cast<const MbxHeader *>(mbx_ptr);
            uint16_t plen = hdr->length;
            if (plen > MAILBOX_SIZE - MAILBOX_HEADER)
                plen = MAILBOX_SIZE - MAILBOX_HEADER;
            memcpy(payload,
                   reinterpret_cast<const uint8_t *>(mbx_ptr) + MAILBOX_HEADER,
                   plen);
            *len = plen;
            return true;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    return false;
}

// ── write() / read() ──────────────────────────────────────────────────────────
ssize_t EtherCATTransport::write(const uint8_t *buf, size_t len, int timeout_ms)
{
    if (!open_ || !buf || len == 0) return -1;
    if (len > MAILBOX_SIZE - MAILBOX_HEADER) return -1;

    auto deadline = std::chrono::steady_clock::now() +
                    std::chrono::milliseconds(timeout_ms);
    do {
        if (send_mailbox(buf, static_cast<uint16_t>(len)))
            return static_cast<ssize_t>(len);
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    } while (std::chrono::steady_clock::now() < deadline);
    return -1;
}

ssize_t EtherCATTransport::read(uint8_t *buf, size_t max_len, int timeout_ms)
{
    if (!open_ || !buf || max_len == 0) return -1;
    uint16_t len = 0;
    if (!recv_mailbox(buf, &len, timeout_ms)) return 0;
    return static_cast<ssize_t>(len > max_len ? max_len : len);
}

uint16_t EtherCATTransport::station_address() const
{
    if (!open_ || slave_n_ < 1) return 0;
    return ctx_.slavelist[slave_n_].configadr;
}

const char *EtherCATTransport::last_error() const
{
    return soem_error_buf;
}

} // namespace micro_ros_ethercat
