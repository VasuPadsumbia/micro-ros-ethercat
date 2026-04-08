/**
 * mock_soem.h — Mock SOEM state declarations for unit tests
 *
 * Implementations live in mock_soem.cpp (compiled into the test target).
 * Include this header BEFORE ethercat_transport.h in test files.
 */
#pragma once

#include <cstring>
#include "soem/ec_type.h"
#include "nicdrv.h"        // defines ecx_portt (Linux oshw)
#include "soem/ec_main.h"

// ── Mock state (defined in mock_soem.cpp) ─────────────────────────────────────
extern bool    mock_ec_init_ok;
extern int     mock_ec_slaves_found;
extern uint8_t mock_mbx_recv_buf[];
extern int     mock_mbx_recv_len;
extern uint8_t mock_mbx_sent_buf[];
extern int     mock_mbx_sent_len;
extern int     mock_mbx_recv_calls;
extern int     mock_mbx_send_calls;

// ── Helpers (inline, usable directly in test files) ───────────────────────────
inline void mock_soem_reset()
{
    mock_ec_init_ok      = true;
    mock_ec_slaves_found = 1;
    mock_mbx_recv_len    = 0;
    mock_mbx_sent_len    = 0;
    mock_mbx_recv_calls  = 0;
    mock_mbx_send_calls  = 0;
}

inline void mock_soem_queue_recv(const uint8_t *data, int len)
{
    extern uint8_t mock_mbx_recv_buf[];
    if (len > EC_MAXMBX) len = EC_MAXMBX;
    memcpy(mock_mbx_recv_buf, data, static_cast<size_t>(len));
    mock_mbx_recv_len = len;
}
