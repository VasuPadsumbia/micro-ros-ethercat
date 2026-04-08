#!/usr/bin/env python3
"""
gen_eeprom.py — Generate ESI (EtherCAT Slave Information) EEPROM binary
                for the micro-ROS EtherCAT slave (AT24C256, 32 KiB).

Output: slave_eeprom.bin  (binary, word-addressed, little-endian 16-bit words)

ESI format reference: ETG.1000.6 Table 1, ETG.2000 (ESI specification)

Slave identity:
  Vendor ID   : 0x0059414D ("MAY\x00" — change to your vendor ID after
                             registering at https://www.ethercat.org)
  Product Code: 0x00000001
  Revision    : 0x00000001
  Serial No   : 0x00000000

Mailbox:
  SM0 (Mailbox Out): start=0x1000, size=256, type=MbxOut
  SM1 (Mailbox In) : start=0x1100, size=256, type=MbxIn
  Protocol: VoE (Vendor over EtherCAT) = 0x0020

Categories: General, FMMU, SyncManager, TxPDO, RxPDO, Strings
"""
import struct
import crcmod
import os

OUT_FILE = os.path.join(os.path.dirname(__file__), "slave_eeprom.bin")

# ── Helpers ───────────────────────────────────────────────────────────────────
def u16(v):
    return struct.pack("<H", v & 0xFFFF)

def u32(v):
    return struct.pack("<I", v & 0xFFFFFFFF)

def pad_to(data: bytes, size: int, fill: int = 0xFF) -> bytes:
    assert len(data) <= size, f"Data ({len(data)}) > size ({size})"
    return data + bytes([fill] * (size - len(data)))

crc_fn = crcmod.predefined.mkCrcFun("crc-16")

# ── Word 0-7: General device data (fixed header) ──────────────────────────────
# Word 0: PDI control    — 0x0004 (SPI PDI — closest match for custom PDI)
# Word 1: PDI config     — 0x0000
# Word 2: Sync impulse   — 0x0000
# Word 3: PDI config 2   — 0x0000
# Word 4: Station alias  — 0x0000
# Word 5-6: Reserved     — 0x0000
# Word 7: CRC-16 of words 0-6 (initialised separately)

PDI_CTRL   = 0x0080   # 0x80 = On-chip bus (custom / vendor-specific PDI)
PDI_CFG    = 0x0000
SYNC_IMP   = 0x0000
PDI_CFG2   = 0x0000
STA_ALIAS  = 0x0000

header_words = [PDI_CTRL, PDI_CFG, SYNC_IMP, PDI_CFG2, STA_ALIAS, 0x0000, 0x0000]
header_bytes = b"".join(u16(w) for w in header_words)
crc = crc_fn(header_bytes) & 0xFFFF

header = header_bytes + u16(crc)  # words 0-7

# ── Words 8-31: Device identity ───────────────────────────────────────────────
VENDOR_ID    = 0x0059414D  # "MAY\x00" (placeholder; replace with real EtherCAT vendor ID)
PRODUCT_CODE = 0x00000001
REVISION     = 0x00000001
SERIAL_NO    = 0x00000000

identity = (
    u32(VENDOR_ID)    +   # words 8-9
    u32(PRODUCT_CODE) +   # words 10-11
    u32(REVISION)     +   # words 12-13
    u32(SERIAL_NO)    +   # words 14-15
    u16(0x0000)       +   # word 16: reserved
    u16(0x0000)       +   # word 17: reserved
    # Bootstrap mailbox
    u16(0x1000)       +   # word 18: Bootstrap MbxOut offset
    u16(0x0100)       +   # word 19: Bootstrap MbxOut size (256 bytes)
    u16(0x1100)       +   # word 20: Bootstrap MbxIn  offset
    u16(0x0100)       +   # word 21: Bootstrap MbxIn  size
    # Standard mailbox
    u16(0x1000)       +   # word 22: Standard MbxOut offset
    u16(0x0100)       +   # word 23: Standard MbxOut size
    u16(0x1100)       +   # word 24: Standard MbxIn  offset
    u16(0x0100)       +   # word 25: Standard MbxIn  size
    u16(0x0020)       +   # word 26: Mailbox protocol (VoE = 0x0020)
    u16(0x0000)       +   # word 27: reserved
    u16(0x0000)       +   # word 28: reserved
    u16(0x0000)       +   # word 29: reserved
    u16(0x0000)       +   # word 30: reserved
    u16(0x00FF)       +   # word 31: EEPROM size = 0xFF+1 = 256 Kbit (AT24C256)
    u16(0x0001)           # word 32: version
)

# ── Category helper ───────────────────────────────────────────────────────────
def category(cat_type: int, data: bytes) -> bytes:
    """Wrap data in an ESI category header (type + word count)."""
    assert len(data) % 2 == 0
    word_count = len(data) // 2
    return u16(cat_type) + u16(word_count) + data

# ── Category 0x000A: General ──────────────────────────────────────────────────
#  Group string index, Image string index, Order string index, Name string index
#  CoE details, FoE details, EoE details, SoE details
GENERAL_CAT = bytes([
    0x01,       # Group string index (index in Strings category)
    0x00,       # Image string index (0 = none)
    0x02,       # Order string index
    0x03,       # Name string index
    0x00,       # physical layer (0x01=100Base-TX)
    0x00,       # CoE details: 0x00 (no CoE)
    0x00,       # FoE details
    0x00,       # EoE details: 0x00 (no EoE)
    0x00,       # SoE details
    0x00,       # DS402 channels
    0x00,       # SysmanClass
    0x00,       # flags
    0x00, 0x00, # CurrentOnEBus (mA × 1) = 0
    0x00,       # pad
    0x00,       # pad
])

# Pad to even length
if len(GENERAL_CAT) % 2:
    GENERAL_CAT += b"\x00"

# ── Category 0x0028: FMMU ────────────────────────────────────────────────────
# One FMMU entry per direction
# Byte meaning: 0x01=MbxOut→Inputs, 0x02=MbxIn→Outputs (simplified)
FMMU_CAT = bytes([
    0x01,   # FMMU0: Input (RxPDO)
    0x02,   # FMMU1: Output (TxPDO)
])

# ── Category 0x0029: SyncManager ─────────────────────────────────────────────
# 8 bytes per SM: PhysAddr[2], Length[2], CtrlReg[1], Status[1], Enable[1], SmType[1]
# SmType: 0x01=MbxOut, 0x02=MbxIn, 0x03=PdOut, 0x04=PdIn
SM_CAT = (
    struct.pack("<HHBBBB", 0x1000, 0x0100, 0x26, 0x00, 0x01, 0x01) +  # SM0: MbxOut
    struct.pack("<HHBBBB", 0x1100, 0x0100, 0x22, 0x00, 0x01, 0x02)    # SM1: MbxIn
)

# ── Category 0x0032: TxPDO (slave→master, i.e. micro-ROS agent→PC) ───────────
# Minimal: 1 PDO with 1 entry (raw bytes via VoE; PDO mapping is symbolic here)
TXPDO_CAT = bytes([
    0x00, 0x16,  # PDO index: 0x1600
    0x00,        # number of entries
    0x00,        # sync manager assignment (SM1)
    0x00,        # sync unit
    0x04,        # Name string index
    0x00, 0x00,  # flags
])

# ── Category 0x0033: RxPDO (master→slave, i.e. PC→micro-ROS) ────────────────
RXPDO_CAT = bytes([
    0x00, 0x1A,  # PDO index: 0x1A00
    0x00,        # number of entries
    0x00,        # sync manager assignment (SM0)
    0x00,        # sync unit
    0x05,        # Name string index
    0x00, 0x00,  # flags
])

# ── Category 0x000F: Strings ──────────────────────────────────────────────────
def make_strings(*strings) -> bytes:
    """Pack n+1 strings: first byte is count, then length+data for each."""
    out = bytes([len(strings)])
    for s in strings:
        enc = s.encode("ascii")
        out += bytes([len(enc)]) + enc
    # Pad to even length
    if len(out) % 2:
        out += b"\x00"
    return out

STRINGS_CAT = make_strings(
    "micro-ROS EtherCAT",     # index 1 — Group
    "UROS-EC-001",            # index 2 — Order
    "micro-ROS EtherCAT Slave",# index 3 — Name
    "VoE TxPDO",              # index 4
    "VoE RxPDO",              # index 5
)

# ── Category 0xFFFF: End ─────────────────────────────────────────────────────
END_CAT = u16(0xFFFF) + u16(0x0000)

# ── Assemble EEPROM ───────────────────────────────────────────────────────────
eeprom = (
    header
    + identity
    + category(0x000F, STRINGS_CAT)
    + category(0x000A, GENERAL_CAT)
    + category(0x0028, FMMU_CAT)
    + category(0x0029, SM_CAT)
    + category(0x0032, TXPDO_CAT)
    + category(0x0033, RXPDO_CAT)
    + END_CAT
)

# Pad to 32 KiB (AT24C256 size)
EEPROM_SIZE = 32 * 1024
eeprom = pad_to(eeprom, EEPROM_SIZE)

with open(OUT_FILE, "wb") as f:
    f.write(eeprom)

print(f"Generated {OUT_FILE}  ({len(eeprom)} bytes)")
print(f"  Vendor ID  : 0x{VENDOR_ID:08X}")
print(f"  Product    : 0x{PRODUCT_CODE:08X}")
print(f"  Revision   : 0x{REVISION:08X}")
print(f"  MbxOut     : 0x1000 / 256 B")
print(f"  MbxIn      : 0x1100 / 256 B")
print(f"  Protocol   : VoE (0x0020)")
