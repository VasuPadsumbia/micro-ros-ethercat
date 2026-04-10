# User Guide

## script.py — Project Orchestrator

All project operations are driven from `script.py` in the workspace root.

```
python script.py --build [all|firmware|slave|agent]
python script.py --clean [all|firmware|slave|agent]
python script.py --test  [all|firmware|slave|agent]
python script.py --run   [agent|flash-firmware|flash-slave]
```

### --build

| Target | What it does |
|--------|-------------|
| `agent` | CMake + make for the PC agent (pulls SOEM submodule if missing) |
| `firmware` | ESP-IDF `idf.py build` for the ESP32 firmware |
| `slave` | Yosys synthesis + nextpnr-gowin P&R → `.fs` bitstream |
| `all` | All three in order: firmware → slave → agent |

```bash
python script.py --build agent
python script.py --build all
```

### --test

| Target | What it does |
|--------|-------------|
| `agent` | Builds with `-DBUILD_TESTS=ON`, runs GTest via `ctest` (no hardware needed) |
| `slave` | Runs cocotb + iverilog simulation tests via `pytest` |
| `firmware` | ESP-IDF build + flash + monitor Unity tests (ESP32 required) |
| `all` | All three |

```bash
python script.py --test agent
python script.py --test slave
```

### --clean

| Target | What it does |
|--------|-------------|
| `agent` | Deletes `agent/build/` |
| `slave` | Deletes `ethercat-slave/build/out/` |
| `firmware` | Runs `idf.py fullclean` |
| `all` | All three |

```bash
python script.py --clean all
```

### --run

| Action | What it does |
|--------|-------------|
| `agent` | Runs the built agent binary (requires root for raw socket) |
| `flash-firmware` | Flashes ESP32 via `idf.py flash` |
| `flash-slave` | Flashes FPGA bitstream via `openFPGALoader` |

```bash
python script.py --run agent --eth enp3s0
python script.py --run flash-firmware --port /dev/ttyUSB0 --baud 460800
python script.py --run flash-slave
```

### Options

| Flag | Default | Description |
|------|---------|-------------|
| `--eth IFACE` | `eth0` | Ethernet interface for the EtherCAT agent |
| `--port PORT` | `/dev/ttyUSB0` | Serial port for firmware flashing |
| `--baud BAUD` | `460800` | Baud rate for firmware flashing |

---

## Running the System

### Start Order
Always start in this order:
1. Power on Tang Nano 20K (FPGA)
2. Connect PC Ethernet to Tang Nano Port 0
3. Start the PC agent
4. Power on / reset ESP32

The agent must be running before the ESP32 boots because micro-ROS
pings the agent on startup and restarts if it can't connect.

### PC Agent

```bash
sudo ./agent/build/micro_ros_ethercat_agent --iface eth0 --slave 1
```

Or via the build script:
```bash
python script.py --run agent --eth eth0
```

**LED status (Tang Nano 20K):**

| LED | State | Meaning |
|-----|-------|---------|
| LED0 | Always on | FPGA powered |
| LED1 | On after ~1 s | PHY MDIO init done |
| LED2 | On when OP | EtherCAT in OPERATIONAL state |
| LED3 | Blinks | Mailbox data available for ESP32 |
| LED4 | Blinks | Mailbox data ready for master |

### EtherCAT State Progression

The agent automatically progresses the slave through states:

```
INIT → PRE-OP → (SAFE-OP) → OP
```

This happens during `open()` in `EtherCATTransport`. You can observe the state
change via LED2.

### Monitoring ROS Topics

```bash
source /opt/ros/humble/setup.bash

# List topics
ros2 topic list

# Monitor status at 10 Hz
ros2 topic echo /esp32/status

# Check publish rate
ros2 topic hz /esp32/status

# Send a command
ros2 topic pub --once /esp32/cmd std_msgs/String '{data: "ping"}'
```

### Adjusting Publish Rate

In `firmware/main/main.c`, change the `vTaskDelay` in the spin loop:

```c
vTaskDelay(pdMS_TO_TICKS(100)); // 100 ms = 10 Hz
```

For 50 Hz: `pdMS_TO_TICKS(20)`.

Note: EtherCAT mailbox is not designed for high-rate cyclic data.
For rates > 100 Hz, consider PDO (Process Data Object) mapping instead.

### Adding Custom Topics

1. In `firmware/main/main.c`, add publisher/subscriber using rclc API
2. Rebuild firmware: `python script.py --build firmware`
3. Flash: `python script.py --run flash-firmware`

## SPI Transport Protocol Reference

### Commands (ESP32 → FPGA)

| CMD | Name | Description |
|-----|------|-------------|
| 0x01 | Write | Write payload bytes to SM1 (slave→master mailbox) |
| 0x02 | Read  | Read payload bytes from SM0 (master→slave mailbox) |
| 0x03 | Status | Query flags: rx_avail, tx_ready |

### Frame Format

```
┌──────┬────────┬────────┬──────────────────┬───────┐
│ CMD  │ LEN_H  │ LEN_L  │ PAYLOAD (0-1024B)│ CRC-8 │
│ 1 B  │ 1 B    │ 1 B    │ variable          │ 1 B   │
└──────┴────────┴────────┴──────────────────┴───────┘
```

CRC-8: polynomial 0x07, initial value 0x00, computed over CMD+LEN+PAYLOAD.

### Status Response (CMD=0x03)

| Bit | Name | Meaning |
|-----|------|---------|
| 0 | rx_avail | SM0 has a complete frame ready for ESP32 |
| 1 | tx_ready | SM1 is empty and can accept a new frame |

## EtherCAT Mailbox Reference

### VoE Frame (Vendor over EtherCAT)

```
Offset  Size  Description
──────  ────  ──────────────────────────────────
0       2     Length (payload bytes, excl. header)
2       2     Address (slave address, 0 for this slave)
4       1     Channel (0)
5       1     Type: bits[3:0]=priority, bits[7:4]=0x0F (VoE)
6       2     Reserved
8       N     Payload (raw micro-ROS XRCE-DDS frame)
```

### Mailbox Addresses

| SM | Direction | Physical Address | Size |
|----|-----------|-----------------|------|
| SM0 | Master → Slave | 0x1000 | 256 bytes |
| SM1 | Slave → Master | 0x1100 | 256 bytes |

## SOEM Master API Reference

The agent uses these SOEM functions internally:

| Function | Purpose |
|----------|---------|
| `ec_init(iface)` | Open raw socket on interface |
| `ec_config_init()` | Scan for slaves |
| `ec_slave[n].state` | AL state of slave n |
| `ec_writestate(0)` | Apply state to all slaves |
| `ec_mbxsend(n, buf, to)` | Send mailbox frame to slave n |
| `ec_mbxreceive(n, buf, to)` | Receive mailbox frame from slave n |
| `ec_close()` | Close master |

## Configuration Reference

### Firmware (`firmware/sdkconfig.defaults`)
| Key | Default | Effect |
|-----|---------|--------|
| `CONFIG_FREERTOS_HZ` | 1000 | FreeRTOS tick rate (ms resolution) |
| `CONFIG_ESP_MAIN_TASK_STACK_SIZE` | 8192 | Main task stack |
| `CONFIG_SPI_MASTER_IN_IRAM` | y | SPI ISR in IRAM for lower latency |

### FPGA (`ethercat-slave/rtl/`)
| Parameter | Default | Effect |
|-----------|---------|--------|
| `MBX_OUT_BASE` | 0x1000 | SM0 physical start address |
| `MBX_OUT_SIZE` | 256 | SM0 size in bytes |
| `MBX_IN_BASE` | 0x1100 | SM1 physical start address |
| `MBX_IN_SIZE` | 256 | SM1 size in bytes |
| `CLK_DIV` (I2C) | 67 | I2C clock divider (27 MHz / 4 / 100 kHz) |
| `MDC_DIV` | 6 | MDC clock divider (27 MHz / 12 ≈ 2.25 MHz) |

All parameters are `parameter` declarations in the Verilog modules.
