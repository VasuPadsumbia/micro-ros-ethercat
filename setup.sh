#!/usr/bin/env bash
# ──────────────────────────────────────────────
# setup.sh — one-shot environment bootstrap
# Run once: bash setup.sh
# ──────────────────────────────────────────────
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── System dependencies ───────────────────────
echo "[setup] Installing system dependencies..."
sudo apt-get update -qq
sudo apt-get install -y --no-install-recommends \
    python3 python3-pip python3-venv \
    iverilog gtkwave \
    cmake ninja-build \
    git curl wget \
    libpcap-dev \
    gcc g++ \
    openocd

# ── ESP-IDF (firmware) ───────────────────────
IDF_PATH="${HOME}/esp/esp-idf"
if [ ! -d "$IDF_PATH" ]; then
    echo "[setup] Installing ESP-IDF v5.3..."
    mkdir -p "${HOME}/esp"
    git clone --recursive --depth=1 --branch v5.3 \
        https://github.com/espressif/esp-idf.git "$IDF_PATH"
    "$IDF_PATH/install.sh" esp32
fi

# ── micro-ROS IDF component (submodule) ──────
UROS_COMP="${SCRIPT_DIR}/firmware/components/micro_ros_espidf_component"
if [ ! -d "$UROS_COMP/.git" ]; then
    echo "[setup] Cloning micro-ROS ESP-IDF component..."
    git clone --depth=1 \
        https://github.com/micro-ROS/micro_ros_espidf_component.git \
        "$UROS_COMP"
fi

# ── SOEM (agent EtherCAT master library) ─────
SOEM_DIR="${SCRIPT_DIR}/agent/soem"
if [ ! -d "$SOEM_DIR/.git" ]; then
    echo "[setup] Cloning SOEM..."
    git clone --depth=1 \
        https://github.com/OpenEtherCATsociety/SOEM.git \
        "$SOEM_DIR"
fi

# ── micro-ROS agent (agent bridge) ───────────
AGENT_SRC="${SCRIPT_DIR}/agent/micro_ros_agent"
if [ ! -d "$AGENT_SRC/.git" ]; then
    echo "[setup] Cloning micro-ROS Agent..."
    git clone --depth=1 \
        https://github.com/micro-ROS/micro-ROS-Agent.git \
        "$AGENT_SRC"
fi

# ── openFPGALoader (FPGA programmer) ─────────
if ! command -v openFPGALoader &>/dev/null; then
    echo "[setup] Building openFPGALoader..."
    TMP=$(mktemp -d)
    git clone --depth=1 https://github.com/trabucayre/openFPGALoader.git "$TMP/ofpgal"
    cmake -S "$TMP/ofpgal" -B "$TMP/ofpgal/build" -GNinja -DCMAKE_BUILD_TYPE=Release
    cmake --build "$TMP/ofpgal/build"
    sudo cmake --install "$TMP/ofpgal/build"
    rm -rf "$TMP"
fi

# ── Yosys + nextpnr-gowin (open FPGA flow) ───
if ! command -v yosys &>/dev/null; then
    echo "[setup] Installing Yosys..."
    sudo apt-get install -y yosys
fi

# ── Python venv ───────────────────────────────
echo "[setup] Creating Python venv..."
python3 -m venv "${SCRIPT_DIR}/.venv"
source "${SCRIPT_DIR}/.venv/bin/activate"
pip install --upgrade pip
pip install -r "${SCRIPT_DIR}/requirements.txt"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Setup complete."
echo " Activate venv: source .venv/bin/activate"
echo " Build all:     python script.py --build all"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
