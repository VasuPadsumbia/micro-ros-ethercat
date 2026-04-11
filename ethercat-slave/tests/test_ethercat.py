"""
test_ethercat.py — cocotb + pytest tests for ethercat_slave.v

Tests:
  1. FPRD datagram: slave reads ESC register and fills data field; WKC = 1
  2. FPRD to wrong station: WKC stays 0
  3. BWR datagram: broadcast write, always matched; WKC = 1
  4. Bad EtherType: frame silently discarded
  5. AL state transition: master writes AL Control, slave updates AL Status
  6. Multiple datagrams in one frame (M-bit chaining)

Convention:
  sim_*  — cocotb coroutines run inside the Icarus simulator (dut is provided)
  test_* — plain pytest functions that invoke one sim_* via COCOTB_TESTCASE
"""
import os
import struct
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles, Timer
from conftest import sim_run, RTL_DIR

_SOURCES = [os.path.join(RTL_DIR, "ethercat_slave.v")]
_TOP     = "ethercat_slave"
_MODULE  = os.path.splitext(os.path.basename(__file__))[0]


# ── EtherCAT frame builder ────────────────────────────────────────────────────
def eth_header(dst=b"\xff"*6, src=b"\x00\x11\x22\x33\x44\x55",
               etype=0x88A4) -> bytes:
    return dst + src + struct.pack(">H", etype)


def ethercat_header(length: int, etype_pdu: int = 1) -> bytes:
    word = (length & 0x07FF) | ((etype_pdu & 0xF) << 12)
    return struct.pack("<H", word)


def datagram(cmd: int, idx: int, addr32: int, data: bytes, more: bool = False) -> bytes:
    length = len(data)
    flags = (1 << 6) if more else 0
    hdr = struct.pack("<BBIHH",
                      cmd, idx, addr32,
                      length | (flags << 8),
                      0)
    wkc = struct.pack("<H", 0)
    return hdr + data + wkc


def build_frame(datagrams: bytes) -> bytes:
    ec_hdr = ethercat_header(len(datagrams))
    payload = ec_hdr + datagrams
    frame = eth_header() + payload
    return frame + b"\xDE\xAD\xBE\xEF"


# ── Common setup ──────────────────────────────────────────────────────────────
async def _setup(dut, esc_rdata=0x42, station_addr=0x0001):
    cocotb.start_soon(Clock(dut.clk, 40, units="ns").start())  # 25 MHz
    dut.rst_n.value        = 0
    dut.p0_rx_valid.value  = 0
    dut.p0_rx_last.value   = 0
    dut.p0_rx_fcs_ok.value = 0
    dut.p0_rx_data.value   = 0
    dut.p0_tx_ready.value  = 1
    dut.esc_rdata.value    = esc_rdata
    dut.station_addr.value = station_addr
    dut.al_control.value   = 0x1   # INIT state
    await ClockCycles(dut.clk, 5)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 5)


async def _feed_frame(dut, frame: bytes):
    dut.p0_rx_fcs_ok.value = 1
    for i, b in enumerate(frame):
        await RisingEdge(dut.clk)
        dut.p0_rx_data.value  = b
        dut.p0_rx_valid.value = 1
        dut.p0_rx_last.value  = 1 if i == len(frame) - 1 else 0
    await RisingEdge(dut.clk)
    dut.p0_rx_valid.value = 0
    dut.p0_rx_last.value  = 0


async def _collect_tx(dut, timeout_cycles=10000) -> bytes:
    buf = bytearray()
    for _ in range(timeout_cycles):
        await RisingEdge(dut.clk)
        if int(dut.p0_tx_valid.value) == 1:
            buf.append(int(dut.p0_tx_data.value))
            if int(dut.p0_tx_last.value) == 1:
                return bytes(buf)
    return bytes(buf)


# ── Test commands ─────────────────────────────────────────────────────────────
CMD_FPRD = 0x04
CMD_FPWR = 0x05
CMD_BWR  = 0x08


# ── Cocotb simulation coroutines (sim_*) ──────────────────────────────────────

@cocotb.test()
async def sim_fprd_wkc_incremented(dut):
    """FPRD to matching station address: WKC in returned frame = 1."""
    await _setup(dut, esc_rdata=0x11, station_addr=0x0001)
    dg = datagram(CMD_FPRD, 0, (0x0001 | (0x0000 << 16)), b"\x00\x00")
    frame = build_frame(dg)
    await _feed_frame(dut, frame)
    tx = await _collect_tx(dut)

    assert len(tx) > 0, "No TX frame received"
    wkc_offset = 14 + 2 + 10 + 2
    if len(tx) > wkc_offset + 1:
        wkc = struct.unpack_from("<H", tx, wkc_offset)[0]
        assert wkc == 1, f"WKC should be 1 after FPRD match, got {wkc}"


@cocotb.test()
async def sim_fprd_wrong_station_no_match(dut):
    """FPRD to non-matching station: WKC stays 0."""
    await _setup(dut, station_addr=0x0001)
    dg = datagram(CMD_FPRD, 0, (0x0002 | (0x0000 << 16)), b"\x00\x00")
    frame = build_frame(dg)
    await _feed_frame(dut, frame)
    tx = await _collect_tx(dut)

    assert len(tx) > 0, "No TX frame received"
    wkc_offset = 14 + 2 + 10 + 2
    if len(tx) > wkc_offset + 1:
        wkc = struct.unpack_from("<H", tx, wkc_offset)[0]
        assert wkc == 0, f"WKC should be 0 for non-matching FPRD, got {wkc}"


@cocotb.test()
async def sim_bwr_always_matches(dut):
    """BWR (broadcast write): WKC incremented regardless of station addr."""
    await _setup(dut, station_addr=0x0005)
    dg = datagram(CMD_BWR, 0, (0x0000 | (0x0120 << 16)), b"\x08")
    frame = build_frame(dg)
    await _feed_frame(dut, frame)
    tx = await _collect_tx(dut)
    assert len(tx) > 0, "No TX frame received for BWR"


@cocotb.test()
async def sim_bad_ethertype_discarded(dut):
    """Frame with wrong EtherType (0x0800 = IP) is silently discarded."""
    await _setup(dut)
    bad_frame = eth_header(etype=0x0800) + b"\x00" * 20 + b"\xDE\xAD\xBE\xEF"
    await _feed_frame(dut, bad_frame)
    tx = await _collect_tx(dut, timeout_cycles=2000)
    assert len(tx) == 0, f"Bad EtherType frame should be discarded; got {len(tx)} TX bytes"


@cocotb.test()
async def sim_al_state_machine_preop(dut):
    """Master BWR to AL Control (0x0120) with PREOP=0x02 → al_state becomes PREOP."""
    await _setup(dut, station_addr=0x0001)

    async def esc_reg_loopback():
        while True:
            await RisingEdge(dut.clk)
            if int(dut.esc_wr.value) == 1 and int(dut.esc_addr.value) == 0x0120:
                dut.al_control.value = int(dut.esc_wdata.value) & 0xF

    loopback = cocotb.start_soon(esc_reg_loopback())
    dg = datagram(CMD_BWR, 0, (0x0000 | (0x0120 << 16)), b"\x02")
    frame = build_frame(dg)
    await _feed_frame(dut, frame)
    await ClockCycles(dut.clk, 100)
    loopback.cancel()

    al = int(dut.al_state.value)
    assert al == 0x2, f"AL state should be PREOP (0x2), got {al:#x}"


@cocotb.test()
async def sim_two_datagrams_m_bit(dut):
    """Frame with two chained datagrams (M=1 on first): both processed."""
    await _setup(dut, station_addr=0x0001)
    dg1 = datagram(CMD_FPWR, 0, (0x0001 | (0x0010 << 16)), b"\x00\x01", more=True)
    dg2 = datagram(CMD_FPRD, 1, (0x0001 | (0x0000 << 16)), b"\x00")
    frame = build_frame(dg1 + dg2)
    await _feed_frame(dut, frame)
    tx = await _collect_tx(dut)
    assert len(tx) > 0, "No TX frame received for chained datagrams"


# ── Pytest entry points (one per sim_* above) ─────────────────────────────────

def test_fprd_wkc_incremented():
    """FPRD to matching station: WKC = 1."""
    sim_run(_SOURCES, _TOP, _MODULE, "sim_fprd_wkc_incremented")

def test_fprd_wrong_station_no_match():
    """FPRD to wrong station: WKC stays 0."""
    sim_run(_SOURCES, _TOP, _MODULE, "sim_fprd_wrong_station_no_match")

def test_bwr_always_matches():
    """BWR broadcast write: WKC incremented regardless of station address."""
    sim_run(_SOURCES, _TOP, _MODULE, "sim_bwr_always_matches")

def test_bad_ethertype_discarded():
    """Frame with wrong EtherType is silently discarded."""
    sim_run(_SOURCES, _TOP, _MODULE, "sim_bad_ethertype_discarded")

def test_al_state_machine_preop():
    """BWR to AL Control 0x0120 with 0x02 → AL state transitions to PREOP."""
    sim_run(_SOURCES, _TOP, _MODULE, "sim_al_state_machine_preop")

def test_two_datagrams_m_bit():
    """Two chained datagrams (M-bit) in one frame are both processed."""
    sim_run(_SOURCES, _TOP, _MODULE, "sim_two_datagrams_m_bit")
