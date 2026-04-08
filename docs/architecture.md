# Architecture

## Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  PC (Ubuntu / ROS 2 Humble)                                                 │
│                                                                             │
│  ┌──────────────────────┐       ┌──────────────────────────────────────┐   │
│  │  ROS 2 Node          │       │  micro-ROS EtherCAT Agent            │   │
│  │  (rclcpp)            │◄─────►│  (SOEM + micro-ros-agent)            │   │
│  └──────────────────────┘       └──────────────┬───────────────────────┘   │
│                                                │  eth0 (raw Ethernet)       │
└────────────────────────────────────────────────┼───────────────────────────┘
                                                 │
                               EtherCAT (0x88A4) │
                               RJ45 / Cat5e cable │
                                                 │
┌────────────────────────────────────────────────▼───────────────────────────┐
│  Tang Nano 20K (Gowin GW2AR-18 FPGA)                                       │
│                                                                             │
│  ┌──────────────┐   ┌─────────────────────────────────────────────────┐   │
│  │DP83848 PHY 1 │   │  EtherCAT Slave Core (RTL)                      │   │
│  │(Port 0 — IN) │◄─►│  ┌───────────┐ ┌─────────────┐ ┌────────────┐ │   │
│  └──────────────┘   │  │MII MAC    │ │ESC Registers│ │Mailbox     │ │   │
│  ┌──────────────┐   │  │(mii_mac.v)│ │(esc_regs.v) │ │SM0/SM1     │ │   │
│  │DP83848 PHY 2 │   │  └───────────┘ └─────────────┘ └─────┬──────┘ │   │
│  │(Port 1 — OUT)│◄─►│  ┌───────────────────────────────┐   │        │   │
│  └──────────────┘   │  │ ethercat_slave.v (FSM)        │   │        │   │
│                     │  │ INIT→PREOP→SAFEOP→OP          │   │        │   │
│  ┌──────────────┐   │  └───────────────────────────────┘   │        │   │
│  │AT24C256 EEPROM│  │  ┌────────────────────┐              │        │   │
│  │(I2C, ESI)    │◄─►│  │i2c_master.v (SII) │              │        │   │
│  └──────────────┘   │  └────────────────────┘              │        │   │
│                     │  ┌─────────────────────┐             │        │   │
│                     │  │spi_slave.v          │◄────────────┘        │   │
│                     │  └──────────┬──────────┘                      │   │
│                     └────────────┼────────────────────────────────┘   │
│                                  │  SPI (8 MHz, Mode 0)                │
│                                  │  + INT_N (active-low)               │
└──────────────────────────────────┼─────────────────────────────────────┘
                                   │
┌──────────────────────────────────▼─────────────────────────────────────┐
│  ESP32 DevKit V4                                                        │
│                                                                         │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │  micro-ROS (micro-XRCE-DDS + rclc)                              │   │
│  │  ┌──────────────────────┐   ┌──────────────────────────────┐   │   │
│  │  │ ROS publisher/sub    │   │ spi_transport.c              │   │   │
│  │  │ /esp32/status        │──►│ uxrCustomTransport callbacks │   │   │
│  │  │ /esp32/cmd           │◄──│ spi_cmd_write/read/status    │   │   │
│  │  └──────────────────────┘   └──────────────────────────────┘   │   │
│  └─────────────────────────────────────────────────────────────────┘   │
└────────────────────────────────────────────────────────────────────────┘
```

## Component Descriptions

### ESP32 Firmware (`firmware/`)
- Runs micro-ROS with a **custom SPI transport** (`spi_transport.c`)
- SPI master (8 MHz, Mode 0) talks to FPGA SPI slave
- Protocol: `[CMD][LEN_H][LEN_L][PAYLOAD...][CRC8]`
- INT_N pin (GPIO4): FPGA pulls low when mailbox data is ready for ESP32
- Publishes `/esp32/status` at 10 Hz; subscribes to `/esp32/cmd`

### FPGA EtherCAT Slave (`ethercat-slave/`)
| Module | File | Function |
|---|---|---|
| `top` | top.v | Top-level wiring + reset sequencer |
| `ethercat_slave` | ethercat_slave.v | EtherCAT frame FSM; datagram processing; AL state machine |
| `esc_registers` | esc_registers.v | ESC register file (0x0000–0x07FF) + 4 KiB process data RAM |
| `mailbox` | mailbox.v | SM0 (master→slave) + SM1 (slave→master) buffers + INT_N |
| `mii_mac` | mii_mac.v | MII TX/RX MAC for DP83848; FCS generate/check; async FIFOs |
| `spi_slave` | spi_slave.v | SPI slave (Mode 0); frame parser/builder; CRC-8 |
| `i2c_master` | i2c_master.v | I2C master for AT24C256 EEPROM (SII reads) |
| `mdio_ctrl` | mdio_ctrl.v | MDIO PHY init (force 100BASE-TX FD) |
| `crc32` | crc32.v | Ethernet CRC-32 (reflected, nibble-serial) |

### PC Agent (`agent/`)
- **SOEM** (Simple Open EtherCAT Master) provides raw EtherCAT access
- `EtherCATTransport` wraps SOEM mailbox read/write into a byte-stream API
- `SoemBridge` connects the transport to the micro-ros-agent relay loop
- Requires root or `CAP_NET_RAW` for raw socket access

### ESI EEPROM (`ethercat-slave/eeprom/`)
- AT24C256 (32 KiB I2C EEPROM) stores the EtherCAT Slave Information (ESI)
- Generated by `gen_eeprom.py`: vendor ID, mailbox config, VoE protocol flag
- FPGA reads ESI via I2C at startup; exposes it through ESC register 0x0500

## Data Flow (Detailed)

### ESP32 → PC (client → agent)

1. micro-ROS publishes a message
2. micro-XRCE-DDS serializes to XRCE-DDS frame
3. `spi_transport_write()` frames as: `0x01 [LEN_H] [LEN_L] [payload] [CRC8]`
4. SPI transfer: ESP32 → FPGA spi_slave.v
5. `spi_slave.v` writes payload bytes to SM1 buffer (mailbox.v)
6. `mailbox.v` sets `mbox_in_ready=1`
7. Next EtherCAT cycle: master reads SM1 via FPRD datagram
8. `ethercat_slave.v` reads SM1 bytes from process data RAM, increments WKC
9. Frame returns to master with payload
10. `EtherCATTransport::read()` extracts VoE payload
11. micro-ros-agent forwards to ROS 2 DDS

### PC → ESP32 (agent → client)

1. ROS 2 node publishes to `/esp32/cmd`
2. micro-ros-agent serializes XRCE-DDS frame
3. `EtherCATTransport::write()` wraps in VoE mailbox header
4. SOEM `ec_mbxsend()` sends FPWR datagram to SM0
5. `ethercat_slave.v` writes SM0 bytes to process data RAM
6. `mailbox.v` detects SM0 write complete → sets `sm0_written=1`
7. `mailbox.v` asserts `INT_N` (pulls low)
8. ESP32 detects INT_N low (or polls status)
9. `spi_transport_read()` sends CMD=0x02 to read SM0 bytes
10. `spi_slave.v` feeds SM0 bytes byte-by-byte via MISO
11. micro-XRCE-DDS delivers message to `subscription_callback()`

## EtherCAT AL State Machine

```
Reset → INIT (0x01)
              │ master BWR AL Control = 0x02
              ▼
         PRE-OP (0x02)   ← mailbox communication enabled
              │ master BWR AL Control = 0x04
              ▼
        SAFE-OP (0x04)   ← PDO RX active (future: cyclic data)
              │ master BWR AL Control = 0x08
              ▼
            OP (0x08)    ← full operation
```

## Clock Domains

| Domain | Source | Frequency | Usage |
|---|---|---|---|
| sys_clk | Tang Nano 20K XTAL | 27 MHz | FPGA logic, SPI, I2C, ESC FSM |
| tx_clk0 | PHY0 TX_CLK | 25 MHz | MII TX Port 0 |
| rx_clk0 | PHY0 RX_CLK | 25 MHz | MII RX Port 0 |
| tx_clk1 | PHY1 TX_CLK | 25 MHz | MII TX Port 1 |
| rx_clk1 | PHY1 RX_CLK | 25 MHz | MII RX Port 1 |

CDC (Clock Domain Crossing) is handled via 2-flop synchronisers and Gray-coded async FIFOs in `mii_mac.v`.

## Protocol Stack

```
┌────────────────────────────────────┐
│  ROS 2 Topics (DDS-RTPS)          │  PC / ESP32
├────────────────────────────────────┤
│  micro-XRCE-DDS (XRCE protocol)   │  ESP32 / Agent
├────────────────────────────────────┤
│  VoE Mailbox (EtherCAT Vendor)    │  FPGA / Agent
├────────────────────────────────────┤
│  EtherCAT (0x88A4)                │  FPGA / SOEM
├────────────────────────────────────┤
│  100BASE-TX Ethernet               │  DP83848 PHY
└────────────────────────────────────┘
```
