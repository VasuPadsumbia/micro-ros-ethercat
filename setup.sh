#!/usr/bin/env bash
# setup.sh — one-shot environment bootstrap
# Run once after cloning:  bash setup.sh

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Load config ───────────────────────────────────────────────────────────────
[[ -f "$ROOT/config.in" ]] || { echo "ERROR: config.in not found" >&2; exit 1; }
source "$ROOT/config.in"

TOOLS_DIR="$ROOT/${TOOLS_DIR:-tools}"
LOGS_DIR="$ROOT/${LOGS_DIR:-logs}"
VENV="$ROOT/.venv"
IDF_PATH="$TOOLS_DIR/esp-idf"
IDF_TOOLS_PATH="$TOOLS_DIR/espressif"
APIO_HOME="$TOOLS_DIR/apio"
UROS_COMP="$ROOT/${FIRMWARE_DIR:-firmware}/components/micro_ros_espidf_component"
SOEM_DIR="$ROOT/${AGENT_DIR:-agent}/soem"

export IDF_TOOLS_PATH
export APIO_HOME

# ── Logging ───────────────────────────────────────────────────────────────────
if [[ "${DEBUG:-false}" == "true" ]]; then
    mkdir -p "$LOGS_DIR"
    exec > >(tee "$LOGS_DIR/setup.log") 2>&1
    echo "── Setup log started $(date '+%Y-%m-%d %H:%M:%S') ──"
fi

GREEN="\033[32m"; YELLOW="\033[33m"; RESET="\033[0m"
ok()     { echo -e "${GREEN}✔  $1${RESET}"; }
info()   { echo -e "${YELLOW}»  $1${RESET}"; }
header() { echo -e "\n${YELLOW}── $1 ──${RESET}"; }

# ── System packages ───────────────────────────────────────────────────────────
header "System packages"
sudo apt-get update -qq
sudo apt-get install -y --no-install-recommends \
    python3 python3-pip python3.12 python3.12-venv \
    cmake make \
    gcc g++ \
    git curl wget \
    libpcap-dev \
    libgtest-dev \
    iverilog gtkwave \
    openocd \
    libusb-1.0-0-dev \
    libftdi1-dev \
    libhidapi-dev \
    libudev-dev
ok "System packages installed"

# ── Python venv ───────────────────────────────────────────────────────────────
header "Python venv  →  $VENV"
python3.12 -m venv "$VENV"
"$VENV/bin/pip" install --upgrade pip -q
"$VENV/bin/pip" install -r "$ROOT/requirements.txt" -q
ok "Python venv ready"

# ── apio packages  →  tools/apio ─────────────────────────────────────────────
# apio is already installed via requirements.txt (in the venv).
# Install the oss-cad-suite package which contains yosys, nextpnr, gowin_pack.
header "apio packages  →  $APIO_HOME"
mkdir -p "$APIO_HOME"
"$VENV/bin/apio" packages install
ok "apio oss-cad-suite installed"

# ── ESP-IDF  →  tools/esp-idf ─────────────────────────────────────────────────
header "ESP-IDF ${IDF_BRANCH:-v5.3}  →  $IDF_PATH"
mkdir -p "$TOOLS_DIR"
if [[ ! -d "$IDF_PATH/.git" ]]; then
    info "Cloning ESP-IDF ${IDF_BRANCH:-v5.3}..."
    git clone --recursive --depth=1 \
        --branch "${IDF_BRANCH:-v5.3}" \
        https://github.com/espressif/esp-idf.git \
        "$IDF_PATH"
else
    ok "ESP-IDF already cloned"
fi
info "Installing ESP-IDF tools → $IDF_TOOLS_PATH ..."
(
    unset VIRTUAL_ENV VIRTUAL_ENV_PROMPT
    export PATH
    PATH="$(echo "$PATH" | tr ':' '\n' | grep -v "$VENV/bin" | tr '\n' ':' | sed 's/:$//')"
    "$IDF_PATH/install.sh" esp32
)
ok "ESP-IDF tools installed"

# ── micro-ROS Python deps → ESP-IDF Python env ────────────────────────────────
# micro-ROS colcon build runs inside the ESP-IDF Python env and needs catkin_pkg
# and colcon itself — install them there so the firmware build works offline.
header "micro-ROS Python deps  →  ESP-IDF venv"
IDF_PYENV="$IDF_TOOLS_PATH/python_env"
IDF_PIP="$(ls -1d "$IDF_PYENV"/idf*_env/bin/pip 2>/dev/null | head -1)"
if [[ -n "$IDF_PIP" ]]; then
    "$IDF_PIP" install -q catkin_pkg colcon-common-extensions empy lark
    ok "catkin_pkg + colcon installed into ESP-IDF venv"
else
    echo "WARNING: ESP-IDF Python env not found — run setup again after ESP-IDF install" >&2
fi

# ── micro-ROS ESP-IDF component  →  firmware/components/ ─────────────────────
header "micro-ROS component  →  $UROS_COMP"
if [[ ! -d "$UROS_COMP/.git" ]]; then
    mkdir -p "$(dirname "$UROS_COMP")"
    git clone --depth=1 \
        https://github.com/micro-ROS/micro_ros_espidf_component.git \
        "$UROS_COMP"
    ok "micro-ROS component cloned"
else
    ok "micro-ROS component already present"
fi

# ── SOEM submodule  →  agent/soem ─────────────────────────────────────────────
header "SOEM submodule  →  $SOEM_DIR"
if [[ ! -f "$SOEM_DIR/CMakeLists.txt" ]]; then
    git -C "$ROOT" submodule update --init --recursive
    ok "SOEM submodule initialised"
else
    ok "SOEM already present"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Setup complete.  Everything is inside the workspace:"
echo "   .venv/            Python tools + apio"
echo "   tools/apio/       apio packages (oss-cad-suite)"
echo "   tools/esp-idf/    ESP-IDF SDK"
echo "   tools/espressif/  Xtensa toolchain"
echo ""
echo " Commands:"
echo "   ./run.sh --build agent     Build PC agent"
echo "   ./run.sh --build slave     Synthesise FPGA bitstream"
echo "   ./run.sh --build firmware  Build ESP32 firmware"
echo "   ./run.sh --load-ecat       Flash Tang Nano 20K"
echo "   ./run.sh --load-mcu        Flash ESP32"
echo "   ./run.sh --test agent      Run GTest suite"
echo "   ./run.sh --clean all       Remove all generated files"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
