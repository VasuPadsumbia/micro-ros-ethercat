#!/usr/bin/env python3
"""
script.py — micro-ROS EtherCAT project orchestrator

Usage:
  python script.py --build [all|firmware|slave|agent]
  python script.py --clean [all|firmware|slave|agent]
  python script.py --test  [all|firmware|slave|agent]
  python script.py --run   [agent|flash-firmware|flash-slave]

Options:
  --port PORT      Serial port for firmware flashing (default: /dev/ttyUSB0)
  --eth  IFACE     Ethernet interface for EtherCAT agent (default: eth0)
  --baud BAUD      Baud rate for flashing (default: 460800)
"""
import argparse
import os
import subprocess
import sys
from pathlib import Path

# ── Paths ─────────────────────────────────────────────────────────────────────
ROOT = Path(__file__).resolve().parent
VENV = ROOT / ".venv"
FIRMWARE_DIR = ROOT / "firmware"
SLAVE_DIR = ROOT / "ethercat-slave"
AGENT_DIR = ROOT / "agent"
DOCS_DIR = ROOT / "docs"

# ── Helpers ───────────────────────────────────────────────────────────────────
RESET = "\033[0m"
BOLD = "\033[1m"
GREEN = "\033[32m"
RED = "\033[31m"
CYAN = "\033[36m"
YELLOW = "\033[33m"


def banner(msg: str) -> None:
    print(f"\n{BOLD}{CYAN}{'━'*60}{RESET}")
    print(f"{BOLD}{CYAN}  {msg}{RESET}")
    print(f"{BOLD}{CYAN}{'━'*60}{RESET}\n")


def ok(msg: str) -> None:
    print(f"{GREEN}✔ {msg}{RESET}")


def fail(msg: str) -> None:
    print(f"{RED}✘ {msg}{RESET}", file=sys.stderr)


def run(cmd: list[str], cwd: Path = ROOT, env: dict | None = None) -> int:
    e = os.environ.copy()
    if env:
        e.update(env)
    print(f"{YELLOW}$ {' '.join(str(c) for c in cmd)}{RESET}")
    result = subprocess.run(cmd, cwd=cwd, env=e)
    return result.returncode


def require_venv() -> dict:
    """Return env vars that activate the venv."""
    venv_bin = VENV / "bin"
    if not venv_bin.exists():
        fail("venv not found. Run: bash setup.sh")
        sys.exit(1)
    return {
        "VIRTUAL_ENV": str(VENV),
        "PATH": f"{venv_bin}:{os.environ['PATH']}",
    }


# ── Build ─────────────────────────────────────────────────────────────────────
def build_firmware() -> int:
    banner("Building ESP32 firmware")
    idf_path = Path.home() / "esp" / "esp-idf"
    if not idf_path.exists():
        fail(f"ESP-IDF not found at {idf_path}. Run: bash setup.sh")
        return 1
    env = {
        "IDF_PATH": str(idf_path),
        "PATH": f"{idf_path}/tools:{os.environ['PATH']}",
    }
    rc = run(["python", f"{idf_path}/tools/idf.py", "build"], cwd=FIRMWARE_DIR, env=env)
    if rc == 0:
        ok("Firmware build succeeded")
    else:
        fail("Firmware build failed")
    return rc


def build_slave() -> int:
    banner("Building EtherCAT slave (FPGA)")
    # Generate EEPROM binary first
    gen = SLAVE_DIR / "eeprom" / "gen_eeprom.py"
    env = require_venv()
    rc = run(["python", str(gen)], cwd=SLAVE_DIR / "eeprom", env=env)
    if rc != 0:
        fail("EEPROM generation failed")
        return rc

    # Synthesize with Yosys + nextpnr-gowin (open source flow)
    rtl_files = list((SLAVE_DIR / "rtl").glob("*.v"))
    if not rtl_files:
        fail("No RTL files found")
        return 1

    build_dir = SLAVE_DIR / "build" / "out"
    build_dir.mkdir(parents=True, exist_ok=True)

    top_file = SLAVE_DIR / "rtl" / "top.v"
    json_out = build_dir / "ethercat_slave.json"
    cst_file = SLAVE_DIR / "constraints" / "tang_nano_20k.cst"
    fs_out = build_dir / "ethercat_slave.fs"

    # Yosys synthesis
    rtl_str = " ".join(str(f) for f in rtl_files)
    yosys_script = (
        f"read_verilog -sv {rtl_str}; "
        f"synth_gowin -top top -json {json_out}"
    )
    rc = run(["yosys", "-p", yosys_script])
    if rc != 0:
        fail("Yosys synthesis failed")
        return rc

    # nextpnr place-and-route
    rc = run([
        "nextpnr-gowin",
        "--json", str(json_out),
        "--write", str(fs_out),
        "--device", "GW2AR-LV18QN88C8/I7",
        "--cst", str(cst_file),
    ])
    if rc != 0:
        fail("nextpnr-gowin P&R failed")
        return rc

    ok(f"FPGA bitstream: {fs_out}")
    return 0


def build_agent() -> int:
    banner("Building PC agent")
    build_dir = AGENT_DIR / "build"
    build_dir.mkdir(exist_ok=True)

    soem_dir = AGENT_DIR / "soem"
    if not soem_dir.exists():
        fail("SOEM not found. Run: bash setup.sh")
        return 1

    rc = run(["cmake", "..", "-GNinja",
              f"-DSOEM_DIR={soem_dir}",
              "-DCMAKE_BUILD_TYPE=Release"],
             cwd=build_dir)
    if rc != 0:
        return rc
    rc = run(["ninja"], cwd=build_dir)
    if rc == 0:
        ok("Agent build succeeded")
    else:
        fail("Agent build failed")
    return rc


BUILD_MAP = {
    "firmware": build_firmware,
    "slave": build_slave,
    "agent": build_agent,
}


def do_build(target: str) -> int:
    targets = list(BUILD_MAP.keys()) if target == "all" else [target]
    for t in targets:
        rc = BUILD_MAP[t]()
        if rc != 0:
            return rc
    return 0


# ── Clean ─────────────────────────────────────────────────────────────────────
def clean_firmware() -> int:
    banner("Cleaning firmware")
    idf_path = Path.home() / "esp" / "esp-idf"
    env = {"IDF_PATH": str(idf_path), "PATH": os.environ["PATH"]}
    return run(["python", f"{idf_path}/tools/idf.py", "fullclean"],
               cwd=FIRMWARE_DIR, env=env)


def clean_slave() -> int:
    banner("Cleaning FPGA build")
    import shutil
    out = SLAVE_DIR / "build" / "out"
    if out.exists():
        shutil.rmtree(out)
        ok(f"Removed {out}")
    return 0


def clean_agent() -> int:
    banner("Cleaning agent build")
    import shutil
    bd = AGENT_DIR / "build"
    if bd.exists():
        shutil.rmtree(bd)
        ok(f"Removed {bd}")
    return 0


CLEAN_MAP = {
    "firmware": clean_firmware,
    "slave": clean_slave,
    "agent": clean_agent,
}


def do_clean(target: str) -> int:
    targets = list(CLEAN_MAP.keys()) if target == "all" else [target]
    for t in targets:
        rc = CLEAN_MAP[t]()
        if rc != 0:
            return rc
    return 0


# ── Test ──────────────────────────────────────────────────────────────────────
def test_firmware() -> int:
    banner("Testing firmware (Unity via ESP-IDF)")
    idf_path = Path.home() / "esp" / "esp-idf"
    test_dir = FIRMWARE_DIR / "test"
    if not test_dir.exists():
        fail("No firmware test directory found")
        return 1
    env = {"IDF_PATH": str(idf_path), "PATH": os.environ["PATH"]}
    return run(["python", f"{idf_path}/tools/idf.py", "build", "flash", "monitor"],
               cwd=test_dir, env=env)


def test_slave() -> int:
    banner("Testing EtherCAT slave (cocotb + iverilog)")
    env = require_venv()
    return run(["pytest", "tests/", "-v", "--tb=short"], cwd=SLAVE_DIR, env=env)


def test_agent() -> int:
    banner("Testing PC agent (GTest)")
    build_dir = AGENT_DIR / "build"
    build_dir.mkdir(exist_ok=True)
    soem_dir = AGENT_DIR / "soem"
    rc = run(["cmake", "..", "-GNinja",
              f"-DSOEM_DIR={soem_dir}",
              "-DCMAKE_BUILD_TYPE=Debug",
              "-DBUILD_TESTS=ON"],
             cwd=build_dir)
    if rc != 0:
        return rc
    rc = run(["ninja"], cwd=build_dir)
    if rc != 0:
        return rc
    return run(["ctest", "--output-on-failure"], cwd=build_dir)


TEST_MAP = {
    "firmware": test_firmware,
    "slave": test_slave,
    "agent": test_agent,
}


def do_test(target: str) -> int:
    targets = list(TEST_MAP.keys()) if target == "all" else [target]
    for t in targets:
        rc = TEST_MAP[t]()
        if rc != 0:
            return rc
    return 0


# ── Run ───────────────────────────────────────────────────────────────────────
def run_agent(eth: str) -> int:
    banner(f"Running micro-ROS EtherCAT agent on {eth}")
    agent_bin = AGENT_DIR / "build" / "micro_ros_ethercat_agent"
    if not agent_bin.exists():
        fail("Agent not built. Run: python script.py --build agent")
        return 1
    return run(["sudo", str(agent_bin), "--iface", eth])


def flash_firmware(port: str, baud: str) -> int:
    banner(f"Flashing firmware to {port}")
    idf_path = Path.home() / "esp" / "esp-idf"
    env = {"IDF_PATH": str(idf_path), "PATH": os.environ["PATH"]}
    return run(["python", f"{idf_path}/tools/idf.py",
                "flash", "-p", port, "-b", baud],
               cwd=FIRMWARE_DIR, env=env)


def flash_slave() -> int:
    banner("Flashing FPGA bitstream via openFPGALoader")
    fs = SLAVE_DIR / "build" / "out" / "ethercat_slave.fs"
    if not fs.exists():
        fail("Bitstream not found. Run: python script.py --build slave")
        return 1
    return run(["openFPGALoader", "-b", "tangnano20k", str(fs)])


# ── Main ──────────────────────────────────────────────────────────────────────
def main() -> int:
    parser = argparse.ArgumentParser(
        description="micro-ROS EtherCAT project orchestrator",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument("--build", nargs="?", const="all",
                        choices=["all", "firmware", "slave", "agent"],
                        metavar="TARGET")
    parser.add_argument("--clean", nargs="?", const="all",
                        choices=["all", "firmware", "slave", "agent"],
                        metavar="TARGET")
    parser.add_argument("--test", nargs="?", const="all",
                        choices=["all", "firmware", "slave", "agent"],
                        metavar="TARGET")
    parser.add_argument("--run",
                        choices=["agent", "flash-firmware", "flash-slave"],
                        metavar="ACTION")
    parser.add_argument("--port", default="/dev/ttyUSB0",
                        help="Serial port for firmware flash (default: /dev/ttyUSB0)")
    parser.add_argument("--eth", default="eth0",
                        help="Ethernet interface for EtherCAT agent (default: eth0)")
    parser.add_argument("--baud", default="460800",
                        help="Flash baud rate (default: 460800)")
    args = parser.parse_args()

    if not any([args.build, args.clean, args.test, args.run]):
        parser.print_help()
        return 0

    rc = 0
    if args.build:
        rc = do_build(args.build)
    if args.clean and rc == 0:
        rc = do_clean(args.clean)
    if args.test and rc == 0:
        rc = do_test(args.test)
    if args.run and rc == 0:
        if args.run == "agent":
            rc = run_agent(args.eth)
        elif args.run == "flash-firmware":
            rc = flash_firmware(args.port, args.baud)
        elif args.run == "flash-slave":
            rc = flash_slave()

    return rc


if __name__ == "__main__":
    sys.exit(main())
