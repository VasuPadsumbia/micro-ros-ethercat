"""
conftest.py — pytest configuration for cocotb-based FPGA simulation tests.

Each test module corresponds to one RTL module. Tests are compiled with
iverilog and run with cocotb (SIM=icarus).

Strategy: cocotb coroutines are named sim_* (not test_*) so pytest doesn't
try to collect them. Each cocotb test also has a plain def test_*() wrapper
that invokes the simulator with COCOTB_TESTCASE filtering so pytest sees
individual test items with proper PASS/FAIL reporting.

Waveforms: each test generates a VCD dump at
  data/test/waves/<test_module>/<test_name>/dump.vcd
  (viewable in GTKWave)

Dependencies (from requirements.txt):
  cocotb>=1.8
  pytest>=7.4
  pytest-html>=4.1
"""
import os
import warnings

# Suppress the "Python runners are experimental" warning globally
warnings.filterwarnings("ignore", message="Python runners.*experimental")

os.environ.setdefault("SIM", "icarus")
os.environ.setdefault("COCOTB_RESOLVE_X", "ZEROS")

# Paths
_TESTS_DIR   = os.path.dirname(__file__)
RTL_DIR      = os.path.abspath(os.path.join(_TESTS_DIR, "..", "rtl"))
_WAVES_BASE  = os.path.abspath(os.path.join(_TESTS_DIR, "..", "..", "..", "data", "test", "waves"))


def rtl(*files) -> list[str]:
    """Return absolute paths to RTL source files."""
    return [os.path.join(RTL_DIR, f) for f in files]


def sim_run(sources: list[str], toplevel: str, module: str, test_name: str) -> None:
    """
    Compile the RTL with iverilog and run one named cocotb test.

    Args:
        sources:   RTL source files.
        toplevel:  Top-level Verilog module name.
        module:    Python test module name (e.g. 'test_ethercat').
        test_name: Name of the sim_* coroutine to run.

    Waveform output: data/test/waves/<module>/<test_name>/dump.vcd
    """
    from cocotb.runner import get_runner
    warnings.filterwarnings("ignore", message="Python runners.*experimental")

    waves_dir = os.path.join(_WAVES_BASE, module, test_name)
    os.makedirs(waves_dir, exist_ok=True)

    runner = get_runner("icarus")
    runner.build(
        sources=sources,
        hdl_toplevel=toplevel,
        build_args=["-DCOCOTB_SIM=1"],
        timescale=("1ns", "1ps"),
        build_dir=os.path.join(waves_dir, "sim_build"),
        waves=True,
        always=True,
    )
    runner.test(
        hdl_toplevel=toplevel,
        test_module=module,
        build_dir=os.path.join(waves_dir, "sim_build"),
        waves=True,
        extra_env={"COCOTB_TESTCASE": test_name},
    )
