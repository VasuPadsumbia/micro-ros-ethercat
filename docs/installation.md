# Installation Guide

## Dev Container Setup (Recommended)

The repository ships with a pre-configured dev container that eliminates manual
tool installation for everything except ESP-IDF and the micro-ROS component
(which must be fetched from the internet at first use).

### What is pre-installed

| Tool | Version | Notes |
|------|---------|-------|
| Ubuntu | 22.04 | Base image |
| ROS 2 | Humble (desktop) | `source /opt/ros/humble/setup.bash` runs automatically |
| CMake / Ninja | system | plus GCC, G++, Clang |
| Python | 3.12 + 3.10 | deadsnakes PPA |
| Rust | stable | via rustup |
| Node.js | 20 | via NodeSource |
| Claude Code CLI | latest | `claude` command available |
| apio | latest | FPGA toolchain frontend |
| openFPGALoader | HEAD | Tang Nano 20K programmer |
| code-server | latest | browser VS Code on port 8888 |

`bash setup.sh` is still required once inside the container to download:
- ESP-IDF v5.3 + Xtensa toolchain (`tools/esp-idf/`)
- micro-ROS ESP-IDF component (`firmware/components/`)
- SOEM submodule (`agent/soem/`)
- apio oss-cad-suite packages (Yosys, nextpnr-gowin)
- Python venv (`.venv/`)

### Option A: VS Code Dev Container

Requirements: [Docker Desktop](https://docs.docker.com/get-docker/) and the
[Dev Containers](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers)
VS Code extension.

```bash
git clone git@github.com:VasuPadsumbia/micro-ros-ethercat.git
cd micro-ros-ethercat
code .
```

VS Code will detect `.devcontainer/devcontainer.json` and prompt
**"Reopen in Container"** — click it. The image builds once (~10 min on first
run) and opens with all extensions pre-installed. The `postCreateCommand`
automatically sources ROS 2.

Set `ANTHROPIC_API_KEY` in your host environment before opening the container;
`devcontainer.json` forwards it as `remoteEnv`.

### Option B: Docker Compose (browser VS Code)

Use this when you don't have VS Code installed locally or want the full IDE in
a browser tab.

```bash
git clone git@github.com:VasuPadsumbia/micro-ros-ethercat.git
cd micro-ros-ethercat

# Pass your Anthropic key (optional — only needed for Claude Code)
export ANTHROPIC_API_KEY=<your-key>

docker compose up --build -d
```

Then open **http://localhost:8888** in any browser. The workspace is
live-mounted so edits in the browser IDE are immediately reflected on disk.

Stop the container:
```bash
docker compose down
```

### First-run inside the container

The `postCreateCommand` in `devcontainer.json` runs `bash setup.sh` automatically.
This is a **one-time** operation (~60 min) that:

1. Clones ESP-IDF v5.3 and installs the Xtensa toolchain (~10 min)
2. Clones the micro-ROS ESP-IDF component and runs the colcon cross-compilation
   build for all micro-ROS packages including `rcl`, `rclc`, `std_msgs` (~45 min)
3. Installs apio oss-cad-suite packages (Yosys, nextpnr-gowin)
4. Creates the Python venv

After setup completes, activate the venv:

```bash
source .venv/bin/activate
```

Subsequent container starts are instant — setup is skipped if already done.

From this point the [Quick Start](#quick-start) steps apply normally.

### USB / hardware access

The container runs with `--privileged` and `SYS_PTRACE` so USB devices
(Tang Nano 20K via openFPGALoader, ESP32 via `/dev/ttyUSB*`) are
accessible without extra configuration on Linux and WSL 2.

On macOS with Docker Desktop, USB passthrough requires
[Docker USB passthrough](https://github.com/dorssel/usbipd-win) or
flashing from the host instead.

---

## Native / Bare-Metal Setup

Follow this path if you prefer not to use Docker.

## Prerequisites

### Hardware
- ESP32 DevKit V4
- Tang Nano 20K (Gowin GW2AR-18)
- 2× DP83848 PHY modules with RJ45
- AT24C256 EEPROM (256 Kbit, I2C)
- 2× 2.2 kΩ resistors (DP83848 pull-ups)
- 2× 4.7 kΩ resistors (I2C pull-ups for SCL and SDA)
- 4× 100 nF decoupling capacitors
- Cat5e / Cat6 Ethernet cable (PC ↔ Tang Nano Port 0)
- SPI wires: ESP32 ↔ Tang Nano (4 signals + INT_N)
- 3.3 V power supply for Tang Nano (USB or external)

### Software (Ubuntu 22.04 / 24.04 recommended)
- Python 3.10+
- git
- cmake, ninja-build
- gcc, g++ (for agent)
- iverilog (for FPGA simulation)

> **Tip:** All of the above are pre-installed in the dev container.
> See [Dev Container Setup](#dev-container-setup-recommended) to skip this section.

## Quick Start

```bash
git clone <this-repo> micro-ros-ethercat
cd micro-ros-ethercat

# One-time setup: installs all tools, clones submodules, creates venv
bash setup.sh

# Activate Python venv
source .venv/bin/activate

# Build everything
./run.sh --build all

# Flash FPGA
./run.sh --run flash-slave

# Flash ESP32 (connect via USB first)
./run.sh --run flash-firmware --port /dev/ttyUSB0

# Run agent (replace eth0 with your EtherCAT interface)
./run.sh --run agent --eth eth0
```

## Step-by-Step

### 1. Clone and Setup

```bash
git clone <repo> micro-ros-ethercat
cd micro-ros-ethercat
bash setup.sh
source .venv/bin/activate
```

`setup.sh` installs:
- ESP-IDF v5.3 → `~/esp/esp-idf`
- micro-ROS IDF component → `firmware/components/micro_ros_espidf_component`
- SOEM → `agent/soem`
- micro-ROS Agent → `agent/micro_ros_agent`
- openFPGALoader (FPGA programmer)
- Yosys (optional open-source synthesis)
- Python packages from `requirements.txt`

### 2. Hardware Wiring

> Full circuit diagrams, exact pin numbers, and resistor requirements are in
> **[docs/wiring.md](wiring.md)**.  The tables below are a quick reference.

#### SPI (ESP32 ↔ Tang Nano 20K — RIGHT header)
| ESP32 Pin | FPGA IO | Signal |
|-----------|---------|--------|
| GPIO14    | IO52    | SPI_SCK |
| GPIO13    | IO53    | SPI_MOSI |
| GPIO12    | IO54    | SPI_MISO |
| GPIO15    | IO55    | SPI_CS_N |
| GPIO4     | IO56    | INT_N (active-low) |
| GND       | GND     | Ground |
| 3.3V      | 3.3V    | Power |

**Resistor:** 10 kΩ pull-up from INT_N to 3.3V (strongly recommended).

#### I2C (Tang Nano 20K ↔ AT24C256 — RIGHT header)
| FPGA IO | AT24C256 | Signal |
|---------|----------|--------|
| IO71    | Pin 6 (SCL) | I2C_SCL |
| IO72    | Pin 5 (SDA) | I2C_SDA |
| GND     | Pin 4 (GND) | Ground |
| 3.3V    | Pin 8 (VCC) | Power |
| GND     | Pins 1,2,3 (A0,A1,A2) | Tie to GND → I2C addr 0x50 |
| GND     | Pin 7 (WP) | Tie to GND (write enabled) |

**Resistors:** 4.7 kΩ from SCL to 3.3V and 4.7 kΩ from SDA to 3.3V — **MANDATORY**.

#### MII (Tang Nano 20K ↔ DP83848 module)

**LEFT header** — high-speed MII data:
| FPGA IO | DP83848 | Direction | Signal |
|---------|---------|-----------|--------|
| IO73    | TX_CLK  | PHY→FPGA  | 25 MHz TX clock |
| IO74    | TXD0    | FPGA→PHY  | TX nibble bit 0 |
| IO75    | TXD1    | FPGA→PHY  | TX nibble bit 1 |
| IO77    | TXD2    | FPGA→PHY  | TX nibble bit 2 |
| IO25    | TXD3    | FPGA→PHY  | TX nibble bit 3 |
| IO26    | TX_EN   | FPGA→PHY  | Transmit enable |
| IO27    | RX_CLK  | PHY→FPGA  | 25 MHz RX clock |
| IO28    | RXD0    | PHY→FPGA  | RX nibble bit 0 |
| IO29    | RXD1    | PHY→FPGA  | RX nibble bit 1 |
| IO30    | RXD2    | PHY→FPGA  | RX nibble bit 2 |
| IO31    | RXD3    | PHY→FPGA  | RX nibble bit 3 |

**RIGHT header** — management + RX status:
| FPGA IO | DP83848 | Direction | Signal |
|---------|---------|-----------|--------|
| IO41    | RX_DV   | PHY→FPGA  | Receive data valid |
| IO42    | RX_ER   | PHY→FPGA  | Receive error |
| IO48    | MDC     | FPGA→PHY  | MDIO clock |
| IO49    | MDIO    | Bidir     | MDIO data (open-drain) |
| IO51    | RESET_N | FPGA→PHY  | Active-low reset |

**Resistors:**
- 2.2 kΩ from MDIO to 3.3V — **MANDATORY** (check if already on your module)
- 10 kΩ from RESET_N to 3.3V — strongly recommended
- TX_ER → tie to **GND** on module side (not connected to FPGA)

#### Ethernet (PC ↔ Tang Nano Port 0)
Cat5e cable from PC NIC to the RJ45 on the DP83848 module.

### 3. Build FPGA Bitstream

**Option A: Open-source (Yosys + nextpnr)**
```bash
./run.sh --build slave
```

**Option B: Gowin IDE**
```bash
# Open Gowin IDE, File → New Project → from TCL script
# Load: ethercat-slave/build/project.tcl
```

**Generate ESI EEPROM binary:**
```bash
python ethercat-slave/eeprom/gen_eeprom.py
# Output: ethercat-slave/eeprom/slave_eeprom.bin
```

**Flash EEPROM (one-time):**
```bash
# Use any I2C programmer (e.g. Bus Pirate, Raspberry Pi) to write
# slave_eeprom.bin to the AT24C256 at address 0x50
```

### 4. Flash FPGA

```bash
./run.sh --run flash-slave
# Uses openFPGALoader with Tang Nano 20K profile
```

### 5. Build and Flash ESP32 Firmware

```bash
# Source ESP-IDF
source ~/esp/esp-idf/export.sh

# Build
./run.sh --build firmware

# Flash (replace /dev/ttyUSB0 with your port)
./run.sh --run flash-firmware --port /dev/ttyUSB0
```

### 6. Build and Run PC Agent

```bash
./run.sh --build agent

# Run (requires root for raw socket)
./run.sh --run agent --eth eth0
```

Or directly:
```bash
sudo ./agent/build/micro_ros_ethercat_agent --iface eth0 --slave 1
```

### 7. Verify

With agent running, open a second terminal:
```bash
source /opt/ros/humble/setup.bash
ros2 topic echo /esp32/status
```

Expected output (10 Hz):
```
data: 'ESP32 alive seq=0 uptime=1234ms'
```

Send a command:
```bash
ros2 topic pub --once /esp32/cmd std_msgs/String "data: 'hello'"
```

## Running Tests

```bash
source .venv/bin/activate

# FPGA simulation tests (cocotb + iverilog)
./run.sh --test slave

# Firmware tests (on-hardware, ESP32 connected)
./run.sh --test firmware

# Agent unit tests (Google Test, no hardware needed)
./run.sh --test agent

# All tests
./run.sh --test all
```

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| `ec_init failed` | Wrong interface or no permissions | Run with `sudo`, check interface name |
| `No slaves found` | PHY not initialised or cable unplugged | Check MDIO init LEDs, check cable |
| INT_N never asserts | FPGA not programmed or SPI wiring issue | Check bitstream, verify SPI connections |
| `CRC mismatch` in SPI | Noise on SPI lines or wrong mode | Add decoupling, verify CPOL/CPHA=0,0 |
| ESP32 `Agent not reachable` | Agent not running or mailbox not in PRE-OP | Start agent first, check AL state |
