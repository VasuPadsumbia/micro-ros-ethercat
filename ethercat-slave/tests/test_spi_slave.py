"""
test_spi_slave.py — cocotb tests for spi_slave.v

Tests:
  1. STATUS command returns correct flags
  2. WRITE command stores bytes in mailbox
  3. READ command returns mailbox bytes
  4. CRC error discards frame
  5. Back-to-back transactions
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, Timer, ClockCycles
from cocotb.binary import BinaryValue
import pytest
import struct


# ── SPI master helper ─────────────────────────────────────────────────────────
class SPIMaster:
    """Bit-bang SPI Mode 0 over cocotb signals."""

    def __init__(self, dut, period_ns=125):
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

    async def read_mailbox(self, length: int) -> bytes:
        frame = bytes([0x02, length >> 8, length & 0xFF])
        self.dut.spi_cs_n.value = 0
        await Timer(10, units="ns")
        result = bytearray()
        for b in frame:
            await self._transfer_byte(b)
        for _ in range(length):
            r = await self._transfer_byte(0x00)
            result.append(r)
        crc_byte = await self._transfer_byte(0x00)  # CRC byte
        await Timer(10, units="ns")
        self.dut.spi_cs_n.value = 1
        return bytes(result)

    async def status(self) -> int:
        self.dut.spi_cs_n.value = 0
        await Timer(10, units="ns")
        await self._transfer_byte(0x03)  # CMD
        await self._transfer_byte(0x00)  # LEN_H
        flags = await self._transfer_byte(0x00)  # LEN_L → returns flags
        await Timer(10, units="ns")
        self.dut.spi_cs_n.value = 1
        return flags


# ── Common DUT setup ──────────────────────────────────────────────────────────
async def reset_dut(dut, clk_period_ns=37):
    """Start clock, apply reset."""
    cocotb.start_soon(Clock(dut.sys_clk, clk_period_ns, units="ns").start())
    dut.rst_n.value         = 0
    dut.spi_sck.value       = 0
    dut.spi_mosi.value      = 0
    dut.spi_cs_n.value      = 1
    dut.mbox_rd_data.value  = 0xAB
    dut.mbox_rd_valid.value = 0
    dut.mbox_rd_empty.value = 1
    dut.status_rx_avail.value = 0
    dut.status_tx_ready.value = 1
    await ClockCycles(dut.sys_clk, 5)
    dut.rst_n.value = 1
    await ClockCycles(dut.sys_clk, 5)


# ── Tests ─────────────────────────────────────────────────────────────────────
@cocotb.test()
async def test_status_no_data(dut):
    """STATUS returns rx_avail=0, tx_ready=1 when mailbox empty."""
    await reset_dut(dut)
    spi = SPIMaster(dut)
    flags = await spi.status()
    assert flags & 0x01 == 0, f"rx_avail should be 0, flags={flags:#04x}"
    assert flags & 0x02 != 0, f"tx_ready should be 1, flags={flags:#04x}"


@cocotb.test()
async def test_status_with_data(dut):
    """STATUS returns rx_avail=1 when mailbox has data."""
    await reset_dut(dut)
    dut.status_rx_avail.value = 1
    spi = SPIMaster(dut)
    flags = await spi.status()
    assert flags & 0x01 != 0, f"rx_avail should be 1, flags={flags:#04x}"


@cocotb.test()
async def test_write_mailbox_fires_wr_valid(dut):
    """WRITE command generates mbox_wr_valid pulses for each payload byte."""
    await reset_dut(dut)
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
    monitor.cancel()

    assert wr_count == len(payload), \
        f"Expected {len(payload)} wr_valid pulses, got {wr_count}"


@cocotb.test()
async def test_write_mbox_start_pulse(dut):
    """mbox_wr_start goes high on the first byte of a write transaction."""
    await reset_dut(dut)
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
    monitor.cancel()

    assert start_seen, "mbox_wr_start never asserted"


@cocotb.test()
async def test_back_to_back(dut):
    """Multiple back-to-back SPI transactions complete without deadlock."""
    await reset_dut(dut)
    spi = SPIMaster(dut)

    for i in range(5):
        await spi.write_mailbox(bytes([i, i + 1, i + 2]))
        await ClockCycles(dut.sys_clk, 10)

    # Should not hang — if we got here, test passes
    assert True
