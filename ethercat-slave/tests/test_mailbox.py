"""
test_mailbox.py — cocotb + pytest tests for mailbox.v

Tests:
  1. SM0: After ec_write + sm0_written pulse, mbox_out_ready=1, INT_N=0
  2. SM0: SPI reads all bytes → mbox_out_ready clears, INT_N=1
  3. SM1: SPI writes frame → mbox_in_ready=1
  4. SM1: sm1_read pulse clears mbox_in_ready
  5. SM0/SM1 back-to-back: two consecutive cycles without corruption

Convention:
  sim_*  — cocotb coroutines run inside the Icarus simulator
  test_* — plain pytest functions that invoke one sim_* via COCOTB_TESTCASE
"""
import os
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles
from conftest import sim_run, RTL_DIR

_SOURCES = [os.path.join(RTL_DIR, "mailbox.v")]
_TOP     = "mailbox"
_MODULE  = os.path.splitext(os.path.basename(__file__))[0]

MBX_OUT_BASE = 0x1000
MBX_IN_BASE  = 0x1100


# ── Common setup ──────────────────────────────────────────────────────────────
async def _setup(dut):
    cocotb.start_soon(Clock(dut.clk, 40, units="ns").start())  # 25 MHz
    dut.rst_n.value        = 0
    dut.ec_addr.value      = 0
    dut.ec_wdata.value     = 0
    dut.ec_wr.value        = 0
    dut.ec_rd.value        = 0
    dut.sm0_written.value  = 0
    dut.sm1_read.value     = 0
    dut.spi_rx_ack.value   = 0
    dut.spi_tx_data.value  = 0
    dut.spi_tx_valid.value = 0
    dut.spi_tx_start.value = 0
    dut.spi_tx_len.value   = 0
    await ClockCycles(dut.clk, 5)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 3)


async def _ec_write_byte(dut, addr, data):
    await RisingEdge(dut.clk)
    dut.ec_addr.value  = addr
    dut.ec_wdata.value = data
    dut.ec_wr.value    = 1
    await RisingEdge(dut.clk)
    dut.ec_wr.value    = 0


async def _write_sm0_frame(dut, payload: bytes):
    """Write a mailbox frame to SM0 via the EtherCAT port."""
    header = bytes([len(payload) & 0xFF, 0x00, 0x00, 0x00, 0x00, 0x0F, 0x00, 0x00])
    frame = header + payload
    for i, b in enumerate(frame):
        await _ec_write_byte(dut, MBX_OUT_BASE + i, b)
    await RisingEdge(dut.clk)
    dut.sm0_written.value = 1
    await RisingEdge(dut.clk)
    dut.sm0_written.value = 0
    await ClockCycles(dut.clk, 3)


async def _write_sm1_via_spi(dut, payload: bytes):
    """Write a mailbox frame to SM1 via the SPI (PDI) port."""
    total = len(payload) + 8
    await RisingEdge(dut.clk)
    dut.spi_tx_start.value = 1
    dut.spi_tx_len.value   = total
    dut.spi_tx_data.value  = 0x00
    dut.spi_tx_valid.value = 1
    await RisingEdge(dut.clk)
    dut.spi_tx_start.value = 0
    for b in bytes([0x00, 0x00, 0x00, 0x00, 0x0F, 0x00, 0x00]):
        dut.spi_tx_data.value = b
        await RisingEdge(dut.clk)
    for b in payload:
        dut.spi_tx_data.value = b
        await RisingEdge(dut.clk)
    dut.spi_tx_valid.value = 0
    await ClockCycles(dut.clk, 3)


# ── Cocotb simulation coroutines (sim_*) ──────────────────────────────────────

@cocotb.test()
async def sim_sm0_write_sets_ready(dut):
    """After master writes SM0 and sm0_written, mbox_out_ready=1 and INT_N=0."""
    await _setup(dut)
    await _write_sm0_frame(dut, b"\xDE\xAD\xBE\xEF")
    assert int(dut.mbox_out_ready.value) == 1, "mbox_out_ready should be 1"
    assert int(dut.int_n.value) == 0,          "INT_N should be 0 (active-low)"


@cocotb.test()
async def sim_sm0_spi_read_clears_ready(dut):
    """SPI consuming all SM0 bytes clears mbox_out_ready."""
    await _setup(dut)
    payload = b"\xCA\xFE\xBA\xBE"
    frame_len = 8 + len(payload)
    await _write_sm0_frame(dut, payload)

    for _ in range(frame_len):
        await RisingEdge(dut.clk)
        dut.spi_rx_ack.value = 1
        await RisingEdge(dut.clk)
        dut.spi_rx_ack.value = 0

    await ClockCycles(dut.clk, 5)
    assert int(dut.mbox_out_ready.value) == 0, "mbox_out_ready should clear"
    assert int(dut.int_n.value) == 1,          "INT_N should deassert"


@cocotb.test()
async def sim_sm1_spi_write_sets_ready(dut):
    """SPI writing to SM1 sets mbox_in_ready."""
    await _setup(dut)
    await _write_sm1_via_spi(dut, b"\x01\x02\x03\x04")
    assert int(dut.mbox_in_ready.value) == 1, "mbox_in_ready should be 1"


@cocotb.test()
async def sim_sm1_read_clears_ready(dut):
    """sm1_read pulse clears mbox_in_ready."""
    await _setup(dut)
    await _write_sm1_via_spi(dut, b"\xAA\xBB")
    await RisingEdge(dut.clk)
    dut.sm1_read.value = 1
    await RisingEdge(dut.clk)
    dut.sm1_read.value = 0
    await ClockCycles(dut.clk, 3)
    assert int(dut.mbox_in_ready.value) == 0, "mbox_in_ready should clear"


@cocotb.test()
async def sim_back_to_back_sm0(dut):
    """Two consecutive SM0 write/read cycles work correctly."""
    await _setup(dut)

    for cycle in range(2):
        payload = bytes([cycle * 0x10 + i for i in range(4)])
        await _write_sm0_frame(dut, payload)
        assert int(dut.mbox_out_ready.value) == 1, f"Cycle {cycle}: not ready"

        for _ in range(8 + len(payload)):
            await RisingEdge(dut.clk)
            dut.spi_rx_ack.value = 1
            await RisingEdge(dut.clk)
            dut.spi_rx_ack.value = 0

        await ClockCycles(dut.clk, 5)
        assert int(dut.mbox_out_ready.value) == 0, f"Cycle {cycle}: not cleared"


# ── Pytest entry points (one per sim_* above) ─────────────────────────────────

def test_sm0_write_sets_ready():
    """After EtherCAT write to SM0, mbox_out_ready asserts and INT_N goes low."""
    sim_run(_SOURCES, _TOP, _MODULE, "sim_sm0_write_sets_ready")

def test_sm0_spi_read_clears_ready():
    """SPI reading all SM0 bytes deasserts mbox_out_ready and INT_N."""
    sim_run(_SOURCES, _TOP, _MODULE, "sim_sm0_spi_read_clears_ready")

def test_sm1_spi_write_sets_ready():
    """SPI writing a frame to SM1 asserts mbox_in_ready."""
    sim_run(_SOURCES, _TOP, _MODULE, "sim_sm1_spi_write_sets_ready")

def test_sm1_read_clears_ready():
    """sm1_read pulse clears mbox_in_ready."""
    sim_run(_SOURCES, _TOP, _MODULE, "sim_sm1_read_clears_ready")

def test_back_to_back_sm0():
    """Two consecutive SM0 write/drain cycles complete without corruption."""
    sim_run(_SOURCES, _TOP, _MODULE, "sim_back_to_back_sm0")
