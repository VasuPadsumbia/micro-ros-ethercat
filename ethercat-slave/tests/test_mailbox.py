"""
test_mailbox.py — cocotb tests for mailbox.v

Tests:
  1. SM0: After ec_write + sm0_written pulse, mbox_out_ready=1, INT_N=0
  2. SM0: SPI reads all bytes → mbox_out_ready clears, INT_N=1
  3. SM1: SPI writes frame → mbox_in_ready=1
  4. SM1: sm1_read pulse clears mbox_in_ready
  5. SM0/SM1 back-to-back: two consecutive cycles without corruption
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles


MBX_OUT_BASE = 0x1000
MBX_IN_BASE  = 0x1100


async def setup(dut):
    cocotb.start_soon(Clock(dut.clk, 37, units="ns").start())
    dut.rst_n.value       = 0
    dut.ec_addr.value     = 0
    dut.ec_wdata.value    = 0
    dut.ec_wr.value       = 0
    dut.ec_rd.value       = 0
    dut.sm0_written.value = 0
    dut.sm1_read.value    = 0
    dut.spi_rx_ack.value  = 0
    dut.spi_tx_data.value = 0
    dut.spi_tx_valid.value= 0
    dut.spi_tx_start.value= 0
    dut.spi_tx_len.value  = 0
    await ClockCycles(dut.clk, 5)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 3)


async def ec_write_byte(dut, addr, data):
    await RisingEdge(dut.clk)
    dut.ec_addr.value  = addr
    dut.ec_wdata.value = data
    dut.ec_wr.value    = 1
    await RisingEdge(dut.clk)
    dut.ec_wr.value    = 0


async def write_sm0_frame(dut, payload: bytes):
    """Write a mailbox frame to SM0 via the EtherCAT port."""
    # Header: length=payload_len (lo), 0 (hi), addr=0, ch=0, type=VoE=0x0F, rsv
    header = bytes([len(payload) & 0xFF, 0x00, 0x00, 0x00, 0x00, 0x0F, 0x00, 0x00])
    frame = header + payload
    for i, b in enumerate(frame):
        await ec_write_byte(dut, MBX_OUT_BASE + i, b)
    # Signal frame complete
    await RisingEdge(dut.clk)
    dut.sm0_written.value = 1
    await RisingEdge(dut.clk)
    dut.sm0_written.value = 0
    await ClockCycles(dut.clk, 3)


async def write_sm1_via_spi(dut, payload: bytes):
    """Write a mailbox frame to SM1 via the SPI (PDI) port."""
    total = len(payload) + 8  # +8 for header
    await RisingEdge(dut.clk)
    dut.spi_tx_start.value = 1
    dut.spi_tx_len.value   = total
    dut.spi_tx_data.value  = 0x00  # header byte 0 (len lo placeholder)
    dut.spi_tx_valid.value = 1
    await RisingEdge(dut.clk)
    dut.spi_tx_start.value = 0
    # Write remaining header bytes
    header_rest = bytes([0x00, 0x00, 0x00, 0x00, 0x0F, 0x00, 0x00])
    for b in header_rest:
        dut.spi_tx_data.value = b
        await RisingEdge(dut.clk)
    # Write payload
    for b in payload:
        dut.spi_tx_data.value = b
        await RisingEdge(dut.clk)
    dut.spi_tx_valid.value = 0
    await ClockCycles(dut.clk, 3)


# ── Tests ─────────────────────────────────────────────────────────────────────

@cocotb.test()
async def test_sm0_write_sets_ready(dut):
    """After master writes SM0 and sm0_written, mbox_out_ready=1 and INT_N=0."""
    await setup(dut)
    await write_sm0_frame(dut, b"\xDE\xAD\xBE\xEF")
    assert int(dut.mbox_out_ready.value) == 1, "mbox_out_ready should be 1"
    assert int(dut.int_n.value) == 0,          "INT_N should be 0 (active-low)"


@cocotb.test()
async def test_sm0_spi_read_clears_ready(dut):
    """SPI consuming all SM0 bytes clears mbox_out_ready."""
    await setup(dut)
    payload = b"\xCA\xFE\xBA\xBE"
    frame_len = 8 + len(payload)  # 8-byte header
    await write_sm0_frame(dut, payload)

    # ACK all bytes
    for _ in range(frame_len):
        await RisingEdge(dut.clk)
        dut.spi_rx_ack.value = 1
        await RisingEdge(dut.clk)
        dut.spi_rx_ack.value = 0

    await ClockCycles(dut.clk, 5)
    assert int(dut.mbox_out_ready.value) == 0, "mbox_out_ready should clear"
    assert int(dut.int_n.value) == 1,          "INT_N should deassert"


@cocotb.test()
async def test_sm1_spi_write_sets_ready(dut):
    """SPI writing to SM1 sets mbox_in_ready."""
    await setup(dut)
    await write_sm1_via_spi(dut, b"\x01\x02\x03\x04")
    assert int(dut.mbox_in_ready.value) == 1, "mbox_in_ready should be 1"


@cocotb.test()
async def test_sm1_read_clears_ready(dut):
    """sm1_read pulse clears mbox_in_ready."""
    await setup(dut)
    await write_sm1_via_spi(dut, b"\xAA\xBB")
    await RisingEdge(dut.clk)
    dut.sm1_read.value = 1
    await RisingEdge(dut.clk)
    dut.sm1_read.value = 0
    await ClockCycles(dut.clk, 3)
    assert int(dut.mbox_in_ready.value) == 0, "mbox_in_ready should clear"


@cocotb.test()
async def test_back_to_back_sm0(dut):
    """Two consecutive SM0 write/read cycles work correctly."""
    await setup(dut)

    for cycle in range(2):
        payload = bytes([cycle * 0x10 + i for i in range(4)])
        await write_sm0_frame(dut, payload)
        assert int(dut.mbox_out_ready.value) == 1, f"Cycle {cycle}: not ready"

        # Drain
        for _ in range(8 + len(payload)):
            await RisingEdge(dut.clk)
            dut.spi_rx_ack.value = 1
            await RisingEdge(dut.clk)
            dut.spi_rx_ack.value = 0

        await ClockCycles(dut.clk, 5)
        assert int(dut.mbox_out_ready.value) == 0, f"Cycle {cycle}: not cleared"
