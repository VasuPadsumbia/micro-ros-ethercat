/**
 * mock_soem.h — Mock SOEM functions for unit testing EtherCATTransport
 *
 * Replaces real SOEM with in-memory implementations so tests can run
 * without a real EtherCAT interface or slave hardware.
 *
 * Include this header BEFORE ethercat_transport.h in test files.
 */
#pragma once

#include <cstdint>
#include <cstring>
#include <cstdio>

// ── SOEM type and constant stubs ─────────────────────────────────────────────
#define EC_STATE_INIT    0x01
#define EC_STATE_PRE_OP  0x02
#define EC_STATE_SAFE_OP 0x04
#define EC_STATE_OP      0x08

#define EC_TIMEOUTSTATE  2000000
#define EC_TIMEOUTTXM    20000
#define FALSE 0

typedef uint8_t ec_mbxbuft[1024];

struct ec_slave_t {
    char     name[64];
    uint32_t eep_id;
    uint32_t eep_man;
    uint16_t configadr;
    uint16_t state;
};

// Global slave array (SOEM convention: index 0 = all slaves, 1..n = individual)
static ec_slave_t ec_slave[16];
static int        ec_slavecount = 0;
static char       ec_iobuf[4096];

// ── Mock state ────────────────────────────────────────────────────────────────
static bool       mock_ec_init_ok        = true;
static int        mock_ec_slaves_found   = 1;
static uint8_t    mock_mbx_recv_buf[256] = {};
static int        mock_mbx_recv_len      = 0;
static uint8_t    mock_mbx_sent_buf[256] = {};
static int        mock_mbx_sent_len      = 0;
static int        mock_mbx_recv_calls    = 0;
static int        mock_mbx_send_calls    = 0;

inline void mock_soem_reset()
{
    mock_ec_init_ok      = true;
    mock_ec_slaves_found = 1;
    mock_mbx_recv_len    = 0;
    mock_mbx_sent_len    = 0;
    mock_mbx_recv_calls  = 0;
    mock_mbx_send_calls  = 0;
    memset(ec_slave, 0, sizeof(ec_slave));
    ec_slave[1].state    = EC_STATE_PRE_OP;
    ec_slave[1].configadr= 0x0001;
    strncpy(ec_slave[1].name, "mock_slave", sizeof(ec_slave[1].name));
    ec_slave[1].eep_id   = 0x0059414D;
    ec_slave[1].eep_man  = 0x00000001;
}

/** Queue a mailbox frame to be returned on the next ec_mbxreceive() call. */
inline void mock_soem_queue_recv(const uint8_t *data, int len)
{
    if (len > (int)sizeof(mock_mbx_recv_buf)) len = sizeof(mock_mbx_recv_buf);
    memcpy(mock_mbx_recv_buf, data, len);
    mock_mbx_recv_len = len;
}

// ── Mock SOEM function implementations ───────────────────────────────────────
extern "C" {

inline int ec_init(const char * /*ifname*/)
{
    return mock_ec_init_ok ? 1 : 0;
}

inline int ec_config_init(int /*usetable*/)
{
    ec_slavecount = mock_ec_slaves_found;
    return ec_slavecount;
}

inline int ec_config_map(void * /*pIOmap*/) { return 0; }
inline int ec_configdc(void)               { return 0; }

inline int ec_writestate(uint16_t /*slave*/) { return 0; }

inline uint16_t ec_statecheck(uint16_t slave, uint16_t reqstate, int /*timeout*/)
{
    ec_slave[slave].state = reqstate;
    return reqstate;
}

inline void ec_close(void) {}

inline int ec_mbxsend(uint16_t /*slave*/, ec_mbxbuft *mbx, int /*timeout*/)
{
    mock_mbx_send_calls++;
    // Record what was sent
    memcpy(mock_mbx_sent_buf, mbx, sizeof(mock_mbx_sent_buf));
    mock_mbx_sent_len = sizeof(mock_mbx_sent_buf);
    return 8; // success: return number of bytes
}

inline int ec_mbxreceive(uint16_t /*slave*/, ec_mbxbuft *mbx, int /*timeout*/)
{
    mock_mbx_recv_calls++;
    if (mock_mbx_recv_len > 0) {
        memcpy(mbx, mock_mbx_recv_buf, mock_mbx_recv_len);
        int ret = mock_mbx_recv_len;
        mock_mbx_recv_len = 0; // consume
        return ret;
    }
    return 0; // nothing available
}

} // extern "C"
