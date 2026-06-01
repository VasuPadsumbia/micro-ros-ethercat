# micro-ROS over EtherCAT

Replace the default TCP/UDP micro-ROS transport with an EtherCAT mailbox link.

```
ESP32 DevKit V4          Tang Nano 20K FPGA           PC
┌──────────────┐  SPI   ┌──────────────────┐  RJ45  ┌─────────────────────┐
│  micro-ROS   │───────►│  EtherCAT Slave  │───────►│  micro-ROS Agent    │
│  (firmware/) │        │  (ethercat-slave/)│        │  (agent/)           │
└──────────────┘        └──────────────────┘        └─────────────────────┘
```

VoE (Vendor over EtherCAT, type 0x0F) mailbox is used as the micro-ROS tunnel.

---

## Hardware

| Component | Part |
|-----------|------|
| Microcontroller | ESP32 DevKit V4 |
| FPGA | Sipeed Tang Nano 20K (Gowin GW2AR-18) |
| PHY ×2 | DP83848 100BASE-TX + RJ45 |
| ESI EEPROM | AT24C256 (I2C, 32 KiB) |
| SPI link | ESP32 ↔ FPGA, Mode 0, 8 MHz |
| INT_N pin | FPGA → ESP32 GPIO4 (active-low interrupt) |

---

## Repository layout

```
micro-ros-ethercat/
├── firmware/           ESP32 micro-ROS client (ESP-IDF v5.3)
│   ├── main/
│   │   ├── main.c
│   │   ├── spi_transport.c / .h
│   │   └── CMakeLists.txt
│   └── test/           Unity unit tests
├── ethercat-slave/     Tang Nano 20K FPGA design
│   ├── rtl/            Verilog RTL
│   ├── constraints/    Gowin CST pin constraints
│   ├── eeprom/         ESI EEPROM generator (gen_eeprom.py)
│   ├── sim/            Verilog simulation testbenches
│   └── tests/          cocotb + iverilog Python tests
├── agent/              PC-side micro-ROS agent (C++17, SOEM)
│   ├── include/
│   ├── src/
│   ├── test/           GTest unit tests (mock SOEM)
│   └── soem/           SOEM git submodule
├── docs/
│   ├── architecture.md
│   ├── installation.md
│   ├── user_guide.md
│   └── limitations.md
├── script.py           Project orchestrator
├── requirements.txt    Python dependencies (venv)
└── setup.sh            One-time tool installation
```

---

## Quick start

### Option A — Dev Container (recommended)

Requires [Docker](https://docs.docker.com/get-docker/) and either VS Code with the
[Dev Containers](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers)
extension, or just Docker Compose for a fully browser-based experience.

**VS Code Dev Container:**
```bash
git clone git@github.com:VasuPadsumbia/micro-ros-ethercat.git
cd micro-ros-ethercat
code .          # then click "Reopen in Container" when prompted
```

**Docker Compose (browser VS Code at http://localhost:8888):**
```bash
git clone git@github.com:VasuPadsumbia/micro-ros-ethercat.git
cd micro-ros-ethercat
ANTHROPIC_API_KEY=<your-key> docker compose up --build -d
# open http://localhost:8888 in your browser
```

Pre-installed in the container: ROS 2 Humble, CMake/GCC/Clang, Python 3.12, Rust,
Node.js 20, Claude Code CLI, apio, openFPGALoader, code-server.

Inside the container, run `bash setup.sh` once to fetch ESP-IDF, the micro-ROS
component, SOEM, and the apio oss-cad-suite packages.

---

### Option B — Native (Ubuntu 22.04 / 24.04)

### 1. Clone

```bash
git clone git@github.com:VasuPadsumbia/micro-ros-ethercat.git
cd micro-ros-ethercat
git submodule update --init --recursive   # pulls SOEM
```

### 2. Install system tools (once, requires sudo)

```bash
bash setup.sh
```

Installs: ESP-IDF v5.3, micro-ROS component, Yosys, nextpnr-gowin,
openFPGALoader, iverilog, GTest, Python 3.12 venv.

### 3. Build

```bash
./run.sh --build agent       # PC agent
./run.sh --build firmware    # ESP32 firmware
./run.sh --build slave       # FPGA bitstream
./run.sh --build all         # all three
```

### 4. Test

```bash
./run.sh --test agent        # GTest (no hardware needed)
./run.sh --test slave        # cocotb + iverilog simulation
./run.sh --test firmware     # Unity (needs ESP32 connected)
```

### 5. Flash hardware

```bash
# Flash Tang Nano 20K FPGA
./run.sh --load-ecat

# Flash ESP32 (override port/baud if needed)
./run.sh --load-mcu --port /dev/ttyUSB0 --baud 460800
```

### 6. Run agent

```bash
# Start PC agent (needs raw socket — runs with sudo)
./run.sh --run agent --eth enp3s0
```

---

## SPI frame protocol

```
┌──────┬───────┬─────────────┬─────┐
│ CMD  │ LEN_H │ LEN_L + ... │ CRC │
│ 1 B  │ 1 B   │ payload     │ 1 B │
└──────┴───────┴─────────────┴─────┘

CMD: 0x01 = write  0x02 = read  0x03 = status
CRC: CRC-8 (poly 0x07) over CMD + LEN + payload
```

---

## Documentation

| Document | Description |
|----------|-------------|
| [docs/architecture.md](docs/architecture.md) | System architecture and data flow |
| [docs/installation.md](docs/installation.md) | Detailed installation steps |
| [docs/user_guide.md](docs/user_guide.md) | Usage and configuration |
| [docs/limitations.md](docs/limitations.md) | Known limitations |

---

## License

MIT
