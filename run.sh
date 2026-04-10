#!/usr/bin/env bash
# run.sh — micro-ROS EtherCAT project orchestrator
#
# Usage:
#   ./run.sh --build     [all|firmware|slave|agent]
#   ./run.sh --clean     [all|firmware|slave|agent]
#   ./run.sh --test      [all|firmware|slave|agent]
#   ./run.sh --run       [agent]
#   ./run.sh --load-ecat              Flash FPGA bitstream → Tang Nano 20K
#   ./run.sh --load-mcu               Flash firmware       → ESP32
#
# Options (override config.in):
#   --eth   IFACE   Ethernet interface for the agent   (default: eth0)
#   --port  PORT    Serial port for ESP32 flash        (default: /dev/ttyUSB0)
#   --baud  BAUD    Baud rate for ESP32 flash          (default: 460800)

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Load config ───────────────────────────────────────────────────────────────
[[ -f "$ROOT/config.in" ]] || { echo "ERROR: config.in not found" >&2; exit 1; }
source "$ROOT/config.in"

# Resolve all paths relative to workspace root
FIRMWARE_DIR="$ROOT/${FIRMWARE_DIR:-firmware}"
SLAVE_DIR="$ROOT/${SLAVE_DIR:-ethercat-slave}"
AGENT_DIR="$ROOT/${AGENT_DIR:-agent}"
LOGS_DIR="$ROOT/${LOGS_DIR:-logs}"
TOOLS_DIR="$ROOT/${TOOLS_DIR:-tools}"

VENV="$ROOT/.venv"
IDF_PATH="$TOOLS_DIR/esp-idf"
IDF_TOOLS_PATH="$TOOLS_DIR/espressif"
APIO_HOME="$TOOLS_DIR/apio"
export IDF_TOOLS_PATH
export APIO_HOME

UROS_COMP="$FIRMWARE_DIR/components/micro_ros_espidf_component"

# ── Colours ───────────────────────────────────────────────────────────────────
RESET="\033[0m"; BOLD="\033[1m"; CYAN="\033[36m"
RED="\033[31m";  GREEN="\033[32m"; YELLOW="\033[33m"

banner() { echo -e "\n${BOLD}${CYAN}$(printf '━%.0s' {1..60})${RESET}"
           echo -e "${BOLD}${CYAN}  $1${RESET}"
           echo -e "${BOLD}${CYAN}$(printf '━%.0s' {1..60})${RESET}\n"; }
ok()     { echo -e "${GREEN}✔  $1${RESET}"; }
fail()   { echo -e "${RED}✘  $1${RESET}" >&2; }
info()   { echo -e "${YELLOW}»  $1${RESET}"; }

# ── Logging ───────────────────────────────────────────────────────────────────
setup_log() {
    if [[ "${DEBUG:-false}" == "true" ]]; then
        mkdir -p "$LOGS_DIR"
        exec > >(tee "$LOGS_DIR/$1") 2>&1
        echo "── Log started $(date '+%Y-%m-%d %H:%M:%S') ──"
    fi
}

# ── Argument parsing ──────────────────────────────────────────────────────────
ACTION=""; TARGET=""
CLI_ETH=""; CLI_PORT=""; CLI_BAUD=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --build|--clean|--test|--run)
            ACTION="${1#--}"; TARGET="${2:-all}"; shift 2 ;;
        --load-ecat) ACTION="load-ecat"; shift ;;
        --load-mcu)  ACTION="load-mcu";  shift ;;
        --eth)       CLI_ETH="$2";  shift 2 ;;
        --port)      CLI_PORT="$2"; shift 2 ;;
        --baud)      CLI_BAUD="$2"; shift 2 ;;
        --help|-h)   sed -n '2,13p' "$0"; exit 0 ;;
        *) fail "Unknown argument: $1"; exit 1 ;;
    esac
done

[[ -n "$CLI_ETH"  ]] && ETH_IFACE="$CLI_ETH"
[[ -n "$CLI_PORT" ]] && SERIAL_PORT="$CLI_PORT"
[[ -n "$CLI_BAUD" ]] && BAUD_RATE="$CLI_BAUD"

if [[ -z "$ACTION" ]]; then sed -n '2,13p' "$0"; exit 0; fi

# ── Helpers ───────────────────────────────────────────────────────────────────
require_venv() {
    [[ -x "$VENV/bin/python" ]] || { fail "venv not found. Run: bash setup.sh"; exit 1; }
}

require_idf() {
    [[ -d "$IDF_PATH" ]] || { fail "ESP-IDF not found. Run: bash setup.sh"; exit 1; }
    # Strip the project venv from PATH so idf.py uses the IDF Python env, not ours.
    # (unset VIRTUAL_ENV alone doesn't remove .venv/bin from PATH)
    export PATH
    PATH="$(echo "$PATH" | tr ':' '\n' | grep -v "$VENV/bin" | tr '\n' ':' | sed 's/:$//')"
    unset VIRTUAL_ENV VIRTUAL_ENV_PROMPT 2>/dev/null || true
    # shellcheck source=/dev/null
    # || true: export.sh exits 1 when optional tools (riscv32-esp-elf) are absent;
    # that doesn't affect ESP32 builds, so don't let set -e abort the script.
    source "$IDF_PATH/export.sh" &>/dev/null || true
    [[ -x "$(command -v idf.py)" ]] || { fail "idf.py not in PATH after sourcing export.sh"; exit 1; }
}

cmake_build() {
    local build_dir="$1"; shift
    local soem_dir="$AGENT_DIR/soem"
    if [[ ! -f "$soem_dir/CMakeLists.txt" ]]; then
        info "Initialising SOEM submodule..."
        git -C "$ROOT" submodule update --init --recursive
    fi
    mkdir -p "$build_dir"
    cmake -S "$AGENT_DIR" -B "$build_dir" \
        -G "Unix Makefiles" \
        -DSOEM_DIR="$soem_dir" \
        -DCMAKE_BUILD_TYPE="${CMAKE_BUILD_TYPE:-Release}" \
        "$@"
    make -C "$build_dir" -j"$(nproc)"
}

# ══════════════════════════════════════════════════════════════════════════════
# BUILD
# ══════════════════════════════════════════════════════════════════════════════
build_agent() {
    banner "Building PC agent"
    cmake_build "$AGENT_DIR/build"
    ok "Agent → $AGENT_DIR/build/micro_ros_ethercat_agent"
}

build_firmware() {
    banner "Building ESP32 firmware"
    require_idf
    idf.py -C "$FIRMWARE_DIR" build
    ok "Firmware build succeeded"
}

build_slave() {
    banner "Building EtherCAT slave (Tang Nano 20K — apio)"
    require_venv

    info "Generating EEPROM binary..."
    "$VENV/bin/python" "$SLAVE_DIR/eeprom/gen_eeprom.py"

    info "apio build..."
    # apio reads apio.ini in SLAVE_DIR (board=tangnano20k, top-module=top)
    # and synthesises all .v files in rtl/ via oss-cad-suite
    (cd "$SLAVE_DIR" && "$VENV/bin/apio" build)

    # apio writes the bitstream to hardware/
    local fs_out="$SLAVE_DIR/hardware/top.fs"
    [[ -f "$fs_out" ]] || { fail "apio build did not produce a bitstream at $fs_out"; exit 1; }

    ok "Build complete → $fs_out"
}

do_build() {
    case "$TARGET" in
        agent)    setup_log "build_agent.log";    build_agent ;;
        firmware) setup_log "build_firmware.log"; build_firmware ;;
        slave)    setup_log "build_slave.log";    build_slave ;;
        all)
            setup_log "build_all.log"
            build_firmware; build_slave; build_agent ;;
        *) fail "Unknown build target: $TARGET"; exit 1 ;;
    esac
}

# ══════════════════════════════════════════════════════════════════════════════
# CLEAN
# ══════════════════════════════════════════════════════════════════════════════
clean_agent() {
    banner "Cleaning agent build"
    rm -rf "$AGENT_DIR/build"
    ok "Removed $AGENT_DIR/build"
}

clean_firmware() {
    banner "Cleaning firmware build"
    rm -rf "$FIRMWARE_DIR/build"
    ok "Removed $FIRMWARE_DIR/build"
}

clean_slave() {
    banner "Cleaning FPGA build"
    (cd "$SLAVE_DIR" && "$VENV/bin/apio" clean 2>/dev/null || true)
    rm -rf "$SLAVE_DIR/hardware" "$SLAVE_DIR/.apio"
    ok "FPGA build artefacts removed"
}

clean_all() {
    banner "Deep clean — removing all generated and downloaded files"

    # Build artefacts
    info "Removing build artefacts..."
    rm -rf "$AGENT_DIR/build"
    rm -rf "$FIRMWARE_DIR/build"
    rm -rf "$SLAVE_DIR/build/gowin_proj" \
           "$SLAVE_DIR/build/ethercat_slave.json" \
           "$SLAVE_DIR/build/ethercat_slave.fs"

    # Downloaded SDKs and toolchains
    info "Removing tools/ (ESP-IDF, Xtensa toolchain)..."
    rm -rf "$TOOLS_DIR"

    # Python venv
    info "Removing Python venv..."
    rm -rf "$VENV"

    # Cloned components
    info "Removing cloned components..."
    rm -rf "$UROS_COMP"

    # Logs
    info "Removing logs..."
    rm -f "$LOGS_DIR"/*.log

    # Python cache
    find "$ROOT" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
    find "$ROOT" -type d -name ".pytest_cache" -exec rm -rf {} + 2>/dev/null || true

    ok "Workspace clean — only project source files remain"
    echo ""
    info "To rebuild from scratch: bash setup.sh"
}

do_clean() {
    case "$TARGET" in
        agent)    setup_log "clean_agent.log";    clean_agent ;;
        firmware) setup_log "clean_firmware.log"; clean_firmware ;;
        slave)    setup_log "clean_slave.log";    clean_slave ;;
        all)      clean_all ;;   # no log — removes the logs dir itself
        *) fail "Unknown clean target: $TARGET"; exit 1 ;;
    esac
}

# ══════════════════════════════════════════════════════════════════════════════
# TEST
# ══════════════════════════════════════════════════════════════════════════════
test_agent() {
    banner "Testing PC agent (GTest)"
    cmake_build "$AGENT_DIR/build" -DBUILD_TESTS=ON -DCMAKE_BUILD_TYPE=Debug
    ctest --test-dir "$AGENT_DIR/build" --output-on-failure
    ok "All agent tests passed"
}

test_slave() {
    banner "Testing EtherCAT slave (cocotb + iverilog)"
    require_venv
    "$VENV/bin/pytest" "$SLAVE_DIR/tests/" -v --tb=short
    ok "Slave simulation tests passed"
}

test_firmware() {
    banner "Testing firmware (Unity via ESP-IDF)"
    require_idf
    idf.py -C "$FIRMWARE_DIR/test" build flash monitor
}

do_test() {
    case "$TARGET" in
        agent)    setup_log "test_agent.log";    test_agent ;;
        firmware) setup_log "test_firmware.log"; test_firmware ;;
        slave)    setup_log "test_slave.log";    test_slave ;;
        all)      setup_log "test_all.log";      test_agent; test_slave; test_firmware ;;
        *) fail "Unknown test target: $TARGET"; exit 1 ;;
    esac
}

# ══════════════════════════════════════════════════════════════════════════════
# RUN
# ══════════════════════════════════════════════════════════════════════════════
do_run() {
    setup_log "run.log"
    case "$TARGET" in
        agent)
            banner "Running micro-ROS EtherCAT agent on $ETH_IFACE"
            local bin="$AGENT_DIR/build/micro_ros_ethercat_agent"
            [[ -x "$bin" ]] || { fail "Agent not built. Run: ./run.sh --build agent"; exit 1; }
            info "Starting agent (Ctrl+C to stop)..."
            sudo "$bin" --iface "$ETH_IFACE" --slave "${ETHERCAT_SLAVE:-1}"
            ;;
        *) fail "Unknown run target: $TARGET"; exit 1 ;;
    esac
}

# ══════════════════════════════════════════════════════════════════════════════
# LOAD-ECAT — Flash Tang Nano 20K
# ══════════════════════════════════════════════════════════════════════════════
do_load_ecat() {
    setup_log "load-ecat.log"
    banner "Flashing Tang Nano 20K (EtherCAT slave)"
    require_venv
    [[ -f "$SLAVE_DIR/hardware/top.fs" ]] || { fail "Bitstream not found. Run: ./run.sh --build slave"; exit 1; }
    info "Flashing via apio upload..."
    (cd "$SLAVE_DIR" && "$VENV/bin/apio" upload)
    ok "Tang Nano 20K flashed successfully"
}

# ══════════════════════════════════════════════════════════════════════════════
# LOAD-MCU — Flash ESP32
# ══════════════════════════════════════════════════════════════════════════════
do_load_mcu() {
    setup_log "load-mcu.log"
    banner "Flashing ESP32 (micro-ROS firmware)"
    require_idf
    [[ -d "$FIRMWARE_DIR/build" ]] || { fail "Firmware not built. Run: ./run.sh --build firmware"; exit 1; }
    info "Flashing to $SERIAL_PORT at ${BAUD_RATE} baud..."
    idf.py -C "$FIRMWARE_DIR" flash -p "$SERIAL_PORT" -b "$BAUD_RATE"
    ok "ESP32 flashed successfully"
    info "Monitor: idf.py -C $FIRMWARE_DIR monitor -p $SERIAL_PORT"
}

# ── Dispatch ──────────────────────────────────────────────────────────────────
case "$ACTION" in
    build)     do_build    ;;
    clean)     do_clean    ;;
    test)      do_test     ;;
    run)       do_run      ;;
    load-ecat) do_load_ecat ;;
    load-mcu)  do_load_mcu  ;;
esac
