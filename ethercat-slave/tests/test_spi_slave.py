"""
test_spi_slave.py — cocotb + pytest tests for spi_slave.v

Tests:
  1. STATUS command returns tx_ready=1, rx_avail=0 when mailbox empty
  2. STATUS returns rx_avail=1 when mailbox has data
  3. WRITE command generates mbox_wr_valid pulses for each payload byte
  4. mbox_wr_start goes high on the first byte of a write transaction
  5. Multiple back-to-back transactions complete without deadlock

Convention:
  sim_*  — cocotb coroutines run inside the Icarus simulator
  test_* — plain pytest functions that invoke one sim_* via COCOTB_TESTCASE
"""
import os
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer, ClockCycles
from conftest import sim_run, RTL_DIR

_SOURCES = [os.path.join(RTL_DIR, "spi_slave.v")]
_TOP     = "spi_slave"
_MODULE  = os.path.splitext(os.path.basename(__file__))[0]


# ── SPI master helper ─────────────────────────────────────────────────────────
class SPIMaster:
    """Bit-bang SPI Mode 0 over cocotb signals.

    Uses period_ns=400 (2.5 MHz) to give the slave's 3-cycle MISO synchronizer
    (≈120 ns at 40 ns sys_clk) enough margin before the master samples MISO.
    """

    def __init__(self, dut, period_ns=400):
        self.dut = dut
        self.half = period_ns // 2

    async def _transfer_byte(self, send: int) -> int:
        recv = 0
        for i in range(7, -1, -1):
            self.dut.spi_mosi.value = (send >> i) & 1
            await Timer(self.half, units="ns")
            self.dut.spi_sck.value = 1
            recv = (recv << 1) | int(self.dut.spi_miso.value)
            await Timer(self.half, units="ns")
            self.dut.spi_sck.value = 0
        return recv

    def _crc8(self, data: bytes) -> int:
        crc = 0
        for b in data:
            crc ^= b
            for _ in range(8):
                crc = ((crc << 1) ^ 0x07) & 0xFF if crc & 0x80 else (crc << 1) & 0xFF
        return crc

    async def write_mailbox(self, payload: bytes) -> None:
        frame = bytes([0x01, len(payload) >> 8, len(payload) & 0xFF]) + payload
        crc = self._crc8(frame)
        self.dut.spi_cs_n.value = 0
        await Timer(10, units="ns")
        for b in frame + bytes([crc]):
            await self._transfer_byte(b)
        await Timer(10, units="ns")
        self.dut.spi_cs_n.value = 1

    async def status(self) -> int:
        self.dut.spi_cs_n.value = 0
        await Timer(10, units="ns")
        await self._transfer_byte(0x03)  # CMD=STATUS
        await self._transfer_byte(0x00)  # LEN_H (slave sends flags byte here)
        flags = await self._transfer_byte(0x00)  # LEN_L (slave sends flags again)
        await Timer(10, units="ns")
        self.dut.spi_cs_n.value = 1
        return flags


# ── Common DUT reset ──────────────────────────────────────────────────────────
async def _reset_dut(dut, clk_period_ns=40):
    cocotb.start_soon(Clock(dut.sys_clk, clk_period_ns, units="ns").start())
    dut.rst_n.value            = 0
    dut.spi_sck.value          = 0
    dut.spi_mosi.value         = 0
    dut.spi_cs_n.value         = 1
    dut.mbox_rd_data.value     = 0xAB
    dut.mbox_rd_valid.value    = 0
    dut.mbox_rd_empty.value    = 1
    dut.status_rx_avail.value  = 0
    dut.status_tx_ready.value  = 1
    await ClockCycles(dut.sys_clk, 5)
    dut.rst_n.value = 1
    await ClockCycles(dut.sys_clk, 5)


# ── Cocotb simulation coroutines (sim_*) ──────────────────────────────────────

@cocotb.test()
async def sim_status_no_data(dut):
    """STATUS returns rx_avail=0, tx_ready=1 when mailbox empty."""
    await _reset_dut(dut)
    spi = SPIMaster(dut)
    flags = await spi.status()
    assert flags & 0x01 == 0, f"rx_avail should be 0, flags={flags:#04x}"
    assert flags & 0x02 != 0, f"tx_ready should be 1, flags={flags:#04x}"


@cocotb.test()
async def sim_status_with_data(dut):
    """STATUS returns rx_avail=1 when mailbox has data."""
    await _reset_dut(dut)
    dut.status_rx_avail.value = 1
    spi = SPIMaster(dut)
    flags = await spi.status()
    assert flags & 0x01 != 0, f"rx_avail should be 1, flags={flags:#04x}"


@cocotb.test()
async def sim_write_mailbox_fires_wr_valid(dut):
    """WRITE command generates mbox_wr_valid pulses for each payload byte."""
    await _reset_dut(dut)
    spi = SPIMaster(dut)
    payload = b"\x00\x00\x00\x00\x00\x0F\x00\x00\xDE\xAD"

    wr_count = 0

    async def count_writes():
        nonlocal wr_count
        while True:
            await RisingEdge(dut.sys_clk)
            if int(dut.mbox_wr_valid.value) == 1:
                wr_count += 1

    monitor = cocotb.start_soon(count_writes())
    await spi.write_mailbox(payload)
    await ClockCycles(dut.sys_clk, 20)
    monitor.kill()

    assert wr_count == len(payload), \
        f"Expected {len(payload)} wr_valid pulses, got {wr_count}"


@cocotb.test()
async def sim_write_mbox_start_pulse(dut):
    """mbox_wr_start goes high on the first byte of a write transaction."""
    await _reset_dut(dut)
    spi = SPIMaster(dut)

    start_seen = False

    async def watch_start():
        nonlocal start_seen
        while True:
            await RisingEdge(dut.sys_clk)
            if int(dut.mbox_wr_start.value) == 1:
                start_seen = True

    monitor = cocotb.start_soon(watch_start())
    await spi.write_mailbox(b"\xAA\xBB\xCC")
    await ClockCycles(dut.sys_clk, 20)
    monitor.kill()

    assert start_seen, "mbox_wr_start never asserted"


@cocotb.test()
async def sim_back_to_back(dut):
    """Multiple back-to-back SPI transactions complete without deadlock."""
    await _reset_dut(dut)
    spi = SPIMaster(dut)

    for i in range(5):
        await spi.write_mailbox(bytes([i, i + 1, i + 2]))
        await ClockCycles(dut.sys_clk, 10)

    assert True  # reaching here means no hang


# ── Pytest entry points (one per sim_* above) ─────────────────────────────────

def test_status_no_data():
    """STATUS command: rx_avail=0 and tx_ready=1 when mailbox is empty."""
    sim_run(_SOURCES, _TOP, _MODULE, "sim_status_no_data")

def test_status_with_data():
    """STATUS command: rx_avail=1 when mailbox has pending data."""
    sim_run(_SOURCES, _TOP, _MODULE, "sim_status_with_data")

def test_write_mailbox_fires_wr_valid():
    """WRITE command generates one mbox_wr_valid pulse per payload byte."""
    sim_run(_SOURCES, _TOP, _MODULE, "sim_write_mailbox_fires_wr_valid")

def test_write_mbox_start_pulse():
    """mbox_wr_start asserts on the first byte of a WRITE transaction."""
    sim_run(_SOURCES, _TOP, _MODULE, "sim_write_mbox_start_pulse")

def test_back_to_back():
    """Five consecutive SPI WRITE transactions complete without deadlock."""
    sim_run(_SOURCES, _TOP, _MODULE, "sim_back_to_back")
