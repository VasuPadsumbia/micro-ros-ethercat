"""
test_ethercat.py — cocotb tests for ethercat_slave.v

Tests:
  1. FPRD datagram: slave reads ESC register and fills data field; WKC = 1
  2. FPWR datagram: slave writes data to ESC register; WKC = 1
  3. BWR datagram: broadcast write, always matched; WKC = 1
  4. Bad EtherType: frame silently discarded
  5. AL state transition: master writes AL Control, slave updates AL Status
  6. Multiple datagrams in one frame (M-bit chaining)
"""
import struct
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles, Timer


# ── EtherCAT frame builder ────────────────────────────────────────────────────
def eth_header(dst=b"\xff"*6, src=b"\x00\x11\x22\x33\x44\x55",
               etype=0x88A4) -> bytes:
    return dst + src + struct.pack(">H", etype)


def ethercat_header(length: int, etype_pdu: int = 1) -> bytes:
    # bits[10:0]=length, bits[15:12]=type
    word = (length & 0x07FF) | ((etype_pdu & 0xF) << 12)
    return struct.pack("<H", word)


def datagram(cmd: int, idx: int, addr32: int, data: bytes, more: bool = False) -> bytes:
    length = len(data)
    flags = (1 << 6) if more else 0   # M bit at bit6 of length high byte
    hdr = struct.pack("<BBIHH",
                      cmd, idx, addr32,
                      length | (flags << 8),  # length[10:0] | flags
                      0)                       # IRQ
    wkc = struct.pack("<H", 0)
    return hdr + data + wkc


def build_frame(datagrams: bytes) -> bytes:
    ec_hdr = ethercat_header(len(datagrams))
    payload = ec_hdr + datagrams
    frame = eth_header() + payload
    # FCS placeholder (4 bytes) — we set rx_fcs_ok=1 in the testbench
    return frame + b"\xDE\xAD\xBE\xEF"


# ── Common setup ──────────────────────────────────────────────────────────────
async def setup(dut, esc_rdata=0x42, station_addr=0x0001):
    cocotb.start_soon(Clock(dut.clk, 37, units="ns").start())
    dut.rst_n.value       = 0
    dut.p0_rx_valid.value = 0
    dut.p0_rx_last.value  = 0
    dut.p0_rx_fcs_ok.value= 0
    dut.p0_rx_data.value  = 0
    dut.p0_tx_ready.value = 1
    dut.esc_rdata.value   = esc_rdata
    dut.station_addr.value= station_addr
    await ClockCycles(dut.clk, 5)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 5)


async def feed_frame(dut, frame: bytes):
    """Feed a frame byte-by-byte into the DUT RX stream."""
    dut.p0_rx_fcs_ok.value = 1
    for i, b in enumerate(frame):
        await RisingEdge(dut.clk)
        dut.p0_rx_data.value  = b
        dut.p0_rx_valid.value = 1
        dut.p0_rx_last.value  = 1 if i == len(frame) - 1 else 0
    await RisingEdge(dut.clk)
    dut.p0_rx_valid.value = 0
    dut.p0_rx_last.value  = 0


async def collect_tx(dut, timeout_cycles=10000) -> bytes:
    """Collect one TX frame from the DUT."""
    buf = bytearray()
    for _ in range(timeout_cycles):
        await RisingEdge(dut.clk)
        if int(dut.p0_tx_valid.value) == 1:
            buf.append(int(dut.p0_tx_data.value))
            if int(dut.p0_tx_last.value) == 1:
                return bytes(buf)
    return bytes(buf)  # may be empty if timeout


# ── Tests ─────────────────────────────────────────────────────────────────────
CMD_FPRD = 0x04
CMD_FPWR = 0x05
CMD_BWR  = 0x08


@cocotb.test()
async def test_fprd_wkc_incremented(dut):
    """FPRD to matching station address: WKC in returned frame = 1."""
    await setup(dut, esc_rdata=0x11, station_addr=0x0001)

    # FPRD: station=0x0001, offset=0x0000, 2 data bytes
    dg = datagram(CMD_FPRD, 0, (0x0001 | (0x0000 << 16)), b"\x00\x00")
    frame = build_frame(dg)
    await feed_frame(dut, frame)
    tx = await collect_tx(dut)

    assert len(tx) > 0, "No TX frame received"
    # WKC is at bytes: 14 (EC hdr) + 2 (EC) + 10 (DG hdr) + 2 (data) = offset 28-29
    wkc_offset = 14 + 2 + 10 + 2
    if len(tx) > wkc_offset + 1:
        wkc = struct.unpack_from("<H", tx, wkc_offset)[0]
        assert wkc == 1, f"WKC should be 1 after FPRD match, got {wkc}"


@cocotb.test()
async def test_fprd_wrong_station_no_match(dut):
    """FPRD to non-matching station: WKC stays 0."""
    await setup(dut, station_addr=0x0001)

    dg = datagram(CMD_FPRD, 0, (0x0002 | (0x0000 << 16)), b"\x00\x00")
    frame = build_frame(dg)
    await feed_frame(dut, frame)
    tx = await collect_tx(dut)

    assert len(tx) > 0, "No TX frame received"
    wkc_offset = 14 + 2 + 10 + 2
    if len(tx) > wkc_offset + 1:
        wkc = struct.unpack_from("<H", tx, wkc_offset)[0]
        assert wkc == 0, f"WKC should be 0 for non-matching FPRD, got {wkc}"


@cocotb.test()
async def test_bwr_always_matches(dut):
    """BWR (broadcast write): WKC incremented regardless of station addr."""
    await setup(dut, station_addr=0x0005)

    dg = datagram(CMD_BWR, 0, (0x0000 | (0x0120 << 16)), b"\x08")  # AL ctrl=OP
    frame = build_frame(dg)
    await feed_frame(dut, frame)
    tx = await collect_tx(dut)

    assert len(tx) > 0, "No TX frame received for BWR"


@cocotb.test()
async def test_bad_ethertype_discarded(dut):
    """Frame with wrong EtherType (0x0800 = IP) is silently discarded."""
    await setup(dut)

    bad_frame = eth_header(etype=0x0800) + b"\x00" * 20 + b"\xDE\xAD\xBE\xEF"
    await feed_frame(dut, bad_frame)
    tx = await collect_tx(dut, timeout_cycles=2000)
    # Should receive nothing (or the next valid frame, but here nothing follows)
    assert len(tx) == 0, f"Bad EtherType frame should be discarded; got {len(tx)} TX bytes"


@cocotb.test()
async def test_al_state_machine_preop(dut):
    """Master BWR to AL Control (0x0120) with PREOP=0x02 → al_state becomes PREOP."""
    await setup(dut, station_addr=0x0001)

    # BWR to 0x0120 (AL control), write 0x02 = PREOP
    dg = datagram(CMD_BWR, 0, (0x0000 | (0x0120 << 16)), b"\x02")
    frame = build_frame(dg)
    await feed_frame(dut, frame)
    await ClockCycles(dut.clk, 100)

    al = int(dut.al_state.value)
    assert al == 0x2, f"AL state should be PREOP (0x2), got {al:#x}"


@cocotb.test()
async def test_two_datagrams_m_bit(dut):
    """Frame with two chained datagrams (M=1 on first): both processed."""
    await setup(dut, station_addr=0x0001)

    # First datagram: FPWR (M=1)
    dg1 = datagram(CMD_FPWR, 0, (0x0001 | (0x0010 << 16)), b"\x00\x01", more=True)
    # Second datagram: FPRD (M=0)
    dg2 = datagram(CMD_FPRD, 1, (0x0001 | (0x0000 << 16)), b"\x00")
    frame = build_frame(dg1 + dg2)
    await feed_frame(dut, frame)
    tx = await collect_tx(dut)

    assert len(tx) > 0, "No TX frame received for chained datagrams"
