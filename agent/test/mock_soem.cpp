/**
 * mock_soem.cpp — SOEM mock implementations compiled into the test target.
 *
 * All ecx_* functions are defined here with extern "C" so they satisfy
 * the C-linkage declarations in ec_main.h without linking libsoem.
 */
#include "mock_soem.h"
#include <cstring>

// ── Mock state storage ────────────────────────────────────────────────────────
bool    mock_ec_init_ok       = true;
int     mock_ec_slaves_found  = 1;
uint8_t mock_mbx_recv_buf[EC_MAXMBX] = {};
int     mock_mbx_recv_len     = 0;
uint8_t mock_mbx_sent_buf[EC_MAXMBX] = {};
int     mock_mbx_sent_len     = 0;
int     mock_mbx_recv_calls   = 0;
int     mock_mbx_send_calls   = 0;

static ec_mbxbuft mock_mbx_buf;

// ── SOEM mock implementations (C linkage) ────────────────────────────────────
extern "C" {

int ecx_init(ecx_contextt *ctx, const char *)
{
    if (!mock_ec_init_ok) return 0;
    ctx->slavecount = mock_ec_slaves_found;
    if (mock_ec_slaves_found >= 1) {
        memset(&ctx->slavelist[1], 0, sizeof(ctx->slavelist[1]));
        strncpy(ctx->slavelist[1].name, "mock_slave",
                sizeof(ctx->slavelist[1].name) - 1);
        ctx->slavelist[1].eep_id    = 0x0059414D;
        ctx->slavelist[1].eep_man   = 0x00000001;
        ctx->slavelist[1].configadr = 0x0001;
        ctx->slavelist[1].state     = EC_STATE_PRE_OP;
        ctx->slavelist[0].state     = EC_STATE_PRE_OP;
    }
    return 1;
}

int ecx_config_init(ecx_contextt *ctx)
{
    return ctx->slavecount;
}

int ecx_config_map_group(ecx_contextt *, void *, uint8_t) { return 0; }
boolean ecx_configdc(ecx_contextt *)       { return 0; }
int ecx_writestate(ecx_contextt *, uint16_t) { return 0; }
void ecx_close(ecx_contextt *)             {}

uint16_t ecx_statecheck(ecx_contextt *ctx, uint16_t slave,
                        uint16_t reqstate, int)
{
    ctx->slavelist[slave].state = reqstate;
    return reqstate;
}

int ecx_mbxsend(ecx_contextt *, uint16_t, ec_mbxbuft *mbx, int)
{
    mock_mbx_send_calls++;
    memcpy(mock_mbx_sent_buf, mbx, sizeof(mock_mbx_sent_buf));
    mock_mbx_sent_len = (int)sizeof(mock_mbx_sent_buf);
    return 8;
}

int ecx_mbxreceive(ecx_contextt *, uint16_t, ec_mbxbuft **mbx_out, int)
{
    mock_mbx_recv_calls++;
    if (mock_mbx_recv_len > 0) {
        memcpy(&mock_mbx_buf, mock_mbx_recv_buf,
               static_cast<size_t>(mock_mbx_recv_len));
        *mbx_out          = &mock_mbx_buf;
        mock_mbx_recv_len = 0;
        return 8;
    }
    *mbx_out = nullptr;
    return 0;
}

} // extern "C"
